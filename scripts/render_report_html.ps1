param(
  [string]$Date = (Get-Date -Format "yyyy-MM-dd"),
  [string]$ReportDir = "reports",
  [string]$OutputDir = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $scriptDir
$reportPath = Join-Path (Join-Path $repoDir $ReportDir) ("ai-daily-brief-" + $Date + ".md")
$outputRoot = if ($OutputDir -eq ".") { $repoDir } else { Join-Path $repoDir $OutputDir }
$reportsDir = Join-Path $outputRoot "report-pages"
if (!(Test-Path $reportsDir)) {
  New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
}

if (!(Test-Path $reportPath)) {
  Write-Error "Report not found: $reportPath"
  exit 1
}

function Escape-Html {
  param([string]$Text)
  if ($null -eq $Text) { return "" }
  return [System.Net.WebUtility]::HtmlEncode($Text)
}

$raw = Get-Content -Path $reportPath -Raw -Encoding UTF8
$lines = @($raw -split "`r?`n")

$sections = New-Object System.Collections.Generic.List[object]
$current = New-Object System.Collections.Generic.List[string]

foreach ($line in $lines) {
  if ($line.Trim() -eq "--------------------------") {
    if ($current.Count -gt 0) {
      $sections.Add([pscustomobject]@{ lines = @($current) })
      $current = New-Object System.Collections.Generic.List[string]
    }
    continue
  }
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $current.Add($line)
}
if ($current.Count -gt 0) {
  $sections.Add([pscustomobject]@{ lines = @($current) })
}

$sectionHtml = New-Object System.Collections.Generic.List[string]
foreach ($s in $sections) {
  $blockLines = @($s.lines)
  if ($blockLines.Count -eq 0) { continue }

  $titleLine = $blockLines[0].Trim()
  $title = $titleLine.TrimStart("【").TrimEnd("】")
  $sectionHtml.Add("<section class='card'>")
  $sectionHtml.Add("<h2>" + (Escape-Html -Text $title) + "</h2>")

  $items = New-Object System.Collections.Generic.List[string]
  $currentItem = ""
  for ($i = 1; $i -lt $blockLines.Count; $i++) {
    $l = $blockLines[$i]
    if ($l.TrimStart().StartsWith("- ")) {
      if (-not [string]::IsNullOrWhiteSpace($currentItem)) { $items.Add($currentItem) }
      $currentItem = $l.TrimStart().Substring(2)
    } else {
      if ([string]::IsNullOrWhiteSpace($currentItem)) {
        $currentItem = $l.Trim()
      } else {
        $currentItem += "`n" + $l.Trim()
      }
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($currentItem)) { $items.Add($currentItem) }

  if ($items.Count -gt 0) {
    $sectionHtml.Add("<ul>")
    foreach ($item in $items) {
      $parts = @($item -split "`n")
      $sectionHtml.Add("<li>")
      if ($parts.Count -gt 0) {
        $sectionHtml.Add("<div class='main'>" + (Escape-Html -Text $parts[0]) + "</div>")
      }
      if ($parts.Count -gt 1) {
        for ($j = 1; $j -lt $parts.Count; $j++) {
          $p = $parts[$j].Trim()
          if ([string]::IsNullOrWhiteSpace($p)) { continue }
          $sectionHtml.Add("<div class='sub'>" + (Escape-Html -Text $p) + "</div>")
        }
      }
      $sectionHtml.Add("</li>")
    }
    $sectionHtml.Add("</ul>")
  }

  $sectionHtml.Add("</section>")
}

$pageTitle = "今日AI简报 " + $Date
$timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

$html = @"
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$pageTitle</title>
  <style>
    :root {
      --bg: #f6f8fb;
      --card: #ffffff;
      --text: #1f2937;
      --muted: #6b7280;
      --accent: #0f766e;
      --line: #e5e7eb;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "PingFang SC", "Microsoft YaHei", "Segoe UI", sans-serif;
      color: var(--text);
      background: linear-gradient(180deg, #edf6ff 0%, var(--bg) 200px);
    }
    .wrap {
      width: min(920px, 92vw);
      margin: 28px auto 48px;
    }
    .hero {
      background: radial-gradient(circle at top right, #ccfbf1, #ffffff 45%);
      border: 1px solid var(--line);
      border-radius: 16px;
      padding: 18px 20px;
      margin-bottom: 14px;
    }
    .hero h1 {
      margin: 0;
      font-size: 24px;
      line-height: 1.3;
    }
    .hero .meta {
      margin-top: 6px;
      color: var(--muted);
      font-size: 13px;
    }
    .card {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 14px;
      padding: 14px 16px;
      margin-bottom: 12px;
      box-shadow: 0 4px 10px rgba(2, 6, 23, 0.03);
    }
    .card h2 {
      margin: 0 0 10px;
      color: var(--accent);
      font-size: 18px;
    }
    ul {
      margin: 0;
      padding-left: 18px;
    }
    li { margin: 8px 0; }
    .main { font-size: 15px; line-height: 1.6; }
    .sub {
      margin-top: 4px;
      font-size: 14px;
      color: var(--muted);
      line-height: 1.6;
    }
    .footer {
      margin-top: 14px;
      color: var(--muted);
      font-size: 12px;
      text-align: center;
    }
    a { color: #0b57d0; text-decoration: none; }
    @media (max-width: 640px) {
      .hero h1 { font-size: 21px; }
      .card h2 { font-size: 17px; }
      .main { font-size: 14px; }
      .sub { font-size: 13px; }
    }
  </style>
</head>
<body>
  <main class="wrap">
    <section class="hero">
      <h1>今日AI简报</h1>
      <div class="meta">日期：$Date | 自动生成时间：$timestamp</div>
    </section>
    $($sectionHtml -join "`r`n    ")
    <div class="footer">Powered by GitHub Actions · Tencent AI&amp;S Source</div>
  </main>
</body>
</html>
"@

$dailyHtmlFileName = "ai-daily-brief-" + $Date + ".html"
$dailyHtmlPath = Join-Path $reportsDir $dailyHtmlFileName
Set-Content -Path $dailyHtmlPath -Value $html -Encoding UTF8

$latestPath = Join-Path $outputRoot "index.html"
Set-Content -Path $latestPath -Value $html -Encoding UTF8

Write-Output $dailyHtmlPath
