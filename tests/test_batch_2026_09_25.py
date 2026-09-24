"""The 25 Sep batch: F5 standing decisions reviewed by age, F6a the case
variants merged, F7 the widget's week line and block-aware phase."""
import unittest
from unittest.mock import MagicMock, patch

try:
    import blockfix  # noqa: F401
except ImportError:
    from tests import blockfix  # noqa: F401


class StandingDecisionReviewTests(unittest.TestCase):
    ROWS = [{"exercise": "Machine Shoulder Press", "max_load_kg": 70, "note": "shoulder niggle", "set_on": "2026-09-17"}]

    def test_sessions_under_the_decision_are_counted_per_lift(self):
        import constraints
        sb = MagicMock()
        sb.table.return_value.select.return_value.gte.return_value.execute.return_value.data = [
            {"exercise": "Machine Shoulder Press", "workout_session_id": s, "date": d}
            for s, d in (("a", "2026-09-17"), ("a", "2026-09-17"), ("b", "2026-09-22"), ("c", "2026-09-27"), ("old", "2026-09-10"))
        ] + [{"exercise": "Leg Press", "workout_session_id": "z", "date": "2026-09-23"}]
        with patch("constraints.get_supabase", return_value=sb):
            held = constraints.sessions_held(self.ROWS)
        self.assertEqual(held, {"machineshoulderpress": 3})

    def test_due_after_four_sessions_and_not_again_for_a_week(self):
        import constraints
        held = {"machineshoulderpress": 4}
        self.assertEqual(constraints.due_for_review(self.ROWS, held, {}), ["Machine Shoulder Press"])
        self.assertEqual(constraints.due_for_review(self.ROWS, {"machineshoulderpress": 3}, {}), [])
        today = constraints.now_local().strftime("%Y-%m-%d")
        self.assertEqual(constraints.due_for_review(self.ROWS, held, {"constraint_asked:machineshoulderpress": today}), [])
        self.assertEqual(constraints.due_for_review(self.ROWS, held, {"constraint_asked:machineshoulderpress": "2026-01-01"}), ["Machine Shoulder Press"])

    def test_the_coach_is_told_once(self):
        import constraints
        text = constraints.format_constraints(self.ROWS, {"machineshoulderpress": 5}, ["Machine Shoulder Press"])
        self.assertIn("5 sessions under it", text)
        self.assertIn("ASK ONCE TODAY", text)
        self.assertIn("`Decision: Machine Shoulder Press | clear`", text)
        quiet = constraints.format_constraints(self.ROWS, {"machineshoulderpress": 2}, [])
        self.assertNotIn("ASK ONCE", quiet)
        self.assertIn("2 sessions under it", quiet)


class CaseVariantTests(unittest.TestCase):
    def test_the_plan_merges_case_and_spacing_only(self):
        from fixes_2026_09 import case_variant_plan
        names = {"Leg Press": 143, "Leg press": 31, "Machine Chest Fly": 4, "Cable Chest Fly": 53, "Ab Crunch Machine": 56,
                 "Ab crunch machine": 19, "Face  Pulls": 2, "Face Pulls": 57, "Pull-Ups": 81, "Pull-ups": 1}
        plan = case_variant_plan(names)
        self.assertEqual(plan, {"Leg press": "Leg Press", "Ab crunch machine": "Ab Crunch Machine",
                                "Face  Pulls": "Face Pulls", "Pull-ups": "Pull-Ups"})
        self.assertNotIn("Machine Chest Fly", plan, "a different lift or an alias, never a case fix")

    def test_the_fix_renames_each_variant(self):
        from fixes_2026_09 import _fix_2026_09_25_exercise_case_variants
        sb = MagicMock()
        sb.table.return_value.select.return_value.execute.return_value.data = (
            [{"exercise": "Leg Press"}] * 3 + [{"exercise": "Leg press"}] * 2 + [{"exercise": "Dips"}])
        with patch("data.get_supabase", return_value=sb):
            out = _fix_2026_09_25_exercise_case_variants()
        self.assertIn("Leg press -> Leg Press (2 sets)", out)
        sb.table.return_value.update.assert_called_once_with({"exercise": "Leg Press"})
        sb.table.return_value.update.return_value.eq.assert_called_once_with("exercise", "Leg press")

    def test_registered_first_in_the_september_fixes(self):
        from fixes_2026_09 import FIXES_2026_09
        self.assertEqual(FIXES_2026_09[0][0], "2026-09-25-exercise-case-variants")


