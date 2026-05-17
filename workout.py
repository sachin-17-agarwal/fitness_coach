"""
workout.py - Workout mode state management.
Handles session state, set logging, PR detection, fatigue detection,
substitution memory, and session summaries.
"""

import logging
from datetime import datetime, timedelta

from data import get_supabase, now_local, today_local_str

log = logging.getLogger(__name__)

# -- Session State -------------------------------------------------------------

def get_workout_state() -> dict:
    """Load current workout state from Supabase memory table."""
    try:
        supabase = get_supabase()
        if not supabase:
            return {"workout_mode": "inactive"}
        result = supabase.table("memory").select("key, value").in_(
            "key", ["workout_mode", "current_session_id", "current_exercise_index",
                    "current_set_number", "session_start_time", "current_exercise_name"]
        ).execute()
        return {r["key"]: r["value"] for r in result.data}
    except Exception:
        log.exception("Failed to load workout state")
        return {"workout_mode": "inactive"}

def set_workout_state(updates: dict):
    """Update workout state keys in Supabase memory table."""
    try:
        supabase = get_supabase()
        if not supabase:
            return
        for key, value in updates.items():
            supabase.table("memory").upsert({
                "key": key,
                "value": str(value),
                "updated_at": now_local().isoformat()
            }, on_conflict="key").execute()
    except Exception:
        log.exception("Failed to update workout state")

def is_workout_active() -> bool:
    state = get_workout_state()
    return state.get("workout_mode") == "active"

def has_session_for_today() -> bool:
    """Return True if any workout_session row exists for today's local date.

    Used to block the implicit-start path in the coach: once the user has
    started a session for today (whether it's still active, was properly
    completed, or was created by iOS), further chat messages that happen to
    contain a `weight x reps` pattern must not spawn a phantom second session.
    """
    try:
        supabase = get_supabase()
        if not supabase:
            return False
        result = supabase.table("workout_sessions")\
            .select("id")\
            .eq("date", today_local_str())\
            .limit(1)\
            .execute()
        return bool(result.data)
    except Exception:
        log.exception("has_session_for_today failed")
        return False

def start_session(session_type: str) -> str:
    """Create a new workout session and activate workout mode."""
    try:
        existing_state = get_workout_state()
        existing_session_id = existing_state.get("current_session_id", "")
        if existing_state.get("workout_mode") == "active" and existing_session_id:
            print(f"Workout already active. Reusing session {existing_session_id}")
            return existing_session_id

        supabase = get_supabase()
        result = supabase.table("workout_sessions").insert({
            "date": today_local_str(),
            "type": session_type,
            "status": "active",
            "start_time": now_local().isoformat()
        }).execute()
        if not result.data:
            print("Failed to start session: insert returned no data")
            return ""
        session_id = result.data[0]["id"]
        set_workout_state({
            "workout_mode": "active",
            "current_session_id": session_id,
            "current_exercise_index": "0",
            "current_set_number": "0",
            "current_exercise_name": "",
            "session_start_time": now_local().isoformat(),
        })
        return session_id
    except Exception:
        log.exception("Failed to start session")
        return ""

def end_session(session_id: str) -> dict:
    """Mark session complete and calculate summary stats."""
    if not session_id:
        print("end_session called with empty session_id — skipping")
        return {}
    try:
        supabase = get_supabase()

        sets = supabase.table("workout_sets")\
            .select("actual_weight_kg, actual_reps, is_warmup")\
            .eq("workout_session_id", session_id)\
            .execute()

        tonnage = sum(
            (s.get("actual_weight_kg") or 0) * (s.get("actual_reps") or 0)
            for s in (sets.data or [])
            if not s.get("is_warmup")
            and s.get("actual_weight_kg") is not None
            and s.get("actual_reps") is not None
        )

        supabase.table("workout_sessions").update({
            "status": "complete",
            "end_time": now_local().isoformat(),
            "tonnage_kg": round(tonnage, 1)
        }).eq("id", session_id).execute()

        set_workout_state({
            "workout_mode": "inactive",
            "current_session_id": "",
            "current_exercise_index": "0",
            "current_set_number": "0",
            "current_exercise_name": "",
        })

        return {"tonnage_kg": tonnage, "total_sets": len(sets.data)}
    except Exception:
        log.exception("Failed to end session")
        return {}

