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
from dataclasses import dataclass, field, replace

# ── Exercise classification ──────────────────────────────────────────────────
#
# Rep ranges, load increments and rest all key off this. The prompt never gives
# an explicit list, so it is inferred from how each movement is described and
# recorded here rather than re-inferred per call.

COMPOUND = "compound"
ISOLATION = "isolation"

def _contributions(exercise: str) -> dict:
    """Muscle shares for an exercise. Imported locally so this module keeps its
    dependency-free import: the caller supplies the plan, and only this one
    lookup reaches for the shared catalog."""
    from volume import resolve_contributions  # local: keeps import order flat
    return resolve_contributions(exercise) or {}


def classify(exercise: str) -> str:
    """COMPOUND if the movement has synergists, ISOLATION if it does not.

    Derived rather than listed. A hand-written table is a second place for the
    same fact to live, and every divergence between two such places has cost
    this programme something today — the template saying "Incline Press" while
    the log says "Incline Barbell Press" silently dropped two muscles' credit.
    Verified to reproduce the original hand-written Pull classifications
    exactly, for all seven exercises.
    """
    return COMPOUND if len(_contributions(exercise)) > 1 else ISOLATION


def warms(exercise: str) -> tuple:
    """Muscles this movement leaves warm enough to skip a ramp for."""
    return tuple(sorted(_contributions(exercise)))


def primary_muscle(exercise: str) -> str:
    """The muscle carrying the full share; "" when the catalog knows nothing."""
    shares = _contributions(exercise)
    return max(shares, key=lambda m: shares[m]) if shares else ""


def day_plan(entries) -> tuple:
    """(exercise, sets) pairs from a session template -> (exercise, sets, kind).

    The exercise list and its set counts come from the programme document via
    coach_parsing.parse_session_template, so the code cannot disagree with the
    prompt about what a day contains. Only the arithmetic lives here.

    Entries the catalog does not recognise are dropped: the Cardio+Abs template
    carries two "Weak-Point Exercise" placeholder slots that are filled with a
    real movement at prescription time and have no loads of their own.
    """
    plan = []
    for exercise, sets in entries:
        if not _contributions(exercise):
            continue
        plan.append((exercise, sets, classify(exercise)))
    return tuple(plan)


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


def is_bodyweight(exercise: str) -> bool:
    """Loaded by adding weight to the athlete, not by a stack (:274).

    Read from the shared catalog rather than the one-line set above, which
    knew Pull-Ups and nothing else — so Dips arrived as a 2.5kg movement, and
    the whole Push proposal went with it. A machine or assisted variant is a
    stack movement whatever its name says.
    """
    name = (exercise or "").lower()
    if exercise in BODYWEIGHT:
        return True
    if "machine" in name or "assisted" in name:
        return False
    from muscle_map import BODYWEIGHT_MOVEMENTS  # local: keeps import order flat
    return any(tag in name for tag in BODYWEIGHT_MOVEMENTS)

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
    load: float | None          # the ADDED load for a bodyweight movement
    reps: int | None
    rpe: float | None
    date: str = ""
    week: int | None = None     # mesocycle week it was performed in, if known
    bodyweight: bool = False    # progression's "BW" key: a set at bodyweight


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
            load = "BW" if not self.weight_kg else f"BW + {self.weight_kg:g}kg"
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
    # Today's readings call for a different session, not a lighter version of
    # this one (:316). Nothing may render a block for it.
    recovery_session: bool = False
    # Kept apart from `reasons` because they must not be truncated. :321 says
    # more than one rule usually matches and the coach must say WHICH — and
    # format_proposal keeps only the first ordinary reason per exercise, so a
    # recovery cut sharing that list loses every explanation but one.
    recovery_reasons: list[str] = field(default_factory=list)

    def __post_init__(self):
        self.reasons = [strip_citations(r) for r in self.reasons]
        self.deferred = [strip_citations(d) for d in self.deferred]

    @property
    def working_set_count(self) -> int:
        return len(self.working) + len(self.backoff)


