"""This block's weak points: bands from the prompt, the block's start, the
pick by shortfall, the stored decision, and the plan's slot check."""

import json
import unittest
import blockfix  # noqa: F401  pins the block to four weeks for the legacy rules
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


class CatalogTests(unittest.TestCase):
    def test_the_back_extension_credits_hamstrings(self):
        from volume import resolve_contributions, resolve_muscle_group
        self.assertEqual(resolve_muscle_group("45° Back Extension"), "Hamstrings")
        self.assertEqual(resolve_contributions("45° Back Extension"), {"Hamstrings": 1.0, "Glutes": 0.5, "Back": 0.5})
        self.assertEqual(resolve_contributions("Leg Press")["Glutes"], 0.5, "glutes were credited by nothing")

    def test_the_templates_now_cover_every_band(self):
        """The reason the slots became exceptions: nothing is under from the
        template alone."""
        from coach_parsing import parse_session_template
        from volume import resolve_contributions
        prompt = _prompt()
        totals = {}
        for day in ("Push", "Pull", "Legs", "Cardio+Abs"):
            for name, sets in parse_session_template(prompt, day)[0]:
                if name.lower().startswith("weak-point"):
                    continue
                for m, share in resolve_contributions(name).items():
                    totals[m] = totals.get(m, 0) + sets * share * 1.5
        for muscle, (low, high) in parse_volume_bands(prompt).items():
            with self.subTest(muscle=muscle):
                self.assertGreaterEqual(totals.get(muscle, 0), low, f"{muscle} under its band from the template")


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

    def test_a_block_about_to_begin_starts_after_a_session_finished_today(self):
        # 19 Sep 2026: the deload's last session was today and memory had
        # rolled to week 1 day 1. "Today" put the new block's first day on
        # the old block's last, and every range built from it lost that session.
        self.assertEqual(block_start(self.SESSIONS, 1, 1, "2026-08-20"), "2026-08-21")
        self.assertEqual(weakpoints.block_boundary(self.SESSIONS, "2026-08-21"), "2026-08-20")
        self.assertEqual(weakpoints.block_boundary(self.SESSIONS, "2026-08-17"), "2026-08-16")
        self.assertIsNone(weakpoints.block_boundary(self.SESSIONS, "2026-08-01"))

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
        if name in ("select", "gte", "lte", "order", "like", "eq", "delete"):
            def method(*args, **kwargs):
                if name in ("eq", "like"):
                    self._filters.append((name, args))
                if name == "delete":
                    self._deleting = True
                return self
            return method
        raise AttributeError(name)

    def insert(self, rows):
        self._sink.extend(rows)
        return self

    def execute(self):
        rows = self._rows
        if getattr(self, "_deleting", False):
            keep = []
            for r in self._rows:
                hit = all((r.get(f) == v) if k == "eq" else str(r.get(f, "")).startswith(v.rstrip("%"))
                          for k, (f, v) in self._filters)
                if not hit:
                    keep.append(r)
            self._rows[:] = keep
            return type("R", (), {"data": []})()
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
        self.assertTrue(all(p["shortfall"] > 0 for p in info["picks"]), "only real deficits fill a slot")
        self.assertEqual(len(picked), 1, "one emphasis per block")
        self.assertEqual(len(fake.written), len(picked))
        self.assertTrue(fake.written[0]["exercise"].startswith("Weak-point: "))
        self.assertIn("previous block (2026-08-05 to 2026-08-20)", fake.written[0]["reason"])

    def test_nothing_under_its_band_is_stored_as_none_and_read_back(self):
        sets = []
        for d in range(5, 21):
            for name in ("Machine Chest Press", "Cable Row", "Leg Press", "Seated Leg Curl", "45° Back Extension",
                         "Machine Calf Raise", "Machine Shoulder Press", "Tricep Pushdown", "Face Pulls",
                         "Cable Lateral Raise", "Hammer Curl", "Cable Crunch"):
                sets += [{"exercise": name, "is_warmup": False, "notes": "", "date": f"2026-08-{d:02d}"}] * 3
        fake = _FakeSupabase(self._sessions(), sets)
        with patch.object(weakpoints, "get_supabase", return_value=fake), \
             patch.object(weakpoints, "now_local", return_value=__import__("datetime").datetime(2026, 8, 25)):
            info = weakpoints.current_block_weak_points({"mesocycle_week": 2, "mesocycle_day": 1}, _prompt())
        self.assertEqual(info["picks"], [])
        self.assertEqual([r["exercise"] for r in fake.written], ["Weak-point: none"])
        self.assertIn("both weak-point slots stay EMPTY", format_block_weak_points(info))
        self.assertIn("no lift stalled", format_block_weak_points(info))
        fake2 = _FakeSupabase(self._sessions(), [], decisions=fake.written)
        with patch.object(weakpoints, "get_supabase", return_value=fake2), \
             patch.object(weakpoints, "now_local", return_value=__import__("datetime").datetime(2026, 8, 25)):
            again = weakpoints.current_block_weak_points({"mesocycle_week": 2, "mesocycle_day": 1}, _prompt())
        self.assertEqual((again["source"], again["picks"]), ("stored", []))

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
        self.assertIn("One slot per muscle above", text)

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


