"""
memory.py - Persistent memory using Supabase.
Replaces the old memory.json file approach.
"""

import os
from datetime import datetime

from data import CYCLE, get_supabase, now_local, today_local_str


def load_memory() -> dict:
    """Load memory from Supabase memory table."""
    try:
        supabase = get_supabase()
        if not supabase:
            raise ValueError("No Supabase connection")
        result = supabase.table("memory").select("key, value").execute()
        memory = {row["key"]: row["value"] for row in result.data}

        for key in ["mesocycle_week", "mesocycle_day"]:
            if key in memory:
                try:
                    memory[key] = int(memory[key])
                except (TypeError, ValueError):
                    memory[key] = 1

        print(
            f"Memory loaded. Mesocycle: Week {memory.get('mesocycle_week', 1)}, "
            f"Day {memory.get('mesocycle_day', 1)}"
        )
        return memory
    except Exception as e:
        print(f"Supabase memory load failed: {e}. Using defaults.")
        return {
            "mesocycle_week": 1,
            "mesocycle_day": 1,
        }


def save_memory(memory: dict):
    """Save key memory values to Supabase."""
    try:
        supabase = get_supabase()
        for key in ["mesocycle_week", "mesocycle_day"]:
            if key in memory:
                supabase.table("memory").upsert({
                    "key": key,
                    "value": str(memory[key]),
                    "updated_at": now_local().isoformat(),
                }).execute()
    except Exception as e:
        print(f"Supabase memory save failed: {e}")


def save_conversation_message(role: str, content: str):
    """Save a single message to the conversations table."""
    try:
        supabase = get_supabase()
        supabase.table("conversations").insert({
            "date": today_local_str(),
            "role": role,
            "content": content,
            "created_at": now_local().isoformat(),
        }).execute()
    except Exception as e:
        print(f"Failed to save conversation message: {e}")


def load_today_conversation() -> list:
    """Load today's conversation history from Supabase."""
    try:
        supabase = get_supabase()
        today = today_local_str()
        result = (
            supabase.table("conversations")
            .select("role, content")
            .eq("date", today)
            .order("created_at")
            .execute()
        )
        return [{"role": row["role"], "content": row["content"]} for row in result.data]
    except Exception as e:
        print(f"Failed to load conversation: {e}")
        return []


def log_session(session: dict):
    """Save a completed workout session to Supabase."""
    try:
        supabase = get_supabase()
        supabase.table("sessions").insert({
            "date": session.get("date", today_local_str()),
            "type": session.get("type", "Unknown"),
            "summary": session.get("summary", ""),
            "tonnage_kg": session.get("tonnage_kg"),
            "notes": session.get("notes", ""),
            "mesocycle_week": session.get("mesocycle_week", 1),
            "mesocycle_day": session.get("mesocycle_day", 1),
        }).execute()
        print(f"Session logged: {session.get('type')} on {session.get('date')}")
    except Exception as e:
        print(f"Failed to log session: {e}")


def save_recovery_data(data: dict):
    """Save daily Apple Health recovery data using upsert on date."""
    try:
        supabase = get_supabase()
        row = {
            k: v
            for k, v in {
                "date": data.get("date", today_local_str()),
                "sleep_hours": data.get("sleep_hours"),
                "hrv": data.get("hrv"),
                "hrv_status": data.get("hrv_status"),
                "resting_hr": data.get("resting_hr"),
                "heart_rate": data.get("heart_rate"),
                "steps": data.get("steps"),
                "active_energy_kcal": data.get("active_energy_kcal"),
                "weight_kg": data.get("weight_kg"),
                "body_fat_pct": data.get("body_fat_pct"),
                "exercise_minutes": data.get("exercise_minutes"),
                "respiratory_rate": data.get("respiratory_rate"),
                "vo2_max": data.get("vo2_max"),
            }.items()
            if v is not None
        }
        supabase.table("recovery").upsert(row, on_conflict="date").execute()
        print(f"Recovery data saved for {row.get('date')}")
    except Exception as e:
        print(f"Failed to save recovery data: {e}")


def get_current_session_type(memory: dict) -> str:
    """Return today's session type based on cycle position."""
    day = int(memory.get("mesocycle_day", 1)) - 1
    return CYCLE[day % len(CYCLE)]


def get_next_session_type(memory: dict) -> str:
    """Return tomorrow's session type."""
    day = int(memory.get("mesocycle_day", 1))
    return CYCLE[day % len(CYCLE)]


def advance_mesocycle(memory: dict):
    """Advance mesocycle day after a session using fresh DB state."""
    fresh_memory = load_memory()
    current_day = int(fresh_memory.get("mesocycle_day", 1))
    next_day = (current_day % len(CYCLE)) + 1
    fresh_memory["mesocycle_day"] = next_day

    if current_day == len(CYCLE):
        fresh_memory["mesocycle_week"] = (int(fresh_memory.get("mesocycle_week", 1)) % 4) + 1

    save_memory(fresh_memory)
    memory["mesocycle_day"] = fresh_memory["mesocycle_day"]
    memory["mesocycle_week"] = fresh_memory["mesocycle_week"]
    print(f"Mesocycle advanced: day {current_day} -> {next_day}")
