"""Weekly training volume per muscle group, for the coach context.

The programme instructs the coach to notice when a muscle is short on
weekly sets and to pick the two lowest for the Cardio+Abs weak-point
block. That is only possible if the coach can see the numbers, so this
module computes them from `workout_sets` and renders them into context.

Muscle mapping mirrors the iOS ExerciseCatalog exactly — see muscle_map.py,
which is generated from the Swift source.
"""

import logging
from datetime import timedelta

from data import get_supabase, now_local
from muscle_map import MUSCLE_GROUPS

log = logging.getLogger(__name__)

# Substring matches shorter than this are too generic to trust ("row",
# "dip"), mirroring the iOS matcher's guard.
_MIN_KEY_LEN = 4


def resolve_muscle_group(exercise: str) -> str | None:
    """Exercise name -> muscle group, mirroring ExerciseCatalog.muscleGroup.

    Exact match first, then the LONGEST substring match, so "leg press"
    beats "press" and "lying leg curl" beats "curl".
    """
    key = " ".join((exercise or "").split()).lower()
    if not key:
        return None
    direct = MUSCLE_GROUPS.get(key)
    if direct:
        return direct

    best_len = 0
    best_group = None
    for candidate, group in MUSCLE_GROUPS.items():
        if len(candidate) < _MIN_KEY_LEN or candidate not in key:
            continue
        if len(candidate) > best_len:
            best_len = len(candidate)
            best_group = group
    return best_group


def _is_cardio_or_yoga(row: dict) -> bool:
    note = (row.get("notes") or "").lower()
    return note.startswith(("cardio", "yoga"))


def get_weekly_volume(days: int = 7) -> dict[str, int]:
    """Working sets per muscle group over the trailing `days`.

    Warm-ups and cardio/yoga entries are excluded, matching how the app's
    Volume tab counts. Returns {} when the data can't be read — callers
    treat that as "no readout" rather than "zero volume".
    """
    try:
        supabase = get_supabase()
        if not supabase:
            return {}
        since = (now_local().date() - timedelta(days=days - 1)).isoformat()
        result = (
            supabase.table("workout_sets")
            .select("exercise, is_warmup, notes")
            .gte("date", since)
            .execute()
        )
    except Exception:
        log.exception("Weekly volume fetch failed")
        return {}

    counts: dict[str, int] = {}
    for row in result.data or []:
        if row.get("is_warmup") or _is_cardio_or_yoga(row):
            continue
        group = resolve_muscle_group(row.get("exercise", ""))
        if not group:
            continue
        counts[group] = counts.get(group, 0) + 1
    return counts


def format_weekly_volume(counts: dict[str, int]) -> str:
    """Render the volume block, lowest first.

    Ordered ascending on purpose: the muscle needing attention is the first
    thing read, and the weak-point block picks off the top of this list.
    Target ranges deliberately live in the system prompt rather than here,
    so there is one authority for them rather than two that can disagree.
    """
    if not counts:
        return "  No volume data available for the last 7 days."
    ordered = sorted(counts.items(), key=lambda kv: (kv[1], kv[0]))
    lines = [f"  {group}: {sets} sets" for group, sets in ordered]
    lowest = ", ".join(g for g, _ in ordered[:2])
    lines.append(f"  Lowest two: {lowest}")
    return "\n".join(lines)
