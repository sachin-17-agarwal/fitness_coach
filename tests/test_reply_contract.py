"""The reply contract: every check on the coach's reply in one fixed order,
with one record of what each did."""

import contextlib
import unittest
try:
    import blockfix  # noqa: F401  pins the block to four weeks for the legacy rules
except ImportError:  # run as tests.test_x (CI), where tests/ is not on sys.path
    from tests import blockfix  # noqa: F401
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
        reply = "*Overhead Cable Extension*\nWorking Set: 20kg x8-12 RPE8 | Rest: 150s\n"
        computed = {"Overhead Cable Extension": "*Overhead Cable Extension*\nWorking Set: 25kg x10-15 RPE8 | Rest: 150s\n"}
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
        self.assertEqual([n for n, _ in STEPS], ["truncation", "numbers", "set_counts", "rest_floor", "plan_follows", "revise_claim",
                                                 "weak_points", "programme_live", "decisions", "captures"])
        self.assertTrue(set(EDITING_STEPS) <= {n for n, _ in STEPS})


class NumbersStepTests(unittest.TestCase):
    """S1: a number the coach states about a lift must be in the context it
    was handed, or one rewrite is asked for."""
    CONTEXT = "Leg Press: 180kg x10 @ RPE 8 on 16 Sep. Standing Calf Raise: 125kg x12 RPE 7."

    def test_claims_outside_the_context_are_found(self):
        from reply_contract import unsupported_numbers
        reply = "Last week you pressed 200kg for 10 reps at RPE 9, so 180kg today is fine."
        self.assertEqual(unsupported_numbers(reply, self.CONTEXT), ["9", "200"])

    def test_context_numbers_small_counts_steps_and_percentages_pass(self):
        from reply_contract import unsupported_numbers
        reply = ("Your 180kg x10 at RPE 8 on 16 Sep was 3 reps clear; add 2.5kg next week — about 5% up. "
                 "Rest 120 seconds, 3 sets.")
        self.assertEqual(unsupported_numbers(reply, self.CONTEXT), [])

    def test_block_and_card_lines_are_the_programmes_numbers(self):
        from reply_contract import unsupported_numbers
        reply = ("Working Set: 190kg x8-10 RPE 8\nBack-off: 150kg x10-12 RPE 7\n"
                 "Card: Back-off 2: 155kg (from 150kg).\nKeep the tempo.")
        self.assertEqual(unsupported_numbers(reply, self.CONTEXT), [])

    def _ctx(self, reply, rewrite, kind="prose"):
        from reply_contract import ReplyContext
        return ReplyContext(reply=reply, reply_kind=kind, system_prompt="", today_type="Legs",
                            context_text=self.CONTEXT, rewrite=rewrite)

    def test_one_rewrite_is_asked_for_and_recorded(self):
        from reply_contract import numbers
        calls = []
        def rewrite(reply, bad):
            calls.append(bad)
            return "Your last logged press was 180kg x10 at RPE 8; hold it today."
        ctx = self._ctx("Last week you pressed 200kg at RPE 9.", rewrite)
        numbers(ctx)
        self.assertEqual(calls, [["9", "200"]])
        self.assertTrue(ctx.reply.startswith("Your last logged press was 180kg"))
        self.assertEqual([(r["step"], r["action"]) for r in ctx.record], [("numbers", "rewritten")])

    def test_a_rewrite_that_still_invents_is_kept_and_flagged(self):
        from reply_contract import numbers
        ctx = self._ctx("You pressed 200kg.", lambda r, b: "You pressed 210kg then.")
        numbers(ctx)
        self.assertEqual(ctx.reply, "You pressed 210kg then.")
        self.assertEqual(ctx.record[0]["action"], "rewritten_still_unsupported")
        self.assertEqual(ctx.record[0]["detail"], "210")

    def test_no_rewrite_available_logs_only(self):
        from reply_contract import numbers
        ctx = self._ctx("You pressed 200kg.", None)
        numbers(ctx)
        self.assertEqual(ctx.reply, "You pressed 200kg.")
        self.assertEqual(ctx.record[0]["action"], "logged")

    def test_plan_replies_are_logged_not_rewritten(self):
        from reply_contract import numbers
        ctx = self._ctx("Why: you pressed 200kg last week.\nWorking Set: 180kg x10 RPE 8", lambda r, b: "changed", kind="plan")
        numbers(ctx)
        self.assertTrue(ctx.reply.startswith("Why:"))
        self.assertEqual(ctx.record[0]["action"], "logged")

    def test_set_replies_are_code_rendered_and_skipped(self):
        from reply_contract import numbers
        ctx = self._ctx("Card: 200kg.", lambda r, b: "changed", kind="set_reply")
        numbers(ctx)
        self.assertEqual(ctx.reply, "Card: 200kg.")
        self.assertEqual(ctx.record, [])

    def test_off_switch(self):
        from types import SimpleNamespace
        import reply_contract
        ctx = self._ctx("You pressed 200kg.", lambda r, b: "changed")
        with patch.object(reply_contract, "get_settings", return_value=SimpleNamespace(numbers_contract=False)):
            reply_contract.numbers(ctx)
        self.assertEqual(ctx.reply, "You pressed 200kg.")


class NumbersStepReviewFixes(unittest.TestCase):
    CONTEXT = "Leg Press: 180kg x10 @ RPE 8 on 16 Sep; last week 160kg x10."

    def test_a_rewrite_that_drops_a_protected_line_is_refused(self):
        from reply_contract import ReplyContext, numbers
        original = ("Last week you pressed 200kg.\nRevising: Leg Press\nWorking Set: 180kg x8 RPE 8\n"
                    "Proposed: Decision: Leg Press | max load 180kg | knee")
        ctx = ReplyContext(reply=original, reply_kind="prose", system_prompt="", today_type="Legs",
                           context_text=self.CONTEXT,
                           rewrite=lambda r, b: "Your last press was 180kg x10.\nWorking Set: 180kg x8 RPE 8")
        numbers(ctx)
        self.assertEqual(ctx.reply, original)
        self.assertEqual(ctx.record[0]["action"], "rewrite_refused")

    def test_differences_of_context_loads_and_relative_reps_are_arithmetic(self):
        from reply_contract import unsupported_numbers
        self.assertEqual(unsupported_numbers("That's 20kg more than last week with 6 reps in hand, 3 reps clear.",
                                             self.CONTEXT), [])
        self.assertEqual(unsupported_numbers("You did 6 reps at 200kg.", self.CONTEXT), ["6", "200"])

    def test_drift_is_read_after_every_edit(self):
        from reply_contract import STEPS
        names = [n for n, _ in STEPS]
        self.assertNotIn("set_count_drift", names)
        self.assertLess(names.index("set_counts"), names.index("programme_live"))
