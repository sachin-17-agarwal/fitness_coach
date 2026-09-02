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

# Week 3 of the 4-week wave is peak intensity; week 4 deloads by holding week
# 3's load and cutting reps. "What did he lift in the peak week" is therefore
# the anchor for both the deload and the next cycle's opening loads.
PEAK_WEEK = 3

# The peak-week lookup needs a longer window than the stall/current-load ones.
# A mesocycle is four completed rotations, and a rotation takes 4-7 calendar
# days depending on rest days, so a cycle spans roughly 16-28 days. Ten weeks
# reliably contains the most recent peak week even on a slow rotation; since
# the lookup takes the most RECENT qualifying session, a longer window can only
# help it, never drag in something staler.
PEAK_WINDOW_DAYS = 70


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


def _group_by_exercise_and_date(rows: list[dict]) -> dict[str, dict[str, list[dict]]]:
    """Working sets keyed exercise -> date -> rows. Warm-ups and the cardio /
    yoga rows that share the table are dropped; neither carries a load to
    progress."""
    grouped: dict[str, dict[str, list[dict]]] = {}
    for row in rows:
        if row.get("is_warmup") or _is_cardio_or_yoga(row):
            continue
        exercise = (row.get("exercise") or "").strip()
        date = row.get("date")
        if not exercise or not date:
            continue
        grouped.setdefault(exercise, {}).setdefault(str(date), []).append(row)
    return grouped


def find_current_loads(rows: list[dict]) -> list[dict]:
    """The load each exercise is currently ON — one line per exercise.

    This exists because the coach was getting it wrong by reading. Asked to
    open Leg Press it scanned a 30-day log, landed on a peak-week 205kg from
    three weeks earlier, and prescribed a load the athlete had already moved
    past — then found the right answer immediately when challenged, from the
    same data. Nothing was missing from its context; the lookup was just buried
    in ~26 sessions of prose and it read the wrong line.

    So the answer is computed instead of searched. Same division of labour as
    find_stalls: this establishes the fact, the coach decides what to do with
    it.
    """
    loads = []
    for exercise, sessions in _group_by_exercise_and_date(rows).items():
        latest = max(sessions.keys())
        top = _top_set(sessions[latest])
        if top is None:
            continue
        loads.append({
            "exercise": exercise,
            "date": latest,
            "load": _load_key(top),
            "reps": _as_int(top.get("actual_reps")),
            "rpe": _as_float(top.get("actual_rpe")),
            "met_target": _met_target(top),
        })
    # Alphabetical: this is a lookup table, and the coach arrives knowing the
    # exercise name, not the date.
    loads.sort(key=lambda entry: entry["exercise"].lower())
    return loads


def format_current_loads(loads: list[dict]) -> str:
    if not loads:
        return "  No working sets logged in the window."
    lines = []
    for entry in loads:
        load = entry["load"]
        load_text = "bodyweight" if load == "BW" else f"{load:g}kg"
        reps = entry["reps"]
        detail = f"x{reps}" if reps is not None else "reps unknown"
        if entry["rpe"] is not None:
            detail += f" @RPE{entry['rpe']:g}"
        note = " — met target" if entry["met_target"] else ""
        lines.append(
            f"  {entry['exercise']}: {load_text} {detail} on {entry['date']}{note}"
        )
    return "\n".join(lines)


