"""Pre-flight: the programme's card checked and corrected by code before
anyone sees it.

Every rule in prescribe.py is right on its own and has a test. What broke,
week after week, was what they produce TOGETHER on a real lift: week 1
anchored to the peak, a readiness cut, a half-kilo rounding and a cable stack
made "12kg x7-11" for a lift that lives on 2.5kg steps and had just done
12.5 x 12. The athlete found it at the gym. Nothing here asks him to check
anything: a card that fails an invariant is corrected, the correction is
written into its reason line, and the miss is logged for the report.

Invariants, in the order they run:
  loadable    every prescribed load is a multiple of the lift's own step
  regression  the top set is not below the anchor set's load unless a rule
              says so (recovery, deload, below-range, cap, decision)
  range       working reps sit inside the programme's range for the lift
              (one step under the floor is allowed: a recovery cut)
  ceiling     no load above an active standing cap
  slots       on Cardio+Abs the queued emphasis lifts are on the card

`enforce` is pure and runs inside programme.build_proposal, so every card —
the opening, a mid-session recompute, tomorrow's dry run — passes it.
`run_if_due` computes tomorrow's card once a day from the live data and
stores what it found under memory["preflight_last"], read by /status.
"""

from __future__ import annotations

import json
import logging
from dataclasses import replace

from constraints import norm_name
from prescribe import INCREMENT, OVERSHOOT_CAP, TOP_SET_RANGE, Proposal, SetSpec, _is_straight_set, _round_load

log = logging.getLogger(__name__)

PREFLIGHT_DATE_KEY = "preflight_date"
PREFLIGHT_LAST_KEY = "preflight_last"

import re

# A reason that explains a load below the anchor, in the words the rules
# themselves write. Deliberately not "reset" or "cut" alone: "reps reset to
# the bottom" is ordinary week 1 wording and explains nothing about the load.
_JUSTIFIED_RE = re.compile(
    r"recovery|deload|below range|ceiling|\bcap\b|capped|standing|decision|stall|tempo|regression"
    r"|load cut|drops? the load|comes down|bringing it back|feel-out",
    re.IGNORECASE,
)


def _on_step(weight: float | None, step: float | None) -> bool:
    if weight is None or not step or step <= 0:
        return True
    return abs(weight / step - round(weight / step)) < 1e-6


def _scaled(spec: SetSpec, ratio: float, grid: float | None) -> SetSpec:
    if spec.weight_kg is None or ratio == 1.0:
        return spec
    return replace(spec, weight_kg=_round_load(spec.weight_kg * ratio, grid or spec.grid))


