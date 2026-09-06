"""
coach_parsing.py - Set parsing, exercise resolution, and session-completion
heuristics shared by the chat handler.
"""

import logging
import re

from data import session_type_for
from exercises import find_exercise
from volume import resolve_muscle_group

log = logging.getLogger(__name__)


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
# Cycle days that aren't a top-set/back-off strength session. Yoga used to be
# day 5 here; it is no longer a rotation position at all — it's pinned to
# Sunday and overrides whatever the rotation is showing (see data.CYCLE).
CARDIO_YOGA_DAYS = [4]
SESSION_TYPE_ALIASES = {
    "Pull": ["pull", "pull day"],
    "Push": ["push", "push day"],
    "Legs": ["legs", "leg day"],
    "Cardio+Abs": ["cardio", "abs", "cardio day", "cardio abs"],
    "Yoga": ["yoga", "mobility", "stretching"],
}


def get_session_type_for_day(mesocycle_day: int, override=None) -> str:
    # Delegates so the Sunday yoga override, and the athlete's own per-day
    # override, live in exactly one place.
    return session_type_for(mesocycle_day, override=override)


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


# ── Session template ─────────────────────────────────────────────────────────

_TEMPLATE_RE = re.compile(
    r"\*(?P<name>PUSH|PULL|LEGS|CARDIO\+ABS) — (?P<total>\d+) working sets\*\n(?P<line>[^\n]+)"
)

# Days that MUST parse to a template. Yoga is the only session type that
# legitimately has none. Without this the two failure states are identical: a
# day with no template line and a day whose template line stopped matching the
# regex both return ([], 0) and render nothing, so an editing accident in the
# prompt would silently remove the set counts and look exactly like normal
# operation for Yoga.
_DAYS_REQUIRING_A_TEMPLATE = ("Push", "Pull", "Legs", "Cardio+Abs")
_EXERCISE_RE = re.compile(r"^(?P<name>.+?)\s+(?P<sets>\d+)$")


def parse_session_template(prompt: str, session_type: str) -> tuple[list[tuple[str, int]], int]:
    """Per-exercise working-set counts for a session type, from the programme.

    The prompt enumerates them on one line per day —
    "Machine Chest Press 2 · Incline Press 2 · Dips 2 · ..." — which is
    authoritative and machine-readable, and was being ignored in favour of the
    30-day log.

    Returns ([(exercise, sets)], stated_total), or ([], 0) for a day with no
    such line (Cardio+Abs, yoga).
    """
    wanted = (session_type or "").strip().upper()
    for match in _TEMPLATE_RE.finditer(prompt):
        if match.group("name") != wanted:
            continue
        pairs: list[tuple[str, int]] = []
        for chunk in match.group("line").split("·"):
            found = _EXERCISE_RE.match(chunk.strip())
            if found:
                pairs.append((found.group("name").strip(), int(found.group("sets"))))
        return pairs, int(match.group("total"))
    return [], 0


# The Cardio+Abs template names its two weak-point slots generically, because
# which muscle fills them is chosen at prescription time from the WEEKLY VOLUME
# readout. The COUNT is fixed at 3 either way, which is the thing worth stating.
_WEAK_POINT_SLOT_RE = re.compile(r"^\s*weak[- ]point exercise\b", re.IGNORECASE)


def _set_shape(exercise: str, sets: int) -> str:
    """How the sets are structured, not just how many there are.

    The count alone was not enough — the original failure was a SECOND back-off
    on a 2-set exercise, which "2 sets" does not rule out. But rendering every
    entry as top-set-plus-back-offs was wrong in the other direction: it told
    the coach the Ab Crunch Machine takes "1 top set + 2 back-offs" when all
    direct ab work is straight sets at one load, with every set enumerated on
    the `Working Set:` line and NO `Back-off:` line at all. The block then
    closed by asserting "Where they disagree, THIS is right", so the one
    computed authority in the system was confidently specifying the wrong
    shape for the exercise that ends every Legs day.

    Ab work is identified through the same muscle map the volume readout uses,
    so a renamed or added ab movement is picked up without a list to maintain
    here.
    """
    if resolve_muscle_group(exercise) == "Abs" or _WEAK_POINT_SLOT_RE.match(exercise or ""):
        return f"{sets} straight sets at one load, no back-off line"
    backoffs = max(0, sets - 1)
    return "1 top set" + (
        f" + {backoffs} back-off{'s' if backoffs != 1 else ''}" if backoffs else ""
    )


