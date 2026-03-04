[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,
    [string]$ApiKey = $env:PIXTOOLS_API_KEY,
    [ValidateSet("baseline", "spike")]
    [string]$Scenario = "baseline",
    [string]$Duration = "2m",
    [int]$Vus = 8,
    [switch]$PollCompletion,
    [int]$PollMaxSeconds = 180,
    [int]$WatchIntervalSeconds = 30,
    [string]$Region = "us-east-1",
    [string]$Environment = "dev",
    [string]$ProjectTag = "pixtools",
    [string]$OutputDir = "bench/results",
    [switch]$ExportRawJson,
    [switch]$SkipClusterWatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is not installed or not on PATH."
    }
}

function Get-K3sServerInstanceId {
    param(
        [Parameter(Mandatory = $true)][string]$AwsRegion,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$EnvName
    )

    $instanceId = aws ec2 describe-instances `
        --region $AwsRegion `
        --filters `
            Name=tag:Project,Values=$Project `
            Name=tag:Environment,Values=$EnvName `
            Name=tag:Role,Values=k3s-server `
            Name=instance-state-name,Values=running `
        --query "Reservations[].Instances[] | sort_by(@, &LaunchTime) | [-1].InstanceId" `
        --output text

    if ([string]::IsNullOrWhiteSpace($instanceId) -or $instanceId -eq "None") {
        throw "Could not find a running K3s server instance for project=$Project environment=$EnvName."
    }

    return $instanceId.Trim()
}

