"""
coach_context.py - Context fetchers and prompt assembly for the coach.

These functions read recent training/recovery state from Supabase and shape
it into the [ATHLETE CONTEXT] block injected into Claude's system prompt.
"""

from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta

from data import CYCLE, get_athlete_context, get_supabase, now_local
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


def build_context_block(memory: dict, athlete_name: str,
                        athlete_current_weight_kg: int,
                        athlete_goal_weight_kg: int,
                        log) -> str:
    today = now_local().strftime("%A %d %B %Y")
    mesocycle_week = memory.get("mesocycle_week", 1)
    mesocycle_day = _safe_int(memory.get("mesocycle_day", 1))
    today_session = CYCLE[(mesocycle_day - 1) % len(CYCLE)]
    next_session = CYCLE[mesocycle_day % len(CYCLE)]

    with ThreadPoolExecutor(max_workers=5) as executor:
        futures = {
            executor.submit(get_athlete_context): "data",
            executor.submit(get_full_session_history, 30): "session_history",
            executor.submit(get_recovery_history, 30): "recovery_history",
            executor.submit(get_substitution_history): "substitution_history",
            executor.submit(get_apple_workouts, 30): "apple_workouts",
            executor.submit(get_workout_state): "workout_state",
        }
        results = {}
        for future, key in futures.items():
            try:
                results[key] = future.result(timeout=10)
            except Exception:
                log.exception("Context fetch failed (%s)", key)
                results[key] = None

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

    session_history = results.get("session_history") or "No sessions found."
    recovery_history = results.get("recovery_history") or "No recovery data."
    substitution_history = results.get("substitution_history") or ""
    apple_workouts = results.get("apple_workouts") or ""
    workout_state = results.get("workout_state") or {}
    workout_context = get_workout_context(workout_state)

    return f"""
[ATHLETE CONTEXT]
Athlete: {athlete_name} | Current weight: {athlete_current_weight_kg}kg | Goal weight: {athlete_goal_weight_kg}kg
Date: {today}
Mesocycle: Week {mesocycle_week} of 4 | Cycle day {mesocycle_day}/5
TODAY'S SESSION TYPE: {today_session}
NEXT SESSION: {next_session}

TODAY'S RECOVERY:
Recovery data date: {data.get('date', 'Unknown')} | Freshness: {freshness}
Sleep: {data.get('sleep_hours', 'N/A')} hrs | HRV: {data.get('hrv', 'N/A')} (7-day avg: {data.get('hrv_avg', 'N/A')}) | Status: {data.get('hrv_status', 'Unknown')}
Resting HR: {data.get('resting_hr', 'N/A')} bpm (7-day avg: {data.get('resting_hr_baseline', 'N/A')})
Avg HR: {data.get('heart_rate', 'N/A')} bpm | Respiratory rate: {data.get('respiratory_rate', 'N/A')} | Steps: {data.get('steps', 'N/A')} | Active energy: {data.get('active_energy_kcal', 'N/A')} kcal | Exercise minutes: {data.get('exercise_minutes', 'N/A')}
Body weight: {data.get('weight_kg', 'N/A')}kg | Body fat: {data.get('body_fat_pct', 'N/A')}% | VO2 max: {data.get('vo2_max', 'N/A')}

LAST 30 DAYS RECOVERY:
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


def truncate_history(history: list) -> list:
    """Keep the most recent messages to avoid exceeding Claude's context window."""
    if len(history) <= MAX_CONVERSATION_MESSAGES:
        return history
    return history[-MAX_CONVERSATION_MESSAGES:]
