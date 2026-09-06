"""This block's weak points: bands from the prompt, the block's start, the
pick by shortfall, the stored decision, and the plan's slot check."""

import json
import unittest
from unittest.mock import patch

import weakpoints
from weakpoints import (block_start, format_block_weak_points, parse_volume_bands,
                        previous_block_range, rank_by_shortfall)


def _prompt():
    with open("system_prompt.txt") as handle:
        return handle.read()


class BandTests(unittest.TestCase):
    def test_the_bands_are_read_from_the_prompt(self):
        bands = parse_volume_bands(_prompt())
        self.assertEqual(bands["Hamstrings"], (10, 16))
        self.assertEqual(bands["Calves"], (6, 10))
        self.assertEqual(bands["Rear Delts"], (8, 14))
        self.assertEqual(bands["Triceps"], (8, 12))
        self.assertEqual(bands["Abs"], (10, 16))
        self.assertEqual(len(bands), 10)

    def test_no_sentence_means_no_bands(self):
        self.assertEqual(parse_volume_bands("nothing here 10-16."), {})


class PickTests(unittest.TestCase):
    BANDS = {"Chest": (10, 16), "Hamstrings": (10, 16), "Calves": (6, 10), "Triceps": (8, 12), "Abs": (10, 16)}

    def test_the_pick_is_by_shortfall_against_the_band_not_absolute_sets(self):
        volume = {"Chest": 12.0, "Hamstrings": 7.2, "Calves": 7.5, "Triceps": 9.1, "Abs": 18}
        ranking = rank_by_shortfall(volume, self.BANDS)
        self.assertEqual([r["muscle"] for r in ranking[:2]], ["Hamstrings", "Triceps"],
                         "calves at 7.5 are inside 6-10; triceps at 9.1 have less headroom than chest")
        self.assertEqual(ranking[0]["shortfall"], 2.8)
        self.assertNotIn("Abs", [r["muscle"] for r in ranking])

    def test_a_muscle_with_no_sets_is_the_biggest_shortfall(self):
        ranking = rank_by_shortfall({"Chest": 12.0}, self.BANDS)
        self.assertEqual(ranking[0]["muscle"], "Hamstrings")
        self.assertEqual(ranking[0]["sets"], 0.0)


class BlockStartTests(unittest.TestCase):
    SESSIONS = [{"date": f"2026-08-{d:02d}", "type": t, "mesocycle_week": None, "mesocycle_day": None}
                for d, t in zip(range(1, 21), ["Pull", "Push", "Legs", "Cardio+Abs"] * 5)]

    def test_the_block_began_the_number_of_done_slots_back(self):
        # next session is week 2 day 2: 5 slots done, so the block began 5 sessions ago
        self.assertEqual(block_start(self.SESSIONS, 2, 2, "2026-08-21"), "2026-08-16")

    def test_a_block_about_to_begin_starts_today(self):
        self.assertEqual(block_start(self.SESSIONS, 1, 1, "2026-08-21"), "2026-08-21")

    def test_a_stamp_wins_over_the_count(self):
        sessions = [dict(s) for s in self.SESSIONS]
        sessions[8]["mesocycle_week"], sessions[8]["mesocycle_day"] = 1, 1   # 2026-08-09
        self.assertEqual(block_start(sessions, 2, 2, "2026-08-21"), "2026-08-09")

    def test_the_previous_block_is_the_sixteen_sessions_before_the_start(self):
        since, until = previous_block_range(self.SESSIONS, "2026-08-17")
        self.assertEqual((since, until), ("2026-08-01", "2026-08-16"))
        self.assertIsNone(previous_block_range(self.SESSIONS, "2026-08-01"))


class _FakeQuery:
    def __init__(self, rows, sink=None):
        self._rows, self._sink = rows, sink
        self._filters = []

    def __getattr__(self, name):
        if name in ("select", "gte", "lte", "order", "like", "eq"):
            def method(*args, **kwargs):
                if name in ("eq", "like"):
                    self._filters.append((name, args))
                return self
            return method
        raise AttributeError(name)

    def insert(self, rows):
        self._sink.extend(rows)
        return self

    def execute(self):
        rows = self._rows
        for kind, args in self._filters:
            field, value = args
            if kind == "eq":
                rows = [r for r in rows if r.get(field) == value]
            if kind == "like":
                rows = [r for r in rows if str(r.get(field, "")).startswith(value.rstrip("%"))]
        return type("R", (), {"data": rows})()


class _FakeSupabase:
    def __init__(self, sessions, sets, decisions=None):
        self.sessions, self.sets = sessions, sets
        self.decisions = decisions or []
        self.written = []

    def table(self, name):
        if name == "workout_sessions":
            return _FakeQuery(self.sessions)
        if name == "workout_sets":
            return _FakeQuery(self.sets)
        return _FakeQuery(self.decisions, sink=self.written)


