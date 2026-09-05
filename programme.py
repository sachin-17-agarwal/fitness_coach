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

from coach_parsing import parse_session_template
from prescribe import PriorSet, day_plan, norm_name, prescribe_session

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
        )
    renamed = {e: n for e, n in matches.items() if norm_name(e) != norm_name(n)}
    return history, renamed, ambiguous


def build_proposal(prompt: str, session_type: str, week: int,
                   current_loads: list[dict],
                   recovery: dict | None = None,
                   peak_week_loads: list[dict] | None = None) -> tuple:
    """The programme's proposal for today.

    Returns (proposals, renamed, ambiguous) — empty throughout when it cannot
    compute one. `renamed` records where a template name resolved to a different
    logged name, `ambiguous` where it refused to.

    `peak_week_loads` is progression.get_peak_week_loads: each lift's top set
    from the most recent week 3. Weeks 1 and 4 anchor to it (:181, :185).
    """
    try:
        entries, _total = parse_session_template(prompt, session_type)
        plan = day_plan(entries)
        if not plan:
            return [], {}, {}
        history, renamed, ambiguous = _history(plan, current_loads)
        peak_history, _r, _a = _history(plan, peak_week_loads or [], week=3)
        return (prescribe_session(plan, week, history, recovery=recovery,
                                  peak_history=peak_history),
                renamed, ambiguous)
    except Exception:
        # A proposal is an aid, never a precondition. The coach has run without
        # one since the programme was written; a failure here must not take the
        # session down with it.
        log.exception("Could not compute the programme proposal")
        return [], {}, {}


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
        backoff = proposal.backoff[0].render() if proposal.backoff else None
        count = proposal.working_set_count
        detail = f"{count} working set{'' if count == 1 else 's'} · top {top}"
        if backoff:
            detail += f" · back-off {backoff}"
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