def format_session_template(prompt: str, session_type: str) -> str:
    """Render the template as a lookup table for the live context.

    Written because stating the rule in prose did not hold. The prompt already
    says Machine Chest Press dropped from 3 sets to 2 in August 2026, names the
    consequence of getting it wrong, and warns that older sessions in the log
    still show two back-offs — and a Push session was still prescribed with a
    second back-off. The log is longer, more concrete and more recent-feeling
    than a sentence in a document, so it wins.

    So the count is computed and handed over, and the log is explicitly
    demoted where the numbers are read.
    """
    pairs, total = parse_session_template(prompt, session_type)
    if not pairs:
        if (session_type or "").strip() in _DAYS_REQUIRING_A_TEMPLATE:
            log.error(
                "No template line parsed for %s — the set-count block is EMPTY for a "
                "day that has one. Check the '*%s — N working sets*' header and the "
                "exercise line under it in system_prompt.txt.",
                session_type, (session_type or "").upper(),
            )
        return ""
    lines = []
    for name, sets in pairs:
        lines.append(f"  {name}: {sets} working sets ({_set_shape(name, sets)})")
    body = "\n".join(lines)
    return (
        f"\nTODAY'S SET COUNTS — the programme's template, and a LOOKUP rather "
        f"than something to infer:\n{body}\n"
        f"  Total: {total} working sets.\n"
        f"Sessions in the 30-day log may show DIFFERENT counts for these "
        f"exercises. The programme changed in August 2026 and the log still "
        f"holds sessions from before it. The log is what happened; this is what "
        f"is prescribed. Where they disagree, THIS is right.\n"
    )


# ── Prescription parser ──────────────────────────────────────────────────────
#
# Moved here from webhook.py so coach.py can reach it. coach.py cannot import
# webhook (webhook imports coach), and the set-count check below has to run on
# the reply before it leaves chat_with_coach. webhook.py re-exports the private
# names so its own callers and the regression suite are unaffected.

def _parse_prescription(text: str) -> dict | None:
    """Extract structured prescription data from Claude's workout response."""
    # Find bold exercise names: *Exercise Name*
    name_pattern = re.compile(r'^\s*\*{1,2}([^*\n]+)\*{1,2}\s*$', re.MULTILINE)
    matches = list(name_pattern.finditer(text))
    if not matches:
        return None

    # Take the first exercise block that has actual set data
    for i, match in enumerate(matches):
        name = match.group(1).strip()
        start = match.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        block = text[start:end]

        rx = _parse_block(name, block)
        if rx and (rx.get("warmup") or rx.get("working") or rx.get("backoff")):
            return rx

    return None


_WARMUP_PREFIXES = ("warm-up:", "warmup:", "warm up:", "warm-up sets:",
                    "warmup sets:", "warm up sets:", "warm sets:", "warm:")
_WORKING_PREFIXES = ("working set:", "working sets:", "work:", "working:",
                     "top set:", "top sets:", "primary set:", "primary:",
                     "main set:", "main:")
_BACKOFF_PREFIXES = ("back-off:", "backoff:", "back off:", "back-off set:",
                     "back off set:", "backoff set:", "drop set:", "drop:",
                     "light set:", "light:")

