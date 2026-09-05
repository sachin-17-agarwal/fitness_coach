"""Did the coach follow its own protocol? Counted, over real history.

The question this answers is not "are the programme's numbers better than the
coach's" — that needs a judgement, and mine is the same judgement already
inside the programme, so asking me is circular. It answers a narrower question
that needs no judgement at all: how often did a prescription the athlete
actually trained on BREAK a rule written in the system prompt.

Every check here is decidable from the prescription text plus the mesocycle
week. None of them needs the loads reconstructed as they stood on that date,
which is the part that cannot be recovered reliably — and none of them is an
opinion:

  - the top-set RPE is the week's target        (:179-185, WAVE)
  - the top-set reps sit inside the range       (:63, TOP_SET_RANGE; week 4 exempt)
  - the set count matches the template          (:117, TODAY'S SET COUNTS)
  - two back-offs share a load and descend      (:65)
  - the back-off sits 15-25% under the top set  (:64)

Those are precisely the failures that have surfaced: a week-1 baseline
prescribed at deload RPE, a top set below its range, one back-off against a
template of three. Counting them across months of stored replies turns "the
coach gets it wrong sometimes" into a number, and gives the rebuild something
to be measured against rather than asserted over.

Runs server-side, like replay: the database is reachable there and is not
reachable from a development machine.
"""

import logging
import re
from datetime import timedelta

from coach_parsing import (get_session_type_for_day, parse_all_prescriptions,
                           parse_session_template, _normalise_exercise,
                           _set_shape)
from data import get_supabase, is_session_finished, now_local
from prescribe import (TOP_SET_RANGE, WAVE, classify, infer_session_weeks,
                       is_bodyweight, recovery_adjustment)
from volume import resolve_contributions

# PostgREST answers at most this many rows per request, silently. The first
# real run of this audit read exactly 1000 replies — the OLDEST 1000 in the
# window, because the query was ordered ascending — and reported that none
# could be dated. Every fetch here pages.
_PAGE = 1000


def _all_rows(build) -> list[dict]:
    """Every row of a query, paged past the server's per-request cap.

    `build` returns a fresh query with its select, filters and ordering
    applied; the range is added here so no caller can forget it.
    """
    rows: list[dict] = []
    start = 0
    while True:
        page = (build().range(start, start + _PAGE - 1).execute()).data or []
        rows.extend(page)
        if len(page) < _PAGE:
            return rows
        start += _PAGE


def _as_int(value) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None

log = logging.getLogger(__name__)

# A prescription block carries no date of its own; it is dated by the reply it
# arrived in. Only assistant turns can contain one.
_ASSISTANT = "assistant"


def fetch_assistant_replies(days: int) -> list[dict]:
    """Stored coach replies, oldest first, with the date they were sent."""
    supabase = get_supabase()
    if not supabase:
        raise RuntimeError("No Supabase client configured.")
    since = (now_local().date() - timedelta(days=days)).isoformat()
    rows = _all_rows(lambda: (
        supabase.table("conversations")
        .select("date, role, content")
        .gte("date", since)
        .eq("role", _ASSISTANT)
        .order("date")
        .order("id")
    ))
    return [r for r in rows if (r.get("content") or "").strip()]