# Fine enough to survive the smallest increment the programme applies. It was
# 2.5kg, which silently ate every isolation increase: the isolation step is
# 1.0kg, so 55 + 1 rounded straight back to 55. The increase was computed, named
# in the reason string ("opens ~1kg ABOVE last cycle"), and then discarded — on
# 8 of 11 realistic loads it vanished entirely and on two it came out inflated
# to 2x. That is a load that moves sometimes and not others for no reason the
# athlete can see.
#
# The old docstring cited the programme's own increment guidance as the reason
# for a 2.5kg grid, and that passage says the opposite: "never present a
# prescribed load as an exact must-hit number on a clean 2.5kg grid" and
# "Machines, cables, and fixed dumbbells: round to the nearest available step,
# never assume 2.5kg". The number here is a starting point the coach phrases as
# approximate, so it must not assert a grid it cannot know.
_LOAD_GRID = 0.5


def _round_load(value: float) -> float:
    """Round to the nearest half-kilo.

    Half a kilo divides every increment the programme uses (1.0kg isolation,
    2.5kg compound), so an increase can never be rounded away. Percentage
    results — back-off drops, deload drops, warm-up ramps — land on a tidy
    number without pretending to know the athlete's equipment.
    """
    return round(value / _LOAD_GRID) * _LOAD_GRID


@dataclass(frozen=True)
class RecoveryAdjustment:
    """What today's readout does to the week's targets, as arithmetic.

    The rules are :315-319 and they are not advisory — "Recovery data is
    injected with every message. Apply these rules". More than one usually
    matches and :321 says the STRICTEST applies, so this resolves them rather
    than leaving the choice to prose.

    Why it lives here and not in an enforcement pass: the previous attempt
    checked the model's RPE against the week's target on the way out, which
    silently undid exactly this reduction and pushed a suppressed-HRV day back
    to full intensity. The adjustment cannot be told apart from drift after the
    fact — the only way to get it right is to compute it WITH the prescription,
    where the load, the reps and the RPE are still one decision.
    """
    rpe_delta: float = 0.0
    load_multiplier: float = 1.0
    recovery_session: bool = False
    reasons: tuple = ()

    @property
    def adjusted(self) -> bool:
        """Anything to say about today, arithmetic or not.

        `reasons` counts. :319 attaches no number to an elevated resting HR —
        "flag potential overreaching, ask how they feel" — and an earlier cut
        of this gated on the numbers alone, so that rule produced a reason and
        then dropped it on the floor.
        """
        return bool(self.rpe_delta or self.load_multiplier != 1.0
                    or self.recovery_session or self.reasons)


def _pct_below(value, baseline) -> float | None:
    """How far under the baseline, as a percentage. None when unknowable."""
    try:
        value, baseline = float(value), float(baseline)
    except (TypeError, ValueError):
        return None
    if baseline <= 0:
        return None
    return (baseline - value) / baseline * 100.0


def recovery_adjustment(recovery: dict | None) -> RecoveryAdjustment:
    """Resolve :315-319 against today's numbers, strictest first.

    Computed from the readings rather than from the rendered status line. The
    status string is produced for a human to read and has been spelled three
    different ways in two files; the numbers it is derived from have not moved.
    """
    if not recovery:
        return RecoveryAdjustment()

    hrv_down = _pct_below(recovery.get("hrv"), recovery.get("hrv_avg"))
    # Above baseline, so the baseline is the denominator — _pct_below with the
    # arguments swapped divides by the wrong number and under-reports.
    rhr_down = _pct_below(recovery.get("resting_hr"),
                          recovery.get("resting_hr_baseline"))
    rhr_up = -rhr_down if rhr_down is not None else None
    try:
        sleep = float(recovery.get("sleep_hours"))
    except (TypeError, ValueError):
        sleep = None

    reasons = []
    # :316 the strictest rule, and the only one that is not an adjustment.
    if (hrv_down is not None and hrv_down > 20) or (sleep is not None and sleep < 5):
        if hrv_down is not None and hrv_down > 20:
            reasons.append(f"HRV {hrv_down:.0f}% below the 7-day average (:316)")
        if sleep is not None and sleep < 5:
            reasons.append(f"{sleep:g}h sleep, under 5 (:316)")
        return RecoveryAdjustment(recovery_session=True, reasons=tuple(reasons))

    rpe_delta, multiplier = 0.0, 1.0
    if hrv_down is not None and hrv_down > 10:
        rpe_delta = -1.0
        reasons.append(f"HRV {hrv_down:.0f}% below the 7-day average, so RPE "
                       f"targets come down a point (:315)")
    if sleep is not None and 5 <= sleep <= 6:
        multiplier = 0.95
        reasons.append(f"{sleep:g}h sleep, so the top set comes down 5% for CNS "
                       f"fatigue (:317)")
    if rhr_up is not None and rhr_up > 10:
        reasons.append(f"resting HR {rhr_up:.0f}% above baseline — possible "
                       f"overreaching, worth asking how he feels (:319)")
    return RecoveryAdjustment(rpe_delta=rpe_delta, load_multiplier=multiplier,
                              reasons=tuple(reasons))


