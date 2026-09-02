"""The training programme as code.

Every rule in system_prompt.txt that produces a NUMBER is a deterministic
function of (session type, mesocycle week, what was logged last time). The
4-week wave, the load-increase trigger, the back-off drop, the deload
arithmetic, the warm-up ramp — each has exactly one correct answer, and each
has been executed by a language model reading prose, at a temperature that
cannot be set, with thinking disabled.

That is why the patch list never converges. Six computed blocks now feed the
coach its inputs — CURRENT WORKING LOADS, PROGRESSION WATCH, WEEKLY VOLUME,
WEAK-POINT BLOCK, TODAY'S SET COUNTS, TODAY vs LAST SESSION — and every one of
them was added because the model got that specific piece of arithmetic wrong.
Pre-computing inputs does not help when the RULES are still prose: the model
still has to apply forty of them correctly in one pass, every message.

So this module executes them instead. It returns a PROPOSAL, not a
prescription. The coach receives it alongside the athlete's state and either
ships it, adjusts it, or overrides it — and says which. The algorithm owns what
the programme says; the coach owns whether today is a day to follow it. A
deviation is then legible AS a deviation, which is the thing that has been
missing: with no baseline, a considered 2-set prescription and a glitch are
indistinguishable.

Nothing here talks to a database or an API. Pure functions over plain data, so
the whole programme is testable and fails identically every time instead of
randomly.

Every rule carries the system_prompt.txt line it comes from. Where the prompt
is ambiguous or contradicts itself, the conflict is recorded on the proposal
rather than silently resolved — see `Proposal.deferred`.
"""

import re
from dataclasses import dataclass, field

# ── Exercise classification ──────────────────────────────────────────────────
#
# Rep ranges, load increments and rest all key off this. The prompt never gives
# an explicit list, so it is inferred from how each movement is described and
# recorded here rather than re-inferred per call.

COMPOUND = "compound"
ISOLATION = "isolation"

PULL_DAY = (
    # (exercise, working sets, kind)   — counts from the template line at :357
    ("Pull-Ups", 2, COMPOUND),
    ("Cable Row", 2, COMPOUND),
    ("Lat Pulldown", 2, COMPOUND),
    ("T-Bar Row", 2, COMPOUND),
    ("Machine Bicep Curl", 3, ISOLATION),
    ("Hammer Curl", 3, ISOLATION),
    ("Reverse Cable Fly", 2, ISOLATION),
)

# Which muscles a movement loads enough to count as "warm" for the next
# exercise. ":131 — 'Already trained' includes heavy secondary involvement:
# triceps are warm after pressing, biceps after rowing." Mirrors the 0.5
# synergist share muscle_map already uses for volume.
WARMS = {
    "Pull-Ups": ("Back", "Biceps"),
    "Cable Row": ("Back", "Biceps", "Rear Delts"),
    "Lat Pulldown": ("Back", "Biceps"),
    "T-Bar Row": ("Back", "Biceps", "Rear Delts"),
    "Machine Bicep Curl": ("Biceps",),
    "Hammer Curl": ("Biceps",),
    "Reverse Cable Fly": ("Rear Delts",),
}

PRIMARY_MUSCLE = {
    "Pull-Ups": "Back", "Cable Row": "Back", "Lat Pulldown": "Back",
    "T-Bar Row": "Back", "Machine Bicep Curl": "Biceps",
    "Hammer Curl": "Biceps", "Reverse Cable Fly": "Rear Delts",
}

BODYWEIGHT = {"Pull-Ups"}

# :63 Working Set 1 — "Compounds 6-10 reps, isolation exercises 8-12 reps".
# :64 Back-off — "Compounds 10-12 reps, isolation exercises 12-15 reps".
TOP_SET_RANGE = {COMPOUND: (6, 10), ISOLATION: (8, 12)}
BACKOFF_RANGE = {COMPOUND: (10, 12), ISOLATION: (12, 15)}

