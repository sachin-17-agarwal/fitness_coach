# Roadmap

A living plan for Vaux and its coach. Two halves: what is already in
motion, and what is proposed and waiting for a yes. Items move down the
page as they are decided; nothing is deleted, so the log of what was tried
and why stays readable.

Rules this document works under:

- **Quality first.** A change that could make the coaching worse ships
  behind a measured gate or not at all. Optimisation comes second.
- **Bug fixes ship directly.** Anything that changes how a screen looks or
  how the coach behaves is proposed here first and built on approval.
- **Every number is deliberate.** A reading on a screen must be traceable to
  the log, and the screen must say how it was derived when that is not
  obvious. See the loose-estimate marker on the Strength tab for the shape
  this takes.

Status words used below: **shipped** (merged, on the phone after the next
build), **verify** (shipped, not yet confirmed on device), **in progress**,
**gated** (waits on a measurement), **proposed**, **approved**, **declined**.

---

## Part 1 — Pending and ongoing

### 1.1 Optimisation plan (`docs/OPTIMISATION.md`)

Five stages, four gates. Where each stands on 14 Sep 2026:

| Stage | What | Status |
|---|---|---|
| 1 | Fewer output tokens: accepts omit numbers, invalid exercise falls back to the programme, never prose | shipped (#205, #206), under observation |
| 2 | Measure every model call; Sunday report to `reports/model_calls.md` | **in progress**, first real data landed 14 Sep |
| 3 | Prompt: keep the rules, remove the history. Target ~15,000 tokens from ~25,800 | gated on Stage 2 |
| 4 | Context shape: older sessions one line each, last week in full | gated on Stage 3 |
| 5 | Cache hygiene: the live half split into a cached day block and an uncached set block; history caching as a gated second cut | **first cut shipped 15 Sep (#241)**, moved ahead of Stage 3; reading due in the 20 Sep report |

**What the first report says.** Two weeks of calls, 41 in total:

| kind | calls | median s | p90 s | uncached in | cached | out | cache hit |
|---|---:|---:|---:|---:|---:|---:|---:|
| plan | 1 | 82.2 | 82.2 | 6,926 | 0 | 7,832 | 0% |
| prose | 15 | 3.2 | 5.1 | 11,617 | 50,343 | 183 | 77% |
| set_reply | 25 | 4.7 | 10.7 | 13,236 | 51,422 | 271 | 79% |

Reading it: in-session replies are fine. The one measured session opening
took 82 seconds, hit no cache, and produced 7,800 output tokens, most of
which is thinking. That is the "two minutes to start" complaint, in
numbers. Output tokens account for ~80 of the 82 seconds, so the fix has to
shorten output or move it off the critical path; item 2.1 in Part 2 lays
out the order, measurement first.

**What the first priced report says (15 Sep, two recorded training days,
Push 13 Sep and Legs 14 Sep):**

| kind | calls | total | median per call | share |
|---|---:|---:|---:|---:|
| plan | 2 | $0.58 | $0.29 | 13% |
| prose | 20 | $1.46 | $0.04 | 32% |
| set_reply | 50 | $2.54 | $0.04 | 55% |

A training day costs about $2.30. At five sessions a week that is roughly
$45 a month; the report's own projection of $83 assumes every day is a
training day and is an upper bound. Where the money goes: not the opening
(13%) but the in-session replies, and inside each of those the ~13,500
uncached input tokens of the live block, two thirds of a set reply's
price. If the live block were mostly cacheable, set replies and prose
would each fall from about $0.04 to about $0.015: roughly 40% off the bill
with no change to what the coach says. That is Stage 5, and it now has a
number to be judged against.

**Open follow-ups inside the plan:**

- ~~Add the stored plan decisions to the Sunday report.~~ Shipped 16 Sep
  (#257): a Decisions section with the adjust rate, the cause rate and the
  most-adjusted lifts, plus the programme shadow as a table
  (`programme_shadow`, migration 008) instead of a Railway log line.
- **Decisions agreed in chat must not sit in this file as homework.** Two
  emphasis commands were agreed on 12 Sep, written here for the athlete to
  send, and the next block opened without them. The command now supersedes a
  computed pick when it was named before the block began, and the context
  says what is queued for the next one (#245) — but the deeper fix is that
  the coach should offer to record a decision at the moment it is reached,
  rather than the plan carrying a to-do list. *proposed, needs a design*
- Audit watch: after nine clean days a rule break landed on 14 Sep (Legs wk3,
  Seated Leg Curl, two back-offs at different loads). One is noise; a second
  this block is a pattern to chase. *watching*

**First readings after the deload week's shipping (17 Sep, two training
days: deload Pull 16 Sep and Push 17 Sep):**

| kind | uncached in | cache hit | text | thinking | per call |
|---|---:|---:|---:|---:|---:|
| plan | 2,271 | 0% | 1,175 | 4,193 | $0.30 |
| prose | 8,019 | 88% | 182 | 120 | $0.033 |
| set_reply | 7,634 | 88% | 88 | 142 | $0.032 |
| context build | median 1.3 s, p90 1.6 s, max 8.6 s, no timeouts | | | | |

- **Stage 5 first cut is working.** Uncached input per set reply fell from
  ~13,200 to ~7,600 tokens, prose from ~11,600 to ~8,000; cache hit rose
  from 79% to 88%; a set reply now costs $0.032 against $0.040 (−20%) and
  prose $0.033 against $0.039 (−15%). The remaining ~7,600 uncached tokens
  are the conversation history plus the set block: the second cut's target.
- **The opening is 83% thinking**: 4,193 of 5,050 output tokens. With
  2.1(b) that is off the critical path; it is still $0.25 of the $0.30.
- **Context build is not the wait**: 1.3 s median before any model call.
- **Decisions, three openings**: 20 exercises, 5 adjusted (25%), 3 with a
  cause, 0 shape. **Shadow**: 3 blocks on the plan path differed from the
  programme's computation; the comparison was on whole parsed blocks
  including the form cue, so it over-counted — numbers only from #265.

### 1.1b Surfaced 15–16 Sep, decided 16 Sep

1. **Card reference line** ("LAST BLOCK · WK 3"): hardcoded 21–35 day
   window, labelled with today's week. *Decided 16 Sep: the athlete's last
   session on that lift, labelled by date* — the set progression works
   from, so card and coach agree by construction. Shipped. *Extended 18 Sep
   at the athlete's suggestion: two references — LAST (most recent session,
   a plain fact) and BLOCK (same stamped week of the previous block, peak
   against peak), with the load delta on BLOCK alone; a deload set beside a
   peak set had read as "▼5".*
2. **Band per calendar week or per rotation**: *settled from the exported
   log on 17 Sep.* Legs has come round every 5.0 days since July (1.4 a
   week). Over the block 2–16 Sep the log carries 22.5 hamstring sets — 12
   Seated Leg Curl, 6 back extension, 4.5 from the presses — which is 10.5
   a calendar week, inside 10–16. The coach's "3.3 under" was computed over
   the previous block's window, before the back extension was in the
   template. Every banded muscle sits inside its band at the measured 1.4
   rate (hamstrings 10.5, calves 7.0, rear delts 8.4, triceps 10.5). The
   band is judged per calendar week from the log, as now; the on-paper
   table stays a reference and the WEEKLY VOLUME block is the number.
3. **Decisions captured when reached**: the coach offers to record a
   decision at the moment it is agreed, instead of the plan carrying a to-do
   list. *Approved 16 Sep; designed 17 Sep (`docs/DECISION_CAPTURE.md`);
   approved and shipped 18 Sep: the coach's `Proposed:` line, the Home card
   with Record / Not now, "record it" / "not now" in chat, the miss
   detector and the "Decisions captured" report section. Migration 009.
   The chat-bubble card and the session-shape grammar are stages 2 and 3.*
4. **Context fetch ceiling**: the ten-second per-query limit that turned a
   slow read into "no history". *Approved 16 Sep, shipped 17 Sep (#264)*:
   ceiling 20 s, one worker per fetch, every fetch timed, and the whole
   build recorded as a `context` row so the Sunday report shows the seconds
   the athlete waits before any model call and which fetch is slowest.

### 1.1c What the first Decisions report says (16 Sep, 8 openings)

78 exercises decided, 35 adjusted (45%): 15 named a cause, 7 progression,
7 shape, 6 other. The five most-adjusted lifts are all ab work. Two
programme defects follow, both to fix before the substitution flag is
even discussed:

1. **Ab-work shape.** *Closed 17 Sep from the exported log.* All seven
   shape adjusts are from 6 Sep, before the programme rendered ab work as
   straight sets; on 15 Sep the coach ACCEPTED Cable Crunch, Pallof Press
   and Hanging Leg Raises as three straight sets. Historical, fixed. The
   6 Sep opening was also stored three times (a retried opening), which
   alone lifted the adjust rate from 38% to 45%; the report now counts one
   row per exercise per opening (#263).
2. **Bodyweight and straight-set progression.** Ab Wheel Rollout stuck at
   bodyweight × 8 for seven sessions at RPE 6–7; Hanging Leg Raises held at
   +5 kg; Pallof Press three sessions at 40 kg with reps over the range. The
   programme's progression excludes bodyweight movements from the sized
   step and has no lever once a bodyweight lift reaches the top of its
   range (add load, then reps; or tempo/range). The coach has been doing
   this by hand. *2.11, approved and shipped 17 Sep.*

Migration 008 run 16 Sep: the programme shadow records from the next coach
reply and appears in the 20 Sep report. Deduplicated adjust rate over the
same eight openings: 21 of 56 (38%): 8 cause, 5 progression, 3 shape, 5
other.

### 1.1e The briefing is never read (17 Sep)

"I never look at the briefing because it's useless. Everything that I need
to know is in the app dashboard." Two things assumed otherwise. The block
review was prepared and shown only by the briefing route, so the first
review would never have been written; *fixed 17 Sep*: Home's fetch of
`/api/block-review` prepares it under the same guards and shows it as a
card under the readiness block, answered there (Approve all / No) or in
chat. The decision-capture design routed unanswered proposals to the
briefing; it now says Home. The briefing itself stays on its button and
costs nothing unless tapped; whether to retire it is a later question.

### 1.1f Garbled set reply (18 Sep Legs)

The reply to the third Leg Press warm-up reached the athlete as ", solid,
thenring warm-.135kg for3 (RE 6.0.Rest 2min then Working Set: 240kg x12
RPE6 | Rest:2min.Everything onined properly…". The stored row is identical,
`model_calls` shows one accepted `set_reply` attempt, and nothing between
the model and the card edits text — so the damage was in the
constrained-output call itself, and the contract accepted it because it
only ever checked the numbers. *Fixed 18 Sep:* `note_damage` marks a note
that starts with punctuation, has unbalanced brackets, glues a word to a
number, runs sentences together or carries a set line; two marks send the
reply back once, then it falls through to the prose call, and the event
is logged. Watching: if it recurs, the prose fallback becomes the default
for set replies and the structured path is reserved for changes.

Seen in the same transcript, not yet explained: the coach never received
"Logged warm-up 2 of 3" — the app went from warm-up 1 to warm-up 3. Either
the request failed silently or it was never sent. *To look at on the app
side.*

### 1.1d Data hygiene, seen in the export (17 Sep)

- 35 days carry more than one session row; a Cardio+Abs day often has an
  empty cardio-logger row beside the real one, and 6 Sep has three.
- `status` is spelled both `complete` and `completed`; 10 sessions have a
  blank type and 2 from April read `Unknown`.
- None of it breaks a number today (the readers filter on sets, not
  sessions), but `rotation_sessions` and the block calendar walk this list.
  *2.12, approved and shipped 18 Sep: migration 010 respells the statuses
  and nulls the blank types; the `hygiene` cleanup step infers a type from
  the sets and collapses same-day duplicates onto the row with the sets,
  dry run first (`POST /admin/cleanup {"step":"hygiene"}`).*

### 1.2 Shipped this week, confirm on the phone

- Set counts: a `Revised:` block is no longer a licence to owe fewer sets.
  On the 16 Sep deload Pull the coach revised the Hammer Curl by load and
  re-sent one back-off against a template of two; the exemption let it
  through, the card read complete after the first back-off, and the second
  was skipped. Causeless revisions are now padded to the template; a
  revision naming pain, the joint, the equipment or the clock still stands.
  *shipped, backend*
- Logger label past the plan's last set reads "Extra back-off · plan had 2"
  instead of padding the total to the index ("3 of 3" on a plan of one).
  *verify on the next build*
- Strength: a week whose only set on a lift runs past 12 reps still counts
  as lifted, marked "EST. FROM N REPS" (#226). Hamstrings should read a PR
  after the 110 × 16 leg curl. *verify*
- Strength hero: "1 DROPPING" rather than "1 STALLED" for a dropping lift
  (#225). *verify*
- Automatic re-sign: `tools/deploy_device.sh` finds Xcode 26 wherever it was
  unzipped, forces a fresh seven-day profile, logs the real expiry, and runs
  from launchd at 07:30 and 21:00 (#224, #227, #228). Confirmed working on
  14 Sep. Check `~/Library/Logs/vaux-deploy.log` after the first scheduled
  run. *verify the schedule*
- Live Activity for the rest timer (build settings, #197). *verify* the
  toggle now appears under Settings and the timer shows on the lock screen.
- Coach chat: exercise reorder by asking ("can I do X first?") moves the
  card when nothing is logged yet; mid-exercise changes need the swap
  words. Confirmed 13 Sep. *shipped*

### 1.3 Waiting on the athlete

Migrations 006 and 007 were run on 16 Sep. Two decisions and one build:

- **Band per calendar week or per rotation.** Recommendation: per calendar
  week, with the on-paper table recomputed at the measured rotation rate so
  the two numbers agree. *pending*
- **Verify on the next build**: START opening on Push or Pull (card at
  once, coach lands), the Shoulders row reads HELD, Settings → Export, the
  card's "LAST · 12 SEP" line, the logger label past the plan.
- **The block review's dry run**: read it the morning it lands after this
  deload block rolls over, answer it in chat, and we compare.

Chat messages still worth sending (the code is live):

- `Record a decision: Machine Shoulder Press, shoulder niggle, hold at 70 kg, RPE 8 cap, progress by reps only`
- `emphasis next: triceps | overhead cable extension` and
  `emphasis next: chest | low-to-high cable fly, upper chest` for next block.
  **These were agreed in chat on 12 Sep and left here as a manual step; the
  block that opened on 15 Sep picked hamstrings from the deficit rule
  instead.** A decision reached in conversation should not depend on the
  athlete remembering to type it — see the note under 1.1.
- `weak points: triceps, chest` to move them to the block in progress
- `weak points none` for this block if not already sent
- A third Reverse Cable Fly set. Undecided; either answer is fine.

### 1.4 Housekeeping on the Mac

- Move Xcode out of Downloads into Applications and bin the 2023 copy
  (frees ~12 GB on a disk with 9 GB left). Three commands, given in chat.

---

## Part 2 — Proposed, waiting for approval

Each item says what, why, the evidence, rough size, and the risk to
coaching quality. Say "approve 2.3" or "decline 2.3" and it moves to Part 3.

### 2.1 Faster session opening
**Where the time goes.** The one measured opening produced 7,832 output
tokens in 82 s, about 95 tokens a second. Output is therefore ~80 of the
82 seconds; reading the uncached 35,000-token prompt is the rest. Any fix
has to shorten the output or move it off the critical path. The report
does not yet split thinking from visible text inside those 7,832, so the
biggest question is unanswered.
**What, in order.**
(a) Measure: record the visible output length per call beside the total,
so the Sunday report shows thinking and text separately. Tiny, no risk.
(b) Start on the programme, the coach catches up. The athlete's two
constraints: no waiting, and no call a session does not use. A schedule
is inconsistent with real life; a button is no better than START. So:
the programme's numbers (already computed in code in under a second, with
the progression rule, the recovery read and standing ceilings applied)
appear on the card the moment START is pressed, labelled "PROGRAMME ·
COACH REVIEWING". The coach's review lands as today; where it agrees the
label changes, where it differs that exercise updates with its Why line
and a note naming the change and its cause. No extra call. The visible
cost is an occasional number changing before the athlete reaches that
exercise; the adjust rate in the Sunday report says how often.
(c) Gym arrival as an optional trigger on top. A geofence around the gym
wakes the app, which sends one "prepare today's session" request; the
server computes and stores the plan and START finds it ready. One call per
gym visit. Needs "Always" location permission; location stays on the
phone, only the arrival is sent. Geofences are good, not perfect, so (b)
remains the fallback. **Review date: two weeks after (b) ships**, set
when it does; the question then is only whether START still feels slow.
No cache pre-warming on tab open, no scheduled pre-plan.
(d) Plan before prose, as a second streamed call. **Not risk-free.** Today
the reasoning that picks the numbers also writes the Why line, so the
reason on the card is the actual reason. A second call explaining
decisions it did not make can rationalise after the fact. Viable only if
the prose call is handed the structured causes and phrases them without
adding any; gated on (a) showing prose is a meaningful share of the output.
(e) Thinking depth. The largest lever and the only one with real quality
risk. Not before two more weeks of Stage 2 data and gates 1–3 in place.
**Risk.** (a) none. (b) none to content; a number the athlete has seen may
change, always with the cause shown. (c) none; reliability only. (d) real,
see above. (e) real.
**Size.** (a) tiny, (b) medium, (c) small, (d) medium, (e) small once gated.

### 2.2 HELD state for lifts under a standing decision
**What.** When a `Decision:` caps a lift, the Strength tab shows
"HELD · CAP 70 KG · SHOULDER NIGGLE" in a neutral colour, the body map does
not paint the muscle red, and the lift sits outside the dropping count.
Clearing the decision returns it to normal judging. The coach hand-off
text says "held by decision" rather than "dropping".
**Why.** Machine Shoulder Press reads DROPPING −8.3% today. It is a
deliberate hold. The screen and the coach are telling the wrong story.
**Risk.** None to coaching; it is a display and hand-off change. Adds one
legend entry.
**Size.** Small to medium. The app already reads the same database.

### 2.3 Rep-overshoot rule: size the step to the overshoot
**What the programme does today.** Rule :205 already treats reps above the
range as an overdue increase: the next prescription adds one increment.
One increment is 2.5 kg on a compound and 1 kg on an isolation. So after
110 × 16 on the Seated Leg Curl the deterministic proposal for next block's
week 1 is 111 kg × 8. The set itself says 10 reps sits near 125 kg.
**What changes.** When the overshoot is three reps or more, size the step
from the set (Epley to the middle of the range), capped at +10% a session,
and put the arithmetic on the card: "Load 122.5: 16 reps at 110 puts 10
reps near 125; capped at +10%". One- and two-rep overshoots keep the single
increment. The coach can still adjust with a cause, as now.
**Why.** A block's load set too light for the whole block is wasted
progression; the fix should land in one session, not creep 1 kg at a time.
**Risk.** Low. A deterministic rule in `prescribe.py` with tests; the cap
keeps a single high-rep set from producing a jump the joint has not seen.
**Size.** Small.

### 2.4 Swift tests for the numbers
**What.** A test target for the pure calculations the History tab depends on:
Epley and the 12-rep rule, block peak and the per-lift gate, working-set
tonnage with bodyweight loads, weekly volume from dates, the recovery facts
layer. Fixtures are small hand-written set logs with known answers.
**Why.** Every numeric bug this month (quads dropping in week 1, hamstrings
"building" after a session, sleep 15 min low, tonnage without bodyweight,
the stalled/dropping label) was found by you on a screenshot. The Python
side has 521 tests and has not shipped a wrong number since; the Swift side
has none.
**Risk.** None to the app. It makes the next change safer.
**Size.** Medium. Runs in Xcode; a GitHub Actions macOS runner is possible
later but not needed to start.

### 2.5 Block report as a coach conversation
**In one breath.** At the end of each block the coach writes the review
and suggests two or three changes; the athlete replies "yes to 1 and 3";
those become recorded decisions. Numbers come from code, the coach only
phrases and proposes, nothing is recorded without the yes, and the first
block is a dry run.
**When and where, not after a workout.** "This can't happen right after
my workout as I feel dead and can't make decisions." The review is
prepared once the block's last session is logged, but it is shown the
next morning, on a rest day, as a card on the Home tab and a coach message
that waits. No timer: it stays until answered, and the coach never raises
it inside a session. If the new block's first session arrives before an
answer, week 1 opens on the programme's defaults with no changes, the
coach says so in one line, and the review stays available.
**What.** At the end of each block the coach opens with a written review:
median gain, what set PRs, what held or dropped and the reason on record,
volume against bands, recovery over the block, and the one or two changes
proposed for the next block, each with its evidence. The athlete replies to
approve or amend, and the approved changes become `Decision:` and
`Emphasis-next:` lines automatically.
**Why.** The pieces exist (BlockReportView, weak-point policy, standing
decisions, the read) but the athlete assembles the conclusion by hand across
four tabs and then has to phrase the commands. The coach should do that
work.
**Risk.** Medium: it is a new coach behaviour and needs its own prompt
section and tests. Ship behind a manual trigger first ("block review").
**Size.** Medium to large.

### 2.6 Weekly recovery digest on the Home tab
**What.** One card each Monday: HRV against baseline for the week, short
nights count, weight trend, and the readiness taps you gave against what
the read said. Two sentences, no chart.
**Why.** The Recovery tab has the facts, but a weekly line is what changes
behaviour (bedtime, a planned lighter day). It also shows whether the read
and your own readiness agree, which is the check on the algorithm.
**Risk.** None to coaching.
**Size.** Small.

### 2.7 Export and backup of the training log
**What.** Settings → Export: every set, session, weigh-in and recovery row
as CSV, shared via the iOS share sheet. Plus a nightly GitHub Actions job
that writes a compressed snapshot of the same tables into a private
`backups/` branch.
**Why.** Six months of logged training exists in one Supabase project. A
mistaken migration or an account problem loses it. The export is also what
lets any future analysis run outside the app.
**Risk.** None to coaching. Privacy: this is health data, so the nightly
snapshot goes to storage you own (iCloud Drive or an encrypted archive),
not in clear to a repository.
**Size.** Small for the export, small for the job.

### 2.8 Apple Watch: rest timer and set logging
**What.** A companion app for the Ultra 2: the rest timer with haptics, and
"log the set as prescribed" or adjust reps and load from the wrist. The
phone stays the coach; the watch is the hands.
**Why.** Phone in hand between sets is friction; the watch is already on
you and its haptics beat a lock-screen glance.
**Risk.** None to coaching. Highest engineering cost on this list and a new
target to sign and deploy.
**Size.** Large. Would be built in stages: timer first.

### 2.9 Home-screen widget: the day's stats, beautifully
**What.** Not a workout widget; a glanceable read of where training stands,
for the hours you are not in the gym. Medium: block progress (week 2 of
3), median strength gain so far, last night's HRV against the baseline
band, sleep, next session. Large: adds the body map. Values are what the
app already computes, written to a shared container and refreshed each
morning after Health sync; the widget makes no network calls.
**Why.** "A home screen widget would be nice not during workout but if
during the day it's showing my stats in a beautiful way."
**Risk.** None. Mockups of both sizes before building, per the house rule.
**Size.** Small to medium; the widget extension exists.

### 2.10 Monthly cost line in the Sunday report
**What.** Convert the model-call tokens to a cost estimate per kind and per
month, at the current published rates, and print it beside the latency
table.
**Why.** Optimisation stages need a money number as well as seconds to be
judged fairly.
**Risk.** None.
**Size.** Tiny.

### 2.11 Bodyweight and straight-set progression
**What.** Three levers the programme lacked for a bodyweight lift, as
arithmetic in `prescribe.py`: (1) added load moves in 2.5 kg plates, not
the 1 kg isolation step no belt or dumbbell offers; (2) the sized
overshoot step (2.3) applies to bodyweight movements by sizing on what the
set actually lifted — plate plus the movement's share of the latest
weigh-in — and comes back in plates; (3) a top set that has sat at the
same load AND the same reps for three sessions is a stall the prescription
answers: with reps in reserve (RPE at least a point under target) it pins
the top of the range as a count, not a band, so the load can move next
time; at the target RPE it defers the lever to the coach by name (cut,
tempo, variation). A rollout's first added load says what it means
(a plate on the back or a vest). The stall lever applies to stack lifts
too; weeks 1 and 4 ignore it.
**Why.** Ab Wheel Rollout at bodyweight × 8 for seven sessions at RPE 6–7
while the programme repeated "9–12"; Hanging Leg Raises held at +5 kg while
it asked for +6. The coach did both by hand every session (1.1c).
**Risk.** A pinned count is a harder set than a band; it fires only with
a full RPE point in reserve, so the set is one the athlete has already
shown they can do.
**Size.** Small.

---

## Part 3 — Decided

Approved items list their PRs when shipped. Declined items keep the reason.

- **Approved 18 Sep, shipped 18 Sep.** Decision capture (1.1b item 3), the
  first two stages: `decisions.py`, migration 009, the prompt rule, the
  Home card, chat answers, the Sunday report section. 2.12 session hygiene:
  migration 010 plus the `hygiene` cleanup step, dry run before execute.
- **Approved 17 Sep, shipped 17 Sep.** 2.11 bodyweight and straight-set
  progression: plates not kilos for added load, the sized step on the
  lifted load, a three-session stall pinned to the top of the range when
  the RPE says the reps are there and deferred by name when it does not.
  `find_current_loads` now carries `held`, the sessions at the same load
  and reps. *Verify on the next Cardio+Abs card: Ab Wheel Rollout reads a
  count, not a band, if it is still at × 8.*
- **Approved 15 Sep, shipped 16 Sep (#251).** 2.2 HELD state: a lift under a
  standing decision reads "HELD · CAP 70 KG · SINCE 13 SEP", paints blue on
  the map, sits outside the dropping count and is explained, not judged, in
  the coach hand-off. A PR still reads PR. *Verified on the phone 17 Sep:*
  hero "1 HELD", shoulders row HELD; the decision itself was re-recorded
  after #261 so the 70 kg cap is on the row.
- **Approved, 15 Sep.** 2.3 rep-overshoot step sizing (shipped #249);
  2.4 Swift tests for the numbers; 2.7 export **(shipped 16 Sep, #254; verified 17 Sep — five CSVs came back and settled the hamstring question)**; 2.8 Apple Watch, staged, mockups first;
  2.9 stats widget **(settled and shipped 17 Sep: the Home readiness hero
  as a widget — score, verdict with today's session, week and strength
  gain; medium, small, lock screen. Readiness now computed server-side
  in `readiness.py` with the phone's formula. *Verified on the phone 18 Sep:
  medium and lock-screen both live, 74% amber, STEADY — LEGS.*)**.
- **Approved 15 Sep, shipped 16 Sep (#252 backend, #253 app).** 2.1(b) start
  on the programme, the coach catches up: START shows the programme's card
  at once under "PROGRAMME · COACH REVIEWING"; the review lands into the
  card, a changed exercise carries "Coach changed 80kg → 75kg · HRV below
  baseline"; a failed review leaves the programme standing. *Verified on
  Push 17 Sep: card at once, coach landed during the warm-up.* **2.1(c)
  geofence review date: 30 Sep.**
- **Approved 15 Sep, shipped 16 Sep (#255) as a DRY RUN.** 2.5 block review:
  the first morning after a block rolls over, the briefing carries the
  review — strength peak week against peak week, volume against bands,
  recovery against the 42 days before, the departures on record — with up
  to three proposals in the recordable grammar. "block review" in chat
  writes one on demand (never mid-session). "yes to 1 and 3" answers it;
  this block nothing is recorded and the answer is kept for comparison.
  Migration 007 run 16 Sep. Every number is computed; a narrative citing a
  number the sheet lacks is rejected.
- **Approved 14 Sep, shipped 15 Sep (#239).** 2.6 Weekly recovery digest:
  a Monday/Tuesday card under the Home ledger, up to three sentences from
  the log (HRV against the 42-day band, short nights by name and the hours
  under need, weight against last week, readiness taps against the
  numbers). No model call. *verify on the phone next Monday.*
- **Approved 14 Sep, shipped 15 Sep (#234).** 2.10 Cost line in the Sunday
  report: per-kind totals, month projection, month to date, and the price
  of a session opening. Rates in one dated table in `usage.py`. The 14 Sep
  opening prices at about $0.20; a set reply at about $0.04, two thirds of
  it the ~13k uncached tokens of the live block — the first number for
  Stage 5.

- **Declined, 12 Sep.** Three-stage multi-model pipeline (cheap model for
  parsing, mid for prose, top for the plan). Not clearly better and adds
  failure modes; the single structured plan contract with programme fallback
  covers the reliability goal.
- **Declined, 12 Sep.** Extra hamstring or calf work for its own sake when
  the deficit was an artefact of set counting. "No point doing extra workout
  for no reason." Emphasis slots are the mechanism instead.
- **Approved and shipped, Sep.** Plan contract (#205, #206); measurement
  and the optimisation plan (#207, #217); standing decisions (#210);
  weak-point slots to emphasis (#211, #212, #216); recovery read (#213,
  #218); per-lift peak-week gate (#219); reorder by asking (#222);
  automatic re-sign (#200, #220–#228).

---

## Build order (15 Sep)

~~2.10 cost line~~ (#234) → ~~2.6 recovery digest~~ (#239) → ~~Stage 5 first cut~~ (#241; second cut gated on the 20 Sep report) → 2.1(a) measurement and 2.1(b)
start on the programme → 2.2 HELD → 2.3 overshoot step → 2.4 Swift tests →
2.7 export → 2.9 widget mockups → 2.5 block review (dry run first) → 2.8
watch, timer stage first. Two weeks after 2.1(b) ships: review 2.1(c).

How each item gets built — files, steps, tests, device checks, and the
calendar from Thursday 17 Sep — is in `docs/IMPLEMENTATION.md`.

## How to use this document

- New idea: add it to Part 2 with the five fields. No idea is too small.
- Decision: say the item number and approve or decline. It moves to Part 3.
- Weekly: after the Sunday report lands, update 1.1 with the numbers and
  move anything gated whose gate has opened.
