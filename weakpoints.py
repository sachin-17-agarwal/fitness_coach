"""This block's weak points, chosen once.

The two weak-point slots on Cardio+Abs day used to be filled from "Lowest
two" in the rolling WEEKLY VOLUME readout: the two muscles with the fewest
absolute sets over the last fourteen days, recomputed on every message. That
was wrong twice over. Absolute sets favour muscles with small bands — calves
were picked at 7.5 sets against a 6-10 band, inside it — and a window that
slides daily changes the pick whenever a session drops out of it, then feeds
on itself: pick calves, calves rise, pick something else, calves fall. A lift
that appears once and then not for three weeks has no wave to progress on.

A muscle that needs more weekly volume than its main day can hold is a
programme decision, so it is made like one: once, at the start of the block,
from how far below its BAND each muscle ran over the block before, and held
for the block's four Cardio+Abs days so the two lifts progress like any other.
The pick is stored with the numbers that justified it, so the coach can say
why, and the rolling readout stays in context as information.

The bands are read from the prompt, so the two cannot disagree.
"""

import json
import logging
import re
from datetime import date, timedelta

from data import (CYCLE, YOGA_SESSION_TYPE, get_supabase, is_session_finished,
                  now_local)
from volume import _is_cardio_or_yoga, resolve_contributions

log = logging.getLogger(__name__)

SLOTS = 2
ROTATION = len(CYCLE)                 # sessions per week of the block
BLOCK_SLOTS = ROTATION * 4            # sessions per block
DECISION_PREFIX = "Weak-point: "
NONE = "none"                          # stored when no muscle was under its band
# A muscle the athlete has named for the NEXT block's emphasis, waiting to be
# consumed when that block's pick is made. Stored under today's date so it
# never collides with a block's own pick rows.
PENDING_PREFIX = "Emphasis-next: "
# Sessions a lift's top load must sit still for before it counts as a stall.
STALL_SESSIONS = 3
# Muscles that have their own block and never fill a slot.
EXCLUDED = ("Abs",)

# ── Bands, from the prompt ───────────────────────────────────────────────────

_BAND_LINE = "Weekly volume targets per muscle"
_BAND_RE = re.compile(r"([A-Za-z ,]+?)\s+(\d+)\s*-\s*(\d+)\.")


def _canonical(name: str) -> str:
    name = " ".join(name.split()).strip().lower()
    return "Rear Delts" if name == "rear delts" else name.title()


def parse_volume_bands(prompt: str) -> dict:
    """{muscle: (low, high)} from the prompt's own sentence — "Chest, back,
    quads, hamstrings 10-16. Shoulders, biceps, triceps 8-12. Calves 6-10.
    Rear delts 8-14. Abs 10-16." Empty when the sentence is not there."""
    line = next((l for l in (prompt or "").splitlines() if _BAND_LINE in l), "")
    if not line:
        return {}
    tail = line.split("recompute.", 1)[-1] if "recompute." in line else line
    bands = {}
    for names, low, high in _BAND_RE.findall(tail):
        for name in names.split(","):
            if name.strip():
                bands[_canonical(name)] = (int(low), int(high))
    return bands


# ── Where the block starts ───────────────────────────────────────────────────

def rotation_sessions(supabase, days: int = 120) -> list[dict]:
    """Finished, non-yoga sessions, one per (date, type), oldest first."""
    since = (now_local().date() - timedelta(days=days)).isoformat()
    rows = (
        supabase.table("workout_sessions")
        .select("id, date, type, status, mesocycle_week, mesocycle_day")
        .gte("date", since)
        .order("date")
        .order("id")
        .execute()
    ).data or []
    out, seen = [], set()
    for row in rows:
        kind = (row.get("type") or "").strip()
        if kind == YOGA_SESSION_TYPE or kind not in CYCLE:
            continue
        if not is_session_finished(row.get("status")):
            continue
        key = (row.get("date"), kind)
        if key in seen or not key[0]:
            continue
        seen.add(key)
        out.append(row)
    return out


def block_start(sessions: list[dict], week: int, day: int, today: str) -> str | None:
    """The date the current block began.

    A stamped week-1/day-1 session in the last five weeks is the answer when
    there is one. Otherwise the memory state — the week and day of the NEXT
    session — says how many of this block's slots are done, and the block
    began at the session that many slots back. Zero done means the block
    begins with today's session.
    """
    floor = (date.fromisoformat(today) - timedelta(days=35)).isoformat()
    stamped = [s for s in sessions
               if s.get("mesocycle_week") == 1 and s.get("mesocycle_day") == 1
               and (s.get("date") or "") >= floor]
    if stamped:
        return stamped[-1]["date"]
    done = max(0, (week - 1) * ROTATION + (day - 1))
    if done == 0:
        return today
    if len(sessions) < done:
        return None
    return sessions[-done]["date"]


