"""The session plan as a contract between the coach and the card.

For six months the coach's output was prose, and the prose was the data: the
model did arithmetic inside a paragraph, a regex read the paragraph back into
a card, and every guard, fallback and audit existed to police that paragraph.
A number could be fixed for no reason ("+2.5 at 10 reps, always") or changed
for no reason ("one back-off today, two tomorrow"), and when asked why, the
coach had nothing to read back and reversed itself. Both are the same failure:
a number nobody decided.

Here the coach returns a PLAN, typed. Every exercise carries a decision — the
programme's default applied on purpose, or a deliberate departure — and a
departure must carry its reason. The plan is checked against the athlete's
own rules and handed back once for correction if it breaks them; the model
fixes the model, and the code never edits a number. The card's block text is
RENDERED from the plan, so it always parses. And the decisions are stored, so
when the athlete asks why, the coach reads its own reason rather than
inventing one — and a departure made on Tuesday is still known on Friday.

The prose stays prose. The coaching, the conversation, the encouragement do
not change. Only the numbers move into the contract.
"""

import json
import logging
import re
from dataclasses import dataclass, field
from datetime import timedelta

from coach_parsing import (_WEAK_POINT_SLOT_RE, _match_template_key,
                           _normalise_exercise, _set_shape,
                           parse_session_template)
from data import get_supabase, now_local
from prescribe import WAVE, is_bodyweight

log = logging.getLogger(__name__)

STRENGTH_DAYS = ("Pull", "Push", "Legs")
# Cardio+Abs opens under the contract too: the cardio half is done and imported
# from the Watch before the athlete taps START ABS, and the ab block plus the
# two weak-point slots are a regular workout.
PLAN_DAYS = STRENGTH_DAYS + ("Cardio+Abs",)

# ── The contract ─────────────────────────────────────────────────────────────
#
# Written by hand rather than generated, so it stays inside the subset the
# structured-output validator accepts (no numeric bounds, no string lengths;
# those are checked in code below) and so every field has one meaning.

_SET = {
    "type": "object",
    "properties": {
        "load_kg": {"type": "number",
                    "description": "Load in kg. For a bodyweight movement, the ADDED load (0 for bodyweight alone)."},
        "reps_low": {"type": "integer"},
        "reps_high": {"type": "integer", "description": "Equal to reps_low for a single target."},
        "rpe": {"type": "number"},
    },
    "required": ["load_kg", "reps_low", "reps_high", "rpe"],
    "additionalProperties": False,
}
_WARMUP_SET = {
    "type": "object",
    "properties": {"load_kg": {"type": "number"}, "reps": {"type": "integer"}},
    "required": ["load_kg", "reps"],
    "additionalProperties": False,
}

PLAN_SCHEMA = {
    "type": "object",
    "properties": {
        "opening": {
            "type": "string",
            "description": "The coach's words to open the session, three to five sentences: recovery read, "
                           "what today is for, one thing to watch. Plain prose, no exercise blocks, no "
                           "per-exercise reasons (those go in each exercise's reason).",
        },
        "exercises": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "exercise": {"type": "string", "description": "The template's name for the movement."},
                    "decision": {
                        "type": "string", "enum": ["accept", "adjust"],
                        "description": "accept: the programme's proposal, applied as it stands. "
                                       "adjust: a deliberate departure from it — reason required.",
                    },
                    "reason": {
                        "type": "string",
                        "description": "For adjust: ONE or two sentences, the cause only — the card already "
                                       "prints the programme's numbers beside yours, so do not restate the "
                                       "numbers or the shape rule. Lead with the specific fact that drove the "
                                       "change (last session's set, a machine's step, a joint, a reading). "
                                       "For accept: the rule being applied, in a few words.",
                    },
                    "warmup": {"type": "array", "items": _WARMUP_SET,
                               "description": "Omit for accept: the programme's ramp is used."},
                    "working": {"type": "array", "items": _SET,
                                "description": "Omit for accept: the programme's numbers are used. For adjust: one top "
                                               "set for top-set/back-off work; every set for straight-set work."},
                    "backoff": {"type": "array", "items": _SET,
                                "description": "Omit for accept. For adjust: empty for straight-set work."},
                    "tempo": {"type": "string", "description": "e.g. 3-1-2"},
                    "rest_seconds": {"type": "integer"},
                    "form_cue": {"type": "string"},
                    "note": {"type": "string",
                             "description": "Coaching context for THIS lift beyond the reason — what to watch today, "
                                            "a cue for the machine, what a clean top set would trigger next time. It "
                                            "is shown on the lift's card, never in the opening. Not a restatement of "
                                            "reason; empty is fine."},
                },
                "required": ["exercise", "decision", "reason", "tempo", "rest_seconds", "form_cue", "note"],
                "additionalProperties": False,
            },
        },
        "carried": {
            "type": "array", "items": {"type": "string"},
            "description": "ONLY entries from DECISIONS IN FORCE in your context that still apply today, "
                           "one sentence each. Empty when there are none. Never a repeat of the opening.",
        },
    },
    "required": ["opening", "exercises", "carried"],
    "additionalProperties": False,
}


@dataclass
class SetPlan:
    load_kg: float
    reps_low: int
    reps_high: int
    rpe: float


@dataclass
class ExercisePlan:
    exercise: str
    decision: str
    reason: str
    warmup: list = field(default_factory=list)      # [(load_kg, reps)]
    working: list = field(default_factory=list)     # [SetPlan]
    backoff: list = field(default_factory=list)     # [SetPlan]
    tempo: str = ""
    rest_seconds: int = 120
    form_cue: str = ""
    note: str = ""
    # Set by validate(): this exercise fills one of the template's weak-point
    # slots rather than replacing a named movement.
    slot_fill: bool = False


@dataclass
class SessionPlan:
    opening: str
    exercises: list
    carried: list = field(default_factory=list)


def parse_plan(text: str, proposal: dict | None = None) -> SessionPlan:
    """The model's JSON into the dataclasses. Raises on anything malformed.

    An `accept` may omit its sets: the programme's numbers are what accept
    MEANS, so restating them was ~60% of the plan's output tokens for no
    information — and output tokens are what the athlete waits on. They are
    filled from `proposal` here, so downstream nothing knows the difference.
    """
    raw = json.loads(text)
    proposal_by_key = {_normalise_exercise(k): v for k, v in (proposal or {}).items()}
    exercises = []
    for e in raw["exercises"]:
        plan_e = ExercisePlan(
            exercise=str(e["exercise"]).strip(),
            decision=str(e["decision"]).strip().lower(),
            reason=str(e.get("reason") or "").strip(),
            warmup=[(float(w["load_kg"]), int(w["reps"])) for w in e.get("warmup") or []],
            working=[SetPlan(float(s["load_kg"]), int(s["reps_low"]), int(s["reps_high"]), float(s["rpe"]))
                     for s in e.get("working") or []],
            backoff=[SetPlan(float(s["load_kg"]), int(s["reps_low"]), int(s["reps_high"]), float(s["rpe"]))
                     for s in e.get("backoff") or []],
            tempo=str(e.get("tempo") or "").strip(),
            rest_seconds=int(e.get("rest_seconds") or 0),
            form_cue=str(e.get("form_cue") or "").strip(),
            note=str(e.get("note") or "").strip(),
        )
        if plan_e.decision == "accept" and not plan_e.working:
            block = proposal_by_key.get(_normalise_exercise(plan_e.exercise), "")
            _fill_sets_from_block(plan_e, block)
        exercises.append(plan_e)
    return SessionPlan(opening=str(raw.get("opening") or "").strip(), exercises=exercises,
                       carried=[str(c) for c in raw.get("carried") or []])


def _rest_seconds(text) -> int:
    """"2min" / "90s" / "1min30" as the parser hands them -> seconds."""
    t = str(text or "").strip().lower()
    m = re.match(r"^(\d+)\s*min(?:\s*(\d+)\s*s?)?$", t)
    if m:
        return int(m.group(1)) * 60 + int(m.group(2) or 0)
    m = re.match(r"^(\d+)\s*s(?:ec)?$", t)
    if m:
        return int(m.group(1))
    return 0


def _fill_sets_from_block(e: ExercisePlan, block: str) -> bool:
    """The programme's rendered block -> this exercise's sets. False when
    the block has no working set to give."""
    parsed = _proposal_numbers(block)
    if not parsed.get("working"):
        return False

    def sets(rows):
        return [SetPlan(float(r.get("weight") or 0), int(r.get("reps") or 0),
                        int(r.get("reps_high") or r.get("reps") or 0), float(r.get("rpe") or 0))
                for r in rows or []]
    e.working = sets(parsed.get("working"))
    e.backoff = sets(parsed.get("backoff"))
    if not e.warmup:
        e.warmup = [(float(w.get("weight") or 0), int(w.get("reps") or 0)) for w in parsed.get("warmup") or []]
    if not e.tempo and parsed.get("tempo"):
        e.tempo = str(parsed["tempo"])
    if not e.note and parsed.get("note"):
        e.note = str(parsed["note"])
    if not e.rest_seconds:
        from prescribe import REST_SECONDS, classify  # local: keeps import order flat
        e.rest_seconds = _rest_seconds(parsed.get("rest")) or REST_SECONDS[classify(e.exercise)]
    return True