class EndToEndTests(unittest.TestCase):
    def _sessions(self):
        types = ["Pull", "Push", "Legs", "Cardio+Abs"] * 6
        return [{"id": i, "date": f"2026-08-{i + 1:02d}", "type": t, "status": "completed",
                 "mesocycle_week": None, "mesocycle_day": None} for i, t in enumerate(types)]

    def _sets(self):
        # previous block (Aug 5 - Aug 20): chest well fed, hamstrings starved, calves inside band
        sets = []
        for d in range(5, 21):
            sets += [{"exercise": "Machine Chest Press", "is_warmup": False, "notes": "", "date": f"2026-08-{d:02d}"}] * 2
            if d % 4 == 0:
                sets += [{"exercise": "Seated Leg Curl", "is_warmup": False, "notes": "", "date": f"2026-08-{d:02d}"}] * 3
                sets += [{"exercise": "Machine Calf Raise", "is_warmup": False, "notes": "", "date": f"2026-08-{d:02d}"}] * 6
        return sets

    def test_the_pick_is_computed_once_and_stored_with_its_reason(self):
        fake = _FakeSupabase(self._sessions(), self._sets())
        # next session: week 2 day 1 -> 4 slots done -> block began Aug 21
        memory = {"mesocycle_week": 2, "mesocycle_day": 1}
        with patch.object(weakpoints, "get_supabase", return_value=fake), \
             patch.object(weakpoints, "now_local", return_value=__import__("datetime").datetime(2026, 8, 25)):
            info = weakpoints.current_block_weak_points(memory, _prompt())
        self.assertEqual(info["block_start"], "2026-08-21")
        self.assertEqual((info["since"], info["until"]), ("2026-08-05", "2026-08-20"))
        self.assertEqual(info["source"], "computed")
        picked = [p["muscle"] for p in info["picks"]]
        self.assertNotIn("Calves", picked, "calves are inside their band")
        self.assertNotIn("Chest", picked)
        self.assertEqual(len(fake.written), 2)
        self.assertTrue(fake.written[0]["exercise"].startswith("Weak-point: "))
        self.assertIn("previous block (2026-08-05 to 2026-08-20)", fake.written[0]["reason"])

    def test_a_stored_pick_is_read_back_not_recomputed(self):
        stored = [{"date": "2026-08-21", "exercise": "Weak-point: Hamstrings", "reason": "Block pick: ...",
                   "plan": json.dumps({"sets": 3.0, "low": 10, "high": 16, "shortfall": 7.0,
                                       "since": "2026-08-05", "until": "2026-08-20"})},
                  {"date": "2026-08-21", "exercise": "Weak-point: Rear Delts", "reason": "Block pick: ...",
                   "plan": json.dumps({"sets": 4.0, "low": 8, "high": 14, "shortfall": 4.0,
                                       "since": "2026-08-05", "until": "2026-08-20"})}]
        fake = _FakeSupabase(self._sessions(), [], decisions=stored)
        with patch.object(weakpoints, "get_supabase", return_value=fake), \
             patch.object(weakpoints, "now_local", return_value=__import__("datetime").datetime(2026, 8, 25)):
            info = weakpoints.current_block_weak_points({"mesocycle_week": 2, "mesocycle_day": 1}, _prompt())
        self.assertEqual(info["source"], "stored")
        self.assertEqual([p["muscle"] for p in info["picks"]], ["Hamstrings", "Rear Delts"])
        self.assertEqual(fake.written, [])
        text = format_block_weak_points(info)
        self.assertIn("Hamstrings: 3 sets/week against 10-16 — short by 7", text)
        self.assertIn("held for every Cardio+Abs day this block", text)

    def test_no_history_means_the_coach_is_told_so(self):
        self.assertIn("unavailable", format_block_weak_points(None))


class PlanSlotTests(unittest.TestCase):
    def test_a_slot_fill_outside_the_blocks_pick_needs_an_adjust(self):
        from plan import parse_plan, validate
        from tests.test_plan_contract import CardioAbsTests
        raw = CardioAbsTests._plan()     # fills with Overhead Cable Extension (triceps) and Machine Calf Raise
        plan = parse_plan(json.dumps(raw))
        problems = validate(plan, "Cardio+Abs", _prompt(), weak_points=["Hamstrings", "Triceps"])
        self.assertTrue(any("Machine Calf Raise: serves Calves" in p for p in problems))
        self.assertFalse(any("Overhead Cable Extension" in p for p in problems))
        raw["exercises"][5]["decision"] = "adjust"
        raw["exercises"][5]["reason"] = "Hamstrings are off the table today: the leg curl is out of order."
        self.assertEqual(validate(parse_plan(json.dumps(raw)), "Cardio+Abs", _prompt(),
                                  weak_points=["Hamstrings", "Triceps"]), [])


if __name__ == "__main__":
    unittest.main()