def previous_block_range(sessions: list[dict], start: str) -> tuple | None:
    """(since, until) covering the block before `start`: its last sixteen
    sessions, or as many as exist. None when nothing precedes the start."""
    before = [s for s in sessions if s["date"] < start]
    if not before:
        return None
    previous = before[-BLOCK_SLOTS:]
    return previous[0]["date"], before[-1]["date"]


# ── Volume over a range, and the pick ────────────────────────────────────────

def volume_between(supabase, since: str, until: str) -> dict:
    """Working sets per week per muscle over [since, until], fractionally
    attributed exactly as the rolling readout is."""
    rows = (
        supabase.table("workout_sets")
        .select("exercise, is_warmup, notes, date")
        .gte("date", since)
        .lte("date", until)
        .execute()
    ).data or []
    days = (date.fromisoformat(until) - date.fromisoformat(since)).days + 1
    weeks = max(days / 7.0, 1.0)
    totals: dict = {}
    for row in rows:
        if row.get("is_warmup") or _is_cardio_or_yoga(row):
            continue
        for muscle, share in resolve_contributions(row.get("exercise", "")).items():
            totals[muscle] = totals.get(muscle, 0.0) + share
    return {m: round(v / weeks, 1) for m, v in totals.items()}


def rank_by_shortfall(volume: dict, bands: dict, exclude=EXCLUDED) -> list[dict]:
    """Every banded muscle, furthest below its band first.

    `shortfall` is band_low minus sets per week: positive means under the
    band, zero or negative means inside or over it. The two at the top are
    the pick; when fewer than two are under, the next is the one with the
    least headroom, and it is labelled as such rather than passed off as a
    deficit.
    """
    rows = []
    for muscle, (low, high) in bands.items():
        if muscle in exclude:
            continue
        sets = float(volume.get(muscle, 0.0))
        rows.append({"muscle": muscle, "sets": round(sets, 1), "low": low, "high": high,
                     "shortfall": round(low - sets, 1)})
    rows.sort(key=lambda r: (-r["shortfall"], r["muscle"]))
    return rows


# ── The stored decision ──────────────────────────────────────────────────────

def _stored_pick(supabase, start: str) -> list[dict]:
    rows = (
        supabase.table("prescription_decisions")
        .select("exercise, reason, plan, date")
        .eq("date", start)
        .like("exercise", f"{DECISION_PREFIX}%")
        .order("id")
        .execute()
    ).data or []
    out = []
    for row in rows:
        try:
            detail = row.get("plan") or {}
            if isinstance(detail, str):
                detail = json.loads(detail)
        except (TypeError, ValueError):
            detail = {}
        out.append({"muscle": row["exercise"][len(DECISION_PREFIX):], "reason": row.get("reason") or "",
                    **{k: detail.get(k) for k in ("sets", "low", "high", "shortfall", "since", "until")}})
    return out


def _store_pick(supabase, start: str, picks: list[dict], since: str, until: str) -> None:
    rows = []
    if not picks:
        rows.append({"date": start, "session_type": "Cardio+Abs", "mesocycle_week": 1,
                     "exercise": f"{DECISION_PREFIX}{NONE}", "decision": "accept",
                     "reason": f"Block pick: no muscle ran under its band over the previous block "
                               f"({since} to {until}); both weak-point slots stay empty.",
                     "plan": json.dumps({"since": since, "until": until})})
    for p in picks:
        rows.append({
            "date": start, "session_type": "Cardio+Abs", "mesocycle_week": 1,
            "exercise": f"{DECISION_PREFIX}{p['muscle']}", "decision": "accept",
            "reason": p["reason"],
            "plan": json.dumps({**{k: p[k] for k in ("sets", "low", "high", "shortfall")},
                                "since": since, "until": until}),
        })
    supabase.table("prescription_decisions").insert(rows).execute()


def _reason(p: dict, since: str, until: str) -> str:
    band = f"{p['low']}-{p['high']}"
    if p["shortfall"] > 0:
        return (f"Block pick: {p['muscle']} ran {p['sets']:g} sets/week against a {band} band "
                f"over the previous block ({since} to {until}) — short by {p['shortfall']:g}.")
    return (f"Block pick: {p['muscle']} ran {p['sets']:g} sets/week against {band} over the "
            f"previous block ({since} to {until}) — inside the band, but with the least headroom; "
            f"nothing else was under.")


