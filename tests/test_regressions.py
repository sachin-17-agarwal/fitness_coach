import logging
import os
import re
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
    load_system_prompt,
)
from coach_parsing import (check_set_counts, enforce_set_counts,
                           parse_session_template)
import data
import coach as coach_module
import progression
import volume
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

        # The coach's own reply is preserved intact; the exercise here was
        # inferred from context rather than named, so the attribution note is
        # prepended ahead of it.
        self.assertTrue(response.endswith("Logged"))
        self.assertIn("Back Squat", response)
        log_set_mock.assert_called_once()
        set_state_mock.assert_called_once()
        advance_mock.assert_not_called()
        send_mock.assert_called_once_with(response)

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

    def test_yoga_overrides_sunday_without_advancing_the_rotation(self):
        """Sunday shows Yoga but must not consume a rotation slot.

        The failure this guards against is silent: if Sunday advanced the
        cycle, a Saturday Pull would be followed by a Monday Legs with Push
        skipped entirely, and nothing in the app would report it.
        """
        saturday = datetime(2026, 8, 1, 10, 0)
        sunday = datetime(2026, 8, 2, 10, 0)
        monday = datetime(2026, 8, 3, 10, 0)

        # mesocycle_day 2 == Push, the session Sunday must not eat.
        self.assertEqual(data.session_type_for(2, saturday), "Push")
        self.assertEqual(data.session_type_for(2, sunday), "Yoga")
        self.assertEqual(data.session_type_for(2, monday), "Push")

        # Tomorrow-facing view: Saturday looks ahead to yoga; Sunday looks
        # ahead to the position it passed over rather than the one after it.
        self.assertEqual(data.next_session_type_for(2, saturday), "Yoga")
        self.assertEqual(data.next_session_type_for(2, sunday), "Push")

    def test_session_override_replaces_the_computed_type_for_that_day_only(self):
        """A missed day has to be recoverable without editing the rotation.

        Skipping a Saturday leaves the athlete wanting Legs on the Sunday the
        schedule reserves for yoga. Before the override there was no give in
        the programme at all: Sunday returned "Yoga" unconditionally, and no
        setting anywhere could say otherwise.
        """
        sunday = datetime(2026, 8, 9, 10, 0)
        monday = datetime(2026, 8, 10, 10, 0)
        override = "2026-08-09|Legs"

        # Day 3 of the rotation is Legs, which Sunday would otherwise cover.
        self.assertEqual(data.session_type_for(3, sunday), "Yoga")
        self.assertEqual(data.session_type_for(3, sunday, override), "Legs")

        # Stamped for one date only: the next day is back on the schedule.
        self.assertEqual(data.session_type_for(4, monday, override), "Cardio+Abs")

    def test_session_override_is_ignored_when_stale_or_malformed(self):
        """A leftover override must never re-point a later day's training."""
        sunday = datetime(2026, 8, 9, 10, 0)

        for raw in [
            "",
            None,
            "2026-08-08|Legs",      # yesterday's
            "2026-08-09|",          # no type
            "2026-08-09|Brunch",    # not a real session type
            "garbage",
        ]:
            with self.subTest(raw=raw):
                self.assertEqual(data.parse_session_override(raw, sunday), "")
                self.assertEqual(data.session_type_for(3, sunday, raw), "Yoga")

    def test_override_changes_whether_the_day_consumes_a_rotation_slot(self):
        """Advancing keys off what was trained, not what weekday it is.

        Legs standing in for a Sunday is a real rotation session and must move
        the position on, or the athlete repeats Legs on Monday. Yoga taken on
        a weekday is still active recovery and must not.
        """
        sunday = datetime(2026, 8, 9, 10, 0)
        monday = datetime(2026, 8, 10, 10, 0)

        # Sunday overridden to Legs: tomorrow steps along to Cardio+Abs
        # rather than returning the position Sunday would have passed over.
        self.assertEqual(
            data.next_session_type_for(3, sunday, "2026-08-09|Legs"), "Cardio+Abs"
        )
        self.assertEqual(data.next_session_type_for(3, sunday), "Legs")

        # Yoga forced onto a Monday leaves the rotation where it is, so the
        # position it passed over is what comes next.
        self.assertEqual(
            data.next_session_type_for(3, monday, "2026-08-10|Yoga"), "Legs"
        )

    def test_session_status_reads_both_codebases_spellings(self):
        """The status column has four spellings for two states.

        This backend wrote "active"/"complete" and the iOS app
        "in_progress"/"completed", with nothing reconciling them, so a session
        ended in chat read as unfinished to the app — History showed it amber
        and labelled "COMPLETE" beside green "COMPLETED" ones. There is no
        migration, so both spellings have to stay readable indefinitely.
        """
        for raw in ["complete", "completed", "COMPLETED", "  Complete  "]:
            with self.subTest(raw=raw):
                self.assertTrue(data.is_session_finished(raw))
                self.assertFalse(data.is_session_open(raw))

        for raw in ["active", "in_progress", "IN_PROGRESS"]:
            with self.subTest(raw=raw):
                self.assertTrue(data.is_session_open(raw))
                self.assertFalse(data.is_session_finished(raw))

        # Neither state, and must not be mistaken for finished.
        for raw in ["", None, "abandoned"]:
            with self.subTest(raw=raw):
                self.assertFalse(data.is_session_finished(raw))

    def test_new_session_writes_use_one_spelling_per_state(self):
        """Both codebases now write the same value, so the split stops here."""
        self.assertEqual(data.SESSION_STATUS_OPEN, "in_progress")
        self.assertEqual(data.SESSION_STATUS_FINISHED, "completed")
        # Whatever is written must still read back as the state it names.
        self.assertTrue(data.is_session_open(data.SESSION_STATUS_OPEN))
        self.assertTrue(data.is_session_finished(data.SESSION_STATUS_FINISHED))

    def test_rotation_rolls_from_last_position_back_to_first(self):
        """Cardio+Abs (day 4) is followed by Pull (day 1), not by Yoga."""
        monday = datetime(2026, 8, 3, 10, 0)
        self.assertEqual(data.session_type_for(4, monday), "Cardio+Abs")
        self.assertEqual(data.next_session_type_for(4, monday), "Pull")
        self.assertEqual(len(data.CYCLE), 4)
        self.assertNotIn("Yoga", data.CYCLE)

    def test_set_log_implicitly_starts_workout(self):
        # Pinned to a Monday. `get_session_type_for_day` consults the real
        # clock now that yoga is a Sunday override, so without freezing the
        # date this asserts "Push" six days a week and "Yoga" on the seventh.
        memory = {"mesocycle_day": 2, "mesocycle_week": 1}
        state_sequence = [
            # Stale-session guard checks state first — inactive means skip
            {"workout_mode": "inactive", "current_session_id": "", "current_set_number": "0"},
            # Main flow check — still inactive so implicit start triggers
            {"workout_mode": "inactive", "current_session_id": "", "current_set_number": "0"},
            # After start_session succeeds — now active
            {"workout_mode": "active", "current_session_id": "new-session", "current_set_number": "0"},
        ]
        with patch("data.now_local", return_value=datetime(2026, 8, 3, 10, 0)), \
             patch("coach.load_today_conversation", return_value=[]), \
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

    def test_set_log_does_not_implicit_start_when_today_has_session(self):
        """Once today has any workout_session row (active or completed), a
        chat message containing `weight x reps` must not spawn a second
        phantom session. Without this guard the implicit-start path was
        creating an orphan "Active" session whenever the user discussed an
        extra exercise after the real workout had ended — those phantoms
        then stuck around because no end-of-workout phrase ever followed.
        """
        memory = {"mesocycle_day": 2, "mesocycle_week": 1}
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="Reply"), \
             patch("coach.get_workout_state", return_value={
                 "workout_mode": "inactive",
                 "current_session_id": "",
                 "current_set_number": "0",
             }), \
             patch("coach.has_session_for_today", return_value=True), \
             patch("coach.start_session") as start_mock, \
             patch("coach.log_set") as log_set_mock, \
             patch("coach.send_telegram_message"):
            handle_incoming_message("Incline dumbbell curl 70 x 12", memory)

        start_mock.assert_not_called()
        log_set_mock.assert_not_called()

    def test_unknown_exercise_does_not_log_set(self):
        """If we can't resolve the set's exercise to anything — neither from
        the message text, the conversation context, nor the last set logged
        in this session — we must NOT persist a row tagged "Unknown".
        Those rows clutter history and make sessions look broken.
        """
        memory = {"mesocycle_day": 3, "mesocycle_week": 1}
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="What exercise was that?"), \
             patch("coach.get_workout_state", return_value={
                 "workout_mode": "active",
                 "current_session_id": "abc",
                 "current_set_number": "0",
                 "current_exercise_name": "",
             }), \
             patch("coach.extract_exercise_from_context", return_value="Unknown"), \
             patch("coach.get_last_logged_exercise", return_value=""), \
             patch("coach.log_set") as log_set_mock, \
             patch("coach.set_workout_state"), \
             patch("coach.send_telegram_message"):
            handle_incoming_message("100 x 8", memory)

        log_set_mock.assert_not_called()

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

    def test_prescription_parser_marks_revised_blocks(self):
        """A `Revised:` line flags the block as a deliberate structure change
        so the iOS app applies it verbatim instead of reconciling it against
        the on-screen card. Normal blocks must NOT carry the flag — it is
        what authorizes shrinking the athlete's plan."""
        from webhook import _parse_prescription
        revised_text = (
            "*Pull-Ups*\n"
            "Warm-up: BW x5\n"
            "Working Set: 10kg x6 RPE8 | Tempo: 3-1-2 | Rest: 2min\n"
            "Back-off: BW x10 RPE7\n"
            "Form: Squeeze lats at top\n"
            "Revised: warm-up cut to 1 set\n"
        )
        rx = _parse_prescription(revised_text)
        self.assertIsNotNone(rx)
        self.assertTrue(rx.get("revised"))
        self.assertEqual(len(rx["warmup"]), 1)

        normal_text = (
            "*Pull-Ups*\n"
            "Warm-up: BW x5, BW x5\n"
            "Working Set: 10kg x6 RPE8 | Tempo: 3-1-2 | Rest: 2min\n"
            "Back-off: BW x10 RPE7\n"
            "Form: Squeeze lats at top\n"
        )
        rx = _parse_prescription(normal_text)
        self.assertIsNotNone(rx)
        self.assertNotIn("revised", rx)

    def test_prescription_parser_straight_sets_parse_as_multiple_working_sets(self):
        """Ab work is prescribed as straight sets: every set enumerated on the
        `Working Set:` line, no back-off. Each comma-separated entry must
        surface as its own working set so the card renders one chip per set."""
        from webhook import _parse_prescription
        text = (
            "*Cable Crunch*\n"
            "Working Set: 25kg x12, 25kg x12, 25kg x12, 25kg x12 RPE8 | Tempo: 2-1-2 | Rest: 90s\n"
            "Form: Flex the spine, pull with abs not arms\n"
        )
        rx = _parse_prescription(text)
        self.assertIsNotNone(rx)
        self.assertEqual(rx["exercise"], "Cable Crunch")
        self.assertEqual(len(rx["working"]), 4)
        self.assertEqual(rx["working"][0], {"weight": 25.0, "reps": 12, "rpe": 8.0})
        self.assertNotIn("backoff", rx)
        self.assertEqual(rx["rest"], "90s")

    def test_prescription_parser_straight_sets_get_no_phantom_backoff(self):
        """A straight-set prescription (2+ enumerated working sets, no
        `Back-off:` line) must not have loose narrative set mentions promoted
        into a phantom back-off — abs genuinely have no back-off."""
        from webhook import _parse_prescription
        text = (
            "*Hanging Leg Raises*\n"
            "Working Set: BW x12, BW x12, BW x12 RPE8 | Rest: 90s\n"
            "Form: Straight legs, no swinging\n"
            "After this we finish with 3 sets: 20kg x15 on oblique crunches.\n"
        )
        rx = _parse_prescription(text)
        self.assertIsNotNone(rx)
        self.assertEqual(len(rx["working"]), 3)
        self.assertNotIn("backoff", rx)

    def test_prescription_parser_handles_bodyweight_swap(self):
        """Swapping to pull-ups / dips uses `BW xN` instead of a kg weight.
        The parser must recognise the bodyweight token (resolving to 0kg) so
        the workout card actually swaps to the new exercise instead of
        leaving the previous one on screen."""
        from webhook import _parse_prescription
        text = (
            "*Pull-ups*\n"
            "Warm-up: BW x5, BW x5\n"
            "Working Set: BW x6 RPE8 | Tempo: 3-1-2 | Rest: 2min\n"
            "Back-off: BW x10 RPE7\n"
            "Form: Squeeze lats at top\n"
        )
        rx = _parse_prescription(text)
        self.assertIsNotNone(rx)
        self.assertEqual(rx["exercise"], "Pull-ups")
        self.assertEqual(rx["warmup"], [
            {"weight": 0.0, "reps": 5},
            {"weight": 0.0, "reps": 5},
        ])
        self.assertEqual(rx["working"], [{"weight": 0.0, "reps": 6, "rpe": 8.0}])
        self.assertEqual(rx["backoff"], [{"weight": 0.0, "reps": 10, "rpe": 7.0}])

    def test_prescription_parser_keeps_rep_range_high_bound(self):
        """A working/back-off rep range ("85kg x6-8") must keep the low bound in
        `reps` (drives prefill/logging) and surface the top in `reps_high` so the
        card can render the full range instead of collapsing to 6 — the bug where
        the card showed 6 while the coach's prose said "aim for 7-8"."""
        from webhook import _parse_prescription
        text = (
            "*Lat Pulldown*\n"
            "Warm-up: 50kg x10, 70kg x5\n"
            "Working Set: 85kg x6-8 RPE8 | Tempo: 3-1-2 | Rest: 2min\n"
            "Back-off: 65kg x10-12 RPE7\n"
            "Form: Drive elbows down\n"
        )
        rx = _parse_prescription(text)
        self.assertIsNotNone(rx)
        self.assertEqual(rx["working"], [{"weight": 85.0, "reps": 6, "reps_high": 8, "rpe": 8.0}])
        self.assertEqual(rx["backoff"], [{"weight": 65.0, "reps": 10, "reps_high": 12, "rpe": 7.0}])
        # Warm-up chips stay single-rep — no range bound added there.
        self.assertEqual(rx["warmup"], [
            {"weight": 50.0, "reps": 10},
            {"weight": 70.0, "reps": 5},
        ])

    def test_prescription_parser_single_rep_has_no_high_bound(self):
        """A single-rep prescription must NOT gain a reps_high key (deload weeks,
        fixed targets) so downstream code can treat its absence as 'no range'."""
        from webhook import _parse_prescription
        text = (
            "*Lat Pulldown*\n"
            "Working Set: 85kg x6 RPE8 | Tempo: 3-1-2 | Rest: 2min\n"
        )
        rx = _parse_prescription(text)
        self.assertIsNotNone(rx)
        self.assertEqual(rx["working"], [{"weight": 85.0, "reps": 6, "rpe": 8.0}])
        self.assertNotIn("reps_high", rx["working"][0])

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
        # WorkoutViewModel.swift has shipped a few formats. The detector must
        # tolerate all of them so backend deploys don't have to land in lock
        # step with iOS releases.
        self.assertTrue(is_ios_structured_log(
            "Logged warm-up: Leg Press - 60 kg x 10. Set 1 for this exercise, 0 working sets total. What's next?"
        ))
        self.assertTrue(is_ios_structured_log(
            "Logged working: Leg Press - 170 kg x 8 @ RPE 8.0. Set 3 for this exercise, 2 working sets total. What's next?"
        ))
        self.assertTrue(is_ios_structured_log(
            "Logged back-off: Leg Press - 130 kg x 12 @ RPE 7.0. Set 5 for this exercise, 3 working sets total. What's next?"
        ))
        self.assertTrue(is_ios_structured_log(
            "Logged working: Lat Pulldown — actual: 95kg × 6 @ RPE 8.5 (target was 95kg × 6 @ RPE 8). Set 3 for this exercise, 1 working sets total. Quote the actual numbers (95kg × 6 @ RPE 8.5) when responding, not the target. What's next?"
        ))
        self.assertTrue(is_ios_structured_log(
            "Logged warm-up: Lat Pulldown — actual: 60kg × 10 (target was 60kg × 10). Set 1 for this exercise, 0 working sets total. Quote the actual numbers (60kg × 10) when responding, not the target. What's next?"
        ))
        # Current shape — "Logged <phase> X of Y: …".
        self.assertTrue(is_ios_structured_log(
            "Logged warm-up 2 of 2: Machine Shoulder Press — actual: 60kg × 8 (target was 60kg × 8). 0 working sets done so far. Acknowledge the athlete's actual numbers (60kg × 8) — do NOT echo any other phase's target as the result. What's next?"
        ))
        self.assertTrue(is_ios_structured_log(
            "Logged working 1 of 2: Lat Pulldown — actual: 95kg × 6 @ RPE 8.5 (target was 95kg × 6 @ RPE 8). 1 working sets done so far. What's next?"
        ))
        self.assertTrue(is_ios_structured_log(
            "Logged back-off 1 of 1: Leg Press — actual: 130kg × 12 @ RPE 7 (target was 130kg × 12 @ RPE 7). 2 working sets done so far. What's next?"
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

    def test_free_form_ios_chat_never_logs_a_set(self):
        """A chat message from the in-workout composer must not become a set.

        The iOS app writes every set to Supabase itself, then sends a message.
        `is_ios_structured_log` catches its "Logged working …" lines, but
        free-form chat looks like ordinary text — so any number-shaped phrase
        the athlete typed got parsed and logged. That is how a Push session
        acquired a "Leg press 60kg x 1" row.
        """
        memory = {"mesocycle_day": 2, "mesocycle_week": 1}
        chat = "the leg press bay is free, should I do 60 x 1 to test the knee?"
        with patch("data.now_local", return_value=datetime(2026, 8, 3, 10, 0)), \
             patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="Stick to push today"), \
             patch("coach.get_workout_state", return_value={
                 "workout_mode": "active",
                 "current_session_id": "abc",
                 "current_set_number": "3",
                 "current_exercise_name": "Machine Chest Press",
             }), \
             patch("coach.start_session") as start_mock, \
             patch("coach.log_set") as log_set_mock, \
             patch("coach.set_workout_state"), \
             patch("coach.send_telegram_message"), \
             patch("coach.resolve_exercise_name", return_value="Leg press"):
            handle_incoming_message(chat, memory, allow_set_logging=False)

        log_set_mock.assert_not_called()
        start_mock.assert_not_called()

    def test_telegram_still_logs_sets_from_plain_text(self):
        """The gate must not disarm Telegram, where typing the set IS the log."""
        memory = {"mesocycle_day": 2, "mesocycle_week": 1}
        with patch("data.now_local", return_value=datetime(2026, 8, 3, 10, 0)), \
             patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="Logged"), \
             patch("coach.get_workout_state", return_value={
                 "workout_mode": "active",
                 "current_session_id": "abc",
                 "current_set_number": "0",
                 "current_exercise_name": "Machine Chest Press",
             }), \
             patch("coach.log_set", return_value={"is_pr": False}) as log_set_mock, \
             patch("coach.set_workout_state"), \
             patch("coach.send_telegram_message"), \
             patch("coach.resolve_exercise_name", return_value="Machine Chest Press"):
            handle_incoming_message("133 x 8 @8", memory)

        log_set_mock.assert_called_once()
        self.assertEqual(log_set_mock.call_args.kwargs["actual_weight"], 133)
        self.assertEqual(log_set_mock.call_args.kwargs["actual_reps"], 8)

    def test_fractional_attribution_credits_synergists(self):
        """A row must credit biceps and rear delts, not just back.

        Single attribution is what made the volume readout wrong: eight sets
        of rowing counted 8 for Back and ZERO for the biceps doing half the
        work, so rear delts read 3 sets/week against a 4-8 band when they
        were really at 6, and biceps read 9 against 8-12 when they were
        really at 15 — over, not under. The weak-point block picks the two
        lowest muscles, so it was aimed at the two needing it least.
        """
        from volume import resolve_contributions
        row = resolve_contributions("Cable Row")
        self.assertEqual(row.get("Back"), 1.0)
        self.assertEqual(row.get("Biceps"), 0.5)
        self.assertEqual(row.get("Rear Delts"), 0.5)

        press = resolve_contributions("Machine Chest Press")
        self.assertEqual(press.get("Chest"), 1.0)
        self.assertEqual(press.get("Triceps"), 0.5)

        # Isolations stay whole — the fallback is correct for them, not
        # merely safe.
        self.assertEqual(resolve_contributions("Machine Bicep Curl"), {"Biceps": 1.0})

    def test_dips_is_not_matched_by_a_sub_four_character_key(self):
        """Regression: the key was "dip", and the substring matcher ignores
        keys under four characters, so "Dips" fell through to Chest alone and
        silently lost its triceps share. Caught by simulation, not review."""
        from volume import resolve_contributions
        from muscle_map import MUSCLE_CONTRIBUTIONS
        self.assertFalse([k for k in MUSCLE_CONTRIBUTIONS if len(k) < 4])
        self.assertEqual(resolve_contributions("Dips").get("Triceps"), 0.5)

    def test_quads_and_hamstrings_are_separate_buckets(self):
        """Hamstrings hid inside a combined Legs bucket that read 16.5/week —
        top of band — while getting 3 direct sets. The weak-point block picks
        the LOWEST two, so the thinnest muscle in the programme could never be
        selected, and a seated leg curl added to fix it would have landed in
        the same bucket and made it look better served."""
        from volume import resolve_contributions
        self.assertEqual(resolve_contributions("Lying Leg Curl"), {"Hamstrings": 1.0})
        press = resolve_contributions("Leg Press")
        self.assertEqual(press.get("Quads"), 1.0)
        # Deliberately small: leg pressing must never make hamstrings look served.
        self.assertEqual(press.get("Hamstrings"), 0.25)
        self.assertNotIn("Legs", press)

    def test_single_arm_db_row_resolves(self):
        """It is in the allowed Pull list but mapped to nothing, so its sets
        dropped out of volume AND strength entirely."""
        from volume import resolve_muscle_group, resolve_contributions
        self.assertEqual(resolve_muscle_group("Single Arm DB Row"), "Back")
        self.assertEqual(resolve_contributions("Single Arm DB Row").get("Back"), 1.0)

    def test_injury_survives_conversation_truncation(self):
        """An injury stated at the start of a session must still be visible at
        the end of it.

        A session logs ~22 sets, each producing an athlete message and a coach
        reply — ~44 messages against a 40-message window. So a shoulder injury
        mentioned first was pushed out of context about four-fifths of the way
        through, and the coach that had said "skip pull-ups" would later ask
        why they were skipped. It could not see what it had been told.
        """
        from coach_context import truncate_history, MAX_CONVERSATION_MESSAGES
        history = [
            {"role": "user", "content": "Starting pull. My shoulder is hurting, skip pull-ups"},
            {"role": "assistant", "content": "Understood — pull-ups are out today."},
        ]
        for _ in range(22):
            history.append({"role": "user", "content": "Logged working 1 of 1: 90kg x 8 @ RPE 8"})
            history.append({"role": "assistant", "content": "Good set."})
        self.assertGreater(len(history), MAX_CONVERSATION_MESSAGES)

        kept = truncate_history(history)
        self.assertTrue(
            any("shoulder is hurting" in (m.get("content") or "") for m in kept),
            "constraint dropped by truncation — the coach cannot honour what it can't see",
        )
        # Chronology preserved: the pinned message stays ahead of the tail.
        self.assertIn("shoulder is hurting", kept[0]["content"])

    def test_truncation_does_not_pin_ordinary_chat(self):
        """Pinning costs context on every later request, so it must be narrow."""
        from coach_context import truncate_history
        history = [{"role": "user", "content": "how many sets left?"},
                   {"role": "assistant", "content": "Two."}]
        for _ in range(22):
            history.append({"role": "user", "content": "Logged working"})
            history.append({"role": "assistant", "content": "Good."})
        kept = truncate_history(history)
        self.assertFalse(any("how many sets left" in (m.get("content") or "") for m in kept))

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


    def test_muscle_map_matches_the_swift_catalog(self):
        """muscle_map.py is generated from ExerciseCatalog.swift. If someone
        edits the Swift map without regenerating, the coach's volume readout
        silently disagrees with the app's Volume tab."""
        import subprocess
        import sys
        from pathlib import Path

        root = Path(__file__).resolve().parent.parent
        before = (root / "muscle_map.py").read_text()
        subprocess.run(
            [sys.executable, "tools/generate_muscle_map.py"],
            cwd=root, check=True, capture_output=True,
        )
        after = (root / "muscle_map.py").read_text()
        self.assertEqual(
            before, after,
            "muscle_map.py is stale — run python tools/generate_muscle_map.py",
        )

    def test_resolve_muscle_group_prefers_longest_match(self):
        """Mirrors the iOS matcher: exact first, then longest substring, so
        qualified names ("Machine Calf Press") don't fall through to a
        shorter generic key or to nothing at all."""
        from volume import resolve_muscle_group
        self.assertEqual(resolve_muscle_group("Leg Press"), "Legs")
        self.assertEqual(resolve_muscle_group("Machine Calf Press"), "Calves")
        self.assertEqual(resolve_muscle_group("Single Leg Sumo Press"), "Legs")
        self.assertEqual(resolve_muscle_group("Lying Leg Curl"), "Legs")
        self.assertEqual(resolve_muscle_group("Machine Bicep Curl"), "Biceps")
        self.assertEqual(resolve_muscle_group("Overhead Cable Extension"), "Triceps")
        self.assertEqual(resolve_muscle_group("Face Pulls"), "Rear Delts")
        self.assertIsNone(resolve_muscle_group(""))

    def test_weekly_volume_block_orders_lowest_first(self):
        """The weak-point block picks the two lowest muscles, so the readout
        must lead with them rather than making the coach scan."""
        from volume import format_weekly_volume
        block = format_weekly_volume({"Chest": 10, "Triceps": 3, "Back": 11, "Calves": 4})
        lines = block.strip().split("\n")
        self.assertIn("Triceps: 3 sets", lines[0])
        self.assertIn("Calves: 4 sets", lines[1])
        self.assertIn("Lowest two: Triceps, Calves", lines[-1])

    def test_weekly_volume_block_handles_no_data(self):
        """An unreadable table must read as 'no data', never as zero volume —
        the coach would otherwise flag every muscle as untrained."""
        from volume import format_weekly_volume
        self.assertIn("No volume data", format_weekly_volume({}))

    def test_load_memory_normalizes_overflowed_mesocycle_week(self):
        """The old iOS advance() incremented mesocycle_week without wrapping,
        leaving values like 5/6 in the DB — the coach was being told
        "Week 6 of 4". load_memory must fold them back into the 4-week
        cycle (6 → week 2 of the following mesocycle)."""
        import memory as memory_module
        store = {"memory": [
            {"key": "mesocycle_week", "value": "6"},
            {"key": "mesocycle_day", "value": "3"},
        ]}
        with patch.object(memory_module, "get_supabase", return_value=FakeSupabase(store)):
            loaded = memory_module.load_memory()
        self.assertEqual(loaded["mesocycle_week"], 2)
        self.assertEqual(loaded["mesocycle_day"], 3)

    def test_webhook_skips_duplicate_telegram_update_id(self):
        # Telegram retries can deliver the same update twice; the dedup table
        # must short-circuit the second delivery before handle_incoming_message
        # runs.
        import webhook as webhook_module
        store = {"memory": []}
        fake = FakeSupabase(store)
        payload = {
            "update_id": 12345,
            "message": {
                "text": "hello",
                "chat": {"id": "1"},
                "from": {"first_name": "Sachin"},
            },
        }

        with patch.object(webhook_module, "get_supabase", return_value=fake), \
             patch.object(webhook_module, "load_memory", return_value={}), \
             patch.object(webhook_module, "handle_incoming_message") as handler, \
             patch.dict(os.environ, {"TELEGRAM_CHAT_ID": ""}, clear=False):
            client = webhook_module.app.test_client()
            r1 = client.post("/webhook", json=payload)
            r2 = client.post("/webhook", json=payload)

        self.assertEqual(r1.status_code, 200)
        self.assertEqual(r2.status_code, 200)
        handler.assert_called_once()  # Second delivery short-circuits

    def test_webhook_lets_distinct_update_ids_through(self):
        import webhook as webhook_module
        store = {"memory": []}
        fake = FakeSupabase(store)

        with patch.object(webhook_module, "get_supabase", return_value=fake), \
             patch.object(webhook_module, "load_memory", return_value={}), \
             patch.object(webhook_module, "handle_incoming_message") as handler, \
             patch.dict(os.environ, {"TELEGRAM_CHAT_ID": ""}, clear=False):
            client = webhook_module.app.test_client()
            for update_id in (1, 2):
                client.post("/webhook", json={
                    "update_id": update_id,
                    "message": {
                        "text": "hi",
                        "chat": {"id": "1"},
                        "from": {"first_name": "Sachin"},
                    },
                })

        self.assertEqual(handler.call_count, 2)