def apply_recovery(spec: "SetSpec", adjustment: RecoveryAdjustment,
                   reasons: list) -> "SetSpec":
    """Move load, reps and RPE together, per :323.

    "Reducing an RPE target is a REP change, not a note on the card ... RPE is
    reps-in-reserve, so one point of RPE at a fixed load is one rep: `215kg
    x6-8 @ RPE8` becomes `215kg x5-7 @ RPE7`." Both ends of the band drop, and
    it explicitly does NOT become more reps at less effort.

    "If subtracting the reps leaves fewer than 5, hold the reps and drop the
    load 5-10% instead. Either way, state which lever you used."
    """
    if not adjustment.adjusted:
        return spec

    rpe = spec.rpe + adjustment.rpe_delta
    low, high = spec.reps_low, spec.reps_high
    weight = spec.weight_kg
    step = int(round(-adjustment.rpe_delta))

    if step:
        if low - step < DELOAD_MIN_REPS:
            if weight is not None:
                weight = _round_load(weight * 0.925)
            reasons.append(
                f"Recovery cut taken as LOAD, not reps: {low} reps minus {step} "
                f"would leave under {DELOAD_MIN_REPS}, so the reps hold and the "
                f"weight comes down 7.5% instead (:323)."
            )
        else:
            low, high = low - step, max(low - step, high - step)
    if adjustment.load_multiplier != 1.0 and weight is not None:
        weight = _round_load(weight * adjustment.load_multiplier)

    return SetSpec(weight, low, high, rpe, bodyweight=spec.bodyweight)


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
    """The top set for today, from the wave and what was logged last time.

    When the load moves, the reps are prescribed as the whole band with the
    target RPE deciding where in it the set lands — the prompt's own example
    is "this cycle opens at 210kg x6-8". A single count at the bottom read as
    a target, and failed the prompt's coherence check (:176): after 220kg x10
    at RPE 9, six reps at 222.5kg is nowhere near RPE 8. It also fed the
    deload a six-rep peak set and turned "stop two reps short" into a 17.5%
    load cut. "Reps reset to the bottom" is the floor of the band, not a cap.
    """
    targets = WAVE[week]
    low, high = TOP_SET_RANGE[kind]
    bodyweight = is_bodyweight(exercise) or bool(prior and prior.bodyweight)

    # A bodyweight movement with a logged set HAS a load — the athlete — and
    # progression writes it as "BW". Reading that as "no load" deferred every
    # pull-up as a feel-out; reading it as a number raised TypeError and took
    # the whole session's proposal down with it, on every Pull and Push day.
    if prior is None or (prior.load is None and not bodyweight):
        deferred.append(
            f"{exercise}: no logged history, so no opening load can be computed. "
            f"The programme calls this a genuine feel-out — ramp in clear steps and "
            f"find where {low}-{high} reps lands at RPE {targets['top']:g}."
        )
        return SetSpec(None, low, high, targets["top"])

    load = (prior.load or 0.0) if bodyweight else prior.load
    if bodyweight and isinstance(load, str):
        load = 0.0

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
        return SetSpec(load, low, high, targets["top"], bodyweight=bodyweight)

    if week == 2:
        # :182 — "Keep the Week 1 weight and reach RPE 8 by adding reps toward
        # the top of the range. If last week already hit the top of the range at
        # RPE <=8, add 2.5-5kg instead and reset reps to the bottom."
        #
        # :205 first: reps ABOVE the range are a backlog whatever the RPE was.
        # The generic branch below the week ladder applies it, but every week
        # returns before reaching that branch, so 12 reps at RPE 9 on a 6-10
        # range was told to "add reps toward the top" of a range it had left.
        if prior.reps is not None and prior.reps > high:
            step = INCREMENT[kind]
            load = _round_load(load + step)
            reasons.append(
                f"Load up ~{step:g}kg and OVERDUE: {prior.reps} reps is above the "
                f"top of the {low}-{high} range, so the increase was already due "
                f"(:205). Reps reset to the bottom."
            )
            return SetSpec(load, low, high, targets["top"], bodyweight=bodyweight)
        if _met_top_of_range(prior, kind, targets["top"]):
            step = INCREMENT[kind]
            load = _round_load(load + step)
            reasons.append(
                f"Week 2 adds ~{step:g}kg: week 1 already reached the top of the "
                f"{low}-{high} range at RPE {prior.rpe:g}, so reps have nowhere left "
                f"to go (:182). Reps reset to the bottom."
            )
            return SetSpec(load, low, high, targets["top"], bodyweight=bodyweight)
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
            return SetSpec(load, low, high, targets["top"], bodyweight=bodyweight)
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
        if reps < DELOAD_MIN_REPS and bodyweight and not load:
            # No added load to drop and no stack to lower: the floor holds.
            reps = DELOAD_MIN_REPS
            deferred.append(
                f"{exercise}: a deload by load is not available at bodyweight, "
                f"so the reps hold at {DELOAD_MIN_REPS} instead of "
                f"{(prior.reps or high) - max(drop, 0)}. Decide whether an "
                f"easier variation is the better deload."
            )
        elif reps < DELOAD_MIN_REPS:
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
        return SetSpec(load, low, high, targets["top"], bodyweight=bodyweight)

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
        return SetSpec(load, low, high, targets["top"], bodyweight=bodyweight)

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
        # Shed, not scaled: 20% off a 2.5kg plate is a 2kg plate, which no
        # gym has and which changes nothing about the set. The reason line
        # below always said "sheds the added load"; now the number does too.
        load = None
        reasons.append(
            "Back-off sheds the added load and stays at bodyweight — a bodyweight "
            "movement cannot drop 20% of the athlete (:64 applied to the added "
            f"load only), at RPE {rpe:g} for week {week}."
        )
    elif top.weight_kg is None:
        load = None
    else:
        load = _round_load(top.weight_kg * (1 - BACKOFF_DROP))
        if load >= top.weight_kg:
            # A working load small enough that 20% of it rounds to nothing. A
            # back-off at the top-set load is not a back-off; take one grid
            # step down so the drop exists.
            load = max(0.0, top.weight_kg - _LOAD_GRID)
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
    # From the catalog, like everything else here. PRIMARY_MUSCLE knows the
    # seven Pull movements and nothing else, so on Push and Legs every lift
    # read as the first for its muscle and a warm chest got a full ramp on the
    # fourth pressing movement of the day.
    primary = primary_muscle(exercise) or PRIMARY_MUSCLE.get(exercise, "")
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


