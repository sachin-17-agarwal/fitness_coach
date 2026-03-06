"""
memory.py — Persistent memory for the coach.

Stores:
- Mesocycle position (week + day)
- Recent session history
- Conversation history per day
- Any long-term notes the coach has made
"""

import json
import os
from datetime import datetime

MEMORY_FILE = "memory.json"

def load_memory() -> dict:
    """Load memory from disk. Returns empty dict if no memory file exists."""
    if not os.path.exists(MEMORY_FILE):
        print("📂 No memory file found. Starting fresh.")
        return {
            "mesocycle_week": 1,
            "mesocycle_day": 1,
            "recent_sessions": [],
            "conversations": {},
            "notes": [],
            "created_at": datetime.now().isoformat()
        }
    
    with open(MEMORY_FILE, "r") as f:
        memory = json.load(f)
        print(f"📂 Memory loaded. Mesocycle: Week {memory.get('mesocycle_week', 1)}, "
              f"Day {memory.get('mesocycle_day', 1)}")
        return memory

def save_memory(memory: dict):
    """Save memory to disk."""
    memory["last_updated"] = datetime.now().isoformat()
    with open(MEMORY_FILE, "w") as f:
        json.dump(memory, f, indent=2)

def add_coach_note(memory: dict, note: str):
    """
    Add a long-term note to memory.
    Use this for things the coach should always remember:
    e.g. "athlete mentioned right knee pain on 2024-01-10"
    """
    if "notes" not in memory:
        memory["notes"] = []
    
    memory["notes"].append({
        "date": datetime.now().strftime("%Y-%m-%d"),
        "note": note
    })
    save_memory(memory)
    print(f"📝 Note saved: {note}")

def get_notes_text(memory: dict) -> str:
    """Format notes for injection into context."""
    notes = memory.get("notes", [])
    if not notes:
        return "No long-term notes."
    return "\n".join([f"  [{n['date']}] {n['note']}" for n in notes[-10:]])

def reset_mesocycle(memory: dict):
    """Start a new mesocycle."""
    memory["mesocycle_week"] = 1
    memory["mesocycle_day"] = 1
    save_memory(memory)
    print("🔄 Mesocycle reset to Week 1, Day 1.")

def get_memory_summary(memory: dict) -> str:
    """Print a human-readable summary of current memory state."""
    sessions = memory.get("recent_sessions", [])
    notes = memory.get("notes", [])
    
    return f"""
Memory Summary
──────────────
Mesocycle: Week {memory.get('mesocycle_week', 1)} of 4, Day {memory.get('mesocycle_day', 1)}
Sessions logged: {len(sessions)}
Coach notes: {len(notes)}
Last updated: {memory.get('last_updated', 'Never')}
Last 3 sessions:
{chr(10).join([f"  - {s['date']}: {s['type']} — {s['summary']}" for s in sessions[-3:]]) or '  None yet'}
"""
