[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$Project = "pixtools",
    [string]$Region = "us-east-1",
    [string]$InfraDir = "infra",
    [string]$VarFile = "",
    [string]$BackendConfig = "",
    [switch]$AutoApprove,
    [switch]$SkipK3sDatastoreReset,
    [switch]$DestroyBackend
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:WarningCount = 0
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-WarnMsg {
    param([string]$Message)
    $script:WarningCount++
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Refresh-AwsSessionCredentials {
    $credOutput = & aws configure export-credentials --format process 2>&1
    if ($LASTEXITCODE -ne 0 -or $null -eq $credOutput) {
        return $false
    }

    $credText = ($credOutput | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($credText)) {
        return $false
    }

    try {
        $creds = $credText | ConvertFrom-Json
    }
    catch {
        return $false
    }

    $accessKeyProp = $creds.PSObject.Properties["AccessKeyId"]
    $secretKeyProp = $creds.PSObject.Properties["SecretAccessKey"]
    $sessionTokenProp = $creds.PSObject.Properties["SessionToken"]

    if ($null -eq $accessKeyProp -or [string]::IsNullOrWhiteSpace([string]$accessKeyProp.Value)) {
        return $false
    }
    if ($null -eq $secretKeyProp -or [string]::IsNullOrWhiteSpace([string]$secretKeyProp.Value)) {
        return $false
    }

    $env:AWS_ACCESS_KEY_ID = [string]$accessKeyProp.Value
    $env:AWS_SECRET_ACCESS_KEY = [string]$secretKeyProp.Value
    if ($null -ne $sessionTokenProp -and -not [string]::IsNullOrWhiteSpace([string]$sessionTokenProp.Value)) {
        $env:AWS_SESSION_TOKEN = [string]$sessionTokenProp.Value
    }
    else {
        Remove-Item Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
    }
    $env:AWS_DEFAULT_REGION = $Region
    return $true
}

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function Invoke-AwsText {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args,
        [switch]$AllowFailure
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = & aws @Args 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $prevEap
        }
        if ($exitCode -eq 0) {
            if ($null -eq $output) {
                return ""
            }
            return ($output | Out-String).Trim()
        }

        $errorText = ""
        if ($null -ne $output) {
            $errorText = ($output | Out-String).Trim()
        }
        $tokenExpired = $errorText -match "ExpiredToken|RequestExpired|InvalidClientTokenId|UnrecognizedClientException"
        if ($tokenExpired -and $attempt -lt 3) {
            if (Refresh-AwsSessionCredentials) {
                Write-WarnMsg "AWS session expired; refreshed credentials and retrying command."
                Start-Sleep -Seconds 1
                continue
            }
        }

        if ($AllowFailure) {
            return $null
        }
        throw "aws $($Args -join ' ') failed: $errorText"
    }

    if ($AllowFailure) {
        return $null
    }
    throw "aws $($Args -join ' ') failed after retries."
}

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args,
        [switch]$AllowFailure
    )
    $text = Invoke-AwsText -Args $Args -AllowFailure:$AllowFailure
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    try {
        return $text | ConvertFrom-Json
    }
    catch {
        if ($AllowFailure) {
            return $null
        }
        throw "Failed to parse aws JSON output for args: $($Args -join ' ')`nRaw: $text"
    }
}

function Invoke-TerraformText {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args,
        [switch]$AllowFailure
    )
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & terraform @Args 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    if ($exitCode -ne 0) {
        if ($AllowFailure) {
            return $null
        }
        throw "terraform $($Args -join ' ') failed: $output"
    }
    if ($null -eq $output) {
        return ""
    }
    return ($output | Out-String).Trim()
}

function Convert-AwsTextToList {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text -eq "None") {
        return , @()
    }
    return , @(
        $Text -split '\s+' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne "None" }
    )
}

function Get-ObjectArrayProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )
    if ($null -eq $Object) {
        return , @()
    }
    $prop = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $prop -or $null -eq $prop.Value) {
        return , @()
    }
    return , @($prop.Value)
}

function Resolve-RepoPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return (Resolve-Path $Path).Path
    }
    return (Resolve-Path (Join-Path $script:RepoRoot $Path)).Path
}

function Remove-AnsiEscapeCodes {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }
    return [regex]::Replace($Text, '\x1B\[[0-9;]*[A-Za-z]', '')
}

function Get-TerraformOutputRaw {
    param([string]$Name)
    $value = Invoke-TerraformText -Args @("-chdir=$script:InfraPath", "output", "-raw", $Name) -AllowFailure
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    $clean = Remove-AnsiEscapeCodes -Text $value
    if ($clean -match "No outputs found") {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($clean) -or $clean.Trim() -eq "null") {
        return $null
    }
    return $clean.Trim()
}

