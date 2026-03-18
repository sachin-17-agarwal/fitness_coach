# AI Fitness Coach

A Telegram-based AI personal trainer powered by Claude and backed by Supabase.
It ingests Apple Health recovery/workout data, tracks workout state, and coaches
you through sessions with memory across days.

## What It Does

- Sends a morning briefing with recovery context and the planned session
- Supports live workout coaching over Telegram
- Logs completed sets during an active workout
- Tracks mesocycle position and completed sessions in Supabase
- Ingests Apple Health recovery metrics and workout exports through webhooks

## Current Architecture

- `coach.py`: main orchestration and chat flow
- `webhook.py`: Flask server for Telegram and Apple Health webhooks
- `telegram_bot.py`: Telegram delivery helpers
- `memory.py`: Supabase-backed memory and recovery persistence
- `workout.py`: active workout state, set logging, and PR checks
- `parse_health.py`: Apple Health recovery payload parser
- `parse_workouts.py`: Apple Health workout payload parser
- `scheduler.py`: morning briefing job

The current app uses:

- Anthropic for coach responses
- Telegram Bot API for messages
- Supabase for memory, recovery, sessions, and workout state
- Apple Health / Health Auto Export style webhook payloads for data ingestion

## Requirements

- Python 3.11+
- An Anthropic API key
- A Supabase project with the required tables
- A Telegram bot token and your Telegram chat ID
- Optional: a public HTTPS URL for webhooks

Install dependencies:

```bash
pip install -r requirements.txt
```

## Environment Setup

Copy the example file and fill in your values:

```bash
cp .env.example .env
```

Expected variables:

- `ANTHROPIC_API_KEY`
- `SUPABASE_URL`
- `SUPABASE_KEY`
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`
- `HEALTH_WEBHOOK_TOKEN`
- `PORT` (optional, defaults to `5000`)

## System Prompt

The coach reads from `system_prompt.txt` in the repo root.
That file already exists in this repo, so no extra setup is needed unless you want to edit the coach behavior.

## Running Locally

Interactive terminal mode:

```bash
python coach.py terminal
```

Send a morning briefing:

```bash
python coach.py morning
```

Run the webhook server:

```bash
python webhook.py
```

Run the scheduler job manually:

```bash
python scheduler.py
```

Run regression tests:

```bash
python -m unittest discover -s tests -v
```

## Telegram Setup

1. Create a bot with BotFather in Telegram.
2. Put the bot token into `TELEGRAM_BOT_TOKEN`.
3. Put your personal chat ID into `TELEGRAM_CHAT_ID`.
4. Expose your local app with a public HTTPS URL if you want webhook delivery.
5. Point Telegram webhook traffic to:

```text
https://your-domain.example/webhook
```

The app only responds to the configured `TELEGRAM_CHAT_ID`.

## Apple Health Webhook Setup

The recovery endpoint is:

```text
POST /apple-health
```

If `HEALTH_WEBHOOK_TOKEN` is set, send it in the `X-Health-Token` header.

Supported payload styles:

- Flat daily recovery JSON
- Nested Health Auto Export style metrics payload
- Workout payloads under `data.workouts`

Example flat payload:

```json
{
  "date": "2026-03-17",
  "sleep_hours": 7.2,
  "hrv": 58,
  "resting_hr": 52,
  "steps": 8400,
  "exercise_minutes": 62
}
```

Example local test on Windows:

```powershell
curl -X POST http://localhost:5000/apple-health `
  -H "Content-Type: application/json" `
  -H "X-Health-Token: your-token" `
  -d "{\"date\":\"2026-03-17\",\"sleep_hours\":7.2,\"hrv\":58,\"resting_hr\":52}"
```

## Workout Flow

Typical flow over Telegram:

1. Send a start message such as `starting push` or `starting pull`
2. During the session, send set logs like:
   - `110kg x8`
   - `110 x 10 RPE8`
   - `done 100 x 12 @8`
3. End the session with:
   - PPL days: `session done`, `workout complete`, or similar
   - Cardio/yoga days: `workout wrapped`

When workout mode is active, the app attempts to log sets automatically and maintain session state in Supabase.

## Notes On Current Behavior

- If Supabase is unavailable, some paths fall back to defaults or mock recovery data.
- `coach.py terminal` uses the same Claude-backed logic as the live bot.
- Message sending is Telegram-first in the current codebase.
- This README reflects the current code, not the older Twilio/Google Sheets version.

## Troubleshooting

**Imports fail on startup**
Check that you installed `requirements.txt` into the Python environment you are actually using.

**Coach cannot answer**
Check `ANTHROPIC_API_KEY` and make sure `system_prompt.txt` exists.

**No memory or recovery data**
Check `SUPABASE_URL`, `SUPABASE_KEY`, and the expected Supabase tables.

**Telegram messages do not arrive**
Check `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, and webhook configuration.

**Apple Health posts are rejected**
Check that the `X-Health-Token` header matches `HEALTH_WEBHOOK_TOKEN`.

**Morning briefing fails**
Run `python scheduler.py` directly and inspect the logged exception.
