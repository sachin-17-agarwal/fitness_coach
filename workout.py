"""
workout.py — Workout mode state management.
Handles session state, set logging, PR detection, fatigue detection,
substitution memory, and session summaries.
"""

import os
from datetime import datetime, timedelta

def get_supabase():
    from supabase import create_client
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_KEY")
    if not url or not key:
        return None
    return create_client(url, key)

# ── Session State ─────────────────────────────────────────────────────────────

def get_workout_state() -> dict:
    """Load current workout state from Supabase memory table."""
    try:
        supabase = get_supabase()
        result = supabase.table("memory").select("key, value").in_(
            "key", ["workout_mode", "current_session_id", "current_exercise_index",
                    "current_set_number", "session_start_time"]
        ).execute()
        return {r["key"]: r["value"] for r in result.data}
    except Exception as e:
        print(f"Failed to load workout state: {e}")
        return {"workout_mode": "inactive"}

def set_workout_state(updates: dict):
    """Update workout state keys in Supabase memory table."""
    try:
        supabase = get_supabase()
        for key, value in updates.items():
            supabase.table("memory").upsert({
                "key": key,
                "value": str(value),
                "updated_at": datetime.now().isoformat()
            }).execute()
    except Exception as e:
        print(f"Failed to update workout state: {e}")

def is_workout_active() -> bool:
    state = get_workout_state()
    return state.get("workout_mode") == "active"

def start_session(session_type: str) -> str:
    """Create a new workout session and activate workout mode."""
    try:
        supabase = get_supabase()
        result = supabase.table("workout_sessions").insert({
            "date": datetime.now().strftime("%Y-%m-%d"),
            "type": session_type,
            "status": "active",
            "start_time": datetime.now().isoformat()
        }).execute()
        session_id = result.data[0]["id"]
        set_workout_state({
            "workout_mode": "active",
            "current_session_id": session_id,
            "current_exercise_index": "0",
            "current_set_number": "0",
            "session_start_time": datetime.now().isoformat()
        })
        return session_id
    except Exception as e:
        print(f"Failed to start session: {e}")
        return ""

def end_session(session_id: str) -> dict:
    """Mark session complete and calculate summary stats."""
    try:
        supabase = get_supabase()

        # Calculate total tonnage
        sets = supabase.table("workout_sets")\
            .select("actual_weight_kg, actual_reps, is_warmup")\
            .eq("workout_session_id", session_id)\
            .execute()

        tonnage = sum(
            (s["actual_weight_kg"] or 0) * (s["actual_reps"] or 0)
            for s in sets.data
            if not s.get("is_warmup")
        )

        supabase.table("workout_sessions").update({
            "status": "complete",
            "end_time": datetime.now().isoformat(),
            "tonnage_kg": round(tonnage, 1)
        }).eq("id", session_id).execute()

        set_workout_state({
            "workout_mode": "inactive",
            "current_session_id": "",
            "current_exercise_index": "0",
            "current_set_number": "0"
        })

        return {"tonnage_kg": tonnage, "total_sets": len(sets.data)}
    except Exception as e:
        print(f"Failed to end session: {e}")
        return {}

# ── Set Logging ───────────────────────────────────────────────────────────────

def log_set(session_id: str, exercise: str, set_number: int,
            actual_weight: float, actual_reps: int, actual_rpe: float = None,
            target_weight: float = None, target_reps: int = None,
            target_rpe: float = None, is_warmup: bool = False,
            rest_seconds: int = None, notes: str = None) -> dict:
    """Log a completed set and return PR info + fatigue analysis."""
    try:
        supabase = get_supabase()
        supabase.table("workout_sets").insert({
            "workout_session_id": session_id,
            "date": datetime.now().strftime("%Y-%m-%d"),
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
            "logged_at": datetime.now().isoformat()
        }).execute()

        pr_info = check_pr(exercise, actual_weight, actual_reps)
        return pr_info
    except Exception as e:
        print(f"Failed to log set: {e}")
        return {}

# ── PR Detection ──────────────────────────────────────────────────────────────

def check_pr(exercise: str, weight: float, reps: int) -> dict:
    """Check if this set is a PR for this exercise."""
    try:
        supabase = get_supabase()

        # Check historical sets for this exercise
        result = supabase.table("workout_sets")\
            .select("actual_weight_kg, actual_reps")\
            .eq("exercise", exercise)\
            .eq("is_warmup", False)\
            .execute()

        if not result.data:
            return {"is_pr": False}

        # Calculate 1RM estimate using Epley formula: w * (1 + r/30)
        def estimated_1rm(w, r):
            return w * (1 + r / 30) if w and r else 0

        current_1rm = estimated_1rm(weight, reps)
        previous_best = max(
            (estimated_1rm(s["actual_weight_kg"], s["actual_reps"])
             for s in result.data),
            default=0
        )

        if current_1rm > previous_best * 1.01:  # 1% threshold to avoid noise
            return {
                "is_pr": True,
                "estimated_1rm": round(current_1rm, 1),
                "previous_best": round(previous_best, 1),
                "improvement_pct": round((current_1rm - previous_best) / previous_best * 100, 1)
            }
        return {"is_pr": False}
    except Exception as e:
        print(f"PR check failed: {e}")
        return {"is_pr": False}