class ModelRequestConfigTests(unittest.TestCase):
    """Pins the three parameters that interact.

    Sonnet 4.6 treated an omitted `thinking` as "no thinking". Sonnet 5 treats
    the same omission as adaptive thinking, and `effort` defaults to `high` on
    the Claude API — so simply swapping the model string would have started
    spending a large share of the budget on reasoning. `max_tokens` caps
    thinking and response text together, which lands that on the one failure
    the parsers cannot detect: a prescription truncated mid-block still matches
    the `Warm-up:` / `Working Set:` prefixes it managed to emit, so the card
    renders half a plan and nothing reports an error.
    """

    def _captured_request(self):
        captured = {}

        class FakeMessages:
            def create(self, **kwargs):
                captured.update(kwargs)
                return type("R", (), {
                    "content": [type("B", (), {"text": "ok"})()],
                    "usage": None, "stop_reason": "end_turn",
                })()

        fake_client = type("C", (), {"messages": FakeMessages()})()
        with patch("coach.get_anthropic_client", return_value=fake_client),              patch("coach.load_system_prompt", return_value="SYSTEM"),              patch("coach.build_context_block", return_value=("STABLE", "LIVE")),              patch("coach._truncate_history", side_effect=lambda h: h), \
             patch("coach.save_conversation_message"):
            coach_module.chat_with_coach("hi", [], {})
        return captured

    def test_thinking_is_set_explicitly_not_left_to_the_default(self):
        """Omission is the bug. An explicit value — either value — is the fix."""
        self.assertIn("thinking", self._captured_request())

    def test_thinking_is_disabled(self):
        self.assertEqual(self._captured_request()["thinking"], {"type": "disabled"})

    def test_max_tokens_leaves_room_for_a_long_prescription(self):
        """Sonnet 5's tokenizer yields ~1.35x the tokens for identical text, so
        a 1400-token prescription becomes ~1900 — brushing the old 2000 ceiling
        with nothing added.
        """
        self.assertGreaterEqual(self._captured_request()["max_tokens"], 4000)

    def test_model_is_pinned_to_sonnet_5(self):
        self.assertEqual(self._captured_request()["model"], "claude-sonnet-5")

    def test_the_cache_breakpoint_still_sits_between_stable_and_live_context(self):
        """Caching is a prefix match, so the stable block must physically
        precede the live one. Re-checked here because a model swap is exactly
        when someone reshuffles this array.
        """
        system = self._captured_request()["system"]
        self.assertEqual([b["text"] for b in system], ["SYSTEM", "STABLE", "LIVE"])
        self.assertIn("cache_control", system[1])
        self.assertNotIn("cache_control", system[2])


class SessionTemplateTests(unittest.TestCase):
    """The prompt states each session's working-set total AND enumerates the
    per-exercise counts. Both are load-bearing — "set counts are a LOOKUP,
    never a derivation" points the coach at the enumerated line, while the
    total is what it checks a whole session against before sending. If the two
    ever disagree the coach gets a contradiction and picks one at random,
    which is how the same question started returning three different answers.
    """

    _TEMPLATE = re.compile(
        r"\*(?P<name>PUSH|PULL|LEGS) — (?P<total>\d+) working sets\*\n(?P<line>[^\n]+)"
    )

    def test_enumerated_set_counts_match_each_stated_total(self):
        prompt = load_system_prompt()
        found = list(self._TEMPLATE.finditer(prompt))
        self.assertEqual({m.group("name") for m in found}, {"PUSH", "PULL", "LEGS"})
        for match in found:
            counts = [int(n) for n in re.findall(r"\s(\d+)(?:\s·|$)", match.group("line"))]
            self.assertTrue(counts, f"{match.group('name')}: no set counts parsed")
            self.assertEqual(
                sum(counts), int(match.group("total")),
                f"{match.group('name')} enumerates {sum(counts)} sets "
                f"but its header says {match.group('total')}",
            )

    def test_pull_day_carries_the_added_rear_delt_work(self):
        """Reverse Cable Fly was added to Pull in August 2026, taking rear
        delts from 6 sets a week to 9. Moving face pulls across instead would
        have changed no weekly total whatsoever.
        """
        prompt = load_system_prompt()
        pull = self._TEMPLATE.search(prompt)
        self.assertIn("Reverse Cable Fly 2", prompt)
        self.assertIn("PULL — 16 working sets", prompt)
        # Face pulls stay on Push: the only external rotation in a pressing day.
        self.assertIn("No face pulls here", prompt)

    def test_rear_delt_band_matches_the_measured_figure(self):
        """The band was raised from 4-8 when the volume readout was corrected.
        A band left behind by its own measurement is what made a sensible dose
        read as over-training.
        """
        prompt = load_system_prompt()
        self.assertIn("Rear delts 8-14", prompt)
        self.assertNotIn("Rear delts 4-8", prompt)
        self.assertIn("rear delts 9", prompt)


