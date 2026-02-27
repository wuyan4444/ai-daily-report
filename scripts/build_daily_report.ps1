param(
  [string]$Date = (Get-Date -Format "yyyy-MM-dd"),
  [string]$InputDir = "data",
  [string]$OutputDir = "reports",
  [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $scriptDir
$inputPath = Join-Path (Join-Path $repoDir $InputDir) ("ai-news-" + $Date + ".json")
$outputRoot = Join-Path $repoDir $OutputDir
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

function NText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
  $v = [System.Net.WebUtility]::HtmlDecode($Text)
  $v = $v -replace "\s+", " "
  return $v.Trim()
}

function Get-OptionalText {
  param($Obj,[string]$Name)
  if ($null -eq $Obj) { return "" }
  if ($null -eq $Obj.PSObject.Properties[$Name]) { return "" }
  return NText -Text ([string]$Obj.PSObject.Properties[$Name].Value)
}

function Parse-LocalTime {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  try { return [datetime]::Parse($Text) } catch { return $null }
}

function Get-AgeDays {
  param([datetime]$Published,[datetime]$RefDate)
  if ($null -eq $Published) { return 9999 }
  return [int](($RefDate.Date - $Published.Date).TotalDays)
}

function Get-RecencyLabel {
  param([int]$AgeDays)
  if ($AgeDays -le 0) { return "今日" }
  if ($AgeDays -eq 1) { return "昨日" }
  if ($AgeDays -le 7) { return ("近{0}天" -f $AgeDays) }
  if ($AgeDays -le 30) { return ("近{0}天" -f $AgeDays) }
  return ("{0}天前" -f $AgeDays)
}

function Normalize-Confidence {
  param([string]$Value)
  $v = NText -Text $Value
  if ($v -eq "高" -or $v -eq "中" -or $v -eq "低") { return $v }
  return "中"
}

$raw = Get-Content -Path $inputPath -Raw -Encoding UTF8
$doc = $raw | ConvertFrom-Json
$items = @($doc.items)
$collectionWarnings = @()
if ($null -ne $doc.PSObject.Properties["collection_warnings"]) {
  foreach ($w in @($doc.collection_warnings)) {
    $v = NText -Text ([string]$w)
    if (-not [string]::IsNullOrWhiteSpace($v)) { $collectionWarnings += $v }
  }
}

$reportDate = [datetime]::ParseExact($Date, "yyyy-MM-dd", $null)
$seen = @{}
$cards = @()

foreach ($i in $items) {
  $title = NText -Text ([string]$i.title)
  if ([string]::IsNullOrWhiteSpace($title)) { continue }

  $key = $title.ToLowerInvariant()
  if ($seen.ContainsKey($key)) { continue }
  $seen[$key] = $true

  $source = NText -Text ([string]$i.source_label)
  $link = NText -Text ([string]$i.link)
  $publishedText = NText -Text ([string]$i.published_at_local)
  $published = Parse-LocalTime -Text $publishedText
  $ageDays = Get-AgeDays -Published $published -RefDate $reportDate

  $atomicFact = Get-OptionalText -Obj $i -Name "llm_atomic_fact"
  if ([string]::IsNullOrWhiteSpace($atomicFact)) { $atomicFact = Get-OptionalText -Obj $i -Name "llm_summary" }
  if ([string]::IsNullOrWhiteSpace($atomicFact)) { $atomicFact = NText -Text ([string]$i.snippet) }
  if ([string]::IsNullOrWhiteSpace($atomicFact)) { $atomicFact = $title }

  $importance = Get-OptionalText -Obj $i -Name "llm_importance"
  if ([string]::IsNullOrWhiteSpace($importance)) { $importance = "该信息提供了可追踪的变化信号。" }

  $evidenceNote = Get-OptionalText -Obj $i -Name "llm_evidence_note"
  if ([string]::IsNullOrWhiteSpace($evidenceNote)) { $evidenceNote = "基于视频字幕提取结果，建议打开原视频核验关键表述。" }

  $careerHint = Get-OptionalText -Obj $i -Name "llm_career_hint"
  if ([string]::IsNullOrWhiteSpace($careerHint)) { $careerHint = "转成岗位能力要求，再决定学习投入。" }

  $investHint = Get-OptionalText -Obj $i -Name "llm_invest_hint"
  if ([string]::IsNullOrWhiteSpace($investHint)) { $investHint = "优先看产业链受益路径，不做买卖建议。" }

  $todayAction = Get-OptionalText -Obj $i -Name "llm_today_action"
  if ([string]::IsNullOrWhiteSpace($todayAction)) { $todayAction = "把这条信息改写成四行事实卡片。" }

  $unknowns = Get-OptionalText -Obj $i -Name "llm_unknowns"
  if ([string]::IsNullOrWhiteSpace($unknowns)) { $unknowns = "关键细节仍需结合原文进一步确认。" }

  $confidence = Normalize-Confidence -Value (Get-OptionalText -Obj $i -Name "llm_confidence")

  $score = 0
  switch ($confidence) {
    "高" { $score += 30 }
    "中" { $score += 20 }
    default { $score += 10 }
  }
  if ($ageDays -le 1) { $score += 10 }
  elseif ($ageDays -le 7) { $score += 7 }
  elseif ($ageDays -le 30) { $score += 4 }
  elseif ($ageDays -gt 180) { $score -= 5 }

  $cards += [pscustomobject]@{
    title = $title
    source = $source
    link = $link
    ageDays = $ageDays
    recency = Get-RecencyLabel -AgeDays $ageDays
    confidence = $confidence
    atomicFact = $atomicFact
    importance = $importance
    evidenceNote = $evidenceNote
    careerHint = $careerHint
    investHint = $investHint
    todayAction = $todayAction
    unknowns = $unknowns
    score = $score
  }
}

$ordered = @($cards | Sort-Object @{Expression="score";Descending=$true}, @{Expression="ageDays";Descending=$false})
$factCards = @($ordered | Select-Object -First 4)

$overview = @()
if ($null -ne $doc.PSObject.Properties["llm_distilled_overview"]) {
  foreach ($x in @($doc.llm_distilled_overview)) {
    $v = NText -Text ([string]$x)
    if (-not [string]::IsNullOrWhiteSpace($v)) { $overview += $v }
  }
}
if ($overview.Count -eq 0) {
  if ($cards.Count -eq 0) {
    $overview = @("今日没有可用字幕视频，未生成事实卡片。", "请优先替换为带字幕的频道或视频。")
  } else {
    $overview = @("今天优先看已核验事实，再决定行动。", "老信息只做背景，不直接触发动作。")
  }
}

$signals = @()
if ($null -ne $doc.PSObject.Properties["llm_theme_signals"]) {
  foreach ($s in @($doc.llm_theme_signals)) {
    $signal = NText -Text ([string]$s.signal)
    if ([string]::IsNullOrWhiteSpace($signal)) { continue }
    $signals += [pscustomobject]@{
      signal = $signal
      why = NText -Text ([string]$s.why)
      how = NText -Text ([string]$s.how_to_use)
    }
  }
}
if ($signals.Count -eq 0) {
  if ($cards.Count -eq 0) {
    $signals = @([pscustomobject]@{
      signal = "采集阶段未获得可提纯视频内容"
      why = "当前配置频道近期视频缺少可用字幕。"
      how = "调整频道池，优先保留字幕稳定的频道。"
    })
  } else {
    $signals = @([pscustomobject]@{
      signal = "今天未形成高一致性的跨条信号"
      why = "当前素材时间分布较散，信息增量有限。"
      how = "先维护来源与核验清单，等待下一批增量。"
    })
  }
}

$decisionCards = @()
if ($null -ne $doc.PSObject.Properties["llm_decision_cards"]) {
  foreach ($c in @($doc.llm_decision_cards)) {
    $ifText = NText -Text ([string]$c.if)
    $thenText = NText -Text ([string]$c.then)
    if ([string]::IsNullOrWhiteSpace($ifText) -or [string]::IsNullOrWhiteSpace($thenText)) { continue }
    $decisionCards += [pscustomobject]@{
      if = $ifText
      then = $thenText
      metric = NText -Text ([string]$c.metric)
    }
  }
}
if ($decisionCards.Count -eq 0) {
  if ($cards.Count -eq 0) {
    $decisionCards = @([pscustomobject]@{
      if = "如果某频道连续3条视频无可用字幕"
      then = "将该频道移出自动提纯清单，改为人工抽样关注"
      metric = "无字幕视频占比"
    })
  } else {
    $decisionCards = @([pscustomobject]@{
      if = "如果同一主题在一周内连续出现并且原文可核验"
      then = "将其加入重点学习/研究列表并安排时间"
      metric = "连续出现次数、原文可核验程度"
    })
  }
}

$noiseFilters = @()
if ($null -ne $doc.PSObject.Properties["llm_noise_filters"]) {
  foreach ($n in @($doc.llm_noise_filters)) {
    $v = NText -Text ([string]$n)
    if (-not [string]::IsNullOrWhiteSpace($v)) { $noiseFilters += $v }
  }
}
if ($noiseFilters.Count -eq 0) {
  if ($cards.Count -eq 0) {
    $noiseFilters = @("无字幕视频不进入自动提纯。")
  } else {
    $noiseFilters = @(
      "只含观点没有出处的内容先放观察池。",
      "时间过旧且无新增证据的内容降权处理。"
    )
  }
}

$todayPlan = @()
if ($null -ne $doc.PSObject.Properties["llm_today_plan"]) {
  foreach ($a in @($doc.llm_today_plan)) {
    $v = NText -Text ([string]$a)
    if (-not [string]::IsNullOrWhiteSpace($v)) { $todayPlan += $v }
  }
}
if ($todayPlan.Count -eq 0) {
  if ($cards.Count -eq 0) {
    $todayPlan = @("替换至少1个频道为字幕稳定来源。", "手动补充1条带字幕视频链接做验证。")
  } else {
    $todayPlan = @("核验1条最相关信息并写成事实卡片。", "把今天不确定信息整理到明日待验证列表。")
  }
} elseif ($todayPlan.Count -eq 1) {
  $todayPlan += "把今天不确定信息整理到明日待验证列表。"
} elseif ($todayPlan.Count -gt 2) {
  $todayPlan = @($todayPlan | Select-Object -First 2)
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("【提纯总览】")
foreach ($x in ($overview | Select-Object -First 2)) {
  $lines.Add("- " + $x)
}
$lines.Add("- 方法：事实提纯 -> 证据说明 -> 模式信号 -> 行动清单")
$lines.Add("--------------------------")

if ($collectionWarnings.Count -gt 0) {
  $lines.Add("【采集告警】")
  $lines.Add("- 以下提醒表示该频道近期缺少可用字幕，当前自动提纯方案不适配。")
  foreach ($w in ($collectionWarnings | Select-Object -First 8)) {
    $lines.Add("- " + $w)
  }
  $lines.Add("--------------------------")
}

$lines.Add("【模式信号】")
foreach ($s in ($signals | Select-Object -First 3)) {
  $lines.Add("- 信号：" + $s.signal)
  if (-not [string]::IsNullOrWhiteSpace($s.why)) { $lines.Add("  原因：" + $s.why) }
  if (-not [string]::IsNullOrWhiteSpace($s.how)) { $lines.Add("  用法：" + $s.how) }
}
$lines.Add("--------------------------")

$lines.Add("【事实卡片】")
if ($factCards.Count -eq 0) {
  $lines.Add("- 今日无可用字幕视频，未生成事实卡片。")
} else {
  foreach ($c in $factCards) {
    $lines.Add("- [" + $c.recency + "][置信" + $c.confidence + "] " + $c.title)
    $lines.Add("  原子事实：" + $c.atomicFact)
    $lines.Add("  重要性：" + $c.importance)
    $lines.Add("  证据说明：" + $c.evidenceNote)
    $lines.Add("  职业借鉴：" + $c.careerHint)
    $lines.Add("  投资观察：" + $c.investHint)
    $lines.Add("  今日动作：" + $c.todayAction)
    $lines.Add("  未知点：" + $c.unknowns)
    $lines.Add("  来源：" + $c.source + " | " + $c.link)
    $lines.Add("")
  }
}
$lines.Add("--------------------------")

$lines.Add("【决策卡片】")
foreach ($d in ($decisionCards | Select-Object -First 3)) {
  $lines.Add("- 如果：" + $d.if)
  $lines.Add("  那么：" + $d.then)
  if (-not [string]::IsNullOrWhiteSpace($d.metric)) { $lines.Add("  观察指标：" + $d.metric) }
}
$lines.Add("--------------------------")

$lines.Add("【去噪规则】")
foreach ($n in ($noiseFilters | Select-Object -First 3)) {
  $lines.Add("- " + $n)
}
$lines.Add("--------------------------")

$lines.Add("【今日执行清单】")
$lines.Add("- " + $todayPlan[0])
$lines.Add("- " + $todayPlan[1])

Set-Content -Path $reportPath -Value ($lines -join "`r`n") -Encoding UTF8
Write-Output $reportPath
