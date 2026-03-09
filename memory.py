"""
memory.py — Persistent memory using Supabase.
Replaces the old memory.json file approach.
"""

import os
from datetime import datetime
from supabase import create_client, Client

def get_supabase() -> Client:
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_KEY")
    if not url or not key:
        raise ValueError("SUPABASE_URL and SUPABASE_KEY must be set in environment variables")
    return create_client(url, key)

def load_memory() -> dict:
    """Load memory from Supabase memory table."""
    try:
        supabase = get_supabase()
        result = supabase.table("memory").select("key, value").execute()
        memory = {row["key"]: row["value"] for row in result.data}
        
        for key in ["mesocycle_week", "mesocycle_day"]:
            if key in memory:
                memory[key] = int(memory[key])
        
        sessions = supabase.table("sessions")\
            .select("*")\
            .order("date", desc=True)\
            .limit(30)\
            .execute()
        memory["recent_sessions"] = sessions.data or []
        
        print(f"📂 Memory loaded. Mesocycle: Week {memory.get('mesocycle_week', 1)}, Day {memory.get('mesocycle_day', 1)}")
        return memory

    except Exception as e:
        print(f"⚠️  Supabase memory load failed: {e}. Using defaults.")
        return {
            "mesocycle_week": 1,
            "mesocycle_day": 1,
            "recent_sessions": [],
            "conversations": {}
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
                    "updated_at": datetime.now().isoformat()
                }).execute()
    except Exception as e:
        print(f"⚠️  Supabase memory save failed: {e}")

def save_conversation_message(role: str, content: str):
    """Save a single message to the conversations table."""
    try:
        supabase = get_supabase()
        supabase.table("conversations").insert({
            "date": datetime.now().strftime("%Y-%m-%d"),
            "role": role,
            "content": content,
            "created_at": datetime.now().isoformat()
        }).execute()
    except Exception as e:
        print(f"⚠️  Failed to save conversation message: {e}")

def load_today_conversation() -> list:
    """Load today's conversation history from Supabase."""
    try:
        supabase = get_supabase()
        today = datetime.now().strftime("%Y-%m-%d")
        result = supabase.table("conversations")\
            .select("role, content")\
            .eq("date", today)\
            .order("created_at")\
            .execute()
        return [{"role": row["role"], "content": row["content"]} for row in result.data]
    except Exception as e:
        print(f"⚠️  Failed to load conversation: {e}")
        return []

def log_session(session: dict):
    """Save a completed workout session to Supabase."""
    try:
        supabase = get_supabase()
        supabase.table("sessions").insert({
            "date": session.get("date", datetime.now().strftime("%Y-%m-%d")),
            "type": session.get("type", "Unknown"),
            "summary": session.get("summary", ""),
            "tonnage_kg": session.get("tonnage_kg"),
            "notes": session.get("notes", ""),
            "mesocycle_week": session.get("mesocycle_week", 1),
            "mesocycle_day": session.get("mesocycle_day", 1)
        }).execute()
        print(f"✅ Session logged: {session.get('type')} on {session.get('date')}")
    except Exception as e:
        print(f"⚠️  Failed to log session: {e}")

def save_recovery_data(data: dict):
    """Save daily Apple Health recovery data."""
    try:
        supabase = get_supabase()
        supabase.table("recovery").upsert({
            "date": data.get("date", datetime.now().strftime("%Y-%m-%d")),
            "sleep_hours": data.get("sleep_hours"),
            "sleep_quality": data.get("sleep_quality"),
            "hrv": data.get("hrv"),
            "hrv_avg_7day": data.get("hrv_avg_7day"),
            "hrv_status": data.get("hrv_status"),
            "resting_hr": data.get("resting_hr"),
            "resting_hr_baseline": data.get("resting_hr_baseline")
        }).execute()
        print(f"✅ Recovery data saved for {data.get('date')}")
    except Exception as e:
        print(f"⚠️  Failed to save recovery data: {e}")

def advance_mesocycle(memory: dict):
    """Advance mesocycle day/week after a session."""
    memory["mesocycle_day"] = memory.get("mesocycle_day", 1) + 1
    if memory["mesocycle_day"] > 7:
        memory["mesocycle_day"] = 1
        memory["mesocycle_week"] = (memory.get("mesocycle_week", 1) % 4) + 1
    save_memory(memory)
