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
from muscle_map import MUSCLE_CONTRIBUTIONS, MUSCLE_GROUPS

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


def resolve_contributions(exercise: str) -> dict[str, float]:
    """Exercise name -> {muscle: fraction}, mirroring muscleContributions.

    Single attribution — one exercise, one muscle — is what made the volume
    readout wrong. Eight sets of rowing counted 8 for Back and ZERO for the
    biceps doing half the work, so every muscle living on indirect volume
    read as starved: rear delts showed 3 sets/week against a 4-8 band when
    they were really at 6, and biceps showed 9 against 8-12 when they were
    really at 15, i.e. OVER. The weak-point block picks the two lowest
    muscles, so it was aimed at the two needing it least.

    Falls back to {primary: 1.0} for anything unclassified — isolations are
    genuinely single-muscle, so that is correct for them, not just safe.
    """
    key = " ".join((exercise or "").split()).lower()
    if not key:
        return {}

    direct = MUSCLE_CONTRIBUTIONS.get(key)
    if direct:
        return dict(direct)

    # Same longest-key-wins rule as resolve_muscle_group. Matching it exactly
    # matters: if the two disagreed about which catalog entry a name resolves
    # to, strength and volume would attribute the same set to different
    # muscles.
    best_len = 0
    best_split = None
    for candidate, split in MUSCLE_CONTRIBUTIONS.items():
        if len(candidate) < _MIN_KEY_LEN or candidate not in key:
            continue
        if len(candidate) > best_len:
            best_len = len(candidate)
            best_split = split
    if best_split:
        return dict(best_split)

    primary = resolve_muscle_group(exercise)
    return {primary: 1.0} if primary else {}


def _is_cardio_or_yoga(row: dict) -> bool:
    note = (row.get("notes") or "").lower()
    return note.startswith(("cardio", "yoga"))