def fill_from_programme(plan: SessionPlan, problems: list[str], session_type: str, prompt: str,
                        proposal: dict | None, week: int | None = None) -> tuple[SessionPlan, list[str], list[str]]:
    """Replace every exercise a problem names with the programme's own, and
    add any template exercise the plan left out.

    This is the fallback for an invalid plan. It used to be the PROSE reply:
    the whole opening thrown away, a second slow call, and blocks written
    freehand by the model with none of these checks — which is how a Leg
    Press opened at 207.5kg the week after 230kg x12 @7. Now the coach's
    valid decisions stand, the invalid ones become the programme's default
    with the failed rule as their reason, and the athlete is told which.

    Returns (plan, remaining problems, names filled).
    """
    proposal_by_key = {_normalise_exercise(k): v for k, v in (proposal or {}).items()}
    if not proposal_by_key:
        return plan, problems, []
    bad_keys = set()
    reasons: dict = {}
    for text in problems:
        name, sep, rest = text.partition(":")
        if sep:
            key = _normalise_exercise(name.strip())
            bad_keys.add(key)
            reasons.setdefault(key, rest.strip())
    pairs, _total = parse_session_template(prompt, session_type, week)
    template_keys = [_normalise_exercise(n) for n, _ in pairs if not _WEAK_POINT_SLOT_RE.match(n)]

    kept = []
    filled: list[str] = []
    present = set()
    for e in plan.exercises:
        key = _normalise_exercise(e.exercise)
        if key not in bad_keys:
            kept.append(e); present.add(key); continue
        block = proposal_by_key.get(key) or next(
            (v for k, v in proposal_by_key.items() if _match_template_key(k, {key: 1}) or _match_template_key(key, {k: 1})), "")
        replacement = ExercisePlan(exercise=e.exercise, decision="accept",
                                   reason=f"programme default — the coach's plan for this lift broke a rule ({reasons.get(key, 'see log')})",
                                   tempo=e.tempo, rest_seconds=e.rest_seconds, form_cue=e.form_cue, note=e.note)
        if _fill_sets_from_block(replacement, block):
            kept.append(replacement); present.add(key); filled.append(e.exercise)
        # A slot fill or substitution with no programme block simply drops:
        # the template exercises below cover the day.
    for key in template_keys:
        if key in present or _match_template_key(key, {k: 1 for k in present}):
            continue
        block = proposal_by_key.get(key, "")
        name = next(n for n, _ in pairs if _normalise_exercise(n) == key)
        added = ExercisePlan(exercise=name, decision="accept",
                             reason="programme default — missing from the coach's plan")
        if _fill_sets_from_block(added, block):
            kept.append(added); present.add(key); filled.append(name)
    plan.exercises = kept
    return plan, validate(plan, session_type, prompt, proposal, week=week), filled


# ── Checking the plan against the athlete's rules ────────────────────────────

# What a load cut below the programme has to be able to point at. A Leg
# Press opened 10% under the programme with "hold last week's loads" as the
# reason — a rule misapplied to the wrong week, not a cause. Cutting load is
# coaching when it names the recovery reading, the joint, the equipment or
# the clock; without one of those it is a number nobody decided.
_CAUSE_RE = re.compile(
    r"pain|hurt|injur|sore|tight|niggl|tweak|recover|hrv|sleep|fatigue|tired|rhr|resting heart|"
    r"machine|increment|stack|pin|plate|step|available|busy|occupied|taken|time|late|minutes|"
    r"deload|sick|ill\b|unwell|travel|jet ?lag|form|technique|grip|belt|spotter|ramp|feel-?out|"
    r"no (?:logged )?history|first session|new (?:movement|exercise)",
    re.IGNORECASE)


# An accept on a two-miss trend needs a reason that speaks to it: the trend
# itself, the range, or a cause that holds the number today.
_OUTCOME_RE = re.compile(r"light|heavy|range|reps|outcome|hold|stand|niggl|pain|hurt|sore|recover|hrv|sleep|"
                         r"joint|form|technique|step|stack|machine|first|warm", re.IGNORECASE)


# A problem the coach is ASKED about, never overruled on. The cause rule is
# the one judgement call in validate: a cut below the programme is coaching
# when the coach can say why, and the code cannot know every why. So it is
# handed back once for the cause; if the coach stands by the cut, the cut
# stands and the log records that no cause was given. Quality of coaching
# outranks tidiness of the rulebook.
SOFT = " [soft]"


def is_soft(problem: str) -> bool:
    return problem.endswith(SOFT)


def _is_straight(exercise: str, sets: int) -> bool:
    return _set_shape(exercise, sets).startswith(f"{sets} straight")


def _proposal_numbers(block: str) -> dict:
    """The programme's rendered block -> {working: [...], backoff: [...]}, by
    the same parser the card uses, so 'accept' is compared like for like."""
    from coach_parsing import parse_all_prescriptions
    parsed = parse_all_prescriptions(block or "")
    return parsed[0] if parsed else {}


def _same_set(spec: SetPlan, parsed: dict) -> bool:
    return (abs(spec.load_kg - float(parsed.get("weight") or 0)) < 1e-6
            and spec.reps_low == parsed.get("reps")
            and spec.reps_high == parsed.get("reps_high", parsed.get("reps"))
            and abs(spec.rpe - float(parsed.get("rpe") or 0)) < 1e-6)


def _backoff_problems(e: ExercisePlan) -> list[str]:
    """The rules a back-off must obey, wherever the exercise came from.

    A back-off is lighter than the top set and easier than it — that is what
    the word means (:64, :66). The first live weak-point fill went out as
    105kg x11 @8 with back-offs of 105kg x10 @8 and 105kg x9 @8: same load,
    same RPE, three top sets in a row. The slot path had checked only that
    the back-offs matched each other.
    """
    out: list[str] = []
    if not e.working or not e.backoff:
        return out
    top = e.working[0]
    if len({b.load_kg for b in e.backoff}) > 1:
        out.append(f"{e.exercise}: both back-offs at the SAME load.")
    if len(e.backoff) > 1 and e.backoff[1].reps_low >= e.backoff[0].reps_low:
        out.append(f"{e.exercise}: the second back-off carries fewer reps than the first.")
    if not is_bodyweight(e.exercise):
        if top.load_kg > 0 and e.backoff[0].load_kg >= top.load_kg:
            out.append(f"{e.exercise}: a back-off is LIGHTER than the top set — {e.backoff[0].load_kg:g}kg "
                       f"against a top set of {top.load_kg:g}kg is not a back-off. Drop 15-25%.")
        elif top.load_kg > 0:
            drop = 1 - e.backoff[0].load_kg / top.load_kg
            outside = 0.0 if 0.15 <= drop <= 0.25 else min(abs(drop - 0.15), abs(drop - 0.25))
            if outside * top.load_kg > 2.5:
                out.append(f"{e.exercise}: back-off {drop:.0%} below the top set; the band is 15-25%.")
    for b in e.backoff:
        if b.rpe >= top.rpe:
            out.append(f"{e.exercise}: a back-off targets a LOWER RPE than the top set "
                       f"(top RPE{top.rpe:g}, back-off RPE{b.rpe:g}); the wave puts it one point under.")
            break
    return out


def rest_floor(plan: SessionPlan) -> list[str]:
    """Rest is the programme's number, not the coach's (C13, 26 Sep 2026):
    the first Pull after the 3-minute rest merged showed a 2:00 timer,
    because the coach's plan JSON carries `rest_seconds` and nothing held
    it to the kind's floor. A coach may rest LONGER (a heavy top set), never
    shorter. Returns one note per exercise raised."""
    from prescribe import REST_SECONDS, classify  # local: keeps import order flat
    notes = []
    for e in plan.exercises:
        floor = REST_SECONDS[classify(e.exercise)]
        if (e.rest_seconds or 0) < floor:
            notes.append(f"{e.exercise}: rest {e.rest_seconds or 0}s raised to the programme's {floor}s")
            e.rest_seconds = floor
    return notes


