"""Defects found reviewing the computed-prescription rebuild, each pinned.

Every test here failed against the rebuild as submitted and passes after the
fix. They are grouped by where the defect lived, not by severity.
"""

import unittest

import prescribe
import programme
from coach_parsing import parse_all_prescriptions, substitute_computed_blocks
from prescribe import COMPOUND, PriorSet, next_top_set, prescribe_session


def _prompt():
    with open("system_prompt.txt") as handle:
        return handle.read()


class BodyweightPriorTests(unittest.TestCase):
    """progression writes a bodyweight set's load as the string "BW"."""

    PULL = [{"exercise": "Pull-Ups", "load": "BW", "reps": 11, "rpe": 8.0, "date": "2026-09-01"},
            {"exercise": "Cable Row", "load": 80.0, "reps": 8, "rpe": 8.0, "date": "2026-09-01"}]

    def test_a_bodyweight_prior_no_longer_takes_the_whole_session_down(self):
        props, _, _ = programme.build_proposal(_prompt(), "Pull", 2, self.PULL)
        self.assertEqual(len(props), 7, "every Pull exercise gets a proposal")
        row = next(p for p in props if p.exercise == "Cable Row")
        self.assertEqual(row.working[0].weight_kg, 80.0)

    def test_pull_ups_above_the_range_progress_by_adding_load(self):
        """:274 — once he clears the top at the target RPE, BW + 2.5kg with
        reps reset to the bottom."""
        props, _, _ = programme.build_proposal(_prompt(), "Pull", 2, self.PULL)
        pull = next(p for p in props if p.exercise == "Pull-Ups")
        top = pull.working[0]
        self.assertTrue(top.bodyweight)
        self.assertEqual(top.weight_kg, 2.5)
        self.assertEqual((top.reps_low, top.reps_high), (6, 10), "the band, floor at the bottom")
        self.assertTrue(prescribe.is_determined(pull))

    def test_dips_are_bodyweight_too(self):
        self.assertTrue(prescribe.is_bodyweight("Dips"))
        self.assertTrue(prescribe.is_bodyweight("Hanging Leg Raise"))
        self.assertFalse(prescribe.is_bodyweight("Assisted Dip Machine"))
        self.assertFalse(prescribe.is_bodyweight("Leg Press"))

    def test_the_rendered_block_reads_back_as_the_added_load(self):
        """`BW + 2.5kg x6` is the prompt's spelling; both parsers read it as
        2.5kg, which is also what the log stores for a weighted pull-up."""
        props, _, _ = programme.build_proposal(_prompt(), "Pull", 2, self.PULL)
        pull = next(p for p in props if p.exercise == "Pull-Ups")
        block = prescribe.render_block(pull)
        self.assertIn("BW + 2.5kg x6-10 RPE8", block)
        card = parse_all_prescriptions(block)[0]
        self.assertEqual(card["working"][0]["weight"], 2.5)
        self.assertIn("BW x5", block, "the ramp set is at bodyweight")
        self.assertIn("Back-off: BW x10-12", block, "the back-off sheds the plate entirely")

    def test_a_bodyweight_deload_cannot_drop_a_load_it_does_not_have(self):
        reasons, deferred = [], []
        spec = next_top_set("Pull-Ups", COMPOUND, 4,
                            PriorSet(None, 6, 9.0, week=3, bodyweight=True),
                            reasons, deferred)
        self.assertEqual(spec.reps_low, prescribe.DELOAD_MIN_REPS)
        self.assertTrue(any("not available at bodyweight" in d for d in deferred))


class MalformedHistoryTests(unittest.TestCase):
    def test_junk_in_a_history_row_costs_that_exercise_not_the_session(self):
        rows = [{"exercise": "Cable Row", "load": "abc", "reps": "x", "rpe": "y"},
                {"exercise": "Lat Pulldown", "load": 70.0, "reps": 8, "rpe": 8.0}]
        props, _, _ = programme.build_proposal(_prompt(), "Pull", 2, rows)
        self.assertEqual(len(props), 7)
        by = {p.exercise: p for p in props}
        self.assertFalse(prescribe.is_determined(by["Cable Row"]))
        self.assertEqual(by["Lat Pulldown"].working[0].weight_kg, 70.0)

    def test_a_tiny_load_still_gets_a_real_back_off(self):
        from prescribe import SetSpec, backoff_sets
        [b] = backoff_sets(SetSpec(1.0, 8, 8, 8.0), COMPOUND, 1, 1, [])
        self.assertLess(b.weight_kg, 1.0)


