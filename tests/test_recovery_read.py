"""Today's recovery read: rolling HRV against a baseline, sleep on a slide
gated by a second signal, the athlete's own readiness."""

import math
import unittest
from datetime import date, timedelta

from recovery import (RecoveryRead, Trend, build_read, decide, format_read,
                      sleep_multiplier, trend)


def _days(n, end="2026-09-11"):
    e = date.fromisoformat(end)
    return [(e - timedelta(days=i)).isoformat() for i in range(n)][::-1]


def _rows(hrv, sleep=7.5, rhr=56, n=50, end="2026-09-11", today_hrv=None, today_sleep=None):
    """n days of steady readings; today's values may differ."""
    rows = []
    for i, d in enumerate(_days(n, end)):
        last = i == n - 1
        rows.append({"date": d, "hrv": (today_hrv if last and today_hrv is not None else hrv),
                     "sleep_hours": (today_sleep if last and today_sleep is not None else sleep),
                     "resting_hr": rhr})
    return rows


class TrendTests(unittest.TestCase):
    def test_rolling_and_baseline_windows(self):
        series = {d: 40 + (i % 5) for i, d in enumerate(_days(50))}
        t = trend(series, "2026-09-11", math.log)
        self.assertEqual(t.n_rolling, 7)
        self.assertEqual(t.n_baseline, 42)
        self.assertIsNotNone(t.z)

    def test_too_little_history_does_not_judge(self):
        series = {d: 40 for d in _days(8)}
        t = trend(series, "2026-09-11", math.log)
        self.assertIsNone(t.baseline)
        self.assertIsNone(t.z)

    def test_a_short_baseline_is_used_when_the_full_one_is_missing(self):
        series = {d: 40 + (i % 3) for i, d in enumerate(_days(20))}
        t = trend(series, "2026-09-11", math.log)
        self.assertEqual(t.n_baseline, 13)
        self.assertIsNotNone(t.z)


class SleepTests(unittest.TestCase):
    def test_the_slide(self):
        self.assertEqual(sleep_multiplier(7.5), 1.0)
        self.assertEqual(sleep_multiplier(6.5), 1.0)
        self.assertAlmostEqual(sleep_multiplier(5.75), 0.975, places=3)
        self.assertEqual(sleep_multiplier(5.0), 0.95)
        self.assertEqual(sleep_multiplier(4.0), 0.95)
        self.assertEqual(sleep_multiplier(None), 1.0)


