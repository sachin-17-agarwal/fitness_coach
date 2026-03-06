# AI Fitness Coach 🏋️

A WhatsApp-based AI personal trainer powered by Claude. Reads your Apple Health data,
MyFitnessPal nutrition, and workout history — then coaches you like a real trainer would.

---

## What It Does

- **Morning briefing** sent to your WhatsApp every day: recovery status, today's full workout plan with sets/reps/weights/RPE
- **Live session coaching**: message back and forth during your workout, it adjusts set by set
- **Recovery-aware**: uses your sleep and HRV from Apple Health to modify intensity automatically
- **Nutrition-aware**: checks your MyFitnessPal data and adjusts recommendations
- **Remembers everything**: session history, mesocycle position, long-term notes

---

## Setup (Step by Step)

### Step 1 — Install dependencies
```bash
pip install -r requirements.txt
```

### Step 2 — Set up environment variables
```bash
cp .env.example .env
# Edit .env with your API keys (see below for where to get them)
```

### Step 3 — Add the system prompt
Copy the contents of `coach_system_prompt.md` into a file called `system_prompt.txt`
in the same folder as these scripts.

### Step 4 — Connect Apple Health → Google Sheets
1. Download **Health Auto Export** from the iOS App Store (~$5 one-time)
2. Open the app → select metrics: Sleep, HRV, Resting Heart Rate
3. Set destination: Google Sheets
4. It will automatically create and update a sheet in your Google Drive

### Step 5 — Connect MyFitnessPal → Google Sheets
**Option A (easiest):** Use Zapier
- Trigger: New day logged in MyFitnessPal
- Action: Add row to Google Sheets (Nutrition tab)
- Map: Date, Calories, Protein, Carbs, Fat

**Option B (free):** Manual CSV export weekly
- MyFitnessPal → Reports → Export → paste into your Nutrition sheet

### Step 6 — Google Sheets API credentials
1. Go to [console.cloud.google.com](https://console.cloud.google.com)
2. Create a project → Enable "Google Sheets API" and "Google Drive API"
3. Create a Service Account → Download `credentials.json`
4. Place `credentials.json` in this folder
5. Open your Google Sheet → Share it with the service account email

### Step 7 — Set up Twilio WhatsApp
1. Sign up at [twilio.com](https://twilio.com) (free account works)
2. Go to Messaging → Try it out → Send a WhatsApp message
3. Follow sandbox setup (takes 2 mins — you send a code to a number)
4. Add your TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN to .env

### Step 8 — Test it
```bash
# Test with mock data (no Google Sheets needed)
python coach.py terminal

# Send a manual morning briefing
python coach.py morning

# Simulate an incoming message
python coach.py chat "Done. Bench press 90kg x 8, felt solid"
```

### Step 9 — Run the webhook (to receive your WhatsApp messages)
```bash
# Terminal 1: start the webhook server
python webhook.py

# Terminal 2: expose it to the internet
ngrok http 5000

# Copy the ngrok URL (e.g. https://abc123.ngrok.io)
# In Twilio dashboard: Messaging → Sandbox → Webhook URL → paste https://abc123.ngrok.io/webhook
```

### Step 10 — Schedule morning briefings
```bash
# Keep running in background
python scheduler.py

# Or add to crontab (fires at 7am daily)
# crontab -e
# 0 7 * * * cd /path/to/fitness_coach && python coach.py morning
```

---

## File Structure

```
fitness_coach/
├── coach.py          # Main entry point — orchestrates everything
├── data.py           # Fetches Apple Health + nutrition data from Google Sheets
├── memory.py         # Persistent memory (sessions, mesocycle position, notes)
├── whatsapp.py       # Sends messages via Twilio
├── webhook.py        # Flask server — receives your WhatsApp replies
├── scheduler.py      # Sends morning briefing automatically each day
├── system_prompt.txt # The coach's brain (copy from coach_system_prompt.md)
├── memory.json       # Auto-created — stores your history
├── credentials.json  # Google service account (you create this)
├── .env              # Your API keys (never commit this)
└── requirements.txt
```

---

## Logging a Session

After each workout, log it so the coach remembers it:

```python
from coach import log_session
from memory import load_memory

memory = load_memory()
log_session({
    "type": "Push",
    "date": "2024-01-15",
    "summary": "Incline DB 3x10 @ 32kg, Cable chest 3x12 @ 50kg, Tricep pushdown 4x12",
    "tonnage_kg": 3800,
    "notes": "Shoulder felt fine, good pump"
}, memory)
```

Or just tell the coach in WhatsApp: *"Session done. Log it."* and it will ask you for the details.

---

## Cost Estimate

| Component | Cost |
|-----------|------|
| Claude API (Sonnet) | ~$0.05–0.20/day |
| Twilio WhatsApp | ~$0.005/message |
| Health Auto Export app | $5 one-time |
| Zapier (MFP sync) | Free tier works |
| Server (optional) | $0 on Railway free tier |
| **Total** | **~$2–5/month** |

---

## Troubleshooting

**No Google credentials found** — Coach runs with mock data. Fine for testing, follow Step 6 to connect real data.

**Twilio not sending** — Check your .env has correct SID/token. Make sure you've joined the sandbox (send the join code first).

**Coach doesn't remember sessions** — Check memory.json exists and is writable. Call `log_session()` after each workout.

**Morning briefing not arriving** — Check scheduler.py is running and your ATHLETE_WHATSAPP number in coach.py is correct with country code.
