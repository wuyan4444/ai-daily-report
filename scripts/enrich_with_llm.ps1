param(
  [string]$Date = (Get-Date -Format "yyyy-MM-dd"),
  [string]$InputDir = "data",
  [int]$MaxItems = 6,
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
  Write-Error "LLM_API_KEY is required in pure-LLM mode."
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

function Get-OptionalArray {
  param($Obj,[string]$Name)
  if ($null -eq $Obj) { return @() }
  if ($null -eq $Obj.PSObject.Properties[$Name]) { return @() }
  return @($Obj.PSObject.Properties[$Name].Value)
}

function Parse-DateSafe {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  try { return [datetime]::Parse($Text) } catch { return $null }
}

function Normalize-Confidence {
  param([string]$Value)
  $v = NText -Text $Value
  if ($v -eq "高" -or $v -eq "中" -or $v -eq "低") { return $v }
  return "中"
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

  $json = $payload | ConvertTo-Json -Depth 10
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

function Invoke-LlmJsonWithRetry {
  param(
    [string]$Prompt,
    [string]$ApiKey,
    [string]$BaseUrl,
    [string]$Model,
    [int]$RetryCount = 2
  )

  for ($i = 0; $i -le $RetryCount; $i++) {
    $res = Invoke-LlmJson -Prompt $Prompt -ApiKey $ApiKey -BaseUrl $BaseUrl -Model $Model
    if ($null -ne $res) { return $res }
    if ($i -lt $RetryCount) { Start-Sleep -Seconds 2 }
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
$collectionWarnings = @()
if ($null -ne $doc.PSObject.Properties["collection_warnings"]) {
  foreach ($w in @($doc.collection_warnings)) {
    $v = NText -Text ([string]$w)
    if (-not [string]::IsNullOrWhiteSpace($v)) { $collectionWarnings += $v }
  }
}

if ($items.Count -eq 0) {
  $overview = @("今日未采集到可用字幕视频，自动提纯已跳过。")
  foreach ($w in ($collectionWarnings | Select-Object -First 1)) {
    $overview += ("采集提醒：" + $w)
  }

  $doc | Add-Member -NotePropertyName llm_distilled_overview -NotePropertyValue $overview -Force
  $doc | Add-Member -NotePropertyName llm_theme_signals -NotePropertyValue @() -Force
  $doc | Add-Member -NotePropertyName llm_decision_cards -NotePropertyValue @() -Force
  $doc | Add-Member -NotePropertyName llm_noise_filters -NotePropertyValue @("先确保来源有字幕，再进行自动提纯。") -Force
  $doc | Add-Member -NotePropertyName llm_today_plan -NotePropertyValue @("替换或新增至少1个带字幕的YouTube频道。", "手动补充1条带字幕视频链接做验证。") -Force
  $doc | Add-Member -NotePropertyName llm_method -NotePropertyValue "distill-v2-no-items" -Force
  $doc.items = $items
  $doc | ConvertTo-Json -Depth 10 | Set-Content -Path $inputPath -Encoding UTF8
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
  $source = NText -Text ([string]$it.source_label)
  $time = NText -Text ([string]$it.published_at_local)

  $prompt = @"
你是“信息提纯编辑器”。请对单条素材做提纯，只输出 JSON 对象：
{
  "atomic_fact": "15-50字，描述可核验的核心事实",
  "importance": "15-40字，说明为什么重要",
  "evidence_note": "20-50字，说明证据来源与局限",
  "career_hint": "15-35字，对职业发展启发",
  "invest_hint": "15-35字，对投资研究观察（非买卖建议）",
  "today_action": "10-30字，今天可执行的一步",
  "unknowns": "10-30字，尚不确定点",
  "confidence": "高|中|低"
}

要求：
1) 不要输出评级字母，不要输出分数。
2) 若证据不足，要在 evidence_note 和 unknowns 中明确写出。
3) 不要复述空话，不要给宏大判断。

素材：
标题：$title
摘要：$snippet
来源：$source
发布时间：$time
链接：$link
"@

  $parsed = Invoke-LlmJsonWithRetry -Prompt $prompt -ApiKey $LlmApiKey -BaseUrl $LlmBaseUrl -Model $LlmModel
  if ($null -eq $parsed) {
    Write-Warning ("LLM parsing failed for item, fallback applied: " + $title)
    $parsed = [pscustomobject]@{
      atomic_fact = $title
      importance = "该信息提供了可追踪的变化线索。"
      evidence_note = "本条由系统降级生成，请打开原文核验。"
      career_hint = "先抽取岗位相关能力变化再行动。"
      invest_hint = "先看产业链信号，不做买卖建议。"
      today_action = "提炼4行事实卡片并核对原文。"
      unknowns = "关键细节待进一步核验。"
      confidence = "低"
    }
  }

  $atomicFact = Get-OptionalText -Obj $parsed -Name "atomic_fact"
  if ([string]::IsNullOrWhiteSpace($atomicFact)) { $atomicFact = $title }

  $it | Add-Member -NotePropertyName llm_atomic_fact -NotePropertyValue $atomicFact -Force
  $it | Add-Member -NotePropertyName llm_importance -NotePropertyValue (Get-OptionalText -Obj $parsed -Name "importance") -Force
  $it | Add-Member -NotePropertyName llm_evidence_note -NotePropertyValue (Get-OptionalText -Obj $parsed -Name "evidence_note") -Force
  $it | Add-Member -NotePropertyName llm_career_hint -NotePropertyValue (Get-OptionalText -Obj $parsed -Name "career_hint") -Force
  $it | Add-Member -NotePropertyName llm_invest_hint -NotePropertyValue (Get-OptionalText -Obj $parsed -Name "invest_hint") -Force
  $it | Add-Member -NotePropertyName llm_today_action -NotePropertyValue (Get-OptionalText -Obj $parsed -Name "today_action") -Force
  $it | Add-Member -NotePropertyName llm_unknowns -NotePropertyValue (Get-OptionalText -Obj $parsed -Name "unknowns") -Force
  $it | Add-Member -NotePropertyName llm_confidence -NotePropertyValue (Normalize-Confidence -Value (Get-OptionalText -Obj $parsed -Name "confidence")) -Force

  # Keep a compatibility field for older readers.
  $it | Add-Member -NotePropertyName llm_summary -NotePropertyValue $atomicFact -Force
}

$overviewInput = New-Object System.Collections.Generic.List[string]
foreach ($it in ($items | Select-Object -First 8)) {
  $title = NText -Text ([string]$it.title)
  if ([string]::IsNullOrWhiteSpace($title)) { continue }
  $fact = Get-OptionalText -Obj $it -Name "llm_atomic_fact"
  if ([string]::IsNullOrWhiteSpace($fact)) { $fact = NText -Text ([string]$it.snippet) }
  $evidence = Get-OptionalText -Obj $it -Name "llm_evidence_note"
  $confidence = Normalize-Confidence -Value (Get-OptionalText -Obj $it -Name "llm_confidence")
  $overviewInput.Add("- 标题：" + $title + " | 事实：" + $fact + " | 证据说明：" + $evidence + " | 置信：" + $confidence)
}

if ($overviewInput.Count -gt 0) {
  $overviewPrompt = @"
你是“提纯主编”，请对当天素材做跨条提纯，只输出 JSON：
{
  "distilled_overview": ["...","..."],
  "theme_signals": [
    {
      "signal": "趋势信号",
      "why": "为什么值得关注",
      "how_to_use": "如何在工作中使用"
    }
  ],
  "decision_cards": [
    {
      "if": "如果出现什么条件",
      "then": "我该怎么做",
      "metric": "观察指标"
    }
  ],
  "noise_filters": ["今天应过滤的噪音类型"],
  "today_plan": ["今天动作1","今天动作2"]
}

要求：
1) 不要使用字母分级和分数。
2) distilled_overview 最多2条，每条不超过45字。
3) theme_signals 1-3条，必须是跨多条素材共性的信号。
4) decision_cards 1-3条，强调“条件 -> 动作”。
5) today_plan 恰好2条，必须可执行。

