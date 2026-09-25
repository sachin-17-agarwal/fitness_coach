"""The decision scorecard: was the number right?

For six months every change to the coach answered a screenshot. Nothing
asked, after the session, whether the numbers it and the programme put on
the card were right — so the coach rubber-stamped the programme 94% of the
time in the 3-19 Sep block while the programme's own numbers came in light
15 times in 64, and nobody saw the trend (measured from the export, 24 Sep
2026).

One rule, applied to every lift of every finished session:

    the top set beat the top of its range at or under the target RPE  -> LIGHT
    it fell under the range, or ran more than a point over the RPE   -> HEAVY
    otherwise                                                        -> RIGHT

Each verdict is stored (decision_outcomes) against the programme's number
and the coach's, so an override is judged against what it departed from.
The verdicts go three places: back to the coach in its context (OUTCOMES),
to the Sunday report, and into the programme's next number (two lights in
a row size the next step up). What the coach and the programme each got
right is then a count, not an impression.
"""
from __future__ import annotations

import logging
import threading
from collections import Counter, defaultdict
from datetime import timedelta

from data import get_supabase, now_local

log = logging.getLogger(__name__)

RIGHT, LIGHT, HEAVY, UNKNOWN = "right", "light", "heavy", "unknown"
_RPE_SLACK_LIGHT = 0.5   # at or under the target, with half a point of reporting slack
_RPE_SLACK_HEAVY = 1.0   # more than a point over the target is a miss


def _fold(name: str) -> str:
    return "".join(ch for ch in (name or "").lower() if ch.isalnum())


def _f(value):
    try:
        return None if value in (None, "") else float(value)
    except (TypeError, ValueError):
        return None


def verdict(reps, rpe, reps_low, reps_high, rpe_target) -> str:
    """One set against the range and RPE it was prescribed."""
    reps, rpe, lo, hi, target = _f(reps), _f(rpe), _f(reps_low), _f(reps_high), _f(rpe_target)
    if reps is None or lo is None or hi is None:
        return UNKNOWN
    if reps > hi and (rpe is None or target is None or rpe <= target + _RPE_SLACK_LIGHT):
        return LIGHT
    if reps < lo or (rpe is not None and target is not None and rpe > target + _RPE_SLACK_HEAVY):
        return HEAVY
    return RIGHT


# ── scoring a session ────────────────────────────────────────────────────────

def _card_rows(supabase, session_id: str) -> dict[str, dict]:
    """The last row that set each lift's card in the session, with the
    programme's number from the opening row (accept/adjust) kept beside it."""
    rows = (supabase.table("prescription_decisions").select("*").eq("session_id", session_id)
            .order("created_at").execute()).data or []
    out: dict[str, dict] = {}
    for r in rows:
        name = r.get("exercise") or ""
        if not name or name.startswith("Weak-point") or r.get("decision") not in ("accept", "adjust", "update"):
            continue
        key = _fold(name)
        prev = out.get(key)
        merged = dict(r)
        if prev:
            for col in ("programme_load_kg", "programme_reps_low", "programme_reps_high", "programme_rpe"):
                if merged.get(col) is None:
                    merged[col] = prev.get(col)
            if prev.get("decision") == "adjust" and merged.get("decision") == "update":
                merged["_opening_decision"] = "adjust"
        out[key] = merged
    return out


def _top_sets(supabase, session_id: str) -> dict[str, dict]:
    rows = (supabase.table("workout_sets")
            .select("exercise, is_warmup, actual_weight_kg, actual_reps, actual_rpe, set_number, phase")
            .eq("workout_session_id", session_id).execute()).data or []
    tops: dict[str, dict] = {}
    for r in rows:
        if r.get("is_warmup") or r.get("actual_weight_kg") is None or r.get("actual_reps") is None:
            continue
        key = _fold(r.get("exercise") or "")
        # The top set: the working-phase set when the phase is known, else the heaviest.
        cur = tops.get(key)
        phase_top = (r.get("phase") or "") == "working"
        if cur is None or (phase_top and (cur.get("phase") or "") != "working") or (
                (cur.get("phase") or "") != "working" and _f(r["actual_weight_kg"]) > _f(cur["actual_weight_kg"])):
            tops[key] = r
    return tops