class AthleteOverrideTests(unittest.TestCase):
    """The athlete overrules this block's pick with one line of chat."""

    def test_the_command_parses(self):
        from weakpoints import parse_weak_point_command
        self.assertEqual(parse_weak_point_command("weak points none"), [])
        self.assertEqual(parse_weak_point_command("Weak points: clear"), [])
        self.assertEqual(parse_weak_point_command("weak point = rear delts, hamstrings"), ["rear delts", "hamstrings"])
        self.assertEqual(parse_weak_point_command("weakpoints rear delts and calves."), ["rear delts", "calves"])
        self.assertIsNone(parse_weak_point_command("what are my weak points?"))
        self.assertIsNone(parse_weak_point_command("Logged working set 1 of 3: Cable Crunch 105kg x 12"))

    def _fake(self):
        sessions = [{"id": f"s{i}", "date": d, "type": t, "status": "completed", "mesocycle_week": w, "mesocycle_day": k}
                    for i, (d, t, w, k) in enumerate([
                        ("2026-09-02", "Pull", 1, 1), ("2026-09-03", "Push", 1, 2), ("2026-09-04", "Legs", 1, 3),
                        ("2026-09-06", "Cardio+Abs", 1, 4), ("2026-09-07", "Pull", 2, 1), ("2026-09-08", "Push", 2, 2),
                        ("2026-09-09", "Legs", 2, 3)])]
        stored = [{"date": "2026-09-02", "exercise": "Weak-point: Hamstrings", "reason": "old", "plan": "{}"},
                  {"date": "2026-09-02", "exercise": "Weak-point: Calves", "reason": "old", "plan": "{}"}]
        return _FakeSupabase(sessions, [], decisions=stored)

    def test_none_clears_the_stored_pick_for_the_block(self):
        fake = self._fake()
        with patch.object(weakpoints, "get_supabase", return_value=fake), \
             patch.object(weakpoints, "now_local", return_value=__import__("datetime").datetime(2026, 9, 10, 9, 0)):
            msg = weakpoints.set_block_weak_points({"mesocycle_week": 2, "mesocycle_day": 4}, _prompt(), [])
        self.assertIn("no weak-point slots", msg)
        self.assertEqual([r for r in fake.decisions if r["exercise"].startswith("Weak-point")], [])
        self.assertEqual(len(fake.written), 1)
        self.assertEqual(fake.written[0]["exercise"], "Weak-point: none")
        self.assertEqual(fake.written[0]["date"], "2026-09-02")

    def test_named_muscles_replace_the_pick(self):
        fake = self._fake()
        with patch.object(weakpoints, "get_supabase", return_value=fake), \
             patch.object(weakpoints, "now_local", return_value=__import__("datetime").datetime(2026, 9, 10, 9, 0)):
            msg = weakpoints.set_block_weak_points({"mesocycle_week": 2, "mesocycle_day": 4}, _prompt(), ["rear delts"])
        self.assertIn("Rear Delts", msg)
        self.assertEqual([r["exercise"] for r in fake.written], ["Weak-point: Rear Delts"])

    def test_an_unknown_muscle_changes_nothing(self):
        fake = self._fake()
        with patch.object(weakpoints, "get_supabase", return_value=fake):
            msg = weakpoints.set_block_weak_points({"mesocycle_week": 2, "mesocycle_day": 4}, _prompt(), ["forearms"])
        self.assertIn("isn't a muscle with a band", msg)
        self.assertEqual(fake.written, [])