def validate(plan: SessionPlan, session_type: str, prompt: str,
             proposal: dict | None = None, weak_points: list | None = None,
             ceilings: dict | None = None, steps: dict | None = None,
             week: int | None = None, verdicts: dict | None = None) -> list[str]:
    """Every way the plan breaks the programme, as sentences the model can act on.

    Mechanical rules only — set counts from the template, the shape of the
    back-offs, sane ranges — plus one honesty rule: an exercise marked
    'accept' must carry the programme's numbers, and one marked 'adjust'
    must say why. Nothing here judges whether a departure is wise; that is
    the coach's job, and the reason field is where it is done.
    """
    problems: list[str] = []
    pairs, _total = parse_session_template(prompt, session_type, week)
    # The Cardio+Abs template carries two placeholder slots — "Weak-Point
    # Exercise 1/2", 3 sets each — filled at prescription time with a real
    # movement for the two lowest muscles. A slot is satisfied by any exercise
    # not otherwise in the template that carries 3 sets, in either shape.
    slots = [(n, c) for n, c in pairs if _WEAK_POINT_SLOT_RE.match(n)]
    # The block decides how many slots are live: None means it could not be
    # placed (fill both from the readout); a list means exactly that many.
    live_slots = len(slots) if weak_points is None else min(len(slots), len(weak_points))
    expected = {_normalise_exercise(n): c for n, c in pairs if not _WEAK_POINT_SLOT_RE.match(n)}
    seen: dict = {}
    filled_slots = 0
    proposal = proposal or {}
    proposal_by_key = {_normalise_exercise(k): v for k, v in proposal.items()}
    rest_floor(plan)

    for e in plan.exercises:
        key = _normalise_exercise(e.exercise)
        target = expected.get(key)
        if target is None:
            target = _match_template_key(key, expected)
        slot_fill = False
        if target is None and filled_slots < len(slots):
            slot_fill = True
            e.slot_fill = True
            filled_slots += 1
            target = slots[filled_slots - 1][1]
            if weak_points is not None and filled_slots > live_slots and e.decision != "adjust":
                problems.append(f"{e.exercise}: this block names {'no' if not weak_points else 'one'} "
                                f"weak point, so this slot stays empty unless marked adjust with the reason.")
            if len(e.reason) < 20:
                problems.append(f"{e.exercise}: a weak-point slot — say which muscle it serves and why.")
            if weak_points:
                from weakpoints import primary_muscle  # local: keeps import order flat
                served = primary_muscle(e.exercise)
                if served and served not in weak_points and e.decision != "adjust":
                    problems.append(f"{e.exercise}: serves {served}, but this block's weak points are "
                                    f"{' and '.join(weak_points)}. Use one of those, or mark adjust and say why.")
            if len(e.working) + len(e.backoff) != target:
                problems.append(f"{e.exercise}: a weak-point slot is {target} sets, in either shape.")
        elif target is None:
            if e.decision != "adjust" or len(e.reason) < 20:
                problems.append(f"{e.exercise}: not in today's template; a substitution must be "
                                f"marked adjust with the reason.")
            target = len(e.working) + len(e.backoff) or 1
        if key in seen:
            problems.append(f"{e.exercise}: listed twice.")
        seen[key] = True

        if e.decision not in ("accept", "adjust"):
            problems.append(f"{e.exercise}: decision must be accept or adjust.")
        if e.decision == "adjust" and len(e.reason) < 20:
            problems.append(f"{e.exercise}: marked adjust without a reason the athlete can read.")

        for s in e.working + e.backoff:
            if not (1 <= s.reps_low <= s.reps_high <= 30):
                problems.append(f"{e.exercise}: reps {s.reps_low}-{s.reps_high} are not a real target.")
            if not (5 <= s.rpe <= 10):
                problems.append(f"{e.exercise}: RPE {s.rpe:g} is outside 5-10.")
            if s.load_kg < 0:
                problems.append(f"{e.exercise}: negative load.")
        for load, reps in e.warmup:
            if load < 0 or not (1 <= reps <= 30):
                problems.append(f"{e.exercise}: a warm-up set is malformed.")
        if not e.working:
            problems.append(f"{e.exercise}: no working set.")
            continue

        if slot_fill:
            if len(e.working) > 1 and e.backoff:
                problems.append(f"{e.exercise}: either straight sets or one top set with back-offs, not both.")
            if len(e.working) > 1 and len({s.load_kg for s in e.working}) > 1:
                problems.append(f"{e.exercise}: straight sets sit at ONE load.")
            problems.extend(_backoff_problems(e))
        elif _is_straight(e.exercise, target):
            if e.backoff:
                problems.append(f"{e.exercise}: ab work is straight sets — no back-off line.")
            if len(e.working) != target:
                problems.append(f"{e.exercise}: {len(e.working)} sets against a template of {target}, "
                                f"all on the Working Set line.")
            if len({s.load_kg for s in e.working}) > 1:
                problems.append(f"{e.exercise}: straight sets sit at ONE load.")
        else:
            if len(e.working) != 1:
                problems.append(f"{e.exercise}: exactly one top set on the Working Set line; the rest are back-offs.")
            if len(e.working) + len(e.backoff) != target:
                problems.append(f"{e.exercise}: {len(e.working) + len(e.backoff)} working sets against a "
                                f"template of {target} (1 top set + {target - 1} back-off"
                                f"{'s' if target - 1 != 1 else ''}).")
            problems.extend(_backoff_problems(e))

        if ceilings:
            from prescribe import norm_name  # local: keeps import order flat
            cap = {norm_name(k): v for k, v in ceilings.items()}.get(norm_name(e.exercise))
            if cap is not None:
                over = [s for s in e.working + e.backoff if s.load_kg > cap + 1e-6]
                if over:
                    problems.append(f"{e.exercise}: {over[0].load_kg:g}kg is over the standing ceiling of "
                                    f"{cap:g}kg you recorded for this machine — progress by reps and tempo "
                                    f"at {cap:g}kg, or clear the decision if the machine has changed.")
        computed = _proposal_numbers(proposal_by_key.get(key, ""))
        if e.decision == "adjust" and computed.get("working") and e.working:
            # An "adjust" that carries the programme's own numbers is an
            # accept with a comment. Left as adjust it inflated the adjust
            # rate and the card showed "Coach changed 90kg x8-10 / 70kg
            # x10-12" over the programme's exact numbers (Lat Pulldown,
            # 26 Sep 2026, screenshot). The reason is kept as the note.
            same = _same_set(e.working[0], computed["working"][0]) and \
                len(e.backoff) == len(computed.get("backoff", [])) and \
                all(_same_set(b, c) for b, c in zip(e.backoff, computed.get("backoff", [])))
            if same:
                e.decision = "accept"
                if e.reason and not e.note:
                    e.note = e.reason
        if e.decision == "adjust" and computed.get("working") and e.working:
            programme_top = float(computed["working"][0].get("weight") or 0)
            if programme_top > 0 and e.working[0].load_kg < programme_top * 0.95 \
                    and not _CAUSE_RE.search(e.reason):
                problems.append(f"{e.exercise}: today's top set ({e.working[0].load_kg:g}kg) is under the "
                                f"programme's ({programme_top:g}kg) and the reason names no cause — say the "
                                f"recovery reading, the joint, the machine's step or the time that drove it, "
                                f"or accept the programme's number.{SOFT}")
        if e.decision == "adjust" and computed.get("working") and e.working:
            # The mirror of the cut: a reach ABOVE the programme is at most one
            # step of the lift. The pre-flight holds the programme's own jumps
            # to this; the coach's were unbounded, and on 22 Sep 2026 it put
            # the Machine Chest Press at 168kg against the programme's ~152
            # (149 x11 the block before): 165 x5 @9, under the range. Not
            # soft — no cause makes a bigger jump right; a set that turns out
            # easy moves the card through the set reply.
            from prescribe import INCREMENT, classify  # local: keeps import order flat
            programme_top = float(computed["working"][0].get("weight") or 0)
            step = lift_step(steps, e.exercise) or 0.0
            allowance = max(2 * INCREMENT[classify(e.exercise)], step, 2.5)  # one cable step at least
            if programme_top > 0 and e.working[0].load_kg > programme_top + allowance + 1e-6:
                problems.append(f"{e.exercise}: today's top set ({e.working[0].load_kg:g}kg) is "
                                f"{e.working[0].load_kg - programme_top:g}kg over the programme's ({programme_top:g}kg), "
                                f"more than one step up ({allowance:g}kg) — the programme's number stands; if the "
                                f"set proves easy the card moves through the set reply.")
        if e.decision == "accept" and verdicts and not _OUTCOME_RE.search(e.reason or ""):
            # An unexamined accept on a lift whose last two outcomes agreed on
            # a miss. The coach rubber-stamped 94% of decisions in the 3-19
            # Sep block while the programme ran light 15 times; the outcomes
            # block shows it the trend, and this asks it to act or say why not.
            import scorecard  # local: keeps import order flat
            miss = scorecard.last_two_missed(verdicts, e.exercise)
            if miss:
                problems.append(f"{e.exercise}: the last two sessions came in {miss.upper()} on this number "
                                f"(see OUTCOMES) — adjust {'up' if miss == 'light' else 'down'} with the reason, "
                                f"or keep accept and give the reason it should stand today.{SOFT}")
        if e.decision == "accept" and computed.get("working"):
            same = _same_set(e.working[0], computed["working"][0]) and \
                len(e.backoff) == len(computed.get("backoff", [])) and \
                all(_same_set(b, c) for b, c in zip(e.backoff, computed.get("backoff", [])))
            if not same:
                problems.append(f"{e.exercise}: marked accept but the numbers differ from the "
                                f"programme's proposal — either use its numbers or mark adjust and say why.")

    for key, count in expected.items():
        if key not in seen and not any(_match_template_key(key, {k: 1 for k in seen}) for _ in [0]):
            name = next(n for n, _ in pairs if _normalise_exercise(n) == key)
            problems.append(f"{name}: in today's template but missing from the plan. Include it, "
                            f"or replace it with a substitution marked adjust and say why.")
    # An unfilled slot is a problem only when the block has NAMED a muscle
    # for it. A block that could not be placed, or names none, leaves the
    # slots empty: on the current templates no muscle is under its band, so
    # an empty slot is the normal day, not a gap to invent a lift for.
    if weak_points and filled_slots < live_slots:
        which = " and ".join(weak_points)
        problems.append(f"{live_slots - filled_slots} weak-point slot(s) unfilled: {slots[0][1]} sets "
                        f"each, for {which}, named as real movements.")
    return problems


# ── Rendering the plan as the card's text ────────────────────────────────────

def _load(spec_load: float, exercise: str) -> str:
    if is_bodyweight(exercise):
        return "BW" if not spec_load else f"BW + {spec_load:g}kg"
    return f"{spec_load:g}kg"


def _reps(s: SetPlan) -> str:
    return f"x{s.reps_low}" if s.reps_low == s.reps_high else f"x{s.reps_low}-{s.reps_high}"


def _rest(seconds: int) -> str:
    if seconds <= 0:
        return "2min"
    return f"{seconds // 60}min" if seconds % 60 == 0 else f"{seconds}s"


def _shape_summary(working: list, backoff: list) -> str:
    """"95kg x8-12 RPE8 + 2 back-offs" or "3 × 95kg x8-12 RPE8" from parsed or planned sets."""
    if not working:
        return "nothing"
    top = working[0]
    load = top.get("weight") if isinstance(top, dict) else top.load_kg
    low = top.get("reps") if isinstance(top, dict) else top.reps_low
    high = (top.get("reps_high", low) if isinstance(top, dict) else top.reps_high)
    rpe = top.get("rpe") if isinstance(top, dict) else top.rpe
    reps = f"x{low}" if high in (None, low) else f"x{low}-{high}"
    rpe_s = f" RPE{float(rpe):g}" if rpe is not None else ""
    load_s = f"{float(load or 0):g}kg"
    if len(working) > 1:
        return f"{len(working)} × {load_s} {reps}{rpe_s}"
    if backoff:
        return f"{load_s} {reps}{rpe_s} + {len(backoff)} back-off{'s' if len(backoff) != 1 else ''}"
    return f"{load_s} {reps}{rpe_s}"


def _delta(e: ExercisePlan, proposal_block: str) -> str:
    """"programme 95kg x8-12 RPE8 + 2 back-offs → today 3 × 100kg x9 RPE8"."""
    computed = _proposal_numbers(proposal_block)
    if not computed.get("working"):
        return ""
    before = _shape_summary(computed["working"], computed.get("backoff") or [])
    after = _shape_summary(e.working, e.backoff)
    return f"programme {before} → today {after}"