class WeakPointBlockTests(unittest.TestCase):
    """The Cardio+Abs weak-point block is the mechanism that feeds the two
    lowest muscles, and the measured volume says it has not been landing:
    calves 4.5 against a 6-10 band, hamstrings 6.8 against 10-16, while the
    block naming both has been scheduled every rotation. Whether it is being
    prescribed and skipped, or never prescribed, is invisible in a 30-day log
    of raw sets — so it is computed and reported.
    """

    @staticmethod
    def _sets(*exercises):
        return [{"exercise": e, "is_warmup": False, "notes": None} for e in exercises]

    def test_block_work_is_separated_from_the_days_ab_staples(self):
        history = volume.find_weak_point_work([
            {"date": "2026-08-01", "sets": self._sets(
                "Cable Crunch", "Hanging Leg Raises",
                "Seated Leg Curl", "Seated Leg Curl", "Machine Calf Raise")},
        ])
        self.assertEqual(history[0]["muscles"], {"Hamstrings": 2.0, "Calves": 1.0})

    def test_a_session_with_only_abs_and_cardio_reports_none(self):
        """The whole point. A session that did abs and went home must read as
        a miss, not as an absence of data.
        """
        history = volume.find_weak_point_work([
            {"date": "2026-08-05", "sets": [
                {"exercise": "Cable Crunch", "is_warmup": False, "notes": None},
                {"exercise": "Boxing", "is_warmup": False, "notes": "cardio session"},
            ]},
        ])
        self.assertEqual(history[0]["muscles"], {})
        self.assertIn("none logged", volume.format_weak_point_history(history))

    def test_repeated_misses_are_counted_out_loud(self):
        history = volume.find_weak_point_work([
            {"date": "2026-08-05", "sets": self._sets("Cable Crunch")},
            {"date": "2026-08-01", "sets": self._sets("Cable Crunch", "Machine Calf Raise")},
            {"date": "2026-07-28", "sets": self._sets("Hanging Leg Raises")},
        ])
        rendered = volume.format_weak_point_history(history)
        self.assertIn("2 of the last 3", rendered)

    def test_warmups_do_not_count_as_block_work(self):
        history = volume.find_weak_point_work([
            {"date": "2026-08-05", "sets": [
                {"exercise": "Machine Calf Raise", "is_warmup": True, "notes": None},
            ]},
        ])
        self.assertEqual(history[0]["muscles"], {})

    def test_empty_history_says_so_rather_than_claiming_compliance(self):
        self.assertIn("No Cardio+Abs sessions", volume.format_weak_point_history([]))

    def test_prompt_makes_the_block_binding_and_names_its_movements(self):
        prompt = load_system_prompt()
        self.assertIn("WEAK-POINT BLOCK readout", prompt)
        # Prescribed with the abs, not after them — the failure was positional.
        self.assertIn("SAME reply as the ab block", prompt)
        # Abs yield to the block, never the other way round.
        self.assertIn("cut AB sets to protect this block", prompt)


class SeatedLegCurlSwapTests(unittest.TestCase):
    """Prone curls train the hamstring at a short muscle length; seated at a
    long one, which is worth 14% growth against 9% over 12 weeks. The swap
    costs nothing — same sets, same machine family.
    """

    def test_legs_template_uses_the_seated_curl(self):
        prompt = load_system_prompt()
        self.assertIn("Seated Leg Curl 3", prompt)
        self.assertNotIn("Lying Leg Curl 3", prompt)

    def test_no_load_is_carried_across_from_the_prone_variant(self):
        """85kg x5 on a lying curl means nothing seated — different seat, hip
        angle and leverage. Carrying it over would prescribe a load he has
        never lifted in that position.
        """
        prompt = load_system_prompt()
        self.assertNotIn("Lying Leg Curl 85kg", prompt)
        # The reference-load line used to answer this with static text ("NO
        # history, fresh baseline"), which was true when written and then
        # never stopped being read — the coach saw "no history" on every
        # request no matter how many sessions had been logged since. It now
        # points at the block that is recomputed from the log each request.
        self.assertIn("Seated Leg Curl: read CURRENT WORKING LOADS", prompt)
        self.assertNotIn("NO history, fresh baseline", prompt)

    def test_seated_curl_resolves_to_hamstrings_in_the_volume_map(self):
        self.assertEqual(
            volume.resolve_contributions("Seated Leg Curl"), {"Hamstrings": 1.0}
        )


class LoadProgressionStallTests(unittest.TestCase):
    """The ab crunch machine sat at one load for five sessions at 12-15 reps
    and RPE 7-8 — past the load-increase trigger, with the rule spelled out in
    the system prompt naming that exact machine — and only moved when the
    athlete asked why it hadn't. The trigger is computed now rather than left
    to the coach to notice mid-session.
    """

    @staticmethod
    def _set(date, exercise, weight, reps, rpe,
             target_reps=None, target_rpe=None, is_warmup=False, notes=None):
        return {
            "date": date, "exercise": exercise,
            "actual_weight_kg": weight, "actual_reps": reps, "actual_rpe": rpe,
            "target_reps": target_reps, "target_rpe": target_rpe,
            "is_warmup": is_warmup, "notes": notes,
        }

    def _ab_crunch_history(self):
        rows = []
        for date, reps, rpe in [
            ("2026-07-10", 13, 8), ("2026-07-17", 12, 8), ("2026-07-24", 14, 8),
            ("2026-07-31", 15, 7), ("2026-08-05", 13, 8),
        ]:
            for _ in range(3):
                rows.append(self._set(date, "Ab Crunch Machine", 75, reps, rpe,
                                      target_reps=10, target_rpe=8))
        return rows

    def test_stalled_load_is_flagged_with_increase_indicated(self):
        stalls = progression.find_stalls(self._ab_crunch_history())
        match = [s for s in stalls if s["exercise"] == "Ab Crunch Machine"]
        self.assertEqual(len(match), 1)
        self.assertEqual(match[0]["sessions"], 5)
        self.assertEqual(match[0]["load"], 75)
        self.assertTrue(match[0]["increase_indicated"])
        self.assertIn("LOAD INCREASE INDICATED", progression.format_stalls(stalls))

    def test_progressing_lift_is_not_flagged(self):
        """A load that moves every session must never appear. If it did, the
        block would cry wolf and get ignored like the prose rule it replaces.
        """
        rows = [
            self._set(d, "Leg Press", w, 10, 9, target_reps=6, target_rpe=9)
            for d, w in [("2026-07-12", 190), ("2026-07-19", 195),
                         ("2026-07-26", 200), ("2026-08-02", 205)]
        ]
        self.assertEqual(progression.find_stalls(rows), [])

    def test_stall_without_meeting_target_is_reported_but_not_indicated(self):
        """Held load + missed reps is a real reason to hold. Report the stall,
        withhold the verdict.
        """
        rows = [
            self._set(d, "Machine Calf Raise", 117, 9, 9, target_reps=11, target_rpe=9)
            for d in ("2026-07-12", "2026-07-19", "2026-07-26")
        ]
        stalls = progression.find_stalls(rows)
        self.assertEqual(len(stalls), 1)
        self.assertFalse(stalls[0]["increase_indicated"])
        self.assertNotIn("LOAD INCREASE INDICATED", progression.format_stalls(stalls))

    def test_missing_target_never_fakes_a_trigger(self):
        """A set logged with no prescription proves nothing. Treating an
        absent target as satisfied would fire the trigger on every free-form
        entry in the log.
        """
        rows = [
            self._set(d, "Cable Chest Fly", 17.5, 11, 8)
            for d in ("2026-07-13", "2026-07-20", "2026-07-27")
        ]
        stalls = progression.find_stalls(rows)
        self.assertEqual(len(stalls), 1)
        self.assertFalse(stalls[0]["increase_indicated"])

    def test_bodyweight_lift_stalls_on_load_not_reps(self):
        """Pull-ups carry no stack, so every session reads the same load. It
        must collapse to one key rather than looking like a load change.
        """
        rows = [
            self._set(d, "Pull-Ups", None, reps, 8, target_reps=8, target_rpe=8)
            for d, reps in [("2026-07-11", 10), ("2026-07-18", 11), ("2026-07-25", 12)]
        ]
        stalls = progression.find_stalls(rows)
        self.assertEqual(len(stalls), 1)
        self.assertEqual(stalls[0]["load"], "BW")
        self.assertIn("bodyweight", progression.format_stalls(stalls))

    def test_warmups_and_cardio_are_excluded(self):
        """A warm-up is not a top set, and a cardio row stores minutes in the
        reps column — either one would corrupt the comparison.
        """
        rows = self._ab_crunch_history()
        rows.append(self._set("2026-08-05", "Ab Crunch Machine", 200, 20, 6, is_warmup=True))
        rows += [self._set(d, "Boxing", None, 30, None, notes="cardio session")
                 for d in ("2026-07-14", "2026-07-21", "2026-07-28")]
        stalls = progression.find_stalls(rows)
        self.assertEqual([s["exercise"] for s in stalls], ["Ab Crunch Machine"])
        self.assertEqual(stalls[0]["load"], 75)

    def test_streak_counts_back_from_the_most_recent_session(self):
        """The streak is CONSECUTIVE sessions ending at the newest one, not a
        tally of every session that happened to use the current load.

        The history deliberately returns to 35kg after a session at 30kg. A
        counter that just tallies matches reports four sessions and overstates
        the stall; only one that stops at the first different load reports the
        true three.
        """
        history = [
            ("2026-06-27", 35), ("2026-07-04", 30), ("2026-07-11", 35),
            ("2026-07-18", 35), ("2026-07-25", 35),
        ]
        rows = [self._set(d, "Tricep Pushdown", w, 10, 8, target_reps=10, target_rpe=8)
                for d, w in history]
        stalls = progression.find_stalls(rows)
        self.assertEqual(stalls[0]["load"], 35)
        self.assertEqual(stalls[0]["sessions"], 3)
        self.assertEqual(stalls[0]["first_date"], "2026-07-11")

    def test_empty_history_renders_a_readable_line(self):
        self.assertIn("No lift has held", progression.format_stalls([]))

    def test_prompt_points_the_coach_at_the_computed_block(self):
        """The rule failed as prose for months. It is only fixed if the prompt
        tells the coach the block is binding and names the action.
        """
        prompt = load_system_prompt()
        self.assertIn("PROGRESSION WATCH", prompt)
        self.assertIn("LOAD INCREASE INDICATED", prompt)

    def test_progression_trigger_does_not_override_recovery(self):
        """The first version of this rule said a flagged lift "has its load
        raised in THIS session's prescription" — full stop. That contradicted
        both Recovery-Aware Programming (bad HRV means hold) and the Week 4
        deload (holds Week 3 loads, non-negotiable), leaving the coach with
        two mutually exclusive instructions and no precedence. Detection is
        computed; the decision stays a judgement.
        """
        prompt = load_system_prompt()
        self.assertIn("Recovery outranks the progression trigger", prompt)
        self.assertIn("The block detects; you decide", prompt)
        # Deferring must remain available, with a reason and a stated deadline.
        self.assertIn("explicitly deferred", prompt)
        self.assertIn("Deload week", prompt)

    def test_prompt_no_longer_hardcodes_a_stale_ab_crunch_load(self):
        """The prompt used to carry an audit list naming "Ab Crunch Machine
        (70kg x12)" as the pending step. He had already been at 75kg for weeks,
        so the coach was reading a decision that was months out of date.
        """
        prompt = load_system_prompt()
        self.assertNotIn("Ab Crunch Machine (70kg", prompt)


class CachedPrefixStabilityTests(unittest.TestCase):
    """The stable block must not change while the athlete trains.

    It sits behind the prompt cache breakpoint, so a cache hit needs the bytes
    to match the previous call exactly. Anything that moves mid-session — a
    row for today, a Health Auto Export sync, an unordered query whose rows
    come back shuffled — turns a ~$0.006 read into a ~$0.13 write for the same
    32k tokens. The reply is identical either way, which is what makes this
    class of bug survive: it costs 20x and shows no symptom.

    Two leaks were live when these were written. `get_recovery_history` and
    `get_apple_workouts` bound their queries below by date but not above, so
    today's rows sat in the cached half and changed every time Health Auto
    Export pushed. And `get_full_session_history` fetched sets with no ORDER
    BY at all, leaving the render order to Postgres — which under MVCC moves
    an updated tuple to the end of the heap, so logging a set could reshuffle
    how a session from three weeks ago printed.
    """

    FETCHES = {
        "get_full_session_history": "",
        "get_recovery_history": "",
        "get_substitution_history": "  Lying Leg Curl -> Seated Leg Curl",
        "get_apple_workouts": "",
        "get_workout_state": {},
        "get_weekly_volume": {},
        "get_load_stalls": [],
        "get_weak_point_history": [],
        "get_current_loads": [],
        # Today's sets by definition — it belongs in the live half, and the
        # test below pins it there.
        "get_set_comparisons": [],
    }

    def _build(self, **overrides):
        """Run the real build_context_block against fixture fetches."""
        import coach_context

        today_iso = coach_context.now_local().strftime("%Y-%m-%d")
        fixtures = dict(self.FETCHES)
        fixtures.update(overrides)

        patches = []
        for name, value in fixtures.items():
            patches.append(patch.object(
                coach_context, name, **{"side_effect": lambda *a, _v=value, **k: _v}
            ))
        for p in patches:
            p.start()
        self.addCleanup(lambda: [p.stop() for p in patches])

        stable, live = coach_context.build_context_block(
            {"mesocycle_week": 1, "mesocycle_day": 1},
            "Athlete", 80, 75, logging.getLogger("test"),
            recovery_override={"date": today_iso, "hrv": 60, "resting_hr": 52},
        )
        return stable, live, today_iso

    def test_stable_block_is_identical_when_only_today_changes(self):
        """The invariant, stated directly: today must not move the prefix.

        Between the two calls the Watch workout gains eight minutes and 20
        bpm, today's recovery row gains a weight reading, and another set
        lands. That is an ordinary five minutes of a session. None of it may
        reach the cached half.
        """
        import coach_context
        today_iso = coach_context.now_local().strftime("%Y-%m-%d")

        early_stable, _, _ = self._build(
            get_apple_workouts=f"  {today_iso} — Traditional Strength Training 12min | avg HR 96bpm\n  2026-08-10 — Walking 30min",
            get_recovery_history=f"  {today_iso} | sleep:7.1h | HRV:60\n  2026-08-10 | sleep:6.8h | HRV:55",
            get_full_session_history=f"\n{today_iso} — Pull (tonnage: 400kg)\n  Lat Pulldown: 60kg x 10\n\n2026-08-10 — Push (tonnage: 5000kg)\n  Bench: 80kg x 8",
        )
        late_stable, _, _ = self._build(
            get_apple_workouts=f"  {today_iso} — Traditional Strength Training 20min | avg HR 116bpm\n  2026-08-10 — Walking 30min",
            get_recovery_history=f"  {today_iso} | sleep:7.1h | HRV:60 | weight:79.4kg\n  2026-08-10 | sleep:6.8h | HRV:55",
            get_full_session_history=f"\n{today_iso} — Pull (tonnage: 900kg)\n  Lat Pulldown: 60kg x 10 | 60kg x 10\n\n2026-08-10 — Push (tonnage: 5000kg)\n  Bench: 80kg x 8",
        )

        self.assertEqual(
            early_stable, late_stable,
            "the cached prefix moved mid-session — every later call pays write "
            "rates on ~32k tokens instead of read rates",
        )

    def test_the_set_comparison_block_stays_out_of_the_cached_half(self):
        """It is a comparison against TODAY's sets, so it moves on every logged
        set. In the stable half it would rewrite ~32k tokens per set for a
        reply that is identical either way."""
        comparison = [{"exercise": "Machine Bicep Curl", "verdict": "harder",
                       "load": 55.0, "reps": 9, "rpe": 8.0,
                       "prev_load": 55.0, "prev_reps": 9, "prev_rpe": 7.0,
                       "prev_date": "2026-08-28"}]
        stable, live, _ = self._build(get_set_comparisons=comparison)
        self.assertNotIn("TODAY vs LAST SESSION", stable)
        self.assertIn("TODAY vs LAST SESSION", live)
        self.assertIn("HARDER for identical work", live)

    def test_todays_date_never_appears_in_the_cached_block(self):
        """A blunt catch-all for the next fetch that forgets an upper bound."""
        import coach_context
        today_iso = coach_context.now_local().strftime("%Y-%m-%d")
        stable, _, _ = self._build(
            get_apple_workouts=f"  {today_iso} — Traditional Strength Training 20min",
            get_recovery_history=f"  {today_iso} | sleep:7.1h | HRV:60",
            get_full_session_history=f"\n{today_iso} — Pull (tonnage: 900kg)\n  Lat Pulldown: 60kg x 10",
        )
        self.assertNotIn(today_iso, stable)

    def test_todays_watch_workout_is_moved_to_live_not_dropped(self):
        """Splitting it out of the cache must not lose it.

        The coach reads stable and live as one continuous block, so this is a
        move, not a deletion — and today's Watch data is exactly what it needs
        to judge whether the athlete has already been active.
        """
        today_stable, live, today_iso = self._build(
            get_apple_workouts="  {} — Traditional Strength Training 20min | avg HR 116bpm".format(
                __import__("coach_context").now_local().strftime("%Y-%m-%d")
            ),
        )
        self.assertIn("Traditional Strength Training", live)
        self.assertNotIn("Traditional Strength Training", today_stable)

    def test_todays_recovery_is_not_printed_twice_with_two_sets_of_numbers(self):
        """The DB row and the app's live snapshot can disagree.

        `recovery_override` carries what the athlete sees on the dashboard;
        the 30-day table carries whatever last synced. Printing both let the
        coach read today's HRV as 60 in one block and 41 in another.
        """
        stable, live, today_iso = self._build(
            get_recovery_history=f"  {today_iso if False else __import__('coach_context').now_local().strftime('%Y-%m-%d')} | sleep:7.1h | HRV:41",
        )
        self.assertNotIn("HRV:41", stable)
        self.assertNotIn("HRV:41", live)
        self.assertIn("60", live)

    def test_earlier_history_still_reaches_the_cached_block(self):
        """Splitting today out must not take the other 29 days with it."""
        stable, _, _ = self._build(
            get_apple_workouts="  2026-08-10 — Walking 30min",
            get_recovery_history="  2026-08-10 | sleep:6.8h | HRV:55",
            get_full_session_history="\n2026-08-10 — Push (tonnage: 5000kg)\n  Bench: 80kg x 8",
        )
        self.assertIn("Walking 30min", stable)
        self.assertIn("HRV:55", stable)
        self.assertIn("Bench: 80kg x 8", stable)

    def test_split_helper_keeps_non_dated_rows_on_the_stable_side(self):
        """"No workouts recorded." and error strings must not become "today"."""
        from coach_context import _split_lines_at_today
        past, today = _split_lines_at_today(
            "Could not load Apple Watch workouts: timeout", "2026-08-12", "none", "nothing",
        )
        self.assertIn("timeout", past)
        self.assertEqual(today, "nothing")


