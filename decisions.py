"""Decisions captured when reached (docs/DECISION_CAPTURE.md).

A decision that outlives the session used to depend on the model writing a
`Decision:` or `Emphasis-next:` line in the reply where it was agreed, and
when it agreed in prose and moved on, the decision was lost — the 12 Sep
triceps-and-chest emphasis never reached the block that followed.

Now the coach writes `Proposed: <recordable line>` when something lasting
emerges from the conversation. This module holds the proposal, shows it on
Home until the athlete records or declines it with one tap or one word, and
applies it through the paths that already exist. A detector counts the
lasting phrases in the athlete's message that got no recordable line back,
so the Sunday report can say how often the rule failed. Nothing here calls
a model; nothing is recorded by silence.
"""

from __future__ import annotations

import json
import logging
import re
from datetime import datetime, timedelta, timezone

from data import get_supabase, now_local

log = logging.getLogger(__name__)

# The recordable grammar — one place for what block_review and constraints
# each used to hold. A line is recordable when it is exactly one of these.
# The third grammar (stage 3, shape.py): a substitution held for the block
# or standing, and a session's standing order.
RECORDABLE_RE = re.compile(
    r"^(?P<line>Decision: (?P<exercise>[^|\n]+?) \| (?:max load (?P<cap>\d+(?:\.\d+)?)kg \| (?P<why>.+)|clear)"
    r"|Emphasis-next: (?P<muscle>[A-Za-z ]+?) \| (?P<note>.+)"
    r"|Substitute: (?P<sub_from>[^|>\n]+?) -> (?P<sub_to>[^|\n]+?) \| (?P<horizon>this block|standing) \| (?P<sub_why>.+)"
    r"|Order: (?P<order_session>[A-Za-z+ ]+?) \| (?P<order_first>[^|\n]+?) first \| (?P<order_why>.+))$"
)
PROPOSED_RE = re.compile(r"^\s*Proposed:\s*(?P<line>.+?)\s*$", re.IGNORECASE | re.MULTILINE)
_ANY_RECORDABLE_RE = re.compile(r"^\s*(Decision|Emphasis-next|Proposed|Substitute|Order):", re.IGNORECASE | re.MULTILINE)

# What the athlete says when something is meant to outlive today. Kept to
# phrases that carry a number or a horizon so ordinary set talk ("max
# effort", "cap the reps") does not count.
LASTING_RE = re.compile(
    r"\b(next block|from now on|for the rest of (?:the|this) block|for good|permanently|every session|never again|"
    r"hold (?:it |that |the \w+ )?at \d|cap(?: it| that| the \w+)? at \d|max(?:imum)? (?:load |weight )?(?:of |at )?\d|"
    r"no more than \d|stop (?:doing|programming|prescribing) )",
    re.IGNORECASE,
)

# Answers in chat. Explicit words work any time; a bare yes/no only within
# ANSWER_WINDOW_MINUTES of the proposal, so a "yes" to the coach's question
# mid-set is not taken as a decision.
_RECORD_RE = re.compile(r"^\s*(record(?: it| that| this)?|yes,? record(?: it)?|approve(?: it)?|do it|yes|ok|okay|sure)\b[.!]?\s*$", re.I)
_DECLINE_RE = re.compile(r"^\s*(not now|don'?t record(?: it| that)?|no,? (?:not now|leave it|skip)|skip(?: it)?|later|no)\b[.!]?\s*$", re.I)
_EXPLICIT_RE = re.compile(r"record|not now|skip|later|approve|do it", re.I)
ANSWER_WINDOW_MINUTES = 15


def kind_of(line: str) -> str | None:
    """constraint | emphasis | substitute | order | None."""
    m = RECORDABLE_RE.match((line or "").strip())
    if not m:
        return None
    head = m.group("line").split(":", 1)[0]
    return {"Decision": "constraint", "Emphasis-next": "emphasis", "Substitute": "substitute", "Order": "order"}[head]


def subject_of(line: str) -> str:
    """What the line is about — the exercise, the muscle, the lift replaced or
    the session reordered — folded for comparison."""
    m = RECORDABLE_RE.match((line or "").strip())
    if not m:
        return ""
    subject = m.group("exercise") or m.group("muscle") or m.group("sub_from") or m.group("order_session") or ""
    return "".join(ch for ch in subject.lower() if ch.isalnum())