def score_session(session_id: str) -> list[dict]:
    """Score every lift of a finished session and store the verdicts.
    Returns the rows written; never raises past a log line."""
    supabase = get_supabase()
    if not supabase or not session_id:
        return []
    try:
        session = (supabase.table("workout_sessions").select("id, date, type, mesocycle_week, status")
                   .eq("id", session_id).limit(1).execute()).data or []
        if not session:
            return []
        session = session[0]
        cards = _card_rows(supabase, session_id)
        tops = _top_sets(supabase, session_id)
    except Exception:
        log.exception("scorecard: could not read session %s", session_id)
        return []
    written = []
    for key, card in cards.items():
        top = tops.get(key)
        plan = card.get("plan")
        if isinstance(plan, str):
            import json
            try:
                plan = json.loads(plan)
            except ValueError:
                plan = {}
        working = ((plan or {}).get("working") or [{}])[0] if isinstance(plan, dict) else {}
        lo, hi, target = working.get("reps_low", card.get("top_reps")), working.get("reps_high", card.get("top_reps")), working.get("rpe", card.get("top_rpe"))
        coach_load = _f(card.get("top_load_kg"))
        prog_load = _f(card.get("programme_load_kg"))
        v = verdict(top and top.get("actual_reps"), top and top.get("actual_rpe"), lo, hi, target) if top else UNKNOWN
        decision = card.get("_opening_decision") or card.get("decision")
        row = {
            "session_id": session_id, "date": session.get("date"), "session_type": session.get("type"),
            "mesocycle_week": session.get("mesocycle_week"), "exercise": card.get("exercise"),
            "decision": decision,
            "overrode": bool(decision == "adjust" or (prog_load is not None and coach_load is not None and abs(prog_load - coach_load) > 1e-6)),
            "programme_load_kg": prog_load, "coach_load_kg": coach_load,
            "reps_low": _f(lo) and int(_f(lo)), "reps_high": _f(hi) and int(_f(hi)), "rpe_target": _f(target),
            "lifted_load_kg": _f(top.get("actual_weight_kg")) if top else None,
            "lifted_reps": int(_f(top.get("actual_reps"))) if top and _f(top.get("actual_reps")) is not None else None,
            "lifted_rpe": _f(top.get("actual_rpe")) if top else None,
            "verdict": v, "reason": (card.get("reason") or "")[:300],
            "scored_at": now_local().isoformat(),
        }
        try:
            supabase.table("decision_outcomes").upsert(row, on_conflict="session_id,exercise").execute()
            written.append(row)
        except Exception:
            log.warning("scorecard: could not store %s / %s (migration 015?)", session_id, card.get("exercise"))
    if written:
        log.info("SCORECARD %s %s: %s", session.get("date"), session.get("type"),
                 ", ".join(f"{r['exercise']}={r['verdict']}" for r in written))
    return written


_scored_on: dict = {"date": None}


def score_pending(days: int = 14) -> int:
    """Score finished sessions in the window that have no verdicts yet. Cheap
    once a day per process; a session is scored again only when it has no
    rows (a store without migration 015 stays quiet)."""
    supabase = get_supabase()
    if not supabase:
        return 0
    today = now_local().strftime("%Y-%m-%d")
    if _scored_on["date"] == today:
        return 0
    _scored_on["date"] = today
    since = (now_local() - timedelta(days=days)).strftime("%Y-%m-%d")
    try:
        sessions = (supabase.table("workout_sessions").select("id, date, status, end_time, tonnage_kg")
                    .gte("date", since).execute()).data or []
        done = {r["session_id"] for r in ((supabase.table("decision_outcomes").select("session_id")
                                            .gte("date", since).execute()).data or [])}
    except Exception:
        log.warning("scorecard: could not list sessions to score (migration 015?)")
        return 0
    n = 0
    for s in sessions:
        if s.get("id") in done or not s.get("end_time") or not (s.get("tonnage_kg") or 0):
            continue
        n += len(score_session(s["id"]))
    return n


def score_in_background(days: int = 14) -> None:
    """Score what is pending on a daemon thread, so no request waits on it."""
    def run():
        try:
            n = score_pending(days)
            if n:
                log.info("scorecard: %d lifts scored in the background", n)
        except Exception:
            log.exception("scorecard: background scoring failed")
    threading.Thread(target=run, name="scorecard", daemon=True).start()


# ── reading the verdicts ─────────────────────────────────────────────────────

def recent_outcomes(days: int = 42) -> list[dict]:
    supabase = get_supabase()
    if not supabase:
        return []
    since = (now_local() - timedelta(days=days)).strftime("%Y-%m-%d")
    try:
        return (supabase.table("decision_outcomes").select("*").gte("date", since)
                .order("date", desc=True).execute()).data or []
    except Exception:
        return []


def verdicts_by_lift(rows: list[dict], n: int = 3) -> dict[str, list[dict]]:
    """Newest first, the last n verdicts per lift (fold -> rows), unknowns left out."""
    out: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        if r.get("verdict") in (RIGHT, LIGHT, HEAVY):
            k = _fold(r.get("exercise") or "")
            if len(out[k]) < n:
                out[k].append(r)
    return dict(out)


