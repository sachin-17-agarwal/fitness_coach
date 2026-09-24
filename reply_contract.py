"""The reply contract: every check the coach's reply passes through, in one
place, in one fixed order, with one record of what each did.

Until 20 Sep 2026 these were seven guards in chat_with_coach, each added
after an incident, each in its own try/except, run in the order they were
written. When one changed the reply the next saw a different text, and
nothing said which had acted. This module is that pipeline made explicit.

Steps, in order. Only the ones marked EDITS may rebind the reply.

  truncation      the model hit its token ceiling: logged, cannot be repaired
  numbers         EDITS  a number the reply states about a lift (kg, reps,
                          RPE, a date) that the context handed to the coach
                          does not carry: one rewrite is asked for, using
                          only the context's numbers
  set_counts      EDITS  surplus sets trimmed, a shortfall filled from the
                          block's own last set (coach_parsing.enforce_set_counts)
  plan_follows           a block for a lift in today's plan becomes the plan
                          in force (plan.record_plan_update)
  revise_claim    EDITS  "Revising:" with no block gets the card's standing
                          numbers appended (plan.missing_revision_note)
  weak_points     EDITS  the weak-point lifts' blocks are the programme's
                          computation, whatever the coach wrote
  programme_live  EDITS  behind PROGRAMME_SUBSTITUTION: every computed block
                          replaces the coach's; then what is still
                          off-template after every edit, logged
  decisions              `Decision:` lines become standing constraints
  captures               `Proposed:` lines are held for the athlete

A step that raises is logged and skipped; the reply always reaches the
athlete. The rule for adding to this file: a new check goes in as a step
here, and one comes out or is folded in.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Callable
from dataclasses import dataclass, field

from coach_parsing import (check_set_counts, enforce_set_counts, parse_all_prescriptions,
                           substitute_computed_blocks)
from settings import get_settings

log = logging.getLogger(__name__)


@dataclass
class ReplyContext:
    reply: str
    reply_kind: str                      # plan | set_reply | prose
    system_prompt: str
    today_type: str
    programme_out: dict = field(default_factory=dict)
    set_log_session: str | None = None
    memory: dict = field(default_factory=dict)
    user_message: str = ""
    truncated: bool = False
    card_exercise: str = ""
    card_stored: dict | None = None
    # Everything the coach was handed, as text: the context blocks and the
    # conversation. A number about a lift that is not in it was made up.
    context_text: str = ""
    # (reply, unsupported numbers) -> a rewrite, or None. coach.py supplies
    # the model call; tests supply a function.
    rewrite: Callable[[str, list[str]], str | None] | None = None
    record: list = field(default_factory=list)

    def note(self, step: str, action: str, detail: str = "") -> None:
        self.record.append({"step": step, "action": action, "detail": detail})


def _week(ctx: ReplyContext) -> int | None:
    try:
        return int((ctx.memory or {}).get("mesocycle_week") or 0) or None
    except (TypeError, ValueError):
        return None


def _norm(name: str) -> str:
    return "".join(ch for ch in (name or "").lower() if ch.isalnum())


# ── Steps ────────────────────────────────────────────────────────────────────

# ── numbers ─────────────────────────────────────────────────────────────────
# The block review has had this rule since 19 Sep (block_review.numbers_not_in
# _sheet). The in-session coach did not, and it argued from loads and reps the
# context never showed it. Only numbers that read as a claim about a lift are
# checked — a load in kg, a rep count, an RPE, a day of a month — so a
# percentage, a set count or a rest time is left alone. The lines the card
# reads (Warm-up / Working Set / Back-off) and the code-written "Card:"
# sentence are the programme's numbers, checked elsewhere, and are skipped.
_CLAIM_RE = re.compile(
    r"(?P<kg>\d+(?:\.\d+)?)\s*(?:kg|kgs|kilos?)\b"
    r"|\bx\s*(?P<x>\d+)\b"
    r"|\b(?P<reps>\d+)\s*reps?\b"
    r"|\bRPE\s*(?P<rpe>\d+(?:\.\d+)?)\b"
    r"|@\s*(?P<at>\d+(?:\.\d+)?)\b"
    r"|\b(?P<day>\d{1,2})\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\b",
    re.IGNORECASE)
# Letters may touch the number ("x10", "RPE8"): the context writes them so.
_ANY_NUM_RE = re.compile(r"(?<![\d.])\d+(?:\.\d+)?(?!\.?\d)")
_BLOCK_LINE_RE = re.compile(r"(?i)^\s*(?:\*\*)?(?:warm-?up|ramp|working set|back-?off|top set)s?\b.*:|^\s*Card:")
# Lines the rest of the contract reads: a rewrite that loses one is refused.
_KEEP_LINE_RE = re.compile(r"(?i)^\s*(?:\*\*)?(?:warm-?up|ramp|working set|back-?off|top set)s?\b.*:"
                           r"|^\s*(?:Card|Revising|Revised|Decision|Proposed|Emphasis-next|Substitute|Order):")
# A rep count said relative to the target is arithmetic, not history:
# "6 reps in hand", "3 reps clear", "two more reps".
_RELATIVE_REPS_RE = re.compile(r"(?i)\b\d+\s*reps?\s+(?:in hand|in reserve|in the tank|to spare|clear|short|"
                               r"left|more|fewer|less|over|under|up|down)\b|\bRIR\b")
# Loads the programme itself moves by; "add 2.5kg" is arithmetic, not history.
_PROGRAMME_STEPS = {"1", "1.25", "2.5", "5"}


def _num_key(text: str) -> str:
    try:
        return f"{float(text):g}"
    except ValueError:
        return text


def unsupported_numbers(reply: str, context_text: str) -> list[str]:
    """Every number the reply states as a claim about a lift that the
    context does not carry, as written in the reply."""
    have = {_num_key(n) for n in _ANY_NUM_RE.findall(context_text or "")}
    # A difference between two context loads ("20kg more than last week")
    # is the coach's arithmetic on numbers it was shown, not a new claim.
    loads = sorted({float(k) for k in have if k.replace(".", "", 1).isdigit()})[-200:]
    derived = {_num_key(str(round(b - a, 3))) for i, a in enumerate(loads) for b in loads[i + 1:]}
    bad = []
    for line in (reply or "").splitlines():
        if _BLOCK_LINE_RE.match(line):
            continue
        line = _RELATIVE_REPS_RE.sub(" ", line)
        for m in _CLAIM_RE.finditer(line):
            n = next(v for v in m.groupdict().values() if v is not None)
            key = _num_key(n)
            if key in have or key in _PROGRAMME_STEPS or (m.group("kg") and key in derived):
                continue
            try:
                if 0 <= float(n) <= 4 and float(n).is_integer():
                    continue
            except ValueError:
                pass
            bad.append(n)
    return sorted(set(bad), key=lambda n: float(n))


def numbers(ctx: ReplyContext) -> None:
    if ctx.reply_kind == "set_reply" or not get_settings().numbers_contract or not ctx.context_text:
        return
    bad = unsupported_numbers(ctx.reply, ctx.context_text)
    if not bad:
        return
    log.warning("NUMBERS NOT IN CONTEXT (%s): %s", ctx.reply_kind, ", ".join(bad))
    # A plan reply is rendered by code around the model's reasons; a prose
    # rewrite of it could disturb the blocks the card reads. Logged only.
    if ctx.rewrite is None or ctx.reply_kind != "prose":
        ctx.note("numbers", "logged", ", ".join(bad))
        return
    rewritten = ctx.rewrite(ctx.reply, bad)
    if not rewritten or not rewritten.strip():
        ctx.note("numbers", "logged", ", ".join(bad))
        return
    # The steps after this one read block, Revising and recordable lines. A
    # rewrite that lost one would lose a decision or turn a revision into a
    # re-send silently; it is refused and the original goes on.
    kept = {l.strip() for l in rewritten.splitlines()}
    lost = [l.strip() for l in ctx.reply.splitlines() if _KEEP_LINE_RE.match(l) and l.strip() not in kept]
    if lost:
        log.warning("NUMBERS rewrite dropped %d protected line(s); original kept: %s", len(lost), lost[0][:80])
        ctx.note("numbers", "rewrite_refused", ", ".join(bad))
        return
    still = unsupported_numbers(rewritten, ctx.context_text)
    ctx.reply = rewritten
    if still:
        log.warning("NUMBERS NOT IN CONTEXT after rewrite (%s): %s", ctx.reply_kind, ", ".join(still))
        ctx.note("numbers", "rewritten_still_unsupported", ", ".join(still))
    else:
        ctx.note("numbers", "rewritten", ", ".join(bad))


def truncation(ctx: ReplyContext) -> None:
    if ctx.truncated:
        log.warning("Coach reply hit max_tokens — prescription may be truncated (%d chars)", len(ctx.reply))
        ctx.note("truncation", "logged", f"{len(ctx.reply)} chars")


def set_counts(ctx: ReplyContext) -> None:
    ctx.reply, fixes = enforce_set_counts(ctx.reply, ctx.system_prompt, ctx.today_type, _week(ctx))
    for fix in fixes:
        if fix.get("added"):
            log.warning("SET COUNT FILLED (%s): %s had %d %s set(s) too few against a template of %d — "
                        "last set repeated before sending", ctx.today_type, fix["exercise"], fix["added"],
                        fix["phase"], fix["target"])
            ctx.note("set_counts", "filled", f"{fix['exercise']} +{fix['added']} {fix['phase']}")
        else:
            log.warning("SET COUNT TRIMMED (%s): %s had %d surplus %s set(s) against a template of %d — "
                        "removed before sending", ctx.today_type, fix["exercise"], fix["dropped"],
                        fix["phase"], fix["target"])
            ctx.note("set_counts", "trimmed", f"{fix['exercise']} -{fix['dropped']} {fix['phase']}")


def _log_drift(ctx: ReplyContext) -> None:
    """What is still off-template once every editing step has run. Once its
    own step after programme_live; folded on 23 Sep 2026 when the numbers
    step came in (one in, one out) and kept at the same point in the order."""
    counts = check_set_counts(ctx.reply, ctx.system_prompt, ctx.today_type, _week(ctx))
    for bad in counts["mismatches"]:
        log.warning("SET COUNT DRIFT (%s): %s prescribed %d working sets, template says %d, and the reply "
                    "gives no reason", ctx.today_type, bad["exercise"], bad["actual"], bad["expected"])
        ctx.note("programme_live", "drift", f"{bad['exercise']} {bad['actual']} vs {bad['expected']}")
    for chosen in counts["deliberate"]:
        log.info("Set count deviated deliberately (%s): %s prescribed %d against a template of %d, marked Revised:",
                 ctx.today_type, chosen["exercise"], chosen["actual"], chosen["expected"])
    if counts["unmatched"]:
        log.info("Set-count check skipped %d block(s) with no template entry: %s",
                 len(counts["unmatched"]), ", ".join(counts["unmatched"]))


def plan_follows(ctx: ReplyContext) -> None:
    """A prose reply carrying a block for a lift in today's plan — a Revised:
    block, or a re-sent block with new numbers — replaces the card, and the
    stored plan follows it so the next set reply computes from the screen."""
    if ctx.reply_kind != "prose" or not ctx.set_log_session:
        return
    from plan import block_differs, load_today_plan, plan_from_block, record_plan_update  # local
    week = ctx.memory.get("mesocycle_week", 1)
    try:
        week = int(week)
    except (TypeError, ValueError):
        week = 1
    for block in parse_all_prescriptions(ctx.reply):
        stored = load_today_plan(block.get("exercise") or "")
        if stored and (block.get("working") or block.get("backoff")) and block_differs(block, stored):
            record_plan_update(plan_from_block(block, stored), ctx.today_type, week,
                               reason="mid-session block" + (" (Revised)" if block.get("revised") else ""),
                               session_id=ctx.set_log_session)
            ctx.note("plan_follows", "stored", block.get("exercise") or "")


def revise_claim(ctx: ReplyContext) -> None:
    if ctx.reply_kind != "prose" or not ctx.set_log_session:
        return
    from plan import missing_revision_note  # local: import order
    note = missing_revision_note(ctx.reply, parse_all_prescriptions(ctx.reply), ctx.card_exercise, ctx.card_stored)
    if note:
        ctx.reply = ctx.reply.rstrip() + "\n\n" + note
        log.warning("REVISE CLAIM WITHOUT BLOCK (%s): note appended", ctx.card_exercise)
        ctx.note("revise_claim", "appended", ctx.card_exercise)


def weak_points(ctx: ReplyContext) -> None:
    """The weak-point lifts are computed by the programme from their own
    history (3 straight sets, reps 10-15, the wave and recovery applied); the
    coach's block for them is replaced whether or not the general switch is
    on. A Revised: block and a lift already on the board today stay the
    coach's, as everywhere else."""
    if ctx.reply_kind == "set_reply":
        return
    out = ctx.programme_out or {}
    wp = out.get("weak_point_exercises") or []
    computed = {name: block for name, block in (out.get("computed") or {}).items()
                if any(_norm(name) == _norm(e) for e in wp)}
    if not computed:
        return
    replaced, swapped = substitute_computed_blocks(ctx.reply, computed, aliases=out.get("aliases"),
                                                   skip=out.get("logged_today") or ())
    if swapped:
        ctx.reply = replaced
        log.warning("WEAK-POINT BLOCK COMPUTED (%s wk%s): %s", out.get("session_type"), out.get("week"),
                    ", ".join(swapped))
        ctx.note("weak_points", "substituted", ", ".join(swapped))


