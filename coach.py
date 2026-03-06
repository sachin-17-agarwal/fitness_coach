"""
AI Fitness Coach — Main Script
Pulls data from Google Sheets (Apple Health + MyFitnessPal + Workouts)
and calls Claude API with your coaching system prompt.
"""

import os
import json
from datetime import datetime, timedelta
from dotenv import load_dotenv
load_dotenv()  # Load .env file before anything else

from anthropic import Anthropic
from data import get_athlete_context
from memory import load_memory, save_memory
from whatsapp import send_whatsapp_message

# ── Config ────────────────────────────────────────────────────────────────────
ATHLETE_NAME = "Your Name"          # Change this
ATHLETE_BODYWEIGHT_KG = 80          # Change this — used for protein/calorie targets
TWILIO_TO_NUMBER = "whatsapp:+61XXXXXXXXX"   # Your WhatsApp number
# ─────────────────────────────────────────────────────────────────────────────

client = Anthropic()

def load_system_prompt() -> str:
    """Load the system prompt from file."""
    path = os.path.join(os.path.dirname(__file__), "system_prompt.txt")
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def build_context_block(memory: dict) -> str:
    """Build the athlete context block injected into every API call."""
    data = get_athlete_context()
    today = datetime.now().strftime("%A %d %B %Y")
    
    # Mesocycle tracking
    mesocycle_week = memory.get("mesocycle_week", 1)
    mesocycle_day = memory.get("mesocycle_day", 1)
    
    # Recent workouts (last 7 days)
    recent_sessions = memory.get("recent_sessions", [])
    sessions_text = "\n".join([
        f"  - {s['date']}: {s['type']} — {s['summary']}"
        for s in recent_sessions[-7:]
    ]) or "  No recent sessions logged yet."

    protein_target = round(ATHLETE_BODYWEIGHT_KG * 2.1)
    calorie_target = round(ATHLETE_BODYWEIGHT_KG * 28)  # Moderate deficit estimate

    return f"""
[ATHLETE CONTEXT]
Athlete: {ATHLETE_NAME} | Bodyweight: {ATHLETE_BODYWEIGHT_KG}kg
Date: {today}
Mesocycle: Week {mesocycle_week} of 4 | Day {mesocycle_day} of cycle

Sleep last night: {data['sleep_hours']} hrs | Quality: {data['sleep_quality']}
HRV: {data['hrv']} (7-day avg: {data['hrv_avg']}) | Status: {data['hrv_status']}
Resting HR: {data['resting_hr']} bpm (baseline: {data['resting_hr_baseline']} bpm)

Yesterday's nutrition:
  Calories: {data['calories']} / {calorie_target} target
  Protein: {data['protein_g']}g / {protein_target}g target
  Carbs: {data['carbs_g']}g | Fat: {data['fat_g']}g

Recent sessions (last 7 days):
{sessions_text}

Known limitations: Slight knee and shoulder issues — see coaching profile.
[END CONTEXT]
"""

def chat_with_coach(user_message: str, conversation_history: list, memory: dict) -> str:
    """Send a message to the coach and get a response."""
    system_prompt = load_system_prompt()
    context_block = build_context_block(memory)
    
    # Inject context into system prompt
    full_system = system_prompt + "\n\n" + context_block

    # Add user message to history
    conversation_history.append({
        "role": "user",
        "content": user_message
    })

    response = client.messages.create(
        model="claude-sonnet-4-20250514",
        max_tokens=1000,
        system=full_system,
        messages=conversation_history
    )

    assistant_message = response.content[0].text

    # Add assistant response to history
    conversation_history.append({
        "role": "assistant",
        "content": assistant_message
    })

    return assistant_message

def send_morning_briefing(memory: dict):
    """Triggered each morning — sends daily session plan via WhatsApp."""
    print("📤 Sending morning briefing...")
    
    conversation_history = []
    message = (
        "Good morning. Please give me my morning briefing: "
        "review my recovery data, tell me today's session with full "
        "exercise list, sets, reps, weights and RPE targets, and flag "
        "anything I need to know about today."
    )
    
    response = chat_with_coach(message, conversation_history, memory)
    
    send_whatsapp_message(response, TWILIO_TO_NUMBER)
    print("✅ Morning briefing sent.")
    
    # Save conversation to memory for continuity
    memory["last_morning_briefing"] = {
        "date": datetime.now().isoformat(),
        "conversation": conversation_history
    }
    save_memory(memory)

def handle_incoming_message(incoming_text: str, memory: dict):
    """
    Called when athlete sends a WhatsApp message.
    Continues the day's conversation with full context.
    """
    # Load today's conversation history if it exists
    today = datetime.now().strftime("%Y-%m-%d")
    conversation_history = memory.get("conversations", {}).get(today, [])
    
    response = chat_with_coach(incoming_text, conversation_history, memory)
    
    # Save updated conversation
    if "conversations" not in memory:
        memory["conversations"] = {}
    memory["conversations"][today] = conversation_history
    save_memory(memory)
    
    # Send reply via WhatsApp
    send_whatsapp_message(response, TWILIO_TO_NUMBER)
    return response

def log_session(session_summary: dict, memory: dict):
    """
    Call this after a session to update memory with what happened.
    session_summary = {
        'type': 'Push',
        'date': '2024-01-15',
        'summary': 'Bench 3x8 @ 90kg, OHP 3x10 @ 60kg...',
        'tonnage_kg': 4200,
        'notes': 'Felt strong, shoulder fine'
    }
    """
    if "recent_sessions" not in memory:
        memory["recent_sessions"] = []
    
    memory["recent_sessions"].append(session_summary)
    
    # Keep only last 30 sessions
    memory["recent_sessions"] = memory["recent_sessions"][-30:]
    
    # Advance mesocycle day
    memory["mesocycle_day"] = memory.get("mesocycle_day", 1) + 1
    if memory["mesocycle_day"] > 7:
        memory["mesocycle_day"] = 1
        memory["mesocycle_week"] = (memory.get("mesocycle_week", 1) % 4) + 1
    
    save_memory(memory)
    print(f"✅ Session logged: {session_summary['type']} on {session_summary['date']}")

# ── Entry points ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import sys
    memory = load_memory()
    
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python coach.py morning          — send morning briefing")
        print("  python coach.py chat 'message'   — send a message to coach")
        print("  python coach.py terminal         — interactive terminal mode")
        sys.exit(0)

    mode = sys.argv[1]

    if mode == "morning":
        send_morning_briefing(memory)

    elif mode == "chat" and len(sys.argv) > 2:
        msg = sys.argv[2]
        response = handle_incoming_message(msg, memory)
        print(f"\nCoach: {response}")

    elif mode == "terminal":
        # ── Interactive terminal mode for testing without WhatsApp ──
        print("🏋️  AI Fitness Coach — Terminal Mode")
        print("Type 'quit' to exit\n")
        
        conversation_history = []
        while True:
            user_input = input("You: ").strip()
            if user_input.lower() in ("quit", "exit", "q"):
                break
            if not user_input:
                continue
            response = chat_with_coach(user_input, conversation_history, memory)
            print(f"\nCoach: {response}\n")