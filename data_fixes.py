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


FIXES = [
    ("2026-09-19-emphasis-triceps-chest", _fix_2026_09_19_emphasis_triceps_chest),
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
