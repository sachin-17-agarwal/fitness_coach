# Model calls · last 14 days (since 2026-09-06)

| kind | calls | retries | failed | median s | p90 s | max s | in (med) | cached (med) | out (med) | text (med) | thinking (med) | cache hit |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| block_review | 40 | 9 | 0 | 24.0 | 33.9 | 35.6 | 4266 | 0 | 2250 | 512 | 1738 | 0% |
| context | 113 | 0 | 0 | 1.3 | 2.0 | 8.6 | 0 | 0 | 0 | ? | ? | 0% |
| plan | 11 | 1 | 1 | 57.9 | 82.2 | 85.6 | 2422 | 0 | 5368 | 688 | 5205 | 0% |
| prose | 102 | 0 | 0 | 4.1 | 8.0 | 14.1 | 8414 | 53482 | 194 | 117 | 81 | 85% |
| set_reply | 140 | 0 | 0 | 5.8 | 11.4 | 335.9 | 8932 | 59949 | 244 | 84 | 140 | 85% |

Reading it: `in` is uncached input tokens per call, `cached` the tokens served from the prompt cache, `out` the tokens the athlete waited on (thinking included), `text` the part of `out` the athlete actually received and `thinking` the rest (`?` until migration 006 has rows). A low cache hit on a day with many calls means the stable block changed within the day. See docs/OPTIMISATION.md for the gates each stage must pass.

## Cost

| kind | calls | total | median per call | share |
|---|---:|---:|---:|---:|
| block_review | 40 | $1.23 | $0.032 | 7% |
| context | 113 | $0.00 | $0.000 | 0% |
| plan | 11 | $3.17 | $0.299 | 17% |
| prose | 102 | $7.05 | $0.037 | 38% |
| set_reply | 140 | $6.90 | $0.034 | 38% |

**$18.36 over 8 recorded days (first call 2026-09-13)** → $2.42 a day → about **$74 a month** at this rate. Month to date: $18.36 (window shorter than the month; lower bound).
A session opening (the plan call, retries included) costs about **$0.32**.

Rates as of 2026-09-15, first-party API, per million tokens: Sonnet 5 $2.00 in / $10.00 out, cache read $0.20, cache write $4.00 at the one-hour TTL the coach uses. The table is `RATES` in usage.py; move the date when it changes.

## Decisions — the coach against the programme

Over 12 openings the coach decided 81 exercises and adjusted **22** of them (**27%**). Why: 8 named a cause (recovery, joint, machine, time), 5 progression (a stall, reps over the range), 3 shape (the proposal's set structure), 6 other. The rest took the programme's numbers.

A shape count this high says the programme's proposal and the coach disagree about how these exercises are structured. That is a programme defect to fix, not a coaching decision, and each one inflates the adjust rate.

| lift | adjusted | reasons |
|---|---:|---|
| Seated Leg Curl | 3 | Hamstrings are your lowest-volume muscle this week (7.2 sets against a 10-16 band) — this  · First hamstring loading of the session — quads being warm says nothing about hamstrings, s |
| Ab Wheel Rollout | 2 | Flagged stalled at bodyweight for 7 sessions, last set already at the top of the 8-10 rang · Last session hit 12 reps at bodyweight @RPE8, over the 8-10 range at an easy effort — this |
| Cable Crunch | 2 | Ab work is straight sets, not top+back-off, so the proposal's split is converted into thre · Machine's stack tops out at 105kg — standing constraint. Progression is by reps now, not l |
| Machine Calf Raise | 2 | Calves are your second-lowest muscle (7.5 sets against a 6-10 band, barely inside) — this  · Compromised joint under real load — calf raise gets a full ramp like leg extension does, w |
| Machine Shoulder Press | 2 | Last session only hit 3 reps at 80kg at RPE9 — well under the 6-10 range, meaning the load · Last two sessions landed under the 6-10 rep range at RPE9 — 70kg x5 on 09-08, and 80kg x3  |

Reading it: the adjust rate is how often the coach departs from the programme at the opening, and the buckets say why. Mid-session moves are the card following the coach's set replies. Every reply's checks are one pipeline (reply_contract.py); what each did is in the REPLY CONTRACT log lines.

## Decisions captured

Proposed **0** (none) · recorded 0 · declined 0 · open 0 · superseded 0 · median answer —

Missed 0 in 14 days: every lasting phrase the detector saw got a recordable line back.

Reading it: proposed is how often the coach turned an agreement into a line the athlete could record with a tap; missed is how often the rule failed. Zero or one miss a block means the prompt rule is enough; a climbing count is the case for the second-call stage, costed first.