# Matches loose phrasings like "3 sets: 90kg x12 RPE7" or "3x 90kg x 12 RPE7".
# The optional `(\d+)-(\d+)` rep range mirrors the strict parser so a loose
# "3 sets: 90kg x6-8" keeps the low bound in reps and the top in reps_high.
_LOOSE_SET_PATTERN = re.compile(
    r'(?:^|\s)(?:\d+\s*(?:sets?|x)\s*:?\s*)'
    r'(\d+(?:\.\d+)?)\s*(?:kg|lbs?)?\s*[xX×]\s*(\d+)(?:\s*[-–—]\s*(\d+))?'
    r'(?:\s*(?:rpe|@)\s*(\d+(?:\.\d+)?))?',
    re.IGNORECASE,
)


# "Back-off 2 of 2:" -> "back-off:". The iOS app tells the coach "Next: back-off
# 2 of 2 on <exercise>" and the coach echoes that phrasing onto the prescription
# line, which neither the strict prefixes nor the loose "N sets:" fallback match
# — so a revised set was silently dropped and the card kept the old target.
# Anchored on a leading word-run so "3 sets: 90kg x12" and "Tempo: 3-1-2" are
# untouched.
_NUMBERED_PHASE_RE = re.compile(r'^([a-z][a-z \-]*?)\s+\d+(?:\s*of\s*\d+)?\s*:')


def _canonicalise_phase_label(lower: str) -> str:
    return _NUMBERED_PHASE_RE.sub(r'\1:', lower, count=1)


def _parse_block(name: str, block: str) -> dict | None:
    """Parse a single exercise block into structured data."""
    result = {"exercise": name}
    warmup = []
    working = []
    backoff = []
    form = None
    why = None
    tempo = None
    rest = None
    revised = False

    for line in block.split("\n"):
        line = line.strip()
        lower = _canonicalise_phase_label(line.lower())

        if any(lower.startswith(p) for p in _WARMUP_PREFIXES):
            content = line.split(":", 1)[1].strip()
            warmup = _parse_set_list(content)
        elif any(lower.startswith(p) for p in _WORKING_PREFIXES):
            content = line.split(":", 1)[1].strip()
            parts = [p.strip() for p in content.split("|")]
            if parts:
                working = _parse_set_list_with_rpe(parts[0])
            for part in parts[1:]:
                pl = part.lower()
                if pl.startswith("tempo"):
                    tempo = part.split(":", 1)[1].strip() if ":" in part else part[6:].strip()
                elif pl.startswith("rest"):
                    rest = part.split(":", 1)[1].strip() if ":" in part else part[5:].strip()
        elif any(lower.startswith(p) for p in _BACKOFF_PREFIXES):
            content = line.split(":", 1)[1].strip()
            parts = [p.strip() for p in content.split("|")]
            if parts:
                backoff = _parse_set_list_with_rpe(parts[0])
        elif lower.startswith(("form:", "form cue:", "cue:")):
            form = line.split(":", 1)[1].strip()
        elif lower.startswith("why:"):
            why = line.split(":", 1)[1].strip()
        elif lower.startswith("tempo:"):
            tempo = line.split(":", 1)[1].strip()
        elif lower.startswith("rest:"):
            rest = line.split(":", 1)[1].strip()
        elif lower.startswith(("revised:", "revision:")):
            # Explicit marker that this block deliberately restructures the
            # prescription (athlete asked to add/remove sets). The iOS app
            # applies a revised block verbatim instead of reconciling it
            # against the card, so removed sets actually leave the screen.
            revised = True

    # Fallback: Claude sometimes drops the `Working Set:` / `Back-off:` prefixes
    # and writes loose lines like "3 sets: 90kg x12 RPE7" + "3 sets: 60kg x15 RPE7".
    # Scan the block for those whenever a phase is missing — including the case
    # where the strict `Working Set:` line was sent but the back-off was only
    # mentioned narratively, which would otherwise drop silently and leave the
    # card with a working chip and no back-off.
    if not working or not backoff:
        loose = _parse_loose_sets(block)
        # Don't double-count anything the strict prefixes already captured.
        already = {(s["weight"], s["reps"]) for s in working + backoff}
        loose = [s for s in loose if (s["weight"], s["reps"]) not in already]
        if loose:
            if not working:
                working = [loose.pop(0)]
            # Straight-set prescriptions (abs) enumerate 2+ sets on the
            # `Working Set:` line and legitimately have no back-off — don't
            # promote stray narrative numbers into a phantom back-off.
            if not backoff and loose and len(working) <= 1:
                backoff = [loose[0]]

    if warmup:
        result["warmup"] = warmup
    if working:
        result["working"] = working
    if backoff:
        result["backoff"] = backoff
    if form:
        result["form"] = form
    if why:
        result["why"] = why
    if tempo:
        result["tempo"] = tempo
    if rest:
        result["rest"] = rest
    if revised:
        result["revised"] = True

    return result


