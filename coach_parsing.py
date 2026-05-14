"""
coach_parsing.py - Set parsing, exercise resolution, and session-completion
heuristics shared by the chat handler.
"""

import re

from data import CYCLE
from exercises import find_exercise


# ── Set parsing ───────────────────────────────────────────────────────────────

_SET_PATTERN = re.compile(
    r'(?:^|[\s.,;/])'
    r'(\d+(?:\.\d+)?)\s*(?:kg)?\s*'
    r'[xX×]\s*'
    r'(\d+)'
    r'(?:\s*(?:rpe|@)\s*(\d+(?:\.\d+)?))?',
    re.IGNORECASE,
)


def parse_set_from_message(text: str) -> dict | None:
    """Return first set match — kept for backward compatibility."""
    sets = parse_all_sets_from_message(text)
    return sets[0] if sets else None


def parse_all_sets_from_message(text: str) -> list[dict]:
    """
    Extract ALL weight x reps patterns from a message, e.g.:
      "warm up 90 x 10, 140 x 6"   → [{90,10}, {140,6}]
      "101 x 10 and 93 x 10"        → [{101,10}, {93,10}]
    """
    results = []
    for match in _SET_PATTERN.finditer(text):
        weight = float(match.group(1))
        reps = int(match.group(2))
        rpe = float(match.group(3)) if match.group(3) else None
        if 1 <= weight <= 500 and 1 <= reps <= 50:
            results.append({"weight": weight, "reps": reps, "rpe": rpe})
    return results


def is_warmup_set(text: str) -> bool:
    """Return True if the message indicates warm-up sets."""
    return bool(re.search(r'\bwarm[\s-]?up\b|\bwarmup\b', text, re.IGNORECASE))


# iOS app sends structured log messages after it has already persisted the set
# directly to Supabase. The backend must NOT re-parse and re-log these.
_IOS_LOG_PATTERN = re.compile(
    r'^\s*logged\s+(warm[\s-]?up|working|back[\s-]?off)\b[^:\n]*:',
    re.IGNORECASE,
)


def is_ios_structured_log(text: str) -> bool:
    """Detect a 'Logged <phase>: …' message sent by the iOS app."""
    return bool(_IOS_LOG_PATTERN.match(text or ""))


# ── Exercise name extraction ──────────────────────────────────────────────────

_NON_EXERCISE_HEADERS = {
    "recovery", "nutrition", "tomorrow", "today", "volume analysis",
    "strength trends", "session done", "watch", "best lift",
    "recovery tonight", "key flags", "progression notes",
}


def _is_exercise_name(text: str) -> bool:
    cleaned = text.strip().lower()
    if text.strip().isupper():
        return False
    if cleaned in _NON_EXERCISE_HEADERS:
        return False
    if cleaned.startswith("today:") or cleaned.startswith("tomorrow:"):
        return False
    if len(cleaned) < 3:
        return False
    return True


_BLOCKED_LABELS = {
    "your form cue", "form cue", "back-off", "back off", "backoff",
    "notes", "note", "rest", "warm-up", "warm up", "warmup",
    "cool-down", "cool down", "cooldown",
    "working set", "top set", "drop set",
}


def _is_valid_exercise(text: str) -> bool:
    if not _is_exercise_name(text):
        return False
    cleaned = re.sub(r"\s+", " ", text).strip(" -*_:\n\t").lower()
    if cleaned in _BLOCKED_LABELS:
        return False
    if any(token in cleaned for token in ["form cue", "back-off", "back off"]):
        return False
    return True


def extract_exercise_from_context(conversation_history: list) -> str:
    """
    Look back through recent conversation to find the last exercise the coach
    mentioned. Reads *Bold Name* or Name: formatting from assistant messages.
    """
    recent = conversation_history[-8:] if len(conversation_history) >= 8 else conversation_history

    for msg in reversed(recent):
        if msg["role"] != "assistant":
            continue
        content = msg["content"]

        for match in reversed(list(re.finditer(
            r'\*{1,2}([A-Za-z][A-Za-z0-9\s\-/+&()]+)\*{1,2}', content
        ))):
            name = re.sub(r"\s+", " ", match.group(1)).strip()
            if _is_valid_exercise(name):
                return name

        for match in reversed(list(re.finditer(
            r'^([A-Za-z][A-Za-z0-9\s\-/+&()]+):', content, re.MULTILINE
        ))):
            name = re.sub(r"\s+", " ", match.group(1)).strip()
            if _is_valid_exercise(name):
                return name

    return "Unknown"


_CONVERSATIONAL_PREFIX = re.compile(
    r'^(?:I\s+)?(?:just\s+)?(?:did|done|finished|completed|logged)\s+(?:my\s+)?',
    re.IGNORECASE,
)


def extract_exercise_from_set_message(text: str) -> str:
    """
    Extract exercise name from a set log if provided, e.g.:
      "Pull-ups 40 x 8"
      "Chest Supported T-bar Row 60kg x10 @8"
    """
    match = re.search(
        r'^\s*(?:(?:I\s+)?(?:just\s+)?(?:did|done|finished|completed|logged)\s+(?:my\s+)?)?'
        r'([A-Za-z][A-Za-z0-9\s\-/+&()]+?)\s+\d+(?:\.\d+)?\s*(?:kg)?\s*[xX×]\s*\d+',
        text,
        re.IGNORECASE,
    )
    if not match:
        return ""
    candidate = re.sub(r"\s+", " ", match.group(1)).strip(" -*_:\n\t")
    candidate = _CONVERSATIONAL_PREFIX.sub("", candidate).strip()
    blocked = {
        "done", "finished", "complete", "completed", "set", "sets",
        "warm", "warm up", "warmup", "warm-up",
        "rest", "back off", "back-off", "backoff",
        "cool down", "cool-down", "cooldown",
        "working set", "top set", "drop set",
        "i", "my",
    }
    normalised = candidate.lower().strip(" -_:")
    return "" if normalised in blocked else candidate


