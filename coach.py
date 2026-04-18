"""
AI Fitness Coach — Main Script
"""

import os
import re
from datetime import datetime, timedelta

from anthropic import Anthropic
from concurrent.futures import ThreadPoolExecutor, as_completed
from data import CYCLE, get_athlete_context, get_supabase, now_local, today_local_str
from memory import (
    load_memory, save_memory, save_conversation_message,
    load_today_conversation,
)
from telegram_bot import send_message as send_telegram_message
from workout import (
    get_workout_state, is_workout_active, start_session, end_session,
    log_substitution, get_substitution_history, get_workout_context,
    log_set, set_workout_state, get_last_logged_exercise
)
from exercises import find_exercise
from memory import advance_mesocycle

def _safe_int(value, default: int = 1) -> int:
    """Safely coerce a value to int, returning default on failure."""
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


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
        if not supabase:
            return "No database connection."
        since = (now_local() - timedelta(days=days)).strftime("%Y-%m-%d")

        all_sessions = []

        # ── New table: workout_sessions + workout_sets ────────────────────────
        ws = supabase.table("workout_sessions")\
            .select("id, date, type, tonnage_kg")\
            .gte("date", since)\
            .order("date", desc=True)\
            .execute()

        session_ids = [s["id"] for s in (ws.data or [])]
        all_sets_data = []
        if session_ids:
            # Batch fetch all sets for all sessions at once (avoid N+1)
            all_sets_result = supabase.table("workout_sets")\
                .select("workout_session_id, exercise, actual_weight_kg, actual_reps, actual_rpe, is_warmup")\
                .in_("workout_session_id", session_ids)\
                .eq("is_warmup", False)\
                .execute()
            all_sets_data = all_sets_result.data or []

        # Group sets by session ID
        sets_by_session = {}
        for s in all_sets_data:
            sid = s["workout_session_id"]
            if sid not in sets_by_session:
                sets_by_session[sid] = []
            sets_by_session[sid].append(s)

        for s in (ws.data or []):
            all_sessions.append({
                "date": s["date"],
                "type": s["type"],
                "tonnage_kg": s.get("tonnage_kg"),
                "summary": None,
                "sets": sets_by_session.get(s["id"], [])
            })

        # ── Old table: sessions + sets ────────────────────────────────────────
        ls = supabase.table("sessions")\
            .select("id, date, type, summary, tonnage_kg")\
            .gte("date", since)\
            .order("date", desc=True)\
            .execute()

        old_session_ids = [s["id"] for s in (ls.data or [])]
        old_sets_data = []
        if old_session_ids:
            old_sets_result = supabase.table("sets")\
                .select("session_id, exercise, weight_kg, reps, rpe")\
                .in_("session_id", old_session_ids)\
                .execute()
            old_sets_data = old_sets_result.data or []

        old_sets_by_session = {}
        for st in old_sets_data:
            sid = st["session_id"]
            if sid not in old_sets_by_session:
                old_sets_by_session[sid] = []
            old_sets_by_session[sid].append({
                "exercise": st["exercise"],
                "actual_weight_kg": st["weight_kg"],
                "actual_reps": st["reps"],
                "actual_rpe": st.get("rpe")
            })

        for s in (ls.data or []):
            all_sessions.append({
                "date": s["date"],
                "type": s["type"],
                "tonnage_kg": s.get("tonnage_kg"),
                "summary": s.get("summary"),
                "sets": old_sets_by_session.get(s["id"], [])
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
                    ex = st.get("exercise", "Unknown")
                    if ex not in exercises:
                        exercises[ex] = []
                    set_str = f"{st.get('actual_weight_kg', '?')}kg x {st.get('actual_reps', '?')}"
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
        if not supabase:
            return "No database connection."
        since = (now_local() - timedelta(days=days)).strftime("%Y-%m-%d")
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
        if not supabase:
            return "No database connection."
        since = (now_local() - timedelta(days=days)).strftime("%Y-%m-%d")
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
    today = now_local().strftime("%A %d %B %Y")
    mesocycle_week = memory.get("mesocycle_week", 1)
    mesocycle_day = _safe_int(memory.get("mesocycle_day", 1))
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
                results[key] = future.result(timeout=10)
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
Sleep: {data.get('sleep_hours', 'N/A')} hrs | HRV: {data.get('hrv', 'N/A')} (7-day avg: {data.get('hrv_avg', 'N/A')}) | Status: {data.get('hrv_status', 'Unknown')}
Resting HR: {data.get('resting_hr', 'N/A')} bpm (7-day avg: {data.get('resting_hr_baseline', 'N/A')})

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

MAX_CONVERSATION_MESSAGES = 40  # Keep last ~20 exchanges to stay within token limits


def _truncate_history(history: list) -> list:
    """Keep the most recent messages to avoid exceeding Claude's context window."""
    if len(history) <= MAX_CONVERSATION_MESSAGES:
        return history
    return history[-MAX_CONVERSATION_MESSAGES:]


def chat_with_coach(user_message: str, conversation_history: list, memory: dict) -> str:
    system_prompt = load_system_prompt()
    context_block = build_context_block(memory)
    full_system = system_prompt + "\n\n" + context_block

    conversation_history.append({"role": "user", "content": user_message})
    save_conversation_message("user", user_message)

    messages_to_send = _truncate_history(conversation_history)

    response = get_anthropic_client().messages.create(
        model="claude-sonnet-4-20250514",
        max_tokens=1000,
        system=full_system,
        messages=messages_to_send
    )

    if not response.content:
        assistant_message = "Sorry, I couldn't generate a response. Please try again."
    else:
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

_SET_PATTERN = re.compile(
    r'(?:^|[\s.,;/])'
    r'(\d+(?:\.\d+)?)\s*(?:kg)?\s*'
    r'[xX×]\s*'
    r'(\d+)'
    r'(?:\s*(?:rpe|@)\s*(\d+(?:\.\d+)?))?',
    re.IGNORECASE,
)


def parse_set_from_message(text: str) -> dict | None:
    """Return first set match — kept for backward compatibility."""
    sets = parse_all_sets_from_message(text)
    return sets[0] if sets else None


def parse_all_sets_from_message(text: str) -> list[dict]:
    """
    Extract ALL weight x reps patterns from a message, e.g.:
      "warm up 90 x 10, 140 x 6"   → [{90,10}, {140,6}]
      "101 x 10 and 93 x 10"        → [{101,10}, {93,10}]
    """
    results = []
    for match in _SET_PATTERN.finditer(text):
        weight = float(match.group(1))
        reps = int(match.group(2))
        rpe = float(match.group(3)) if match.group(3) else None
        if 1 <= weight <= 500 and 1 <= reps <= 50:
            results.append({"weight": weight, "reps": reps, "rpe": rpe})
    return results


def is_warmup_set(text: str) -> bool:
    """Return True if the message indicates warm-up sets."""
    return bool(re.search(r'\bwarm[\s-]?up\b|\bwarmup\b', text, re.IGNORECASE))


_NON_EXERCISE_HEADERS = {
    "recovery", "nutrition", "tomorrow", "today", "volume analysis",
    "strength trends", "session done", "watch", "best lift",
    "recovery tonight", "key flags", "progression notes",
}


def _is_exercise_name(text: str) -> bool:
    """Filter out section headers and other non-exercise bold text."""
    cleaned = text.strip().lower()
    # Reject ALL-CAPS section headers like "RECOVERY", "TODAY: PUSH"
    if text.strip().isupper():
        return False
    # Reject known non-exercise headers
    if cleaned in _NON_EXERCISE_HEADERS:
        return False
    if cleaned.startswith("today:") or cleaned.startswith("tomorrow:"):
        return False
    # Reject very short strings (single words under 3 chars)
    if len(cleaned) < 3:
        return False
    return True


_BLOCKED_LABELS = {
    "your form cue", "form cue", "back-off", "back off", "backoff",
    "notes", "note", "rest", "warm-up", "warm up", "warmup",
    "cool-down", "cool down", "cooldown",
    "working set", "top set", "drop set",
}


def _is_valid_exercise(text: str) -> bool:
    """Combined filter: rejects section headers, form labels, and non-exercise text."""
    if not _is_exercise_name(text):
        return False
    cleaned = re.sub(r"\s+", " ", text).strip(" -*_:\n\t").lower()
    if cleaned in _BLOCKED_LABELS:
        return False
    if any(token in cleaned for token in ["form cue", "back-off", "back off"]):
        return False
    return True


def extract_exercise_from_context(conversation_history: list) -> str:
    """
    Look back through recent conversation to find the last exercise the coach
    mentioned. Reads *Bold Name* or Name: formatting from assistant messages.
    Uses broad regex to catch exercises with numbers/special chars (e.g. T-bar Row).
    """
    recent = conversation_history[-8:] if len(conversation_history) >= 8 else conversation_history

    for msg in reversed(recent):
        if msg["role"] != "assistant":
            continue
        content = msg["content"]

        # Bold text: *Exercise Name* or **Exercise Name**
        for match in reversed(list(re.finditer(
            r'\*{1,2}([A-Za-z][A-Za-z0-9\s\-/+&()]+)\*{1,2}', content
        ))):
            name = re.sub(r"\s+", " ", match.group(1)).strip()
            if _is_valid_exercise(name):
                return name

        # Line-start label: Exercise Name: ...
        for match in reversed(list(re.finditer(
            r'^([A-Za-z][A-Za-z0-9\s\-/+&()]+):', content, re.MULTILINE
        ))):
            name = re.sub(r"\s+", " ", match.group(1)).strip()
            if _is_valid_exercise(name):
                return name

    return "Unknown"


_CONVERSATIONAL_PREFIX = re.compile(
    r'^(?:I\s+)?(?:just\s+)?(?:did|done|finished|completed|logged)\s+(?:my\s+)?',
    re.IGNORECASE,
)


def extract_exercise_from_set_message(text: str) -> str:
    """
    Extract exercise name from a set log if provided, e.g.:
      "Pull-ups 40 x 8"
      "Chest Supported T-bar Row 60kg x10 @8"
      "I did calf raise machine 101 x 10"
      "just finished leg press 80 x 12"
    """
    match = re.search(
        r'^\s*(?:(?:I\s+)?(?:just\s+)?(?:did|done|finished|completed|logged)\s+(?:my\s+)?)?'
        r'([A-Za-z][A-Za-z0-9\s\-/+&()]+?)\s+\d+(?:\.\d+)?\s*(?:kg)?\s*[xX×]\s*\d+',
        text,
        re.IGNORECASE,
    )
    if not match:
        return ""
    candidate = re.sub(r"\s+", " ", match.group(1)).strip(" -*_:\n\t")
    # Strip any residual conversational prefix the regex didn't consume
    candidate = _CONVERSATIONAL_PREFIX.sub("", candidate).strip()
    blocked = {
        "done", "finished", "complete", "completed", "set", "sets",
        "warm", "warm up", "warmup", "warm-up",
        "rest", "back off", "back-off", "backoff",
        "cool down", "cool-down", "cooldown",
        "working set", "top set", "drop set",
        "i", "my",
    }
    normalised = candidate.lower().strip(" -_:")
    return "" if normalised in blocked else candidate


def resolve_exercise_name(candidate: str) -> str:
    """
    Resolve to a canonical library name. Returns '' if not found.
    Only accepts exact/confident matches (score ≥ 0.7) — never raw strings.
    """
    if not candidate:
        return ""
    try:
        result = find_exercise(candidate)
        if result.get("status") in {"exact", "confident"} and result.get("match"):
            return (result["match"].get("name") or "").strip()
    except Exception:
        pass
    return ""


def build_exercise_note(unresolved: str) -> str | None:
    """
    Return a user-facing note when an exercise couldn't be resolved to a
    canonical library name, so the user can confirm or request it be added.
    """
    if not unresolved or not _is_valid_exercise(unresolved):
        return None
    try:
        result = find_exercise(unresolved)
        if result.get("status") == "unsure" and result.get("candidates"):
            top = result["candidates"][0]["name"]
            return (
                f"💡 Logged under **{top}** (closest match to \"{unresolved}\"). "
                f"Was that right? If not, reply with the correct name "
                f"or _add exercise {unresolved}_ to add it to my library."
            )
    except Exception:
        pass
    return (
        f"💡 **{unresolved}** isn't in my exercise library. "
        f"Reply _add exercise {unresolved}_ to add it permanently, "
        f"or tell me the correct exercise name."
    )


# ── Session end phrases ───────────────────────────────────────────────────────

PPL_END_PHRASES = [
    "session done", "session complete", "workout done", "workout complete",
    "that's all the exercises", "finished the session", "done with the workout",
    "end workout", "ending workout", "end session", "ending session",
    "end it now", "i'll end it", "i will end", "stop workout",
    "finish workout", "workout over", "calling it", "that's a wrap",
    "thats a wrap",
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
    return CYCLE[(mesocycle_day - 1) % len(CYCLE)]


def _has_set_data_in_text(text: str) -> bool:
    """Check if text contains weight x reps data (a set log, not a completion msg)."""
    return bool(re.search(r'\d+(?:\.\d+)?\s*(?:kg)?\s*[xX\u00d7]\s*\d+', text))


def is_session_completion_message(text: str, expected_session_type: str) -> bool:
    """
    Detect when the user is clearly finishing the whole workout without
    treating normal set logs like "Done 100 x 12" as session completion.
    """
    normalised = text.lower().replace("'", "'").strip()

    # Never treat set logs as session completion
    if _has_set_data_in_text(normalised):
        return False

    if any(phrase in normalised for phrase in PPL_END_PHRASES):
        return True
    if CARDIO_YOGA_END_PHRASE in normalised:
        return True

    general_patterns = [
        r"\b(all done|done|finished|complete|completed|wrapped up|wrapped)\s+(with\s+)?(the\s+)?(workout|session|training|gym)\b",
        r"\b(workout|session|training|gym)\s+(is\s+)?(done|finished|complete|completed|wrapped up|wrapped)\b",
        r"\bthat's it\b",
        r"\bthats it\b",
        r"\bthat's all the exercises\b",
        r"\ball done\b",
    ]
    if any(re.search(pattern, normalised) for pattern in general_patterns):
        return True

    # Check ALL session types, not just the expected one — handles out-of-sync cycles
    all_session_terms = []
    for terms in SESSION_TYPE_ALIASES.values():
        all_session_terms.extend(terms)
    escaped_all = "|".join(re.escape(term) for term in all_session_terms)

    session_patterns = [
        # "yoga done", "pull done", "cardio complete", "legs finished"
        rf"\b({escaped_all})\s+(is\s+)?(done|finished|complete|completed|wrapped)\b",
        # "done with yoga", "finished pull", "completed legs"
        rf"\b(all done|done|finished|complete|completed|wrapped up|wrapped)\s+(with\s+)?({escaped_all})\b",
        # "done with today's session", "finished today"
        rf"\b(done|finished|completed|wrapped)\s+(with\s+)?(today|today's)\b",
    ]
    return any(re.search(pattern, normalised) for pattern in session_patterns)


def infer_session_type_from_recent(conversation_history: list, default: str) -> str:
    """
    Scan the last few user messages for explicit session type declarations
    like 'Today is legs' or 'doing push' so the correct type is used even
    when the session is implicitly started by the first set log.
    """
    recent = conversation_history[-8:] if len(conversation_history) >= 8 else conversation_history
    for msg in reversed(recent):
        if msg["role"] != "user":
            continue
        content = msg["content"].lower().replace("\u2019", "'").strip()
        for canonical, aliases in SESSION_TYPE_ALIASES.items():
            for alias in aliases:
                escaped = re.escape(alias)
                if (re.search(rf"\btoday\s+is\s+{escaped}\b", content)
                        or re.search(rf"\bit'?s\s+{escaped}\b", content)
                        or re.search(rf"\b(?:doing|starting)\s+{escaped}\b", content)):
                    return canonical
    return default


def handle_incoming_message(incoming_text: str, memory: dict, send_reply: bool = True) -> str:
    conversation_history = load_today_conversation()
    normalised_text = incoming_text.lower().replace("'", "'").strip()
    mesocycle_day = _safe_int(memory.get("mesocycle_day", 1))
    expected_session_type = get_session_type_for_day(mesocycle_day)

    # ── "add exercise [name]" command ─────────────────────────────────────────
    add_match = re.match(
        r'add\s+exercise\s+(.+?)(?:\s*,\s*(.+))?\s*$',
        normalised_text,
        re.IGNORECASE,
    )
    if add_match:
        ex_name = add_match.group(1).strip().title()
        muscle_group = (add_match.group(2) or "").strip() or "Unknown"
        from exercises import add_exercise as _add_exercise
        success = _add_exercise(ex_name, muscle_group)
        if success:
            set_workout_state({"current_exercise_name": ex_name})
            print(f"Exercise added to library: {ex_name} ({muscle_group})")
        # Fall through to normal coach response so Claude can confirm naturally

    # ── Close any stale session carried over from a previous day ─────────────
    # Without this guard, a session that was never explicitly ended stays
    # workout_mode=active forever, causing sets from later days to accumulate
    # on the same session_id and mesocycle to never advance.
    stale_state = get_workout_state()
    if stale_state.get("workout_mode") == "active":
        start_time_str = stale_state.get("session_start_time", "")
        try:
            if start_time_str:
                started = datetime.fromisoformat(start_time_str)
                if started.date() < now_local().date():
                    stale_id = stale_state.get("current_session_id", "")
                    if stale_id:
                        end_session(stale_id)
                    advance_mesocycle(memory)
                    mesocycle_day = _safe_int(memory.get("mesocycle_day", 1))
                    expected_session_type = get_session_type_for_day(mesocycle_day)
        except Exception as e:
            print(f"Stale session check failed: {e}")

    # ── Detect session start ──────────────────────────────────────────────────
    start_phrases = [
        "starting pull", "starting push", "starting legs",
        "starting cardio", "starting yoga", "workout mode",
        "at the gym", "let's train", "lets train",
        "starting workout", "start workout", "begin workout", "gym now"
    ]
    should_start = any(p in normalised_text for p in start_phrases)
    if should_start:
        # Check current message first, then fall back to recent conversation
        session_type = expected_session_type
        for canonical, aliases in SESSION_TYPE_ALIASES.items():
            if canonical.lower().replace("+", " ") in normalised_text or any(alias in normalised_text for alias in aliases):
                session_type = canonical
                break
        if session_type == expected_session_type:
            session_type = infer_session_type_from_recent(conversation_history, expected_session_type)
        start_session(session_type)

    # ── Log set if workout is active and message contains set data ────────────
    state = get_workout_state()
    session_id = state.get("current_session_id", "")
    workout_active = state.get("workout_mode") == "active"
    set_data = None

    if not workout_active:
        # If user logs a set without explicitly starting workout mode, start it.
        # Use session type from recent conversation so "Today is legs" + first set
        # log creates a Legs session rather than the mesocycle default.
        parsed_preview = parse_set_from_message(incoming_text)
        should_implicit_start = bool(parsed_preview)
        if should_implicit_start:
            implicit_type = infer_session_type_from_recent(conversation_history, expected_session_type)
            session_id = start_session(implicit_type)
            if session_id:
                state = get_workout_state()
                workout_active = state.get("workout_mode") == "active"

    # Track the exercise name in local scope so the post-response update can
    # compare without an extra get_workout_state() call.
    _active_exercise = (state.get("current_exercise_name") or "").strip()
    all_sets: list = []
    unresolved_candidate = ""

    if workout_active and session_id:
        all_sets = parse_all_sets_from_message(incoming_text)
        set_data = all_sets[0] if all_sets else None
        warmup = is_warmup_set(incoming_text)

        if all_sets:
            current_set_base = int(state.get("current_set_number", 0))

            # Resolve exercise name once for all sets in this message.
            # Each path tries to return a canonical library name only.
            explicit_exercise = extract_exercise_from_set_message(incoming_text)
            exercise = resolve_exercise_name(explicit_exercise)
            if not exercise and explicit_exercise and _is_valid_exercise(explicit_exercise):
                unresolved_candidate = explicit_exercise

            if not exercise:
                exercise = resolve_exercise_name(_active_exercise)

            if not exercise:
                inferred_exercise = extract_exercise_from_context(conversation_history)
                if inferred_exercise != "Unknown":
                    inferred_lookup = find_exercise(inferred_exercise)
                    if inferred_lookup.get("status") in {"exact", "confident"} and inferred_lookup.get("match"):
                        exercise = (inferred_lookup["match"].get("name") or "").strip()
                    elif not unresolved_candidate and _is_valid_exercise(inferred_exercise):
                        unresolved_candidate = inferred_exercise

            if not exercise:
                fallback_exercise = get_last_logged_exercise(session_id)
                if fallback_exercise:
                    exercise = fallback_exercise

            # When no canonical name found, log with the raw candidate so the
            # set isn't lost — but we'll append a note asking user to add it.
            if not exercise:
                exercise = unresolved_candidate or "Unknown"

            for i, set_entry in enumerate(all_sets):
                current_set = current_set_base + i + 1
                pr_info = log_set(
                    session_id=session_id,
                    exercise=exercise,
                    set_number=current_set,
                    actual_weight=set_entry["weight"],
                    actual_reps=set_entry["reps"],
                    actual_rpe=set_entry.get("rpe"),
                    is_warmup=warmup,
                )
                if pr_info.get("is_pr"):
                    print(f"PR detected: {exercise} {set_entry['weight']}kg x {set_entry['reps']}")
                warmup_tag = " (warmup)" if warmup else ""
                print(f"Set logged: {exercise} set{current_set}{warmup_tag} - "
                      f"{set_entry['weight']}kg x {set_entry['reps']}"
                      + (f" @RPE{set_entry['rpe']}" if set_entry.get("rpe") else ""))

            _active_exercise = exercise if exercise != "Unknown" else ""
            set_workout_state({
                "current_set_number": str(current_set_base + len(all_sets)),
                "current_exercise_name": _active_exercise,
            })

    # ── Get coach response ────────────────────────────────────────────────────
    response = chat_with_coach(incoming_text, conversation_history, memory)

    # When we logged sets under a non-canonical name, append a note so the
    # user knows and can add the exercise or correct the name.
    if workout_active and all_sets and unresolved_candidate:
        note = build_exercise_note(unresolved_candidate)
        if note:
            response = response + "\n\n" + note

    # Update current_exercise_name from coach's prescription so the next bare
    # set log ("80 x 8") is attributed to the exercise the coach just prescribed
    # rather than the last explicitly named one.
    if workout_active:
        next_exercise = extract_exercise_from_context(
            [{"role": "assistant", "content": response}]
        )
        if next_exercise and next_exercise != "Unknown":
            resolved = resolve_exercise_name(next_exercise)
            if resolved and resolved != _active_exercise:
                set_workout_state({"current_exercise_name": resolved})
                _active_exercise = resolved
                print(f"Exercise updated from coach response: {resolved}")

    session_complete = is_session_completion_message(incoming_text, expected_session_type)
    brief_completion_ack = workout_active and not set_data and normalised_text in BRIEF_COMPLETION_ACKS
    session_complete = session_complete or brief_completion_ack

    # ── Handle session completion and mesocycle advance ─────────────────────
    if session_complete:
        state = get_workout_state()
        session_id = state.get("current_session_id", "")
        workout_active_flag = state.get("workout_mode") == "active"

        if workout_active_flag or session_id:
            # Active workout session — end it and advance
            if session_id:
                end_session(session_id)
            advance_mesocycle(memory)
            print(f"Session complete (active) - mesocycle advanced to day {memory.get('mesocycle_day')}")
        elif not set_data:
            # No active session but user clearly said they're done — advance anyway.
            # This handles cardio/yoga done outside workout mode, or out-of-sync cycles.
            advance_mesocycle(memory)
            print(f"Session complete (inferred) - mesocycle advanced to day {memory.get('mesocycle_day')}")

    if send_reply:
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
