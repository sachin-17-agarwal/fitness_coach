"""
AI Fitness Coach — Main Script
"""

import os
import json
from datetime import datetime
from dotenv import load_dotenv
load_dotenv()

from anthropic import Anthropic
from data import get_athlete_context
from memory import (
    load_memory, save_memory, save_conversation_message,
    load_today_conversation, log_session, advance_mesocycle
)
from whatsapp import send_whatsapp_message

ATHLETE_NAME = "Sachin"
ATHLETE_BODYWEIGHT_KG = 80
TWILIO_TO_NUMBER = os.environ.get("ATHLETE_WHATSAPP", "whatsapp:+61412345678")

client = Anthropic()

def load_system_prompt() -> str:
    path = os.path.join(os.path.dirname(__file__), "system_prompt.txt")
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def build_context_block(memory: dict) -> str:
    data = get_athlete_context()
    today = datetime.now().strftime("%A %d %B %Y")
    mesocycle_week = memory.get("mesocycle_week", 1)
    mesocycle_day = memory.get("mesocycle_day", 1)

    recent_sessions = memory.get("recent_sessions", [])
    sessions_text = "\n".join([
        f"  - {s['date']}: {s['type']} — {s.get('summary', '')[:80]}"
        for s in recent_sessions[:7]
    ]) or "  No recent sessions logged yet."

    return f"""
[ATHLETE CONTEXT]
Athlete: {ATHLETE_NAME} | Bodyweight: {ATHLETE_BODYWEIGHT_KG}kg
Date: {today}
Mesocycle: Week {mesocycle_week} of 4 | Day {mesocycle_day} of cycle

Sleep last night: {data['sleep_hours']} hrs | Quality: {data['sleep_quality']}
HRV: {data['hrv']} (7-day avg: {data['hrv_avg']}) | Status: {data['hrv_status']}
Resting HR: {data['resting_hr']} bpm (baseline: {data['resting_hr_baseline']} bpm)

Recent sessions (last 7):
{sessions_text}

Known limitations: Slight knee and shoulder issues — see coaching profile.
[END CONTEXT]
"""

def chat_with_coach(user_message: str, conversation_history: list, memory: dict) -> str:
    system_prompt = load_system_prompt()
    context_block = build_context_block(memory)
    full_system = system_prompt + "\n\n" + context_block

    conversation_history.append({"role": "user", "content": user_message})
    save_conversation_message("user", user_message)

    response = client.messages.create(
        model="claude-sonnet-4-20250514",
        max_tokens=1000,
        system=full_system,
        messages=conversation_history
    )

    assistant_message = response.content[0].text
    conversation_history.append({"role": "assistant", "content": assistant_message})
    save_conversation_message("assistant", assistant_message)

    return assistant_message

def send_morning_briefing(memory: dict):
    print("📤 Sending morning briefing...")
    conversation_history = load_today_conversation()
    message = (
        "Good morning. Please give me my morning briefing: "
        "review my recovery data, tell me today's session with full "
        "exercise list, sets, reps, weights and RPE targets, and flag "
        "anything I need to know about today."
    )
    response = chat_with_coach(message, conversation_history, memory)
    send_whatsapp_message(response, TWILIO_TO_NUMBER)
    print("✅ Morning briefing sent.")

def handle_incoming_message(incoming_text: str, memory: dict) -> str:
    conversation_history = load_today_conversation()
    response = chat_with_coach(incoming_text, conversation_history, memory)
    send_whatsapp_message(response, TWILIO_TO_NUMBER)
    return response

if __name__ == "__main__":
    import sys
    memory = load_memory()

    if len(sys.argv) < 2:
        print("Usage:")
        print("  python coach.py morning    — send morning briefing")
        print("  python coach.py terminal   — interactive terminal mode")
        sys.exit(0)

    mode = sys.argv[1]

    if mode == "morning":
        send_morning_briefing(memory)

    elif mode == "terminal":
        print("🏋️  AI Fitness Coach — Terminal Mode")
        print("Type 'quit' to exit\n")
        conversation_history = load_today_conversation()
        while True:
            user_input = input("You: ").strip()
            if user_input.lower() in ("quit", "exit", "q"):
                break
            if not user_input:
                continue
            response = chat_with_coach(user_input, conversation_history, memory)
            print(f"\nCoach: {response}\n")