def current_block_weak_points(memory: dict, prompt: str) -> dict | None:
    """This block's two weak-point muscles, computed once and stored.

    Returns {"block_start", "since", "until", "picks": [...], "ranking": [...],
    "source": "stored"|"computed"} or None when it cannot be known — no
    database, no bands in the prompt, or not enough history to place the
    block. Every failure is a log line; the coach then falls back to the
    rolling readout as before.
    """
    try:
        supabase = get_supabase()
        bands = parse_volume_bands(prompt)
        if not supabase or not bands:
            return None
        today = now_local().strftime("%Y-%m-%d")
        week = int(memory.get("mesocycle_week", 1) or 1)
        day = int(memory.get("mesocycle_day", 1) or 1)
        sessions = rotation_sessions(supabase)
        start = block_start(sessions, week, day, today)
        if start is None:
            return None

        stored = _stored_pick(supabase, start)
        if stored:
            picks = [p for p in stored if p["muscle"] != NONE][:SLOTS]
            return {"block_start": start, "since": stored[0].get("since"), "until": stored[0].get("until"),
                    "picks": picks, "ranking": [], "source": "stored"}

        window = previous_block_range(sessions, start)
        if window is None:
            return None
        since, until = window
        ranking = rank_by_shortfall(volume_between(supabase, since, until), bands)
        # The slot is an EMPHASIS, earned in this order:
        #   1. a muscle the athlete named for this block ("emphasis next: ...");
        #   2. a real deficit — a muscle that ran under its band last block;
        #   3. a stall — a lift whose top load sat still for three sessions
        #      last block, nominating its prime mover for one block of extra
        #      volume (the dose-response is real; the bands are the floor,
        #      not the ceiling);
        #   4. nothing, and the day ends after the ab block.
        # One muscle per block. With the templates covering every band, 2 and
        # 3 are the exceptions they were meant to be.
        picks = []
        pending = _pending_emphasis(supabase)
        for named in pending:
            if named["muscle"] not in bands or any(p["muscle"] == named["muscle"] for p in picks):
                continue
            low, high = bands[named["muscle"]]
            picks.append({"muscle": named["muscle"], "sets": 0, "low": low, "high": high, "shortfall": 0,
                          "reason": f"Emphasis this block, named by the athlete on {named['set_on']}"
                                    + (f": {named['note']}" if named.get("note") else "") + "."})
        if not picks:
            picks = [r for r in ranking[:1] if r["shortfall"] > 0]
            for p in picks:
                p["reason"] = _reason(p, since, until)
        if not picks:
            stall = _stalled_muscle(supabase, since, until, bands)
            if stall:
                picks = [stall]
        try:
            _store_pick(supabase, start, picks, since, until)
            if pending:
                _consume_pending(supabase)
        except Exception:
            log.exception("Could not store this block's weak-point pick")
        return {"block_start": start, "since": since, "until": until, "picks": picks,
                "ranking": ranking, "source": "computed"}
    except Exception:
        log.exception("Could not determine this block's weak points")
        return None


def _pending_emphasis(supabase) -> list[dict]:
    """The athlete's named emphases for the next block, oldest first, at
    most one per slot."""
    rows = (supabase.table("prescription_decisions").select("id, exercise, reason, date")
            .like("exercise", f"{PENDING_PREFIX}%").order("id").execute()).data or []
    out = []
    for row in rows:
        out.append({"id": row.get("id"), "muscle": row["exercise"][len(PENDING_PREFIX):],
                    "note": row.get("reason") or "", "set_on": row.get("date")})
    return out[-SLOTS:]


def _consume_pending(supabase) -> None:
    supabase.table("prescription_decisions").delete().like("exercise", f"{PENDING_PREFIX}%").execute()


