"""Replay the Pull-day programme against real logged history.

Split out of tools/replay_pull.py so the web process can import it without
pulling in a CLI script. The rule is the same one prescribe.py follows: this
module READS and returns text. It never writes, and every query here is a
select.

The falsifiable version of "the programme should be code": for each logged Pull
session, what would prescribe_pull() have proposed knowing only what came
before, and how does that compare to what was actually performed?
"""

import logging
from collections import defaultdict
from datetime import timedelta

from data import get_supabase, now_local
from prescribe import PULL_DAY, PriorSet, infer_session_weeks, prescribe_pull

log = logging.getLogger(__name__)

# A replay runs inside a web request, so the window is bounded. A year of
# sessions is far more than the experiment needs and the query is unindexed on
# type.
MAX_DAYS = 365


def _is_cardio_or_yoga(row: dict) -> bool:
    return (row.get("notes") or "").lower().startswith(("cardio", "yoga"))


def _load_mesocycle_state(supabase) -> tuple[int, int] | None:
    """The (week, day) of the NEXT session, from the memory table."""
    try:
        rows = (
            supabase.table("memory")
            .select("key, value")
            .in_("key", ["mesocycle_week", "mesocycle_day"])
            .execute()
        ).data or []
        values = {r["key"]: r["value"] for r in rows}
        return int(values["mesocycle_week"]), int(values["mesocycle_day"])
    except Exception:
        log.warning("Could not read mesocycle state; week will fall back")
        return None


def fetch_pull_sessions(days: int) -> tuple[list[dict], list[str]]:
    """Pull sessions oldest-first with their working sets, plus any notes.

    Fetches EVERY session type, not only Pull: the week is reconstructed by
    counting rotation boundaries, and filtering to one day would drop the day-4
    completions that count depends on. Pull days are selected at the end.
    """
    notes: list[str] = []
    supabase = get_supabase()
    if not supabase:
        raise RuntimeError("No Supabase client configured.")

    since = (now_local().date() - timedelta(days=days)).isoformat()

    def _query(columns: str):
        return (
            supabase.table("workout_sessions")
            .select(columns)
            .gte("date", since)
            .order("date")
            .order("id")
            .execute()
        ).data or []

    try:
        sessions = _query("id, date, type, mesocycle_week, mesocycle_day")
    except Exception:
        notes.append(
            "workout_sessions has no mesocycle columns — the week is "
            "reconstructed from the rotation instead. Running "
            "migrations/001_workout_session_mesocycle.sql makes it exact."
        )
        sessions = _query("id, date, type")

    if not sessions:
        return [], notes

    rows = (
        supabase.table("workout_sets")
        .select("workout_session_id, exercise, is_warmup, notes, "
                "actual_weight_kg, actual_reps, actual_rpe")
        .in_("workout_session_id", [s["id"] for s in sessions])
        .order("logged_at")
        .order("id")
        .execute()
    ).data or []

    by_session = defaultdict(list)
    for row in rows:
        if row.get("is_warmup") or _is_cardio_or_yoga(row):
            continue
        by_session[row["workout_session_id"]].append(row)

    state = _load_mesocycle_state(supabase)
    if state:
        inferred = infer_session_weeks([s.get("type", "") for s in sessions], *state)
        for session, week in zip(sessions, inferred):
            if session.get("mesocycle_week") is None and week is not None:
                session["mesocycle_week"] = week
                session["week_inferred"] = True
    else:
        notes.append("Mesocycle state unreadable — the week falls back to the "
                     "requested default.")

    for session in sessions:
        session["sets"] = by_session.get(session["id"], [])
    return [s for s in sessions if s.get("type") == "Pull"], notes


def top_sets(session: dict) -> dict[str, PriorSet]:
    """The heaviest working set per exercise — what progression tracks."""
    best: dict[str, dict] = {}
    for row in session.get("sets") or []:
        name = (row.get("exercise") or "").strip()
        if not name:
            continue
        weight = row.get("actual_weight_kg") or 0
        if name not in best or weight > (best[name].get("actual_weight_kg") or 0):
            best[name] = row
    return {
        name: PriorSet(
            load=row.get("actual_weight_kg"),
            reps=row.get("actual_reps"),
            rpe=row.get("actual_rpe"),
            date=session.get("date", ""),
            week=session.get("mesocycle_week"),
        )
        for name, row in best.items()
    }


def performed_counts(session: dict) -> dict[str, int]:
    counts: dict[str, int] = defaultdict(int)
    for row in session.get("sets") or []:
        name = (row.get("exercise") or "").strip()
        if name:
            counts[name] += 1
    return dict(counts)


def build_report(sessions: list[dict], default_week: int = 1,
                 notes: list[str] | None = None) -> str:
    """Render the replay. Pure — takes sessions, returns text."""
    lines: list[str] = []
    for note in notes or []:
        lines.append(f"NOTE: {note}")
    if notes:
        lines.append("")

    if len(sessions) < 2:
        lines.append(f"Need at least two Pull sessions to replay; found "
                     f"{len(sessions)}.")
        return "\n".join(lines)

    template = {name: count for name, count, _ in PULL_DAY}
    totals = {"match": 0, "diverge": 0, "deferred": 0, "missing": 0}

    lines.append(f"Replaying {len(sessions) - 1} Pull sessions "
                 f"({sessions[1]['date']} → {sessions[-1]['date']})")
    lines.append("")

    for prior_session, session in zip(sessions, sessions[1:]):
        history = top_sets(prior_session)
        week = session.get("mesocycle_week") or default_week
        if session.get("mesocycle_week") and not session.get("week_inferred"):
            source = "recorded"
        elif session.get("week_inferred"):
            source = "reconstructed"
        else:
            source = "default"

        proposals = prescribe_pull(week, history)
        actual = performed_counts(session)

        lines.append("=" * 74)
        lines.append(f"{session['date']}  (prior: {prior_session['date']}, "
                     f"week {week} — {source})")

        for proposal in proposals:
            name = proposal.exercise
            proposed = proposal.working_set_count
            done = actual.get(name)
            top = proposal.working[0]
            if done is None:
                totals["missing"] += 1
                lines.append(f"  {name:22} not logged   proposed {proposed} sets")
            elif done == proposed == template[name]:
                totals["match"] += 1
                lines.append(f"  {name:22} match        {proposed} sets · {top.render()}")
            else:
                totals["diverge"] += 1
                lines.append(f"  {name:22} DIVERGE      proposed {proposed}, "
                             f"logged {done} (template {template[name]}) · {top.render()}")

        for proposal in proposals:
            for note in proposal.deferred:
                totals["deferred"] += 1
                lines.append(f"  ! {note}")

    lines.append("")
    lines.append("=" * 74)
    lines.append(f"match {totals['match']} · diverge {totals['diverge']} · "
                 f"not logged {totals['missing']} · deferred {totals['deferred']}")
    lines.append("")
    lines.append("A DIVERGE line is a question, not a verdict: the programme on "
                 "paper and the")
    lines.append("programme as performed disagree. A ! line is something the "
                 "programme does not")
    lines.append("determine at all — the coach has been deciding it with nothing "
                 "to check against.")
    return "\n".join(lines)


def run_pull_replay(days: int = 90, default_week: int = 1) -> str:
    """Fetch and render in one call. Read-only; raises only on a failed fetch."""
    days = max(1, min(int(days), MAX_DAYS))
    sessions, notes = fetch_pull_sessions(days)
    return build_report(sessions, default_week=default_week, notes=notes)
