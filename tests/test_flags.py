"""Coach flags: the exchange kept whole, shared as Markdown, filed as an
issue when a token is set."""
import json
import unittest
from unittest.mock import MagicMock, patch

import flags
import webhook


class _Settings:
    app_api_token = "tok"
    github_flags_token = ""
    github_flags_repo = "o/r"


HEADERS = {"Authorization": "Bearer tok"}

ROW = {"created_at": "2026-09-23T21:14:03+10:00", "date": "2026-09-23", "exercise": "Standing Calf Raise",
       "note": "Said heavier, card did not move", "user_message": "Logged 125kg x12 @7",
       "coach_reply": "Take the last back-off heavier.\nRest 90s.", "card": "125kg x8-12 @8; back-off 100kg x10-12 @7",
       "logged_sets": [{"set_number": 1, "actual_weight_kg": 125, "actual_reps": 12, "actual_rpe": 7}],
       "contract": {"reply_kind": "set_reply", "record": [{"step": "numbers", "action": "logged", "detail": "200"}]}}


class FormatTests(unittest.TestCase):
    def test_one_flag_carries_every_part(self):
        text = flags.format_flag(ROW)
        for part in ["### 2026-09-23 21:14 · Standing Calf Raise", "**What was wrong:** Said heavier",
                     "**Athlete:** Logged 125kg x12 @7", "> Take the last back-off heavier.", "> Rest 90s.",
                     "**Card (stored plan):** 125kg x8-12 @8", "**Logged on this lift:** 125kg x12 @7",
                     "**Reply contract:** set_reply — numbers:logged(200)"]:
            self.assertIn(part, text)

    def test_json_columns_come_back_as_text_from_the_store(self):
        row = {**ROW, "logged_sets": json.dumps(ROW["logged_sets"]), "contract": json.dumps(ROW["contract"])}
        text = flags.format_flag(row)
        self.assertIn("125kg x12 @7", text)
        self.assertIn("numbers:logged(200)", text)

    def test_many_and_none(self):
        self.assertIn("# Coach flags (2)", flags.format_flags([ROW, ROW]))
        self.assertIn("None in this period", flags.format_flags([]))


class RememberTests(unittest.TestCase):
    def test_recall_by_id_then_newest(self):
        flags.remember("abc", "prose", [{"step": "numbers", "action": "rewritten", "detail": "200"}], "Leg Press")
        flags.remember("def", "set_reply", [], "Calf Raise")
        self.assertEqual(flags.recall("abc")["record"][0]["detail"], "200")
        self.assertEqual(flags.recall("abc")["exercise"], "Leg Press")
        self.assertEqual(flags.recall(None)["reply_kind"], "set_reply")
        self.assertEqual(flags.recall("unknown")["reply_kind"], "set_reply")


class RecordTests(unittest.TestCase):
    def _supabase(self):
        sb = MagicMock()
        sb.table.return_value.insert.return_value.execute.return_value.data = [{"id": 7}]
        return sb

    def test_stores_the_exchange_the_card_the_sets_and_the_record(self):
        sb = self._supabase()
        flags.remember("cid", "set_reply", [{"step": "set_counts", "action": "trimmed", "detail": "x"}], "Standing Calf Raise")
        with patch("flags.get_supabase", return_value=sb), \
             patch("flags.get_settings", return_value=_Settings()), \
             patch("workout.get_workout_state", return_value={"current_session_id": "s1", "current_exercise_name": "Standing Calf Raise"}), \
             patch("delivery.find_delivery", return_value={"user": {"content": "Logged 125 x12"}, "assistant": {"content": "Heavier."}}), \
             patch("plan.load_today_plan", return_value={"working": [{"load_kg": 125, "reps_low": 8, "reps_high": 12, "rpe": 8}], "backoff": []}), \
             patch("plan.latest_logged_sets", return_value=[{"set_number": 1, "actual_weight_kg": 125.0, "actual_reps": 12, "actual_rpe": 7.0, "exercise": "x"}]):
            out = flags.record_flag("card did not move", None, "cid")
        row = sb.table.return_value.insert.call_args.args[0]
        self.assertEqual(row["exercise"], "Standing Calf Raise")
        self.assertEqual(row["user_message"], "Logged 125 x12")
        self.assertEqual(row["coach_reply"], "Heavier.")
        self.assertIn("125kg x8-12", row["card"])
        self.assertEqual(row["logged_sets"], [{"set_number": 1, "actual_weight_kg": 125.0, "actual_reps": 12, "actual_rpe": 7.0}])
        self.assertEqual(row["contract"]["record"][0]["action"], "trimmed")
        self.assertEqual(out["id"], 7)
        self.assertTrue(out["stored"])
        self.assertIsNone(out["issue_url"])
        self.assertIn("card did not move", out["summary"])

    def test_no_store_still_returns_the_summary(self):
        with patch("flags.get_supabase", return_value=None), patch("flags.get_settings", return_value=_Settings()), \
             patch("workout.get_workout_state", return_value={}), \
             patch("memory.load_today_conversation", return_value=[{"role": "user", "content": "q"}, {"role": "assistant", "content": "a"}]):
            out = flags.record_flag("", None, None)
        self.assertFalse(out["stored"])
        self.assertIn("**Athlete:** q", out["summary"])
        self.assertIn("> a", out["summary"])

    def test_issue_filed_only_with_a_token(self):
        s = _Settings(); s.github_flags_token = "t"
        resp = MagicMock(); resp.read.return_value = b'{"html_url": "https://github.com/o/r/issues/1"}'
        resp.__enter__.return_value = resp
        with patch("flags.get_settings", return_value=s), patch("flags.urllib.request.urlopen", return_value=resp) as opened:
            self.assertEqual(flags._file_issue(ROW), "https://github.com/o/r/issues/1")
        req = opened.call_args.args[0]
        self.assertEqual(req.full_url, "https://api.github.com/repos/o/r/issues")
        body = json.loads(req.data.decode())
        self.assertEqual(body["labels"], ["coach-flag"])
        self.assertIn("Standing Calf Raise", body["title"])
        with patch("flags.get_settings", return_value=_Settings()):
            self.assertIsNone(flags._file_issue(ROW))


class RouteTests(unittest.TestCase):
    def setUp(self):
        self.client = webhook.app.test_client()

    def test_flag_needs_the_token(self):
        with patch.object(webhook, "get_settings", return_value=_Settings()):
            self.assertEqual(self.client.post("/api/flag", json={}).status_code, 401)
            self.assertEqual(self.client.get("/api/flags").status_code, 401)

    def test_flag_and_flags(self):
        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("flags.record_flag", return_value={"id": 1, "issue_url": None, "summary": "s", "stored": True}) as rec, \
             patch("flags.list_flags", return_value=[ROW]):
            r = self.client.post("/api/flag", json={"note": "wrong", "exercise": "Leg Press", "client_id": "cid"}, headers=HEADERS)
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.get_json()["id"], 1)
            rec.assert_called_once_with(note="wrong", exercise="Leg Press", client_id="cid")
            r = self.client.get("/api/flags?days=7", headers=HEADERS)
            self.assertEqual(r.get_json()["count"], 1)
            self.assertIn("# Coach flags (1)", r.get_json()["markdown"])
