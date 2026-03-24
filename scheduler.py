"""
scheduler.py — Morning briefing cron job.
Run as a separate Railway service with cron schedule: 30 23 * * *
(23:30 UTC = 10:30am Sydney AEDT / 9:30am AEST)
"""

import sys

from coach import send_morning_briefing
from memory import load_memory

def main():
    print("⏰ Morning briefing triggered")
    try:
        memory = load_memory()
        send_morning_briefing(memory)
        print("✅ Morning briefing complete")
    except Exception as e:
        print(f"❌ Morning briefing failed: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