class WarmupRampTests(unittest.TestCase):
    """The ramp read the primary muscle from a seven-entry Pull table."""

    PUSH = [{"exercise": n, "load": l, "reps": 8, "rpe": 8.0} for n, l in (
        ("Machine Chest Press", 100.0), ("Incline Press", 60.0), ("Cable Chest Fly", 30.0),
        ("Machine Shoulder Press", 60.0), ("Cable Lateral Raise", 12.0),
        ("Face Pulls", 20.0), ("Tricep Pushdown", 40.0))]

    def test_a_warm_chest_gets_no_ramp_on_the_fourth_pressing_movement(self):
        props, _, _ = programme.build_proposal(_prompt(), "Push", 2, self.PUSH)
        by = {p.exercise: p for p in props}
        self.assertEqual(len(by["Machine Chest Press"].warmup), 3, "first, heavy")
        self.assertEqual(len(by["Incline Press"].warmup), 0, "chest is warm")
        self.assertEqual(len(by["Cable Chest Fly"].warmup), 0)
        self.assertEqual(len(by["Machine Shoulder Press"].warmup), 0,
                         ":131 — shoulders are warm from pressing")
        self.assertEqual(len(by["Tricep Pushdown"].warmup), 0)

    def test_the_first_movement_for_a_cold_muscle_still_ramps(self):
        props, _, _ = programme.build_proposal(_prompt(), "Push", 2, self.PUSH)
        by = {p.exercise: p for p in props}
        self.assertEqual(len(by["Face Pulls"].warmup), 1, "rear delts are cold")


class WeekTwoBacklogTests(unittest.TestCase):
    def test_reps_above_the_range_move_the_load_in_week_two_whatever_the_rpe(self):
        """:205 — 12 reps on a 6-10 range is an overdue increase, not a cue to
        'add reps toward the top'. The generic branch said so; week 2 returned
        before reaching it."""
        reasons = []
        spec = next_top_set("Cable Row", COMPOUND, 2, PriorSet(80.0, 12, 9.0), reasons, [])
        self.assertEqual(spec.weight_kg, 82.5)
        self.assertEqual((spec.reps_low, spec.reps_high), (6, 10))
        self.assertTrue(any("OVERDUE" in r for r in reasons))

    def test_week_two_at_the_top_of_the_range_over_target_still_adds_reps(self):
        """Exactly AT the top at RPE 9 is not a backlog: :182 wants RPE <= 8."""
        spec = next_top_set("Cable Row", COMPOUND, 2, PriorSet(80.0, 10, 9.0), [], [])
        self.assertEqual(spec.weight_kg, 80.0)


class PeakWeekAnchorTests(unittest.TestCase):
    """Weeks 1 and 4 anchor to the WEEK 3 set, not the most recent one."""

    PLAN = (("Cable Row", 2, COMPOUND),)
    RECENT = {"Cable Row": PriorSet(80.0, 8, 7.0, week=4)}     # the deload
    PEAK = {"Cable Row": PriorSet(80.0, 10, 9.0, week=3)}

    def test_week_one_opens_from_the_peak_week_not_the_deload(self):
        [p] = prescribe_session(self.PLAN, 1, self.RECENT, peak_history=self.PEAK)
        self.assertEqual(p.working[0].weight_kg, 82.5,
                         "week 3 finished at the top of the range, so week 1 opens up")
        self.assertFalse(any("week 4 session" in d for d in p.deferred))

    def test_week_four_deloads_against_the_peak_week(self):
        recent = {"Cable Row": PriorSet(80.0, 7, 7.5, week=None)}
        [p] = prescribe_session(self.PLAN, 4, recent, peak_history=self.PEAK)
        self.assertEqual((p.working[0].weight_kg, p.working[0].reps_low), (80.0, 8),
                         "10 reps at RPE 9 minus two points is 8 reps")

    def test_weeks_two_and_three_still_read_the_most_recent_session(self):
        [p] = prescribe_session(self.PLAN, 2, {"Cable Row": PriorSet(82.5, 6, 8.0)},
                                peak_history=self.PEAK)
        self.assertEqual(p.working[0].weight_kg, 82.5)

    def test_without_a_peak_week_the_most_recent_session_is_used_and_flagged(self):
        [p] = prescribe_session(self.PLAN, 1, self.RECENT)
        self.assertTrue(any("week 4 session" in d for d in p.deferred))

    def test_build_proposal_wires_the_peak_week_loads_through(self):
        recent = [{"exercise": "Cable Row", "load": 80.0, "reps": 8, "rpe": 7.0}]
        peak = [{"exercise": "Cable Row", "load": 80.0, "reps": 10, "rpe": 9.0}]
        props, _, _ = programme.build_proposal(_prompt(), "Pull", 1, recent, peak_week_loads=peak)
        row = next(p for p in props if p.exercise == "Cable Row")
        self.assertEqual(row.working[0].weight_kg, 82.5)


