param(
  [string]$Date = "",
  [switch]$PushLink,
  [string]$RepoOwner = "wuyan4444",
  [string]$RepoName = "ai-daily-report"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Date)) {
  $dateObj = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), "China Standard Time")
  $Date = $dateObj.ToString("yyyy-MM-dd")
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$collectScript = Join-Path $scriptDir "collect_ai_news.ps1"
$enrichScript = Join-Path $scriptDir "enrich_with_llm.ps1"
$buildScript = Join-Path $scriptDir "build_daily_report.ps1"
$renderScript = Join-Path $scriptDir "render_report_html.ps1"
$linkScript = Join-Path $scriptDir "send_link_to_feishu.ps1"

foreach ($p in @($collectScript, $enrichScript, $buildScript, $renderScript, $linkScript)) {
  if (!(Test-Path $p)) {
    Write-Error "Missing script: $p"
    exit 1
  }
}

$newsPath = & $collectScript -Date $Date -OutputDir "data"
if ([string]::IsNullOrWhiteSpace($newsPath)) {
  Write-Error "Collection failed"
  exit 1
}

$enrichedPath = & $enrichScript -Date $Date -InputDir "data"
if ([string]::IsNullOrWhiteSpace($enrichedPath)) {
  Write-Error "LLM enrichment failed"
  exit 1
}

$reportPath = & $buildScript -Date $Date -InputDir "data" -OutputDir "reports" -Overwrite
if ([string]::IsNullOrWhiteSpace($reportPath)) {
  Write-Error "Build report failed"
  exit 1
}

$htmlPath = & $renderScript -Date $Date -ReportDir "reports" -OutputDir "."
if ([string]::IsNullOrWhiteSpace($htmlPath)) {
  Write-Error "Render html failed"
  exit 1
}

if ($PushLink) {
  $url = "https://$RepoOwner.github.io/$RepoName/"
  & $linkScript -ReportUrl $url -Date $Date
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}

Write-Output "Pipeline succeeded for date: $Date"
Write-Output "Report: $reportPath"
Write-Output "HTML: $htmlPath"