# -- Set Logging ---------------------------------------------------------------

def log_set(session_id: str, exercise: str, set_number: int,
            actual_weight: float, actual_reps: int, actual_rpe: float = None,
            target_weight: float = None, target_reps: int = None,
            target_rpe: float = None, is_warmup: bool = False,
            rest_seconds: int = None, notes: str = None) -> dict:
    """Log a completed set and return PR info.

    Guards against double-inserts when the same set message is processed twice
    (Telegram webhook retries, parallel iOS + Telegram delivery) by skipping
    when an equivalent row already exists for the same session/set_number.
    """
    try:
        supabase = get_supabase()
        existing = supabase.table("workout_sets")\
            .select("id")\
            .eq("workout_session_id", session_id)\
            .eq("exercise", exercise)\
            .eq("set_number", set_number)\
            .eq("is_warmup", is_warmup)\
            .limit(1)\
            .execute()
        if existing.data:
            print(f"Set already logged: {exercise} set{set_number} — skipping duplicate")
            return {"is_pr": False, "duplicate": True}
        pr_info = check_pr(exercise, actual_weight, actual_reps)
        supabase.table("workout_sets").insert({
            "workout_session_id": session_id,
            "date": today_local_str(),
            "exercise": exercise,
            "set_number": set_number,
            "is_warmup": is_warmup,
            "target_weight_kg": target_weight,
            "target_reps": target_reps,
            "target_rpe": target_rpe,
            "actual_weight_kg": actual_weight,
            "actual_reps": actual_reps,
            "actual_rpe": actual_rpe,
            "rest_seconds": rest_seconds,
            "notes": notes,
            "logged_at": now_local().isoformat()
        }).execute()

        return pr_info
    except Exception:
        log.exception("Failed to log set")
        return {}


def get_last_logged_exercise(session_id: str) -> str:
    """Return the most recent exercise logged for a session."""
    try:
        supabase = get_supabase()
        result = supabase.table("workout_sets")\
            .select("exercise")\
            .eq("workout_session_id", session_id)\
            .order("logged_at", desc=True)\
            .limit(1)\
            .execute()
        if result.data:
            return (result.data[0].get("exercise") or "").strip()
    except Exception:
        log.exception("Failed to fetch last logged exercise")
    return ""

# -- PR Detection --------------------------------------------------------------

def check_pr(exercise: str, weight: float, reps: int) -> dict:
    """Check PR across both workout_sets (new) and sets (historical)."""
    try:
        supabase = get_supabase()

        def estimated_1rm(w, r):
            return w * (1 + r / 30) if w and r else 0

        current_1rm = estimated_1rm(weight, reps)

        r1 = supabase.table("workout_sets")\
            .select("actual_weight_kg, actual_reps")\
            .eq("exercise", exercise)\
            .eq("is_warmup", False)\
            .execute()

        r2 = supabase.table("sets")\
            .select("weight_kg, reps")\
            .eq("exercise", exercise)\
            .execute()

        all_1rms = (
            [estimated_1rm(s["actual_weight_kg"], s["actual_reps"]) for s in r1.data] +
            [estimated_1rm(s["weight_kg"], s["reps"]) for s in r2.data]
        )

        if not all_1rms:
            return {"is_pr": False}

        previous_best = max(all_1rms, default=0)

        if current_1rm > previous_best * 1.01:
            return {
                "is_pr": True,
                "estimated_1rm": round(current_1rm, 1),
                "previous_best": round(previous_best, 1),
                "improvement_pct": round((current_1rm - previous_best) / previous_best * 100, 1)
            }
        return {"is_pr": False}
    except Exception:
        log.exception("PR check failed")
        return {"is_pr": False}

# -- Fatigue Detection ---------------------------------------------------------