def find_peak_week_loads(rows: list[dict], peak_week: int = PEAK_WEEK) -> list[dict]:
    """Top set per exercise from the most recent PEAK-week (week 3) session.

    Deload holds week 3's load, and week 1 of the next cycle opens above what
    week 3 achieved — so "what did he do in the peak week" is a question the
    programme asks twice per cycle. It used to be answered by a list of loads
    typed into the system prompt, which was stale the moment he trained: on a
    week 4 deload the coach anchored to reference loads frozen three weeks
    earlier, and only found the real numbers when told to look again.

    CURRENT WORKING LOADS cannot answer it on its own. Going INTO a deload it
    happens to coincide (the previous session of a lift is one mesocycle week
    back), but once the deload is logged the most recent session is the deload
    itself — same load, deliberately fewer reps — so anchoring next cycle's
    opening to it would under-open every lift.

    Requires `mesocycle_week` on each row, stamped onto the session at creation.
    Rows without it are skipped rather than guessed at: a session's week cannot
    be recovered from its date, because the week advances per completed rotation,
    not per calendar week.
    """
    peak_rows = [r for r in rows if _as_int(r.get("mesocycle_week")) == peak_week]
    return find_current_loads(peak_rows)


def format_peak_week_loads(loads: list[dict], peak_week: int = PEAK_WEEK) -> str:
    """Render the peak-week block.

    The empty case is load-bearing, not cosmetic. Sessions are only stamped with
    their mesocycle week from the point that shipped, so this block is empty
    until a peak week has been recorded — and an unexplained empty heading is
    exactly the sort of gap that gets filled with a remembered number. It says
    what to use instead.
    """
    if not loads:
        return (
            f"  No week-{peak_week} session recorded yet — sessions carry their mesocycle\n"
            f"  week from this cycle onward. Until one appears, anchor to "
            f"CURRENT WORKING LOADS\n"
            f"  and say that is what you used. Do NOT substitute a load you remember."
        )
    return format_current_loads(loads)


def find_stalls(rows: list[dict], min_sessions: int = DEFAULT_MIN_SESSIONS) -> list[dict]:
    """Exercises whose top-set load has not moved for `min_sessions` sessions.

    Pure function over set rows so it can be tested without a database.
    Returns newest-stall-first, longest streak first, each entry carrying the
    evidence behind it rather than just a verdict.
    """
    by_exercise = _group_by_exercise_and_date(rows)

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


def _fetch_sets_before_today(days: int) -> list[dict] | None:
    """Working-set rows from the window, today excluded.

    Excluding today does two jobs. It keeps everything derived from this in the
    cacheable half of the context, which only changes once a day; and a
    progression decision is about sessions that are finished, so a partly
    logged session in progress must not move the numbers mid-workout. Today's
    sets reach the coach through the live block regardless.

    Six weeks covers a full mesocycle plus margin — an exercise recurring 1.5
    times a week gives about nine sessions to compare.

    Returns None when the data can't be read, so callers can tell "nothing
    found" apart from "couldn't look".
    """
    try:
        supabase = get_supabase()
        if not supabase:
            return None
        today = now_local().date()
        since = (today - timedelta(days=days)).isoformat()
        result = (
            supabase.table("workout_sets")
            .select("date, exercise, workout_session_id, is_warmup, notes, "
                    "actual_weight_kg, actual_reps, actual_rpe, target_reps, "
                    "target_rpe")
            .gte("date", since)
            .lt("date", today.isoformat())
            .execute()
        )
        return result.data or []
    except Exception:
        log.exception("Progression fetch failed")
        return None


def _fetch_session_weeks(days: int) -> dict[str, int]:
    """session id -> mesocycle_week for sessions in the window.

    Read separately and joined in Python rather than through a PostgREST embed:
    the embed depends on a declared foreign key between workout_sets and
    workout_sessions, and the sets table only carries the id as a plain column.
    A failure here returns {}, which leaves every row unstamped and renders the
    peak-week block as its empty case — the same outcome as having no peak week
    recorded, which is the safe direction.
    """
    try:
        supabase = get_supabase()
        if not supabase:
            return {}
        today = now_local().date()
        since = (today - timedelta(days=days)).isoformat()
        result = (
            supabase.table("workout_sessions")
            .select("id, mesocycle_week")
            .gte("date", since)
            .execute()
        )
        weeks = {}
        for row in result.data or []:
            week = _as_int(row.get("mesocycle_week"))
            session_id = row.get("id")
            if week is not None and session_id:
                weeks[str(session_id)] = week
        return weeks
    except Exception:
        log.exception("Session mesocycle-week fetch failed")
        return {}


