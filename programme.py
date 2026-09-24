"""Today's session, computed by the programme, for the coach to reconcile against.

prescribe.py has always been able to compute a session. Nothing asked it to.
It was imported by the replay and by nothing else, which made it a measuring
instrument — it could tell you afterwards whether the coach had agreed with the
programme, and had no way to tell the coach what the programme said.

This is the wire. It builds the same proposal the replay judges against, from
the same three inputs the coach already has (today's session type, the
mesocycle week, and the loads each lift is currently on), and renders it as a
context block. The coach keeps authority: the block is a PROPOSAL, and
departing from it with a stated reason is the documented behaviour. What it
removes is the option of departing from it silently, and the need to derive the
arithmetic in prose.

It also gives set-count enforcement something it never had. Enforcement can
trim a surplus set but not restore a missing one, because "adding would mean
inventing a load and a rep target the coach did not choose". These are computed
numbers, not invented ones — a dropped back-off can now be named with the load
it should carry.
"""

import logging

from data import peak_week  # the block's shape

from coach_parsing import parse_session_template
from prescribe import PriorSet, _is_straight_set, day_plan, norm_name, prescribe_session

log = logging.getLogger(__name__)


def _tokens(name: str) -> frozenset:
    cleaned = "".join(c if c.isalnum() else " " for c in (name or "").lower())
    return frozenset(word for word in cleaned.split() if word)


def match_logged_names(template_exercises, logged_names) -> tuple:
    """Map each template exercise to the logged name it is actually trained as.

    The template says "Incline Press". The log says "Incline Barbell Press".
    Folding case and punctuation cannot bridge that — the difference is a whole
    word — so the coach was told the lift had no history while three sessions of
    it sat in the log, and said so to the athlete twice.

    Matched on WORDS: a logged name is a candidate when it contains every word
    of the template name. Two passes, because a bare subset check over-matches
    exactly once on this programme — "Leg Press" is a subset of "Single Leg
    Sumo Press", which is its own template entry:

      1. Exact matches claim their logged name outright.
      2. Remaining template exercises take an unclaimed candidate.

    An exercise with SEVERAL unclaimed candidates is left unmatched on purpose
    rather than guessed at. "Barbell and dumbbell incline are separate exercises
    for progression... a barbell number never carries over to dumbbells or
    back", so picking one would fabricate a progression across two movements.

    Returns (matches, ambiguous): exercise -> logged name, and exercise -> the
    candidates that could not be told apart.
    """
    by_fold = {}
    for name in logged_names:
        by_fold.setdefault(norm_name(name), name)

    matches, ambiguous, claimed = {}, {}, set()
    unresolved = []
    for exercise in template_exercises:
        exact = by_fold.get(norm_name(exercise))
        if exact is not None:
            matches[exercise] = exact
            claimed.add(exact)
        else:
            unresolved.append(exercise)

    for exercise in unresolved:
        wanted = _tokens(exercise)
        candidates = [
            name for name in logged_names
            if name not in claimed and wanted and wanted <= _tokens(name)
        ]
        if len(candidates) == 1:
            matches[exercise] = candidates[0]
            claimed.add(candidates[0])
        elif len(candidates) > 1:
            ambiguous[exercise] = sorted(candidates)
    return matches, ambiguous


def _number(value) -> float | None:
    """A float, or None for anything that is not one. The rows come from
    progression, which writes floats — but a proposal is built on every coach
    message, and one malformed row must cost an exercise, not the session."""
    try:
        out = float(value)
    except (TypeError, ValueError):
        return None
    return out if out == out else None      # NaN is not a load


def _integer(value) -> int | None:
    number = _number(value)
    return int(number) if number is not None else None


