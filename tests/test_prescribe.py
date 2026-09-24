"""The programme, executed as code, against its own stated rules.

Every assertion here is a rule that was previously enforced only by asking a
language model to read prose and apply it correctly in one pass. Each one is
now a function with one right answer, and these are the answers.
"""

import unittest
try:
    import blockfix  # noqa: F401  pins the block to four weeks for the legacy rules
except ImportError:  # run as tests.test_x (CI), where tests/ is not on sys.path
    from tests import blockfix  # noqa: F401

from prescribe import (
    COMPOUND, ISOLATION, PriorSet, SetSpec, backoff_sets,
    infer_session_weeks, next_top_set, prescribe_exercise, prescribe_pull,
    render, warmup_ramp,
)


class WaveTests(unittest.TestCase):
    """The wave on the four-week block (three loading weeks and a deload):
    RPE targets and what each week moves. Back-offs are RPE 8 in every
    loading week (24 Sep 2026); the deload drops them."""

    def test_each_week_targets_its_stated_rpe(self):
        prior = PriorSet(80.0, 8, 8.0)
        for week, top, back in ((1, 8.0, 8.0), (2, 8.0, 8.0), (3, 9.0, 8.0)):
            with self.subTest(week=week):
                p = prescribe_exercise("Cable Row", 2, COMPOUND, week, prior, set())
                self.assertEqual(p.working[0].rpe, top)
                self.assertEqual(p.backoff[0].rpe, back)
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 4, prior, set())
        self.assertEqual((p.working[0].rpe, p.backoff), (7.0, []))  # deload: top set only

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

    def test_a_missing_rep_count_never_reads_as_a_pass_and_a_missing_rpe_never_blocks(self):
        """Reps only since 25 Sep 2026: the RPE is the card's pre-fill, not a
        reading (74-81% of sets carry it unchanged, measured), so its absence
        cannot hold a load that the reps have earned."""
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 2, PriorSet(80.0, None, 8.0), set())
        self.assertEqual(p.working[0].weight_kg, 80.0)
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 2, PriorSet(80.0, 10, None), set())
        self.assertEqual(p.working[0].weight_kg, 82.5)

    def test_the_top_of_the_range_at_the_target_rpe_or_over_it_still_loads(self):
        """The RPE half of the gate decided 3 of 76 top-of-range hits and the
        load held next session in 2 of them anyway (measured); 7-8-9 is not a
        distinction the athlete can make. Only a failed rep (RPE 10) holds."""
        for rpe in (7.0, 8.0, 9.0, 9.5):
            with self.subTest(rpe=rpe):
                p = prescribe_exercise("Cable Row", 2, COMPOUND, 2, PriorSet(80.0, 10, rpe), set())
                self.assertEqual(p.working[0].weight_kg, 82.5)
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 2, PriorSet(80.0, 10, 10.0), set())
        self.assertEqual(p.working[0].weight_kg, 80.0, "a failed rep holds the load")


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
        for week in (1, 2, 3):
            with self.subTest(week=week):
                total = sum(p.working_set_count for p in prescribe_pull(week, self.HISTORY))
                self.assertEqual(total, 16)
        # The deload keeps the top set alone on every lift: seven sets for seven lifts.
        self.assertEqual(sum(p.working_set_count for p in prescribe_pull(4, self.HISTORY)), 7)

    def test_the_set_count_is_identical_in_every_loading_week(self):
        """:167 'Set count stays fixed within a cycle.' The thing that has been
        varying run to run cannot vary here — it is not an output of the model.
        The deload is the one designed exception (fewer sets, load held)."""
        counts = [
            tuple(p.working_set_count for p in prescribe_pull(week, self.HISTORY))
            for week in (1, 2, 3)
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



class OvershootStepTests(unittest.TestCase):
    """:205 sized to the miss. One increment is 1kg on an isolation, so 110 x 16
    on an 8-12 range proposed 111 next: a block's worth of progression creeping
    back a kilo a session. From three reps over, the step is read off the set."""

    def _top(self, load, reps, kind, week, rpe=8.0):
        from prescribe import next_top_set, PriorSet
        reasons, deferred = [], []
        spec = next_top_set("Seated Leg Curl" if kind == ISOLATION else "Leg Press", kind, week,
                            PriorSet(load, reps, rpe, week=3 if week == 1 else week - 1), reasons, deferred)
        return spec, " ".join(reasons)

    def test_four_over_is_sized_from_the_set_and_capped_at_six_percent(self):
        from prescribe import TOP_SET_RANGE
        low, high = TOP_SET_RANGE[ISOLATION]
        spec, why = self._top(110.0, high + 4, ISOLATION, 3)
        # Epley 110 x 16 = 168.7; mid-range reps sit near 126.5; +6% caps at 116.5
        # (measured 25 Sep 2026: jumps over 6% cost 1.7 reps and landed under
        # the range 20% of the time; 3-6% cost none and missed 11%).
        self.assertEqual(spec.weight_kg, 116.5)
        self.assertIn("capped at +6%", why)
        self.assertIn("(:205)", why)

    def test_three_over_inside_the_cap_lands_at_the_mid_range_load(self):
        from prescribe import TOP_SET_RANGE
        low, high = TOP_SET_RANGE[ISOLATION]
        spec, why = self._top(100.0, high + 3, ISOLATION, 3)
        # 100 x 15 -> e1RM 150 -> 10 reps near 112.5; +6% cap = 106.
        self.assertEqual(spec.weight_kg, 106.0)

    def test_one_or_two_over_keeps_the_single_increment(self):
        from prescribe import TOP_SET_RANGE, INCREMENT
        low, high = TOP_SET_RANGE[ISOLATION]
        spec, why = self._top(100.0, high + 1, ISOLATION, 3)
        self.assertEqual(spec.weight_kg, 100.0 + INCREMENT[ISOLATION])
        spec, why = self._top(100.0, high + 2, ISOLATION, 3)
        self.assertEqual(spec.weight_kg, 100.0 + INCREMENT[ISOLATION])
        self.assertNotIn("sized to the miss", why)

    def test_week_two_and_week_one_openings_use_the_sized_step_too(self):
        from prescribe import TOP_SET_RANGE
        low, high = TOP_SET_RANGE[ISOLATION]
        for week in (1, 2):
            spec, why = self._top(110.0, high + 4, ISOLATION, week)
            self.assertEqual(spec.weight_kg, 116.5, f"week {week}")
            self.assertIn("sized to the miss", why)

    def test_a_compound_never_steps_below_its_own_increment(self):
        from prescribe import TOP_SET_RANGE, INCREMENT
        low, high = TOP_SET_RANGE[COMPOUND]
        spec, why = self._top(20.0, high + 3, COMPOUND, 3)
        self.assertGreaterEqual(spec.weight_kg, 20.0 + INCREMENT[COMPOUND])


class BodyweightProgressionTests(unittest.TestCase):
    """2.11 — a bodyweight lift has the same levers as a stack lift.

    Ab Wheel Rollout sat at bodyweight x8 for seven sessions at RPE 6-7 while
    the programme repeated "add reps toward the top"; Hanging Leg Raises held
    at +5kg while it asked for +6kg, a load no gym has. The coach corrected
    both by hand every session; these are the corrections as arithmetic.
    """

    def test_added_load_moves_in_plates_not_kilos(self):
        p = prescribe_exercise("Hanging Leg Raises", 3, ISOLATION, 2,
                               PriorSet(5.0, 12, 7.0, bodyweight=True), set())
        self.assertEqual(p.working[0].weight_kg, 7.5)
        self.assertTrue(p.working[0].bodyweight)

    def test_the_sized_step_uses_what_the_movement_actually_lifts(self):
        """+5kg x15 on a leg raise lifted about 33kg for an 80kg athlete, not
        5kg. Sized on that and capped at 10%, the step is a plate: +7.5kg."""
        p = prescribe_exercise("Hanging Leg Raises", 3, ISOLATION, 2,
                               PriorSet(5.0, 15, 8.0, bodyweight=True), set(), athlete_kg=80.0)
        self.assertEqual(p.working[0].weight_kg, 7.5)
        self.assertIn("33kg lifted", " ".join(p.reasons))

    def test_a_heavier_overshoot_sizes_a_bigger_step(self):
        p = prescribe_exercise("Pull-Ups", 3, COMPOUND, 3,
                               PriorSet(10.0, 13, 8.0, bodyweight=True), set(), athlete_kg=80.0)
        self.assertEqual(p.working[0].weight_kg, 15.0)   # 90kg lifted, +6% cap (5.4kg), in plates

    def test_without_a_weigh_in_the_single_plate_stands(self):
        p = prescribe_exercise("Hanging Leg Raises", 3, ISOLATION, 2,
                               PriorSet(5.0, 15, 8.0, bodyweight=True), set(), athlete_kg=None)
        self.assertEqual(p.working[0].weight_kg, 7.5)
        self.assertNotIn("lifted", " ".join(p.reasons))

    def test_a_movement_with_nothing_to_load_moves_its_range_not_a_plate(self):
        """A rollout has nothing to load (25 Sep 2026: the card showed BW+2.5kg).
        Its range moves up instead; past the cap a variation is the coach's call."""
        p = prescribe_exercise("Ab Wheel Rollout", 3, ISOLATION, 2,
                               PriorSet(None, 15, 7.0, bodyweight=True), set(), athlete_kg=80.0)
        self.assertIsNone(p.working[0].weight_kg)
        self.assertEqual((p.working[0].reps_low, p.working[0].reps_high), (11, 15))
        self.assertIn("No load to add", " ".join(p.reasons))

    def test_the_lifts_own_step_drives_rounding_and_increments(self):
        # Reverse Cable Fly, 20 Sep 2026: peak 12.5 x 11 @8 on a 2.5kg cable
        # stack. Week 1 opens at 12.5 x 8-12; a readiness cut (RPE down a
        # point, load down 5%) then produced "12kg x 7-11" — 11.875 rounded
        # to the half-kilo, a load the stack does not have.
        from prescribe import RecoveryAdjustment, _adjusted
        p = prescribe_exercise("Reverse Cable Fly", 3, ISOLATION, 1,
                               PriorSet(12.5, 11, 8.0, week=3, step=2.5), set())
        top = p.working[0]
        self.assertEqual((top.weight_kg, top.reps_low, top.reps_high, top.grid), (12.5, 8, 12, 2.5))
        base_rpe = top.rpe
        cut = _adjusted(p, RecoveryAdjustment(rpe_delta=-1.0, load_multiplier=0.95, reasons=("tired",)))
        top = cut.working[0]
        self.assertEqual((top.weight_kg, top.reps_low, top.reps_high, top.rpe), (12.5, 7, 11, base_rpe - 1))
        self.assertIn("effort down, load held — a 5% cut is under this lift's 2.5kg step",
                      " ".join(cut.reasons + cut.recovery_reasons))
        # Week 1 after a top-of-range peak steps by the stack, not by the 1kg guide.
        p = prescribe_exercise("Reverse Cable Fly", 3, ISOLATION, 1,
                               PriorSet(12.5, 12, 7.0, week=3, step=2.5), set())
        self.assertEqual(p.working[0].weight_kg, 15.0)
        # Without a known step the grid is the kind's own increment (1kg for
        # an isolation lift), never the half-kilo, and the move is one whole
        # step from the load he was at: 12.5 -> 13.5. (151.5kg went on a
        # chest press whose stack had not been read, 22 Sep 2026.)
        p = prescribe_exercise("Reverse Cable Fly", 3, ISOLATION, 1,
                               PriorSet(12.5, 12, 7.0, week=3), set())
        self.assertEqual((p.working[0].weight_kg, p.working[0].grid), (13.5, 1.0))

    def test_a_stall_with_reps_in_reserve_pins_the_top_of_the_range(self):
        p = prescribe_exercise("Ab Wheel Rollout", 3, ISOLATION, 2,
                               PriorSet(None, 8, 6.5, bodyweight=True, held=7), set())
        top = p.working[0]
        self.assertEqual((top.reps_low, top.reps_high), (12, 12))
        self.assertTrue(top.bodyweight)
        self.assertFalse(top.weight_kg)      # still no added load
        self.assertIn("STALLED 7 sessions at BW x8", " ".join(p.reasons))

    def test_the_stall_lever_applies_to_stack_lifts_too(self):
        p = prescribe_exercise("Cable Row", 3, COMPOUND, 3,
                               PriorSet(80.0, 8, 7.0, held=3), set())
        self.assertEqual((p.working[0].weight_kg, p.working[0].reps_low, p.working[0].reps_high),
                         (80.0, 10, 10))

    def test_a_stall_logged_harder_than_the_card_is_deferred_not_pinned(self):
        """An RPE ABOVE the week's target is the one slider move that carries
        information (142 of 230 moves were exactly +1, measured); it says the
        reps are not there, and asking for twelve would prescribe a set the
        athlete cannot do."""
        from prescribe import targets_for
        over = targets_for(2)["top"] + 1
        p = prescribe_exercise("Ab Wheel Rollout", 3, ISOLATION, 2,
                               PriorSet(None, 8, over, bodyweight=True, held=4), set())
        self.assertEqual((p.working[0].reps_low, p.working[0].reps_high), (9, 12))
        self.assertTrue(any("coaching decision" in d for d in p.deferred))

    def test_a_stall_at_the_prefilled_rpe_pins_the_reps(self):
        """RPE equal to the card's target is the app's pre-fill, not a reading;
        the rep lever is pulled rather than deferred (25 Sep 2026)."""
        p = prescribe_exercise("Ab Wheel Rollout", 3, ISOLATION, 2,
                               PriorSet(None, 8, 8.0, bodyweight=True, held=4), set())
        self.assertEqual((p.working[0].reps_low, p.working[0].reps_high), (12, 12))

    def test_two_sessions_is_not_a_stall(self):
        p = prescribe_exercise("Ab Wheel Rollout", 3, ISOLATION, 2,
                               PriorSet(None, 8, 6.5, bodyweight=True, held=2), set())
        self.assertEqual((p.working[0].reps_low, p.working[0].reps_high), (9, 12))
        self.assertFalse(p.deferred)

    def test_the_deload_and_the_opening_week_ignore_the_stall(self):
        for week, low, high in ((4, 8, 8), (1, 6, 10)):
            with self.subTest(week=week):
                p = prescribe_exercise("Cable Row", 3, COMPOUND, week,
                                       PriorSet(80.0, 8, 7.0, held=3, week=3), set())
                self.assertEqual((p.working[0].reps_low, p.working[0].reps_high), (low, high))
                self.assertFalse(any("STALLED" in r for r in p.reasons))

    def test_a_straight_set_block_repeats_the_pinned_count(self):
        from prescribe import render_block
        p = prescribe_exercise("Ab Wheel Rollout", 3, ISOLATION, 2,
                               PriorSet(None, 8, 6.5, bodyweight=True, held=7), set())
        block = render_block(p)
        self.assertIn("Working Set: BW x12 RPE8, BW x12 RPE8, BW x12 RPE8", block)
        self.assertNotIn("Back-off", block)