# ── Fatigue Detection ─────────────────────────────────────────────────────────

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

        reps = [s["actual_reps"] for s in sets.data if s["actual_reps"]]
        if len(reps) < 2:
            return {"fatigued": False}

        # Flag if reps drop more than 30% from first to last set
        drop_pct = (reps[0] - reps[-1]) / reps[0] * 100
        if drop_pct > 30:
            return {
                "fatigued": True,
                "drop_pct": round(drop_pct, 1),
                "recommendation": "significant_fatigue"
            }
        elif drop_pct > 20:
            return {
                "fatigued": True,
                "drop_pct": round(drop_pct, 1),
                "recommendation": "moderate_fatigue"
            }
        return {"fatigued": False}
    except Exception as e:
        print(f"Fatigue check failed: {e}")
        return {"fatigued": False}

# ── Session Time ──────────────────────────────────────────────────────────────

def get_session_duration_minutes(state: dict) -> int:
    """Return how long the current session has been running."""
    try:
        start = state.get("session_start_time", "")
        if not start:
            return 0
        start_dt = datetime.fromisoformat(start)
        return int((datetime.now() - start_dt).total_seconds() / 60)
    except:
        return 0

# ── Substitution Memory ───────────────────────────────────────────────────────

def log_substitution(original: str, substitution: str, reason: str = ""):
    """Remember when an exercise was substituted."""
    try:
        supabase = get_supabase()
        supabase.table("exercise_substitutions").insert({
            "original_exercise": original,
            "substitution": substitution,
            "reason": reason,
            "created_at": datetime.now().isoformat()
        }).execute()
    except Exception as e:
        print(f"Failed to log substitution: {e}")

def get_substitution_history() -> str:
    """Return recent substitution history for context injection."""
    try:
        supabase = get_supabase()
        result = supabase.table("exercise_substitutions")\
            .select("original_exercise, substitution, reason, created_at")\
            .order("created_at", desc=True)\
            .limit(20)\
            .execute()
        if not result.data:
            return "No substitutions recorded."
        lines = [f"  {r['original_exercise']} → {r['substitution']}" +
                 (f" ({r['reason']})" if r.get("reason") else "")
                 for r in result.data]
        return "\n".join(lines)
    except:
        return ""

# ── Context for Coach ─────────────────────────────────────────────────────────

def get_workout_context(state: dict) -> str:
    """Build workout mode context block for injection into coach."""
    if state.get("workout_mode") != "active":
        return ""

    session_id = state.get("current_session_id", "")
    exercise_index = int(state.get("current_exercise_index", 0))
    set_number = int(state.get("current_set_number", 0))
    duration = get_session_duration_minutes(state)

    try:
        supabase = get_supabase()

        # Get session info
        session = supabase.table("workout_sessions")\
            .select("type, date")\
            .eq("id", session_id)\
            .execute()
        session_type = session.data[0]["type"] if session.data else "Unknown"

        # Get sets logged so far this session
        sets = supabase.table("workout_sets")\
            .select("exercise, set_number, actual_weight_kg, actual_reps, actual_rpe, is_warmup")\
            .eq("workout_session_id", session_id)\
            .order("logged_at")\
            .execute()

        sets_text = ""
        if sets.data:
            lines = []
            for s in sets.data:
                warmup_tag = " (warmup)" if s.get("is_warmup") else ""
                rpe_tag = f" @RPE{s['actual_rpe']}" if s.get("actual_rpe") else ""
                lines.append(f"  {s['exercise']} set{s['set_number']}{warmup_tag}: "
                            f"{s['actual_weight_kg']}kg x {s['actual_reps']}{rpe_tag}")
            sets_text = "\n".join(lines)

        duration_warning = ""
        if duration >= 90:
            duration_warning = f"\n⚠️ SESSION TIME: {duration} minutes — suggest wrapping up"

        return f"""
[WORKOUT MODE — ACTIVE]
Session type: {session_type}
Exercise index: {exercise_index}
Current set: {set_number}
Session duration: {duration} minutes{duration_warning}

Sets logged this session:
{sets_text or 'None yet'}
[END WORKOUT CONTEXT]
"""
    except Exception as e:
        return f"[WORKOUT MODE — ACTIVE] (context load failed: {e})"
