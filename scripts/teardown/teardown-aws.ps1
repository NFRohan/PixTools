[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$Project = "pixtools",
    [string]$Region = "us-east-1",
    [string]$InfraDir = "infra",
    [string]$VarFile = "",
    [string]$BackendConfig = "",
    [switch]$AutoApprove,
    [switch]$DestroyBackend,
    [switch]$DeleteGithubDeployRole,
    [string]$GithubDeployRoleName = "GitHubActionsPixToolsDeployRole"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:WarningCount = 0

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-WarnMsg {
    param([string]$Message)
    $script:WarningCount++
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
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

    $output = & aws @Args 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        if ($AllowFailure) {
            return $null
        }
        throw "aws $($Args -join ' ') failed: $output"
    }
    if ($null -eq $output) {
        return ""
    }
    return ($output | Out-String).Trim()
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
    $output = & terraform @Args 2>&1
    $exitCode = $LASTEXITCODE
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
        return @()
    }
    return @(
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
        return @()
    }
    $prop = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $prop -or $null -eq $prop.Value) {
        return @()
    }
    return @($prop.Value)
}

function Resolve-RepoPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return (Resolve-Path $Path).Path
    }
    return (Resolve-Path (Join-Path $script:RepoRoot $Path)).Path
}

function Get-TerraformOutputRaw {
    param([string]$Name)
    $value = Invoke-TerraformText -Args @("-chdir=$script:InfraPath", "output", "-raw", $Name) -AllowFailure
    if ([string]::IsNullOrWhiteSpace($value) -or $value -eq "null") {
        return $null
    }
    return $value.Trim()
}

