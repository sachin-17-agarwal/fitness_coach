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
from data import get_supabase, now_local
from prescribe import TOP_SET_RANGE, WAVE, classify, recovery_adjustment
from volume import resolve_contributions

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
    rows = (
        supabase.table("conversations")
        .select("date, role, content")
        .gte("date", since)
        .eq("role", _ASSISTANT)
        .order("date")
        .order("id")
        .execute()
    ).data or []
    return [r for r in rows if (r.get("content") or "").strip()]


def fetch_session_weeks(days: int) -> dict:
    """date -> (session_type, mesocycle_week) from the sessions themselves.

    Taken from the stamped row rather than recomputed. A session records the
    week it was trained in; reconstructing it here would import the very
    rotation-walking that duplicate rows were shown to corrupt.
    """
    supabase = get_supabase()
    since = (now_local().date() - timedelta(days=days)).isoformat()
    rows = (
        supabase.table("workout_sessions")
        .select("date, type, mesocycle_week")
        .gte("date", since)
        .order("date")
        .execute()
    ).data or []
    weeks = {}
    for row in rows:
        date, week = row.get("date"), row.get("mesocycle_week")
        if date and week and date not in weeks:
            weeks[date] = (row.get("type") or "", int(week))
    return weeks


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
    rows = (
        # "recovery", not "health_data" — the name I first wrote does not
        # exist. The query would have returned nothing and the audit would have
        # gone quietly back to being recovery-blind: the same critical, with no
        # symptom, in a tool whose whole value is being trusted about the past.
        supabase.table("recovery")
        .select("date, sleep_hours, hrv, resting_hr")
        .gte("date", since)
        .order("date")
        .execute()
    ).data or []
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


def _violations(block: dict, week: int, session_type: str, prompt: str,
                recovery: dict | None = None, full_reply: bool = True) -> list:
    """Every rule this one prescription breaks. Mechanical, not a judgement.

    A `Revised:` block is the coach departing from the programme on purpose —
    an injury, a machine in use — and the one exit the protocol leaves, so it
    is not a violation of it. `full_reply` says whether the reply laid out the
    session or re-stated one exercise mid-way through it: the set count is
    only checkable on the former, because "Back-off 2 of 2" on its own is a
    partial block by design, not a two-set prescription.
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
    if known and week != 4 and reps is not None and reps < low:
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

    if backoff and top.get("weight") and backoff[0].get("weight"):
        drop = (top["weight"] - backoff[0]["weight"]) / top["weight"] * 100
        if not 15 <= drop <= 25:
            out.append(("backoff_drop",
                        f"back-off {drop:.0f}% below the top set, outside 15-25%"))
    return out


def audit(days: int, prompt: str) -> dict:
    """Count protocol violations across every stored prescription."""
    replies = fetch_assistant_replies(days)
    weeks = fetch_session_weeks(days)
    recovery = fetch_recovery_by_date(days)

    checked, findings, dated, undated = 0, [], 0, 0
    seen_blocks: set = set()
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
            for code, detail in _violations(block, week, session_type, prompt,
                                            recovery.get(date), full_reply):
                findings.append({"date": date, "session": session_type,
                                 "week": week, "exercise": block.get("exercise"),
                                 "code": code, "detail": detail})
    counts = {}
    for f in findings:
        counts[f["code"]] = counts.get(f["code"], 0) + 1
    return {"days": days, "replies": len(replies), "dated": dated,
            "undated": undated, "prescriptions": checked,
            "violations": findings, "counts": counts}


_LABELS = {
    "rpe_under_target": "Prescribed below the week's RPE target",
    "backoff_rpe_under_target": "Back-off below the week's RPE target",
    "reps_below_range": "Top set below the exercise's rep range",
    "set_count": "Wrong number of working sets",
    "backoff_loads_differ": "Two back-offs at different loads",
    "backoff_not_descending": "Second back-off not fewer reps",
    "backoff_drop": "Back-off drop outside 15-25%",
}


def render_chat(result: dict) -> str:
    """The report as the iOS bubble will actually render it.

    Bulleted and blank-line separated on purpose: MarkdownText joins
    consecutive non-blank lines with a single space, so a report laid out for a
    terminal arrives as one paragraph. Only `- ` lines get their own row.
    """
    checked = result["prescriptions"]
    findings = result["violations"]
    lines = [f"**Protocol audit — last {result['days']} days**", ""]

    if not checked:
        lines += ["- No prescriptions found in that window to check.", "",
                  f"- {result['replies']} coach replies were read; "
                  f"{result['undated']} could not be matched to a session with "
                  f"a recorded mesocycle week."]
        return "\n".join(lines)

    bad = len({(f["date"], f["exercise"]) for f in findings})
    lines += [f"- **{checked}** prescriptions checked across "
              f"**{result['dated']}** sessions.",
              f"- **{bad}** of them broke at least one rule.", ""]

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
    report = render_chat(result)

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
