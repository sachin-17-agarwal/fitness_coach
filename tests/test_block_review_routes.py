"""The block review reaches the athlete on Home, not only in the briefing."""

import json
import unittest
try:
    import blockfix  # noqa: F401  pins the block to four weeks for the legacy rules
except ImportError:  # run as tests.test_x (CI), where tests/ is not on sys.path
    from tests import blockfix  # noqa: F401
from unittest.mock import patch

import webhook


class _Settings:
    app_api_token = "tok"


HEADERS = {"Authorization": "Bearer tok"}
ROW = {"id": 7, "status": "shown", "block_start": "2026-08-19", "dry_run": True,
       "narrative": "Strength held.", "proposals_list": [{"line": "Decision: Cable Crunch | clear", "rationale": ""}]}


class BlockReviewRouteTests(unittest.TestCase):
    def setUp(self):
        self.client = webhook.app.test_client()

    def test_home_prepares_the_review_when_it_is_due(self):
        """The briefing route used to be the only place that prepared it, and
        the briefing is never opened. Home's fetch prepares it with the same
        guards."""
        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("block_review.prepare_if_due", return_value=None) as prepare, \
             patch("block_review.latest_block_review", return_value=dict(ROW)), \
             patch("webhook.load_memory", return_value={"mesocycle_week": 1, "mesocycle_day": 1}), \
             patch("webhook.load_system_prompt_for_review", return_value="PROMPT"), \
             patch("coach.get_anthropic_client", return_value=object()):
            res = self.client.get("/api/block-review", headers=HEADERS)
        self.assertEqual(res.status_code, 200)
        prepare.assert_called_once()
        body = res.get_json()
        self.assertEqual(body["status"], "shown")
        self.assertTrue(body["dry_run"])
        self.assertIn("Strength held.", body["text"])
        self.assertEqual(body["proposals"][0]["line"], "Decision: Cable Crunch | clear")
        # The card renders structure, not the text blob.
        self.assertEqual(body["proposals"][0]["kind"], "standing decision")
        self.assertEqual(body["proposals"][0]["subject"], "Cable Crunch")
        self.assertTrue(body["proposals"][0]["detail"].startswith("Clear it"))
        self.assertEqual(body["sections"], [{"label": "", "body": "Strength held."}])
        self.assertEqual(body["window"], {"since": "2026-08-19", "until": None})
        self.assertEqual(body["lifts"], [])
        self.assertEqual(body["volume"], [])

    def test_a_failed_preparation_still_returns_the_latest_review(self):
        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("block_review.prepare_if_due", side_effect=RuntimeError("model down")), \
             patch("block_review.latest_block_review", return_value=dict(ROW)), \
             patch("webhook.load_memory", return_value={}), \
             patch("webhook.load_system_prompt_for_review", return_value="PROMPT"), \
             patch("coach.get_anthropic_client", return_value=object()):
            res = self.client.get("/api/block-review", headers=HEADERS)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.get_json()["status"], "shown")

    def test_the_card_answers_through_the_chat_path(self):
        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("block_review.latest_block_review", return_value=dict(ROW)), \
             patch("block_review.answer_block_review", return_value="Noted (dry run)") as answer, \
             patch("webhook.load_system_prompt_for_review", return_value="PROMPT"):
            res = self.client.post("/api/block-review/answer", headers=HEADERS,
                                   data=json.dumps({"text": "approve all"}), content_type="application/json")
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.get_json(), {"status": "answered", "message": "Noted (dry run)"})
        answer.assert_called_once()
        self.assertEqual(answer.call_args[0][1], "approve all")

    def test_nothing_open_is_a_conflict_not_a_silent_record(self):
        answered = dict(ROW, status="answered")
        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("block_review.latest_block_review", return_value=answered), \
             patch("block_review.answer_block_review") as answer:
            res = self.client.post("/api/block-review/answer", headers=HEADERS,
                                   data=json.dumps({"text": "no"}), content_type="application/json")
        self.assertEqual(res.status_code, 409)
        answer.assert_not_called()

    def test_the_routes_need_the_app_token(self):
        with patch.object(webhook, "get_settings", return_value=_Settings()):
            self.assertEqual(self.client.get("/api/block-review").status_code, 401)
            self.assertEqual(self.client.post("/api/block-review/answer", json={"text": "no"}).status_code, 401)