def fetch_session_weeks(days: int) -> tuple[dict, dict]:
    """date -> (session_type, mesocycle_week), and how each week was known.

    Read from the stamped row where there is one. Rows written before stamping
    began carry nothing, and on the first real run that was every row in the
    window — so the week is otherwise RECONSTRUCTED from the rotation, exactly
    as the replay does: the day is the type, the week turns at day 4, and the
    walk is anchored to the mesocycle state in memory. Duplicate rows for one
    date and type are collapsed first, because a duplicate spends two rotation
    slots on one training day and shifts every earlier week by one. Unfinished
    sessions are not slots at all.

    A stamp always wins over a reconstruction. The counts say how many of each
    the report rests on, so a number built on reconstruction is labelled as
    such rather than passed off as read.
    """
    supabase = get_supabase()
    since = (now_local().date() - timedelta(days=days)).isoformat()
    rows = _all_rows(lambda: (
        supabase.table("workout_sessions")
        .select("id, date, type, status, mesocycle_week")
        .gte("date", since)
        .order("date")
        .order("id")
    ))
    sessions, seen = [], set()
    for row in rows:
        if not is_session_finished(row.get("status")):
            continue
        key = (row.get("date"), (row.get("type") or "").strip())
        if not key[0] or key in seen:
            continue
        seen.add(key)
        sessions.append(row)

    stamped = [_as_int(r.get("mesocycle_week")) for r in sessions]
    inferred: list = [None] * len(sessions)
    if any(week is None for week in stamped):
        from replay import _load_mesocycle_state  # local: keeps import order flat
        state = _load_mesocycle_state(supabase)
        if state:
            inferred = infer_session_weeks([r.get("type") for r in sessions], *state)

    weeks, counts = {}, {"stamped": 0, "reconstructed": 0, "by_date": {}}
    for row, stamp, guess in zip(sessions, stamped, inferred):
        week = stamp or guess
        if not week or week not in WAVE:
            continue
        date = row["date"]
        if date in weeks:
            continue
        weeks[date] = ((row.get("type") or "").strip(), int(week))
        source = "stamped" if stamp else "reconstructed"
        counts[source] += 1
        counts["by_date"][date] = source
    return weeks, counts


def fetch_recovery_by_date(days: int) -> dict:
    """date -> the readings that were true that morning.

    Without this the audit is worse than useless. :313 is "Recovery data is
    injected with every message. Apply these rules", and :315 makes the RPE
    reduction MANDATORY when HRV is more than 10% down. A prescription that
    obeyed it sits a point under the week — which is exactly the shape of the
    failure this audit exists to count. Blind to the readings, it reports the
    protocol working as three violations per exercise, and would have told us
    the coach was worst on precisely the days it was most correct.

    This is the same mistake the enforcement guard made, reproduced in the tool
    built to measure it: after the fact, a mandated reduction and a soft
    prescription are the same three numbers.
    """
    supabase = get_supabase()
    if not supabase:
        return {}
    since = (now_local().date() - timedelta(days=days)).isoformat()
    rows = _all_rows(lambda: (
        # "recovery", not "health_data" — the name I first wrote does not
        # exist. The query would have returned nothing and the audit would have
        # gone quietly back to being recovery-blind: the same critical, with no
        # symptom, in a tool whose whole value is being trusted about the past.
        supabase.table("recovery")
        .select("date, sleep_hours, hrv, resting_hr")
        .gte("date", since)
        .order("date")
    ))
    by_date = {r["date"]: dict(r) for r in rows if r.get("date")}

    # hrv_avg and the RHR baseline are 7-day trailing means, the same window
    # data.py computes for the live context — the seven days up to AND
    # INCLUDING the day, by calendar date rather than by row count, so a gap in
    # the readings does not stretch the window back a fortnight.
    from datetime import date as _date
    dates = sorted(by_date)
    for date in dates:
        try:
            day = _date.fromisoformat(date)
        except ValueError:
            continue
        since = (day - timedelta(days=7)).isoformat()
        window = [by_date[d] for d in dates if since <= d <= date]
        hrvs = [r["hrv"] for r in window if r.get("hrv") is not None]
        rhrs = [r["resting_hr"] for r in window if r.get("resting_hr") is not None]
        by_date[date]["hrv_avg"] = (sum(hrvs) / len(hrvs)) if hrvs else None
        by_date[date]["resting_hr_baseline"] = (sum(rhrs) / len(rhrs)) if rhrs else None
    return by_date


