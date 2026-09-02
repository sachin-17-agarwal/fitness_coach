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
from dataclasses import dataclass
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


@dataclass
class ExerciseOutcome:
    """One exercise on one session: what the programme proposed vs what was done."""
    exercise: str
    verdict: str            # "match" | "diverge" | "missing"
    proposed: int
    logged: int | None
    template: int
    top: str                # the proposed top set, rendered


@dataclass
class SessionOutcome:
    date: str
    prior_date: str
    week: int
    week_source: str        # "recorded" | "reconstructed" | "default"
    outcomes: list
    deferred: list


@dataclass
class Replay:
    """The result of the comparison, before anything decides how to print it.

    Analysis and rendering are separate because the same replay goes to two
    surfaces that want opposite shapes: a browser hitting /admin/replay can take
    a wide chronological table, and a chat bubble on a phone cannot — it needs
    the verdict first and roughly 38 columns. Computing twice is how the two
    drift apart and start disagreeing, so it is computed once.
    """
    sessions: list
    totals: dict
    notes: list
    span: tuple | None


def analyse(sessions: list[dict], default_week: int = 1,
            notes: list[str] | None = None) -> Replay:
    """Compare each logged session against what the programme would have said.

    Pure — takes sessions, returns structure. Each session is judged knowing
    only the session before it, which is the whole point: the programme gets no
    access to what actually happened on the day it is prescribing.
    """
    template = {name: count for name, count, _ in PULL_DAY}
    totals = {"match": 0, "diverge": 0, "deferred": 0, "missing": 0}
    out: list[SessionOutcome] = []

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

        outcomes: list[ExerciseOutcome] = []
        deferred: list[str] = []
        for proposal in proposals:
            name = proposal.exercise
            proposed = proposal.working_set_count
            done = actual.get(name)
            if done is None:
                verdict = "missing"
            elif done == proposed == template[name]:
                verdict = "match"
            else:
                verdict = "diverge"
            totals[verdict] += 1
            outcomes.append(ExerciseOutcome(
                exercise=name, verdict=verdict, proposed=proposed, logged=done,
                template=template[name], top=proposal.working[0].render(),
            ))
            for note in proposal.deferred:
                totals["deferred"] += 1
                deferred.append(note)

        out.append(SessionOutcome(
            date=session["date"], prior_date=prior_session["date"], week=week,
            week_source=source, outcomes=outcomes, deferred=deferred,
        ))

    span = (out[0].date, out[-1].date) if out else None
    return Replay(sessions=out, totals=totals, notes=list(notes or []), span=span)


def build_report(sessions: list[dict], default_week: int = 1,
                 notes: list[str] | None = None) -> str:
    """Render the replay wide, for a browser or a terminal."""
    lines: list[str] = []
    for note in notes or []:
        lines.append(f"NOTE: {note}")
    if notes:
        lines.append("")

    if len(sessions) < 2:
        lines.append(f"Need at least two Pull sessions to replay; found "
                     f"{len(sessions)}.")
        return "\n".join(lines)

    replay = analyse(sessions, default_week=default_week)
    totals = replay.totals

    lines.append(f"Replaying {len(replay.sessions)} Pull sessions "
                 f"({replay.span[0]} → {replay.span[1]})")
    lines.append("")

    for s in replay.sessions:
        lines.append("=" * 74)
        lines.append(f"{s.date}  (prior: {s.prior_date}, "
                     f"week {s.week} — {s.week_source})")
        for o in s.outcomes:
            if o.verdict == "missing":
                lines.append(f"  {o.exercise:22} not logged   "
                             f"proposed {o.proposed} sets")
            elif o.verdict == "match":
                lines.append(f"  {o.exercise:22} match        "
                             f"{o.proposed} sets · {o.top}")
            else:
                lines.append(f"  {o.exercise:22} DIVERGE      "
                             f"proposed {o.proposed}, logged {o.logged} "
                             f"(template {o.template}) · {o.top}")
        for note in s.deferred:
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


# A phone chat bubble is roughly this many characters wide before it wraps.
# The wide report runs to 184 columns, which on a phone becomes five ragged
# wrapped lines per row with the column alignment destroyed.
CHAT_WIDTH = 38


def _wrap(text: str, indent: str = "", width: int = CHAT_WIDTH) -> list[str]:
    """Greedy wrap. Long single words are left long rather than broken, since
    the only long words here are exercise names and loads."""
    words, lines, current = text.split(), [], indent
    for word in words:
        candidate = f"{current} {word}" if current.strip() else f"{indent}{word}"
        if len(candidate) > width and current.strip():
            lines.append(current)
            current = f"{indent}{word}"
        else:
            current = candidate
    if current.strip():
        lines.append(current)
    return lines


