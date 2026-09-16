"""The shadow, read from tables: the coach against the programme in the
Sunday report."""

import unittest
from unittest.mock import patch

from usage import (format_decisions, is_coach_decision, record_shadow, summarise_decisions,
                   summarise_shadow)


class DecisionsSummaryTests(unittest.TestCase):

    ROWS = [
        {"date": "2026-09-13", "session_type": "Push", "exercise": "Machine Chest Press", "decision": "accept", "reason": "programme"},
        {"date": "2026-09-13", "session_type": "Push", "exercise": "Machine Shoulder Press", "decision": "adjust",
         "reason": "shoulder niggle — hold at 70kg, reps only"},
        {"date": "2026-09-13", "session_type": "Push", "exercise": "Dips", "decision": "adjust", "reason": "felt like it"},
        {"date": "2026-09-14", "session_type": "Legs", "exercise": "Leg Press", "decision": "accept", "reason": "programme"},
        {"date": "2026-09-14", "session_type": "Legs", "exercise": "Machine Shoulder Press", "decision": "adjust",
         "reason": "shoulder niggle again"},
        # Not the coach's decisions: the weak-point pick, a queued emphasis, the programme card.
        {"date": "2026-09-14", "session_type": "Cardio+Abs", "exercise": "Weak-point: hamstrings", "decision": "accept", "reason": "Block pick"},
        {"date": "2026-09-14", "session_type": "Cardio+Abs", "exercise": "Emphasis-next: triceps", "decision": "accept", "reason": None},
        {"date": "2026-09-16", "session_type": "Pull", "exercise": "Cable Row", "decision": "accept", "reason": "programme — coach reviewing"},
    ]

    def test_only_the_coachs_decisions_count(self):
        kept = [r for r in self.ROWS if is_coach_decision(r)]
        self.assertEqual(len(kept), 5)

    def test_adjust_rate_cause_rate_and_top_lifts(self):
        d = summarise_decisions(self.ROWS)
        self.assertEqual(d["sessions"], 2)
        self.assertEqual(d["exercises"], 5)
        self.assertEqual(d["adjusts"], 3)
        self.assertAlmostEqual(d["adjust_rate"], 0.6)
        self.assertAlmostEqual(d["cause_rate"], 2 / 3)      # "felt like it" names no cause
        self.assertEqual(d["top_adjusted"][0]["exercise"], "Machine Shoulder Press")
        self.assertEqual(d["top_adjusted"][0]["count"], 2)

    def test_the_section_reads_the_numbers_and_the_shadow(self):
        d = summarise_decisions(self.ROWS)
        shadow = summarise_shadow([{"date": "2026-09-13", "kind": "prose", "exercise": "Cable Crunch"},
                                   {"date": "2026-09-13", "kind": "prose", "exercise": "Cable Crunch"},
                                   {"date": "2026-09-15", "kind": "set_reply", "exercise": "Hammer Curl"}])
        text = format_decisions(d, shadow, 14)
        self.assertIn("adjusted **3** of them (**60%**)", text)
        self.assertIn("**67%** named a cause", text)
        self.assertIn("| Machine Shoulder Press | 2 |", text)
        self.assertIn("**3** exercise blocks on 2 days", text)
        self.assertIn("prose 2, set_reply 1", text)
        self.assertIn("Cable Crunch ×2", text)

    def test_an_empty_window_and_a_missing_shadow_table_are_said_plainly(self):
        text = format_decisions(summarise_decisions([]), None, 14)
        self.assertIn("No opening decisions recorded", text)
        self.assertIn("migration 008", text)
        text = format_decisions(summarise_decisions([]), summarise_shadow([]), 14)
        self.assertIn("None in 14 days", text)


class RecordShadowTests(unittest.TestCase):

    def test_a_row_per_differing_exercise_and_never_raises(self):
        rows = []
        class Table:
            def insert(self, row):
                rows.append(row)
                class X:
                    def execute(inner): return None
                return X()
        class SB:
            def table(self, name): return Table()
        with patch("data.get_supabase", return_value=SB()):
            record_shadow("2026-09-16", "Pull", 4, "prose", "Hammer Curl",
                          {"working": [{"weight": 20, "reps": 10}], "backoff": []},
                          {"working": [{"weight": 20, "reps": 8}], "backoff": [{"weight": 16, "reps": 12}]})
        self.assertEqual(rows[0]["kind"], "prose")
        self.assertEqual(rows[0]["mesocycle_week"], 4)
        self.assertIn('"reps": 8', rows[0]["computed"])
        class Broken:
            def table(self, name): raise RuntimeError("no table")
        with patch("data.get_supabase", return_value=Broken()):
            record_shadow("2026-09-16", "Pull", 4, "prose", "Hammer Curl", {}, {})   # must not raise
