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


def case_variant_plan(names: dict[str, int]) -> dict[str, str]:
    """{variant spelling: canonical spelling} for names that differ only by
    case or spacing; the most-logged spelling wins ("Leg press" 31 sets ->
    "Leg Press" 143). Real variants ("Machine Chest Fly" vs "Cable Chest
    Fly") are different lifts or aliases and are left alone."""
    groups: dict[str, list] = {}
    for name, count in names.items():
        key = " ".join((name or "").split()).lower()
        if key:
            groups.setdefault(key, []).append((name, count))
    plan = {}
    for key, variants in groups.items():
        if len(variants) < 2:
            continue
        canonical = max(variants, key=lambda v: (v[1], v[0] == v[0].title(), v[0]))[0]
        for name, _ in variants:
            if name != canonical:
                plan[name] = canonical
    return plan


def _fix_2026_09_25_exercise_case_variants() -> str:
    """Twelve lifts were logged under two or three spellings differing only
    by case ("Leg press" 31 sets beside "Leg Press" 143; measured from the
    23 Sep export). Each split a lift's history in two for the strength page,
    the step inference and the reviews. Rename the minority spellings to the
    majority's, in workout_sets."""
    from data import get_supabase
    supabase = get_supabase()
    if not supabase:
        raise RuntimeError("no database connection")
    rows = (supabase.table("workout_sets").select("exercise").execute()).data or []
    counts: dict[str, int] = {}
    for r in rows:
        n = r.get("exercise")
        if n:
            counts[n] = counts.get(n, 0) + 1
    plan = case_variant_plan(counts)
    if not plan:
        return "no case variants in workout_sets"
    done = []
    for variant, canonical in sorted(plan.items()):
        supabase.table("workout_sets").update({"exercise": canonical}).eq("exercise", variant).execute()
        done.append(f"{variant} -> {canonical} ({counts[variant]} sets)")
    return "; ".join(done)


_PUSH = {"Chest", "Shoulders", "Triceps", "Front Delts", "Side Delts"}
_PULL = {"Back", "Biceps", "Rear Delts", "Lats", "Traps"}
_LEGS = {"Quads", "Hamstrings", "Glutes", "Calves", "Legs"}


def infer_session_type(exercises: list[str]) -> str | None:
    """Pull / Push / Legs / Cardio+Abs from the muscles a session's sets
    worked, by majority; None when nothing classifies."""
    from volume import resolve_muscle_group
    votes: dict[str, int] = {}
    for name in exercises:
        m = resolve_muscle_group(name) or ""
        t = ("Push" if m in _PUSH else "Pull" if m in _PULL else "Legs" if m in _LEGS else
             "Cardio+Abs" if m == "Abs" else None)
        if t:
            votes[t] = votes.get(t, 0) + 1
    return max(votes, key=votes.get) if votes else None


def _fix_2026_09_25_session_hygiene() -> str:
    """S9. Thirty-six finished sessions hold no sets and no tonnage — app
    tests and false starts, March to September — and two typed `Unknown`
    hold real work. The first become `abandoned`, the second get the type
    their sets say (docs/hygiene_2026-09-25.md is the dry run the athlete
    approved)."""
    from data import get_supabase, now_local
    supabase = get_supabase()
    if not supabase:
        raise RuntimeError("no database connection")
    today = now_local().strftime("%Y-%m-%d")
    sessions = (supabase.table("workout_sessions").select("id, date, type, tonnage_kg, status").execute()).data or []
    sets = (supabase.table("workout_sets").select("workout_session_id, exercise, is_warmup").execute()).data or []
    by_session: dict[str, list] = {}
    for s in sets:
        if not s.get("is_warmup"):
            by_session.setdefault(s.get("workout_session_id"), []).append(s.get("exercise") or "")
    abandoned = retyped = 0
    for s in sessions:
        if str(s.get("date") or "") >= today or s.get("status") == "abandoned":
            continue
        worked = by_session.get(s["id"], [])
        if not worked and not (s.get("tonnage_kg") or 0):
            supabase.table("workout_sessions").update({"status": "abandoned"}).eq("id", s["id"]).execute()
            abandoned += 1
        elif s.get("type") == "Unknown" and worked:
            t = infer_session_type(worked)
            if t:
                supabase.table("workout_sessions").update({"type": t}).eq("id", s["id"]).execute()
                retyped += 1
    return f"{abandoned} empty sessions marked abandoned; {retyped} Unknown sessions typed from their sets"


