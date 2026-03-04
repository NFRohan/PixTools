[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    [string]$Environment = "dev",
    [string]$ProjectTag = "pixtools",
    [string]$ServerInstanceId = "",
    [string]$RunDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-SsmCapture {
    param(
        [Parameter(Mandatory = $true)][string]$AwsRegion,
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Commands,
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [int]$TimeoutSeconds = 1200
    )

    $payloadPath = Join-Path $env:TEMP ("pixtools-log-" + [guid]::NewGuid().ToString("N") + ".json")
    try {
        (@{ commands = $Commands } | ConvertTo-Json -Depth 10 -Compress) | Set-Content -Path $payloadPath -Encoding ascii
        $commandId = aws ssm send-command `
            --region $AwsRegion `
            --instance-ids $InstanceId `
            --document-name AWS-RunShellScript `
            --timeout-seconds $TimeoutSeconds `
            --parameters file://$payloadPath `
            --query "Command.CommandId" `
            --output text

        $elapsed = 0
        do {
            Start-Sleep -Seconds 5
            $elapsed += 5
            $status = aws ssm get-command-invocation `
                --region $AwsRegion `
                --command-id $commandId `
                --instance-id $InstanceId `
                --query "Status" `
                --output text 2>$null
        } while ($status -in @("Pending", "InProgress", "Delayed") -and $elapsed -lt $TimeoutSeconds)

        $stdoutLines = aws ssm get-command-invocation `
            --region $AwsRegion `
            --command-id $commandId `
            --instance-id $InstanceId `
            --query "StandardOutputContent" `
            --output text
        $stderrLines = aws ssm get-command-invocation `
            --region $AwsRegion `
            --command-id $commandId `
            --instance-id $InstanceId `
            --query "StandardErrorContent" `
            --output text

        $outPath = Join-Path $OutputDir ($Name + ".txt")
        @(
            "Name: $Name"
            "CommandId: $commandId"
            "Status: $status"
            "ElapsedSeconds: $elapsed"
            ""
            "--- STDOUT ---"
            (@($stdoutLines) -join "`n")
            ""
            "--- STDERR ---"
            (@($stderrLines) -join "`n")
        ) | Set-Content -Path $outPath -Encoding utf8

        Write-Host "captured $Name ($status)" -ForegroundColor Cyan
    }
    finally {
        Remove-Item -Path $payloadPath -Force -ErrorAction SilentlyContinue
    }
}

if ([string]::IsNullOrWhiteSpace($RunDir)) {
    $latest = Get-ChildItem -Path "bench/results" -Directory |
        Where-Object { $_.Name -like "prod-perf-suite-*" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latest) {
        throw "No prod-perf-suite run directory found under bench/results."
    }
    $RunDir = $latest.FullName
}

if ([string]::IsNullOrWhiteSpace($ServerInstanceId)) {
    $ServerInstanceId = aws ec2 describe-instances `
        --region $Region `
        --filters Name=tag:Project,Values=$ProjectTag Name=tag:Environment,Values=$Environment Name=tag:Role,Values=k3s-server Name=instance-state-name,Values=running `
        --query "Reservations[].Instances[] | sort_by(@,&LaunchTime) | [-1].InstanceId" `
        --output text
}

if ([string]::IsNullOrWhiteSpace($ServerInstanceId) -or $ServerInstanceId -eq "None") {
    throw "Could not resolve running k3s-server instance."
}

$logDir = Join-Path $RunDir "runtime-logs"
New-Item -Path $logDir -ItemType Directory -Force | Out-Null

Write-Host "Collecting runtime logs into: $logDir" -ForegroundColor Yellow
Write-Host "Server instance: $ServerInstanceId" -ForegroundColor Yellow

