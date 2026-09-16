"""Cost of every model call, recorded and reported.

The optimisation plan (docs/OPTIMISATION.md) has one rule: nothing is cut
until the numbers say where the cost is. This module supplies the numbers.

`record_call` writes one row per call to `model_calls` — kind, attempt,
seconds, tokens with cache reads separate. It never raises: a failed write
costs a log line, not a reply. `report` turns the last N days into the
summary the weekly Actions job prints and commits, so the figures reach the
repository without anyone pasting a log.

Every row is also priced. Seconds say what the athlete waited; dollars say
what the app paid, and the optimisation stages are judged on both. Rates
live in one dated table below and nowhere else; a model the table does not
know is reported as unpriced rather than guessed.

    python usage.py --report 14
"""

from __future__ import annotations

import argparse
import logging
import statistics
from datetime import datetime, timedelta, timezone

log = logging.getLogger(__name__)

# USD per million tokens, Anthropic first-party API. Cache writes are priced
# at the ONE-HOUR rate (2× input) because coach.py caches with ttl "1h";
# cache reads are 0.1× input. Check against the pricing page when a model
# changes and move the date.
RATES_AS_OF = "2026-09-15"
RATES = {
    "claude-sonnet-5":  {"input": 2.00, "output": 10.00, "cache_read": 0.20, "cache_write": 4.00},
    "claude-opus-5":    {"input": 5.00, "output": 25.00, "cache_read": 0.50, "cache_write": 10.00},
    "claude-haiku-4-5": {"input": 1.00, "output": 5.00,  "cache_read": 0.10, "cache_write": 2.00},
}
# Rows written before the model column was filled were all Sonnet 5 calls.
DEFAULT_MODEL = "claude-sonnet-5"
DAYS_PER_MONTH = 30.44


def rates_for(model: str | None) -> dict | None:
    """The rate row for a model id, matched on prefix so a dated snapshot
    id prices like its family. None when unknown."""
    name = model or DEFAULT_MODEL
    for prefix, r in RATES.items():
        if name.startswith(prefix):
            return r
    return None


def cost_usd(row: dict) -> float | None:
    """Dollars for one model_calls row, or None when the model is unpriced."""
    r = rates_for(row.get("model"))
    if r is None:
        return None
    m = 1_000_000
    return (int(row.get("input_tokens") or 0) * r["input"]
            + int(row.get("cache_read_tokens") or 0) * r["cache_read"]
            + int(row.get("cache_write_tokens") or 0) * r["cache_write"]
            + int(row.get("output_tokens") or 0) * r["output"]) / m


def usage_fields(response) -> dict:
    """Token counts off an API response, zero when absent."""
    u = getattr(response, "usage", None)
    def g(attr):
        v = getattr(u, attr, None) if u is not None else None
        return int(v) if isinstance(v, (int, float)) else 0
    return {
        "input_tokens": g("input_tokens"),
        "cache_read_tokens": g("cache_read_input_tokens"),
        "cache_write_tokens": g("cache_creation_input_tokens"),
        "output_tokens": g("output_tokens"),
    }


def visible_chars(response) -> int | None:
    """Length of the text the athlete actually received — every text block,
    thinking excluded. None when the response carries no content list."""
    content = getattr(response, "content", None)
    if not isinstance(content, (list, tuple)):
        return None
    return sum(len(getattr(b, "text", "") or "") for b in content if getattr(b, "type", "") == "text")


CHARS_PER_TOKEN = 4.0


def record_call(kind: str, seconds: float, response=None, attempt: int = 1,
                ok: bool = True, note: str = "", model: str | None = None) -> None:
    """Best-effort: one row in model_calls. Never raises.

    `visible_chars` is written when migration 006 has run; before that the
    insert is retried without it, so a missing column costs nothing but the
    one field."""
    try:
        from data import get_supabase  # local: keeps import order flat
        supabase = get_supabase()
        if not supabase:
            return
        row = {"kind": kind, "attempt": attempt, "ok": ok, "seconds": round(float(seconds), 2),
               "note": (note or "")[:500], "model": model}
        row.update(usage_fields(response))
        vis = visible_chars(response)
        if vis is not None:
            row["visible_chars"] = vis
        try:
            supabase.table("model_calls").insert(row).execute()
        except Exception:
            if "visible_chars" not in row:
                raise
            row.pop("visible_chars")
            log.info("model_calls has no visible_chars column yet (migration 006); recorded without it")
            supabase.table("model_calls").insert(row).execute()
    except Exception:
        log.warning("model_calls write failed (%s)", kind, exc_info=True)


