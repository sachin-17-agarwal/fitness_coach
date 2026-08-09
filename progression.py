"""Per-exercise load stalls, for the coach context.

The programme already carries a load-increase trigger: hit the top of the rep
range at or under the week's target RPE and the load goes up next session. It
is written out in the system prompt with the ab crunch machine as its worked
example — and the ab crunch machine still sat at one load for five sessions
running, then moved only when the athlete asked why it hadn't.

That is what a rule costs when it depends on being remembered. The evidence
for it is spread across a raw 30-day log: to notice a stall the coach has to
group every set by exercise, compare top-set loads across sessions, and hold
the comparison in mind while also programming the set in front of it. It will
do that when asked a direct question and miss it the rest of the time.

So the comparison is computed here and injected as a finding. Same treatment
the weekly volume block already gets, for the same reason: the coach should be
TOLD which lifts have stalled, not asked to notice.

Deliberately conservative about what it claims. `target_reps` stores the
BOTTOM of a prescribed range (the app writes `target?.reps`, and the top of
the range is never persisted), so this module cannot verify "top of the
range". It reports two things it can stand behind — how long a load has been
unchanged, and whether the last session met its target reps at or under its
target RPE — and leaves the prescription to the coach.
"""

import logging
from datetime import timedelta

from data import get_supabase, now_local

log = logging.getLogger(__name__)

# A load held across this many sessions is a stall worth surfacing. An
# exercise recurs about 1.5x a week, so three sessions is roughly a fortnight
# on the same weight — long enough to be a pattern, short enough to catch it
# before a whole mesocycle is spent there.
DEFAULT_MIN_SESSIONS = 3

# How many recent top sets to quote back, so the coach can see the trend that
# produced the flag rather than trusting the flag alone.
_RECENT_SETS_SHOWN = 4


def _is_cardio_or_yoga(row: dict) -> bool:
    note = (row.get("notes") or "").lower()
    return note.startswith(("cardio", "yoga"))


def _as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _top_set(sets: list[dict]) -> dict | None:
    """The heaviest working set of a session, which is the one progression
    tracks. Falls back to the highest rep count for bodyweight movements,
    where every set carries the same load and reps are the only lever.
    """
    if not sets:
        return None
    weighted = [s for s in sets if (_as_float(s.get("actual_weight_kg")) or 0) > 0]
    if weighted:
        return max(weighted, key=lambda s: _as_float(s.get("actual_weight_kg")) or 0)
    return max(sets, key=lambda s: _as_int(s.get("actual_reps")) or 0)


def _load_key(row: dict):
    """What counts as 'the same load'. Bodyweight sets collapse to a single
    key so a BW movement doesn't look like it changes load every session.
    """
    weight = _as_float(row.get("actual_weight_kg"))
    if weight is None or weight <= 0:
        return "BW"
    return round(weight, 2)


def _met_target(row: dict) -> bool:
    """Whether this set hit its prescribed reps at or under its prescribed RPE.

    Both targets must be present. A missing target is not evidence of anything
    and must not be read as a pass — that is how a set logged with no
    prescription would fake a progression trigger.
    """
    target_reps = _as_int(row.get("target_reps"))
    actual_reps = _as_int(row.get("actual_reps"))
    target_rpe = _as_float(row.get("target_rpe"))
    actual_rpe = _as_float(row.get("actual_rpe"))
    if target_reps is None or actual_reps is None:
        return False
    if actual_reps < target_reps:
        return False
    if target_rpe is None or actual_rpe is None:
        return False
    return actual_rpe <= target_rpe