def _short_date(iso: str) -> str:
    """2026-08-28 -> 28 Aug. Saves ~6 columns a line and reads faster."""
    months = ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    try:
        _, month, day = iso.split("-")
        return f"{int(day)} {months[int(month) - 1]}"
    except (ValueError, IndexError):
        return iso


def render_chat(replay: Replay) -> str:
    """Render the replay for a chat bubble on a phone.

    Three differences from the wide report, all of them because of who reads
    this one. The verdict comes FIRST — a phone reader should not have to scroll
    a table to find out whether anything disagreed. Agreements are counted, not
    listed, because a list of things that went fine is what buries the three
    that did not. And the deferred notes are grouped by what they say instead of
    repeated once per exercise, which on a real history is the same sentence
    five times in a row.
    """
    L: list[str] = []
    for note in replay.notes:
        L.extend(_wrap(f"NOTE: {note}"))
    if replay.notes:
        L.append("")

    if not replay.sessions:
        L.extend(_wrap("Not enough Pull sessions logged yet to replay — it "
                       "needs at least two, so it can judge one against the "
                       "one before it."))
        return "\n".join(L)

    t = replay.totals
    n = len(replay.sessions)
    L.append(f"REPLAY · {n} Pull session{'' if n == 1 else 's'}")
    start, end = _short_date(replay.span[0]), _short_date(replay.span[1])
    L.append(start if start == end else f"{start} → {end}")
    L.append("")
    L.extend(_wrap("The programme written as code, run against what you "
                   "actually logged. Each session is judged knowing only the "
                   "session before it."))
    L.append("")

    L.append("── VERDICT ──")
    L.append(f"agreed      {t['match']:>4}")
    L.append(f"disagreed   {t['diverge']:>4}")
    L.append(f"not logged  {t['missing']:>4}")
    L.append("")

    diverged = [(s, o) for s in replay.sessions
                for o in s.outcomes if o.verdict == "diverge"]
    if diverged:
        L.append("── WHERE IT DISAGREED ──")
        last_date = None
        for s, o in diverged:
            if s.date != last_date:
                L.append(f"{_short_date(s.date)} · week {s.week} "
                         f"({s.week_source})")
                last_date = s.date
            L.append(f"  {o.exercise}")
            L.append(f"    code {o.proposed} sets · you did {o.logged}")
            if o.proposed != o.template:
                L.append(f"    template says {o.template}")
            L.extend(_wrap(f"code's top set {o.top}", indent="    "))
        L.append("")
    else:
        L.extend(_wrap("Nothing disagreed. Every logged exercise ran the set "
                       "count the programme would have chosen."))
        L.append("")

    # Group by what the note SAYS, not which exercise it is about — the same
    # sentence repeated seven times is what makes the raw report unreadable.
    grouped: dict[str, list[str]] = {}
    for s in replay.sessions:
        for note in s.deferred:
            exercise, _, body = note.partition(": ")
            if not body:
                exercise, body = "", note
            grouped.setdefault(body, [])
            if exercise and exercise not in grouped[body]:
                grouped[body].append(exercise)

    if grouped:
        L.append("── THE CODE COULDN'T DECIDE ──")
        L.extend(_wrap("These are the places the programme genuinely does not "
                       "determine an answer, so the coach has been deciding "
                       "them with nothing to check against."))
        L.append("")
        for body, exercises in grouped.items():
            L.extend(_wrap(body))
            if exercises:
                L.extend(_wrap(", ".join(exercises), indent="  "))
            L.append("")

    L.append("── HOW TO READ THIS ──")
    L.extend(_wrap("A disagreement is a question, not a verdict. It means the "
                   "programme on paper and the programme as performed differ, "
                   "and one of the two is wrong."))
    return "\n".join(L)


def run_pull_replay(days: int = 90, default_week: int = 1,
                    surface: str = "wide") -> str:
    """Fetch and render in one call. Read-only; raises only on a failed fetch.

    `surface="chat"` renders for a phone; anything else renders wide for a
    browser. Both go through the same analyse() so the two can never disagree
    about what happened — only about how to show it.
    """
    days = max(1, min(int(days), MAX_DAYS))
    sessions, notes = fetch_pull_sessions(days)
    if surface == "chat":
        if len(sessions) < 2:
            return render_chat(Replay(sessions=[], totals={}, notes=notes,
                                      span=None))
        return render_chat(analyse(sessions, default_week=default_week,
                                   notes=notes))
    return build_report(sessions, default_week=default_week, notes=notes)