def render_exercise(e: ExercisePlan, proposal_block: str = "") -> str:
    lines = [f"*{e.exercise}*"]
    if e.warmup:
        lines.append("Warm-up: " + ", ".join(f"{_load(l, e.exercise)} x{r}" for l, r in e.warmup))
    working = ", ".join(f"{_load(s.load_kg, e.exercise)} {_reps(s)} RPE{s.rpe:g}" for s in e.working)
    tempo = f" | Tempo: {e.tempo}" if e.tempo else ""
    lines.append(f"Working Set: {working}{tempo} | Rest: {_rest(e.rest_seconds)}")
    if e.backoff:
        lines.append("Back-off: " + ", ".join(
            f"{_load(s.load_kg, e.exercise)} {_reps(s)} RPE{s.rpe:g}" for s in e.backoff))
    if e.form_cue:
        lines.append(f"Form: {e.form_cue}")
    # The reason travels WITH the exercise, on its own prefixed line, so the
    # card shows it under the lift it belongs to when that lift is up — not
    # six reasons at once in the opening note. A slot fill is the programme
    # asking for a movement, not a departure from it, and is labelled so.
    # The numbers come from the code, so the change is never vague: what the
    # programme proposed, what today is, then the coach's one-line cause.
    if e.slot_fill and e.reason:
        lines.append(f"Why: Weak-point slot — {e.reason}")
    elif e.decision == "adjust" and e.reason:
        delta = _delta(e, proposal_block)
        lines.append(f"Why: Changed from the programme ({delta}) — {e.reason}" if delta
                     else f"Why: Changed from the programme — {e.reason}")
    # Prefixed, so the card keeps it with the lift. Unprefixed, the parser
    # took the block and left the note behind as prose: six "Week 2 volume
    # step: ..." paragraphs stacked in the opening with no exercise named.
    if e.note:
        lines.append(f"Note: {e.note}")
    return "\n".join(lines)


def render_plan(plan: SessionPlan, proposal: dict | None = None) -> str:
    """The reply the athlete reads and the card parses. Narrative first, then
    every exercise as a block in the exact format the parser expects."""
    proposal_by_key = {_normalise_exercise(k): v for k, v in (proposal or {}).items()}
    parts = []
    if plan.opening:
        parts.append(plan.opening)
    if plan.carried:
        parts.append("Still in force from earlier sessions: " + " ".join(plan.carried))
    parts.extend(render_exercise(e, proposal_by_key.get(_normalise_exercise(e.exercise), ""))
                 for e in plan.exercises)
    return "\n\n".join(parts)


# ── The call ─────────────────────────────────────────────────────────────────

MODEL = "claude-sonnet-5"

PLAN_INSTRUCTION = """
You are opening today's {session_type} session, week {week} ({phase}). Return the
session as the PLAN object described by the schema, not as prose with numbers in it.

How to fill it:
- The PROGRAMME PROPOSAL in your context is the default for every exercise. For each
  one decide: `accept` it as it stands, or `adjust` it. Adjusting is coaching, not an
  exception — do it whenever what you know about him warrants it: the machine's real
  increments, how the last session actually went, recovery, a joint that is unhappy,
  a decision you made on an earlier day that still applies. When you adjust, `reason`
  is the sentence he will read and the one you will be held to later. When you accept,
  `reason` names the rule briefly.
- `working` holds ONE top set for top-set/back-off exercises, and EVERY set for
  straight-set work — ab work and the calf raise — with no back-off there. The
  template's set counts and shapes are facts; the numbers inside them are yours.
- Be specific. A reason names the set, the reading or the machine that drove it.
  "Straight sets, not top+back-off" is not a reason — the shape is the template's.
- `opening` is your voice: recovery read, what today is for, anything carried over.
  `carried` restates earlier decisions still in force (from DECISIONS IN FORCE).
- Use the template's exercise names. A substitution is an `adjust` with its reason.
{day_note}
""".strip()

CARDIO_ABS_NOTE = """
- Cardio+Abs: whether cardio is done is a FACT stated in the LIVE WORKOUT block's
  "Cardio logged this session" line and in the message. The Apple Watch export feed
  lags and does not count. If cardio is in, say so and move on; if it is genuinely not,
  its instruction goes in `opening` as prose — never as a prescription block.
  This plan is the AB block, plus ONE weak-point slot ONLY for the muscle THIS BLOCK'S
  EMPHASIS names — 3 straight sets, a movement that loads it in a way the rotation does
  not, the muscle it serves in `reason`. When it names none, the plan is the ab block
  alone and the day ends there. Do not fill a slot from the rolling WEEKLY VOLUME readout.""".strip()


def _phase(week: int) -> str:
    return WAVE.get(week, {}).get("name", "")


# The app waits a bounded time for the opening reply. A first attempt that has
# already spent this long is not handed back for correction; the programme
# fills the invalid exercises instead.
PLAN_TIME_BUDGET_SECONDS = 30.0


def _usage_note(response) -> str:
    u = getattr(response, "usage", None)
    if not u:
        return ""
    parts = []
    for attr, label in (("input_tokens", "in"), ("cache_read_input_tokens", "cached"),
                        ("cache_creation_input_tokens", "cache-write"), ("output_tokens", "out")):
        v = getattr(u, attr, None)
        if v:
            parts.append(f"{label} {v}")
    return " · ".join(parts)


def request_session_plan(client, system_blocks: list, messages: list,
                         session_type: str, week: int, prompt: str,
                         proposal: dict | None = None, model: str = MODEL,
                         weak_points: list | None = None,
                         budget_seconds: float = PLAN_TIME_BUDGET_SECONDS,
                         ceilings: dict | None = None, steps: dict | None = None,
                         verdicts: dict | None = None) -> tuple:
    """Ask for the plan, check it, and make sure a plan comes back.

    Returns (plan, log_lines). `plan` is None only when the model's output
    could not be parsed at all AND the programme has nothing to fill from;
    the caller falls back to prose for that one case.

    Quality first, then speed. The opening plan once sat on a skeleton card
    for two minutes: thinking over a 30k-token context, a full-size retry,
    then the prose fallback, each generating ~2,500 tokens. Two things cut
    that without touching the coaching:

    - Accepts carry no numbers (parse_plan fills them), so the output is a
      fraction of its former size and the model's tokens go on decisions.
    - One correction round at most, and only inside the budget. An exercise
      still invalid after that becomes the programme's default, named as
      such — never a second slow call, never freehand prose.

    Extended thinking stays ON. Weighing a day against the athlete's history,
    recovery and earlier decisions is exactly what deliberation is for, and
    the athlete has said quality outranks latency. It was removed for a day
    and put back on that instruction. max_tokens caps thinking and output
    together; with accepts terse, 8000 leaves most of it for the think.

    Problems marked soft (is_soft) are put to the coach once and never
    overrule it: a cut below the programme without a named cause is queried,
    and if the coach stands by it, it stands.
    """
    import time
    notes: list[str] = []
    instruction = PLAN_INSTRUCTION.format(
        session_type=session_type, week=week, phase=_phase(week),
        day_note=CARDIO_ABS_NOTE if session_type == "Cardio+Abs" else "").strip()
    system = list(system_blocks) + [{"type": "text", "text": instruction}]
    turns = list(messages)
    started = time.monotonic()
    _prev = 0.0

    plan = None
    problems: list[str] = []
    for attempt in (1, 2):
        response = client.messages.create(
            model=model,
            max_tokens=8000,
            thinking={"type": "adaptive"},
            output_config={"format": {"type": "json_schema", "schema": PLAN_SCHEMA},
                           "effort": "medium" if attempt == 1 else "low"},
            system=system,
            messages=turns,
        )
        elapsed = time.monotonic() - started
        usage = _usage_note(response)
        notes.append(f"attempt {attempt}: {elapsed:.1f}s" + (f" ({usage})" if usage else ""))
        text = next((b.text for b in response.content if getattr(b, "type", "") == "text"), "")
        from usage import record_call  # local: keeps import order flat
        record_call("plan", elapsed if attempt == 1 else elapsed - _prev, response, attempt=attempt,
                    ok=bool(text) and getattr(response, "stop_reason", None) != "max_tokens",
                    note=f"{session_type} wk{week}", model=model)
        _prev = elapsed
        if getattr(response, "stop_reason", None) == "max_tokens" or not text:
            notes.append(f"attempt {attempt}: no complete plan returned")
            break
        try:
            plan = parse_plan(text, proposal)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            notes.append(f"attempt {attempt}: plan did not parse ({exc})")
            plan = None
            break
        problems = validate(plan, session_type, prompt, proposal, weak_points, ceilings, steps, week, verdicts)
        if not problems:
            notes.append(f"attempt {attempt}: plan accepted")
            return plan, notes
        notes.append(f"attempt {attempt}: " + " | ".join(problems))
        if all(is_soft(x) for x in problems) and attempt == 2:
            # Asked, answered, and the coach stands by it: its call.
            notes.append("coach's call stands: " + " | ".join(x[:-len(SOFT)] for x in problems))
            return plan, notes
        if attempt == 2:
            break
        if elapsed > budget_seconds:
            notes.append(f"no retry: {elapsed:.0f}s already spent against a {budget_seconds:.0f}s budget")
            break
        # The model corrects its own plan. The code never edits a number.
        turns = turns + [
            {"role": "assistant", "content": text},
            {"role": "user", "content": "Your plan breaks these rules of the programme:\n- "
                                        + "\n- ".join(problems)
                                        + "\nReturn the corrected plan. Keep every decision you "
                                          "still stand behind and its reason."},
        ]

    # The programme stands in for what the coach got wrong, or for all of it.
    # Soft problems are the coach's to keep: they never send a lift to the fill.
    if plan is None:
        plan = SessionPlan(opening="", exercises=[])
        problems = validate(plan, session_type, prompt, proposal, weak_points, ceilings, steps, week, verdicts)
    soft = [x for x in problems if is_soft(x)]
    if soft:
        notes.append("coach's call stands: " + " | ".join(x[:-len(SOFT)] for x in soft))
    plan, remaining, filled = fill_from_programme(plan, [x for x in problems if not is_soft(x)],
                                                  session_type, prompt, proposal)
    remaining = [x for x in remaining if not is_soft(x)]
    if filled:
        notes.append("filled from programme: " + ", ".join(filled))
        plan.carried = list(plan.carried) + [
            f"The programme's numbers stand for {', '.join(filled)}; the coach's plan for "
            f"{'it' if len(filled) == 1 else 'them'} broke a rule and was set aside."]
    if remaining:
        notes.append("still invalid after programme fill: " + " | ".join(remaining))
        return None, notes
    if not plan.exercises:
        notes.append("no plan and nothing to fill from")
        return None, notes
    return plan, notes


# ── The decision log ─────────────────────────────────────────────────────────