def norm_name(name: str) -> str:
    """Fold an exercise name to a comparison key.

    The template says "Pull-Ups". The log holds whatever the resolver wrote on
    the day, and the two logging paths do not agree — the iOS app resolves
    through the exercises library, Telegram through find_exercise. Comparing raw
    strings makes "Pull Ups" a different exercise from "Pull-Ups", which is the
    difference between "no logged history" and a real opening load.
    """
    return "".join(ch for ch in name.lower() if ch.isalnum())


def prescribe_session(plan, week: int,
                      history: dict[str, PriorSet],
                      recovery: dict | None = None,
                      peak_history: dict[str, PriorSet] | None = None) -> list[Proposal]:
    """Every exercise in `plan`, for this week, given this history.

    `history` maps exercise name to its most recent top working set — the same
    thing progression.get_current_loads already returns, so this consumes a
    readout that exists rather than re-deriving one from the log.

    `recovery` is today's readings. When they trigger :315-319 the adjustment
    is applied HERE, to every set, before anything renders — because :323 makes
    the reduction a change to reps and load as well as RPE, and those three
    only stay coherent while they are decided together. Checking them apart
    afterwards is what mistook the reduction for drift and undid it.

    `peak_history` is the same shape, holding each lift's top set from the
    most recent WEEK 3. Week 1 opens from it and week 4 deloads against it
    (:181, :185); `history` is the most recent session, which going into a
    deload is the peak week and coming out of one is the deload itself — so
    without this the wave opened every cycle from its own softest week.
    """
    if week not in WAVE:
        raise ValueError(f"mesocycle week must be 1-4, got {week!r}")

    # Look up through norm_name rather than by raw key. Callers key this dict
    # differently — progression.get_current_loads by whatever spelling the log
    # holds, the replay by its own fold — and an exact-match lookup silently
    # returns None for every near miss, which reads downstream as "this
    # exercise has never been trained" and prescribes a feel-out instead of a
    # load. Building the view here means no caller has to know the convention.
    folded = {norm_name(name): prior for name, prior in history.items()}
    peak = {norm_name(name): prior for name, prior in (peak_history or {}).items()}

    adjustment = recovery_adjustment(recovery)

    proposals = []
    muscles_warm: set[str] = set()
    for exercise, sets, kind in plan:
        key = norm_name(exercise)
        prior = folded.get(key)
        if week in (1, 4) and peak.get(key) is not None:
            prior = peak[key]
        proposal = prescribe_exercise(
            exercise, sets, kind, week, prior, set(muscles_warm)
        )
        if adjustment.adjusted:
            proposal = _adjusted(proposal, adjustment)
        proposals.append(proposal)
        muscles_warm.update(warms(exercise))
    return proposals


