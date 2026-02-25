[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("baseline", "spike", "retry_storm", "starvation_mix")]
    [string]$Scenario,

    [string]$PrometheusUrl = $env:GRAFANA_PROMETHEUS_URL,
    [string]$PrometheusUser = $env:GRAFANA_PROMETHEUS_USER,
    [string]$PrometheusApiKey = $env:GRAFANA_PROMETHEUS_API_KEY,

    [string]$OutputDir = "bench/results",
    [int]$WindowMinutes = 10,
    [datetime]$StartUtc,
    [datetime]$EndUtc,

    [string]$Environment = "dev",
    [string]$BaseUrl = "",
    [string]$CommitSha = "",
    [string]$K6SummaryPath = "",
    [switch]$WriteMarkdownReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($PrometheusUrl)) {
    throw "Prometheus URL is required. Pass -PrometheusUrl or set GRAFANA_PROMETHEUS_URL."
}
if ([string]::IsNullOrWhiteSpace($PrometheusUser)) {
    throw "Prometheus user is required. Pass -PrometheusUser or set GRAFANA_PROMETHEUS_USER."
}
if ([string]::IsNullOrWhiteSpace($PrometheusApiKey)) {
    throw "Prometheus API key is required. Pass -PrometheusApiKey or set GRAFANA_PROMETHEUS_API_KEY."
}

if ($PrometheusUrl.EndsWith("/")) {
    $PrometheusUrl = $PrometheusUrl.TrimEnd("/")
}

if (-not $PSBoundParameters.ContainsKey("EndUtc")) {
    $EndUtc = [datetime]::UtcNow
}
if (-not $PSBoundParameters.ContainsKey("StartUtc")) {
    $StartUtc = $EndUtc.AddMinutes(-1 * [math]::Abs($WindowMinutes))
}
if ($StartUtc -gt $EndUtc) {
    throw "StartUtc must be earlier than EndUtc."
}

New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null

$endIso = $EndUtc.ToString("o")
$startIso = $StartUtc.ToString("o")
$window = "$([math]::Abs($WindowMinutes))m"

if ([string]::IsNullOrWhiteSpace($K6SummaryPath)) {
    $autoSummaryPath = Join-Path $OutputDir "$Scenario-summary.json"
    if (Test-Path $autoSummaryPath) {
        $K6SummaryPath = $autoSummaryPath
    }
}

function New-BasicAuthHeader {
    param(
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$ApiKey
    )
    $raw = "{0}:{1}" -f $User, $ApiKey
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($raw))
    return @{ Authorization = "Basic $encoded" }
}

function Parse-PrometheusNumber {
    param([AllowNull()][object]$ValueText)

    if ($null -eq $ValueText) {
        return $null
    }
    $text = [string]$ValueText
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    $number = 0.0
    $ok = [double]::TryParse(
        $text,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )
    if ($ok) {
        return $number
    }
    return $null
}

function Invoke-PrometheusInstantQuery {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][string]$TimeIso
    )

    $queryEscaped = [uri]::EscapeDataString($Query)
    $timeEscaped = [uri]::EscapeDataString($TimeIso)
    $uri = "{0}/api/prom/api/v1/query?query={1}&time={2}" -f $BaseUrl, $queryEscaped, $timeEscaped

    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers -TimeoutSec 30
    if ($response.status -ne "success") {
        throw "Prometheus query failed for '$Query'. Response status: $($response.status)"
    }
    return $response.data
}

function Get-SinglePrometheusValue {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][string]$TimeIso,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $data = Invoke-PrometheusInstantQuery -BaseUrl $BaseUrl -Headers $Headers -Query $Query -TimeIso $TimeIso
    if ($null -eq $data -or $null -eq $data.result -or $data.result.Count -eq 0) {
        return $null
    }
    $sample = $data.result[0]
    if ($null -eq $sample.value -or $sample.value.Count -lt 2) {
        return $null
    }
    return Parse-PrometheusNumber -ValueText $sample.value[1]
}

function Get-LabeledPrometheusVector {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][string]$TimeIso,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $data = Invoke-PrometheusInstantQuery -BaseUrl $BaseUrl -Headers $Headers -Query $Query -TimeIso $TimeIso
    if ($null -eq $data -or $null -eq $data.result) {
        return @()
    }

    $items = @()
    foreach ($row in $data.result) {
        $labels = @{}
        if ($row.metric) {
            $row.metric.PSObject.Properties | ForEach-Object {
                $labels[$_.Name] = $_.Value
            }
        }
        $items += [pscustomobject]@{
            labels = $labels
            value = (Parse-PrometheusNumber -ValueText $row.value[1])
        }
    }
    return $items
}

