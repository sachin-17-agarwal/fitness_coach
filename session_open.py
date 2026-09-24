"""Start on the programme; the coach catches up.

The athlete's two constraints for the session opening: no waiting, and no
model call a session does not use. The programme's numbers are already
computed in code in under a second — the progression rule, the recovery
read and the standing ceilings applied — and until now they were only the
proposal the coach reviewed. `open_session` renders them as the card the
moment START is pressed, labelled as the programme's, stores them as
today's plan so a set logged meanwhile has a plan to move from, and starts
the coach's review on a thread. `review_session` runs the same plan call
as before, stores the coach's plan on top (newer rows win in
load_today_plan), and records what changed and why. `session_status` is
what the app polls. No extra call is made: the one call the opening always
made is the review.

The visible cost is an occasional number changing before the athlete
reaches that exercise, always with its cause. How often is the adjust rate
in the Sunday report.
"""

from __future__ import annotations

import json
import logging
import threading
import time

from coach_parsing import parse_all_prescriptions
from data import now_local
from memory import load_today_conversation, save_conversation_message, set_memory_value

log = logging.getLogger(__name__)

REVIEW_KEY = "session_review"
PROGRAMME_OPENING = ("Programme plan — the coach is reviewing it now and the card updates "
                     "where the review differs. Warm up on the first exercise.")
PROGRAMME_REASON = "programme — coach reviewing"


def open_session(session_type: str, memory: dict, opening_message: str,
                 recovery_override: dict | None = None, session_id: str | None = None,
                 start_review: bool = True) -> dict:
    """The programme's card for today, at once. Returns
    {"status": "reviewing", "response": text} — or {"status": "unavailable"}
    when the programme has no computed block, in which case the app falls
    back to the ordinary opening."""
    from coach import (ATHLETE_CURRENT_WEIGHT_KG, ATHLETE_GOAL_WEIGHT_KG, ATHLETE_NAME,
                       load_system_prompt)  # local: coach imports widely
    from coach_context import build_context_block
    from plan import SessionPlan, fill_from_programme, render_plan, save_decisions

    system_prompt = load_system_prompt()
    programme_out: dict = {}
    build_context_block(memory, ATHLETE_NAME, ATHLETE_CURRENT_WEIGHT_KG, ATHLETE_GOAL_WEIGHT_KG,
                        log, recovery_override=recovery_override, system_prompt=system_prompt,
                        out=programme_out, session_type=session_type)
    computed = programme_out.get("computed") or {}
    plan = SessionPlan(opening=PROGRAMME_OPENING, exercises=[])
    plan, _problems, _filled = fill_from_programme(plan, [], session_type, system_prompt, computed)
    if not plan.exercises:
        log.info("open_session: no computed programme for %s; app falls back to the coach", session_type)
        return {"status": "unavailable"}
    for e in plan.exercises:
        e.reason = PROGRAMME_REASON
    text = render_plan(plan, computed)
    week = _safe_int(memory.get("mesocycle_week", 1))
    save_decisions(plan, session_type, week, session_id=session_id, proposal=computed)
    save_conversation_message("user", opening_message)
    today = now_local().strftime("%Y-%m-%d")
    _write_status({"date": today, "session_type": session_type, "status": "reviewing",
                   "started_at": now_local().isoformat(), "programme": text})
    if start_review:
        threading.Thread(target=review_session, daemon=True,
                         kwargs=dict(session_type=session_type, memory=memory,
                                     opening_message=opening_message,
                                     recovery_override=recovery_override,
                                     programme_text=text)).start()
    return {"status": "reviewing", "response": text}


def review_session(session_type: str, memory: dict, opening_message: str,
                   recovery_override: dict | None, programme_text: str) -> dict:
    """The coach's plan, on top of the programme's. Runs the same plan call
    the opening always ran; stores the outcome for the app to poll."""
    started = time.monotonic()
    today = now_local().strftime("%Y-%m-%d")
    base = {"date": today, "session_type": session_type, "programme": programme_text}
    try:
        from coach import chat_with_coach  # local: coach imports widely
        history = load_today_conversation()
        text = chat_with_coach(opening_message, history, memory, recovery_override=recovery_override,
                               plan_request=True, session_type=session_type,
                               record_user_message=False)
        changes = diff_plans(programme_text, text)
        status = {**base, "status": "reviewed", "response": text, "changes": changes,
                  "seconds": round(time.monotonic() - started, 1)}
    except Exception as exc:
        log.exception("Session review failed; the programme plan stands")
        status = {**base, "status": "failed", "error": f"{type(exc).__name__}: {exc}",
                  "seconds": round(time.monotonic() - started, 1)}
    _write_status(status)
    return status


def session_status(memory: dict) -> dict:
    """What the app polls: {"status": none|reviewing|reviewed|failed, ...}."""
    raw = memory.get(REVIEW_KEY)
    if not raw:
        return {"status": "none"}
    try:
        data = json.loads(raw) if isinstance(raw, str) else dict(raw)
    except ValueError:
        return {"status": "none"}
    if data.get("date") != now_local().strftime("%Y-%m-%d"):
        return {"status": "none"}
    out = {"status": data.get("status", "none"), "session_type": data.get("session_type")}
    if data.get("status") == "reviewed":
        out["response"] = data.get("response", "")
        out["changes"] = data.get("changes", [])
    if data.get("status") == "failed":
        out["error"] = data.get("error", "")
    return out


def diff_plans(programme_text: str, coach_text: str) -> list[dict]:
    """Per exercise, what the coach changed against the programme and why —
    the card updates only these."""
    def key(name: str) -> str:
        return " ".join((name or "").split()).lower()
    prog = {key(b["exercise"]): b for b in parse_all_prescriptions(programme_text)}
    coach = {key(b["exercise"]): b for b in parse_all_prescriptions(coach_text)}
    changes: list[dict] = []
    for k, cb in coach.items():
        pb = prog.get(k)
        if pb is None:
            changes.append({"exercise": cb["exercise"], "change": "added", "to": _summary(cb),
                            "why": cb.get("why") or ""})
            continue
        if _sets(pb) != _sets(cb):
            changes.append({"exercise": cb["exercise"], "change": "changed", "from": _summary(pb),
                            "to": _summary(cb), "why": cb.get("why") or ""})
    for k, pb in prog.items():
        if k not in coach:
            changes.append({"exercise": pb["exercise"], "change": "removed", "from": _summary(pb), "why": ""})
    return changes


def _sets(block: dict) -> list:
    def norm(rows):
        return [(float(r.get("weight") or 0), int(r.get("reps") or 0),
                 int(r.get("reps_high") or r.get("reps") or 0), float(r.get("rpe") or 0)) for r in rows or []]
    return [norm(block.get("working")), norm(block.get("backoff"))]


def _summary(block: dict) -> str:
    def one(r):
        reps = f"x{r.get('reps')}" + (f"-{r['reps_high']}" if r.get("reps_high") and r["reps_high"] != r.get("reps") else "")
        rpe = f" @{r['rpe']:g}" if r.get("rpe") else ""
        return f"{r.get('weight'):g}kg {reps}{rpe}"
    working = ", ".join(one(r) for r in block.get("working") or [])
    backoff = ", ".join(one(r) for r in block.get("backoff") or [])
    return working + (f" / {backoff}" if backoff else "")


def _write_status(status: dict) -> None:
    set_memory_value(REVIEW_KEY, json.dumps(status))


def _safe_int(value, default: int = 1) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default
