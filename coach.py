"""
AI Fitness Coach — Main Script
"""

import os
import re
from datetime import datetime, timedelta

from anthropic import Anthropic
from concurrent.futures import ThreadPoolExecutor, as_completed
from data import get_athlete_context
from memory import (
    load_memory, save_memory, save_conversation_message,
    load_today_conversation, get_supabase
)
from telegram_bot import send_message as send_telegram_message
from workout import (
    get_workout_state, is_workout_active, start_session, end_session,
    log_substitution, get_substitution_history, get_workout_context,
    log_set, set_workout_state, get_last_logged_exercise
)
from exercises import find_exercise
from memory import advance_mesocycle

ATHLETE_NAME = "Sachin"
ATHLETE_CURRENT_WEIGHT_KG = 91
ATHLETE_GOAL_WEIGHT_KG = 80

client = None

def get_anthropic_client() -> Anthropic:
    """Create the API client lazily so non-chat code paths can still boot."""
    global client
    if client is None:
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if not api_key:
            raise RuntimeError("ANTHROPIC_API_KEY is not set")
        client = Anthropic(api_key=api_key)
    return client

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
Recovery data date: {data.get('date', 'Unknown')}
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

    response = get_anthropic_client().messages.create(
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
        "my recent performance, and flag anything I need to know. "
        "If the latest recovery data is not from today, say the exact date you are using."
    )
    response = chat_with_coach(message, conversation_history, memory)
    send_telegram_message(response)
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
        r'(\d+(?:\.\d+)?)\s*(?:kg)?\s*'
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
    recent = conversation_history[-8:] if len(conversation_history) >= 8 else conversation_history
    blocked_labels = {
        "your form cue", "form cue", "back-off", "back off",
        "notes", "note", "rest", "warm-up", "warm up", "cool-down", "cool down"
    }

    def clean_candidate(candidate: str) -> str:
        cleaned = re.sub(r"\s+", " ", candidate).strip(" -*_:\n\t")
        if not cleaned:
            return ""
        label = cleaned.lower()
        if label in blocked_labels:
            return ""
        if any(token in label for token in ["form cue", "back-off", "back off"]):
            return ""
        return cleaned

    for msg in reversed(recent):
        if msg["role"] != "assistant":
            continue
        content = msg["content"]
        bold_matches = re.findall(r'\*{1,2}([A-Za-z][A-Za-z0-9\s\-/+&()]+)\*{1,2}', content)
        for raw in bold_matches:
            candidate = clean_candidate(raw)
            if candidate:
                return candidate

        line_matches = re.findall(r'^([A-Za-z][A-Za-z0-9\s\-/+&()]+):', content, re.MULTILINE)
        for raw in line_matches:
            candidate = clean_candidate(raw)
            if candidate:
                return candidate
    return "Unknown"


def extract_exercise_from_set_message(text: str) -> str:
    """
    Extract exercise name from a set log if provided, e.g.:
      "Pull-ups 40 x 8"
      "Chest Supported T-bar Row 60kg x10 @8"
    """
    match = re.search(
        r'^\s*(?:done\s+)?([A-Za-z][A-Za-z0-9\s\-/+&()]+?)\s+\d+(?:\.\d+)?\s*(?:kg)?\s*[xX×]\s*\d+',
        text,
        re.IGNORECASE,
    )
    if not match:
        return ""
    candidate = re.sub(r"\s+", " ", match.group(1)).strip(" -*_:\n\t")
    blocked = {"done", "finished", "complete", "completed", "set", "sets"}
    return "" if candidate.lower() in blocked else candidate


def resolve_exercise_name(candidate: str) -> str:
    """
    Resolve to a canonical library name when confidence is high.
    Returns empty string when candidate looks unreliable.
    """
    if not candidate:
        return ""
    try:
        result = find_exercise(candidate)
        if result.get("status") in {"exact", "confident"} and result.get("match"):
            return (result["match"].get("name") or "").strip()
    except Exception:
        pass
    # Keep explicit user-provided exercise names even if not in library yet.
    if re.search(r"[A-Za-z]", candidate):
        return candidate.strip()
    return ""


# ── Session end phrases ───────────────────────────────────────────────────────