def check_fatigue(session_id: str, exercise: str) -> dict:
    """Detect if reps are dropping faster than expected across sets."""
    try:
        supabase = get_supabase()
        sets = supabase.table("workout_sets")\
            .select("set_number, actual_reps, actual_weight_kg")\
            .eq("workout_session_id", session_id)\
            .eq("exercise", exercise)\
            .eq("is_warmup", False)\
            .order("set_number")\
            .execute()

        if len(sets.data) < 2:
            return {"fatigued": False}

        reps = [s["actual_reps"] for s in sets.data if s.get("actual_reps")]
        if len(reps) < 2 or reps[0] <= 0:
            return {"fatigued": False}

        drop_pct = (reps[0] - reps[-1]) / reps[0] * 100
        if drop_pct > 30:
            return {"fatigued": True, "drop_pct": round(drop_pct, 1), "recommendation": "significant_fatigue"}
        elif drop_pct > 20:
            return {"fatigued": True, "drop_pct": round(drop_pct, 1), "recommendation": "moderate_fatigue"}
        return {"fatigued": False}
    except Exception:
        log.exception("Fatigue check failed")
        return {"fatigued": False}

# -- Session Time --------------------------------------------------------------

def get_session_duration_minutes(state: dict) -> int:
    try:
        start = state.get("session_start_time", "")
        if not start:
            return 0
        start_dt = datetime.fromisoformat(start)
        now = now_local()
        # Make start_dt offset-aware if it's naive
        if start_dt.tzinfo is None:
            now = now.replace(tzinfo=None)
        return int((now - start_dt).total_seconds() / 60)
    except Exception:
        return 0

# -- Substitution Memory -------------------------------------------------------

def log_substitution(original: str, substitution: str, reason: str = ""):
    try:
        supabase = get_supabase()
        supabase.table("exercise_substitutions").insert({
            "original_exercise": original,
            "substitution": substitution,
            "reason": reason,
            "created_at": now_local().isoformat()
        }).execute()
    except Exception:
        log.exception("Failed to log substitution")

def get_substitution_history() -> str:
    try:
        supabase = get_supabase()
        result = supabase.table("exercise_substitutions")\
            .select("original_exercise, substitution, reason, created_at")\
            .order("created_at", desc=True)\
            .limit(20)\
            .execute()
        if not result.data:
            return "No substitutions recorded."
        lines = [f"  {r['original_exercise']} -> {r['substitution']}" +
                 (f" ({r['reason']})" if r.get("reason") else "")
                 for r in result.data]
        return "\n".join(lines)
    except Exception:
        return ""

# -- Context for Coach ---------------------------------------------------------

def _find_live_session() -> dict | None:
    """Returns today's `in_progress` workout_sessions row, or None.

    Used as a fallback when the `memory` table doesn't show an active
    session — the iOS app writes directly to workout_sessions and never
    touches the memory key, so without this the coach gets no live
    context at all for app-initiated sessions and has to guess what
    was logged from the chat history alone.
    """
    try:
        supabase = get_supabase()
        if not supabase:
            return None
        today = today_local_str()
        result = supabase.table("workout_sessions")\
            .select("id, type, date, start_time, status")\
            .eq("date", today)\
            .eq("status", "in_progress")\
            .order("start_time", desc=True)\
            .limit(1)\
            .execute()
        rows = result.data or []
        return rows[0] if rows else None
    except Exception as e:
        print(f"Failed to find live session: {e}")
        return None


