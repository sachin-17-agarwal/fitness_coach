import unittest
from datetime import datetime
from unittest.mock import patch

from coach import (
    handle_incoming_message,
    is_ios_structured_log,
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
        library_hit = {"status": "confident", "match": {"name": "Back Squat"}, "candidates": [], "confidence": 0.9}
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="Logged"), \
             patch("coach.get_workout_state", return_value={"workout_mode": "active", "current_session_id": "abc", "current_set_number": "0"}), \
             patch("coach.extract_exercise_from_context", return_value="Back Squat"), \
             patch("coach.find_exercise", return_value=library_hit), \
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
            # Stale-session guard checks state first — inactive means skip
            {"workout_mode": "inactive", "current_session_id": "", "current_set_number": "0"},
            # Main flow check — still inactive so implicit start triggers
            {"workout_mode": "inactive", "current_session_id": "", "current_set_number": "0"},
            # After start_session succeeds — now active
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

    def test_warm_up_is_not_treated_as_exercise_name(self):
        # extract_exercise_from_set_message must reject "Warm up" / "Warmup" / "Rest"
        self.assertEqual(extract_exercise_from_set_message("Warm up 60 x 10"), "")
        self.assertEqual(extract_exercise_from_set_message("warmup 80 x 8"), "")
        self.assertEqual(extract_exercise_from_set_message("Warm-up 100 x 5"), "")
        self.assertEqual(extract_exercise_from_set_message("Rest 60 x 10"), "")
        self.assertEqual(extract_exercise_from_set_message("Back-off 50 x 12"), "")
        self.assertEqual(extract_exercise_from_set_message("Working Set 100 x 8"), "")
        # Sanity: a real exercise name still works
        self.assertEqual(
            extract_exercise_from_set_message("Bench Press 100 x 8"),
            "Bench Press",
        )

    def test_resolve_exercise_name_rejects_warm_up(self):
        from coach import resolve_exercise_name
        # Even if candidate leaks through, resolve should reject it
        self.assertEqual(resolve_exercise_name("Warm up"), "")
        self.assertEqual(resolve_exercise_name("Warmup"), "")
        self.assertEqual(resolve_exercise_name("Rest"), "")
        self.assertEqual(resolve_exercise_name("Back-off"), "")

    def test_end_workout_phrases_trigger_completion(self):
        # The exact phrases the user actually types
        self.assertTrue(is_session_completion_message("End workout", "Push"))
        self.assertTrue(is_session_completion_message("end workout", "Legs"))
        self.assertTrue(is_session_completion_message("I will end it now", "Push"))
        self.assertTrue(is_session_completion_message("ending session", "Pull"))
        self.assertTrue(is_session_completion_message("stop workout", "Legs"))
        self.assertTrue(is_session_completion_message("calling it", "Yoga"))
        self.assertTrue(is_session_completion_message("that's a wrap", "Cardio+Abs"))
        # Make sure set logs still don't count
        self.assertFalse(is_session_completion_message("100 x 10 end", "Push"))

    def test_prescription_parser_accepts_loose_set_phrasings(self):
        """Claude sometimes drops the strict prefixes; parser should recover."""
        from webhook import _parse_prescription
        text = (
            "Week 4 deload keeps RPE conservative.\n\n"
            "*Leg Press*\n"
            "3 sets: 90kg x12 RPE7\n"
            "3 sets: 60kg x15 RPE7\n"
            "Form: Control the descent\n"
        )
        rx = _parse_prescription(text)
        self.assertIsNotNone(rx)
        self.assertEqual(rx["exercise"], "Leg Press")
        self.assertEqual(rx["working"], [{"weight": 90.0, "reps": 12, "rpe": 7.0}])
        self.assertEqual(rx["backoff"], [{"weight": 60.0, "reps": 15, "rpe": 7.0}])
        self.assertEqual(rx["form"], "Control the descent")

    def test_prescription_parser_accepts_top_set_and_drop_set_prefixes(self):
        from webhook import _parse_prescription
        text = (
            "*Leg Press*\n"
            "Top Set: 170kg x8 RPE8 | Tempo: 3-1-2 | Rest: 2min\n"
            "Drop Set: 130kg x12 RPE7\n"
            "Form: Full ROM\n"
        )
        rx = _parse_prescription(text)
        self.assertIsNotNone(rx)
        self.assertEqual(rx["working"], [{"weight": 170.0, "reps": 8, "rpe": 8.0}])
        self.assertEqual(rx["backoff"], [{"weight": 130.0, "reps": 12, "rpe": 7.0}])
        self.assertEqual(rx["tempo"], "3-1-2")

    def test_prescription_parser_recovers_loose_backoff_when_working_is_strict(self):
        """When the coach sends a strict `Working Set:` line but only mentions
        the back-off as loose narrative ("3 sets: 50kg x15 RPE7"), the parser
        should still surface the back-off so the workout card renders both
        sections instead of silently dropping the back-off."""
        from webhook import _parse_prescription
        text = (
            "*Leg Press*\n"
            "Working Set: 160kg x8 RPE8 | Tempo: 3-1-2 | Rest: 2min\n"
            "3 sets: 50kg x15 RPE7\n"
            "Form: Control the descent\n"
        )
        rx = _parse_prescription(text)
        self.assertIsNotNone(rx)
        self.assertEqual(rx["working"], [{"weight": 160.0, "reps": 8, "rpe": 8.0}])
        self.assertEqual(rx["backoff"], [{"weight": 50.0, "reps": 15, "rpe": 7.0}])
        self.assertEqual(rx["form"], "Control the descent")

    def test_prescription_parser_does_not_double_count_strict_working_in_loose_pass(self):
        """If a structured `Working Set:` line happens to also match the loose
        regex (e.g. uses extra wording like '3 sets: ...'), the loose
        fallback must not re-add it as the back-off."""
        from webhook import _parse_prescription
        text = (
            "*Leg Press*\n"
            "Working Set: 3 sets 160kg x8 RPE8 | Tempo: 3-1-2 | Rest: 2min\n"
            "Form: Drive through the heels\n"
        )
        rx = _parse_prescription(text)
        self.assertIsNotNone(rx)
        self.assertEqual(rx["working"], [{"weight": 160.0, "reps": 8, "rpe": 8.0}])
        self.assertNotIn("backoff", rx)

    def test_prescription_parser_preserves_strict_format(self):
        """Sanity: the strict format still parses identically after loosening."""
        from webhook import _parse_prescription
        text = (
            "*Leg Press*\n"
            "Warm-up: 60kg x15, 100kg x8\n"
            "Working Set: 170kg x8 RPE8 | Tempo: 3-1-2 | Rest: 2min\n"
            "Back-off: 130kg x12 RPE7\n"
            "Form: Full ROM\n"
        )
        rx = _parse_prescription(text)
        self.assertIsNotNone(rx)
        self.assertEqual(rx["warmup"], [
            {"weight": 60.0, "reps": 15},
            {"weight": 100.0, "reps": 8},
        ])
        self.assertEqual(rx["working"], [{"weight": 170.0, "reps": 8, "rpe": 8.0}])
        self.assertEqual(rx["backoff"], [{"weight": 130.0, "reps": 12, "rpe": 7.0}])

    def test_is_ios_structured_log_detects_all_phases(self):
        # The exact shapes WorkoutViewModel.swift sends
        self.assertTrue(is_ios_structured_log(
            "Logged warm-up: Leg Press - 60 kg x 10. Set 1 for this exercise, 0 working sets total. What's next?"
        ))
        self.assertTrue(is_ios_structured_log(
            "Logged working: Leg Press - 170 kg x 8 @ RPE 8.0. Set 3 for this exercise, 2 working sets total. What's next?"
        ))
        self.assertTrue(is_ios_structured_log(
            "Logged back-off: Leg Press - 130 kg x 12 @ RPE 7.0. Set 5 for this exercise, 3 working sets total. What's next?"
        ))
        # Ad-hoc user messages must not match
        self.assertFalse(is_ios_structured_log("Done 100 x 12 @8"))
        self.assertFalse(is_ios_structured_log("I logged my set"))
        self.assertFalse(is_ios_structured_log("Logged it: 100 x 10"))
        self.assertFalse(is_ios_structured_log(""))

    def test_ios_structured_log_skips_backend_set_logging(self):
        """
        The iOS app already persists the set to workout_sets directly. The
        backend must NOT re-parse and re-insert that set — double-logging was
        causing the coach and app to disagree about which phase was just done.
        """
        memory = {"mesocycle_day": 3, "mesocycle_week": 1}
        ios_msg = ("Logged working: Leg Press - 170 kg x 8 @ RPE 8.0. "
                   "Set 3 for this exercise, 2 working sets total. What's next?")
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="Nice. Next: back-off 130kg x12"), \
             patch("coach.get_workout_state", return_value={
                 "workout_mode": "active",
                 "current_session_id": "abc",
                 "current_set_number": "2",
                 "current_exercise_name": "Leg Press",
             }), \
             patch("coach.log_set") as log_set_mock, \
             patch("coach.set_workout_state") as set_state_mock, \
             patch("coach.start_session") as start_mock, \
             patch("coach.advance_mesocycle") as advance_mock, \
             patch("coach.send_telegram_message"):
            response = handle_incoming_message(ios_msg, memory)

        self.assertEqual(response, "Nice. Next: back-off 130kg x12")
        log_set_mock.assert_not_called()
        set_state_mock.assert_not_called()
        start_mock.assert_not_called()
        advance_mock.assert_not_called()

    def test_ios_structured_log_does_not_implicit_start_session(self):
        """
        An iOS "Logged …" arriving while workout_mode is inactive must not
        trigger an implicit start_session either — iOS creates sessions itself.
        """
        memory = {"mesocycle_day": 3, "mesocycle_week": 1}
        ios_msg = ("Logged warm-up: Leg Press - 60 kg x 10. "
                   "Set 1 for this exercise, 0 working sets total. What's next?")
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="Good warm-up"), \
             patch("coach.get_workout_state", return_value={
                 "workout_mode": "inactive",
                 "current_session_id": "",
                 "current_set_number": "0",
             }), \
             patch("coach.start_session") as start_mock, \
             patch("coach.log_set") as log_set_mock, \
             patch("coach.send_telegram_message"):
            handle_incoming_message(ios_msg, memory)

        start_mock.assert_not_called()
        log_set_mock.assert_not_called()

    def test_save_memory_passes_on_conflict_key(self):
        # The upsert must supply on_conflict="key" so we update existing rows
        # rather than inserting duplicates. Uses a single batched upsert.
        from unittest.mock import MagicMock
        fake_supabase = MagicMock()
        fake_table = MagicMock()
        fake_supabase.table.return_value = fake_table
        fake_table.upsert.return_value = fake_table
        fake_table.execute.return_value = None

        import memory as memory_module
        with patch.object(memory_module, "get_supabase", return_value=fake_supabase):
            memory_module.save_memory({"mesocycle_week": 2, "mesocycle_day": 3})

        # Single batched upsert with on_conflict="key"
        self.assertEqual(len(fake_table.upsert.call_args_list), 1)
        call = fake_table.upsert.call_args_list[0]
        self.assertEqual(call.kwargs.get("on_conflict"), "key")
        rows = call.args[0] if call.args else call.kwargs.get("data", [])
        self.assertEqual(len(rows), 2)


if __name__ == "__main__":
    unittest.main()
