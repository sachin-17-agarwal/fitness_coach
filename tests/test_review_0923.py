"""Review of the 23 Sep 2026 session changes: three defects found reading the
merged code, each pinned here.

1. note_direction read rep and RPE phrasing as a load move, so a correct
   more_reps/harder/fewer_reps reply was handed back to the model.
2. A set reply's load move ignored the lift's own step: 125kg + one step on
   a 5kg calf-raise stack came out as 131kg.
3. (App) a reorder request could remove the lift it moved past; covered by
   the swap-only gate in WorkoutViewModel, not testable here.
"""
import unittest
import blockfix  # noqa: F401  pins the block to four weeks for the legacy rules

from plan import SetPlan, adapted_plan, apply_set_decision, lift_step, note_direction


class NoteDirectionTests(unittest.TestCase):
    def test_rep_and_rpe_phrasing_is_not_a_load_move(self):
        for note in ["Take the next set up to 12 reps.",
                     "Push it up to RPE 8 on the next one.",
                     "Move up to the top of the range.",
                     "Bring the reps down to 8.",
                     "Keep the load, push the reps up."]:
            self.assertIsNone(note_direction(note), note)

    def test_load_phrasing_still_reads(self):
        self.assertEqual(note_direction("Take the last back-off heavier."), "heavier")
        self.assertEqual(note_direction("Go up a plate."), "heavier")
        self.assertEqual(note_direction("Add a plate for the last one."), "heavier")
        self.assertEqual(note_direction("Take it up."), "heavier")
        self.assertEqual(note_direction("Drop the weight a notch."), "lighter")
        self.assertEqual(note_direction("Bring it down a step."), "lighter")
        self.assertEqual(note_direction("Take 2.5kg off for the last set."), "lighter")

    def test_mixed_or_empty_is_none(self):
        self.assertIsNone(note_direction(""))
        self.assertIsNone(note_direction("Go heavier on the top set, then lighter on the back-off."))


class StepAwareMoveTests(unittest.TestCase):
    CALF = SetPlan(125.0, 8, 12, 8.0)

    def test_one_step_on_a_five_kilo_stack_is_five(self):
        self.assertEqual(apply_set_decision("heavier", 1, self.CALF, "Standing Calf Raise", 5.0).load_kg, 130.0)
        self.assertEqual(apply_set_decision("lighter", 1, self.CALF, "Standing Calf Raise", 5.0).load_kg, 120.0)

    def test_unknown_step_keeps_the_programme_guess(self):
        # The half-kilo grid is prescribe's "could not tell", not a real stack.
        for grid in (None, 0.5):
            self.assertEqual(apply_set_decision("heavier", 1, self.CALF, "Standing Calf Raise", grid).load_kg, 131.0)

    def test_easier_cut_lands_on_the_stack(self):
        # 12.5 * 0.925 = 11.56 -> 12.5 on a 2.5kg stack, not 11.5.
        low = SetPlan(12.5, 5, 6, 8.0)
        self.assertEqual(apply_set_decision("easier", 1, low, "Cable Fly", 2.5).load_kg, 12.5)

    STORED = {"working": [{"load_kg": 100, "reps_low": 8, "reps_high": 10, "rpe": 8}],
              "backoff": [{"load_kg": 80, "reps_low": 10, "reps_high": 12, "rpe": 7},
                          {"load_kg": 80, "reps_low": 10, "reps_high": 12, "rpe": 7}],
              "tempo": "", "rest_seconds": 90}
    REPLY = {"decision": "heavier", "steps": 1, "reason": "The last set was four reps clear at RPE 6.",
             "note": "Take the back-offs up a step."}

    def test_adapted_plan_reads_the_stored_step(self):
        e = adapted_plan(self.REPLY, "Leg Press", {**self.STORED, "step": 5.0}, 1)
        self.assertEqual([b.load_kg for b in e.backoff], [85.0, 85.0])

    def test_band_ceiling_floors_to_the_step(self):
        # 85% of 100 is 85; on a 10kg stack the heaviest in-band load is 80,
        # so 'heavier' cannot leave the band and the back-off holds.
        e = adapted_plan(self.REPLY, "Leg Press", {**self.STORED, "step": 10.0}, 1)
        self.assertEqual([b.load_kg for b in e.backoff], [80.0, 80.0])


class LiftStepLookupTests(unittest.TestCase):
    STEPS = {"Incline Press": 2.5, "Standing Calf Raise": 5.0, "Lat Pulldown": 0.5}

    def test_exact_and_case_insensitive(self):
        self.assertEqual(lift_step(self.STEPS, "standing calf raise"), 5.0)

    def test_logged_spelling_meets_the_template_through_aliases(self):
        aliases = {"Incline Barbell Press": "Incline Press"}
        self.assertEqual(lift_step(self.STEPS, "Incline Barbell Press", aliases), 2.5)
        self.assertIsNone(lift_step(self.STEPS, "Incline Barbell Press"))

    def test_half_kilo_default_is_unknown(self):
        self.assertIsNone(lift_step(self.STEPS, "Lat Pulldown"))
        self.assertIsNone(lift_step(None, "Lat Pulldown"))
