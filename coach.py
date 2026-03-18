"""
AI Fitness Coach — Main Script
"""

import os
import re
from datetime import datetime, timedelta
from dotenv import load_dotenv
load_dotenv()

from anthropic import Anthropic
from concurrent.futures import ThreadPoolExecutor, as_completed
from data import get_athlete_context
from memory import (
    load_memory, save_memory, save_conversation_message,
    load_today_conversation, get_supabase
)
from telegram_bot import send_message as send_whatsapp_message
from workout import (
    get_workout_state, is_workout_active, start_session, end_session,
    log_substitution, get_substitution_history, get_workout_context,
    log_set, set_workout_state
)
from memory import advance_mesocycle

ATHLETE_NAME = "Sachin"
ATHLETE_CURRENT_WEIGHT_KG = 91
ATHLETE_GOAL_WEIGHT_KG = 80

client = Anthropic()

def load_system_prompt() -> str:
    path = os.path.join(os.path.dirname(__file__), "system_prompt.txt")
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def get_full_session_history(days: int = 30) -> str:
    try:
        supabase = get_supabase()
        since = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d")

        all_sessions = []

        # ── New table: workout_sessions + workout_sets ────────────────────────
        ws = supabase.table("workout_sessions")\
            .select("id, date, type, tonnage_kg")\
            .gte("date", since)\
            .order("date", desc=True)\
            .execute()

        for s in (ws.data or []):
            sets = supabase.table("workout_sets")\
                .select("exercise, actual_weight_kg, actual_reps, actual_rpe, is_warmup")\
                .eq("workout_session_id", s["id"])\
                .eq("is_warmup", False)\
                .execute()
            all_sessions.append({
                "date": s["date"],
                "type": s["type"],
                "tonnage_kg": s.get("tonnage_kg"),
                "summary": None,
                "sets": sets.data or []
            })

        # ── Old table: sessions + sets ────────────────────────────────────────
        ls = supabase.table("sessions")\
            .select("id, date, type, summary, tonnage_kg")\
            .gte("date", since)\
            .order("date", desc=True)\
            .execute()

        for s in (ls.data or []):
            sets = supabase.table("sets")\
                .select("exercise, weight_kg, reps, rpe")\
                .eq("session_id", s["id"])\
                .execute()
            normalised = [
                {"exercise": st["exercise"],
                 "actual_weight_kg": st["weight_kg"],
                 "actual_reps": st["reps"],
                 "actual_rpe": st.get("rpe")}
                for st in (sets.data or [])
            ]
            all_sessions.append({
                "date": s["date"],
                "type": s["type"],
                "tonnage_kg": s.get("tonnage_kg"),
                "summary": s.get("summary"),
                "sets": normalised
            })

        if not all_sessions:
            return "No sessions logged in the last 30 days."

        all_sessions.sort(key=lambda x: x["date"], reverse=True)

        lines = []
        for s in all_sessions:
            lines.append(f"\n{s['date']} — {s['type']} (tonnage: {s.get('tonnage_kg', '?')}kg)")
            if s["sets"]:
                exercises = {}
                for st in s["sets"]:
                    ex = st["exercise"]
                    if ex not in exercises:
                        exercises[ex] = []
                    set_str = f"{st['actual_weight_kg']}kg x {st['actual_reps']}"
                    if st.get("actual_rpe"):
                        set_str += f" @RPE{st['actual_rpe']}"
                    exercises[ex].append(set_str)
                for ex, set_list in exercises.items():
                    lines.append(f"  {ex}: {' | '.join(set_list)}")
            elif s.get("summary"):
                lines.append(f"  {s['summary'][:200]}")

        return "\n".join(lines)
    except Exception as e:
        return f"Could not load session history: {e}"

def get_apple_workouts(days: int = 30) -> str:
    """Fetch recent Apple Watch workout records."""
    try:
        supabase = get_supabase()
        since = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d")
        result = supabase.table("apple_workouts")\
            .select("date, workout_type, duration_minutes, avg_heart_rate, active_energy_kcal")\
            .gte("date", since)\
            .order("date", desc=True)\
            .execute()
        if not result.data:
            return "No Apple Watch workouts recorded."
        lines = []
        for w in result.data:
            hr = f" | avg HR {round(w['avg_heart_rate'])}bpm" if w.get("avg_heart_rate") else ""
            kcal = f" | {round(w['active_energy_kcal'])}kcal" if w.get("active_energy_kcal") else ""
            lines.append(f"  {w['date']} — {w['workout_type']} {w['duration_minutes']}min{hr}{kcal}")
        return "\n".join(lines)
    except Exception as e:
        return f"Could not load Apple Watch workouts: {e}"