Invoke-SsmCapture -AwsRegion $Region -InstanceId $ServerInstanceId -Name "00-cluster-state" -OutputDir $logDir -Commands @(
    "set -euo pipefail",
    "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
    "echo '=== UTC ==='",
    "date -u",
    "echo '=== NODES ==='",
    "kubectl get nodes -o wide",
    "echo '=== PODS ==='",
    "kubectl -n pixtools get pods -o wide",
    "echo '=== HPA ==='",
    "kubectl -n pixtools get hpa",
    "echo '=== SCALEDOBJECT ==='",
    "kubectl -n pixtools get scaledobject",
    "echo '=== TOP NODES ==='",
    "kubectl top nodes || true",
    "echo '=== TOP PODS ==='",
    "kubectl -n pixtools top pods || true"
)

Invoke-SsmCapture -AwsRegion $Region -InstanceId $ServerInstanceId -Name "01-events-pixtools" -OutputDir $logDir -Commands @(
    "set -euo pipefail",
    "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
    "kubectl -n pixtools get events --sort-by=.lastTimestamp | tail -n 250"
)

Invoke-SsmCapture -AwsRegion $Region -InstanceId $ServerInstanceId -Name "02-api-logs" -OutputDir $logDir -Commands @(
    "set -euo pipefail",
    "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
    "for p in `$(kubectl -n pixtools get pods -o name | grep pixtools-api); do echo `"=== `$p ===`"; kubectl -n pixtools logs `$p --since=3h --tail=180 --all-containers=true || true; done"
)

Invoke-SsmCapture -AwsRegion $Region -InstanceId $ServerInstanceId -Name "03-worker-standard-logs" -OutputDir $logDir -Commands @(
    "set -euo pipefail",
    "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
    "for p in `$(kubectl -n pixtools get pods -o name | grep pixtools-worker-standard); do echo `"=== `$p ===`"; kubectl -n pixtools logs `$p --since=3h --tail=180 --all-containers=true || true; done"
)

Invoke-SsmCapture -AwsRegion $Region -InstanceId $ServerInstanceId -Name "04-worker-ml-logs" -OutputDir $logDir -Commands @(
    "set -euo pipefail",
    "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
    "for p in `$(kubectl -n pixtools get pods -o name | grep pixtools-worker-ml); do echo `"=== `$p ===`"; kubectl -n pixtools logs `$p --since=3h --tail=180 --all-containers=true || true; done"
)

Invoke-SsmCapture -AwsRegion $Region -InstanceId $ServerInstanceId -Name "05-rabbitmq-logs" -OutputDir $logDir -Commands @(
    "set -euo pipefail",
    "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
    "kubectl -n pixtools logs statefulset/rabbitmq --since=3h --tail=250 --all-containers=true || true"
)

Invoke-SsmCapture -AwsRegion $Region -InstanceId $ServerInstanceId -Name "06-cluster-autoscaler-logs" -OutputDir $logDir -Commands @(
    "set -euo pipefail",
    "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
    "kubectl -n pixtools logs deployment/cluster-autoscaler --since=3h --tail=250 --all-containers=true || true"
)

Invoke-SsmCapture -AwsRegion $Region -InstanceId $ServerInstanceId -Name "07-keda-operator-logs" -OutputDir $logDir -Commands @(
    "set -euo pipefail",
    "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
    "if kubectl get ns keda >/dev/null 2>&1; then for p in `$(kubectl -n keda get pods -o name | grep operator); do echo `"=== `$p ===`"; kubectl -n keda logs `$p --since=3h --tail=250 --all-containers=true || true; done; else echo 'keda namespace not found'; fi"
)

Invoke-SsmCapture -AwsRegion $Region -InstanceId $ServerInstanceId -Name "08-ingress-controller-logs" -OutputDir $logDir -Commands @(
    "set -euo pipefail",
    "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
    "if kubectl -n kube-system get deployment traefik >/dev/null 2>&1; then kubectl -n kube-system logs deployment/traefik --since=3h --tail=250 --all-containers=true || true; else echo 'traefik deployment not found'; fi"
)

Get-ChildItem -Path $logDir | Select-Object Name, Length, LastWriteTime | Sort-Object Name | Format-Table -AutoSize
