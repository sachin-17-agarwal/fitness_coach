# Backlog

Every upgrade we have named, in one place, so nothing gets lost. Six
categories. The roadmap (`docs/ROADMAP.md`) keeps the reasoning behind each
item and the record of what was decided; this file is the list we plan
from. An item moves to **done** when it is merged and seen on the phone.

Sizes: S under a day, M a few days, L a week or more. Status: idea ·
proposed (needs a yes) · approved · in progress · blocked (on what) · done.

The two categories beyond the four you named:

- **Coaching** — what the coach prescribes and says. A wrong number or a
  wrong claim is not instability, the system ran exactly as built; it is
  the coaching being wrong. It needs its own list or it hides inside
  Stability.
- **Process** — how we build and ship: the deploy path, the tests that
  run before a change, the rules we hold ourselves to. Not features, not
  fixes, but where most of this week's pain came from.

---

## Efficiency — cost and speed

| # | Item | Size | Status | Notes |
|---|---|---|---|---|
| E1 | Prompt diet: `system_prompt.next.txt`, a third the size, every code-enforced rule removed | M | live from the 21 Sep rest day | Roll back with `PROMPT_FILE=system_prompt.txt`. Gate: the audit's rule-break rate must not rise over the first week; read in the 27 Sep report. |
| E2 | Context shape: older sessions one line each, last week in full (Optimisation stage 4) | M | proposed | Gated on E1. |
| E3 | History caching as a second cut of cache hygiene (stage 5) | S | proposed | First cut shipped 15 Sep; read the 20 Sep report first. |
| E4 | Plan before prose as a second streamed call (2.1d) | M | proposed | Gated on the thinking/text split showing prose is a real share. Real quality risk: a Why line written after the decision. |
| E5 | Thinking depth on set replies and plans (2.1e) | S | proposed | Largest lever, real quality risk. Not before two more weeks of data. |
| E6 | Gym-arrival geofence that pre-computes the plan (2.1c) | S | proposed | Review 30 Sep: does START still feel slow after 2.1b? |
| E7 | Block review prepared off the request path (Home gets 202, polls) | S | idea | Home's first fetch timed out on 19 Sep; the app's one retry covers it today. |
| E8 | Monthly cost view in the Sunday report | S | done (#234) | |

## Features — new, and improving what exists

| # | Item | Size | Status | Notes |
|---|---|---|---|---|
| F1 | Block review goes live: a tap records, no more dry run | S | done 23 Sep | `block_review.DRY_RUN = False`; the 19 Sep row stays a dry run. First live review at the next block rollover. |
| F2 | Decision capture stages 2–3: the chat-bubble card, the session-shape grammar | M | done 23 Sep | Cards under the reply in Coach chat; `Substitute:`/`Order:` recorded and applied inside `parse_session_template` (`shape.py`), so coach and programme read one template. First shape line waits on the coach proposing one. |
| F3 | Apple Watch: rest timer with haptics (stage 1), set logging from the wrist (stage 2) | L | parked 24 Sep | Needed a second signed target through P1, which is declined. Revisit only if the free provisioning path can carry a watch extension. |
| F4 | Pre-flight phase 2: findings that need a decision become Home decision cards; unanswered → programme default, stated | M | idea | Phase 1 (correct + log) shipped 20 Sep (#303). |
| F5 | Standing decisions reviewed mid-block by age, not only at the block review | S | idea | The shoulder cap was never asked about until the review existed. |
| F6 | Exercise aliases managed from the app: merge two spellings of one lift | S | idea | Incline Press / Incline Barbell Press; the review and strength page already honour the library. |
| F7 | Widget: strength number kept fresh; a "this week" line | S | idea | Widget shipped 17 Sep, fixed 19–20 Sep. |
| F8 | Replay of the whole pipeline against the real export, as a test | M | done 24 Sep | `replay_export.py` + `tests/test_replay_export.py`: 18 stamped sessions, offline, against the 23 Sep export (training tables committed; recovery read locally only — the repo is public). First run found the 8kg chest-press stack rounded to 151.5. |
| F9 | Set reply as prose by default if note damage recurs | S | watch | Guard shipped 18 Sep; no recurrence seen. |
| F10 | Morning briefing retired: route, prompt section, Home note and sheet, chat button, settings style, Telegram CLI mode | S | done 20 Sep | Nothing ever sent one; Home and the widget carry what it said. A Telegram-era feature. |

## Stability — the thing does what it says, every time

| # | Item | Size | Status | Notes |
|---|---|---|---|---|
| S1 | In-session coach: any number it states about history must be in the context it was handed, or the reply is rewritten | M | done 23 Sep | `reply_contract.numbers`: kg, reps, RPE and dates in prose checked against the handed context; one rewrite; off with `NUMBERS_CONTRACT=false`. `set_count_drift` folded into `set_counts`. |
| S2 | One `blocks` module for block identity: start, boundary, ended range, picks | M | done 20 Sep (#307) | |
| S3 | Prune the applied dated fixes into a history note; keep the mechanism | S | done 20 Sep (#307); delete `fixes_2026_09.py` once `/status` shows all eight applied | |
| S4 | Session stamping: every finished session carries its mesocycle week and day; hygiene check and backfill | S | idea | `block_start` and the review lean on stamps; the 2 Sep opener had none. |
| S5 | Pre-flight invariants grow with every gym screenshot; nightly record read from `/status` and the Sunday report | S each | standing | Loadable, regression, range, ceiling, slots so far. |
| S6 | Verify idempotent delivery on a real dropped connection (switch apps mid-set) | S | blocked on a rebuild | Migration 011 run 20 Sep. |
| S7 | Swift tests for the block review card decoding, the widget payload, the pending-reply resume | S | idea | 31 Swift tests exist for the numbers. |
| S8 | The missing "Logged warm-up 2 of 3" message | S | idea | App side; noticed 18 Sep. |
| S9 | Hygiene dry run of session statuses/types, then execute | S | blocked on the athlete pasting the log | Migration 010 run. |
| S10 | Late coach review applied after 3 minutes | — | done (#277) | |
| S13 | A coach `adjust` above the programme's top set is at most one step of the lift (`plan.validate`); beyond that the programme's card stands | S | done 24 Sep | Machine Chest Press 168 vs ~152 on 22 Sep → 165 x5 @9. The pre-flight bounded the programme's jumps; the coach's were unbounded. |
| S12 | Logged sets carry their phase (`workout_sets.phase`, migration 014); card and set replies count by phase, position only for older rows | S | done 24 Sep | A skipped working set no longer relabels the back-offs after it. |
| S11 | Coach flag log: a wrong reply is flagged from the coach sheet; the exchange, card, sets and contract record are kept (`coach_flags`), shared from Settings as one text, and filed as a GitHub issue when `GITHUB_FLAGS_TOKEN` is set | S | done 23 Sep | Migration 013 to run. Optional: a fine-grained token with issues write on this repo, set on Railway. |

## UI — how it looks

| # | Item | Size | Status | Notes |
|---|---|---|---|---|
| U1 | Retire the serif face app-wide (eight remaining uses) | S | proposed | Greeting moved to the display face 18 Sep. |
| U2 | Widget with a Liquid Glass treatment | S | asked 18 Sep, undecided | Current widget: flat ink palette. |
| U3 | Block review card: judge the rows after a real morning read; strength page parity on marks (~ and +BW) | S | watch | Rows, folds and toggles shipped 19–20 Sep. |
| U4 | A visible mark on a card the pre-flight corrected, beyond the reason line | S | idea | Decide after the first correction is seen. |
| U5 | Exercise Library screen for aliases (with F6) | S | idea | |

## Coaching — what the coach prescribes and says

| # | Item | Size | Status | Notes |
|---|---|---|---|---|
| C11 | **Decision scorecard**: every finished session scored per lift (right / light / heavy) against the range and RPE prescribed, the programme's number kept beside the coach's; verdicts back to the coach (OUTCOMES block), to the Sunday report, and into the programme (two lights → one step up); an unexamined `accept` on a two-miss trend is asked about | M | done 24 Sep | Migration 015. Measured before building: the coach overrode 4 of 68 decisions in the 3–19 Sep block; the programme ran light 15 of 64. Read after one block (~29 Oct): does the coach's judgement, now exercised, beat the programme's number? |
| C7 | Deload by SETS: back-offs dropped, straight sets halved, load held, top set RPE 7; no readiness cut stacked on it | S | done 24 Sep | Consensus practice (Bell et al.): 25-50% less volume, intensity held. The rep-only deload kept every set. |
| C8 | Back-offs at RPE 8 in every loading week (were 7 in weeks 1-2) | S | done 24 Sep | Proximity-to-failure meta-regressions (Robinson et al. 2024). |
| C9 | Block length is a setting: 5 weeks on a bulk (4 loading + deload), 4 on a cut; `data.block_weeks()` reads memory `block_weeks`, set from Settings → Training block | S | done 24 Sep | Every week rule reads it; peak week = last loading week. |
| C10 | Pull order: Lat Pulldown before Cable Row | — | done 24 Sep | Two vertical pulls with a heavy row between them left the pulldown flat since June. |
| C1 | Readiness cuts on light isolation lifts: whether a red morning should touch load at all when the cut is under one stack step (now: holds, says so) | S | idea | Reverse Cable Fly 20 Sep. |
| C2 | The programme acts on READY TO LOAD (steps the load itself) instead of telling the coach | S | idea | Watch wording fixed 20 Sep. |
| C3 | When an emphasis should be questioned: a muscle over its band with rising lifts (triceps) is queued for next block | S | idea | The review states it; the athlete decides. |
| C4 | Week 1 anchor when the peak week has no stamped set | S | idea | Falls back to block best with a note today. |
| C5 | Coach tone under disagreement: check the athlete's last set before arguing from a rule | — | folded into S1 and E1 | |
| C6 | Cable Crunch: reassess the heavier stacks at the next review; cap cleared 20 Sep | — | scheduled | |

## Process — how we build and ship

| # | Item | Size | Status | Notes |
|---|---|---|---|---|
| P1 | Cloud build: Xcode Cloud → TestFlight; retire `deploy_device.sh` and the launchd job | M | declined 24 Sep | Not paying for the programme. `deploy_device.sh` + launchd stay the deploy path (any paired iPhone, 3 install retries since #314). |
| P2 | One export from Settings for the replay harness (F8) | S | done 24 Sep | Re-export after each block to refresh `tests/fixtures/export/` (not recovery.csv). |
| P6 | Claims ledger (`docs/CLAIMS.md`): every claim Claude makes about the system carries its basis — measured / inferred / assumed — and is verified or marked wrong | — | standing from 24 Sep | The athlete's ask: accountability for the developer as well as the coach. |
| P3 | Rules we hold: a new check is a step in `reply_contract.py` and one comes out; every gym screenshot becomes a pre-flight invariant; nothing merges while a session is live | — | standing | |
| P4 | The Sunday report is read by Claude, not the athlete; sections only a human would read are removed | S | in progress | Shadow removed 20 Sep. |
| P5 | Migrations: 011–014 run; 015 pending | — | waiting on the athlete | `migrations/015_decision_outcomes.sql`. |

---

## Order for the coming week

1. Clearing out: E1 prompt diet, S2 blocks module, S3 prune fixes (approved).
2. S1 in-session numbers check.
3. F8/P2 replay harness, once the export is in.
4. F1 block review live, on your word.
5. ~~P1 cloud build~~ — declined 24 Sep; the nightly re-sign stays.

Everything else waits its turn or a yes.