def _parse_loose_sets(block: str) -> list:
    """Extract sets from loose phrasings inside an exercise block.

    Handles lines like:
      "3 sets: 90kg x12 RPE7"
      "3x 90kg x 12 RPE7"
    Returns a list of {weight, reps, rpe?} dicts in source order.
    """
    seen = []
    for match in _LOOSE_SET_PATTERN.finditer(block):
        try:
            weight = float(match.group(1))
            reps = int(match.group(2))
        except (TypeError, ValueError):
            continue
        entry = {"weight": weight, "reps": reps}
        if match.group(3):
            try:
                reps_high = int(match.group(3))
                if reps_high > reps:
                    entry["reps_high"] = reps_high
            except ValueError:
                pass
        if match.group(4):
            try:
                entry["rpe"] = float(match.group(4))
            except ValueError:
                pass
        seen.append(entry)
    return seen


def _parse_set_list(text: str) -> list:
    """Parse '60kg x10, 80kg x6' (or 'BW x10, BW x6') into structured sets.

    Bodyweight phrasings ('BW', 'Bodyweight', 'BW + 10kg') resolve to weight 0
    so swaps to assisted/pull-up style exercises still render a card."""
    pattern = re.compile(
        r'(BW|bodyweight|body\s*weight|\d+(?:\.\d+)?)\s*(?:kg)?\s*[xX×]\s*(\d+)',
        re.IGNORECASE,
    )
    sets = []
    for m in pattern.finditer(text):
        raw_weight = m.group(1)
        weight = 0.0 if not raw_weight[0].isdigit() else float(raw_weight)
        sets.append({"weight": weight, "reps": int(m.group(2))})
    return sets


def _parse_set_list_with_rpe(text: str) -> list:
    """Parse '120kg x6-8 RPE8-9' (or 'BW x6 RPE8') into structured sets.

    Rep ranges ("x6-8") keep the low bound in `reps` (so prefill/logging and
    the actual-vs-target comparison stay on a single number) and surface the
    top of the range in `reps_high`. The card renders the full range, which
    stops it from contradicting the coach's prose target (e.g. card shows
    "6" while the coach says "aim for 7-8")."""
    pattern = re.compile(
        r'(BW|bodyweight|body\s*weight|\d+(?:\.\d+)?)\s*(?:kg)?\s*[xX×]\s*(\d+)'
        r'(?:\s*[-–—]\s*(\d+))?',
        re.IGNORECASE,
    )
    rpe_pattern = re.compile(r'(?:RPE\s*|@)(\d+(?:\.\d+)?)', re.IGNORECASE)
    results = []
    for m in pattern.finditer(text):
        raw_weight = m.group(1)
        weight = 0.0 if not raw_weight[0].isdigit() else float(raw_weight)
        entry = {"weight": weight, "reps": int(m.group(2))}
        if m.group(3):
            reps_high = int(m.group(3))
            if reps_high > entry["reps"]:
                entry["reps_high"] = reps_high
        rpe_match = rpe_pattern.search(text[m.end():m.end() + 30])
        if not rpe_match:
            rpe_match = rpe_pattern.search(text)
        if rpe_match:
            entry["rpe"] = float(rpe_match.group(1))
        results.append(entry)
    return results


# ── Set-count check ──────────────────────────────────────────────────────────