function Get-K6Value {
    param(
        [AllowNull()][object]$K6Summary,
        [Parameter(Mandatory = $true)][string]$MetricName,
        [Parameter(Mandatory = $true)][string]$Field
    )

    if ($null -eq $K6Summary -or $null -eq $K6Summary.metrics) {
        return $null
    }
    $metric = $K6Summary.metrics.PSObject.Properties[$MetricName]
    if ($null -eq $metric) {
        return $null
    }
    $values = $metric.Value.values
    if ($null -eq $values) {
        return $null
    }
    $prop = $values.PSObject.Properties[$Field]
    if ($null -eq $prop) {
        return $null
    }
    return $prop.Value
}

$headers = New-BasicAuthHeader -User $PrometheusUser -ApiKey $PrometheusApiKey

$singleQueries = [ordered]@{
    api_latency_p50_seconds = "histogram_quantile(0.50, sum(rate(pixtools_api_request_latency_seconds_bucket[$window])) by (le))"
    api_latency_p95_seconds = "histogram_quantile(0.95, sum(rate(pixtools_api_request_latency_seconds_bucket[$window])) by (le))"
    queue_wait_p95_seconds = "histogram_quantile(0.95, sum(rate(pixtools_job_queue_wait_seconds_bucket[$window])) by (le))"
    worker_processing_p95_seconds = "histogram_quantile(0.95, sum(rate(pixtools_worker_task_processing_seconds_bucket[$window])) by (le))"
    job_end_to_end_p95_seconds = "histogram_quantile(0.95, sum(rate(pixtools_job_end_to_end_seconds_bucket[$window])) by (le))"
    jobs_per_second_total = "sum(rate(pixtools_job_status_total[$window]))"
    jobs_per_minute_total = "60 * sum(rate(pixtools_job_status_total[$window]))"
    retry_rate_per_second = "sum(rate(pixtools_task_retry_total[$window]))"
    failure_rate_per_second = "sum(rate(pixtools_task_failure_total[$window]))"
    max_default_queue_depth = "max_over_time(pixtools_rabbitmq_queue_depth{queue=`"default_queue`"}[$window])"
    max_ml_queue_depth = "max_over_time(pixtools_rabbitmq_queue_depth{queue=`"ml_inference_queue`"}[$window])"
    max_dead_letter_queue_depth = "max_over_time(pixtools_rabbitmq_queue_depth{queue=`"dead_letter`"}[$window])"
    rabbitmq_up = "max_over_time(pixtools_rabbitmq_up[$window])"
}

$vectorQueries = [ordered]@{
    jobs_per_second_by_status = "sum by (status) (rate(pixtools_job_status_total[$window]))"
    retry_rate_per_second_by_task = "sum by (task_name) (rate(pixtools_task_retry_total[$window]))"
    failure_rate_per_second_by_task = "sum by (task_name) (rate(pixtools_task_failure_total[$window]))"
    queue_wait_p95_seconds_by_task = "histogram_quantile(0.95, sum(rate(pixtools_job_queue_wait_seconds_bucket[$window])) by (le, task_name))"
    worker_processing_p95_seconds_by_task = "histogram_quantile(0.95, sum(rate(pixtools_worker_task_processing_seconds_bucket[$window])) by (le, task_name))"
}

$metrics = [ordered]@{}
foreach ($entry in $singleQueries.GetEnumerator()) {
    $metrics[$entry.Key] = Get-SinglePrometheusValue -Query $entry.Value -TimeIso $endIso -BaseUrl $PrometheusUrl -Headers $headers
}

$vectors = [ordered]@{}
foreach ($entry in $vectorQueries.GetEnumerator()) {
    $vectors[$entry.Key] = Get-LabeledPrometheusVector -Query $entry.Value -TimeIso $endIso -BaseUrl $PrometheusUrl -Headers $headers
}

$k6Summary = $null
if (-not [string]::IsNullOrWhiteSpace($K6SummaryPath) -and (Test-Path $K6SummaryPath)) {
    $k6Summary = Get-Content $K6SummaryPath -Raw | ConvertFrom-Json
}

$k6Metrics = [ordered]@{
    jobs_submitted_total = (Get-K6Value -K6Summary $k6Summary -MetricName "jobs_submitted_total" -Field "count")
    jobs_failed_total = (Get-K6Value -K6Summary $k6Summary -MetricName "jobs_failed_total" -Field "count")
    duplicate_processing_signals_total = (Get-K6Value -K6Summary $k6Summary -MetricName "duplicate_processing_signals_total" -Field "count")
    client_retries_total = (Get-K6Value -K6Summary $k6Summary -MetricName "client_retries_total" -Field "count")
    k6_http_req_duration_p95_ms = (Get-K6Value -K6Summary $k6Summary -MetricName "http_req_duration" -Field "p(95)")
    k6_http_req_failed_rate = (Get-K6Value -K6Summary $k6Summary -MetricName "http_req_failed" -Field "rate")
}

$payload = [ordered]@{
    metadata = [ordered]@{
        collected_at_utc = [datetime]::UtcNow.ToString("o")
        scenario = $Scenario
        environment = $Environment
        base_url = $BaseUrl
        commit_sha = $CommitSha
        query_window = [ordered]@{
            start_utc = $startIso
            end_utc = $endIso
            duration_minutes = [math]::Abs($WindowMinutes)
        }
        prometheus_url = $PrometheusUrl
    }
    metrics = $metrics
    breakdowns = $vectors
    k6 = [ordered]@{
        summary_path = $K6SummaryPath
        metrics = $k6Metrics
    }
    promql = [ordered]@{
        single = $singleQueries
        vector = $vectorQueries
    }
}

$jsonPath = Join-Path $OutputDir "$Scenario-server-metrics.json"
$payload | ConvertTo-Json -Depth 12 | Set-Content $jsonPath

Write-Host "Server metrics written to $jsonPath" -ForegroundColor Green

if ($WriteMarkdownReport) {
    $reportPath = Join-Path $OutputDir "$Scenario-auto-report.md"

    $reportLines = @(
        "# Auto Benchmark Report ($Scenario)"
        ""
        "## Run Metadata"
        ""
        "- Date (UTC): $([datetime]::UtcNow.ToString('o'))"
        "- Environment: $Environment"
        "- Base URL: $BaseUrl"
        "- Commit SHA: $CommitSha"
        "- Scenario: $Scenario"
        "- Query window: $startIso -> $endIso ($([math]::Abs($WindowMinutes))m)"
        ""
        "## Key Results"
        ""
        "- Accepted jobs per minute (server): $($metrics.jobs_per_minute_total)"
        "- API latency p50 (s): $($metrics.api_latency_p50_seconds)"
        "- API latency p95 (s): $($metrics.api_latency_p95_seconds)"
        "- Queue wait p95 (s): $($metrics.queue_wait_p95_seconds)"
        "- Worker processing p95 (s): $($metrics.worker_processing_p95_seconds)"
        "- End-to-end p95 (s): $($metrics.job_end_to_end_p95_seconds)"
        "- Retry rate (per sec): $($metrics.retry_rate_per_second)"
        "- Failure rate (per sec): $($metrics.failure_rate_per_second)"
        "- Max queue depth default/ml/dlq: $($metrics.max_default_queue_depth) / $($metrics.max_ml_queue_depth) / $($metrics.max_dead_letter_queue_depth)"
        "- RabbitMQ up (window max): $($metrics.rabbitmq_up)"
        ""
        "## k6 Summary (if provided)"
        ""
        "- jobs_submitted_total: $($k6Metrics.jobs_submitted_total)"
        "- jobs_failed_total: $($k6Metrics.jobs_failed_total)"
        "- duplicate_processing_signals_total: $($k6Metrics.duplicate_processing_signals_total)"
        "- client_retries_total: $($k6Metrics.client_retries_total)"
        "- k6 http_req_duration p95 (ms): $($k6Metrics.k6_http_req_duration_p95_ms)"
        "- k6 http_req_failed rate: $($k6Metrics.k6_http_req_failed_rate)"
        ""
        "## Artifacts"
        ""
        "- JSON: $jsonPath"
        "- k6 summary: $K6SummaryPath"
    )

    $reportLines -join "`r`n" | Set-Content $reportPath
    Write-Host "Auto report written to $reportPath" -ForegroundColor Green
}
