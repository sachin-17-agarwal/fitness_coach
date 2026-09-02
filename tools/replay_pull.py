"""Replay prescribe_pull() against real logged history.

The falsifiable version of "the programme should be code". For every Pull
session in the window, this asks: given only what was known BEFORE that day,
what would the algorithm have prescribed — and how does that compare to what
was actually performed?

It changes nothing and writes nothing. Run it with the same environment the
backend uses:

    python tools/replay_pull.py            # last 90 days
    python tools/replay_pull.py --days 180

Read the output for three things, in order of importance:

  DEFERRED   — what the programme genuinely does not determine. Every line here
               is a decision the coach has been making invisibly, with nothing
               to check it against. This is the most valuable column.

  DIVERGENCE — where the algorithm and the logged session disagree. A
               divergence is NOT automatically the algorithm being wrong; it
               may be the programme-on-paper and the programme-as-performed
               having drifted apart. Either way it is a question worth
               answering, and it has been unaskable until now.

  MATCH      — where they agree. This is the part that no longer needs a
               language model.
"""

import argparse
import os
import sys
from collections import defaultdict
from datetime import timedelta

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from data import get_supabase, now_local              # noqa: E402
from prescribe import PULL_DAY, PriorSet, prescribe_pull  # noqa: E402


def _is_cardio_or_yoga(row: dict) -> bool:
    return (row.get("notes") or "").lower().startswith(("cardio", "yoga"))


def fetch_pull_sessions(days: int) -> list[dict]:
    """Pull sessions oldest-first, each with its working sets."""
    supabase = get_supabase()
    if not supabase:
        raise SystemExit(
            "No Supabase client. Set SUPABASE_URL and SUPABASE_KEY the way the "
            "backend does, then re-run."
        )
    since = (now_local().date() - timedelta(days=days)).isoformat()
    sessions = (
        supabase.table("workout_sessions")
        .select("id, date, type")
        .eq("type", "Pull")
        .gte("date", since)
        .order("date")
        .order("id")
        .execute()
    ).data or []
    if not sessions:
        return []

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

    for session in sessions:
        session["sets"] = by_session.get(session["id"], [])
    return sessions


def top_sets(session: dict) -> dict[str, PriorSet]:
    """The heaviest working set per exercise — what progression tracks."""
    best: dict[str, dict] = {}
    for row in session["sets"]:
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
            date=session["date"],
        )
        for name, row in best.items()
    }


def performed_counts(session: dict) -> dict[str, int]:
    counts: dict[str, int] = defaultdict(int)
    for row in session["sets"]:
        name = (row.get("exercise") or "").strip()
        if name:
            counts[name] += 1
    return dict(counts)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=90)
    parser.add_argument("--week", type=int, default=None,
                        help="assume this mesocycle week for every session "
                             "(the log does not record it)")
    args = parser.parse_args()

    sessions = fetch_pull_sessions(args.days)
    if len(sessions) < 2:
        raise SystemExit(
            f"Need at least two Pull sessions to replay; found {len(sessions)} "
            f"in {args.days} days."
        )

    template = {name: count for name, count, _ in PULL_DAY}
    totals = {"match": 0, "diverge": 0, "deferred": 0, "missing": 0}

    print(f"Replaying {len(sessions) - 1} Pull sessions "
          f"({sessions[1]['date']} → {sessions[-1]['date']})\n")

    for prior_session, session in zip(sessions, sessions[1:]):
        history = top_sets(prior_session)
        week = args.week or 1
        proposals = prescribe_pull(week, history)
        actual = performed_counts(session)

        print("=" * 78)
        print(f"{session['date']}  (prior: {prior_session['date']}, "
              f"assumed week {week})")

        for proposal in proposals:
            name = proposal.exercise
            proposed = proposal.working_set_count
            done = actual.get(name)
            top = proposal.working[0]

            if done is None:
                totals["missing"] += 1
                print(f"  {name:22} MISSING   proposed {proposed} sets, "
                      f"none logged")
                continue
            if done == proposed == template[name]:
                totals["match"] += 1
                print(f"  {name:22} match     {proposed} sets · {top.render()}")
            else:
                totals["diverge"] += 1
                print(f"  {name:22} DIVERGE   proposed {proposed}, "
                      f"logged {done} (template {template[name]}) · {top.render()}")

        for proposal in proposals:
            for note in proposal.deferred:
                totals["deferred"] += 1
                print(f"  ! {note}")

    print("\n" + "=" * 78)
    print(f"match {totals['match']} · diverge {totals['diverge']} · "
          f"not logged {totals['missing']} · deferred {totals['deferred']}")
    print(
        "\nA DIVERGE line is a question, not a verdict: it means the programme "
        "on paper and\nthe programme as performed disagree. A ! line is "
        "something the programme does not\ndetermine at all — the coach has "
        "been deciding it with nothing to check it against."
    )


if __name__ == "__main__":
    main()
