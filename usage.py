"""Cost of every model call, recorded and reported.

The optimisation plan (docs/OPTIMISATION.md) has one rule: nothing is cut
until the numbers say where the cost is. This module supplies the numbers.

`record_call` writes one row per call to `model_calls` — kind, attempt,
seconds, tokens with cache reads separate. It never raises: a failed write
costs a log line, not a reply. `report` turns the last N days into the
summary the weekly Actions job prints and commits, so the figures reach the
repository without anyone pasting a log.

    python usage.py --report 14
"""

from __future__ import annotations

import argparse
import logging
import statistics
from datetime import datetime, timedelta, timezone

log = logging.getLogger(__name__)


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


def record_call(kind: str, seconds: float, response=None, attempt: int = 1,
                ok: bool = True, note: str = "", model: str | None = None) -> None:
    """Best-effort: one row in model_calls. Never raises."""
    try:
        from data import get_supabase  # local: keeps import order flat
        supabase = get_supabase()
        if not supabase:
            return
        row = {"kind": kind, "attempt": attempt, "ok": ok, "seconds": round(float(seconds), 2),
               "note": (note or "")[:500], "model": model}
        row.update(usage_fields(response))
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
        out[kind] = {
            "calls": len(rs),
            "failed": sum(1 for r in rs if r.get("ok") is False),
            "retries": sum(1 for r in rs if int(r.get("attempt") or 1) > 1),
            "sec_median": statistics.median(secs) if secs else 0.0,
            "sec_p90": _p(secs, 0.9),
            "sec_max": max(secs) if secs else 0.0,
            "in_median": statistics.median(inp) if inp else 0,
            "cached_median": statistics.median(cached) if cached else 0,
            "out_median": statistics.median(outp) if outp else 0,
            "cache_hit": (sum(cached) / total_in) if total_in else 0.0,
        }
    return out


def format_report(summary: dict, days: int, since: str) -> str:
    lines = [f"# Model calls · last {days} days (since {since})", ""]
    if not summary:
        lines.append("No calls recorded. Has migration 003 been run, and has the backend deployed since?")
        return "\n".join(lines)
    lines.append("| kind | calls | retries | failed | median s | p90 s | max s | in (med) | cached (med) | out (med) | cache hit |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for kind, s in summary.items():
        lines.append(f"| {kind} | {s['calls']} | {s['retries']} | {s['failed']} | {s['sec_median']:.1f} | "
                     f"{s['sec_p90']:.1f} | {s['sec_max']:.1f} | {s['in_median']:.0f} | {s['cached_median']:.0f} | "
                     f"{s['out_median']:.0f} | {s['cache_hit']:.0%} |")
    lines += ["",
              "Reading it: `in` is uncached input tokens per call, `cached` the tokens served from the "
              "prompt cache, `out` the tokens the athlete waited on (thinking included). A low cache hit "
              "on a day with many calls means the stable block changed within the day. See "
              "docs/OPTIMISATION.md for the gates each stage must pass."]
    return "\n".join(lines)


def fetch_rows(days: int) -> list[dict]:
    from data import get_supabase  # local: keeps import order flat
    supabase = get_supabase()
    if not supabase:
        return []
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
    text = format_report(summarise(rows), args.report, since)
    print(text)
    if args.out:
        import os
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        with open(args.out, "w") as fh:
            fh.write(text + "\n")


if __name__ == "__main__":
    main()