def ran_light_twice(verdicts: dict[str, list[dict]] | None, exercise: str) -> bool:
    """The programme's own number came in light in the last two scored
    sessions of this lift (its number, not an override's)."""
    rows = (verdicts or {}).get(_fold(exercise)) or []
    own = [r for r in rows if not r.get("overrode")][:2]
    return len(own) == 2 and all(r.get("verdict") == LIGHT for r in own)


def last_two_missed(verdicts: dict[str, list[dict]] | None, exercise: str) -> str | None:
    """'light' or 'heavy' when the last two verdicts of this lift agree on a
    miss, whoever's number it was; else None."""
    rows = ((verdicts or {}).get(_fold(exercise)) or [])[:2]
    if len(rows) == 2 and rows[0].get("verdict") == rows[1].get("verdict") and rows[0]["verdict"] in (LIGHT, HEAVY):
        return rows[0]["verdict"]
    return None


def track_record(rows: list[dict]) -> dict:
    coach = Counter(r["verdict"] for r in rows if r.get("overrode") and r.get("verdict") != UNKNOWN)
    programme = Counter(r["verdict"] for r in rows if not r.get("overrode") and r.get("verdict") != UNKNOWN)
    return {"coach": dict(coach), "programme": dict(programme)}


# ── parity: the programme against the coach, lift by lift ───────────────────
# The athlete's aim (26 Sep 2026): the programme's numbers reach the coach's,
# and the coach becomes the guard. Parity is measured, not felt: on every
# lift the two agreed on, the verdict is the programme's; on every override,
# the verdict is the coach's, and the programme's number is judged by
# direction — a LIGHT card with the programme higher means the programme
# was closer, a HEAVY card with the programme lower likewise. The athlete
# lifted the coach's number, so the programme's own verdict on an override
# is never known; direction is the honest limit.
COACH_RIGHT, PROGRAMME_CLOSER, BOTH_WRONG, UNJUDGED = "coach right", "programme closer", "both wrong", "unjudged"


def judge_override(row: dict) -> str:
    """Who was nearer the truth on an overridden lift."""
    v = row.get("verdict")
    prog, coach = row.get("programme_load_kg"), row.get("coach_load_kg")
    if v == RIGHT:
        return COACH_RIGHT
    if v not in (LIGHT, HEAVY) or prog is None or coach is None or abs(prog - coach) < 1e-6:
        return UNJUDGED
    if v == LIGHT:
        return PROGRAMME_CLOSER if prog > coach else BOTH_WRONG
    return PROGRAMME_CLOSER if prog < coach else BOTH_WRONG


def head_to_head(rows: list[dict]) -> dict:
    """{agreed, agreed_right, overrides, judged: Counter, rows: [override rows newest first]}."""
    scored = [r for r in rows if r.get("verdict") in (RIGHT, LIGHT, HEAVY)]
    agreed = [r for r in scored if not r.get("overrode")]
    overrides = [r for r in scored if r.get("overrode")]
    judged = Counter(judge_override(r) for r in overrides)
    return {"scored": len(scored), "agreed": len(agreed),
            "agreed_right": sum(1 for r in agreed if r["verdict"] == RIGHT),
            "overrides": len(overrides), "judged": dict(judged),
            "rows": sorted(overrides, key=lambda r: r.get("date") or "", reverse=True)}


def format_head_to_head(rows: list[dict], days: int, limit: int = 20) -> str:
    """The Sunday report's parity section: how often the two agreed, how the
    programme's number did when they agreed, and who was nearer when they
    did not — then the overrides themselves, one line each."""
    h = head_to_head(rows)
    lines = ["", "## Programme vs coach — parity", ""]
    if not h["scored"]:
        lines.append("Nothing scored in the window.")
        return "\n".join(lines)
    agree_pct = h["agreed"] / h["scored"] * 100
    lines.append(f"{h['scored']} lifts scored over {days} days. Agreed on {h['agreed']} ({agree_pct:.0f}%); "
                 f"of those the programme's number was right {h['agreed_right']} times "
                 f"({(h['agreed_right'] / h['agreed'] * 100) if h['agreed'] else 0:.0f}%).")
    j = h["judged"]
    if h["overrides"]:
        lines.append(f"The coach overrode {h['overrides']}: coach right {j.get(COACH_RIGHT, 0)} · programme would have been "
                     f"closer {j.get(PROGRAMME_CLOSER, 0)} · both wrong {j.get(BOTH_WRONG, 0)} · unjudged {j.get(UNJUDGED, 0)}.")
        cr, pc = j.get(COACH_RIGHT, 0), j.get(PROGRAMME_CLOSER, 0)
        if cr + pc:
            if pc >= cr:
                lines.append("Parity: on the lifts where they disagreed, the programme's number was at least as good as "
                             "the coach's. The coach's room to override can shrink.")
            else:
                lines.append(f"Not at parity: the coach was right on {cr} of the {cr + pc} judged overrides. "
                             f"Each 'coach right' names a rule the programme lacks — read the reasons below.")
        lines += ["", "| date | lift | programme | coach | lifted | verdict | judged | coach's reason |", "|---|---|---|---|---|---|---|---|"]
        for r in h["rows"][:limit]:
            lifted = f"{r['lifted_load_kg']:g}x{r['lifted_reps']}" if r.get("lifted_load_kg") and r.get("lifted_reps") is not None else "?"
            prog = f"{r['programme_load_kg']:g}" if r.get("programme_load_kg") is not None else "—"
            coach = f"{r['coach_load_kg']:g}" if r.get("coach_load_kg") is not None else "—"
            reason = " ".join((r.get("reason") or "").split())[:70]
            lines.append(f"| {r.get('date')} | {r.get('exercise')} | {prog} | {coach} | {lifted} | {r['verdict']} | {judge_override(r)} | {reason} |")
    else:
        lines.append("No overrides in the window: every card was the programme's number.")
    lines += ["", "Reading it: the aim is a programme whose numbers need no override. Agreement rising and "
              "'programme closer' at or above 'coach right' is the measure; when it holds for a block, the coach "
              "keeps the guard duties (recovery, a niggle, a substitution) and loses the number."]
    return "\n".join(lines)


