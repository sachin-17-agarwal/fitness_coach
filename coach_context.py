"""
coach_context.py - Context fetchers and prompt assembly for the coach.

These functions read recent training/recovery state from Supabase and shape
it into the [ATHLETE CONTEXT] block injected into Claude's system prompt.
"""

from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta

from data import (
    SESSION_OVERRIDE_KEY, get_athlete_context, get_supabase,
    next_session_type_for, now_local, session_type_for,
)
from progression import format_stalls, get_load_stalls
from volume import format_weekly_volume, get_weekly_volume
from workout import get_substitution_history, get_workout_context, get_workout_state

MAX_CONVERSATION_MESSAGES = 40  # Keep last ~20 exchanges to stay within token limits


def _safe_int(value, default: int = 1) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def get_full_session_history(days: int = 30) -> str:
    try:
        supabase = get_supabase()
        if not supabase:
            return "No database connection."
        since = (now_local() - timedelta(days=days)).strftime("%Y-%m-%d")

        all_sessions = []

        ws = supabase.table("workout_sessions")\
            .select("id, date, type, tonnage_kg")\
            .gte("date", since)\
            .order("date", desc=True)\
            .execute()

        session_ids = [s["id"] for s in (ws.data or [])]
        all_sets_data = []
        if session_ids:
            all_sets_result = supabase.table("workout_sets")\
                .select("workout_session_id, exercise, actual_weight_kg, actual_reps, actual_rpe, is_warmup")\
                .in_("workout_session_id", session_ids)\
                .eq("is_warmup", False)\
                .execute()
            all_sets_data = all_sets_result.data or []

        sets_by_session = {}
        for s in all_sets_data:
            sid = s["workout_session_id"]
            sets_by_session.setdefault(sid, []).append(s)

        for s in (ws.data or []):
            all_sessions.append({
                "date": s["date"],
                "type": s["type"],
                "tonnage_kg": s.get("tonnage_kg"),
                "summary": None,
                "sets": sets_by_session.get(s["id"], [])
            })

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
            old_sets_by_session.setdefault(sid, []).append({
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
                    set_str = f"{st.get('actual_weight_kg', '?')}kg x {st.get('actual_reps', '?')}"
                    if st.get("actual_rpe"):
                        set_str += f" @RPE{st['actual_rpe']}"
                    exercises.setdefault(ex, []).append(set_str)
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


def get_recovery_history(days: int = 30) -> str:
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


def _split_history_at_today(history: str, today_iso: str) -> tuple[str, str]:
    """Divide the rendered 30-day log into before-today and today.

    `get_full_session_history` emits one blank-line-separated block per
    session, each starting "YYYY-MM-DD — Type". Everything except today's
    blocks is fixed for the whole day, which is what lets the bulk of the
    context sit behind a cache breakpoint while today's sets — the only part
    that changes as the athlete logs — stays live after it.
    """
    if not history or not history.strip():
        return "No sessions found.", "Nothing logged yet today."
    past, today = [], []
    for block in history.split("\n\n"):
        if not block.strip():
            continue
        (today if block.strip().startswith(today_iso) else past).append(block)
    return (
        "\n\n".join(past) if past else "No earlier sessions in the window.",
        "\n\n".join(today) if today else "Nothing logged yet today.",
    )


def _recovery_from_override(payload: dict) -> dict:
    """Shape a client-supplied recovery snapshot into today's recovery dict.

    The iOS app already holds the authoritative recovery snapshot it renders on
    the dashboard — same HealthKit read, same definition of "today", same row.
    When it sends that snapshot alongside the chat request we use it verbatim
    instead of re-deriving from the database, so the coach reasons over exactly
    the numbers the athlete is looking at. This removes the entire class of
    dashboard/coach disagreements caused by timezone-split rows and the
    fall-back row-picking in get_athlete_context().
    """
    def _g(key):
        value = payload.get(key)
        return value if value is not None else "N/A"

    return {
        "date": payload.get("date") or now_local().strftime("%Y-%m-%d"),
        "data_age_days": 0,  # a live client snapshot is current by definition
        "source": "device",
        "sleep_hours": _g("sleep_hours"),
        "hrv": _g("hrv"),
        "hrv_avg": _g("hrv_avg"),
        "hrv_status": payload.get("hrv_status") or "Unknown",
        "resting_hr": _g("resting_hr"),
        "resting_hr_baseline": _g("resting_hr_baseline"),
        "heart_rate": _g("heart_rate"),
        "steps": _g("steps"),
        "active_energy_kcal": _g("active_energy_kcal"),
        "exercise_minutes": _g("exercise_minutes"),
        "respiratory_rate": _g("respiratory_rate"),
        "weight_kg": _g("weight_kg"),
        "body_fat_pct": _g("body_fat_pct"),
        "vo2_max": _g("vo2_max"),
        "recovery_score": _g("recovery_score"),
        "recovery_zone": payload.get("recovery_zone") or "",
    }


def build_context_block(memory: dict, athlete_name: str,
                        athlete_current_weight_kg: int,
                        athlete_goal_weight_kg: int,
                        log, recovery_override: dict | None = None) -> str:
    today = now_local().strftime("%A %d %B %Y")
    today_iso = now_local().strftime("%Y-%m-%d")
    mesocycle_week = memory.get("mesocycle_week", 1)
    mesocycle_day = _safe_int(memory.get("mesocycle_day", 1))
    # The athlete's per-day override has to reach the prompt, or the coach
    # programmes yoga while the app shows Legs.
    session_override = memory.get(SESSION_OVERRIDE_KEY)
    today_session = session_type_for(mesocycle_day, override=session_override)
    next_session = next_session_type_for(mesocycle_day, override=session_override)

    # One worker per fetch, counting the conditional recovery fetch below —
    # eight, not seven. Fewer would queue the tail behind the head while each
    # still counts against its own 10s timeout. Keep this in step when a fetch
    # is added; it went briefly out of step when the progression fetch landed
    # alongside another branch's changes.
    with ThreadPoolExecutor(max_workers=8) as executor:
        futures = {
            executor.submit(get_full_session_history, 30): "session_history",
            executor.submit(get_recovery_history, 30): "recovery_history",
            executor.submit(get_substitution_history): "substitution_history",
            executor.submit(get_apple_workouts, 30): "apple_workouts",
            executor.submit(get_workout_state): "workout_state",
            executor.submit(get_weekly_volume): "weekly_volume",
            executor.submit(get_load_stalls): "load_stalls",
        }
        # Only hit the DB for today's recovery when the client hasn't supplied
        # its own authoritative snapshot.
        if recovery_override is None:
            futures[executor.submit(get_athlete_context)] = "data"
        results = {}
        for future, key in futures.items():
            try:
                results[key] = future.result(timeout=10)
            except Exception:
                log.exception("Context fetch failed (%s)", key)
                results[key] = None

    if recovery_override:
        data = _recovery_from_override(recovery_override)
        freshness = ("Live from the athlete's device — these are the exact "
                     "numbers shown on their dashboard right now.")
    else:
        data = results.get("data") or {}
        age = data.get("data_age_days")
        if age is None:
            freshness = "⚠️ Recovery data freshness unknown — verify Apple Health has synced before trusting these numbers."
        elif age <= 0:
            freshness = "Fresh (synced today)."
        elif age == 1:
            freshness = "⚠️ STALE: this is yesterday's data — today's Apple Health metrics have not synced yet. Note this to the athlete and don't over-index on it."
        else:
            freshness = f"⚠️ STALE: recovery data is {age} days old — Apple Health has not synced recently. Flag this and program conservatively."

    score = data.get("recovery_score")
    zone = data.get("recovery_zone") or ""
    if score not in (None, "N/A", ""):
        zone_str = f" ({zone})" if zone else ""
        score_line = (f"Recovery score: {score}/100{zone_str} — the headline "
                      f"figure on the athlete's dashboard.\n")
    else:
        score_line = ""

    session_history = results.get("session_history") or "No sessions found."
    # The 30-day log is stable all day EXCEPT for today's rows, which change
    # with every logged set. Separating them is what makes the bulk cacheable.
    past_sessions, today_sessions = _split_history_at_today(session_history, today_iso)
    recovery_history = results.get("recovery_history") or "No recovery data."
    substitution_history = results.get("substitution_history") or ""
    apple_workouts = results.get("apple_workouts") or ""
    workout_state = results.get("workout_state") or {}
    workout_context = get_workout_context(workout_state)
    weekly_volume = format_weekly_volume(results.get("weekly_volume") or {})
    load_stalls = format_stalls(results.get("load_stalls") or [])

    # Split by volatility, not by topic. Everything that only changes once a
    # day goes in the first block so a cache breakpoint can sit between them;
    # everything that moves as sets are logged goes in the second. During a
    # workout the second block is the ONLY part that differs between requests,
    # so the first (~4k tokens) stops being re-billed on every logged set.
    #
    # The two are concatenated in `system`, so the coach reads one continuous
    # context exactly as before — the split is invisible to it.
    stable = f"""
[ATHLETE CONTEXT]
Athlete: {athlete_name} | Current weight: {athlete_current_weight_kg}kg | Goal weight: {athlete_goal_weight_kg}kg
Known limitations: Slight knee and shoulder issues — see coaching profile.

LAST 30 DAYS RECOVERY:
{recovery_history}

SESSIONS BEFORE TODAY (last 30 days):
{past_sessions}

EXERCISE SUBSTITUTION HISTORY:
{substitution_history}

APPLE WATCH WORKOUTS (last 30 days):
{apple_workouts}

PROGRESSION WATCH — top-set load unchanged across 3+ sessions (today excluded):
{load_stalls}
"""

    live = f"""
TODAY — {today}
Mesocycle: Week {mesocycle_week} of 4 | Rotation day {mesocycle_day}/4 (Pull→Push→Legs→Cardio+Abs, rolling; Sunday is yoga and does not advance it)
TODAY'S SESSION TYPE: {today_session}
NEXT SESSION: {next_session}

TODAY'S RECOVERY:
Recovery data date: {data.get('date', 'Unknown')} | Freshness: {freshness}
{score_line}Sleep: {data.get('sleep_hours', 'N/A')} hrs | HRV: {data.get('hrv', 'N/A')} (7-day avg: {data.get('hrv_avg', 'N/A')}) | Status: {data.get('hrv_status', 'Unknown')}
Resting HR: {data.get('resting_hr', 'N/A')} bpm (7-day avg: {data.get('resting_hr_baseline', 'N/A')})
Avg HR: {data.get('heart_rate', 'N/A')} bpm | Respiratory rate: {data.get('respiratory_rate', 'N/A')} | Steps: {data.get('steps', 'N/A')} | Active energy: {data.get('active_energy_kcal', 'N/A')} kcal | Exercise minutes: {data.get('exercise_minutes', 'N/A')}
Body weight: {data.get('weight_kg', 'N/A')}kg | Body fat: {data.get('body_fat_pct', 'N/A')}% | VO2 max: {data.get('vo2_max', 'N/A')}

TODAY'S SESSIONS SO FAR:
{today_sessions}

WEEKLY VOLUME — working sets per muscle, last 7 days (lowest first):
{weekly_volume}
{workout_context}
[END CONTEXT]
"""
    return stable, live


# Phrases that mark a message as stating a CONSTRAINT on the session — an
# injury, a pain, a machine that is unavailable, an explicit instruction to
# skip something. Deliberately narrow: a pinned message costs context on
# every subsequent request, so this must not match ordinary chat.
_CONSTRAINT_MARKERS = (
    "injur", "hurt", "pain", "painful", "tweak", "strain", "sprain",
    "sore shoulder", "sore knee", "sore back", "niggle", "flare",
    "can't do", "cant do", "cannot do", "skip the", "skipping",
    "avoid ", "no pull-ups", "no pullups", "not doing",
    "shoulder is", "knee is", "back is", "elbow is", "wrist is",
)

# Ceiling on pinned messages so a long day of chat can't crowd out the
# recent window it is meant to supplement.
_MAX_PINNED = 6


def _states_a_constraint(message: dict) -> bool:
    if message.get("role") != "user":
        return False
    text = (message.get("content") or "").lower()
    return any(marker in text for marker in _CONSTRAINT_MARKERS)


def truncate_history(history: list) -> list:
    """Keep the most recent messages, plus any earlier ones stating a constraint.

    Plain tail-truncation loses injuries. A Pull session logs ~22 sets, each
    producing an athlete message and a coach reply, so it generates ~44
    messages against a 40-message window — which means a shoulder injury
    mentioned at the START of the session is pushed out of context about
    four-fifths of the way through. The coach then tells him to skip
    pull-ups, and forty messages later asks why he skipped them. That is not
    the coach being unstable; it genuinely cannot see what it was told.

    Constraint-stating messages are therefore pinned: kept in place even
    once they fall outside the recent window, in their original position so
    the conversation still reads chronologically.
    """
    if len(history) <= MAX_CONVERSATION_MESSAGES:
        return history

    recent = history[-MAX_CONVERSATION_MESSAGES:]
    older = history[:-MAX_CONVERSATION_MESSAGES]
    pinned = [m for m in older if _states_a_constraint(m)][-_MAX_PINNED:]
    return pinned + recent
