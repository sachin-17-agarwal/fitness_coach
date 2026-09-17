# Implementation plan

How each approved item in `docs/ROADMAP.md` gets built, in the order it
gets built, starting Thursday 17 September 2026. The roadmap says what and
why; this says which files, which steps, which tests, what is checked on
the phone, and what is needed from the athlete before a step can start.

Working rules, unchanged: one PR per item or per stage of an item,
squash-merged, branch reset onto main. Python tests run before every push.
Swift is verified on the phone until 2.4 gives it tests of its own.
Anything that changes what the coach says goes behind a gate in
`docs/OPTIMISATION.md`.

## Calendar

Status on the evening of Thursday 17 September. The deload week was used
to ship the queue early; migrations 006, 007 and 008 have been run.

**Shipped 16 Sep**

| Item | PR | On the phone after the next build |
|---|---|---|
| 2.1(a) thinking vs text in the Sunday report | #249 | — (backend; columns fill from tonight's calls) |
| 2.3 overshoot step sized to the miss | #249 | — (backend) |
| 2.2 HELD state | #251 | Shoulders row, hero line, map, hand-off |
| 2.1(b) start on the programme, coach catches up | #252, #253 | START card at once; label; change notes |
| 2.7 export | #254 | Settings → Export |
| 2.5 block review, dry run | #255 | Home briefing the morning after rollover; "block review" in chat |
| Card reference line = last session on the lift | #250 | grey line under the set chips |
| Revised block still owes its sets; past-the-plan label | #247 | logger label |
| Failed lookup ≠ no history; emphasis supersedes; volume table | #244–#246 | — (backend) |

**Remaining**