class DeterministicQueryOrderTests(unittest.TestCase):
    """Every query feeding the cached block needs a total order.

    Postgres promises nothing without ORDER BY, and a partial order is not
    enough: two rows sharing a date can swap between calls and rewrite the
    prefix. These assert a tiebreaker is present, because the failure is
    invisible in the reply and only shows up on the bill.
    """

    @staticmethod
    def _recording_supabase(seen: dict, rows_for=None):
        """A Supabase stand-in that records the ORDER BY keys per table."""
        class RecordingTable:
            def __init__(self, name):
                self.name = name
                seen.setdefault(name, [])

            def select(self, *a, **k): return self
            def eq(self, *a, **k): return self
            def in_(self, *a, **k): return self
            def gte(self, *a, **k): return self
            def lt(self, *a, **k): return self
            def lte(self, *a, **k): return self
            def limit(self, *a, **k): return self

            def order(self, field, desc=False):
                seen[self.name].append(field)
                return self

            def execute(self):
                return FakeResponse((rows_for or {}).get(self.name, []))

        class RecordingSupabase:
            def table(self, name):
                return RecordingTable(name)

        return RecordingSupabase()

    def test_session_history_orders_every_table_it_touches(self):
        """workout_sets had no ORDER BY at all — this is the expensive one."""
        import coach_context

        seen = {}
        parents = [{"id": 1, "date": "2026-08-10", "type": "Push",
                    "tonnage_kg": 5000, "summary": None}]
        fake = self._recording_supabase(
            seen, {"workout_sessions": parents, "sessions": parents},
        )
        with patch.object(coach_context, "get_supabase", return_value=fake):
            coach_context.get_full_session_history(30)

        self.assertTrue(
            seen.get("workout_sets"),
            "workout_sets is fetched with no ORDER BY — the render order is "
            "whatever Postgres returns, and MVCC changes it on every UPDATE",
        )
        self.assertTrue(seen.get("sets"), "legacy sets table has no ORDER BY")
        for table in ("workout_sessions", "sessions"):
            self.assertGreaterEqual(
                len(seen.get(table, [])), 2,
                f"{table} orders by date alone — two sessions on one day can swap",
            )

    def test_apple_workouts_orders_beyond_date(self):
        import coach_context

        seen = {}
        fake = self._recording_supabase(seen)
        with patch.object(coach_context, "get_supabase", return_value=fake):
            coach_context.get_apple_workouts(30)

        self.assertGreaterEqual(
            len(seen.get("apple_workouts", [])), 2,
            "two Watch workouts on the same day can swap and break the cache",
        )

    def test_substitution_history_orders_beyond_created_at(self):
        seen = {}
        fake = self._recording_supabase(seen)
        with patch.object(workout, "get_supabase", return_value=fake):
            workout.get_substitution_history()

        self.assertGreaterEqual(
            len(seen.get("exercise_substitutions", [])), 2,
            "created_at ties on batch inserts, leaving the order undefined",
        )


class SetCountLookupTests(unittest.TestCase):
    """A Push session was prescribed a SECOND back-off on Machine Chest Press.

    It has had one since August 2026, when Incline Press was added and chest
    went to four movements at 2 sets rather than three at 3. The athlete asked
    why, and the coach then explained the change correctly — so the fact was
    available to it the whole time.

    The prompt already carried the rule, the reason, the consequence of getting
    it wrong, AND a warning that older sessions in the log still show two
    back-offs. It lost anyway, because the log is longer, more concrete and
    more recent-feeling than a sentence in a document. Stating it more firmly
    was not going to work; it is now computed and handed over.
    """

    def setUp(self):
        self.prompt = load_system_prompt()

    def test_push_day_gives_chest_press_two_sets_not_three(self):
        from coach_parsing import parse_session_template
        pairs, _ = parse_session_template(self.prompt, "Push")
        counts = dict(pairs)
        self.assertEqual(counts["Machine Chest Press"], 2)

    def test_every_training_day_parses_and_sums_to_its_stated_total(self):
        from coach_parsing import parse_session_template
        for session, exercises in (("Push", 8), ("Pull", 7), ("Legs", 6)):
            with self.subTest(session=session):
                pairs, total = parse_session_template(self.prompt, session)
                self.assertEqual(len(pairs), exercises)
                self.assertEqual(sum(n for _, n in pairs), total)

    def test_only_yoga_renders_nothing(self):
        """Yoga is the one session type with no set counts to state.

        Cardio+Abs used to be here too, and that was the hole: the day whose
        set counts were most often wrong was the only training day with no
        computed lookup, so the weak-point block's 3 sets survived on prose
        alone at the end of the longest instruction in the programme.
        """
        from coach_parsing import format_session_template
        self.assertEqual(format_session_template(self.prompt, "Yoga"), "")
        self.assertEqual(format_session_template(self.prompt, ""), "")

    def test_every_training_day_renders_a_lookup(self):
        """An empty block and a broken regex used to be the same state. If a
        prompt edit stops a header matching, this fails instead of silently
        shipping a session with no set counts."""
        from coach_parsing import format_session_template
        for session in ("Push", "Pull", "Legs", "Cardio+Abs"):
            with self.subTest(session=session):
                self.assertIn("TODAY'S SET COUNTS",
                              format_session_template(self.prompt, session))

    def test_cardio_day_states_the_weak_point_block_count(self):
        """The block is 3 sets per slot regardless of which muscle fills it.
        That number reaching the coach as a lookup is the whole point."""
        from coach_parsing import format_session_template
        block = format_session_template(self.prompt, "Cardio+Abs")
        self.assertIn("Weak-Point Exercise 1: 3 working sets", block)
        self.assertIn("Weak-Point Exercise 2: 3 working sets", block)
        self.assertIn("Total: 16 working sets.", block)

    def test_ab_work_is_not_described_as_top_set_plus_back_offs(self):
        """All direct ab work is straight sets with NO back-off line. The
        lookup used to render the Ab Crunch Machine as "1 top set + 2
        back-offs" and then assert "Where they disagree, THIS is right" —
        the one computed authority specifying the wrong shape."""
        from coach_parsing import format_session_template
        legs = format_session_template(self.prompt, "Legs")
        ab_line = next(line for line in legs.split("\n")
                       if line.strip().startswith("Ab Crunch Machine:"))
        self.assertIn("straight sets", ab_line)
        self.assertIn("no back-off line", ab_line)
        self.assertNotIn("top set", ab_line)

    def test_the_block_spells_out_the_top_and_backoff_split(self):
        """The error was in the SHAPE of the sets, not the total — "2 sets"
        alone still leaves room to read it as two back-offs."""
        from coach_parsing import format_session_template
        text = format_session_template(self.prompt, "Push")
        self.assertIn("Machine Chest Press: 2 working sets (1 top set + 1 back-off)", text)
        self.assertIn("Machine Shoulder Press: 3 working sets (1 top set + 2 back-offs)", text)

    def test_the_block_demotes_the_log_where_the_numbers_are_read(self):
        """The competing source has to be named at the point of use. It is
        named in the prompt already and that did not hold."""
        from coach_parsing import format_session_template
        text = format_session_template(self.prompt, "Push")
        self.assertIn("30-day log may show DIFFERENT counts", text)
        self.assertIn("Where they disagree, THIS is right", text)

    def test_it_reaches_the_prompt_for_the_session_being_trained(self):
        src = open("coach.py", encoding="utf-8").read()
        self.assertIn("live_context += format_session_template(system_prompt, today_type)", src)


class TelegramSetNumberingTests(unittest.TestCase):
    """Set numbers ran straight through a machine change on the Telegram path.

    `current_set_number` is seeded to 0 when the SESSION starts and never
    again, so three sets of cable crunch followed by a calf raise numbered the
    calf raise sets 4, 5 and 6. The iOS app numbers per exercise, so the same
    session logged the two ways produced two different histories and only one
    of them was right.

    This matters exactly when the app is unavailable — an expired signing
    profile puts every set through this path for a week.
    """

    def _log_sets(self, message, state):
        from unittest.mock import patch
        calls = []

        def record(**kwargs):
            calls.append(kwargs)
            return {"is_pr": False}

        library_hit = {"status": "confident",
                       "match": {"name": "Machine Calf Raise"},
                       "candidates": [], "confidence": 0.95}
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="ok"), \
             patch("coach.get_workout_state", return_value=state), \
             patch("coach.extract_exercise_from_context", return_value="Machine Calf Raise"), \
             patch("coach.find_exercise", return_value=library_hit), \
             patch("coach.log_set", side_effect=record), \
             patch("coach.set_workout_state"), \
             patch("coach.advance_mesocycle"), \
             patch("coach.send_telegram_message"):
            handle_incoming_message(message, {"mesocycle_day": 4, "mesocycle_week": 2})
        return calls

    def test_a_new_exercise_starts_its_sets_at_one(self):
        calls = self._log_sets(
            "Machine Calf Raise 101 x 12",
            {"workout_mode": "active", "current_session_id": "s1",
             "current_set_number": "3", "current_exercise_name": "Cable Crunch"},
        )
        self.assertEqual([c["set_number"] for c in calls], [1])

    def test_continuing_the_same_exercise_keeps_counting(self):
        """The reset must fire on a change, not on every message."""
        calls = self._log_sets(
            "101 x 12",
            {"workout_mode": "active", "current_session_id": "s1",
             "current_set_number": "2", "current_exercise_name": "Machine Calf Raise"},
        )
        self.assertEqual([c["set_number"] for c in calls], [3])


class RPEReductionArithmeticTests(unittest.TestCase):
    """A suppressed-HRV Legs session was prescribed `215kg x8-10 @ RPE7`.

    The previous plan was `215kg x6-8 @ RPE8`. So the card asked for MORE reps
    at LESS effort with the same load, which cannot be performed — RPE is
    reps-in-reserve, an outcome of load and reps rather than a third dial.

    The arithmetic was already in the prompt and already emphatic, but it sat
    inside the deload-week section. The rule the coach actually applied —
    "HRV >10% below 7-day avg: reduce RPE targets by 1" — carried no arithmetic
    and no pointer to any, so the number on the card moved and the reps did not.
    """

    def setUp(self):
        self.prompt = open("system_prompt.txt", encoding="utf-8").read()

    def test_the_hrv_rule_states_what_an_rpe_drop_costs_in_reps(self):
        block = self.prompt.split("### Recovery-Aware Programming")[1][:3000]
        self.assertIn("REP change", block)
        self.assertIn("one point of RPE at a fixed load is one rep", block)

    def test_the_impossible_prescription_is_named_verbatim(self):
        """The wrong answer written out, because the right rule stated
        abstractly did not stop it."""
        self.assertIn("215kg x6-8 @ RPE8", self.prompt)
        self.assertIn("215kg x8-10 @ RPE7", self.prompt)

    def test_the_low_rep_escape_hatch_is_present_outside_deload(self):
        """Subtracting reps from a heavy triple leaves a near-single, which is
        a strength stimulus rather than a lighter day."""
        block = self.prompt.split("### Recovery-Aware Programming")[1][:3000]
        self.assertIn("fewer than 5", block)
        self.assertIn("drop the load", block)

    def test_overlapping_recovery_rules_resolve_to_the_strictest(self):
        """5.8h sleep with HRV 25% down matched three rules at once, and the
        mildest was applied silently."""
        block = self.prompt.split("### Recovery-Aware Programming")[1][:3000]
        self.assertIn("STRICTEST applies", block)

    def test_the_deload_arithmetic_is_still_there(self):
        """The new text generalises the rule; it must not have replaced it."""
        self.assertIn("Prescribing MORE reps at the same load", self.prompt)


class InheritedExerciseAttributionTests(unittest.TestCase):
    """A Telegram session filed eight sets under one exercise, silently.

    With the app down, a Cardio+Abs session was logged over Telegram. Sets
    arrive there as bare numbers — "101 x 12" — so nothing names the lift, and
    the resolver falls back to whichever exercise was last active. Loads from
    37.5kg to 120kg all landed on "Ab crunch machine", and the athlete only
    found out days later reading his own history.

    Inference is not the bug; over Telegram it is the only option. Doing it
    without saying so is, because a wrong guess then persists for the rest of
    the session and pollutes the log that progression reads from.
    """

    def test_the_reply_names_the_exercise_it_guessed(self):
        from coach_parsing import extract_exercise_from_set_message, resolve_exercise_name
        # A bare set message names nothing to resolve — the state the whole
        # failure depends on.
        self.assertFalse(resolve_exercise_name(
            extract_exercise_from_set_message("101 x 12") or ""
        ))

    def test_source_prepends_a_locally_authored_attribution_line(self):
        """Authored in Python, not requested from the model.

        Same reasoning as the iOS fact prefix: the one thing the backend knows
        for certain is what it just wrote to the database, and a warning the
        model may or may not include is not a warning.
        """
        src = open("coach.py", encoding="utf-8").read()
        self.assertIn("inherited_attribution", src)
        self.assertIn("you didn't name a lift", src)
        marker = src.index("if inherited_attribution:")
        chat = src.index("response = chat_with_coach(incoming_text")
        self.assertGreater(marker, chat,
                           "the note must be prepended to a reply that already exists")

    def test_an_explicitly_named_exercise_produces_no_note(self):
        """The note must not fire on every set or it becomes wallpaper."""
        src = open("coach.py", encoding="utf-8").read()
        self.assertIn("if not exercise_was_named:", src)