function Find-K3sInstanceId {
    $text = Invoke-AwsText -AllowFailure -Args @(
        "ec2", "describe-instances",
        "--region", $Region,
        "--filters",
        "Name=tag:Project,Values=$Project",
        "Name=tag:Environment,Values=$Environment",
        "Name=tag:Role,Values=k3s-server",
        "Name=instance-state-name,Values=pending,running,stopping,stopped",
        "--query", "Reservations[].Instances[].InstanceId",
        "--output", "text"
    )
    $ids = Convert-AwsTextToList $text
    if ($ids.Count -gt 0) {
        return $ids[0]
    }
    return $null
}

function Invoke-SsmCommands {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string[]]$Commands
    )

    $payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("pixtools-ssm-" + [guid]::NewGuid().ToString() + ".json")
    try {
        @{ commands = $Commands } | ConvertTo-Json -Compress | Set-Content -Path $payloadPath -Encoding Ascii
        $commandId = Invoke-AwsText -Args @(
            "ssm", "send-command",
            "--region", $Region,
            "--instance-ids", $InstanceId,
            "--document-name", "AWS-RunShellScript",
            "--comment", "PixTools teardown",
            "--parameters", "file://$payloadPath",
            "--query", "Command.CommandId",
            "--output", "text"
        )

        if ([string]::IsNullOrWhiteSpace($commandId) -or $commandId -eq "None") {
            throw "Failed to create SSM command ID."
        }

        Write-Info "SSM command sent: $commandId"

        for ($i = 0; $i -lt 120; $i++) {
            $status = Invoke-AwsText -AllowFailure -Args @(
                "ssm", "get-command-invocation",
                "--region", $Region,
                "--command-id", $commandId,
                "--instance-id", $InstanceId,
                "--query", "Status",
                "--output", "text"
            )

            switch ($status) {
                "Success" {
                    $stdout = Invoke-AwsText -AllowFailure -Args @(
                        "ssm", "get-command-invocation",
                        "--region", $Region,
                        "--command-id", $commandId,
                        "--instance-id", $InstanceId,
                        "--query", "StandardOutputContent",
                        "--output", "text"
                    )
                    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
                        Write-Info "SSM output:`n$stdout"
                    }
                    return
                }
                "Failed" {
                    $stderr = Invoke-AwsText -AllowFailure -Args @(
                        "ssm", "get-command-invocation",
                        "--region", $Region,
                        "--command-id", $commandId,
                        "--instance-id", $InstanceId,
                        "--query", "StandardErrorContent",
                        "--output", "text"
                    )
                    throw "SSM command failed: $stderr"
                }
                "Cancelled" { throw "SSM command cancelled." }
                "TimedOut" { throw "SSM command timed out." }
                default { Start-Sleep -Seconds 5 }
            }
        }

        throw "Timed out waiting for SSM command completion."
    }
    finally {
        Remove-Item -Path $payloadPath -Force -ErrorAction SilentlyContinue
    }
}

function Reset-K3sDatastore {
    param(
        [string]$InstanceId,
        [string]$SsmPrefix,
        [string]$K3sDbName
    )
    if ([string]::IsNullOrWhiteSpace($InstanceId)) {
        Write-WarnMsg "No K3s EC2 instance found; skipping K3s datastore reset."
        return
    }
    if ([string]::IsNullOrWhiteSpace($SsmPrefix)) {
        Write-WarnMsg "SSM prefix unavailable; skipping K3s datastore reset."
        return
    }
    if ([string]::IsNullOrWhiteSpace($K3sDbName)) {
        $K3sDbName = "k3s_state"
    }

    Write-Info "Resetting K3s datastore database '$K3sDbName' via SSM on $InstanceId"

    $commands = @(
        "set -euo pipefail",
        "REGION='$Region'",
        "SSM_PREFIX='$SsmPrefix'",
        "K3S_DB_NAME='$K3sDbName'",
        'DB_URL=$(aws ssm get-parameter --region "$REGION" --name "$SSM_PREFIX/database_url" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)',
        'if [ -z "$DB_URL" ] || [ "$DB_URL" = "None" ]; then echo "database_url parameter not found; skipping datastore reset"; exit 0; fi',
        'if ! command -v psql >/dev/null 2>&1; then',
        '  if command -v yum >/dev/null 2>&1; then sudo yum -y install postgresql15 >/dev/null 2>&1 || true; fi',
        'fi',
        "python3 - <<'PY'",
        'import os',
        'import subprocess',
        'import urllib.parse',
        '',
        'url = os.environ.get("DB_URL", "")',
        'k3s_db_name = os.environ.get("K3S_DB_NAME", "k3s_state")',
        'if not url:',
        '    raise SystemExit("Empty DB_URL")',
        '',
        'if "+" in url.split("://", 1)[0]:',
        '    url = url.replace("postgresql+asyncpg://", "postgresql://", 1)',
        '',
        'parsed = urllib.parse.urlparse(url)',
        'username = urllib.parse.unquote(parsed.username or "")',
        'password = urllib.parse.unquote(parsed.password or "")',
        'hostname = parsed.hostname or ""',
        'port = str(parsed.port or 5432)',
        '',
        'if not username or not password or not hostname:',
        '    raise SystemExit("Unable to parse DB_URL components")',
        '',
        'safe_db = k3s_db_name.replace("_", "")',
        'if not safe_db.isalnum():',
        '    raise SystemExit("Unsafe k3s datastore DB name")',
        '',
        'env = os.environ.copy()',
        'env["PGPASSWORD"] = password',
        'drop_sql = f''DROP DATABASE IF EXISTS "{k3s_db_name}" WITH (FORCE);''',
        'create_sql = f''CREATE DATABASE "{k3s_db_name}";''',
        '',
        'base_cmd = ["psql", "-h", hostname, "-p", port, "-U", username, "-d", "postgres", "-v", "ON_ERROR_STOP=1"]',
        'subprocess.run(base_cmd + ["-c", drop_sql], check=True, env=env)',
        'subprocess.run(base_cmd + ["-c", create_sql], check=True, env=env)',
        'print(f"Reset k3s datastore database: {k3s_db_name}")',
        'PY'
    )

    try {
        Invoke-SsmCommands -InstanceId $InstanceId -Commands $commands
    }
    catch {
        Write-WarnMsg "K3s datastore reset failed: $($_.Exception.Message)"
    }
}

