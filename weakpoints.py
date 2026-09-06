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
        if len(stored) >= SLOTS:
            return {"block_start": start, "since": stored[0].get("since"), "until": stored[0].get("until"),
                    "picks": stored[:SLOTS], "ranking": [], "source": "stored"}

        window = previous_block_range(sessions, start)
        if window is None:
            return None
        since, until = window
        ranking = rank_by_shortfall(volume_between(supabase, since, until), bands)
        picks = ranking[:SLOTS]
        for p in picks:
            p["reason"] = _reason(p, since, until)
        try:
            _store_pick(supabase, start, picks, since, until)
        except Exception:
            log.exception("Could not store this block's weak-point pick")
        return {"block_start": start, "since": since, "until": until, "picks": picks,
                "ranking": ranking, "source": "computed"}
    except Exception:
        log.exception("Could not determine this block's weak points")
        return None


def format_block_weak_points(info: dict | None) -> str:
    """The block the coach reads before filling the two slots."""
    if not info or not info.get("picks"):
        return ("THIS BLOCK'S WEAK POINTS — unavailable (not enough history to place the "
                "block). Fill the two slots from the two muscles furthest below their bands "
                "in WEEKLY VOLUME, and say which.")
    lines = [f"THIS BLOCK'S WEAK POINTS — chosen once, at the block's start ({info['block_start']}), "
             f"from the previous block's volume against the bands, and held for every "
             f"Cardio+Abs day this block so the two lifts progress like any other:"]
    for p in info["picks"]:
        sets = p.get("sets")
        low, high = p.get("low"), p.get("high")
        short = p.get("shortfall")
        if sets is None or low is None:
            lines.append(f"  {p['muscle']}: {p.get('reason', '')}")
            continue
        state = (f"short by {short:g}" if (short or 0) > 0
                 else "inside the band, least headroom — nothing else was under")
        lines.append(f"  {p['muscle']}: {sets:g} sets/week against {low}-{high} — {state}")
    lines.append("The two weak-point slots are these two muscles. The rolling WEEKLY VOLUME "
                 "readout is information, not the pick; departing from this block's pick "
                 "is an adjust with its reason, and it holds for the rest of the block.")
    return "\n".join(lines)


def primary_muscle(exercise: str) -> str:
    shares = resolve_contributions(exercise)
    return max(shares, key=lambda m: shares[m]) if shares else ""