# :203 "2.5-5kg (compounds) / 1-2.5kg (isolations) is a guide, not a fixed grid"
INCREMENT = {COMPOUND: 2.5, ISOLATION: 1.0}

# :64 "Drop weight 15-25% immediately." Midpoint, so the result lands inside
# the band whichever way the gym's stack rounds.
BACKOFF_DROP = 0.20

# :391 "Rest stays 2min on compounds, 90s on isolations."
REST_SECONDS = {COMPOUND: 120, ISOLATION: 90}

# :64 "RPE follows the weekly wave (7 in weeks 1-2, 8 in week 3, 6 on deload)"
# :177-186 for the top-set targets.
WAVE = {
    1: {"top": 8.0, "backoff": 7.0, "name": "Baseline"},
    2: {"top": 8.0, "backoff": 7.0, "name": "Volume progression"},
    3: {"top": 9.0, "backoff": 8.0, "name": "Peak intensity"},
    4: {"top": 7.0, "backoff": 6.0, "name": "Deload"},
}

# :186 "if subtracting the reps leaves fewer than 5, do not prescribe a
# near-single ... Deload by LOAD instead — hold the week 3 reps and drop the
# weight 15-20%."
DELOAD_MIN_REPS = 5
DELOAD_LOAD_DROP = 0.175


@dataclass(frozen=True)
class PriorSet:
    """The top working set of an exercise's most recent session.

    Deliberately the same shape as one row of progression.find_current_loads,
    which is already the system's answer to "what weight is he on" (:211).
    """
    load: float | None          # None or 0.0 for bodyweight
    reps: int | None
    rpe: float | None
    date: str = ""
    week: int | None = None     # mesocycle week it was performed in, if known


@dataclass
class SetSpec:
    """One prescribed set.

    `bodyweight` is separate from `weight_kg` because a weighted pull-up is
    BW+15kg, not 15kg — collapsing the two loses the athlete's own mass and
    would prescribe a 15kg pull-up. `weight_kg` is None with bodyweight False
    only when no load could be determined at all, which must render as unknown
    rather than silently as bodyweight.
    """
    weight_kg: float | None
    reps_low: int
    reps_high: int
    rpe: float
    bodyweight: bool = False

    def render(self) -> str:
        if self.bodyweight:
            load = "BW" if not self.weight_kg else f"BW+{self.weight_kg:g}kg"
        elif self.weight_kg is None:
            load = "[load TBD]"
        else:
            load = f"{self.weight_kg:g}kg"
        reps = (f"{self.reps_low}" if self.reps_low == self.reps_high
                else f"{self.reps_low}-{self.reps_high}")
        return f"{load} x{reps} RPE{self.rpe:g}"


# " (:182)." -> "."   and   "(:64 applied to X)" -> "(applied to X)".
# Anchored on the colon-digit form so "RPE 8" and "8-12" are untouched.
_CITATION_RE = re.compile(r"\s*\(:\d{1,4}\)|\(:\d{1,4}\s+|(?<![\w:]):\d{1,4}\b")


def strip_citations(text: str) -> str:
    """Remove system_prompt.txt line references from athlete-facing text."""
    return _CITATION_RE.sub(lambda m: "(" if m.group().startswith("(") and
                            m.group().endswith(" ") else "", text).strip()


@dataclass
class Proposal:
    """What the programme says for one exercise today.

    `reasons` records why each number is what it is, so the coach can explain a
    prescription without re-deriving it and the athlete can be told the actual
    cause rather than a plausible-sounding one.

    `deferred` is the honest half: everything the programme does not determine,
    or determines two ways. A rule this module cannot settle must surface here
    rather than be guessed, because a guess dressed as a computed value is
    worse than the prose it replaced.
    """
    exercise: str
    kind: str
    warmup: list[SetSpec] = field(default_factory=list)
    working: list[SetSpec] = field(default_factory=list)
    backoff: list[SetSpec] = field(default_factory=list)
    rest_seconds: int = 120
    reasons: list[str] = field(default_factory=list)
    deferred: list[str] = field(default_factory=list)

    def __post_init__(self):
        self.reasons = [strip_citations(r) for r in self.reasons]
        self.deferred = [strip_citations(d) for d in self.deferred]

    @property
    def working_set_count(self) -> int:
        return len(self.working) + len(self.backoff)