_PHASE_WEEK = {"baseline": 1, "volume": 2, "peak": 3, "deload": 4}
# "Week 4 — Deload", "Week 1 (Baseline)", "Week 3: peak", "Baseline week 1",
# "deload week (4)". The phase name sits right beside the number, with at most
# punctuation between them; "Week 3 you hit 205kg ... peak" is a reference to
# the past and must not read as today.
_SEP = r"[\s—–\-:(/·,*_]{0,4}"
_STATED_WEEK_RE = re.compile(
    rf"\bweek{_SEP}([1-4])\b{_SEP}(?:of\s*4{_SEP})?(baseline|volume|peak|deload)\b"
    rf"|\b(baseline|volume|peak|deload)\b(?:\s+(?:week|phase|intensity|progression))?{_SEP}"
    rf"(?:week{_SEP})?\(?([1-4])\b",
    re.IGNORECASE)
_LONE_DELOAD_RE = re.compile(
    r"(?:^|\n)\W*deload\b|\bdeload (?:week|day|session|today)\b", re.IGNORECASE)
_NOT_TODAY_RE = re.compile(r"\b(next|last|previous|after|before|until|no|not|skip)\b", re.IGNORECASE)


def stated_week(text: str) -> int | None:
    """The mesocycle week the coach itself named in the reply, if it did.

    The coach opens a session with the week it was handed — "Week 4 — Deload",
    "Week 1 (Baseline)" — from the same memory state the stamps come from, so
    a stated week is as good as a stamp and better than a reconstruction. Only
    a week number with its phase name right beside it is taken, or a deload
    named as today's; the first reading of this accepted a phase word forty
    characters away and mislabelled openings that mentioned the peak week.
    """
    if not text:
        return None
    for found in _STATED_WEEK_RE.finditer(text):
        number = found.group(1) or found.group(4)
        phase = (found.group(2) or found.group(3) or "").lower()
        before = text[max(0, found.start() - 24):found.start()]
        if _NOT_TODAY_RE.search(before):
            continue                      # "so next Week 1 baseline, drop 5%"
        if number and _PHASE_WEEK.get(phase) == int(number):
            return int(number)
    for match in _LONE_DELOAD_RE.finditer(text):
        before = text[max(0, match.start() - 24):match.start()]
        after = text[match.end():match.end() + 16]
        if not _NOT_TODAY_RE.search(before + " " + after):
            return 4
    return None


def _snippet(text: str, width: int = 90) -> str:
    """The stretch of the reply around its week statement, one line."""
    found = _STATED_WEEK_RE.search(text or "") or _LONE_DELOAD_RE.search(text or "")
    if not found:
        return ""
    lo, hi = max(0, found.start() - 30), min(len(text), found.end() + width)
    return " ".join(text[lo:hi].split())


