[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    [string]$Environment = "dev",
    [string]$ProjectTag = "pixtools",
    [string]$BaseUrl = "",
    [string]$ApiKey = "",
    [string]$OutputDir = "bench/results",
    [string]$RunnerInstanceType = "m7i-flex.large",
    [string]$RunnerName = "pixtools-dev-temp-prod-perf",
    [string]$RunnerAmiId = "",
    [int]$BaselineVus = 30,
    [string]$BaselineDuration = "10m",
    [int]$SpikeVus = 120,
    [string]$SpikeDuration = "5m",
    [int]$RetryVus = 60,
    [string]$RetryDuration = "5m",
    [string]$RetryRequestTimeout = "8s",
    [int]$RetryMaxAttempts = 2,
    [string]$StarvationDuration = "8m",
    [int]$StarvationHeavyRps = 8,
    [int]$StarvationLightRps = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is not installed or not on PATH."
    }
}

function Wait-SsmOnline {
    param(
        [Parameter(Mandatory = $true)][string]$AwsRegion,
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [int]$TimeoutSeconds = 600
    )
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $status = aws ssm describe-instance-information `
            --region $AwsRegion `
            --filters Key=InstanceIds,Values=$InstanceId `
            --query "InstanceInformationList[0].PingStatus" `
            --output text 2>$null
        if ($status -eq "Online") {
            return
        }
        Start-Sleep -Seconds 10
        $elapsed += 10
    }
    throw "SSM did not become online for $InstanceId within $TimeoutSeconds seconds."
}

function Wait-SsmInvocation {
    param(
        [Parameter(Mandatory = $true)][string]$AwsRegion,
        [Parameter(Mandatory = $true)][string]$CommandId,
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [int]$TimeoutSeconds = 7200
    )
    $elapsed = 0
    $lastPrintedStatus = ""
    $lastPrintedAt = -9999
    while ($elapsed -lt $TimeoutSeconds) {
        $status = aws ssm get-command-invocation `
            --region $AwsRegion `
            --command-id $CommandId `
            --instance-id $InstanceId `
            --query "Status" `
            --output text
        if ($status -ne $lastPrintedStatus -or ($elapsed - $lastPrintedAt) -ge 60) {
            Write-Host "SSM command $CommandId status=$status elapsed=${elapsed}s" -ForegroundColor DarkGray
            $lastPrintedStatus = $status
            $lastPrintedAt = $elapsed
        }
        if ($status -in @("Success", "Failed", "Cancelled", "TimedOut", "Undeliverable", "Terminated")) {
            return $status
        }
        Start-Sleep -Seconds 10
        $elapsed += 10
    }
    throw "Timed out waiting for command $CommandId."
}

function Invoke-SsmScript {
    param(
        [Parameter(Mandatory = $true)][string]$AwsRegion,
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string[]]$Commands,
        [int]$TimeoutSeconds = 7200
    )

    $payloadPath = Join-Path $env:TEMP ("pixtools-perf-" + [guid]::NewGuid().ToString("N") + ".json")
    try {
        (@{ commands = $Commands } | ConvertTo-Json -Depth 10 -Compress) | Set-Content -Path $payloadPath -Encoding ascii
        $cmdId = aws ssm send-command `
            --region $AwsRegion `
            --instance-ids $InstanceId `
            --document-name AWS-RunShellScript `
            --timeout-seconds $TimeoutSeconds `
            --parameters file://$payloadPath `
            --query "Command.CommandId" `
            --output text
        $status = Wait-SsmInvocation -AwsRegion $AwsRegion -CommandId $cmdId -InstanceId $InstanceId -TimeoutSeconds $TimeoutSeconds
        $stdoutLines = aws ssm get-command-invocation `
            --region $AwsRegion `
            --command-id $cmdId `
            --instance-id $InstanceId `
            --query "StandardOutputContent" `
            --output text
        $stderrLines = aws ssm get-command-invocation `
            --region $AwsRegion `
            --command-id $cmdId `
            --instance-id $InstanceId `
            --query "StandardErrorContent" `
            --output text
        $stdout = (@($stdoutLines) -join "`n")
        $stderr = (@($stderrLines) -join "`n")
        return [pscustomobject]@{
            CommandId = $cmdId
            Status = $status
            Stdout = $stdout
            Stderr = $stderr
        }
    }
    finally {
        Remove-Item -Path $payloadPath -Force -ErrorAction SilentlyContinue
    }
}