class LiveSessionIsClosedListTests(unittest.TestCase):
    """The coach reported exercises as done on a session with zero sets.

    Opening a Cardio+Abs session it stated Hanging Leg Raises was "done
    (12, 12, 10 @ RPE7)" with Cable Crunch and Pallof Press "done before
    that" — while the app header read TONNAGE 0kg, SETS 0. Those were real
    numbers from an earlier session, re-dated to today.

    The live block said only "None yet" under a heading, and told the coach
    the values were ground truth without ever saying the list was exhaustive.
    An empty list therefore read as "what I happen to have seen" rather than
    "nothing has happened", and thirty days of history supplied the rest.
    """

    def _block(self, rows):
        from unittest.mock import patch
        import workout

        class Table:
            def __init__(self, name): self.name = name
            def select(self, *a, **k): return self
            def eq(self, *a, **k): return self
            def order(self, *a, **k): return self
            def execute(self):
                if self.name == "workout_sessions":
                    return FakeResponse([{"type": "Cardio+Abs"}])
                return FakeResponse(rows)

        class Supa:
            def table(self, name): return Table(name)

        with patch.object(workout, "get_supabase", return_value=Supa()), \
             patch.object(workout, "get_session_duration_minutes", return_value=12):
            return workout.get_workout_context({
                "workout_mode": "active", "current_session_id": "sess-1",
            })

    def test_an_empty_session_states_that_nothing_was_done(self):
        text = self._block([])
        self.assertIn("NOTHING", text)
        self.assertIn("Working sets logged this session: 0", text)

    def test_an_empty_session_names_the_history_as_the_wrong_source(self):
        """The failure was specifically substitution from earlier sessions."""
        text = self._block([])
        self.assertIn("whatever earlier sessions in the history show", text)

    def test_the_list_is_declared_complete(self):
        """Without this the block is a sample, and a sample invites filling in."""
        text = self._block([])
        self.assertIn("THIS LIST IS COMPLETE", text)
        self.assertIn("has NOT been performed today", text)

    def test_prescribing_is_distinguished_from_performing(self):
        """The conversation is full of prescriptions for exercises not yet done."""
        self.assertIn("Prescribing an exercise is\nnot performing it", self._block([]))

    def test_the_working_count_excludes_warmups(self):
        rows = [
            {"exercise": "Cable Crunch", "set_number": 1, "is_warmup": True,
             "actual_weight_kg": 20, "actual_reps": 12, "logged_at": "2026-08-12T10:00:00"},
            {"exercise": "Cable Crunch", "set_number": 2, "is_warmup": False,
             "actual_weight_kg": 35, "actual_reps": 12, "logged_at": "2026-08-12T10:03:00"},
            {"exercise": "Cable Crunch", "set_number": 3, "is_warmup": False,
             "actual_weight_kg": 35, "actual_reps": 11, "logged_at": "2026-08-12T10:06:00"},
        ]
        text = self._block(rows)
        self.assertIn("Working sets logged this session: 2", text)
        self.assertNotIn("NOTHING", text)

    def test_a_populated_session_still_carries_the_completeness_claim(self):
        """Partial logs mislead the same way — three of six exercises done
        does not license the coach to treat the other three as finished."""
        rows = [
            {"exercise": "Pallof Press", "set_number": 1, "is_warmup": False,
             "actual_weight_kg": 15, "actual_reps": 12, "logged_at": "2026-08-12T10:00:00"},
        ]
        self.assertIn("THIS LIST IS COMPLETE", self._block(rows))


class CurrentWorkingLoadTests(unittest.TestCase):
    """Opening a Legs session, the coach prescribed a load the athlete had
    already passed.

    His last five Leg Press sessions were 205kg on 07-21, 07-25, 07-30 and
    08-04, then 210kg on 08-09. It read the 07-21 figure as the current top set
    and opened at "205 -> 210". Asked to check again it produced the right
    answer from the same context — so nothing was missing, the lookup was just
    buried in twenty-six sessions of prose and it picked the wrong line.

    Reading is therefore not the mechanism. The load is computed.
    """

    LEG_PRESS = [
        {"date": "2026-07-21", "exercise": "Leg Press", "actual_weight_kg": 205,
         "actual_reps": 12, "actual_rpe": 9, "target_reps": 6, "target_rpe": 8},
        {"date": "2026-07-25", "exercise": "Leg Press", "actual_weight_kg": 205,
         "actual_reps": 8, "actual_rpe": 7, "target_reps": 6, "target_rpe": 8},
        {"date": "2026-07-30", "exercise": "Leg Press", "actual_weight_kg": 205,
         "actual_reps": 10, "actual_rpe": 8, "target_reps": 6, "target_rpe": 8},
        {"date": "2026-08-04", "exercise": "Leg Press", "actual_weight_kg": 205,
         "actual_reps": 12, "actual_rpe": 8, "target_reps": 6, "target_rpe": 8},
        {"date": "2026-08-09", "exercise": "Leg Press", "actual_weight_kg": 210,
         "actual_reps": 11, "actual_rpe": 9, "target_reps": 6, "target_rpe": 8},
    ]

    def test_reports_the_most_recent_load_not_the_heaviest_history(self):
        from progression import find_current_loads
        [entry] = find_current_loads(self.LEG_PRESS)
        self.assertEqual(entry["load"], 210)
        self.assertEqual(entry["date"], "2026-08-09")

    def test_row_order_from_the_database_cannot_change_the_answer(self):
        """The rows arrive unordered, so the newest must be found, not assumed.

        This is the specific shape of the original bug: something earlier in
        the list was treated as current.
        """
        from progression import find_current_loads
        for rows in (self.LEG_PRESS, list(reversed(self.LEG_PRESS))):
            with self.subTest(order="reversed" if rows is not self.LEG_PRESS else "natural"):
                [entry] = find_current_loads(rows)
                self.assertEqual(entry["load"], 210)

    def test_a_lighter_recent_session_still_wins(self):
        """Recency beats magnitude. A deload week is the current load.

        Taking the heaviest ever would have got 07-21 right by luck here and
        wrong the moment the athlete backs off — which week 4 does by design.
        """
        from progression import find_current_loads
        rows = self.LEG_PRESS + [
            {"date": "2026-08-11", "exercise": "Leg Press", "actual_weight_kg": 160,
             "actual_reps": 12, "actual_rpe": 6, "target_reps": 12, "target_rpe": 6},
        ]
        [entry] = find_current_loads(rows)
        self.assertEqual(entry["load"], 160)

    def test_warmups_are_never_the_current_load(self):
        from progression import find_current_loads
        rows = self.LEG_PRESS + [
            {"date": "2026-08-09", "exercise": "Leg Press", "actual_weight_kg": 150,
             "actual_reps": 12, "is_warmup": True},
        ]
        [entry] = find_current_loads(rows)
        self.assertEqual(entry["load"], 210)

    def test_bodyweight_movements_report_reps_not_a_phantom_weight(self):
        from progression import find_current_loads, format_current_loads
        rows = [
            {"date": "2026-08-11", "exercise": "Pull-ups", "actual_weight_kg": 0,
             "actual_reps": 9, "actual_rpe": 9, "target_reps": 8, "target_rpe": 9},
        ]
        entries = find_current_loads(rows)
        self.assertEqual(entries[0]["load"], "BW")
        self.assertIn("bodyweight x9", format_current_loads(entries))

    def test_cardio_and_yoga_rows_are_excluded(self):
        """They share the table but carry a duration in the reps column."""
        from progression import find_current_loads
        rows = [
            {"date": "2026-08-11", "exercise": "Treadmill", "actual_reps": 30,
             "notes": "cardio — incline walk"},
        ]
        self.assertEqual(find_current_loads(rows), [])

    def test_the_rendered_block_names_load_reps_rpe_and_date(self):
        """All four, because the coach reasons about the next step from them."""
        from progression import find_current_loads, format_current_loads
        text = format_current_loads(find_current_loads(self.LEG_PRESS))
        for fragment in ("Leg Press", "210kg", "x11", "RPE9", "2026-08-09"):
            self.assertIn(fragment, text)

    def test_empty_history_says_so_rather_than_rendering_nothing(self):
        from progression import format_current_loads
        self.assertIn("No working sets", format_current_loads([]))

    def test_each_exercise_appears_exactly_once(self):
        from progression import find_current_loads
        rows = self.LEG_PRESS + [
            {"date": "2026-08-10", "exercise": "Lat Pulldown", "actual_weight_kg": 75,
             "actual_reps": 10, "actual_rpe": 8, "target_reps": 8, "target_rpe": 8},
        ]
        entries = find_current_loads(rows)
        names = [e["exercise"] for e in entries]
        self.assertEqual(sorted(names), names, "block must read alphabetically")
        self.assertEqual(len(names), len(set(names)))

    def test_the_block_reaches_the_cached_half_of_the_context(self):
        """It excludes today, so it belongs with PROGRESSION WATCH in stable.

        Putting it in the live block would re-bill it on every logged set for
        data that cannot change until tomorrow.
        """
        import coach_context
        self.assertIn("CURRENT WORKING LOADS", open("system_prompt.txt", encoding="utf-8").read())
        src = open("coach_context.py", encoding="utf-8").read()
        stable = src.split("stable = f\"\"\"")[1].split('"""')[0]
        self.assertIn("{current_loads}", stable)


class NumberedPhaseLabelTests(unittest.TestCase):
    """The coach echoed the app's own phrasing and the card ignored it.

    Mid-deload the coach revised a back-off down to 90kg and wrote it as
    "Back-off 2 of 2: 90kg x6 RPE6" — the phrasing the app itself teaches, since
    the per-set message it sends says "Next: back-off 2 of 2 on <exercise>". The
    strict prefixes only matched "Back-off:", and the loose fallback wants
    "N sets:", so the line was dropped and the card kept rendering the
    superseded 95kg. The athlete was told 90kg twice and shown 95kg throughout.
    """

    def test_numbered_backoff_line_is_parsed(self):
        from webhook import _parse_prescription
        text = (
            "*Single Leg Sumo Press*\n"
            "Working Set: 120kg x8 RPE7 | Tempo: 3-1-2 | Rest: 2min\n"
            "Back-off 2 of 2: 90kg x6 RPE6\n"
        )
        rx = _parse_prescription(text)
        self.assertIsNotNone(rx)
        self.assertEqual(rx["backoff"], [{"weight": 90.0, "reps": 6, "rpe": 6.0}])

    def test_numbered_working_and_warmup_labels_are_parsed(self):
        from webhook import _parse_prescription
        text = (
            "*Leg Press*\n"
            "Warm-up 1 of 2: 60kg x10\n"
            "Working Set 1 of 2: 220kg x8 RPE7 | Tempo: 3-1-2 | Rest: 2min\n"
        )
        rx = _parse_prescription(text)
        self.assertIsNotNone(rx)
        self.assertEqual(rx["warmup"], [{"weight": 60.0, "reps": 10}])
        self.assertEqual(rx["working"], [{"weight": 220.0, "reps": 8, "rpe": 7.0}])

    def test_loose_and_metadata_lines_are_left_alone(self):
        """The rewrite must not disturb lines that legitimately carry digits."""
        from webhook import _canonicalise_phase_label as c
        for line in ("3 sets: 90kg x12 rpe7", "tempo: 3-1-2", "form: pull with abs"):
            self.assertEqual(c(line), line)

    def test_both_parsers_share_the_phrasing_the_app_teaches(self):
        """iOS and backend must agree, or the card and the coach diverge again."""
        swift = open("Vaux/Vaux/Services/PrescriptionParser.swift", encoding="utf-8").read()
        self.assertIn("canonicalisePhaseLabel", swift)
        ios = open("Vaux/Vaux/ViewModels/WorkoutViewModel.swift", encoding="utf-8").read()
        # The message that teaches the coach "back-off N of M" phrasing.
        self.assertIn("of \\(phaseTotal)", ios)


class PeakWeekReferenceLoadTests(unittest.TestCase):
    """On a week 4 deload, the coach anchored to month-old numbers.

    The deload holds week 3's load, so the coach went looking for "week 3
    numbers" — and found them in a `Week 3 reference loads:` line typed into the
    system prompt, frozen weeks earlier. Reminded, it produced the right figures
    immediately from the same context. Same shape as the CURRENT WORKING LOADS
    bug above: nothing missing, the wrong source consulted.

    So the peak week is computed too. It cannot be derived from dates — the
    mesocycle week advances per completed rotation, not per calendar week — so
    it is read from the week stamped on each session.
    """

    # Week 3 peaked at 205kg x12; week 4 deloaded by holding the load and
    # cutting reps, which is what makes "most recent" the wrong answer here.
    ROWS = [
        {"date": "2026-08-04", "exercise": "Leg Press", "mesocycle_week": 2,
         "actual_weight_kg": 190, "actual_reps": 10, "actual_rpe": 8},
        {"date": "2026-08-09", "exercise": "Leg Press", "mesocycle_week": 3,
         "actual_weight_kg": 205, "actual_reps": 12, "actual_rpe": 9},
        {"date": "2026-08-14", "exercise": "Leg Press", "mesocycle_week": 4,
         "actual_weight_kg": 205, "actual_reps": 6, "actual_rpe": 7},
    ]

    def test_returns_the_peak_week_set_not_the_most_recent(self):
        from progression import find_peak_week_loads
        [entry] = find_peak_week_loads(self.ROWS)
        self.assertEqual(entry["load"], 205)
        self.assertEqual(entry["date"], "2026-08-09")
        # The deload shares the load but not the reps; quoting 6 back as the
        # peak would under-open week 1 of the next cycle.
        self.assertEqual(entry["reps"], 12)

    def test_most_recent_peak_week_wins_over_an_older_one(self):
        """Cycles repeat, so week 3 recurs. The latest one is the reference."""
        from progression import find_peak_week_loads
        rows = self.ROWS + [
            {"date": "2026-09-06", "exercise": "Leg Press", "mesocycle_week": 3,
             "actual_weight_kg": 215, "actual_reps": 10, "actual_rpe": 9},
        ]
        [entry] = find_peak_week_loads(rows)
        self.assertEqual(entry["load"], 215)
        self.assertEqual(entry["date"], "2026-09-06")

    def test_unstamped_sessions_are_skipped_not_guessed(self):
        """Sessions predating the stamp have no week and must not be inferred.

        Reading an unstamped row as week 3 would resurrect exactly the failure
        this block exists to end.
        """
        from progression import find_peak_week_loads
        rows = [{k: v for k, v in row.items() if k != "mesocycle_week"}
                for row in self.ROWS]
        self.assertEqual(find_peak_week_loads(rows), [])

    def test_empty_block_names_the_fallback_instead_of_going_silent(self):
        """An unexplained empty heading is what gets filled from memory."""
        from progression import format_peak_week_loads
        text = format_peak_week_loads([])
        self.assertIn("CURRENT WORKING LOADS", text)
        self.assertIn("Do NOT", text)

    def test_block_is_injected_into_the_cacheable_half(self):
        """It excludes today, so it belongs in stable alongside the others."""
        src = open("coach_context.py", encoding="utf-8").read()
        stable = src.split("stable = f\"\"\"")[1].split('"""')[0]
        self.assertIn("{peak_week_loads}", stable)
        self.assertIn("PEAK WEEK REFERENCE LOADS", stable)

    def test_prompt_carries_no_hardcoded_reference_loads(self):
        """The regression itself: a load list typed into the prompt.

        `Week 3 reference loads:` lines used to carry real weights per session
        template. They went stale and were prescribed on a deload. The heading
        may stay as a pointer; a kg figure on that line may not.
        """
        prompt = open("system_prompt.txt", encoding="utf-8").read()
        for line in prompt.splitlines():
            if line.strip().startswith("Week 3 reference loads:"):
                self.assertNotIn("kg", line, f"hardcoded load survived: {line[:90]}")
                self.assertIn("PEAK WEEK REFERENCE LOADS", line)


class MesocycleStampTests(unittest.TestCase):
    """A session records the mesocycle week it belongs to, at creation.

    It cannot be recovered later: `advance_mesocycle` bumps the week only when a
    full rotation completes, and yoga days and session swaps deliberately do not
    advance it, so the week is not a function of the calendar.
    """

    def test_start_session_stamps_the_current_week(self):
        store = {"memory": [], "workout_sessions": []}
        with patch.object(workout, "get_supabase", return_value=FakeSupabase(store)), \
             patch("memory.load_memory", return_value={"mesocycle_week": 3, "mesocycle_day": 2}):
            workout.start_session("Legs")

        [row] = store["workout_sessions"]
        self.assertEqual(row["mesocycle_week"], 3)
        self.assertEqual(row["mesocycle_day"], 2)

    def test_a_failed_memory_read_still_creates_the_session(self):
        """Stamping is best-effort — it must never block starting a workout.

        Asserted on the written row rather than the returned id: FakeSupabase
        has no `gen_random_uuid()` default, so the insert comes back without an
        id and start_session returns "" regardless of stamping.
        """
        store = {"memory": [], "workout_sessions": []}
        with patch.object(workout, "get_supabase", return_value=FakeSupabase(store)), \
             patch("memory.load_memory", side_effect=RuntimeError("db down")):
            workout.start_session("Legs")

        [row] = store["workout_sessions"]
        self.assertEqual(row["type"], "Legs")
        # Absent, not defaulted to 1 — a wrong week is worse than no week.
        self.assertNotIn("mesocycle_week", row)
        self.assertNotIn("mesocycle_day", row)


