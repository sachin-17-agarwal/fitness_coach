# Model calls · last 7 days (since 2026-09-09)

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

**$10.51 over 4 recorded days (first call 2026-09-13)** → $2.97 a day → about **$90 a month** at this rate. Month to date: $10.51 (window shorter than the month; lower bound).
A session opening (the plan call, retries included) costs about **$0.32**.

Rates as of 2026-09-15, first-party API, per million tokens: Sonnet 5 $2.00 in / $10.00 out, cache read $0.20, cache write $4.00 at the one-hour TTL the coach uses. The table is `RATES` in usage.py; move the date when it changes.

## Decisions — the coach against the programme

Over 5 openings the coach decided 38 exercises and adjusted **11** of them (**29%**). Why: 7 named a cause (recovery, joint, machine, time), 1 progression (a stall, reps over the range), 0 shape (the proposal's set structure), 3 other. The rest took the programme's numbers.

| lift | adjusted | reasons |
|---|---:|---|
| Seated Leg Curl | 3 | First hamstring loading of the session — quads being warm says nothing about hamstrings, s · Last logged set (Legs, 09-14) was 110kg x16 @RPE8 — well over the 12-15 range at moderate  |
| Ab Wheel Rollout | 2 | You hit 12 reps at bodyweight @RPE8 last session — over the 8-10 range at an easy effort.  · Last session hit 12 reps at bodyweight @RPE8, over the 8-10 range at an easy effort — this |
| Cable Crunch | 1 | Machine's stack tops out at 105kg — standing constraint. Progression is by reps now, not l |
| Leg Extension | 1 | Loaded knee under real load — gets one ramp set regardless of the muscle already being war |
| Machine Calf Raise | 1 | Compromised joint under real load — calf raise gets a full ramp like leg extension does, w |

### Programme shadow — replies the programme would have changed

None in 7 days: every block the coach sent matched what the programme computed, or the difference was already an adjust with its reason.

Reading it: the adjust rate is how often the coach departs from the programme at the opening, and the buckets say why. The shadow counts replies outside the plan contract — prose and set replies — whose numbers the programme would have replaced. The substitution flag stays off while the adjust rate is low and the cause rate high; a rising shadow count on prose replies is the case for turning it on.