| Day | Work | Needs from you |
|---|---|---|
| ~~Thu 17 Sep~~ done | ~~Verify on the phone~~: HELD row, START opening on Push (card at once, coach landed), export (five CSVs) all confirmed; reference line and logger label still to glance at · ~~first `text`/`thinking` split~~ read: opening 83% thinking; Stage 5 first cut −20% on set replies | — |
| ~~Fri 18 Sep~~ shipped Thu 17 Sep | ~~Item 4: raise the context fetch ceiling, log per-query timings~~ (#264: ceiling 20 s, every fetch timed, the build recorded as a `context` row in the Sunday report with the slowest fetch named) | — |
| ~~Sun 20 Sep~~ pulled to Thu 17 Sep | ~~2.11 bodyweight progression~~ (approved 17 Sep evening, shipped the same night; see the section below) · pulled forward with it: the decision-capture design (item 3, written: `docs/DECISION_CAPTURE.md`) and the 2.9 widget mockups (published, link in the 2.9 section) | approve or amend the design; pick a widget direction |
| Sat 19 – Sun 20 Sep | Read the 20 Sep report: Stage 5 cache reading, adjust rate and its four buckets, first shadow rows, first thinking/text split · decide band per week vs rotation and recompute the on-paper table at the measured rotation rate | the band decision |
| Mon 21 Sep | 2.4 Swift test target and the first thirty tests | add the Unit Testing Bundle target in Xcode (two minutes) |
| Week of 28 Sep | ~~2.9 widget build~~ (shipped 17 Sep) · decision capture build if the design is approved · block review: read the dry run when it lands on Home, answer it, compare | read the review the morning it appears |
| Tue 30 Sep | Review 2.1(c) geofence: does START still feel slow? | your answer |
| After | 2.5 goes live (dry_run off) once the first review has been compared · 2.8 watch, timer stage first | mockups approval |

Two days of slack remain; an item that overruns takes the next slot.

---

## 2.1(a) Split thinking from visible output in the report

**Goal.** The report's `out` column mixes thinking and text. Each row
records the length of the text the athlete actually received, so the
Sunday table shows thinking and text apart and 2.1's later steps are
judged on numbers.

**Files.** `migrations/006_model_calls_visible.sql` (new), `usage.py`,
`plan.py`, `coach.py`, `tests/test_plan_contract.py`.

**Steps.**
1. Migration 006: `ALTER TABLE model_calls ADD COLUMN IF NOT EXISTS visible_chars INTEGER;`
2. `record_call(..., visible_chars=)`: the length of the concatenated text
   blocks of the response. All three call sites pass it.
3. `summarise`: per kind, `visible_median` (chars ÷ 4 as tokens) and
   `thinking_median = out_median − visible_median`, floored at zero.
4. `format_report`: two new columns, `text (med)` and `thinking (med)`. A
   row without the column (older rows) counts as unknown, not zero.
5. Tests: a row with 8,000 out and 6,000 visible chars reports 1,500 text
   and 6,500 thinking; a row without the field reports unknown.

**Verify.** Run the report workflow by hand after the next Push; the plan
row shows the split.

**Gate.** None; measurement only.

## 2.3 Rep-overshoot step sized to the overshoot

**Goal.** A top set three or more reps over its range moves the next load
so the range is reachable, capped at +10% a session, with the arithmetic
on the card. One- and two-rep overshoots keep the single increment.

**Files.** `prescribe.py` (the three branches that already handle
`prior.reps > high`: week 2 at ~line 587, the generic branch at ~line 684,
and week 1's `>= high` opening at ~line 562), `tests/test_prescribe.py`.

**Steps.**
1. Helper `_overshoot_step(prior, low, high, kind) -> (load, reason)`:
   `e1rm = load × (1 + reps/30)`; target load for the middle of the range
   `e1rm / (1 + mid/30)`; step `= min(target − load, load × 0.10)`, never
   below one increment; rounded with `_round_load`.
2. Each branch: if `reps − high >= 3`, use the helper and a reason of the
   form "Load 121: 16 reps at 110 puts 10 reps near 126; capped at +10%
   this session (:205)". Otherwise unchanged.
3. Week 1 opening keeps its own wording ("Week 1 opens above last cycle")
   with the sized step.
4. Tests: 110 × 16 on 8–12 → 121 (the cap binds); 100 × 15 on 8–12 → 110;
   100 × 13 on 8–12 → one increment, unchanged; 60 × 14 on 12–15 → one
   increment (two over); ceilings still win afterwards
   (`apply_ceilings`).

**Verify.** Next Legs opening: the Seated Leg Curl card shows the sized
step and its Why line.

**Gate.** Audit rule-break rate over the block must not rise (gate 1).

## 2.11 Bodyweight and straight-set progression

**Goal.** A bodyweight lift has the same levers as a stack lift, and a
three-session stall is answered by the prescription, not only flagged in
the readout.

**Files.** `prescribe.py` (`BODYWEIGHT_INCREMENT`, `STALL_SESSIONS`,
`_increment`, `_bodyweight_overshoot`, `PriorSet.held`, the stall branch
ahead of the week 2 ladder, `athlete_kg` threaded through
`prescribe_session` → `prescribe_exercise` → `next_top_set`),
`progression.py` (`_held_sessions`, `find_current_loads` row key `held`),
`programme.py` (`_history` carries `held`; `build_proposal(athlete_kg=)`),
`coach_context.py` (fetches `latest_bodyweight_kg` in the pool as
`bodyweight` and passes it), `tests/test_prescribe.py`
(`BodyweightProgressionTests`), `tests/test_regressions.py`
(`HeldSessionsTests`).

**Rules, as shipped.**
1. Added load on a bodyweight movement steps by 2.5 kg. Isolation stack
   lifts keep 1 kg, compounds 2.5 kg.
2. Three or more reps over the range on a bodyweight movement: size on
   `added + fraction × weigh-in` with the same Epley-to-mid-range step and
   +10% cap as 2.3, then round to plates and never less than one plate.
   No weigh-in, or a movement with no body share (rollout, hollow hold):
   one plate.
3. `held ≥ 3` with the reps inside the range but under the top, in weeks
   2 and 3 and the generic branch: RPE ≤ target − 1 pins reps at the top
   as a count and says "STALLED N sessions at …"; otherwise the rep
   prescription stands and a deferred line names the stall and hands the
   lever to the coach.
4. First added load on a movement with no body share carries the line
   "a plate on the back or a vest; if impractical, a harder variation is
   the coach's call".

**Worked numbers.** Hanging Leg Raises +5 kg × 15 at 80 kg athlete →
+7.5 kg (33 kg lifted, cap binds). Pull-Ups +10 kg × 13 in week 3 → +20 kg.
Ab Wheel Rollout BW × 8 at RPE 6.5, held 7 → BW × 12 as a count. Cable Row
80 × 8 at RPE 7, held 3, week 3 → 80 × 10.

**Verify.** Next Cardio+Abs opening: the rollout card reads a count if it is
still at × 8; the leg raise step is a plate. The Decisions report's
progression bucket should fall over the next block.

**Gate.** Rule-break rate over the block must not rise (gate 1).

## 2.2 HELD state for lifts under a standing decision

**Goal.** A lift capped by a `Decision:` reads HELD, not DROPPING, on the
Strength tab, the body map, the hero and the coach hand-off, until the
decision is cleared. A PR still reads PR.

**Files.** `Vaux/Vaux/Services/SupabaseClient.swift` or a new
`ConstraintsService.swift` (fetch `exercise_constraints where active`),
`Vaux/Vaux/ViewModels/StrengthViewModel.swift`,
`Vaux/Vaux/Views/History/StrengthTabView.swift`, the body map colour
table, the legend, `HistoryView.swift` (pass the constraints into
`rebuild`).

**Steps.**
1. Model `StandingConstraint { exercise, maxLoadKg?, note?, setOn }`;
   fetch once per History load, keyed by `PrescriptionParser.normalizeExerciseName`.
2. `StrengthState` gains `.held` with label "HELD", ink and map colour
   `Editorial.blue`, `attention` between `.hold` and `.drop`.
3. `judge(...)` takes `constraint: StandingConstraint?`; after the PR
   check, `if constraint != nil { state = .held }`. `LiftReport` carries
   the constraint.
4. Row eyebrow "HELD · CAP 70 KG · SINCE 13 SEP", subtitle carries the
   note; the estimate and the delta stay visible in grey as information.
5. Hero: `heldCount`; third line "1 HELD" when nothing is stalled or
   dropping, joined with " · " otherwise; held lifts leave the "lifts up"
   denominator.
6. Body map: `.held` paints blue. Legend gains HELD.
7. Hand-off text: "Machine Shoulder Press is held at 70 kg by decision
   (shoulder niggle) since 13 Sep; its −8.3% is expected."
8. Balance ratios: a held side shows "HELD" beside the ratio.

**Verify.** Shoulders row reads HELD with the cap and note; hero says
"20 of 21 lifts up · 1 held"; front delts blue; the hand-off names the
decision. Then `Decision: Machine Shoulder Press | clear` in chat and the
row returns to a verdict on the next load.

**Needs from you.** The decision recorded in chat, if not already:
`Record a decision: Machine Shoulder Press, shoulder niggle, hold at 70 kg, RPE 8 cap, progress by reps only`.

**Gate.** None; display and hand-off only.

## 2.1(b) Start on the programme, the coach catches up

**Goal.** START shows the card at once with the programme's numbers,
labelled "PROGRAMME · COACH REVIEWING". The coach's review lands as now;
where it agrees the label changes, where it differs that exercise updates
with its Why line and a note naming the change and its cause. No extra
model call; nothing fires on tab open.

**Backend files.** `coach.py` (split `chat_with_coach`'s plan path into
`open_session()` and `review_session()`), `webhook.py` (two routes),
`plan.py` (render a programme-only `SessionPlan` via
`fill_from_programme`; a `diff_plans()`), `data.py` (today's plan store
gains `source: programme|coach` and `status: reviewing|reviewed|failed`),
`tests/test_plan_contract.py`, `tests/test_regressions.py`.

**Backend steps.**
1. `open_session(session_type, memory, recovery_override)`: builds the
   context once, renders the programme's plan (accept every proposal;
   every card line carries "Why: programme"), stores it as today's plan
   with `source=programme, status=reviewing`, appends the athlete's
   opening message to the conversation, returns the rendered text. Under
   one second; no model call.
2. `review_session()` runs the existing `request_session_plan` on a
   worker thread started by `open_session`, with the same system blocks.
   On success: `save_decisions`, store the coach's plan with
   `source=coach, status=reviewed`, append the assistant message to the
   conversation as today. On failure or after the 30 s budget plus one
   retry: `status=failed`, the programme plan stands, one log line.
3. `diff_plans(programme, coach)`: per exercise, `unchanged | changed
   {field, from, to, cause}` from the coach plan's own reasons. Returned
   by the status route so the app updates only what moved.
4. Routes: `POST /api/session/open` → `{plan_text, status}`;
   `GET /api/session/status` → `{status, plan_text?, changes[]}`.
   `POST /api/chat` is unchanged for everything else, including the old
   START message, so an older build keeps working.
5. Set replies logged while `status=reviewing` use the programme plan
   (already stored, same `load_today_plan` path). When the review lands,
   an exercise with logged sets keeps those sets; the coach's change
   applies to its remaining sets only, and the note says so.
6. Tests: open returns in the programme's shape with no model call;
   review stores and diffs; a failed review leaves the programme plan
   standing; a set logged mid-review reads the programme plan; the diff
   names the cause.

**App files.** `Vaux/Vaux/ViewModels/WorkoutViewModel.swift` (START flow
at ~line 231), `Vaux/Vaux/Services/WorkoutService.swift` (two calls),
`Vaux/Vaux/Views/Workout/PrescriptionCard.swift` (label and change
note), `WorkoutModeView.swift`.

**App steps.**
1. START calls `open`; the card renders from `plan_text` immediately with
   the eyebrow "PROGRAMME · COACH REVIEWING" and a soft pulse on the
   label only.
2. Poll `status` every 5 s for up to 3 min, only while the workout screen
   is open. On `reviewed`: apply `changes[]` exercise by exercise, label
   becomes "COACH", a changed exercise shows its Why line and a one-line
   note "Coach: 72.5 → 70 kg, HRV below baseline" for that session. On
   `failed` or timeout: label becomes "PROGRAMME", no error dialog.
3. The chat transcript shows the coach's message when it lands, as now.
4. An exercise the athlete has already started is not re-rendered above
   the logged sets; the remaining sets update.

**Verify.** On Push: the card appears within a second of START; the coach
label lands during the warm-up; a deliberately capped lift (Machine
Shoulder Press) shows a change note only if the coach moved it. On Pull:
the same with no change expected. Check `reports/model_calls.md` the
following Sunday: plan calls per training day still 1.

**Gate.** Adjust rate from `prescription_decisions` in the Sunday report
(how often the coach changes the programme) — this is the visible-change
frequency; if it is above one exercise in three, the note design is
revisited before 2.1(c). Audit gate 1 unchanged.

**Review date for 2.1(c) geofence.** Two weeks after this ships; the
question is only whether START still feels slow.

## 2.4 Swift tests for the numbers

**Goal.** The pure calculations behind the History tab and the Home
readiness read run as tests in Xcode, so a change in one place cannot
quietly move a number elsewhere.

**Needs from you first.** In Xcode: File → New → Target → Unit Testing
Bundle, product name `VauxTests`, target to test `Vaux`, then commit the
project file. Adding a target by hand to the objectVersion 77 project
file is not worth the risk.

**Files.** `Vaux/VauxTests/Fixtures.swift` (builders for `WorkoutSet`,
`WorkoutSession`, `Recovery`, `BlockCalendar`), then one file per subject:
`StrengthJudgeTests.swift`, `TonnageTests.swift`, `VolumeTests.swift`,
`RecoveryFactsTests.swift`, `RecoveryDigestTests.swift`,
`ReadinessScoreTests.swift`.

**First thirty tests**, each one a bug that has already happened or a
rule that is easy to break:
- Epley on 12 reps; a 13-rep set produces a loose point only when no
  tighter set exists that week; a 12-rep set in the same week wins.
- A lift with no peak-week set is unjudged in the current block; one
  peak-week set opens its verdict.
- PR beats every other state; drop needs −5%; hold inside ±1%; stall
  after two blocks without a PR.
- HELD from a constraint (after 2.2), PR still wins.
- Hero counts: stalled and dropping counted apart; held outside the
  denominator.
- Tonnage: dips count the weigh-in plus the plate; leg raises 0.35 of
  bodyweight; a missing weigh-in falls back to the latest.
- Weekly volume: fractional sets, dates not week numbers, an eight-day
  block spans two weeks.
- Recovery facts: baseline band from 42 days ending a week ago, log
  space; fewer than five readings gives no band; a night under 2 h is
  missing data; sleep windows include segments before midnight.
- Recovery digest: the three sentences from a fixed week; tap agreement
  buckets; no card outside Monday/Tuesday.
- Composite readiness: anchors at 8 h → 100, 5 h → ~32.

**Run.** Cmd+U. Later, optionally, a GitHub Actions macOS job on PRs.

**Gate.** None.

## 2.7 Export

**Goal.** Settings → "Export training log" writes one CSV per table and
opens the share sheet.

**Files.** `Vaux/Vaux/Views/Settings/…` (one row), new
`Vaux/Vaux/Services/ExportService.swift`, `SupabaseClient.swift` (paged
fetch helper).

**Steps.** Tables: `workout_sessions`, `workout_sets`, `recovery`,
`exercise_constraints`, `prescription_decisions`, weigh-ins if separate.
Page 1,000 rows at a time; write to a temp folder named by date; present
`ShareLink` with all files. Progress line while fetching; a failure names
the table.

**Verify.** Export, save to Files, open one CSV in Numbers; row counts
match the History tab's counts for a known week.

**Not built unless asked.** The nightly snapshot job, because it is
health data and belongs in storage you own.

## 2.9 Widget: the day's stats

**Goal.** A medium and a large widget for the hours outside the gym.

**Shipped 17 Sep (built the same night, on request).** The Home readiness
hero as a widget — https://claude.ai/artifact/2nfvyuwbrBY9pkqzJhcuE1 —
medium, small and a lock-screen tile. Anton readiness figure in the verdict
colour, the verdict line naming today's session, week and phase, the block's
strength gain, HRV with its delta, sleep. Nothing else.

**How the numbers reach it.** `GET /api/widget` is the widget's one read:
`readiness.py` computes the score on the server with the formula
`Recovery.compositeScore` runs on the phone (anchors pinned in
`tests/test_widget.py`), the verdict is the Home line naming the session,
the week and phase come from memory, and the strength number is the
Strength tab's own — `HistoryViewModel` posts it to
`POST /api/widget/strength` whenever it recomputes, and asks WidgetKit to
redraw. The timeline re-reads about every 45 minutes and whenever Home
loads. A dead network shows the last good read.

**Files.** `readiness.py`, `webhook.py` (`/api/widget`,
`/api/widget/strength`, `widget_verdict`), `Vaux/VauxWidgets/ReadinessWidget.swift`
(payload, provider, three sizes), `VauxWidgetsEntryPoint.swift`,
`VauxWidgets/Info.plist` (Anton registered) and `Anton-Regular.ttf` beside
it, `Shared/Config.swift` (moved from the app folder so the extension shares
the backend address), `ChatService.postWidgetStrength`, `HistoryViewModel`
and `DashboardViewModel` reloads.

**Verified 18 Sep.** Medium and lock-screen live on the phone: 74% amber,
"STEADY — LEGS, AS PLANNED", week 4 deload, strength ▴7.9%, HRV 40, sleep
5:55. The lock tile's first line was clipped at full tracking; now the
session leads ("LEGS · STEADY") at tighter tracking.


**Verify.** Add both sizes; numbers match Home and Strength at the same
moment.

## 2.5 Block review as a coach conversation

**Delivery changed 17 Sep.** The review is prepared and shown by Home's
`GET /api/block-review` (same guards: week 1 day 1, no active workout,
once per block) and answered from the Home card via
`POST /api/block-review/answer` or in chat. The briefing route still
prepends it, but nothing depends on the briefing being opened.

**Goal.** The morning after the block's last session, on a rest day, a
Home card and a waiting coach message carry the review and two or three
proposed changes; "yes to 1 and 3" records them.

**Backend files.** New `block_review.py` (fact sheet), `system_prompt.txt`
(a short "Block review" section), `coach.py` (trigger and approval
parsing), `webhook.py` (`GET /api/block-review`), `data.py` (a
`block_reviews` table via migration 007: block, facts JSON, narrative,
proposals JSON, status `draft|shown|answered`, dry_run flag),
`tests/test_block_review.py`.

**Steps.**
1. Fact sheet in code: per-lift peak versus peak from the same rows the
   app uses, PRs, held and dropped with the reason on record, volume
   against bands, the recovery read over the block, the stored plan
   decisions. Cross-checked against the app's numbers with a shared
   fixture (2.4 gives the Swift side).
2. Narrative and proposals from the model, from the fact sheet only.
   Proposals also in the existing line grammar (`Decision:`,
   `Emphasis-next:`). A check that every number in the narrative appears
   in the sheet, like the accept-honesty rule.
3. Delivery: prepared when the block's last session is logged; shown from
   the next morning (`BriefingService` already runs then) as a Home card
   and a coach message; never inside a session. Stays until answered. If
   the new block's first session arrives first, week 1 opens on programme
   defaults, the coach says so in one line, the review stays.
4. Approval: "yes to 1 and 3", "approve all", "no" parsed; only approved
   lines are recorded through the existing paths. Nothing recorded
   otherwise.
5. Dry run: the first block writes and shows the review with
   `dry_run=true`; nothing is recordable; you tell me what you would have
   decided and we compare.

**Gate.** Gates 1–3; the narrative-cites-facts check; one dry-run block.

## 2.8 Apple Watch, timer stage

**Goal.** The rest timer on the wrist with haptics and the next prescribed
set shown; the phone stays the coach.

**Mockups first.** Then a watchOS target, `WatchConnectivity` from
`RestActivityController`, haptic at ten seconds and zero, the deploy
script installing the watch app with the phone app. Logging from the
wrist is stage two, after the timer has been used for a block.

---

## Reporting

Every session I post: what shipped (PR numbers), what is on the phone and
awaiting your check, and the next slot. The roadmap's Part 1 is updated
the same day; this document's calendar shifts when something overruns.