def enforce(proposals: list, history: dict, peak_history: dict | None, week: int,
            straight_lifts: dict | None = None, ceilings: dict | None = None,
            session_type: str = "", weak_points: list | None = None) -> tuple[list, list[dict]]:
    """Return (corrected proposals, findings). Each finding is
    {"exercise", "kind", "fixed": bool, "detail"}; a fixed one has already
    been written into the proposal's first reason."""
    folded = {norm_name(k): v for k, v in (history or {}).items()}
    peak = {norm_name(k): v for k, v in (peak_history or {}).items()}
    caps = {norm_name(k): float(v) for k, v in (ceilings or {}).items() if v is not None}
    straight = {norm_name(k): v for k, v in (straight_lifts or {}).items()}
    findings: list[dict] = []
    out = []
    for p in proposals:
        key = norm_name(p.exercise)
        prior = folded.get(key)
        anchor = peak.get(key) if week in (1, 4) and peak.get(key) is not None else prior
        step = (getattr(prior, "step", None) or getattr(peak.get(key), "step", None)) or None
        reasons = list(p.reasons)
        fixes: list[str] = []
        working, backoff, warmup = list(p.working), list(p.backoff), list(p.warmup)

        # loadable: a load the stack does not have is rounded to one it has.
        if step:
            for name, sets in (("working", working), ("backoff", backoff), ("warmup", warmup)):
                for i, spec in enumerate(sets):
                    if not _on_step(spec.weight_kg, step):
                        fixed = _round_load(spec.weight_kg, step)
                        sets[i] = replace(spec, weight_kg=fixed, grid=step)
                        fixes.append(f"{spec.weight_kg:g}kg is not a load on this lift's {step:g}kg step; {fixed:g}kg is")
                        findings.append({"exercise": p.exercise, "kind": "loadable", "fixed": True,
                                         "detail": f"{name} {spec.weight_kg:g}kg → {fixed:g}kg (step {step:g})"})

        # regression: below the anchor with no rule naming why.
        if (working and anchor is not None and getattr(anchor, "load", None) and week != 4
                and not p.recovery_session and working[0].weight_kg is not None
                and working[0].weight_kg < float(anchor.load) - 1e-9):
            text = " ".join(list(p.reasons) + list(getattr(p, "recovery_reasons", [])) + list(p.deferred)).lower()
            if not _JUSTIFIED_RE.search(text):
                old = working[0].weight_kg
                ratio = float(anchor.load) / old if old else 1.0
                working = [replace(working[0], weight_kg=float(anchor.load))] + [_scaled(w, ratio, step) for w in working[1:]]
                backoff = [_scaled(b, ratio, step) for b in backoff]
                warmup = [_scaled(w, ratio, step) for w in warmup]
                fixes.append(f"no rule lowers this lift below its last top set of {float(anchor.load):g}kg, so it holds there")
                findings.append({"exercise": p.exercise, "kind": "regression", "fixed": True,
                                 "detail": f"top {old:g}kg → {float(anchor.load):g}kg (anchor {anchor.load:g} x{anchor.reps})"})

        # jump: an increase is one increment (2.5-5kg compounds, 1-2.5kg
        # isolations, :181/:202) or, when the reason says it was sized to an
        # overshoot, at most OVERSHOOT_CAP. Nothing else may put a top set
        # further above its anchor: Single Leg Sumo Press opened 132.5 -> 150
        # on 23 Sep 2026 from a mis-measured step and nothing caught it.
        if (working and anchor is not None and getattr(anchor, "load", None) and week != 4
                and working[0].weight_kg is not None and not working[0].bodyweight):
            base = float(anchor.load)
            inc = max(INCREMENT.get(p.kind, 2.5), step or 0.0)
            reasons_text = " ".join(p.reasons).lower()
            limit = base * (1 + OVERSHOOT_CAP) + (step or 0.5) if "sized" in reasons_text else base + max(2 * INCREMENT.get(p.kind, 2.5), step or 0.0)
            if working[0].weight_kg > limit + 1e-9:
                old = working[0].weight_kg
                new_top = _round_load(base + inc, step) if step else base + inc
                ratio = new_top / old
                working = [replace(working[0], weight_kg=new_top)] + [_scaled(w, ratio, step) for w in working[1:]]
                backoff = [_scaled(b, ratio, step) for b in backoff]
                warmup = [_scaled(w, ratio, step) for w in warmup]
                fixes.append(f"{old:g}kg is {old - base:g}kg above the {base:g}kg it progresses from, more than one "
                             f"increment; {new_top:g}kg is one increment up")
                findings.append({"exercise": p.exercise, "kind": "jump", "fixed": True,
                                 "detail": f"top {old:g}kg → {new_top:g}kg (anchor {base:g})"})

        # range: inside the programme's band, one step under the floor allowed.
        # Ab work and a weak-point slot are straight sets with their own range;
        # the slot's is known, the ab block's (12-15) is left to the rules.
        if key in straight:
            low, high = straight[key]
        elif getattr(p, "straight", False) or _is_straight_set(p.exercise):
            low, high = None, None
        else:
            low, high = TOP_SET_RANGE.get(p.kind, (None, None))
        if low is not None and working:
            for i, spec in enumerate(working):
                lo, hi = spec.reps_low, spec.reps_high
                new_lo, new_hi = max(lo, low - 1), min(hi, high)
                if new_lo > new_hi:
                    new_lo, new_hi = min(new_lo, new_hi), max(new_lo, new_hi)
                if (new_lo, new_hi) != (lo, hi):
                    working[i] = replace(spec, reps_low=new_lo, reps_high=new_hi)
                    fixes.append(f"reps {lo}-{hi} sat outside the {low}-{high} range; {new_lo}-{new_hi} is inside it")
                    findings.append({"exercise": p.exercise, "kind": "range", "fixed": True,
                                     "detail": f"working reps {lo}-{hi} → {new_lo}-{new_hi} (range {low}-{high})"})

        # ceiling: never above an active cap.
        cap = caps.get(key)
        if cap is not None:
            for name, sets in (("working", working), ("backoff", backoff), ("warmup", warmup)):
                for i, spec in enumerate(sets):
                    if spec.weight_kg is not None and spec.weight_kg > cap + 1e-9:
                        sets[i] = replace(spec, weight_kg=cap)
                        fixes.append(f"{spec.weight_kg:g}kg is above the standing {cap:g}kg cap; capped")
                        findings.append({"exercise": p.exercise, "kind": "ceiling", "fixed": True,
                                         "detail": f"{name} {spec.weight_kg:g}kg → {cap:g}kg"})

        if fixes:
            reasons.insert(0, "Pre-flight corrected this card: " + "; ".join(dict.fromkeys(fixes)) + ".")
        out.append(replace(p, working=working, backoff=backoff, warmup=warmup, reasons=reasons))

    # slots: the queued emphasis must be on a Cardio+Abs card. Not fixable
    # here — the plan is built upstream — so it is reported, loudly.
    if (session_type or "").strip() == "Cardio+Abs":
        names = {norm_name(p.exercise) for p in out}
        for pick in weak_points or []:
            exercise = pick.get("exercise")
            if exercise and norm_name(exercise) not in names:
                findings.append({"exercise": exercise, "kind": "slots", "fixed": False,
                                 "detail": f"{pick.get('muscle', '?')} emphasis names {exercise}, which is not on the card"})
    return out, findings


