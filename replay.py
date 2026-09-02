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
from dataclasses import dataclass, field
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

    # Note text carries NO underscores: the iOS bubble parses inline markdown,
    # so "workout_sessions" reaches the athlete as "workoutsessions" — the
    # underscore is read as emphasis and consumed. He does not need the table
    # name anyway; he needs to know whether the week labels below were read or
    # inferred.
    try:
        sessions = _query("id, date, type, mesocycle_week, mesocycle_day")
        migrated = True
    except Exception:
        migrated = False
        notes.append(
            "Your sessions do not record which mesocycle week they belonged "
            "to, so every week below is worked out from the rotation rather "
            "than read from the log. That is reliable while no session was "
            "skipped or swapped, and it is why each one is marked "
            "reconstructed. The database migration I wrote makes it exact — "
            "ask me to walk you through it."
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

    pull = [s for s in sessions if s.get("type") == "Pull"]

    # Once the columns exist the query stops failing, so the note above stops
    # printing — but sessions logged BEFORE that keep a NULL week and are still
    # reconstructed. Without this the labels would read "(reconstructed)" with
    # nothing left on the page explaining why, which is worse than the state it
    # replaced. Says how many, so the proportion visibly shrinks as new
    # sessions are recorded.
    if migrated:
        older = sum(1 for s in pull if s.get("week_inferred"))
        if older:
            notes.append(
                f"{older} of these {len(pull)} sessions were logged before "
                f"the week started being recorded, so their week is worked "
                f"out from the rotation and marked reconstructed. That is "
                f"reliable while no session was skipped or swapped. Sessions "
                f"from now on record it exactly, and this number will shrink."
            )

    return pull, notes


def norm_name(name: str) -> str:
    """Fold an exercise name to a comparison key.

    The template says "Pull-Ups"; the log holds whatever the resolver wrote on
    the day, and the two logging paths do not agree — the iOS app resolves
    through the exercises library, Telegram through find_exercise. Matching the
    raw strings made "Pull Ups" and "pull-ups" into exercises that were never
    performed, which is not a small inaccuracy: it is the difference between
    "you skipped this" and "this is filed under another name".
    """
    return "".join(ch for ch in name.lower() if ch.isalnum())


def top_sets(session: dict) -> dict[str, PriorSet]:
    """The heaviest working set per exercise — what progression tracks.

    Keyed by norm_name so a prior session filed under a spelling variant still
    supplies history, rather than reading as a first-ever session.
    """
    best: dict[str, dict] = {}
    for row in session.get("sets") or []:
        name = norm_name((row.get("exercise") or "").strip())
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
    """Working sets per exercise, keyed by norm_name."""
    counts: dict[str, int] = defaultdict(int)
    for row in session.get("sets") or []:
        name = norm_name((row.get("exercise") or "").strip())
        if name:
            counts[name] += 1
    return dict(counts)


def logged_display_names(session: dict) -> dict[str, str]:
    """norm_name -> the spelling the log actually used, for reporting back."""
    seen: dict[str, str] = {}
    for row in session.get("sets") or []:
        raw = (row.get("exercise") or "").strip()
        if raw:
            seen.setdefault(norm_name(raw), raw)
    return seen


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
    # Exercise names found in the log that no template entry claims. A high
    # "not logged" count means one of two very different things, and only this
    # tells them apart: work that was skipped, or work filed under a name the
    # template does not recognise.
    unmatched: dict = field(default_factory=dict)


def analyse(sessions: list[dict], default_week: int = 1,
            notes: list[str] | None = None) -> Replay:
    """Compare each logged session against what the programme would have said.

    Pure — takes sessions, returns structure. Each session is judged knowing
    only the session before it, which is the whole point: the programme gets no
    access to what actually happened on the day it is prescribing.
    """
    template = {name: count for name, count, _ in PULL_DAY}
    template_keys = {norm_name(name) for name in template}
    unmatched: dict[str, int] = defaultdict(int)
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
        for key, display in logged_display_names(session).items():
            if key not in template_keys:
                unmatched[display] += 1

        outcomes: list[ExerciseOutcome] = []
        deferred: list[str] = []
        for proposal in proposals:
            name = proposal.exercise
            proposed = proposal.working_set_count
            done = actual.get(norm_name(name))
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
    return Replay(sessions=out, totals=totals, notes=list(notes or []),
                  span=span, unmatched=dict(unmatched))


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


def _short_date(iso: str) -> str:
    """2026-08-28 -> 28 Aug. Saves columns and reads faster on a phone."""
    months = ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    try:
        _, month, day = iso.split("-")
        return f"{int(day)} {months[int(month) - 1]}"
    except (ValueError, IndexError):
        return iso


def render_chat(replay: Replay) -> str:
    """Render the replay for the coach chat.

    Written against the renderer that will actually show it. The iOS bubble goes
    through MarkdownText (Vaux/Vaux/Components/MarkdownText.swift), whose block
    parser trims each line and then joins every run of consecutive non-blank
    lines with a single space — so a hand-aligned table arrives as one run-on
    paragraph with no number attributable to any exercise. It starts a new block
    only on a BLANK line, and gives a line of its own only to "- " bullets.

    So: every row that has to stand alone is a bullet, every logical group is
    separated by a blank line, and nothing is hard-wrapped — wrapping is the
    renderer's job, and pre-wrapping only manufactures more fragments for it to
    run together. That shape survives Telegram too, which is plain text and
    wraps long lines itself.

    Content-wise this leads with the verdict rather than ending on it, counts
    agreements instead of listing them, and groups identical deferred notes —
    on a real history the same sentence otherwise repeats once per exercise.
    """
    L: list[str] = []
    for note in replay.notes:
        L.append(f"NOTE: {note}")
        L.append("")

    if not replay.sessions:
        L.append("Not enough Pull sessions logged yet to replay — it needs at "
                 "least two, so it can judge one against the one before it.")
        return "\n".join(L)

    t = replay.totals
    n = len(replay.sessions)
    start, end = _short_date(replay.span[0]), _short_date(replay.span[1])
    span = start if start == end else f"{start} → {end}"
    L.append(f"REPLAY · {n} Pull session{'' if n == 1 else 's'} · {span}")
    L.append("")
    L.append("The programme written as code, run against what you actually "
             "logged. Each session is judged knowing only the session before it.")
    L.append("")

    L.append("VERDICT")
    L.append("")
    L.append(f"- agreed {t['match']}")
    L.append(f"- disagreed {t['diverge']}")
    L.append(f"- not logged {t['missing']}")
    L.append("")

    diverged = [(s, o) for s in replay.sessions
                for o in s.outcomes if o.verdict == "diverge"]
    missing: dict[str, list[str]] = {}
    for s in replay.sessions:
        for o in s.outcomes:
            if o.verdict == "missing":
                missing.setdefault(o.exercise, []).append(s.date)

    if diverged:
        L.append("WHERE IT DISAGREED")
        L.append("")
        last_date = None
        for s, o in diverged:
            if s.date != last_date:
                if last_date is not None:
                    L.append("")
                L.append(f"{_short_date(s.date)} · week {s.week} "
                         f"({s.week_source})")
                L.append("")
                last_date = s.date
            template = ("" if o.proposed == o.template
                        else f", template {o.template}")
            L.append(f"- {o.exercise} — code says {o.proposed} sets, you did "
                     f"{o.logged}{template} · code's top set {o.top}")
        L.append("")
    elif not missing:
        L.append("Nothing disagreed. Every exercise ran the set count the "
                 "programme would have chosen.")
        L.append("")
    else:
        L.append("Nothing that you logged disagreed — every exercise you did "
                 "ran the set count the programme would have chosen.")
        L.append("")

    # The count alone reads as an accusation with no subject. An exercise with
    # history that simply was not logged is counted here and named nowhere else
    # in the report — the deferred notes only pick up exercises with NO history.
    if missing:
        L.append("WHAT THE PROGRAMME EXPECTED AND DIDN'T FIND")
        L.append("")
        L.append("Prescribed on the day but not logged. A swap, a machine in "
                 "use, or a set that went unrecorded all look the same here — "
                 "the log cannot tell them apart.")
        L.append("")
        for exercise, dates in missing.items():
            when = (f"{len(dates)} sessions" if len(dates) > 1
                    else _short_date(dates[0]))
            L.append(f"- {exercise} — {when}")
        L.append("")

        if replay.unmatched:
            L.append("These names ARE in your log for those days, and the "
                     "programme does not recognise any of them. If one is the "
                     "same movement under another name, that is a naming "
                     "mismatch and not a missed exercise — the count above is "
                     "wrong by however many it accounts for.")
            L.append("")
            for name, count in sorted(replay.unmatched.items(),
                                      key=lambda kv: -kv[1]):
                sessions = f"{count} sessions" if count > 1 else "1 session"
                L.append(f"- {name} — {sessions}")
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
        L.append("THE CODE COULDN'T DECIDE")
        L.append("")
        L.append("These are the places the programme genuinely does not "
                 "determine an answer, so the coach has been deciding them "
                 "with nothing to check against.")
        L.append("")
        for body, exercises in grouped.items():
            who = f"{', '.join(exercises)} — " if exercises else ""
            L.append(f"- {who}{body}")
        L.append("")

    L.append("HOW TO READ THIS")
    L.append("")
    L.append("A disagreement is a question, not a verdict. It means the "
             "programme on paper and the programme as performed differ, and "
             "one of the two is wrong.")
    return "\n".join(L)


def render_summary(replay: Replay, days: int) -> str:
    """A few dozen tokens standing in for the full report in the transcript.

    The report itself is deliberately not persisted — today's conversation is
    replayed into the model's context on every later request, so a few hundred
    lines of table would crowd out the actual session and be re-billed all day.
    But persisting NOTHING costs two things the token argument does not cover:
    the iOS app reloads its transcript from the conversations table whenever the
    chat reappears (CoachChatView .task -> loadConversation), so the report
    vanishes on a tab switch; and a follow-up question reaches the model with no
    record that a replay ever ran, which is the exact confabulation everything
    else here works to prevent.

    So the totals are persisted, and the summary says outright that it is only
    the totals — the model must not answer from detail it does not have.
    """
    if not replay.sessions:
        return (f"Ran the replay over {days} days: not enough Pull sessions "
                f"logged yet to compare (it needs at least two).")
    t = replay.totals
    diverged = sorted({o.exercise for s in replay.sessions
                       for o in s.outcomes if o.verdict == "diverge"})
    detail = (f" Disagreements were on: {', '.join(diverged)}."
              if diverged else " Nothing disagreed.")
    # Written to the ATHLETE, in the second person. It is stored as an ordinary
    # assistant row and the app renders every assistant row as a coach bubble,
    # so anything addressed to the model would be read by him instead — the
    # coach appearing to discuss him in the third person and issue itself
    # orders. What the model must know about this row (that it holds totals
    # only) belongs in the system prompt, not in the transcript.
    n = len(replay.sessions)
    return (f"Ran the replay over {days} days across "
            f"{n} Pull session{'' if n == 1 else 's'}: {t['match']} agreed, "
            f"{t['diverge']} disagreed, {t['missing']} not logged.{detail} "
            f"Only these totals are kept here — paste the part of the report "
            f"you want to dig into.")


def run_chat_replay(days: int = 90, default_week: int = 1) -> tuple[str, str]:
    """The chat report and a short summary of it, computed in one pass."""
    days = max(1, min(int(days), MAX_DAYS))
    sessions, notes = fetch_pull_sessions(days)
    if len(sessions) < 2:
        replay = Replay(sessions=[], totals={}, notes=notes, span=None)
    else:
        replay = analyse(sessions, default_week=default_week, notes=notes)
    return render_chat(replay), render_summary(replay, days)


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
