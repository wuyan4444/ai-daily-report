param(
  [string]$Date = (Get-Date -Format "yyyy-MM-dd"),
  [string]$InputDir = "data",
  [string]$OutputDir = "reports",
  [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillDir = Split-Path -Parent $scriptDir
$inputPath = Join-Path (Join-Path $skillDir $InputDir) ("ai-news-" + $Date + ".json")
$outputRoot = Join-Path $skillDir $OutputDir
if (!(Test-Path $outputRoot)) {
  New-Item -ItemType Directory -Path $outputRoot | Out-Null
}
$reportPath = Join-Path $outputRoot ("ai-daily-brief-" + $Date + ".md")

if ((Test-Path $reportPath) -and (-not $Overwrite)) {
  Write-Output $reportPath
  exit 0
}
if (!(Test-Path $inputPath)) {
  Write-Error "Input not found: $inputPath"
  exit 1
}

$raw = Get-Content -Path $inputPath -Raw -Encoding UTF8
$doc = $raw | ConvertFrom-Json
$items = @($doc.items)
$reportDate = [datetime]::ParseExact($Date, "yyyy-MM-dd", $null)
$llmDailyOverview = @()
if ($null -ne $doc.PSObject.Properties["llm_daily_overview"]) {
  foreach ($x in @($doc.llm_daily_overview)) {
    $v = [string]$x
    if (-not [string]::IsNullOrWhiteSpace($v)) { $llmDailyOverview += $v.Trim() }
  }
}
if ($llmDailyOverview.Count -eq 0) {
  Write-Error "Pure-LLM mode requires llm_daily_overview, but none was found."
  exit 1
}

function NText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
  $v = [System.Net.WebUtility]::HtmlDecode($Text)
  $v = $v -replace "\s+", " "
  return $v.Trim()
}

function NKey {
  param([string]$Text)
  return (NText -Text $Text).ToLowerInvariant()
}

function Parse-LocalTime {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  try { return [datetime]::Parse($Text) } catch { return $null }
}

function Get-OptionalText {
  param($Obj,[string]$Name)
  if ($null -eq $Obj) { return "" }
  if ($null -eq $Obj.PSObject.Properties[$Name]) { return "" }
  return NText -Text ([string]$Obj.PSObject.Properties[$Name].Value)
}

function Get-AgeDays {
  param([datetime]$Published,[datetime]$RefDate)
  if ($null -eq $Published) { return 9999 }
  return [int](($RefDate.Date - $Published.Date).TotalDays)
}

function Get-Score {
  param([string]$Title,[string]$Source,[string]$Snippet,[string]$SourceHost,[int]$AgeDays)
  $score = 0
  $t = NKey -Text ($Title + " " + $Source + " " + $Snippet + " " + $SourceHost)

  foreach ($w in @("发布","上线","开源","融资","并购","监管","政策","openai","nvidia","google","microsoft","财报")) {
    if ($t.Contains($w)) { $score += 5 }
  }
  foreach ($w in @("agent","工作流","效率","实战","具身","机器人","空间智能")) {
    if ($t.Contains($w)) { $score += 3 }
  }
  foreach ($w in @("captcha","blocked","验证码","风控拦截","受限")) {
    if ($t.Contains($w)) { $score -= 6 }
  }

  if ($t.Contains("腾讯研究院") -or $t.Contains("tisi.org")) { $score += 2 }
  if ($t.Contains("openai.com") -or $t.Contains("nvidia.com")) { $score += 3 }

  if ($AgeDays -le 1) { $score += 6 }
  elseif ($AgeDays -le 3) { $score += 4 }
  elseif ($AgeDays -le 7) { $score += 2 }
  elseif ($AgeDays -le 30) { $score += 0 }
  elseif ($AgeDays -le 90) { $score -= 4 }
  else { $score -= 8 }

  return $score
}

function Get-Confidence {
  param([string]$Source,[string]$Snippet)
  $t = NKey -Text ($Source + " " + $Snippet)
  if ($t.Contains("captcha") -or $t.Contains("验证码") -or $t.Contains("风控拦截") -or $t.Contains("受限")) { return "低" }
  if ([string]::IsNullOrWhiteSpace($Snippet)) { return "低" }
  if ($t.Contains("腾讯研究院") -or $t.Contains("openai") -or $t.Contains("nvidia")) { return "中高" }
  return "中"
}

function Get-Tier {
  param([int]$Score,[string]$Confidence)
  if ($Confidence -eq "低") { return "C" }
  if ($Score -ge 14) { return "S" }
  if ($Score -ge 9) { return "A" }
  if ($Score -ge 4) { return "B" }
  return "C"
}

function Get-RecencyLabel {
  param([int]$AgeDays)
  if ($AgeDays -le 0) { return "今日" }
  if ($AgeDays -eq 1) { return "昨日" }
  if ($AgeDays -le 7) { return ("近{0}天" -f $AgeDays) }
  if ($AgeDays -le 30) { return ("近{0}天" -f $AgeDays) }
  return ("{0}天前" -f $AgeDays)
}

$seen = @{}
$ranked = @()
foreach ($i in $items) {
  $title = NText -Text ([string]$i.title)
  if ([string]::IsNullOrWhiteSpace($title)) { continue }
  $key = NKey -Text $title
  if ($seen.ContainsKey($key)) { continue }
  $seen[$key] = $true

  $source = NText -Text ([string]$i.source_label)
  $sourceHost = NText -Text ([string]$i.source_host)
  $time = NText -Text ([string]$i.published_at_local)
  $link = NText -Text ([string]$i.link)
  $snippet = NText -Text ([string]$i.snippet)
  $llmSummary = Get-OptionalText -Obj $i -Name "llm_summary"
  $llmAction = Get-OptionalText -Obj $i -Name "llm_action"
  $llmInvest = Get-OptionalText -Obj $i -Name "llm_invest"
  $llmConfidence = Get-OptionalText -Obj $i -Name "llm_confidence"
  if ([string]::IsNullOrWhiteSpace($llmSummary) -or [string]::IsNullOrWhiteSpace($llmAction) -or [string]::IsNullOrWhiteSpace($llmInvest)) {
    continue
  }
  $published = Parse-LocalTime -Text $time
  $ageDays = Get-AgeDays -Published $published -RefDate $reportDate

  $score = Get-Score -Title $title -Source $source -Snippet $snippet -SourceHost $sourceHost -AgeDays $ageDays
  $confidence = Get-Confidence -Source $source -Snippet $snippet
  $tier = Get-Tier -Score $score -Confidence $confidence

  $ranked += [pscustomobject]@{
    title = $title
    source = $source
    host = $sourceHost
    time = $time
    link = $link
    snippet = $snippet
    ageDays = $ageDays
    recency = Get-RecencyLabel -AgeDays $ageDays
    score = $score
    tier = $tier
    confidence = $confidence
    fact = $llmSummary
    action = $llmAction
    invest = $llmInvest
    llmSummary = $llmSummary
    llmAction = $llmAction
    llmInvest = $llmInvest
    llmConfidence = $llmConfidence
  }
}
if ($ranked.Count -eq 0) {
  Write-Error "Pure-LLM mode requires llm-enriched items, but none were found."
  exit 1
}

$ordered = @($ranked | Sort-Object @{Expression="score";Descending=$true}, @{Expression="time";Descending=$true})
$fresh = @($ordered | Where-Object { $_.ageDays -le 30 -and $_.confidence -ne "低" })
$priority = @($ordered | Where-Object { ($_.tier -eq "S" -or $_.tier -eq "A") -and $_.ageDays -le 30 })
if ($priority.Count -eq 0) { $priority = @($fresh | Where-Object { $_.tier -eq "B" }) }
$focus = @($priority | Select-Object -First 3)
$background = @($ordered | Where-Object { $_.ageDays -gt 30 -and $_.confidence -ne "低" } | Select-Object -First 1)

$sCount = @($ordered | Where-Object { $_.tier -eq "S" }).Count
$aCount = @($ordered | Where-Object { $_.tier -eq "A" }).Count
$bCount = @($ordered | Where-Object { $_.tier -eq "B" }).Count
$cCount = @($ordered | Where-Object { $_.tier -eq "C" }).Count

$recent7Count = @($ordered | Where-Object { $_.ageDays -le 7 }).Count
$historyCount = @($ordered | Where-Object { $_.ageDays -gt 30 }).Count

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("【一眼结论】")
if ($llmDailyOverview.Count -gt 0) {
  foreach ($x in ($llmDailyOverview | Select-Object -First 2)) {
    $lines.Add("- " + (NText -Text $x))
  }
} elseif ($focus.Count -eq 0) {
  $lines.Add("- 今日未抓到可直接行动的高价值增量。")
} else {
  $lines.Add("- 今日可执行重点：" + $focus.Count + " 条（已压缩成最小可读版本）。")
}
$lines.Add("- 分级总览：S " + $sCount + " | A " + $aCount + " | B " + $bCount + " | C " + $cCount)
$lines.Add("- 时效总览：近7天 " + $recent7Count + " 条 | 历史参考 " + $historyCount + " 条")
$lines.Add("--------------------------")

$lines.Add("【三条重点】")
if ($focus.Count -eq 0) {
  $lines.Add("- 暂无（今日未抓到可执行的新鲜增量）")
  if ($background.Count -gt 0) {
    $lines.Add("- 背景补课（非今日）：[" + $background[0].recency + "] " + $background[0].title)
    $bgFact = $background[0].llmSummary
    $bgAction = $background[0].llmAction
    $lines.Add("  关键点：" + $bgFact)
    $lines.Add("  你能立刻做：" + $bgAction)
    $lines.Add("  来源：" + $background[0].source + " | " + $background[0].link)
  }
} else {
  foreach ($it in $focus) {
    $factText = $it.llmSummary
    $actionText = $it.llmAction
    $investText = $it.llmInvest
    $lines.Add("- [" + $it.tier + "][" + $it.recency + "] " + $it.title)
    $lines.Add("  关键点：" + $factText)
    $lines.Add("  你能立刻做：" + $actionText)
    $lines.Add("  投资观察：" + $investText)
    $lines.Add("  来源：" + $it.source + " | " + $it.link)
    $lines.Add("")
  }
}

$lines.Add("--------------------------")
$lines.Add("【S/A/B/C 看板】")
$topS = @($ordered | Where-Object { $_.tier -eq "S" -and $_.ageDays -le 30 } | Select-Object -First 1)
$topA = @($ordered | Where-Object { $_.tier -eq "A" -and $_.ageDays -le 30 } | Select-Object -First 1)
$topB = @($ordered | Where-Object { $_.tier -eq "B" -and $_.ageDays -le 30 } | Select-Object -First 1)

if ($topS.Count -gt 0) { $lines.Add("- S级代表：" + $topS[0].title + "（" + $topS[0].recency + "）") } else { $lines.Add("- S级代表：暂无") }
if ($topA.Count -gt 0) { $lines.Add("- A级代表：" + $topA[0].title + "（" + $topA[0].recency + "）") } else { $lines.Add("- A级代表：暂无") }
if ($topB.Count -gt 0) { $lines.Add("- B级代表：" + $topB[0].title + "（" + $topB[0].recency + "）") } else { $lines.Add("- B级代表：暂无") }
$lines.Add("- C级说明：主要为低证据或受限来源，默认不展开。")
$lines.Add("--------------------------")

$lines.Add("【今天只做这2件事】")
$action1 = if ($focus.Count -gt 0) { $focus[0].llmAction } else { "复盘今天信息，并等待明日新增。" }
$action2 = "把历史参考内容和今日增量分开看，避免被旧内容占用注意力。"
$lines.Add("- " + $action1)
$lines.Add("- " + $action2)

Set-Content -Path $reportPath -Value ($lines -join "`r`n") -Encoding UTF8
Write-Output $reportPath