def _violations(block: dict, week: int, session_type: str, prompt: str,
                recovery: dict | None = None, full_reply: bool = True,
                week_known: bool = True) -> list:
    """Every rule this one prescription breaks. Mechanical, not a judgement.

    A `Revised:` block is the coach departing from the programme on purpose —
    an injury, a machine in use — and the one exit the protocol leaves, so it
    is not a violation of it. `full_reply` says whether the reply laid out the
    session or re-stated one exercise mid-way through it: the set count is
    only checkable on the former, because "Back-off 2 of 2" on its own is a
    partial block by design, not a two-set prescription.

    `week_known` is False when the week is only a reconstruction from the
    rotation. Measured against the coach's own statements, that reconstruction
    was wrong two times in three over ninety days — the rotation itself has
    changed — so on such a day only the checks that need no week run: the
    set count, and the shape of the back-offs. An RPE or a rep count judged
    against a guessed week is not a finding.
    """
    if block.get("revised"):
        return []
    name = block.get("exercise") or ""
    known = bool(resolve_contributions(name))
    kind = classify(name)
    low, high = TOP_SET_RANGE[kind]
    targets = WAVE.get(week)

    # The day's readings shift the targets before anything is compared against
    # them. A recovery session is not audited at all: :316 says switch session,
    # so whatever was prescribed that day was the coach's call to make.
    adjustment = recovery_adjustment(recovery)
    if adjustment.recovery_session:
        return []
    if targets and adjustment.rpe_delta:
        targets = {"top": targets["top"] + adjustment.rpe_delta,
                   "backoff": targets["backoff"] + adjustment.rpe_delta,
                   "name": targets.get("name", "")}
        # :323 makes the RPE cut a REP cut too, so the floor moves with it.
        low = max(1, low + int(round(adjustment.rpe_delta)))
    out = []

    working = block.get("working") or []
    backoff = block.get("backoff") or []
    if not working:
        return out

    top = working[0]
    rpe = top.get("rpe")
    if not week_known:
        targets = None
    if targets and rpe is not None and rpe < targets["top"]:
        out.append(("rpe_under_target",
                    f"top set at RPE{rpe:g} in week {week}, which targets "
                    f"RPE{targets['top']:g}"))
    for b in backoff:
        if targets and b.get("rpe") is not None and b["rpe"] < targets["backoff"]:
            out.append(("backoff_rpe_under_target",
                        f"back-off at RPE{b['rpe']:g} in week {week}, which "
                        f"targets RPE{targets['backoff']:g}"))
            break

    reps = top.get("reps")
    # Only for a movement the catalog can classify: an unknown name falls to
    # the isolation range, and a compound under a spelling the map has not
    # met would be reported as under-repped at 7.
    if known and week_known and week != 4 and reps is not None and reps < low:
        out.append(("reps_below_range",
                    f"top set at {reps} reps against a {low}-{high} range"))

    pairs, _total = parse_session_template(prompt, session_type)
    expected = {_normalise_exercise(n): c for n, c in pairs}
    target = expected.get(_normalise_exercise(name)) if full_reply else None
    if target:
        straight = _set_shape(name, target).startswith(f"{target} straight")
        actual = len(working) if straight else len(working) + len(backoff)
        if actual != target:
            out.append(("set_count",
                        f"{actual} working set(s) against a template of {target}"))

    if len(backoff) > 1:
        if backoff[0].get("weight") != backoff[1].get("weight"):
            out.append(("backoff_loads_differ", "two back-offs at different loads"))
        r0, r1 = backoff[0].get("reps"), backoff[1].get("reps")
        if r0 is not None and r1 is not None and r1 >= r0:
            out.append(("backoff_not_descending",
                        f"second back-off at {r1} reps, not fewer than {r0}"))

    # Not for a bodyweight movement: the number on the line is the added
    # plate, and 20% of the plate is not 20% of the load. "Dips BW + 14kg"
    # backing off to "BW + 4kg" read as a 71% drop.
    if (backoff and top.get("weight") and backoff[0].get("weight")
            and not is_bodyweight(name)):
        drop = (top["weight"] - backoff[0]["weight"]) / top["weight"] * 100
        # :64 is 15-25%, and the prompt also says to round to the nearest
        # step the equipment has. A back-off within one 2.5kg step of the band
        # is the band, on a stack that could not land inside it.
        outside_by = 0.0 if 15 <= drop <= 25 else min(abs(drop - 15), abs(drop - 25))
        if outside_by / 100 * top["weight"] > 2.5:
            out.append(("backoff_drop",
                        f"back-off {drop:.0f}% below the top set, outside 15-25%"))
    return out