def _counts(c: dict) -> str:
    n = sum(c.values())
    if not n:
        return "none scored yet"
    return f"{c.get(RIGHT, 0)} right · {c.get(LIGHT, 0)} light · {c.get(HEAVY, 0)} heavy (n={n})"


def format_outcomes(today_exercises: list[str], verdicts: dict[str, list[dict]], record: dict) -> str:
    """The block the coach reads: what the last numbers did on today's lifts,
    and the standing of its own judgement against the programme's."""
    lines = ["\nOUTCOMES — what the last numbers on today's lifts did (right = inside the range at the "
             "target RPE; light = beat the top of the range at or under it; heavy = under the range or more "
             "than a point over). Two lights in a row on the programme's number means the range is telling "
             "you the load is under — adjust up, or say why not. Two heavies mean the opposite."]
    shown = 0
    for name in today_exercises:
        rows = verdicts.get(_fold(name)) or []
        if not rows:
            continue
        parts = []
        for r in rows:
            who = "coach" if r.get("overrode") else "programme"
            lifted = f"{r['lifted_load_kg']:g}x{r['lifted_reps']}" + (f"@{r['lifted_rpe']:g}" if r.get("lifted_rpe") is not None else "") if r.get("lifted_load_kg") else "?"
            parts.append(f"{r.get('date')} {r['verdict']} ({who}'s {r.get('coach_load_kg') or 0:g}kg → {lifted})")
        miss = last_two_missed(verdicts, name)
        flag = f" ← {miss.upper()} twice running" if miss else ""
        lines.append(f"- {name}: " + "; ".join(parts) + flag)
        shown += 1
    if not shown:
        lines.append("- nothing scored yet for today's lifts.")
    lines.append(f"Track record, last six weeks — your overrides: {_counts(record.get('coach') or {})}; "
                 f"the programme's numbers you accepted: {_counts(record.get('programme') or {})}.")
    return "\n".join(lines) + "\n"


def format_report(rows: list[dict], days: int) -> str:
    """The Sunday report's section."""
    lines = ["", "## Outcomes — were the numbers right?", ""]
    scored = [r for r in rows if r.get("verdict") != UNKNOWN]
    if not scored:
        lines.append("Nothing scored in the window (migration 015 run? sessions finished?).")
        return "\n".join(lines)
    rec = track_record(scored)
    lines.append(f"{len(scored)} lifts scored over {days} days. The programme's numbers (accepted): "
                 f"{_counts(rec['programme'])}. The coach's overrides: {_counts(rec['coach'])}.")
    by = defaultdict(list)
    for r in sorted(scored, key=lambda r: r.get("date") or ""):
        by[r.get("exercise")].append(r["verdict"])
    trending = [(ex, v) for ex, v in by.items() if len(v) >= 2 and v[-1] == v[-2] and v[-1] != RIGHT]
    if trending:
        lines += ["", "Two of the same in a row:"]
        for ex, v in sorted(trending):
            lines.append(f"- {ex}: {' → '.join(v[-3:])}")
    lines += ["", "Reading it: light means the range said the load was under and nobody moved it; heavy means "
              "the opposite. A coach that adjusts and comes out right more often than the programme's number "
              "has earned more room; one that does not has not."]
    lines.append(format_head_to_head(rows, days))
    return "\n".join(lines)
