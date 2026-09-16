# Optimisation plan

Quality first. Nothing here is allowed to make the coaching worse; every stage
has a gate it must pass before the next begins, and the gates are measured,
not judged.

## Where the cost is

- The system prompt is ~25,600 tokens. Largest sections: Training Philosophy
  (~4,400), Session Templates (~3,500), Progressive Overload (~3,000).
- Every call also carries the stable context (a month of session history,
  volume and load blocks) and the live workout state.
- With the one-hour prompt cache, repeat reads of the prompt and stable
  context are cheap. What the athlete waits on is OUTPUT tokens (thinking
  included) and cache misses.

## The gates

1. **Audit rule-break rate** (`reports/` from `.github/workflows/audit.yml`).
   Must not rise over a block.
2. **Stored plan decisions** (`prescription_decisions`): adjust rate and
   whether reasons name a cause, printed in the Sunday report's Decisions
   section since 16 Sep (#257), with the programme shadow — replies outside
   the contract whose numbers the programme would have replaced — recorded
   to `programme_shadow` and counted beside it. The substitution flag is
   judged on these two numbers, not on a log.
3. **Regression tests** that assert the prompt still carries specific rules.
4. **Model call costs** (`model_calls`, reported weekly to
   `reports/model_calls.md`): seconds, tokens, cache hit rate per call kind.

## Stages

**1 — Output tokens (shipped, #205/#206).** Accepts omit their numbers; an
invalid exercise falls back to the programme, never to prose. Extended
thinking stays on. No coaching change.

**2 — Measure (in progress).** `usage.record_call` writes every call.
`usage_report.yml` prints and commits the summary each Sunday. One to two
weeks of data before anything else moves. Questions it answers: how long an
opening actually takes and where; cache hit rate; cost of thinking per
opening.

**3 — Prompt: keep the rules, remove the history.** Much of the prompt is
narrative about past failures whose rule is now enforced in code (set
counts, substitution, replay, stale sessions). Each paragraph is either a
rule the coach needs or a story the code has made redundant. Stories move to
code comments and tests; rules stay. Cut in passes of a few thousand tokens,
gates 1–3 checked after each. Target ~15,000 tokens with no rule lost.

**4 — Context shape.** Older sessions in the stable block become one line
each, the last week stays in full. Gate 2 must still show decisions citing
the right last set (the accept-honesty rule already checks this).

**5 — Cache hygiene (moved ahead of Stage 3 on 15 Sep; first cut shipped).**
The first priced report put 55% of the bill on set replies and two thirds
of each set reply on ~13,500 uncached input tokens: the whole live half of
the context, re-sent on every logged set although most of it — today's
header, the programme's proposal with its decisions and constraints, the
block's emphasis, the session template — does not change within a session.
First cut: the live half is split by volatility into a DAY part behind a
second one-hour cache breakpoint and a SET part (today's rows, the
comparisons, steps and energy, the Watch feed, the live workout state)
outside every breakpoint. Same words, same blocks, plan before progress.
Expected in gate 4: set_reply and prose `in (med)` falling from ~13k
toward ~5k, cache hit rising. Second cut, gated on that reading: the
conversation history is the other large uncached part; caching it needs
the set part moved after the history (into the last user turn), which is
a prompt-shape change and goes through gates 1–3.

## Order

Stage 5 runs now, ahead of Stage 3, because it has a number and no coaching
change. Stage 3 does not start until Stage 2's numbers are in. A stage that
fails a gate is reverted, not tuned.
