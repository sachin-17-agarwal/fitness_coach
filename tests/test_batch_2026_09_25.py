"""The 25 Sep batch: F5 standing decisions reviewed by age, F6a the case
variants merged, F7 the widget's week line and block-aware phase."""
import unittest
from unittest.mock import MagicMock, patch

try:
    import blockfix  # noqa: F401
except ImportError:
    from tests import blockfix  # noqa: F401


class StandingDecisionReviewTests(unittest.TestCase):
    ROWS = [{"exercise": "Machine Shoulder Press", "max_load_kg": 70, "note": "shoulder niggle", "set_on": "2026-09-17"}]

    def test_sessions_under_the_decision_are_counted_per_lift(self):
        import constraints
        sb = MagicMock()
        sb.table.return_value.select.return_value.gte.return_value.execute.return_value.data = [
            {"exercise": "Machine Shoulder Press", "workout_session_id": s, "date": d}
            for s, d in (("a", "2026-09-17"), ("a", "2026-09-17"), ("b", "2026-09-22"), ("c", "2026-09-27"), ("old", "2026-09-10"))
        ] + [{"exercise": "Leg Press", "workout_session_id": "z", "date": "2026-09-23"}]
        with patch("constraints.get_supabase", return_value=sb):
            held = constraints.sessions_held(self.ROWS)
        self.assertEqual(held, {"machineshoulderpress": 3})

    def test_due_after_four_sessions_and_not_again_for_a_week(self):
        import constraints
        held = {"machineshoulderpress": 4}
        self.assertEqual(constraints.due_for_review(self.ROWS, held, {}), ["Machine Shoulder Press"])
        self.assertEqual(constraints.due_for_review(self.ROWS, {"machineshoulderpress": 3}, {}), [])
        today = constraints.now_local().strftime("%Y-%m-%d")
        self.assertEqual(constraints.due_for_review(self.ROWS, held, {"constraint_asked:machineshoulderpress": today}), [])
        self.assertEqual(constraints.due_for_review(self.ROWS, held, {"constraint_asked:machineshoulderpress": "2026-01-01"}), ["Machine Shoulder Press"])

    def test_the_coach_is_told_once(self):
        import constraints
        text = constraints.format_constraints(self.ROWS, {"machineshoulderpress": 5}, ["Machine Shoulder Press"])
        self.assertIn("5 sessions under it", text)
        self.assertIn("ASK ONCE TODAY", text)
        self.assertIn("`Decision: Machine Shoulder Press | clear`", text)
        quiet = constraints.format_constraints(self.ROWS, {"machineshoulderpress": 2}, [])
        self.assertNotIn("ASK ONCE", quiet)
        self.assertIn("2 sessions under it", quiet)


class CaseVariantTests(unittest.TestCase):
    def test_the_plan_merges_case_and_spacing_only(self):
        from fixes_2026_09 import case_variant_plan
        names = {"Leg Press": 143, "Leg press": 31, "Machine Chest Fly": 4, "Cable Chest Fly": 53, "Ab Crunch Machine": 56,
                 "Ab crunch machine": 19, "Face  Pulls": 2, "Face Pulls": 57, "Pull-Ups": 81, "Pull-ups": 1}
        plan = case_variant_plan(names)
        self.assertEqual(plan, {"Leg press": "Leg Press", "Ab crunch machine": "Ab Crunch Machine",
                                "Face  Pulls": "Face Pulls", "Pull-ups": "Pull-Ups"})
        self.assertNotIn("Machine Chest Fly", plan, "a different lift or an alias, never a case fix")

    def test_the_fix_renames_each_variant(self):
        from fixes_2026_09 import _fix_2026_09_25_exercise_case_variants
        sb = MagicMock()
        sb.table.return_value.select.return_value.execute.return_value.data = (
            [{"exercise": "Leg Press"}] * 3 + [{"exercise": "Leg press"}] * 2 + [{"exercise": "Dips"}])
        with patch("data.get_supabase", return_value=sb):
            out = _fix_2026_09_25_exercise_case_variants()
        self.assertIn("Leg press -> Leg Press (2 sets)", out)
        sb.table.return_value.update.assert_called_once_with({"exercise": "Leg Press"})
        sb.table.return_value.update.return_value.eq.assert_called_once_with("exercise", "Leg press")

    def test_registered_first_in_the_september_fixes(self):
        from fixes_2026_09 import FIXES_2026_09
        self.assertEqual(FIXES_2026_09[0][0], "2026-09-25-exercise-case-variants")


class WidgetWeekTests(unittest.TestCase):
    def test_phase_follows_the_block_length(self):
        import data, webhook
        self.assertEqual([webhook._phase_short(w) for w in (1, 2, 3, 4)], ["BASELINE", "VOLUME", "PEAK · LOAD", "DELOAD"])
        with patch.object(data, "block_weeks", lambda: 5):
            self.assertEqual([webhook._phase_short(w) for w in (3, 4, 5)], ["PEAK · REPS", "PEAK · LOAD", "DELOAD"])
        self.assertEqual(webhook._phase_short(9), "")

    def test_this_week_against_last(self):
        import webhook
        from datetime import timedelta
        today = webhook.now_local().date(); monday = today - timedelta(days=today.weekday())
        rows = [{"date": (monday + timedelta(days=1)).isoformat(), "tonnage_kg": 20000, "type": "Legs"},
                {"date": monday.isoformat(), "tonnage_kg": 8000, "type": "Pull"},
                {"date": (monday - timedelta(days=3)).isoformat(), "tonnage_kg": 25000, "type": "Legs"},
                {"date": monday.isoformat(), "tonnage_kg": 0, "type": "Cardio+Abs"}]
        sb = MagicMock()
        sb.table.return_value.select.return_value.gte.return_value.execute.return_value.data = rows
        with patch("webhook.get_supabase", return_value=sb):
            out = webhook._week_stats()
        self.assertEqual((out["week_sessions"], out["week_tonnage_kg"], out["week_tonnage_delta_pct"]), (2, 28000.0, 12))
        with patch("webhook.get_supabase", return_value=None):
            self.assertEqual(webhook._week_stats()["week_sessions"], None)


