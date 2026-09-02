"""The programme, executed as code, against its own stated rules.

Every assertion here is a rule that was previously enforced only by asking a
language model to read prose and apply it correctly in one pass. Each one is
now a function with one right answer, and these are the answers.
"""

import unittest

from prescribe import (
    COMPOUND, ISOLATION, PriorSet, SetSpec, backoff_sets,
    infer_session_weeks, next_top_set, prescribe_exercise, prescribe_pull,
    render, warmup_ramp,
)


class WaveTests(unittest.TestCase):
    """The 4-week wave: RPE targets and what each week moves."""

    def test_each_week_targets_its_stated_rpe(self):
        prior = PriorSet(80.0, 8, 8.0)
        for week, top, back in ((1, 8.0, 7.0), (2, 8.0, 7.0), (3, 9.0, 8.0), (4, 7.0, 6.0)):
            with self.subTest(week=week):
                p = prescribe_exercise("Cable Row", 2, COMPOUND, week, prior, set())
                self.assertEqual(p.working[0].rpe, top)
                self.assertEqual(p.backoff[0].rpe, back)

    def test_a_week_outside_one_to_four_is_refused(self):
        with self.assertRaises(ValueError):
            prescribe_pull(5, {})


class DeloadTests(unittest.TestCase):
    """RPE is reps-in-reserve, so at a fixed load a 2-point drop costs 2 reps.

    ":185 Prescribing MORE reps at the same load and calling it a lower RPE is
    arithmetically impossible; it is the single most common way this week gets
    botched."
    """

    def test_two_rpe_points_cost_two_reps_at_the_same_load(self):
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 4,
                               PriorSet(80.0, 10, 9.0, week=3), set())
        top = p.working[0]
        self.assertEqual(top.weight_kg, 80.0)     # same load as week 3
        self.assertEqual(top.reps_low, 8)         # 10 - 2
        self.assertEqual(top.rpe, 7.0)

    def test_the_deload_never_prescribes_more_reps_than_week_three(self):
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 4,
                               PriorSet(80.0, 10, 9.0, week=3), set())
        self.assertLessEqual(p.working[0].reps_high, 10)

    def test_the_low_rep_exception_drops_load_instead(self):
        """:186 — subtracting from an already-short set leaves a near-single,
        which is a strength stimulus, not a deload."""
        p = prescribe_exercise("Lat Pulldown", 2, COMPOUND, 4,
                               PriorSet(95.0, 5, 9.0, week=3), set())
        top = p.working[0]
        self.assertEqual(top.reps_low, 5)          # reps held
        self.assertLess(top.weight_kg, 95.0)       # load dropped instead
        self.assertGreaterEqual(top.weight_kg, 95.0 * 0.80)
        self.assertTrue(any("Deload by LOAD" in r for r in p.reasons))

    def test_deloading_off_a_non_peak_session_is_flagged_not_guessed(self):
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 4,
                               PriorSet(80.0, 5, 7.0, week=1), set())
        self.assertTrue(p.deferred)


