"""Replay the whole pipeline against a real export, offline (backlog F8).

For every stamped session in the export — the ones carrying a mesocycle
week and day, 3 Sep 2026 on — the store is wound back to the moment the
session started, the clock is frozen there, and coach_context.build_context_block
runs exactly as it does before a coach call: every fetch, the programme's
proposal, the pre-flight. What comes out is compared with what was actually
prescribed that day (prescription_decisions) and what was lifted
(workout_sets). Nothing is mocked but the store and the clock; no model is
called.

The five CSVs are the app's Export (Settings → Export training log) copied
to tests/fixtures/export/. tests/test_replay_export.py runs this as a test;
`python replay_export.py` prints the report.
"""
from __future__ import annotations

import csv
import json
import logging
import os
import threading
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

FIXTURES = Path(__file__).parent / "tests" / "fixtures" / "export"
TABLES = ("recovery", "workout_sessions", "workout_sets", "prescription_decisions", "exercise_constraints")
_BOOL_COLUMNS = {"is_warmup", "active"}
_JSON_COLUMNS = {"plan"}

log = logging.getLogger(__name__)


# ── the export ───────────────────────────────────────────────────────────────

def _coerce(column: str, value: str):
    if value is None or value == "":
        return None
    if column in _BOOL_COLUMNS:
        return value.strip().lower() in ("1", "true", "t", "yes")
    if column in _JSON_COLUMNS:
        try:
            return json.loads(value)
        except ValueError:
            return value
    try:
        f = float(value)
    except ValueError:
        return value
    if column in ("id",) and not value.isdigit():
        return value
    return int(f) if f.is_integer() and "." not in value else f


def load_export(folder: Path = FIXTURES) -> dict[str, list[dict]]:
    """The export's tables. recovery.csv is health data and is not committed
    (the repository is public); when the file is beside the others the
    replay reads it, otherwise every session runs as a day with no reading."""
    out = {}
    for table in TABLES:
        path = folder / f"{table}.csv"
        if not path.exists():
            out[table] = []
            continue
        with open(path, newline="", encoding="utf-8") as fh:
            out[table] = [{k: _coerce(k, v) for k, v in row.items()} for row in csv.DictReader(fh)]
    return out


# ── an in-memory PostgREST ───────────────────────────────────────────────────

class _Response:
    def __init__(self, data, count=None):
        self.data, self.count = data, count