def get_load_stalls(days: int = 42, min_sessions: int = DEFAULT_MIN_SESSIONS) -> list[dict]:
    """Exercises sitting on the same load. [] when the data can't be read,
    which callers render as "no readout" rather than "nothing has stalled"."""
    rows = _fetch_sets_before_today(days)
    if rows is None:
        return []
    return find_stalls(rows, min_sessions=min_sessions)


def get_current_loads(days: int = 42) -> list[dict]:
    """The load each exercise is currently on, ready to be read off."""
    rows = _fetch_sets_before_today(days)
    if rows is None:
        return []
    return find_current_loads(rows)


def get_peak_week_loads(days: int = PEAK_WINDOW_DAYS, peak_week: int = PEAK_WEEK) -> list[dict]:
    """Top set per exercise from the most recent peak-week session.

    [] when the data can't be read or nothing is stamped yet; the formatter
    renders that as an explicit "no peak week recorded" rather than silence.
    """
    rows = _fetch_sets_before_today(days)
    if rows is None:
        return []
    weeks = _fetch_session_weeks(days)
    if not weeks:
        return []
    for row in rows:
        session_id = row.get("workout_session_id")
        if session_id is not None:
            week = weeks.get(str(session_id))
            if week is not None:
                row["mesocycle_week"] = week
    return find_peak_week_loads(rows, peak_week=peak_week)


# ── Today vs last session, per exercise ──────────────────────────────────────

def find_set_comparisons(today_rows: list[dict], prior: list[dict]) -> list[dict]:
    """Today's top set against the same exercise's previous session.

    Both facts were already in context and the comparison between them still
    came out wrong: 55kg x9 @RPE8 today against 55kg x9 @RPE7 last session was
    reported as "one better than last session at the same RPE". Identical reps,
    and the RPE had moved — so not only was there no improvement, the set was
    HARDER for the same work, which is the opposite of what the athlete was
    told.

    Nothing was missing from its context. The same lesson as find_current_loads,
    one level up: computing the facts is not enough when the coaching decision
    depends on the DIFFERENCE between two of them.

    The RPE arm is the one nothing else in the system covers. find_stalls
    catches a load that has not moved; the iOS card catches reps at the same
    load (RestTimer.deltaLine). Neither looks at effort, so "same load, same
    reps, rising RPE" — the early sign that recovery is slipping — has been
    invisible everywhere.

    Pure function over rows so it is testable without a database.
    """
    by_exercise = _group_by_exercise_and_date(today_rows)
    reference = {entry["exercise"].strip().lower(): entry for entry in prior}

    out = []
    for exercise, sessions in by_exercise.items():
        latest = max(sessions.keys())
        top = _top_set(sessions[latest])
        if top is None:
            continue
        ref = reference.get(exercise.strip().lower())
        if ref is None:
            out.append({"exercise": exercise, "verdict": "no_history",
                        "load": _load_key(top), "reps": _as_int(top.get("actual_reps")),
                        "rpe": _as_float(top.get("actual_rpe"))})
            continue

        load, reps, rpe = _load_key(top), _as_int(top.get("actual_reps")), _as_float(top.get("actual_rpe"))
        entry = {
            "exercise": exercise, "load": load, "reps": reps, "rpe": rpe,
            "prev_load": ref["load"], "prev_reps": ref["reps"], "prev_rpe": ref["rpe"],
            "prev_date": ref["date"],
        }

        numeric = isinstance(load, (int, float)) and isinstance(ref["load"], (int, float))
        if numeric and load != ref["load"]:
            entry["verdict"] = "load_up" if load > ref["load"] else "load_down"
        elif load != ref["load"]:
            entry["verdict"] = "changed"
        elif reps is None or ref["reps"] is None:
            entry["verdict"] = "same_load"
        elif reps > ref["reps"]:
            entry["verdict"] = "reps_up"
        elif reps < ref["reps"]:
            entry["verdict"] = "reps_down"
        elif rpe is None or ref["rpe"] is None:
            entry["verdict"] = "matched"
        elif rpe > ref["rpe"]:
            entry["verdict"] = "harder"
        elif rpe < ref["rpe"]:
            entry["verdict"] = "easier"
        else:
            entry["verdict"] = "matched"
        out.append(entry)

    out.sort(key=lambda e: e["exercise"].lower())
    return out