def get_weekly_volume(days: int = 14) -> dict[str, float]:
    """Weekly working sets per muscle, fractionally attributed.

    Two deliberate choices, both of which the old version got wrong.

    FRACTIONAL: a set is divided across the muscles that do the work rather
    than assigned wholly to one. See `resolve_contributions` for why single
    attribution made three muscles read wrong.

    FOURTEEN DAYS, HALVED: the rotation is four days rolling through six
    training days, so a 7-day window can never contain a whole number of
    rotations — every muscle oscillated 2x depending on whether its session
    fell once or twice in the window. Back read 8 one day and 16 the next
    while the target band said 10-16, so the same unchanged programme looked
    under-dosed half the time. Over 14 days each session type occurs exactly
    three times, so halving gives a stable per-week figure that means the
    same thing every day and is directly comparable to the bands.

    Returns {} when the data can't be read — callers treat that as "no
    readout" rather than "zero volume".
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

    weeks = max(days / 7.0, 1.0)
    totals: dict[str, float] = {}
    for row in result.data or []:
        if row.get("is_warmup") or _is_cardio_or_yoga(row):
            continue
        for muscle, share in resolve_contributions(row.get("exercise", "")).items():
            totals[muscle] = totals.get(muscle, 0.0) + share
    return {m: round(v / weeks, 1) for m, v in totals.items()}


def format_weekly_volume(counts: dict[str, float]) -> str:
    """Render the volume block, lowest first.

    Ordered ascending on purpose: the muscle needing attention is the first
    thing read, and the weak-point block picks off the top of this list.
    Target ranges live in the system prompt — see VOLUME_TARGETS there; this
    module deliberately states none so the two can't disagree.
    """
    if not counts:
        return "  No volume data available."
    ordered = sorted(counts.items(), key=lambda kv: (kv[1], kv[0]))
    lines = [f"  {group}: {sets:g} sets/week" for group, sets in ordered]
    lowest = ", ".join(g for g, _ in ordered[:2])
    lines.append(f"  Lowest two by absolute count: {lowest} — information only; the "
                 f"weak-point slots follow THIS BLOCK'S WEAK POINTS above.")
    return "\n".join(lines)


# Exercises that ARE the Cardio+Abs day's scheduled work rather than its
# weak-point block. Anything else logged on that day is block work.
_CARDIO_DAY_STAPLES = ("Abs",)


def find_weak_point_work(sessions: list[dict]) -> list[dict]:
    """What the weak-point block actually delivered, per Cardio+Abs session.

    Pure function over `[{date, sets: [...]}]` so it is testable without a
    database.

    The block is the mechanism the programme relies on to feed its two
    lowest muscles, and the volume readout says it is not landing: calves
    and hamstrings have sat under their bands while the block that names
    them has been scheduled the whole time. Whether that is because it is
    never prescribed, or prescribed and skipped, is not something the coach
    can tell from a 30-day log of raw sets — so it is computed here and
    reported as a finding, the same treatment that stopped load stalls going
    unnoticed.

    Everything on the day that is not cardio, not warm-up and not an ab
    movement is block work by definition; the day has no other content.
    """
    out = []
    for session in sessions:
        muscles: dict[str, float] = {}
        for row in session.get("sets") or []:
            if row.get("is_warmup") or _is_cardio_or_yoga(row):
                continue
            shares = resolve_contributions(row.get("exercise", ""))
            if not shares or all(m in _CARDIO_DAY_STAPLES for m in shares):
                continue
            for muscle, share in shares.items():
                muscles[muscle] = muscles.get(muscle, 0.0) + share
        out.append({"date": session.get("date"), "muscles": muscles})
    return out


def format_weak_point_history(history: list[dict]) -> str:
    """Render block compliance, newest first.

    States the absence explicitly rather than omitting empty sessions. A
    session that simply does not appear reads as missing data; "none logged"
    reads as the finding it actually is.
    """
    if not history:
        return "  No Cardio+Abs sessions in the window."
    lines = []
    for entry in history:
        if entry["muscles"]:
            worked = ", ".join(
                f"{m} {v:g}" for m, v in sorted(entry["muscles"].items(), key=lambda kv: -kv[1])
            )
        else:
            worked = "none logged"
        lines.append(f"  {entry['date']}: {worked}")
    missed = sum(1 for e in history if not e["muscles"])
    if missed:
        lines.append(
            f"  {missed} of the last {len(history)} Cardio+Abs sessions carried NO "
            f"weak-point work. That block is why the lowest two muscles are lowest."
        )
    return "\n".join(lines)


def get_weak_point_history(sessions_back: int = 4) -> list[dict]:
    """Recent Cardio+Abs sessions and what non-ab work each one carried.

    Returns [] when the data can't be read, which callers render as "no
    readout" rather than "nothing was done".
    """
    try:
        supabase = get_supabase()
        if not supabase:
            return []
        # Rows, then DAYS. A Cardio+Abs day has produced two rows more than
        # once — the cardio import in one, the ab work in another — and
        # taking the last four rows read two days as four sessions, half of
        # them "none logged". The block's history is per training day.
        ws = (
            supabase.table("workout_sessions")
            .select("id, date")
            .eq("type", "Cardio+Abs")
            .order("date", desc=True)
            .limit(sessions_back * 4)
            .execute()
        )
        all_rows = ws.data or []
        if not all_rows:
            return []
        dates = sorted({r["date"] for r in all_rows if r.get("date")}, reverse=True)[:sessions_back]
        rows = [r for r in all_rows if r.get("date") in dates]
        sets_result = (
            supabase.table("workout_sets")
            .select("workout_session_id, exercise, is_warmup, notes")
            .in_("workout_session_id", [r["id"] for r in rows])
            .execute()
        )
    except Exception:
        log.exception("Weak-point history fetch failed")
        return []

    by_session: dict[str, list[dict]] = {}
    for row in sets_result.data or []:
        by_session.setdefault(row["workout_session_id"], []).append(row)

    by_date: dict[str, list[dict]] = {}
    for r in rows:
        by_date.setdefault(r["date"], []).extend(by_session.get(r["id"], []))
    return find_weak_point_work(
        [{"date": d, "sets": by_date[d]} for d in sorted(by_date, reverse=True)]
    )
