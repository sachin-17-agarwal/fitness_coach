"""Idempotent chat delivery (migration 011).

The phone drops the connection whenever the athlete switches apps while the
coach is thinking; iOS suspends the app within seconds. The coach finishes
regardless, but the reply never reaches the card, and re-sending the message
used to make the coach see it twice.

Every message the app sends carries a client_id it generated. On arrival the
backend writes the USER turn with that id at once — the in-flight marker —
and the ASSISTANT turn with the same id when it answers. A resend of the
same id then finds one of three states:

  answered    the assistant turn exists: return it, run nothing
  in flight   the user turn exists and is fresh: 202, the app asks again
  unknown     nothing, or a marker older than INFLIGHT_STALE_SECONDS: process

Without the column (migration not yet run) the marker cannot be stored; an
in-process set stands in, which covers everything but a restart mid-request.
"""

from __future__ import annotations

import logging
import threading
from datetime import datetime, timedelta

from data import get_supabase, now_local
from memory import save_conversation_message

log = logging.getLogger(__name__)

INFLIGHT_STALE_SECONDS = 180

_lock = threading.Lock()
_inflight_memory: dict[str, datetime] = {}


def find_delivery(client_id: str) -> dict:
    """{"user": row|None, "assistant": row|None} for the exchange `client_id`
    tags; both None when the store has no column or nothing is written."""
    supabase = get_supabase()
    out = {"user": None, "assistant": None}
    if not supabase or not client_id:
        return out
    try:
        rows = (supabase.table("conversations").select("id, role, content, created_at, client_id")
                .eq("client_id", client_id).order("id").execute()).data or []
    except Exception:
        log.warning("conversations has no client_id column (migration 011?); delivery cannot be recovered")
        return out
    for row in rows:
        if row.get("role") == "user" and out["user"] is None:
            out["user"] = row
        elif row.get("role") == "assistant":
            out["assistant"] = row
    return out


def _is_stale(created_at: str | None) -> bool:
    if not created_at:
        return True
    try:
        started = datetime.fromisoformat(str(created_at).replace("Z", "+00:00"))
    except ValueError:
        return True
    now = now_local()
    if started.tzinfo is None and now.tzinfo is not None:
        now = now.replace(tzinfo=None)
    if started.tzinfo is not None and now.tzinfo is None:
        started = started.replace(tzinfo=None)
    return now - started > timedelta(seconds=INFLIGHT_STALE_SECONDS)


def check(client_id: str) -> tuple[str, dict | None]:
    """("answered", assistant_row) | ("in_flight", None) | ("new", None)."""
    found = find_delivery(client_id)
    if found["assistant"]:
        return "answered", found["assistant"]
    if found["user"] and not _is_stale(found["user"].get("created_at")):
        return "in_flight", None
    with _lock:
        started = _inflight_memory.get(client_id)
        if started and now_local() - started <= timedelta(seconds=INFLIGHT_STALE_SECONDS):
            return "in_flight", None
    return "new", None


def claim(client_id: str, text: str) -> None:
    """Mark the exchange in flight: the user turn, tagged, written now. A
    stale marker from a request that died is refreshed rather than doubled."""
    with _lock:
        _inflight_memory[client_id] = now_local()
        for key in [k for k, v in _inflight_memory.items() if now_local() - v > timedelta(hours=6)]:
            _inflight_memory.pop(key, None)
    supabase = get_supabase()
    found = find_delivery(client_id) if supabase else {"user": None}
    if found["user"]:
        try:
            supabase.table("conversations").update({"created_at": now_local().isoformat()})\
                .eq("id", found["user"]["id"]).execute()
        except Exception:
            log.warning("could not refresh the in-flight marker", exc_info=True)
        return
    save_conversation_message("user", text, client_id=client_id)


def release(client_id: str) -> None:
    with _lock:
        _inflight_memory.pop(client_id, None)