class LoadProgressionTests(unittest.TestCase):
    """:203 — the trigger is the WEEK'S target RPE, not a flat 8."""

    def test_top_of_range_at_or_under_target_moves_the_load(self):
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 1,
                               PriorSet(80.0, 10, 8.0), set())
        self.assertEqual(p.working[0].weight_kg, 82.5)
        self.assertEqual(p.working[0].reps_low, 6)   # reset to bottom of range

    def test_peak_week_at_rpe_nine_still_triggers_an_increase(self):
        """Reading the trigger as a flat 'RPE <= 8' silently blocks every
        peak-week result from ever producing a load increase (:204)."""
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 3,
                               PriorSet(80.0, 10, 9.0), set())
        self.assertGreater(p.working[0].weight_kg, 80.0)

    def test_week_one_ignores_rpe_and_reads_only_the_week_three_reps(self):
        """:181 states week 1's rule purely in reps against last cycle's week 3
        — 'where Week 3 finished at or above the top of the range, open at the
        next increment up'. RPE is not part of it, so an RPE 9 week-3 set at the
        top of the range still opens the new cycle higher."""
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 1,
                               PriorSet(80.0, 10, 9.0, week=3), set())
        self.assertEqual(p.working[0].weight_kg, 82.5)
        self.assertEqual(p.working[0].reps_low, 6)   # reset to the bottom

    def test_week_one_below_the_top_of_range_holds_the_load(self):
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 1,
                               PriorSet(80.0, 8, 9.0, week=3), set())
        self.assertEqual(p.working[0].weight_kg, 80.0)
        self.assertEqual(p.working[0].reps_low, 6)

    def test_week_one_never_repeats_last_cycle(self):
        """:181 'Without this the wave loops forever.' Either the load moves or
        the reps reset to the bottom — never the same prescription back."""
        prior = PriorSet(80.0, 8, 8.0, week=3)
        top = prescribe_exercise("Cable Row", 2, COMPOUND, 1, prior, set()).working[0]
        self.assertNotEqual((top.weight_kg, top.reps_low), (prior.load, prior.reps))

    def test_week_one_flags_an_anchor_that_is_not_week_three(self):
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 1,
                               PriorSet(80.0, 6, 7.0, week=4), set())
        self.assertTrue(any("WEEK 3" in d for d in p.deferred))

    def test_week_two_holds_the_load_and_adds_reps(self):
        """:182 volume before intensity."""
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 2,
                               PriorSet(80.0, 7, 8.0), set())
        self.assertEqual(p.working[0].weight_kg, 80.0)
        self.assertGreater(p.working[0].reps_low, 7)

    def test_week_three_names_the_lever_it_used(self):
        """:183 'State which lever you used and why.'"""
        by_load = prescribe_exercise("Cable Row", 2, COMPOUND, 3,
                                     PriorSet(80.0, 10, 8.0), set())
        by_reps = prescribe_exercise("Cable Row", 2, COMPOUND, 3,
                                     PriorSet(80.0, 7, 8.0), set())
        self.assertTrue(any("via LOAD" in r for r in by_load.reasons))
        self.assertGreater(by_load.working[0].weight_kg, 80.0)
        self.assertTrue(any("via REPS" in r for r in by_reps.reasons))
        self.assertEqual(by_reps.working[0].weight_kg, 80.0)

    def test_reps_above_the_range_are_a_backlog(self):
        """:205. Week 2 is where the generic trigger lives; week 1 covers the
        same case through its own 'at or above the top' clause."""
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 2,
                               PriorSet(80.0, 14, 8.0), set())
        self.assertGreater(p.working[0].weight_kg, 80.0)

    def test_isolations_take_the_smaller_increment(self):
        p = prescribe_exercise("Hammer Curl", 3, ISOLATION, 1,
                               PriorSet(20.0, 12, 8.0), set())
        self.assertLessEqual(p.working[0].weight_kg - 20.0, 2.5)

    def test_a_missing_rep_or_rpe_never_reads_as_a_pass(self):
        """Week 2, because that is where the trigger consults RPE at all —
        week 1's rule is rep-only by design (:181)."""
        for prior in (PriorSet(80.0, None, 8.0), PriorSet(80.0, 10, None)):
            with self.subTest(prior=prior):
                p = prescribe_exercise("Cable Row", 2, COMPOUND, 2, prior, set())
                self.assertEqual(p.working[0].weight_kg, 80.0)


class BackOffTests(unittest.TestCase):
    """:64-65 — the drop, and the rule most often botched."""

    def test_the_back_off_drops_fifteen_to_twenty_five_percent(self):
        sets = backoff_sets(SetSpec(100.0, 8, 8, 8.0), COMPOUND, 1, 1, [])
        self.assertGreaterEqual(sets[0].weight_kg, 75.0)
        self.assertLessEqual(sets[0].weight_kg, 85.0)

    def test_the_second_back_off_carries_fewer_reps_at_the_same_load(self):
        """'Not a choice, not a judgement call — always.' (:65)"""
        sets = backoff_sets(SetSpec(100.0, 8, 8, 8.0), COMPOUND, 2, 1, [])
        self.assertEqual(len(sets), 2)
        self.assertEqual(sets[0].weight_kg, sets[1].weight_kg)
        self.assertLess(sets[1].reps_low, sets[0].reps_low)

    def test_a_two_set_exercise_gets_exactly_one_back_off(self):
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 1, PriorSet(80.0, 8, 8.0), set())
        self.assertEqual(len(p.backoff), 1)
        self.assertEqual(p.working_set_count, 2)

    def test_a_three_set_exercise_gets_exactly_two(self):
        p = prescribe_exercise("Hammer Curl", 3, ISOLATION, 1, PriorSet(20.0, 10, 8.0), set())
        self.assertEqual(len(p.backoff), 2)
        self.assertEqual(p.working_set_count, 3)

    def test_a_bodyweight_movement_sheds_the_added_load_not_the_athlete(self):
        sets = backoff_sets(SetSpec(15.0, 8, 8, 8.0, bodyweight=True), COMPOUND, 1, 1, [])
        self.assertTrue(sets[0].bodyweight)
        self.assertLess(sets[0].weight_kg or 0, 15.0)