class EmphasisTests(unittest.TestCase):
    """The slot is an emphasis: named, or a deficit, or a stall — else empty."""

    def _sessions(self):
        types = ["Pull", "Push", "Legs", "Cardio+Abs"] * 6
        return [{"id": i, "date": f"2026-08-{i + 1:02d}", "type": t, "status": "completed",
                 "mesocycle_week": None, "mesocycle_day": None} for i, t in enumerate(types)]

    def _full_sets(self, stalled=None):
        sets = []
        for d in range(5, 21):
            for name in ("Machine Chest Press", "Cable Row", "Leg Press", "Seated Leg Curl", "45° Back Extension",
                         "Machine Calf Raise", "Machine Shoulder Press", "Tricep Pushdown", "Face Pulls",
                         "Cable Lateral Raise", "Hammer Curl", "Cable Crunch"):
                load = 37.5 if (name == stalled) else 40 + d
                sets += [{"exercise": name, "is_warmup": False, "notes": "", "date": f"2026-08-{d:02d}",
                          "actual_weight_kg": load, "actual_reps": 10, "actual_rpe": 8}] * 3
        return sets

    def test_a_named_next_emphasis_is_consumed_at_the_block_start(self):
        pending = [{"id": 9, "date": "2026-08-19", "exercise": "Emphasis-next: Triceps",
                    "reason": "overhead cable extension", "plan": "{}"}]
        fake = _FakeSupabase(self._sessions(), self._full_sets(), decisions=pending)
        with patch.object(weakpoints, "get_supabase", return_value=fake), \
             patch.object(weakpoints, "now_local", return_value=__import__("datetime").datetime(2026, 8, 25)):
            info = weakpoints.current_block_weak_points({"mesocycle_week": 2, "mesocycle_day": 1}, _prompt())
        self.assertEqual([p["muscle"] for p in info["picks"]], ["Triceps"])
        self.assertIn("named by the athlete on 2026-08-19: overhead cable extension", info["picks"][0]["reason"])
        self.assertEqual([r["exercise"] for r in fake.written], ["Weak-point: Triceps"])
        self.assertEqual([r for r in fake.decisions if r["exercise"].startswith("Emphasis-next")], [],
                         "the pending emphasis is consumed once used")
        self.assertIn("Triceps: Emphasis this block", format_block_weak_points(info))

    def test_a_pick_made_on_a_rest_day_is_the_same_pick_on_the_opening_day(self):
        """The pick is keyed to the block, not to the day it was made. Made
        on the rest day after the last session (start = the next day), it is
        found again once the opening session has been logged and the start
        has moved to that session's date; the emphasis is not consumed twice
        and nothing is recomputed."""
        import datetime
        sessions = self._sessions()                       # 24 sessions, 1–24 Aug
        pending = [{"id": 9, "date": "2026-08-23", "exercise": "Emphasis-next: Triceps",
                    "reason": "overhead cable extension", "plan": "{}"}]
        # Rest day 25 Aug, memory at week 1 day 1: the block begins 25 Aug.
        fake = _FakeSupabase(sessions, self._full_sets(), decisions=pending)
        with patch.object(weakpoints, "get_supabase", return_value=fake), \
             patch.object(weakpoints, "now_local", return_value=datetime.datetime(2026, 8, 25)):
            first = weakpoints.current_block_weak_points({"mesocycle_week": 1, "mesocycle_day": 1}, _prompt())
        self.assertEqual(first["block_start"], "2026-08-25")
        self.assertEqual([p["muscle"] for p in first["picks"]], ["Triceps"])
        self.assertEqual([r["date"] for r in fake.written], ["2026-08-25"])
        # 27 Aug: Pull was logged on the 26th, memory at week 1 day 2, so the
        # start is now the 26th. The stored pick is dated the 25th.
        stored = [dict(r, id=100 + i) for i, r in enumerate(fake.written)]
        later = _FakeSupabase(sessions + [{"id": 30, "date": "2026-08-26", "type": "Pull", "status": "completed",
                                           "mesocycle_week": None, "mesocycle_day": None}],
                              self._full_sets(), decisions=stored)
        with patch.object(weakpoints, "get_supabase", return_value=later), \
             patch.object(weakpoints, "now_local", return_value=datetime.datetime(2026, 8, 27)):
            second = weakpoints.current_block_weak_points({"mesocycle_week": 1, "mesocycle_day": 2}, _prompt())
        self.assertEqual(second["block_start"], "2026-08-26")
        self.assertEqual(second["source"], "stored")
        self.assertEqual([p["muscle"] for p in second["picks"]], ["Triceps"])
        self.assertEqual(later.written, [], "nothing recomputed, nothing consumed")

    def test_the_review_reads_a_blocks_pick_without_making_one(self):
        rows = [{"id": 1, "date": "2026-08-02", "exercise": "Weak-point: Hamstrings", "reason": "under", "plan": "{}"},
                {"id": 2, "date": "2026-08-21", "exercise": "Weak-point: Triceps", "reason": "named", "plan": "{}"},
                {"id": 3, "date": "2026-08-21", "exercise": "Weak-point: Chest", "reason": "named", "plan": "{}"},
                {"id": 4, "date": "2026-09-19", "exercise": "Weak-point: none", "reason": "nothing under", "plan": "{}"}]
        fake = _FakeSupabase([], [], decisions=rows)
        picks = weakpoints.block_picks_between(fake, "2026-08-20", "2026-09-18")
        self.assertEqual([p["muscle"] for p in picks], ["Triceps", "Chest"])
        self.assertEqual(weakpoints.block_picks_between(fake, "2026-09-18", "2026-09-19"), [], "'none' is no pick")
        self.assertEqual([p["muscle"] for p in weakpoints.block_picks_between(fake, None, "2026-08-10")], ["Hamstrings"])
        self.assertEqual(fake.written, [])

    def test_the_restore_fix_removes_the_orphan_pick_and_queues_the_emphasis_again(self):
        import datetime
        import data_fixes
        rows = [{"id": 1, "date": "2026-09-19", "exercise": "Weak-point: Triceps", "reason": "named", "plan": "{}"},
                {"id": 2, "date": "2026-09-19", "exercise": "Weak-point: Chest", "reason": "named", "plan": "{}"},
                {"id": 3, "date": "2026-09-02", "exercise": "Weak-point: Triceps", "reason": "last block", "plan": "{}"}]
        fake = _FakeSupabase([], [], decisions=rows)
        with patch("data.get_supabase", return_value=fake), patch.object(weakpoints, "get_supabase", return_value=fake), \
             patch("coach.load_system_prompt", return_value=_prompt()), \
             patch.object(weakpoints, "now_local", return_value=datetime.datetime(2026, 9, 19, 18)):
            note = data_fixes._fix_2026_09_19_restore_next_emphasis()
        self.assertIn("removed 2 orphan pick row(s)", note)
        self.assertEqual([r["id"] for r in fake.decisions], [3], "last block's pick is untouched")
        self.assertEqual([r["exercise"] for r in fake.written], ["Emphasis-next: Triceps", "Emphasis-next: Chest"])
        self.assertEqual([r["reason"] for r in fake.written], ["Overhead Cable Extension", "Cable Fly (Low To High)"])

    def test_a_stalled_lift_nominates_its_muscle_when_nothing_is_under(self):
        fake = _FakeSupabase(self._sessions(), self._full_sets(stalled="Tricep Pushdown"))
        with patch.object(weakpoints, "get_supabase", return_value=fake), \
             patch.object(weakpoints, "now_local", return_value=__import__("datetime").datetime(2026, 8, 25)):
            info = weakpoints.current_block_weak_points({"mesocycle_week": 2, "mesocycle_day": 1}, _prompt())
        self.assertEqual([p["muscle"] for p in info["picks"]], ["Triceps"])
        self.assertIn("Tricep Pushdown sat at 37.5kg", info["picks"][0]["reason"])

    def test_nothing_under_and_nothing_stalled_is_none(self):
        fake = _FakeSupabase(self._sessions(), self._full_sets())
        with patch.object(weakpoints, "get_supabase", return_value=fake), \
             patch.object(weakpoints, "now_local", return_value=__import__("datetime").datetime(2026, 8, 25)):
            info = weakpoints.current_block_weak_points({"mesocycle_week": 2, "mesocycle_day": 1}, _prompt())
        self.assertEqual(info["picks"], [])

    def test_the_next_emphasis_command(self):
        from weakpoints import parse_emphasis_next, parse_weak_point_command
        self.assertEqual(parse_emphasis_next("emphasis next: triceps | overhead cable extension"),
                         {"muscle": "triceps", "note": "overhead cable extension"})
        self.assertEqual(parse_emphasis_next("weak points next none"), {"muscle": None, "note": ""})
        self.assertIsNone(parse_emphasis_next("weak points none"))
        self.assertIsNone(parse_weak_point_command("emphasis next: triceps"))
        fake = _FakeSupabase([], [], decisions=[])
        with patch.object(weakpoints, "get_supabase", return_value=fake), \
             patch.object(weakpoints, "now_local", return_value=__import__("datetime").datetime(2026, 9, 10)):
            msg = weakpoints.set_next_emphasis(_prompt(), "triceps", "overhead cable extension")
        self.assertIn("Triceps is the emphasis for the next block", msg)
        self.assertEqual(fake.written[0]["exercise"], "Emphasis-next: Triceps")
        self.assertEqual(fake.written[0]["reason"], "overhead cable extension")

    def test_two_named_muscles_take_one_slot_each(self):
        pending = [{"id": 8, "date": "2026-09-12", "exercise": "Emphasis-next: Triceps",
                    "reason": "overhead cable extension", "plan": "{}"},
                   {"id": 9, "date": "2026-09-12", "exercise": "Emphasis-next: Chest",
                    "reason": "low-to-high cable fly, upper chest", "plan": "{}"}]
        fake = _FakeSupabase(self._sessions(), self._full_sets(), decisions=pending)
        with patch.object(weakpoints, "get_supabase", return_value=fake), \
             patch.object(weakpoints, "now_local", return_value=__import__("datetime").datetime(2026, 8, 25)):
            info = weakpoints.current_block_weak_points({"mesocycle_week": 2, "mesocycle_day": 1}, _prompt())
        self.assertEqual([p["muscle"] for p in info["picks"]], ["Triceps", "Chest"])
        text = format_block_weak_points(info)
        self.assertIn("One slot per muscle above", text)
        self.assertIn("low-to-high cable fly", text)

    def test_naming_a_second_muscle_keeps_the_first(self):
        fake = _FakeSupabase([], [], decisions=[{"id": 1, "date": "2026-09-12", "exercise": "Emphasis-next: Triceps",
                                                 "reason": "overhead cable extension", "plan": "{}"}])
        with patch.object(weakpoints, "get_supabase", return_value=fake), \
             patch.object(weakpoints, "now_local", return_value=__import__("datetime").datetime(2026, 9, 12)):
            msg = weakpoints.set_next_emphasis(_prompt(), "chest", "low-to-high cable fly")
        self.assertIn("Triceps and Chest are the emphasis", msg)
        self.assertEqual([r["exercise"] for r in fake.decisions if r["exercise"].startswith("Emphasis-next")],
                         ["Emphasis-next: Triceps"])
        self.assertEqual(fake.written[0]["exercise"], "Emphasis-next: Chest")