def _stalled_muscle(supabase, since: str, until: str, bands: dict) -> dict | None:
    """The prime mover of the lift most stuck over the previous block, if any
    lift's top load sat still for STALL_SESSIONS sessions."""
    from progression import find_stalls  # local: keeps import order flat
    rows = (supabase.table("workout_sets")
            .select("exercise, actual_weight_kg, actual_reps, actual_rpe, is_warmup, notes, date")
            .gte("date", since).lte("date", until).execute()).data or []
    for stall in find_stalls(rows, min_sessions=STALL_SESSIONS):
        # Only a LOADED lift can stall here. A bodyweight movement sits at
        # "BW" by design and progresses by reps or a plate, and a row with no
        # load recorded says nothing about progress.
        if not isinstance(stall.get("load"), (int, float)) or stall["load"] <= 0:
            continue
        muscle = _canonical(primary_muscle(stall["exercise"]) or "")
        if muscle in bands and muscle not in EXCLUDED:
            low, high = bands[muscle]
            load = stall["load"]
            load_s = "bodyweight" if load == "BW" else f"{load:g}kg"
            return {"muscle": muscle, "sets": 0, "low": low, "high": high, "shortfall": 0,
                    "reason": f"Emphasis this block: {stall['exercise']} sat at {load_s} for "
                              f"{stall['sessions']} sessions ({stall['first_date']} to {stall['last_date']}) "
                              f"— one block of extra {muscle} volume, then the slot moves on."}
    return None


def format_block_weak_points(info: dict | None) -> str:
    """The block the coach reads before filling a slot."""
    if not info:
        return ("THIS BLOCK'S EMPHASIS — unavailable (not enough history to place the block). "
                "Leave the weak-point slots empty unless he names a muscle.")
    if not info.get("picks"):
        return (f"THIS BLOCK'S EMPHASIS — none. Over the previous block "
                f"({info.get('since')} to {info.get('until')}) no muscle ran under its band, no lift "
                f"stalled, and he named nothing, so both weak-point slots stay EMPTY this block and "
                f"Cardio+Abs ends after the ab block. Filling a slot anyway is an adjust with its reason.")
    lines = [f"THIS BLOCK'S EMPHASIS — chosen once, at the block's start ({info['block_start']}), and "
             f"held for every Cardio+Abs day this block so the lift progresses like any other:"]
    for p in info["picks"]:
        sets = p.get("sets")
        low, high = p.get("low"), p.get("high")
        short = p.get("shortfall")
        if not sets or low is None:
            lines.append(f"  {p['muscle']}: {p.get('reason', '')}")
            continue
        state = (f"short by {short:g}" if (short or 0) > 0
                 else "inside the band, least headroom — nothing else was under")
        lines.append(f"  {p['muscle']}: {sets:g} sets/week against {low}-{high} — {state}")
    n = len(info["picks"])
    lines.append(f"{'ONE slot' if n == 1 else 'One slot per muscle above'}, 3 straight sets each, a movement "
                 f"that loads the muscle in a way the rotation does not (triceps: the overhead cable "
                 f"extension, long head lengthened; chest: the low-to-high cable fly, upper fibres). "
                 f"{'The other slot stays empty. ' if n == 1 else ''}The rolling WEEKLY VOLUME readout is "
                 f"information, not the pick; departing from this block's emphasis is an adjust with its reason.")
    return "\n".join(lines)


def primary_muscle(exercise: str) -> str:
    shares = resolve_contributions(exercise)
    return max(shares, key=lambda m: shares[m]) if shares else ""


# ── The athlete's override ───────────────────────────────────────────────────

_COMMAND_RE = re.compile(
    r"^/?(?:weak\s*-?\s*points?|emphasis)\s*(?P<next>next)?\s*(?::|=|are|is|->)?\s*(?P<body>.+?)\s*[.!]?$",
    re.IGNORECASE)
_NONE_WORDS = {"none", "no", "clear", "nothing", "empty", "skip"}


def parse_weak_point_command(text: str) -> list[str] | None:
    """"weak points none" -> []; "weak points: rear delts, hamstrings" -> the
    two names; anything else -> None (not a command). "next" variants belong
    to parse_emphasis_next."""
    m = _COMMAND_RE.match((text or "").strip())
    if not m or m.group("next"):
        return None
    body = m.group("body").strip().lower()
    if body in _NONE_WORDS:
        return []
    names = [n.strip() for n in re.split(r",|\band\b|&|/", body) if n.strip()]
    return names[:SLOTS] if names else None


def parse_emphasis_next(text: str) -> dict | None:
    """"emphasis next: triceps | overhead cable extension" -> {"muscle", "note"};
    "emphasis next: none" -> {"muscle": None} (withdraw); else None."""
    m = _COMMAND_RE.match((text or "").strip())
    if not m or not m.group("next"):
        return None
    body = m.group("body").strip()
    if body.lower() in _NONE_WORDS:
        return {"muscle": None, "note": ""}
    parts = [p.strip() for p in body.split("|")]
    return {"muscle": parts[0], "note": " — ".join(parts[1:])}


