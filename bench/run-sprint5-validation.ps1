[CmdletBinding()]
param(
    [string]$BaseUrl = "",
    [string]$ApiKey = $env:PIXTOOLS_API_KEY,
    [string]$Region = "us-east-1",
    [string]$Environment = "dev",
    [string]$ProjectTag = "pixtools",
    [string]$OutputDir = "bench/results",
    [string]$BaselineDuration = "3m",
    [int]$BaselineVus = 10,
    [string]$SpikeDuration = "2m",
    [int]$SpikeVus = 24,
    [int]$WatchIntervalSeconds = 20,
    [int]$PollMaxSeconds = 240,
    [int]$SettleSecondsAfterSpike = 240,
    [bool]$RunNodeScaleProbe = $true,
    [int]$NodeProbeCpuMillicores = 1500,
    [string]$NodeProbeMemory = "512Mi",
    [int]$NodeProbeTimeoutSeconds = 600,
    [switch]$ExportRawJson
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
        [int]$TimeoutSeconds = 300
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

function Invoke-SsmScript {
    param(
        [Parameter(Mandatory = $true)][string]$AwsRegion,
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string[]]$Commands,
        [int]$TimeoutSeconds = 300
    )

    $jsonPath = Join-Path $env:TEMP ("pixtools-sprint5-{0}.json" -f [guid]::NewGuid().ToString("N"))
    $payload = @{ commands = $Commands } | ConvertTo-Json -Depth 5 -Compress
    $payload | Out-File -FilePath $jsonPath -Encoding ascii

    try {
        $commandId = aws ssm send-command `
            --region $AwsRegion `
            --instance-ids $InstanceId `
            --document-name AWS-RunShellScript `
            --parameters file://$jsonPath `
            --query Command.CommandId `
            --output text
        $status = Wait-SsmInvocation -AwsRegion $AwsRegion -CommandId $commandId.Trim() -InstanceId $InstanceId -TimeoutSeconds $TimeoutSeconds
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

        return [pscustomobject]@{
            CommandId = $commandId.Trim()
            Status = $status
            Stdout = $stdout
            Stderr = $stderr
        }
    }
    finally {
        if (Test-Path $jsonPath) {
            Remove-Item $jsonPath -Force
        }
    }
}

function Get-BaseUrlFromIngress {
    param(
        [Parameter(Mandatory = $true)][string]$AwsRegion,
        [Parameter(Mandatory = $true)][string]$InstanceId
    )

    $result = Invoke-SsmScript -AwsRegion $AwsRegion -InstanceId $InstanceId -TimeoutSeconds 120 -Commands @(
        "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
        "kubectl -n pixtools get ingress pixtools -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
    )
    if ($result.Status -ne "Success") {
        throw "Failed to resolve ingress hostname from cluster: $($result.Stderr)"
    }
    $hostname = $result.Stdout.Trim()
    if ([string]::IsNullOrWhiteSpace($hostname)) {
        throw "Ingress hostname is empty."
    }
    return "http://$hostname"
}

function Get-ApiKeyFromSsm {
    param(
        [Parameter(Mandatory = $true)][string]$AwsRegion,
        [Parameter(Mandatory = $true)][string]$EnvName
    )

    $paramName = "/pixtools/$EnvName/api_key"
    $value = aws ssm get-parameter `
        --region $AwsRegion `
        --name $paramName `
        --with-decryption `
        --query "Parameter.Value" `
        --output text

    if ([string]::IsNullOrWhiteSpace($value) -or $value -eq "None") {
        throw "Could not read API key from SSM parameter $paramName"
    }
    return $value.Trim()
}

function Find-NewRunDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$RootDir,
        [string[]]$Before = @()
    )

    $after = @()
    if (Test-Path $RootDir) {
        $after = @(Get-ChildItem -Path $RootDir -Directory | Select-Object -ExpandProperty FullName)
    }
    $new = @($after | Where-Object { $_ -notin $Before })
    if ($new.Count -gt 0) {
        return (@($new | Sort-Object))[-1]
    }
    if ($after.Count -gt 0) {
        return (@(Get-ChildItem -Path $RootDir -Directory | Sort-Object LastWriteTime))[-1].FullName
    }
    throw "Could not find run directory under $RootDir"
}