def audit(days: int, prompt: str) -> dict:
    """Count protocol violations across every stored prescription."""
    replies = fetch_assistant_replies(days)
    weeks, week_sources = fetch_session_weeks(days)
    week_sources_by_date = week_sources.pop("by_date", {})
    recovery = fetch_recovery_by_date(days)

    checked, findings, dated, undated = 0, [], 0, 0
    seen_blocks: set = set()
    # How the week of each checked prescription was known, and whether the
    # coach's own statement of it agreed with the session row.
    week_from = {"stated": 0, "stamped": 0, "reconstructed": 0}
    agreement = {"compared": 0, "agreed": 0}
    disagreements: list = []

    # The coach names the week once, in the reply that opens the session; the
    # replies that follow through the day do not repeat it. So the statement
    # is read for the DAY, not the reply, and the most-stated week wins.
    stated_by_date: dict = {}
    snippet_by_date: dict = {}
    for reply in replies:
        stated = stated_week(reply.get("content") or "")
        if stated is not None and reply.get("date"):
            tally = stated_by_date.setdefault(reply["date"], {})
            tally[stated] = tally.get(stated, 0) + 1
            snippet_by_date.setdefault(reply["date"], _snippet(reply.get("content") or ""))
    stated_for = {d: max(t, key=t.get) for d, t in stated_by_date.items()}
    compared_dates: set = set()

    for reply in replies:
        date = reply.get("date")
        known = weeks.get(date)
        if not known:
            undated += 1
            continue
        session_type, week = known
        if not session_type or week not in WAVE:
            undated += 1
            continue
        dated += 1
        stated = stated_for.get(date)
        source = ("stated" if stated is not None
                  else week_sources_by_date.get(date, "reconstructed"))
        if stated is not None:
            if date not in compared_dates:
                compared_dates.add(date)
                agreement["compared"] += 1
                agreement["agreed"] += int(stated == week)
                if stated != week and len(disagreements) < 12:
                    disagreements.append({"date": date, "session": session_type,
                                          "row_week": week, "stated": stated,
                                          "snippet": snippet_by_date.get(date, "")})
            week = stated
        week_known = source != "reconstructed"
        blocks = [b for b in parse_all_prescriptions(reply.get("content") or "")
                  if b.get("working")]
        # The session-opening reply lays the whole day out; anything shorter
        # is a mid-session re-statement of one lift, and its set count means
        # nothing on its own.
        pairs, _total = parse_session_template(prompt, session_type)
        full_reply = len(blocks) >= max(2, len(pairs) // 2) if pairs else False
        for block in blocks:
            key = (date, _normalise_exercise(block.get("exercise") or ""))
            if key in seen_blocks:
                # The same lift is re-stated on every logged set during a
                # session. One prescription trained on, counted once.
                continue
            seen_blocks.add(key)
            checked += 1
            week_from[source] += 1
            for code, detail in _violations(block, week, session_type, prompt,
                                            recovery.get(date), full_reply,
                                            week_known=week_known):
                findings.append({"date": date, "session": session_type,
                                 "week": week, "exercise": block.get("exercise"),
                                 "code": code, "detail": detail})
    counts = {}
    for f in findings:
        counts[f["code"]] = counts.get(f["code"], 0) + 1
    return {"days": days, "replies": len(replies), "dated": dated,
            "undated": undated, "prescriptions": checked,
            "violations": findings, "counts": counts,
            "week_sources": week_sources, "week_from": week_from,
            "agreement": agreement, "disagreements": disagreements}


_LABELS = {
    "rpe_under_target": "Prescribed below the week's RPE target",
    "backoff_rpe_under_target": "Back-off below the week's RPE target",
    "reps_below_range": "Top set below the exercise's rep range",
    "set_count": "Wrong number of working sets",
    "backoff_loads_differ": "Two back-offs at different loads",
    "backoff_not_descending": "Second back-off not fewer reps",
    "backoff_drop": "Back-off drop outside 15-25%",
}


def render_chat(result: dict, detail: bool = False) -> str:
    """The report as the iOS bubble will actually render it.

    Bulleted and blank-line separated on purpose: MarkdownText joins
    consecutive non-blank lines with a single space, so a report laid out for a
    terminal arrives as one paragraph. Only `- ` lines get their own row.
    """
    checked = result["prescriptions"]
    findings = result["violations"]
    lines = [f"**Protocol audit — last {result['days']} days**", ""]

    sources = result.get("week_sources") or {}
    origin = result.get("week_from") or {}
    agreement = result.get("agreement") or {}
    known = origin.get("stated", 0) + origin.get("stamped", 0)
    provenance = (f"Week known for {known} prescriptions ({origin.get('stated', 0)} from "
                  f"the coach's own words that day, {origin.get('stamped', 0)} from the "
                  f"session stamp): every check ran. Week only reconstructed for "
                  f"{origin.get('reconstructed', 0)}: set count and back-off shape "
                  f"checked, RPE and rep range not judged.")
    if agreement.get("compared"):
        provenance += (f" Where the coach stated the week, the rotation walk agreed "
                       f"{agreement['agreed']} of {agreement['compared']} days.")

    if not checked:
        lines += ["- No prescriptions found in that window to check.", "",
                  f"- {result['replies']} coach replies were read; "
                  f"{result['undated']} fell on days with no finished session "
                  f"whose mesocycle week is known.",
                  f"- {provenance}"]
        return "\n".join(lines)

    bad = len({(f["date"], f["exercise"]) for f in findings})
    lines += [f"- **{checked}** prescriptions checked across "
              f"**{result['dated']}** replies on dated training days.",
              f"- **{bad}** of them broke at least one rule.",
              f"- {provenance}", ""]

    if not findings:
        lines += ["- Nothing to report: every prescription followed the "
                  "protocol on every check.", ""]
        return "\n".join(lines)

    lines += ["**What was broken, and how often**", ""]
    for code, count in sorted(result["counts"].items(), key=lambda kv: -kv[1]):
        lines.append(f"- {_LABELS.get(code, code)} — **{count}**")
    lines.append("")

    lines += ["**The most recent of each**", ""]
    seen = set()
    for f in reversed(findings):
        if f["code"] in seen:
            continue
        seen.add(f["code"])
        lines.append(f"- {f['date']} · {f['session']} wk{f['week']} · "
                     f"{f['exercise']} — {f['detail']}")
    lines.append("")
    if detail and result.get("disagreements"):
        lines += ["**Where the coach's stated week and the session row disagree (sample)**", ""]
        for d in result["disagreements"]:
            lines.append(f"- {d['date']} · {d['session']} · row says wk{d['row_week']}, "
                         f"coach says wk{d['stated']} — “{d['snippet']}”")
        lines.append("")

    # Bulleted like everything above it: a bare paragraph here is exactly the
    # trailing line that gets glued onto the row before it in the bubble.
    lines += ["- Every check is decidable from the prescription and the week — "
              "no load history is reconstructed and nothing is a judgement "
              "call. These are the coach disagreeing with the protocol in your "
              "own prompt."]
    return "\n".join(lines)


def run_chat_audit(days: int, prompt: str) -> tuple:
    """(report, summary) — same shape the replay command already returns."""
    result = audit(days, prompt)
    report = render_chat(result)
    bad = len({(f["date"], f["exercise"]) for f in result["violations"]})
    summary = (f"A protocol audit ran over the last {days} days: "
               f"{result['prescriptions']} prescriptions checked, {bad} broke "
               f"at least one rule.")
    return report, summary


def _main() -> int:
    """CLI entry point, so a scheduled job can run this without a chat turn.

    The point of this path: a development machine cannot reach the database —
    the egress proxy denies both the Supabase host and the Railway app — so any
    report produced there has to be pasted in by the athlete, every time. A
    GitHub Actions runner is not behind that proxy. It can read the database,
    write the report into the repository, and the repository IS reachable.

    So the data arrives on a schedule with nobody copying anything.
    """
    import argparse
    import os

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=90)
    parser.add_argument("--out", default="reports/audit-latest.md")
    parser.add_argument("--prompt", default="system_prompt.txt")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    with open(args.prompt) as handle:
        prompt = handle.read()

    result = audit(args.days, prompt)
    report = render_chat(result, detail=True)

    stamp = now_local().date().isoformat()
    header = (f"<!-- generated {stamp} · {result['prescriptions']} prescriptions "
              f"· {len(result['violations'])} violations -->\n\n")
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w") as handle:
        handle.write(header + report + "\n")

    # A per-code, per-date breakdown alongside the prose, so a trend is
    # readable without re-running anything.
    import csv
    rows_path = os.path.join(os.path.dirname(args.out) or ".", "audit-findings.csv")
    with open(rows_path, "w", newline="") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=["date", "session", "week", "exercise", "code", "detail"])
        writer.writeheader()
        writer.writerows(result["violations"])

    print(f"{result['prescriptions']} prescriptions checked, "
          f"{len(result['violations'])} violations -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
