"""Logged sets carry their phase (migration 014). The card and the set reply
count by it; rows without one fall back to position."""
import unittest
import blockfix  # noqa: F401  pins the block to four weeks for the legacy rules
from unittest.mock import MagicMock, patch

from plan import last_logged_slot, latest_logged_sets, next_set_index, owed_set_decision, phase_counts

STORED = {"working": [{"load_kg": 270, "reps_low": 5, "reps_high": 9, "rpe": 7}],
          "backoff": [{"load_kg": 215, "reps_low": 8, "reps_high": 12, "rpe": 7},
                      {"load_kg": 215, "reps_low": 8, "reps_high": 12, "rpe": 7}]}
STRAIGHT = {"working": [{"load_kg": 60, "reps_low": 10, "reps_high": 12, "rpe": 8}] * 3, "backoff": []}


def row(phase=None, **kw):
    r = {"actual_weight_kg": 215, "actual_reps": 10, "actual_rpe": 7}
    r.update(kw)
    if phase:
        r["phase"] = phase
    return r


class PhaseCountTests(unittest.TestCase):
    def test_a_skipped_working_set_does_not_relabel_the_back_offs(self):
        rows = [row("backoff")]
        self.assertEqual(phase_counts(rows, STORED), {"working": 0, "backoff": 1})
        # The next set is the second back-off, not the working set that was skipped.
        self.assertEqual(next_set_index(rows, STORED), 0)  # working slot still open, so the card points there
        self.assertEqual(last_logged_slot(rows, STORED), ("backoff", 0))

    def test_rows_without_a_phase_keep_the_position_rule(self):
        rows = [row(), row()]
        self.assertEqual(phase_counts(rows, STORED), {"working": 1, "backoff": 1})
        self.assertEqual(next_set_index(rows, STORED), 2)
        self.assertEqual(last_logged_slot(rows, STORED), ("backoff", 0))

    def test_mixed_rows(self):
        rows = [row("working", actual_weight_kg=270), row(), row("backoff")]
        self.assertEqual(phase_counts(rows, STORED), {"working": 1, "backoff": 2})
        self.assertEqual(next_set_index(rows, STORED), 3)

    def test_straight_sets(self):
        rows = [row("working"), row("working")]
        self.assertEqual(next_set_index(rows, STRAIGHT), 2)
        self.assertEqual(last_logged_slot(rows, STRAIGHT), ("working", 1))
        self.assertEqual(next_set_index([], STRAIGHT), 0)
        self.assertIsNone(last_logged_slot([], STRAIGHT))


class OwedByPhaseTests(unittest.TestCase):
    def test_the_owed_move_reads_the_slot_the_set_was_logged_under(self):
        # A back-off logged first (working skipped), 3 reps over its range at target RPE.
        rows = [row("backoff", actual_reps=15)]
        done = next_set_index(rows, STORED)
        self.assertEqual(done, 0)  # the skipped working set is still the next slot
        owed = owed_set_decision(rows[-1], STORED, done, last=last_logged_slot(rows, STORED))
        self.assertEqual(owed["decision"], "heavier")
        self.assertIn("8-12", owed["reason"])
        # Without the slot, position would have judged it against the 270kg working set and owed nothing.
        self.assertIsNone(owed_set_decision(rows[-1], STORED, 1))


class SelectFallbackTests(unittest.TestCase):
    def test_a_store_without_the_column_still_answers(self):
        sb = MagicMock()
        calls = []
        def select(columns):
            calls.append(columns)
            q = MagicMock()
            if "phase" in columns:
                q.eq.return_value.execute.side_effect = RuntimeError("column phase does not exist")
            else:
                q.eq.return_value.execute.return_value.data = [{"exercise": "Leg Press", "is_warmup": False,
                                                                 "actual_weight_kg": 270, "set_number": 1}]
            return q
        sb.table.return_value.select.side_effect = select
        with patch("plan.get_supabase", return_value=sb):
            rows = latest_logged_sets("s1", "Leg Press")
        self.assertEqual(len(rows), 1)
        self.assertEqual(len(calls), 2)
        self.assertIn("phase", calls[0])