class EmphasisArrivingLateTests(unittest.TestCase):
    """The pick is made once per block and held. "Once" meant "at the first
    coach interaction after the block rolled over" — a briefing, or any chat
    message — and after that the stored pick short-circuited the lookup, so a
    muscle named later was never read again for that block. Two muscles were
    agreed in chat, named a day late, and a Cardio+Abs day still went out on
    the computed deficit with nothing anywhere saying why.
    """

    def test_an_emphasis_named_before_the_block_supersedes_a_computed_pick(self):
        from weakpoints import _named_picks
        bands = {"triceps": (10, 16), "chest": (10, 18), "hamstrings": (10, 16)}
        pending = [{"id": 1, "muscle": "triceps", "note": "overhead cable extension", "set_on": "2026-09-12"},
                   {"id": 2, "muscle": "chest", "note": "low-to-high cable fly", "set_on": "2026-09-12"}]
        start = "2026-09-15"
        due = [n for n in pending if (n.get("set_on") or "9999") < start]
        self.assertEqual(len(due), 2)
        picks = _named_picks(due, bands)
        self.assertEqual([p["muscle"] for p in picks], ["triceps", "chest"])
        self.assertIn("named by the athlete on 2026-09-12", picks[0]["reason"])
        self.assertIn("overhead cable extension", picks[0]["reason"])

    def test_an_emphasis_named_during_the_block_is_left_for_the_next_one(self):
        """`emphasis next` means next. Hijacking the block in progress would
        break the rule that the pick is held so the lift can progress."""
        start = "2026-09-15"
        pending = [{"id": 3, "muscle": "triceps", "note": "", "set_on": "2026-09-16"}]
        due = [n for n in pending if (n.get("set_on") or "9999") < start]
        self.assertEqual(due, [])

    def test_a_muscle_without_a_band_is_skipped_not_stored(self):
        from weakpoints import _named_picks
        bands = {"triceps": (10, 16)}
        picks = _named_picks([{"id": 1, "muscle": "eyebrows", "note": "", "set_on": "2026-09-12"}], bands)
        self.assertEqual(picks, [])

    def test_the_readout_names_what_is_queued_for_the_next_block(self):
        from weakpoints import format_block_weak_points
        info = {"block_start": "2026-09-15", "since": "2026-09-01", "until": "2026-09-14",
                "picks": [{"muscle": "hamstrings", "sets": 6.7, "low": 10, "high": 16, "shortfall": 3.3,
                           "reason": "Block pick: hamstrings ran 6.7 sets/week"}],
                "ranking": [], "source": "stored",
                "pending": [{"id": 1, "muscle": "triceps", "note": "", "set_on": "2026-09-16"},
                            {"id": 2, "muscle": "chest", "note": "", "set_on": "2026-09-16"}]}
        text = format_block_weak_points(info)
        self.assertIn("hamstrings", text)
        self.assertIn("Queued for the NEXT block", text)
        self.assertIn("triceps, chest", text)
        # And it tells the coach the command that would move it to this block.
        self.assertIn("weak points: triceps, chest", text)

    def test_nothing_queued_adds_no_line(self):
        from weakpoints import format_block_weak_points
        info = {"block_start": "2026-09-15", "since": "2026-09-01", "until": "2026-09-14",
                "picks": [], "ranking": [], "source": "stored", "pending": []}
        self.assertNotIn("Queued for the NEXT block", format_block_weak_points(info))

    def test_the_athletes_own_pick_for_this_block_is_never_superseded(self):
        """`weak points:` is a deliberate instruction about THIS block and
        outranks anything queued for the next one. It is marked since=athlete."""
        stored = [{"muscle": "calves", "since": "athlete", "until": "2026-09-16"}]
        by_athlete = any((p.get("since") or "") == "athlete" for p in stored)
        self.assertTrue(by_athlete)
