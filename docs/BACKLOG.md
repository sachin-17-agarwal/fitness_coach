# Backlog

Every upgrade we have named, in one place, so nothing gets lost. Six
categories. The roadmap (`docs/ROADMAP.md`) keeps the reasoning behind each
item and the record of what was decided; this file is the list we plan
from. An item moves to **done** when it is merged and seen on the phone — *merged, unverified* until the athlete has trained on it. (Rule restated 24 Sep after four days of "done" meaning "merged".)

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
| E3 | History caching as a second cut of cache hygiene (stage 5) | S | approved 25 Sep | Cache breakpoint under the older turns of today's history; ~6k of the ~8.9k uncached tokens per set reply (20 Sep report) → about −30% per call, ~$20/month, no change to content. Batch with the next weekly PR. |
| E4 | Plan before prose as a second streamed call (2.1d) | M | on hold to 9 Oct | Real quality risk: a Why line written after the decision. The opening card is already instant (2.1b), so the wait it would shorten is one the athlete no longer stands in. Revisit 9 Oct. |
| E5 | Thinking depth on set replies and plans (2.1e) | S | proposed | Largest lever, real quality risk. Not before two more weeks of data. |
| E6 | Gym-arrival geofence that pre-computes the plan (2.1c) | S | dropped 25 Sep | START is not slow any more — the programme card is instant and the coach review lands during the ramp. Not worth Always-location permission. |
| E7 | Block review prepared at rollover, not when Home first asks | S | approved 25 Sep | 24 s median, 9 retries in 40 calls, one Home timeout (19 Sep). Build it with the ~29 Oct block-review touch. |
| E8 | Monthly cost view in the Sunday report | S | done (#234) | |

## Features — new, and improving what exists

| # | Item | Size | Status | Notes |
|---|---|---|---|---|
| F1 | Block review goes live: a tap records, no more dry run | S | merged 23 Sep, unverified | `block_review.DRY_RUN = False`; the 19 Sep row stays a dry run. First live review at the next block rollover. |
| F2 | Decision capture stages 2–3: the chat-bubble card, the session-shape grammar | M | merged 23 Sep, unverified | Cards under the reply in Coach chat; `Substitute:`/`Order:` recorded and applied inside `parse_session_template` (`shape.py`), so coach and programme read one template. First shape line waits on the coach proposing one. |
| F4 | Pre-flight phase 2: findings that need a decision become Home decision cards; unanswered → programme default, stated | M | idea | Phase 1 (correct + log) shipped 20 Sep (#303). |
| F5 | Standing decisions reviewed mid-block by age, not only at the block review | S | in PR 25 Sep, unverified — after 4 sessions under a decision the coach is told to ask once, then not for a week | The shoulder cap was never asked about until the review existed. |
| F6 | Exercise aliases managed from the app: merge two spellings of one lift | S | in PR 25 Sep, unverified — (a) dated fix merges the case-only variants (12 lifts); (b) Add-alias action on each library row | Incline Press / Incline Barbell Press; the review and strength page already honour the library. |
| F7 | Widget: strength number kept fresh; a "this week" line | S | in PR 25 Sep, unverified — THIS WEEK sessions·tonnage vs last week, server-computed; widget reloads at session end; strength number still refreshes when History opens | Widget shipped 17 Sep, fixed 19–20 Sep. |
| F8 | Replay of the whole pipeline against the real export, as a test | M | merged 24 Sep, unverified | `replay_export.py` + `tests/test_replay_export.py`: 18 stamped sessions, offline, against the 23 Sep export (training tables committed; recovery read locally only — the repo is public). First run found the 8kg chest-press stack rounded to 151.5. |
| F9 | Set reply as prose by default if note damage recurs | S | watch | Guard shipped 18 Sep; no recurrence seen. |
| F10 | Morning briefing retired: route, prompt section, Home note and sheet, chat button, settings style, Telegram CLI mode | S | done 20 Sep | Nothing ever sent one; Home and the widget carry what it said. A Telegram-era feature. |

## Stability — the thing does what it says, every time

| # | Item | Size | Status | Notes |
|---|---|---|---|---|
| S1 | In-session coach: any number it states about history must be in the context it was handed, or the reply is rewritten | M | merged 23 Sep, unverified | `reply_contract.numbers`: kg, reps, RPE and dates in prose checked against the handed context; one rewrite; off with `NUMBERS_CONTRACT=false`. `set_count_drift` folded into `set_counts`. |
| S2 | One `blocks` module for block identity: start, boundary, ended range, picks | M | done 20 Sep (#307) | |
| S3 | Prune the applied dated fixes into a history note; keep the mechanism | S | done 20 Sep (#307); delete `fixes_2026_09.py` once `/status` shows all eight applied | |
| S4 | Session stamping: every finished session carries its mesocycle week and day; hygiene check and backfill | S | in PR 25 Sep, unverified — `2026-09-25-stamp-backfill`: 103 sessions by rotation inference, notes say so; block starts 20 Apr, 15 May, 6 Jun, 3 Jul, 23 Jul, 11 Aug (the review's own estimate for the last: 9–10 Aug) | `block_start` and the review lean on stamps; the 2 Sep opener had none. |
| S5 | Pre-flight invariants grow with every gym screenshot; nightly record read from `/status` and the Sunday report | S each | standing | Loadable, regression, range, ceiling, slots so far. |
| S6 | Verify idempotent delivery on a real dropped connection (switch apps mid-set) | S | blocked on a rebuild | Migration 011 run 20 Sep. |
| S7 | Swift tests for the block review card decoding, the widget payload, the pending-reply resume | S | approved 25 Sep — with the next touch of those files | 31 Swift tests exist for the numbers. |
| S8 | The missing "Logged warm-up 2 of 3" message | S | in PR 25 Sep, unverified — the fact line shows the moment any set is logged, above the typing dots | App side; noticed 18 Sep. |
| S9 | Hygiene dry run of session statuses/types, then execute | S | in PR 25 Sep, unverified — `2026-09-25-session-hygiene` executes the dry run (`docs/hygiene_2026-09-25.md`): 36 abandoned, 2 retyped from their sets (Push, Legs) | Migration 010 run. |
| S10 | Late coach review applied after 3 minutes | — | done (#277) | |
| N6 | A hard 30 s budget on set replies: past it a code-only reply goes out (card unchanged) and the coach's note lands later | S | proposed 25 Sep, saved for review | Measured (20 Sep report): set reply median 5.8 s, p90 11.4 s, max 335.9 s. |
| N7 | Warm-up adherence: measure prescribed ramps against logged ramps per lift before building anything | S | proposed 25 Sep — measure first | Measured: 28 of 60 heavy lifts in September have no warm-up row; some are the programme's own "no ramp", some may be unlogged, some skipped. |
| S13 | A coach `adjust` above the programme's top set is at most one step of the lift (`plan.validate`); beyond that the programme's card stands | S | merged 24 Sep, unverified | Machine Chest Press 168 vs ~152 on 22 Sep → 165 x5 @9. The pre-flight bounded the programme's jumps; the coach's were unbounded. |
| S12 | Logged sets carry their phase (`workout_sets.phase`, migration 014); card and set replies count by phase, position only for older rows | S | merged 24 Sep, unverified | A skipped working set no longer relabels the back-offs after it. |
| S11 | Coach flag log: a wrong reply is flagged from the coach sheet; the exchange, card, sets and contract record are kept (`coach_flags`), shared from Settings as one text, and filed as a GitHub issue when `GITHUB_FLAGS_TOKEN` is set | S | merged 23 Sep, unverified | Migration 013 to run. Optional: a fine-grained token with issues write on this repo, set on Railway. |

## UI — how it looks

| # | Item | Size | Status | Notes |
|---|---|---|---|---|
| U1 | Retire the serif face app-wide (eight remaining uses) | S | in PR 25 Sep, unverified — eight sites moved to the display face or plain system; the serif title tokens removed; the numeric tokens keep their face | Greeting moved to the display face 18 Sep. |
| U2 | Widget with a Liquid Glass treatment | S | approved 25 Sep — next batch, needs a build-and-screenshot cycle | Current widget: flat ink palette. |
| U3 | Block review card: judge the rows after a real morning read; strength page parity on marks (~ and +BW) | S | approved 25 Sep — judged at the ~29 Oct review | Rows, folds and toggles shipped 19–20 Sep. |
| U4 | A visible mark on a card the pre-flight corrected, beyond the reason line | S | in PR 25 Sep, unverified — a shield mark above the reason when the pre-flight wrote a correction | Decide after the first correction is seen. |
| U5 | Exercise Library screen for aliases (with F6) | S | folded into F6(b) | |

## Coaching — what the coach prescribes and says

| # | Item | Size | Status | Notes |
|---|---|---|---|---|
| C11 | **Decision scorecard**: every finished session scored per lift (right / light / heavy) against the range and RPE prescribed, the programme's number kept beside the coach's; verdicts back to the coach (OUTCOMES block), to the Sunday report, and into the programme (two lights → one step up); an unexamined `accept` on a two-miss trend is asked about | M | merged 24 Sep, unverified | Migration 015. Measured before building: the coach overrode 4 of 68 decisions in the 3–19 Sep block; the programme ran light 15 of 64. Read after one block (~29 Oct): does the coach's judgement, now exercised, beat the programme's number? |
| C7 | Deload by SETS: back-offs dropped, straight sets halved, load held, top set RPE 7; no readiness cut stacked on it | S | merged 24 Sep, unverified | Consensus practice (Bell et al.): 25-50% less volume, intensity held. The rep-only deload kept every set. |
| C8 | Back-offs at RPE 8 in every loading week (were 7 in weeks 1-2) | S | merged 24 Sep, unverified | Proximity-to-failure meta-regressions (Robinson et al. 2024). |
| C9 | Block length is a setting: 5 weeks on a bulk (4 loading + deload), 4 on a cut; `data.block_weeks()` reads memory `block_weeks`, set from Settings → Training block | S | merged 24 Sep, unverified | Every week rule reads it; peak week = last loading week. |
| C10 | Pull order: Lat Pulldown before Cable Row | — | merged 24 Sep, unverified | Two vertical pulls with a heavy row between them left the pulldown flat since June. |
| C1 | Readiness cuts on light isolation lifts: whether a red morning should touch load at all when the cut is under one stack step (now: holds, says so) | S | in PR 25 Sep, unverified — effort-only under one step, one clause on the card; 7 such lifts in the replayed block, none ever actually cut | Reverse Cable Fly 20 Sep. |
| C2 | The programme acts on READY TO LOAD (steps the load itself) instead of telling the coach | S | in PR 25 Sep, unverified — `PriorSet.ready` from the watch's own flag; weeks 2 and peak-by-reps step. Measured: 21 ready runs since June, the load moved next session in 9 | Watch wording fixed 20 Sep. |
| C3 | When an emphasis should be questioned: a muscle over its band with rising lifts (triceps) is queued for next block | S | folded into the ~29 Oct review (U3) — every muscle inside its band this block | The review states it; the athlete decides. |
| C4 | Week 1 anchor when the peak week has no stamped set | S | dropped 25 Sep — 1 of 21 week-1 lifts, and only a spelling variant; F6 covers it | Falls back to block best with a note today. |
| C5 | Coach tone under disagreement: check the athlete's last set before arguing from a rule | — | folded into S1 and E1 | |
| C6 | Cable Crunch: reassess the heavier stacks at the next review; cap cleared 20 Sep | — | scheduled | |
| N1 | **RPE is mostly the slider's default**: the app records whether the RPE was touched, stops prefilling the target as the value, and the scorecard treats an untouched RPE as unknown (verdict by reps alone) | S | proposed 25 Sep, saved for review | Measured: 260 of 312 September working sets (83%) carry an RPE exactly equal to the prefilled target. Decides whether the scorecard's "right" means anything. |
| N2 | Rest reprogrammed to what is done: ~3 min between working sets (evidence favours ~3 min over 1 for hypertrophy) | S | proposed 25 Sep, saved for review | Measured: median rest 3.2–3.4 min, p90 4.5–4.9, against 90 s / 2 min prescribed; sessions 79 min median, 106 max. |
| N3 | Bodyweight-plus lifts: the added-load step sized on the athlete plus the plate | S | proposed 25 Sep, saved for review | Measured: Dips 15 vs 20 lifted, Pull-Ups 14 vs 17.5 twice among the 8 replay outliers. |
| N4 | Light stacks: when one step exceeds ~10% of the load, progress by widening the rep range before the load | S | proposed 25 Sep, saved for review | Measured: Reverse Cable Fly three times among the outliers (12.5 ↔ 10 ↔ 15); lateral raise and Pallof the same shape. |
| N5 | Bulk-rate readout: weekly weight rate in the Sunday report and a one-line note to the coach above ~0.5%/week | S | proposed 25 Sep, saved for review | Measured: 80.8 → 82.6 over the last seven weigh-ins; ~1 kg/week for six weeks. |

## Process — how we build and ship

| # | Item | Size | Status | Notes |
|---|---|---|---|---|
| P2 | One export from Settings for the replay harness (F8) | S | merged 24 Sep, unverified | Re-export after each block to refresh `tests/fixtures/export/` (not recovery.csv). |
| N8 | Swift built and tested in CI on a macOS runner, on PRs that touch Swift | S | proposed 25 Sep, saved for review | Every Swift claim in the ledger is "assumed"; the nightly Mac build is the only compiler. Free minutes while the repo is public, 10× cost once private — build only on Swift changes. |
| P6 | Claims ledger (`docs/CLAIMS.md`): every claim Claude makes about the system carries its basis — measured / inferred / assumed — and is verified or marked wrong | — | standing from 24 Sep | The athlete's ask: accountability for the developer as well as the coach. |
| P3 | Rules we hold: a new check is a step in `reply_contract.py` and one comes out; every gym screenshot becomes a pre-flight invariant; nothing merges while a session is live | — | standing | |
| P4 | The Sunday report is read by Claude, not the athlete; sections only a human would read are removed | S | in progress | Shadow removed 20 Sep. |
| P5 | Migrations: 011–015 all run (24 Sep) | — | done | Nothing pending. |

---

## Order for the coming week

1. Clearing out: E1 prompt diet, S2 blocks module, S3 prune fixes (approved).
2. S1 in-session numbers check.
3. F8/P2 replay harness, once the export is in.
4. F1 block review live, on your word.

Everything else waits its turn or a yes.
