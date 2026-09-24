# Working rules for this repository

Read by every Claude Code session here. These are the athlete's rules for
the developer, set on 24 Sep 2026 after six months in which conclusions
were stated with the same conviction whether measured or guessed.

## Claims carry their basis

Every statement about how this system behaves says which of these it is:

- **measured** — a test, a replay, or a query over real data ran and said so
- **inferred** — read from the code, not run
- **assumed** — neither

Say it inline ("(measured)", "(inferred)", "(assumed)") every time, in chat
and in PR descriptions. A number stated without its basis is a guess.

## Measure before proposing

No proposal to change how the coach or the programme decides goes to the
athlete before the relevant behaviour has been counted from the data
(`replay_export.py`, the export under `tests/fixtures/export/`, or the live
tables). On 24 Sep a proposal to remove the model's authority over numbers
was made from a feeling and reversed by a count within the hour. Count
first.

## The claims ledger

`docs/CLAIMS.md` records every non-trivial claim with its date, basis, and
whether it held. Rules:

- A claim marked **assumed** must be verified or marked wrong within 14
  days; `tests/test_claims_ledger.py` fails CI otherwise.
- A claim that turned out wrong stays in the ledger with what was wrong.
- Each PR that changes coaching behaviour adds its central claim as a row.

## Tests mean the whole suite, the way CI runs it

"Tests pass" means `python -m unittest discover -s tests` AND the module
form CI used to run (`python -m unittest tests.test_regressions`) — both,
before every push. On 24 Sep the suite passed under one and failed under
the other; two red runs on main.

## Nothing merges while a session is live

A merge to main redeploys Railway and kills in-flight coach requests. Ask,
or check the session state, before every merge.

## Decisions go in by code

A decision the athlete has made is applied by code (a dated fix, a setting,
a rule), never left as his homework. He runs SQL migrations himself; give
him the text. Never paste tokens or keys; `Vaux/Shared/Config.swift` holds
secrets and is read only for the one line needed.

## The coach is a judgement, not a spreadsheet

The product is a coach that reads recovery, history, a niggle and what the
athlete said, and decides. Guards bound it; they do not replace it. The
scorecard (`scorecard.py`) measures whether its decisions and the
programme's were right; that count, not an impression, decides how much
room each gets.

## No cap on the athlete's fixes

A limit on pull requests per month was tried on 24 Sep and withdrawn on 25
Sep: it rationed the athlete's fixes to flatter the developer's churn. The
measures of the developer are the rework rate and the regression count in
`docs/RELIABILITY.md`. A bug the athlete finds is fixed; related bugs may be
grouped when that is obviously right, never as a reason to wait.