function Save-TextArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][psobject]$Result
    )
    @(
        "Title: $Title"
        "CommandId: $($Result.CommandId)"
        "Status: $($Result.Status)"
        ""
        "--- STDOUT ---"
        $Result.Stdout
        ""
        "--- STDERR ---"
        $Result.Stderr
    ) | Set-Content -Path $Path -Encoding ascii
}

function Get-JsonAfterMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Marker
    )
    $lines = $Text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq $Marker -and ($i + 1) -lt $lines.Count) {
            $candidate = $lines[$i + 1].Trim()
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                return $null
            }
            try {
                return ($candidate | ConvertFrom-Json)
            }
            catch {
                return $null
            }
        }
    }
    return $null
}

function Run-K6ScenarioRemote {
    param(
        [Parameter(Mandatory = $true)][string]$AwsRegion,
        [Parameter(Mandatory = $true)][string]$RunnerInstanceId,
        [Parameter(Mandatory = $true)][string]$ScenarioName,
        [Parameter(Mandatory = $true)][string[]]$EnvExports,
        [int]$TimeoutSeconds = 7200
    )

    $summaryPath = "/tmp/pix-prod-perf/$ScenarioName-summary.json"
    $rawPath = "/tmp/pix-prod-perf/$ScenarioName-raw.json"
    $logPath = "/tmp/pix-prod-perf/$ScenarioName.log"

    $commands = @(
        "set -euo pipefail",
        "cd /tmp/PixTools",
        "mkdir -p /tmp/pix-prod-perf"
    )
    $commands += $EnvExports
    $commands += @(
        "k6 run --no-thresholds --summary-export $summaryPath --out json=$rawPath bench/k6/$ScenarioName.js >$logPath",
        "echo __SUMMARY__",
        "jq -c '{scenario:`"$ScenarioName`",submitted:(.metrics.jobs_submitted_total.count // .metrics.jobs_submitted_total.values.count // 0),completed:(.metrics.jobs_completed_total.count // .metrics.jobs_completed_total.values.count // 0),failed_jobs:(.metrics.jobs_failed_total.count // .metrics.jobs_failed_total.values.count // 0),failed_after_retries:(.metrics.failed_after_retries_total.count // .metrics.failed_after_retries_total.values.count // 0),dup_signals:(.metrics.duplicate_processing_signals_total.count // .metrics.duplicate_processing_signals_total.values.count // 0),client_retries:(.metrics.client_retries_total.count // .metrics.client_retries_total.values.count // 0),mix_failures:(.metrics.mix_failures_total.count // .metrics.mix_failures_total.values.count // 0),heavy_submitted:(.metrics.heavy_jobs_submitted_total.count // .metrics.heavy_jobs_submitted_total.values.count // 0),light_submitted:(.metrics.light_jobs_submitted_total.count // .metrics.light_jobs_submitted_total.values.count // 0),http_failed_rate:(.metrics.http_req_failed.value // .metrics.http_req_failed.values.rate // .metrics.http_req_failed.rate // 0),http_avg_ms:(.metrics.http_req_duration.avg // .metrics.http_req_duration.values.avg // 0),http_p95_ms:(.metrics.http_req_duration[`"p(95)`"] // .metrics.http_req_duration.values[`"p(95)`"] // 0),light_http_p95_ms:(.metrics[`"http_req_duration{workload:light}`"][`"p(95)`"] // .metrics[`"http_req_duration{workload:light}`"].values[`"p(95)`"] // 0)}' $summaryPath",
        "echo __STATUS_COUNTS__",
        "jq -c -n 'reduce (inputs | select(.type==`"Point`" and .metric==`"http_reqs`")) as `$p ({}; .[(`$p.data.tags.status // `"NO_STATUS`")] += (`$p.data.value // 1))' $rawPath",
        "echo __TIMEOUT_POINTS__",
        "grep -i -c '`"error`":`"[^`"]*timeout' $rawPath || true"
    )

    $result = Invoke-SsmScript -AwsRegion $AwsRegion -InstanceId $RunnerInstanceId -Commands $commands -TimeoutSeconds $TimeoutSeconds
    return $result
}

