"""Coach flags: the athlete marks a reply as wrong, in the moment, and the
whole exchange is kept where it can be read later.

Until 23 Sep 2026 a wrong reply was a screenshot in a chat with the
developer, read hours later without the card, the sets, or what the reply
contract had done. A flag keeps all of it at once: the question, the reply,
the card as the stored plan had it, the sets logged on that lift, and the
contract's record for that reply. The rows are read three ways: the app's
Settings shares them as one Markdown text; /api/flags returns the same; and
with GITHUB_FLAGS_TOKEN set each flag is also filed as an issue on the
repository, where the developer's tools can read it without the athlete
doing anything.
"""
from __future__ import annotations

import json
import logging
import threading
import urllib.request
from collections import OrderedDict
from datetime import timedelta

from data import get_supabase, local_time_str, now_local, today_local_str
from settings import get_settings

log = logging.getLogger(__name__)

# What the reply contract did to the last replies, by the app's client_id,
# kept in process: a flag lands seconds after the reply, and the record is
# not stored anywhere else. "_last" is the newest, for a flag with no id.
_RECENT: "OrderedDict[str, dict]" = OrderedDict()
_LOCK = threading.Lock()
_KEEP = 50
_LAST = "_last"

_SET_KEYS = ("set_number", "actual_weight_kg", "actual_reps", "actual_rpe")


def remember(client_id: str | None, reply_kind: str, record: list, exercise: str = "") -> None:
    entry = {"reply_kind": reply_kind, "record": list(record or []), "exercise": exercise or "",
             "at": now_local().isoformat()}
    with _LOCK:
        if client_id:
            _RECENT[client_id] = entry
        _RECENT[_LAST] = entry
        while len(_RECENT) > _KEEP:
            oldest = next(iter(_RECENT))
            if oldest == _LAST:
                _RECENT.move_to_end(_LAST)
                continue
            _RECENT.popitem(last=False)


def recall(client_id: str | None) -> dict | None:
    """The record for this reply, or the newest only when the flag names no
    id. An unknown id (after a redeploy, or an older reply) gets None rather
    than another reply's record presented as this one's."""
    with _LOCK:
        if client_id:
            return dict(_RECENT[client_id]) if client_id in _RECENT else None
        return dict(_RECENT[_LAST]) if _LAST in _RECENT else None


def _exchange(client_id: str | None) -> tuple[str, str]:
    """The athlete's message and the coach's reply being flagged: the pair
    written under the app's id, else the last two turns of today."""
    if client_id:
        from delivery import find_delivery  # local: keeps import order flat
        found = find_delivery(client_id)
        if found.get("assistant"):
            return ((found.get("user") or {}).get("content") or "", found["assistant"].get("content") or "")
    from memory import load_today_conversation  # local: keeps import order flat
    rows = load_today_conversation()
    user = next((r["content"] for r in reversed(rows) if r.get("role") == "user"), "")
    coach = next((r["content"] for r in reversed(rows) if r.get("role") == "assistant"), "")
    return user, coach


def _compact_sets(rows: list[dict]) -> list[dict]:
    return [{k: r.get(k) for k in _SET_KEYS if r.get(k) is not None} for r in rows or []]


def record_flag(note: str, exercise: str | None, client_id: str | None) -> dict:
    """Store the flag with everything around it; file it as an issue when a
    token is configured. Returns what the app shows: id, issue_url, summary.
    Nothing here may raise past the store: a flag that cannot be kept still
    comes back as text the athlete can share."""
    from plan import card_line, latest_logged_sets, load_today_plan  # local: keeps import order flat
    from workout import get_workout_state  # local: keeps import order flat

    state = get_workout_state()
    session_id = state.get("current_session_id") or None
    exercise = (exercise or state.get("current_exercise_name") or "").strip() or None
    user_message, coach_reply = _exchange(client_id)
    stored = load_today_plan(exercise) if exercise else None
    logged = _compact_sets(latest_logged_sets(session_id, exercise)) if exercise and session_id else []
    row = {
        "date": today_local_str(),
        "created_at": now_local().isoformat(),
        "session_id": session_id,
        "client_id": client_id,
        "exercise": exercise,
        "note": (note or "").strip(),
        "user_message": user_message,
        "coach_reply": coach_reply,
        "card": card_line(stored) if stored else "",
        "logged_sets": logged,
        "contract": recall(client_id) or {},
    }
    out = {"id": None, "issue_url": None, "summary": format_flag(row), "stored": False}
    supabase = get_supabase()
    if supabase:
        try:
            saved = supabase.table("coach_flags").insert(row).execute().data or []
            out["id"] = (saved[0] if saved else {}).get("id")
            out["stored"] = out["id"] is not None
        except Exception:
            log.exception("coach_flags insert failed (migration 013?)")
    url = _file_issue(row)
    if url:
        out["issue_url"] = url
        if supabase and out["id"] is not None:
            try:
                supabase.table("coach_flags").update({"issue_url": url}).eq("id", out["id"]).execute()
            except Exception:
                log.warning("coach_flags: issue filed but its url could not be stored")
    log.warning("COACH FLAG (%s): %s", exercise or "no lift", row["note"] or "no note")
    return out


