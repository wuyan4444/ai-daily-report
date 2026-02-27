param(
  [string]$Date = (Get-Date -Format "yyyy-MM-dd"),
  [int]$MaxItemsPerSource = 8,
  [string]$OutputDir = "data"
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillDir = Split-Path -Parent $scriptDir
$targetDir = Join-Path $skillDir $OutputDir
if (!(Test-Path $targetDir)) {
  New-Item -ItemType Directory -Path $targetDir | Out-Null
}

$dateObj = [datetime]::ParseExact($Date, "yyyy-MM-dd", $null)
$nextDay = $dateObj.AddDays(1)
$outputPath = Join-Path $targetDir ("ai-news-" + $Date + ".json")

function Decode-Text {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
  $value = [System.Net.WebUtility]::HtmlDecode($Text)
  $value = $value -replace "<.*?>", " "
  $value = $value -replace "&nbsp;", " "
  $value = $value -replace "\s+", " "
  return $value.Trim()
}

function In-DateWindow {
  param([datetime]$PublishedLocal, [datetime]$StartDate, [datetime]$NextDate)
  if ($null -eq $PublishedLocal) { return $true }
  return ($PublishedLocal -ge $StartDate -and $PublishedLocal -lt $NextDate)
}

function Add-Item {
  param(
    [ref]$Items,
    [string]$SourceLabel,
    [string]$Query,
    [string]$Title,
    [string]$Link,
    [datetime]$PublishedLocal,
    [string]$Snippet
  )
  if ([string]::IsNullOrWhiteSpace($Title) -or [string]::IsNullOrWhiteSpace($Link)) { return }

  $sourceHost = ""
  try { $sourceHost = ([System.Uri]$Link).Host } catch {}

  $entry = [ordered]@{
    source_label = $SourceLabel
    query = $Query
    title = (Decode-Text -Text $Title)
    link = $Link.Trim()
    source_host = $sourceHost
    published_at_local = if ($null -eq $PublishedLocal) { "" } else { $PublishedLocal.ToString("yyyy-MM-dd HH:mm:ss") }
    snippet = (Decode-Text -Text $Snippet)
    collected_at_local = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  }
  $Items.Value += [pscustomobject]$entry
}

function Get-TencentArticleSnippet {
  param([string]$ArticleUrl)
  try {
    $html = (Invoke-WebRequest -Uri $ArticleUrl -TimeoutSec 20 -UseBasicParsing).Content
  } catch {
    return ""
  }

  $paragraphs = [regex]::Matches($html, '<p[^>]*>(.*?)</p>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
  $clean = @()
  foreach ($p in $paragraphs) {
    $line = Decode-Text -Text $p.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.Length -lt 12) { continue }
    if ($line -match "阅读全文|腾讯研究院|微信|视频号") { continue }
    $clean += $line
    if ($clean.Count -ge 4) { break }
  }
  if ($clean.Count -eq 0) { return "" }
  return ($clean -join "; ")
}

function Collect-TencentTisi {
  param(
    [datetime]$StartDate,
    [datetime]$NextDate,
    [int]$Limit
  )

  $result = @()
  $pages = @(
    "https://tisi.org/ais/",
    "https://tisi.org/ais/2/",
    "https://tisi.org/ais/3/"
  )

  foreach ($pageUrl in $pages) {
    $html = ""
    try {
      $html = (Invoke-WebRequest -Uri $pageUrl -TimeoutSec 20 -UseBasicParsing).Content
    } catch {
      Write-Warning ("Tencent page fetch failed: " + $pageUrl + " - " + $_.Exception.Message)
      continue
    }

    $blocks = [regex]::Matches($html, '<h3 class="elementor-post__title">.*?</article>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    foreach ($b in $blocks) {
      $block = $b.Value

      $linkMatch = [regex]::Match($block, 'href="(https://tisi.org/\d+/)"')
      $titleMatch = [regex]::Match($block, '<h3 class="elementor-post__title">\s*<a [^>]*>\s*(.*?)\s*</a>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
      $dateMatch = [regex]::Match($block, '<span class="elementor-post-date">\s*([0-9]{4}-[0-9]{2}-[0-9]{2})\s*</span>')
      if (-not $linkMatch.Success -or -not $titleMatch.Success) { continue }

      $publishedLocal = $null
      if ($dateMatch.Success) {
        try { $publishedLocal = [datetime]::ParseExact($dateMatch.Groups[1].Value, "yyyy-MM-dd", $null) } catch {}
      }

      $title = Decode-Text -Text $titleMatch.Groups[1].Value
      $isDailyDigest = ($title -match "AI每日速递|每日速递|每日动态|九宫格")

      $link = $linkMatch.Groups[1].Value
      $snippet = Get-TencentArticleSnippet -ArticleUrl $link
      $result += [pscustomobject]@{
        source_label = "腾讯研究院 AI&S"
        query = "https://tisi.org/ais/"
        title = $title
        link = $link
        published_local = $publishedLocal
        snippet = $snippet
        is_daily_digest = $isDailyDigest
      }
    }
  }

  $ordered = @(
    $result |
      Sort-Object `
        @{ Expression = { if ($_.is_daily_digest) { 1 } else { 0 } }; Descending = $true }, `
        @{ Expression = { if ($null -eq $_.published_local) { [datetime]::MinValue } else { $_.published_local } }; Descending = $true }, `
        @{ Expression = { $_.title }; Descending = $false }
  )

  return @($ordered | Select-Object -First $Limit)
}

$allItems = @()
$tencentItems = @(Collect-TencentTisi -StartDate $dateObj -NextDate $nextDay -Limit $MaxItemsPerSource)
foreach ($it in $tencentItems) {
  Add-Item -Items ([ref]$allItems) -SourceLabel $it.source_label -Query $it.query -Title $it.title -Link $it.link -PublishedLocal $it.published_local -Snippet $it.snippet
}

$payload = [ordered]@{
  date = $Date
  generated_at_local = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  item_count = $allItems.Count
  items = $allItems
}

$payload | ConvertTo-Json -Depth 6 | Set-Content -Path $outputPath -Encoding UTF8
Write-Output $outputPath