def save_decisions(plan: SessionPlan, session_type: str, week: int,
                   session_id: str | None = None, proposal: dict | None = None) -> int:
    """Write every exercise's decision and reason, with the PROGRAMME's top
    set beside the coach's (migration 015) so the scorecard can judge an
    adjust against what it departed from. Returns rows written; a missing
    table or a failed write costs a log line, never the reply."""
    supabase = get_supabase()
    if not supabase:
        return 0
    today = now_local().strftime("%Y-%m-%d")
    proposal_by_key = {_normalise_exercise(k): v for k, v in (proposal or {}).items()}
    rows = []
    for e in plan.exercises:
        top = e.working[0] if e.working else None
        computed = _proposal_numbers(proposal_by_key.get(_normalise_exercise(e.exercise), "")) if proposal_by_key else {}
        prog = (computed.get("working") or [{}])[0] if computed else {}
        rows.append({
            "date": today,
            "session_id": session_id or None,
            "session_type": session_type,
            "mesocycle_week": week,
            "exercise": e.exercise,
            "decision": e.decision,
            "reason": e.reason,
            "top_load_kg": top.load_kg if top else None,
            "top_reps": top.reps_low if top else None,
            "top_rpe": top.rpe if top else None,
            "programme_load_kg": _as_float_or_none(prog.get("weight")) if prog else None,
            "programme_reps_low": prog.get("reps") if prog else None,
            "programme_reps_high": prog.get("reps_high", prog.get("reps")) if prog else None,
            "programme_rpe": _as_float_or_none(prog.get("rpe")) if prog else None,
            "plan": json.dumps({
                "warmup": e.warmup,
                "working": [s.__dict__ for s in e.working],
                "backoff": [s.__dict__ for s in e.backoff],
                "tempo": e.tempo, "rest_seconds": e.rest_seconds,
            }),
        })
    try:
        supabase.table("prescription_decisions").insert(rows).execute()
        return len(rows)
    except Exception:
        # A store without migration 015 rejects the programme_* columns; the
        # decision is worth more than the comparison.
        try:
            stripped = [{k: v for k, v in r.items() if not k.startswith("programme_")} for r in rows]
            supabase.table("prescription_decisions").insert(stripped).execute()
            log.warning("prescription_decisions has no programme_* columns (migration 015?); stored without them")
            return len(stripped)
        except Exception:
            log.exception("Could not store the session's decisions")
        return 0


def load_recent_decisions(days: int = 21) -> list[dict]:
    """Departures from the programme in the window, newest first."""
    supabase = get_supabase()
    if not supabase:
        return []
    since = (now_local().date() - timedelta(days=days)).isoformat()
    try:
        rows = (
            supabase.table("prescription_decisions")
            .select("date, session_type, mesocycle_week, exercise, decision, reason, top_load_kg, top_reps, top_rpe")
            .gte("date", since)
            .eq("decision", "adjust")
            .order("date", desc=True)
            .limit(40)
            .execute()
        ).data or []
    except Exception:
        log.warning("Could not read earlier decisions")
        return []
    return rows


def format_decisions(rows: list[dict]) -> str:
    """The block the coach reads before it prescribes, and when it is asked why."""
    if not rows:
        return ("\nDECISIONS IN FORCE — departures from the programme you made in the last "
                "three weeks, with the reason you gave. None recorded.\n")
    lines = ["\nDECISIONS IN FORCE — departures from the programme you made in the last "
             "three weeks, with the reason you gave. When he asks why a number is what it "
             "is, this is the answer; do not invent another. Restate any that still apply "
             "today, or say plainly that it no longer does and why."]
    for r in rows:
        top = ""
        if r.get("top_load_kg") is not None:
            top = f" ({r['top_load_kg']:g}kg x{r.get('top_reps')} @{r.get('top_rpe'):g})"
        lines.append(f"- {r.get('date')} {r.get('session_type')} wk{r.get('mesocycle_week')} · "
                     f"{r.get('exercise')}{top}: {r.get('reason')}")
    return "\n".join(lines) + "\n"


_PLAN_REQUEST_RE = re.compile(
    r"^\s*(starting (my|the)|resend today'?s|resuming my|i'?ve finished cardio|starting (pull|push|legs|cardio)\b|start(ing)? workout|let'?s train)",
    re.IGNORECASE)


def is_plan_request(text: str, session_type: str) -> bool:
    """A session-opening message on a strength day: the one reply that is a
    whole plan rather than a conversation."""
    return session_type in PLAN_DAYS and bool(_PLAN_REQUEST_RE.match(text or ""))


# ── Mid-session: the reply to a logged set ───────────────────────────────────
#
# The opening plan put every number on the card through the contract, and
# then the first logged set broke it: the coach wrote "Next set: 100kg x12" as
# prose and the card kept 97.5 x 9. The first repair let the coach return the
# next set as free numbers and policed them with bounds — and a ramp single
# (95kg x3 @6) walked straight through the bounds and overwrote a top set.
#
# So the mid-session change is a DECISION, not a number. The coach picks a
# move from a small vocabulary — hold, a step lighter or heavier, a rep or two
# either way, a point easier or harder — and the programme computes the sets
# from the plan on the card. There is no move that turns a 108kg x10-12 @8 top
# set into a 95kg x3 @6 single, so there is nothing to police. The one exit is
# `revise`: free numbers, a stated reason, and a `Revised:` line the athlete
# sees, exactly as the prompt has always defined a deliberate departure.

SET_DECISIONS = ("hold", "lighter", "heavier", "fewer_reps", "more_reps", "easier", "harder", "revise")

SET_REPLY_SCHEMA = {
    "type": "object",
    "properties": {
        "note": {
            "type": "string",
            "description": "Your read on the set he just logged and the instruction for the next one: one "
                           "to three sentences, plain prose. Do not write numbers for the next set; the card "
                           "is computed from `decision`.",
        },
        "decision": {
            "type": "string", "enum": list(SET_DECISIONS),
            "description": "hold: the card stands. lighter/heavier: the load moves one or two steps. "
                           "fewer_reps/more_reps: the rep target moves one or two. easier/harder: the RPE "
                           "target moves a point, applied as the programme applies it (reps first). "
                           "revise: a deliberate departure — injury, machine in use — with `revised` filled "
                           "and `reason` stated.",
        },
        "steps": {"type": "integer", "description": "1 or 2. Ignored for hold and revise."},
        "scope": {"type": "string", "enum": ["next", "remaining"],
                  "description": "next: only the next set. remaining: every set left in this phase."},
        "reason": {"type": "string",
                   "description": "One sentence: the fact from the set he just did (or the reading, or the "
                                  "machine) that drove the decision. Empty for hold."},
        "revised": {
            "type": "object",
            "properties": {"load_kg": {"type": "number"}, "reps_low": {"type": "integer"},
                           "reps_high": {"type": "integer"}, "rpe": {"type": "number"}},
            "required": ["load_kg", "reps_low", "reps_high", "rpe"],
            "additionalProperties": False,
            "description": "Used only with decision = revise.",
        },
    },
    "required": ["note", "decision", "steps", "scope", "reason", "revised"],
    "additionalProperties": False,
}

SET_REPLY_INSTRUCTION = """
He has just logged a set of {exercise} (set {done} of {total} done). The card on his screen
for this exercise stands at: {card}. Those are the numbers in force — not what you wrote at
the opening, not what you suggested in prose since. Return the SET REPLY
object. `note` is your read and your instruction, in your voice. `decision` is what
happens to the next set: `hold` unless the set he just did gives you a reason — it came
in well under or over the target RPE, the reps fell short or flew past, the ramp said
the working weight is wrong. A step lighter or heavier, a rep or two, a point easier or
harder: pick the move and the size, and the programme computes the numbers. Say the
reason in `reason`. Use `revise` only for a genuine departure (pain, equipment) and fill
`revised` — it is shown to him as a revision. The card moves ONLY on `decision`: if your note
tells him to go heavier or lighter, `decision` is that move. The programme writes the new
numbers after your note, so never leave a change unsaid and never write the numbers yourself.
A set that beat the top of its range at or under its target RPE is already moved up by the
programme; say so in the note rather than asking for more reps at the same load.
""".strip()


def _same(a: str, b: str) -> bool:
    return _normalise_exercise(a) == _normalise_exercise(b)


def card_line(stored: dict | None) -> str:
    """The stored plan for one exercise as the card shows it: working sets,
    then back-offs. What the coach is told is in force."""
    if not stored or not stored.get("working"):
        return "no stored plan"
    def one(d: dict) -> str:
        sp = _as_set(d)
        reps = f"x{sp.reps_low}" + (f"-{sp.reps_high}" if sp.reps_high != sp.reps_low else "")
        return f"{sp.load_kg:g}kg {reps} @{sp.rpe:g}"
    working = ", ".join(one(d) for d in stored.get("working") or [])
    backoff = ", ".join(one(d) for d in stored.get("backoff") or [])
    return f"Working {working}" + (f" | Back-off {backoff}" if backoff else "")


def record_plan_update(e: ExercisePlan, session_type: str, week: int, reason: str,
                       session_id: str | None = None) -> bool:
    """Write the exercise's adapted plan as today's current plan.

    The card follows whatever block reaches it; until now the stored plan
    stayed at the opening's numbers, so the next set reply computed from
    stale sets, the coach was told a card that no longer existed, and the
    two drifted apart within a session. Decision `update` keeps these rows
    out of the opening statistics. Never raises."""
    supabase = get_supabase()
    if not supabase:
        return False
    top = e.working[0] if e.working else None
    try:
        supabase.table("prescription_decisions").insert({
            "date": now_local().strftime("%Y-%m-%d"),
            "session_id": session_id or None,
            "session_type": session_type,
            "mesocycle_week": week,
            "exercise": e.exercise,
            "decision": "update",
            "reason": reason[:500],
            "top_load_kg": top.load_kg if top else None,
            "top_reps": top.reps_low if top else None,
            "top_rpe": top.rpe if top else None,
            "plan": json.dumps({"warmup": e.warmup, "working": [x.__dict__ for x in e.working],
                                "backoff": [x.__dict__ for x in e.backoff],
                                "tempo": e.tempo, "rest_seconds": e.rest_seconds}),
        }).execute()
        log.info("PLAN UPDATED (%s): %s", e.exercise, reason[:120])
        return True
    except Exception:
        # Loud on purpose: a swallowed failure here left the stored plan at
        # the opening's numbers for five days (migration 012).
        log.exception("PLAN UPDATE NOT STORED (%s): the next set reply will compute from the old plan", e.exercise)
        return False


