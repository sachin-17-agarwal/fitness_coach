# Decisions captured when reached

*Designed 17 September 2026, approved and built 18 September. Roadmap item
1.1b(3). All three stages are live: `decisions.py`, migration 009, the
prompt rule, the Home card, chat answers, the report section (18 Sep); the
in-chat card and the session-shape grammar — `Substitute:` and `Order:`,
applied by `shape.py` inside `parse_session_template` (23 Sep).*

## The problem, from the log

On 12 September the athlete and the coach agreed in chat that the next
block's emphasis would be triceps and chest. Nothing recorded it. The block
that opened on 15 September picked hamstrings from the deficit rule, the
coach prescribed Seated Leg Curl on a Cardio+Abs day, and the athlete had to
ask why. The agreement had been real; it lived only in a conversation four
days old that the coach no longer saw.

The same shape recurs. "Hold the shoulder press at 70 kg" was agreed on 13
Sep and stored with no ceiling until the parser was widened on 17 Sep. Three
chat commands sat in the roadmap under "messages still worth sending" for
two days because a decision reached in conversation depended on the athlete
remembering to type it again in the right grammar.

The system already has three ways to store a decision, all live:

| Kind | Grammar | Stored in | Fires when |
|---|---|---|---|
| Standing constraint | `Decision: <lift> \| max load Nkg \| <why>` or `\| clear` | `exercise_constraints` | the coach writes the line in any reply |
| Next block's emphasis | `Emphasis-next: <muscle> \| <note>` | memory (`weakpoints.PENDING_PREFIX`) | the coach writes the line, or the athlete types `emphasis next: …` |
| This block's weak points | `weak points: a, b` / `weak points none` | memory | the athlete types the command |

And 2.5's block review proposes lines in the first two grammars for the
athlete to approve. What is missing is not storage or grammar. It is the
moment between "we agree" and "it is written": today that moment belongs
to the model's memory of the rule, and when the model agrees in prose and
moves on, the decision is lost.

## What changes

**One grammar, three entry points, one confirmation.** A decision that
outlives today is written as a recordable line — the two grammars above
plus a third kind, session order and substitutions, added below. The line
can arrive from the opening plan, from a chat reply or from the block
review. Whoever writes it, the athlete confirms it with one tap or one
word, and the same code applies it. The confirmation is the design's only
new gesture; everything after it exists.

### 1. The coach proposes, in the reply where it is agreed

A new prefix, `Proposed:`, in front of any recordable line:

```
Proposed: Emphasis-next: triceps | overhead cable extension, weakest of the push muscles this block
Proposed: Decision: Machine Shoulder Press | max load 70kg | shoulder niggle; progress by reps, RPE 8 cap
```

The prompt rule (replacing the current "Standing Decisions" section):

> When something you two agree on outlives this session — a load cap, a
> movement off the table, next block's emphasis, a lift moved for good —
> write it as a `Proposed:` line in the reply where it is agreed, in the
> recordable grammar. One line per decision. He confirms it with a tap;
> until he does it is a proposal, not a fact. A fact he states outright
> ("the stack tops out at 105") is still a `Decision:` line, recorded at
> once as now.

The distinction is who decided. He said it as a fact: record it (today's
behaviour, unchanged). It emerged from the conversation: propose it, and
let him close it. The 12 Sep case is the second kind.

### 2. Code holds the proposal and asks once

After every reply, `decisions.py` (new, and the home of the grammar that
`block_review._LINE_RE` and `constraints.DECISION_RE` currently hold
separately) parses `Proposed:` lines. Each becomes a row in a new table
`decision_captures` (migration 009): the line, its kind, the rationale
sentence the coach gave with it, `proposed_at`, `session_id`, `source`
(`coach` | `review` | `athlete`), `status` (`proposed` | `recorded` |
`declined` | `superseded`), `answered_at`, `answer_text`.

The app renders the proposal as a card under the coach's reply, not as a
line of chat text (today a `Decision:` line shows as raw text — the app has
no rule for it). The card reads the line in plain words and offers two
actions:

```
┌──────────────────────────────────────────────┐
│ DECISION · NEXT BLOCK                        │
│ Emphasis: triceps                            │
│ overhead cable extension, weakest of the     │
│ push muscles this block                      │
│                                              │
│        [ Record ]          [ Not now ]       │
└──────────────────────────────────────────────┘
```

"Record" posts to `POST /api/decision/answer {id, answer: "record"}`;
the server applies the line through the existing paths
(`constraints.record_decisions`, `weakpoints.set_next_emphasis`) and marks
the row `recorded`. The card collapses to one line: "Recorded · 17 Sep".
"Not now" marks it `declined` and the card collapses to "Not recorded". In
chat, the athlete's next message also answers it — "yes", "record it",
"no" — through the grammar `block_review.parse_answer` already accepts, so
a Watch or a busy hand does not need the button.