def _adjusted(proposal: Proposal, adjustment: RecoveryAdjustment) -> Proposal:
    """Re-issue one exercise with today's recovery applied to every set.

    The warm-up ramp carries a LOAD cut but not an RPE cut. A ramp is not
    effort — :62 says warm-ups "are not working sets" — so dropping the RPE
    target means nothing to it. But its weights are absolute, computed from the
    working set at ~55/75/88%, so a 5% cut to the top set leaves the last ramp
    single at 93% of it instead of 88%: heavier, relative to the day, than on a
    full-intensity day. It gets the same multiplier.

    A recovery session is NOT prescribed by scaling this one down. :316 says
    "switch to recovery session", which is a different session — a decision
    about what to train, not how heavy. It is surfaced as deferred so the coach
    makes it out loud, which is what the rule asks for.
    """
    reasons = list(proposal.reasons)
    deferred = list(proposal.deferred)

    if adjustment.recovery_session:
        deferred.append(
            f"{proposal.exercise}: today's readings call for a RECOVERY SESSION "
            f"rather than this one, so the programme prescribes NOTHING here — "
            + "; ".join(adjustment.reasons) +
            ". The programme does not substitute the session for you: say what "
            "you are doing instead and why it protects the block (:316)."
        )
        return replace(proposal, deferred=deferred, working=[], backoff=[],
                       warmup=[], recovery_session=True)

    working = tuple(apply_recovery(w, adjustment, reasons) for w in proposal.working)

    # Everything else follows the TOP SET's actual movement, not its own copy
    # of the rules. Applying the levers to each set independently was wrong in
    # both directions at once: apply_recovery's low-rep escape hatch can drop
    # the working load 7.5% without touching `load_multiplier`, so the ramp —
    # which only watched the multiplier — stayed put, and a "warm-up" triple
    # ended up at 95% of the day's working weight. Meanwhile the back-off, cut
    # by a different amount than the top set, drifted to 13.5% below it,
    # outside :64's 15-25% band, while the reason handed to the coach still
    # claimed "20% below the top set, inside the 15-25% band".
    #
    # A ramp is a fraction of the working weight and a back-off is a fraction
    # of the working weight. Both stay fractions of it.
    before = proposal.working[0].weight_kg if proposal.working else None
    after = working[0].weight_kg if working else None
    ratio = (after / before) if (before and after) else 1.0

    def _scaled(spec):
        if spec.weight_kg is None or ratio == 1.0:
            return spec
        return SetSpec(_round_load(spec.weight_kg * ratio), spec.reps_low,
                       spec.reps_high, spec.rpe, bodyweight=spec.bodyweight)

    # Back-offs take the rep and RPE change from the wave, and the LOAD change
    # from the top set — never their own load lever, which is what let the two
    # drift apart.
    backoff = []
    for b in proposal.backoff:
        moved = apply_recovery(_scaled(b), adjustment, [])
        backoff.append(SetSpec(_scaled(b).weight_kg, moved.reps_low,
                               moved.reps_high, moved.rpe,
                               bodyweight=b.bodyweight))
    backoff = tuple(backoff)
    warmup = [_scaled(w) for w in proposal.warmup]
    # PREPENDED, not appended. format_proposal keeps only the first reason per
    # exercise (:170), so an appended recovery reason is computed, rendered and
    # then dropped before the coach ever sees it — the cut happens to the
    # numbers and the explanation for it silently does not arrive. :315 says
    # "reduce RPE targets by 1. Flag it." The flag is the half that was lost.
    recovery_notes = list(adjustment.reasons)
    # apply_recovery records the lever it used ("taken as LOAD, not reps"),
    # which :323 requires be stated either way. It lands in `reasons`, so lift
    # it across rather than leaving it to the truncation.
    lever = [r for r in reasons if "Recovery cut taken" in r]
    recovery_notes += [r for r in lever if r not in recovery_notes]
    reasons = [r for r in reasons if r not in lever]
    return replace(proposal, warmup=list(warmup), working=list(working),
                   backoff=list(backoff), reasons=reasons, deferred=deferred,
                   recovery_reasons=recovery_notes)


