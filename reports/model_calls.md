# Model calls · last 30 days (since 2026-08-16)

| kind | calls | retries | failed | median s | p90 s | max s | in (med) | cached (med) | out (med) | cache hit |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| plan | 2 | 0 | 0 | 68.0 | 82.2 | 82.2 | 7020 | 0 | 6507 | 0% |
| prose | 20 | 0 | 0 | 3.3 | 5.1 | 7.8 | 11722 | 50343 | 188 | 77% |
| set_reply | 50 | 0 | 0 | 5.4 | 10.7 | 18.9 | 13482 | 51422 | 244 | 79% |

Reading it: `in` is uncached input tokens per call, `cached` the tokens served from the prompt cache, `out` the tokens the athlete waited on (thinking included). A low cache hit on a day with many calls means the stable block changed within the day. See docs/OPTIMISATION.md for the gates each stage must pass.

## Cost

| kind | calls | total | median per call | share |
|---|---:|---:|---:|---:|
| plan | 2 | $0.58 | $0.289 | 13% |
| prose | 20 | $1.46 | $0.038 | 32% |
| set_reply | 50 | $2.54 | $0.041 | 55% |

**$4.58 over 30 days** → $0.15 a day → about **$5 a month** at this rate. Month to date: $4.58.
A session opening (the plan call, retries included) costs about **$0.29**.

Rates as of 2026-09-15, first-party API, per million tokens: Sonnet 5 $2.00 in / $10.00 out, cache read $0.20, cache write $4.00 at the one-hour TTL the coach uses. The table is `RATES` in usage.py; move the date when it changes.