function Get-K6MetricValue {
    param(
        [AllowNull()][object]$Summary,
        [Parameter(Mandatory = $true)][string]$MetricName,
        [Parameter(Mandatory = $true)][string]$Field
    )
    if ($null -eq $Summary -or $null -eq $Summary.metrics) { return $null }
    $metricProp = $Summary.metrics.PSObject.Properties[$MetricName]
    if ($null -eq $metricProp) { return $null }
    $metricValue = $metricProp.Value

    $directField = $metricValue.PSObject.Properties[$Field]
    if ($null -ne $directField) {
        return $directField.Value
    }

    $valuesProp = $metricValue.PSObject.Properties['values']
    if ($null -eq $valuesProp) { return $null }
    $nestedField = $valuesProp.Value.PSObject.Properties[$Field]
    if ($null -eq $nestedField) { return $null }
    return $nestedField.Value
}

function Get-SnapshotMetrics {
    param([Parameter(Mandatory = $true)][string]$Path)

    $workerReplicas = $null
    $apiReplicas = $null
    $nodeCount = 0
    $inNodesSection = $false
    $lines = Get-Content $Path

    foreach ($line in $lines) {
        if ($line -eq "=== NODES ===") {
            $inNodesSection = $true
            continue
        }
        if ($inNodesSection -and $line -like "===*") {
            $inNodesSection = $false
        }
        if ($inNodesSection -and $line -match '^ip-\d+-\d+-\d+-\d+\.ec2\.internal\s+') {
            $nodeCount += 1
        }

        if ($line -match '^keda-hpa-pixtools-worker-standard\s+') {
            $tokens = @($line -split '\s+')
            if ($tokens.Count -ge 2) {
                $candidate = $tokens[$tokens.Count - 2]
                $parsed = 0
                if ([int]::TryParse($candidate, [ref]$parsed)) {
                    $workerReplicas = $parsed
                }
            }
        }

        if ($line -match '^pixtools-api\s+Deployment/pixtools-api\s+') {
            $tokens = @($line -split '\s+')
            if ($tokens.Count -ge 2) {
                $candidate = $tokens[$tokens.Count - 2]
                $parsed = 0
                if ([int]::TryParse($candidate, [ref]$parsed)) {
                    $apiReplicas = $parsed
                }
            }
        }
    }

    return [pscustomobject]@{
        WorkerReplicas = $workerReplicas
        ApiReplicas = $apiReplicas
        NodeCount = $nodeCount
    }
}

function Get-RunStats {
    param([Parameter(Mandatory = $true)][string]$RunDir)

    $clusterDir = Join-Path $RunDir "cluster"
    $files = Get-ChildItem -Path $clusterDir -Filter "*.txt" | Sort-Object Name
    if ($files.Count -eq 0) {
        throw "No cluster snapshots found under $clusterDir"
    }

    $metricsByFile = @{}
    foreach ($f in $files) {
        $metricsByFile[$f.FullName] = Get-SnapshotMetrics -Path $f.FullName
    }

    $pre = $files | Where-Object { $_.Name -like "*-pre.txt" } | Select-Object -First 1
    $post = $files | Where-Object { $_.Name -like "*-post.txt" } | Select-Object -First 1
    if ($null -eq $pre) { $pre = $files[0] }
    if ($null -eq $post) { $post = $files[$files.Count - 1] }

    $maxWorker = 0
    $maxApi = 0
    $maxNodes = 0
    foreach ($entry in $metricsByFile.GetEnumerator()) {
        $m = $entry.Value
        if ($null -ne $m.WorkerReplicas -and $m.WorkerReplicas -gt $maxWorker) { $maxWorker = $m.WorkerReplicas }
        if ($null -ne $m.ApiReplicas -and $m.ApiReplicas -gt $maxApi) { $maxApi = $m.ApiReplicas }
        if ($m.NodeCount -gt $maxNodes) { $maxNodes = $m.NodeCount }
    }

    return [pscustomobject]@{
        Pre = $metricsByFile[$pre.FullName]
        Post = $metricsByFile[$post.FullName]
        MaxWorkerReplicas = $maxWorker
        MaxApiReplicas = $maxApi
        MaxNodes = $maxNodes
        SnapshotFiles = @($files | Select-Object -ExpandProperty FullName)
    }
}

