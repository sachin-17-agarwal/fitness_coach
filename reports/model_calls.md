# Model calls · last 2 days (since 2026-09-15)

| kind | calls | retries | failed | median s | p90 s | max s | in (med) | cached (med) | out (med) | text (med) | thinking (med) | cache hit |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| context | 26 | 0 | 0 | 1.3 | 1.6 | 8.6 | 0 | 0 | 0 | ? | ? | 0% |
| plan | 2 | 0 | 0 | 54.8 | 57.9 | 57.9 | 2271 | 0 | 5050 | 1175 | 4193 | 0% |
| prose | 15 | 0 | 0 | 5.5 | 7.2 | 8.2 | 8019 | 59114 | 237 | 182 | 120 | 88% |
| set_reply | 39 | 0 | 0 | 6.0 | 9.9 | 20.8 | 7634 | 59982 | 234 | 88 | 142 | 88% |

Reading it: `in` is uncached input tokens per call, `cached` the tokens served from the prompt cache, `out` the tokens the athlete waited on (thinking included), `text` the part of `out` the athlete actually received and `thinking` the rest (`?` until migration 006 has rows). A low cache hit on a day with many calls means the stable block changed within the day. See docs/OPTIMISATION.md for the gates each stage must pass.

## Cost

| kind | calls | total | median per call | share |
|---|---:|---:|---:|---:|
| context | 26 | $0.00 | $0.000 | 0% |
| plan | 2 | $0.60 | $0.298 | 18% |
| prose | 15 | $1.16 | $0.033 | 34% |
| set_reply | 39 | $1.61 | $0.032 | 48% |

**$3.36 over 1 recorded days (first call 2026-09-16)** → $3.15 a day → about **$96 a month** at this rate. Month to date: $3.36 (window shorter than the month; lower bound).
A session opening (the plan call, retries included) costs about **$0.30**.

Rates as of 2026-09-15, first-party API, per million tokens: Sonnet 5 $2.00 in / $10.00 out, cache read $0.20, cache write $4.00 at the one-hour TTL the coach uses. The table is `RATES` in usage.py; move the date when it changes.

## Decisions — the coach against the programme

Over 3 openings the coach decided 20 exercises and adjusted **5** of them (**25%**). Why: 3 named a cause (recovery, joint, machine, time), 0 progression (a stall, reps over the range), 0 shape (the proposal's set structure), 2 other. The rest took the programme's numbers.

| lift | adjusted | reasons |
|---|---:|---|
| Ab Wheel Rollout | 1 | Last session hit 12 reps at bodyweight @RPE8, over the 8-10 range at an easy effort — this |
| Cable Crunch | 1 | Machine's stack tops out at 105kg — standing constraint. Progression is by reps now, not l |
| Incline Press | 1 | Chest is warm from the press, but this is a different implement and range — one calibratio |
| Pallof Press | 1 | Logged 50kg x12 @9 on both sets, 4kg over the prescribed 46-48.5kg and still at the top of |
| Seated Leg Curl | 1 | Weak-point pick for hamstrings, 3.3 sets under their weekly band. Last logged 110kg x16 @R |

### Programme shadow — replies the programme would have changed

**3** exercise blocks on 1 days differed from the programme's computation (plan 3). Most often: Face Pulls ×1, Incline Press ×1, Machine Chest Press ×1.

Reading it: the adjust rate is how often the coach departs from the programme at the opening, and the buckets say why. The shadow counts replies outside the plan contract — prose and set replies — whose numbers the programme would have replaced. The substitution flag stays off while the adjust rate is low and the cause rate high; a rising shadow count on prose replies is the case for turning it on.
