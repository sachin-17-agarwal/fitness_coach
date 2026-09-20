"""Idempotent chat delivery: a message resent after the phone dropped the
connection returns the reply already written, waits while the coach is still
on it, and never runs the coach twice."""

import json
import unittest
from datetime import datetime, timedelta
from unittest.mock import patch

import delivery
import webhook


class _Settings:
    app_api_token = "tok"


HEADERS = {"Authorization": "Bearer tok"}


class _Rows:
    """A conversations table that answers find_delivery and records writes."""
    def __init__(self, rows):
        self.rows = rows
        self.updated = []

    def table(self, name):
        assert name == "conversations"
        return self

    def select(self, *_): return self
    def eq(self, field, value):
        self._eq = (field, value); return self
    def order(self, *_): return self
    def update(self, values):
        self._update = values; return self

    def execute(self):
        if getattr(self, "_update", None) is not None:
            self.updated.append((self._eq, self._update)); self._update = None
            return type("R", (), {"data": []})()
        field, value = self._eq
        return type("R", (), {"data": [r for r in self.rows if r.get(field) == value]})()


def _now():
    return datetime(2026, 9, 20, 10, 0, 0)


class DeliveryStateTests(unittest.TestCase):
    def setUp(self):
        delivery._inflight_memory.clear()

    def test_an_answered_exchange_is_returned_not_rerun(self):
        rows = [{"id": 1, "role": "user", "content": "Logged set 2", "created_at": "2026-09-20T09:58:00", "client_id": "abc"},
                {"id": 2, "role": "assistant", "content": "Next: 100kg x10", "created_at": "2026-09-20T09:58:20", "client_id": "abc"}]
        with patch.object(delivery, "get_supabase", return_value=_Rows(rows)), patch.object(delivery, "now_local", _now):
            state, answered = delivery.check("abc")
        self.assertEqual(state, "answered")
        self.assertEqual(answered["content"], "Next: 100kg x10")

    def test_a_fresh_marker_means_in_flight_and_a_stale_one_means_new(self):
        fresh = [{"id": 1, "role": "user", "content": "x", "created_at": "2026-09-20T09:59:00", "client_id": "abc"}]
        stale = [{"id": 1, "role": "user", "content": "x", "created_at": "2026-09-20T09:50:00", "client_id": "abc"}]
        with patch.object(delivery, "get_supabase", return_value=_Rows(fresh)), patch.object(delivery, "now_local", _now):
            self.assertEqual(delivery.check("abc")[0], "in_flight")
        with patch.object(delivery, "get_supabase", return_value=_Rows(stale)), patch.object(delivery, "now_local", _now):
            self.assertEqual(delivery.check("abc")[0], "new")

    def test_without_the_column_the_process_remembers_what_is_in_flight(self):
        class NoColumn(_Rows):
            def execute(self):
                raise RuntimeError("column client_id does not exist")
        store = NoColumn([])
        with patch.object(delivery, "get_supabase", return_value=store), patch.object(delivery, "now_local", _now), \
             patch.object(delivery, "save_conversation_message") as save:
            self.assertEqual(delivery.check("abc")[0], "new")
            delivery.claim("abc", "Logged set 2")
            self.assertEqual(delivery.check("abc")[0], "in_flight")
            delivery.release("abc")
            self.assertEqual(delivery.check("abc")[0], "new")
        save.assert_called_once_with("user", "Logged set 2", client_id="abc")

    def test_claiming_a_stale_marker_refreshes_it_instead_of_doubling_it(self):
        rows = [{"id": 7, "role": "user", "content": "x", "created_at": "2026-09-20T09:50:00", "client_id": "abc"}]
        store = _Rows(rows)
        with patch.object(delivery, "get_supabase", return_value=store), patch.object(delivery, "now_local", _now), \
             patch.object(delivery, "save_conversation_message") as save:
            delivery.claim("abc", "x")
        save.assert_not_called()
        self.assertEqual(store.updated[0][0], ("id", 7))