def parse_all_prescriptions(text: str) -> list[dict]:
    """Every exercise block in a reply, not just the first.

    `_parse_prescription` returns the first block carrying set data, because
    the card only renders one exercise at a time. The set-count check needs
    all of them: a session-opening reply lists the whole day, and the count
    that goes wrong is as likely to be on exercise four as exercise one.
    """
    name_pattern = re.compile(r'^\s*\*{1,2}([^*\n]+)\*{1,2}\s*$', re.MULTILINE)
    matches = list(name_pattern.finditer(text))
    blocks = []
    for i, match in enumerate(matches):
        start = match.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        parsed = _parse_block(match.group(1).strip(), text[start:end])
        if parsed and (parsed.get("working") or parsed.get("backoff")):
            blocks.append(parsed)
    return blocks


def _normalise_exercise(name: str) -> str:
    return " ".join((name or "").split()).lower()


def _match_template_key(key: str, expected: dict) -> int | None:
    """Fall back from an exact name match to an unambiguous partial one.

    The prompt names the same movement four different ways ("Seated Leg Curl"
    in the template line, "leg curl" in the exercise-selection list, "Leg Curl"
    in the briefing example), and the coach writes whichever it read. An exact
    match alone would silently skip the check on precisely the exercise this
    was built for.

    Deliberately NOT a fuzzy score, and deliberately not `find_exercise` —
    that resolves against the exercise library rather than the template, and
    it costs a database round trip on a path that runs on every reply. A
    containment match is enough here, and it is only accepted when exactly one
    template key matches, so a partial name can never be attributed to the
    wrong exercise. "Press" against a Push day matches four keys and is
    correctly rejected as ambiguous.
    """
    hits = [count for name, count in expected.items()
            if name in key or key in name]
    return hits[0] if len(hits) == 1 else None


def check_set_counts(reply: str, prompt: str, session_type: str) -> dict:
    """Compare the reply's working-set counts against the session template.

    This is the missing half of the set-count machinery. `parse_session_template`
    already computes what each exercise should get and renders it into context,
    but nothing ever looked at what came back — a reply prescribing 2 working
    sets of Seated Leg Curl against a template of 3 reached the card, logged as
    a complete session, and raised nothing anywhere.

    Deliberately observational. It returns findings for the caller to log; it
    does not edit the reply and does not block it. Rewriting a prescription
    would mean inventing a load and rep target the coach never chose, and a
    re-ask mid-exercise risks a partial block, which the app applies by
    replacing the whole card (see the re-send rule in the system prompt).

    The target is NOT "every exercise runs its template count, always". The
    template is a default, and a coach that can never depart from it cannot
    coach — a tweaked knee, reps falling off, a session running past 90
    minutes are all real reasons to prescribe something else. What went wrong
    was not deviation, it was SILENT deviation: nothing distinguished a
    considered 2-set prescription from the count simply coming out differently
    this time.

    So deviations are split rather than suppressed:
      * `mismatches` — the count differs and the reply gives no reason. This
        is the drift the check exists to surface.
      * `deliberate` — the count differs and the block carries a `Revised:`
        line, the marker the coach already uses to say a structure was chosen
        on purpose. Still recorded, because a run of them means the template
        is wrong rather than the reply.
      * `unmatched` — exercises with no template entry: substitutions, and the
        weak-point slots, which are named generically because which muscle
        fills them is decided at prescription time. Reported so the check's
        real coverage is visible rather than assumed from a silent zero.
    """
    pairs, _total = parse_session_template(prompt, session_type)
    expected = {_normalise_exercise(name): count for name, count in pairs}

    findings = {"mismatches": [], "deliberate": [], "unmatched": [], "checked": 0}
    if not expected:
        return findings

    for block in parse_all_prescriptions(reply):
        name = block.get("exercise", "")
        key = _normalise_exercise(name)
        target = expected.get(key)
        if target is None:
            target = _match_template_key(key, expected)
        if target is None:
            findings["unmatched"].append(name)
            continue

        actual = len(block.get("working") or []) + len(block.get("backoff") or [])
        findings["checked"] += 1
        if actual == target:
            continue
        entry = {"exercise": name, "expected": target, "actual": actual}
        # A deviation the coach marked is a coaching decision; an unmarked one
        # is the drift this check exists to catch. Both are recorded — a
        # deliberate deviation is still worth seeing, because a run of them
        # says the template is wrong rather than the reply.
        bucket = "deliberate" if block.get("revised") else "mismatches"
        findings[bucket].append(entry)
    return findings


