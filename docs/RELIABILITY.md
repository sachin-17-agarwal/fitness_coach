# Reliability record

*Written 24 Sep 2026 at the athlete's request, from the GitHub pull-request*
*record (api.github.com, all closed PRs), after six months in which fixes were*
*announced as done and were not. This is the developer's accountability file;*
*`docs/CLAIMS.md` holds the individual claims. Both are the athlete's to use.*

## The numbers

- **325 pull requests merged** between 2026-04-06 and 2026-09-24.
- Merged per month: 2026-04 **33**, 2026-05 **26**, 2026-06 **14**, 2026-07 **16**, 2026-08 **16**, 2026-09 **220**.
- **123 of 325 merged PRs (38%) describe themselves as re-fixing something an earlier PR had been meant to fix** — their own titles and descriptions say "still", "again", "silently", "did not hold", "botched", "revert".

The same subjects, fixed repeatedly (by words in the PR title):

| subject | merged PRs | months |
|---|---:|---:|
| the card / prescription | 59 | 5 |
| loads and history | 46 | 5 |
| watch / heart rate / recovery | 15 | 5 |
| the prompt | 12 | 3 |
| the card moving between lifts | 9 | 4 |
| deload / the week | 6 | 3 |
| warm-ups | 6 | 4 |
| set counts | 4 | 3 |
| rest timer | 4 | 3 |
| back-offs | 3 | 1 |

## What it means

September's 220 merges are the period of daily Claude Code sessions. A subject
fixed 59 times is not 59 bugs; it is a few causes patched at the surface,
each patch small enough to look complete and shipped the same day with
"done" attached. The daily pull request is how the causes stayed untreated.

The training programme underneath delivered over the same period (estimated
1RM up 7–27% Aug→Sep on every lift but two; measured from the export). The
coach layer consumed most of the development spend and is the part that was
still unreliable at the end of it.

## The commitments this record is judged against

*Rewritten 25 Sep after the athlete's objection: a cap of four PRs a month
rationed HIS fixes to flatter the developer's churn count. It measured the
wrong party and is withdrawn. These measure the developer.*

1. **"Done" means the athlete has trained on it.** A merged change is *merged,
   unverified* until then.
2. **Rework rate.** A PR that a later PR has to fix again is a rework. Baseline
   38% over April–September (123 of 325). Counted from the PR record each
   Sunday; recorded here. The block's question is whether it falls.
3. **Regressions the developer introduces**, each with its cause, in
   `docs/CLAIMS.md`. One so far this week (the 110 s first message, #324).
4. **Measured before built.** No change to how the coach or the programme
   decides without the count first.
5. **No cap on fixing the athlete's bugs.** A bug he finds gets fixed. Grouping
   related bugs into one change is suggested when it is obviously right; it is
   never a reason for him to wait.

## Method

`GET /repos/sachin-17-agarwal/fitness_coach/pulls?state=closed` paged; rework
counted by a fixed word list over title + description; subjects by regular
expression over the title. The word list under-counts (a re-fix that does not
say so is missed) and never over-counts a PR twice. Re-run the count with the
script in the 24 Sep session transcript or by hand; the API is public.