class FakeQuery:
    """The chain the code uses — select/eq/gte/lte/lt/gt/in_/like/ilike/is_/
    not_/order/limit/range and the four writes — over lists of dicts."""

    def __init__(self, store: "FakeStore", table: str):
        self.store, self.table = store, table
        self.filters: list = []
        self.orders: list = []
        self.limit_n = None
        self.range_ = None
        self.count_mode = None
        self.negate = False
        self.write = None

    # select / writes
    def select(self, *_cols, count=None, **_kw):
        self.count_mode = count
        return self

    def insert(self, rows):
        self.write = ("insert", rows)
        return self

    def upsert(self, rows, **_kw):
        self.write = ("upsert", rows)
        return self

    def update(self, values):
        self.write = ("update", values)
        return self

    def delete(self):
        self.write = ("delete", None)
        return self

    # filters
    def _add(self, op, field, value):
        self.filters.append((op, field, value, self.negate))
        self.negate = False
        return self

    def eq(self, f, v): return self._add("eq", f, v)
    def neq(self, f, v): return self._add("neq", f, v)
    def gte(self, f, v): return self._add("gte", f, v)
    def lte(self, f, v): return self._add("lte", f, v)
    def gt(self, f, v): return self._add("gt", f, v)
    def lt(self, f, v): return self._add("lt", f, v)
    def in_(self, f, v): return self._add("in", f, tuple(v))
    def like(self, f, v): return self._add("like", f, v)
    def ilike(self, f, v): return self._add("ilike", f, v)
    def is_(self, f, v): return self._add("is", f, v)

    @property
    def not_(self):
        self.negate = True
        return self

    def order(self, field, desc=False, **_kw):
        self.orders.append((field, desc))
        return self

    def limit(self, n):
        self.limit_n = n
        return self

    def range(self, a, b):
        self.range_ = (a, b)
        return self

    # evaluation
    @staticmethod
    def _cmp(a, b) -> int | None:
        if a is None or b is None:
            return None
        try:
            fa, fb = float(a), float(b)
            return (fa > fb) - (fa < fb)
        except (TypeError, ValueError):
            sa, sb = str(a), str(b)
            return (sa > sb) - (sa < sb)

    def _matches(self, row: dict) -> bool:
        for op, field, value, neg in self.filters:
            have = row.get(field)
            if op == "eq":
                ok = have == value or (have is not None and str(have) == str(value))
            elif op == "neq":
                ok = not (have == value or (have is not None and str(have) == str(value)))
            elif op in ("gte", "lte", "gt", "lt"):
                c = self._cmp(have, value)
                ok = c is not None and {"gte": c >= 0, "lte": c <= 0, "gt": c > 0, "lt": c < 0}[op]
            elif op == "in":
                ok = have in value or str(have) in {str(v) for v in value}
            elif op in ("like", "ilike"):
                import fnmatch
                pattern = str(value).replace("%", "*").replace("_", "?")
                s = str(have or "")
                ok = fnmatch.fnmatchcase(s if op == "like" else s.lower(), pattern if op == "like" else pattern.lower())
            elif op == "is":
                ok = (have is None) if str(value).lower() == "null" else (have == value)
            else:
                ok = True
            if neg:
                ok = not ok
            if not ok:
                return False
        return True

    def execute(self):
        with self.store.lock:
            rows = self.store.tables.setdefault(self.table, [])
            if self.write:
                kind, payload = self.write
                if kind == "insert":
                    new = payload if isinstance(payload, list) else [payload]
                    for r in new:
                        r = dict(r)
                        r.setdefault("id", self.store.next_id())
                        rows.append(r)
                    return _Response(new)
                if kind == "upsert":
                    new = payload if isinstance(payload, list) else [payload]
                    for r in new:
                        key = r.get("key")
                        if key is not None:
                            rows[:] = [x for x in rows if x.get("key") != key]
                        rows.append(dict(r))
                    return _Response(new)
                if kind == "update":
                    hit = [r for r in rows if self._matches(r)]
                    for r in hit:
                        r.update(payload)
                    return _Response(hit)
                if kind == "delete":
                    hit = [r for r in rows if self._matches(r)]
                    rows[:] = [r for r in rows if not self._matches(r)]
                    return _Response(hit)
            hit = [r for r in rows if self._matches(r)]
            for field, desc in reversed(self.orders):
                hit.sort(key=lambda r: (r.get(field) is None, str(r.get(field)) if not isinstance(r.get(field), (int, float)) else r.get(field)), reverse=desc)
            total = len(hit)
            if self.range_:
                a, b = self.range_
                hit = hit[a:b + 1]
            if self.limit_n is not None:
                hit = hit[:self.limit_n]
            return _Response([dict(r) for r in hit], total if self.count_mode else None)


class FakeStore:
    def __init__(self, tables: dict[str, list[dict]]):
        self.tables = {k: [dict(r) for r in v] for k, v in tables.items()}
        self.lock = threading.RLock()
        self._id = 10_000_000

    def next_id(self):
        self._id += 1
        return self._id

    def table(self, name):
        return FakeQuery(self, name)


# ── time travel ──────────────────────────────────────────────────────────────

def _iso(value) -> str:
    return str(value or "")


def snapshot(export: dict, before_utc: str, session: dict, memory: dict) -> FakeStore:
    """Everything the store held when the session started: rows written
    before that moment, plus the session row itself (already 'active') and
    the memory keys the pipeline reads."""
    tables = {}
    tables["workout_sets"] = [r for r in export["workout_sets"] if _iso(r.get("logged_at")) < before_utc]
    tables["workout_sessions"] = [r for r in export["workout_sessions"]
                                  if _iso(r.get("created_at")) < before_utc and r.get("id") != session.get("id")]
    tables["workout_sessions"].append({**session, "status": "active", "end_time": None, "tonnage_kg": None})
    tables["recovery"] = [r for r in export["recovery"] if _iso(r.get("date")) <= session["date"]
                          and _iso(r.get("created_at")) < before_utc]
    tables["prescription_decisions"] = [r for r in export["prescription_decisions"] if _iso(r.get("created_at")) < before_utc]
    tables["exercise_constraints"] = [r for r in export["exercise_constraints"] if _iso(r.get("created_at")) < before_utc]
    tables["memory"] = [{"key": k, "value": str(v)} for k, v in memory.items()]
    for empty in ("block_reviews", "decision_captures", "conversations", "coach_flags", "model_calls",
                  "exercises", "exercise_substitutions", "apple_workouts"):
        tables[empty] = []
    return FakeStore(tables)