def prescribe_pull(week: int, history: dict) -> list:
    """The Pull day, from the plan compiled into this module.

    Kept because the replay calls it, and because PULL_DAY is the one plan
    written down here rather than read from the prompt.
    """
    return prescribe_session(PULL_DAY, week, history)


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


# ---------------------------------------------------------------------------
# Rendering a computed session as prescription blocks
# ---------------------------------------------------------------------------
#
# The point of this module was always that load, reps and RPE are ONE decision.
# next_top_set picks all three together from the wave and the logged history;
# the back-off drop and its rep step-down follow from the top set; the warm-up
# ramp follows from the working weight. Split them apart and each is nonsense
# on its own — an RPE is a claim about reps in reserve AT a load, so "same
# weight, same reps, higher RPE" says nothing at all.
#
# That is why this renders the whole block rather than exposing the numbers for
# something else to reassemble. Anything that edits one field of a rendered
# block has, by construction, broken the coupling that made the three correct.


def _fmt_load(spec: "SetSpec") -> str:
    """`60kg`, `62.5kg`, `BW`, `BW + 15kg`, or `[load TBD]`.

    `BW + 15kg` is the prompt's own spelling (:274, :782). Both parsers read
    it as 15kg, which is also what a logged weighted pull-up is stored as, so
    the number on the card and the number in the log agree."""
    if spec.bodyweight:
        if not spec.weight_kg:
            return "BW"
        return f"BW + {spec.weight_kg:g}kg"
    if spec.weight_kg is None:
        return "[load TBD]"
    return f"{spec.weight_kg:g}kg"


def _fmt_reps(spec: "SetSpec") -> str:
    if spec.reps_high > spec.reps_low:
        return f"x{spec.reps_low}-{spec.reps_high}"
    return f"x{spec.reps_low}"


def _fmt_set(spec: "SetSpec", with_rpe: bool = True) -> str:
    body = f"{_fmt_load(spec)} {_fmt_reps(spec)}"
    return f"{body} RPE{spec.rpe:g}" if with_rpe else body


