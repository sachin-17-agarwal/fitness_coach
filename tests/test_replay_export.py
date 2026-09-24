"""F8: the whole pipeline replayed against the real export (tests/fixtures/
export), every stamped session from 3 Sep 2026, offline. The numbers below
are the baseline at the time the harness was built; a change that makes any
of them worse fails here, and one that makes them better should lower the
bound. `python replay_export.py` prints the full report.

recovery.csv is health data and is not committed; when it is not beside the
other files every session replays as a day with no reading, which changes a
few loads, so the bounds hold with or without it."""
import unittest

import replay_export as R


class ReplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.results = R.replay_all()
        cls.summary = R.summarise(cls.results)

    def test_every_stamped_session_replays(self):
        self.assertEqual(self.summary["sessions"], 18)
        self.assertEqual(self.summary["errors"], [], [r["error"] for r in self.summary["errors"]])
        self.assertGreaterEqual(self.summary["lifts"], 110)

    def test_every_computed_load_is_on_the_lifts_ladder(self):
        self.assertEqual(self.summary["unloadable"], [])

    def test_the_chest_press_opens_on_its_own_stack(self):
        # 85, 93, ... 141, 149, 165: an 8kg stack. Week 1 after a 149 x11
        # peak opens one step up, at 157 — not 151.5 (half-kilo rounding of
        # 149 + 2.5) and not 152 or 160 (multiples of 8 the machine lacks).
        lift = next(l for r in self.results if r["date"] == "2026-09-22"
                    for l in r["lifts"] if l["exercise"] == "Machine Chest Press")
        self.assertEqual((lift["computed"], lift["grid"]), (157.0, 8.0))

    def test_the_programme_stays_close_to_what_was_lifted(self):
        # Baseline 24 Sep 2026: 8 of 106 computed tops more than 15% from the
        # top set actually lifted that day. Lower this when it improves.
        self.assertLessEqual(len(self.summary["far_from_logged"]), 8, self.summary["far_from_logged"])
        # And the pre-flight has less to correct once loads start on the ladder.
        self.assertLessEqual(self.summary["preflight"], 60)
