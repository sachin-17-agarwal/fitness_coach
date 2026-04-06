import unittest
from datetime import datetime
from unittest.mock import patch

from coach import (
    handle_incoming_message,
    is_session_completion_message,
    parse_set_from_message,
    extract_exercise_from_context,
    extract_exercise_from_set_message,
)
import data
from parse_health import parse_health_export
from parse_workouts import parse_workouts
from telegram_bot import split_message
import workout


class FakeResponse:
    def __init__(self, data):
        self.data = data


class FakeTable:
    def __init__(self, name, store):
        self.name = name
        self.store = store
        self.filters = []
        self.pending_insert = None
        self.pending_upsert = None
        self.order_field = None
        self.order_desc = False
        self.limit_count = None

    def select(self, *_args, **_kwargs):
        return self

    def eq(self, field, value):
        self.filters.append((field, value))
        return self

    def in_(self, field, values):
        self.filters.append((field, tuple(values), "in"))
        return self

    def lte(self, field, value):
        self.filters.append((field, value, "lte"))
        return self

    def gte(self, field, value):
        self.filters.append((field, value, "gte"))
        return self

    def order(self, field, desc=False):
        self.order_field = field
        self.order_desc = desc
        return self

    def limit(self, count):
        self.limit_count = count
        return self

    def insert(self, row):
        self.pending_insert = row
        return self

    def upsert(self, row, **_kwargs):
        self.pending_upsert = row
        return self

    def execute(self):
        if self.pending_insert is not None:
            self.store[self.name].append(self.pending_insert)
            return FakeResponse([self.pending_insert])

        if self.pending_upsert is not None:
            row = self.pending_upsert
            key = row.get("key")
            if key is not None:
                self.store[self.name] = [r for r in self.store[self.name] if r.get("key") != key]
            self.store[self.name].append(row)
            return FakeResponse([row])

        rows = list(self.store[self.name])
        for item in self.filters:
            if len(item) == 3 and item[2] == "in":
                field, values, _ = item
                rows = [row for row in rows if row.get(field) in values]
            elif len(item) == 3 and item[2] == "lte":
                field, value, _ = item
                rows = [row for row in rows if row.get(field) <= value]
            elif len(item) == 3 and item[2] == "gte":
                field, value, _ = item
                rows = [row for row in rows if row.get(field) >= value]
            else:
                field, value = item
                rows = [row for row in rows if row.get(field) == value]
        if self.order_field:
            rows = sorted(rows, key=lambda row: row.get(self.order_field), reverse=self.order_desc)
        if self.limit_count is not None:
            rows = rows[:self.limit_count]
        return FakeResponse(rows)


class FakeSupabase:
    def __init__(self, store):
        self.store = store

    def table(self, name):
        return FakeTable(name, self.store)


