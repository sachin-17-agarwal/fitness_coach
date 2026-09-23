"""Session shape: the two lasting decisions that used to live in the
athlete's head and be re-negotiated every session in chat — a substitution
held for the block ("overhead cable extension instead of dips this block")
and a standing reorder ("shoulder press first on Push").

Stage 3 of docs/DECISION_CAPTURE.md. Both arrive as `Proposed:` lines in
the recordable grammar (decisions.py), are recorded with a tap or a word,
and are applied here, inside parse_session_template, so the coach's
set-count block and the programme's proposal read one shaped template and
agree by construction:

    Substitute: Dips -> Overhead Cable Extension | this block | elbow
    Order: Push | Machine Shoulder Press first | shoulder warm before pressing

`this block` expires at the block rollover; `standing` does not. The store
is the decision_captures rows themselves (status recorded); nothing is
copied anywhere else. Read once a minute at most, and a read that fails
leaves the template as written.
"""
from __future__ import annotations

import logging
import threading
import time
from datetime import timedelta

from data import get_supabase, local_date_str, now_local

log = logging.getLogger(__name__)

_TTL_SECONDS = 60
_BLOCK_FALLBACK_DAYS = 28
_cache: dict = {"at": 0.0, "shape": None}
_lock = threading.Lock()


def _fold(name: str) -> str:
    return "".join(ch for ch in (name or "").lower() if ch.isalnum())


def invalidate() -> None:
    with _lock:
        _cache["at"], _cache["shape"] = 0.0, None


def _block_start(supabase) -> str | None:
    """The current block's first day, or None when it cannot be placed."""
    try:
        from blocks import block_start  # local: keeps import order flat
        from memory import load_memory  # local: keeps import order flat
        from weakpoints import rotation_sessions  # local: keeps import order flat
        memory = load_memory()
        today = now_local().strftime("%Y-%m-%d")
        return block_start(rotation_sessions(supabase), int(memory.get("mesocycle_week", 1) or 1),
                           int(memory.get("mesocycle_day", 1) or 1), today)
    except Exception:
        log.debug("shape: block start unavailable", exc_info=True)
        return None


def _load() -> dict:
    """{"substitutes": [{from, to, horizon, why}], "orders": {session_fold: {first, session, why}}}."""
    from decisions import RECORDABLE_RE  # local: keeps import order flat
    empty = {"substitutes": [], "orders": {}}
    supabase = get_supabase()
    if not supabase:
        return empty
    try:
        rows = (supabase.table("decision_captures").select("line, kind, answered_at")
                .in_("kind", ["substitute", "order"]).eq("status", "recorded")
                .order("answered_at", desc=True).execute()).data or []
    except Exception:
        log.warning("decision_captures could not be read for the session shape")
        return empty
    if not rows:
        return empty
    start = _block_start(supabase) if any(" this block " in (r.get("line") or "") for r in rows) else None
    fallback = (now_local() - timedelta(days=_BLOCK_FALLBACK_DAYS)).strftime("%Y-%m-%d")
    out = {"substitutes": [], "orders": {}}
    # Newest first: the first row seen for a lift or a session decides; a
    # `| clear` row ends what came before it.
    seen_from: set[str] = set()
    seen_session: set[str] = set()
    for r in rows:
        m = RECORDABLE_RE.match((r.get("line") or "").strip())
        if not m:
            continue
        answered = local_date_str(r.get("answered_at"))
        if m.group("sub_from"):
            key = _fold(m.group("sub_from"))
            if key in seen_from:
                continue
            if not m.group("sub_to"):
                seen_from.add(key)
                continue
            if m.group("horizon") == "this block" and answered < (start or fallback):
                continue
            seen_from.add(key)
            out["substitutes"].append({"from": m.group("sub_from").strip(), "to": m.group("sub_to").strip(),
                                       "horizon": m.group("horizon"), "why": m.group("sub_why").strip()})
        elif m.group("order_session"):
            key = _fold(m.group("order_session"))
            if key in seen_session:
                continue
            seen_session.add(key)
            if m.group("order_first"):
                out["orders"][key] = {"session": m.group("order_session").strip(),
                                      "first": m.group("order_first").strip(), "why": m.group("order_why").strip()}
    return out


def recorded_shape() -> dict:
    with _lock:
        if _cache["shape"] is not None and time.monotonic() - _cache["at"] < _TTL_SECONDS:
            return _cache["shape"]
    shape = _load()
    with _lock:
        _cache["at"], _cache["shape"] = time.monotonic(), shape
    return shape


def apply(pairs: list[tuple[str, int]], session_type: str, shape: dict | None = None) -> list[tuple[str, int]]:
    """The template with the recorded substitutions and order applied. A
    substitute keeps the slot's set count; an order moves the named lift to
    the front. Nothing else moves."""
    shape = recorded_shape() if shape is None else shape
    if not shape or (not shape.get("substitutes") and not shape.get("orders")):
        return pairs
    out = []
    for name, sets in pairs:
        for s in shape.get("substitutes") or []:
            if _fold(s["from"]) == _fold(name):
                name = s["to"]
                break
        out.append((name, sets))
    order = (shape.get("orders") or {}).get(_fold(session_type))
    if order:
        first = _fold(order["first"])
        idx = next((i for i, (n, _) in enumerate(out) if _fold(n) == first), None)
        if idx is not None and idx > 0:
            out.insert(0, out.pop(idx))
    return out


def describe(session_type: str, pairs: list[tuple[str, int]] | None = None, shape: dict | None = None) -> str:
    """One line for the context when the shape changed today's template, so
    the coach knows why the set-count block differs from the programme."""
    shape = recorded_shape() if shape is None else shape
    parts = []
    names = {_fold(n) for n, _ in (pairs or [])}
    for s in shape.get("substitutes") or []:
        if not pairs or _fold(s["to"]) in names:
            parts.append(f"{s['from']} -> {s['to']} ({s['horizon']}; {s['why']})")
    order = (shape.get("orders") or {}).get(_fold(session_type))
    if order:
        parts.append(f"{order['first']} first ({order['why']})")
    return "; ".join(parts)