def find_stalls(rows: list[dict], min_sessions: int = DEFAULT_MIN_SESSIONS) -> list[dict]:
    """Exercises whose top-set load has not moved for `min_sessions` sessions.

    Pure function over set rows so it can be tested without a database.
    Returns newest-stall-first, longest streak first, each entry carrying the
    evidence behind it rather than just a verdict.
    """
    by_exercise: dict[str, dict[str, list[dict]]] = {}
    for row in rows:
        if row.get("is_warmup") or _is_cardio_or_yoga(row):
            continue
        exercise = (row.get("exercise") or "").strip()
        date = row.get("date")
        if not exercise or not date:
            continue
        by_exercise.setdefault(exercise, {}).setdefault(str(date), []).append(row)

    stalls = []
    for exercise, sessions in by_exercise.items():
        # Newest first; the streak is counted backwards from the most recent
        # session, because a load that moved and then settled again is a
        # current stall, not a historical one.
        dates = sorted(sessions.keys(), reverse=True)
        tops = []
        for date in dates:
            top = _top_set(sessions[date])
            if top is not None:
                tops.append((date, top))
        if len(tops) < min_sessions:
            continue

        current_load = _load_key(tops[0][1])
        streak = 0
        for _, top in tops:
            if _load_key(top) != current_load:
                break
            streak += 1
        if streak < min_sessions:
            continue

        streak_entries = tops[:streak]
        stalls.append({
            "exercise": exercise,
            "load": current_load,
            "sessions": streak,
            "first_date": streak_entries[-1][0],
            "last_date": streak_entries[0][0],
            # Oldest-to-newest so the trend reads left to right.
            "recent": [top for _, top in reversed(streak_entries[:_RECENT_SETS_SHOWN])],
            "increase_indicated": _met_target(streak_entries[0][1]),
        })

    stalls.sort(key=lambda s: (not s["increase_indicated"], -s["sessions"], s["exercise"]))
    return stalls


def _format_set(row: dict) -> str:
    reps = _as_int(row.get("actual_reps"))
    rpe = _as_float(row.get("actual_rpe"))
    text = f"{reps}" if reps is not None else "?"
    if rpe is not None:
        text += f"@{rpe:g}"
    return text


def format_stalls(stalls: list[dict]) -> str:
    """Render the progression block.

    Flagged lifts first, with the evidence inline. The wording separates what
    is measured (the load has not moved; the last session met its target) from
    what is a decision (whether to add weight) — the coach owns the second.
    """
    if not stalls:
        return "  No lift has held the same top-set load for 3+ sessions."

    lines = []
    for stall in stalls:
        load = stall["load"]
        load_text = "bodyweight" if load == "BW" else f"{load:g}kg"
        recent = ", ".join(_format_set(r) for r in stall["recent"])
        line = (
            f"  {stall['exercise']}: {load_text} for {stall['sessions']} sessions "
            f"({stall['first_date']} → {stall['last_date']}). Top sets: {recent}."
        )
        if stall["increase_indicated"]:
            line += " LOAD INCREASE INDICATED — last session met its target reps at or under target RPE."
        lines.append(line)
    return "\n".join(lines)


def get_load_stalls(days: int = 42, min_sessions: int = DEFAULT_MIN_SESSIONS) -> list[dict]:
    """Fetch and analyse recent sets.

    Excludes today for two reasons. It keeps this block in the cacheable half
    of the context, which only changes once a day; and a progression decision
    is about sessions that are finished, so a partly-logged session in
    progress should not flip a flag mid-workout.

    Six weeks covers a full mesocycle plus margin — an exercise recurring 1.5
    times a week gives about nine sessions to compare.

    Returns [] when the data can't be read, which callers render as "no
    readout" rather than "nothing has stalled".
    """
    try:
        supabase = get_supabase()
        if not supabase:
            return []
        today = now_local().date()
        since = (today - timedelta(days=days)).isoformat()
        result = (
            supabase.table("workout_sets")
            .select("date, exercise, is_warmup, notes, actual_weight_kg, "
                    "actual_reps, actual_rpe, target_reps, target_rpe")
            .gte("date", since)
            .lt("date", today.isoformat())
            .execute()
        )
    except Exception:
        log.exception("Load-stall fetch failed")
        return []

    return find_stalls(result.data or [], min_sessions=min_sessions)
