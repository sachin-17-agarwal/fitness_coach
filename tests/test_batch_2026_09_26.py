"""The 26 Sep 2026 batch: C13 rest, C19 ladders, F4 questions, E7 rollover."""
import unittest
from unittest.mock import patch

try:
    import blockfix  # noqa: F401
except ImportError:
    from tests import blockfix  # noqa: F401


class _Q:
    def __init__(self, store, table): self.store, self.table_name = store, table
    def select(self, *a): return self
    def eq(self, *a): return self
    def in_(self, *a): return self
    def order(self, *a, **k): return self
    def limit(self, *a): return self
    def execute(self):
        class R: pass
        r = R(); r.data = list(self.store[self.table_name]); return r
    def insert(self, row):
        self.store[self.table_name].append(dict(row)); return self


class _Fake:
    def __init__(self, rows=None): self.store = {"decision_captures": list(rows or [])}
    def table(self, name): return _Q(self.store, name)


def _sessions(exercise, loads, reps=10):
    return {f"2026-09-{i+1:02d}": [{"exercise": exercise, "actual_weight_kg": str(w), "actual_reps": str(reps),
                                     "is_warmup": False, "set_number": "1", "date": f"2026-09-{i+1:02d}"}]
            for i, w in enumerate(loads)}


class RestTests(unittest.TestCase):
    """C13: rest reprogrammed to what the evidence and the athlete's own rests say."""

    def test_the_card_rests_three_minutes_on_compounds_and_two_and_a_half_on_isolations(self):
        from prescribe import COMPOUND, ISOLATION, REST_SECONDS, PriorSet, prescribe_exercise
        self.assertEqual((REST_SECONDS[COMPOUND], REST_SECONDS[ISOLATION]), (180, 150))
        self.assertEqual(prescribe_exercise("Cable Row", 2, COMPOUND, 2, PriorSet(80.0, 8, 8.0), set()).rest_seconds, 180)
        self.assertEqual(prescribe_exercise("Hammer Curl", 3, ISOLATION, 2, PriorSet(20.0, 9, 8.0), set()).rest_seconds, 150)

    def test_a_block_without_a_rest_takes_the_kinds(self):
        from plan import plan_from_block
        e = plan_from_block({"exercise": "Leg Press", "working": [{"weight": 200, "reps": 8, "rpe": 8}]}, {})
        self.assertEqual(e.rest_seconds, 180)