class RegressionTests(unittest.TestCase):
    def test_parse_set_accepts_plain_weight_x_reps(self):
        parsed = parse_set_from_message("done 100 x 12 @8")
        self.assertEqual(parsed["weight"], 100.0)
        self.assertEqual(parsed["reps"], 12)
        self.assertEqual(parsed["rpe"], 8.0)

        parsed = parse_set_from_message("110 x 10 RPE8")
        self.assertEqual(parsed["weight"], 110.0)
        self.assertEqual(parsed["reps"], 10)
        self.assertEqual(parsed["rpe"], 8.0)

    def test_health_parser_respects_payload_date(self):
        payload = {
            "date": "2026-03-17",
            "data": {
                "metrics": [
                    {"name": "heart_rate_variability", "data": [{"date": "2026-03-17 08:00:00", "qty": 55}]},
                    {"name": "resting_heart_rate", "data": [{"date": "2026-03-17 07:00:00", "qty": 52}]},
                    {"name": "sleep_analysis", "data": [{"date": "2026-03-17 06:00:00", "totalSleep": 7.5}]},
                ]
            },
        }

        parsed = parse_health_export(payload)
        self.assertEqual(parsed["date"], "2026-03-17")
        self.assertEqual(parsed["hrv"], 55.0)
        self.assertEqual(parsed["resting_hr"], 52.0)
        self.assertEqual(parsed["sleep_hours"], 7.5)

    def test_flat_health_parser_does_not_multiply_minutes(self):
        parsed = parse_health_export({
            "date": "2026-03-17",
            "exercise_minutes": 20,
        })
        self.assertEqual(parsed["exercise_minutes"], 20.0)

    def test_get_athlete_context_uses_latest_local_recovery_row(self):
        store = {
            "recovery": [
                {"date": "2026-03-19", "sleep_hours": 7.1, "hrv": 55, "hrv_status": "Normal", "resting_hr": 52},
                {"date": "2026-03-20", "sleep_hours": 8.0, "hrv": 62, "hrv_status": "Elevated", "resting_hr": 50},
            ],
        }

        with patch.object(data, "get_supabase", return_value=FakeSupabase(store)), \
             patch.object(data, "now_local", return_value=datetime(2026, 3, 20, 8, 0, 0)):
            parsed = data.get_athlete_context()

        self.assertEqual(parsed["date"], "2026-03-20")
        self.assertEqual(parsed["sleep_hours"], 8.0)
        self.assertEqual(parsed["hrv"], 62)

    def test_workout_parser_handles_iso_timestamps(self):
        payload = {
            "data": {
                "workouts": [
                    {
                        "name": "Running",
                        "start": "2026-03-17T08:00:00Z",
                        "end": "2026-03-17T08:45:00Z",
                        "duration": {"qty": 2700},
                        "heartRate": {"avg": {"qty": 150}, "max": {"qty": 175}},
                        "activeEnergyBurned": {"qty": 900},
                    }
                ]
            }
        }

        parsed = parse_workouts(payload)
        self.assertEqual(parsed[0]["date"], "2026-03-17")
        self.assertEqual(parsed[0]["duration_minutes"], 45.0)
        self.assertEqual(parsed[0]["avg_heart_rate"], 150.0)

    def test_telegram_split_message_breaks_long_single_paragraph(self):
        text = "A" * 5000
        chunks = split_message(text)
        self.assertGreater(len(chunks), 1)
        self.assertTrue(all(len(chunk) <= 4096 for chunk in chunks))
        self.assertEqual("".join(chunks), text)

    def test_log_set_detects_pr_against_prior_history(self):
        store = {
            "workout_sets": [
                {"exercise": "Bench Press", "actual_weight_kg": 100.0, "actual_reps": 5, "is_warmup": False},
            ],
            "sets": [],
            "memory": [],
        }

        with patch.object(workout, "get_supabase", return_value=FakeSupabase(store)):
            pr_info = workout.log_set(
                session_id="session-1",
                exercise="Bench Press",
                set_number=2,
                actual_weight=105.0,
                actual_reps=5,
            )

        self.assertTrue(pr_info["is_pr"])
        self.assertEqual(len(store["workout_sets"]), 2)

    def test_start_session_reuses_existing_active_session(self):
        store = {
            "memory": [
                {"key": "workout_mode", "value": "active"},
                {"key": "current_session_id", "value": "existing-session"},
            ],
            "workout_sessions": [],
        }

        with patch.object(workout, "get_supabase", return_value=FakeSupabase(store)):
            session_id = workout.start_session("Push")

        self.assertEqual(session_id, "existing-session")
        self.assertEqual(store["workout_sessions"], [])

    def test_completion_message_detects_finished_legs(self):
        self.assertTrue(is_session_completion_message("Finished legs", "Legs"))
        self.assertTrue(is_session_completion_message("All done with push", "Push"))

    def test_set_log_is_not_treated_as_session_completion(self):
        self.assertFalse(is_session_completion_message("Done 100 x 12 @8", "Legs"))

    def test_extract_exercise_ignores_form_cue_and_backoff(self):
        history = [
            {
                "role": "assistant",
                "content": "**Pull-ups**\nYour form cue: elbows to pockets\nBack-off: 10% lighter",
            }
        ]
        self.assertEqual(extract_exercise_from_context(history), "Pull-ups")

    def test_extract_exercise_from_set_message(self):
        self.assertEqual(extract_exercise_from_set_message("Pull-ups 40 x 8"), "Pull-ups")
        self.assertEqual(extract_exercise_from_set_message("done 100 x 8"), "")

    def test_finished_legs_advances_mesocycle_without_active_state(self):
        memory = {"mesocycle_day": 3, "mesocycle_week": 1}
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="Wrapped"), \
             patch("coach.get_workout_state", return_value={"workout_mode": "inactive", "current_session_id": ""}), \
             patch("coach.advance_mesocycle") as advance_mock, \
             patch("coach.send_telegram_message") as send_mock:
            response = handle_incoming_message("Finished legs", memory)

        self.assertEqual(response, "Wrapped")
        advance_mock.assert_called_once_with(memory)
        send_mock.assert_called_once_with("Wrapped")

    def test_workout_complete_advances_mesocycle_without_active_state(self):
        memory = {"mesocycle_day": 4, "mesocycle_week": 1}
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="Wrapped"), \
             patch("coach.get_workout_state", return_value={"workout_mode": "inactive", "current_session_id": ""}), \
             patch("coach.advance_mesocycle") as advance_mock, \
             patch("coach.send_telegram_message") as send_mock:
            response = handle_incoming_message("Workout complete", memory)

        self.assertEqual(response, "Wrapped")
        advance_mock.assert_called_once_with(memory)
        send_mock.assert_called_once_with("Wrapped")

    def test_set_log_does_not_advance_mesocycle(self):
        memory = {"mesocycle_day": 3, "mesocycle_week": 1}
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="Logged"), \
             patch("coach.get_workout_state", return_value={"workout_mode": "active", "current_session_id": "abc", "current_set_number": "0"}), \
             patch("coach.extract_exercise_from_context", return_value="Back Squat"), \
             patch("coach.log_set", return_value={"is_pr": False}) as log_set_mock, \
             patch("coach.set_workout_state") as set_state_mock, \
             patch("coach.advance_mesocycle") as advance_mock, \
             patch("coach.send_telegram_message") as send_mock:
            response = handle_incoming_message("Done 100 x 12 @8", memory)

        self.assertEqual(response, "Logged")
        log_set_mock.assert_called_once()
        set_state_mock.assert_called_once()
        advance_mock.assert_not_called()
        send_mock.assert_called_once_with("Logged")

    def test_cardio_wrap_ends_active_session(self):
        memory = {"mesocycle_day": 4, "mesocycle_week": 1}
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="Wrapped"), \
             patch("coach.get_workout_state", return_value={"workout_mode": "active", "current_session_id": "abc"}), \
             patch("coach.end_session") as end_session_mock, \
             patch("coach.advance_mesocycle") as advance_mock, \
             patch("coach.send_telegram_message") as send_mock:
            response = handle_incoming_message("Workout wrapped", memory)

        self.assertEqual(response, "Wrapped")
        end_session_mock.assert_called_once_with("abc")
        advance_mock.assert_called_once_with(memory)
        send_mock.assert_called_once_with("Wrapped")

    def test_plain_done_ends_active_session(self):
        memory = {"mesocycle_day": 5, "mesocycle_week": 1}
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="Done"), \
             patch("coach.get_workout_state", return_value={"workout_mode": "active", "current_session_id": "abc"}), \
             patch("coach.end_session") as end_session_mock, \
             patch("coach.advance_mesocycle") as advance_mock, \
             patch("coach.send_telegram_message"):
            handle_incoming_message("Done", memory)

        end_session_mock.assert_called_once_with("abc")
        advance_mock.assert_called_once_with(memory)

    def test_set_log_implicitly_starts_workout(self):
        memory = {"mesocycle_day": 2, "mesocycle_week": 1}
        state_sequence = [
            {"workout_mode": "inactive", "current_session_id": "", "current_set_number": "0"},
            {"workout_mode": "active", "current_session_id": "new-session", "current_set_number": "0"},
        ]
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="Logged"), \
             patch("coach.get_workout_state", side_effect=state_sequence), \
             patch("coach.start_session", return_value="new-session") as start_mock, \
             patch("coach.extract_exercise_from_context", return_value="Bench Press"), \
             patch("coach.log_set", return_value={"is_pr": False}) as log_set_mock, \
             patch("coach.set_workout_state"), \
             patch("coach.send_telegram_message"):
            handle_incoming_message("100 x 8", memory)

        start_mock.assert_called_once_with("Push")
        log_set_mock.assert_called_once()

    def test_plain_text_does_not_implicitly_start_workout(self):
        memory = {"mesocycle_day": 2, "mesocycle_week": 1}
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="Reply"), \
             patch("coach.get_workout_state", return_value={"workout_mode": "inactive", "current_session_id": "", "current_set_number": "0"}), \
             patch("coach.start_session") as start_mock, \
             patch("coach.log_set") as log_set_mock, \
             patch("coach.send_telegram_message"):
            handle_incoming_message("My push day was rough yesterday", memory)

        start_mock.assert_not_called()
        log_set_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