class SubstitutionTests(unittest.TestCase):
    COMPUTED = {"Incline Press": ("*Incline Press*\n"
                                  "Warm-up: 40kg x10, 52.5kg x5\n"
                                  "Working Set: 62.5kg x6 RPE8 | Rest: 2min\n"
                                  "Back-off: 50kg x10-12 RPE7")}

    def test_the_coachs_header_is_kept(self):
        """The card keys its transitions on the coach's spelling."""
        reply = ("*Incline Barbell Press*\n"
                 "Working Set: 60kg x8 RPE7 | Rest: 2min\n"
                 "Back-off: 50kg x10 RPE7\n")
        out, swapped = substitute_computed_blocks(
            reply, self.COMPUTED, aliases={"Incline Barbell Press": "Incline Press"})
        self.assertEqual(swapped, ["Incline Barbell Press"])
        self.assertTrue(out.startswith("*Incline Barbell Press*\n"))
        self.assertNotIn("*Incline Press*", out)
        card = parse_all_prescriptions(out)[0]
        self.assertEqual(card["working"][0]["weight"], 62.5)

    def test_a_logged_spelling_without_an_alias_is_left_alone(self):
        reply = "*Incline Barbell Press*\nWorking Set: 60kg x8 RPE7 | Rest: 2min\n"
        out, swapped = substitute_computed_blocks(reply, self.COMPUTED)
        self.assertEqual(swapped, [])
        self.assertEqual(out, reply)

    def test_an_exercise_already_on_the_board_today_is_the_coachs(self):
        reply = "*Incline Press*\nBack-off: 47.5kg x10 RPE7\n"
        out, swapped = substitute_computed_blocks(
            reply, self.COMPUTED, skip=["Incline Press"])
        self.assertEqual(swapped, [])
        self.assertEqual(out, reply)

    def test_skip_follows_the_alias_both_ways(self):
        reply = "*Incline Press*\nBack-off: 47.5kg x10 RPE7\n"
        out, swapped = substitute_computed_blocks(
            reply, self.COMPUTED, aliases={"Incline Barbell Press": "Incline Press"},
            skip=["Incline Barbell Press"])
        self.assertEqual(swapped, [])

    def test_a_prescription_on_the_header_line_is_not_duplicated(self):
        reply = "*Incline Press* Warm-up: 40kg x10\nWorking Set: 60kg x8 RPE7 | Rest: 2min\n"
        out, _ = substitute_computed_blocks(reply, self.COMPUTED)
        card = parse_all_prescriptions(out)[0]
        self.assertEqual(len(card["warmup"]), 2)
        self.assertEqual(out.count("Warm-up:"), 1)


class LoadIncreaseIsABandTests(unittest.TestCase):
    """:181's own example is "opens at 210kg x6-8" — a band, RPE decides."""

    def test_week_one_after_a_peak_at_the_top_prescribes_the_band_not_a_point(self):
        spec = next_top_set("Leg Press", COMPOUND, 1, PriorSet(220.0, 10, 9.0, week=3), [], [])
        self.assertEqual((spec.weight_kg, spec.reps_low, spec.reps_high, spec.rpe), (222.5, 6, 10, 8.0))

    def test_a_full_cycle_stays_coherent_and_moves(self):
        """Two cycles with the athlete hitting the band at the target RPE:
        every week's set is reachable from the last, the deload is two reps
        short at the SAME load, and the next cycle opens above this one."""
        plan = (("Leg Press", 3, COMPOUND),)
        recent = peak = PriorSet(220.0, 10, 9.0, week=3)
        opens = []
        for _cycle in (1, 2):
            for week in (1, 2, 3, 4):
                [p] = prescribe_session(plan, week, {"Leg Press": recent}, peak_history={"Leg Press": peak})
                top = p.working[0]
                if week == 1:
                    opens.append(top.weight_kg)
                if week == 4:
                    self.assertEqual(top.weight_kg, peak.load, "deload holds the week 3 load")
                    self.assertEqual(top.reps_low, peak.reps - 2, "two RPE points is two reps")
                recent = PriorSet(top.weight_kg, top.reps_high, top.rpe, week=week)
                if week == 3:
                    peak = recent
        self.assertGreater(opens[1], opens[0], "the wave moves between cycles")


