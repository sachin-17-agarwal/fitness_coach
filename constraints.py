"""Standing constraints: decisions that outlive the session they were made in.

The opening plan's decisions are stored; a decision made in chat was not.
The athlete said the cable crunch stack tops out at 105kg, the coach agreed
to progress by reps and tempo instead — and nothing wrote that down, so the
next proposal would ask for 107.5 and the coach would have to remember a
conversation four days old.

Now the coach declares such a fact in one line, in any reply:

    Decision: Cable Crunch | max load 105kg | stack tops out; reps to 12-15 @8, then tempo
    Decision: Cable Crunch | clear

The line is parsed and stored here, shown back to the coach every session
as STANDING CONSTRAINTS, and handed to the programme, whose proposal caps
its loads to the ceiling and progresses by reps instead. The code never
invents a constraint; it only keeps the one the coach wrote.
"""

from __future__ import annotations

import logging
import re

from data import get_supabase, now_local
from prescribe import norm_name

log = logging.getLogger(__name__)

DECISION_RE = re.compile(r"^\s*decision:\s*(.+?)\s*$", re.IGNORECASE | re.MULTILINE)
_MAX_LOAD_RE = re.compile(r"max(?:imum)?\s*load\s*(\d+(?:\.\d+)?)\s*kg", re.IGNORECASE)


def parse_decision_lines(reply: str) -> list[dict]:
    """Every `Decision:` line -> {exercise, max_load_kg, note, clear}."""
    out = []
    for m in DECISION_RE.finditer(reply or ""):
        parts = [p.strip() for p in m.group(1).split("|") if p.strip()]
        if not parts:
            continue
        exercise = parts[0].strip("*").strip()
        rest = parts[1:]
        if any(p.lower() == "clear" for p in rest):
            out.append({"exercise": exercise, "clear": True})
            continue
        max_load = None
        notes = []
        for p in rest:
            hit = _MAX_LOAD_RE.search(p)
            if hit:
                max_load = float(hit.group(1))
            else:
                notes.append(p)
        if max_load is None and not notes:
            continue
        out.append({"exercise": exercise, "max_load_kg": max_load, "note": " — ".join(notes), "clear": False})
    return out


def record_decisions(reply: str) -> int:
    """Store the reply's Decision lines. Returns rows written; never raises."""
    decisions = parse_decision_lines(reply)
    if not decisions:
        return 0
    try:
        supabase = get_supabase()
        if not supabase:
            return 0
        today = now_local().strftime("%Y-%m-%d")
        written = 0
        for d in decisions:
            # One active row per exercise: the newest decision replaces the last.
            for row in (supabase.table("exercise_constraints").select("id, exercise")
                        .eq("active", True).execute().data or []):
                if norm_name(row.get("exercise", "")) == norm_name(d["exercise"]):
                    supabase.table("exercise_constraints").update({"active": False}).eq("id", row["id"]).execute()
            if d.get("clear"):
                log.info("STANDING CONSTRAINT cleared: %s", d["exercise"])
                continue
            supabase.table("exercise_constraints").insert({
                "exercise": d["exercise"], "max_load_kg": d.get("max_load_kg"),
                "note": d.get("note") or None, "set_on": today, "active": True,
            }).execute()
            written += 1
            log.info("STANDING CONSTRAINT: %s max %s — %s", d["exercise"], d.get("max_load_kg"), d.get("note"))
        return written
    except Exception:
        log.warning("Could not store Decision lines", exc_info=True)
        return 0


def load_active() -> list[dict]:
    try:
        supabase = get_supabase()
        if not supabase:
            return []
        return (supabase.table("exercise_constraints").select("exercise, max_load_kg, note, set_on")
                .eq("active", True).order("set_on", desc=True).execute().data or [])
    except Exception:
        log.warning("Could not load standing constraints", exc_info=True)
        return []


def ceilings(rows: list[dict]) -> dict[str, float]:
    """norm exercise name -> max load, for the programme."""
    out = {}
    for r in rows or []:
        if r.get("max_load_kg") is not None:
            out[norm_name(r["exercise"])] = float(r["max_load_kg"])
    return out


def format_constraints(rows: list[dict]) -> str:
    if not rows:
        return ("\nSTANDING CONSTRAINTS — facts you have recorded with a `Decision:` line that outlive "
                "the session (a machine's top plate, a movement off the table). None recorded.\n")
    lines = ["\nSTANDING CONSTRAINTS — facts you recorded with a `Decision:` line. The programme's "
             "proposal already respects them; your plan must too. `Decision: <Exercise> | clear` ends one."]
    for r in rows:
        cap = f" · max load {float(r['max_load_kg']):g}kg" if r.get("max_load_kg") is not None else ""
        note = f" — {r['note']}" if r.get("note") else ""
        lines.append(f"- {r['exercise']}{cap} (since {r.get('set_on')}){note}")
    return "\n".join(lines) + "\n"


# ── The programme respects a ceiling ────────────────────────────────────────

REPS_AT_CEILING_SPAN = 3
REPS_AT_CEILING_MAX = 15


def apply_ceilings(proposals: list, caps: dict[str, float]) -> list:
    """Cap every proposal's loads at its exercise's ceiling.

    When the programme wanted MORE load than the stack has, progression moves
    to reps: the range steps up from where it was (the old top becomes the new
    floor, span 3, never past 15), and the reason says tempo is the lever after
    that. Ramp and back-off scale with the top set so the shape holds.
    """
    if not caps:
        return proposals
    from dataclasses import replace
    from prescribe import SetSpec, _round_load
    caps = {norm_name(k): float(v) for k, v in caps.items() if v is not None}
    out = []
    for p in proposals:
        cap = caps.get(norm_name(p.exercise))
        top = p.working[0] if p.working else None
        if cap is None or top is None or top.weight_kg is None or top.weight_kg <= cap:
            out.append(p); continue
        ratio = cap / top.weight_kg
        low, high = top.reps_low, top.reps_high
        new_low = high
        new_high = min(REPS_AT_CEILING_MAX, high + REPS_AT_CEILING_SPAN)
        if new_low >= new_high:
            new_low, new_high = max(low, REPS_AT_CEILING_MAX - REPS_AT_CEILING_SPAN), REPS_AT_CEILING_MAX

        def scaled(spec, reps=None):
            w = None if spec.weight_kg is None else _round_load(spec.weight_kg * ratio)
            if reps is None:
                return SetSpec(w, spec.reps_low, spec.reps_high, spec.rpe, bodyweight=spec.bodyweight)
            return SetSpec(w, reps[0], reps[1], spec.rpe, bodyweight=spec.bodyweight)

        working = [scaled(s, (new_low, new_high)) for s in p.working]
        working = [SetSpec(cap, s.reps_low, s.reps_high, s.rpe, bodyweight=s.bodyweight) for s in working]
        backoff = [scaled(s) for s in p.backoff]
        warmup = [scaled(s) for s in p.warmup]
        reasons = list(p.reasons) + [
            f"{p.exercise}: the programme wanted {top.weight_kg:g}kg, but a standing decision caps this "
            f"machine at {cap:g}kg. Progression moves to reps — {new_low}-{new_high} at the same RPE — "
            f"and to tempo (longer eccentric, a pause at the top) once the range is cleared."]
        out.append(replace(p, working=working, backoff=backoff, warmup=warmup, reasons=reasons))
    return out