def _p(values, q):
    if not values:
        return 0.0
    values = sorted(values)
    idx = min(len(values) - 1, max(0, round(q * (len(values) - 1))))
    return float(values[idx])


def summarise(rows: list[dict]) -> dict:
    """Per kind: count, seconds (median, p90, max), tokens (median in/cached/out),
    cache hit rate = cached / (cached + uncached input)."""
    by_kind: dict = {}
    for r in rows:
        by_kind.setdefault(r.get("kind") or "?", []).append(r)
    out = {}
    for kind, rs in sorted(by_kind.items()):
        secs = [float(r["seconds"]) for r in rs if r.get("seconds") is not None]
        inp = [int(r.get("input_tokens") or 0) for r in rs]
        cached = [int(r.get("cache_read_tokens") or 0) for r in rs]
        outp = [int(r.get("output_tokens") or 0) for r in rs]
        total_in = sum(inp) + sum(cached)
        # Text the athlete saw, as tokens, and thinking as the remainder.
        # Rows from before migration 006 have no visible_chars and are left
        # out of both, so the two medians describe the same calls.
        vis_tokens = [int(r["visible_chars"]) / CHARS_PER_TOKEN for r in rs
                      if r.get("visible_chars") is not None]
        vis_out = [int(r.get("output_tokens") or 0) for r in rs if r.get("visible_chars") is not None]
        text_median = statistics.median(vis_tokens) if vis_tokens else None
        thinking_median = (max(0.0, statistics.median(vis_out) - text_median)
                           if vis_tokens else None)
        costs = [cost_usd(r) for r in rs]
        priced = [c for c in costs if c is not None]
        out[kind] = {
            "cost_total": sum(priced),
            "cost_median": statistics.median(priced) if priced else 0.0,
            "unpriced": len(costs) - len(priced),
            "calls": len(rs),
            "failed": sum(1 for r in rs if r.get("ok") is False),
            "retries": sum(1 for r in rs if int(r.get("attempt") or 1) > 1),
            "sec_median": statistics.median(secs) if secs else 0.0,
            "sec_p90": _p(secs, 0.9),
            "sec_max": max(secs) if secs else 0.0,
            "in_median": statistics.median(inp) if inp else 0,
            "cached_median": statistics.median(cached) if cached else 0,
            "out_median": statistics.median(outp) if outp else 0,
            "text_median": text_median,
            "thinking_median": thinking_median,
            "cache_hit": (sum(cached) / total_in) if total_in else 0.0,
        }
    return out


def _parse_when(value) -> datetime | None:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def cost_summary(rows: list[dict], days: int, now: datetime | None = None) -> dict:
    """Dollars over the window, per day, projected to a month, month to date,
    and per session opening (every `plan` row, retries included, divided by
    first attempts)."""
    now = now or datetime.now(timezone.utc)
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    # Recording began when migration 003 ran and the backend deployed, which
    # can be well inside the window. Dividing by the window's days would then
    # understate the daily rate, so the rate is taken over the days actually
    # recorded: first row to now, never less than one day.
    firsts = [w for w in (_parse_when(r.get("called_at")) for r in rows) if w is not None]
    first = min(firsts) if firsts else None
    recorded_days = max(1.0, (now - first).total_seconds() / 86400) if first else float(days or 1)
    total = 0.0
    mtd = 0.0
    plan_cost = 0.0
    openings = 0
    unpriced = 0
    for r in rows:
        c = cost_usd(r)
        if c is None:
            unpriced += 1
            continue
        total += c
        when = _parse_when(r.get("called_at"))
        if when is not None and when >= month_start:
            mtd += c
        if (r.get("kind") or "") == "plan":
            plan_cost += c
            if int(r.get("attempt") or 1) == 1:
                openings += 1
    per_day = total / recorded_days
    return {
        "total": total,
        "first_recorded": first.strftime("%Y-%m-%d") if first else None,
        "recorded_days": recorded_days,
        "per_day": per_day,
        "month_projection": per_day * DAYS_PER_MONTH,
        "month_to_date": mtd,
        # The window reaches back to the 1st only when it is at least that long.
        "mtd_complete": (now - timedelta(days=days)) <= month_start,
        "per_opening": (plan_cost / openings) if openings else None,
        "unpriced": unpriced,
    }