function Invoke-NodeScaleProbe {
    param(
        [Parameter(Mandatory = $true)][string]$AwsRegion,
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][int]$CpuMillicores,
        [Parameter(Mandatory = $true)][string]$Memory,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $ticks = [Math]::Ceiling($TimeoutSeconds / 15.0)
    $yamlPatch = "{`"spec`":{`"template`":{`"spec`":{`"nodeSelector`":{`"pixtools-workload-app`":`"true`"},`"containers`":[{`"name`":`"pause`",`"resources`":{`"requests`":{`"cpu`":`"$($CpuMillicores)m`",`"memory`":`"$Memory`"},`"limits`":{`"cpu`":`"$($CpuMillicores)m`",`"memory`":`"$Memory`"}}}]}}}}"

    $probeLoop = @'
for i in $(seq 1 __TICKS__); do
  current=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  phase=$(kubectl -n pixtools get pod -l app=ca-scale-probe-s5 -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  echo TICK=$i NODES=$current POD_PHASE=$phase
  if [ "$current" -gt "$initial_nodes" ]; then
    echo SCALE_OUT_OBSERVED=true
    scaled=true
    break
  fi
  sleep 15
done
'@
    $probeLoop = $probeLoop.Replace('__TICKS__', [string]$ticks)

    $result = Invoke-SsmScript -AwsRegion $AwsRegion -InstanceId $InstanceId -TimeoutSeconds ($TimeoutSeconds + 180) -Commands @(
        'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml',
        "initial_nodes=`$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')",
        "echo INITIAL_NODES=`$initial_nodes",
        'kubectl -n pixtools create deployment ca-scale-probe-s5 --image=registry.k8s.io/pause:3.10 --dry-run=client -o yaml | kubectl apply -f -',
        "kubectl -n pixtools patch deployment ca-scale-probe-s5 --type merge -p '$yamlPatch'",
        'scaled=false',
        $probeLoop,
        "final_nodes=`$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')",
        "echo FINAL_NODES=`$final_nodes",
        "echo SCALE_OUT_OBSERVED=`$scaled",
        'kubectl -n pixtools delete deployment ca-scale-probe-s5 --ignore-not-found=true'
    )

    $initial = $null
    $final = $null
    $observed = $false
    $initialMatch = [regex]::Match($result.Stdout, 'INITIAL_NODES=(\d+)')
    if ($initialMatch.Success) { $initial = [int]$initialMatch.Groups[1].Value }
    $finalMatch = [regex]::Match($result.Stdout, 'FINAL_NODES=(\d+)')
    if ($finalMatch.Success) { $final = [int]$finalMatch.Groups[1].Value }
    $observedMatch = [regex]::Match($result.Stdout, 'SCALE_OUT_OBSERVED=true')
    if ($observedMatch.Success) { $observed = $true }

    return [pscustomobject]@{
        Status = $result.Status
        InitialNodes = $initial
        FinalNodes = $final
        ScaledOut = $observed
        Stdout = $result.Stdout
        Stderr = $result.Stderr
        CommandId = $result.CommandId
    }
}

Assert-Command -Name "k6"
Assert-Command -Name "aws"

$serverInstance = Get-K3sServerInstanceId -AwsRegion $Region -Project $ProjectTag -EnvName $Environment

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $BaseUrl = Get-BaseUrlFromIngress -AwsRegion $Region -InstanceId $serverInstance
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $ApiKey = Get-ApiKeyFromSsm -AwsRegion $Region -EnvName $Environment
}

