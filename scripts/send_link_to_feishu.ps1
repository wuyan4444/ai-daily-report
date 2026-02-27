param(
  [Parameter(Mandatory = $true)]
  [string]$ReportUrl,
  [string]$Date = (Get-Date -Format "yyyy-MM-dd"),
  [string]$WebhookUrl = $env:FEISHU_WEBHOOK_URL,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$title = "AI Daily Report | 今日AI简报 - " + $Date
$line1 = "AI Daily Report"
$line2 = "今日AI简报已更新，点击查看："
$line3 = $ReportUrl

$rows = @(
  @(@{ tag = "text"; text = $line1 }),
  @(@{ tag = "text"; text = $line2 }),
  @(@{ tag = "a"; text = $ReportUrl; href = $ReportUrl })
)

$payload = @{
  msg_type = "post"
  content = @{
    post = @{
      zh_cn = @{
        title = $title
        content = $rows
      }
    }
  }
}

$json = $payload | ConvertTo-Json -Depth 10

if ($DryRun) {
  Write-Output $json
  exit 0
}

if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
  Write-Error "Missing FEISHU_WEBHOOK_URL"
  exit 1
}

try {
  $response = Invoke-RestMethod -Method Post -Uri $WebhookUrl -ContentType "application/json; charset=utf-8" -Body $json
} catch {
  Write-Error "Failed to call Feishu webhook: $($_.Exception.Message)"
  exit 1
}

$ok = $false
if ($null -ne $response.PSObject.Properties["code"] -and [int]$response.code -eq 0) {
  $ok = $true
}
if ($null -ne $response.PSObject.Properties["StatusCode"] -and [int]$response.StatusCode -eq 0) {
  $ok = $true
}
if (-not $ok) {
  Write-Error "Feishu returned non-success response: $($response | ConvertTo-Json -Depth 8)"
  exit 1
}

Write-Output "Feishu link push succeeded: $ReportUrl"
