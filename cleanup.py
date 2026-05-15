"""
cleanup.py — One-off DB cleanup for bugs fixed in PR #5 and later.

Addresses five data issues caused by previous broken behaviour:

1. Stale open session(s) — workout_sessions rows with status='active' or
   'in_progress' whose date is before today. Mark them complete and clear
   workout_mode.

2. "Warm up" mis-labeled sets — workout_sets rows where exercise='Warm up'
   (or similar) were created because the extractor accepted user messages
   like "Warm up 60 x 10" as exercises. These sets have real weight/rep
   data but the wrong exercise name.

3. Duplicate memory keys — memory table may have multiple rows for
   mesocycle_week / mesocycle_day from when save_memory() upserted without
   on_conflict. Keep only the row with the latest updated_at per key.

4. Orphan duplicate-day sessions — when the coach's implicit-start path
   spawned a phantom session on top of an already-completed one (visible
   in the UI as a second "Active" card for the same date), the phantom
   sticks around forever. Delete any open session that shares a (date,
   type) with a completed sibling.

5. Duplicate `workout_sets` rows — when the iOS resume flow re-used a
   `set_number` that was already on disk for the same exercise/phase, the
   iOS insert path (no dedup) wrote a second row with identical keys.
   Collapse those groups to a single (earliest-logged) row and recompute
   each affected session's tonnage.

Usage:
    python cleanup.py                 # dry run — prints what would change
    python cleanup.py --execute       # actually apply changes
    python cleanup.py --only sessions # only run the sessions cleanup
    python cleanup.py --only sets     # only run the mis-labeled sets cleanup
    python cleanup.py --only memory   # only dedupe memory keys
    python cleanup.py --only orphans  # only delete same-day orphan sessions
    python cleanup.py --only dupsets  # only collapse duplicate set rows

For the mis-labeled sets, by default the script DELETES rows. Pass
--relabel-to "<name>" to rename them instead (e.g. the exercise they were
supposed to be logged as).
"""

import argparse
import sys
from collections import defaultdict

from data import get_supabase, now_local, today_local_str


BAD_EXERCISE_NAMES = {
    "warm up", "warmup", "warm-up",
    "rest", "back-off", "back off", "backoff",
    "cool down", "cool-down", "cooldown",
    "working set", "top set", "drop set",
}


def _is_bad_exercise_name(name: str) -> bool:
    return (name or "").strip().lower() in BAD_EXERCISE_NAMES


# ── 1. Stale sessions ────────────────────────────────────────────────────────

OPEN_STATUSES = ("active", "in_progress")


def cleanup_stale_sessions(supabase, execute: bool) -> None:
    today = today_local_str()
    print(f"\n[1/5] Checking for stale open sessions (date < {today})...")

    result = (
        supabase.table("workout_sessions")
        .select("id, date, type, status, start_time")
        .in_("status", list(OPEN_STATUSES))
        .execute()
    )
    rows = result.data or []
    stale = [r for r in rows if (r.get("date") or "") < today]

    if not stale:
        print("  No stale open sessions found.")
    else:
        for row in stale:
            print(f"  Stale session {row['id']} ({row['type']} on {row['date']}) "
                  f"started {row.get('start_time')}")

        if execute:
            for row in stale:
                supabase.table("workout_sessions").update({
                    "status": "complete",
                    "end_time": now_local().isoformat(),
                }).eq("id", row["id"]).execute()
                print(f"  -> Marked session {row['id']} complete.")
        else:
            print(f"  [dry-run] Would mark {len(stale)} session(s) complete.")

    # Always reset workout_mode if it's stuck active
    state = (
        supabase.table("memory")
        .select("key, value")
        .in_("key", ["workout_mode", "current_session_id", "session_start_time"])
        .execute()
    )
    state_map = {r["key"]: r["value"] for r in (state.data or [])}
    if state_map.get("workout_mode") == "active":
        session_id = state_map.get("current_session_id", "")
        start_time = state_map.get("session_start_time", "")
        # Consider it stuck if the session id points to a now-completed row OR
        # the session_start_time is before today.
        stuck = False
        if start_time and start_time < today:
            stuck = True
        if session_id and any(row["id"] == session_id for row in stale):
            stuck = True

        if stuck:
            print(f"  workout_mode='active' is stuck (session_id={session_id!r}, "
                  f"start_time={start_time!r})")
            if execute:
                for key, value in [
                    ("workout_mode", "inactive"),
                    ("current_session_id", ""),
                    ("current_exercise_index", "0"),
                    ("current_set_number", "0"),
                    ("current_exercise_name", ""),
                ]:
                    supabase.table("memory").upsert({
                        "key": key,
                        "value": value,
                        "updated_at": now_local().isoformat(),
                    }, on_conflict="key").execute()
                print("  -> Reset workout_mode to inactive.")
            else:
                print("  [dry-run] Would reset workout_mode to inactive.")
        else:
            print(f"  workout_mode='active' but not clearly stuck — leaving alone.")


