"""Data fixes: decisions and corrections written into the live records by
code, once, at startup — never left as homework in a plan document.

Each fix has a key; applied keys are kept in memory under APPLIED_KEY so a
redeploy does not repeat one. A fix that fails logs and is retried at the
next start. Nothing here calls a model.
"""

from __future__ import annotations

import json
import logging

from memory import load_memory, set_memory_value

log = logging.getLogger(__name__)

APPLIED_KEY = "data_fixes_applied"


def _fix_2026_09_19_emphasis_triceps_chest() -> str:
    """The emphasis agreed in chat on 12 Sep and never recorded: triceps and
    chest, with the movements as they are logged, queued for the block that
    opens 20 Sep. Two blocks ran without it."""
    from coach import load_system_prompt  # local: coach imports widely
    from data import get_supabase
    from weakpoints import set_next_emphasis
    if not get_supabase():
        raise RuntimeError("no database connection")
    prompt = load_system_prompt()
    notes = []
    for muscle, movement in (("triceps", "Overhead Cable Extension"), ("chest", "Cable Fly (Low To High)")):
        note = set_next_emphasis(prompt, muscle, movement)
        # set_next_emphasis reports a refusal as prose; a fix that did not
        # land must not be marked applied.
        if note.startswith("I can't") or "isn't a muscle" in note:
            raise RuntimeError(f"{muscle}: {note}")
        notes.append(note)
    return " | ".join(notes)


def _fix_2026_09_19_block_review_window() -> str:
    """The first block review (19 Sep) was built on a one-day window: at
    rollover block_start answered "today" because no stamped opening session
    sat within its five-week floor. Remove every review whose block starts on
    the day it was read, so the Home card prepares the real one on the next
    open. Its dry-run answer, if any, described a review that never existed."""
    from data import get_supabase
    supabase = get_supabase()
    if not supabase:
        raise RuntimeError("no database connection")
    rows = (supabase.table("block_reviews").select("id, block_start, window_until").execute()).data or []
    bad = [r["id"] for r in rows if str(r.get("block_start")) == str(r.get("window_until"))]
    for rid in bad:
        supabase.table("block_reviews").delete().eq("id", rid).execute()
    return f"removed {len(bad)} one-day review(s): {bad}"


def _fix_2026_09_19_block_review_emphasis() -> str:
    """The second review of 19 Sep proposed 'Emphasis-next' for biceps and
    triceps, both OVER their bands, one already queued with its movement.
    Remove any unanswered review whose proposals would not pass the emphasis
    rule against its own fact sheet, so Home prepares it again."""
    from block_review import valid_proposals
    from data import get_supabase
    supabase = get_supabase()
    if not supabase:
        raise RuntimeError("no database connection")
    rows = (supabase.table("block_reviews").select("id, status, proposals, facts").eq("status", "shown")
            .execute()).data or []
    bad = []
    for row in rows:
        props, facts = row.get("proposals") or [], row.get("facts") or {}
        if isinstance(props, str):
            props = json.loads(props or "[]")
        if isinstance(facts, str):
            facts = json.loads(facts or "{}")
        if len(valid_proposals(props, facts)) != len(props):
            bad.append(row["id"])
    for rid in bad:
        supabase.table("block_reviews").delete().eq("id", rid).execute()
    return f"removed {len(bad)} review(s) with a disallowed Emphasis-next: {bad}"


FIXES = [
    ("2026-09-19-emphasis-triceps-chest", _fix_2026_09_19_emphasis_triceps_chest),
    ("2026-09-19-block-review-window", _fix_2026_09_19_block_review_window),
    ("2026-09-19-block-review-emphasis", _fix_2026_09_19_block_review_emphasis),
]


def applied_keys(memory: dict | None = None) -> list[str]:
    raw = (memory if memory is not None else load_memory()).get(APPLIED_KEY) or "[]"
    try:
        keys = json.loads(raw) if isinstance(raw, str) else list(raw)
    except ValueError:
        keys = []
    return [str(k) for k in keys]


def apply_pending(memory: dict | None = None) -> list[str]:
    """Run every fix not yet applied; returns the keys applied this call."""
    try:
        done = applied_keys(memory)
    except Exception:
        log.warning("Data fixes: could not read the applied list; skipping this start", exc_info=True)
        return []
    applied: list[str] = []
    for key, fn in FIXES:
        if key in done:
            continue
        try:
            note = fn()
            done.append(key)
            set_memory_value(APPLIED_KEY, json.dumps(done))
            applied.append(key)
            log.info("DATA FIX applied %s: %s", key, note)
        except Exception:
            log.exception("DATA FIX %s failed; will retry at the next start", key)
    return applied