**Unanswered proposals do not chase him during the session.** The card is
passive. It reappears in one place afterwards: the Home tab, under the
recovery digest, as "1 decision waiting from Tuesday's Push" with the same
two actions, until answered. The briefing is not part of this: it is not read.
The block review's fact sheet lists any still open at rollover, so the
review can propose them again or let them lapse. Nothing is recorded by
silence; nothing is lost by it either.

### 3. The safety net measures the misses

The prompt rule can fail exactly as the current one did. So the code checks
independently: `decisions.lasting_phrases(user_message)` matches the
athlete's message against a small pattern set — `next block`, `from now
on`, `for the rest of the block`, `hold at`, `cap`, `max`, `no more than`,
`stop doing`, `drop … for good`, `permanently`, `every session`, `always`,
`never again` — and when it matches and the coach's reply carries no
recordable line (`Decision:`, `Proposed:`, `Emphasis-next:`), a row is
written with `source = detector`, `status = missed`, the phrase and the
reply's first sentence. No card, no interruption. The Sunday report gains
a "Decisions captured" section:

```
## Decisions captured

Proposed 6 (coach 5, review 1) · recorded 5 · declined 1 · median answer 40 s
Missed 1: "let's keep the leg curl at 110 for the rest of the block" (Legs, 24 Sep) — no recordable line in the reply.
```

That count is the gate. If the detector's misses stay at zero or one a
block, the prompt rule is enough. If they climb, stage two is a cheap
second call on the flagged reply alone — "did this reply agree to
something lasting; if so write it as a Proposed line" — costed against the
report before it is turned on. Not built now.

### 4. A third grammar: session shape

Two lasting decisions today have no line at all and live in the athlete's
head: a substitution held for the block ("overhead cable extension instead
of dips this block") and a permanent reorder. Both are today re-negotiated
every session in chat. Added to the grammar, applied through the template
override the coach already reads:

```
Substitute: Dips -> Overhead Cable Extension | this block | elbow
Order: Push | Machine Shoulder Press first | shoulder warm before pressing
```

`this block` expires at rollover; `standing` does not. Stored in
`decision_captures` and rendered into the session template block the
coach and the programme both read, so `build_proposal` proposes the
substitute with its own history rather than the original's. This is the
one piece with programme consequences, so it ships last and only if the
first two grammars have run clean for a block.

## What it does not do

- It does not decide anything. Every recorded line was either stated by
  the athlete as a fact or confirmed by him with a tap or a word.
- It does not ask twice, or after the workout. One card, then Home.
- It does not touch today's numbers. A `Proposed:` line never replaces a
  `Revised:` block; the prompt keeps the two apart as now.
- It does not add a model call. Parsing is regex; applying is the code
  already live.

## Files

Backend: `decisions.py` (grammar, `parse_proposed`, `lasting_phrases`,
`apply_line`, `open_captures`, `answer`), `migrations/009_decision_captures.sql`,
`coach.py` (call `decisions.capture(reply, user_message, session_id)` after
`record_decisions`; route chat answers when a capture is open), `webhook.py`
(`GET /api/decision/pending`, `POST /api/decision/answer`),
`block_review.py` (fact sheet lists open captures; `_LINE_RE` moves to
`decisions.py`), `usage.py` (report section), `system_prompt.txt` (rule),
`tests/test_decisions.py`.

App: `Models/DecisionCapture.swift`, `ChatService.pendingDecisions /
answerDecision`, `Views/Chat/DecisionCard.swift`, Home tab line under the
digest, chat view strips `Proposed:` / `Decision:` / `Emphasis-next:` lines
from the prose bubble and renders the card instead.

## Order and size

1. Migration 009 (you run it), `decisions.py`, coach hook, prompt rule,
   report section, tests. Backend, half a day. Ships first because the
   detector starts counting misses even before the app shows a card;
   chat answers work from day one.
2. App card and Home line. Half a day, next build.
3. Session-shape grammar. A day, after one clean block.

## Verify

- Say "let's do triceps and chest next block" in chat: a card appears
  under the reply; "Record" puts `Emphasis-next: triceps …` in memory and
  the next block's opening picks it. The roadmap's "messages still worth
  sending" list empties.
- Say "keep the leg curl at 110 for the block" and get a prose-only reply:
  no card, and Sunday's report shows one miss with the phrase.
- Leave a card unanswered: it is on Home the next morning; the block
  review's sheet lists it at rollover.

## Gate

Over the first block: every lasting agreement in chat appears as a
proposal or a miss (nothing lost), misses at most one, and at least four in
five proposals answered within a day. Rule-break rate (gate 1) unchanged.