PPL_END_PHRASES = [
    "session done", "session complete", "workout done", "workout complete",
    "that's all the exercises", "finished the session", "done with the workout"
]
CARDIO_YOGA_END_PHRASE = "workout wrapped"
BRIEF_COMPLETION_ACKS = {"done", "finished", "complete", "completed", "wrapped", "wrapped up"}
CARDIO_YOGA_DAYS = [4, 5]
SESSION_TYPE_ALIASES = {
    "Pull": ["pull", "pull day"],
    "Push": ["push", "push day"],
    "Legs": ["legs", "leg day"],
    "Cardio+Abs": ["cardio", "abs", "cardio day", "cardio abs"],
    "Yoga": ["yoga", "mobility", "stretching"],
}


def get_session_type_for_day(mesocycle_day: int) -> str:
    cycle = ["Pull", "Push", "Legs", "Cardio+Abs", "Yoga"]
    return cycle[(mesocycle_day - 1) % len(cycle)]


def is_session_completion_message(text: str, expected_session_type: str) -> bool:
    """
    Detect when the user is clearly finishing the whole workout without
    treating normal set logs like "Done 100 x 12" as session completion.
    """
    normalised = text.lower().replace("’", "'").strip()

    if any(phrase in normalised for phrase in PPL_END_PHRASES):
        return True
    if CARDIO_YOGA_END_PHRASE in normalised:
        return True

    general_patterns = [
        r"\b(all done|done|finished|complete|completed|wrapped up)\s+(with\s+)?(the\s+)?(workout|session|training|gym)\b",
        r"\b(workout|session|training|gym)\s+(done|finished|complete|completed|wrapped up)\b",
        r"\bthat's it\b",
        r"\bthats it\b",
        r"\bthat's all the exercises\b",
    ]
    if any(re.search(pattern, normalised) for pattern in general_patterns):
        return True

    session_terms = SESSION_TYPE_ALIASES.get(expected_session_type, [])
    escaped_terms = "|".join(re.escape(term) for term in session_terms)
    if not escaped_terms:
        return False

    session_patterns = [
        rf"\b(all done|done|finished|complete|completed|wrapped up)\s+(with\s+)?({escaped_terms})\b",
        rf"\b({escaped_terms})\s+(done|finished|complete|completed)\b",
    ]
    return any(re.search(pattern, normalised) for pattern in session_patterns)