def _default_rest(exercise: str) -> int:
    """The kind's rest (prescribe.REST_SECONDS) when a block names none — C13."""
    from prescribe import REST_SECONDS, classify  # local: keeps import order flat
    return REST_SECONDS[classify(exercise)]


def plan_from_block(block: dict, stored: dict | None = None) -> ExercisePlan:
    """A parsed reply block (coach_parsing shape: weight/reps/reps_high/rpe)
    as an ExercisePlan, keeping the stored tempo and rest."""
    def rows(items):
        return [SetPlan(float(r.get("weight") or 0), int(r.get("reps") or 0),
                        int(r.get("reps_high") or r.get("reps") or 0), float(r.get("rpe") or 0))
                for r in items or []]
    return ExercisePlan(exercise=str(block.get("exercise") or ""), decision="adjust", reason="",
                        warmup=[(float(w.get("weight") or 0), int(w.get("reps") or 0)) for w in block.get("warmup") or []],
                        working=rows(block.get("working")), backoff=rows(block.get("backoff")),
                        tempo=str((stored or {}).get("tempo") or ""),
                        rest_seconds=int((stored or {}).get("rest_seconds") or 0) or _default_rest(str(block.get("exercise") or "")))


def block_differs(block: dict, stored: dict) -> bool:
    """Whether a reply block's working or back-off numbers differ from the
    stored plan's."""
    def norm_block(items):
        return [(float(r.get("weight") or 0), int(r.get("reps") or 0),
                 int(r.get("reps_high") or r.get("reps") or 0), float(r.get("rpe") or 0)) for r in items or []]
    def norm_stored(items):
        return [(sp.load_kg, sp.reps_low, sp.reps_high, sp.rpe) for sp in (_as_set(d) for d in items or [])]
    return (norm_block(block.get("working")) != norm_stored(stored.get("working"))
            or norm_block(block.get("backoff")) != norm_stored(stored.get("backoff")))


def load_today_plan(exercise: str) -> dict | None:
    """The stored plan for this exercise at today's opening: {working, backoff,
    tempo, rest_seconds} as SetPlan-shaped dicts, or None when the opening was
    not under the contract (then the reply stays prose)."""
    supabase = get_supabase()
    if not supabase:
        return None
    today = now_local().strftime("%Y-%m-%d")
    try:
        rows = (
            supabase.table("prescription_decisions")
            .select("exercise, plan, id")
            .eq("date", today)
            .order("id", desc=True)
            .execute()
        ).data or []
    except Exception:
        log.warning("Could not read today's plan for %s", exercise)
        return None
    for row in rows:
        if not _same(row.get("exercise") or "", exercise):
            continue
        detail = row.get("plan") or {}
        if isinstance(detail, str):
            try:
                detail = json.loads(detail)
            except ValueError:
                return None
        if detail.get("working"):
            return detail
    return None


_SET_COLUMNS = "exercise, is_warmup, actual_weight_kg, actual_reps, actual_rpe, set_number, created_at"


def latest_logged_sets(session_id: str | None, exercise: str) -> list[dict]:
    """This exercise's working sets logged against the session, in order,
    with the phase each was logged under when the row carries one."""
    supabase = get_supabase()
    if not supabase or not session_id:
        return []
    rows = None
    for columns in (_SET_COLUMNS + ", phase", _SET_COLUMNS):
        try:
            rows = (supabase.table("workout_sets").select(columns)
                    .eq("workout_session_id", session_id).execute()).data or []
            break
        except Exception:
            continue  # a store without the phase column (migration 014) still answers
    if rows is None:
        return []
    mine = [r for r in rows if _same(r.get("exercise") or "", exercise) and not r.get("is_warmup")]
    return sorted(mine, key=lambda r: (str(r.get("created_at") or ""), r.get("set_number") or 0))


def phase_counts(rows: list[dict], stored: dict) -> dict:
    """Working and back-off sets done, by the phase each row was logged
    under. Rows without a phase (before migration 014) fill the working
    slots first and the back-offs after, as position always had it."""
    n_working = len(stored.get("working") or [])
    counts = {"working": 0, "backoff": 0}
    unknown = 0
    for r in rows or []:
        ph = (r.get("phase") or "").lower()
        if ph in counts:
            counts[ph] += 1
        elif ph != "warmup":
            unknown += 1
    fill = min(unknown, max(0, n_working - counts["working"]))
    counts["working"] += fill
    counts["backoff"] += unknown - fill
    return counts


def next_set_index(rows: list[dict], stored: dict) -> int:
    """Position in the card's sequence of the next set to do: the first slot
    whose phase has not logged that many sets. A skipped working set no
    longer turns the first back-off into "working set 1"."""
    counts = phase_counts(rows, stored)
    sequence = _sequence(stored or {})
    for k, (ph, i) in enumerate(sequence):
        if i >= counts.get(ph, 0):
            return k
    return len(sequence)


def last_logged_slot(rows: list[dict], stored: dict) -> tuple | None:
    """(phase, index) of the most recent row, for the move it may owe."""
    if not rows:
        return None
    ph = (rows[-1].get("phase") or "").lower()
    if ph in ("working", "backoff"):
        return ph, sum(1 for r in rows if (r.get("phase") or "").lower() == ph) - 1
    # No phase on the row: position, as before.
    done = next_set_index(rows, stored)
    sequence = _sequence(stored or {})
    return sequence[done - 1] if 0 < done <= len(sequence) else None


def logged_sets_for(session_id: str, exercise: str) -> int:
    """Working (non-warm-up) sets of this exercise persisted against the session."""
    supabase = get_supabase()
    if not supabase or not session_id:
        return 0
    try:
        rows = (
            supabase.table("workout_sets")
            .select("exercise, is_warmup")
            .eq("workout_session_id", session_id)
            .execute()
        ).data or []
    except Exception:
        return 0
    return sum(1 for r in rows if _same(r.get("exercise") or "", exercise) and not r.get("is_warmup"))


def latest_exercise(session_id: str) -> str:
    """The exercise of the most recently logged set in the session."""
    supabase = get_supabase()
    if not supabase or not session_id:
        return ""
    try:
        rows = (
            supabase.table("workout_sets")
            .select("exercise, logged_at")
            .eq("workout_session_id", session_id)
            .order("logged_at", desc=True)
            .limit(1)
            .execute()
        ).data or []
    except Exception:
        return ""
    return (rows[0].get("exercise") or "") if rows else ""


def _as_set(d: dict) -> SetPlan:
    return SetPlan(float(d.get("load_kg", 0) or 0), int(d.get("reps_low", 1)), int(d.get("reps_high", 1)),
                   float(d.get("rpe", 8)))


def _known_step(grid: float | None) -> float | None:
    """The lift's own load step when the programme knows it. prescribe's
    default grid is the half-kilo, which means "the log could not tell", not
    a stack that moves in 0.5kg."""
    from prescribe import _LOAD_GRID
    return grid if grid and grid > _LOAD_GRID else None


def lift_step(steps: dict | None, exercise: str, aliases: dict | None = None) -> float | None:
    """The step coach_context computed for this lift (SetSpec.grid). `steps`
    is keyed by the template's name; `aliases` (logged spelling -> template
    name, coach_context's out["aliases"]) lets a plan stored as "Incline
    Barbell Press" meet the programme's "Incline Press"."""
    names = [exercise] + [t for logged, t in (aliases or {}).items() if _same(logged, exercise)]
    for name, grid in (steps or {}).items():
        if any(_same(name, n) for n in names):
            return _known_step(_as_float_or_none(grid))
    return None


def _load_step(exercise: str, load: float, grid: float | None = None) -> float:
    """One step for this movement: the programme's increment or the lift's
    own stack step, whichever is larger, or 5% of the load rounded to that
    step when that is larger still. Without the step a 125kg calf raise on a
    5kg stack was moved to 131kg (review of 23 Sep 2026)."""
    from prescribe import INCREMENT, _round_load, classify
    grid = _known_step(grid)
    base = max(INCREMENT[classify(exercise)], grid or 0.0)
    return max(base, _round_load(load * 0.05, grid))


def apply_set_decision(decision: str, steps: int, planned: SetPlan, exercise: str,
                       grid: float | None = None) -> SetPlan | None:
    """The programme's arithmetic for one move on one planned set.

    easier/harder follow :323 — a point of RPE at a fixed load is a rep; if
    that would leave under five reps, the reps hold and the load moves 7.5%.
    `grid` is the lift's own load step (stored["step"]) so every load lands on
    the stack. None when the decision is unknown.
    """
    from prescribe import DELOAD_MIN_REPS, _round_load, is_bodyweight
    grid = _known_step(grid)
    n = 1 if steps < 1 else min(int(steps), 2)
    low, high, load, rpe = planned.reps_low, planned.reps_high, planned.load_kg, planned.rpe
    if decision == "hold":
        return planned
    if decision in ("lighter", "heavier"):
        if is_bodyweight(exercise) and load <= 0 and decision == "lighter":
            return planned
        step = _load_step(exercise, load, grid) * n
        load = max(0.0, _round_load(load - step if decision == "lighter" else load + step, grid, load))
        return SetPlan(load, low, high, rpe)
    if decision in ("fewer_reps", "more_reps"):
        d = -n if decision == "fewer_reps" else n
        return SetPlan(load, max(1, low + d), max(1, high + d), rpe)
    if decision in ("easier", "harder"):
        d = -n if decision == "easier" else n
        new_rpe = min(10.0, max(5.0, rpe + d))
        if decision == "easier" and low - n < DELOAD_MIN_REPS:
            return SetPlan(_round_load(load * 0.925, grid, load) if load > 0 else load, low, high, new_rpe)
        return SetPlan(load, max(1, low + d), max(1, high + d), new_rpe)
    return None


# A set reply's note came back with word-pieces missing on 18 Sep — ", solid,
# thenring warm-.135kg for3 (RE 6.0.Rest 2min then Working Set: 240kg x12
# RPE6 | Rest:2min.Everything onined properly" — accepted, rendered, stored
# and shown. Nothing between the model and the card edits text, so the
# damage was in the constrained-output call itself. These are the marks such
# a note leaves; two of them and the note is sent back once, then the reply
# falls through to the prose call.
_GLUED_WORD_DIGIT_RE = re.compile(r"\b(?:for|at|to|of|then|and|with|by|on|in)\d")
_MISSING_SPACE_RE = re.compile(r"[a-z0-9]\.[A-Za-z]")
_BLOCK_IN_NOTE_RE = re.compile(r"(?i)\b(?:warm-?up|working set|back-?off)\s*:")


