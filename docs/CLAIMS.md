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
| 24 Sep | The scorecard (#324) will show within one block whether the coach's judgement beats the programme's number | assumed | — | due ~29 Oct |
| 24 Sep | The Swift changes of 23–24 Sep compile | **assumed** — no compiler here | — | the nightly build decides |