def _round_load(value: float) -> float:
    """Nearest 2.5kg — the smallest increment common to plate-loaded and stack
    machines. :246 warns never to present a load as an exact must-hit number,
    so this is a starting point for the coach to phrase as approximate, not a
    claim about the athlete's gym."""
    return round(value / 2.5) * 2.5


def _met_top_of_range(prior: PriorSet, kind: str, target_rpe: float) -> bool:
    """The load-increase trigger, exactly as stated at :203.

    "when the top of the range is hit AT OR BELOW THE WEEK'S TARGET RPE, go up
    to the next loadable increment ... The trigger is the week's target, not a
    fixed RPE 8."

    Both halves must be present. A missing rep count or RPE is not evidence of
    anything and must not read as a pass.
    """
    if prior.reps is None or prior.rpe is None:
        return False
    return prior.reps >= TOP_SET_RANGE[kind][1] and prior.rpe <= target_rpe


def next_top_set(exercise: str, kind: str, week: int, prior: PriorSet | None,
                 reasons: list[str], deferred: list[str]) -> SetSpec:
    """The top set for today, from the wave and what was logged last time."""
    targets = WAVE[week]
    low, high = TOP_SET_RANGE[kind]

    if prior is None or prior.load is None:
        deferred.append(
            f"{exercise}: no logged history, so no opening load can be computed. "
            f"The programme calls this a genuine feel-out — ramp in clear steps and "
            f"find where {low}-{high} reps lands at RPE {targets['top']:g}."
        )
        return SetSpec(None, low, high, targets["top"])

    load = prior.load
    bodyweight = exercise in BODYWEIGHT

    if prior.reps is not None and prior.reps < low and week != 4:
        # :70 "That flexibility runs UPWARD only ... drifting BELOW an
        # exercise's range is not." Reported rather than silently corrected:
        # bringing the reps back in means dropping the load, and how far is a
        # judgement about this athlete, not arithmetic.
        #
        # Week 4 is excluded because a deload is SUPPOSED to sit below the
        # range — :74 gives "Cable Row 78.5kg x8 becomes 78.5kg x6" as correct.
        # Flagging it there would report the protocol working as a fault.
        deferred.append(
            f"{exercise}: last session ran {prior.reps} reps against a "
            f"{low}-{high} range — BELOW range, which the programme does not allow. "
            f"Bringing it back in means cutting the load; the size of that cut is "
            f"a coaching decision, not arithmetic. (If that session was a DELOAD "
            f"this is expected and not a fault — the log does not record which "
            f"week it was.)"
        )

    if week == 1:
        # :181 — Week 1 anchors to LAST CYCLE'S WEEK 3, not to the most recent
        # session, and it never repeats last cycle's numbers. "Take what he
        # achieved in Week 3 (the peak week, not the deload) and open Week 1 at
        # that load with reps reset to the BOTTOM of the range; where Week 3
        # finished at or above the top of the range, open at the next increment
        # up instead."
        #
        # Without this, weeks 2-4 progress from a Week 1 that simply repeated
        # the last cycle, and the wave loops forever without moving.
        if prior.week is not None and prior.week != 3:
            deferred.append(
                f"{exercise}: opening week 1 from a week {prior.week} session. "
                f"Week 1 anchors to the WEEK 3 peak — a deload result would "
                f"open the cycle low and the wave would never move."
            )
        elif prior.week is None:
            deferred.append(
                f"{exercise}: opening week 1 from the most recent session, but "
                f"week 1 anchors to last cycle's WEEK 3. This session has no "
                f"recorded mesocycle week, so which week it belonged to "
                f"cannot be verified."
            )
        if prior.reps is not None and prior.reps >= high:
            step = INCREMENT[kind]
            load = _round_load(load + step)
            reasons.append(
                f"Week 1 opens ~{step:g}kg ABOVE last cycle: week 3 finished at "
                f"{prior.reps} reps, at or above the top of the {low}-{high} range. "
                f"Reps reset to the bottom."
            )
        else:
            reasons.append(
                f"Week 1 opens at last cycle's week 3 load with reps reset to the "
                f"bottom of the {low}-{high} range. Baseline means the start "
                f"of a NEW cycle, never a repeat of the last one."
            )
        return SetSpec(load, low, low, targets["top"], bodyweight=bodyweight)

    if week == 2:
        # :182 — "Keep the Week 1 weight and reach RPE 8 by adding reps toward
        # the top of the range. If last week already hit the top of the range at
        # RPE <=8, add 2.5-5kg instead and reset reps to the bottom."
        if _met_top_of_range(prior, kind, targets["top"]):
            step = INCREMENT[kind]
            load = _round_load(load + step)
            reasons.append(
                f"Week 2 adds ~{step:g}kg: week 1 already reached the top of the "
                f"{low}-{high} range at RPE {prior.rpe:g}, so reps have nowhere left "
                f"to go (:182). Reps reset to the bottom."
            )
            return SetSpec(load, low, low, targets["top"], bodyweight=bodyweight)
        target_low = max(low, min((prior.reps or low) + 1, high))
        reasons.append(
            f"Week 2 holds the week 1 load and adds reps toward the top of the "
            f"{low}-{high} range (:182). Volume before intensity."
        )
        return SetSpec(load, target_low, high, targets["top"], bodyweight=bodyweight)

    if week == 3:
        # :183 — "Reach it by adding load (preferred when reps are already at the
        # top of the range) OR by grinding 1-2 more reps at the same weight.
        # State which lever you used and why."
        if prior.reps is not None and prior.reps >= high:
            step = INCREMENT[kind]
            load = _round_load(load + step)
            reasons.append(
                f"Week 3 peak via LOAD, ~{step:g}kg up: week 2 finished at "
                f"{prior.reps} reps, already at the top of the range, so load is the "
                f"preferred lever (:183)."
            )
            return SetSpec(load, low, low, targets["top"], bodyweight=bodyweight)
        target_low = max(low, min((prior.reps or low) + 1, high))
        reasons.append(
            f"Week 3 peak via REPS: same load, 1-2 more reps than week 2 to reach "
            f"RPE {targets['top']:g} (:183)."
        )
        return SetSpec(load, target_low, min(target_low + 1, high),
                       targets["top"], bodyweight=bodyweight)

    if week == 4:
        # :185 "Same exercises and same weights as Week 3, but deliberately
        # STOP SHORT so the set lands at RPE 7." RPE is reps-in-reserve, so at a
        # fixed load dropping the target N points costs N reps.
        #
        # The reference is WEEK 3 specifically, not simply the last session. The
        # caller supplies the most recent top set, which is usually the same
        # thing but is not when a session was missed or run light — and there the
        # subtraction silently yields zero and the "deload" repeats week 3's
        # actual effort. Flagged rather than guessed.
        if prior.week is not None and prior.week != 3:
            deferred.append(
                f"{exercise}: deloading against a week {prior.week} session, but "
                f"a deload anchors to WEEK 3. The rep subtraction is only "
                f"correct against a peak-week set."
            )
        elif prior.rpe is not None and prior.rpe <= targets["top"]:
            deferred.append(
                f"{exercise}: last session was already at RPE {prior.rpe:g}, at or "
                f"below the deload target of {targets['top']:g}, so there is nothing "
                f"to subtract and this 'deload' repeats it. Anchor to the week 3 set."
            )
        drop = int(round((prior.rpe or targets["top"]) - targets["top"]))
        reps = (prior.reps or high) - max(drop, 0)
        if reps < DELOAD_MIN_REPS:
            # :186 the low-rep exception — deload by load instead.
            load = _round_load(load * (1 - DELOAD_LOAD_DROP))
            reps = prior.reps or high
            reasons.append(
                f"Deload by LOAD, not reps: subtracting {drop} from {prior.reps} "
                f"would leave under {DELOAD_MIN_REPS} reps, which is a strength "
                f"stimulus rather than a deload (:186). Held the reps and dropped "
                f"the weight {DELOAD_LOAD_DROP:.0%}."
            )
        else:
            reasons.append(
                f"Deload: same load as last session, {drop} fewer reps so the set "
                f"lands at RPE {targets['top']:g}."
            )
        return SetSpec(load, reps, reps, targets["top"], bodyweight=bodyweight)

    if prior.reps is not None and prior.reps > high:
        # :205 "Reps ABOVE the top of the range are a backlog, not an
        # achievement: the load increase is already overdue."
        step = INCREMENT[kind]
        load = _round_load(load + step)
        reasons.append(
            f"Load up ~{step:g}kg and OVERDUE: {prior.reps} reps is above the top "
            f"of the {low}-{high} range, which means the increase was already due "
            f"last session (:205)."
        )
        return SetSpec(load, low, low, targets["top"], bodyweight=bodyweight)

    if _met_top_of_range(prior, kind, targets["top"]):
        # :203 rep progression is exhausted, so the load moves.
        step = INCREMENT[kind]
        load = _round_load(load + step)
        reasons.append(
            f"Load up ~{step:g}kg: last session hit {prior.reps} reps at "
            f"RPE {prior.rpe:g}, which is the top of the {low}-{high} range at or "
            f"under the week's target of {targets['top']:g} (:203). Reps reset to "
            f"the bottom of the range."
        )
        return SetSpec(load, low, low, targets["top"], bodyweight=bodyweight)

    # :201 rep progression first — same load, aim further up the range.
    # Clamp to the range: a prior session below the floor must not drag the
    # proposal below it too (:70 — the flexibility runs upward only).
    target_low = max(low, min((prior.reps or low) + 1, high))
    at_rpe = f" at RPE {prior.rpe:g}" if prior.rpe is not None else ""
    reasons.append(
        f"Rep progression at the same load: {prior.reps} reps last session"
        f"{at_rpe}, so add reps toward the top of the range before the load "
        f"moves (:201)."
    )
    return SetSpec(load, target_low, high, targets["top"], bodyweight=bodyweight)