def programme_live(ctx: ReplyContext) -> None:
    """Behind PROGRAMME_SUBSTITUTION: the coach keeps its prose, cues and
    tempo; the Warm-up / Working Set / Back-off lines become the programme's."""
    try:
        _substitute(ctx)
    finally:
        _log_drift(ctx)


def _substitute(ctx: ReplyContext) -> None:
    if not get_settings().programme_substitution:
        return
    out = ctx.programme_out or {}
    computed = out.get("computed") or {}
    if not computed:
        return
    substituted, swapped = substitute_computed_blocks(ctx.reply, computed, aliases=out.get("aliases"),
                                                      skip=out.get("logged_today") or ())
    if swapped:
        ctx.reply = substituted
        log.warning("PROGRAMME LIVE (%s wk%s): substituted %s", out.get("session_type"), out.get("week"),
                    ", ".join(swapped))
        ctx.note("programme_live", "substituted", ", ".join(swapped))


def decisions(ctx: ReplyContext) -> None:
    from constraints import record_decisions  # local: keeps import order flat
    written = record_decisions(ctx.reply)
    if written:
        ctx.note("decisions", "recorded", str(written))


def captures(ctx: ReplyContext) -> None:
    from decisions import capture  # local: keeps import order flat
    from workout import get_workout_state  # local: keeps import order flat
    written = capture(ctx.reply, ctx.user_message, (get_workout_state() or {}).get("current_session_id") or None)
    if written:
        ctx.note("captures", "captured", str(written))


