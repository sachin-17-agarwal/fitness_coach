# Claims ledger

Every claim Claude makes about how this system behaves, with its basis and
whether it held. Started 24 Sep 2026 at the athlete's request: for six months
conclusions were stated at one volume whether measured or guessed. The rule
now — in every reply, a claim carries its basis:

- **measured** — a test, a replay, a query over the export ran and said so
- **inferred** — read from the code, not run
- **assumed** — neither; a belief

Sunday's report lists rows with an empty *verified* column. A claim that
turned out wrong stays here with what was wrong about it.

| date | claim | basis | verified | outcome |
|---|---|---|---|---|
| 22 Sep | Migration 012 was the one thing blocking mid-session card updates | inferred | 24 Sep | held — the CHECK constraint rejected every `update` row |
| 23 Sep | Opus's three defects (note_direction, swap-on-reorder, set-reply step) | measured (probes) | 23 Sep | held; all three fixed in #316 |
| 23 Sep | "The plan contract has no jump guard on the coach's top set" | **assumed** — stated before reading `validate` | 24 Sep | held, but by luck: the claim preceded the check. Guard added in #322 |
| 24 Sep | "Nothing measures the coach against the programme" | **assumed** | 24 Sep | **half wrong** — the Sunday report counts adjust rate and reasons since 18 Sep (`usage.format_decisions`). What it lacked was whether the decisions were *right* |
| 24 Sep | The coach overrode the programme on 4 of 68 opening decisions in the 3–19 Sep block; the programme's number ran light 15 of 64 times | measured (export) | 24 Sep | held (replay + prescription_decisions) |
| 24 Sep | Machine Chest Press stack moves in 8kg; 151.5 came from the step cap + half-kilo rounding | measured (export, replay) | 24 Sep | held; fixed in #322 |
| 24 Sep | Triceps and hamstrings are under-served | **wrong** — counted single-muscle credit | 24 Sep | withdrawn the same hour; fractional credit puts both inside their bands |
| 24 Sep | Deload by sets, back-offs RPE 8, 5-week block are supported by the literature cited | inferred (search summaries; full papers not fetchable from this environment) | — | to verify: read Bell et al. 2023 and Robinson et al. 2024 in full |
| 24 Sep | The scorecard (#324) will show within one block whether the coach's judgement beats the programme's number | assumed — grace runs to 8 Oct; by then: does the OUTCOMES block appear in the coach's context and does the plan contract ask on a two-miss lift? | — | due 8 Oct (mechanism), ~29 Oct (verdict) |
| 24 Sep | The Swift changes of 23–24 Sep compile | **assumed** — no compiler here | — | the nightly build decides; if it fails, the athlete sends the error and this row records it |
| 24 Sep | "813 tests pass" (#323, #324) | measured — under `discover -s tests` only | 24 Sep | **wrong for CI**: CI ran `python -m unittest tests.test_regressions`, where `import blockfix` fails (tests/ not on sys.path). Two red runs on main; the coach was unaffected. Fixed in #325; CI now runs the whole suite both ways |
| 24 Sep | CI is green on main after #325 | measured (run 35949577498: success) | 24 Sep | held |
| 24 Sep | `block_review.PEAK_WEEK = 3` would have compared this block's peak with the old block's deload at the next review | inferred (read `block_review._render_strength` window logic) | — | to verify at the ~29 Oct review: the strength rows name week-4 sets for this block, week-3 for the last |
| 24 Sep | "The coach overrode on 4 of 68 decisions (6%) — it barely decides" | measured, but on a narrow filter (adjusts on lifts with a comparable programme number AND a lifted top set) | 25 Sep | **overstated**: over all opening rows in the export the adjust rate is 28 of 138 (20%); the Sunday report's window says 27%. Most adjusts were shape (straight sets vs top+back-off), ramps, or the 6 Sep re-openings, not load — the load-override count of 4 stands, the headline did not |
| 25 Sep | The coach's phase label in the widget, and its step-back at day 1, were still on the 4-week block after #323 | inferred (read `webhook.widget_payload`) | 25 Sep | held; fixed in the 25 Sep batch |
| 25 Sep | 12 lifts logged under case/spacing variants; a rename of the minority spelling merges each history | measured (export) | — | verify after the fix runs at boot: `/status` lists `2026-09-25-exercise-case-variants`, strength page shows one Leg Press line |
| 25 Sep | The missing warm-up fact line came from the last warm-up (phase already advanced) and unplanned ramps going to the coach | inferred (read `logSet`) | — | verify on the phone: "Logged warm-up 3 of 3" appears at once |
| 25 Sep | The 25 Sep batch's Swift compiles (alias sheet, widget line, fact line, session-end reload) | **assumed** — no compiler here | — | the nightly build decides |
| 25 Sep | Commit ce6d95b: "both test invocations pass" | **wrong** — the shell chain gated on `tail`, not on unittest; `discover` was red (the ledger test's own year-wrap bug on a row dated tomorrow) | 25 Sep | fixed in the next commit; the gate now checks unittest's exit status |
| 25 Sep | The stamp backfill (S4) places the Aug block's start at 11 Aug; the block review's own rotation estimate said 9–10 Aug | measured (export) — two sessions apart, both inferences | — | at the ~29 Oct review: the previous-block window the review names should match the stamps now on the rows; if not, the review's estimate wins and the stamps move |
| 25 Sep | 21 READY-TO-LOAD runs since June; the load moved the next session in 9 | measured (export: same load two sessions running with reps at/over the range top at RPE ≤ 9) | 25 Sep | held; C2 makes the programme take the step |
| 25 Sep | The first coach message of the day took ~110 s with nothing on screen (athlete's report) | inferred cause: #324 scored 12 sessions inline in the first context build (~120 queries, up to the 20 s fetch cap) before the instant card could render, on a cold container after four deploys, ahead of a 58–86 s plan call | — | fix: scoring off the request path (background thread at boot). Verify: the next first-of-day card appears within seconds; the plan call's own wait is the remaining 60–85 s (E4/E5 territory) |
| 24 Sep | "The opening card is instant (2.1b)" — said when arguing against E4 and E6 | inferred, and **broken the same day** by #324's inline scoring | 25 Sep | wrong for the first call after the migration; corrected above |

Rules for this ledger: `CLAUDE.md`. Teeth: `tests/test_claims_ledger.py` fails the suite when an *assumed* row is neither verified nor marked wrong after 14 days.