def _history(plan, current_loads: list[dict], week: int | None = None) -> tuple:
    """progression.get_current_loads rows -> the shape prescribe consumes.

    Keyed by the TEMPLATE name, so the proposal for "Incline Press" carries the
    loads logged as "Incline Barbell Press". Without the resolution step this is
    where history silently goes missing and the programme reports a lift with
    months behind it as a feel-out — which is exactly what the coach told the
    athlete, twice, on a Push day.
    """
    rows = {}
    for row in current_loads or []:
        name = (row.get("exercise") or "").strip()
        if name:
            rows[name] = row

    matches, ambiguous = match_logged_names([e for e, _, _ in plan], rows)

    history = {}
    for exercise, logged_name in matches.items():
        row = rows[logged_name]
        # progression writes a bodyweight set's load as the string "BW".
        # Handed to arithmetic it raised, and the exception took every other
        # exercise's proposal down with it.
        load = row.get("load")
        bodyweight = isinstance(load, str) and load.strip().upper() == "BW"
        history[norm_name(exercise)] = PriorSet(
            load=None if bodyweight else _number(load),
            reps=_integer(row.get("reps")),
            rpe=_number(row.get("rpe")),
            date=str(row.get("date") or ""),
            week=row.get("mesocycle_week") if week is None else week,
            bodyweight=bodyweight,
            held=int(row.get("held") or 1),
            step=_number(row.get("step")),
            ready=bool(row.get("ready")),
        )
    renamed = {e: n for e, n in matches.items() if norm_name(e) != norm_name(n)}
    return history, renamed, ambiguous


def _ladder_notes(plan, current_loads: list[dict]) -> dict:
    """{folded template name: reason line} for lifts the programme is
    progressing from an on-ladder load because the newest one sits off it
    (C19). The card says so; Home carries the question."""
    rows = {}
    for row in current_loads or []:
        name = (row.get("exercise") or "").strip()
        if name and row.get("off_ladder"):
            rows[name] = row
    if not rows:
        return {}
    matches, _ambiguous = match_logged_names([e for e, _, _ in plan], rows)
    notes = {}
    for exercise, logged_name in matches.items():
        off = rows[logged_name]["off_ladder"]
        if off.get("treated") == "stray":
            notes[norm_name(exercise)] = (
                f"{off['load']:g}kg on {off['date']} is not a whole number of {off['step']:g}kg steps from this "
                f"lift's ladder — another machine, or a typo — so today progresses from {off['anchor_load']:g}kg "
                f"({off['anchor_date']}). Home has the question; answer it once and this line goes."
            )
        else:
            notes[norm_name(exercise)] = (
                f"{off['load']:g}kg on {off['date']} is off this lift's usual {off['step']:g}kg ladder but you said "
                f"it was real, so today progresses from it."
            )
    return notes


def weak_point_slots(plan: tuple, entries: list, weak_points: list | None) -> tuple:
    """Fill the template's weak-point slots with this block's named lifts.

    Returns (plan, straight_lifts): the plan with one (exercise, sets, kind)
    per named pick, up to the number of slots, and the folded names mapped to
    the slot's rep range. A pick without a movement leaves its slot to the
    coach, as before.
    """
    from coach_parsing import _WEAK_POINT_SLOT_RE  # local: keeps import order flat
    from prescribe import WEAK_POINT_RANGE, classify
    slots = [sets for name, sets in entries if _WEAK_POINT_SLOT_RE.match(name or "")]
    named = [p for p in (weak_points or []) if p.get("exercise")]
    plan = list(plan)
    straight: dict = {}
    for sets, pick in zip(slots, named):
        exercise = pick["exercise"]
        if any(norm_name(exercise) == norm_name(e) for e, _s, _k in plan):
            continue
        plan.append((exercise, int(sets) or 3, classify(exercise)))
        straight[norm_name(exercise)] = WEAK_POINT_RANGE
    return tuple(plan), straight


# Findings of the most recent build_proposal (preflight.enforce), for the
# nightly record; a module value because the tuple this returns is unpacked
# by every caller.
LAST_PREFLIGHT: list = []