def backoff_sets(top: SetSpec, kind: str, count: int, week: int,
                 reasons: list[str]) -> list[SetSpec]:
    """The back-off sets: 15-25% lighter, and the second one shorter.

    :64 "Drop weight 15-25% immediately." :65 "On a 3-set exercise prescribe TWO
    back-offs at the SAME load ... and the SECOND one always carries 1-2 FEWER
    REPS than the first. Not a choice, not a judgement call — always."

    That last rule is the most-botched line in the programme, and it is one
    subtraction.
    """
    if count < 1:
        return []
    low, high = BACKOFF_RANGE[kind]
    rpe = WAVE[week]["backoff"]

    if top.bodyweight:
        # A weighted pull-up backs off by shedding the added load, not by
        # becoming a different exercise. Dropping 20% of bodyweight is not a
        # thing he can do.
        load = _round_load((top.weight_kg or 0) * (1 - BACKOFF_DROP)) or None
        reasons.append(
            "Back-off sheds the added load and stays at bodyweight — a bodyweight "
            "movement cannot drop 20% of the athlete (:64 applied to the added "
            f"load only), at RPE {rpe:g} for week {week}."
        )
    elif top.weight_kg is None:
        load = None
    else:
        load = _round_load(top.weight_kg * (1 - BACKOFF_DROP))
        reasons.append(
            f"Back-off at {load:g}kg — {BACKOFF_DROP:.0%} below the top set, inside "
            f"the 15-25% band (:64), at RPE {rpe:g} for week {week}."
        )

    sets = [SetSpec(load, low, high, rpe, bodyweight=top.bodyweight)]
    for _ in range(count - 1):
        # Same load, 1-2 fewer reps than the one before it.
        prev = sets[-1]
        sets.append(SetSpec(load, max(prev.reps_low - 2, 1),
                            max(prev.reps_high - 2, 1), rpe,
                            bodyweight=top.bodyweight))
    if count > 1:
        reasons.append(
            "Second back-off carries 2 fewer reps at the same load — a set under "
            "two sets' worth of fatigue cannot be as easy as the first (:65)."
        )
    return sets


