"""Dated one-off fixes from 19 Sep 2026, kept runnable until /status shows
every key applied in production, then deleted. The story of each is in
docs/DATA_FIXES.md. Nothing new goes here: a new fix is a dated function in
data_fixes.py, and this file is history.
"""

from __future__ import annotations

import json
import logging

log = logging.getLogger(__name__)


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


def _fix_2026_09_19_block_review_loose_sets() -> str:
    """Reviews computed before the review learned the app's rule for sets
    past 12 reps carry a false drop (Seated Leg Curl -10.9% for a peak week
    of 110 x 16). Remove any unanswered review whose strength facts predate
    the rule (no `this_loose` key) so Home prepares it again with matching
    numbers."""
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
        strength = facts.get("strength") or []
        if strength and any("this_loose" not in f for f in strength):
            bad.append(row["id"])
    for rid in bad:
        supabase.table("block_reviews").delete().eq("id", rid).execute()
    return f"removed {len(bad)} review(s) computed before the loose-set rule: {bad}"


def _fix_2026_09_19_restore_next_emphasis() -> str:
    """The block review of 19 Sep called current_block_weak_points at week 1
    day 1, which made the coming block's pick on the ended block's last day:
    it consumed the queued emphasis (triceps, chest) and stored the pick dated
    19 Sep, a date the block's opening would never look up. Remove that
    orphan pick and queue the emphasis again, exactly as it stood that
    morning; the opening session makes the pick from it."""
    from coach import load_system_prompt  # local: coach imports widely
    from data import get_supabase
    from weakpoints import DECISION_PREFIX, PENDING_PREFIX, set_next_emphasis
    supabase = get_supabase()
    if not supabase:
        raise RuntimeError("no database connection")
    orphans = (supabase.table("prescription_decisions").select("id, exercise, date")
               .eq("date", "2026-09-19").like("exercise", f"{DECISION_PREFIX}%").execute()).data or []
    for row in orphans:
        supabase.table("prescription_decisions").delete().eq("id", row["id"]).execute()
    prompt = load_system_prompt()
    notes = []
    for muscle, movement in (("triceps", "Overhead Cable Extension"), ("chest", "Cable Fly (Low To High)")):
        supabase.table("prescription_decisions").delete().eq("exercise", f"{PENDING_PREFIX}{muscle.capitalize()}").execute()
        note = set_next_emphasis(prompt, muscle, movement)
        if note.startswith("I can't") or "isn't a muscle" in note:
            raise RuntimeError(f"{muscle}: {note}")
        notes.append(note)
    return f"removed {len(orphans)} orphan pick row(s) dated 2026-09-19; " + " | ".join(notes)


def _fix_2026_09_19_incline_press_alias() -> str:
    """The template says "Incline Press", the log says "Incline Barbell
    Press" (programme.py has said so since August); the review compared them
    as two lifts. Record the alias in the exercise library so every reader
    treats them as one. Nothing to do when the library has neither name."""
    from data import get_supabase
    from exercises import add_alias
    supabase = get_supabase()
    if not supabase:
        raise RuntimeError("no database connection")
    rows = (supabase.table("exercises").select("id, name, aliases").execute()).data or []
    names = {(r.get("name") or "").strip().lower(): r for r in rows}
    if "incline barbell press" in names:
        aliases = names["incline barbell press"].get("aliases") or []
        if any(isinstance(a, str) and a.strip().lower() == "incline press" for a in aliases):
            return "Incline Press already an alias of Incline Barbell Press"
        if not add_alias("Incline Barbell Press", "Incline Press"):
            raise RuntimeError("could not add the alias")
        return "Incline Press recorded as an alias of Incline Barbell Press"
    if "incline press" in names:
        if not add_alias("Incline Press", "Incline Barbell Press"):
            raise RuntimeError("could not add the alias")
        return "Incline Barbell Press recorded as an alias of Incline Press"
    return "library has neither incline press; nothing merged"


def _fix_2026_09_19_clear_cable_crunch_cap() -> str:
    """Decided in chat on 19 Sep: the 105kg Cable Crunch cap comes off for
    next block. The gym has two heavier stacks (about 130kg) that are usually
    taken; the athlete will use them when free and reassess next review if
    they prove too hard to get. Cleared through the same path a chat
    `Decision:` line takes, so the coach and the programme stop honouring it."""
    from constraints import load_active, norm_name, record_decisions
    from data import get_supabase
    if not get_supabase():
        raise RuntimeError("no database connection")
    active = [c for c in load_active() if norm_name(c.get("exercise", "")) == norm_name("Cable Crunch")]
    if not active:
        return "no active Cable Crunch constraint; nothing to clear"
    record_decisions("Decision: Cable Crunch | clear")
    still = [c for c in load_active() if norm_name(c.get("exercise", "")) == norm_name("Cable Crunch")]
    if still:
        raise RuntimeError("Cable Crunch constraint still active after the clear")
    return f"cleared the Cable Crunch cap ({active[0].get('max_load_kg')}kg, since {active[0].get('set_on')})"


def _fix_2026_09_19_clear_leg_press_note() -> str:
    """Approved on the 19 Sep dry-run review card, which recorded nothing:
    the Leg Press "too light, open heavier than 242.5kg" note is done — the
    block delivered 245 x 15. The coach recommended the same."""
    from data_fixes import _clear_constraint  # the helper stays with the mechanism
    return _clear_constraint("Leg Press", "245kg x15 this block did what the note asked")


FIXES_2026_09 = [
    ("2026-09-19-emphasis-triceps-chest", _fix_2026_09_19_emphasis_triceps_chest),
    ("2026-09-19-block-review-window", _fix_2026_09_19_block_review_window),
    ("2026-09-19-block-review-emphasis", _fix_2026_09_19_block_review_emphasis),
    ("2026-09-19-block-review-loose-sets", _fix_2026_09_19_block_review_loose_sets),
    ("2026-09-19-restore-next-emphasis", _fix_2026_09_19_restore_next_emphasis),
    ("2026-09-19-incline-press-alias", _fix_2026_09_19_incline_press_alias),
    ("2026-09-19-clear-cable-crunch-cap", _fix_2026_09_19_clear_cable_crunch_cap),
    ("2026-09-19-clear-leg-press-note", _fix_2026_09_19_clear_leg_press_note),
]
