# AI Fitness Coach

An AI personal trainer delivered through the **Vaux** iOS app, powered by
Claude and backed by Supabase. It ingests Apple Health recovery/workout data,
tracks workout state, and coaches you through sessions with memory across days.

## What It Does

- Shows a morning briefing with recovery context and the planned session
- Live workout coaching in-app, with set logging and rest timers
- Tracks mesocycle position and completed sessions in Supabase
- Ingests Apple Health recovery metrics and workout exports through webhooks
- Surfaces PRs, fatigue signals, and exercise substitutions

## Architecture

The repo has two parts: a Python backend that talks to Claude and Supabase, and
the **Vaux** SwiftUI iOS app that consumes it.

### Backend (Python)

- `coach.py`: main orchestration and chat flow
- `webhook.py`: Flask server exposing the app chat API and the Apple Health webhook
- `memory.py`: Supabase-backed memory and recovery persistence
- `workout.py`: active workout state, set logging, and PR checks
- `exercises.py`: exercise library lookup and fuzzy matching
- `parse_health.py`: Apple Health recovery payload parser
- `parse_workouts.py`: Apple Health workout payload parser
- `scheduler.py`: morning briefing job

### iOS App (Vaux)

- `Vaux/Vaux.xcodeproj`: Xcode project
- `Vaux/Vaux/Views`: SwiftUI screens (Dashboard, Briefing, Coach, Workout, History, Settings)
- `Vaux/Vaux/Services`: ChatService, HealthKitManager, SupabaseClient, etc.
- `Vaux/Vaux/Config.swift`: backend URL, Supabase URL/key, and API token

The current stack:

- Anthropic for coach responses
- Supabase for memory, recovery, sessions, and workout state
- Apple Health / Health Auto Export style webhook payloads for data ingestion
- Flask JSON API consumed by the iOS app

## Requirements

- Python 3.11+ (for the backend)
- Xcode 15+ and an iOS 17+ device or simulator (for the Vaux app)
- An Anthropic API key
- A Supabase project with the required tables
- Optional: a public HTTPS URL for Apple Health webhooks

Install backend dependencies:

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
- `APP_API_TOKEN` — shared secret the iOS app sends as `Authorization: Bearer <token>`
- `HEALTH_WEBHOOK_TOKEN` — shared secret the Apple Health webhook sends as `X-Health-Token`
- `APP_TIMEZONE` (optional, defaults to `Australia/Sydney`)
- `PORT` (optional, defaults to `5000`)

## System Prompt

The coach reads from `system_prompt.txt` in the repo root. It already exists in
the repo, so no extra setup is needed unless you want to edit the coach
behaviour.

## Running The Backend

Run the webhook / API server:

```bash
python webhook.py
```

This exposes:

- `POST /api/chat` — chat endpoint used by the Vaux app
- `POST /apple-health` — Apple Health webhook
- `GET  /status` — health check

Run the scheduler job manually:

```bash
python scheduler.py
```

Interactive terminal mode (handy for local debugging of coach responses):

```bash
python coach.py terminal
```

Send a morning briefing to the configured channel:

```bash
python coach.py morning
```

Run regression tests:

```bash
python -m unittest discover -s tests -v
```

## Running The Vaux iOS App

1. Open `Vaux/Vaux.xcodeproj` in Xcode.
2. In `Vaux/Vaux/Config.swift`, confirm or override:
   - `backendURL` — your deployed `/api/chat` URL
   - `appAPIToken` — must match `APP_API_TOKEN` on the backend
   - `supabaseURL` / `supabaseKey`
3. Select a simulator or device and run.
4. On first launch, grant HealthKit permissions so recovery and workout data
   can sync.

The app talks to the backend over HTTPS and reads/writes history directly from
Supabase.

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

Example local test:

```bash
curl -X POST http://localhost:5000/apple-health \
  -H "Content-Type: application/json" \
  -H "X-Health-Token: your-token" \
  -d '{"date":"2026-03-17","sleep_hours":7.2,"hrv":58,"resting_hr":52}'
```

## Workout Flow

Typical flow inside the Vaux app:

1. Start a session from the dashboard (or by sending a start message such as
   `starting push` in the coach chat).
2. During the session, log sets either through the Set Log input or by typing
   free-form messages like:
   - `110kg x8`
   - `110 x 10 RPE8`
   - `done 100 x 12 @8`
3. End the session with:
   - PPL days: `session done`, `workout complete`, or similar
   - Cardio/yoga days: `workout wrapped`

When workout mode is active, the backend logs sets automatically and maintains
session state in Supabase, which the iOS app mirrors via `WorkoutService`.

## Notes On Current Behaviour

- If Supabase is unavailable, some paths fall back to defaults or mock recovery
  data.
- `coach.py terminal` uses the same Claude-backed logic as the live app.
- The iOS app is the primary interface. Legacy Telegram delivery code still
  exists in the backend but is no longer part of the supported flow.

## Troubleshooting

**Imports fail on startup**
Check that you installed `requirements.txt` into the Python environment you are
actually using.

**Coach cannot answer**
Check `ANTHROPIC_API_KEY` and make sure `system_prompt.txt` exists.

**App shows "Unauthorized" from the coach**
Check that `APP_API_TOKEN` on the backend matches `appAPIToken` in the Vaux
`Config.swift`.

**No memory or recovery data**
Check `SUPABASE_URL`, `SUPABASE_KEY`, and the expected Supabase tables.

**Apple Health posts are rejected**
Check that the `X-Health-Token` header matches `HEALTH_WEBHOOK_TOKEN`.

**Morning briefing fails**
Run `python scheduler.py` directly and inspect the logged exception.