class ChatRouteTests(unittest.TestCase):
    def setUp(self):
        self.client = webhook.app.test_client()
        delivery._inflight_memory.clear()

    def _post(self, body):
        return self.client.post("/api/chat", headers=HEADERS, data=json.dumps(body), content_type="application/json")

    def test_a_new_message_is_claimed_processed_and_released_with_its_id(self):
        calls = {}

        def handle(text, memory, **kw):
            calls.update(kw); calls["text"] = text
            return "Next: 100kg x10"

        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("webhook.load_memory", return_value={"mesocycle_week": 1, "mesocycle_day": 1}), \
             patch("webhook.handle_incoming_message", side_effect=handle), \
             patch("delivery.check", return_value=("new", None)), \
             patch("delivery.claim") as claim, patch("delivery.release") as release:
            res = self._post({"message": "Logged set 2", "client_id": "abc"})
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.get_json()["response"], "Next: 100kg x10")
        self.assertNotIn("recovered", res.get_json())
        claim.assert_called_once_with("abc", "Logged set 2")
        release.assert_called_once_with("abc")
        # The marker IS the user turn: the handler must not save it again, and tags its reply.
        self.assertFalse(calls["save_user"])
        self.assertEqual(calls["client_id"], "abc")

    def test_a_resend_of_an_answered_message_returns_the_reply_without_the_coach(self):
        answered = {"id": 2, "role": "assistant", "content": "Next: 100kg x10"}
        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("webhook.load_memory", return_value={"mesocycle_week": 1, "mesocycle_day": 2}), \
             patch("webhook.handle_incoming_message") as handle, \
             patch("delivery.check", return_value=("answered", answered)):
            res = self._post({"message": "Logged set 2", "client_id": "abc"})
        self.assertEqual(res.status_code, 200)
        body = res.get_json()
        self.assertEqual((body["response"], body["recovered"], body["mesocycle_day"]), ("Next: 100kg x10", True, 2))
        handle.assert_not_called()

    def test_a_resend_while_the_coach_is_still_thinking_gets_202(self):
        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("webhook.handle_incoming_message") as handle, \
             patch("delivery.check", return_value=("in_flight", None)):
            res = self._post({"message": "Logged set 2", "client_id": "abc"})
        self.assertEqual(res.status_code, 202)
        self.assertEqual(res.get_json()["status"], "processing")
        handle.assert_not_called()

    def test_a_message_without_an_id_behaves_as_before(self):
        calls = {}

        def handle(text, memory, **kw):
            calls.update(kw); return "ok"

        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("webhook.load_memory", return_value={}), \
             patch("webhook.handle_incoming_message", side_effect=handle), \
             patch("delivery.check") as check:
            res = self._post({"message": "hello"})
        self.assertEqual(res.status_code, 200)
        check.assert_not_called()
        self.assertTrue(calls["save_user"])
        self.assertIsNone(calls["client_id"])

    def test_a_failed_coach_releases_the_id_so_the_next_try_runs(self):
        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("webhook.load_memory", return_value={}), \
             patch("webhook.handle_incoming_message", side_effect=RuntimeError("model down")), \
             patch("delivery.check", return_value=("new", None)), \
             patch("delivery.claim"), patch("delivery.release") as release:
            res = self._post({"message": "Logged set 2", "client_id": "abc"})
        self.assertEqual(res.status_code, 502)
        release.assert_called_once_with("abc")


class SaveFallbackTests(unittest.TestCase):
    def test_a_store_without_the_column_still_gets_the_turn(self):
        import memory as mem

        class Store:
            def __init__(self): self.rows = []
            def table(self, _): return self
            def insert(self, row): self._row = row; return self
            def execute(self):
                if "client_id" in self._row:
                    raise RuntimeError("column client_id does not exist")
                self.rows.append(self._row)
                return type("R", (), {"data": [{"id": 5}]})()

        store = Store()
        with patch.object(mem, "get_supabase", return_value=store):
            self.assertEqual(mem.save_conversation_message("user", "hi", client_id="abc"), 5)
        self.assertEqual(store.rows[0]["content"], "hi")
        self.assertNotIn("client_id", store.rows[0])
