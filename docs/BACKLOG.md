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
| F1 | Block review goes live: a tap records, no more dry run | S | proposed | First dry run compared 19 Sep: matched on 2 of 3, the third reasoned in chat. Say "go live". |
| F2 | Decision capture stages 2–3: the chat-bubble card, the session-shape grammar | M | approved (design) | Stage 1 shipped 18 Sep. |
| F3 | Apple Watch: rest timer with haptics (stage 1), set logging from the wrist (stage 2) | L | proposed (2.8) | Mockups first. New target to sign; depends on P1. |
| F4 | Pre-flight phase 2: findings that need a decision become Home decision cards; unanswered → programme default, stated | M | idea | Phase 1 (correct + log) shipped 20 Sep (#303). |
| F5 | Standing decisions reviewed mid-block by age, not only at the block review | S | idea | The shoulder cap was never asked about until the review existed. |
| F6 | Exercise aliases managed from the app: merge two spellings of one lift | S | idea | Incline Press / Incline Barbell Press; the review and strength page already honour the library. |
| F7 | Widget: strength number kept fresh; a "this week" line | S | idea | Widget shipped 17 Sep, fixed 19–20 Sep. |
| F8 | Replay of the whole pipeline against the real export, as a test | M | approved 20 Sep (in principle) | Needs one export from Settings. Also the biggest stability item. |
| F9 | Set reply as prose by default if note damage recurs | S | watch | Guard shipped 18 Sep; no recurrence seen. |

## Stability — the thing does what it says, every time

| # | Item | Size | Status | Notes |
|---|---|---|---|---|
| S1 | In-session coach: any number it states about history must be in the context it was handed, or the reply is rewritten | M | approved 20 Sep | The block review already has this rule (`numbers_not_in_sheet`). |
| S2 | One `blocks` module for block identity: start, boundary, ended range, picks | M | done 20 Sep (#307) | |
| S3 | Prune the applied dated fixes into a history note; keep the mechanism | S | done 20 Sep (#307); delete `fixes_2026_09.py` once `/status` shows all eight applied | |
| S4 | Session stamping: every finished session carries its mesocycle week and day; hygiene check and backfill | S | idea | `block_start` and the review lean on stamps; the 2 Sep opener had none. |
| S5 | Pre-flight invariants grow with every gym screenshot; nightly record read from `/status` and the Sunday report | S each | standing | Loadable, regression, range, ceiling, slots so far. |
| S6 | Verify idempotent delivery on a real dropped connection (switch apps mid-set) | S | blocked on a rebuild | Migration 011 run 20 Sep. |
| S7 | Swift tests for the block review card decoding, the widget payload, the pending-reply resume | S | idea | 31 Swift tests exist for the numbers. |
| S8 | The missing "Logged warm-up 2 of 3" message | S | idea | App side; noticed 18 Sep. |
| S9 | Hygiene dry run of session statuses/types, then execute | S | blocked on the athlete pasting the log | Migration 010 run. |
| S10 | Late coach review applied after 3 minutes | — | done (#277) | |

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
| C1 | Readiness cuts on light isolation lifts: whether a red morning should touch load at all when the cut is under one stack step (now: holds, says so) | S | idea | Reverse Cable Fly 20 Sep. |
| C2 | The programme acts on READY TO LOAD (steps the load itself) instead of telling the coach | S | idea | Watch wording fixed 20 Sep. |
| C3 | When an emphasis should be questioned: a muscle over its band with rising lifts (triceps) is queued for next block | S | idea | The review states it; the athlete decides. |
| C4 | Week 1 anchor when the peak week has no stamped set | S | idea | Falls back to block best with a note today. |
| C5 | Coach tone under disagreement: check the athlete's last set before arguing from a rule | — | folded into S1 and E1 | |
| C6 | Cable Crunch: reassess the heavier stacks at the next review; cap cleared 20 Sep | — | scheduled | |

## Process — how we build and ship

| # | Item | Size | Status | Notes |
|---|---|---|---|---|
| P1 | Cloud build: Xcode Cloud → TestFlight; retire `deploy_device.sh` and the launchd job | M | proposed | The Intel Mac cannot run Xcode 27; iOS beta updates now off. Needs the paid programme. |
| P2 | One export from Settings for the replay harness (F8) | S | waiting on the athlete | Training data only. |
| P3 | Rules we hold: a new check is a step in `reply_contract.py` and one comes out; every gym screenshot becomes a pre-flight invariant; nothing merges while a session is live | — | standing | |
| P4 | The Sunday report is read by Claude, not the athlete; sections only a human would read are removed | S | in progress | Shadow removed 20 Sep. |
| P5 | Migrations: 011 run; none pending | — | done | |

---

## Order for the coming week

1. Clearing out: E1 prompt diet, S2 blocks module, S3 prune fixes (approved).
2. S1 in-session numbers check.
3. F8/P2 replay harness, once the export is in.
4. F1 block review live, on your word.
5. P1 cloud build, when you have decided on the paid programme.

Everything else waits its turn or a yes.
