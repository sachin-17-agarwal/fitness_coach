"""
scheduler.py — Runs the morning briefing automatically every day.

Option A (simple): Run this script with cron on any Linux server or Mac.
  Add to crontab: 0 7 * * * /usr/bin/python3 /path/to/scheduler.py

Option B: Use this file with a cloud scheduler (Railway, Render cron jobs)

The script checks the current time and fires the morning briefing at your
configured time.
"""

import schedule
import time
from coach import send_morning_briefing
from memory import load_memory

# ── Config ────────────────────────────────────────────────────────────────────
MORNING_BRIEFING_TIME = "07:00"   # 24hr format, your local time
# ─────────────────────────────────────────────────────────────────────────────

def run_morning_briefing():
    print(f"⏰ Scheduled morning briefing firing...")
    memory = load_memory()
    send_morning_briefing(memory)

# Schedule the morning briefing
schedule.every().day.at(MORNING_BRIEFING_TIME).do(run_morning_briefing)

print(f"📅 Scheduler running. Morning briefing set for {MORNING_BRIEFING_TIME} daily.")
print("Press Ctrl+C to stop.\n")

while True:
    schedule.run_pending()
    time.sleep(60)