def warmup_ramp(exercise: str, top: SetSpec, muscles_warm: set[str],
                prior: PriorSet | None, reasons: list[str]) -> list[SetSpec]:
    """The ramp, as the decision table at :127-135.

    Driven by the working weight and by whether the muscle is already warm —
    never by the week. ":125 Deload holds week-3 loads, so a deload ramp is
    identical to the peak-week ramp."
    """
    primary = PRIMARY_MUSCLE.get(exercise, "")
    first_for_muscle = primary not in muscles_warm
    weight = top.weight_kg

    def ramp(fractions: list[float], reps: list[int]) -> list[SetSpec]:
        if top.bodyweight:
            # Ramp at bodyweight before a weighted set — :133 makes this the
            # standing case for pull-ups whenever the added load goes up.
            return [SetSpec(None, reps[0], reps[0], 5.5, bodyweight=True)]
        if weight is None:
            return []      # no working load determined, so nothing to ramp to
        return [SetSpec(_round_load(weight * f), r, r, 5.5)
                for f, r in zip(fractions, reps)]

    if not first_for_muscle:
        # :131 second and later exercises for an already-warm muscle: 0-1.
        # :132 take the 1 when the LOADING is new.
        if prior is None or prior.load is None:
            reasons.append(
                f"One ramp set: {primary} is already warm, but the loading is new "
                f"for this movement (:132)."
            )
            return ramp([0.65], [8])
        reasons.append(
            f"No ramp: {primary} is already warm from earlier in the session and a "
            f"ramp here only adds fatigue (:131)."
        )
        return []

    if top.bodyweight:
        reasons.append("One bodyweight ramp set before the weighted top set (:133).")
        return ramp([1.0], [5])
    if weight is None:
        reasons.append("No ramp computed: the working load is not yet determined, "
                       "so there is nothing to ramp to. The feel-out sets ARE the ramp.")
        return []
    if weight >= 100:
        reasons.append("Three ramp sets at ~55/75/88% — first movement for this "
                       "muscle and the working weight is heavy (:128).")
        return ramp([0.55, 0.75, 0.88], [10, 5, 3])
    if weight >= 50:
        reasons.append("Two ramp sets at ~60/85% — first movement for this muscle "
                       "at a moderate working weight (:129).")
        return ramp([0.60, 0.85], [10, 5])
    reasons.append("One ramp set at ~65% — first movement for this muscle, light "
                   "working weight (:130).")
    return ramp([0.65], [8])


