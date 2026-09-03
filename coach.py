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

from data import SESSION_OVERRIDE_KEY, now_local, session_type_for
from exercises import find_exercise
from memory import (
    advance_mesocycle, load_memory, load_today_conversation,
    save_conversation_message,
)
from settings import get_settings
from telegram_bot import send_message as send_telegram_message
from workout import (
    end_session, get_last_logged_exercise, get_workout_state,
    has_session_for_today, is_workout_active, log_set, log_substitution,
    set_workout_state, start_session,
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
    check_set_counts,
    enforce_set_counts,
    extract_exercise_from_context,
    extract_exercise_from_set_message,
    get_session_type_for_day,
    infer_session_type_from_recent,
    is_ios_structured_log,
    is_session_completion_message,
    format_session_template,
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


# Above the system prompt's own size, so an ordinary short write can't trip
# it — only a rewrite of the cached prefix itself.
_PREFIX_REWRITE_ALARM_TOKENS = 10_000

# How far back the "replay" command looks when no window is given. Long enough
# to span several mesocycles (a 4-day rotation plus rest runs ~18-19 days per
# wave), so the report covers whole cycles rather than a slice of one.
DEFAULT_REPLAY_DAYS = 90


def _log_cache_usage(response) -> None:
    """Record what the prompt cache actually did on this call.

    `input_tokens` is only the uncached remainder, so it reads misleadingly
    small on its own — the true prompt size is the sum of all three counters.
    Logging them together is the only way to tell a genuine cache hit from a
    silent invalidation, which otherwise looks identical from the outside.
    """
    try:
        usage = response.usage
        read = getattr(usage, "cache_read_input_tokens", 0) or 0
        written = getattr(usage, "cache_creation_input_tokens", 0) or 0
        fresh = getattr(usage, "input_tokens", 0) or 0
        total = read + written + fresh
        pct = (read / total * 100) if total else 0.0
        log.info(
            "prompt cache: read=%d write=%d uncached=%d total=%d (%.0f%% from cache)",
            read, written, fresh, total, pct,
        )
        # A rewrite of the whole prefix costs ~20x what reading it does, and
        # produces an identical reply — so it is invisible unless something
        # says so out loud. It is legitimate on the first call of a session and
        # after the 1h TTL lapses; back to back it means the cached half is
        # moving between calls, which is a bug in what we put there rather
        # than in the cache.
        if written > _PREFIX_REWRITE_ALARM_TOKENS and read == 0:
            log.warning(
                "prompt cache MISS: rewrote %d tokens with no read. Expected once "
                "per session; if this repeats, something in the stable context "
                "block is changing between calls.", written,
            )
    except Exception:  # never let telemetry break a coaching reply
        log.debug("Could not read cache usage", exc_info=True)


def chat_with_coach(user_message: str, conversation_history: list, memory: dict,
                    recovery_override: dict | None = None) -> str:
    system_prompt = load_system_prompt()
    stable_context, live_context = build_context_block(
        memory,
        ATHLETE_NAME,
        ATHLETE_CURRENT_WEIGHT_KG,
        ATHLETE_GOAL_WEIGHT_KG,
        log,
        recovery_override=recovery_override,
        system_prompt=system_prompt,
    )

    # Appended to the LIVE half deliberately. It is derived from the prompt
    # rather than the database, so it would sit happily in the cached block —
    # but it has to be read against today's session type, and putting it beside
    # the live workout state is where the coach is already looking when it
    # decides how many sets an exercise gets.
    today_type = session_type_for(
        _safe_int(memory.get("mesocycle_day", 1)),
        override=memory.get(SESSION_OVERRIDE_KEY),
    )
    live_context += format_session_template(system_prompt, today_type)

    conversation_history.append({"role": "user", "content": user_message})
    save_conversation_message("user", user_message)

    messages_to_send = _truncate_history(conversation_history)

    # Split system into two blocks so the static prompt is cached across calls
    # but the per-request context (recovery, sessions, workout state) stays live.
    #
    # The breakpoint uses the 1-hour TTL rather than the 5-minute default.
    # Traffic here is bursty: a morning briefing, then a 60-90 minute session
    # where messages arrive a set at a time. Rest periods keep most turns
    # inside 5 minutes, but every longer gap — walking to the next machine,
    # a heavy single, a stretch of not talking to the coach — expired the
    # entry and re-wrote the whole ~17k-token prompt. A 1h write costs 2x
    # instead of 1.25x and needs three reads to break even, which a session
    # of twenty-plus turns clears easily.
    response = get_anthropic_client().messages.create(
        model="claude-sonnet-5",
        # Thinking is set EXPLICITLY, and that is the whole point of the line.
        # Omitting it meant "no thinking" on Sonnet 4.6; on Sonnet 5 the same
        # omission means adaptive thinking — and `effort` defaults to `high`,
        # so a bare model-string swap would have quietly started spending a
        # large share of the token budget on reasoning before a word of the
        # prescription was written. With max_tokens capping thinking and
        # response text TOGETHER, that lands on the one failure the parsers
        # cannot see (see below).
        #
        # Disabled rather than adaptive because the coach's failures have been
        # architectural — a truncated context window, an uncomputed stall, a
        # retry classifier — not shallow reasoning. Worth revisiting: adaptive
        # at `effort: "low"` is a one-line experiment now the ceiling has room
        # for it, and the judgement calls this thing makes (progression,
        # recovery-aware programming) are the kind of work thinking helps.
        thinking={"type": "disabled"},
        # A recap plus a full Warm-up/Working Set/Back-off/Form block runs
        # close to 1000 tokens, and ab days — which enumerate every straight
        # set inline — routinely exceed it. Truncating mid-block leaves the
        # parser a partial prescription that still looks well-formed, so the
        # card renders half a plan with nothing reporting an error. Output is
        # billed per token generated, not per token allowed, and max_tokens is
        # never shown to the model, so a higher ceiling costs nothing until a
        # reply actually needs it.
        #
        # Raised from 2000 with the move to Sonnet 5, whose tokenizer produces
        # roughly 1.35x the tokens for identical text (its 1M window holds
        # ~555k words against Sonnet 4.6's ~750k). A 1400-token prescription
        # becomes ~1900 without a word being added, which brushes the old
        # ceiling on exactly the long ab days flagged above.
        max_tokens=4000,
        # Three blocks, breakpoint after the second. The context used to be
        # one lump AFTER the only breakpoint, so all ~4k tokens of it were
        # re-billed on every request — a third of the cost of a logged set.
        # Splitting it by volatility puts the day-stable part (30-day recovery,
        # sessions before today, Apple workouts, substitutions) inside the
        # cached prefix, leaving only today's sets and the live workout state
        # outside it. Caching is a prefix match, so the stable block must
        # physically precede the live one — that ordering is load-bearing.
        system=[
            {"type": "text", "text": system_prompt},
            {"type": "text", "text": stable_context,
             "cache_control": {"type": "ephemeral", "ttl": "1h"}},
            {"type": "text", "text": live_context},
        ],
        messages=messages_to_send,
    )

    _log_cache_usage(response)

    if not response.content:
        assistant_message = "Sorry, I couldn't generate a response. Please try again."
    else:
        assistant_message = response.content[0].text

    # A reply cut off at the token ceiling is the one failure the parsers
    # cannot see: a prescription truncated mid-block still matches the
    # `Warm-up:` / `Working Set:` prefixes it managed to emit, so the card
    # renders a partial plan and the athlete is left asking for it again.
    # Nothing here can un-truncate it, but it must not pass silently.
    if getattr(response, "stop_reason", None) == "max_tokens":
        log.warning(
            "Coach reply hit max_tokens — prescription may be truncated (%d chars)",
            len(assistant_message),
        )
    # The set count the coach was HANDED, checked against the one it sent.
    #
    # format_session_template puts an explicit "Seated Leg Curl: 3 working sets"
    # into the live context on every Legs day, and replies came back with 2
    # anyway. Nothing downstream noticed: the app renders whatever chips the
    # reply parses to, marks the session complete against that same number, and
    # the log then shows a 2-set session as though it were prescribed.
    #
    # Log-only on purpose. Editing the reply would mean inventing a load and
    # rep target the coach never chose, and a re-ask mid-exercise can return a
    # partial block, which the app applies by replacing the entire card —
    # including the athlete's completed-set checkmarks. Making the divergence
    # visible is the fix; deciding what to do about it needs the log first.
    # Correct a surplus BEFORE the reply leaves, then report what is left.
    #
    # Logging the divergence was not enough. The count is computed, handed over
    # as an explicit lookup, and a Pull session still went out with three sets of
    # Reverse Cable Fly against a template of two — a week after the same session
    # had correctly explained why it is two. Both replies were defensible; only
    # one was right; and from the athlete's side the pair is indistinguishable
    # from randomness, which costs the correct reply its authority too.
    #
    # Only surplus sets are removed. An under-count is left alone and reported,
    # because filling one means inventing a load and a rep target the coach never
    # chose.
    try:
        assistant_message, trimmed = enforce_set_counts(
            assistant_message, system_prompt, today_type,
        )
        for fix in trimmed:
            log.warning(
                "SET COUNT TRIMMED (%s): %s had %d surplus %s set(s) against a "
                "template of %d — removed before sending",
                today_type, fix["exercise"], fix["dropped"], fix["phase"],
                fix["target"],
            )
    except Exception:
        log.exception("Set-count enforcement failed")

    try:
        counts = check_set_counts(assistant_message, system_prompt, today_type)
        for bad in counts["mismatches"]:
            log.warning(
                "SET COUNT DRIFT (%s): %s prescribed %d working sets, template "
                "says %d, and the reply gives no reason",
                today_type, bad["exercise"], bad["actual"], bad["expected"],
            )
        for chosen in counts["deliberate"]:
            # Not a fault. Logged because a run of these on one exercise means
            # the template is the thing that is wrong.
            log.info(
                "Set count deviated deliberately (%s): %s prescribed %d "
                "against a template of %d, marked Revised:",
                today_type, chosen["exercise"], chosen["actual"],
                chosen["expected"],
            )
        if counts["unmatched"]:
            # Not an error — substitutions and the whole Cardio+Abs day have no
            # template line. Logged so the check's real coverage is visible
            # rather than assumed from a silent zero.
            log.info(
                "Set-count check skipped %d block(s) with no template entry: %s",
                len(counts["unmatched"]), ", ".join(counts["unmatched"]),
            )
    except Exception:
        # A reply must never fail to reach the athlete because a check on it
        # raised.
        log.exception("Set-count check failed")

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
                            out_prs: list | None = None,
                            recovery_override: dict | None = None,
                            allow_set_logging: bool = True) -> str:
    """Process a user message, log any sets, and return the coach reply.

    `allow_set_logging` MUST be False for callers whose client persists its own
    sets — which is every iOS caller. The app writes each set straight to
    Supabase and then sends a chat message; if the backend also parses that
    conversation for weight x reps patterns, any number-shaped phrase the
    athlete types becomes a phantom set. `is_ios_structured_log` catches the
    app's own "Logged working 1 of 1: ..." messages, but free-form chat from
    the in-workout composer looks like ordinary text, so it was unguarded: a
    Push session picked up a "Leg press 60kg x 1" row this way.

    If `out_prs` is provided, every set that beats the historical e1RM by >1%
    is appended as a dict so callers (the iOS /api/chat endpoint) can surface
    the celebration in-app. Telegram callers can leave it None.

    `recovery_override`, when provided by the iOS app, is the authoritative
    recovery snapshot already shown on the dashboard. The coach reasons over it
    verbatim so its "today's recovery" can never disagree with what the athlete
    sees on screen. Telegram/CLI callers leave it None and fall back to the
    database-derived snapshot.
    """
    conversation_history = load_today_conversation()
    normalised_text = incoming_text.lower().replace("'", "'").strip()
    mesocycle_day = _safe_int(memory.get("mesocycle_day", 1))
    expected_session_type = get_session_type_for_day(
        mesocycle_day, memory.get(SESSION_OVERRIDE_KEY)
    )

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
                    expected_session_type = get_session_type_for_day(
                        mesocycle_day, memory.get(SESSION_OVERRIDE_KEY)
                    )
        except Exception:
            log.exception("Stale session check failed")

    # ── "replay" command ──────────────────────────────────────────────────────
    # Replays prescribe.py (the programme as code) against real logged history
    # and returns the comparison verbatim — no model call, so the numbers are
    # computed rather than narrated.
    #
    # It sits here — after the stale-session guard, before anything that reads
    # the message for training content — because this is the one code path
    # both surfaces share: the iOS coach chat posts to /api/chat and Telegram
    # posts to /webhook, and both land in this function. That makes "replay" a
    # command the athlete can run by typing one word into the app he already
    # uses — no admin URL, no API token to look up, no app release. The
    # /admin/replay route still exists and is unchanged; this is the same report
    # reachable without a browser.
    #
    # The guard above still runs: a session left active from a previous day has
    # to be closed and the mesocycle advanced whatever today's first message
    # happens to be, and returning ahead of it would defer a correctness fix,
    # not just a formatting one.
    #
    # The REPORT is not persisted — today's conversation is replayed into the
    # model's context on every later request, so a few hundred lines of table
    # would crowd out the actual session and be re-billed all day. A short
    # SUMMARY is, because persisting nothing costs two things that token
    # argument does not cover: the iOS app reloads its transcript from the
    # conversations table whenever the chat reappears, so the report would
    # vanish on a tab switch, and a follow-up question would reach the model
    # with no record that a replay ever ran.
    replay_match = re.match(r'^/?replay(?:\s+(\d+))?$', normalised_text)
    if replay_match:
        days = int(replay_match.group(1) or DEFAULT_REPLAY_DAYS)
        # Never into a live session on the app's own path. The in-workout
        # composer feeds every /api/chat reply through applyAIResponse, which —
        # when nothing parses as a prescription, and this report has no "*"
        # markers so nothing does — falls through to detectExerciseTransition.
        # That is a bare substring scan over the whole reply
        # (PrescriptionParser.swift:301), and the report names every exercise in
        # the day's plan, so it matches the first one in plan order and jumps
        # the card off the lift he is mid-way through, permanently reordering
        # what is up next. A read-only diagnostic must not be able to do that.
        #
        # Telegram (send_reply=True) drives no card and is unaffected, so it
        # still gets the report mid-session.
        if not send_reply and get_workout_state().get("workout_mode") == "active":
            message = ("You're mid-session, so I'm holding the replay — it "
                       "names every exercise in today's plan, and posting that "
                       "into the workout chat would move your card off the lift "
                       "you're on. Finish the session and run `replay` again.")
            save_conversation_message("user", incoming_text)
            save_conversation_message("assistant", message)
            return message

        try:
            from replay import run_chat_replay  # local: keeps import order flat
            report, summary = run_chat_replay(days)
        except Exception as exc:
            # Never raise at the athlete: a failed replay must read as a failed
            # replay, not as a 500 in the app or silence in Telegram.
            log.exception("Replay command failed")
            report = (f"Replay failed: {exc}\n\n"
                      f"This is a diagnostic, so nothing about your training is "
                      f"affected.")
            summary = f"A replay was requested but failed: {exc}"
        try:
            save_conversation_message("user", incoming_text)
            save_conversation_message("assistant", summary)
        except Exception:
            # The transcript is a convenience here, not the deliverable — the
            # athlete already has the report in front of him either way.
            log.exception("Could not record the replay in the transcript")
        if send_reply:
            send_telegram_message(report)
        return report

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

    # Either the app's own structured log line, or a caller that logs its
    # own sets. Both mean: do not parse this message for set data.
    ios_log = is_ios_structured_log(incoming_text) or not allow_set_logging

    if not workout_active and not ios_log:
        parsed_preview = parse_set_from_message(incoming_text)
        # Skip the implicit-start path when today already has a session: a
        # stray set-shaped message after the real workout ended must not
        # spawn a phantom "Active" session that lingers for days.
        should_implicit_start = bool(parsed_preview) and not has_session_for_today()
        if should_implicit_start:
            implicit_type = infer_session_type_from_recent(conversation_history, expected_session_type)
            session_id = start_session(implicit_type)
            if session_id:
                state = get_workout_state()
                workout_active = state.get("workout_mode") == "active"

    _active_exercise = (state.get("current_exercise_name") or "").strip()
    all_sets: list = []
    unresolved_candidate = ""
    inherited_attribution: tuple[str, int] | None = None

    if workout_active and session_id and not ios_log:
        all_sets = parse_all_sets_from_message(incoming_text)
        set_data = all_sets[0] if all_sets else None
        warmup = is_warmup_set(incoming_text)

        if all_sets:
            current_set_base = int(state.get("current_set_number", 0))

            # Resolved the same way the incoming one is, so a state value
            # written before a rename does not read as a different exercise.
            previous_exercise = resolve_exercise_name(_active_exercise) or _active_exercise
            explicit_exercise = extract_exercise_from_set_message(incoming_text)
            exercise = resolve_exercise_name(explicit_exercise)
            # Whether the athlete named the lift or we inferred it. Over
            # Telegram a set usually arrives as bare numbers ("101 x 12"), so
            # inference is the norm rather than the exception — and when it is
            # wrong it is wrong silently, for as long as it takes him to
            # notice. One Cardio+Abs session filed eight sets spanning 37.5kg
            # to 120kg under a single exercise this way.
            exercise_was_named = bool(exercise)
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

            # Refuse to persist a set when we can't pin it to an exercise.
            # Writing rows under the literal string "Unknown" buries the data
            # in history and makes the user think the session is broken.
            # Instead, leave the set unlogged and surface the unresolved
            # candidate (or a generic "what was that?") via the coach reply.
            if exercise == "Unknown":
                print(f"Skipping log_set: no resolvable exercise for {len(all_sets)} set(s)")
                if not unresolved_candidate:
                    unresolved_candidate = "that set"
            else:
                # A new exercise starts its own count. current_set_number is
                # seeded to 0 when the SESSION starts and never again, so on
                # the Telegram path it ran straight through a machine change —
                # three sets of cable crunch then a calf raise gave the calf
                # raise sets 4, 5 and 6. The iOS app numbers per exercise, so
                # the same session logged two ways produced two different
                # histories, and only one of them was right.
                if exercise != previous_exercise:
                    current_set_base = 0

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

                if not exercise_was_named:
                    inherited_attribution = (exercise, len(all_sets))

                _active_exercise = exercise
                set_workout_state({
                    "current_set_number": str(current_set_base + len(all_sets)),
                    "current_exercise_name": _active_exercise,
                })

    # ── Get coach response ────────────────────────────────────────────────────
    response = chat_with_coach(incoming_text, conversation_history, memory,
                               recovery_override=recovery_override)

    if inherited_attribution:
        guessed, count = inherited_attribution
        plural = "" if count == 1 else "s"
        response = (
            f"Logged {count} set{plural} to *{guessed}* — you didn't name a lift, "
            f"so I used the last one. Say the exercise name if that's wrong.\n\n"
            + response
        )

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
