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
  return Decode-Text -Text ([string]$Obj.PSObject.Properties[$Name].Value
  )
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

  return (Decode-Text -Text ([string]$text))
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
    title = (Decode-Text -Text $Title)
    link = $Link.Trim()
    source_host = "youtube.com"
    channel_name = (Decode-Text -Text $ChannelName)
    video_id = (Decode-Text -Text $VideoId)
    content_type = "video"
    published_at_local = if ($null -eq $PublishedLocal) { "" } else { $PublishedLocal.ToString("yyyy-MM-dd HH:mm:ss") }
    snippet = (Decode-Text -Text $Snippet)
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
    Write-Warning ("YouTube feed fetch failed: " + $ChannelName + " - " + $_.Exception.Message)
    return @()
  }

  [xml]$doc = $xmlText
  $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  $ns.AddNamespace("atom", "http://www.w3.org/2005/Atom")
  $ns.AddNamespace("yt", "http://www.youtube.com/xml/schemas/2015")
  $ns.AddNamespace("media", "http://search.yahoo.com/mrss/")

  $entries = $doc.SelectNodes("//atom:entry", $ns)
  if ($null -eq $entries) { return @() }

  $rows = @()
  $count = 0

  foreach ($entry in $entries) {
    if ($count -ge $Limit) { break }

    $titleNode = $entry.SelectSingleNode("atom:title", $ns)
    $videoNode = $entry.SelectSingleNode("yt:videoId", $ns)
    $publishedNode = $entry.SelectSingleNode("atom:published", $ns)
    $descNode = $entry.SelectSingleNode("media:group/media:description", $ns)

    $title = if ($null -eq $titleNode) { "" } else { $titleNode.InnerText }
    $videoId = if ($null -eq $videoNode) { "" } else { $videoNode.InnerText }
    if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($videoId)) { continue }

    $published = if ($null -eq $publishedNode) { $null } else { Parse-DateSafe -Text $publishedNode.InnerText }
    $link = "https://www.youtube.com/watch?v=" + $videoId

    $description = if ($null -eq $descNode) { "" } else { Decode-Text -Text $descNode.InnerText }
    $transcript = Get-YoutubeTranscriptSnippet -VideoId $videoId -MaxChars $TranscriptChars

    $snippet = ""
    if (-not [string]::IsNullOrWhiteSpace($transcript) -and $transcript.Length -ge 40) {
      $snippet = $transcript
    } elseif (-not [string]::IsNullOrWhiteSpace($description)) {
      $snippet = $description
    } else {
      $snippet = $title
    }

    $rows += [pscustomobject]@{
      source_label = "YouTube"
      query = $feedUrl
      title = $title
      link = $link
      published_local = $published
      snippet = $snippet
      channel_name = $ChannelName
      video_id = $videoId
    }

    $count += 1
  }

  return @($rows)
}

$allItems = @()
$sources = @(Load-YoutubeSources -Path $sourcesPath)

foreach ($src in $sources) {
  $name = Get-OptionalText -Obj $src -Name "name"
  if ([string]::IsNullOrWhiteSpace($name)) { $name = "YouTube Channel" }

  $channelId = Resolve-YoutubeChannelId -Source $src
  if ([string]::IsNullOrWhiteSpace($channelId)) {
    Write-Warning ("Skip source (channel id unresolved): " + $name)
    continue
  }

  $items = @(Collect-YoutubeChannelItems -ChannelId $channelId -ChannelName $name -Limit $MaxItemsPerSource -TranscriptChars $MaxTranscriptChars)
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

if ($allItems.Count -eq 0) {
  Write-Error "No YouTube items collected. Check config/youtube_channels.json or network access."
  exit 1
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

$payload = [ordered]@{
  date = $Date
  generated_at_local = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  item_count = $deduped.Count
  source = "youtube"
  items = $deduped
}

$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $outputPath -Encoding UTF8
Write-Output $outputPath
