"""Session shape (stage 3 of docs/DECISION_CAPTURE.md): the Substitute and
Order grammar, recorded rows applied inside parse_session_template, the
block horizon."""
import unittest
import blockfix  # noqa: F401  pins the block to four weeks for the legacy rules
from unittest.mock import patch

import decisions
import shape

SUB = "Substitute: Dips -> Overhead Cable Extension | this block | elbow"
SUB_STANDING = "Substitute: Barbell Row -> Chest-Supported Row | standing | lower back"
ORDER = "Order: Push | Machine Shoulder Press first | shoulder warm before pressing"

PROMPT = """*PUSH — 8 working sets*
Machine Chest Press 2 · Incline Press 2 · Dips 2 · Machine Shoulder Press 2
"""


class GrammarTests(unittest.TestCase):
    def test_kinds_subjects_and_words(self):
        self.assertEqual(decisions.kind_of(SUB), "substitute")
        self.assertEqual(decisions.kind_of(ORDER), "order")
        self.assertIsNone(decisions.kind_of("Substitute: Dips -> Cable | next week | why"))
        self.assertIsNone(decisions.kind_of("Order: Push | Dips | why"))
        self.assertEqual(decisions.subject_of(SUB), "dips")
        self.assertEqual(decisions.subject_of(ORDER), "push")
        self.assertEqual(decisions.describe(SUB), "Dips → Overhead Cable Extension for this block — elbow")
        self.assertEqual(decisions.describe(SUB_STANDING), "Barbell Row → Chest-Supported Row from now on — lower back")
        self.assertEqual(decisions.describe(ORDER), "Push: Machine Shoulder Press first — shoulder warm before pressing")

    def test_proposed_lines_in_the_new_grammar_are_captured(self):
        got = decisions.parse_proposed(f"Agreed.\nProposed: {SUB}\nProposed: {ORDER}\n")
        self.assertEqual([p["kind"] for p in got], ["substitute", "order"])
        self.assertTrue(decisions.has_recordable_line(f"{SUB}\n"))

    def test_recording_a_shape_line_only_clears_the_cache(self):
        with patch("shape.invalidate") as inv:
            self.assertTrue(decisions.apply_line(SUB, "PROMPT"))
            self.assertTrue(decisions.apply_line(ORDER, "PROMPT"))
        self.assertEqual(inv.call_count, 2)


SHAPE = {"substitutes": [{"from": "Dips", "to": "Overhead Cable Extension", "horizon": "this block", "why": "elbow"}],
         "orders": {"push": {"session": "Push", "first": "Machine Shoulder Press", "why": "shoulder warm before pressing"}}}


class ApplyTests(unittest.TestCase):
    PAIRS = [("Machine Chest Press", 2), ("Incline Press", 2), ("Dips", 2), ("Machine Shoulder Press", 2)]

    def test_substitute_keeps_the_slot_and_order_leads(self):
        self.assertEqual(shape.apply(self.PAIRS, "Push", SHAPE),
                         [("Machine Shoulder Press", 2), ("Machine Chest Press", 2), ("Incline Press", 2),
                          ("Overhead Cable Extension", 2)])

    def test_other_sessions_and_empty_shape_are_untouched(self):
        self.assertEqual(shape.apply(self.PAIRS, "Pull", SHAPE)[0], ("Machine Chest Press", 2))
        self.assertEqual(shape.apply(self.PAIRS, "Push", {"substitutes": [], "orders": {}}), self.PAIRS)

    def test_template_readers_see_the_shaped_template(self):
        from coach_parsing import format_session_template, parse_session_template
        with patch("shape.recorded_shape", return_value=SHAPE):
            pairs, total = parse_session_template(PROMPT, "Push")
            self.assertEqual([n for n, _ in pairs][0], "Machine Shoulder Press")
            self.assertIn("Overhead Cable Extension", [n for n, _ in pairs])
            self.assertEqual(total, 8)
            text = format_session_template(PROMPT, "Push")
        self.assertIn("Recorded session shape applied above: Dips -> Overhead Cable Extension (this block; elbow); "
                      "Machine Shoulder Press first (shoulder warm before pressing)", text)

    def test_without_a_store_the_template_is_as_written(self):
        from coach_parsing import parse_session_template
        with patch("shape.get_supabase", return_value=None):
            shape.invalidate()
            pairs, _ = parse_session_template(PROMPT, "Push")
        self.assertEqual([n for n, _ in pairs], ["Machine Chest Press", "Incline Press", "Dips", "Machine Shoulder Press"])