function Cleanup-KubernetesWorkloads {
    param([string]$InstanceId)
    if ([string]::IsNullOrWhiteSpace($InstanceId)) {
        Write-WarnMsg "No K3s EC2 instance found; skipping in-cluster cleanup."
        return
    }

    Write-Info "Cleaning Kubernetes workloads on instance $InstanceId"
    $commands = @(
        "set -euo pipefail",
        "if command -v kubectl >/dev/null 2>&1; then",
        "  kubectl -n pixtools delete ingress pixtools --ignore-not-found=true || true",
        "  kubectl delete namespace pixtools --ignore-not-found=true --wait=false || true",
        "  if kubectl get namespace pixtools >/dev/null 2>&1; then",
        "    for i in `$(seq 1 36); do",
        "      if ! kubectl get namespace pixtools >/dev/null 2>&1; then",
        "        break",
        "      fi",
        "      sleep 5",
        "    done",
        "    kubectl patch namespace pixtools --type=merge -p '{""metadata"":{""finalizers"":[]}}' >/dev/null 2>&1 || true",
        "  fi",
        "fi",
        "if command -v helm >/dev/null 2>&1; then",
        "  helm uninstall aws-load-balancer-controller -n kube-system >/dev/null 2>&1 || true",
        "fi"
    )

    try {
        Invoke-SsmCommands -InstanceId $InstanceId -Commands $commands
    }
    catch {
        Write-WarnMsg "Kubernetes cleanup over SSM failed: $($_.Exception.Message)"
    }
}

function Set-AsgToZero {
    param([string]$AsgName)
    if ([string]::IsNullOrWhiteSpace($AsgName)) {
        Write-WarnMsg "ASG name not available; skipping ASG scale-down."
        return
    }

    Write-Info "Scaling ASG $AsgName to zero"
    Invoke-AwsText -AllowFailure -Args @(
        "autoscaling", "update-auto-scaling-group",
        "--region", $Region,
        "--auto-scaling-group-name", $AsgName,
        "--min-size", "0",
        "--max-size", "0",
        "--desired-capacity", "0"
    ) | Out-Null

    $instancesText = Invoke-AwsText -AllowFailure -Args @(
        "autoscaling", "describe-auto-scaling-groups",
        "--region", $Region,
        "--auto-scaling-group-names", $AsgName,
        "--query", "AutoScalingGroups[0].Instances[].InstanceId",
        "--output", "text"
    )
    $instanceIds = Convert-AwsTextToList $instancesText
    if ($instanceIds.Count -eq 0) {
        return
    }

    Write-Info "Terminating EC2 instances in ASG: $($instanceIds -join ', ')"
    $terminateArgs = @(
        "ec2", "terminate-instances",
        "--region", $Region,
        "--instance-ids"
    )
    $terminateArgs += $instanceIds
    Invoke-AwsText -AllowFailure -Args $terminateArgs | Out-Null
}

function Wait-ForAsgZero {
    param(
        [string]$AsgName,
        [int]$TimeoutSeconds = 600
    )
    if ([string]::IsNullOrWhiteSpace($AsgName)) {
        return
    }

    Write-Info "Waiting for ASG '$AsgName' to reach zero in-service instances"
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $asgJson = Invoke-AwsJson -AllowFailure -Args @(
            "autoscaling", "describe-auto-scaling-groups",
            "--region", $Region,
            "--auto-scaling-group-names", $AsgName,
            "--output", "json"
        )

        if ($null -eq $asgJson) {
            return
        }

        $groups = Get-ObjectArrayProperty -Object $asgJson -PropertyName "AutoScalingGroups"
        if ($groups.Count -eq 0) {
            return
        }

        $group = $groups[0]
        $instances = Get-ObjectArrayProperty -Object $group -PropertyName "Instances"
        if ($instances.Count -eq 0) {
            Write-Info "ASG is drained."
            return
        }

        Start-Sleep -Seconds 10
        $elapsed += 10
    }

    Write-WarnMsg "Timed out waiting for ASG '$AsgName' to drain."
}