def get_recovery_history(days: int = 14) -> str:
    try:
        supabase = get_supabase()
        since = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d")
        result = supabase.table("recovery")\
            .select("date, sleep_hours, hrv, resting_hr, steps, weight_kg, body_fat_pct, vo2_max")\
            .gte("date", since)\
            .order("date", desc=True)\
            .execute()

        if not result.data:
            return "No recovery data available."

        lines = []
        for r in result.data:
            parts = [r["date"]]
            if r.get("sleep_hours"): parts.append(f"sleep:{r['sleep_hours']}h")
            if r.get("hrv"): parts.append(f"HRV:{r['hrv']}")
            if r.get("resting_hr"): parts.append(f"RHR:{r['resting_hr']}")
            if r.get("weight_kg"): parts.append(f"weight:{r['weight_kg']}kg")
            if r.get("body_fat_pct"): parts.append(f"bf:{r['body_fat_pct']}%")
            if r.get("vo2_max"): parts.append(f"VO2:{r['vo2_max']}")
            lines.append("  " + " | ".join(parts))
        return "\n".join(lines)
    except Exception as e:
        return f"Could not load recovery data: {e}"

def build_context_block(memory: dict) -> str:
    today = datetime.now().strftime("%A %d %B %Y")
    mesocycle_week = memory.get("mesocycle_week", 1)
    mesocycle_day = int(memory.get("mesocycle_day", 1))
    CYCLE = ["Pull", "Push", "Legs", "Cardio+Abs", "Yoga"]
    today_session = CYCLE[(mesocycle_day - 1) % len(CYCLE)]
    next_session = CYCLE[mesocycle_day % len(CYCLE)]

    with ThreadPoolExecutor(max_workers=5) as executor:
        futures = {
            executor.submit(get_athlete_context): "data",
            executor.submit(get_full_session_history, 30): "session_history",
            executor.submit(get_recovery_history, 14): "recovery_history",
            executor.submit(get_substitution_history): "substitution_history",
            executor.submit(get_apple_workouts, 30): "apple_workouts",
            executor.submit(get_workout_state): "workout_state",
        }
        results = {}
        for future, key in futures.items():
            try:
                results[key] = future.result(timeout=5)
            except Exception as e:
                print(f"Context fetch failed ({key}): {e}")
                results[key] = None

    data = results.get("data") or {}
    session_history = results.get("session_history") or "No sessions found."
    recovery_history = results.get("recovery_history") or "No recovery data."
    substitution_history = results.get("substitution_history") or ""
    apple_workouts = results.get("apple_workouts") or ""
    workout_state = results.get("workout_state") or {}
    workout_context = get_workout_context(workout_state)

    return f"""
[ATHLETE CONTEXT]
Athlete: {ATHLETE_NAME} | Current weight: {ATHLETE_CURRENT_WEIGHT_KG}kg | Goal weight: {ATHLETE_GOAL_WEIGHT_KG}kg
Date: {today}
Mesocycle: Week {mesocycle_week} of 4 | Cycle day {mesocycle_day}/5
TODAY'S SESSION TYPE: {today_session}
NEXT SESSION: {next_session}

TODAY'S RECOVERY:
Sleep: {data['sleep_hours']} hrs | HRV: {data['hrv']} (7-day avg: {data['hrv_avg']}) | Status: {data['hrv_status']}
Resting HR: {data['resting_hr']} bpm

LAST 14 DAYS RECOVERY:
{recovery_history}

LAST 30 DAYS SESSIONS:
{session_history}

EXERCISE SUBSTITUTION HISTORY:
{substitution_history}

APPLE WATCH WORKOUTS (last 30 days):
{apple_workouts}

Known limitations: Slight knee and shoulder issues — see coaching profile.
{workout_context}
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
    print("Sending morning briefing...")
    conversation_history = []
    message = (
        "Good morning. Give me my morning briefing: "
        "review my recovery data, tell me today's session with full "
        "exercise list, sets, reps, weights and RPE targets based on "
        "my recent performance, and flag anything I need to know."
    )
    response = chat_with_coach(message, conversation_history, memory)
    send_whatsapp_message(response)
    print("Morning briefing sent.")

# ── Set parsing ───────────────────────────────────────────────────────────────

def parse_set_from_message(text: str) -> dict | None:
    """
    Extract set data from messages like:
      "Done. 110kg x8"
      "110 x 10 RPE8"
      "bench 90kg x8 rpe 8.5"
      "done 100 x 12 @8"
    Returns dict with weight, reps, rpe (optional) or None if no match.
    """
    pattern = re.compile(
        r'(?:^|[\s.,])'
        r'(\d+(?:\.\d+)?)\s*kg?\s*'
        r'[xX×]\s*'
        r'(\d+)'
        r'(?:\s*(?:rpe|@)\s*(\d+(?:\.\d+)?))?',
        re.IGNORECASE
    )

    match = pattern.search(text)
    if not match:
        return None

    weight = float(match.group(1))
    reps = int(match.group(2))
    rpe = float(match.group(3)) if match.group(3) else None

    if weight < 1 or weight > 500:
        return None
    if reps < 1 or reps > 50:
        return None

    return {"weight": weight, "reps": reps, "rpe": rpe}


def extract_exercise_from_context(conversation_history: list) -> str:
    """
    Look back through recent conversation to find the last exercise the coach
    mentioned. Reads *Bold Name* or Name: formatting from assistant messages.
    """
    recent = conversation_history[-6:] if len(conversation_history) >= 6 else conversation_history
    for msg in reversed(recent):
        if msg["role"] != "assistant":
            continue
        content = msg["content"]
        match = re.search(r'\*([A-Za-z\s\-]+)\*', content)
        if match:
            return match.group(1).strip()
        match = re.search(r'^([A-Za-z][A-Za-z\s\-]+):', content, re.MULTILINE)
        if match:
            return match.group(1).strip()
    return "Unknown"


# ── Session end phrases ───────────────────────────────────────────────────────

PPL_END_PHRASES = [
    "session done", "session complete", "workout done", "workout complete",
    "that's all the exercises", "finished the session", "done with the workout"
]
CARDIO_YOGA_END_PHRASE = "workout wrapped"
CARDIO_YOGA_DAYS = [4, 5]


def handle_incoming_message(incoming_text: str, memory: dict) -> str:
    conversation_history = load_today_conversation()

    # ── Detect session start ──────────────────────────────────────────────────
    start_phrases = [
        "starting pull", "starting push", "starting legs",
        "starting cardio", "starting yoga", "workout mode",
        "at the gym", "let's train", "lets train"
    ]
    if any(p in incoming_text.lower() for p in start_phrases):
        session_type = "Unknown"
        for s in ["pull", "push", "legs", "cardio", "yoga"]:
            if s in incoming_text.lower():
                session_type = s.capitalize()
                break
        start_session(session_type)

    # ── Log set if workout is active and message contains set data ────────────
    state = get_workout_state()
    session_id = state.get("current_session_id", "")
    workout_active = state.get("workout_mode") == "active"

    if workout_active and session_id:
        set_data = parse_set_from_message(incoming_text)
        if set_data:
            current_set = int(state.get("current_set_number", 0)) + 1
            exercise = extract_exercise_from_context(conversation_history)

            pr_info = log_set(
                session_id=session_id,
                exercise=exercise,
                set_number=current_set,
                actual_weight=set_data["weight"],
                actual_reps=set_data["reps"],
                actual_rpe=set_data.get("rpe"),
            )

            set_workout_state({"current_set_number": str(current_set)})

            if pr_info.get("is_pr"):
                print(f"🏆 PR detected: {exercise} {set_data['weight']}kg x {set_data['reps']}")
            print(f"✅ Set logged: {exercise} set{current_set} — {set_data['weight']}kg x {set_data['reps']}" +
                  (f" @RPE{set_data['rpe']}" if set_data.get("rpe") else ""))

    # ── Get coach response ────────────────────────────────────────────────────
    response = chat_with_coach(incoming_text, conversation_history, memory)

    mesocycle_day = int(memory.get("mesocycle_day", 1))

    # ── Cardio+Abs and Yoga days ──────────────────────────────────────────────
    if CARDIO_YOGA_END_PHRASE in incoming_text.lower() and mesocycle_day in CARDIO_YOGA_DAYS:
        advance_mesocycle(memory)
        print(f"✅ Cardio/Yoga session complete — mesocycle advanced to day {memory.get('mesocycle_day')}")

    # ── PPL days ──────────────────────────────────────────────────────────────
    elif any(p in incoming_text.lower() for p in PPL_END_PHRASES):
        state = get_workout_state()
        session_id = state.get("current_session_id", "")
        workout_active_flag = state.get("workout_mode") == "active"
        if workout_active_flag or session_id:
            if session_id:
                end_session(session_id)
            advance_mesocycle(memory)
            print(f"✅ PPL session complete — mesocycle advanced to day {memory.get('mesocycle_day')}")
        else:
            print(f"⚠️ Session end phrase detected but no active workout — mesocycle not advanced")

    send_whatsapp_message(response)
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
        print("AI Fitness Coach — Terminal Mode")
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
