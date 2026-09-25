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
import threading
import time
import math
import re
import time
from datetime import date, timedelta

from data import get_supabase, now_local

log = logging.getLogger(__name__)

# The first block's review (19 Sep 2026) was a dry run: written and shown,
# nothing recordable, the answer kept to compare. It matched on 2 of 3 and
# the third was reasoned in chat; live from 23 Sep on the athlete's word. A
# row stored with dry_run true stays a dry run whatever this says.
DRY_RUN = False
MAX_PROPOSALS = 3
E1RM_MAX_REPS = 12
# A set past 12 reps still counts when nothing tighter exists for the same
# stretch, up to this many reps, and is marked as a looser estimate. Mirrors
# StrengthViewModel.maxRepsForLooseE1RM: Seated Leg Curl 110 x 16 in a peak
# week read as a drop here while the app read it as a rise, because the
# review threw the set away and fell back to a lighter week-1 set.
E1RM_LOOSE_MAX_REPS = 20


def _peak_week_of(rows: list, week_of) -> int:
    """The block's peak week from its own stamped rows: the week before its
    last (the deload) once the block has run its deload, else its last week.
    Block lengths differ (4 weeks to 19 Sep 2026, 5 from 20 Sep), so a
    constant read the old block's deload as its peak."""
    weeks = {w for w in (week_of(r) for r in rows) if isinstance(w, int) and w > 0}
    if not weeks:
        from data import peak_week  # local: keeps import order flat
        return peak_week()
    m = max(weeks)
    return m - 1 if m >= 4 else m
# Bumped whenever the fact sheet's rules change; an unanswered review built
# on an older version is removed at the next start so Home prepares it again
# with numbers that match the app (data_fixes keys a fix on this number).
FACTS_VERSION = 4

# The narrative arrives as four named paragraphs, so the card can always show
# them under their labels; the model cannot leave a label out.
SECTIONS = (("strength", "Strength"), ("volume", "Volume"), ("recovery", "Recovery"), ("changes", "What to change"))

