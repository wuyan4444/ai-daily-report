param(
  [string]$Date = (Get-Date -Format "yyyy-MM-dd"),
  [int]$MaxItemsPerSource = 3,
  [string]$OutputDir = "data",
  [string]$SourcesFile = "config/youtube_channels.json",
  [int]$MaxTranscriptChars = 1000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $scriptDir
$targetDir = Join-Path $repoDir $OutputDir
if (!(Test-Path $targetDir)) {
  New-Item -ItemType Directory -Path $targetDir | Out-Null
}

$outputPath = Join-Path $targetDir ("ai-news-" + $Date + ".json")
$sourcesPath = Join-Path $repoDir $SourcesFile

$script:TranscriptSupportReady = $false
$script:TranscriptSupportChecked = $false

function Decode-Text {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
  $value = [System.Net.WebUtility]::HtmlDecode($Text)
  $value = $value -replace "<.*?>", " "
  $value = $value -replace "&nbsp;", " "
  $value = $value -replace "\s+", " "
  return $value.Trim()
}

function Parse-DateSafe {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  try { return [datetime]::Parse($Text).ToLocalTime() } catch { return $null }
}

function Get-OptionalText {
  param($Obj,[string]$Name)
  if ($null -eq $Obj) { return "" }
  if ($null -eq $Obj.PSObject.Properties[$Name]) { return "" }
  return Decode-Text -Text ([string]$Obj.PSObject.Properties[$Name].Value)
}

function Ensure-DefaultSourcesFile {
  param([string]$Path)

  if (Test-Path $Path) { return }

  $parent = Split-Path -Parent $Path
  if (!(Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  $default = @{
    channels = @(
      @{ name = "OpenAI"; handle = "@OpenAI" },
      @{ name = "Google DeepMind"; handle = "@GoogleDeepMind" }
    )
  }

  $default | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
  Write-Warning ("Created default YouTube sources file: " + $Path)
}

function Load-YoutubeSources {
  param([string]$Path)

  Ensure-DefaultSourcesFile -Path $Path
  $raw = Get-Content -Path $Path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "YouTube sources file is empty: $Path"
  }

  $obj = $raw | ConvertFrom-Json
  $channels = @()
  if ($null -ne $obj.PSObject.Properties["channels"]) {
    $channels = @($obj.channels)
  }

  if ($channels.Count -eq 0) {
    throw "No channels configured in $Path"
  }

  return $channels
}

function Resolve-YoutubeChannelId {
  param($Source)

  $id = Get-OptionalText -Obj $Source -Name "channel_id"
  if ($id -match '^UC[0-9A-Za-z_-]{20,}$') { return $id }

  $url = Get-OptionalText -Obj $Source -Name "url"
  $handle = Get-OptionalText -Obj $Source -Name "handle"

  if ([string]::IsNullOrWhiteSpace($url) -and -not [string]::IsNullOrWhiteSpace($handle)) {
    if (-not $handle.StartsWith("@")) { $handle = "@" + $handle }
    $url = "https://www.youtube.com/" + $handle
  }

  if ([string]::IsNullOrWhiteSpace($url)) { return "" }

  $html = ""
  try {
    $html = (Invoke-WebRequest -Uri $url -TimeoutSec 30 -UseBasicParsing).Content
  } catch {
    return ""
  }

  $m = [regex]::Match($html, '"channelId":"(UC[0-9A-Za-z_-]{20,})"')
  if ($m.Success) { return $m.Groups[1].Value }

  $m = [regex]::Match($html, 'feeds/videos\.xml\?channel_id=(UC[0-9A-Za-z_-]{20,})')
  if ($m.Success) { return $m.Groups[1].Value }

  $m = [regex]::Match($url, '/channel/(UC[0-9A-Za-z_-]{20,})')
  if ($m.Success) { return $m.Groups[1].Value }

  return ""
}

function Ensure-TranscriptSupport {
  if ($script:TranscriptSupportChecked) { return $script:TranscriptSupportReady }
  $script:TranscriptSupportChecked = $true

  $python = Get-Command python -ErrorAction SilentlyContinue
  if ($null -eq $python) {
    $script:TranscriptSupportReady = $false
    return $false
  }

  try {
    & python --version *> $null
    if ($LASTEXITCODE -ne 0) {
      $script:TranscriptSupportReady = $false
      return $false
    }
    & python -m pip install --quiet youtube-transcript-api *> $null
    if ($LASTEXITCODE -ne 0) {
      $script:TranscriptSupportReady = $false
      return $false
    }
    & python -c "import youtube_transcript_api" *> $null
    if ($LASTEXITCODE -ne 0) {
      $script:TranscriptSupportReady = $false
      return $false
    }
  } catch {
    $script:TranscriptSupportReady = $false
    return $false
  }

  $script:TranscriptSupportReady = $true
  return $true
}

function Get-YoutubeTranscriptSnippet {
  param(
    [string]$VideoId,
    [int]$MaxChars
  )

  if ([string]::IsNullOrWhiteSpace($VideoId)) { return "" }
  if (-not (Ensure-TranscriptSupport)) { return "" }

  $py = @'
import sys
from youtube_transcript_api import YouTubeTranscriptApi

def normalize(items):
    out = []
    for x in items:
        text = ""
        if isinstance(x, dict):
            text = x.get("text", "")
        else:
            text = getattr(x, "text", "")
        text = text.replace("\n", " ").strip()
        if text:
            out.append(text)
    return " ".join(out).strip()

video_id = sys.argv[1]
max_chars = int(sys.argv[2])
langs = ["zh-Hans", "zh-CN", "zh", "en"]
text = ""

try:
    api = YouTubeTranscriptApi()
    data = api.fetch(video_id, languages=langs)
    text = normalize(data)
except Exception:
    try:
        data = YouTubeTranscriptApi.get_transcript(video_id, languages=langs)
        text = normalize(data)
    except Exception:
        text = ""

print(text[:max_chars])
'@

  try {
    $text = $py | python - $VideoId $MaxChars
  } catch {
    return ""
  }

  return Decode-Text -Text ([string]$text)
}

function Add-Item {
  param(
    [ref]$Items,
    [string]$SourceLabel,
    [string]$Query,
    [string]$Title,
    [string]$Link,
    [datetime]$PublishedLocal,
    [string]$Snippet,
    [string]$ChannelName,
    [string]$VideoId
  )

  if ([string]::IsNullOrWhiteSpace($Title) -or [string]::IsNullOrWhiteSpace($Link)) { return }

  $entry = [ordered]@{
    source_label = $SourceLabel
    query = $Query
    title = Decode-Text -Text $Title
    link = $Link.Trim()
    source_host = "youtube.com"
    channel_name = Decode-Text -Text $ChannelName
    video_id = Decode-Text -Text $VideoId
    content_type = "video"
    transcript_available = $true
    published_at_local = if ($null -eq $PublishedLocal) { "" } else { $PublishedLocal.ToString("yyyy-MM-dd HH:mm:ss") }
    snippet = Decode-Text -Text $Snippet
    collected_at_local = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  }

  $Items.Value += [pscustomobject]$entry
}

function Collect-YoutubeChannelItems {
  param(
    [string]$ChannelId,
    [string]$ChannelName,
    [int]$Limit,
    [int]$TranscriptChars
  )

  $feedUrl = "https://www.youtube.com/feeds/videos.xml?channel_id=" + $ChannelId
  $xmlText = ""

  try {
    $xmlText = (Invoke-WebRequest -Uri $feedUrl -TimeoutSec 30 -UseBasicParsing).Content
  } catch {
    $msg = "Channel '$ChannelName' fetch failed: $($_.Exception.Message)"
    Write-Warning $msg
    return [pscustomobject]@{
      items = @()
      scanned = 0
      with_subtitle = 0
      without_subtitle = 0
      warning = $msg
    }
  }

  [xml]$doc = $xmlText
  $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  $ns.AddNamespace("atom", "http://www.w3.org/2005/Atom")
  $ns.AddNamespace("yt", "http://www.youtube.com/xml/schemas/2015")

  $entries = $doc.SelectNodes("//atom:entry", $ns)
  if ($null -eq $entries) {
    $msg = "Channel '$ChannelName' has no readable feed entries."
    return [pscustomobject]@{
      items = @()
      scanned = 0
      with_subtitle = 0
      without_subtitle = 0
      warning = $msg
    }
  }

  $rows = @()
  $scanLimit = [Math]::Max($Limit, 5)
  $scanned = 0
  $withSubtitle = 0
  $withoutSubtitle = 0

  foreach ($entry in $entries) {
    if ($scanned -ge $scanLimit) { break }
    $scanned += 1

    $titleNode = $entry.SelectSingleNode("atom:title", $ns)
    $videoNode = $entry.SelectSingleNode("yt:videoId", $ns)
    $publishedNode = $entry.SelectSingleNode("atom:published", $ns)

    $title = if ($null -eq $titleNode) { "" } else { $titleNode.InnerText }
    $videoId = if ($null -eq $videoNode) { "" } else { $videoNode.InnerText }
    if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($videoId)) { continue }

    $published = if ($null -eq $publishedNode) { $null } else { Parse-DateSafe -Text $publishedNode.InnerText }
    $link = "https://www.youtube.com/watch?v=" + $videoId
    $transcript = Get-YoutubeTranscriptSnippet -VideoId $videoId -MaxChars $TranscriptChars

    if ([string]::IsNullOrWhiteSpace($transcript) -or $transcript.Length -lt 40) {
      $withoutSubtitle += 1
      continue
    }
    $withSubtitle += 1

    if ($rows.Count -ge $Limit) { continue }
    $rows += [pscustomobject]@{
      source_label = "YouTube"
      query = $feedUrl
      title = $title
      link = $link
      published_local = $published
      snippet = $transcript
      channel_name = $ChannelName
      video_id = $videoId
    }
  }

  $warning = ""
  if ($scanned -gt 0 -and $withSubtitle -eq 0) {
    $warning = "Channel '$ChannelName' has no usable subtitles in recent videos and is not suitable for this automation."
  } elseif ($withoutSubtitle -gt 0) {
    $warning = "Channel '$ChannelName' has $withoutSubtitle video(s) without usable subtitles and they were skipped."
  }

  return [pscustomobject]@{
    items = @($rows)
    scanned = $scanned
    with_subtitle = $withSubtitle
    without_subtitle = $withoutSubtitle
    warning = $warning
  }
}

$allItems = @()
$collectionWarnings = New-Object System.Collections.Generic.List[string]
$sourceStats = @()
$sources = @(Load-YoutubeSources -Path $sourcesPath)

foreach ($src in $sources) {
  $name = Get-OptionalText -Obj $src -Name "name"
  if ([string]::IsNullOrWhiteSpace($name)) { $name = "YouTube Channel" }

  $channelId = Resolve-YoutubeChannelId -Source $src
  if ([string]::IsNullOrWhiteSpace($channelId)) {
    $warn = "Channel '$name' channel_id cannot be resolved; skipped."
    Write-Warning $warn
    $collectionWarnings.Add($warn)
    $sourceStats += [pscustomobject]@{
      channel_name = $name
      channel_id = ""
      scanned = 0
      with_subtitle = 0
      without_subtitle = 0
      kept = 0
    }
    continue
  }

  $result = Collect-YoutubeChannelItems -ChannelId $channelId -ChannelName $name -Limit $MaxItemsPerSource -TranscriptChars $MaxTranscriptChars
  if (-not [string]::IsNullOrWhiteSpace([string]$result.warning)) {
    $collectionWarnings.Add([string]$result.warning)
  }

  $items = @($result.items)
  $sourceStats += [pscustomobject]@{
    channel_name = $name
    channel_id = $channelId
    scanned = [int]$result.scanned
    with_subtitle = [int]$result.with_subtitle
    without_subtitle = [int]$result.without_subtitle
    kept = $items.Count
  }

  foreach ($it in $items) {
    Add-Item `
      -Items ([ref]$allItems) `
      -SourceLabel ($it.source_label + "/" + $name) `
      -Query $it.query `
      -Title $it.title `
      -Link $it.link `
      -PublishedLocal $it.published_local `
      -Snippet $it.snippet `
      -ChannelName $name `
      -VideoId $it.video_id
  }
}

$sorted = @(
  $allItems |
    Sort-Object @{ Expression = { Parse-DateSafe -Text ([string]$_.published_at_local) }; Descending = $true }
)

$seenLinks = @{}
$deduped = @()
foreach ($it in $sorted) {
  $link = [string]$it.link
  if ([string]::IsNullOrWhiteSpace($link)) { continue }
  if ($seenLinks.ContainsKey($link)) { continue }
  $seenLinks[$link] = $true
  $deduped += $it
}

if ($deduped.Count -eq 0) {
  $collectionWarnings.Add("No subtitle-qualified videos were collected today. Replace channels or add subtitle-friendly sources.")
}

$uniqueWarnings = @()
$seenWarn = @{}
foreach ($w in $collectionWarnings) {
  $v = Decode-Text -Text ([string]$w)
  if ([string]::IsNullOrWhiteSpace($v)) { continue }
  if ($seenWarn.ContainsKey($v)) { continue }
  $seenWarn[$v] = $true
  $uniqueWarnings += $v
}

$payload = [ordered]@{
  date = $Date
  generated_at_local = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  item_count = $deduped.Count
  source = "youtube"
  collection_warnings = $uniqueWarnings
  source_stats = $sourceStats
  items = $deduped
}

$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $outputPath -Encoding UTF8
Write-Output $outputPath