class WidgetWeekTests(unittest.TestCase):
    def test_phase_follows_the_block_length(self):
        import data, webhook
        self.assertEqual([webhook._phase_short(w) for w in (1, 2, 3, 4)], ["BASELINE", "VOLUME", "PEAK · LOAD", "DELOAD"])
        with patch.object(data, "block_weeks", lambda: 5):
            self.assertEqual([webhook._phase_short(w) for w in (3, 4, 5)], ["PEAK · REPS", "PEAK · LOAD", "DELOAD"])
        self.assertEqual(webhook._phase_short(9), "")

    def test_this_week_against_last(self):
        import webhook
        from datetime import timedelta
        today = webhook.now_local().date(); monday = today - timedelta(days=today.weekday())
        rows = [{"date": (monday + timedelta(days=1)).isoformat(), "tonnage_kg": 20000, "type": "Legs"},
                {"date": monday.isoformat(), "tonnage_kg": 8000, "type": "Pull"},
                {"date": (monday - timedelta(days=3)).isoformat(), "tonnage_kg": 25000, "type": "Legs"},
                {"date": monday.isoformat(), "tonnage_kg": 0, "type": "Cardio+Abs"}]
        sb = MagicMock()
        sb.table.return_value.select.return_value.gte.return_value.execute.return_value.data = rows
        with patch("webhook.get_supabase", return_value=sb):
            out = webhook._week_stats()
        self.assertEqual((out["week_sessions"], out["week_tonnage_kg"], out["week_tonnage_delta_pct"]), (2, 28000.0, 12))
        with patch("webhook.get_supabase", return_value=None):
            self.assertEqual(webhook._week_stats()["week_sessions"], None)


class HygieneAndBackfillTests(unittest.TestCase):
    def test_session_type_from_the_sets(self):
        from fixes_2026_09 import infer_session_type
        self.assertEqual(infer_session_type(["Barbell Bench Press", "Barbell Bench Press", "Sled Leg Press"]), "Push")
        self.assertEqual(infer_session_type(["Leg press", "Leg Press"]), "Legs")
        self.assertEqual(infer_session_type(["Cable Row", "Lat Pulldown", "Hammer Curl"]), "Pull")
        self.assertIsNone(infer_session_type([]))

    def test_backfill_walks_the_rotation_backwards(self):
        from data import CYCLE
        from fixes_2026_09 import backfill_stamps
        S = [{"id": "a", "date": "2026-08-28", "type": "Pull", "tonnage_kg": 1},
             {"id": "b", "date": "2026-08-29", "type": "Push", "tonnage_kg": 1},
             {"id": "c", "date": "2026-08-31", "type": "Legs", "tonnage_kg": 1},
             {"id": "d", "date": "2026-09-01", "type": "Cardio+Abs", "tonnage_kg": 1},
             {"id": "e", "date": "2026-09-01", "type": "Cardio+Abs", "tonnage_kg": 1, "start_time": "2026-09-01T09:00:00"},
             {"id": "empty", "date": "2026-08-30", "type": "Legs", "tonnage_kg": 0},
             {"id": "s", "date": "2026-09-02", "type": "Pull", "tonnage_kg": 1, "mesocycle_week": 1, "mesocycle_day": 1}]
        out = backfill_stamps(S, CYCLE, 4)
        self.assertEqual(out, {"d": (4, 4), "e": (4, 4), "c": (4, 3), "b": (4, 2), "a": (4, 1)})
        self.assertNotIn("empty", out, "a session with no work is not a slot")
        # a missed slot: no Legs between Push and Cardio
        S2 = [{"id": "p", "date": "2026-08-29", "type": "Push", "tonnage_kg": 1},
              {"id": "cardio", "date": "2026-09-01", "type": "Cardio+Abs", "tonnage_kg": 1},
              {"id": "s", "date": "2026-09-02", "type": "Pull", "tonnage_kg": 1, "mesocycle_week": 1, "mesocycle_day": 1}]
        self.assertEqual(backfill_stamps(S2, CYCLE, 4), {"cardio": (4, 4), "p": (4, 2)})
        self.assertEqual(backfill_stamps([{"id": "x", "date": "2026-08-01", "type": "Pull", "tonnage_kg": 1}], CYCLE), {}, "nothing stamped to walk back from")

    def test_the_fixes_are_registered_in_order(self):
        from fixes_2026_09 import FIXES_2026_09
        keys = [k for k, _ in FIXES_2026_09]
        self.assertEqual(keys[:3], ["2026-09-25-exercise-case-variants", "2026-09-25-session-hygiene", "2026-09-25-stamp-backfill"])