class _FrozenDateTime(datetime):
    frozen: datetime = None

    @classmethod
    def now(cls, tz=None):
        base = cls.frozen
        return base.astimezone(tz) if tz else base.replace(tzinfo=None)


def stamped_sessions(export: dict) -> list[dict]:
    """Resistance sessions with a mesocycle stamp, oldest first."""
    out = [r for r in export["workout_sessions"]
           if r.get("mesocycle_week") and r.get("type") in ("Pull", "Push", "Legs", "Cardio+Abs")
           and r.get("status") == "completed" and (r.get("tonnage_kg") or 0) > 0]
    return sorted(out, key=lambda r: _iso(r.get("start_time")))


# ── one session ──────────────────────────────────────────────────────────────

def replay_session(export: dict, session: dict, prompt: str) -> dict:
    import data
    import programme
    import coach_context

    start = _iso(session.get("start_time") or session.get("created_at"))
    start_dt = datetime.fromisoformat(start.replace("Z", "+00:00"))
    if start_dt.tzinfo is None:
        start_dt = start_dt.replace(tzinfo=timezone.utc)
    memory = {"mesocycle_week": int(session["mesocycle_week"]), "mesocycle_day": int(session["mesocycle_day"]),
              "workout_mode": "inactive"}
    store = snapshot(export, start, session, memory)
    captured: dict = {}
    real_build = programme.build_proposal

    def recording_build(*a, **kw):
        result = real_build(*a, **kw)
        captured["proposals"] = result[0]
        captured["preflight"] = list(programme.LAST_PREFLIGHT or [])
        return result

    _FrozenDateTime.frozen = start_dt
    out: dict = {}
    error = None
    # The block length in force when the session was trained: four weeks
    # until 24 Sep 2026, five from then (data.block_weeks is a setting now).
    weeks_then = 4 if session["date"] < "2026-09-24" else data.block_weeks()
    with patch.object(data, "_supabase_client", store), patch.object(data, "datetime", _FrozenDateTime), \
         patch.object(programme, "build_proposal", recording_build), \
         patch.object(data, "block_weeks", lambda: weeks_then):
        try:
            coach_context.build_context_block(memory, "Athlete", 0, 0, log, system_prompt=prompt, out=out,
                                              session_type=session["type"])
        except Exception as exc:  # the harness reports, it does not hide
            error = f"{type(exc).__name__}: {exc}"

    proposals = captured.get("proposals") or []
    actual = {}
    for r in export["prescription_decisions"]:
        if r.get("session_id") == session.get("id") and r.get("decision") in ("accept", "adjust") \
                and not str(r.get("exercise") or "").startswith("Weak-point"):
            actual.setdefault(_fold(r["exercise"]), r)
    logged = {}
    for r in export["workout_sets"]:
        if r.get("workout_session_id") == session.get("id") and not r.get("is_warmup") and r.get("actual_weight_kg"):
            key = _fold(r["exercise"])
            top = logged.get(key)
            if top is None or float(r["actual_weight_kg"]) > float(top["actual_weight_kg"]):
                logged[key] = r
    # The last top set of each lift before this session: the load the
    # programme progresses from, and the anchor of the stack's ladder.
    prior: dict = {}
    for r in export["workout_sets"]:
        if _iso(r.get("logged_at")) < start and not r.get("is_warmup") and r.get("actual_weight_kg"):
            key = _fold(r["exercise"])
            best = prior.get(key)
            if best is None or _iso(r.get("date")) > _iso(best.get("date")) or (
                    _iso(r.get("date")) == _iso(best.get("date")) and float(r["actual_weight_kg"]) > float(best["actual_weight_kg"])):
                prior[key] = r
    lifts = []
    for p in proposals:
        top = p.working[0] if p.working else None
        key = _fold(p.exercise)
        a, l = actual.get(key), logged.get(key)
        lifts.append({
            "exercise": p.exercise,
            "computed": None if top is None or top.weight_kg is None else float(top.weight_kg),
            "computed_reps": f"{top.reps_low}-{top.reps_high}" if top else "",
            "grid": getattr(top, "grid", None) if top else None,
            "prior": None if key not in prior else float(prior[key]["actual_weight_kg"]),
            "prescribed": None if not a or a.get("top_load_kg") in (None, "") else float(a["top_load_kg"]),
            "logged": None if not l else float(l["actual_weight_kg"]),
            "logged_reps": None if not l else l.get("actual_reps"),
            "reason": "; ".join(getattr(p, "reasons", []) or []),
        })
    return {"date": session["date"], "type": session["type"], "week": memory["mesocycle_week"],
            "day": memory["mesocycle_day"], "id": session.get("id"), "error": error,
            "lifts": lifts, "preflight": captured.get("preflight") or [],
            "open": out.get("open") or [], "context_chars": len(out.get("computed") or {})}