function Wait-NoK3sInstances {
    param(
        [int]$TimeoutSeconds = 600
    )

    $instanceName = "$Project-$Environment-k3s"
    Write-Info "Waiting for all EC2 instances tagged Name=$instanceName to terminate"

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $idsText = Invoke-AwsText -AllowFailure -Args @(
            "ec2", "describe-instances",
            "--region", $Region,
            "--filters",
            "Name=tag:Name,Values=$instanceName",
            "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down",
            "--query", "Reservations[].Instances[].InstanceId",
            "--output", "text"
        )
        $ids = Convert-AwsTextToList $idsText
        if ($ids.Count -eq 0) {
            Write-Info "No live K3s-tagged instances remain."
            return
        }

        Start-Sleep -Seconds 10
        $elapsed += 10
    }

    Write-WarnMsg "Timed out waiting for K3s EC2 instance termination."
}

function Get-TaggedResourceArns {
    param(
        [string]$ResourceType,
        [string]$TagKey,
        [string]$TagValue
    )

    $json = Invoke-AwsJson -AllowFailure -Args @(
        "resourcegroupstaggingapi", "get-resources",
        "--region", $Region,
        "--resource-type-filters", $ResourceType,
        "--tag-filters", "Key=$TagKey,Values=$TagValue",
        "--output", "json"
    )

    if ($null -eq $json) {
        return , @()
    }

    $arns = @()
    foreach ($entry in (Get-ObjectArrayProperty -Object $json -PropertyName "ResourceTagMappingList")) {
        if ($null -ne $entry.ResourceARN -and -not [string]::IsNullOrWhiteSpace([string]$entry.ResourceARN)) {
            $arns += [string]$entry.ResourceARN
        }
    }
    return , @($arns | Select-Object -Unique)
}