class HistoryWindowInvariantTests(unittest.TestCase):
    """Lock the contract of `truncate_history` before anyone reshapes it.

    The window is the most expensive part of a request — it is the one block
    the prompt cache never covers, so it is a standing target for cost work.
    It is also the block whose failure mode is the coach forgetting a stated
    injury, which is why the pinning exists at all. Two tests guarded a
    function carrying that much weight.

    These assert the properties any rewrite must preserve, rather than the
    current implementation's mechanics, so a change to *how* the window is cut
    stays free while a change to what the coach can see does not.
    """

    @staticmethod
    def _log_pairs(n: int, start: int = 0) -> list:
        """n athlete/coach exchanges, each uniquely identifiable."""
        out = []
        for i in range(start, start + n):
            out.append({"role": "user", "content": f"Logged working set {i}"})
            out.append({"role": "assistant", "content": f"Reply {i}"})
        return out

    def test_short_history_is_returned_untouched(self):
        from coach_context import truncate_history, MAX_CONVERSATION_MESSAGES
        history = self._log_pairs(MAX_CONVERSATION_MESSAGES // 2)
        self.assertEqual(len(history), MAX_CONVERSATION_MESSAGES)
        self.assertEqual(truncate_history(history), history)

    def test_never_shows_the_coach_less_than_the_window(self):
        """The floor, not the exact size.

        A rewrite may legitimately keep MORE than the window (a wider cut
        point is how you stop the prefix moving on every turn). Keeping less
        is the regression — that is context the coach used to have.
        """
        from coach_context import truncate_history, MAX_CONVERSATION_MESSAGES
        for exchanges in (25, 30, 40, 60):
            with self.subTest(exchanges=exchanges):
                history = self._log_pairs(exchanges)
                kept = truncate_history(history)
                self.assertGreaterEqual(
                    len(kept), MAX_CONVERSATION_MESSAGES,
                    "truncation dropped below the window the coach is tuned against",
                )

    def test_the_tail_is_contiguous_and_ends_at_the_newest_message(self):
        """No gaps in the recent stretch, and the last message is the newest.

        A set log means nothing without the reply it answers. Any cut that
        interleaves or reorders the tail would have the coach reading a
        conversation that never happened.
        """
        from coach_context import truncate_history, MAX_CONVERSATION_MESSAGES
        history = self._log_pairs(40)
        kept = truncate_history(history)

        self.assertEqual(kept[-1], history[-1])

        tail = kept[-MAX_CONVERSATION_MESSAGES:]
        start = history.index(tail[0])
        self.assertEqual(
            tail, history[start:start + MAX_CONVERSATION_MESSAGES],
            "the recent window is not a contiguous slice of the real conversation",
        )

    def test_pinned_constraints_stay_in_chronological_order(self):
        """Two injuries must not arrive newest-first.

        The coach reads them as a sequence — "shoulder hurt, then it settled"
        reverses into something else entirely if the order flips.
        """
        from coach_context import truncate_history
        history = [
            {"role": "user", "content": "my shoulder is hurting today"},
            {"role": "assistant", "content": "Noted."},
            {"role": "user", "content": "also my knee is sore, skip the leg press"},
            {"role": "assistant", "content": "Noted."},
        ]
        history += self._log_pairs(40)

        kept = truncate_history(history)
        texts = [m.get("content") or "" for m in kept]
        shoulder = next(i for i, t in enumerate(texts) if "shoulder is hurting" in t)
        knee = next(i for i, t in enumerate(texts) if "knee is sore" in t)
        self.assertLess(shoulder, knee)

    def test_pinning_is_capped_so_chat_cannot_crowd_out_the_window(self):
        from coach_context import truncate_history, _MAX_PINNED, MAX_CONVERSATION_MESSAGES
        history = []
        for i in range(_MAX_PINNED * 3):
            history.append({"role": "user", "content": f"my knee is sore, round {i}"})
            history.append({"role": "assistant", "content": "Noted."})
        history += self._log_pairs(40)

        kept = truncate_history(history)
        pinned_count = len(kept) - MAX_CONVERSATION_MESSAGES
        self.assertLessEqual(
            pinned_count, _MAX_PINNED,
            "pinned messages exceeded their cap and are eating the recent window",
        )

    def test_the_newest_constraint_survives_when_the_cap_is_hit(self):
        """When constraints must be dropped, drop the stale ones.

        Today's injury outranks one from six sessions ago; keeping the oldest
        six would pin history and discard the thing that changes today's plan.
        """
        from coach_context import truncate_history, _MAX_PINNED
        history = []
        for i in range(_MAX_PINNED + 4):
            history.append({"role": "user", "content": f"my knee is sore, round {i}"})
            history.append({"role": "assistant", "content": "Noted."})
        newest_round = _MAX_PINNED + 3
        history += self._log_pairs(40)

        kept = truncate_history(history)
        texts = [m.get("content") or "" for m in kept]
        self.assertTrue(
            any(f"round {newest_round}" in t for t in texts),
            "the most recent constraint was dropped in favour of older ones",
        )

    def test_assistant_messages_are_never_pinned(self):
        """Only the athlete states a constraint.

        The coach echoing "understood, no pull-ups" is not new information,
        and pinning its own replies would double the cost of every injury.
        """
        from coach_context import truncate_history
        history = [
            {"role": "assistant", "content": "Your shoulder is hurting, so no pull-ups."},
        ]
        history += self._log_pairs(40)
        kept = truncate_history(history)
        self.assertFalse(
            any((m.get("content") or "").startswith("Your shoulder") for m in kept)
        )


if __name__ == "__main__":
    unittest.main()


class SetCountEnforcementTests(unittest.TestCase):
    """The set count was computed, handed to the coach, and then never checked.

    format_session_template puts "Seated Leg Curl: 3 working sets" into the
    live context on every Legs day. Replies came back with 2 anyway, and
    nothing downstream noticed — the app renders whatever chips the reply
    parses to, marks the session complete against that same number, and the
    log then shows a 2-set session as though it had been prescribed.
    """

    def setUp(self):
        self.prompt = load_system_prompt()

    @staticmethod
    def _block(name, working, backoff=None, extra=""):
        text = f"\n*{name}*\n{extra}Working Set: {working}\n"
        if backoff:
            text += f"Back-off: {backoff}\n"
        return text + "Form: Control the eccentric.\n"

    def test_a_two_set_leg_curl_on_legs_day_is_flagged(self):
        """The athlete's reported case, exactly."""
        reply = self._block("Seated Leg Curl", "50kg x12 RPE8", "45kg x14 RPE7")
        found = check_set_counts(reply, self.prompt, "Legs")
        self.assertEqual(len(found["mismatches"]), 1)
        self.assertEqual(found["mismatches"][0]["expected"], 3)
        self.assertEqual(found["mismatches"][0]["actual"], 2)

    def test_a_correct_three_set_prescription_is_silent(self):
        reply = self._block("Seated Leg Curl", "50kg x12 RPE8",
                            "45kg x14 RPE7, 45kg x12 RPE7")
        self.assertEqual(check_set_counts(reply, self.prompt, "Legs")["mismatches"], [])

    def test_an_alias_name_still_binds_to_the_template(self):
        """The prompt calls this movement four different things. An exact-match
        check would silently skip the exercise it was built for."""
        reply = self._block("Leg Curl", "50kg x12 RPE8", "45kg x14 RPE7")
        found = check_set_counts(reply, self.prompt, "Legs")
        self.assertEqual(len(found["mismatches"]), 1)

    def test_an_ambiguous_partial_name_is_not_guessed(self):
        """"Press" matches four Push-day keys. Attributing it to one of them
        would invent a mismatch on an exercise that was never prescribed."""
        reply = self._block("Press", "100kg x8 RPE8", "90kg x10 RPE7")
        found = check_set_counts(reply, self.prompt, "Push")
        self.assertEqual(found["mismatches"], [])
        self.assertIn("Press", found["unmatched"])

    def test_a_reasoned_deviation_is_recorded_but_not_a_fault(self):
        """Not every exercise should run its template count, always. A sore
        knee is a real reason to prescribe 2, and a coach that cannot do that
        is worse, not more disciplined. The failure was silent deviation, so a
        `Revised:` block is separated out rather than flagged — still recorded,
        because a run of them means the template is what needs changing."""
        reply = self._block("Seated Leg Curl", "50kg x12 RPE8", "45kg x14 RPE7",
                            extra="Revised: knee sore, dropping to 2 sets\n")
        found = check_set_counts(reply, self.prompt, "Legs")
        self.assertEqual(found["mismatches"], [])
        self.assertEqual(len(found["deliberate"]), 1)
        self.assertEqual(found["deliberate"][0]["actual"], 2)

    def test_the_same_count_without_a_reason_is_a_fault(self):
        """The pair to the test above — identical prescription, no marker.
        This is the distinction the whole check turns on."""
        reply = self._block("Seated Leg Curl", "50kg x12 RPE8", "45kg x14 RPE7")
        found = check_set_counts(reply, self.prompt, "Legs")
        self.assertEqual(found["deliberate"], [])
        self.assertEqual(len(found["mismatches"]), 1)

    def test_every_exercise_in_a_reply_is_checked_not_just_the_first(self):
        """_parse_prescription returns only the first block, because the card
        renders one exercise. A wrong count is as likely to be on the fourth."""
        reply = (self._block("Leg Press", "205kg x12 RPE9",
                             "160kg x15 RPE8, 160kg x13 RPE8")
                 + self._block("Seated Leg Curl", "50kg x12 RPE8", "45kg x14 RPE7"))
        found = check_set_counts(reply, self.prompt, "Legs")
        self.assertEqual(found["checked"], 2)
        self.assertEqual([m["exercise"] for m in found["mismatches"]],
                         ["Seated Leg Curl"])

    def test_narrative_replies_are_not_flagged(self):
        """Most messages in a session carry no prescription at all."""
        found = check_set_counts("Nice work — 90 seconds then go again.",
                                 self.prompt, "Legs")
        self.assertEqual(found, {"mismatches": [], "deliberate": [],
                                 "unmatched": [], "checked": 0})


class SystemPromptConsistencyTests(unittest.TestCase):
    """Nothing checked the prompt against itself.

    Every set count in this document exists in several places — the template
    line, the 2-set/3-set membership lists, the worked briefing example, the
    reference-load lines — and they had drifted apart. A model reading one of
    the stale copies gets a defensible wrong answer, which is how the same
    exercise came to be prescribed at 2 sets one day and 3 the next.
    """

    def setUp(self):
        self.prompt = load_system_prompt()

    def test_each_day_sums_to_its_stated_total(self):
        for session in ("Push", "Pull", "Legs", "Cardio+Abs"):
            with self.subTest(session=session):
                pairs, total = parse_session_template(self.prompt, session)
                self.assertTrue(pairs, f"{session} template did not parse")
                self.assertEqual(sum(n for _, n in pairs), total)

    def test_the_three_set_list_agrees_with_the_templates(self):
        """Line 56 names the exercises that carry 3 sets. If an exercise is
        named there and the template gives it 2, the model has two sources
        and no way to choose."""
        three_set_line = next(
            line for line in self.prompt.split("\n")
            if line.startswith("- *3 working sets*")
        )
        templates = {}
        for session in ("Push", "Pull", "Legs"):
            templates.update(dict(parse_session_template(self.prompt, session)[0]))
        for name, count in templates.items():
            if name in three_set_line:
                with self.subTest(exercise=name):
                    self.assertEqual(
                        count, 3,
                        f"{name} is in the 3-set list but the template gives it {count}",
                    )

    def test_the_two_set_list_agrees_with_the_templates(self):
        two_set_line = next(
            line for line in self.prompt.split("\n")
            if line.startswith("- *2 working sets*")
        )
        templates = {}
        for session in ("Push", "Pull", "Legs"):
            templates.update(dict(parse_session_template(self.prompt, session)[0]))
        for name, count in templates.items():
            if name in two_set_line:
                with self.subTest(exercise=name):
                    self.assertEqual(
                        count, 2,
                        f"{name} is in the 2-set list but the template gives it {count}",
                    )

    def test_no_stale_lying_leg_curl_reference_survives(self):
        """The swap happened in August 2026. Every surviving mention describes
        the old exercise as current — including, at the time this was written,
        the do-not-cut list, which left the seated curl unprotected on a
        literal reading."""
        # The sentence documenting the swap itself has to name the old
        # exercise, so it is exempt. Everything else that still mentions it is
        # describing a movement the programme no longer contains.
        stale = [line.strip()[:90] for line in self.prompt.split("\n")
                 if "lying leg curl" in line.lower()
                 and "replaced the Lying Leg Curl" not in line]
        self.assertEqual(stale, [], f"stale lying leg curl references: {stale}")

    def test_the_do_not_cut_list_names_the_exercise_that_exists(self):
        """The time-pressure rule protected "the lying leg curl". On a literal
        reading that left Seated Leg Curl — the only direct hamstring work on
        Legs day — cuttable, which is one of the routes to a 2-set session."""
        protection = next(line for line in self.prompt.split("\n")
                          if line.startswith("- Sessions fill the 90-minute budget"))
        self.assertIn("Seated Leg Curl", protection)

    def test_the_volume_ramp_exception_is_gone(self):
        """It authorised running a template-3 exercise at 2 sets, was scoped
        to "first cycle of the new programme only", and nothing anywhere
        tracked which cycle he was in — so it never expired."""
        self.assertNotIn("weeks 1-2 double as the volume ramp", self.prompt)
        self.assertNotIn("Week 1 carries 2-3 of the new sets", self.prompt)


class SetCountEnforcementTrimsTests(unittest.TestCase):
    """Logging the divergence was not enough.

    The count is computed, rendered into context as an explicit lookup, and a
    Pull session still went out with three sets of Reverse Cable Fly against a
    template of two — a week after the same session had correctly explained why
    it is two. Both replies were defensible; only one was right; and from the
    athlete's side the pair is indistinguishable from randomness, which costs
    the correct reply its authority too.
    """

    def setUp(self):
        self.prompt = load_system_prompt()

    def test_the_reported_case_a_third_reverse_fly_set_is_removed(self):
        reply = ("*Reverse Cable Fly*\n"
                 "Working Set: 8kg x12 RPE7 | Tempo: 2-1-2 | Rest: 90s\n"
                 "Back-off: 8kg x14 RPE7, 8kg x12 RPE7\n"
                 "Form: Lead with the elbows.\n")
        out, fixes = enforce_set_counts(reply, self.prompt, "Pull")
        self.assertEqual(len(fixes), 1)
        self.assertEqual(fixes[0]["dropped"], 1)
        self.assertIn("Back-off: 8kg x14 RPE7\n", out)
        self.assertNotIn("8kg x12 RPE7\n", out)
        # And the result now satisfies the check that flagged it.
        self.assertEqual(check_set_counts(out, self.prompt, "Pull")["mismatches"], [])

    def test_a_correct_block_is_returned_untouched_byte_for_byte(self):
        reply = ("*Machine Bicep Curl*\n"
                 "Working Set: 55kg x9 RPE8 | Tempo: 3-1-1 | Rest: 90s\n"
                 "Back-off: 45kg x12 RPE7, 45kg x10 RPE7\n"
                 "Form: No swinging.\n")
        out, fixes = enforce_set_counts(reply, self.prompt, "Pull")
        self.assertEqual(fixes, [])
        self.assertEqual(out, reply)

    def test_an_under_count_is_never_filled_in(self):
        """Adding a set means inventing a load and a rep target the coach did
        not choose — worse than the wrong count. Report it, don't fix it."""
        reply = ("*Machine Bicep Curl*\n"
                 "Working Set: 55kg x9 RPE8\n"
                 "Back-off: 45kg x12 RPE7\n")
        out, fixes = enforce_set_counts(reply, self.prompt, "Pull")
        self.assertEqual(fixes, [])
        self.assertEqual(out, reply)
        self.assertEqual(len(check_set_counts(out, self.prompt, "Pull")["mismatches"]), 1)

    def test_a_revised_block_is_left_alone(self):
        """The marker is the coach saying the structure is deliberate."""
        reply = ("*Reverse Cable Fly*\n"
                 "Revised: adding a set, rear delts felt fresh\n"
                 "Working Set: 8kg x12 RPE7\n"
                 "Back-off: 8kg x14 RPE7, 8kg x12 RPE7\n")
        out, fixes = enforce_set_counts(reply, self.prompt, "Pull")
        self.assertEqual(fixes, [])
        self.assertEqual(out, reply)

    def test_straight_sets_are_trimmed_on_the_working_line(self):
        """Ab work enumerates every set on the working line and has no
        back-off, so the surplus is there instead."""
        reply = ("*Ab Crunch Machine*\n"
                 "Working Set: 75kg x12, 75kg x12, 75kg x12, 75kg x12 RPE8 | Rest: 90s\n"
                 "Form: Controlled.\n")
        out, fixes = enforce_set_counts(reply, self.prompt, "Legs")
        self.assertEqual(len(fixes), 1)
        self.assertEqual(fixes[0]["phase"], "working")
        self.assertIn("75kg x12, 75kg x12, 75kg x12 RPE8", out)

    def test_a_trailing_rpe_survives_the_trim(self):
        """The straight-set format hangs one RPE off the LAST entry. Dropping
        the tail would take the target effort with it and leave the card with
        no RPE at all."""
        reply = ("*Cable Crunch*\n"
                 "Working Set: 25kg x12, 25kg x12, 25kg x12, 25kg x12 RPE8\n")
        out, _ = enforce_set_counts(reply, self.prompt, "Cardio+Abs")
        self.assertIn("RPE8", out)
        self.assertEqual(out.count("25kg x12"), 3)

    def test_an_exercise_with_no_template_entry_is_untouched(self):
        """Substitutions and weak-point slots have no template line. Trimming
        on a guess is worse than leaving them."""
        reply = ("*Overhead Cable Extension*\n"
                 "Working Set: 30kg x12 RPE7\n"
                 "Back-off: 25kg x14 RPE7, 25kg x12 RPE7\n")
        out, fixes = enforce_set_counts(reply, self.prompt, "Cardio+Abs")
        self.assertEqual(fixes, [])
        self.assertEqual(out, reply)

    def test_narrative_and_pipe_suffixes_survive(self):
        """Tempo and Rest ride on the same line after a pipe and must not be
        eaten by the trim."""
        reply = ("Here we go.\n\n"
                 "*Reverse Cable Fly*\n"
                 "Back-off: 8kg x14 RPE7, 8kg x12 RPE7 | Tempo: 2-1-2 | Rest: 90s\n")
        out, _ = enforce_set_counts(reply, self.prompt, "Pull")
        self.assertIn("Tempo: 2-1-2", out)
        self.assertIn("Rest: 90s", out)
        self.assertIn("Here we go.", out)


class SetComparisonTests(unittest.TestCase):
    """55kg x9 @RPE8 today against 55kg x9 @RPE7 last session was reported to
    the athlete as "one better than last session at the same RPE".

    Identical reps, and the RPE had moved. So there was no improvement, and the
    set was HARDER for the same work — the opposite of what he was told. Both
    facts were already in his context; only the comparison between them was
    missing, which is find_current_loads' lesson one level up.
    """

    @staticmethod
    def _set(exercise, weight, reps, rpe, date="2026-09-02"):
        return {"date": date, "exercise": exercise, "is_warmup": False,
                "notes": None, "actual_weight_kg": weight, "actual_reps": reps,
                "actual_rpe": rpe, "target_reps": None, "target_rpe": None}

    @staticmethod
    def _ref(exercise, load, reps, rpe, date="2026-08-28"):
        return {"exercise": exercise, "date": date, "load": load, "reps": reps,
                "rpe": rpe, "met_target": True}

    def test_same_load_same_reps_higher_rpe_is_not_a_progression(self):
        """The reported case."""
        out = progression.find_set_comparisons(
            [self._set("Machine Bicep Curl", 55, 9, 8.0)],
            [self._ref("Machine Bicep Curl", 55.0, 9, 7.0)],
        )
        self.assertEqual(out[0]["verdict"], "harder")
        rendered = progression.format_set_comparisons(out)
        self.assertIn("NOT a progression", rendered)
        self.assertIn("HARDER", rendered)

    def test_the_same_numbers_at_a_lower_rpe_say_the_load_is_ready(self):
        out = progression.find_set_comparisons(
            [self._set("Machine Bicep Curl", 55, 9, 6.0)],
            [self._ref("Machine Bicep Curl", 55.0, 9, 7.0)],
        )
        self.assertEqual(out[0]["verdict"], "easier")
        self.assertIn("ready to move", progression.format_set_comparisons(out))

    def test_identical_everything_is_flat_not_a_gain(self):
        out = progression.find_set_comparisons(
            [self._set("Lat Pulldown", 95, 5, 8.0)],
            [self._ref("Lat Pulldown", 95.0, 5, 8.0)],
        )
        self.assertEqual(out[0]["verdict"], "matched")
        self.assertIn("Flat, not a gain", progression.format_set_comparisons(out))

    def test_an_extra_rep_at_the_same_load_is_a_progression(self):
        out = progression.find_set_comparisons(
            [self._set("Cable Row", 86.5, 6, 7.0)],
            [self._ref("Cable Row", 86.5, 5, 7.0)],
        )
        self.assertEqual(out[0]["verdict"], "reps_up")
        self.assertIn("Progression", progression.format_set_comparisons(out))

    def test_fewer_reps_is_called_out_as_not_a_progression(self):
        out = progression.find_set_comparisons(
            [self._set("Cable Row", 86.5, 4, 7.0)],
            [self._ref("Cable Row", 86.5, 5, 7.0)],
        )
        self.assertEqual(out[0]["verdict"], "reps_down")
        self.assertIn("NOT a progression", progression.format_set_comparisons(out))

    def test_a_load_change_reports_as_a_load_change(self):
        up = progression.find_set_comparisons(
            [self._set("T-Bar Row", 57.5, 5, 7.0)], [self._ref("T-Bar Row", 55.0, 5, 7.0)])
        down = progression.find_set_comparisons(
            [self._set("T-Bar Row", 52.5, 5, 7.0)], [self._ref("T-Bar Row", 55.0, 5, 7.0)])
        self.assertEqual(up[0]["verdict"], "load_up")
        self.assertEqual(down[0]["verdict"], "load_down")

    def test_an_exercise_with_no_prior_session_says_so(self):
        out = progression.find_set_comparisons(
            [self._set("Reverse Cable Fly", 8, 12, 7.0)], [])
        self.assertEqual(out[0]["verdict"], "no_history")
        self.assertIn("nothing to compare", progression.format_set_comparisons(out))

    def test_warmups_never_become_the_top_set(self):
        """A 30kg warm-up must not be compared against a 55kg working set."""
        out = progression.find_set_comparisons(
            [dict(self._set("Machine Bicep Curl", 30, 8, 5.0), is_warmup=True),
             self._set("Machine Bicep Curl", 55, 9, 8.0)],
            [self._ref("Machine Bicep Curl", 55.0, 9, 7.0)],
        )
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["load"], 55.0)
        self.assertEqual(out[0]["verdict"], "harder")

    def test_nothing_logged_yet_renders_a_plain_line(self):
        self.assertEqual(progression.format_set_comparisons([]),
                         "  Nothing logged yet today.")