def _fold(name: str) -> str:
    return "".join(ch for ch in (name or "").lower() if ch.isalnum())


def replay_all(export: dict | None = None, prompt: str | None = None) -> list[dict]:
    import contextlib
    import io
    export = export or load_export()
    if prompt is None:
        with open(os.path.join(os.path.dirname(__file__), "system_prompt.txt"), encoding="utf-8") as fh:
            prompt = fh.read()
    # Library code prints ("No recovery data found. Using mock data."); the
    # report is the harness's only output.
    with contextlib.redirect_stdout(io.StringIO()):
        return [replay_session(export, s, prompt) for s in stamped_sessions(export)]


# ── the report ───────────────────────────────────────────────────────────────

def loadable(load: float | None, grid: float | None, anchor: float | None = None) -> bool:
    """On the stack's ladder: a whole number of steps from the last top set
    (85, 93, ... 149, 157 on an 8kg step), or a multiple of the step when no
    prior load is known."""
    if load is None or not grid or grid <= 0:
        return True
    base = anchor or 0.0
    d = (load - base) / grid
    return abs(d - round(d)) < 1e-6


def summarise(results: list[dict]) -> dict:
    lifts = [l for r in results for l in r["lifts"]]
    compared = [l for l in lifts if l["computed"] is not None and l["prescribed"] is not None]
    lifted = [l for l in lifts if l["computed"] is not None and l["logged"]]
    return {
        "sessions": len(results),
        "errors": [r for r in results if r["error"]],
        "lifts": len(lifts),
        "unloadable": [(l["exercise"], l["computed"], l["grid"], l["prior"]) for l in lifts
                       if not loadable(l["computed"], l["grid"], l["prior"])],
        "vs_prescribed": [(l["exercise"], l["computed"], l["prescribed"]) for l in compared
                          if abs(l["computed"] - l["prescribed"]) > 1e-6],
        "compared": len(compared),
        "far_from_logged": [(l["exercise"], l["computed"], l["logged"]) for l in lifted
                            if l["logged"] and abs(l["computed"] - l["logged"]) / l["logged"] > 0.15],
        "lifted": len(lifted),
        "preflight": sum(len(r["preflight"]) for r in results),
    }


def render(results: list[dict]) -> str:
    s = summarise(results)
    lines = [f"# Replay of the export — {s['sessions']} stamped sessions, {s['lifts']} computed lifts", ""]
    lines.append(f"- errors: {len(s['errors'])}")
    lines.append(f"- loads not on the lift's step: {len(s['unloadable'])}")
    lines.append(f"- computed ≠ prescribed that day: {len(s['vs_prescribed'])} of {s['compared']} compared")
    lines.append(f"- computed >15% from what was lifted: {len(s['far_from_logged'])} of {s['lifted']}")
    lines.append(f"- pre-flight corrections: {s['preflight']}")
    lines.append("")
    for r in results:
        head = f"## {r['date']} {r['type']} wk{r['week']} d{r['day']}"
        lines.append(head + (f" — ERROR {r['error']}" if r["error"] else ""))
        for l in r["lifts"]:
            c = "—" if l["computed"] is None else f"{l['computed']:g}"
            p = "—" if l["prescribed"] is None else f"{l['prescribed']:g}"
            g = "—" if l["logged"] is None else f"{l['logged']:g} x{l['logged_reps']}"
            flag = "" if l["prescribed"] is None or l["computed"] is None or abs(l["computed"] - l["prescribed"]) < 1e-6 else "  ≠"
            lines.append(f"- {l['exercise']}: computed {c} ({l['computed_reps']}) · prescribed {p} · lifted {g}{flag}")
        for f in r["preflight"]:
            lines.append(f"  · pre-flight: {f}")
        lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING)
    print(render(replay_all()))