def prescribe_exercise(exercise: str, sets: int, kind: str, week: int,
                       prior: PriorSet | None, muscles_warm: set[str]) -> Proposal:
    """One exercise's proposal for today."""
    reasons: list[str] = []
    deferred: list[str] = []

    top = next_top_set(exercise, kind, week, prior, reasons, deferred)
    backoffs = backoff_sets(top, kind, sets - 1, week, reasons)
    warm = warmup_ramp(exercise, top, muscles_warm, prior, reasons)

    return Proposal(
        exercise=exercise, kind=kind, warmup=warm, working=[top],
        backoff=backoffs, rest_seconds=REST_SECONDS[kind],
        reasons=reasons, deferred=deferred,
    )


def prescribe_pull(week: int, history: dict[str, PriorSet]) -> list[Proposal]:
    """The whole Pull session.

    `history` maps exercise name to its most recent top working set — the same
    thing progression.get_current_loads already returns, so this consumes a
    readout that exists rather than re-deriving one from the log.
    """
    if week not in WAVE:
        raise ValueError(f"mesocycle week must be 1-4, got {week!r}")

    proposals = []
    muscles_warm: set[str] = set()
    for exercise, sets, kind in PULL_DAY:
        proposals.append(prescribe_exercise(
            exercise, sets, kind, week, history.get(exercise), set(muscles_warm)
        ))
        muscles_warm.update(WARMS.get(exercise, ()))
    return proposals


