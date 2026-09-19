"""The block review as a coach conversation (roadmap 2.5).

At the end of each block the coach writes the review and proposes two or
three changes; the athlete replies "yes to 1 and 3"; those become recorded
decisions through the same paths a chat decision uses today. What keeps it
honest: every number comes from code — the fact sheet below — and the model
only phrases and proposes; a narrative that cites a number not in the sheet
is rejected; nothing is recorded without the athlete's yes; and the first
block is a dry run, shown but not recordable.

When and where, not after a workout: the review is prepared the first
morning after the block has rolled over (the briefing route calls
`prepare_if_due`), so it lands on a rest morning as the coach's note, never
inside or straight after a session. It stays until answered. If the new
block's first session arrives first, week 1 opens on the programme's
defaults and the review stays available.
"""

from __future__ import annotations

import json
import logging
import math
import re
import time
from datetime import date, timedelta

from data import get_supabase, now_local

log = logging.getLogger(__name__)

DRY_RUN = True            # the first block: written and shown, nothing recordable
MAX_PROPOSALS = 3
E1RM_MAX_REPS = 12
PEAK_WEEK = 3

REVIEW_SCHEMA = {
    "type": "object",
    "properties": {
        "narrative": {"type": "string"},
        "proposals": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "line": {"type": "string"},
                    "rationale": {"type": "string"},
                },
                "required": ["line", "rationale"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["narrative", "proposals"],
    "additionalProperties": False,
}

REVIEW_INSTRUCTION = """
You are writing the athlete's BLOCK REVIEW from the fact sheet below and nothing else.
Rules:
- Every number you write must appear in the fact sheet, exactly. Do not compute new ones.
- Four short paragraphs at most: strength (peak week against peak week), volume against
  the bands, recovery over the block, and what to change. Plain, specific, his numbers.
- Propose at most {max_proposals} changes. Each `line` MUST be in one of these exact grammars,
  which the system records verbatim when he approves it:
    Decision: <Exercise> | max load <N>kg | <one-line reason>
    Decision: <Exercise> | clear
    Emphasis-next: <muscle> | <one-line note>
  Propose nothing you cannot justify from the sheet. Zero proposals is a valid answer.
- `rationale` says which fact the proposal rests on.
""".strip()


# ── Window ───────────────────────────────────────────────────────────────────

def review_window(sessions: list[dict], memory: dict, today: str) -> dict | None:
    """The block under review and the one before it, as date ranges.

    Reviews run the morning after a block ends, when memory already points
    at week 1 day 1 of the new block — so the block under review is the one
    that has just ended: its last sixteen sessions, or from its stamped
    opening session, through today. Called mid-block (an explicit "block
    review" in chat), the block in progress is reviewed so far."""
    from weakpoints import block_start, ended_block_range, previous_block_range
    week = int(memory.get("mesocycle_week", 1) or 1)
    day = int(memory.get("mesocycle_day", 1) or 1)
    rolled_over = week == 1 and day == 1
    if rolled_over:
        # Never block_start here: with no stamped opening session in reach it
        # answers "today", and the review of 19 Sep 2026 read a whole block
        # as one day's sets (every muscle at 0.0 sets/week, 1 of 1 nights).
        ended = ended_block_range(sessions, today)
        if ended is None:
            return None
        start = ended[0]
    else:
        start = block_start(sessions, week, day, today)
        if start is None:
            return None
    since, until = start, today
    before = previous_block_range(sessions, start)
    return {"block_start": since, "since": since, "until": until,
            "prev_since": before[0] if before else None, "prev_until": before[1] if before else None,
            "complete": rolled_over}


# ── Facts ────────────────────────────────────────────────────────────────────

def epley(load: float, reps: int) -> float:
    return load * (1 + reps / 30.0)


def strength_facts(rows: list[dict], weeks: dict, window: dict) -> list[dict]:
    """Per lift: this block's peak-week best against the previous block's,
    both as Epley estimates from sets of 12 reps or fewer. A lift with no
    peak-week set uses its block best and says so."""
    def best(rs):
        pts = [(epley(float(r["actual_weight_kg"]), int(r["actual_reps"])), r) for r in rs
               if not r.get("is_warmup") and r.get("actual_weight_kg") and r.get("actual_reps")
               and 0 < int(r["actual_reps"]) <= E1RM_MAX_REPS and float(r["actual_weight_kg"]) > 0]
        return max(pts, key=lambda p: p[0]) if pts else None

    def in_range(r, since, until):
        return since is not None and until is not None and since <= (r.get("date") or "") <= until

    def week_of(r):
        return weeks.get(str(r.get("workout_session_id")))

    by_ex: dict[str, list[dict]] = {}
    for r in rows:
        by_ex.setdefault((r.get("exercise") or "").strip(), []).append(r)
    out = []
    for name, rs in sorted(by_ex.items()):
        this_rows = [r for r in rs if in_range(r, window["since"], window["until"])]
        prev_rows = [r for r in rs if in_range(r, window.get("prev_since"), window.get("prev_until"))]
        if not this_rows:
            continue
        this_peak = [r for r in this_rows if week_of(r) == PEAK_WEEK]
        prev_peak = [r for r in prev_rows if week_of(r) == PEAK_WEEK]
        peak_best = best(this_peak)
        this_best = peak_best or best(this_rows)
        prev_best = best(prev_peak) or best(prev_rows)
        if not this_best:
            continue
        fact = {"exercise": name, "this_e1rm": round(this_best[0], 1),
                "this_set": f"{float(this_best[1]['actual_weight_kg']):g}kg x{int(this_best[1]['actual_reps'])}",
                "this_from_peak_week": peak_best is not None}
        if prev_best:
            delta = (this_best[0] - prev_best[0]) / prev_best[0] * 100
            fact.update({"prev_e1rm": round(prev_best[0], 1),
                         "prev_set": f"{float(prev_best[1]['actual_weight_kg']):g}kg x{int(prev_best[1]['actual_reps'])}",
                         "delta_pct": round(delta, 1),
                         "verdict": "up" if delta >= 1 else ("down" if delta <= -5 else "held")})
        else:
            fact["verdict"] = "first block"
        out.append(fact)
    return out


def recovery_facts(rows: list[dict], window: dict) -> dict:
    """Block means against the 42 days before the block, from the daily rows."""
    def vals(key, since, until):
        return [float(r[key]) for r in rows if r.get(key) is not None
                and since <= (r.get("date") or "") <= until]
    since, until = window["since"], window["until"]
    base_until = (date.fromisoformat(since) - timedelta(days=1)).isoformat()
    base_since = (date.fromisoformat(since) - timedelta(days=42)).isoformat()
    out: dict = {"since": since, "until": until}
    for key, label in (("hrv", "hrv"), ("resting_hr", "rhr"), ("sleep_hours", "sleep")):
        block = vals(key, since, until)
        base = vals(key, base_since, base_until)
        if block:
            out[f"{label}_block_mean"] = round(sum(block) / len(block), 1)
        if base:
            out[f"{label}_baseline_mean"] = round(sum(base) / len(base), 1)
    sleep = vals("sleep_hours", since, until)
    out["short_nights"] = sum(1 for s in sleep if 2.0 <= s < 7.0)
    out["nights_recorded"] = sum(1 for s in sleep if s >= 2.0)
    taps = [int(r["readiness"]) for r in rows if r.get("readiness") is not None
            and since <= (r.get("date") or "") <= until]
    if taps:
        out["readiness_taps"] = len(taps)
        out["readiness_mean"] = round(sum(taps) / len(taps), 1)
    return out


def build_fact_sheet(memory: dict, prompt: str) -> dict | None:
    """Everything the review may say, computed. None when the block cannot be placed."""
    from constraints import format_constraints
    from coach_context import _recovery_rows, _standing_constraints
    from plan import load_recent_decisions
    from progression import _fetch_session_weeks
    from weakpoints import (current_block_weak_points, parse_volume_bands, rank_by_shortfall,
                            rotation_sessions, volume_between)

    supabase = get_supabase()
    if not supabase:
        return None
    today = now_local().strftime("%Y-%m-%d")
    sessions = rotation_sessions(supabase)
    window = review_window(sessions, memory, today)
    if window is None:
        return None

    since = window.get("prev_since") or window["since"]
    rows = (supabase.table("workout_sets")
            .select("date, exercise, workout_session_id, is_warmup, actual_weight_kg, actual_reps, actual_rpe")
            .gte("date", since).lte("date", window["until"]).order("date").execute()).data or []
    weeks = _fetch_session_weeks(120)
    strength = strength_facts(rows, weeks, window)

    bands = parse_volume_bands(prompt)
    volume = volume_between(supabase, window["since"], window["until"])
    ranking = rank_by_shortfall(volume, bands) if bands else []

    recovery = recovery_facts(_recovery_rows(120), window)
    emphasis = current_block_weak_points(memory, prompt) or {}
    decisions = [d for d in load_recent_decisions(days=60)
                 if window["since"] <= (d.get("date") or "") <= window["until"]]
    return {
        "window": window,
        "strength": strength,
        "volume": [{"muscle": r["muscle"], "sets_per_week": r["sets"], "band": f"{r['low']}-{r['high']}",
                    "under_by": r["shortfall"] if r["shortfall"] > 0 else 0} for r in ranking],
        "recovery": recovery,
        "emphasis": [p.get("muscle") for p in (emphasis.get("picks") or [])],
        "standing_constraints": format_constraints(_standing_constraints()).strip(),
        "adjustments": [{"date": d.get("date"), "exercise": d.get("exercise"), "reason": d.get("reason")}
                        for d in decisions][:12],
    }


def format_facts(facts: dict) -> str:
    """The sheet as the model reads it."""
    w = facts["window"]
    lines = [f"BLOCK UNDER REVIEW: {w['since']} to {w['until']}"
             + ("" if w.get("complete") else " (in progress)")
             + (f"; previous block {w['prev_since']} to {w['prev_until']}" if w.get("prev_since") else "; no previous block"),
             "", "STRENGTH — peak week against peak week, Epley e1RM from sets of 12 reps or fewer:"]
    if not facts["strength"]:
        lines.append("  no loaded lifts in the block")
    for s in facts["strength"]:
        if "delta_pct" in s:
            lines.append(f"  {s['exercise']}: {s['this_e1rm']}kg ({s['this_set']}) vs {s['prev_e1rm']}kg "
                         f"({s['prev_set']}) = {s['delta_pct']:+g}% — {s['verdict']}"
                         + ("" if s["this_from_peak_week"] else " [block best, no peak-week set]"))
        else:
            lines.append(f"  {s['exercise']}: {s['this_e1rm']}kg ({s['this_set']}) — first block")
    lines += ["", "VOLUME — sets per calendar week against the band, over the block:"]
    for v in facts["volume"]:
        lines.append(f"  {v['muscle']}: {v['sets_per_week']} against {v['band']}"
                     + (f" — UNDER by {v['under_by']}" if v["under_by"] else ""))
    r = facts["recovery"]
    lines += ["", "RECOVERY — block mean against the 42 days before it:"]
    for label, name in (("hrv", "HRV"), ("rhr", "resting HR"), ("sleep", "sleep h")):
        if f"{label}_block_mean" in r:
            lines.append(f"  {name}: {r[f'{label}_block_mean']}"
                         + (f" vs baseline {r[f'{label}_baseline_mean']}" if f"{label}_baseline_mean" in r else ""))
    lines.append(f"  short nights (<7h): {r.get('short_nights', 0)} of {r.get('nights_recorded', 0)} recorded")
    if "readiness_taps" in r:
        lines.append(f"  readiness taps: {r['readiness_taps']}, mean {r['readiness_mean']} of 5")
    lines += ["", "THIS BLOCK'S EMPHASIS: " + (", ".join(facts["emphasis"]) or "none")]
    if facts["standing_constraints"]:
        lines += ["", "STANDING DECISIONS IN FORCE:", facts["standing_constraints"]]
    if facts["adjustments"]:
        lines += ["", "DEPARTURES FROM THE PROGRAMME THIS BLOCK (coach's reasons):"]
        for a in facts["adjustments"]:
            lines.append(f"  {a['date']} {a['exercise']}: {a['reason']}")
    return "\n".join(lines)


# ── Narrative ────────────────────────────────────────────────────────────────

# Numbers glued to their unit ("310kg", "+15%") count too, on both sides.
_NUM_RE = re.compile(r"(?<![\w.])-?\d+(?:\.\d+)?(?!\.?\d)")
_LINE_RE = re.compile(r"^(Decision: [^|]+\| (?:max load \d+(?:\.\d+)?kg \| .+|clear)|Emphasis-next: [A-Za-z ]+\| .+)$")


def numbers_not_in_sheet(narrative: str, sheet: str) -> list[str]:
    """Every number the narrative cites that the sheet does not carry. Small
    integers (1-4) are allowed: 'two exercises', 'week 3'."""
    have = set(_NUM_RE.findall(sheet))
    bad = []
    for n in _NUM_RE.findall(narrative):
        if n in have:
            continue
        try:
            if 0 <= float(n) <= 4 and float(n).is_integer():
                continue
        except ValueError:
            pass
        bad.append(n)
    return sorted(set(bad))


def valid_proposals(proposals: list[dict]) -> list[dict]:
    """Only lines in the recordable grammar survive, at most MAX_PROPOSALS."""
    out = []
    for p in proposals or []:
        line = (p.get("line") or "").strip()
        if _LINE_RE.match(line):
            out.append({"line": line, "rationale": (p.get("rationale") or "").strip()})
    return out[:MAX_PROPOSALS]


def narrate(client, sheet: str, model: str | None = None) -> dict:
    """One model call: the review from the sheet, checked. A narrative that
    cites a number the sheet lacks is retried once with the offending numbers
    named; a second failure returns the sheet itself as the narrative."""
    from plan import MODEL
    from usage import record_call
    instruction = REVIEW_INSTRUCTION.format(max_proposals=MAX_PROPOSALS)
    messages = [{"role": "user", "content": f"{instruction}\n\nFACT SHEET\n{sheet}"}]
    last = None
    for attempt in (1, 2):
        started = time.monotonic()
        response = client.messages.create(
            model=model or MODEL, max_tokens=3000, thinking={"type": "adaptive"},
            output_config={"format": {"type": "json_schema", "schema": REVIEW_SCHEMA}, "effort": "medium"},
            messages=messages)
        text = next((b.text for b in response.content if getattr(b, "type", "") == "text"), "")
        record_call("block_review", time.monotonic() - started, response, attempt=attempt, ok=bool(text),
                    note="review", model=model or MODEL)
        try:
            data = json.loads(text)
        except ValueError:
            data = {}
        narrative = (data.get("narrative") or "").strip()
        bad = numbers_not_in_sheet(narrative, sheet)
        proposals = valid_proposals(data.get("proposals") or [])
        last = {"narrative": narrative, "proposals": proposals, "unsupported_numbers": bad}
        if narrative and not bad:
            return last
        messages.append({"role": "assistant", "content": text or "{}"})
        messages.append({"role": "user", "content": "These numbers are not in the fact sheet: "
                         + ", ".join(bad or ["(empty narrative)"]) + ". Rewrite using only the sheet's numbers."})
    return {"narrative": sheet, "proposals": (last or {}).get("proposals", []),
            "unsupported_numbers": (last or {}).get("unsupported_numbers", []), "fell_back_to_sheet": True}


# ── Store, show, answer ──────────────────────────────────────────────────────

def prepare_block_review(memory: dict, prompt: str, client, dry_run: bool = DRY_RUN) -> dict | None:
    facts = build_fact_sheet(memory, prompt)
    if facts is None:
        return None
    sheet = format_facts(facts)
    written = narrate(client, sheet)
    row = {"block_start": facts["window"]["block_start"], "window_since": facts["window"]["since"],
           "window_until": facts["window"]["until"], "facts": json.dumps(facts),
           "narrative": written["narrative"], "proposals": json.dumps(written["proposals"]),
           "status": "shown", "dry_run": dry_run}
    supabase = get_supabase()
    try:
        saved = supabase.table("block_reviews").insert(row).execute().data or []
        row["id"] = (saved[0] if saved else {}).get("id")
    except Exception:
        log.exception("Could not store the block review; showing it unsaved")
    row["proposals_list"] = written["proposals"]
    return row


def latest_block_review() -> dict | None:
    supabase = get_supabase()
    if not supabase:
        return None
    try:
        rows = (supabase.table("block_reviews").select("*").order("id", desc=True).limit(1).execute()).data or []
    except Exception:
        log.warning("block_reviews could not be read (migration 007?)")
        return None
    if not rows:
        return None
    row = rows[0]
    props = row.get("proposals") or []
    if isinstance(props, str):
        try:
            props = json.loads(props)
        except ValueError:
            props = []
    row["proposals_list"] = props
    return row


def prepare_if_due(memory: dict, prompt: str, client) -> dict | None:
    """The morning after a block rolls over: prepare the review once. Nothing
    on any other morning, nothing inside a session."""
    week = int(memory.get("mesocycle_week", 1) or 1)
    day = int(memory.get("mesocycle_day", 1) or 1)
    if not (week == 1 and day == 1):
        return None
    from workout import get_workout_state
    if (get_workout_state() or {}).get("workout_mode") == "active":
        return None
    latest = latest_block_review()
    from weakpoints import rotation_sessions
    supabase = get_supabase()
    today = now_local().strftime("%Y-%m-%d")
    window = review_window(rotation_sessions(supabase), memory, today) if supabase else None
    start = window["block_start"] if window else None
    if latest and start and str(latest.get("block_start")) >= str(start):
        return None   # already reviewed at or after this boundary
    return prepare_block_review(memory, prompt, client)


def render_review(row: dict) -> str:
    """What the athlete reads: the narrative, the numbered proposals, and how
    to answer."""
    parts = [row.get("narrative", "").strip()]
    props = row.get("proposals_list") or []
    if props:
        lines = ["Proposed for next block — reply \"yes to 1 and 3\", \"approve all\" or \"no\":"]
        for i, p in enumerate(props, 1):
            lines.append(f"{i}. {p['line']}" + (f"\n   — {p['rationale']}" if p.get("rationale") else ""))
        parts.append("\n".join(lines))
    else:
        parts.append("No changes proposed for next block.")
    if row.get("dry_run"):
        parts.append("(Dry run: this first review records nothing whatever you answer; your answer is kept "
                     "so we can compare it with what you would have decided.)")
    return "\n\n".join(parts)


# ── Structure for the Home card ─────────────────────────────────────────────
# The narrative is prose in labelled paragraphs ("Strength: …", "Volume: …");
# the card shows each under its label instead of as one block of text.
_SECTION_RE = re.compile(r"^(?P<label>[A-Z][A-Za-z ]{1,30}):\s+(?P<body>.+)$", re.DOTALL)


def review_sections(narrative: str) -> list[dict]:
    """Paragraphs of the narrative as {label, body}; a paragraph with no
    leading label keeps an empty one."""
    out = []
    for para in re.split(r"\n\s*\n", (narrative or "").strip()):
        para = para.strip()
        if not para:
            continue
        m = _SECTION_RE.match(para)
        if m:
            out.append({"label": m.group("label").strip().upper(), "body": m.group("body").strip()})
        else:
            out.append({"label": "", "body": para})
    return out


def proposal_parts(line: str) -> dict:
    """A proposal line in the grammar split for display: kind ("decision" or
    "emphasis"), subject (the lift or muscle) and detail (the rest, parts
    joined with a middle dot)."""
    head, _, rest = (line or "").partition(":")
    head = head.strip().lower()
    kind = "emphasis" if head.startswith("emphasis") else ("decision" if head == "decision" else head)
    parts = [p.strip() for p in rest.split("|")]
    subject = parts[0] if parts else rest.strip()
    detail = " · ".join(p for p in parts[1:] if p)
    return {"kind": kind, "subject": subject, "detail": detail}


_ANSWER_RE = re.compile(r"^\s*(?P<verb>yes|approve|ok|okay|no|decline|reject)\b(?P<rest>.*)$", re.IGNORECASE)


def parse_answer(text: str, count: int) -> list[int] | None:
    """"yes to 1 and 3" -> [1, 3]; "approve all" -> every index; "no" -> [];
    anything else -> None (not an answer)."""
    m = _ANSWER_RE.match(text or "")
    if not m:
        return None
    verb = m.group("verb").lower()
    rest = m.group("rest").lower()
    if verb in ("no", "decline", "reject"):
        return []
    if "all" in rest or (not re.search(r"\d", rest) and count == 1):
        return list(range(1, count + 1))
    nums = sorted({int(n) for n in re.findall(r"\d+", rest) if 1 <= int(n) <= count})
    return nums if nums else None


def answer_block_review(row: dict, text: str, prompt: str) -> str:
    """Record the answer; apply the approved lines unless this is a dry run."""
    props = row.get("proposals_list") or []
    chosen = parse_answer(text, len(props))
    if chosen is None:
        return ("I didn't catch that as an answer to the review. Say \"yes to 1 and 3\", "
                "\"approve all\" or \"no\".")
    approved = [props[i - 1]["line"] for i in chosen]
    applied: list[str] = []
    if approved and not row.get("dry_run"):
        from constraints import record_decisions
        from weakpoints import parse_emphasis_next, set_next_emphasis
        for line in approved:
            if line.startswith("Decision:"):
                record_decisions(line)
                applied.append(line)
            else:
                body = line.partition(":")[2].strip()
                parsed = parse_emphasis_next("emphasis next: " + body)
                if parsed:
                    set_next_emphasis(prompt, parsed["muscle"], parsed.get("note", ""))
                    applied.append(line)
    supabase = get_supabase()
    if supabase and row.get("id"):
        try:
            supabase.table("block_reviews").update({"status": "answered", "answer": text,
                                                     "approved": json.dumps(approved),
                                                     "answered_at": now_local().isoformat()})\
                .eq("id", row["id"]).execute()
        except Exception:
            log.exception("Could not store the review answer")
    if not approved:
        return "Noted — nothing changes for next block. The review stays in your history."
    if row.get("dry_run"):
        return ("Noted (dry run): you would have approved " + "; ".join(approved)
                + ". Nothing was recorded this block; from next block a yes records it.")
    return "Recorded for next block: " + "; ".join(applied) + "."