def note_damage(note: str) -> list[str]:
    """The marks of a note that lost characters on the way out; empty when
    the note reads as prose."""
    text = (note or "").strip()
    if not text:
        return []
    marks = []
    if text[0] in ",.;:)|":
        marks.append("starts with punctuation")
    if text.count("(") != text.count(")"):
        marks.append("unbalanced parentheses")
    if _GLUED_WORD_DIGIT_RE.search(text):
        marks.append("a word glued to a number")
    if len(_MISSING_SPACE_RE.findall(text)) >= 2:
        marks.append("sentences run together")
    if _BLOCK_IN_NOTE_RE.search(text):
        marks.append("a set line inside the note")
    return marks


def note_is_broken(note: str) -> bool:
    return len(note_damage(note)) >= 2


# An instruction to change the load, as the note words it. Reads of how a set
# felt ("felt heavier than Thursday") are not instructions and do not count.
# Explicit load words always count. A bare "up"/"down" ("take it up", "bring
# it down") counts only in a clause with no rep, RPE or range word: "take the
# next set up to 12 reps", "push it up to RPE 8", "bring the reps down to 8"
# and "move up to the top of the range" are rep and effort instructions, and
# reading them as load moves handed correct more_reps/harder/fewer_reps
# replies back to the model (review of 23 Sep 2026).
_NOTE_HEAVIER_RE = re.compile(
    r"\b(?:take|make|go|move|bump|put|load|push)\b[^.!?]{0,40}\b(?:heavier|up a (?:step|notch|plate|pin))\b"
    r"|\b(?:add|put on)\b[^.!?]{0,15}\b(?:weight|a plate|a pin|load|kg)\b|\bgo heavier\b|\bheavier (?:on|for) the\b",
    re.IGNORECASE)
_NOTE_LIGHTER_RE = re.compile(
    r"\b(?:take|make|go|move|drop|bring|put)\b[^.!?]{0,40}\b(?:lighter|down a (?:step|notch|plate|pin))\b"
    r"|\b(?:drop|strip|take off|take)\b[^.!?]{0,15}\b(?:weight|a plate|a pin|load|[\d.]+\s*kg off)\b|\bgo lighter\b",
    re.IGNORECASE)
_NOTE_BARE_UP_RE = re.compile(r"\b(?:take|make|go|move|bump|put|load|push)\b[^.!?]{0,40}\bup\b", re.IGNORECASE)
_NOTE_BARE_DOWN_RE = re.compile(r"\b(?:take|make|go|move|drop|bring|put)\b[^.!?]{0,40}\bdown\b", re.IGNORECASE)
_NOTE_NOT_LOAD_RE = re.compile(r"\b(?:reps?|rpe|range|tempo|effort|rir)\b", re.IGNORECASE)


def note_direction(note: str) -> str | None:
    """'heavier', 'lighter' or None: the load change the note tells him to make."""
    text = note or ""
    heavier, lighter = bool(_NOTE_HEAVIER_RE.search(text)), bool(_NOTE_LIGHTER_RE.search(text))
    for clause in re.split(r"[.!?;]", text):
        if _NOTE_NOT_LOAD_RE.search(clause):
            continue
        heavier = heavier or bool(_NOTE_BARE_UP_RE.search(clause))
        lighter = lighter or bool(_NOTE_BARE_DOWN_RE.search(clause))
    if heavier == lighter:
        return None
    return "heavier" if heavier else "lighter"


def _sequence(stored: dict) -> list:
    working = stored.get("working") or []
    backoff = stored.get("backoff") or []
    if len(working) > 1:
        return [("working", i) for i in range(len(working))]
    return [("working", 0)] + [("backoff", i) for i in range(len(backoff))]


def set_reply_problems(reply: dict, exercise: str, stored: dict, done: int,
                       logged_top: float | None = None) -> list[str]:
    """Only `revise` carries free numbers, and only its sanity is checked; a
    computed move cannot be malformed. The note is checked for damage: a
    reply is text the athlete reads, and a broken one is worse than none.

    The note and the decision must agree. On 23 Sep 2026 a note said "take the
    last back-off heavier" while the card stayed at 100kg: the card moves only
    on `decision`, so a note that tells him to change the load under any other
    decision is handed back."""
    decision = (reply.get("decision") or "").strip().lower()
    if decision not in SET_DECISIONS:
        return [f"decision must be one of {', '.join(SET_DECISIONS)}."]
    if note_is_broken(reply.get("note") or ""):
        return ["the note reads as broken text (" + ", ".join(note_damage(reply.get("note") or ""))
                + "): rewrite it as one to three plain sentences with no set numbers."]
    sequence = _sequence(stored or {})
    direction = note_direction(reply.get("note") or "")
    if direction:
        agrees = decision == direction
        if decision == "revise" and done < len(sequence):
            ph, i = sequence[done]
            planned = ((stored.get(ph) or [])[i] or {}) if (stored.get(ph) or []) else {}
            try:
                target = float((reply.get("revised") or {}).get("load_kg"))
                base = float(planned.get("load_kg"))
                agrees = (target > base) if direction == "heavier" else (target < base)
            except (TypeError, ValueError):
                agrees = False
        if not agrees:
            return [f"the note tells him to go {direction} but decision is {decision}: the card moves only on "
                    f"`decision`. Set decision to {direction} (with steps), or rewrite the note to match {decision}."]
    if decision == "hold":
        return []
    if sequence and done >= len(sequence):
        return [f"every set on the card is logged ({done} done): nothing is left to move, so decision is hold."]
    if len((reply.get("reason") or "").strip()) < 12:
        return ["a change to the next set carries the reason for it, in one sentence."]
    if decision == "revise":
        r = reply.get("revised") or {}
        try:
            low, high, rpe, load = int(r.get("reps_low", 0)), int(r.get("reps_high", 0)), float(r.get("rpe", 0)), float(r.get("load_kg", 0))
        except (TypeError, ValueError):
            return ["revised carries numbers that are not numbers."]
        out = []
        if not (1 <= low <= high <= 30):
            out.append(f"revised reps {low}-{high} are not a real target.")
        if not (5 <= rpe <= 10):
            out.append(f"revised RPE {rpe:g} is outside 5-10.")
        if load < 0:
            out.append("revised load is negative.")
        # A revised back-off stays 15-25% under the top set he actually lifted
        # (:64). 27.5kg under a 40kg top set (31%) reached the card on 22 Sep.
        cause = _REVISE_CAUSE_RE.search(reply.get("reason") or "")
        if done < len(sequence) and sequence[done][0] == "backoff" and load > 0 and not cause:
            top = logged_top or _as_float_or_none(((stored.get("working") or [{}])[0] or {}).get("load_kg"))
            if top:
                drop = 1 - load / top
                if drop > 0.25 + 1e-9 and load < _floor_to(0.75 * top, 2.5) - 1e-9:
                    out.append(f"revised back-off {load:g}kg is {drop:.0%} under the {top:g}kg top set; the "
                               f"band is 15-25%, so the lightest back-off is about {_floor_to(0.75 * top, 2.5):g}kg.")
                elif load >= top:
                    out.append(f"revised back-off {load:g}kg is not lighter than the {top:g}kg top set.")
        return out
    return []


# A revision for a cause outside the numbers — pain, a joint, the machine, the
# plates available — may leave the band; that is what `revise` is for.
_REVISE_CAUSE_RE = re.compile(
    r"\b(?:pain\w*|hurt\w*|sore|niggl\w*|tweak\w*|injur\w*|knee|elbow|shoulder|wrist|back pain|"
    r"machine|stack|plates?|pin|equipment|taken|busy|broken|only has|time)\b", re.IGNORECASE)


def _as_float_or_none(value) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _floor_to(value: float, grid: float) -> float:
    import math
    return math.floor(value / grid + 1e-9) * grid


def adapted_plan(reply: dict, exercise: str, stored: dict, done: int,
                 logged_top: float | None = None) -> ExercisePlan | None:
    """The exercise's plan with the set reply's decision applied, or None when
    nothing moves (hold, invalid, or every set already logged).

    Sets already logged keep the target they were logged against; the move
    lands on the next set and, in a one-load phase, on every set left in it.
    """
    decision = (reply.get("decision") or "hold").strip().lower()
    working = [_as_set(s) for s in stored.get("working") or []]
    backoff = [_as_set(s) for s in stored.get("backoff") or []]
    if not working or set_reply_problems(reply, exercise, stored, done, logged_top) or decision == "hold":
        return None
    straight = len(working) > 1
    sequence = ([("working", i) for i in range(len(working))] if straight
                else [("working", 0)] + [("backoff", i) for i in range(len(backoff))])
    if done >= len(sequence):
        return None
    phase, _ = sequence[done]
    steps = int(reply.get("steps") or 1)
    # A load move in a one-load phase carries to every set left in it. The
    # prompt's own rule: two back-offs at the SAME load, and straight sets at
    # one weight. On 18 Sep the coach bumped the first back-off of the 45°
    # Back Extension from 9.5 to 12 kg with scope "next"; the second stayed
    # at 9.5 on the card while the coach said "same 12kg" — two plans for one
    # lift. Rep and RPE moves stay per set: the second back-off is meant to
    # carry fewer reps than the first.
    load_move = decision in ("lighter", "heavier", "revise")
    one_load_phase = phase == "backoff" or straight
    # The lift's own load step, put on the stored plan by coach.py from the
    # programme's proposal; None when the log could not tell.
    grid = _known_step(_as_float_or_none(stored.get("step")))
    remaining_all = (reply.get("scope") or "next") == "remaining" or (load_move and one_load_phase)

    def moved(planned: SetPlan, first: bool) -> SetPlan:
        if decision == "revise":
            r = reply.get("revised") or {}
            revised = SetPlan(float(r["load_kg"]), int(r["reps_low"]), int(r["reps_high"]), float(r["rpe"]))
            # The revised set is the next one; the sets after it take its
            # load and keep their own reps and RPE.
            return revised if first else SetPlan(revised.load_kg, planned.reps_low, planned.reps_high, planned.rpe)
        return apply_set_decision(decision, steps, planned, exercise, grid) or planned

    for k, (ph, i) in enumerate(sequence):
        if k < done or ph != phase:
            continue
        if k > done and not remaining_all:
            break
        target_list = working if ph == "working" else backoff
        target_list[i] = moved(target_list[i], first=(k == done))
    # A computed load move on a back-off never leaves the 15-25% band under
    # the top set (:64): 'heavier' on a 100kg back-off under a 120kg top set
    # would be 105, 12.5% under; it stays at the lightest in-band load.
    if decision in ("heavier", "lighter") and phase == "backoff" and working:
        top = logged_top or working[0].load_kg
        if top and top > 0:
            band_grid = grid or 2.5
            ceiling = _floor_to(0.85 * top, band_grid)
            floor = _floor_to(0.75 * top, band_grid)
            for i, b in enumerate(backoff):
                if sequence.index(("backoff", i)) < done:
                    continue
                if decision == "heavier" and b.load_kg > ceiling:
                    backoff[i] = SetPlan(max(ceiling, _as_float_or_none((stored.get("backoff") or [])[i].get("load_kg")) or 0.0),
                                         b.reps_low, b.reps_high, b.rpe)
                if decision == "lighter" and b.load_kg < floor:
                    backoff[i] = SetPlan(floor, b.reps_low, b.reps_high, b.rpe)
    return ExercisePlan(exercise=exercise, decision="adjust", reason=str(reply.get("reason") or ""),
                        working=working, backoff=backoff,
                        tempo=str(stored.get("tempo") or ""), rest_seconds=int(stored.get("rest_seconds") or 0))


