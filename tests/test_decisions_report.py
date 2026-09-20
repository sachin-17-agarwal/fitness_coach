"""The coach against the programme in the Sunday report, read from the
prescription_decisions table."""

import unittest
from unittest.mock import patch

from usage import format_decisions, is_coach_decision, summarise_decisions


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

    def test_a_re_sent_opening_counts_once_and_the_last_copy_wins(self):
        rows = [{"date": "d", "session_type": "Cardio+Abs", "exercise": "Cable Crunch", "decision": "adjust", "reason": "shape: straight sets"},
                {"date": "d", "session_type": "Cardio+Abs", "exercise": "Cable Crunch", "decision": "adjust", "reason": "shape: straight sets"},
                {"date": "d", "session_type": "Cardio+Abs", "exercise": "Cable Crunch", "decision": "accept", "reason": "programme"},
                {"date": "d", "session_type": "Cardio+Abs", "exercise": "Pallof Press", "decision": "adjust", "reason": "elbow pain"}]
        d = summarise_decisions(rows)
        self.assertEqual(d["exercises"], 2)
        self.assertEqual(d["adjusts"], 1)          # the crunch's last copy is an accept

    def test_adjust_rate_cause_rate_and_top_lifts(self):
        d = summarise_decisions(self.ROWS)
        self.assertEqual(d["sessions"], 2)
        self.assertEqual(d["exercises"], 5)
        self.assertEqual(d["adjusts"], 3)
        self.assertAlmostEqual(d["adjust_rate"], 0.6)
        self.assertAlmostEqual(d["cause_rate"], 2 / 3)      # "felt like it" names no cause
        self.assertEqual(d["buckets"], {"cause": 2, "progression": 0, "shape": 0, "other": 1})
        self.assertEqual(d["top_adjusted"][0]["exercise"], "Machine Shoulder Press")
        self.assertEqual(d["top_adjusted"][0]["count"], 2)

    def test_the_section_reads_the_numbers(self):
        text = format_decisions(summarise_decisions(self.ROWS), 14)
        self.assertIn("adjusted **3** of them (**60%**)", text)
        self.assertIn("2 named a cause", text)
        self.assertIn("1 other", text)
        self.assertIn("| Machine Shoulder Press | 2 |", text)
        self.assertIn("reply_contract.py", text)

    def test_an_empty_window_is_said_plainly(self):
        text = format_decisions(summarise_decisions([]), 14)
        self.assertIn("No opening decisions recorded", text)


class ReasonBucketTests(unittest.TestCase):

    def test_reasons_fall_into_cause_progression_shape_or_other(self):
        from usage import reason_bucket
        self.assertEqual(reason_bucket("HRV below baseline this morning, holding load"), "cause")
        self.assertEqual(reason_bucket("shoulder niggle — hold at 70kg"), "cause")
        self.assertEqual(reason_bucket("Stuck at bodyweight x8 for seven sessions at RPE6-7"), "progression")
        self.assertEqual(reason_bucket("Three sessions at 40kg with reps at or above the top of the range"), "progression")
        self.assertEqual(reason_bucket("Direct ab work runs as straight sets, not top-set/back-off"), "shape")
        self.assertEqual(reason_bucket("felt like it"), "other")

    def test_a_shape_heavy_report_names_the_programme_defect(self):
        from usage import format_decisions, summarise_decisions
        rows = [{"date": "d", "session_type": "Cardio+Abs", "exercise": f"E{i}", "decision": "adjust",
                 "reason": "abs are straight sets, converting the proposal's back-off line"} for i in range(3)]
        text = format_decisions(summarise_decisions(rows), 14)
        self.assertIn("3 shape", text)
        self.assertIn("programme defect", text)


class SameNumbersTests(unittest.TestCase):

    def test_blocks_with_identical_sets_are_the_same_whatever_the_prose(self):
        from coach import _same_numbers
        a = {"warmup": [{"weight": 40, "reps": 8}], "working": [{"weight": 80, "reps": 6, "reps_high": 8, "rpe": 8}],
             "backoff": [{"weight": 64, "reps": 10, "reps_high": 12, "rpe": 7}],
             "form": "brace hard", "why": "programme", "tempo": "3-1-2", "rest": "2min"}
        b = dict(a, form="elbows in", why=None, tempo=None, rest="90s")
        self.assertTrue(_same_numbers(a, b))
        c = dict(a, backoff=[{"weight": 60, "reps": 10, "reps_high": 12, "rpe": 7}])
        self.assertFalse(_same_numbers(a, c))
        d = dict(a, warmup=[])
        self.assertFalse(_same_numbers(a, d))