class ReplayEndpointTests(unittest.TestCase):
    """The analysis and the database are not reachable from the same place.

    The Railway server talks to Supabase all day; the environment the replay was
    written in is refused at the egress proxy. Rather than move credentials to
    the code, the code runs where the credentials already are — which means a
    route, and a route means it has to be safe to expose.
    """

    def setUp(self):
        import webhook
        self.webhook = webhook
        webhook.app.config["TESTING"] = True
        self.client = webhook.app.test_client()
        from settings import get_settings
        self.fake = get_settings().__class__(app_api_token="secret-token")

    def _get(self, path):
        with patch.object(self.webhook, "get_settings", return_value=self.fake):
            return self.client.get(path)

    def test_no_token_is_rejected(self):
        self.assertEqual(self._get("/admin/replay").status_code, 401)

    def test_a_wrong_token_is_rejected(self):
        self.assertEqual(self._get("/admin/replay?token=nope").status_code, 401)

    def test_a_query_string_token_is_accepted_so_a_link_can_be_tapped(self):
        """A browser will not send an Authorization header. The trade is
        bounded by the route being read-only."""
        r = self._get("/admin/replay?token=secret-token")
        self.assertEqual(r.status_code, 200)
        self.assertIn("text/plain", r.mimetype)

    def test_a_header_token_still_works(self):
        with patch.object(self.webhook, "get_settings", return_value=self.fake):
            r = self.client.get("/admin/replay",
                                headers={"Authorization": "Bearer secret-token"})
        self.assertEqual(r.status_code, 200)

    def test_it_is_get_only_so_nothing_can_be_written_through_it(self):
        with patch.object(self.webhook, "get_settings", return_value=self.fake):
            self.assertEqual(self.client.post("/admin/replay?token=secret-token")
                             .status_code, 405)

    def test_a_failure_is_reported_as_text_rather_than_a_500(self):
        """It is a diagnostic. Why it failed is the thing worth reading, and a
        500 page says nothing."""
        r = self._get("/admin/replay?token=secret-token")
        self.assertEqual(r.status_code, 200)
        self.assertIn("Replay failed", r.get_data(as_text=True))

    def test_a_junk_days_parameter_does_not_raise(self):
        r = self._get("/admin/replay?token=secret-token&days=banana")
        self.assertEqual(r.status_code, 200)


class ReplayReportTests(unittest.TestCase):
    """build_report is pure — sessions in, text out — so the whole replay is
    testable without a database."""

    @staticmethod
    def _session(date, week=None, inferred=False, sets=()):
        row = {"id": date, "date": date, "type": "Pull", "sets": list(sets)}
        if week is not None:
            row["mesocycle_week"] = week
            if inferred:
                row["week_inferred"] = True
        return row

    @staticmethod
    def _set(exercise, weight, reps, rpe):
        return {"exercise": exercise, "is_warmup": False, "notes": None,
                "actual_weight_kg": weight, "actual_reps": reps, "actual_rpe": rpe}

    def test_one_session_cannot_be_replayed(self):
        from replay import build_report
        out = build_report([self._session("2026-08-28")])
        self.assertIn("at least two", out)

    def test_the_week_source_is_always_named(self):
        """A reconstruction must never be mistaken for a recorded fact."""
        from replay import build_report
        sets = [self._set("Cable Row", 80.0, 8, 8.0)]
        recorded = build_report([self._session("2026-08-24", week=3, sets=sets),
                                 self._session("2026-08-28", week=4, sets=sets)])
        guessed = build_report([self._session("2026-08-24", week=3, inferred=True, sets=sets),
                                self._session("2026-08-28", week=4, inferred=True, sets=sets)])
        self.assertIn("recorded", recorded)
        self.assertIn("reconstructed", guessed)

    def test_notes_are_surfaced_at_the_top(self):
        from replay import build_report
        out = build_report([], notes=["something worth knowing"])
        self.assertTrue(out.startswith("NOTE: something worth knowing"))

    def test_a_matching_session_reports_as_a_match(self):
        from replay import build_report
        prior = self._session("2026-08-24", week=3,
                              sets=[self._set("Cable Row", 80.0, 8, 8.0)])
        today = self._session("2026-08-28", week=1,
                              sets=[self._set("Cable Row", 80.0, 6, 8.0),
                                    self._set("Cable Row", 65.0, 11, 7.0)])
        out = build_report([prior, today])
        self.assertIn("Cable Row", out)
        self.assertIn("match", out)


def now_local_iso_today() -> str:
    """A session start-time of today, so the stale-session guard does not close
    it before the test gets to the thing it is actually testing."""
    from data import now_local
    return now_local().isoformat()


class ReplayCommandTests(unittest.TestCase):
    """`replay` had to become a chat command, not a URL.

    The report already existed behind GET /admin/replay, which needs the
    APP_API_TOKEN pasted into a browser. The athlete does not have that token to
    hand and has said plainly that running things himself is too complicated —
    so the report existed and was never once read, which makes it worth nothing.

    Both chat surfaces funnel into handle_incoming_message: the iOS app posts to
    /api/chat and Telegram posts to /webhook. Intercepting the command there
    reaches both with no token, no URL and no app release.
    """

    def _run(self, text, report="REPORT BODY", raises=None, send_reply=True):
        from unittest.mock import patch
        memory = {"mesocycle_day": 1, "mesocycle_week": 1}
        sent = []
        run_mock = patch(
            "replay.run_chat_replay",
            side_effect=raises if raises else None,
            return_value=None if raises else (report, "SUMMARY"),
        )
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="LLM WAS CALLED") as llm, \
             patch("coach.save_conversation_message") as save, \
             patch("coach.get_workout_state", return_value={}), \
             patch("coach.send_telegram_message", side_effect=lambda t: sent.append(t)), \
             run_mock as run:
            out = handle_incoming_message(text, memory, send_reply=send_reply)
        return out, llm, save, sent, run

    def test_the_report_comes_back_verbatim(self):
        """The whole point of computing it is that a model never retells it."""
        out, llm, _, _, _ = self._run("replay", report="Cable Row: match")
        self.assertEqual(out, "Cable Row: match")
        llm.assert_not_called()

    def test_the_command_works_with_a_slash_and_with_a_window(self):
        for text, expected_days in (("replay", 90), ("/replay", 90),
                                    ("replay 180", 180), ("/replay 30", 30)):
            with self.subTest(text=text):
                out, _, _, _, run = self._run(text, report="ok")
                self.assertEqual(out, "ok")
                run.assert_called_once_with(expected_days)

    def test_ordinary_chat_containing_the_word_is_not_hijacked(self):
        """"can you replay it" is a question for the coach, not a command."""
        for text in ("replay the session", "can you replay it", "replaying",
                     "what does replay mean"):
            with self.subTest(text=text):
                out, llm, _, _, run = self._run(text)
                run.assert_not_called()
                self.assertEqual(out, "LLM WAS CALLED")

    def test_the_summary_is_persisted_but_the_report_is_not(self):
        """Two costs pull in opposite directions and both are real.

        Today's conversation is replayed into the model's context on every later
        request, so persisting a few hundred lines of table would crowd out the
        actual session and be re-billed all day. But persisting NOTHING loses
        the report on a tab switch — the iOS app reloads its transcript from the
        conversations table whenever the chat reappears — and leaves a follow-up
        question reaching the model with no record that a replay ever ran, which
        is the exact confabulation the rest of this codebase prevents.
        """
        report = "X\n" * 400
        _, _, save, _, _ = self._run("replay", report=report)
        saved = [c.args for c in save.call_args_list]
        self.assertEqual(saved, [("user", "replay"), ("assistant", "SUMMARY")])
        self.assertNotIn(report, [a[1] for a in saved])

    def test_a_transcript_failure_does_not_cost_the_athlete_the_report(self):
        """The transcript is a convenience here; the report is the deliverable."""
        from unittest.mock import patch
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="LLM"), \
             patch("coach.get_workout_state", return_value={}), \
             patch("coach.send_telegram_message"), \
             patch("coach.save_conversation_message",
                   side_effect=RuntimeError("supabase down")), \
             patch("replay.run_chat_replay", return_value=("REPORT", "S")):
            out = handle_incoming_message("replay", {"mesocycle_day": 1})
        self.assertEqual(out, "REPORT")

    def test_a_failed_replay_reads_as_a_failed_replay(self):
        """It must never surface as a 500 in the app or as silence in Telegram."""
        out, _, _, sent, _ = self._run(
            "replay", raises=RuntimeError("No Supabase client configured.")
        )
        self.assertIn("Replay failed", out)
        self.assertIn("No Supabase client configured", out)
        self.assertIn("nothing about your training is affected", out)
        self.assertEqual(sent, [out])

    def test_the_report_is_held_back_during_a_live_session_on_the_app(self):
        """A read-only diagnostic must not be able to move the workout card.

        The in-workout composer feeds every /api/chat reply through
        applyAIResponse. This report contains no "*" markers, so
        PrescriptionParser.parse returns [] and control falls through to
        detectExerciseTransition — a bare substring scan over the whole reply
        (PrescriptionParser.swift:301). The report names every exercise in the
        day's plan, so it matches the first in plan order, jumps the card off
        the lift he is mid-way through, and permanently reorders what is next.
        """
        from unittest.mock import patch
        active = {"workout_mode": "active", "current_session_id": "s1",
                  "session_start_time": now_local_iso_today()}
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="LLM"), \
             patch("coach.get_workout_state", return_value=active), \
             patch("coach.save_conversation_message"), \
             patch("replay.run_chat_replay") as run:
            out = handle_incoming_message("replay", {"mesocycle_day": 1},
                                          send_reply=False)
        run.assert_not_called()
        self.assertIn("mid-session", out)
        from prescribe import PULL_DAY
        for name, _, _ in PULL_DAY:
            self.assertNotIn(name, out, "names a plan exercise, so it would "
                                        "still trip the transition detector")

    def test_telegram_still_gets_the_report_during_a_live_session(self):
        """Telegram drives no workout card, so the hazard does not apply."""
        from unittest.mock import patch
        active = {"workout_mode": "active", "current_session_id": "s1",
                  "session_start_time": now_local_iso_today()}
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="LLM"), \
             patch("coach.get_workout_state", return_value=active), \
             patch("coach.save_conversation_message"), \
             patch("coach.send_telegram_message"), \
             patch("replay.run_chat_replay", return_value=("REPORT", "S")):
            out = handle_incoming_message("replay", {"mesocycle_day": 1},
                                          send_reply=True)
        self.assertEqual(out, "REPORT")

    def test_a_stale_session_is_still_closed_when_the_command_runs(self):
        """The command returns early, so where it sits in the function matters.

        A session left workout_mode=active from a previous day has to be closed
        and the mesocycle advanced whatever today's first message happens to be
        — otherwise later sets pile onto the old session_id and the mesocycle
        never advances. Returning ahead of that guard would defer a correctness
        fix, not just skip some formatting.
        """
        from unittest.mock import patch
        memory = {"mesocycle_day": 1, "mesocycle_week": 1}
        stale = {"workout_mode": "active",
                 "current_session_id": "old-session",
                 "session_start_time": "2020-01-01T10:00:00"}
        with patch("coach.load_today_conversation", return_value=[]), \
             patch("coach.chat_with_coach", return_value="LLM"), \
             patch("coach.get_workout_state", return_value=stale), \
             patch("coach.send_telegram_message"), \
             patch("coach.end_session") as end, \
             patch("coach.advance_mesocycle") as advance, \
             patch("replay.run_chat_replay", return_value=("R", "S")):
            out = handle_incoming_message("replay", memory)
        self.assertEqual(out, "R")
        end.assert_called_once_with("old-session")
        advance.assert_called_once()

    def test_telegram_gets_the_report_and_ios_does_not_double_send(self):
        """send_reply=False is the iOS path — /api/chat returns the body itself."""
        _, _, _, sent_tg, _ = self._run("replay", report="R", send_reply=True)
        self.assertEqual(sent_tg, ["R"])
        _, _, _, sent_ios, _ = self._run("replay", report="R", send_reply=False)
        self.assertEqual(sent_ios, [])