# ── 2. Mis-labeled sets ──────────────────────────────────────────────────────

def cleanup_bad_exercise_sets(supabase, execute: bool, relabel_to: str) -> None:
    action = f"relabel to {relabel_to!r}" if relabel_to else "delete"
    print(f"\n[2/5] Finding workout_sets rows with bad exercise names ({action})...")

    # We can't OR on the server easily; fetch all and filter locally.
    result = (
        supabase.table("workout_sets")
        .select("id, date, exercise, actual_weight_kg, actual_reps, workout_session_id")
        .execute()
    )
    rows = result.data or []
    bad = [r for r in rows if _is_bad_exercise_name(r.get("exercise"))]

    if not bad:
        print("  No mis-labeled sets found.")
        return

    # Group by date for readable output
    by_date: dict[str, list[dict]] = defaultdict(list)
    for r in bad:
        by_date[r.get("date") or "unknown"].append(r)

    for date in sorted(by_date):
        print(f"  {date}: {len(by_date[date])} row(s)")
        for r in by_date[date][:5]:
            print(f"    - id={r['id']} exercise={r['exercise']!r} "
                  f"{r.get('actual_weight_kg')}kg x {r.get('actual_reps')}")
        if len(by_date[date]) > 5:
            print(f"    ... and {len(by_date[date]) - 5} more")

    print(f"  Total: {len(bad)} mis-labeled set(s)")

    if not execute:
        print(f"  [dry-run] Would {action} {len(bad)} row(s).")
        return

    if relabel_to:
        for r in bad:
            supabase.table("workout_sets").update({
                "exercise": relabel_to,
            }).eq("id", r["id"]).execute()
        print(f"  -> Relabeled {len(bad)} row(s) to {relabel_to!r}.")
    else:
        for r in bad:
            supabase.table("workout_sets").delete().eq("id", r["id"]).execute()
        print(f"  -> Deleted {len(bad)} row(s).")


# ── 3. Duplicate memory keys ─────────────────────────────────────────────────

def cleanup_duplicate_memory_keys(supabase, execute: bool) -> None:
    print("\n[3/5] Checking for duplicate memory rows per key...")

    result = (
        supabase.table("memory")
        .select("id, key, value, updated_at")
        .in_("key", ["mesocycle_week", "mesocycle_day"])
        .execute()
    )
    rows = result.data or []

    grouped: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        grouped[r["key"]].append(r)

    dupes_found = False
    for key, entries in grouped.items():
        if len(entries) <= 1:
            continue
        dupes_found = True
        # Keep the one with the latest updated_at
        entries_sorted = sorted(
            entries,
            key=lambda r: (r.get("updated_at") or ""),
            reverse=True,
        )
        keeper = entries_sorted[0]
        to_delete = entries_sorted[1:]
        print(f"  Key {key!r}: {len(entries)} rows. "
              f"Keeping id={keeper['id']} value={keeper['value']!r} "
              f"updated_at={keeper.get('updated_at')}")
        for r in to_delete:
            print(f"    - DROP id={r['id']} value={r['value']!r} "
                  f"updated_at={r.get('updated_at')}")

        if execute:
            for r in to_delete:
                supabase.table("memory").delete().eq("id", r["id"]).execute()
            print(f"  -> Dropped {len(to_delete)} duplicate row(s) for {key!r}.")
        else:
            print(f"  [dry-run] Would drop {len(to_delete)} duplicate row(s) "
                  f"for {key!r}.")

    if not dupes_found:
        print("  No duplicate memory keys found.")


