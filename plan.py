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
                    "warmup": {"type": "array", "items": _WARMUP_SET},
                    "working": {"type": "array", "items": _SET,
                                "description": "One top set for top-set/back-off work; every set for straight-set ab work."},
                    "backoff": {"type": "array", "items": _SET,
                                "description": "Empty for straight-set ab work."},
                    "tempo": {"type": "string", "description": "e.g. 3-1-2"},
                    "rest_seconds": {"type": "integer"},
                    "form_cue": {"type": "string"},
                    "note": {"type": "string", "description": "One or two lines of coaching context after the block."},
                },
                "required": ["exercise", "decision", "reason", "warmup", "working", "backoff",
                             "tempo", "rest_seconds", "form_cue", "note"],
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


def parse_plan(text: str) -> SessionPlan:
    """The model's JSON into the dataclasses. Raises on anything malformed."""
    raw = json.loads(text)
    exercises = []
    for e in raw["exercises"]:
        exercises.append(ExercisePlan(
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
        ))
    return SessionPlan(opening=str(raw.get("opening") or "").strip(), exercises=exercises,
                       carried=[str(c) for c in raw.get("carried") or []])


# ── Checking the plan against the athlete's rules ────────────────────────────

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


def validate(plan: SessionPlan, session_type: str, prompt: str,
             proposal: dict | None = None, weak_points: list | None = None) -> list[str]:
    """Every way the plan breaks the programme, as sentences the model can act on.

    Mechanical rules only — set counts from the template, the shape of the
    back-offs, sane ranges — plus one honesty rule: an exercise marked
    'accept' must carry the programme's numbers, and one marked 'adjust'
    must say why. Nothing here judges whether a departure is wise; that is
    the coach's job, and the reason field is where it is done.
    """
    problems: list[str] = []
    pairs, _total = parse_session_template(prompt, session_type)
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

        computed = _proposal_numbers(proposal_by_key.get(key, ""))
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
    if filled_slots < live_slots:
        which = (" and ".join(weak_points) if weak_points
                 else "the two lowest muscles in WEEKLY VOLUME")
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
    if e.note:
        lines.append(e.note)
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
  This plan is the AB block and the TWO weak-point slots — 3 sets each, for the two
  lowest muscles in WEEKLY VOLUME — named as real movements, with the muscle they
  serve in `reason`.""".strip()


def _phase(week: int) -> str:
    return WAVE.get(week, {}).get("name", "")


def request_session_plan(client, system_blocks: list, messages: list,
                         session_type: str, week: int, prompt: str,
                         proposal: dict | None = None, model: str = MODEL,
                         weak_points: list | None = None) -> tuple:
    """Ask for the plan, check it, hand it back once if it breaks a rule.

    Returns (plan, log_lines). `plan` is None when no valid plan could be had,
    and the caller falls back to the prose path — the athlete always gets a
    reply. Thinking is ON for this call: it is one call per session, and
    weighing a whole day against the athlete's history is exactly the work
    thinking is for.
    """
    notes: list[str] = []
    instruction = PLAN_INSTRUCTION.format(
        session_type=session_type, week=week, phase=_phase(week),
        day_note=CARDIO_ABS_NOTE if session_type == "Cardio+Abs" else "").strip()
    system = list(system_blocks) + [{"type": "text", "text": instruction}]
    turns = list(messages)

    for attempt in (1, 2):
        response = client.messages.create(
            model=model,
            max_tokens=16000,
            thinking={"type": "adaptive"},
            output_config={"format": {"type": "json_schema", "schema": PLAN_SCHEMA},
                           "effort": "medium"},
            system=system,
            messages=turns,
        )
        text = next((b.text for b in response.content if getattr(b, "type", "") == "text"), "")
        if getattr(response, "stop_reason", None) == "max_tokens" or not text:
            notes.append(f"attempt {attempt}: no complete plan returned")
            return None, notes
        try:
            plan = parse_plan(text)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            notes.append(f"attempt {attempt}: plan did not parse ({exc})")
            return None, notes
        problems = validate(plan, session_type, prompt, proposal, weak_points)
        if not problems:
            notes.append(f"attempt {attempt}: plan accepted")
            return plan, notes
        notes.append(f"attempt {attempt}: " + " | ".join(problems))
        if attempt == 2:
            break
        # The model corrects its own plan. The code never edits a number.
        turns = turns + [
            {"role": "assistant", "content": text},
            {"role": "user", "content": "Your plan breaks these rules of the programme:\n- "
                                        + "\n- ".join(problems)
                                        + "\nReturn the corrected plan. Keep every decision you "
                                          "still stand behind and its reason."},
        ]
    return None, notes


# ── The decision log ─────────────────────────────────────────────────────────

def save_decisions(plan: SessionPlan, session_type: str, week: int,
                   session_id: str | None = None) -> int:
    """Write every exercise's decision and reason. Returns rows written; a
    missing table or a failed write costs a log line, never the reply."""
    supabase = get_supabase()
    if not supabase:
        return 0
    today = now_local().strftime("%Y-%m-%d")
    rows = []
    for e in plan.exercises:
        top = e.working[0] if e.working else None
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
# then the first logged set broke it: the coach wrote "Next set: 100kg x12
# RPE8" as prose, the card kept 97.5 x 9, and the athlete was left with two
# answers. A change to the next set is a number too. It goes through the same
# door — typed, checked, rendered into the block the card reads — and the
# coach's read on the set stays prose.

SET_REPLY_SCHEMA = {
    "type": "object",
    "properties": {
        "note": {
            "type": "string",
            "description": "Your read on the set he just logged and what to do on the next one: one to "
                           "three sentences, plain prose. State the next target in words only if it "
                           "CHANGES; the card carries it either way.",
        },
        "next_set": {
            "type": "object",
            "properties": {
                "changed": {"type": "boolean",
                            "description": "true only when the next set should differ from what the card shows."},
                "load_kg": {"type": "number", "description": "Added load for a bodyweight movement."},
                "reps_low": {"type": "integer"},
                "reps_high": {"type": "integer"},
                "rpe": {"type": "number"},
                "apply_to_remaining": {"type": "boolean",
                                       "description": "true: every remaining set of this phase takes the new "
                                                      "target. false: only the next set."},
            },
            "required": ["changed", "load_kg", "reps_low", "reps_high", "rpe", "apply_to_remaining"],
            "additionalProperties": False,
        },
    },
    "required": ["note", "next_set"],
    "additionalProperties": False,
}

SET_REPLY_INSTRUCTION = """
He has just logged a set of {exercise} (set {done} of {total} done). Return the SET REPLY
object: `note` is your read and your instruction, in your voice; `next_set` says whether
the NEXT set's numbers change. Change them only for a reason you can name — the set he
just did (reps, RPE), a reading, a joint, a machine step — and put that reason in `note`.
If nothing changes, `changed` is false and the card stands. Never write a target in prose
that differs from `next_set`; the card is rendered from `next_set`.
""".strip()


def _same(a: str, b: str) -> bool:
    return _normalise_exercise(a) == _normalise_exercise(b)


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


def set_reply_problems(reply: dict, exercise: str, stored: dict, done: int) -> list[str]:
    """What is wrong with a proposed next set, in sentences the model can act on."""
    nxt = reply.get("next_set") or {}
    if not nxt.get("changed"):
        return []
    working = [_as_set(s) for s in stored.get("working") or []]
    backoff = [_as_set(s) for s in stored.get("backoff") or []]
    if not working:
        return []
    try:
        target = SetPlan(float(nxt.get("load_kg", 0) or 0), int(nxt.get("reps_low", 1)),
                         int(nxt.get("reps_high", nxt.get("reps_low", 1))), float(nxt.get("rpe", 8)))
    except (TypeError, ValueError):
        return ["next_set carries numbers that are not numbers."]
    out: list[str] = []
    if not (1 <= target.reps_low <= target.reps_high <= 30):
        out.append(f"reps {target.reps_low}-{target.reps_high} are not a real target.")
    if not (5 <= target.rpe <= 10):
        out.append(f"RPE {target.rpe:g} is outside 5-10.")
    if target.load_kg < 0:
        out.append("negative load.")
    straight = len(working) > 1
    if not straight and done >= 1 and not is_bodyweight(exercise):
        top = working[0]
        if target.load_kg >= top.load_kg > 0:
            out.append(f"the next set is a back-off and must be LIGHTER than the top set "
                       f"({top.load_kg:g}kg): {target.load_kg:g}kg is not a back-off.")
        if target.rpe >= top.rpe:
            out.append(f"a back-off targets a lower RPE than the top set's RPE{top.rpe:g}.")
    return out


def render_set_reply(reply: dict, exercise: str, stored: dict, done: int) -> str | None:
    """The coach's note, plus the exercise's block with the next set moved.

    Sets already logged keep the target they were logged against; the change
    lands on the next set and, when asked, every remaining set of that phase.
    The whole block is re-sent so the card's merge sees complete phases and
    nothing already on screen is lost.
    """
    note = (reply.get("note") or "").strip()
    nxt = reply.get("next_set") or {}
    working = [_as_set(s) for s in stored.get("working") or []]
    backoff = [_as_set(s) for s in stored.get("backoff") or []]
    if not working:
        return None
    if not nxt.get("changed"):
        return note or None

    if set_reply_problems(reply, exercise, stored, done):
        return None
    target = SetPlan(float(nxt.get("load_kg", 0) or 0), int(nxt.get("reps_low", 1)),
                     int(nxt.get("reps_high", nxt.get("reps_low", 1))), float(nxt.get("rpe", 8)))
    remaining_all = bool(nxt.get("apply_to_remaining", True))

    straight = len(working) > 1
    if straight:
        sequence = [("working", i) for i in range(len(working))]
    else:
        sequence = [("working", 0)] + [("backoff", i) for i in range(len(backoff))]
    if done >= len(sequence):
        return note or None
    phase, _ = sequence[done]
    for k, (ph, i) in enumerate(sequence):
        if k < done or ph != phase:
            continue
        if k > done and not remaining_all:
            break
        (working if ph == "working" else backoff)[i] = target

    e = ExercisePlan(exercise=exercise, decision="adjust", reason="", working=working, backoff=backoff,
                     tempo=str(stored.get("tempo") or ""), rest_seconds=int(stored.get("rest_seconds") or 0))
    block = render_exercise(e)
    return f"{note}\n\n{block}" if note else block


def request_set_reply(client, system_blocks: list, messages: list, exercise: str,
                      done: int, total: int, model: str = MODEL,
                      stored: dict | None = None) -> tuple:
    """Ask for the set reply. Cheap: adaptive thinking at low effort. A next
    set that breaks the back-off rules is handed back once; a second failure
    falls back to the prose reply."""
    notes: list[str] = []
    instruction = SET_REPLY_INSTRUCTION.format(exercise=exercise, done=done, total=total)
    system = list(system_blocks) + [{"type": "text", "text": instruction}]
    turns = list(messages)
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
        text = next((b.text for b in response.content if getattr(b, "type", "") == "text"), "")
        if not text or getattr(response, "stop_reason", None) == "max_tokens":
            notes.append(f"set reply attempt {attempt}: nothing complete returned")
            return None, notes
        try:
            reply = json.loads(text)
        except ValueError as exc:
            notes.append(f"set reply attempt {attempt}: did not parse ({exc})")
            return None, notes
        problems = set_reply_problems(reply, exercise, stored or {}, done) if stored else []
        if not problems:
            notes.append("set reply accepted" + (" · next set changed" if (reply.get("next_set") or {}).get("changed") else ""))
            return reply, notes
        notes.append(f"set reply attempt {attempt}: " + " | ".join(problems))
        if attempt == 2:
            return None, notes
        turns = turns + [
            {"role": "assistant", "content": text},
            {"role": "user", "content": "Your next set breaks the programme:\n- " + "\n- ".join(problems)
                                        + "\nReturn the corrected set reply."},
        ]
    return None, notes
