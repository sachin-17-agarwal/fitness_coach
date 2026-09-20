"""The reply contract: every check the coach's reply passes through, in one
place, in one fixed order, with one record of what each did.

Until 20 Sep 2026 these were seven guards in chat_with_coach, each added
after an incident, each in its own try/except, run in the order they were
written. When one changed the reply the next saw a different text, and
nothing said which had acted. This module is that pipeline made explicit.

Steps, in order. Only the ones marked EDITS may rebind the reply.

  truncation      the model hit its token ceiling: logged, cannot be repaired
  set_counts      EDITS  surplus sets trimmed, a shortfall filled from the
                          block's own last set (coach_parsing.enforce_set_counts)
  plan_follows           a block for a lift in today's plan becomes the plan
                          in force (plan.record_plan_update)
  revise_claim    EDITS  "Revising:" with no block gets the card's standing
                          numbers appended (plan.missing_revision_note)
  weak_points     EDITS  the weak-point lifts' blocks are the programme's
                          computation, whatever the coach wrote
  programme_live  EDITS  behind PROGRAMME_SUBSTITUTION: every computed block
                          replaces the coach's
  set_count_drift        what is still off-template after the edits, logged
  decisions              `Decision:` lines become standing constraints
  captures               `Proposed:` lines are held for the athlete

A step that raises is logged and skipped; the reply always reaches the
athlete. The rule for adding to this file: a new check goes in as a step
here, and one comes out or is folded in.
"""

from __future__ import annotations

import logging
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
    record: list = field(default_factory=list)

    def note(self, step: str, action: str, detail: str = "") -> None:
        self.record.append({"step": step, "action": action, "detail": detail})


def _norm(name: str) -> str:
    return "".join(ch for ch in (name or "").lower() if ch.isalnum())


# ── Steps ────────────────────────────────────────────────────────────────────

def truncation(ctx: ReplyContext) -> None:
    if ctx.truncated:
        log.warning("Coach reply hit max_tokens — prescription may be truncated (%d chars)", len(ctx.reply))
        ctx.note("truncation", "logged", f"{len(ctx.reply)} chars")


def set_counts(ctx: ReplyContext) -> None:
    ctx.reply, fixes = enforce_set_counts(ctx.reply, ctx.system_prompt, ctx.today_type)
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


def set_count_drift(ctx: ReplyContext) -> None:
    counts = check_set_counts(ctx.reply, ctx.system_prompt, ctx.today_type)
    for bad in counts["mismatches"]:
        log.warning("SET COUNT DRIFT (%s): %s prescribed %d working sets, template says %d, and the reply "
                    "gives no reason", ctx.today_type, bad["exercise"], bad["actual"], bad["expected"])
        ctx.note("set_count_drift", "logged", f"{bad['exercise']} {bad['actual']} vs {bad['expected']}")
    for chosen in counts["deliberate"]:
        log.info("Set count deviated deliberately (%s): %s prescribed %d against a template of %d, marked Revised:",
                 ctx.today_type, chosen["exercise"], chosen["actual"], chosen["expected"])
    if counts["unmatched"]:
        log.info("Set-count check skipped %d block(s) with no template entry: %s",
                 len(counts["unmatched"]), ", ".join(counts["unmatched"]))


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
    ("set_counts", set_counts),
    ("plan_follows", plan_follows),
    ("revise_claim", revise_claim),
    ("weak_points", weak_points),
    ("programme_live", programme_live),
    ("set_count_drift", set_count_drift),
    ("decisions", decisions),
    ("captures", captures),
)
EDITING_STEPS = ("set_counts", "revise_claim", "weak_points", "programme_live")


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