class LadderTests(unittest.TestCase):
    """C19: a load off the machine's ladder is questioned, not progressed from."""

    def test_the_chest_press_stray_is_seen_and_anchored_to_the_last_on_ladder_load(self):
        from progression import ladder_position
        # 8kg stack; 132.5 (the export's own stray, 22 Sep) is not on it.
        pos = ladder_position(_sessions("Machine Chest Press", [117.0, 125.0, 141.0, 149.0, 132.5]))
        self.assertIsNotNone(pos)
        self.assertEqual((pos["load"], pos["step"], pos["anchor_load"]), (132.5, 8.0, 149.0))

    def test_a_load_on_the_ladder_is_not_questioned(self):
        from progression import ladder_position
        self.assertIsNone(ladder_position(_sessions("Machine Chest Press", [125.0, 133.0, 141.0, 149.0, 165.0])))

    def test_bodyweight_plates_and_one_off_steps_are_not_ladders(self):
        from progression import ladder_position
        self.assertIsNone(ladder_position(_sessions("Pull-Ups", [10.0, 14.0, 15.0, 17.5])))
        self.assertIsNone(ladder_position(_sessions("Cable Row", [70.0, 74.0, 79.0, 85.5])))

    def test_current_loads_progress_from_the_anchor_until_the_athlete_says_it_was_real(self):
        from progression import find_current_loads
        rows = [r for s in _sessions("Machine Chest Press", [117.0, 125.0, 141.0, 149.0, 132.5]).values() for r in s]
        [row] = find_current_loads(rows)
        self.assertEqual((row["load"], row["off_ladder"]["treated"], row["off_ladder"]["anchor_load"]), (149.0, "stray", 149.0))
        [row] = find_current_loads(rows, {"machinechestpress": {132.5: "real"}})
        self.assertEqual((row["load"], row["off_ladder"]["treated"]), (132.5, "real"))

    def test_the_grammar_and_the_card_text(self):
        from decisions import RECORDABLE_RE, describe, kind_of, subject_of
        line = "Ladder: Machine Chest Press | 133kg stray | not a whole number of 8kg steps from 149kg (2026-09-05)"
        self.assertIsNotNone(RECORDABLE_RE.match(line))
        self.assertEqual((kind_of(line), subject_of(line)), ("ladder", "machinechestpress"))
        text = describe(line)
        self.assertIn("133 kg is off this machine's ladder", text)
        self.assertIn("Record = another machine", text)

    def test_answers_read_recorded_as_the_line_and_declined_as_its_opposite(self):
        import decisions
        rows = [{"line": "Ladder: Machine Chest Press | 133kg stray | why", "status": "recorded"},
                {"line": "Ladder: Cable Row | 73.5kg stray | why", "status": "declined"},
                {"line": "Ladder: Leg Press | 202kg stray | why", "status": "proposed"}]
        with patch("decisions.get_supabase", return_value=_Fake(rows)):
            out = decisions.ladder_answers()
        self.assertEqual(out, {"machinechestpress": {133.0: "stray"}, "cablerow": {73.5: "real"}})

    def test_the_nightly_run_asks_each_question_once(self):
        import decisions
        loads = [{"exercise": "Machine Chest Press", "off_ladder": {"load": 133.0, "date": "2026-09-05", "step": 8.0,
                                                                     "anchor_load": 149.0, "anchor_date": "2026-09-04", "treated": "stray"}},
                 {"exercise": "Cable Row", "off_ladder": None},
                 {"exercise": "Leg Press", "off_ladder": {"load": 202.0, "date": "2026-09-05", "step": 5.0,
                                                         "anchor_load": 200.0, "anchor_date": "2026-09-01", "treated": "real"}}]
        fake = _Fake()
        with patch("decisions.get_supabase", return_value=fake):
            self.assertEqual(decisions.propose_ladder_questions(loads), 1)
            self.assertEqual(decisions.propose_ladder_questions(loads), 0)
        [row] = fake.store["decision_captures"]
        self.assertEqual((row["kind"], row["status"], row["source"]), ("ladder", "proposed", "preflight"))
        self.assertTrue(row["line"].startswith("Ladder: Machine Chest Press | 133kg stray |"))

    def test_the_card_carries_the_programme_default(self):
        from programme import _ladder_notes
        plan = (("Machine Chest Press", 3, "compound"), ("Cable Row", 2, "compound"))
        loads = [{"exercise": "Machine Chest Press", "off_ladder": {"load": 133.0, "date": "2026-09-05", "step": 8.0,
                                                                     "anchor_load": 149.0, "anchor_date": "2026-09-04", "treated": "stray"}}]
        notes = _ladder_notes(plan, loads)
        self.assertIn("progresses from 149kg", notes["machinechestpress"])
        self.assertNotIn("cablerow", notes)


class RolloverReviewTests(unittest.TestCase):
    """E7: the review is prepared when the block rolls over."""

    def test_nothing_starts_outside_week_one_day_one_or_without_a_store(self):
        import block_review as br
        with patch("block_review.get_supabase", return_value=object()):
            self.assertIsNone(br.prepare_at_rollover({"mesocycle_week": 2, "mesocycle_day": 1}))
        with patch("block_review.get_supabase", return_value=None):
            self.assertIsNone(br.prepare_at_rollover({"mesocycle_week": 1, "mesocycle_day": 1}))

    def test_the_rollover_prepares_in_the_background_through_the_same_guards(self):
        import block_review as br
        with patch("block_review.get_supabase", return_value=object()), \
             patch("block_review.prepare_if_due", return_value={"id": 1}) as prepare, \
             patch("memory.load_memory", return_value={"mesocycle_week": 1, "mesocycle_day": 1}), \
             patch("coach.get_anthropic_client", return_value=object()), \
             patch("webhook.load_system_prompt_for_review", return_value="P"):
            t = br.prepare_at_rollover({"mesocycle_week": 1, "mesocycle_day": 1}, grace=0)
            self.assertIsNotNone(t)
            t.join(5)
        self.assertEqual(prepare.call_count, 1)

    def test_advancing_into_week_one_calls_the_hook(self):
        import memory as m
        state = {"mesocycle_week": 5, "mesocycle_day": 4}
        with patch("memory.load_memory", return_value=dict(state)), patch("memory.save_memory"), \
             patch("memory.today_local_str", return_value="2026-10-20"), \
             patch("memory.session_type_for", return_value="Cardio+Abs"), \
             patch("memory._block.block_weeks", return_value=5), \
             patch("block_review.prepare_at_rollover") as hook:
            mem = dict(state)
            m.advance_mesocycle(mem)
        self.assertEqual((mem["mesocycle_week"], mem["mesocycle_day"]), (1, 1))
        self.assertEqual(hook.call_count, 1)


if __name__ == "__main__":
    unittest.main()
