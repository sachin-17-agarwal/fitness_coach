"""The reply contract: every check on the coach's reply in one fixed order,
with one record of what each did."""

import contextlib
import unittest
from unittest.mock import patch

from reply_contract import EDITING_STEPS, ReplyContext, STEPS, apply_contract


def _prompt():
    with open("system_prompt.txt") as handle:
        return handle.read()


@contextlib.contextmanager
def _quiet():
    with patch("constraints.record_decisions", return_value=0), patch("decisions.capture", return_value=0), \
         patch("workout.get_workout_state", return_value={}):
        yield


class ContractTests(unittest.TestCase):

    def test_a_plain_reply_passes_untouched_with_an_empty_record(self):
        ctx = ReplyContext(reply="Good set. Rest 90 seconds.", reply_kind="prose", system_prompt=_prompt(), today_type="Pull")
        with _quiet():
            self.assertEqual(apply_contract(ctx), "Good set. Rest 90 seconds.")
        self.assertEqual(ctx.record, [])

    def test_surplus_sets_are_trimmed_and_recorded(self):
        reply = ("*Reverse Cable Fly*\n"
                 "Working Set: 12.5kg x8-12 RPE8 | Rest: 90s\n"
                 "Back-off: 10kg x12-15 RPE7, 10kg x12-15 RPE7, 10kg x12-15 RPE7\n")
        ctx = ReplyContext(reply=reply, reply_kind="plan", system_prompt=_prompt(), today_type="Pull")
        with _quiet():
            out = apply_contract(ctx)
        self.assertNotEqual(out, reply)
        self.assertEqual([r for r in ctx.record if r["step"] == "set_counts"][0]["action"], "trimmed")

    def test_a_revise_claim_without_a_block_gets_the_card_line_only_mid_session(self):
        stored = {"working": [{"weight": 12.0, "reps_low": 7, "reps_high": 11, "rpe": 6}], "backoff": [], "sets": 3}
        base = dict(reply="You're right. Revising:\n\nGood catch.", reply_kind="prose", system_prompt="", today_type="Pull",
                    card_exercise="Reverse Cable Fly", card_stored=stored)
        with _quiet(), patch("plan.load_today_plan", return_value=None):
            out = apply_contract(ReplyContext(**base, set_log_session="s1"))
            self.assertIn("No revised block came through", out)
            out = apply_contract(ReplyContext(**base))            # not in a session: nothing owed
            self.assertNotIn("No revised block", out)

    def test_the_weak_point_lifts_take_the_programmes_block_whatever_the_switch(self):
        import os
        os.environ.pop("PROGRAMME_SUBSTITUTION", None)
        reply = "*Overhead Cable Extension*\nWorking Set: 20kg x8-12 RPE8 | Rest: 90s\n"
        computed = {"Overhead Cable Extension": "*Overhead Cable Extension*\nWorking Set: 25kg x10-15 RPE8 | Rest: 90s\n"}
        ctx = ReplyContext(reply=reply, reply_kind="prose", system_prompt="", today_type="Cardio+Abs",
                           programme_out={"computed": computed, "weak_point_exercises": ["Overhead Cable Extension"]})
        with _quiet():
            out = apply_contract(ctx)
        self.assertIn("25kg", out)
        self.assertEqual([r["step"] for r in ctx.record if r["action"] == "substituted"], ["weak_points"])
        # A set reply keeps the coach's block: the athlete is mid-lift.
        ctx = ReplyContext(reply=reply, reply_kind="set_reply", system_prompt="", today_type="Cardio+Abs",
                           programme_out={"computed": computed, "weak_point_exercises": ["Overhead Cable Extension"]})
        with _quiet():
            self.assertEqual(apply_contract(ctx), reply)

    def test_a_failing_step_is_skipped_and_the_rest_still_run(self):
        ctx = ReplyContext(reply="Decision: Cable Crunch | clear", reply_kind="prose", system_prompt="", today_type="Pull")
        with patch("constraints.record_decisions", side_effect=RuntimeError("db down")), \
             patch("decisions.capture", return_value=0), patch("workout.get_workout_state", return_value={}):
            out = apply_contract(ctx)
        self.assertEqual(out, "Decision: Cable Crunch | clear")
        self.assertIn(("decisions", "failed"), [(r["step"], r["action"]) for r in ctx.record])

    def test_the_order_and_the_editing_set_are_fixed(self):
        self.assertEqual([n for n, _ in STEPS], ["truncation", "set_counts", "plan_follows", "revise_claim",
                                                 "weak_points", "programme_live", "set_count_drift", "decisions", "captures"])
        self.assertTrue(set(EDITING_STEPS) <= {n for n, _ in STEPS})