def resolve_exercise_name(candidate: str) -> str:
    """Resolve to a canonical library name. Returns '' if not found."""
    if not candidate:
        return ""
    try:
        result = find_exercise(candidate)
        if result.get("status") in {"exact", "confident"} and result.get("match"):
            return (result["match"].get("name") or "").strip()
    except Exception:
        pass
    return ""


def build_exercise_note(unresolved: str) -> str | None:
    """User-facing note when an exercise couldn't be resolved canonically."""
    if not unresolved or not _is_valid_exercise(unresolved):
        return None
    try:
        result = find_exercise(unresolved)
        if result.get("status") == "unsure" and result.get("candidates"):
            top = result["candidates"][0]["name"]
            return (
                f"💡 Logged under **{top}** (closest match to \"{unresolved}\"). "
                f"Was that right? If not, reply with the correct name "
                f"or _add exercise {unresolved}_ to add it to my library."
            )
    except Exception:
        pass
    return (
        f"💡 **{unresolved}** isn't in my exercise library. "
        f"Reply _add exercise {unresolved}_ to add it permanently, "
        f"or tell me the correct exercise name."
    )


# ── Session completion / type detection ───────────────────────────────────────

PPL_END_PHRASES = [
    "session done", "session complete", "workout done", "workout complete",
    "that's all the exercises", "finished the session", "done with the workout",
    "end workout", "ending workout", "end session", "ending session",
    "end it now", "i'll end it", "i will end", "stop workout",
    "finish workout", "workout over", "calling it", "that's a wrap",
    "thats a wrap",
]
CARDIO_YOGA_END_PHRASE = "workout wrapped"
BRIEF_COMPLETION_ACKS = {"done", "finished", "complete", "completed", "wrapped", "wrapped up"}
CARDIO_YOGA_DAYS = [4, 5]
SESSION_TYPE_ALIASES = {
    "Pull": ["pull", "pull day"],
    "Push": ["push", "push day"],
    "Legs": ["legs", "leg day"],
    "Cardio+Abs": ["cardio", "abs", "cardio day", "cardio abs"],
    "Yoga": ["yoga", "mobility", "stretching"],
}


def get_session_type_for_day(mesocycle_day: int) -> str:
    return CYCLE[(mesocycle_day - 1) % len(CYCLE)]


def _has_set_data_in_text(text: str) -> bool:
    return bool(re.search(r'\d+(?:\.\d+)?\s*(?:kg)?\s*[xX×]\s*\d+', text))


def is_session_completion_message(text: str, expected_session_type: str) -> bool:
    """Detect a clear end-of-workout message without misreading set logs."""
    normalised = text.lower().replace("'", "'").strip()

    if _has_set_data_in_text(normalised):
        return False

    if any(phrase in normalised for phrase in PPL_END_PHRASES):
        return True
    if CARDIO_YOGA_END_PHRASE in normalised:
        return True

    general_patterns = [
        r"\b(all done|done|finished|complete|completed|wrapped up|wrapped)\s+(with\s+)?(the\s+)?(workout|session|training|gym)\b",
        r"\b(workout|session|training|gym)\s+(is\s+)?(done|finished|complete|completed|wrapped up|wrapped)\b",
        r"\bthat's it\b",
        r"\bthats it\b",
        r"\bthat's all the exercises\b",
        r"\ball done\b",
    ]
    if any(re.search(pattern, normalised) for pattern in general_patterns):
        return True

    all_session_terms = []
    for terms in SESSION_TYPE_ALIASES.values():
        all_session_terms.extend(terms)
    escaped_all = "|".join(re.escape(term) for term in all_session_terms)

    session_patterns = [
        rf"\b({escaped_all})\s+(is\s+)?(done|finished|complete|completed|wrapped)\b",
        rf"\b(all done|done|finished|complete|completed|wrapped up|wrapped)\s+(with\s+)?({escaped_all})\b",
        rf"\b(done|finished|completed|wrapped)\s+(with\s+)?(today|today's)\b",
    ]
    return any(re.search(pattern, normalised) for pattern in session_patterns)


def infer_session_type_from_recent(conversation_history: list, default: str) -> str:
    """Scan recent user messages for explicit session type declarations."""
    recent = conversation_history[-8:] if len(conversation_history) >= 8 else conversation_history
    for msg in reversed(recent):
        if msg["role"] != "user":
            continue
        content = msg["content"].lower().replace("’", "'").strip()
        for canonical, aliases in SESSION_TYPE_ALIASES.items():
            for alias in aliases:
                escaped = re.escape(alias)
                if (re.search(rf"\btoday\s+is\s+{escaped}\b", content)
                        or re.search(rf"\bit'?s\s+{escaped}\b", content)
                        or re.search(rf"\b(?:doing|starting)\s+{escaped}\b", content)):
                    return canonical
    return default