class ReadyToLoadTests(unittest.TestCase):
    """C2: the watch's READY TO LOAD flag drives the number."""

    def test_the_current_load_row_carries_ready(self):
        from progression import find_current_loads
        rows = [
            {"exercise": "Leg Press", "date": "2026-09-09", "actual_weight_kg": 240, "actual_reps": 13, "actual_rpe": 8, "is_warmup": False, "workout_session_id": "a"},
            {"exercise": "Leg Press", "date": "2026-09-14", "actual_weight_kg": 240, "actual_reps": 11, "actual_rpe": 9.5, "is_warmup": False, "workout_session_id": "b"},
            {"exercise": "Cable Row", "date": "2026-09-14", "actual_weight_kg": 90.5, "actual_reps": 8, "actual_rpe": 9, "is_warmup": False, "workout_session_id": "b"},
        ]
        by = {r["exercise"]: r for r in find_current_loads(rows)}
        self.assertTrue(by["Leg Press"]["ready"], "an earlier session at 240 reached the top at RPE 8")
        self.assertFalse(by["Cable Row"]["ready"])

    def test_week_two_steps_when_ready_even_if_the_last_set_did_not_quite(self):
        from prescribe import COMPOUND, PriorSet, prescribe_exercise
        # Last session 11 of 8-12 at RPE 9.5: the single-set rule holds the load.
        held = prescribe_exercise("Leg Press", 3, COMPOUND, 2, PriorSet(240.0, 9, 9.5, step=2.5), set())
        self.assertEqual(held.working[0].weight_kg, 240.0)
        ready = prescribe_exercise("Leg Press", 3, COMPOUND, 2, PriorSet(240.0, 9, 9.5, step=2.5, ready=True), set())
        self.assertEqual(ready.working[0].weight_kg, 242.5)
        self.assertTrue(any("READY TO LOAD" in r for r in ready.reasons))
        # The peak-by-reps branch too.
        peak = prescribe_exercise("Leg Press", 3, COMPOUND, 3, PriorSet(240.0, 9, 9.5, step=2.5, ready=True), set())
        self.assertEqual(peak.working[0].weight_kg, 242.5)
        # Never at bodyweight, where the step is a plate the coach decides.
        bw = prescribe_exercise("Pull-Ups", 2, COMPOUND, 2, PriorSet(None, 6, 9.5, bodyweight=True, ready=True), set())
        self.assertTrue(bw.working[0].bodyweight)


class UnloadableBodyweightTests(unittest.TestCase):
    """C17: a rollout has nothing to load; it progresses by reps, then a variation."""

    def test_the_range_moves_not_the_load(self):
        from prescribe import ISOLATION, PriorSet, is_unloadable, prescribe_exercise
        self.assertTrue(is_unloadable("Ab Wheel Rollout"))
        self.assertFalse(is_unloadable("Hanging Leg Raises"))   # a dumbbell between the feet
        self.assertFalse(is_unloadable("Pull-Ups"))
        top = prescribe_exercise("Plank", 2, ISOLATION, 2, PriorSet(None, 12, 8.0, bodyweight=True), set()).working[0]
        self.assertEqual((top.weight_kg, top.bodyweight, top.reps_low, top.reps_high), (None, True, 11, 15))
        mid = prescribe_exercise("Ab Wheel Rollout", 2, ISOLATION, 2, PriorSet(None, 9, 8.0, bodyweight=True), set()).working[0]
        self.assertEqual((mid.weight_kg, mid.reps_low, mid.reps_high), (None, 10, 12))
        p = prescribe_exercise("Plank", 2, ISOLATION, 1, PriorSet(None, 12, 8.0, bodyweight=True, week=3), set())
        self.assertIsNone(p.working[0].weight_kg, "week 1 opens without inventing a plate")
        self.assertTrue(any("No load to add" in r for r in p.reasons))

    def test_past_the_cap_a_variation_is_the_coachs_call(self):
        from prescribe import ISOLATION, PriorSet, prescribe_exercise
        p = prescribe_exercise("Plank", 2, ISOLATION, 2, PriorSet(None, 20, 8.0, bodyweight=True), set(), rep_range=(17, 20))
        self.assertIsNone(p.working[0].weight_kg)
        self.assertTrue(any("harder variation" in d for d in p.deferred))