def count_flags(days: int = 14) -> int:
    supabase = get_supabase()
    if not supabase:
        return 0
    since = (now_local() - timedelta(days=max(1, int(days)))).date().isoformat()
    try:
        res = supabase.table("coach_flags").select("id", count="exact").gte("date", since).execute()
        return int(res.count if res.count is not None else len(res.data or []))
    except Exception:
        return 0


def list_flags(days: int = 14) -> list[dict]:
    supabase = get_supabase()
    if not supabase:
        return []
    since = (now_local() - timedelta(days=max(1, int(days)))).date().isoformat()
    try:
        return (supabase.table("coach_flags").select("*").gte("date", since)
                .order("created_at", desc=True).execute()).data or []
    except Exception:
        log.exception("coach_flags select failed (migration 013?)")
        return []


def _one_set(s: dict) -> str:
    w, r, rpe = s.get("actual_weight_kg"), s.get("actual_reps"), s.get("actual_rpe")
    text = f"{w:g}kg" if isinstance(w, (int, float)) else str(w or "?")
    if r is not None:
        text += f" x{r}"
    if rpe is not None:
        text += f" @{rpe:g}" if isinstance(rpe, (int, float)) else f" @{rpe}"
    return text


def format_flag(row: dict) -> str:
    """One flag as Markdown, the way it is shared and filed."""
    when = local_time_str(row.get("created_at")) or str(row.get("date") or "")
    head = " · ".join(p for p in [when, row.get("exercise") or ""] if p)
    lines = [f"### {head or 'Coach flag'}"]
    if row.get("note"):
        lines.append(f"**What was wrong:** {row['note']}")
    if row.get("user_message"):
        lines.append(f"**Athlete:** {row['user_message']}")
    if row.get("coach_reply"):
        lines.append("**Coach:**\n\n" + "\n".join("> " + l for l in str(row["coach_reply"]).splitlines()))
    if row.get("card"):
        lines.append(f"**Card (stored plan):** {row['card']}")
    sets = row.get("logged_sets")
    if isinstance(sets, str):
        try:
            sets = json.loads(sets)
        except ValueError:
            sets = []
    if sets:
        lines.append("**Logged on this lift:** " + ", ".join(_one_set(s) for s in sets))
    contract = row.get("contract")
    if isinstance(contract, str):
        try:
            contract = json.loads(contract)
        except ValueError:
            contract = {}
    if contract:
        acted = [f"{r.get('step')}:{r.get('action')}" + (f"({r['detail']})" if r.get("detail") else "")
                 for r in contract.get("record") or []]
        lines.append(f"**Reply contract:** {contract.get('reply_kind') or '?'}"
                     + (" — " + "; ".join(acted) if acted else " — nothing acted"))
    if row.get("issue_url"):
        lines.append(f"Filed: {row['issue_url']}")
    return "\n\n".join(lines)


def format_flags(rows: list[dict]) -> str:
    if not rows:
        return "# Coach flags\n\nNone in this period."
    return f"# Coach flags ({len(rows)})\n\n" + "\n\n---\n\n".join(format_flag(r) for r in rows)


def _file_issue(row: dict) -> str | None:
    """One GitHub issue per flag, labelled coach-flag, when a token is set.
    The token is a fine-grained one with issues write on the repository,
    configured on the server; it never passes through the app."""
    s = get_settings()
    token, repo = (s.github_flags_token or "").strip(), (s.github_flags_repo or "").strip()
    if not token or not repo:
        return None
    title = " · ".join(p for p in ["Coach flag", str(row.get("date") or ""), row.get("exercise") or ""] if p)
    body = json.dumps({"title": title[:200], "body": format_flag(row), "labels": ["coach-flag"]}).encode()
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/issues", data=body, method="POST",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json", "User-Agent": "fitness-coach-flags"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return (json.loads(resp.read().decode() or "{}") or {}).get("html_url")
    except Exception as exc:
        log.warning("coach flag not filed as an issue: %s", exc)
        return None
