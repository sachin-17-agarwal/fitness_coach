"""The widget's number is the Home tab's number: the readiness formula ported
to the server, pinned to the Swift anchors, and the route that serves it."""

import json
import unittest
from unittest.mock import patch

import readiness
import webhook


class ReadinessFormulaTests(unittest.TestCase):
    def test_sleep_anchors_match_the_app(self):
        for hours, expected in ((8.5, 100), (8.0, 100), (7.5, 92), (7.0, 82), (6.0, 58), (5.0, 32), (4.0, 15), (3.0, 5), (2.0, 3)):
            with self.subTest(hours=hours):
                self.assertAlmostEqual(readiness.sleep_component(hours), expected, places=6)

    def test_hrv_and_rhr_anchors_match_the_app(self):
        self.assertEqual(readiness.hrv_component(1.10), 100)
        self.assertEqual(readiness.hrv_component(1.00), 85)
        self.assertEqual(readiness.hrv_component(0.90), 65)
        self.assertEqual(readiness.hrv_component(0.50), 5)
        self.assertEqual(readiness.rhr_component(0.90), 100)
        self.assertEqual(readiness.rhr_component(1.00), 85)
        self.assertEqual(readiness.rhr_component(1.05), 65)
        self.assertEqual(readiness.rhr_component(1.20), 10)

    def test_composite_weights_and_renormalisation(self):
        # 7h sleep (82) * .4 + HRV on baseline (85) * .4 + RHR on baseline (85) * .2 = 83.8 -> 84
        self.assertEqual(readiness.composite_score(7.0, 68, 68, 52, 52), 84)
        # Sleep alone: the other weights drop out.
        self.assertEqual(readiness.composite_score(7.0, None, None, None, None), 82)
        self.assertIsNone(readiness.composite_score(None, None, None, None, None))

    def test_zones_are_the_home_tabs(self):
        self.assertEqual(readiness.level_for(75), "green")
        self.assertEqual(readiness.level_for(74), "yellow")
        self.assertEqual(readiness.level_for(55), "yellow")
        self.assertEqual(readiness.level_for(54), "red")
        self.assertEqual(readiness.level_for(None), "unknown")

    def test_rows_to_readiness_carries_the_deltas(self):
        latest = {"date": "2026-09-17", "hrv": 68, "resting_hr": 52, "sleep_hours": 7.33}
        week = [latest, {"hrv": 60, "resting_hr": 54}, {"hrv": 64, "resting_hr": 53}]
        out = readiness.readiness_from_rows(latest, week)
        self.assertEqual(out["hrv_delta"], 4)      # 68 - 64
        self.assertEqual(out["rhr_delta"], -1)     # 52 - 53
        self.assertEqual(out["level"], "green")
        self.assertTrue(75 <= out["score"] <= 100)


class _Settings:
    app_api_token = "tok"


HEADERS = {"Authorization": "Bearer tok"}


class WidgetRouteTests(unittest.TestCase):
    def setUp(self):
        self.client = webhook.app.test_client()

    def test_the_verdict_names_the_day(self):
        self.assertEqual(webhook.widget_verdict("green", "Push", False), "READY — PUSH TODAY")
        self.assertEqual(webhook.widget_verdict("green", "Push", True), "READY — SESSION DONE")
        self.assertEqual(webhook.widget_verdict("yellow", "Legs", False), "STEADY — LEGS, AS PLANNED")
        self.assertEqual(webhook.widget_verdict("red", "Pull", False), "RUN DOWN — PULL, GO EASY")
        self.assertEqual(webhook.widget_verdict("unknown", "Pull", False), "NO RECOVERY DATA YET")

    def test_the_widget_read_is_one_payload(self):
        memory = {"mesocycle_week": "4", "mesocycle_day": "2",
                  webhook.WIDGET_STRENGTH_KEY: json.dumps({"median_gain_pct": 8.1, "lifts": 11})}
        ready = {"score": 82, "level": "green", "hrv": 68, "hrv_delta": 4, "sleep_hours": 7.33,
                 "resting_hr": 52, "rhr_delta": -1}
        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("webhook.load_memory", return_value=memory), \
             patch("readiness.readiness_today", return_value=ready), \
             patch("webhook._session_done_today", return_value=False):
            res = self.client.get("/api/widget", headers=HEADERS)
        self.assertEqual(res.status_code, 200)
        body = res.get_json()
        self.assertEqual(body["score"], 82)
        self.assertEqual(body["session_type"], "Push")        # day 2 of the rotation
        self.assertEqual(body["verdict"], "READY — PUSH TODAY")
        self.assertEqual(body["phase"], "DELOAD")
        self.assertEqual(body["strength"]["median_gain_pct"], 8.1)
        self.assertEqual(body["hrv_delta"], 4)

    def test_the_app_posts_the_strength_number_and_it_is_stored_as_is(self):
        with patch.object(webhook, "get_settings", return_value=_Settings()), \
             patch("memory.set_memory_value") as store:
            res = self.client.post("/api/widget/strength", headers=HEADERS,
                                   json={"median_gain_pct": 8.14, "lifts": 11, "block": 6, "week": 4})
        self.assertEqual(res.status_code, 200)
        key, value = store.call_args[0]
        self.assertEqual(key, webhook.WIDGET_STRENGTH_KEY)
        stored = json.loads(value)
        self.assertEqual(stored["median_gain_pct"], 8.1)
        self.assertEqual(stored["lifts"], 11)

    def test_both_routes_need_the_app_token(self):
        with patch.object(webhook, "get_settings", return_value=_Settings()):
            self.assertEqual(self.client.get("/api/widget").status_code, 401)
            self.assertEqual(self.client.post("/api/widget/strength", json={}).status_code, 401)
