param(
  [string]$Date = (Get-Date -Format "yyyy-MM-dd"),
  [string]$InputDir = "data",
  [int]$MaxItems = 4,
  [string]$LlmApiKey = $env:LLM_API_KEY,
  [string]$LlmBaseUrl = $(if ([string]::IsNullOrWhiteSpace($env:LLM_BASE_URL)) { "https://api.openai.com/v1" } else { $env:LLM_BASE_URL }),
  [string]$LlmModel = $(if ([string]::IsNullOrWhiteSpace($env:LLM_MODEL)) { "gpt-4o-mini" } else { $env:LLM_MODEL })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $scriptDir
$inputPath = Join-Path (Join-Path $repoDir $InputDir) ("ai-news-" + $Date + ".json")

if (!(Test-Path $inputPath)) {
  Write-Error "Input not found: $inputPath"
  exit 1
}

if ([string]::IsNullOrWhiteSpace($LlmApiKey)) {
  Write-Output $inputPath
  exit 0
}

function NText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
  $v = [System.Net.WebUtility]::HtmlDecode($Text)
  $v = $v -replace "\s+", " "
  return $v.Trim()
}

function Parse-DateSafe {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  try { return [datetime]::Parse($Text) } catch { return $null }
}

function Invoke-LlmJson {
  param(
    [string]$Prompt,
    [string]$ApiKey,
    [string]$BaseUrl,
    [string]$Model
  )

  $uri = $BaseUrl.TrimEnd('/') + "/chat/completions"
  $payload = @{
    model = $Model
    temperature = 0.2
    messages = @(
      @{ role = "system"; content = "你是严谨的AI情报编辑助手。只输出JSON，不要markdown。" },
      @{ role = "user"; content = $Prompt }
    )
  }

  $json = $payload | ConvertTo-Json -Depth 8
  $headers = @{ Authorization = "Bearer $ApiKey" }

  try {
    $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType "application/json; charset=utf-8" -Body $json -TimeoutSec 60
  } catch {
    return $null
  }

  $content = ""
  try { $content = [string]$resp.choices[0].message.content } catch {}
  if ([string]::IsNullOrWhiteSpace($content)) { return $null }

  try {
    return ($content | ConvertFrom-Json)
  } catch {
    $m = [regex]::Match($content, '\{[\s\S]*\}')
    if ($m.Success) {
      try { return ($m.Value | ConvertFrom-Json) } catch {}
    }
  }

  return $null
}

$raw = Get-Content -Path $inputPath -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($raw)) {
  Write-Output $inputPath
  exit 0
}

$doc = $raw | ConvertFrom-Json
$items = @($doc.items)
if ($items.Count -eq 0) {
  Write-Output $inputPath
  exit 0
}

$candidates = @(
  $items |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.title) } |
    Sort-Object @{ Expression = { Parse-DateSafe -Text ([string]$_.published_at_local) }; Descending = $true } |
    Select-Object -First $MaxItems
)

foreach ($it in $candidates) {
  $title = NText -Text ([string]$it.title)
  $snippet = NText -Text ([string]$it.snippet)
  $link = NText -Text ([string]$it.link)

  $prompt = @"
请基于以下素材输出JSON，字段必须为：summary, action, invest, confidence。
要求：
1) summary：40字内，写核心结论（避免空话）。
2) action：35字内，给我今天能执行的一步。
3) invest：35字内，给观察角度，不给买卖建议。
4) confidence：只能是 高 / 中 / 低。
5) 若证据不足，明确写在summary里并降低confidence。

标题：$title
摘要：$snippet
链接：$link
"@

  $parsed = Invoke-LlmJson -Prompt $prompt -ApiKey $LlmApiKey -BaseUrl $LlmBaseUrl -Model $LlmModel
  if ($null -eq $parsed) { continue }

  $it | Add-Member -NotePropertyName llm_summary -NotePropertyValue (NText -Text ([string]$parsed.summary)) -Force
  $it | Add-Member -NotePropertyName llm_action -NotePropertyValue (NText -Text ([string]$parsed.action)) -Force
  $it | Add-Member -NotePropertyName llm_invest -NotePropertyValue (NText -Text ([string]$parsed.invest)) -Force
  $it | Add-Member -NotePropertyName llm_confidence -NotePropertyValue (NText -Text ([string]$parsed.confidence)) -Force
}

$overviewInput = New-Object System.Collections.Generic.List[string]
foreach ($it in ($items | Select-Object -First 8)) {
  $title = NText -Text ([string]$it.title)
  $snippet = NText -Text ([string]$it.snippet)
  if ([string]::IsNullOrWhiteSpace($title)) { continue }
  $overviewInput.Add("- " + $title + " | " + $snippet)
}

if ($overviewInput.Count -gt 0) {
  $overviewPrompt = @"
请对下面材料做“今日一眼结论”，输出JSON：{"overview":["...","..."]}
要求：
1) 两条以内，每条不超过45字。
2) 必须是可执行、可判断的结论，不要空话。
3) 如果今天没有新增高价值信息，明确写出来。

素材：
$($overviewInput -join "`n")
"@
  $ov = Invoke-LlmJson -Prompt $overviewPrompt -ApiKey $LlmApiKey -BaseUrl $LlmBaseUrl -Model $LlmModel
  if ($null -ne $ov -and $null -ne $ov.overview) {
    $arr = @()
    foreach ($x in @($ov.overview)) {
      $v = NText -Text ([string]$x)
      if (-not [string]::IsNullOrWhiteSpace($v)) { $arr += $v }
    }
    if ($arr.Count -gt 0) {
      $doc | Add-Member -NotePropertyName llm_daily_overview -NotePropertyValue $arr -Force
    }
  }
}

$doc.items = $items
$doc | ConvertTo-Json -Depth 8 | Set-Content -Path $inputPath -Encoding UTF8
Write-Output $inputPath