def build_proposal(prompt: str, session_type: str, week: int,
                   current_loads: list[dict],
                   recovery: dict | None = None,
                   peak_week_loads: list[dict] | None = None,
                   ceilings: dict | None = None,
                   athlete_kg: float | None = None,
                   weak_points: list | None = None,
                   verdicts: dict | None = None) -> tuple:
    """The programme's proposal for today.

    `weak_points` is this block's pick (weakpoints.current_block_weak_points
    "picks"). A pick that names a movement fills one of the template's
    weak-point slots, and the lift is computed from its own history like every
    other: 3 straight sets, reps 10-15, the wave and the recovery rules
    applied. Until 19 Sep the slots were the coach's alone, and the same lift
    came back as a top set with two back-offs one week and two straight sets
    the next.

    Returns (proposals, renamed, ambiguous) — empty throughout when it cannot
    compute one. `renamed` records where a template name resolved to a different
    logged name, `ambiguous` where it refused to.

    `peak_week_loads` is progression.get_peak_week_loads: each lift's top set
    from the most recent week 3. Weeks 1 and 4 anchor to it (:181, :185).
    """
    try:
        entries, _total = parse_session_template(prompt, session_type, week)
        plan, straight_lifts = weak_point_slots(day_plan(entries), entries, weak_points)
        if not plan:
            return [], {}, {}
        history, renamed, ambiguous = _history(plan, current_loads)
        peak_history, _r, _a = _history(plan, peak_week_loads or [], week=peak_week())
        proposals = prescribe_session(plan, week, history, recovery=recovery,
                                      peak_history=peak_history, athlete_kg=athlete_kg,
                                      straight_lifts=straight_lifts)
        proposals = sized_to_outcomes(proposals, verdicts, week, recovery)
        if ceilings:
            from constraints import apply_ceilings  # local: keeps import order flat
            proposals = apply_ceilings(proposals, ceilings)
        # Pre-flight: the card the rules produced TOGETHER, checked against the
        # invariants and corrected in place, the correction written into the
        # reason line. What it found is kept for the nightly record.
        from preflight import enforce, summarise  # local: keeps import order flat
        proposals, findings = enforce(proposals, history, peak_history, week, straight_lifts, ceilings,
                                      session_type=session_type, weak_points=weak_points)
        global LAST_PREFLIGHT
        LAST_PREFLIGHT = findings
        if findings:
            log.warning("PRE-FLIGHT corrected %s wk%s: %s", session_type, week, summarise(findings))
        notes = _ladder_notes(plan, current_loads)
        if notes:
            from dataclasses import replace as _replace  # local: keeps import order flat
            proposals = [_replace(p, reasons=[notes[norm_name(p.exercise)]] + list(p.reasons))
                         if norm_name(p.exercise) in notes else p for p in proposals]
        return proposals, renamed, ambiguous
    except Exception:
        # A proposal is an aid, never a precondition. The coach has run without
        # one since the programme was written; a failure here must not take the
        # session down with it.
        log.exception("Could not compute the programme proposal")
        return [], {}, {}


def sized_to_outcomes(proposals: list, verdicts: dict | None, week: int, recovery: dict | None) -> list:
    """The programme's own number came in LIGHT the last two scored sessions
    of a lift (the range beaten at or under the target RPE, twice): today's
    opens one step higher than the rule alone. The reason says "sized", the
    word the pre-flight's jump invariant reads for a sized increase.

    Not on the deload, not on a recovery session, never on a lift without a
    load. This is the loop the scorecard closes: a trend nobody moved on for
    a block (Leg Press 245 x15, Leg Curl 110 x16, 3-19 Sep 2026) now moves
    the number itself."""
    from dataclasses import replace
    from data import deload_week  # local: keeps import order flat
    from prescribe import INCREMENT, _round_load, recovery_adjustment  # local: keeps import order flat
    import scorecard  # local: keeps import order flat
    if not verdicts or week == deload_week() or recovery_adjustment(recovery).recovery_session:
        return proposals
    out = []
    for p in proposals:
        top = p.working[0] if p.working else None
        already_sized = any("sized" in r.lower() for r in p.reasons)   # this session's miss already moved it
        if (top is None or not top.weight_kg or top.bodyweight or already_sized
                or not scorecard.ran_light_twice(verdicts, p.exercise)):
            out.append(p); continue
        grid = top.grid if top.grid and top.grid > 0.5 else None
        step = max(INCREMENT.get(p.kind, 2.5), grid or 0.0)
        new_top = _round_load(top.weight_kg + step, grid, top.weight_kg)
        ratio = new_top / top.weight_kg
        def scaled(spec):
            if spec.weight_kg is None or spec.bodyweight:
                return spec
            return replace(spec, weight_kg=_round_load(spec.weight_kg * ratio, grid, spec.weight_kg))
        working = [replace(top, weight_kg=new_top)] + [scaled(w) for w in p.working[1:]]
        reasons = [f"Sized to the outcomes: the programme's number came in LIGHT the last two sessions "
                   f"(the range beaten at or under the target RPE), so today opens one step higher "
                   f"({top.weight_kg:g} → {new_top:g}kg) than the rule alone."] + list(p.reasons)
        out.append(replace(p, working=working, backoff=[scaled(b) for b in p.backoff],
                           warmup=[scaled(w) for w in p.warmup], reasons=reasons))
    return out


