[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("baseline", "spike", "retry_storm", "starvation_mix")]
    [string]$Scenario,
    [string]$BaseUrl = "http://localhost:8000",
    [string]$ApiKey = $env:PIXTOOLS_API_KEY,
    [string]$OutputDir = "bench/results",
    [switch]$ExportRawJson,
    [string[]]$ExtraEnv = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command k6 -ErrorAction SilentlyContinue)) {
    throw "k6 is not installed or not on PATH."
}

$scriptPath = Join-Path "bench/k6" "$Scenario.js"
if (-not (Test-Path $scriptPath)) {
    throw "Scenario script not found: $scriptPath"
}

New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null

$summaryPath = Join-Path $OutputDir "$Scenario-summary.json"
$k6args = @(
    "run",
    "--summary-export", $summaryPath,
    "-e", "BASE_URL=$BaseUrl"
)

if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
    $k6args += @("-e", "API_KEY=$ApiKey")
}

foreach ($envVar in $ExtraEnv) {
    $k6args += @("-e", $envVar)
}

if ($ExportRawJson) {
    $rawPath = Join-Path $OutputDir "$Scenario-raw.json"
    $k6args += @("--out", "json=$rawPath")
}

$k6args += $scriptPath

Write-Host "Running: k6 $($k6args -join ' ')" -ForegroundColor Cyan
& k6 @k6args

if ($LASTEXITCODE -ne 0) {
    throw "k6 run failed with exit code $LASTEXITCODE"
}

Write-Host "Summary written to $summaryPath" -ForegroundColor Green
