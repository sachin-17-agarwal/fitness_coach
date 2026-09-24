"""Roadmap 2.12: the hygiene plan is pure, so it is tested from rows."""

import unittest
import blockfix  # noqa: F401  pins the block to four weeks for the legacy rules

from cleanup import infer_session_type, plan_session_hygiene


def S(id_, date, type_, status, start="T10"):
    return {"id": id_, "date": date, "type": type_, "status": status, "start_time": start}


class HygieneTests(unittest.TestCase):
    def test_status_spellings_collapse_to_one_per_state(self):
        plan = plan_session_hygiene([S("a", "2026-09-01", "Push", "complete"), S("b", "2026-09-02", "Pull", "active"),
                                     S("c", "2026-09-03", "Legs", "completed")], {})
        self.assertEqual(plan["status"], [("a", "completed"), ("b", "in_progress")])

    def test_a_blank_type_is_inferred_from_the_sets(self):
        sets = {"x": [{"exercise": "Lat Pulldown"}, {"exercise": "Cable Row"}, {"exercise": "Hammer Curl"}]}
        plan = plan_session_hygiene([S("x", "2026-09-04", "", "completed")], sets)
        self.assertEqual(plan["type"], [("x", "Pull")])

    def test_a_tie_or_no_sets_is_left_alone_and_noted(self):
        self.assertIsNone(infer_session_type(["Lat Pulldown", "Incline Press"]))
        plan = plan_session_hygiene([S("y", "2026-09-05", "Unknown", "completed")], {})
        self.assertEqual(plan["type"], [])
        self.assertTrue(any("left alone" in n for n in plan["notes"]))

    def test_duplicates_keep_the_row_with_the_sets_and_move_the_rest(self):
        sets = {"real": [{"exercise": "Cable Crunch"}] * 9, "logger": [], "stray": [{"exercise": "Pallof Press"}]}
        plan = plan_session_hygiene([S("logger", "2026-09-06", "Cardio+Abs", "completed", "T09"),
                                     S("real", "2026-09-06", "Cardio+Abs", "completed", "T10"),
                                     S("stray", "2026-09-06", "Cardio+Abs", "in_progress", "T11")], sets)
        self.assertEqual(sorted(plan["delete"]), ["logger", "stray"])
        self.assertEqual(plan["move_sets"], [("stray", "real")])

    def test_rows_on_different_days_or_types_are_untouched(self):
        plan = plan_session_hygiene([S("a", "2026-09-07", "Push", "completed"), S("b", "2026-09-07", "Yoga", "completed"),
                                     S("c", "2026-09-08", "Push", "completed")], {})
        self.assertEqual(plan["delete"], [])