class BigStepRangeTests(unittest.TestCase):
    """A machine whose smallest step exceeds 6% of the load stretches the
    rep range instead of taking a jump that misses (25 Sep 2026).

    Measured on the export, top sets June-23 Sep: Hammer Curl moves in 2kg on
    20kg (10%) and all 3 increases landed under the range; Reverse Cable Fly
    2.5kg on 15kg (17%), 2 of 4; Tricep Pushdown 2.5kg on 40kg (6.25%), 2 of 4.
    """

    def test_the_range_stretches_to_where_one_step_lands_back_inside_it(self):
        from prescribe import stretched_top
        self.assertEqual(stretched_top(20.0, 2.0, 8, 12), 13)     # hammer curl
        self.assertEqual(stretched_top(15.0, 2.5, 8, 12), 16)     # reverse cable fly
        self.assertEqual(stretched_top(40.0, 2.5, 8, 12), 12)     # pushdown: 6.25%, but 12 already lands it
        self.assertEqual(stretched_top(100.0, 2.5, 6, 10), 10)    # a 2.5% step: untouched
        self.assertEqual(stretched_top(10.0, 5.0, 8, 12), 18)     # 50%: capped at +6

    def test_the_top_of_the_standard_range_holds_the_load_on_a_big_step_machine(self):
        from prescribe import prescribe_exercise, PriorSet, ISOLATION
        p = prescribe_exercise("Hammer Curl", 3, ISOLATION, 2, PriorSet(20.0, 12, 8.0, step=2.0), set())
        self.assertEqual(p.working[0].weight_kg, 20.0)
        self.assertEqual(p.working[0].reps_high, 13)
        self.assertTrue(any("10% of 20kg" in r for r in p.reasons))
        p = prescribe_exercise("Hammer Curl", 3, ISOLATION, 2, PriorSet(20.0, 13, 8.0, step=2.0), set())
        self.assertEqual(p.working[0].weight_kg, 22.0)
        self.assertEqual((p.working[0].reps_low, p.working[0].reps_high), (8, 13))

    def test_a_small_step_machine_still_loads_at_the_standard_top(self):
        from prescribe import prescribe_exercise, PriorSet, COMPOUND
        p = prescribe_exercise("Cable Row", 2, COMPOUND, 2, PriorSet(80.0, 10, 8.0, step=2.5), set())
        self.assertEqual(p.working[0].weight_kg, 82.5)
        self.assertFalse(any("smallest step" in r for r in p.reasons))

    def test_a_step_no_stretch_can_absorb_is_deferred_to_the_coach(self):
        from prescribe import prescribe_exercise, PriorSet, ISOLATION
        p = prescribe_exercise("Reverse Cable Fly", 3, ISOLATION, 2, PriorSet(10.0, 12, 8.0, step=5.0), set())
        self.assertEqual(p.working[0].weight_kg, 10.0)
        self.assertEqual(p.working[0].reps_high, 18)
        self.assertTrue(any("Microplates" in d for d in p.deferred))

    def test_preflight_does_not_clip_a_stretched_range(self):
        import preflight
        from prescribe import Proposal, SetSpec, PriorSet, ISOLATION
        prior = {"Hammer Curl": PriorSet(20.0, 12, 8.0, step=2.0)}
        p = Proposal(exercise="Hammer Curl", kind=ISOLATION, working=[SetSpec(20.0, 8, 13, 8.0, grid=2.0)])
        out, findings = preflight.enforce([p], prior, {}, 2)
        self.assertEqual(out[0].working[0].reps_high, 13)
        self.assertEqual([f for f in findings if f["kind"] == "range"], [])

    def test_ready_to_load_waits_for_the_stretched_top(self):
        from progression import _programme_due
        tops = [{"actual_weight_kg": "20", "actual_reps": "12", "actual_rpe": "8"}]
        self.assertFalse(_programme_due("Hammer Curl", tops, step=2.0))
        self.assertTrue(_programme_due("Hammer Curl", tops, step=1.0))
        tops[0]["actual_reps"] = "13"
        self.assertTrue(_programme_due("Hammer Curl", tops, step=2.0))