def handle_incoming_message(incoming_text: str, memory: dict) -> str:
    conversation_history = load_today_conversation()
    normalised_text = incoming_text.lower().replace("’", "'").strip()
    mesocycle_day = int(memory.get("mesocycle_day", 1))
    expected_session_type = get_session_type_for_day(mesocycle_day)

    # ── Detect session start ──────────────────────────────────────────────────
    start_phrases = [
        "starting pull", "starting push", "starting legs",
        "starting cardio", "starting yoga", "workout mode",
        "at the gym", "let's train", "lets train",
        "starting workout", "start workout", "begin workout", "gym now"
    ]
    should_start = any(p in normalised_text for p in start_phrases)
    if should_start:
        session_type = expected_session_type
        for canonical, aliases in SESSION_TYPE_ALIASES.items():
            if canonical.lower().replace("+", " ") in normalised_text or any(alias in normalised_text for alias in aliases):
                session_type = canonical
                break
        start_session(session_type)

    # ── Log set if workout is active and message contains set data ────────────
    state = get_workout_state()
    session_id = state.get("current_session_id", "")
    workout_active = state.get("workout_mode") == "active"
    set_data = None

    if not workout_active:
        # If user logs a set without explicitly starting workout mode, start it
        # using today's expected session type so sets are still captured.
        parsed_preview = parse_set_from_message(incoming_text)
        should_implicit_start = bool(parsed_preview)
        if should_implicit_start:
            session_id = start_session(expected_session_type)
            if session_id:
                state = get_workout_state()
                workout_active = state.get("workout_mode") == "active"

    if workout_active and session_id:
        set_data = parse_set_from_message(incoming_text)
        if set_data:
            current_set = int(state.get("current_set_number", 0)) + 1
            explicit_exercise = extract_exercise_from_set_message(incoming_text)
            exercise = resolve_exercise_name(explicit_exercise)

            if not exercise:
                state_exercise = (state.get("current_exercise_name") or "").strip()
                exercise = resolve_exercise_name(state_exercise)

            if not exercise:
                inferred_exercise = extract_exercise_from_context(conversation_history)
                if inferred_exercise != "Unknown":
                    # Only trust inferred context if it maps confidently to library.
                    inferred_lookup = find_exercise(inferred_exercise)
                    if inferred_lookup.get("status") in {"exact", "confident"} and inferred_lookup.get("match"):
                        exercise = (inferred_lookup["match"].get("name") or "").strip()

            if not exercise:
                fallback_exercise = get_last_logged_exercise(session_id)
                if fallback_exercise:
                    exercise = fallback_exercise
            if not exercise:
                exercise = "Unknown"

            pr_info = log_set(
                session_id=session_id,
                exercise=exercise,
                set_number=current_set,
                actual_weight=set_data["weight"],
                actual_reps=set_data["reps"],
                actual_rpe=set_data.get("rpe"),
            )

            set_workout_state({
                "current_set_number": str(current_set),
                "current_exercise_name": exercise if exercise != "Unknown" else "",
            })

            if pr_info.get("is_pr"):
                print(f"PR detected: {exercise} {set_data['weight']}kg x {set_data['reps']}")
            print(f"Set logged: {exercise} set{current_set} - {set_data['weight']}kg x {set_data['reps']}" +
                  (f" @RPE{set_data['rpe']}" if set_data.get("rpe") else ""))

    # ── Get coach response ────────────────────────────────────────────────────
    response = chat_with_coach(incoming_text, conversation_history, memory)

    session_complete = is_session_completion_message(incoming_text, expected_session_type)
    brief_completion_ack = workout_active and not set_data and normalised_text in BRIEF_COMPLETION_ACKS
    session_complete = session_complete or brief_completion_ack

    # ── Cardio+Abs and Yoga days ──────────────────────────────────────────────
    if session_complete and mesocycle_day in CARDIO_YOGA_DAYS:
        state = get_workout_state()
        session_id = state.get("current_session_id", "")
        workout_active_flag = state.get("workout_mode") == "active"
        session_type_terms = SESSION_TYPE_ALIASES.get(expected_session_type, [])
        explicit_session_type = any(term in incoming_text.lower() for term in session_type_terms)
        explicit_workout_completion = any(term in incoming_text.lower() for term in ["workout", "session", "training", "gym"])
        if workout_active_flag or session_id:
            if session_id:
                end_session(session_id)
            advance_mesocycle(memory)
            print(f"Cardio/Yoga session complete - mesocycle advanced to day {memory.get('mesocycle_day')}")
        elif explicit_session_type or explicit_workout_completion:
            advance_mesocycle(memory)
            print(f"Cardio/Yoga session inferred complete - mesocycle advanced to day {memory.get('mesocycle_day')}")

    # ── PPL days ──────────────────────────────────────────────────────────────
    elif session_complete:
        state = get_workout_state()
        session_id = state.get("current_session_id", "")
        workout_active_flag = state.get("workout_mode") == "active"
        session_type_terms = SESSION_TYPE_ALIASES.get(expected_session_type, [])
        explicit_session_type = any(term in incoming_text.lower() for term in session_type_terms)
        explicit_workout_completion = any(term in incoming_text.lower() for term in ["workout", "session", "training", "gym"])
        if workout_active_flag or session_id:
            if session_id:
                end_session(session_id)
            advance_mesocycle(memory)
            print(f"PPL session complete - mesocycle advanced to day {memory.get('mesocycle_day')}")
        elif not set_data and (explicit_session_type or explicit_workout_completion):
            advance_mesocycle(memory)
            print(f"PPL session inferred complete - mesocycle advanced to day {memory.get('mesocycle_day')}")
        else:
            print("Session end phrase detected but no active workout - mesocycle not advanced")

    send_telegram_message(response)
    return response


if __name__ == "__main__":
    import sys
    memory = load_memory()

    if len(sys.argv) < 2:
        print("Usage:")
        print("  python coach.py morning    - send morning briefing")
        print("  python coach.py terminal   - interactive terminal mode")
        sys.exit(0)

    mode = sys.argv[1]

    if mode == "morning":
        send_morning_briefing(memory)

    elif mode == "terminal":
        print("AI Fitness Coach - Terminal Mode")
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
