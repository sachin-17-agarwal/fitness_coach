"""The weak-point slot goes through the programme: a named pick carries its
movement, the movement joins the plan as 3 straight sets in the 10-15 band,
and the coach's block for it is the programme's. And decisions that belong
in the records go in by code, once."""

import json
import unittest
try:
    import blockfix  # noqa: F401  pins the block to four weeks for the legacy rules
except ImportError:  # run as tests.test_x (CI), where tests/ is not on sys.path
    from tests import blockfix  # noqa: F401
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
    def test_a_weak_point_lift_renders_half_its_straight_sets_on_a_deload(self):
        plan = (("Overhead Cable Extension", 3, ISOLATION),)
        history = {"Overhead Cable Extension": PriorSet(25.0, 12, 9.0, week=3)}
        [p] = prescribe_session(plan, 4, history, straight_lifts={"overheadcableextension": WEAK_POINT_RANGE})
        self.assertTrue(p.straight)
        block = render_block(p)
        self.assertIn("Working Set: 25kg x10 RPE7, 25kg x10 RPE7 | Rest", block)  # 3 sets halve to 2 on the deload
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

    def test_the_cable_crunch_cap_is_cleared_through_the_decision_path(self):
        cap = {"exercise": "Cable Crunch", "max_load_kg": 105, "note": "stack tops out", "set_on": "2026-09-15"}
        state = {"active": [cap, {"exercise": "Machine Shoulder Press", "max_load_kg": 70, "set_on": "2026-09-17"}]}

        def load_active():
            return list(state["active"])

        def record(line):
            self.assertEqual(line, "Decision: Cable Crunch | clear")
            state["active"] = [c for c in state["active"] if c["exercise"] != "Cable Crunch"]
            return 0

        with patch("data.get_supabase", return_value=object()), \
             patch("constraints.load_active", side_effect=load_active), \
             patch("constraints.record_decisions", side_effect=record):
            note = data_fixes._fix_2026_09_19_clear_cable_crunch_cap()
        self.assertIn("cleared the Cable Crunch cap (105kg, since 2026-09-15)", note)
        self.assertEqual([c["exercise"] for c in state["active"]], ["Machine Shoulder Press"], "the shoulder cap stays")
        with patch("data.get_supabase", return_value=object()), \
             patch("constraints.load_active", side_effect=load_active):
            self.assertIn("nothing to clear", data_fixes._fix_2026_09_19_clear_cable_crunch_cap())

    def test_the_leg_press_note_is_cleared_and_other_constraints_stay(self):
        state = {"active": [{"exercise": "Leg Press", "max_load_kg": None, "note": "too light", "set_on": "2026-09-14"},
                            {"exercise": "Machine Shoulder Press", "max_load_kg": 70, "set_on": "2026-09-17"}]}

        def record(line):
            self.assertEqual(line, "Decision: Leg Press | clear")
            state["active"] = [c for c in state["active"] if c["exercise"] != "Leg Press"]
            return 0

        with patch("data.get_supabase", return_value=object()), \
             patch("constraints.load_active", side_effect=lambda: list(state["active"])), \
             patch("constraints.record_decisions", side_effect=record):
            note = data_fixes._fix_2026_09_19_clear_leg_press_note()
        self.assertIn("cleared Leg Press (note, since 2026-09-14)", note)
        self.assertEqual([c["exercise"] for c in state["active"]], ["Machine Shoulder Press"])

    def test_the_emphasis_fix_refuses_a_refusal(self):
        with patch("data.get_supabase", return_value=object()), \
             patch("coach.load_system_prompt", return_value="PROMPT"), \
             patch("weakpoints.set_next_emphasis", return_value="I can't reach the block's record right now, so nothing changed."):
            with self.assertRaises(RuntimeError):
                data_fixes._fix_2026_09_19_emphasis_triceps_chest()