def render(proposals: list[Proposal]) -> str:
    """The session in the app's own block format, so the output is directly
    comparable to what the coach currently emits."""
    out = []
    total = sum(p.working_set_count for p in proposals)
    out.append(f"PULL — {total} working sets")
    for p in proposals:
        out.append(f"\n*{p.exercise}*")
        if p.warmup:
            out.append("Warm-up: " + ", ".join(s.render() for s in p.warmup))
        out.append("Working Set: " + ", ".join(s.render() for s in p.working)
                   + f" | Rest: {p.rest_seconds}s")
        if p.backoff:
            out.append("Back-off: " + ", ".join(s.render() for s in p.backoff))
    return "\n".join(out)


# ── Reconstructing the mesocycle week from the session log ───────────────────

MESOCYCLE_WEEKS = 4


def infer_session_weeks(session_types: list[str], next_week: int,
                        next_day: int) -> list[int | None]:
    """Which mesocycle week each past session belonged to, worked out backwards.

    `workout_sessions` does not store the week (the legacy `sessions` table did;
    it was dropped when the table was replaced), and rows written before the
    migration never will. Without it a deload and a session run under target are
    indistinguishable, which is the difference between the protocol working and
    the protocol failing.

    It does not have to be stored to be known. Two facts recover it:

      THE DAY IS THE TYPE. The rotation is a bijection — Pull is day 1, Push 2,
      Legs 3, Cardio+Abs 4 — so a session's rotation position is readable
      directly off the row rather than counted. That makes the reconstruction
      immune to missed days, which is what would break a naive step-by-step walk.

      THE WEEK TURNS ON DAY 4. Completing day 4 advances the week, so walking
      backwards the week decrements exactly when a day-1 session is passed.

    Anchored to the CURRENT memory state, which is the week and day of the NEXT
    session rather than the last one — so if the next session is day 1, the last
    completed one was day 4 of the previous week.

    Yoga is not a rotation position and never advances anything (data.py:45), so
    it yields None and is skipped when stepping.

    Returns one entry per input session, in the same order. This is a RECONSTRUCTION,
    not a record: an override that swapped a day, or a session logged under the
    wrong type, will shift it. Sessions written after the migration carry the real
    value and should be preferred over this every time.
    """
    from data import CYCLE, YOGA_SESSION_TYPE

    days: list[int | None] = []
    for name in session_types:
        clean = (name or "").strip()
        if clean == YOGA_SESSION_TYPE or clean not in CYCLE:
            days.append(None)
        else:
            days.append(CYCLE.index(clean) + 1)

    def _wrap(week: int) -> int:
        return ((week - 1) % MESOCYCLE_WEEKS) + 1

    # The most recent completed session sits one step behind the stored state.
    week = _wrap(next_week - 1) if next_day == 1 else _wrap(next_week)

    out: list[int | None] = [None] * len(days)
    for i in range(len(days) - 1, -1, -1):
        if days[i] is None:
            continue                      # yoga consumes no rotation slot
        out[i] = week
        if days[i] == 1:
            week = _wrap(week - 1)        # stepping back past day 1 crosses a week
    return out
