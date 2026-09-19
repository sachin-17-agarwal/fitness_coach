"""The weak-point slot goes through the programme: a named pick carries its
movement, the movement joins the plan as 3 straight sets in the 10-15 band,
and the coach's block for it is the programme's. And decisions that belong
in the records go in by code, once."""

import json
import unittest
from unittest.mock import patch

import data_fixes
from prescribe import ISOLATION, PriorSet, WEAK_POINT_RANGE, prescribe_session, render_block
from programme import weak_point_slots
from weakpoints import _named_picks, exercise_from_note


class NamedPickTests(unittest.TestCase):
    def test_a_note_that_names_a_movement_carries_it(self):
        self.assertEqual(exercise_from_note("Overhead Cable Extension", "triceps"), "Overhead Cable Extension")
        self.assertEqual(exercise_from_note("overhead cable extension, long head lengthened", "triceps"),
                         "Overhead Cable Extension")
        self.assertEqual(exercise_from_note("Cable Fly (Low To High)", "chest"), "Cable Fly (Low To High)")

    def test_a_note_without_a_movement_or_the_wrong_muscle_carries_none(self):
        self.assertIsNone(exercise_from_note("long head lengthened", "triceps"))
        self.assertIsNone(exercise_from_note("", "triceps"))
        self.assertIsNone(exercise_from_note("Overhead Cable Extension", "chest"))

    def test_named_picks_include_the_exercise(self):
        bands = {"triceps": (8, 12), "chest": (10, 16)}
        pending = [{"muscle": "triceps", "note": "Overhead Cable Extension", "set_on": "2026-09-19"},
                   {"muscle": "chest", "note": "", "set_on": "2026-09-19"}]
        picks = _named_picks(pending, bands)
        self.assertEqual(picks[0]["exercise"], "Overhead Cable Extension")
        self.assertIsNone(picks[1]["exercise"])


class SlotTests(unittest.TestCase):
    ENTRIES = [("Cable Crunch", 3), ("Pallof Press", 2), ("Weak-Point Exercise 1", 3), ("Weak-Point Exercise 2", 3)]
    PLAN = (("Cable Crunch", 3, ISOLATION), ("Pallof Press", 2, ISOLATION))

    def test_named_picks_fill_the_slots_as_straight_lifts(self):
        picks = [{"muscle": "triceps", "exercise": "Overhead Cable Extension"},
                 {"muscle": "chest", "exercise": "Cable Fly (Low To High)"}]
        plan, straight = weak_point_slots(self.PLAN, self.ENTRIES, picks)
        names = [e for e, _s, _k in plan]
        self.assertEqual(names[-2:], ["Overhead Cable Extension", "Cable Fly (Low To High)"])
        self.assertEqual([s for _e, s, _k in plan][-2:], [3, 3])
        self.assertEqual(set(straight.values()), {WEAK_POINT_RANGE})

    def test_a_pick_without_a_movement_leaves_its_slot_to_the_coach(self):
        plan, straight = weak_point_slots(self.PLAN, self.ENTRIES, [{"muscle": "hamstrings", "exercise": None}])
        self.assertEqual(len(plan), 2)
        self.assertEqual(straight, {})

    def test_no_slots_means_no_change(self):
        plan, straight = weak_point_slots(self.PLAN, [("Cable Crunch", 3)], [{"muscle": "triceps", "exercise": "Overhead Cable Extension"}])
        self.assertEqual(len(plan), 2)


class StraightLiftTests(unittest.TestCase):
    def test_a_weak_point_lift_renders_three_straight_sets_on_a_deload(self):
        plan = (("Overhead Cable Extension", 3, ISOLATION),)
        history = {"Overhead Cable Extension": PriorSet(25.0, 12, 9.0, week=3)}
        [p] = prescribe_session(plan, 4, history, straight_lifts={"overheadcableextension": WEAK_POINT_RANGE})
        self.assertTrue(p.straight)
        block = render_block(p)
        self.assertIn("Working Set: 25kg x10 RPE7, 25kg x10 RPE7, 25kg x10 RPE7", block)
        self.assertNotIn("Back-off", block)

    def test_a_weak_point_lift_progresses_by_reps_inside_its_own_band(self):
        plan = (("Cable Fly (Low To High)", 3, ISOLATION),)
        history = {"Cable Fly (Low To High)": PriorSet(15.0, 10, 9.0)}
        [p] = prescribe_session(plan, 2, history, straight_lifts={"cableflylowtohigh": WEAK_POINT_RANGE})
        top = p.working[0]
        self.assertEqual((top.weight_kg, top.reps_low, top.reps_high), (15.0, 11, 15))

    def test_an_ordinary_isolation_keeps_its_shape(self):
        plan = (("Hammer Curl", 3, ISOLATION),)
        [p] = prescribe_session(plan, 2, {"Hammer Curl": PriorSet(20.0, 10, 8.0)})
        self.assertFalse(p.straight)
        self.assertIn("Back-off:", render_block(p))


class DataFixTests(unittest.TestCase):
    def test_a_fix_runs_once_and_is_recorded(self):
        calls = []
        with patch.object(data_fixes, "FIXES", [("t-1", lambda: calls.append(1) or "ok")]), \
             patch("data_fixes.set_memory_value") as store:
            self.assertEqual(data_fixes.apply_pending({}), ["t-1"])
            self.assertEqual(json.loads(store.call_args[0][1]), ["t-1"])
            self.assertEqual(data_fixes.apply_pending({data_fixes.APPLIED_KEY: json.dumps(["t-1"])}), [])
        self.assertEqual(calls, [1])

    def test_a_failing_fix_is_not_marked_applied(self):
        def boom():
            raise RuntimeError("no database connection")
        with patch.object(data_fixes, "FIXES", [("t-2", boom)]), patch("data_fixes.set_memory_value") as store:
            self.assertEqual(data_fixes.apply_pending({}), [])
            store.assert_not_called()

    def test_the_emphasis_fix_refuses_a_refusal(self):
        with patch("data.get_supabase", return_value=object()), \
             patch("coach.load_system_prompt", return_value="PROMPT"), \
             patch("weakpoints.set_next_emphasis", return_value="I can't reach the block's record right now, so nothing changed."):
            with self.assertRaises(RuntimeError):
                data_fixes._fix_2026_09_19_emphasis_triceps_chest()