def summarise(findings: list[dict]) -> str:
    if not findings:
        return "clean"
    return "; ".join(f"{f['exercise']}: {f['kind']} {'fixed' if f['fixed'] else 'UNFIXED'} — {f['detail']}" for f in findings)


# ── The nightly dry run ─────────────────────────────────────────────────────

def run_if_due(memory: dict) -> dict | None:
    """Compute tomorrow's card once per local day and store what pre-flight
    found. Skips inside a session. Returns the stored record, or None."""
    from data import get_supabase, now_local
    if not get_supabase():
        return None
    today = now_local().strftime("%Y-%m-%d")
    if str(memory.get(PREFLIGHT_DATE_KEY) or "") == today:
        return None
    try:
        from workout import get_workout_state
        if (get_workout_state() or {}).get("workout_mode") == "active":
            return None
    except Exception:
        pass
    try:
        record = run_for_next_session(memory)
    except Exception:
        log.exception("Pre-flight dry run failed")
        return None
    from memory import set_memory_value
    set_memory_value(PREFLIGHT_DATE_KEY, today)
    set_memory_value(PREFLIGHT_LAST_KEY, json.dumps(record))
    return record


def run_for_next_session(memory: dict) -> dict:
    """The next session's card, built exactly as the opening will build it,
    with pre-flight's findings."""
    import programme
    from coach import load_system_prompt
    from constraints import ceilings as cap_map, load_active
    from data import SESSION_OVERRIDE_KEY, latest_bodyweight_kg, now_local, session_type_for
    from progression import get_current_loads, get_peak_week_loads
    from weakpoints import current_block_weak_points

    week = int(memory.get("mesocycle_week", 1) or 1)
    day = int(memory.get("mesocycle_day", 1) or 1)
    session_type = session_type_for(day, override=memory.get(SESSION_OVERRIDE_KEY))
    prompt = load_system_prompt()
    picks = (current_block_weak_points(memory, prompt) or {}).get("picks") if session_type == "Cardio+Abs" else None
    proposals, _renamed, _ambiguous = programme.build_proposal(
        prompt, session_type, week, get_current_loads() or [],
        peak_week_loads=get_peak_week_loads() or [], ceilings=cap_map(load_active()),
        athlete_kg=latest_bodyweight_kg(), weak_points=picks)
    findings = list(programme.LAST_PREFLIGHT)
    record = {
        "ran_at": now_local().isoformat(), "session": session_type, "week": week, "day": day,
        "lifts": [{"exercise": p.exercise, "top": p.working[0].render() if p.working else None} for p in proposals],
        "findings": findings,
    }
    if findings:
        log.warning("PRE-FLIGHT %s wk%s: %s", session_type, week, summarise(findings))
    else:
        log.info("PRE-FLIGHT %s wk%s: clean (%d lifts)", session_type, week, len(proposals))
    return record