# ── Set-count enforcement ────────────────────────────────────────────────────

_RPE_SUFFIX_RE = re.compile(r'(?:rpe|@)\s*\d+(?:\.\d+)?\s*$', re.IGNORECASE)


def _trim_set_line(line: str, keep: int) -> tuple[str, int]:
    """Drop surplus comma-separated sets from a Working Set: / Back-off: line.

    Pure removal — no set is invented and no number is altered. The one subtlety
    is the straight-set format, where a single RPE trails the LAST entry
    ("25kg x12, 25kg x12, 25kg x12 RPE8"). Trimming the tail would take the RPE
    with it and leave the card with no target effort, so it is carried onto the
    new last entry.
    """
    prefix, sep, rest = line.partition(":")
    if not sep:
        return line, 0
    segments = rest.split("|")
    sets = [s.strip() for s in segments[0].split(",") if s.strip()]
    if len(sets) <= keep or keep < 1:
        return line, 0

    dropped = sets[keep:]
    kept = sets[:keep]
    trailing_rpe = _RPE_SUFFIX_RE.search(dropped[-1])
    if trailing_rpe and not _RPE_SUFFIX_RE.search(kept[-1]):
        kept[-1] = f"{kept[-1]} {trailing_rpe.group(0).strip()}"

    segments[0] = " " + ", ".join(kept) + (" " if len(segments) > 1 else "")
    return (prefix + ":" + "|".join(segments)).rstrip(), len(dropped)


def enforce_set_counts(reply: str, prompt: str, session_type: str) -> tuple[str, list[dict]]:
    """Trim a prescription back to the template count when it exceeds it.

    Observation was not enough. The count was computed, rendered into context as
    an explicit lookup, and a Pull session still went out with three sets of
    Reverse Cable Fly against a template of two — a week after the same session
    correctly explained why it is two. The athlete cannot tell which reply to
    trust, so the correct ones stop counting too.

    This removes sets; it never adds one. Adding would mean inventing a load and
    a rep target the coach did not choose, which is the one thing worse than the
    wrong count. An UNDER-count is therefore left alone and reported, not filled.

    Safe against the app's merge by construction. A block shorter than the one on
    screen never shrinks it — reconciledPhase overlays onto unlogged slots and
    keeps the planned length (WorkoutViewModel.swift:1521) — so a correction is
    inert on a mid-exercise re-send and takes effect on the first prescription of
    an exercise, which is where the count is actually set.

    Blocks carrying a `Revised:` line are never touched: that marker is the
    coach saying the structure is deliberate.
    """
    pairs, _total = parse_session_template(prompt, session_type)
    expected = {_normalise_exercise(name): count for name, count in pairs}
    if not expected:
        return reply, []

    header = re.compile(r'^\s*\*{1,2}([^*\n]+)\*{1,2}\s*$')
    lines = reply.split("\n")

    # Block spans first: a Revised: line anywhere in a block exempts the whole
    # block, including lines above it.
    blocks = []
    for i, line in enumerate(lines):
        found = header.match(line)
        if found:
            blocks.append({"name": found.group(1).strip(), "start": i, "end": len(lines)})
            if len(blocks) > 1:
                blocks[-2]["end"] = i

    corrections = []
    for block in blocks:
        span = range(block["start"] + 1, block["end"])
        body = [lines[i] for i in span]
        if any(l.strip().lower().startswith(("revised:", "revision:")) for l in body):
            continue

        key = _normalise_exercise(block["name"])
        target = expected.get(key)
        if target is None:
            target = _match_template_key(key, expected)
        if target is None:
            continue

        straight = _set_shape(block["name"], target).startswith(f"{target} straight")
        # Straight sets enumerate every set on the working line and carry no
        # back-off; top-set/back-off shape is one working set plus target-1.
        limits = {"working": target, "backoff": 0} if straight else {
            "working": 1, "backoff": target - 1
        }

        for i in span:
            lower = lines[i].strip().lower()
            if any(lower.startswith(p) for p in _WORKING_PREFIXES):
                phase = "working"
            elif any(lower.startswith(p) for p in _BACKOFF_PREFIXES):
                phase = "backoff"
            else:
                continue
            if limits[phase] < 1:
                continue
            trimmed, dropped = _trim_set_line(lines[i], limits[phase])
            if dropped:
                lines[i] = trimmed
                corrections.append({
                    "exercise": block["name"],
                    "phase": phase,
                    "dropped": dropped,
                    "target": target,
                })

    return ("\n".join(lines), corrections) if corrections else (reply, [])