def describe(line: str) -> str:
    """The line in plain words, for the card."""
    m = RECORDABLE_RE.match((line or "").strip())
    if not m:
        return line
    if m.group("muscle"):
        return f"Next block's emphasis: {m.group('muscle').strip()} — {m.group('note').strip()}"
    if m.group("sub_from"):
        horizon = "for this block" if m.group("horizon") == "this block" else "from now on"
        return f"{m.group('sub_from').strip()} → {m.group('sub_to').strip()} {horizon} — {m.group('sub_why').strip()}"
    if m.group("order_session"):
        return f"{m.group('order_session').strip()}: {m.group('order_first').strip()} first — {m.group('order_why').strip()}"
    exercise = m.group("exercise").strip()
    if m.group("cap"):
        return f"{exercise}: cap {float(m.group('cap')):g} kg — {m.group('why').strip()}"
    return f"{exercise}: cap cleared"


def parse_proposed(reply: str) -> list[dict]:
    """Every `Proposed:` line in the reply that is in the recordable grammar."""
    out = []
    for m in PROPOSED_RE.finditer(reply or ""):
        line = m.group("line").strip()
        kind = kind_of(line)
        if kind:
            out.append({"line": line, "kind": kind})
    return out


def has_recordable_line(reply: str) -> bool:
    return bool(_ANY_RECORDABLE_RE.search(reply or ""))


def lasting_phrases(text: str) -> list[str]:
    return [m.group(0) for m in LASTING_RE.finditer(text or "")]


def _first_sentence(text: str, limit: int = 160) -> str:
    text = " ".join((text or "").split())
    cut = re.split(r"(?<=[.!?])\s", text, maxsplit=1)[0]
    return cut[:limit]


def capture(reply: str, user_message: str, session_id: str | None = None, source: str = "coach") -> int:
    """Store the reply's proposals, and a miss when the athlete said something
    lasting and got no recordable line back. Never raises; returns rows written."""
    try:
        supabase = get_supabase()
        if not supabase:
            return 0
        written = 0
        proposals = parse_proposed(reply)
        if proposals:
            open_rows = open_captures()
            for p in proposals:
                subject = subject_of(p["line"])
                dupe = False
                for row in open_rows:
                    if row.get("line") == p["line"]:
                        dupe = True
                        break
                    if row.get("kind") == p["kind"] and subject_of(row.get("line", "")) == subject:
                        supabase.table("decision_captures").update({"status": "superseded"}).eq("id", row["id"]).execute()
                if dupe:
                    continue
                supabase.table("decision_captures").insert({
                    "line": p["line"], "kind": p["kind"], "source": source, "status": "proposed",
                    "session_id": session_id or None,
                }).execute()
                written += 1
                log.info("DECISION PROPOSED: %s", p["line"])
        phrases = lasting_phrases(user_message)
        if phrases and not has_recordable_line(reply):
            supabase.table("decision_captures").insert({
                "line": _first_sentence(user_message), "kind": "detector", "source": "detector",
                "status": "missed", "phrase": phrases[0], "reply_excerpt": _first_sentence(reply),
                "session_id": session_id or None,
            }).execute()
            written += 1
            log.info("DECISION MISSED: %r in %r", phrases[0], _first_sentence(user_message))
        return written
    except Exception:
        log.warning("Decision capture failed (migration 009?)", exc_info=True)
        return 0


def open_captures() -> list[dict]:
    """Proposals waiting for an answer, newest first."""
    supabase = get_supabase()
    if not supabase:
        return []
    try:
        rows = (supabase.table("decision_captures")
                .select("id, line, kind, source, status, session_id, proposed_at")
                .eq("status", "proposed").order("proposed_at", desc=True).limit(10).execute()).data or []
    except Exception:
        log.warning("decision_captures could not be read (migration 009?)")
        return []
    for row in rows:
        row["text"] = describe(row.get("line", ""))
    return rows


def apply_line(line: str, prompt: str) -> bool:
    """Record a line through the path that already exists for its kind."""
    kind = kind_of(line)
    if kind == "constraint":
        from constraints import record_decisions  # local: keeps import order flat
        record_decisions(line)
        return True
    if kind == "emphasis":
        from weakpoints import parse_emphasis_next, set_next_emphasis  # local: import order
        body = line.partition(":")[2].strip()
        parsed = parse_emphasis_next("emphasis next: " + body)
        if parsed:
            set_next_emphasis(prompt, parsed["muscle"], parsed.get("note", ""))
            return True
    if kind in ("substitute", "order"):
        # The recorded row is the store (shape.py reads it); only the cache
        # has to forget what it held.
        import shape  # local: keeps import order flat
        shape.invalidate()
        return True
    return False


def answer(row: dict, verdict: str, prompt: str, answer_text: str = "") -> str:
    """record | decline. Applies on record; marks the row either way."""
    supabase = get_supabase()
    line = row.get("line", "")
    applied = False
    if verdict == "record":
        applied = apply_line(line, prompt)
    if supabase and row.get("id"):
        try:
            supabase.table("decision_captures").update({
                "status": "recorded" if verdict == "record" else "declined",
                "answered_at": now_local().isoformat(), "answer_text": answer_text or verdict,
            }).eq("id", row["id"]).execute()
        except Exception:
            log.exception("Could not store the decision answer")
    if verdict == "record":
        if applied:
            return f"Recorded: {describe(line)}."
        return f"I couldn't apply that line ({line}); nothing was recorded."
    return f"Not recorded: {describe(line)}. It stays in the log as declined."