REVIEW_SCHEMA = {
    "type": "object",
    "properties": {
        "strength": {"type": "string"},
        "volume": {"type": "string"},
        "recovery": {"type": "string"},
        "changes": {"type": "string"},
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
    "required": ["strength", "volume", "recovery", "changes", "proposals"],
    "additionalProperties": False,
}

REVIEW_INSTRUCTION = """
You are writing the athlete's BLOCK REVIEW from the fact sheet below and nothing else.
Rules:
- Every number you write must appear in the fact sheet, exactly. Do not compute new ones.
- Four short paragraphs, one per field: `strength` (peak week against peak week), `volume`
  against the bands, `recovery` over the block, `changes` (what to change). Plain, specific,
  his numbers. The card beside your words lists EVERY lift's change and EVERY muscle's sets
  against its band as rows, so do not recite them: interpret. Name at most three lifts and
  three muscles, the ones that decide something. Two to four sentences per paragraph.
- Propose at most {max_proposals} changes. Each `line` MUST be in one of these exact grammars,
  which the system records verbatim when he approves it:
    Decision: <Exercise> | max load <N>kg | <one-line reason>
    Decision: <Exercise> | clear
    Emphasis-next: <muscle> | <one-line note>
  Propose nothing you cannot justify from the sheet. Zero proposals is a valid answer.
- `changes` opens by stating next block's emphasis exactly as the sheet gives it (set, with
  the movement, or not set), then one sentence per muscle on whether this block's numbers
  still support it. Do not propose changing it; the athlete changes it in chat.
- Every STANDING DECISION IN FORCE is put to the athlete on the card as keep-or-clear; the
  system adds that line itself, so do not write a `clear` line for it. In `changes`, say
  keep or clear for each one and why, from the sheet's numbers and its age.
- A lift the sheet marks "held (standing decision)" is flat because it was told to be. Say
  so; it is not a drop.
- In `volume`, credit a muscle's sets to weak-point work ONLY when WEAK-POINT WORK THAT RAN
  lists that muscle. Otherwise its sets came from its own days. The block's emphasis is
  exactly that list and nothing else: never name a muscle as picked, planned or intended
  for a weak-point slot unless it is on it.
- A lift marked "plus body" is scored as plate plus the athlete's share of bodyweight, as
  the app scores it; a "~" set is an estimate from a set past 12 reps.
- `Emphasis-next` NAMES A WEAK POINT for the coming block: extra straight sets on that
  muscle, the note being the movement to add. It is only for a muscle UNDER its band.
  A muscle OVER its band is never an Emphasis-next; say it in the volume paragraph and
  leave the programme to hold it. A muscle the sheet lists as already set for next
  block is not proposed again; say it is set. Emphasis-next is not a way to trim.
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
    from blocks import block_start, ended_block_range, previous_block_range
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
        start, last_session = ended
    else:
        start = block_start(sessions, week, day, today)
        if start is None:
            return None
        done = [s["date"] for s in sessions if start <= (s.get("date") or "") <= today]
        last_session = done[-1] if done else None
    since, until = start, today
    before = previous_block_range(sessions, start)
    return {"block_start": since, "since": since, "until": until, "last_session": last_session,
            "prev_since": before[0] if before else None, "prev_until": before[1] if before else None,
            "complete": rolled_over}


# ── Facts ────────────────────────────────────────────────────────────────────

def epley(load: float, reps: int) -> float:
    return load * (1 + reps / 30.0)


def weigh_ins(supabase, days: int = 200) -> list[tuple]:
    """(date, kg) ascending from the recovery table, so a bodyweight set is
    scored against the body that lifted it, as the app does."""
    try:
        since = (now_local().date() - timedelta(days=days)).isoformat()
        rows = (supabase.table("recovery").select("date, weight_kg").gte("date", since)
                .not_.is_("weight_kg", "null").order("date").execute()).data or []
    except Exception:
        log.warning("Block review: weigh-ins unavailable; bodyweight lifts scored on the plate alone", exc_info=True)
        return []
    return sorted((r["date"], float(r["weight_kg"])) for r in rows if r.get("date") and r.get("weight_kg"))


BULK_RATE_GUIDE_PCT = 0.5   # %/week; above it more of the gain is fat (inferred: lean-bulk guidance)


def bulk_rate(weigh: list[tuple], weeks: int = 6) -> dict | None:
    """The weight trend over the last `weeks` of weigh-ins: kg and % of
    bodyweight per week, by least squares over the dates (C16, 26 Sep 2026).
    None with fewer than four weigh-ins spanning at least two weeks."""
    from datetime import date as _date
    if not weigh:
        return None
    last_day = _date.fromisoformat(weigh[-1][0])
    since = (last_day - timedelta(weeks=weeks)).isoformat()
    pts = [(_date.fromisoformat(d), kg) for d, kg in weigh if d >= since]
    if len(pts) < 4 or (pts[-1][0] - pts[0][0]).days < 14:
        return None
    xs = [(d - pts[0][0]).days / 7.0 for d, _ in pts]
    ys = [kg for _, kg in pts]
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return None
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    return {"kg_per_week": slope, "pct_per_week": slope / my * 100, "weeks": (pts[-1][0] - pts[0][0]).days / 7.0,
            "first": (pts[0][0].isoformat(), pts[0][1]), "last": (pts[-1][0].isoformat(), pts[-1][1]), "n": len(pts)}


def format_bulk_rate(rate: dict | None) -> str:
    """The Sunday report's bulk-rate section."""
    lines = ["", "## Bulk rate", ""]
    if not rate:
        lines.append("Fewer than four weigh-ins in the window, or under two weeks between them.")
        return "\n".join(lines)
    verdict = ("above the ~%.1f%%/week guide — more of the gain is fat; ease the surplus" % BULK_RATE_GUIDE_PCT
               if rate["pct_per_week"] > BULK_RATE_GUIDE_PCT else
               "inside the guide" if rate["pct_per_week"] > 0 else "not gaining — the surplus is not there")
    lines.append(f"{rate['first'][1]:.1f} kg on {rate['first'][0]} → {rate['last'][1]:.1f} kg on {rate['last'][0]} "
                 f"({rate['n']} weigh-ins over {rate['weeks']:.1f} weeks): {rate['kg_per_week']:+.2f} kg/week, "
                 f"{rate['pct_per_week']:+.2f}%/week — {verdict}.")
    return "\n".join(lines)


def bulk_rate_line(rate: dict | None) -> str | None:
    """One line for the coach's context, only when the rate is above the
    guide; None otherwise so the block stays quiet on a normal week."""
    if not rate or rate["pct_per_week"] <= BULK_RATE_GUIDE_PCT:
        return None
    return (f"BULK RATE: {rate['kg_per_week']:+.2f} kg/week ({rate['pct_per_week']:+.2f}%/week) over the last "
            f"{rate['weeks']:.0f} weeks — above the ~{BULK_RATE_GUIDE_PCT:g}%/week guide, so more of the gain is fat. "
            f"Say it once when he asks about weight or food; do not change today's loads for it.")


def kg_on(weigh: list[tuple], day: str | None) -> float | None:
    """Weight on or before `day`; the earliest weigh-in when `day` precedes
    them all; None with no weigh-ins. Mirrors WeighInRecord.kg(on:)."""
    if not weigh:
        return None
    if not day:
        return weigh[-1][1]
    best = None
    for d, kg in weigh:
        if d <= day:
            best = kg
        else:
            break
    return best if best is not None else weigh[0][1]


def canonical_names(supabase) -> dict:
    """lowercased alias or name -> the exercise library's name, so one lift
    logged under two spellings is one lift here, as the library says."""
    try:
        rows = (supabase.table("exercises").select("name, aliases").execute()).data or []
    except Exception:
        return {}
    out = {}
    for row in rows:
        name = (row.get("name") or "").strip()
        if not name:
            continue
        out[name.lower()] = name
        aliases = row.get("aliases")
        for alias in (aliases if isinstance(aliases, list) else []):
            if isinstance(alias, str) and alias.strip():
                out[" ".join(alias.split()).lower()] = name
    return out


def canon_name(name: str, canon: dict | None) -> str:
    key = " ".join((name or "").split()).lower()
    return (canon or {}).get(key) or " ".join((name or "").split())


def strength_facts(rows: list[dict], weeks: dict, window: dict, held: set | None = None,
                   weigh: list[tuple] | None = None, canon: dict | None = None) -> list[dict]:
    """Per lift: this block's peak-week best against the previous block's,
    both as Epley estimates. The BEST estimate wins among sets of up to
    E1RM_LOOSE_MAX_REPS reps; a set past E1RM_MAX_REPS is marked loose. A
    bodyweight movement is scored as plate plus the athlete's share of
    bodyweight on that day. Lifts are grouped by the library's canonical
    name. A lift in `held` reads "held" unless it rose. A lift with no
    peak-week set uses its block best and says so.

    Leg Press on 14 Sep 2026: 245 x 15 at RPE 9 was the top set, a lighter
    12-rep set sat beside it, and a strict-first rule read the lift as flat.
    Dips at +26.5% were the plate alone; with the body they are a fraction of that."""
    from constraints import norm_name
    from prescribe import bodyweight_fraction, effective_load
    held = held or set()
    weigh = weigh or []

    def points(rs):
        out = []
        for r in rs:
            if r.get("is_warmup") or not r.get("actual_reps") or r.get("actual_weight_kg") is None:
                continue
            reps = int(r["actual_reps"])
            if not 0 < reps <= E1RM_LOOSE_MAX_REPS:
                continue
            load = effective_load(float(r["actual_weight_kg"]), r.get("exercise") or "", kg_on(weigh, r.get("date")))
            if load <= 0:
                continue
            out.append((epley(load, reps), r, reps > E1RM_MAX_REPS))
        return out

    def best(rs):
        pts = points(rs)
        return max(pts, key=lambda p: p[0]) if pts else None

    def in_range(r, since, until):
        return since is not None and until is not None and since <= (r.get("date") or "") <= until

    def week_of(r):
        return weeks.get(str(r.get("workout_session_id")))

    def set_text(row):
        return f"{float(row['actual_weight_kg']):g}kg x{int(row['actual_reps'])}"

    by_ex: dict[str, list[dict]] = {}
    for r in rows:
        by_ex.setdefault(canon_name(r.get("exercise") or "", canon), []).append(r)
    out = []
    for name, rs in sorted(by_ex.items()):
        this_rows = [r for r in rs if in_range(r, window["since"], window["until"])]
        prev_rows = [r for r in rs if in_range(r, window.get("prev_since"), window.get("prev_until"))]
        if not this_rows:
            continue
        this_peak = [r for r in this_rows if week_of(r) == _peak_week_of(this_rows, week_of)]
        prev_peak = [r for r in prev_rows if week_of(r) == _peak_week_of(prev_rows, week_of)]
        peak_best = best(this_peak)
        this_best = peak_best or best(this_rows)
        prev_best = best(prev_peak) or best(prev_rows)
        if not this_best:
            continue
        fact = {"exercise": name, "this_e1rm": round(this_best[0], 1), "this_set": set_text(this_best[1]),
                "this_from_peak_week": peak_best is not None, "this_loose": this_best[2],
                "bodyweight": bodyweight_fraction(name) is not None and bool(weigh)}
        if prev_best:
            delta = (this_best[0] - prev_best[0]) / prev_best[0] * 100
            fact.update({"prev_e1rm": round(prev_best[0], 1), "prev_set": set_text(prev_best[1]),
                         "prev_loose": prev_best[2], "delta_pct": round(delta, 1),
                         "verdict": "up" if delta >= 1 else ("down" if delta <= -5 else "flat")})
            if norm_name(name) in held and fact["verdict"] != "up":
                fact["verdict"] = "held"
                fact["held_by_decision"] = True
        else:
            fact["verdict"] = "first block"
        out.append(fact)
    return out


def emphasis_that_ran(rows: list[dict], sessions: list[dict], window: dict) -> list[dict]:
    """The weak-point work the block actually carried: sets logged on its
    Cardio+Abs days that are not ab work, by muscle. From the log, never from
    a pick row — a stored pick says what was decided, not what ran."""
    from volume import resolve_muscle_group
    cardio_ids = {str(s.get("id")) for s in sessions
                  if (s.get("type") or "").strip() == "Cardio+Abs"
                  and window["since"] <= (s.get("date") or "") <= window["until"]}
    by_muscle: dict[str, dict] = {}
    for r in rows:
        if str(r.get("workout_session_id")) not in cardio_ids or r.get("is_warmup"):
            continue
        muscle = resolve_muscle_group(r.get("exercise") or "")
        if not muscle or muscle == "Abs":
            continue
        entry = by_muscle.setdefault(muscle, {"muscle": muscle, "sets": 0, "exercises": []})
        entry["sets"] += 1
        name = (r.get("exercise") or "").strip()
        if name and name not in entry["exercises"]:
            entry["exercises"].append(name)
    return sorted(by_muscle.values(), key=lambda e: -e["sets"])


def constraint_proposals(constraints: list[dict], strength: list[dict]) -> list[dict]:
    """One keep-or-clear line per standing decision in force, added by the
    system so the athlete is always asked at the block boundary. Approving
    clears it through the existing `Decision:` path; not approving keeps it."""
    from constraints import norm_name
    by_name = {norm_name(f["exercise"]): f for f in strength}
    out = []
    for c in constraints or []:
        exercise = (c.get("exercise") or "").strip()
        if not exercise:
            continue
        cap = f"{float(c['max_load_kg']):g}kg cap" if c.get("max_load_kg") is not None else "standing note"
        note = f": {c['note']}" if c.get("note") else ""
        fact = by_name.get(norm_name(exercise))
        result = ""
        if fact:
            result = f" This block: {fact['this_set']}"
            if "delta_pct" in fact:
                result += f", {fact['delta_pct']:+g}% on last block's peak"
            result += "."
        out.append({"line": f"Decision: {exercise} | clear",
                    "rationale": f"{cap} since {c.get('set_on')}{note}.{result} "
                                 f"Approve to clear it; leave it to keep it.",
                    "standing": True})
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
    from blocks import block_picks_between
    from weakpoints import parse_volume_bands, rank_by_shortfall, rotation_sessions, volume_between

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
    from constraints import norm_name
    constraints = _standing_constraints()
    held = {norm_name(c["exercise"]) for c in constraints if c.get("exercise")}
    strength = strength_facts(rows, weeks, window, held, weigh_ins(supabase), canonical_names(supabase))
    ran = emphasis_that_ran(rows, sessions, window)

    bands = parse_volume_bands(prompt)
    volume = volume_between(supabase, window["since"], window["until"])
    ranking = rank_by_shortfall(volume, bands) if bands else []

    recovery = recovery_facts(_recovery_rows(120), window)
    # The reviewed block's own pick, read without side effects. This used to
    # call current_block_weak_points, which at week 1 day 1 MAKES the coming
    # block's pick — consuming the athlete's queued emphasis on a rest day
    # and dating the pick to a day the block's opening would not match.
    stored_pick = block_picks_between(supabase, window.get("prev_until"), window.get("last_session") or window["until"])
    # What the athlete has already named for the coming block: the review
    # must not propose it again, and must never propose over it.
    try:
        from blocks import _pending_emphasis
        emphasis_next = [{"muscle": p["muscle"], "note": p.get("note", "")} for p in _pending_emphasis(supabase)]
    except Exception:
        log.warning("Block review: could not read next block's emphasis", exc_info=True)
        emphasis_next = []
    decisions = [d for d in load_recent_decisions(days=60)
                 if window["since"] <= (d.get("date") or "") <= window["until"]]
    return {
        "window": window,
        "strength": strength,
        "volume": [{"muscle": r["muscle"], "sets_per_week": r["sets"], "band": f"{r['low']}-{r['high']}",
                    "under_by": r["shortfall"] if r["shortfall"] > 0 else 0,
                    "over_by": round(r["sets"] - r["high"], 1) if r["sets"] > r["high"] else 0} for r in ranking],
        "recovery": recovery,
        "emphasis": [e["muscle"] for e in ran],
        "emphasis_ran": ran,
        "emphasis_stored": [p["muscle"] for p in stored_pick],
        "standing": [{"exercise": c.get("exercise"), "max_load_kg": c.get("max_load_kg"),
                      "note": c.get("note"), "set_on": c.get("set_on")} for c in constraints if c.get("exercise")],
        "emphasis_next": emphasis_next,
        "standing_constraints": format_constraints(constraints).strip(),
        "version": FACTS_VERSION,
        "adjustments": [{"date": d.get("date"), "exercise": d.get("exercise"), "reason": d.get("reason")}
                        for d in decisions][:12],
    }


def format_facts(facts: dict) -> str:
    """The sheet as the model reads it."""
    w = facts["window"]
    lines = [f"BLOCK UNDER REVIEW: {w['since']} to {w['until']}"
             + ("" if w.get("complete") else " (in progress)")
             + (f"; previous block {w['prev_since']} to {w['prev_until']}" if w.get("prev_since") else "; no previous block"),
             "", "STRENGTH — peak week against peak week, Epley e1RM from the best set of up to 20 reps "
                 "(a set past 12 reps is a looser estimate); bodyweight lifts scored plate plus body:"]
    if not facts["strength"]:
        lines.append("  no loaded lifts in the block")
    for s in facts["strength"]:
        if "delta_pct" in s:
            body = ", plus body" if s.get("bodyweight") else ""
            lines.append(f"  {s['exercise']}: {s['this_e1rm']}kg ({s['this_set']}{body}) vs {s['prev_e1rm']}kg "
                         f"({s['prev_set']}{body}) = {s['delta_pct']:+g}% — {s['verdict']}"
                         + (" (standing decision: flat because it was told to be)" if s.get("held_by_decision") else "")
                         + ("" if s["this_from_peak_week"] else " [block best, no peak-week set]")
                         + (" [estimate from a set past 12 reps, as the app shows it]"
                            if s.get("this_loose") or s.get("prev_loose") else ""))
        else:
            lines.append(f"  {s['exercise']}: {s['this_e1rm']}kg ({s['this_set']}{', plus body' if s.get('bodyweight') else ''}) — first block"
                         + (" [estimate from a set past 12 reps]" if s.get("this_loose") else ""))
    lines += ["", "VOLUME — sets per calendar week against the band, over the block:"]
    for v in facts["volume"]:
        lines.append(f"  {v['muscle']}: {v['sets_per_week']} against {v['band']}"
                     + (f" — UNDER by {v['under_by']}" if v["under_by"] else "")
                     + (f" — OVER by {v['over_by']} (not an Emphasis-next)" if v.get("over_by") else ""))
    r = facts["recovery"]
    lines += ["", "RECOVERY — block mean against the 42 days before it:"]
    for label, name in (("hrv", "HRV"), ("rhr", "resting HR"), ("sleep", "sleep h")):
        if f"{label}_block_mean" in r:
            lines.append(f"  {name}: {r[f'{label}_block_mean']}"
                         + (f" vs baseline {r[f'{label}_baseline_mean']}" if f"{label}_baseline_mean" in r else ""))
    lines.append(f"  short nights (<7h): {r.get('short_nights', 0)} of {r.get('nights_recorded', 0)} recorded")
    if "readiness_taps" in r:
        lines.append(f"  readiness taps: {r['readiness_taps']}, mean {r['readiness_mean']} of 5")
    ran = facts.get("emphasis_ran") or []
    lines += ["", "WEAK-POINT WORK THAT RAN THIS BLOCK (sets logged on Cardio+Abs days beyond the ab block): "
              + ("; ".join(f"{e['muscle']} — {', '.join(e['exercises'])}, {e['sets']} sets" for e in ran)
                 if ran else "none — every Cardio+Abs day ended after the ab block")]
    # A stored pick that did not run stays in the facts JSON for the record
    # and is never shown to the model: the first time it was, the review
    # told the athlete about a hamstrings emphasis that never happened.
    nxt = facts.get("emphasis_next") or []
    if nxt:
        lines.append("NEXT BLOCK'S EMPHASIS, already set by the athlete (do not propose again): "
                     + "; ".join(f"{p['muscle']}" + (f" → {p['note']}" if p.get("note") else "") for p in nxt))
    else:
        lines.append("NEXT BLOCK'S EMPHASIS: not set — the programme picks the two furthest under band "
                     "unless an Emphasis-next is approved")
    standing = facts.get("standing") or []
    if standing:
        by_name = {f["exercise"].lower(): f for f in facts["strength"]}
        lines += ["", "STANDING DECISIONS IN FORCE — the card asks keep-or-clear for each; recommend one:"]
        for c in standing:
            cap = f"max load {float(c['max_load_kg']):g}kg" if c.get("max_load_kg") is not None else "note"
            f = by_name.get((c["exercise"] or "").lower())
            result = (f" — this block {f['this_set']}" + (f", {f['delta_pct']:+g}%" if f and "delta_pct" in f else "")) if f else ""
            lines.append(f"  {c['exercise']}: {cap}, since {c.get('set_on')}" + (f" — {c['note']}" if c.get("note") else "") + result)
    elif facts.get("standing_constraints"):
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


_EMPHASIS_LINE_RE = re.compile(r"^Emphasis-next:\s*(?P<muscle>[A-Za-z ]+?)\s*\|")


def _emphasis_allowed(line: str, facts: dict | None) -> bool:
    """An Emphasis-next line names a weak point: the muscle must be under its
    band in the sheet and not already set for next block. Without a sheet the
    grammar alone decides. The review of 19 Sep 2026 proposed 'Emphasis-next:
    Triceps | Trim weekly sets…' for a muscle OVER its band that was already
    queued with its movement; approving it would have overwritten the movement
    with those words."""
    m = _EMPHASIS_LINE_RE.match(line)
    if not m or facts is None:
        return True
    muscle = m.group("muscle").strip().lower()
    if any((p.get("muscle") or "").lower() == muscle for p in facts.get("emphasis_next") or []):
        log.info("Block review: dropped %r — already set for next block", line)
        return False
    for v in facts.get("volume") or []:
        if (v.get("muscle") or "").lower() == muscle:
            if v.get("under_by"):
                return True
            log.info("Block review: dropped %r — muscle not under its band", line)
            return False
    log.info("Block review: dropped %r — muscle not on the sheet", line)
    return False


def valid_proposals(proposals: list[dict], facts: dict | None = None) -> list[dict]:
    """Only lines in the recordable grammar survive, at most MAX_PROPOSALS;
    with the fact sheet, an Emphasis-next must name a muscle under its band
    that is not already set."""
    out = []
    for p in proposals or []:
        line = (p.get("line") or "").strip()
        if _LINE_RE.match(line) and _emphasis_allowed(line, facts):
            out.append({"line": line, "rationale": (p.get("rationale") or "").strip()})
    return out[:MAX_PROPOSALS]


def assemble_narrative(data: dict) -> str:
    """The four paragraphs as one labelled narrative ("Strength: …"), the form
    chat shows and review_sections splits; a legacy `narrative` field passes
    through."""
    parts = []
    for key, label in SECTIONS:
        text = (data.get(key) or "").strip()
        if text:
            parts.append(f"{label}: {text}")
    if not parts and data.get("narrative"):
        return str(data["narrative"]).strip()
    return "\n\n".join(parts)


def narrate(client, sheet: str, model: str | None = None, facts: dict | None = None) -> dict:
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
        narrative = assemble_narrative(data)
        bad = numbers_not_in_sheet(narrative, sheet)
        proposals = valid_proposals(data.get("proposals") or [], facts)
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
    written = narrate(client, sheet, facts=facts)
    have = {p["line"].strip().lower() for p in written["proposals"]}
    for p in constraint_proposals(facts.get("standing") or [], facts.get("strength") or []):
        if p["line"].lower() not in have:
            written["proposals"].append(p)
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


ROLLOVER_GRACE_SECONDS = 20


def prepare_at_rollover(memory: dict, grace: float = ROLLOVER_GRACE_SECONDS):
    """E7 (25 Sep 2026): the session that ended has rolled the block over to
    week 1 day 1. Prepare the review now, in the background, so Home finds it
    ready in the morning instead of preparing it while the athlete waits
    (24 s median, up to 36 s, with retries — measured in the 23 Sep report).
    The same guards as the Home path apply inside prepare_if_due: once per
    block, never while a session is active. Returns the thread, or None when
    there is nothing to do."""
    if int(memory.get("mesocycle_week", 1) or 1) != 1 or int(memory.get("mesocycle_day", 1) or 1) != 1:
        return None
    if not get_supabase():
        return None

    def run():
        try:
            time.sleep(grace)   # the session row settles; workout_mode leaves "active"
            from memory import load_memory  # local: keeps import order flat
            from coach import get_anthropic_client  # local
            from webhook import load_system_prompt_for_review  # local: webhook imports this module
            row = prepare_if_due(load_memory(), load_system_prompt_for_review(), get_anthropic_client())
            log.info("Block review at rollover: %s", "prepared" if row else "nothing to prepare")
        except Exception:
            log.exception("Block review at rollover failed; Home will prepare it")

    thread = threading.Thread(target=run, name="block-review-rollover", daemon=True)
    thread.start()
    return thread


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


def card_rows(facts) -> dict:
    """Lift and muscle rows for the card's numbers fold, from the stored fact
    sheet: lifts with a comparison first, largest rise first, then first-block
    lifts; muscles in the sheet's order (furthest under band first)."""
    if isinstance(facts, str):
        try:
            facts = json.loads(facts or "{}")
        except ValueError:
            facts = {}
    facts = facts or {}
    compared = [s for s in facts.get("strength") or [] if "delta_pct" in s]
    fresh = [s for s in facts.get("strength") or [] if "delta_pct" not in s]
    compared.sort(key=lambda s: -float(s["delta_pct"]))
    lifts = [{"exercise": s.get("exercise"), "delta_pct": s.get("delta_pct"), "verdict": s.get("verdict"),
              "this_set": s.get("this_set"), "prev_set": s.get("prev_set"),
              "loose": bool(s.get("this_loose") or s.get("prev_loose")),
              "bodyweight": bool(s.get("bodyweight"))} for s in compared + fresh]
    volume = [{"muscle": v.get("muscle"), "sets": v.get("sets_per_week"), "band": v.get("band"),
               "under_by": v.get("under_by") or 0, "over_by": v.get("over_by") or 0} for v in facts.get("volume") or []]
    return {"lifts": lifts, "volume": volume}


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
    if kind == "decision" and detail.lower() == "clear":
        kind, detail = "standing decision", "Clear it — approve to lift it, leave it to keep it"
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
