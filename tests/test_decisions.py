"""Decisions captured when reached: the grammar, the detector, the answer
window, the routes and the report section (docs/DECISION_CAPTURE.md)."""

import json
import unittest
import blockfix  # noqa: F401  pins the block to four weeks for the legacy rules
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import decisions
import webhook


EMPH = "Emphasis-next: triceps | overhead cable extension, weakest of the push muscles this block"
CAP = "Decision: Machine Shoulder Press | max load 70kg | shoulder niggle; progress by reps, RPE 8 cap"


class GrammarTests(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(decisions.kind_of(EMPH), "emphasis")
        self.assertEqual(decisions.kind_of(CAP), "constraint")
        self.assertEqual(decisions.kind_of("Decision: Cable Crunch | clear"), "constraint")
        self.assertIsNone(decisions.kind_of("Decision: Cable Crunch"))
        self.assertIsNone(decisions.kind_of("let's do triceps next block"))

    def test_proposed_lines_are_parsed_only_in_the_grammar(self):
        reply = ("Good session. Agreed — triceps get the slot next block.\n"
                 f"Proposed: {EMPH}\n"
                 "Proposed: something vague about calves\n"
                 f"Proposed: {CAP}")
        got = decisions.parse_proposed(reply)
        self.assertEqual([p["line"] for p in got], [EMPH, CAP])
        self.assertEqual([p["kind"] for p in got], ["emphasis", "constraint"])

    def test_describe_reads_in_plain_words(self):
        self.assertEqual(decisions.describe(EMPH),
                         "Next block's emphasis: triceps — overhead cable extension, weakest of the push muscles this block")
        self.assertEqual(decisions.describe(CAP), "Machine Shoulder Press: cap 70 kg — shoulder niggle; progress by reps, RPE 8 cap")
        self.assertEqual(decisions.describe("Decision: Cable Crunch | clear"), "Cable Crunch: cap cleared")

    def test_subject_folds_the_exercise_or_muscle(self):
        self.assertEqual(decisions.subject_of(CAP), "machineshoulderpress")
        self.assertEqual(decisions.subject_of(EMPH), "triceps")


class DetectorTests(unittest.TestCase):
    def test_lasting_phrases_carry_a_horizon_or_a_number(self):
        self.assertTrue(decisions.lasting_phrases("let's keep the leg curl at 110 for the rest of the block"))
        self.assertTrue(decisions.lasting_phrases("triceps and chest next block"))
        self.assertTrue(decisions.lasting_phrases("hold the shoulder press at 70 from now on"))
        self.assertTrue(decisions.lasting_phrases("cap it at 105"))
        self.assertFalse(decisions.lasting_phrases("that was a max effort set"))
        self.assertFalse(decisions.lasting_phrases("cap the reps at RPE 8 today"))
        self.assertFalse(decisions.lasting_phrases("110 x 16 rpe 7"))

    def test_a_recordable_line_in_the_reply_is_not_a_miss(self):
        self.assertTrue(decisions.has_recordable_line(f"Fine.\nProposed: {EMPH}"))
        self.assertTrue(decisions.has_recordable_line("Decision: Cable Crunch | clear"))
        self.assertFalse(decisions.has_recordable_line("Sure, triceps and chest it is. Rest up."))


class AnswerWindowTests(unittest.TestCase):
    def test_explicit_words_work_any_time(self):
        old = (datetime.now(timezone.utc) - timedelta(hours=5)).isoformat()
        self.assertEqual(decisions.parse_answer("record it", old), "record")
        self.assertEqual(decisions.parse_answer("not now", old), "decline")
        self.assertEqual(decisions.parse_answer("Record", None), "record")

    def test_a_bare_yes_counts_only_inside_the_window(self):
        recent = (datetime.now(timezone.utc) - timedelta(minutes=3)).isoformat()
        old = (datetime.now(timezone.utc) - timedelta(minutes=40)).isoformat()
        self.assertEqual(decisions.parse_answer("yes", recent), "record")
        self.assertEqual(decisions.parse_answer("no", recent), "decline")
        self.assertIsNone(decisions.parse_answer("yes", old))
        self.assertIsNone(decisions.parse_answer("yes", None))

    def test_ordinary_chat_is_not_an_answer(self):
        recent = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
        self.assertIsNone(decisions.parse_answer("yes but the machine was taken", recent))
        self.assertIsNone(decisions.parse_answer("110 x 12 rpe 8", recent))


class ApplyTests(unittest.TestCase):
    def test_record_applies_through_the_existing_paths(self):
        with patch("constraints.record_decisions") as rec, patch("weakpoints.set_next_emphasis") as emph, \
             patch("decisions.get_supabase", return_value=None):
            msg = decisions.answer({"id": 1, "line": CAP}, "record", "PROMPT", "card: record")
            rec.assert_called_once_with(CAP)
            self.assertTrue(msg.startswith("Recorded:"))
            msg = decisions.answer({"id": 2, "line": EMPH}, "record", "PROMPT")
            emph.assert_called_once()
            self.assertEqual(emph.call_args[0][1], "triceps")

    def test_decline_applies_nothing(self):
        with patch("constraints.record_decisions") as rec, patch("decisions.get_supabase", return_value=None):
            msg = decisions.answer({"id": 1, "line": CAP}, "decline", "PROMPT")
            rec.assert_not_called()
            self.assertTrue(msg.startswith("Not recorded:"))


class ReportTests(unittest.TestCase):
    def test_summary_and_section(self):
        rows = [
            {"line": EMPH, "kind": "emphasis", "source": "coach", "status": "recorded",
             "proposed_at": "2026-09-19T10:00:00+00:00", "answered_at": "2026-09-19T10:00:40+00:00"},
            {"line": CAP, "kind": "constraint", "source": "coach", "status": "declined",
             "proposed_at": "2026-09-20T10:00:00+00:00", "answered_at": "2026-09-20T10:02:00+00:00"},
            {"line": "keep the leg curl at 110 for the rest of the block", "kind": "detector", "source": "detector",
             "status": "missed", "phrase": "for the rest of the block", "reply_excerpt": "Got it.",
             "proposed_at": "2026-09-24T18:00:00+00:00"},
        ]
        s = decisions.summarise_captures(rows)
        self.assertEqual((s["proposed"], s["recorded"], s["declined"]), (2, 1, 1))
        self.assertEqual(len(s["missed"]), 1)
        self.assertEqual(s["median_answer_s"], 120)
        text = decisions.format_captures(s, 7)
        self.assertIn("Proposed **2** (coach 2)", text)
        self.assertIn("Missed 1", text)
        self.assertIn("for the rest of the block", text)
        self.assertIn("migration 009", decisions.format_captures(None, 7))


class _Settings:
    app_api_token = "tok"


HEADERS = {"Authorization": "Bearer tok"}


class RouteTests(unittest.TestCase):
    def setUp(self):
        self.client = webhook.app.test_client()

    def test_pending_lists_open_proposals_in_plain_words(self):
        rows = [{"id": 7, "line": EMPH, "kind": "emphasis", "source": "coach", "status": "proposed",
                 "session_id": None, "proposed_at": "2026-09-19T10:00:00+00:00", "text": decisions.describe(EMPH)}]
        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("decisions.open_captures", return_value=rows):
            res = self.client.get("/api/decision/pending", headers=HEADERS)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.get_json()["captures"][0]["text"], "Next block's emphasis: triceps — overhead cable extension, weakest of the push muscles this block")

    def test_answer_records_the_named_proposal(self):
        rows = [{"id": 7, "line": EMPH, "kind": "emphasis", "status": "proposed"}]
        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("decisions.open_captures", return_value=rows), \
             patch("decisions.answer", return_value="Recorded: x") as ans, \
             patch("webhook.load_system_prompt_for_review", return_value="PROMPT"):
            res = self.client.post("/api/decision/answer", headers=HEADERS, json={"id": 7, "answer": "record"})
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.get_json()["status"], "recorded")
        self.assertEqual(ans.call_args[0][1], "record")

    def test_answering_a_closed_proposal_is_a_conflict(self):
        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("decisions.open_captures", return_value=[]):
            res = self.client.post("/api/decision/answer", headers=HEADERS, json={"id": 7, "answer": "record"})
        self.assertEqual(res.status_code, 409)

    def test_routes_need_the_token(self):
        with patch.object(webhook, "get_settings", return_value=_Settings()):
            self.assertEqual(self.client.get("/api/decision/pending").status_code, 401)