# ── 4. Orphan duplicate-day sessions ─────────────────────────────────────────

def cleanup_orphan_duplicate_sessions(supabase, execute: bool) -> None:
    """Delete same-day orphan sessions left over from the implicit-start bug.

    Pattern: for some (date, type), the user has one legitimately completed
    session AND one or more sessions still tagged active/in_progress with a
    handful of stray sets — those latter rows are the phantom sessions
    coach.py used to spawn when a `weight x reps` chat message arrived
    after the real workout had already ended.

    Strategy: for every (date, type) where a completed session exists,
    remove the open sibling sessions (and their workout_sets via the
    ON DELETE CASCADE).
    """
    print("\n[4/4] Finding orphan open sessions next to a completed same-day session...")

    result = (
        supabase.table("workout_sessions")
        .select("id, date, type, status, start_time")
        .execute()
    )
    rows = result.data or []

    by_key: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for r in rows:
        date = r.get("date")
        type_ = r.get("type")
        if not date or not type_:
            continue
        by_key[(date, type_)].append(r)

    orphans: list[dict] = []
    for (date, type_), entries in sorted(by_key.items()):
        has_completed = any(
            (e.get("status") or "").lower() in {"complete", "completed"}
            for e in entries
        )
        if not has_completed:
            continue
        for e in entries:
            status = (e.get("status") or "").lower()
            if status in {s.lower() for s in OPEN_STATUSES}:
                orphans.append(e)

    if not orphans:
        print("  No same-day orphan sessions found.")
        return

    for o in orphans:
        sets_result = (
            supabase.table("workout_sets")
            .select("exercise, set_number, actual_weight_kg, actual_reps, is_warmup")
            .eq("workout_session_id", o["id"])
            .execute()
        )
        sets = sets_result.data or []
        print(f"  Orphan {o['id']} ({o['type']} on {o['date']}, status={o['status']}) "
              f"— {len(sets)} set(s) to remove:")
        for s in sets[:5]:
            warm = " WARM-UP" if s.get("is_warmup") else ""
            print(f"    - {s.get('exercise')!r} set{s.get('set_number')} "
                  f"{s.get('actual_weight_kg')}kg x {s.get('actual_reps')}{warm}")
        if len(sets) > 5:
            print(f"    ... and {len(sets) - 5} more")

    if not execute:
        print(f"  [dry-run] Would delete {len(orphans)} orphan session(s) "
              f"(workout_sets cascade).")
        return

    for o in orphans:
        # Belt-and-braces: explicitly nuke the child sets first, in case the
        # ON DELETE CASCADE was never applied to this Supabase project.
        supabase.table("workout_sets").delete().eq(
            "workout_session_id", o["id"]
        ).execute()
        supabase.table("workout_sessions").delete().eq("id", o["id"]).execute()
        print(f"  -> Deleted orphan session {o['id']}.")


# ── 5. Duplicate set rows ────────────────────────────────────────────────────

