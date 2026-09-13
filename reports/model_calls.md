# Model calls · last 14 days (since 2026-08-30)

| kind | calls | retries | failed | median s | p90 s | max s | in (med) | cached (med) | out (med) | cache hit |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| plan | 1 | 0 | 0 | 82.2 | 82.2 | 82.2 | 6926 | 0 | 7832 | 0% |
| prose | 15 | 0 | 0 | 3.2 | 5.1 | 6.7 | 11617 | 50343 | 183 | 77% |
| set_reply | 25 | 0 | 0 | 4.7 | 10.7 | 13.7 | 13236 | 51422 | 271 | 79% |

Reading it: `in` is uncached input tokens per call, `cached` the tokens served from the prompt cache, `out` the tokens the athlete waited on (thinking included). A low cache hit on a day with many calls means the stable block changed within the day. See docs/OPTIMISATION.md for the gates each stage must pass.