function Find-K3sInstanceId {
    $instanceName = "$Project-$Environment-k3s"
    $text = Invoke-AwsText -AllowFailure -Args @(
        "ec2", "describe-instances",
        "--region", $Region,
        "--filters",
        "Name=tag:Name,Values=$instanceName",
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
        "    for i in $(seq 1 36); do",
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
        return @()
    }

    $arns = @()
    foreach ($entry in (Get-ObjectArrayProperty -Object $json -PropertyName "ResourceTagMappingList")) {
        if ($null -ne $entry.ResourceARN) {
            $arns += [string]$entry.ResourceARN
        }
    }
    return $arns | Select-Object -Unique
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
    $lbArns = $lbArns | Select-Object -Unique

    foreach ($lbArn in $lbArns) {
        Write-Info "Deleting ALB $lbArn"
        Invoke-AwsText -AllowFailure -Args @(
            "elbv2", "delete-load-balancer",
            "--region", $Region,
            "--load-balancer-arn", $lbArn
        ) | Out-Null
    }

    Start-Sleep -Seconds 10

    $tgArns = Get-TaggedResourceArns -ResourceType "elasticloadbalancing:targetgroup" -TagKey "elbv2.k8s.aws/cluster" -TagValue $ClusterTagValue
    foreach ($tgArn in $tgArns) {
        Write-Info "Deleting target group $tgArn"
        Invoke-AwsText -AllowFailure -Args @(
            "elbv2", "delete-target-group",
            "--region", $Region,
            "--target-group-arn", $tgArn
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

    while ($true) {
        $listJson = Invoke-AwsJson -AllowFailure -Args @(
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

        $deletePayloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("pixtools-s3-delete-" + [guid]::NewGuid().ToString() + ".json")
        try {
            @{ Objects = $objects; Quiet = $true } | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $deletePayloadPath -Encoding Ascii
            Invoke-AwsText -AllowFailure -Args @(
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
            if ($null -ne $img.imageTag -and -not [string]::IsNullOrWhiteSpace([string]$img.imageTag)) {
                Invoke-AwsText -AllowFailure -Args @(
                    "ecr", "batch-delete-image",
                    "--region", $Region,
                    "--repository-name", $RepositoryName,
                    "--image-ids", "imageTag=$($img.imageTag)"
                ) | Out-Null
            }
            elseif ($null -ne $img.imageDigest -and -not [string]::IsNullOrWhiteSpace([string]$img.imageDigest)) {
                Invoke-AwsText -AllowFailure -Args @(
                    "ecr", "batch-delete-image",
                    "--region", $Region,
                    "--repository-name", $RepositoryName,
                    "--image-ids", "imageDigest=$($img.imageDigest)"
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

function Remove-GithubDeployRoleArtifacts {
    param([string]$RoleName)
    if ([string]::IsNullOrWhiteSpace($RoleName)) {
        return
    }

    Write-Info "Deleting IAM role artifacts for $RoleName"

    $inlinePolicies = Invoke-AwsJson -AllowFailure -Args @(
        "iam", "list-role-policies",
        "--role-name", $RoleName,
        "--output", "json"
    )
    foreach ($policyName in (Get-ObjectArrayProperty -Object $inlinePolicies -PropertyName "PolicyNames")) {
        Invoke-AwsText -AllowFailure -Args @(
            "iam", "delete-role-policy",
            "--role-name", $RoleName,
            "--policy-name", [string]$policyName
        ) | Out-Null
    }

    $attachedPolicies = Invoke-AwsJson -AllowFailure -Args @(
        "iam", "list-attached-role-policies",
        "--role-name", $RoleName,
        "--output", "json"
    )
    foreach ($policy in (Get-ObjectArrayProperty -Object $attachedPolicies -PropertyName "AttachedPolicies")) {
        if ($null -ne $policy.PolicyArn) {
            Invoke-AwsText -AllowFailure -Args @(
                "iam", "detach-role-policy",
                "--role-name", $RoleName,
                "--policy-arn", [string]$policy.PolicyArn
            ) | Out-Null
        }
    }

    Invoke-AwsText -AllowFailure -Args @(
        "iam", "delete-role",
        "--role-name", $RoleName
    ) | Out-Null
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

    $asgName = Get-TerraformOutputRaw -Name "k3s_asg_name"
    if ([string]::IsNullOrWhiteSpace($asgName)) {
        $asgName = "$namePrefix-k3s"
    }
    $vpcId = Get-TerraformOutputRaw -Name "vpc_id"
    $imagesBucket = Get-TerraformOutputRaw -Name "images_bucket_name"
    $manifestsBucket = Get-TerraformOutputRaw -Name "manifests_bucket_name"
    $outputSsmPrefix = Get-TerraformOutputRaw -Name "ssm_parameter_prefix"
    if (-not [string]::IsNullOrWhiteSpace($outputSsmPrefix)) {
        $ssmPrefix = $outputSsmPrefix
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
    Write-Host "  ASG         : $asgName"
    Write-Host "  VPC         : $vpcId"
    Write-Host "  SSM Prefix  : $ssmPrefix"
    Write-Host "  S3 Buckets  : $imagesBucket, $manifestsBucket"
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

    Cleanup-KubernetesWorkloads -InstanceId $instanceId
    Remove-LbcArtifacts -ClusterTagValue $clusterTag
    Set-AsgToZero -AsgName $asgName

    Clear-EcrRepositoryImages -RepositoryName "$Project-api"
    Clear-EcrRepositoryImages -RepositoryName "$Project-worker"
    Clear-S3BucketCompletely -BucketName $imagesBucket
    Clear-S3BucketCompletely -BucketName $manifestsBucket

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

    $destroyOutput = & terraform @destroyArgs 2>&1
    $destroyExit = $LASTEXITCODE
    if ($destroyOutput) {
        Write-Host ($destroyOutput | Out-String)
    }

    if ($destroyExit -ne 0) {
        Write-WarnMsg "terraform destroy failed on first attempt; retrying after extra cleanup."
        Remove-LbcArtifacts -ClusterTagValue $clusterTag
        Remove-OrphanEnisInVpc -VpcId $vpcId

        $destroyOutput2 = & terraform @destroyArgs 2>&1
        $destroyExit2 = $LASTEXITCODE
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

    if ($DeleteGithubDeployRole) {
        Remove-GithubDeployRoleArtifacts -RoleName $GithubDeployRoleName
    }

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
    exit 1
}