function Remove-LbcArtifacts {
    param([string]$ClusterTagValue)
    if ([string]::IsNullOrWhiteSpace($ClusterTagValue)) {
        return
    }

    Write-Info "Cleaning AWS LBC artifacts for cluster tag $ClusterTagValue"

    $lbArns = @()
    $lbArns += Get-TaggedResourceArns -ResourceType "elasticloadbalancing:loadbalancer" -TagKey "elbv2.k8s.aws/cluster" -TagValue $ClusterTagValue
    $lbArns += Get-TaggedResourceArns -ResourceType "elasticloadbalancing:loadbalancer" -TagKey "ingress.k8s.aws/stack" -TagValue "pixtools/pixtools"
    $lbArns = , @($lbArns | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    foreach ($lbArn in $lbArns) {
        $lbArnValue = [string]$lbArn
        if ([string]::IsNullOrWhiteSpace($lbArnValue) -or $lbArnValue -eq "None") {
            continue
        }
        Write-Info "Deleting ALB $lbArnValue"
        Invoke-AwsText -AllowFailure -Args @(
            "elbv2", "delete-load-balancer",
            "--region", $Region,
            "--load-balancer-arn", $lbArnValue
        ) | Out-Null
    }

    Start-Sleep -Seconds 10

    $tgArns = Get-TaggedResourceArns -ResourceType "elasticloadbalancing:targetgroup" -TagKey "elbv2.k8s.aws/cluster" -TagValue $ClusterTagValue
    foreach ($tgArn in $tgArns) {
        $tgArnValue = [string]$tgArn
        if ([string]::IsNullOrWhiteSpace($tgArnValue) -or $tgArnValue -eq "None") {
            continue
        }
        Write-Info "Deleting target group $tgArnValue"
        Invoke-AwsText -AllowFailure -Args @(
            "elbv2", "delete-target-group",
            "--region", $Region,
            "--target-group-arn", $tgArnValue
        ) | Out-Null
    }

    $sgText = Invoke-AwsText -AllowFailure -Args @(
        "ec2", "describe-security-groups",
        "--region", $Region,
        "--filters", "Name=tag:elbv2.k8s.aws/cluster,Values=$ClusterTagValue",
        "--query", "SecurityGroups[].GroupId",
        "--output", "text"
    )
    $sgIds = Convert-AwsTextToList $sgText
    foreach ($sg in $sgIds) {
        Write-Info "Deleting LBC-managed security group $sg"
        Invoke-AwsText -AllowFailure -Args @(
            "ec2", "delete-security-group",
            "--region", $Region,
            "--group-id", $sg
        ) | Out-Null
    }
}

function Remove-OrphanEnisInVpc {
    param([string]$VpcId)
    if ([string]::IsNullOrWhiteSpace($VpcId)) {
        return
    }

    $eniText = Invoke-AwsText -AllowFailure -Args @(
        "ec2", "describe-network-interfaces",
        "--region", $Region,
        "--filters",
        "Name=vpc-id,Values=$VpcId",
        "Name=status,Values=available",
        "--query", "NetworkInterfaces[].NetworkInterfaceId",
        "--output", "text"
    )
    $eniIds = Convert-AwsTextToList $eniText
    foreach ($eniId in $eniIds) {
        Write-Info "Deleting orphan ENI $eniId"
        Invoke-AwsText -AllowFailure -Args @(
            "ec2", "delete-network-interface",
            "--region", $Region,
            "--network-interface-id", $eniId
        ) | Out-Null
    }
}

function Clear-S3BucketCompletely {
    param([string]$BucketName)
    if ([string]::IsNullOrWhiteSpace($BucketName)) {
        return
    }

    $exists = Invoke-AwsText -AllowFailure -Args @(
        "s3api", "head-bucket",
        "--region", $Region,
        "--bucket", $BucketName
    )
    if ($null -eq $exists) {
        Write-Info "Bucket not found (already removed): $BucketName"
        return
    }

    Write-Info "Purging S3 bucket s3://$BucketName"
    Invoke-AwsText -AllowFailure -Args @(
        "s3", "rm",
        "s3://$BucketName",
        "--recursive",
        "--region", $Region
    ) | Out-Null

    $batchCounter = 0
    while ($true) {
        $listJson = Invoke-AwsJson -Args @(
            "s3api", "list-object-versions",
            "--region", $Region,
            "--bucket", $BucketName,
            "--max-items", "1000",
            "--output", "json"
        )

        if ($null -eq $listJson) {
            break
        }

        $objects = New-Object System.Collections.Generic.List[object]

        foreach ($v in (Get-ObjectArrayProperty -Object $listJson -PropertyName "Versions")) {
            if ($null -ne $v) {
                $objects.Add(@{ Key = $v.Key; VersionId = $v.VersionId })
            }
        }
        foreach ($m in (Get-ObjectArrayProperty -Object $listJson -PropertyName "DeleteMarkers")) {
            if ($null -ne $m) {
                $objects.Add(@{ Key = $m.Key; VersionId = $m.VersionId })
            }
        }

        if ($objects.Count -eq 0) {
            break
        }

        $batchCounter++
        Write-Info "Deleting $($objects.Count) versioned objects from $BucketName (batch $batchCounter)"
        for ($i = 0; $i -lt $objects.Count; $i += 1000) {
            $chunkEnd = [Math]::Min($i + 999, $objects.Count - 1)
            $chunk = @()
            for ($j = $i; $j -le $chunkEnd; $j++) {
                $chunk += $objects[$j]
            }

            $deletePayloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("pixtools-s3-delete-" + [guid]::NewGuid().ToString() + ".json")
            try {
                @{ Objects = $chunk; Quiet = $true } | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $deletePayloadPath -Encoding Ascii
                Invoke-AwsText -Args @(
                    "s3api", "delete-objects",
                    "--region", $Region,
                    "--bucket", $BucketName,
                    "--delete", "file://$deletePayloadPath"
                ) | Out-Null
            }
            finally {
                Remove-Item -Path $deletePayloadPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Clear-EcrRepositoryImages {
    param([string]$RepositoryName)
    if ([string]::IsNullOrWhiteSpace($RepositoryName)) {
        return
    }

    $repoExists = Invoke-AwsText -AllowFailure -Args @(
        "ecr", "describe-repositories",
        "--region", $Region,
        "--repository-names", $RepositoryName,
        "--query", "repositories[0].repositoryName",
        "--output", "text"
    )
    if ([string]::IsNullOrWhiteSpace($repoExists) -or $repoExists -eq "None") {
        Write-Info "ECR repository not found (already removed): $RepositoryName"
        return
    }

    Write-Info "Purging ECR images in repository $RepositoryName"

    while ($true) {
        $images = Invoke-AwsJson -AllowFailure -Args @(
            "ecr", "list-images",
            "--region", $Region,
            "--repository-name", $RepositoryName,
            "--max-results", "1000",
            "--output", "json"
        )

        if ($null -eq $images) {
            break
        }
        $imageIds = Get-ObjectArrayProperty -Object $images -PropertyName "imageIds"
        if ($imageIds.Count -eq 0) {
            break
        }

        foreach ($img in $imageIds) {
            $tagProp = $img.PSObject.Properties["imageTag"]
            $digestProp = $img.PSObject.Properties["imageDigest"]
            $imageTag = if ($null -ne $tagProp) { [string]$tagProp.Value } else { "" }
            $imageDigest = if ($null -ne $digestProp) { [string]$digestProp.Value } else { "" }

            if (-not [string]::IsNullOrWhiteSpace($imageTag)) {
                Invoke-AwsText -AllowFailure -Args @(
                    "ecr", "batch-delete-image",
                    "--region", $Region,
                    "--repository-name", $RepositoryName,
                    "--image-ids", "imageTag=$imageTag"
                ) | Out-Null
            }
            elseif (-not [string]::IsNullOrWhiteSpace($imageDigest)) {
                Invoke-AwsText -AllowFailure -Args @(
                    "ecr", "batch-delete-image",
                    "--region", $Region,
                    "--repository-name", $RepositoryName,
                    "--image-ids", "imageDigest=$imageDigest"
                ) | Out-Null
            }
        }
    }
}

function Remove-SsmPath {
    param([string]$PathPrefix)
    if ([string]::IsNullOrWhiteSpace($PathPrefix)) {
        return
    }

    Write-Info "Deleting SSM parameters under $PathPrefix"
    $nextToken = $null
    while ($true) {
        $args = @(
            "ssm", "get-parameters-by-path",
            "--region", $Region,
            "--path", $PathPrefix,
            "--recursive",
            "--max-results", "10",
            "--output", "json"
        )
        if ($null -ne $nextToken) {
            $args += @("--next-token", $nextToken)
        }

        $resp = Invoke-AwsJson -AllowFailure -Args $args
        if ($null -eq $resp) {
            break
        }

        $names = New-Object System.Collections.Generic.List[string]
        foreach ($p in (Get-ObjectArrayProperty -Object $resp -PropertyName "Parameters")) {
            if ($null -ne $p.Name) {
                $names.Add([string]$p.Name)
            }
        }

        if ($names.Count -gt 0) {
            for ($i = 0; $i -lt $names.Count; $i += 10) {
                $end = [Math]::Min($i + 9, $names.Count - 1)
                $chunk = @()
                for ($j = $i; $j -le $end; $j++) {
                    $chunk += $names[$j]
                }
                $deleteArgs = @(
                    "ssm", "delete-parameters",
                    "--region", $Region,
                    "--names"
                )
                $deleteArgs += $chunk
                Invoke-AwsText -AllowFailure -Args $deleteArgs | Out-Null
            }
        }

        $nextTokenProp = $resp.PSObject.Properties["NextToken"]
        if ($null -eq $nextTokenProp -or [string]::IsNullOrWhiteSpace([string]$nextTokenProp.Value)) {
            break
        }
        $nextToken = [string]$nextTokenProp.Value
    }
}



function Get-BackendConfigValue {
    param(
        [string]$Path,
        [string]$Key
    )
    if (-not (Test-Path $Path)) {
        return $null
    }

    foreach ($line in Get-Content $Path) {
        if ($line -match "^\s*$Key\s*=\s*""([^""]+)""\s*$") {
            return $matches[1]
        }
    }
    return $null
}

function Remove-TerraformBackendArtifacts {
    param([string]$BackendPath)
    if (-not (Test-Path $BackendPath)) {
        Write-WarnMsg "Backend config file not found: $BackendPath"
        return
    }

    $bucket = Get-BackendConfigValue -Path $BackendPath -Key "bucket"
    $key = Get-BackendConfigValue -Path $BackendPath -Key "key"
    $table = Get-BackendConfigValue -Path $BackendPath -Key "dynamodb_table"

    if (-not [string]::IsNullOrWhiteSpace($bucket)) {
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            Write-Info "Deleting Terraform state object s3://$bucket/$key"
            Invoke-AwsText -AllowFailure -Args @(
                "s3api", "delete-object",
                "--region", $Region,
                "--bucket", $bucket,
                "--key", $key
            ) | Out-Null
        }

        Clear-S3BucketCompletely -BucketName $bucket
        Write-Info "Deleting Terraform backend bucket $bucket"
        Invoke-AwsText -AllowFailure -Args @(
            "s3api", "delete-bucket",
            "--region", $Region,
            "--bucket", $bucket
        ) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($table)) {
        Write-Info "Deleting Terraform lock table $table"
        Invoke-AwsText -AllowFailure -Args @(
            "dynamodb", "delete-table",
            "--region", $Region,
            "--table-name", $table
        ) | Out-Null
    }
}

function Test-SsmPathEmpty {
    param([string]$PathPrefix)
    if ([string]::IsNullOrWhiteSpace($PathPrefix)) {
        return $true
    }

    $resp = Invoke-AwsJson -AllowFailure -Args @(
        "ssm", "get-parameters-by-path",
        "--region", $Region,
        "--path", $PathPrefix,
        "--recursive",
        "--max-results", "1",
        "--output", "json"
    )
    if ($null -eq $resp) {
        return $true
    }

    $params = Get-ObjectArrayProperty -Object $resp -PropertyName "Parameters"
    return ($params.Count -eq 0)
}

function Verify-TeardownState {
    param(
        [string]$AsgName,
        [string]$SsmPrefix,
        [string]$ClusterTagValue
    )

    Write-Info "Running post-teardown verification checks"

    $remainingInstance = Find-K3sInstanceId
    if (-not [string]::IsNullOrWhiteSpace($remainingInstance)) {
        Write-WarnMsg "Residual K3s instance still exists: $remainingInstance"
    }
    else {
        Write-Info "No residual K3s instance detected."
    }

    if (-not [string]::IsNullOrWhiteSpace($AsgName)) {
        $asgState = Invoke-AwsText -AllowFailure -Args @(
            "autoscaling", "describe-auto-scaling-groups",
            "--region", $Region,
            "--auto-scaling-group-names", $AsgName,
            "--query", "AutoScalingGroups[0].[MinSize,MaxSize,DesiredCapacity]",
            "--output", "text"
        )
        if (-not [string]::IsNullOrWhiteSpace($asgState) -and $asgState -ne "None") {
            Write-WarnMsg "ASG still exists after destroy: $AsgName ($asgState)"
        }
        else {
            Write-Info "ASG state is clean (not found or destroyed)."
        }
    }

    if (Test-SsmPathEmpty -PathPrefix $SsmPrefix) {
        Write-Info "SSM parameter path is empty: $SsmPrefix"
    }
    else {
        Write-WarnMsg "SSM parameter path still has values: $SsmPrefix"
    }

    $lbArns = Get-TaggedResourceArns -ResourceType "elasticloadbalancing:loadbalancer" -TagKey "elbv2.k8s.aws/cluster" -TagValue $ClusterTagValue
    if ($lbArns.Count -gt 0) {
        Write-WarnMsg "Residual LBC ALBs remain: $($lbArns -join ', ')"
    }
    else {
        Write-Info "No residual LBC ALBs detected."
    }
}

try {
    Require-Command -Name "aws"
    Require-Command -Name "terraform"

    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    $script:InfraPath = Resolve-RepoPath -Path $InfraDir

    if ([string]::IsNullOrWhiteSpace($VarFile)) {
        $VarFile = Join-Path $script:InfraPath "$Environment.tfvars"
    }
    else {
        $VarFile = Resolve-RepoPath -Path $VarFile
    }

    if ([string]::IsNullOrWhiteSpace($BackendConfig)) {
        $backendCandidate = Join-Path $script:InfraPath "backend.hcl"
        if (Test-Path $backendCandidate) {
            $BackendConfig = $backendCandidate
        }
    }
    else {
        $BackendConfig = Resolve-RepoPath -Path $BackendConfig
    }

    $accountId = Invoke-AwsText -Args @(
        "sts", "get-caller-identity",
        "--region", $Region,
        "--query", "Account",
        "--output", "text"
    )

    if ([string]::IsNullOrWhiteSpace($accountId) -or $accountId -eq "None") {
        throw "Unable to resolve AWS account ID."
    }

    $namePrefix = "$Project-$Environment"
    $clusterTag = "$namePrefix-k3s"
    $ssmPrefix = "/$Project/$Environment"

    Write-Info "Initializing Terraform in $script:InfraPath"
    $initArgs = @("-chdir=$script:InfraPath", "init", "-input=false", "-reconfigure")
    if (-not [string]::IsNullOrWhiteSpace($BackendConfig) -and (Test-Path $BackendConfig)) {
        $initArgs += "-backend-config=$BackendConfig"
    }
    Invoke-TerraformText -Args $initArgs | Out-Null

    $serverAsgName = Get-TerraformOutputRaw -Name "k3s_server_asg_name"
    if ([string]::IsNullOrWhiteSpace($serverAsgName)) {
        $serverAsgName = "$namePrefix-k3s-server"
    }
    $agentAsgName = Get-TerraformOutputRaw -Name "k3s_agent_asg_name"
    if ([string]::IsNullOrWhiteSpace($agentAsgName)) {
        $agentAsgName = "$namePrefix-k3s-agent"
    }
    $vpcId = Get-TerraformOutputRaw -Name "vpc_id"
    $imagesBucket = Get-TerraformOutputRaw -Name "images_bucket_name"
    $manifestsBucket = Get-TerraformOutputRaw -Name "manifests_bucket_name"
    $k3sDbName = Get-TerraformOutputRaw -Name "k3s_datastore_db_name"
    $outputSsmPrefix = Get-TerraformOutputRaw -Name "ssm_parameter_prefix"
    if (-not [string]::IsNullOrWhiteSpace($outputSsmPrefix)) {
        $ssmPrefix = $outputSsmPrefix
    }
    if ([string]::IsNullOrWhiteSpace($k3sDbName)) {
        $k3sDbName = "k3s_state"
    }

    if ([string]::IsNullOrWhiteSpace($imagesBucket)) {
        $imagesBucket = "$Project-images-$accountId-$Region"
    }
    if ([string]::IsNullOrWhiteSpace($manifestsBucket)) {
        $manifestsBucket = "$Project-manifests-$accountId-$Region"
    }

    Write-Host ""
    Write-Host "Teardown target summary:" -ForegroundColor Magenta
    Write-Host "  AWS Account : $accountId"
    Write-Host "  Region      : $Region"
    Write-Host "  Environment : $Environment"
    Write-Host "  Name Prefix : $namePrefix"
    Write-Host "  Server ASG  : $serverAsgName"
    Write-Host "  Agent ASG   : $agentAsgName"
    Write-Host "  VPC         : $vpcId"
    Write-Host "  SSM Prefix  : $ssmPrefix"
    Write-Host "  K3s DB      : $k3sDbName"
    Write-Host "  S3 Buckets  : $imagesBucket, $manifestsBucket"
    Write-Host "  DB Reset    : $(if ($SkipK3sDatastoreReset) { 'disabled' } else { 'enabled' })"
    Write-Host "  Var file    : $VarFile"
    if (-not [string]::IsNullOrWhiteSpace($BackendConfig)) {
        Write-Host "  Backend HCL : $BackendConfig"
    }
    Write-Host ""

    if (-not $AutoApprove) {
        $confirmToken = "$namePrefix-destroy"
        $confirmation = Read-Host "Type '$confirmToken' to destroy these resources"
        if ($confirmation -ne $confirmToken) {
            throw "Confirmation token mismatch. Aborting."
        }
    }

    $instanceId = Find-K3sInstanceId
    if (-not [string]::IsNullOrWhiteSpace($instanceId)) {
        Write-Info "Detected K3s instance: $instanceId"
    }
    else {
        Write-WarnMsg "No K3s instance currently detected."
    }

    if (-not $SkipK3sDatastoreReset) {
        Reset-K3sDatastore -InstanceId $instanceId -SsmPrefix $ssmPrefix -K3sDbName $k3sDbName
    }
    else {
        Write-WarnMsg "Skipping K3s datastore reset (SkipK3sDatastoreReset=true)."
    }

    Cleanup-KubernetesWorkloads -InstanceId $instanceId
    Remove-LbcArtifacts -ClusterTagValue $clusterTag
    Set-AsgToZero -AsgName $agentAsgName
    Set-AsgToZero -AsgName $serverAsgName
    Wait-ForAsgZero -AsgName $agentAsgName
    Wait-ForAsgZero -AsgName $serverAsgName
    Wait-NoK3sInstances

    Write-Info "Running terraform destroy"
    $destroyArgs = @("-chdir=$script:InfraPath", "destroy", "-input=false")
    if (Test-Path $VarFile) {
        $destroyArgs += "-var-file=$VarFile"
    }
    else {
        Write-WarnMsg "Var file not found at $VarFile; running destroy without explicit var-file."
    }
    if ($AutoApprove) {
        $destroyArgs += "-auto-approve"
    }

    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $destroyOutput = & terraform @destroyArgs 2>&1
        $destroyExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    if ($destroyOutput) {
        Write-Host ($destroyOutput | Out-String)
    }

    if ($destroyExit -ne 0) {
        Write-WarnMsg "terraform destroy failed on first attempt; retrying after extra cleanup."
        Remove-LbcArtifacts -ClusterTagValue $clusterTag
        Remove-OrphanEnisInVpc -VpcId $vpcId
        Clear-EcrRepositoryImages -RepositoryName "$Project-api"
        Clear-EcrRepositoryImages -RepositoryName "$Project-worker"
        Clear-S3BucketCompletely -BucketName $imagesBucket
        Clear-S3BucketCompletely -BucketName $manifestsBucket

        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $destroyOutput2 = & terraform @destroyArgs 2>&1
            $destroyExit2 = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $prevEap
        }
        if ($destroyOutput2) {
            Write-Host ($destroyOutput2 | Out-String)
        }
        if ($destroyExit2 -ne 0) {
            throw "terraform destroy failed after retry."
        }
    }

    Remove-SsmPath -PathPrefix $ssmPrefix
    Remove-LbcArtifacts -ClusterTagValue $clusterTag
    Remove-OrphanEnisInVpc -VpcId $vpcId
    Clear-EcrRepositoryImages -RepositoryName "$Project-api"
    Clear-EcrRepositoryImages -RepositoryName "$Project-worker"
    Verify-TeardownState -AsgName $serverAsgName -SsmPrefix $ssmPrefix -ClusterTagValue $clusterTag
    Verify-TeardownState -AsgName $agentAsgName -SsmPrefix $ssmPrefix -ClusterTagValue $clusterTag



    if ($DestroyBackend) {
        if ([string]::IsNullOrWhiteSpace($BackendConfig)) {
            Write-WarnMsg "DestroyBackend requested but backend config path is unavailable."
        }
        else {
            Remove-TerraformBackendArtifacts -BackendPath $BackendConfig
        }
    }

    Write-Host ""
    Write-Host "Teardown completed." -ForegroundColor Green
    if ($script:WarningCount -gt 0) {
        Write-Host "Completed with $script:WarningCount warning(s). Review output for manual follow-up." -ForegroundColor Yellow
    }
}
catch {
    Write-Host ""
    Write-Host "Teardown failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ($_ | Out-String) -ForegroundColor Red
    exit 1
}