Assert-Command -Name "aws"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path $OutputDir ("prod-perf-suite-$timestamp")
New-Item -Path $runRoot -ItemType Directory -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $lbHost = aws elbv2 describe-load-balancers `
        --region $Region `
        --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-pixtools-pixtools')].DNSName | [0]" `
        --output text
    if ([string]::IsNullOrWhiteSpace($lbHost) -or $lbHost -eq "None") {
        throw "Could not resolve ALB hostname automatically."
    }
    $BaseUrl = "http://$($lbHost.Trim())"
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $ApiKey = aws ssm get-parameter `
        --region $Region `
        --name "/pixtools/$Environment/api_key" `
        --with-decryption `
        --query "Parameter.Value" `
        --output text
}

$serverInstanceId = aws ec2 describe-instances `
    --region $Region `
    --filters Name=tag:Project,Values=$ProjectTag Name=tag:Environment,Values=$Environment Name=tag:Role,Values=k3s-server Name=instance-state-name,Values=running `
    --query "Reservations[].Instances[] | sort_by(@, &LaunchTime) | [-1].InstanceId" `
    --output text
if ([string]::IsNullOrWhiteSpace($serverInstanceId) -or $serverInstanceId -eq "None") {
    throw "Could not find running k3s-server instance."
}

$agentInfoJson = aws ec2 describe-instances `
    --region $Region `
    --filters Name=tag:Project,Values=$ProjectTag Name=tag:Environment,Values=$Environment Name=tag:Role,Values=k3s-agent Name=instance-state-name,Values=running `
    --query "Reservations[].Instances[] | sort_by(@,&LaunchTime) | [-1].{SubnetId:SubnetId,SecurityGroupId:SecurityGroups[0].GroupId,IamProfileArn:IamInstanceProfile.Arn}" `
    --output json
$agentInfo = $agentInfoJson | ConvertFrom-Json
if ($null -eq $agentInfo -or [string]::IsNullOrWhiteSpace($agentInfo.SubnetId)) {
    throw "Could not resolve runner networking from existing k3s-agent."
}
$instanceProfileName = ($agentInfo.IamProfileArn -split "/")[-1]

if ([string]::IsNullOrWhiteSpace($RunnerAmiId)) {
    $RunnerAmiId = aws ec2 describe-images `
        --region $Region `
        --owners amazon `
        --filters Name=name,Values='al2023-ami-2023*x86_64' Name=state,Values=available `
        --query "Images | sort_by(@,&CreationDate)[-1].ImageId" `
        --output text
}