素材：
$($overviewInput -join "`r`n")
"@

  $ov = Invoke-LlmJsonWithRetry -Prompt $overviewPrompt -ApiKey $LlmApiKey -BaseUrl $LlmBaseUrl -Model $LlmModel
  if ($null -eq $ov) {
    Write-Warning "LLM distilled overview generation failed, fallback applied."
    $ov = [pscustomobject]@{
      distilled_overview = @("今日提纯生成已降级，建议优先核验原文。")
      theme_signals = @()
      decision_cards = @()
      noise_filters = @("模型输出异常时，先看原文再做判断。")
      today_plan = @("核验1条最相关原文并更新事实卡片。", "把不确定信息放入明日待验证列表。")
    }
  }

  $distilledOverview = @()
  foreach ($x in (Get-OptionalArray -Obj $ov -Name "distilled_overview")) {
    $v = NText -Text ([string]$x)
    if (-not [string]::IsNullOrWhiteSpace($v)) { $distilledOverview += $v }
  }
  if ($distilledOverview.Count -eq 0) {
    $distilledOverview = @("今日暂无高置信新增，优先复盘已验证主线。")
  }

  $themeSignals = @()
  foreach ($p in (Get-OptionalArray -Obj $ov -Name "theme_signals")) {
    $signal = Get-OptionalText -Obj $p -Name "signal"
    if ([string]::IsNullOrWhiteSpace($signal)) { continue }
    $themeSignals += [pscustomobject]@{
      signal = $signal
      why = Get-OptionalText -Obj $p -Name "why"
      how_to_use = Get-OptionalText -Obj $p -Name "how_to_use"
    }
  }

  $decisionCards = @()
  foreach ($c in (Get-OptionalArray -Obj $ov -Name "decision_cards")) {
    $ifText = Get-OptionalText -Obj $c -Name "if"
    $thenText = Get-OptionalText -Obj $c -Name "then"
    if ([string]::IsNullOrWhiteSpace($ifText) -or [string]::IsNullOrWhiteSpace($thenText)) { continue }
    $decisionCards += [pscustomobject]@{
      if = $ifText
      then = $thenText
      metric = Get-OptionalText -Obj $c -Name "metric"
    }
  }

  $noiseFilters = @()
  foreach ($n in (Get-OptionalArray -Obj $ov -Name "noise_filters")) {
    $v = NText -Text ([string]$n)
    if (-not [string]::IsNullOrWhiteSpace($v)) { $noiseFilters += $v }
  }
  if ($noiseFilters.Count -gt 3) { $noiseFilters = @($noiseFilters | Select-Object -First 3) }

  $todayPlan = @()
  foreach ($a in (Get-OptionalArray -Obj $ov -Name "today_plan")) {
    $v = NText -Text ([string]$a)
    if (-not [string]::IsNullOrWhiteSpace($v)) { $todayPlan += $v }
  }
  if ($todayPlan.Count -eq 0) {
    $todayPlan = @("整理1条信息成事实卡片并核验来源。", "将未核实观点放入观察池，不立即行动。")
  } elseif ($todayPlan.Count -eq 1) {
    $todayPlan += "将未核实观点放入观察池，不立即行动。"
  } elseif ($todayPlan.Count -gt 2) {
    $todayPlan = @($todayPlan | Select-Object -First 2)
  }

  $doc | Add-Member -NotePropertyName llm_distilled_overview -NotePropertyValue $distilledOverview -Force
  $doc | Add-Member -NotePropertyName llm_theme_signals -NotePropertyValue $themeSignals -Force
  $doc | Add-Member -NotePropertyName llm_decision_cards -NotePropertyValue $decisionCards -Force
  $doc | Add-Member -NotePropertyName llm_noise_filters -NotePropertyValue $noiseFilters -Force
  $doc | Add-Member -NotePropertyName llm_today_plan -NotePropertyValue $todayPlan -Force
  $doc | Add-Member -NotePropertyName llm_method -NotePropertyValue "distill-v2" -Force
}

$doc.items = $items
$doc | ConvertTo-Json -Depth 10 | Set-Content -Path $inputPath -Encoding UTF8
Write-Output $inputPath