class DecisionTests(unittest.TestCase):
    def _read(self, **kw):
        rows = _rows(hrv=kw.pop("hrv", 40), sleep=kw.pop("sleep", 7.5), rhr=kw.pop("rhr", 56),
                     today_hrv=kw.pop("today_hrv", None), today_sleep=kw.pop("today_sleep", None))
        # A noisy but stationary baseline so the SD is real.
        for i, r in enumerate(rows[:-7]):
            r["hrv"] = r["hrv"] * (1 + 0.08 * ((i % 4) - 1.5))
        return build_read(rows, "2026-09-11", readiness=kw.pop("readiness", None))

    def test_a_normal_morning_is_a_full_session(self):
        rpe, mult, rec, reasons = decide(self._read())
        self.assertEqual((rpe, mult, rec), (0.0, 1.0, False))

    def test_one_noisy_low_day_does_not_move_targets(self):
        """The reported case: one reading ~10% under the mean lowered the day."""
        read = self._read(today_hrv=35.0)
        self.assertFalse(read.hrv_below, "the 7-day average barely moves on one day")
        rpe, mult, rec, reasons = decide(read)
        self.assertEqual((rpe, mult, rec), (0.0, 1.0, False))

    def test_a_week_of_suppressed_hrv_lowers_rpe(self):
        rows = _rows(hrv=40)
        for i, r in enumerate(rows[:-7]):
            r["hrv"] = 40 * (1 + 0.08 * ((i % 4) - 1.5))
        for r in rows[-7:]:
            r["hrv"] = 34.0
        read = build_read(rows, "2026-09-11")
        self.assertTrue(read.hrv_below)
        rpe, mult, rec, reasons = decide(read)
        self.assertEqual((rpe, mult, rec), (-1.0, 1.0, False))
        self.assertTrue(any("RPE targets come down a point" in r for r in reasons))

    def test_one_short_night_alone_holds_targets(self):
        """5.79h used to cut every top set 5%. Alone, it is noted."""
        rpe, mult, rec, reasons = decide(self._read(today_sleep=5.79))
        self.assertEqual((rpe, mult, rec), (0.0, 1.0, False))
        self.assertTrue(any("targets hold" in r for r in reasons))

    def test_a_short_night_with_low_readiness_cuts_load_and_rpe(self):
        rpe, mult, rec, reasons = decide(self._read(today_sleep=5.5, readiness=2))
        self.assertEqual(rpe, -1.0)
        self.assertAlmostEqual(mult, sleep_multiplier(5.5))
        self.assertFalse(rec)

    def test_low_readiness_alone_lowers_rpe(self):
        rpe, mult, rec, reasons = decide(self._read(readiness=2))
        self.assertEqual((rpe, mult, rec), (-1.0, 1.0, False))
        self.assertTrue(any("outranks the watch" in r for r in reasons))

    def test_two_short_nights_lower_rpe_and_gate_the_cut(self):
        rows = _rows(hrv=40)
        for i, r in enumerate(rows[:-7]):
            r["hrv"] = 40 * (1 + 0.08 * ((i % 4) - 1.5))
        rows[-1]["sleep_hours"] = 5.6
        rows[-2]["sleep_hours"] = 5.8
        read = build_read(rows, "2026-09-11")
        self.assertTrue(read.two_short_nights)
        rpe, mult, rec, reasons = decide(read)
        self.assertEqual(rpe, -1.0)
        self.assertLess(mult, 1.0)

    def test_a_recovery_session_needs_two_hard_signals(self):
        rows = _rows(hrv=40)
        for i, r in enumerate(rows[:-7]):
            r["hrv"] = 40 * (1 + 0.08 * ((i % 4) - 1.5))
        for r in rows[-7:]:
            r["hrv"] = 30.0
        rows[-1]["sleep_hours"] = 4.5
        read = build_read(rows, "2026-09-11")
        self.assertTrue(read.hrv_well_below and read.sleep_very_short)
        rpe, mult, rec, reasons = decide(read)
        self.assertTrue(rec)
        # The same HRV with a good night and no readiness is an adjustment, not a switch.
        rows[-1]["sleep_hours"] = 7.5
        rpe, mult, rec, reasons = decide(build_read(rows, "2026-09-11"))
        self.assertFalse(rec)
        self.assertEqual(rpe, -1.0)

    def test_the_read_is_stated_for_the_coach(self):
        text = format_read(self._read(today_sleep=5.79))
        self.assertIn("TODAY'S RECOVERY READ", text)
        self.assertIn("HRV: 7-day average", text)
        self.assertIn("Sleep: 5.79h", text)
        self.assertIn("Readiness: not tapped", text)
        self.assertIn("DECISION: full session as planned", text)

    def test_prescribe_consumes_the_read(self):
        from prescribe import recovery_adjustment
        from recovery import read_as_dict
        adj = recovery_adjustment({"hrv": 35, "hrv_avg": 40, "sleep_hours": 5.79,
                                   "read": read_as_dict(self._read(today_sleep=5.79))})
        self.assertEqual((adj.rpe_delta, adj.load_multiplier, adj.recovery_session), (0.0, 1.0, False))
        # Without a read the percentage rules still apply.
        legacy = recovery_adjustment({"hrv": 35, "hrv_avg": 40, "sleep_hours": 5.79})
        self.assertEqual(legacy.load_multiplier, 0.95)