def get_workout_context(state: dict) -> str:
    """Build the live-session context block injected into the coach prompt.

    Reads from both the memory state (Telegram flow) and today's
    in-progress workout_sessions row (iOS flow). The block is the coach's
    only structured ground truth about what's already been logged this
    session — without it Claude was misquoting actuals (warm-ups quoted
    as working sets, back-off targets quoted as working actuals) because
    the only signal was the latest "Logged …" chat message, which is
    easy to misread mid-conversation.
    """
    session_id = state.get("current_session_id", "") if state else ""
    session_type = None
    duration = 0

    if state and state.get("workout_mode") == "active" and session_id:
        duration = get_session_duration_minutes(state)
    else:
        live = _find_live_session()
        if not live:
            return ""
        session_id = live.get("id", "")
        session_type = live.get("type")
        start_iso = live.get("start_time") or ""
        if start_iso:
            try:
                started = datetime.fromisoformat(start_iso.replace("Z", "+00:00"))
                duration = max(0, int((now_local() - started.astimezone(now_local().tzinfo)).total_seconds() // 60))
            except Exception:
                duration = 0

    if not session_id:
        return ""

    try:
        supabase = get_supabase()
        if not supabase:
            return ""

        if session_type is None:
            session = supabase.table("workout_sessions")\
                .select("type")\
                .eq("id", session_id)\
                .execute()
            session_type = session.data[0]["type"] if session.data else "Unknown"

        sets_result = supabase.table("workout_sets")\
            .select("exercise, set_number, actual_weight_kg, actual_reps, "
                    "actual_rpe, target_weight_kg, target_reps, target_rpe, "
                    "is_warmup, notes, logged_at")\
            .eq("workout_session_id", session_id)\
            .order("logged_at")\
            .execute()
        rows = sets_result.data or []

        # Skip cardio/yoga entries — they share the session but encode
        # duration in actual_reps and would otherwise confuse the
        # strength-focused recap below.
        strength_rows = [
            r for r in rows
            if not (r.get("notes") or "").lower().startswith(("cardio", "yoga"))
        ]

        # Group by exercise so the coach sees structured progress per lift
        # rather than a flat dump. The most recently logged exercise is
        # treated as "current".
        groups: list[tuple[str, list[dict]]] = []
        seen: dict[str, int] = {}
        for r in strength_rows:
            ex = r.get("exercise") or "Unknown"
            if ex in seen:
                groups[seen[ex]][1].append(r)
            else:
                seen[ex] = len(groups)
                groups.append((ex, [r]))

        current_exercise = groups[-1][0] if groups else None

        def fmt_set(r: dict, n: int) -> str:
            phase = "warm-up" if r.get("is_warmup") else "working/back-off"
            w = r.get("actual_weight_kg")
            reps = r.get("actual_reps")
            rpe = r.get("actual_rpe")
            tw = r.get("target_weight_kg")
            treps = r.get("target_reps")
            trpe = r.get("target_rpe")
            actual = f"{w}kg × {reps}" if w is not None and reps is not None else "(no values)"
            if rpe is not None:
                actual += f" @ RPE {rpe}"
            target_parts = []
            if tw is not None and treps is not None:
                t = f"{tw}kg × {treps}"
                if trpe is not None:
                    t += f" @ RPE {trpe}"
                target_parts.append(f"target {t}")
            target_suffix = f" ({', '.join(target_parts)})" if target_parts else ""
            return f"    set {n} {phase}: actual {actual}{target_suffix}"

        lines: list[str] = []
        if groups:
            for ex, ex_sets in groups:
                marker = " ← current exercise" if ex == current_exercise else ""
                lines.append(f"  {ex}{marker}")
                warmups = [r for r in ex_sets if r.get("is_warmup")]
                non_warmups = [r for r in ex_sets if not r.get("is_warmup")]
                for i, r in enumerate(warmups, start=1):
                    lines.append(fmt_set(r, i))
                for i, r in enumerate(non_warmups, start=1):
                    lines.append(fmt_set(r, i))
        sets_text = "\n".join(lines) if lines else "  None yet"

        last_line = ""
        if strength_rows:
            last = strength_rows[-1]
            phase = "warm-up" if last.get("is_warmup") else "working/back-off"
            w = last.get("actual_weight_kg")
            reps = last.get("actual_reps")
            rpe = last.get("actual_rpe")
            rpe_s = f" @ RPE {rpe}" if rpe is not None else ""
            last_line = f"\nMost recently logged: {last.get('exercise')} {phase} {w}kg × {reps}{rpe_s}"

        duration_warning = ""
        if duration >= 90:
            duration_warning = f"\nWARNING SESSION TIME: {duration} minutes — suggest wrapping up"

        current_line = f"\nCurrent exercise: {current_exercise}" if current_exercise else ""

        return f"""
[LIVE WORKOUT — IN PROGRESS]
Session type: {session_type}
Session duration: {duration} minutes{duration_warning}{current_line}{last_line}

Logged this session (grouped by exercise, in order):
{sets_text}

NOTE TO COACH: the values above are persisted ground truth. When the
athlete (or the app) sends a "Logged …" message, those numbers also
appear here — quote them exactly. Never substitute a prescription
target for an actual performance.
[END LIVE WORKOUT]
"""
    except Exception as e:
        return f"[LIVE WORKOUT — IN PROGRESS] (context load failed: {e})"