STEPS = (
    ("truncation", truncation),
    ("numbers", numbers),
    ("set_counts", set_counts),
    ("plan_follows", plan_follows),
    ("revise_claim", revise_claim),
    ("weak_points", weak_points),
    ("programme_live", programme_live),
    ("decisions", decisions),
    ("captures", captures),
)
EDITING_STEPS = ("numbers", "set_counts", "revise_claim", "weak_points", "programme_live")


def apply_contract(ctx: ReplyContext) -> str:
    """Run every step in order; return the reply the athlete gets."""
    for name, step in STEPS:
        before = ctx.reply
        try:
            step(ctx)
        except Exception:
            log.exception("Reply contract step %s failed; reply left as it was", name)
            ctx.reply = before
            ctx.note(name, "failed")
            continue
        if ctx.reply != before and name not in EDITING_STEPS:
            # A read-only step changed the reply: the contract's own rule broken.
            log.error("Reply contract step %s is not allowed to edit the reply; change reverted", name)
            ctx.reply = before
            ctx.note(name, "reverted")
    acted = [f"{r['step']}:{r['action']}" + (f"({r['detail']})" if r["detail"] else "") for r in ctx.record]
    if acted:
        log.info("REPLY CONTRACT (%s, %s): %s", ctx.reply_kind, ctx.today_type, "; ".join(acted))
    return ctx.reply