$runnerInstanceId = $null
try {
    $runnerInstanceId = aws ec2 run-instances `
        --region $Region `
        --image-id $RunnerAmiId `
        --instance-type $RunnerInstanceType `
        --iam-instance-profile Name=$instanceProfileName `
        --subnet-id $agentInfo.SubnetId `
        --security-group-ids $agentInfo.SecurityGroupId `
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$RunnerName},{Key=Project,Value=$ProjectTag},{Key=Environment,Value=$Environment},{Key=Role,Value=loadgen-temp}]" `
        --query "Instances[0].InstanceId" `
        --output text

    aws ec2 wait instance-running --region $Region --instance-ids $runnerInstanceId
    Wait-SsmOnline -AwsRegion $Region -InstanceId $runnerInstanceId

    Write-Host "Runner online: $runnerInstanceId" -ForegroundColor Cyan
    Write-Host "Server: $serverInstanceId" -ForegroundColor Cyan
    Write-Host "Base URL: $BaseUrl" -ForegroundColor Cyan

    Write-Host "[1/8] Runner setup" -ForegroundColor Yellow
    $runnerSetup = Invoke-SsmScript -AwsRegion $Region -InstanceId $runnerInstanceId -TimeoutSeconds 1800 -Commands @(
        "set -euo pipefail",
        "sudo dnf install -y git jq tar gzip --allowerasing >/dev/null",
        "command -v k6 >/dev/null 2>&1 || (cd /tmp && curl -fsSL -o k6.tgz https://github.com/grafana/k6/releases/download/v0.49.0/k6-v0.49.0-linux-amd64.tar.gz && tar -xzf k6.tgz && sudo install k6-v0.49.0-linux-amd64/k6 /usr/local/bin/k6)",
        "rm -rf /tmp/PixTools && git clone --depth 1 https://github.com/NFRohan/PixTools.git /tmp/PixTools >/dev/null",
        "cd /tmp/PixTools",
        "if [ ! -f test_image.png ]; then echo 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlH0WwAAAAASUVORK5CYII=' | base64 -d > test_image.png; fi",
        "echo READY"
    )
    Save-TextArtifact -Path (Join-Path $runRoot "00-runner-setup.txt") -Title "runner setup" -Result $runnerSetup
    if ($runnerSetup.Status -ne "Success") {
        throw "Runner setup failed."
    }

    Write-Host "[2/8] Pre-run health probe" -ForegroundColor Yellow
    $preHealth = Invoke-SsmScript -AwsRegion $Region -InstanceId $runnerInstanceId -TimeoutSeconds 300 -Commands @(
        "set -euo pipefail",
        "for i in 1 2 3 4 5; do curl -s -o /dev/null -w 'health_rtt_s=%{time_total}`n' '$BaseUrl/api/health'; done"
    )
    Save-TextArtifact -Path (Join-Path $runRoot "01-pre-health.txt") -Title "pre health" -Result $preHealth

    Write-Host "[3/8] Pre-run cluster snapshot" -ForegroundColor Yellow
    $preCluster = Invoke-SsmScript -AwsRegion $Region -InstanceId $serverInstanceId -TimeoutSeconds 300 -Commands @(
        "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
        "echo ===NODES===",
        "kubectl get nodes -o wide",
        "echo ===HPA===",
        "kubectl -n pixtools get hpa",
        "echo ===SCALEDOBJECT===",
        "kubectl -n pixtools get scaledobject",
        "echo ===PODS===",
        "kubectl -n pixtools get pods -o wide",
        "echo ===TOP_NODES===",
        "kubectl top nodes || true",
        "echo ===TOP_PODS===",
        "kubectl -n pixtools top pods || true"
    )
    Save-TextArtifact -Path (Join-Path $runRoot "02-pre-cluster.txt") -Title "pre cluster" -Result $preCluster

    $results = @()

    Write-Host "[4/8] Scenario baseline" -ForegroundColor Yellow
    $baselineResult = Run-K6ScenarioRemote -AwsRegion $Region -RunnerInstanceId $runnerInstanceId -ScenarioName "baseline" -EnvExports @(
        "export BASE_URL='$BaseUrl' API_KEY='$ApiKey'",
        "export VUS=$BaselineVus DURATION=$BaselineDuration POLL_COMPLETION=true POLL_MAX_SECONDS=300 REQUEST_TIMEOUT=30s"
    ) -TimeoutSeconds 7200
    Save-TextArtifact -Path (Join-Path $runRoot "10-baseline.txt") -Title "baseline" -Result $baselineResult
    $results += [pscustomobject]@{
        Name = "baseline"
        CommandId = $baselineResult.CommandId
        Status = $baselineResult.Status
        Summary = Get-JsonAfterMarker -Text $baselineResult.Stdout -Marker "__SUMMARY__"
        StatusCounts = Get-JsonAfterMarker -Text $baselineResult.Stdout -Marker "__STATUS_COUNTS__"
        TimeoutPoints = Get-JsonAfterMarker -Text $baselineResult.Stdout -Marker "__TIMEOUT_POINTS__"
    }

    Write-Host "[5/8] Scenario spike" -ForegroundColor Yellow
    $spikeResult = Run-K6ScenarioRemote -AwsRegion $Region -RunnerInstanceId $runnerInstanceId -ScenarioName "spike" -EnvExports @(
        "export BASE_URL='$BaseUrl' API_KEY='$ApiKey'",
        "export VUS=$SpikeVus DURATION=$SpikeDuration REQUEST_TIMEOUT=20s"
    ) -TimeoutSeconds 7200
    Save-TextArtifact -Path (Join-Path $runRoot "20-spike.txt") -Title "spike" -Result $spikeResult
    $results += [pscustomobject]@{
        Name = "spike"
        CommandId = $spikeResult.CommandId
        Status = $spikeResult.Status
        Summary = Get-JsonAfterMarker -Text $spikeResult.Stdout -Marker "__SUMMARY__"
        StatusCounts = Get-JsonAfterMarker -Text $spikeResult.Stdout -Marker "__STATUS_COUNTS__"
        TimeoutPoints = Get-JsonAfterMarker -Text $spikeResult.Stdout -Marker "__TIMEOUT_POINTS__"
    }

    Write-Host "[6/8] Scenario retry_storm" -ForegroundColor Yellow
    $retryResult = Run-K6ScenarioRemote -AwsRegion $Region -RunnerInstanceId $runnerInstanceId -ScenarioName "retry_storm" -EnvExports @(
        "export BASE_URL='$BaseUrl' API_KEY='$ApiKey'",
        "export VUS=$RetryVus DURATION=$RetryDuration REQUEST_TIMEOUT=$RetryRequestTimeout MAX_CLIENT_ATTEMPTS=$RetryMaxAttempts"
    ) -TimeoutSeconds 7200
    Save-TextArtifact -Path (Join-Path $runRoot "30-retry-storm.txt") -Title "retry storm" -Result $retryResult
    $results += [pscustomobject]@{
        Name = "retry_storm"
        CommandId = $retryResult.CommandId
        Status = $retryResult.Status
        Summary = Get-JsonAfterMarker -Text $retryResult.Stdout -Marker "__SUMMARY__"
        StatusCounts = Get-JsonAfterMarker -Text $retryResult.Stdout -Marker "__STATUS_COUNTS__"
        TimeoutPoints = Get-JsonAfterMarker -Text $retryResult.Stdout -Marker "__TIMEOUT_POINTS__"
    }

    Write-Host "[7/8] Scenario starvation_mix" -ForegroundColor Yellow
    $starvationResult = Run-K6ScenarioRemote -AwsRegion $Region -RunnerInstanceId $runnerInstanceId -ScenarioName "starvation_mix" -EnvExports @(
        "export BASE_URL='$BaseUrl' API_KEY='$ApiKey'",
        "export DURATION=$StarvationDuration HEAVY_RPS=$StarvationHeavyRps LIGHT_RPS=$StarvationLightRps HEAVY_PREALLOCATED_VUS=60 HEAVY_MAX_VUS=220 LIGHT_PREALLOCATED_VUS=20 LIGHT_MAX_VUS=120 REQUEST_TIMEOUT=30s"
    ) -TimeoutSeconds 7200
    Save-TextArtifact -Path (Join-Path $runRoot "40-starvation-mix.txt") -Title "starvation mix" -Result $starvationResult
    $results += [pscustomobject]@{
        Name = "starvation_mix"
        CommandId = $starvationResult.CommandId
        Status = $starvationResult.Status
        Summary = Get-JsonAfterMarker -Text $starvationResult.Stdout -Marker "__SUMMARY__"
        StatusCounts = Get-JsonAfterMarker -Text $starvationResult.Stdout -Marker "__STATUS_COUNTS__"
        TimeoutPoints = Get-JsonAfterMarker -Text $starvationResult.Stdout -Marker "__TIMEOUT_POINTS__"
    }

    Write-Host "[8/8] Post-run health + cluster snapshots" -ForegroundColor Yellow
    $postHealth = Invoke-SsmScript -AwsRegion $Region -InstanceId $runnerInstanceId -TimeoutSeconds 300 -Commands @(
        "set -euo pipefail",
        "for i in 1 2 3 4 5; do curl -s -o /dev/null -w 'health_rtt_s=%{time_total}`n' '$BaseUrl/api/health'; done"
    )
    Save-TextArtifact -Path (Join-Path $runRoot "90-post-health.txt") -Title "post health" -Result $postHealth

    $postCluster = Invoke-SsmScript -AwsRegion $Region -InstanceId $serverInstanceId -TimeoutSeconds 300 -Commands @(
        "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
        "echo ===NODES===",
        "kubectl get nodes -o wide",
        "echo ===HPA===",
        "kubectl -n pixtools get hpa",
        "echo ===SCALEDOBJECT===",
        "kubectl -n pixtools get scaledobject",
        "echo ===PODS===",
        "kubectl -n pixtools get pods -o wide",
        "echo ===TOP_NODES===",
        "kubectl top nodes || true",
        "echo ===TOP_PODS===",
        "kubectl -n pixtools top pods || true",
        "echo ===EVENTS===",
        "kubectl -n pixtools get events --sort-by=.lastTimestamp | tail -n 40"
    )
    Save-TextArtifact -Path (Join-Path $runRoot "91-post-cluster.txt") -Title "post cluster" -Result $postCluster

    $summaryPath = Join-Path $runRoot "production-performance-summary.json"
    $reportPath = Join-Path $runRoot "production-performance-report.md"

    $outputSummary = [ordered]@{
        generated_utc = [datetime]::UtcNow.ToString("o")
        region = $Region
        environment = $Environment
        base_url = $BaseUrl
        server_instance = $serverInstanceId
        runner_instance = $runnerInstanceId
        profile = [ordered]@{
            baseline = [ordered]@{ vus = $BaselineVus; duration = $BaselineDuration; poll_completion = $true }
            spike = [ordered]@{ vus = $SpikeVus; duration = $SpikeDuration }
            retry_storm = [ordered]@{ vus = $RetryVus; duration = $RetryDuration; request_timeout = $RetryRequestTimeout; max_attempts = $RetryMaxAttempts }
            starvation_mix = [ordered]@{ duration = $StarvationDuration; heavy_rps = $StarvationHeavyRps; light_rps = $StarvationLightRps }
        }
        scenarios = $results
    }
    $outputSummary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath

    $reportLines = @(
        "# Production-Style Performance Suite",
        "",
        "## Metadata",
        "",
        "- Generated UTC: $([datetime]::UtcNow.ToString('o'))",
        "- Region: $Region",
        "- Environment: $Environment",
        "- Base URL: $BaseUrl",
        "- Server instance: $serverInstanceId",
        "- Runner instance: $runnerInstanceId",
        "",
        "## Scenario Results",
        ""
    )
    foreach ($r in $results) {
        $reportLines += "### $($r.Name)"
        $reportLines += ""
        $reportLines += "- CommandId: $($r.CommandId)"
        $reportLines += "- Status: $($r.Status)"
        if ($null -ne $r.Summary) {
            $reportLines += "- Submitted: $($r.Summary.submitted)"
            $reportLines += "- Completed: $($r.Summary.completed)"
            $reportLines += "- Failed jobs: $($r.Summary.failed_jobs)"
            $reportLines += "- Failed-after-retries: $($r.Summary.failed_after_retries)"
            $reportLines += "- Client retries: $($r.Summary.client_retries)"
            $reportLines += "- HTTP avg ms: $([Math]::Round([double]$r.Summary.http_avg_ms,2))"
            $reportLines += "- HTTP p95 ms: $([Math]::Round([double]$r.Summary.http_p95_ms,2))"
            $reportLines += "- HTTP failed rate: $([Math]::Round(([double]$r.Summary.http_failed_rate*100),2))%"
            if ($null -ne $r.Summary.light_http_p95_ms -and [double]$r.Summary.light_http_p95_ms -gt 0) {
                $reportLines += "- Light workload p95 ms: $([Math]::Round([double]$r.Summary.light_http_p95_ms,2))"
            }
        }
        if ($null -ne $r.StatusCounts) {
            $statusJson = ($r.StatusCounts | ConvertTo-Json -Compress)
            $reportLines += "- HTTP status counts: $statusJson"
        }
        if ($null -ne $r.TimeoutPoints) {
            $reportLines += "- Timeout points in raw stream: $($r.TimeoutPoints)"
        }
        $reportLines += ""
    }

    $reportLines += @(
        "## Artifacts",
        "",
        "- Summary JSON: $summaryPath",
        "- Pre health: $(Join-Path $runRoot '01-pre-health.txt')",
        "- Pre cluster: $(Join-Path $runRoot '02-pre-cluster.txt')",
        "- Baseline raw output: $(Join-Path $runRoot '10-baseline.txt')",
        "- Spike raw output: $(Join-Path $runRoot '20-spike.txt')",
        "- Retry storm raw output: $(Join-Path $runRoot '30-retry-storm.txt')",
        "- Starvation mix raw output: $(Join-Path $runRoot '40-starvation-mix.txt')",
        "- Post health: $(Join-Path $runRoot '90-post-health.txt')",
        "- Post cluster: $(Join-Path $runRoot '91-post-cluster.txt')"
    )
    $reportLines -join "`r`n" | Set-Content -Path $reportPath

    Write-Host "Report: $reportPath" -ForegroundColor Green
    Write-Host "Summary: $summaryPath" -ForegroundColor Green
}
finally {
    if ($runnerInstanceId) {
        aws ec2 terminate-instances --region $Region --instance-ids $runnerInstanceId --query "TerminatingInstances[0].CurrentState.Name" --output text | Out-Null
        try {
            aws ec2 wait instance-terminated --region $Region --instance-ids $runnerInstanceId
        }
        catch {
            Write-Warning "Failed waiting for runner termination ($runnerInstanceId): $($_.Exception.Message)"
        }
    }
}
