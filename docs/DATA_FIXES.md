# Data fixes — the record

Decisions and corrections written into the live records by code, once, at
startup (`data_fixes.py`). A fix has a dated key; applied keys sit in memory
under `data_fixes_applied` and `/status` lists them. A fix that fails is
retried at the next start and never marked applied. Nothing here calls a
model, and nothing here is the athlete's homework.

## Standing

| key | what | since |
|---|---|---|
| `block-review-facts-v{N}` | removes any unanswered block review built under an older facts version, so Home prepares it again under the current rules; bump `FACTS_VERSION` in `block_review.py` and the fix follows | 19 Sep 2026 |

## History — 19 Sep 2026 (`fixes_2026_09.py`, delete once all applied)

| key | what it did | why |
|---|---|---|
| `2026-09-19-emphasis-triceps-chest` | queued triceps (Overhead Cable Extension) and chest (Cable Fly (Low To High)) as next block's emphasis | agreed in chat 12 Sep, never recorded; two blocks ran without it |
| `2026-09-19-block-review-window` | removed reviews whose block started on the day they were read | the first review read a whole block as one day |
| `2026-09-19-block-review-emphasis` | removed unanswered reviews with an Emphasis-next for a muscle over its band or already set | one would have overwritten the queued movement with "Trim weekly sets" |
| `2026-09-19-block-review-loose-sets` | removed unanswered reviews computed before the 13–20 rep rule | Seated Leg Curl read −10.9% while the app read it up |
| `2026-09-19-restore-next-emphasis` | deleted the orphan pick rows dated 19 Sep and queued the emphasis again | the review had consumed the emphasis and dated the pick to a day the opening would never look up |
| `2026-09-19-incline-press-alias` | recorded "Incline Press" as an alias of "Incline Barbell Press" in the exercise library | one lift compared as two |
| `2026-09-19-clear-cable-crunch-cap` | cleared the 105 kg Cable Crunch cap | decided in chat 19 Sep: heavier stacks when free, reassess next review |
| `2026-09-19-clear-leg-press-note` | cleared the Leg Press "too light" note | approved on the dry-run review card, which recorded nothing; 245 x 15 did what it asked |

When `/status` shows all eight keys under `data_fixes`, `fixes_2026_09.py`
and its import in `data_fixes.py` go, and this table is the record.