def set_next_emphasis(prompt: str, muscle: str | None, note: str = "") -> str:
    """Store (or withdraw) the athlete's emphasis for the NEXT block. Consumed
    when that block's pick is made; nothing about this block changes."""
    supabase = get_supabase()
    bands = parse_volume_bands(prompt)
    if not supabase or not bands:
        return "I can't reach the block's record right now, so nothing changed."
    if muscle is None:
        supabase.table("prescription_decisions").delete().like("exercise", f"{PENDING_PREFIX}%").execute()
        return "Done — no emphasis carried into the next block; it will be picked from the numbers."
    c = _canonical(muscle)
    if c not in bands or c in EXCLUDED:
        return (f"'{muscle}' isn't a muscle with a band. The bands cover: "
                + ", ".join(k for k in bands if k not in EXCLUDED) + ".")
    # Two slots, so up to two named muscles. Naming a muscle again replaces
    # its own entry; a third name drops the oldest.
    existing = _pending_emphasis(supabase)
    for e in existing:
        if e["muscle"] == c:
            supabase.table("prescription_decisions").delete().eq("id", e["id"]).execute()
    existing = [e for e in existing if e["muscle"] != c]
    while len(existing) >= SLOTS:
        supabase.table("prescription_decisions").delete().eq("id", existing[0]["id"]).execute()
        existing = existing[1:]
    today = now_local().strftime("%Y-%m-%d")
    supabase.table("prescription_decisions").insert([{
        "date": today, "session_type": "Cardio+Abs", "mesocycle_week": 1,
        "exercise": f"{PENDING_PREFIX}{c}", "decision": "accept", "reason": note or None,
        "plan": json.dumps({"set_on": today}),
    }]).execute()
    named = [e["muscle"] for e in existing] + [c]
    return (f"Done — {' and '.join(named)} {'is' if len(named) == 1 else 'are'} the emphasis for the next block"
            + (f" ({c}: {note})" if note else "")
            + ". One weak-point slot each on every Cardio+Abs day of that block, then the slots move on.")


def set_block_weak_points(memory: dict, prompt: str, muscles: list[str]) -> str:
    """Overwrite this block's stored pick with the athlete's own.

    The pick is made once per block from the block before, so a programme
    change lands one block late: hamstrings and calves were picked from a
    Legs day that no longer exists, and on the new template neither is
    under its band. Rather than a swap the athlete cannot see, this stores
    the correction as the block's decision, with the reason, exactly where
    the computed pick would sit. Returns the sentence to show the athlete.
    """
    supabase = get_supabase()
    bands = parse_volume_bands(prompt)
    if not supabase or not bands:
        return "I can't reach the block's record right now, so nothing changed."
    canon = {}
    for name in muscles:
        c = _canonical(name)
        if c not in bands or c in EXCLUDED:
            return (f"'{name}' isn't a muscle with a band. The bands cover: "
                    + ", ".join(k for k in bands if k not in EXCLUDED) + ".")
        canon[c] = True
    today = now_local().strftime("%Y-%m-%d")
    week = int(memory.get("mesocycle_week", 1) or 1)
    day = int(memory.get("mesocycle_day", 1) or 1)
    sessions = rotation_sessions(supabase)
    start = block_start(sessions, week, day, today)
    if start is None:
        return "I can't place this block yet (not enough stamped sessions), so nothing changed."
    supabase.table("prescription_decisions").delete().eq("date", start)\
        .like("exercise", f"{DECISION_PREFIX}%").execute()
    picks = []
    for c in canon:
        low, high = bands[c]
        picks.append({"muscle": c, "sets": 0, "low": low, "high": high, "shortfall": 0,
                      "reason": f"Set by the athlete on {today}: {c} fills a weak-point slot for the rest "
                                f"of this block (band {low}-{high})."})
    if picks:
        _store_pick(supabase, start, picks, since="athlete", until=today)
    else:
        supabase.table("prescription_decisions").insert([{
            "date": start, "session_type": "Cardio+Abs", "mesocycle_week": 1,
            "exercise": f"{DECISION_PREFIX}{NONE}", "decision": "accept",
            "reason": f"Set by the athlete on {today}: no weak point this block — on the current "
                      f"programme no muscle is under its band, so both slots stay empty.",
            "plan": json.dumps({"since": "athlete", "until": today}),
        }]).execute()
    if picks:
        return (f"Done — this block's weak-point slots are now {' and '.join(canon)}, from today until "
                f"the block ends. The coach reads that every session.")
    return ("Done — no weak-point slots for the rest of this block. Cardio+Abs ends after the ab "
            "block. The pick is remade from real numbers when the next block starts.")