class RepRangeTests(unittest.TestCase):
    """:70 — 'That flexibility runs UPWARD only.'"""

    def test_a_prior_session_below_range_never_drags_the_proposal_below_it(self):
        p = prescribe_exercise("Hammer Curl", 3, ISOLATION, 1,
                               PriorSet(20.0, 6, 7.0), set())
        self.assertGreaterEqual(p.working[0].reps_low, 8)

    def test_running_below_range_is_reported_rather_than_silently_corrected(self):
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 1,
                               PriorSet(86.5, 5, 7.0), set())
        self.assertTrue(any("BELOW range" in d for d in p.deferred))

    def test_a_deload_below_range_is_not_reported_as_a_fault(self):
        """:74 gives 'Cable Row 78.5kg x8 becomes 78.5kg x6' as the deload
        working correctly. Flagging that would report the protocol as a bug —
        which is the mistake I made reading the 28 August session."""
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 4,
                               PriorSet(86.5, 5, 7.0, week=3), set())
        self.assertFalse(any("BELOW range" in d for d in p.deferred))


class WarmupTests(unittest.TestCase):
    """:127-135 — the ramp is a function of the working weight and whether the
    muscle is already warm, never of the week."""

    def test_heavy_first_movement_gets_three_ramp_sets(self):
        ramp = warmup_ramp("Lat Pulldown", SetSpec(120.0, 8, 8, 8.0), set(), PriorSet(120.0, 8, 8.0), [])
        self.assertEqual(len(ramp), 3)
        self.assertLess(ramp[0].weight_kg, ramp[1].weight_kg)
        self.assertLess(ramp[1].weight_kg, ramp[2].weight_kg)

    def test_moderate_first_movement_gets_two(self):
        ramp = warmup_ramp("Cable Row", SetSpec(80.0, 8, 8, 8.0), set(), PriorSet(80.0, 8, 8.0), [])
        self.assertEqual(len(ramp), 2)

    def test_an_already_warm_muscle_gets_no_ramp(self):
        ramp = warmup_ramp("Lat Pulldown", SetSpec(95.0, 8, 8, 8.0), {"Back"}, PriorSet(95.0, 8, 8.0), [])
        self.assertEqual(ramp, [])

    def test_ramp_sets_are_never_near_failure(self):
        ramp = warmup_ramp("Lat Pulldown", SetSpec(120.0, 8, 8, 8.0), set(), PriorSet(120.0, 8, 8.0), [])
        for s in ramp:
            self.assertLessEqual(s.rpe, 6.0)

    def test_the_ramp_never_exceeds_three_sets(self):
        """:139 'Three is the ceiling; more is fatigue disguised as preparation.'"""
        for weight in (60.0, 100.0, 200.0, 400.0):
            ramp = warmup_ramp("Lat Pulldown", SetSpec(weight, 8, 8, 8.0), set(),
                               PriorSet(weight, 8, 8.0), [])
            self.assertLessEqual(len(ramp), 3)

    def test_the_ramp_is_identical_on_a_deload(self):
        """:125 'Deload holds week-3 loads, so a deload ramp is identical to
        the peak-week ramp.'"""
        peak = prescribe_exercise("Cable Row", 2, COMPOUND, 3, PriorSet(80.0, 8, 8.0), set())
        deload = prescribe_exercise("Cable Row", 2, COMPOUND, 4, PriorSet(80.0, 8, 8.0, week=3), set())
        self.assertEqual([s.weight_kg for s in peak.warmup],
                         [s.weight_kg for s in deload.warmup])


class PullSessionTests(unittest.TestCase):
    """The whole session, against the template line at :357."""

    HISTORY = {
        "Pull-Ups":           PriorSet(15.0, 4, 8.0, "2026-08-28"),
        "Cable Row":          PriorSet(86.5, 5, 7.0, "2026-08-28"),
        "Lat Pulldown":       PriorSet(95.0, 5, 8.0, "2026-08-28"),
        "T-Bar Row":          PriorSet(55.0, 5, 7.0, "2026-08-28"),
        "Machine Bicep Curl": PriorSet(55.0, 9, 7.0, "2026-08-28"),
        "Hammer Curl":        PriorSet(20.0, 6, 7.0, "2026-08-28"),
    }

    def test_the_session_always_totals_sixteen_working_sets(self):
        for week in (1, 2, 3, 4):
            with self.subTest(week=week):
                total = sum(p.working_set_count for p in prescribe_pull(week, self.HISTORY))
                self.assertEqual(total, 16)

    def test_the_set_count_is_identical_in_every_week(self):
        """:167 'Set count stays fixed within a cycle.' The thing that has been
        varying run to run cannot vary here — it is not an output of the model."""
        counts = [
            tuple(p.working_set_count for p in prescribe_pull(week, self.HISTORY))
            for week in (1, 2, 3, 4)
        ]
        self.assertEqual(len(set(counts)), 1, f"set counts differ by week: {counts}")

    def test_the_same_inputs_always_produce_the_same_session(self):
        """The whole point. Two calls, byte-identical."""
        a = render(prescribe_pull(1, self.HISTORY))
        b = render(prescribe_pull(1, self.HISTORY))
        self.assertEqual(a, b)

    def test_biceps_are_warm_after_the_rows_so_the_curl_needs_no_full_ramp(self):
        """:131 ''Already trained' includes heavy secondary involvement:
        triceps are warm after pressing, biceps after rowing.'"""
        curl = next(p for p in prescribe_pull(1, self.HISTORY)
                    if p.exercise == "Machine Bicep Curl")
        self.assertEqual(curl.warmup, [])

    def test_an_exercise_with_no_history_defers_instead_of_inventing_a_load(self):
        fly = next(p for p in prescribe_pull(1, self.HISTORY)
                   if p.exercise == "Reverse Cable Fly")
        self.assertIsNone(fly.working[0].weight_kg)
        self.assertTrue(fly.deferred)
        self.assertEqual(fly.working_set_count, 2)   # count is still known

    def test_every_number_carries_a_stated_reason(self):
        for p in prescribe_pull(1, self.HISTORY):
            with self.subTest(exercise=p.exercise):
                self.assertTrue(p.reasons or p.deferred)