def format_report(summary: dict, days: int, since: str, cost: dict | None = None) -> str:
    lines = [f"# Model calls · last {days} days (since {since})", ""]
    if not summary:
        lines.append("No calls recorded. Has migration 003 been run, and has the backend deployed since?")
        return "\n".join(lines)
    lines.append("| kind | calls | retries | failed | median s | p90 s | max s | in (med) | cached (med) | out (med) | text (med) | thinking (med) | cache hit |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for kind, s in summary.items():
        text_c = "?" if s.get("text_median") is None else f"{s['text_median']:.0f}"
        think_c = "?" if s.get("thinking_median") is None else f"{s['thinking_median']:.0f}"
        lines.append(f"| {kind} | {s['calls']} | {s['retries']} | {s['failed']} | {s['sec_median']:.1f} | "
                     f"{s['sec_p90']:.1f} | {s['sec_max']:.1f} | {s['in_median']:.0f} | {s['cached_median']:.0f} | "
                     f"{s['out_median']:.0f} | {text_c} | {think_c} | {s['cache_hit']:.0%} |")
    lines += ["",
              "Reading it: `in` is uncached input tokens per call, `cached` the tokens served from the "
              "prompt cache, `out` the tokens the athlete waited on (thinking included), `text` the part "
              "of `out` the athlete actually received and `thinking` the rest (`?` until migration 006 "
              "has rows). A low cache hit "
              "on a day with many calls means the stable block changed within the day. See "
              "docs/OPTIMISATION.md for the gates each stage must pass."]

    # ── Cost ────────────────────────────────────────────────────────────────
    grand = sum(s["cost_total"] for s in summary.values())
    lines += ["", "## Cost", "",
              "| kind | calls | total | median per call | share |",
              "|---|---:|---:|---:|---:|"]
    for kind, s in summary.items():
        share = (s["cost_total"] / grand) if grand else 0.0
        lines.append(f"| {kind} | {s['calls']} | ${s['cost_total']:.2f} | ${s['cost_median']:.3f} | {share:.0%} |")
    if cost:
        month_note = "" if cost["mtd_complete"] else " (window shorter than the month; lower bound)"
        span = (f"{cost['recorded_days']:.0f} recorded days (first call {cost['first_recorded']})"
                if cost.get("first_recorded") else f"{days} days")
        lines += ["",
                  f"**${cost['total']:.2f} over {span}** → ${cost['per_day']:.2f} a day → "
                  f"about **${cost['month_projection']:.0f} a month** at this rate. "
                  f"Month to date: ${cost['month_to_date']:.2f}{month_note}."]
        if cost["per_opening"] is not None:
            lines.append(f"A session opening (the plan call, retries included) costs about "
                         f"**${cost['per_opening']:.2f}**.")
        if cost["unpriced"]:
            lines.append(f"{cost['unpriced']} call(s) on a model the rate table does not know were left out.")
    sonnet = RATES["claude-sonnet-5"]
    lines += ["",
              f"Rates as of {RATES_AS_OF}, first-party API, per million tokens: Sonnet 5 "
              f"${sonnet['input']:.2f} in / ${sonnet['output']:.2f} out, cache read ${sonnet['cache_read']:.2f}, "
              f"cache write ${sonnet['cache_write']:.2f} at the one-hour TTL the coach uses. "
              f"The table is `RATES` in usage.py; move the date when it changes."]
    return "\n".join(lines)


# ── The shadow, read from tables ────────────────────────────────────────────
#
# "How often does the coach depart from the programme, and does it say why"
# has had a table answering it since the plan contract: prescription_decisions
# stores every exercise of every opening as accept or adjust with its reason.
# The older programme shadow — what the programme would have prescribed
# against what the coach sent, on every reply — was a Railway log line nobody
# read; record_shadow writes it as a row. Both are aggregated here so the
# substitution flag is judged on numbers.

# Rows in prescription_decisions that are not the coach's decisions.
_NOT_A_DECISION_PREFIXES = ("Weak-point: ", "Emphasis-next: ")
_PROGRAMME_REASON_PREFIX = "programme — coach reviewing"


def record_shadow(date: str, session_type: str | None, week, kind: str, exercise: str,
                  sent: dict, computed: dict) -> None:
    """Best-effort: one row per exercise the programme would have changed."""
    try:
        import json
        from data import get_supabase  # local: keeps import order flat
        supabase = get_supabase()
        if not supabase:
            return
        supabase.table("programme_shadow").insert({
            "date": date, "session_type": session_type,
            "mesocycle_week": int(week) if str(week).isdigit() else None,
            "kind": kind, "exercise": exercise,
            "sent": json.dumps({"working": sent.get("working"), "backoff": sent.get("backoff")}),
            "computed": json.dumps({"working": computed.get("working"), "backoff": computed.get("backoff")}),
        }).execute()
    except Exception:
        log.warning("programme_shadow write failed (%s)", exercise, exc_info=True)


def is_coach_decision(row: dict) -> bool:
    ex = row.get("exercise") or ""
    reason = row.get("reason") or ""
    return not ex.startswith(_NOT_A_DECISION_PREFIXES) and not reason.startswith(_PROGRAMME_REASON_PREFIX)


def summarise_decisions(rows: list[dict]) -> dict:
    """Per opening: exercises decided, adjusts, adjusts that name a cause, the
    lifts most often adjusted with a sample reason each."""
    from plan import _CAUSE_RE  # local: keeps import order flat
    rows = [r for r in rows if is_coach_decision(r)]
    sessions = {(r.get("date"), r.get("session_type")) for r in rows}
    adjusts = [r for r in rows if (r.get("decision") or "") == "adjust"]
    with_cause = [r for r in adjusts if _CAUSE_RE.search(r.get("reason") or "")]
    by_lift: dict = {}
    for r in adjusts:
        entry = by_lift.setdefault(r.get("exercise") or "?", {"count": 0, "reasons": []})
        entry["count"] += 1
        if len(entry["reasons"]) < 2 and r.get("reason"):
            entry["reasons"].append((r.get("reason") or "")[:90])
    top = sorted(by_lift.items(), key=lambda kv: (-kv[1]["count"], kv[0]))[:5]
    return {
        "sessions": len(sessions),
        "exercises": len(rows),
        "adjusts": len(adjusts),
        "adjust_rate": (len(adjusts) / len(rows)) if rows else 0.0,
        "cause_rate": (len(with_cause) / len(adjusts)) if adjusts else None,
        "top_adjusted": [{"exercise": k, **v} for k, v in top],
    }


def summarise_shadow(rows: list[dict]) -> dict:
    """Per reply kind: how many exercises the programme would have changed,
    and which most often."""
    by_kind: dict = {}
    by_lift: dict = {}
    for r in rows:
        by_kind[r.get("kind") or "?"] = by_kind.get(r.get("kind") or "?", 0) + 1
        by_lift[r.get("exercise") or "?"] = by_lift.get(r.get("exercise") or "?", 0) + 1
    top = sorted(by_lift.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
    return {"total": len(rows), "by_kind": by_kind, "top": top,
            "days": len({r.get("date") for r in rows})}


def format_decisions(d: dict, shadow: dict | None, days: int) -> str:
    lines = ["", "## Decisions — the coach against the programme", ""]
    if not d["exercises"]:
        lines.append("No opening decisions recorded in the window.")
    else:
        cause = "—" if d["cause_rate"] is None else f"{d['cause_rate']:.0%}"
        lines.append(f"Over {d['sessions']} openings the coach decided {d['exercises']} exercises and adjusted "
                     f"**{d['adjusts']}** of them (**{d['adjust_rate']:.0%}**); of the adjusts, **{cause}** named a "
                     f"cause (recovery reading, joint, machine, time). The rest took the programme's numbers.")
        if d["top_adjusted"]:
            lines += ["", "| lift | adjusted | reasons |", "|---|---:|---|"]
            for t in d["top_adjusted"]:
                lines.append(f"| {t['exercise']} | {t['count']} | {' · '.join(t['reasons']) or '—'} |")
    lines += ["", "### Programme shadow — replies the programme would have changed", ""]
    if shadow is None:
        lines.append("Not recorded yet (migration 008).")
    elif not shadow["total"]:
        lines.append(f"None in {days} days: every block the coach sent matched what the programme computed, "
                     f"or the difference was already an adjust with its reason.")
    else:
        kinds = ", ".join(f"{k} {v}" for k, v in sorted(shadow["by_kind"].items()))
        lines.append(f"**{shadow['total']}** exercise blocks on {shadow['days']} days differed from the programme's "
                     f"computation ({kinds}). Most often: " + ", ".join(f"{n} ×{c}" for n, c in shadow["top"]) + ".")
    lines += ["", "Reading it: the adjust rate is how often the coach departs from the programme at the "
              "opening; the cause rate is whether it says why. The shadow counts replies outside the plan "
              "contract — prose and set replies — whose numbers the programme would have replaced. The "
              "substitution flag stays off while the adjust rate is low and the cause rate high; a rising "
              "shadow count on prose replies is the case for turning it on."]
    return "\n".join(lines)


def fetch_decisions(days: int) -> list[dict]:
    from data import get_supabase  # local: keeps import order flat
    supabase = get_supabase()
    if not supabase:
        return []
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
    try:
        return (supabase.table("prescription_decisions")
                .select("date, session_type, exercise, decision, reason")
                .gte("date", since).order("date").order("id").range(0, 4999).execute()).data or []
    except Exception as exc:
        log.warning("prescription_decisions could not be read: %s", exc)
        return []


def fetch_shadow(days: int) -> list[dict] | None:
    """None when the table does not exist yet (migration 008), [] when empty."""
    from data import get_supabase  # local: keeps import order flat
    supabase = get_supabase()
    if not supabase:
        return None
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
    try:
        return (supabase.table("programme_shadow").select("date, kind, exercise")
                .gte("date", since).order("date").range(0, 4999).execute()).data or []
    except Exception as exc:
        log.warning("programme_shadow could not be read: %s", exc)
        return None


def fetch_rows(days: int) -> list[dict]:
    """Rows from model_calls. A missing table — migration 003 not yet run —
    reads as no calls, so the report says what to do instead of the job
    failing."""
    from data import get_supabase  # local: keeps import order flat
    supabase = get_supabase()
    if not supabase:
        return []
    try:
        return _fetch_rows(supabase, days)
    except Exception as exc:  # postgrest.APIError for a missing table, network, etc.
        log.warning("model_calls could not be read: %s", exc)
        print(f"model_calls could not be read: {exc}")
        return []


def _fetch_rows(supabase, days: int) -> list[dict]:
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    rows: list[dict] = []
    page, offset = 1000, 0
    while True:
        result = (supabase.table("model_calls").select("*").gte("called_at", since)
                  .order("called_at").range(offset, offset + page - 1).execute())
        chunk = result.data or []
        rows.extend(chunk)
        if len(chunk) < page:
            break
        offset += page
    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", type=int, default=14, metavar="DAYS")
    ap.add_argument("--out", default="reports/model_calls.md")
    args = ap.parse_args()
    rows = fetch_rows(args.report)
    since = (datetime.now(timezone.utc) - timedelta(days=args.report)).strftime("%Y-%m-%d")
    text = format_report(summarise(rows), args.report, since, cost_summary(rows, args.report))
    shadow_rows = fetch_shadow(args.report)
    text += "\n" + format_decisions(summarise_decisions(fetch_decisions(args.report)),
                                     None if shadow_rows is None else summarise_shadow(shadow_rows),
                                     args.report)
    print(text)
    if args.out:
        import os
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        with open(args.out, "w") as fh:
            fh.write(text + "\n")


if __name__ == "__main__":
    main()