class CoachFailureBenchmarkTests(unittest.TestCase):
    """The failures the athlete actually saw from the coach, and what the
    programme computes from the same inputs. This is the 'better than the
    coach' claim made checkable."""

    def test_baseline_week_after_a_220_for_10_peak(self):
        """Coach sent 220kg x5 @7 for a week-1 baseline. The programme opens
        above the peak, at the week's RPE, with the band."""
        [p] = prescribe_session((("Leg Press", 3, COMPOUND),), 1, {},
                                peak_history={"Leg Press": PriorSet(220.0, 10, 9.0, week=3)})
        top = p.working[0]
        self.assertEqual((top.weight_kg, top.rpe), (222.5, 8.0))
        self.assertEqual((top.reps_low, top.reps_high), (6, 10))
        self.assertEqual(len(p.backoff), 2, "a 3-set exercise carries two back-offs")
        self.assertEqual(p.backoff[0].weight_kg, p.backoff[1].weight_kg)
        self.assertLess(p.backoff[1].reps_low, p.backoff[0].reps_low)

    def test_a_lift_with_months_of_history_is_never_called_new(self):
        """Coach said "this exercise is new" about Incline Press, logged as
        Incline Barbell Press. The programme resolves the name and computes."""
        rows = [{"exercise": "Incline Barbell Press", "load": 60.0, "reps": 8, "rpe": 8.0}]
        props, renamed, _ = programme.build_proposal(_prompt(), "Push", 2, rows)
        incline = next(p for p in props if p.exercise == "Incline Press")
        self.assertTrue(prescribe.is_determined(incline))
        self.assertEqual(incline.working[0].weight_kg, 60.0)
        self.assertEqual(renamed.get("Incline Press"), "Incline Barbell Press")

    def test_a_suppressed_hrv_day_comes_down_a_point_everywhere(self):
        """The guard that raised a soft RPE back to target undid this. The
        programme computes it into every set at once."""
        recovery = {"hrv": 51, "hrv_avg": 60, "sleep_hours": 7.5}
        [p] = prescribe_session((("Leg Press", 3, COMPOUND),), 2,
                                {"Leg Press": PriorSet(222.5, 8, 8.0)}, recovery=recovery)
        self.assertEqual(p.working[0].rpe, 7.0)
        self.assertEqual(p.working[0].reps_low, 8, "one point of RPE is one rep: 9 becomes 8")
        self.assertTrue(all(b.rpe == 6.0 for b in p.backoff))
        self.assertTrue(p.recovery_reasons)

    def test_the_same_inputs_always_give_the_same_session(self):
        plan = (("Leg Press", 3, COMPOUND), ("Leg Extension", 2, prescribe.ISOLATION))
        hist = {"Leg Press": PriorSet(220.0, 8, 8.0), "Leg Extension": PriorSet(100.0, 12, 8.0)}
        a = prescribe.render_session(prescribe_session(plan, 2, hist))
        b = prescribe.render_session(prescribe_session(plan, 2, hist))
        self.assertEqual(a, b)