def _is_ab_work(exercise: str) -> bool:
    from volume import resolve_muscle_group  # local: keeps import order flat
    return resolve_muscle_group(exercise) == "Abs"


def format_proposal(proposals: list, session_type: str, week: int,
                    renamed: dict | None = None,
                    ambiguous: dict | None = None) -> str:
    """Render the proposal, and say plainly what it is and is not."""
    if not proposals:
        return ("PROGRAMME PROPOSAL — unavailable for this session. Prescribe "
                "from the session template and CURRENT WORKING LOADS as usual.")

    lines = [f"PROGRAMME PROPOSAL — {session_type}, week {week}, computed from "
             f"the template and the logged loads."]
    lines.append("")
    # Grouped, not repeated per exercise. On a full Push day the same sentence
    # came back eight times — "opening week 1 from the most recent session..." —
    # and the reasons and deferrals together were 773 of the block's 998 tokens,
    # re-sent on every logged set. Measured before and after: 998 -> ~350.
    # Same repetition, and the same fix, as the replay report's deferred notes.
    grouped_reasons: dict = {}
    grouped_deferred: dict = {}
    for proposal in proposals:
        top = proposal.working[0].render() if proposal.working else "load TBD"
        backoff = ", ".join(b.render() for b in proposal.backoff) if proposal.backoff else None
        count = proposal.working_set_count
        if _is_straight_set(proposal.exercise):
            # Ab work is straight sets at one load (:145). The coach was shown
            # a top set plus back-offs here and, correctly, "adjusted" every
            # ab exercise to undo a shape the programme never meant.
            detail = f"{count} straight set{'' if count == 1 else 's'} at one load · {top}"
            if proposal.warmup and not _is_ab_work(proposal.exercise):
                detail += " · ramp " + ", ".join(w.render().split(" RPE")[0] for w in proposal.warmup)
        else:
            detail = f"{count} working set{'' if count == 1 else 's'} · top {top}"
            if backoff:
                detail += f" · back-off {backoff}"
            if proposal.warmup:
                detail = f"ramp {', '.join(w.render().split(' RPE')[0] for w in proposal.warmup)} · " + detail
        lines.append(f"- {proposal.exercise} — {detail}")
        # Recovery notes are never truncated: :321 requires saying which rules
        # applied when more than one matches, and :323 requires stating which
        # lever was used. The [:1] below is a token economy for the ordinary
        # progression reason and must not swallow those.
        for reason in list(getattr(proposal, "recovery_reasons", [])) + proposal.reasons[:1]:
            grouped_reasons.setdefault(reason, []).append(proposal.exercise)
        for note in proposal.deferred:
            # The note leads with its own exercise name; strip it so identical
            # notes collapse instead of each being unique by prefix.
            _, _, body = note.partition(": ")
            grouped_deferred.setdefault(body or note, []).append(proposal.exercise)

    if grouped_reasons:
        lines.append("")
        lines.append("WHY THOSE NUMBERS")
        for reason, who in grouped_reasons.items():
            lines.append(f"- {', '.join(who)}: {reason}")
    if grouped_deferred:
        lines.append("")
        lines.append("UNDETERMINED — the programme does not settle these. "
                     "Decide them and say what you decided.")
        for body, who in grouped_deferred.items():
            lines.append(f"- {', '.join(who)}: {body}")
    for exercise, logged in sorted((renamed or {}).items()):
        lines.append(f"  {exercise} is logged as \"{logged}\" — same lift, "
                     f"and its history was read from there.")
    for exercise, candidates in sorted((ambiguous or {}).items()):
        lines.append(
            f"  {exercise} is logged under more than one name "
            f"({', '.join(candidates)}), so no history was carried across. "
            f"They progress separately — a load from one is not a load for the "
            f"other. Ask which he is doing today."
        )
    lines.append("")
    lines.append("How to read this block is in the system prompt; it is not "
                 "repeated here because this block is re-sent on every logged "
                 "set and the explanation never changes.")
    return "\n".join(lines)