def backfill_stamps(sessions: list[dict], cycle: list[str], block_weeks: int = 4) -> dict[str, tuple[int, int]]:
    """S4. Week and day for the resistance sessions before stamping began,
    by walking the rotation BACKWARDS from the earliest stamped session:
    each session is one slot; a session whose type is not the expected
    slot's is a missed slot (or, when it repeats the type just placed, a
    second session of the same day). Four rotations make a block. This is
    inference from the rotation, not a record; the rows say so."""
    order = {t: i for i, t in enumerate(cycle)}
    rows = sorted((s for s in sessions if s.get("type") in order and (s.get("tonnage_kg") or 0) > 0),
                  key=lambda s: (str(s.get("date")), str(s.get("start_time") or "")))
    stamped = [s for s in rows if s.get("mesocycle_week") and s.get("mesocycle_day")]
    if not stamped:
        return {}
    first = stamped[0]
    week, day = int(first["mesocycle_week"]), int(first["mesocycle_day"])
    out: dict[str, tuple[int, int]] = {}
    last_type = first["type"]
    for s in reversed([r for r in rows if str(r.get("date")) < str(first["date"]) or
                       (str(r.get("date")) == str(first["date"]) and str(r.get("start_time") or "") < str(first.get("start_time") or ""))]):
        if s.get("mesocycle_week") and s.get("mesocycle_day"):
            week, day, last_type = int(s["mesocycle_week"]), int(s["mesocycle_day"]), s["type"]
            continue
        if s["type"] == last_type:
            out[s["id"]] = (week, day)          # a second session of the same slot (a duplicate day)
            continue
        target = order[s["type"]] + 1
        # step back one slot at a time until the slot is this session's type
        for _ in range(len(cycle)):
            day -= 1
            if day < 1:
                day = len(cycle)
                week = block_weeks if week <= 1 else week - 1
            if day == target:
                break
        out[s["id"]] = (week, day)
        last_type = s["type"]
    return out


def _fix_2026_09_25_stamp_backfill() -> str:
    """S4. 143 of 165 resistance sessions (April-August) carry no mesocycle
    week or day; the block review, the peak-week reference and the replay
    cannot place them. Stamped here by rotation inference (backfill_stamps),
    marked as such in notes."""
    from data import CYCLE, get_supabase
    supabase = get_supabase()
    if not supabase:
        raise RuntimeError("no database connection")
    sessions = (supabase.table("workout_sessions")
                .select("id, date, start_time, type, tonnage_kg, status, mesocycle_week, mesocycle_day, notes")
                .neq("status", "abandoned").execute()).data or []
    stamps = backfill_stamps(sessions, CYCLE, block_weeks=4)
    n = 0
    for s in sessions:
        if s["id"] in stamps:
            week, day = stamps[s["id"]]
            note = ((s.get("notes") or "") + " ").strip()
            note = (note + " " if note else "") + "week/day backfilled 2026-09-25 by rotation inference"
            supabase.table("workout_sessions").update({"mesocycle_week": week, "mesocycle_day": day, "notes": note}).eq("id", s["id"]).execute()
            n += 1
    return f"{n} sessions stamped by rotation inference"


ROLLOUT_STANDING_LINE = ("Substitute: Ab Wheel Rollout -> Standing Ab Wheel Rollout | standing | "
                         "12-14 reps kneeling at RPE 6-8 since 10 Sep 2026; the programme progresses "
                         "the rollout by lever, never reps (athlete, 25 Sep 2026)")


def _fix_2026_09_25_rollout_standing() -> str:
    """The athlete's decision of 25 Sep 2026: the rollout goes standing. Recorded
    as the Substitute decision the session shape already reads (shape.py), so
    the card names `Standing Ab Wheel Rollout` in the rollout's slot and the
    new movement carries its own history. Idempotent: skipped when a recorded
    substitution for the rollout already exists."""
    from data import get_supabase, now_local
    supabase = get_supabase()
    if not supabase:
        raise RuntimeError("no database connection")
    rows = (supabase.table("decision_captures").select("id, line").eq("kind", "substitute")
            .eq("status", "recorded").execute()).data or []
    if any("ab wheel rollout ->" in (r.get("line") or "").lower() for r in rows):
        return "a recorded rollout substitution already exists; nothing written"
    stamp = now_local().isoformat()
    supabase.table("decision_captures").insert({
        "line": ROLLOUT_STANDING_LINE, "kind": "substitute", "source": "review", "status": "recorded",
        "rationale": "Ab Wheel Rollout at 12-14 kneeling reps, RPE 6-8, three sessions running; the lever rule",
        "proposed_at": stamp, "answered_at": stamp, "answer_text": "athlete, 25 Sep 2026",
    }).execute()
    return "recorded: Ab Wheel Rollout -> Standing Ab Wheel Rollout (standing)"


FIXES_2026_09 = [
    ("2026-09-25-exercise-case-variants", _fix_2026_09_25_exercise_case_variants),
    ("2026-09-25-session-hygiene", _fix_2026_09_25_session_hygiene),
    ("2026-09-25-stamp-backfill", _fix_2026_09_25_stamp_backfill),
    ("2026-09-25-rollout-standing", _fix_2026_09_25_rollout_standing),
    ("2026-09-19-emphasis-triceps-chest", _fix_2026_09_19_emphasis_triceps_chest),
    ("2026-09-19-block-review-window", _fix_2026_09_19_block_review_window),
    ("2026-09-19-block-review-emphasis", _fix_2026_09_19_block_review_emphasis),
    ("2026-09-19-block-review-loose-sets", _fix_2026_09_19_block_review_loose_sets),
    ("2026-09-19-restore-next-emphasis", _fix_2026_09_19_restore_next_emphasis),
    ("2026-09-19-incline-press-alias", _fix_2026_09_19_incline_press_alias),
    ("2026-09-19-clear-cable-crunch-cap", _fix_2026_09_19_clear_cable_crunch_cap),
    ("2026-09-19-clear-leg-press-note", _fix_2026_09_19_clear_leg_press_note),
]
