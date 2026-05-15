"""
AI Fitness Coach — Main entry point.

Routing, Claude API calls, and the chat handler live here. The heavy
context-fetching and parsing utilities sit in coach_context.py and
coach_parsing.py to keep this file scannable.
"""

import logging
import os
import re
from datetime import datetime

from anthropic import Anthropic

from data import now_local
from exercises import find_exercise
from memory import (
    advance_mesocycle, load_memory, load_today_conversation,
    save_conversation_message,
)
from settings import get_settings
from telegram_bot import send_message as send_telegram_message
from workout import (
    end_session, get_last_logged_exercise, get_workout_state,
    is_workout_active, log_set, log_substitution, set_workout_state,
    start_session,
)

# Re-exported from the split modules so external callers (tests, scripts)
# can keep `from coach import ...` working. Patching `coach.<name>` also
# continues to intercept calls made from handle_incoming_message because
# Python resolves these names from this module's globals.
from coach_context import (
    MAX_CONVERSATION_MESSAGES,
    build_context_block,
    get_apple_workouts,
    get_full_session_history,
    get_recovery_history,
    truncate_history as _truncate_history,
)
from coach_parsing import (
    BRIEF_COMPLETION_ACKS,
    CARDIO_YOGA_DAYS,
    CARDIO_YOGA_END_PHRASE,
    PPL_END_PHRASES,
    SESSION_TYPE_ALIASES,
    build_exercise_note,
    extract_exercise_from_context,
    extract_exercise_from_set_message,
    get_session_type_for_day,
    infer_session_type_from_recent,
    is_ios_structured_log,
    is_session_completion_message,
    is_warmup_set,
    parse_all_sets_from_message,
    parse_set_from_message,
    resolve_exercise_name,
    _is_valid_exercise,
)

log = logging.getLogger(__name__)


def _safe_int(value, default: int = 1) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


_athlete = get_settings()
ATHLETE_NAME = _athlete.athlete_name
ATHLETE_CURRENT_WEIGHT_KG = _athlete.athlete_current_weight_kg
ATHLETE_GOAL_WEIGHT_KG = _athlete.athlete_goal_weight_kg

client = None


def get_anthropic_client() -> Anthropic:
    """Create the API client lazily so non-chat code paths can still boot."""
    global client
    if client is None:
        api_key = get_settings().anthropic_api_key
        if not api_key:
            raise RuntimeError("ANTHROPIC_API_KEY is not set")
        client = Anthropic(api_key=api_key)
    return client


_SYSTEM_PROMPT_CACHE: str | None = None


def load_system_prompt() -> str:
    global _SYSTEM_PROMPT_CACHE
    if _SYSTEM_PROMPT_CACHE is None:
        path = os.path.join(os.path.dirname(__file__), "system_prompt.txt")
        with open(path, "r", encoding="utf-8") as f:
            _SYSTEM_PROMPT_CACHE = f.read()
    return _SYSTEM_PROMPT_CACHE


def chat_with_coach(user_message: str, conversation_history: list, memory: dict) -> str:
    system_prompt = load_system_prompt()
    context_block = build_context_block(
        memory,
        ATHLETE_NAME,
        ATHLETE_CURRENT_WEIGHT_KG,
        ATHLETE_GOAL_WEIGHT_KG,
        log,
    )

    conversation_history.append({"role": "user", "content": user_message})
    save_conversation_message("user", user_message)

    messages_to_send = _truncate_history(conversation_history)

    # Split system into two blocks so the static prompt is cached across calls
    # but the per-request context (recovery, sessions, workout state) stays live.
    response = get_anthropic_client().messages.create(
        model="claude-sonnet-4-6",
        max_tokens=1000,
        system=[
            {"type": "text", "text": system_prompt,
             "cache_control": {"type": "ephemeral"}},
            {"type": "text", "text": context_block},
        ],
        messages=messages_to_send,
    )

    if not response.content:
        assistant_message = "Sorry, I couldn't generate a response. Please try again."
    else:
        assistant_message = response.content[0].text
    conversation_history.append({"role": "assistant", "content": assistant_message})
    save_conversation_message("assistant", assistant_message)

    return assistant_message


