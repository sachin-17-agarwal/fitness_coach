"""The block's length is a setting (24 Sep 2026): five weeks on a bulk (four
loading and a deload), four on a cut. Every week rule reads data.block_weeks();
the legacy suite pins it to four (blockfix.py); these tests cover five, the
switch, and the deload-by-sets rule that came in with it."""
import unittest
from unittest.mock import MagicMock, patch

try:
    import blockfix  # noqa: F401
except ImportError:
    from tests import blockfix  # noqa: F401
import data
from prescribe import COMPOUND, ISOLATION, PriorSet, prescribe_exercise, targets_for, deload_set_count


def five():
    return patch.object(data, "block_weeks", lambda: 5)


class WaveTests(unittest.TestCase):
    def test_four_week_block(self):
        self.assertEqual([targets_for(w)["name"] for w in (1, 2, 3, 4)],
                         ["Baseline", "Volume progression", "Peak by load", "Deload"])
        self.assertEqual([targets_for(w)["backoff"] for w in (1, 2, 3)], [8.0, 8.0, 8.0])
        with self.assertRaises(ValueError):
            targets_for(5)

    def test_five_week_block(self):
        with five():
            self.assertEqual([targets_for(w)["name"] for w in (1, 2, 3, 4, 5)],
                             ["Baseline", "Volume progression", "Peak by reps", "Peak by load", "Deload"])
            self.assertEqual([targets_for(w)["top"] for w in (1, 2, 3, 4, 5)], [8.0, 8.0, 9.0, 9.0, 7.0])
            self.assertEqual(data.peak_week(), 4)
            self.assertEqual(data.deload_week(), 5)
            self.assertEqual(data.peak_weeks(), (3, 4))
        self.assertEqual(data.peak_weeks(), (3,))

    def test_week_four_peaks_on_five_and_deloads_on_four(self):
        prior = PriorSet(80.0, 10, 9.0, week=3)
        four = prescribe_exercise("Cable Row", 3, COMPOUND, 4, PriorSet(80.0, 8, 9.0, week=3), set())
        self.assertEqual((four.working[0].rpe, four.backoff), (7.0, []))
        with five():
            p = prescribe_exercise("Cable Row", 3, COMPOUND, 4, prior, set())
            self.assertEqual(p.working[0].rpe, 9.0)
            self.assertEqual(len(p.backoff), 2)
            self.assertTrue(all(b.rpe == 8.0 for b in p.backoff))
            d = prescribe_exercise("Cable Row", 3, COMPOUND, 5, PriorSet(82.5, 8, 9.0, week=4), set())
            self.assertEqual((d.working[0].weight_kg, d.working[0].rpe, d.backoff), (82.5, 7.0, []))
            self.assertTrue(any("back-offs are dropped" in r for r in d.reasons))


class DeloadBySetsTests(unittest.TestCase):
    def test_counts(self):
        self.assertEqual(deload_set_count(3), 1)
        self.assertEqual(deload_set_count(2), 1)
        self.assertEqual(deload_set_count(1), 1)
        self.assertEqual(deload_set_count(3, straight=True), 2)
        self.assertEqual(deload_set_count(4, straight=True), 2)

    def test_the_template_readers_see_the_deload_counts(self):
        from coach_parsing import deload_counts, format_session_template, parse_session_template
        prompt = "*LEGS — 8 working sets*\nLeg Press 3 · Leg Extension 2 · Machine Calf Raise 3\n"
        self.assertEqual(parse_session_template(prompt, "Legs")[0], [("Leg Press", 3), ("Leg Extension", 2), ("Machine Calf Raise", 3)])
        pairs, total = parse_session_template(prompt, "Legs", week=4)
        self.assertEqual(pairs, [("Leg Press", 1), ("Leg Extension", 1), ("Machine Calf Raise", 2)])
        self.assertEqual(total, 4)
        self.assertEqual(parse_session_template(prompt, "Legs", week=3)[0][0], ("Leg Press", 3))
        self.assertIn("DELOAD WEEK", format_session_template(prompt, "Legs", week=4))
        self.assertNotIn("DELOAD WEEK", format_session_template(prompt, "Legs", week=1))
        self.assertEqual(deload_counts([("Cable Crunch", 3)]), [("Cable Crunch", 2)])

    def test_no_readiness_cut_on_the_deload(self):
        from prescribe import prescribe_session
        plan = (("Leg Press", 3, COMPOUND),)
        history = {"Leg Press": PriorSet(220.0, 10, 9.0, week=3)}
        tired = {"hrv": 51.6, "hrv_avg": 60, "sleep_hours": 7.5, "resting_hr": 55, "resting_hr_baseline": 55}
        [p] = prescribe_session(plan, 4, history, recovery=tired)
        self.assertEqual((p.working[0].weight_kg, p.working[0].rpe, p.backoff), (220.0, 7.0, []))
        self.assertTrue(any("not applied" in r for r in p.recovery_reasons))
        [p3] = prescribe_session(plan, 3, history, recovery=tired)
        self.assertEqual(p3.working[0].rpe, 8.0, "a loading week still takes the cut")


class SettingTests(unittest.TestCase):
    def test_the_memory_row_wins_then_the_setting(self):
        saved = dict(data._block_cache)
        try:
            data.invalidate_block_weeks()
            sb = MagicMock()
            sb.table.return_value.select.return_value.eq.return_value.execute.return_value.data = [{"value": "4"}]
            with patch.object(data, "get_supabase", return_value=sb):
                self.assertEqual(data.block_weeks(), 4)
            data.invalidate_block_weeks()
            sb.table.return_value.select.return_value.eq.return_value.execute.return_value.data = []
            with patch.object(data, "get_supabase", return_value=sb):
                self.assertEqual(data.block_weeks(), int(data.get_settings().block_weeks))
            data.invalidate_block_weeks()
            sb.table.return_value.select.return_value.eq.return_value.execute.return_value.data = [{"value": "9"}]
            with patch.object(data, "get_supabase", return_value=sb):
                self.assertIn(data.block_weeks(), (4, 5, 6), "nonsense in the row falls to the setting")
        finally:
            data._block_cache.update(saved)

    def test_the_rollover_uses_the_block_length(self):
        from memory import load_memory
        with patch("memory.get_supabase") as sb:
            sb.return_value.table.return_value.select.return_value.execute.return_value.data = [
                {"key": "mesocycle_week", "value": "6"}, {"key": "mesocycle_day", "value": "1"}]
            self.assertEqual(load_memory()["mesocycle_week"], 2)   # four-week block: 6 -> 2
            with five():
                self.assertEqual(load_memory()["mesocycle_week"], 1)  # five-week block: 6 -> 1
