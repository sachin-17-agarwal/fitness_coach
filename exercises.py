"""
exercises.py — Exercise library and fuzzy matching.

When you log "chest fly" it finds the closest match in your library.
Only asks for confirmation if confidence is low.
"""

from difflib import SequenceMatcher

from data import get_supabase

def similarity(a: str, b: str) -> float:
    """Return similarity score between two strings (0-1)."""
    a, b = a.lower().strip(), b.lower().strip()
    # Exact match
    if a == b:
        return 1.0
    # One contains the other
    if a in b or b in a:
        return 0.9
    return SequenceMatcher(None, a, b).ratio()

def find_exercise(user_input: str, threshold_auto=0.7, threshold_ask=0.5) -> dict:
    """
    Find the best matching exercise from the library.
    
    Returns:
        {
            'status': 'exact' | 'confident' | 'unsure' | 'not_found',
            'match': exercise dict or None,
            'candidates': list of close matches (when unsure),
            'confidence': float
        }
    """
    supabase = get_supabase()
    if not supabase:
        return {"status": "not_found", "match": None, "candidates": [], "confidence": 0}
    
    try:
        result = supabase.table("exercises").select("id, name, muscle_group, aliases").execute()
        exercises = result.data or []
    except Exception:
        return {"status": "not_found", "match": None, "candidates": [], "confidence": 0}
    
    scored = []
    for ex in exercises:
        if not isinstance(ex, dict) or not ex.get("name"):
            continue
        # Check name similarity
        score = similarity(user_input, ex["name"])

        # Check aliases too — guard against non-list values (stored as null,
        # CSV string, or JSON string depending on migration state).
        aliases = ex.get("aliases")
        if isinstance(aliases, list):
            for alias in aliases:
                if not isinstance(alias, str):
                    continue
                alias_score = similarity(user_input, alias)
                score = max(score, alias_score)

        scored.append((score, ex))
    
    scored.sort(key=lambda x: x[0], reverse=True)
    
    if not scored:
        return {"status": "not_found", "match": None, "candidates": [], "confidence": 0}
    
    best_score, best_match = scored[0]
    
    if best_score >= threshold_auto:
        status = "exact" if best_score == 1.0 else "confident"
        return {"status": status, "match": best_match, "candidates": [], "confidence": best_score}
    
    elif best_score >= threshold_ask:
        candidates = [ex for score, ex in scored[:4] if score >= threshold_ask]
        return {"status": "unsure", "match": None, "candidates": candidates, "confidence": best_score}
    
    else:
        return {"status": "not_found", "match": None, "candidates": [], "confidence": best_score}

def add_exercise(name: str, muscle_group: str) -> bool:
    """Add a new exercise to the library."""
    supabase = get_supabase()
    if not supabase:
        return False
    try:
        supabase.table("exercises").insert({
            "name": name.strip(),
            "muscle_group": muscle_group.strip(),
            "aliases": []
        }).execute()
        return True
    except Exception as e:
        print(f"Failed to add exercise: {e}")
        return False

def add_alias(exercise_name: str, alias: str) -> bool:
    """Add an alias to an existing exercise."""
    supabase = get_supabase()
    if not supabase:
        return False
    try:
        result = supabase.table("exercises")\
            .select("id, aliases")\
            .ilike("name", exercise_name)\
            .execute()
        if not result.data:
            return False
        ex = result.data[0]
        aliases = ex.get("aliases")
        if not isinstance(aliases, list):
            aliases = []
        if alias not in aliases:
            aliases.append(alias)
            supabase.table("exercises")\
                .update({"aliases": aliases})\
                .eq("id", ex["id"])\
                .execute()
        return True
    except Exception as e:
        print(f"Failed to add alias: {e}")
        return False

def list_exercises_by_muscle(muscle_group: str) -> list:
    """Get all exercises for a given muscle group."""
    supabase = get_supabase()
    if not supabase:
        return []
    try:
        result = supabase.table("exercises")\
            .select("name, muscle_group")\
            .ilike("muscle_group", f"%{muscle_group}%")\
            .order("name")\
            .execute()
        return result.data or []
    except Exception:
        return []

def format_unsure_message(user_input: str, candidates: list) -> str:
    """Format a message asking user to clarify which exercise they mean."""
    options = "\n".join([f"  {i+1}. {c['name']} ({c['muscle_group']})" 
                         for i, c in enumerate(candidates)])
    return f"Not sure which exercise you mean by '{user_input}'. Did you mean:\n{options}\n\nReply with the number or the full name."