BRIEFING_STYLE_INSTRUCTIONS = {
    "concise": (
        "Keep it short — 4-6 bullet lines, max ~150 words. No preamble, no "
        "filler. Lead with today's session type and the headline recovery number."
    ),
    "detailed": (
        "Give the full breakdown: recovery numbers with context, today's full "
        "exercise list with sets/reps/weights/RPE, progression notes vs last "
        "week, anything to watch."
    ),
    "drill_sergeant": (
        "Talk like a no-nonsense strength coach. Direct, demanding, zero "
        "fluff. Tell me what to do, why it matters, and what would be a "
        "cop-out. Still cover recovery + today's plan + key targets."
    ),
}


def build_briefing_prompt(style: str) -> str:
    """Compose the morning briefing prompt with a style-specific tone."""
    base = (
        "Good morning. Give me my morning briefing: "
        "review my recovery data, tell me today's session with full "
        "exercise list, sets, reps, weights and RPE targets based on "
        "my recent performance, and flag anything I need to know. "
        "If the latest recovery data is not from today, say the exact date you are using."
    )
    instruction = BRIEFING_STYLE_INSTRUCTIONS.get(
        style, BRIEFING_STYLE_INSTRUCTIONS["detailed"]
    )
    return f"{base}\n\nStyle: {instruction}"


def send_morning_briefing(memory: dict):
    print("Sending morning briefing...")
    conversation_history = []
    style = str(memory.get("briefing_style", "detailed")).strip().lower()
    message = build_briefing_prompt(style)
    response = chat_with_coach(message, conversation_history, memory)
    send_telegram_message(response)
    print(f"Morning briefing sent (style={style}).")


def handle_incoming_message(incoming_text: str, memory: dict, send_reply: bool = True,
                            out_prs: list | None = None) -> str:
    """Process a user message, log any sets, and return the coach reply.

    If `out_prs` is provided, every set that beats the historical e1RM by >1%
    is appended as a dict so callers (the iOS /api/chat endpoint) can surface
    the celebration in-app. Telegram callers can leave it None.
    """
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
        except Exception:
            log.exception("Stale session check failed")

    # ── Detect session start ──────────────────────────────────────────────────
    start_phrases = [
        "starting pull", "starting push", "starting legs",
        "starting cardio", "starting yoga", "workout mode",
        "at the gym", "let's train", "lets train",
        "starting workout", "start workout", "begin workout", "gym now",
    ]
    should_start = any(p in normalised_text for p in start_phrases)
    if should_start:
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

    ios_log = is_ios_structured_log(incoming_text)

    if not workout_active and not ios_log:
        parsed_preview = parse_set_from_message(incoming_text)
        should_implicit_start = bool(parsed_preview)
        if should_implicit_start:
            implicit_type = infer_session_type_from_recent(conversation_history, expected_session_type)
            session_id = start_session(implicit_type)
            if session_id:
                state = get_workout_state()
                workout_active = state.get("workout_mode") == "active"

    _active_exercise = (state.get("current_exercise_name") or "").strip()
    all_sets: list = []
    unresolved_candidate = ""

    if workout_active and session_id and not ios_log:
        all_sets = parse_all_sets_from_message(incoming_text)
        set_data = all_sets[0] if all_sets else None
        warmup = is_warmup_set(incoming_text)

        if all_sets:
            current_set_base = int(state.get("current_set_number", 0))

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
                    if out_prs is not None:
                        out_prs.append({
                            "exercise": exercise,
                            "weight_kg": set_entry["weight"],
                            "reps": set_entry["reps"],
                            "estimated_1rm": pr_info.get("estimated_1rm"),
                            "previous_best": pr_info.get("previous_best"),
                            "improvement_pct": pr_info.get("improvement_pct"),
                        })
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

    if workout_active and all_sets and unresolved_candidate:
        note = build_exercise_note(unresolved_candidate)
        if note:
            response = response + "\n\n" + note

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
            if session_id:
                end_session(session_id)
            advance_mesocycle(memory)
            print(f"Session complete (active) - mesocycle advanced to day {memory.get('mesocycle_day')}")
        elif not set_data:
            advance_mesocycle(memory)
            print(f"Session complete (inferred) - mesocycle advanced to day {memory.get('mesocycle_day')}")

    if send_reply:
        send_telegram_message(response)
    return response


if __name__ == "__main__":
    import sys
    settings = get_settings()
    logging.basicConfig(
        level=settings.log_level.upper(),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
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