def _fmt_rest(seconds: int) -> str:
    """Whole minutes as "2min", anything else as seconds.

    The "1min30" form this used to emit for 90 seconds appears nowhere in the
    prompt and BOTH iOS parsers truncate it at the "min" — reading 90 seconds
    as 60. Isolation work rests 90s, so that was a third of the rest gone from
    4 of 8 exercises on Push, 3 of 7 on Pull, 4 of 6 on Legs and every one on
    Cardio+Abs. The docstring it replaces claimed these were "the shapes
    coach_parsing already reads", which was the part worth checking and was not
    checked: the function could never produce "90s" at all.
    """
    if seconds % 60 == 0:
        return f"{seconds // 60}min"
    return f"{seconds}s"


def _is_straight_set(exercise: str) -> bool:
    """Direct ab work is straight sets at one load, with no back-off line.

    Same test coach_parsing._set_shape uses, and for the same reason it was
    added there: the shape is a property of the movement, not of the count.
    Deciding it through the muscle map rather than a list here means a renamed
    or added ab movement is picked up without a second list to maintain.
    """
    from volume import resolve_muscle_group
    return resolve_muscle_group(exercise) == "Abs"


def render_block(proposal: "Proposal", tempo: str | None = None) -> str:
    """One computed exercise as the block format the parser and card expect.

    Warm-ups deliberately carry no RPE: they are a ramp, not effort, and
    :62 calls them "not working sets". The parser reads a warm-up entry as
    weight and reps only, so an RPE there would be dropped anyway.

    A block is emitted even when the load is undetermined. `[load TBD]` is the
    honest rendering of a genuine feel-out — the alternative is silence, and
    silence is what leaves the card reading "No plan yet".
    """
    lines = [f"*{proposal.exercise}*"]
    straight = _is_straight_set(proposal.exercise)
    # :61 "Every exercise (EXCEPT ABS) follows this structure" — and the three
    # parts it then lists are the warm-up, the working set and the back-off.
    # Ab work gets neither a ramp nor a drop, only its sets.
    if proposal.warmup and not straight:
        lines.append("Warm-up: " + ", ".join(
            _fmt_set(w, with_rpe=False) for w in proposal.warmup))

    if straight:
        # Every set enumerated at one load, which is what the count means here.
        # prescribe_session still models an ab exercise as a top set plus
        # back-offs, so the total is what those two add up to.
        top = proposal.working[0]
        working = ", ".join([_fmt_set(top)] * (len(proposal.working) + len(proposal.backoff)))
    else:
        working = ", ".join(_fmt_set(w) for w in proposal.working)

    suffix = f" | Tempo: {tempo}" if tempo else ""
    lines.append(f"Working Set: {working}{suffix}"
                 f" | Rest: {_fmt_rest(proposal.rest_seconds)}")

    if proposal.backoff and not straight:
        lines.append("Back-off: " + ", ".join(_fmt_set(b) for b in proposal.backoff))
    return "\n".join(lines)


def is_determined(proposal: "Proposal") -> bool:
    """Did the programme actually settle a load for this exercise?

    A lift with no logged history genuinely is the coach's call — :296 calls it
    "a genuine feel-out". Rendering `[load TBD]` into a block would be worse
    than saying nothing: it does not parse, so the card silently loses the
    exercise, and it dresses an open question as a computed answer.
    """
    if proposal.recovery_session or not proposal.working:
        return False
    return all(spec.weight_kg is not None or spec.bodyweight
               for spec in list(proposal.working) + list(proposal.backoff))


def render_session(proposals: list, tempos: dict | None = None) -> tuple[str, list]:
    """Every DETERMINED exercise for today, plus the names of those left open.

    Returns the blocks and the exercises the coach still owns, so the caller can
    tell the difference between "the programme has this" and "nobody does".
    """
    tempos = tempos or {}
    determined = [p for p in proposals if is_determined(p)]
    open_ones = [p.exercise for p in proposals if not is_determined(p)]
    blocks = "\n\n".join(render_block(p, tempos.get(p.exercise)) for p in determined)
    return blocks, open_ones