class StepFromTheCommonGapTests(unittest.TestCase):
    """One load off the lift's grid — another machine, a typo — must not set
    the step (25 Sep 2026: 9 of 28 lifts carried such a load, measured)."""

    def _sessions(self, loads):
        return {f"2026-09-{i+1:02d}": [{"actual_weight_kg": str(w), "actual_reps": "10", "is_warmup": "0", "set_number": "1"}]
                for i, w in enumerate(loads)}

    def test_the_chest_press_reads_its_eight_kilo_stack_despite_a_half_kilo_stray(self):
        from progression import _load_step
        self.assertEqual(_load_step(self._sessions([132.5, 133.0, 141.0, 149.0, 165.0])), 8.0)

    def test_the_cable_row_reads_four_not_one(self):
        from progression import _load_step
        self.assertEqual(_load_step(self._sessions([73.5, 74.5, 78.5, 82.5, 86.5, 90.5])), 4.0)

    def test_a_finer_gap_that_divides_the_common_one_is_the_real_step(self):
        from progression import _load_step
        # Sumo press: moved in 5s by habit, but 132.5 proves the 2.5 exists.
        self.assertEqual(_load_step(self._sessions([105.0, 110.0, 115.0, 120.0, 125.0, 130.0, 132.5, 150.0])), 2.5)
        # Face pulls: 35, 40, 42.5, 47.5 — the 2.5 is half the 5.
        self.assertEqual(_load_step(self._sessions([35.0, 40.0, 42.5, 47.5])), 2.5)

    def test_a_clean_grid_is_unchanged_and_a_tie_goes_to_the_smaller_gap(self):
        from progression import _load_step
        self.assertEqual(_load_step(self._sessions([100.0, 102.5, 105.0, 107.5])), 2.5)
        self.assertEqual(_load_step(self._sessions([10.0, 12.5, 17.5])), 2.5)


class RolloutLadderTests(unittest.TestCase):
    """The rollout progresses by lever, never by reps (the programme's rule;
    athlete's decision 25 Sep 2026: standing now, no vest available)."""

    def test_at_the_top_of_the_range_the_next_rung_is_named_not_more_reps(self):
        from prescribe import prescribe_exercise, PriorSet, ISOLATION
        p = prescribe_exercise("Ab Wheel Rollout", 2, ISOLATION, 2, PriorSet(None, 12, 7.0, bodyweight=True), set())
        self.assertIsNone(p.working[0].weight_kg)
        self.assertEqual((p.working[0].reps_low, p.working[0].reps_high), (8, 12))
        self.assertTrue(any("Standing Ab Wheel Rollout" in d and "NOT progress by reps" in d for d in p.deferred))

    def test_the_standing_rollout_runs_six_to_ten_and_names_the_rung_after(self):
        from prescribe import prescribe_exercise, PriorSet, ISOLATION
        p = prescribe_exercise("Standing Ab Wheel Rollout", 2, ISOLATION, 2, PriorSet(None, 8, 8.0, bodyweight=True), set())
        self.assertEqual((p.working[0].reps_low, p.working[0].reps_high), (9, 10))
        p = prescribe_exercise("Standing Ab Wheel Rollout", 2, ISOLATION, 2, PriorSet(None, 10, 7.0, bodyweight=True), set())
        self.assertTrue(any("farther out" in d and "full standing" in d for d in p.deferred))
        self.assertIsNone(p.working[0].weight_kg)

    def test_the_recorded_line_is_a_substitution_the_shape_applies(self):
        import shape
        from decisions import RECORDABLE_RE
        from fixes_2026_09 import ROLLOUT_STANDING_LINE
        m = RECORDABLE_RE.match(ROLLOUT_STANDING_LINE)
        self.assertIsNotNone(m)
        self.assertEqual((m.group("sub_from"), m.group("sub_to"), m.group("horizon")),
                         ("Ab Wheel Rollout", "Standing Ab Wheel Rollout", "standing"))
        recorded = {"substitutes": [{"from": "Ab Wheel Rollout", "to": "Standing Ab Wheel Rollout",
                                     "horizon": "standing", "why": "lever"}], "orders": {}}
        pairs = shape.apply([("Cable Crunch", 3), ("Ab Wheel Rollout", 2)], "Cardio+Abs", recorded)
        self.assertEqual(pairs, [("Cable Crunch", 3), ("Standing Ab Wheel Rollout", 2)])

    def test_the_fix_writes_once(self):
        from unittest.mock import patch
        from fixes_2026_09 import _fix_2026_09_25_rollout_standing, FIXES_2026_09

        class Q:
            def __init__(self, store, table): self.store, self.table_name = store, table
            def select(self, *a): return self
            def eq(self, *a): return self
            def execute(self):
                class R: pass
                r = R(); r.data = list(self.store[self.table_name]); return r
            def insert(self, row):
                self.store[self.table_name].append(row); return self

        class Fake:
            def __init__(self): self.store = {"decision_captures": []}
            def table(self, name): return Q(self.store, name)

        fake = Fake()
        with patch("data.get_supabase", return_value=fake):
            first = _fix_2026_09_25_rollout_standing()
            second = _fix_2026_09_25_rollout_standing()
        self.assertIn("recorded", first)
        self.assertIn("already exists", second)
        rows = fake.store["decision_captures"]
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["kind"], rows[0]["status"]), ("substitute", "recorded"))
        self.assertIn("2026-09-25-rollout-standing", [k for k, _ in FIXES_2026_09])