def cleanup_duplicate_sets(supabase, execute: bool) -> None:
    """Collapse `workout_sets` rows that share the dedup key.

    The iOS resume flow used to reset `exerciseSetIndex` to 0, causing the
    next logged set after a resume to re-use a `set_number` that was already
    present in the DB. Backend `log_set` dedupes, but the iOS path inserts
    directly — so the duplicates slipped in via that path.

    Key = (workout_session_id, exercise, set_number, is_warmup). When a
    group has more than one row, keep the earliest-logged copy and delete
    the rest.
    """
    print("\n[5/5] Finding duplicate workout_sets rows...")

    result = (
        supabase.table("workout_sets")
        .select("id, workout_session_id, exercise, set_number, is_warmup, "
                "actual_weight_kg, actual_reps, logged_at")
        .execute()
    )
    rows = result.data or []

    groups: dict[tuple, list[dict]] = defaultdict(list)
    for r in rows:
        key = (
            r.get("workout_session_id"),
            (r.get("exercise") or "").strip(),
            r.get("set_number"),
            bool(r.get("is_warmup")),
        )
        groups[key].append(r)

    to_delete: list[dict] = []
    for key, entries in groups.items():
        if len(entries) <= 1:
            continue
        entries_sorted = sorted(entries, key=lambda r: (r.get("logged_at") or ""))
        keeper = entries_sorted[0]
        for dup in entries_sorted[1:]:
            to_delete.append(dup)
        print(f"  Dup ({key[1]} set{key[2]}{' WARMUP' if key[3] else ''} in "
              f"session {key[0]}): keeping id={keeper['id']}, dropping "
              f"{len(entries_sorted) - 1} sibling(s)")

    if not to_delete:
        print("  No duplicate set rows found.")
        return

    if not execute:
        print(f"  [dry-run] Would delete {len(to_delete)} duplicate set row(s).")
        return

    for r in to_delete:
        supabase.table("workout_sets").delete().eq("id", r["id"]).execute()
    print(f"  -> Deleted {len(to_delete)} duplicate set row(s).")

    # Recompute tonnage for affected sessions
    affected_sessions = {r.get("workout_session_id") for r in to_delete if r.get("workout_session_id")}
    for session_id in affected_sessions:
        sets_result = (
            supabase.table("workout_sets")
            .select("actual_weight_kg, actual_reps, is_warmup")
            .eq("workout_session_id", session_id)
            .execute()
        )
        new_tonnage = sum(
            (s.get("actual_weight_kg") or 0) * (s.get("actual_reps") or 0)
            for s in (sets_result.data or [])
            if not s.get("is_warmup")
        )
        supabase.table("workout_sessions").update({
            "tonnage_kg": round(new_tonnage, 1),
        }).eq("id", session_id).execute()
        print(f"  -> Recomputed tonnage for session {session_id}: {new_tonnage:.1f}kg")


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Actually apply changes. Without this flag, runs as a dry run.",
    )
    parser.add_argument(
        "--only",
        choices=["sessions", "sets", "memory", "orphans", "dupsets"],
        help="Only run one of the cleanup steps.",
    )
    parser.add_argument(
        "--relabel-to",
        default="",
        help="For the mis-labeled sets step: rename to this exercise name "
             "instead of deleting.",
    )
    args = parser.parse_args()

    supabase = get_supabase()
    if not supabase:
        print("ERROR: no Supabase connection (check SUPABASE_URL / SUPABASE_KEY).")
        return 1

    mode = "EXECUTE" if args.execute else "DRY RUN"
    print(f"Running cleanup in {mode} mode.")

    steps = {"sessions", "sets", "memory", "orphans", "dupsets"}
    if args.only:
        steps = {args.only}

    if "sessions" in steps:
        cleanup_stale_sessions(supabase, args.execute)
    if "sets" in steps:
        cleanup_bad_exercise_sets(supabase, args.execute, args.relabel_to)
    if "memory" in steps:
        cleanup_duplicate_memory_keys(supabase, args.execute)
    if "orphans" in steps:
        cleanup_orphan_duplicate_sessions(supabase, args.execute)
    if "dupsets" in steps:
        cleanup_duplicate_sets(supabase, args.execute)

    print("\nDone.")
    if not args.execute:
        print("Re-run with --execute to apply changes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