$runRoot = Join-Path $OutputDir ("sprint5-validation-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -Path $runRoot -ItemType Directory -Force | Out-Null

$runner = Resolve-Path "bench/run-small-stress.ps1"

Write-Host "Sprint 5 validation run directory: $runRoot" -ForegroundColor Cyan
Write-Host "Base URL: $BaseUrl" -ForegroundColor Cyan
Write-Host "K3s server: $serverInstance" -ForegroundColor Cyan

$beforeDirs = @()
if (Test-Path $runRoot) {
    $beforeDirs = @(Get-ChildItem -Path $runRoot -Directory | Select-Object -ExpandProperty FullName)
}

Write-Host "Running baseline scenario..." -ForegroundColor Yellow
& $runner `
    -BaseUrl $BaseUrl `
    -ApiKey $ApiKey `
    -Scenario "baseline" `
    -Duration $BaselineDuration `
    -Vus $BaselineVus `
    -PollCompletion `
    -PollMaxSeconds $PollMaxSeconds `
    -WatchIntervalSeconds $WatchIntervalSeconds `
    -Region $Region `
    -Environment $Environment `
    -ProjectTag $ProjectTag `
    -OutputDir $runRoot `
    -ExportRawJson:$ExportRawJson.IsPresent

$baselineRunDir = Find-NewRunDirectory -RootDir $runRoot -Before $beforeDirs
$beforeDirs = @(Get-ChildItem -Path $runRoot -Directory | Select-Object -ExpandProperty FullName)

Write-Host "Running spike scenario..." -ForegroundColor Yellow
& $runner `
    -BaseUrl $BaseUrl `
    -ApiKey $ApiKey `
    -Scenario "spike" `
    -Duration $SpikeDuration `
    -Vus $SpikeVus `
    -WatchIntervalSeconds $WatchIntervalSeconds `
    -Region $Region `
    -Environment $Environment `
    -ProjectTag $ProjectTag `
    -OutputDir $runRoot `
    -ExportRawJson:$ExportRawJson.IsPresent

$spikeRunDir = Find-NewRunDirectory -RootDir $runRoot -Before $beforeDirs

Write-Host "Waiting $SettleSecondsAfterSpike seconds for scale-down settling..." -ForegroundColor Yellow
Start-Sleep -Seconds $SettleSecondsAfterSpike

$settleSnapshot = Invoke-SsmScript -AwsRegion $Region -InstanceId $serverInstance -TimeoutSeconds 180 -Commands @(
    "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
    "echo '=== HPA ==='",
    "kubectl -n pixtools get hpa",
    "echo '=== NODES ==='",
    "kubectl get nodes -o wide",
    "echo '=== SCALEDOBJECTS ==='",
    "kubectl -n pixtools get scaledobject"
)
$settlePath = Join-Path $runRoot "settle-snapshot.txt"
@(
    "SSM command: $($settleSnapshot.CommandId)"
    "Status: $($settleSnapshot.Status)"
    ""
    "--- STDOUT ---"
    $settleSnapshot.Stdout
    ""
    "--- STDERR ---"
    $settleSnapshot.Stderr
) | Set-Content -Path $settlePath -Encoding ascii

$nodeProbe = $null
if ($RunNodeScaleProbe) {
    Write-Host "Running node scale-out probe..." -ForegroundColor Yellow
    $nodeProbe = Invoke-NodeScaleProbe `
        -AwsRegion $Region `
        -InstanceId $serverInstance `
        -CpuMillicores $NodeProbeCpuMillicores `
        -Memory $NodeProbeMemory `
        -TimeoutSeconds $NodeProbeTimeoutSeconds

    $probePath = Join-Path $runRoot "node-scale-probe.txt"
    @(
        "SSM command: $($nodeProbe.CommandId)"
        "Status: $($nodeProbe.Status)"
        "InitialNodes: $($nodeProbe.InitialNodes)"
        "FinalNodes: $($nodeProbe.FinalNodes)"
        "ScaledOut: $($nodeProbe.ScaledOut)"
        ""
        "--- STDOUT ---"
        $nodeProbe.Stdout
        ""
        "--- STDERR ---"
        $nodeProbe.Stderr
    ) | Set-Content -Path $probePath -Encoding ascii
}

$baselineSummaryPath = Join-Path $baselineRunDir "baseline-summary.json"
$spikeSummaryPath = Join-Path $spikeRunDir "spike-summary.json"

$baselineSummary = Get-Content $baselineSummaryPath -Raw | ConvertFrom-Json
$spikeSummary = Get-Content $spikeSummaryPath -Raw | ConvertFrom-Json
$baselineStats = Get-RunStats -RunDir $baselineRunDir
$spikeStats = Get-RunStats -RunDir $spikeRunDir

$baselineFailed = [int](Get-K6MetricValue -Summary $baselineSummary -MetricName "jobs_failed_total" -Field "count")
$baselineCompleted = [int](Get-K6MetricValue -Summary $baselineSummary -MetricName "jobs_completed_total" -Field "count")
$baselineTimedOut = [int](Get-K6MetricValue -Summary $baselineSummary -MetricName "jobs_poll_timeout_total" -Field "count")
$baselineSubmitted = [int](Get-K6MetricValue -Summary $baselineSummary -MetricName "jobs_submitted_total" -Field "count")

$spikeFailed = [int](Get-K6MetricValue -Summary $spikeSummary -MetricName "jobs_failed_total" -Field "count")
$spikeSubmitted = [int](Get-K6MetricValue -Summary $spikeSummary -MetricName "jobs_submitted_total" -Field "count")

$criterionBaselineNoStuck = ($baselineFailed -eq 0 -and $baselineTimedOut -eq 0)
$criterionSpikeReplicaGrowth = ($spikeStats.MaxWorkerReplicas -ge 2)
$criterionNodeScaleObserved = $false
if ($RunNodeScaleProbe -and $null -ne $nodeProbe) {
    $criterionNodeScaleObserved = $nodeProbe.ScaledOut
} else {
    $criterionNodeScaleObserved = ($spikeStats.MaxNodes -gt $spikeStats.Pre.NodeCount)
}
$criterionReturnsToBaseline = ($spikeStats.Post.WorkerReplicas -le [Math]::Max(1, $spikeStats.Pre.WorkerReplicas + 1)) -and `
    ($spikeStats.Post.ApiReplicas -le [Math]::Max(1, $spikeStats.Pre.ApiReplicas + 1))

$overallPass = $criterionBaselineNoStuck -and $criterionSpikeReplicaGrowth -and $criterionNodeScaleObserved -and $criterionReturnsToBaseline

$decisionNote = "Keep ML scaling fixed for now. This sprint's baseline/spike runs are standard-queue dominant; run a denoise-heavy starvation mix before enabling ML autoscaling."

$summaryObject = [ordered]@{
    metadata = [ordered]@{
        generated_utc = [datetime]::UtcNow.ToString("o")
        base_url = $BaseUrl
        region = $Region
        environment = $Environment
        server_instance = $serverInstance
        baseline_run_dir = $baselineRunDir
        spike_run_dir = $spikeRunDir
        settle_snapshot = $settlePath
    }
    baseline = [ordered]@{
        submitted = $baselineSubmitted
        completed = $baselineCompleted
        failed = $baselineFailed
        timed_out = $baselineTimedOut
        max_worker_replicas = $baselineStats.MaxWorkerReplicas
        max_api_replicas = $baselineStats.MaxApiReplicas
        max_nodes = $baselineStats.MaxNodes
    }
    spike = [ordered]@{
        submitted = $spikeSubmitted
        failed = $spikeFailed
        max_worker_replicas = $spikeStats.MaxWorkerReplicas
        max_api_replicas = $spikeStats.MaxApiReplicas
        max_nodes = $spikeStats.MaxNodes
        pre_worker_replicas = $spikeStats.Pre.WorkerReplicas
        post_worker_replicas = $spikeStats.Post.WorkerReplicas
        pre_api_replicas = $spikeStats.Pre.ApiReplicas
        post_api_replicas = $spikeStats.Post.ApiReplicas
        pre_nodes = $spikeStats.Pre.NodeCount
        post_nodes = $spikeStats.Post.NodeCount
    }
    node_scale_probe = if ($null -ne $nodeProbe) {
        [ordered]@{
            status = $nodeProbe.Status
            scaled_out = $nodeProbe.ScaledOut
            initial_nodes = $nodeProbe.InitialNodes
            final_nodes = $nodeProbe.FinalNodes
        }
    } else { $null }
    acceptance = [ordered]@{
        baseline_without_stuck_jobs = $criterionBaselineNoStuck
        spike_replica_growth = $criterionSpikeReplicaGrowth
        node_scale_out_observed = $criterionNodeScaleObserved
        returned_close_to_baseline = $criterionReturnsToBaseline
        overall_pass = $overallPass
    }
    ml_scaling_decision = $decisionNote
}

$summaryJsonPath = Join-Path $runRoot "sprint5-readiness-summary.json"
$summaryObject | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryJsonPath

$reportPath = Join-Path $runRoot "sprint5-readiness-report.md"
$reportLines = @(
    "# Sprint 5 Benchmark Readiness Report"
    ""
    "## Run Metadata"
    ""
    "- Date (UTC): $([datetime]::UtcNow.ToString('o'))"
    "- Base URL: $BaseUrl"
    "- Region: $Region"
    "- Environment: $Environment"
    "- Server instance: $serverInstance"
    "- Baseline run dir: $baselineRunDir"
    "- Spike run dir: $spikeRunDir"
    ""
    "## Baseline"
    ""
    "- Submitted jobs: $baselineSubmitted"
    "- Completed jobs: $baselineCompleted"
    "- Failed jobs: $baselineFailed"
    "- Poll timeouts: $baselineTimedOut"
    "- Max worker replicas observed: $($baselineStats.MaxWorkerReplicas)"
    "- Max API replicas observed: $($baselineStats.MaxApiReplicas)"
    "- Max node count observed: $($baselineStats.MaxNodes)"
    ""
    "## Spike"
    ""
    "- Submitted jobs: $spikeSubmitted"
    "- Failed jobs: $spikeFailed"
    "- Max worker replicas observed: $($spikeStats.MaxWorkerReplicas)"
    "- Max API replicas observed: $($spikeStats.MaxApiReplicas)"
    "- Max node count observed: $($spikeStats.MaxNodes)"
    "- Pre -> post worker replicas: $($spikeStats.Pre.WorkerReplicas) -> $($spikeStats.Post.WorkerReplicas)"
    "- Pre -> post API replicas: $($spikeStats.Pre.ApiReplicas) -> $($spikeStats.Post.ApiReplicas)"
    "- Pre -> post node count: $($spikeStats.Pre.NodeCount) -> $($spikeStats.Post.NodeCount)"
    ""
    "## Node Scale-Out Probe"
    ""
)

if ($null -ne $nodeProbe) {
    $reportLines += @(
        "- Status: $($nodeProbe.Status)"
        "- Scaled out observed: $($nodeProbe.ScaledOut)"
        "- Initial -> final nodes: $($nodeProbe.InitialNodes) -> $($nodeProbe.FinalNodes)"
    )
} else {
    $reportLines += "- Not executed"
}

$reportLines += @(
    ""
    "## Acceptance Criteria"
    ""
    "- Baseline run completes without stuck jobs: $criterionBaselineNoStuck"
    "- Spike run demonstrates replica growth: $criterionSpikeReplicaGrowth"
    "- Node scale-out observed automatically when needed: $criterionNodeScaleObserved"
    "- System returns close to baseline after load subsides: $criterionReturnsToBaseline"
    ""
    "- Overall PASS: $overallPass"
    ""
    "## ML Scaling Decision"
    ""
    "$decisionNote"
    ""
    "## Artifacts"
    ""
    "- Summary JSON: $summaryJsonPath"
    "- Settling snapshot: $settlePath"
)

if ($null -ne $nodeProbe) {
    $reportLines += "- Node probe log: $(Join-Path $runRoot 'node-scale-probe.txt')"
}

$reportLines -join "`r`n" | Set-Content -Path $reportPath

Write-Host "Sprint 5 report written to $reportPath" -ForegroundColor Green
Write-Host "Overall PASS: $overallPass" -ForegroundColor Cyan
