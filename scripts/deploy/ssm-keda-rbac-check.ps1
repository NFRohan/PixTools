[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    [string]$InstanceId = "",
    [switch]$ApplyFix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$kube = "kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml"

if ([string]::IsNullOrWhiteSpace($InstanceId)) {
    $InstanceId = aws ec2 describe-instances `
        --region $Region `
        --filters Name=tag:Project,Values=pixtools Name=tag:Environment,Values=dev Name=tag:Role,Values=k3s-server Name=instance-state-name,Values=running `
        --query "Reservations[].Instances[] | sort_by(@,&LaunchTime) | [-1].InstanceId" `
        --output text
}

if ([string]::IsNullOrWhiteSpace($InstanceId) -or $InstanceId -eq "None") {
    throw "Could not resolve running k3s server instance."
}

$commands = @(
    'set -euo pipefail'
)

if ($ApplyFix) {
    $commands += @(
        "$kube create clusterrole keda-metrics-auth-delegator --verb=create --resource=tokenreviews.authentication.k8s.io --resource=subjectaccessreviews.authorization.k8s.io --dry-run=client -o yaml | $kube apply -f -",
        "$kube create clusterrolebinding keda-metrics-auth-delegator --clusterrole=keda-metrics-auth-delegator --serviceaccount=keda:keda-metrics-server --dry-run=client -o yaml | $kube apply -f -",
        "$kube -n kube-system create role extension-apiserver-authentication-reader --verb=get,list,watch --resource=configmaps --dry-run=client -o yaml | $kube apply -f -",
        "$kube -n kube-system create rolebinding keda-metrics-auth-reader --role=extension-apiserver-authentication-reader --serviceaccount=keda:keda-metrics-server --dry-run=client -o yaml | $kube apply -f -"
    )
}

$commands += @(
    "echo can-i-sar",
    "$kube auth can-i create subjectaccessreviews.authorization.k8s.io --as=system:serviceaccount:keda:keda-metrics-server",
    "echo can-i-tokenreview",
    "$kube auth can-i create tokenreviews.authentication.k8s.io --as=system:serviceaccount:keda:keda-metrics-server",
    "echo can-i-get-cm",
    "$kube auth can-i get configmaps -n kube-system --as=system:serviceaccount:keda:keda-metrics-server",
    "echo can-i-list-cm",
    "$kube auth can-i list configmaps -n kube-system --as=system:serviceaccount:keda:keda-metrics-server",
    "echo can-i-watch-cm",
    "$kube auth can-i watch configmaps -n kube-system --as=system:serviceaccount:keda:keda-metrics-server",
    "$kube -n kube-system get rolebinding keda-metrics-auth-reader -o wide || true",
    "$kube get clusterrolebinding keda-metrics-auth-delegator -o wide || true",
    "$kube -n keda get deploy keda-operator-metrics-apiserver -o wide || true",
    "$kube -n keda logs deploy/keda-operator-metrics-apiserver --since=10m --tail=120 || true"
)

$payloadPath = Join-Path $env:TEMP ("keda-rbac-" + [guid]::NewGuid().ToString("N") + ".json")
try {
    (@{ commands = $commands } | ConvertTo-Json -Depth 8 -Compress) | Set-Content -Path $payloadPath -Encoding ascii
    $cmdId = aws ssm send-command `
        --region $Region `
        --instance-ids $InstanceId `
        --document-name AWS-RunShellScript `
        --parameters file://$payloadPath `
        --query "Command.CommandId" `
        --output text

    Start-Sleep -Seconds 8

    $status = aws ssm get-command-invocation `
        --region $Region `
        --command-id $cmdId `
        --instance-id $InstanceId `
        --query "Status" `
        --output text

    $stdout = aws ssm get-command-invocation `
        --region $Region `
        --command-id $cmdId `
        --instance-id $InstanceId `
        --query "StandardOutputContent" `
        --output text

    $stderr = aws ssm get-command-invocation `
        --region $Region `
        --command-id $cmdId `
        --instance-id $InstanceId `
        --query "StandardErrorContent" `
        --output text

    Write-Host "Instance: $InstanceId"
    Write-Host "CommandId: $cmdId"
    Write-Host "Status: $status"
    Write-Host ""
    Write-Host "--- STDOUT ---"
    Write-Host $stdout
    if ($stderr) {
        Write-Host ""
        Write-Host "--- STDERR ---"
        Write-Host $stderr
    }
}
finally {
    Remove-Item -Path $payloadPath -Force -ErrorAction SilentlyContinue
}