def moved_sets_sentence(stored: dict, e: "ExercisePlan", done: int) -> str:
    """What changed on the card, in words the athlete reads beside the note:
    "Back-off 2: 105kg (from 100kg)." The model is told not to write numbers;
    code writes them, so the new load is never left unsaid (the note "take the
    last back-off heavier" on 23 Sep named no load and moved nothing)."""
    parts = []
    for k, (ph, i) in enumerate(_sequence(stored)):
        if k < done:
            continue
        before = (stored.get(ph) or [])[i] if i < len(stored.get(ph) or []) else None
        after_list = e.working if ph == "working" else e.backoff
        after = after_list[i] if i < len(after_list) else None
        if not before or not after:
            continue
        b = _as_set(before)
        if (b.load_kg, b.reps_low, b.reps_high, b.rpe) == (after.load_kg, after.reps_low, after.reps_high, after.rpe):
            continue
        label = "Top set" if ph == "working" and len(e.working) == 1 else (
            f"Set {i + 1}" if ph == "working" else f"Back-off {i + 1}")
        reps = f"{after.reps_low}" if after.reps_low == after.reps_high else f"{after.reps_low}-{after.reps_high}"
        was = f" (from {b.load_kg:g}kg)" if b.load_kg != after.load_kg else ""
        parts.append(f"{label}: {after.load_kg:g}kg x{reps} @{after.rpe:g}{was}")
    return ("Card: " + "; ".join(parts) + ".") if parts else ""


def render_set_reply(reply: dict, exercise: str, stored: dict, done: int,
                     logged_top: float | None = None) -> str | None:
    """The coach's note, plus the exercise's block with the decision applied.

    The whole block is re-sent so the card's merge sees complete phases and
    nothing already on screen is lost. `revise` renders the given set with a
    `Revised:` line, the prompt's own marker for a departure. When a move
    changes a set, the note ends with the new numbers, written by code.
    """
    note = (reply.get("note") or "").strip()
    decision = (reply.get("decision") or "hold").strip().lower()
    if not (stored.get("working") or []) or set_reply_problems(reply, exercise, stored, done, logged_top):
        return None
    e = adapted_plan(reply, exercise, stored, done, logged_top)
    if e is None:
        return note or None
    said = moved_sets_sentence(stored, e, done)
    if said:
        note = f"{note} {said}".strip() if note else said
    elif decision in ("heavier", "lighter"):
        note = (f"{note} The card stays as it is: a back-off {decision} than this would leave the 15-25% band "
                f"under the top set, so the lever is reps.").strip()
    # A computed move keeps the plan's shape by construction; a revision is
    # the athlete's and the coach's business, marked as such.
    lines = render_exercise(e).split("\n")
    if decision == "revise":
        lines.insert(1, f"Revised: {(reply.get('reason') or '').strip()}")
    block = "\n".join(lines)
    return f"{note}\n\n{block}" if note else block


def owed_set_decision(logged: dict | None, stored: dict, done: int, last: tuple | None = None) -> dict | None:
    """The move the programme owes after a logged set, whatever the model said.

    A set that beats the top of its range at the prescribed load, at or under
    its target RPE, means the load is light (:204, "the rep range polices the
    load"); the remaining sets of the exercise go up now. 270kg x11 @7 against
    5-9 @7 on 23 Sep was answered with `hold` twice, and the back-offs stayed
    at 215kg. None when nothing is owed or nothing is left to move."""
    if not logged or (done < 1 and not last):
        return None
    sequence = _sequence(stored or {})
    if done >= len(sequence):
        return None
    # `last` is the slot the row was logged under (plan.last_logged_slot);
    # without it, the slot before the next one, as position had it.
    ph, i = last if last else sequence[done - 1]
    planned_list = stored.get(ph) or []
    if i >= len(planned_list):
        return None
    planned = _as_set(planned_list[i])
    reps = logged.get("actual_reps")
    load = _as_float_or_none(logged.get("actual_weight_kg"))
    rpe = _as_float_or_none(logged.get("actual_rpe"))
    if reps is None or load is None or rpe is None:
        return None
    reps = int(reps)
    over = reps - planned.reps_high
    if over < 1 or load < planned.load_kg - 1e-9 or rpe > planned.rpe + 1e-9:
        return None
    return {"decision": "heavier", "steps": 2 if over >= 3 else 1, "scope": "remaining",
            "reason": f"{reps} reps against {planned.reps_low}-{planned.reps_high} at RPE {rpe:g} (target "
                      f"{planned.rpe:g}): the range polices the load, so the remaining sets go up."}


def request_set_reply(client, system_blocks: list, messages: list, exercise: str,
                      done: int, total: int, model: str = MODEL,
                      stored: dict | None = None) -> tuple:
    """Ask for the set reply. Cheap: adaptive thinking at low effort. A reply
    that fails the (small) checks is handed back once; a second failure falls
    back to the prose reply."""
    notes: list[str] = []
    instruction = SET_REPLY_INSTRUCTION.format(exercise=exercise, done=done, total=total,
                                               card=card_line(stored))
    system = list(system_blocks) + [{"type": "text", "text": instruction}]
    turns = list(messages)
    import time
    started = time.monotonic()
    for attempt in (1, 2):
        response = client.messages.create(
            model=model,
            max_tokens=4000,
            thinking={"type": "adaptive"},
            output_config={"format": {"type": "json_schema", "schema": SET_REPLY_SCHEMA},
                           "effort": "low"},
            system=system,
            messages=turns,
        )
        usage = _usage_note(response)
        elapsed = time.monotonic() - started
        notes.append(f"set reply attempt {attempt}: {elapsed:.1f}s" + (f" ({usage})" if usage else ""))
        text = next((b.text for b in response.content if getattr(b, "type", "") == "text"), "")
        from usage import record_call  # local: keeps import order flat
        record_call("set_reply", elapsed, response, attempt=attempt, ok=bool(text), note=exercise, model=model)
        started = time.monotonic()
        if not text or getattr(response, "stop_reason", None) == "max_tokens":
            notes.append(f"set reply attempt {attempt}: nothing complete returned")
            return None, notes
        try:
            reply = json.loads(text)
        except ValueError as exc:
            notes.append(f"set reply attempt {attempt}: did not parse ({exc})")
            return None, notes
        problems = set_reply_problems(reply, exercise, stored or {}, done) if stored else []
        if any(p.startswith("the note reads as broken") for p in problems):
            log.warning("SET REPLY NOTE BROKEN (%s, attempt %d): %r", exercise, attempt, (reply.get("note") or "")[:200])
        if not problems:
            decision = (reply.get("decision") or "hold")
            notes.append(f"set reply accepted · {decision}")
            return reply, notes
        notes.append(f"set reply attempt {attempt}: " + " | ".join(problems))
        if attempt == 2:
            return None, notes
        turns = turns + [
            {"role": "assistant", "content": text},
            {"role": "user", "content": "Your set reply is not valid:\n- " + "\n- ".join(problems)
                                        + "\nReturn the corrected set reply."},
        ]
    return None, notes


# ── A "Revising:" that revised nothing ─────────────────────────────────────
# The coach wrote "Revising:" and sent no block: the card kept the old
# numbers while the athlete read that they had changed (Reverse Cable Fly,
# 20 Sep 2026). The rule (:740) is that a change travels as a block.
_REVISE_CLAIM_RE = re.compile(
    r"\b(?:revis(?:ing|ed)\b|updat(?:ing|ed) (?:the |your )?(?:card|prescription|plan|target|load)"
    r"|chang(?:ing|ed) (?:the |your )?(?:card|prescription|plan|target|load)"
    r"|(?:bump|stepp|mov)(?:ing|ed) (?:it |you )?(?:up|down) to \d)",
    re.IGNORECASE,
)


def missing_revision_note(reply: str, blocks: list[dict], card_exercise: str, card_stored: dict | None) -> str | None:
    """The sentence to append when `reply` claims a revision but carries no
    block for the lift on the card; None when nothing is owed."""
    if not _REVISE_CLAIM_RE.search(reply or ""):
        return None
    if not card_exercise or not card_stored:
        return None
    wanted = "".join(ch for ch in card_exercise.lower() if ch.isalnum())
    for block in blocks or []:
        name = "".join(ch for ch in (block.get("exercise") or "").lower() if ch.isalnum())
        if name and (name == wanted or name in wanted or wanted in name) and (block.get("working") or block.get("backoff")):
            return None
    return (f"(No revised block came through, so the card still reads {card_line(card_stored)}. "
            f"Say the number you want and I'll send the block.)")