class HygieneAndBackfillTests(unittest.TestCase):
    def test_session_type_from_the_sets(self):
        from fixes_2026_09 import infer_session_type
        self.assertEqual(infer_session_type(["Barbell Bench Press", "Barbell Bench Press", "Sled Leg Press"]), "Push")
        self.assertEqual(infer_session_type(["Leg press", "Leg Press"]), "Legs")
        self.assertEqual(infer_session_type(["Cable Row", "Lat Pulldown", "Hammer Curl"]), "Pull")
        self.assertIsNone(infer_session_type([]))

    def test_backfill_walks_the_rotation_backwards(self):
        from data import CYCLE
        from fixes_2026_09 import backfill_stamps
        S = [{"id": "a", "date": "2026-08-28", "type": "Pull", "tonnage_kg": 1},
             {"id": "b", "date": "2026-08-29", "type": "Push", "tonnage_kg": 1},
             {"id": "c", "date": "2026-08-31", "type": "Legs", "tonnage_kg": 1},
             {"id": "d", "date": "2026-09-01", "type": "Cardio+Abs", "tonnage_kg": 1},
             {"id": "e", "date": "2026-09-01", "type": "Cardio+Abs", "tonnage_kg": 1, "start_time": "2026-09-01T09:00:00"},
             {"id": "empty", "date": "2026-08-30", "type": "Legs", "tonnage_kg": 0},
             {"id": "s", "date": "2026-09-02", "type": "Pull", "tonnage_kg": 1, "mesocycle_week": 1, "mesocycle_day": 1}]
        out = backfill_stamps(S, CYCLE, 4)
        self.assertEqual(out, {"d": (4, 4), "e": (4, 4), "c": (4, 3), "b": (4, 2), "a": (4, 1)})
        self.assertNotIn("empty", out, "a session with no work is not a slot")
        # a missed slot: no Legs between Push and Cardio
        S2 = [{"id": "p", "date": "2026-08-29", "type": "Push", "tonnage_kg": 1},
              {"id": "cardio", "date": "2026-09-01", "type": "Cardio+Abs", "tonnage_kg": 1},
              {"id": "s", "date": "2026-09-02", "type": "Pull", "tonnage_kg": 1, "mesocycle_week": 1, "mesocycle_day": 1}]
        self.assertEqual(backfill_stamps(S2, CYCLE, 4), {"cardio": (4, 4), "p": (4, 2)})
        self.assertEqual(backfill_stamps([{"id": "x", "date": "2026-08-01", "type": "Pull", "tonnage_kg": 1}], CYCLE), {}, "nothing stamped to walk back from")

    def test_the_fixes_are_registered_in_order(self):
        from fixes_2026_09 import FIXES_2026_09
        keys = [k for k, _ in FIXES_2026_09]
        self.assertEqual(keys[:3], ["2026-09-25-exercise-case-variants", "2026-09-25-session-hygiene", "2026-09-25-stamp-backfill"])


class ReadyToLoadTests(unittest.TestCase):
    """C2: the watch's READY TO LOAD flag drives the number."""

    def test_the_current_load_row_carries_ready(self):
        from progression import find_current_loads
        rows = [
            {"exercise": "Leg Press", "date": "2026-09-09", "actual_weight_kg": 240, "actual_reps": 13, "actual_rpe": 8, "is_warmup": False, "workout_session_id": "a"},
            {"exercise": "Leg Press", "date": "2026-09-14", "actual_weight_kg": 240, "actual_reps": 11, "actual_rpe": 9.5, "is_warmup": False, "workout_session_id": "b"},
            {"exercise": "Cable Row", "date": "2026-09-14", "actual_weight_kg": 90.5, "actual_reps": 8, "actual_rpe": 9, "is_warmup": False, "workout_session_id": "b"},
        ]
        by = {r["exercise"]: r for r in find_current_loads(rows)}
        self.assertTrue(by["Leg Press"]["ready"], "an earlier session at 240 reached the top at RPE 8")
        self.assertFalse(by["Cable Row"]["ready"])

    def test_week_two_steps_when_ready_even_if_the_last_set_did_not_quite(self):
        from prescribe import COMPOUND, PriorSet, prescribe_exercise
        # Last session 11 of 8-12 at RPE 9.5: the single-set rule holds the load.
        held = prescribe_exercise("Leg Press", 3, COMPOUND, 2, PriorSet(240.0, 9, 9.5, step=2.5), set())
        self.assertEqual(held.working[0].weight_kg, 240.0)
        ready = prescribe_exercise("Leg Press", 3, COMPOUND, 2, PriorSet(240.0, 9, 9.5, step=2.5, ready=True), set())
        self.assertEqual(ready.working[0].weight_kg, 242.5)
        self.assertTrue(any("READY TO LOAD" in r for r in ready.reasons))
        # The peak-by-reps branch too.
        peak = prescribe_exercise("Leg Press", 3, COMPOUND, 3, PriorSet(240.0, 9, 9.5, step=2.5, ready=True), set())
        self.assertEqual(peak.working[0].weight_kg, 242.5)
        # Never at bodyweight, where the step is a plate the coach decides.
        bw = prescribe_exercise("Pull-Ups", 2, COMPOUND, 2, PriorSet(None, 6, 9.5, bodyweight=True, ready=True), set())
        self.assertTrue(bw.working[0].bodyweight)