if __name__ == "__main__":
    unittest.main()


class MesocycleWeekReconstructionTests(unittest.TestCase):
    """The week is recoverable without being stored.

    `workout_sessions` has no mesocycle column (the legacy `sessions` table did;
    it was dropped when the table replaced it), and rows written before the
    migration never will. Without the week, a deload and a session run under
    target are indistinguishable — and the migration is not something the
    athlete can run. So it is reconstructed instead.
    """

    def test_the_rotation_is_read_off_the_type_not_counted(self):
        """Pull=1, Push=2, Legs=3, Cardio+Abs=4 is a bijection, which is what
        makes this immune to a missed day."""
        weeks = infer_session_weeks(
            ["Pull", "Push", "Legs", "Cardio+Abs"], next_week=2, next_day=1)
        self.assertEqual(weeks, [1, 1, 1, 1])

    def test_the_week_rolls_at_each_day_four(self):
        types = ["Pull", "Push", "Legs", "Cardio+Abs"] * 2
        weeks = infer_session_weeks(types, next_week=3, next_day=1)
        self.assertEqual(weeks, [1, 1, 1, 1, 2, 2, 2, 2])

    def test_yoga_consumes_no_rotation_slot(self):
        """data.py:45 — yoga overrides the rotation without advancing it."""
        types = ["Pull", "Push", "Yoga", "Legs", "Cardio+Abs"]
        weeks = infer_session_weeks(types, next_week=2, next_day=1)
        self.assertIsNone(weeks[2])
        self.assertEqual([weeks[0], weeks[1], weeks[3], weeks[4]], [1, 1, 1, 1])

    def test_a_missed_day_does_not_shift_the_reconstruction(self):
        """A step-by-step walk would drift here; reading the day off the type
        does not. Legs is skipped entirely and Cardio+Abs is still day 4."""
        types = ["Pull", "Push", "Cardio+Abs", "Pull"]
        weeks = infer_session_weeks(types, next_week=2, next_day=2)
        self.assertEqual(weeks, [1, 1, 1, 2])

    def test_the_anchor_accounts_for_the_stored_state_being_the_NEXT_session(self):
        """memory holds the week and day of the session still to come. If that
        is day 1, the last completed session was day 4 of the week before."""
        ending_on_day_four = infer_session_weeks(
            ["Pull", "Push", "Legs", "Cardio+Abs"], next_week=2, next_day=1)
        mid_week = infer_session_weeks(
            ["Pull", "Push", "Legs"], next_week=1, next_day=4)
        self.assertEqual(ending_on_day_four[-1], 1)   # day 4 of week 1
        self.assertEqual(mid_week[-1], 1)             # still inside week 1

    def test_the_week_wraps_at_four(self):
        types = ["Cardio+Abs", "Pull"]
        weeks = infer_session_weeks(types, next_week=1, next_day=2)
        self.assertEqual(weeks, [4, 1])

    def test_an_unknown_session_type_yields_none_rather_than_a_guess(self):
        weeks = infer_session_weeks(["Pull", "Mobility", "Push"],
                                    next_week=1, next_day=3)
        self.assertIsNone(weeks[1])

    def test_it_reproduces_a_full_four_week_mesocycle(self):
        types = ["Pull", "Push", "Legs", "Cardio+Abs"] * 4
        weeks = infer_session_weeks(types, next_week=1, next_day=1)
        self.assertEqual(weeks, [1]*4 + [2]*4 + [3]*4 + [4]*4)