# ---------------------------------------------------------------------------
# Substituting the computed prescription
# ---------------------------------------------------------------------------

_PRESCRIPTION_PREFIXES = _WARMUP_PREFIXES + _WORKING_PREFIXES + _BACKOFF_PREFIXES
_TEMPO_RE = re.compile(r'\|\s*Tempo:\s*([^|]+)', re.IGNORECASE)


def _coach_tempo(body: list) -> str | None:
    """The tempo the coach chose, if any. It is not arithmetic and not ours."""
    for line in body:
        found = _TEMPO_RE.search(line)
        if found:
            return found.group(1).strip()
    return None


def substitute_computed_blocks(reply: str, computed: dict,
                               aliases: dict | None = None,
                               skip=()) -> tuple[str, list]:
    """Replace the coach's prescription lines with the programme's own.

    The end of the road the guards were on. Set counts were trimmed, RPEs were
    floored, a missing back-off was filled — each one editing a single field of
    a block someone else had written, and each one a new way to be wrong,
    because load, reps and RPE are one decision and a guard only ever sees one
    of them. The last such guard reverted the mandatory HRV reduction and put a
    suppressed-recovery day back at full intensity.

    So the numbers are not corrected here. They are replaced, whole, by the
    ones prescribe.py computed from the same logged loads, the same wave and
    the same recovery readings — already coherent, because they were decided
    together.

    THREE THINGS THIS DELIBERATELY DOES NOT DO.

    It does not inject. Only a block the coach actually wrote is replaced.
    During a session the coach prescribes one exercise at a time ("EXERCISE 1
    OF 4"), and adding the other five to that reply would replace the card the
    athlete is halfway through.

    It does not touch a `Revised:` block. That marker is the coach saying the
    departure is deliberate, and it is the one exit the programme leaves — an
    injury, a machine in use, how he says he feels. Every guard honoured it and
    so does this.

    It does not take the exercise's prose. `Form:` cues, notes and the tempo
    are the coaching, not the arithmetic; only the Warm-up / Working Set /
    Back-off lines are replaced, and the coach's tempo is carried onto the new
    Working Set line rather than dropped.

    AND TWO MORE, FOUND ON REVIEW.

    It keeps the coach's header line. The programme keys its blocks by the
    template name ("Incline Press"); the coach writes the name the athlete
    logs under ("Incline Barbell Press"), which is also the name the iOS card
    keys its transitions on. Swapping the header for the programme's spelling
    would read as a change of exercise mid-session. `aliases` maps the logged
    spelling back to the template name so such a block is still matched.

    It leaves alone any exercise in `skip` — the ones with sets already logged
    today. The computed block is built from LAST session's loads; once the top
    set is on the board the coach's re-prescription is a reaction to today,
    and overwriting it with the pre-session numbers would undo exactly the
    adjustment a coach is for.
    """
    if not computed:
        return reply, []

    wanted = {_normalise_exercise(name): name for name in computed}
    for logged, template in (aliases or {}).items():
        if template in computed:
            wanted.setdefault(_normalise_exercise(logged), template)
    skipped = {_normalise_exercise(name) for name in skip or ()}
    skipped |= {_normalise_exercise(logged) for logged, template in (aliases or {}).items()
                if _normalise_exercise(template) in skipped}
    skipped |= {_normalise_exercise(template) for logged, template in (aliases or {}).items()
                if _normalise_exercise(logged) in skipped}
    lines = reply.split("\n")

    # A bold line is a CANDIDATE header, never a header on its own. Three of
    # this function's worst failures came from treating the two as the same:
    #
    #   - "*Bench Press*" as a discussion heading, with prose under it, was
    #     replaced by a full prescription. A chat reply about yesterday became
    #     two cards the athlete had not been given.
    #   - "**This is lighter on purpose**" inside a block ended it, so the
    #     "Revised:" line below was no longer in the body and the deliberate
    #     lighter load was overwritten — the one exemption that exists for an
    #     injury, defeated by an emphasised sentence.
    #   - "*Landmine Press* (subbing for OHP)" was not matched at all, because
    #     the pattern demanded end-of-line after the asterisks. Its sets fell
    #     into the PREVIOUS block's body and were deleted as prescription lines.
    #
    # Trailing text after the name is allowed, and a candidate is promoted only
    # when its own body carries at least one prescription line. Everything else
    # belongs to the block above it, which is where "Revised:" and the coach's
    # prose were meant to be looked for all along.
    candidate = re.compile(r'^\s*\*{1,2}([^*\n]+?)\*{1,2}\s*(?:\(|$|[^*\w].*$)')
    marks = [(i, candidate.match(l)) for i, l in enumerate(lines)]
    marks = [(i, m.group(1).strip()) for i, m in marks if m]

    blocks = []
    for pos, (i, name) in enumerate(marks):
        end = marks[pos + 1][0] if pos + 1 < len(marks) else len(lines)
        body = lines[i + 1:end]
        if any(l.strip().lower().startswith(_PRESCRIPTION_PREFIXES) for l in body):
            blocks.append({"name": name, "start": i, "end": end})
        elif blocks:
            # Prose or emphasis under the previous exercise: extend it, so the
            # body it is scanned for really is the whole block.
            blocks[-1]["end"] = end
    if not blocks:
        return reply, []

    out, cursor, swapped = [], 0, []
    for block in blocks:
        out.extend(lines[cursor:block["start"]])
        cursor = block["end"]
        body = lines[block["start"] + 1:block["end"]]

        key = _normalise_exercise(block["name"])
        if key not in wanted or key in skipped or _normalise_exercise(wanted[key]) in skipped or any(
                l.strip().lower().startswith(("revised:", "revision:")) for l in body):
            out.extend(lines[block["start"]:block["end"]])
            continue

        rendered = computed[wanted[key]]
        tempo = _coach_tempo(body)
        if tempo:
            rendered = _TEMPO_RE.sub("", rendered)
            rendered = "\n".join(
                line + f" | Tempo: {tempo}" if line.strip().lower().startswith(
                    _WORKING_PREFIXES) else line
                for line in rendered.split("\n"))

        kept = [l for l in body
                if not l.strip().lower().startswith(_PRESCRIPTION_PREFIXES)]
        # The coach's header stays; the programme's own header line is dropped.
        # A prescription written on the header line itself ("*Dips* Warm-up:
        # BW x8") goes with the other prescription lines, or the card would
        # carry two warm-ups.
        header = lines[block["start"]]
        closing = re.match(r'^(\s*\*{1,2}[^*\n]+?\*{1,2})(.*)$', header)
        if closing and closing.group(2).strip().lower().startswith(_PRESCRIPTION_PREFIXES):
            header = closing.group(1)
        out.append(header)
        out.extend(rendered.split("\n")[1:])
        out.extend(kept)
        swapped.append(block["name"])

    out.extend(lines[cursor:])
    return "\n".join(out), swapped