function Wait-SsmInvocation {
    param(
        [Parameter(Mandatory = $true)][string]$AwsRegion,
        [Parameter(Mandatory = $true)][string]$CommandId,
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [int]$TimeoutSeconds = 180
    )

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $status = aws ssm get-command-invocation `
            --region $AwsRegion `
            --command-id $CommandId `
            --instance-id $InstanceId `
            --query Status `
            --output text

        if ($status -in @("Success", "Failed", "Cancelled", "TimedOut", "Undeliverable", "Terminated")) {
            return $status
        }

        Start-Sleep -Seconds 5
        $elapsed += 5
    }

    throw "Timed out waiting for SSM command $CommandId after $TimeoutSeconds seconds."
}

function Invoke-ClusterSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$AwsRegion,
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$SnapshotDir
    )

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeLabel = $Label -replace "[^a-zA-Z0-9_-]", "-"
    $jsonPath = Join-Path $env:TEMP "pixtools-ssm-$safeLabel-$timestamp.json"
    $outPath = Join-Path $SnapshotDir "$timestamp-$safeLabel.txt"

    $commands = @(
        "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
        "echo '=== SNAPSHOT ==='",
        "date -Is",
        "echo '=== SCALEDOBJECTS ==='",
        "kubectl get scaledobject -n pixtools",
        "echo '=== HPA ==='",
        "kubectl get hpa -n pixtools",
        "echo '=== DEPLOYMENTS ==='",
        "kubectl get deploy -n pixtools",
        "echo '=== PODS ==='",
        "kubectl get pods -n pixtools -o wide",
        "echo '=== NODES ==='",
        "kubectl get nodes -o wide",
        "echo '=== POD TOP ==='",
        "kubectl top pods -n pixtools || true",
        "echo '=== RECENT EVENTS ==='",
        "kubectl get events -n pixtools --sort-by=.lastTimestamp | tail -n 25"
    )

    $payload = @{ commands = $commands } | ConvertTo-Json -Depth 5 -Compress
    $payload | Out-File -FilePath $jsonPath -Encoding ascii

    try {
        $commandId = aws ssm send-command `
            --region $AwsRegion `
            --instance-ids $InstanceId `
            --document-name AWS-RunShellScript `
            --parameters file://$jsonPath `
            --query Command.CommandId `
            --output text

        $status = Wait-SsmInvocation -AwsRegion $AwsRegion -CommandId $commandId.Trim() -InstanceId $InstanceId
        $stdout = aws ssm get-command-invocation `
            --region $AwsRegion `
            --command-id $commandId.Trim() `
            --instance-id $InstanceId `
            --query StandardOutputContent `
            --output text
        $stderr = aws ssm get-command-invocation `
            --region $AwsRegion `
            --command-id $commandId.Trim() `
            --instance-id $InstanceId `
            --query StandardErrorContent `
            --output text

        @(
            "Snapshot label: $Label"
            "SSM command: $commandId"
            "Status: $status"
            ""
            "--- STDOUT ---"
            $stdout
            ""
            "--- STDERR ---"
            $stderr
        ) | Set-Content -Path $outPath -Encoding ascii

        return $outPath
    }
    finally {
        if (Test-Path $jsonPath) {
            Remove-Item $jsonPath -Force
        }
    }
}

Assert-Command -Name "aws"
Assert-Command -Name "k6"

$runnerPath = Resolve-Path "bench/run-k6.ps1"
$repoRoot = (Get-Location).Path
$testImagePath = Resolve-Path "test_image.png" -ErrorAction SilentlyContinue
if (-not $testImagePath) {
    throw "test_image.png was not found at the repo root. k6 upload scenarios require it."
}

New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$runDir = Join-Path $OutputDir "small-stress-$runId"
$snapshotDir = Join-Path $runDir "cluster"
New-Item -Path $runDir -ItemType Directory -Force | Out-Null
New-Item -Path $snapshotDir -ItemType Directory -Force | Out-Null

$extraEnv = @(
    "VUS=$Vus",
    "DURATION=$Duration"
)
if ($PollCompletion) {
    $extraEnv += @(
        "POLL_COMPLETION=true",
        "POLL_MAX_SECONDS=$PollMaxSeconds"
    )
}

$instanceId = $null
if (-not $SkipClusterWatch) {
    $instanceId = Get-K3sServerInstanceId -AwsRegion $Region -Project $ProjectTag -EnvName $Environment
    Write-Host "Using K3s server instance $instanceId for live snapshots." -ForegroundColor Cyan
    $prePath = Invoke-ClusterSnapshot -AwsRegion $Region -InstanceId $instanceId -Label "pre" -SnapshotDir $snapshotDir
    Write-Host "Captured pre-run snapshot: $prePath" -ForegroundColor Green
}

$k6Job = Start-Job -ScriptBlock {
    param(
        [string]$RepoRoot,
        [string]$Runner,
        [string]$RunScenario,
        [string]$RunBaseUrl,
        [string]$RunApiKey,
        [string]$RunOutputDir,
        [bool]$ShouldExportRawJson,
        [string[]]$RunExtraEnv
    )

    Set-Location $RepoRoot
    & $Runner `
        -Scenario $RunScenario `
        -BaseUrl $RunBaseUrl `
        -ApiKey $RunApiKey `
        -OutputDir $RunOutputDir `
        -ExportRawJson:$ShouldExportRawJson `
        -ExtraEnv $RunExtraEnv
} -ArgumentList @(
    $repoRoot,
    $runnerPath.Path,
    $Scenario,
    $BaseUrl,
    $ApiKey,
    $runDir,
    $ExportRawJson.IsPresent,
    $extraEnv
)

$snapshotIndex = 1
try {
    while ($k6Job.State -eq "Running" -or $k6Job.State -eq "NotStarted") {
        $completed = Wait-Job -Job $k6Job -Timeout $WatchIntervalSeconds
        if ($completed) {
            break
        }

        if (-not $SkipClusterWatch -and $instanceId) {
            $tickLabel = "tick-{0:D3}" -f $snapshotIndex
            $tickPath = Invoke-ClusterSnapshot `
                -AwsRegion $Region `
                -InstanceId $instanceId `
                -Label $tickLabel `
                -SnapshotDir $snapshotDir
            Write-Host "Captured live snapshot: $tickPath" -ForegroundColor Green
            $snapshotIndex += 1
        }
    }

    Receive-Job -Job $k6Job -ErrorAction Stop | Out-Host
}
finally {
    if (-not $SkipClusterWatch -and $instanceId) {
        $postPath = Invoke-ClusterSnapshot -AwsRegion $Region -InstanceId $instanceId -Label "post" -SnapshotDir $snapshotDir
        Write-Host "Captured post-run snapshot: $postPath" -ForegroundColor Green
    }

    Remove-Job -Job $k6Job -Force -ErrorAction SilentlyContinue
}

Write-Host "Small stress run completed. Output directory: $runDir" -ForegroundColor Green