class HorizonTests(unittest.TestCase):
    def _rows(self):
        return [{"line": SUB, "kind": "substitute", "answered_at": "2026-09-10T10:00:00+10:00"},
                {"line": SUB_STANDING, "kind": "substitute", "answered_at": "2026-09-10T10:00:00+10:00"},
                {"line": ORDER, "kind": "order", "answered_at": "2026-09-20T10:00:00+10:00"}]

    def _load(self, block_start):
        from unittest.mock import MagicMock
        sb = MagicMock()
        sb.table.return_value.select.return_value.in_.return_value.eq.return_value.order.return_value.execute.return_value.data = self._rows()
        with patch("shape.get_supabase", return_value=sb), patch("shape._block_start", return_value=block_start):
            return shape._load()

    def test_this_block_lapses_at_the_rollover_standing_does_not(self):
        current = self._load("2026-09-02")
        self.assertEqual([s["from"] for s in current["substitutes"]], ["Dips", "Barbell Row"])
        self.assertIn("push", current["orders"])
        rolled = self._load("2026-09-15")
        self.assertEqual([s["from"] for s in rolled["substitutes"]], ["Barbell Row"])
        self.assertIn("push", rolled["orders"])


class ReviewFixTests(unittest.TestCase):
    def test_clear_forms(self):
        self.assertEqual(decisions.kind_of("Substitute: Dips | clear"), "substitute")
        self.assertEqual(decisions.kind_of("Order: Push | clear"), "order")
        self.assertEqual(decisions.describe("Substitute: Dips | clear"), "Dips: substitution cleared, back in the template")
        self.assertEqual(decisions.describe("Order: Push | clear"), "Push: order cleared, template order again")

    def _load(self, rows, block_start="2026-09-02"):
        from unittest.mock import MagicMock
        sb = MagicMock()
        sb.table.return_value.select.return_value.in_.return_value.eq.return_value.order.return_value.execute.return_value.data = rows
        with patch("shape.get_supabase", return_value=sb), patch("shape._block_start", return_value=block_start):
            return shape._load()

    def test_a_newer_clear_ends_the_shape(self):
        rows = [{"line": "Substitute: Dips | clear", "kind": "substitute", "answered_at": "2026-09-22T00:00:00+00:00"},
                {"line": "Order: Push | clear", "kind": "order", "answered_at": "2026-09-22T00:00:00+00:00"},
                {"line": SUB_STANDING, "kind": "substitute", "answered_at": "2026-09-10T00:00:00+00:00"},
                {"line": SUB, "kind": "substitute", "answered_at": "2026-09-10T00:00:00+00:00"},
                {"line": ORDER, "kind": "order", "answered_at": "2026-09-10T00:00:00+00:00"}]
        got = self._load(rows)
        self.assertEqual([s["from"] for s in got["substitutes"]], ["Barbell Row"])
        self.assertEqual(got["orders"], {})

    def test_the_block_horizon_reads_the_local_date(self):
        # 08:30 Sydney on the block's first day is 22:30 UTC the day before.
        rows = [{"line": SUB, "kind": "substitute", "answered_at": "2026-09-21T22:30:00+00:00"}]
        self.assertEqual(len(self._load(rows, "2026-09-22")["substitutes"]), 1)
        self.assertEqual(len(self._load(rows, "2026-09-23")["substitutes"]), 0)

    def test_recorded_is_said_only_once_the_row_is_stored(self):
        from unittest.mock import MagicMock
        sb = MagicMock()
        sb.table.return_value.update.return_value.eq.return_value.execute.side_effect = RuntimeError("down")
        with patch("decisions.get_supabase", return_value=sb), patch("shape.invalidate"):
            text = decisions.answer({"id": 1, "line": SUB}, "record", "PROMPT")
        self.assertIn("nothing was recorded", text)
        sb2 = MagicMock()
        with patch("decisions.get_supabase", return_value=sb2), patch("shape.invalidate"):
            text = decisions.answer({"id": 1, "line": SUB}, "record", "PROMPT")
        self.assertTrue(text.startswith("Recorded: Dips → Overhead Cable Extension"))