class GoLiveSwitchTests(unittest.TestCase):
    """The substitution reaches the reply only behind PROGRAMME_SUBSTITUTION."""

    def test_the_switch_defaults_off(self):
        import os
        from settings import get_settings
        os.environ.pop("PROGRAMME_SUBSTITUTION", None)
        self.assertFalse(get_settings().programme_substitution)

    def test_the_live_block_binds_the_reply_only_under_the_switch(self):
        """AST, like the shadow test: the only place assistant_message is bound
        from the computed blocks sits inside `if ...programme_substitution:`."""
        import ast, inspect, coach
        tree = ast.parse(inspect.getsource(coach.chat_with_coach))
        live = [n for n in ast.walk(tree)
                if isinstance(n, ast.If) and "programme_substitution" in ast.dump(n.test)]
        self.assertEqual(len(live), 1, "one guarded live block")
        bound_inside = {t.id for n in ast.walk(live[0]) if isinstance(n, ast.Assign)
                        for t in ast.walk(n.targets[0]) if isinstance(t, ast.Name)}
        self.assertIn("assistant_message", bound_inside)
        # And nowhere else does a substitution result reach the reply.
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign) and any(
                    isinstance(t, ast.Name) and t.id == "assistant_message"
                    for t in ast.walk(node.targets[0])):
                inside_live = any(node is m for m in ast.walk(live[0]))
                src = ast.dump(node.value)
                self.assertTrue(inside_live or "substitut" not in src.lower(),
                                "a substitution binds the reply outside the switch")

    def test_on_and_off_end_to_end(self):
        import os
        from settings import get_settings
        from coach_parsing import substitute_computed_blocks, parse_all_prescriptions
        computed = {"Leg Press": ("*Leg Press*\nWorking Set: 222.5kg x6-10 RPE8 | Rest: 2min\n"
                                  "Back-off: 178kg x10-12 RPE7, 178kg x8-10 RPE7")}
        reply = "*Leg Press*\nWorking Set: 220kg x5 @7 | Rest: 2min\nBack-off: 178kg x11 @6\n"
        # Off: the shadow path leaves the reply alone (mirrors coach.py's gate).
        os.environ.pop("PROGRAMME_SUBSTITUTION", None)
        out = substitute_computed_blocks(reply, computed)[0] if get_settings().programme_substitution else reply
        self.assertEqual(out, reply)
        # On: the same call rewrites the prescription lines.
        os.environ["PROGRAMME_SUBSTITUTION"] = "1"
        try:
            self.assertTrue(get_settings().programme_substitution)
            out = substitute_computed_blocks(reply, computed)[0]
            card = parse_all_prescriptions(out)[0]
            self.assertEqual(card["working"][0]["weight"], 222.5)
            self.assertEqual(len(card["backoff"]), 2)
        finally:
            os.environ.pop("PROGRAMME_SUBSTITUTION", None)


class AuditCountTests(unittest.TestCase):
    def test_a_revised_block_is_not_a_violation(self):
        from audit import _violations
        block = {"exercise": "Leg Press", "revised": True,
                 "working": [{"weight": 120.0, "reps": 15, "rpe": 6.0}]}
        self.assertEqual(_violations(block, 1, "Legs", _prompt()), [])

    def test_a_mid_session_restatement_is_not_a_set_count_violation(self):
        from audit import _violations
        block = {"exercise": "Leg Press",
                 "working": [{"weight": 220.0, "reps": 6, "rpe": 8.0}],
                 "backoff": [{"weight": 176.0, "reps": 8, "rpe": 7.0}]}
        codes = [c for c, _ in _violations(block, 1, "Legs", _prompt(), full_reply=False)]
        self.assertNotIn("set_count", codes)
        codes = [c for c, _ in _violations(block, 1, "Legs", _prompt(), full_reply=True)]
        self.assertIn("set_count", codes)

    def test_an_unknown_movement_is_not_held_to_the_isolation_range(self):
        from audit import _violations
        block = {"exercise": "Landmine Thing",
                 "working": [{"weight": 60.0, "reps": 6, "rpe": 8.0}]}
        codes = [c for c, _ in _violations(block, 1, "Push", _prompt())]
        self.assertNotIn("reps_below_range", codes)

    def test_the_same_lift_on_the_same_day_is_counted_once(self):
        import audit as audit_module
        opening = "\n\n".join(
            f"*{n}*\nWorking Set: 100kg x6 RPE8 | Rest: 2min\nBack-off: 80kg x10 RPE7"
            for n in ("Leg Press", "Leg Extension", "Seated Leg Curl"))
        restated = "*Leg Press*\nWorking Set: 100kg x6 RPE8 | Rest: 2min\nBack-off: 80kg x10 RPE7"
        replies = [{"date": "2026-09-01", "content": opening},
                   {"date": "2026-09-01", "content": restated}]
        original = (audit_module.fetch_assistant_replies, audit_module.fetch_session_weeks,
                    audit_module.fetch_recovery_by_date)
        try:
            audit_module.fetch_assistant_replies = lambda days: replies
            audit_module.fetch_session_weeks = lambda days: {"2026-09-01": ("Legs", 1)}
            audit_module.fetch_recovery_by_date = lambda days: {}
            result = audit_module.audit(30, _prompt())
        finally:
            (audit_module.fetch_assistant_replies, audit_module.fetch_session_weeks,
             audit_module.fetch_recovery_by_date) = original
        self.assertEqual(result["prescriptions"], 3)
        press = [f for f in result["violations"] if f["exercise"] == "Leg Press"
                 and f["code"] == "set_count"]
        self.assertEqual(len(press), 1)


if __name__ == "__main__":
    unittest.main()