def _ios_blocks(content: str) -> list:
    """Port of MarkdownText.blocks — Vaux/Vaux/Components/MarkdownText.swift:30.

    The iOS coach bubble renders through MarkdownText, not as plain text. Its
    block parser trims every line, then joins each run of consecutive non-blank
    lines with a SINGLE SPACE, flushing only on a blank line; "- " lines become
    bullets that each get their own row. Any report written for a terminal
    therefore arrives as run-on paragraphs. Testing the raw string cannot see
    that, so the tests below assert on what this produces.
    """
    import re as _re
    blocks, buf, bullets, numbered = [], [], [], []

    def flush_paragraph():
        if buf:
            text = " ".join(buf).strip()
            if text:
                blocks.append(("paragraph", text))
            buf.clear()

    def flush_bullets():
        if bullets:
            blocks.append(("bullet", list(bullets)))
            bullets.clear()

    def flush_numbered():
        if numbered:
            blocks.append(("numbered", list(numbered)))
            numbered.clear()

    for raw in content.split("\n"):
        line = raw.strip()
        if not line:
            flush_paragraph(); flush_bullets(); flush_numbered()
            continue
        if line[:2] in ("- ", "* ", "\u2022 "):
            flush_paragraph(); flush_numbered()
            bullets.append(line[2:].strip())
        elif _re.match(r"^\d+\.\s+", line):
            flush_paragraph(); flush_bullets()
            numbered.append(_re.sub(r"^\d+\.\s+", "", line))
        else:
            flush_bullets(); flush_numbered()
            buf.append(line)
    flush_paragraph(); flush_bullets(); flush_numbered()
    return blocks


class ChatReplayRenderingTests(unittest.TestCase):
    """The report was built for a browser and then pointed at a chat bubble.

    /admin/replay returns text/plain, so the wide renderer pads exercise names
    into a 22-char column and rules sections with 74 '=' characters — measured
    at up to 184 characters wide on real-shaped data. The first attempt at a fix
    hard-wrapped to 38 columns, which was worse than useless: MarkdownText joins
    consecutive lines with a space, so pre-wrapping only manufactured more
    fragments to run together, and "Cable Row code 2 sets you did 1 Hammer Curl
    code 3 sets you did 1" is not attributable to any lift.
    """

    def _sessions(self):
        def st(ex, w, r, rpe, n=1):
            return {"exercise": ex, "actual_weight_kg": w, "actual_reps": r,
                    "actual_rpe": rpe, "set_number": n, "is_warmup": False}
        prior = {"date": "2026-08-10", "mesocycle_week": 3,
                 "sets": [st("Cable Row", 80, 8, 8), st("Cable Row", 65, 12, 7, 2),
                          st("Hammer Curl", 16, 11, 8)]}
        today = {"date": "2026-08-28", "mesocycle_week": 1,
                 "sets": [st("Cable Row", 82.5, 6, 8), st("Hammer Curl", 17, 10, 8)]}
        return [prior, today]

    def _chat(self, sessions=None, notes=None):
        from replay import analyse, render_chat
        return render_chat(analyse(sessions or self._sessions(), notes=notes))

    def _rendered(self, sessions=None):
        return _ios_blocks(self._chat(sessions))

    def test_each_disagreement_survives_as_its_own_row(self):
        """The failure this guards: every exercise run together in one blob."""
        bullets = [b for kind, b in self._rendered() if kind == "bullet"]
        flat = [item for group in bullets for item in group]
        rows = [i for i in flat if "code says" in i]
        self.assertEqual(len(rows), 2)
        self.assertTrue(any(i.startswith("Cable Row") for i in rows))
        self.assertTrue(any(i.startswith("Hammer Curl") for i in rows))
        for row in rows:
            self.assertEqual(row.count("code says"), 1,
                             f"two exercises ran together: {row!r}")

    def test_the_verdict_counts_do_not_run_together(self):
        """"agreed 0 disagreed 2 not logged 5" as one line is unreadable."""
        flat = [i for kind, b in self._rendered() if kind == "bullet" for i in b]
        for label in ("agreed", "disagreed", "not logged"):
            self.assertTrue(any(i.startswith(label) for i in flat),
                            f"{label} is not its own row")

    def test_no_paragraph_becomes_a_wall_of_numbers(self):
        """A paragraph carrying several exercises' numbers is the bug."""
        for kind, val in self._rendered():
            if kind != "paragraph":
                continue
            self.assertLess(val.count("code says"), 2, f"run-on: {val[:120]!r}")

    def test_the_verdict_comes_before_the_detail(self):
        out = self._chat()
        self.assertIn("VERDICT", out)
        detail = [i for i in (out.find("WHERE IT DISAGREED"),
                              out.find("COULDN'T DECIDE")) if i != -1]
        self.assertTrue(detail)
        self.assertLess(out.find("VERDICT"), min(detail))

    def test_no_source_line_references_reach_the_athlete(self):
        """A narrow version of this test passed while fifteen citations shipped.

        It rendered one fixture, which exercised one branch — the no-history
        path — so it saw ":350" and nothing else. The first real replay came
        back carrying ":70", ":182", ":183", ":186", ":203" and ":205" from the
        branches the fixture never reached. The fix was to strip at a single
        choke point instead of editing the strings a test happened to cover;
        this sweeps every week against every shape of history to prove it.
        """
        import re as _re
        from prescribe import PULL_DAY, PriorSet, prescribe_pull
        histories = [
            {},
            {"load": 80.0, "reps": 5, "rpe": 7.0, "week": 3},    # below range
            {"load": 80.0, "reps": 14, "rpe": 9.0, "week": 4},   # above range
            {"load": 80.0, "reps": 9, "rpe": 8.0, "week": 3},    # in range
            {"load": None, "reps": None, "rpe": None, "week": None},
        ]
        leaked = set()
        for week in (1, 2, 3, 4):
            for spec in histories:
                hist = {} if not spec else {
                    "".join(c for c in name.lower() if c.isalnum()):
                        PriorSet(date="2026-08-01", **spec)
                    for name, _, _ in PULL_DAY
                }
                for proposal in prescribe_pull(week, hist):
                    for line in list(proposal.reasons) + list(proposal.deferred):
                        leaked |= set(_re.findall(r"(?<![\w:]):\d{2,4}\b", line))
        self.assertEqual(leaked, set(), f"citations reaching the athlete: {leaked}")

    def test_real_numbers_survive_the_citation_strip(self):
        from prescribe import strip_citations
        self.assertEqual(strip_citations("Hold 8-12 reps at RPE 8.5, drop 20%"),
                         "Hold 8-12 reps at RPE 8.5, drop 20%")
        self.assertEqual(strip_citations("Volume before intensity (:182). Go."),
                         "Volume before intensity. Go.")
        self.assertEqual(
            strip_citations("cannot drop 20% (:64 applied to added weight)."),
            "cannot drop 20% (applied to added weight).")

    def test_no_underscored_identifier_reaches_the_bubble(self):
        """The iOS bubble parses inline markdown, so "_" is read as emphasis and
        consumed: "workout_sessions" arrived as "workoutsessions" and
        "001_workout_session_mesocycle.sql" as "001workoutsessionmesocycle.sql".
        """
        import re as _re
        from replay import analyse, render_chat
        note = ("Your sessions do not record which mesocycle week they "
                "belonged to")
        out = render_chat(analyse(self._sessions(), notes=[note]))
        self.assertNotRegex(out, r"\w+_\w+")

    def test_a_spelling_variant_is_not_reported_as_a_missed_exercise(self):
        """The two logging paths do not agree on spelling — the iOS app resolves
        through the exercises library, Telegram through find_exercise. Matching
        raw strings turned "Pull Ups" into an exercise that never happened,
        which is the difference between "you skipped this" and "this is filed
        under another name"."""
        from replay import analyse
        def st(ex, w, r, rpe, n=1):
            return {"exercise": ex, "actual_weight_kg": w, "actual_reps": r,
                    "actual_rpe": rpe, "set_number": n, "is_warmup": False}
        prior = {"date": "2026-08-10", "mesocycle_week": 3,
                 "sets": [st("pull ups", 15, 8, 8), st("Pull-Ups", 15, 7, 8, 2)]}
        today = {"date": "2026-08-28", "mesocycle_week": 1,
                 "sets": [st("PULLUPS", 17, 8, 8), st("Pull Ups", 17, 7, 8, 2)]}
        outcomes = {o.exercise: o for o in analyse([prior, today]).sessions[0].outcomes}
        self.assertEqual(outcomes["Pull-Ups"].verdict, "match")
        self.assertEqual(outcomes["Pull-Ups"].logged, 2)

    def test_the_reconstruction_note_survives_the_migration(self):
        """The note was tied to the QUERY failing, not to the data.

        Once the columns exist the query stops failing and the note stops
        printing — but sessions logged before that keep a NULL week and are
        still reconstructed. The labels would have read "(reconstructed)" with
        nothing left on the page explaining why, which is worse than the state
        it replaced.
        """
        from unittest.mock import MagicMock, patch
        import replay as replay_mod

        sessions = [{"id": f"s{i}", "date": f"2026-08-{10 + i:02d}",
                     "type": "Pull", "mesocycle_week": None,
                     "mesocycle_day": None} for i in range(3)]

        client = MagicMock()
        def table(name):
            t = MagicMock()
            chain = t.select.return_value
            for attr in ("gte", "order", "in_"):
                setattr(chain, attr, MagicMock(return_value=chain))
            chain.execute.return_value = MagicMock(
                data=sessions if name == "workout_sessions" else [])
            return t
        client.table.side_effect = table

        with patch.object(replay_mod, "get_supabase", return_value=client), \
             patch.object(replay_mod, "_load_mesocycle_state", return_value=(1, 1)), \
             patch.object(replay_mod, "infer_session_weeks",
                          return_value=[3, 4, 1]):
            _, notes = replay_mod.fetch_pull_sessions(90)

        self.assertTrue(notes, "no note left to explain the labels")
        joined = " ".join(notes)
        self.assertIn("3 of these 3 sessions", joined)
        self.assertIn("reconstructed", joined)
        self.assertNotRegex(joined, r"\w+_\w+")

    def test_the_report_cannot_be_mistaken_for_a_prescription(self):
        """The app treats a reply that parses as a prescription very
        differently, and this report must never be one.

        Two things key off it. CoachReply.parse renders a parsed plan as ledger
        rows in a CoachPlanCard instead of as text, and applyAIResponse re-points
        the live workout card when NOTHING parses but the prose names a known
        exercise. This report names every exercise in the plan, so it sits
        deliberately on one side of that line: no "*" markers, so
        PrescriptionParser.parse returns nothing and the whole report renders as
        text. The mid-session guard in coach.py covers the second hazard; this
        covers the first, and pins the property the guard assumes.
        """
        import re as _re
        out = self._chat()
        self.assertEqual(out.count("*"), 0, "an asterisk makes this a plan card")
        name_pattern = _re.compile(r"^[ \t]*\*{1,2}[^*\n]+\*{1,2}")
        loose_sets = _re.compile(r"^\d+\s*(sets?|x)\b", _re.I)
        for line in out.split("\n"):
            self.assertIsNone(name_pattern.search(line), f"exercise-block line: {line!r}")
            self.assertIsNone(loose_sets.search(line.strip()), f"set line: {line!r}")

    def test_log_names_the_template_does_not_know_are_reported(self):
        """A large "not logged" count means one of two very different things,
        and only this distinguishes them."""
        from replay import analyse, render_chat
        def st(ex, w, r, rpe, n=1):
            return {"exercise": ex, "actual_weight_kg": w, "actual_reps": r,
                    "actual_rpe": rpe, "set_number": n, "is_warmup": False}
        prior = {"date": "2026-08-10", "mesocycle_week": 3,
                 "sets": [st("Cable Row", 80, 8, 8)]}
        today = {"date": "2026-08-28", "mesocycle_week": 1,
                 "sets": [st("Cable Row", 82.5, 6, 8), st("Face Pull", 20, 15, 7)]}
        replay = analyse([prior, today])
        self.assertEqual(replay.unmatched, {"Face Pull": 1})
        out = render_chat(replay)
        self.assertIn("Face Pull", out)
        self.assertIn("naming mismatch", out)

    def test_identical_deferred_notes_are_grouped_not_repeated(self):
        """Five exercises with no history produced the same sentence five
        times, which is what made the raw report unreadable."""
        out = self._chat()
        self.assertEqual(out.count("no opening load"), 2,
                         "one group per distinct note, not one per exercise")

    def test_an_empty_history_explains_itself_in_plain_language(self):
        from replay import Replay, render_chat
        out = render_chat(Replay(sessions=[], totals={}, notes=[], span=None))
        self.assertIn("at least two", out)
        self.assertNotIn("Traceback", out)

    def test_one_session_is_not_reported_as_sessions(self):
        self.assertIn("1 Pull session ", self._chat())

    def test_the_summary_is_addressed_to_the_athlete_not_the_model(self):
        """It is stored as an ordinary assistant row, and MessageBubble renders
        every assistant row as a coach bubble. So an instruction written at the
        model is read by HIM — the coach discussing him in the third person and
        issuing itself orders. What the model needs to know about this row lives
        in the system prompt instead."""
        from replay import analyse, render_summary
        summary = render_summary(analyse(self._sessions()), 90)
        self.assertIn("2 disagreed", summary)
        self.assertIn("Cable Row", summary)
        self.assertLess(len(summary), 500, "this is persisted on every request")
        import re as _re
        for third_person in (r"the athlete", r"\bdo not\b", r"\bhe\b",
                             r"\bhis\b", r"\bhim\b"):
            self.assertIsNone(_re.search(third_person, summary, _re.I),
                              f"written at the model, not to him: {summary!r}")

    def test_the_summary_is_not_reported_as_sessions_when_there_is_one(self):
        from replay import analyse, render_summary
        self.assertIn("1 Pull session:", render_summary(analyse(self._sessions()), 90))

    def test_the_prompt_tells_the_coach_the_summary_is_only_totals(self):
        """The instruction had to move somewhere, or the coach answers a
        follow-up from detail it was never given."""
        prompt = load_system_prompt()
        self.assertIn("NOTHING about individual sets", prompt)
        self.assertIn("ask him to paste that section", prompt)

    def _missing_case(self):
        """T-Bar Row has history and is simply not logged on the later day."""
        def st(ex, w, r, rpe, n=1):
            return {"exercise": ex, "actual_weight_kg": w, "actual_reps": r,
                    "actual_rpe": rpe, "set_number": n, "is_warmup": False}
        prior = {"date": "2026-08-10", "mesocycle_week": 3,
                 "sets": [st("Cable Row", 80, 8, 8), st("Cable Row", 65, 12, 7, 2),
                          st("T-Bar Row", 60, 8, 8), st("T-Bar Row", 50, 12, 7, 2)]}
        today = {"date": "2026-08-28", "mesocycle_week": 1,
                 "sets": [st("Cable Row", 82.5, 6, 8), st("Cable Row", 66, 11, 7, 2)]}
        return [prior, today]

    def test_the_not_logged_count_names_its_exercises(self):
        """"not logged 6" alone is an accusation with no subject.

        The deferred notes only pick up exercises with NO history at all, so an
        exercise that has history and simply was not logged that day was counted
        in the total and named nowhere in the report.
        """
        out = self._chat(self._missing_case())
        self.assertIn("T-Bar Row", out)
        self.assertIn("WHAT THE PROGRAMME EXPECTED AND DIDN'T FIND", out)
        self.assertIn("the log cannot tell them apart", out,
                      "a swap and a missed set must not be reported as the same")

    def test_nothing_disagreed_is_not_claimed_over_an_unexplained_count(self):
        out = self._chat(self._missing_case())
        self.assertNotIn("Every exercise ran the set count", out)
        self.assertIn("Nothing that you logged disagreed", out)

    def test_both_surfaces_agree_on_what_happened(self):
        """The wide and chat renderers go through one analyse() precisely so
        they can never disagree about the numbers."""
        from replay import analyse, build_report
        sessions = self._sessions()
        replay = analyse(sessions)
        wide = build_report(sessions)
        chat = self._chat(sessions)
        for key, label in (("match", "agreed"), ("diverge", "disagreed"),
                           ("missing", "not logged")):
            self.assertIn(f"- {label} {replay.totals[key]}", chat)
            self.assertIn(f"{key.replace('missing', 'not logged')} "
                          f"{replay.totals[key]}", wide)
