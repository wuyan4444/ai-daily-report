# ai-daily-report

Cloud-run AI daily report website + Feishu link push.

## What this repo does
- Runs daily at **09:00 China time** (`01:00 UTC`) via GitHub Actions.
- Collects AI updates from **Tencent Research AI&S**.
- Builds a concise Chinese report.
- Generates a web page (`index.html`) and archive page (`report-pages/ai-daily-brief-YYYY-MM-DD.html`).
- Pushes only the report link to Feishu webhook.

## One-time setup

### 1) Enable GitHub Pages
- Repo: `Settings` -> `Pages`
- Source: `Deploy from a branch`
- Branch: `main`
- Folder: `/ (root)`

After a minute, your report URL is:
- `https://wuyan4444.github.io/ai-daily-report/`

### 2) Add Feishu webhook secret
- Repo: `Settings` -> `Secrets and variables` -> `Actions` -> `New repository secret`
- Name: `FEISHU_WEBHOOK_URL`
- Value: your Feishu bot webhook URL

### 3) Enable LLM summary (Required)
This repo now runs in pure-LLM mode. Add these secrets:

- `LLM_API_KEY` (required)
- `LLM_BASE_URL` (optional, default `https://api.openai.com/v1`)
- `LLM_MODEL` (optional, default `gpt-4o-mini`)

Examples:
- OpenAI:
  - `LLM_BASE_URL = https://api.openai.com/v1`
  - `LLM_MODEL = gpt-4o-mini`
- Kimi (Moonshot, OpenAI-compatible endpoint):
  - `LLM_BASE_URL = https://api.moonshot.cn/v1`
  - `LLM_MODEL = moonshot-v1-8k`

If `LLM_API_KEY` is missing, workflow fails by design.

### 4) Trigger once manually
- Repo: `Actions` -> `Daily AI Report` -> `Run workflow`

## Schedule
- Workflow file: `.github/workflows/daily-report.yml`
- Default cron: `0 1 * * *` (UTC)
- Equivalent: every day 09:00 China Standard Time

## Local run (optional)
```powershell
powershell -File scripts/run_cloud_pipeline.ps1
```

## Notes
- This cloud pipeline does not depend on your local computer.
- If Tencent has no new post on that day, the report will include historical reference items.
- To change report style, update `scripts/build_daily_report.ps1` and `scripts/render_report_html.ps1`.
