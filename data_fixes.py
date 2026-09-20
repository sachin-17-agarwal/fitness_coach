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


def _clear_constraint(exercise: str, why: str) -> str:
    """Clear one standing constraint through the path a chat Decision line
    takes, verified; the sentence returned goes in the log."""
    from constraints import load_active, norm_name, record_decisions
    from data import get_supabase
    if not get_supabase():
        raise RuntimeError("no database connection")
    active = [c for c in load_active() if norm_name(c.get("exercise", "")) == norm_name(exercise)]
    if not active:
        return f"no active {exercise} constraint; nothing to clear"
    record_decisions(f"Decision: {exercise} | clear")
    if [c for c in load_active() if norm_name(c.get("exercise", "")) == norm_name(exercise)]:
        raise RuntimeError(f"{exercise} constraint still active after the clear")
    cap = f"{active[0].get('max_load_kg')}kg" if active[0].get("max_load_kg") is not None else "note"
    return f"cleared {exercise} ({cap}, since {active[0].get('set_on')}): {why}"


def _fix_block_review_facts_version() -> str:
    """Remove any unanswered review whose fact sheet predates the current
    FACTS_VERSION, so Home prepares it again under the current rules."""
    from block_review import FACTS_VERSION
    from data import get_supabase
    supabase = get_supabase()
    if not supabase:
        raise RuntimeError("no database connection")
    rows = (supabase.table("block_reviews").select("id, status, facts").eq("status", "shown").execute()).data or []
    bad = []
    for row in rows:
        facts = row.get("facts") or {}
        if isinstance(facts, str):
            facts = json.loads(facts or "{}")
        if facts.get("version") != FACTS_VERSION:
            bad.append(row["id"])
    for rid in bad:
        supabase.table("block_reviews").delete().eq("id", rid).execute()
    return f"removed {len(bad)} review(s) older than facts v{FACTS_VERSION}: {bad}"


def _facts_version_key() -> str:
    from block_review import FACTS_VERSION
    return f"block-review-facts-v{FACTS_VERSION}"


# History first (fixes_2026_09.py, deleted once /status shows them applied),
# then the standing fix keyed on the block review's facts version.
from fixes_2026_09 import (FIXES_2026_09, _fix_2026_09_19_block_review_emphasis,  # noqa: E402,F401 — re-exported for tests
                           _fix_2026_09_19_block_review_loose_sets, _fix_2026_09_19_block_review_window,
                           _fix_2026_09_19_clear_cable_crunch_cap, _fix_2026_09_19_clear_leg_press_note,
                           _fix_2026_09_19_emphasis_triceps_chest, _fix_2026_09_19_incline_press_alias,
                           _fix_2026_09_19_restore_next_emphasis)

FIXES = [
    *FIXES_2026_09,
    (_facts_version_key(), _fix_block_review_facts_version),
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