def parse_answer(text: str, proposed_at: str | None = None, now: datetime | None = None) -> str | None:
    """record | decline | None. Bare yes/no count only inside the answer window."""
    text = (text or "").strip()
    verdict = "record" if _RECORD_RE.match(text) else ("decline" if _DECLINE_RE.match(text) else None)
    if verdict is None:
        return None
    if _EXPLICIT_RE.search(text):
        return verdict
    if not proposed_at:
        return None
    try:
        when = datetime.fromisoformat(str(proposed_at).replace("Z", "+00:00"))
    except ValueError:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    now = now or datetime.now(timezone.utc)
    return verdict if now - when <= timedelta(minutes=ANSWER_WINDOW_MINUTES) else None


# ── Sunday report ────────────────────────────────────────────────────────────

def fetch_captures(days: int) -> list[dict] | None:
    """None when the table does not exist yet (migration 009), [] when empty."""
    supabase = get_supabase()
    if not supabase:
        return None
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    try:
        return (supabase.table("decision_captures")
                .select("line, kind, source, status, phrase, reply_excerpt, proposed_at, answered_at")
                .gte("proposed_at", since).order("proposed_at").range(0, 999).execute()).data or []
    except Exception as exc:
        log.warning("decision_captures could not be read: %s", exc)
        return None


def summarise_captures(rows: list[dict]) -> dict:
    proposed = [r for r in rows if r.get("source") != "detector"]
    missed = [r for r in rows if r.get("status") == "missed"]
    by_source: dict = {}
    for r in proposed:
        by_source[r.get("source") or "?"] = by_source.get(r.get("source") or "?", 0) + 1
    answers = []
    for r in proposed:
        if r.get("answered_at") and r.get("proposed_at"):
            try:
                a = datetime.fromisoformat(str(r["answered_at"]).replace("Z", "+00:00"))
                p = datetime.fromisoformat(str(r["proposed_at"]).replace("Z", "+00:00"))
                answers.append((a - p).total_seconds())
            except ValueError:
                pass
    answers.sort()
    median = answers[len(answers) // 2] if answers else None
    return {
        "proposed": len(proposed), "by_source": by_source,
        "recorded": sum(1 for r in proposed if r.get("status") == "recorded"),
        "declined": sum(1 for r in proposed if r.get("status") == "declined"),
        "open": sum(1 for r in proposed if r.get("status") == "proposed"),
        "superseded": sum(1 for r in proposed if r.get("status") == "superseded"),
        "missed": [{"phrase": r.get("phrase"), "said": r.get("line"), "date": str(r.get("proposed_at") or "")[:10],
                    "reply": r.get("reply_excerpt")} for r in missed],
        "median_answer_s": median,
    }


def _duration(seconds: float | None) -> str:
    if seconds is None:
        return "—"
    if seconds < 90:
        return f"{seconds:.0f} s"
    if seconds < 5400:
        return f"{seconds / 60:.0f} min"
    return f"{seconds / 3600:.1f} h"


def format_captures(summary: dict | None, days: int) -> str:
    lines = ["", "## Decisions captured", ""]
    if summary is None:
        lines.append("Not recorded yet (migration 009).")
        return "\n".join(lines)
    src = ", ".join(f"{k} {v}" for k, v in sorted(summary["by_source"].items())) or "none"
    lines.append(f"Proposed **{summary['proposed']}** ({src}) · recorded {summary['recorded']} · "
                 f"declined {summary['declined']} · open {summary['open']} · superseded {summary['superseded']} · "
                 f"median answer {_duration(summary['median_answer_s'])}")
    if summary["missed"]:
        lines.append("")
        lines.append(f"Missed {len(summary['missed'])} — a lasting phrase with no recordable line in the reply:")
        for m in summary["missed"][:8]:
            lines.append(f"- \"{m['said']}\" ({m['date']}; matched \"{m['phrase']}\"). Reply began: \"{m['reply']}\"")
    else:
        lines.append("")
        lines.append(f"Missed 0 in {days} days: every lasting phrase the detector saw got a recordable line back.")
    lines += ["", "Reading it: proposed is how often the coach turned an agreement into a line the athlete "
              "could record with a tap; missed is how often the rule failed. Zero or one miss a block means the "
              "prompt rule is enough; a climbing count is the case for the second-call stage, costed first."]
    return "\n".join(lines)


def to_json(rows: list[dict]) -> str:
    return json.dumps(rows, default=str)
