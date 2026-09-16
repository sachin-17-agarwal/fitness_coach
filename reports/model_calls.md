# Model calls · last 14 days (since 2026-09-02)

| kind | calls | retries | failed | median s | p90 s | max s | in (med) | cached (med) | out (med) | text (med) | thinking (med) | cache hit |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| plan | 7 | 1 | 0 | 51.6 | 64.2 | 82.2 | 6926 | 0 | 4731 | ? | ? | 0% |
| prose | 55 | 0 | 0 | 4.4 | 8.9 | 14.0 | 11095 | 51548 | 194 | ? | ? | 81% |
| set_reply | 78 | 0 | 0 | 5.9 | 11.5 | 335.9 | 11683 | 52168 | 262 | ? | ? | 82% |

Reading it: `in` is uncached input tokens per call, `cached` the tokens served from the prompt cache, `out` the tokens the athlete waited on (thinking included), `text` the part of `out` the athlete actually received and `thinking` the rest (`?` until migration 006 has rows). A low cache hit on a day with many calls means the stable block changed within the day. See docs/OPTIMISATION.md for the gates each stage must pass.

## Cost

| kind | calls | total | median per call | share |
|---|---:|---:|---:|---:|
| plan | 7 | $1.92 | $0.278 | 18% |
| prose | 55 | $4.24 | $0.039 | 40% |
| set_reply | 78 | $4.35 | $0.040 | 41% |

**$10.51 over 3 recorded days (first call 2026-09-13)** → $3.26 a day → about **$99 a month** at this rate. Month to date: $10.51 (window shorter than the month; lower bound).
A session opening (the plan call, retries included) costs about **$0.32**.

Rates as of 2026-09-15, first-party API, per million tokens: Sonnet 5 $2.00 in / $10.00 out, cache read $0.20, cache write $4.00 at the one-hour TTL the coach uses. The table is `RATES` in usage.py; move the date when it changes.

## Decisions — the coach against the programme

Over 8 openings the coach decided 78 exercises and adjusted **35** of them (**45%**). Why: 15 named a cause (recovery, joint, machine, time), 7 progression (a stall, reps over the range), 7 shape (the proposal's set structure), 6 other. The rest took the programme's numbers.

A shape count this high says the programme's proposal and the coach disagree about how these exercises are structured. That is a programme defect to fix, not a coaching decision, and each one inflates the adjust rate.

| lift | adjusted | reasons |
|---|---:|---|
| Ab Wheel Rollout | 5 | You've been stuck at bodyweight x8 for seven sessions at RPE6-7 — that's below the top of  · Flagged stalled at bodyweight for 7 sessions and last set already hit the top of the 8-10  |
| Seated Leg Curl | 5 | Hamstrings are your lowest-volume muscle this week (7.2 sets against a 10-16 band) — this  · Hamstrings are your lowest-volume muscle this week (7.2 sets against a 10-16 band) — this  |
| Cable Crunch | 4 | Direct ab work runs as straight sets, not top-set/back-off — the proposal's back-off line  · Ab work is straight sets, not top+back-off, so I'm converting the proposal's split into th |
| Pallof Press | 4 | Three sessions at 40kg with reps sitting at or above the top of the 10-12 range (12, 15, 1 · Straight sets, not top+back-off, for the same reason as the crunch — and it's flagged stal |
| Hanging Leg Raises | 3 | Bodyweight-plus movement progresses by adding load, not letting reps drift. You've held 5k · Abs run as straight sets, not the top-set/back-off shape the proposal used — I'm convertin |

### Programme shadow — replies the programme would have changed

Not recorded yet (migration 008).

Reading it: the adjust rate is how often the coach departs from the programme at the opening, and the buckets say why. The shadow counts replies outside the plan contract — prose and set replies — whose numbers the programme would have replaced. The substitution flag stays off while the adjust rate is low and the cause rate high; a rising shadow count on prose replies is the case for turning it on.