def _describe(entry: dict) -> str:
    """One sentence stating the measurement AND its single reading.

    The verdict is spelled out rather than left implied. "RPE +1 at the same
    load and reps" has exactly one meaning, and leaving the coach to infer it
    is what produced "progressing nicely" for a set that got harder.
    """
    verdict = entry["verdict"]
    if verdict == "no_history":
        return "no previous session in the window — nothing to compare."
    prev = (f"{entry['prev_load']:g}kg" if isinstance(entry["prev_load"], (int, float))
            else "bodyweight")
    prev += f" x{entry['prev_reps']}" if entry["prev_reps"] is not None else ""
    if entry["prev_rpe"] is not None:
        prev += f" @RPE{entry['prev_rpe']:g}"
    prev += f" on {entry['prev_date']}"

    return {
        "load_up": f"load UP vs {prev}.",
        "load_down": f"load DOWN vs {prev}.",
        "changed": f"different loading to {prev}.",
        "same_load": f"same load as {prev}; reps or RPE missing, so no verdict.",
        "reps_up": f"+{(entry['reps'] or 0) - (entry['prev_reps'] or 0)} rep(s) at the same load vs {prev}. Progression.",
        "reps_down": f"{(entry['reps'] or 0) - (entry['prev_reps'] or 0)} rep(s) at the same load vs {prev}. NOT a progression.",
        "harder": (f"SAME load, SAME reps as {prev}, but RPE is "
                   f"{entry['rpe']:g} against {entry['prev_rpe']:g} — HARDER for identical "
                   f"work. This is NOT a progression; treat it as a fatigue or "
                   f"recovery signal."),
        "easier": (f"same load and reps as {prev} at a LOWER RPE "
                   f"({entry['rpe']:g} vs {entry['prev_rpe']:g}) — easier for identical work. "
                   f"The load is ready to move."),
        "matched": f"matched {prev} exactly — same load, reps and RPE. Flat, not a gain.",
    }.get(verdict, f"compared against {prev}.")


def format_set_comparisons(entries: list[dict]) -> str:
    """Render the comparison block, one line per exercise trained today."""
    if not entries:
        return "  Nothing logged yet today."
    lines = []
    for entry in entries:
        load = entry["load"]
        load_text = "bodyweight" if load == "BW" else f"{load:g}kg"
        detail = load_text + (f" x{entry['reps']}" if entry.get("reps") is not None else "")
        if entry.get("rpe") is not None:
            detail += f" @RPE{entry['rpe']:g}"
        lines.append(f"  {entry['exercise']}: {detail} today — {_describe(entry)}")
    return "\n".join(lines)


def get_set_comparisons(days: int = 42) -> list[dict]:
    """Today's top sets compared against each exercise's previous session."""
    try:
        supabase = get_supabase()
        if not supabase:
            return []
        today = now_local().date().isoformat()
        result = (
            supabase.table("workout_sets")
            .select("date, exercise, is_warmup, notes, actual_weight_kg, "
                    "actual_reps, actual_rpe, target_reps, target_rpe")
            .eq("date", today)
            .execute()
        )
        today_rows = result.data or []
    except Exception:
        log.exception("Set-comparison fetch failed")
        return []
    if not today_rows:
        return []
    return find_set_comparisons(today_rows, get_current_loads(days))
