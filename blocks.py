"""Block identity and the block's stored pick — one definition.

A block is sixteen rotation sessions. Its identity is its BOUNDARY: the last
finished session before it, which does not move while the block's first day
drifts (a rest day before the opener, an unstamped opening session). Every
question about "which block" is answered here, once:

  block_start(...)          the date the current block began (or begins)
  block_boundary(...)       the last finished session before a start
  ended_block_range(...)    the block that has just ended, for the review
  previous_block_range(...) the block before a start, for volume windows

and every read or write of a block's stored weak-point pick and of the
athlete's queued emphasis goes through the helpers below, keyed by the
boundary rather than by the day the row was written. Until 20 Sep 2026
three helpers in weakpoints.py answered the first question three ways; they
agreed because one person wrote them, which is not the same as one
definition.

The functions take the sessions and the store as arguments and read no
clock of their own, so callers (and their tests) decide today's date.
"""

from __future__ import annotations

import json
import logging
from datetime import date, timedelta

from data import CYCLE

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


# ── Where a block starts and ends ────────────────────────────────────────────

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
        # Nothing of the new block is done. It begins no earlier than the
        # day after the last finished session: when that session was today
        # (the deload's last day, memory already rolled over), "today" would
        # put the block's first day on the old block's last, and every range
        # built from the start would drop that session.
        last = sessions[-1]["date"] if sessions else None
        if last and last >= today:
            return (date.fromisoformat(last) + timedelta(days=1)).isoformat()
        return today
    if len(sessions) < done:
        return None
    return sessions[-done]["date"]


def block_boundary(sessions: list[dict], start: str) -> str | None:
    """The last finished session before `start`: the date that identifies
    the block after it. A block's first day drifts (a rest day before the
    opening session, an unstamped opener), the boundary does not — so a
    pick stored on any day after the boundary belongs to that block."""
    before = [s["date"] for s in sessions if (s.get("date") or "") < start]
    return before[-1] if before else None


def ended_block_range(sessions: list[dict], today: str) -> tuple | None:
    """(since, until) of the block that has just ended, for the morning-after
    review: the last BLOCK_SLOTS sessions up to today, or from the most recent
    stamped week-1/day-1 session among them when the block ran short. None
    when no session exists. Sessions on today count: the deload's last day is
    the day the review is read.

    Unlike block_start this never answers "today": a block that took longer
    than five weeks of calendar, or whose opening session carries no stamp,
    is still the last sixteen sessions, not a one-day window."""
    done = [s for s in sessions if (s.get("date") or "") <= today]
    if not done:
        return None
    block = done[-BLOCK_SLOTS:]
    for i in range(len(block) - 1, 0, -1):
        if block[i].get("mesocycle_week") == 1 and block[i].get("mesocycle_day") == 1:
            block = block[i:]
            break
    return block[0]["date"], block[-1]["date"]


def previous_block_range(sessions: list[dict], start: str) -> tuple | None:
    """(since, until) covering the block before `start`: its last sixteen
    sessions, or as many as exist. None when nothing precedes the start."""
    before = [s for s in sessions if s["date"] < start]
    if not before:
        return None
    previous = before[-BLOCK_SLOTS:]
    return previous[0]["date"], before[-1]["date"]


# ── The block's stored pick, and the queued emphasis ─────────────────────────

def _parse_pick_rows(rows: list[dict]) -> list[dict]:
    out = []
    for row in rows:
        try:
            detail = row.get("plan") or {}
            if isinstance(detail, str):
                detail = json.loads(detail)
        except (TypeError, ValueError):
            detail = {}
        out.append({"id": row.get("id"), "date": row.get("date"),
                    "muscle": row["exercise"][len(DECISION_PREFIX):], "reason": row.get("reason") or "",
                    **{k: detail.get(k) for k in ("sets", "low", "high", "shortfall", "since", "until", "exercise")}})
    return out


def _pick_rows_between(supabase, after: str | None, until: str | None) -> list[dict]:
    """Stored pick rows dated after `after` (exclusive) and up to `until`
    (inclusive), the latest day's set only: a block's pick is remade in
    place, so the newest day is the one that stands."""
    query = (supabase.table("prescription_decisions").select("id, exercise, reason, plan, date")
             .like("exercise", f"{DECISION_PREFIX}%"))
    if after:
        query = query.gte("date", (date.fromisoformat(after) + timedelta(days=1)).isoformat())
    if until:
        query = query.lte("date", until)
    rows = (query.order("id").execute()).data or []
    rows = [r for r in rows if (r.get("date") or "")
            and (not after or r["date"] > after) and (not until or r["date"] <= until)]
    if not rows:
        return []
    newest = max(r["date"] for r in rows)
    return [r for r in rows if r["date"] == newest]


def _stored_pick(supabase, start: str, boundary: str | None = None) -> list[dict]:
    """This block's stored pick: rows dated exactly at `start`, or — since the
    start drifts while the boundary does not — any rows dated after the
    previous block's last session. The 19 Sep 2026 review made the pick on
    the ended block's last day, dated that day; the next morning's start was
    a day later, the pick was invisible, and the named emphasis it had
    consumed would have been lost for a third time."""
    rows = (supabase.table("prescription_decisions").select("id, exercise, reason, plan, date")
            .eq("date", start).like("exercise", f"{DECISION_PREFIX}%").order("id").execute()).data or []
    if not rows and boundary:
        rows = _pick_rows_between(supabase, boundary, None)
    return _parse_pick_rows(rows)


def block_picks_between(supabase, after: str | None, until: str | None) -> list[dict]:
    """Read-only: the pick that governed the block whose sessions ran after
    `after` and through `until`. For the block review, which must never make
    or consume a pick."""
    return [p for p in _parse_pick_rows(_pick_rows_between(supabase, after, until)) if p["muscle"] != NONE]


def _delete_pick_rows(supabase, picks: list[dict], start: str) -> None:
    """Remove a block's stored pick rows, wherever they were dated."""
    ids = [p["id"] for p in picks if p.get("id") is not None]
    for rid in ids:
        supabase.table("prescription_decisions").delete().eq("id", rid).execute()
    if not ids:
        supabase.table("prescription_decisions").delete().eq("date", start)\
            .like("exercise", f"{DECISION_PREFIX}%").execute()


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
                                "exercise": p.get("exercise"), "since": since, "until": until}),
        })
    supabase.table("prescription_decisions").insert(rows).execute()


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
