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


class RestFloorTests(unittest.TestCase):
    """Rest is the programme's number: the coach may go longer, never shorter."""

    def test_a_coach_rest_under_the_floor_is_raised_and_a_longer_one_kept(self):
        from plan import ExercisePlan, SessionPlan, SetPlan, rest_floor
        plan = SessionPlan(opening="", exercises=[
            ExercisePlan(exercise="Pull-Ups", decision="accept", reason="", working=[SetPlan(17.5, 7, 10, 8.0)], backoff=[], rest_seconds=120),
            ExercisePlan(exercise="Hammer Curl", decision="accept", reason="", working=[SetPlan(20.0, 9, 13, 8.0)], backoff=[], rest_seconds=240),
        ])
        notes = rest_floor(plan)
        self.assertEqual([e.rest_seconds for e in plan.exercises], [180, 240])
        self.assertEqual(notes, ["Pull-Ups: rest 120s raised to the programme's 180s"])


class NoChangeAdjustTests(unittest.TestCase):
    """An 'adjust' with the programme's own numbers is an accept with a note."""

    PROMPT = "Session template:\nPull: Lat Pulldown 2\n"

    def test_identical_numbers_flip_to_accept_and_the_card_shows_no_change(self):
        from plan import ExercisePlan, SessionPlan, SetPlan, render_plan, validate
        proposal = {"Lat Pulldown": "*Lat Pulldown*\nWorking Set: 90kg x8-10 RPE8 | Rest: 3min\nBack-off: 70kg x10-12 RPE8"}
        plan = SessionPlan(opening="", exercises=[
            ExercisePlan(exercise="Lat Pulldown", decision="adjust", reason="holding the programme's number after the pull-ups",
                         working=[SetPlan(90.0, 8, 10, 8.0)], backoff=[SetPlan(70.0, 10, 12, 8.0)], rest_seconds=180)])
        with patch("plan.parse_session_template", return_value=([("Lat Pulldown", 2)], 2)):
            validate(plan, "Pull", self.PROMPT, proposal)
        e = plan.exercises[0]
        self.assertEqual(e.decision, "accept")
        self.assertEqual(e.note, "holding the programme's number after the pull-ups")
        self.assertNotIn("Changed from the programme", render_plan(plan, proposal))


class BackoffSizingTests(unittest.TestCase):
    """C23: the back-off's own last result sizes the drop inside 15-25%."""

    def test_over_its_range_shrinks_the_drop_and_under_widens_it(self):
        from prescribe import COMPOUND, PriorSet, SetSpec, backoff_sets
        top = SetSpec(100.0, 8, 8, 8.0, grid=5.0)
        self.assertEqual(backoff_sets(top, COMPOUND, 1, 2, [], PriorSet(100.0, 8, 8.0, backoff_reps=15))[0].weight_kg, 85.0)
        self.assertEqual(backoff_sets(top, COMPOUND, 1, 2, [], PriorSet(100.0, 8, 8.0, backoff_reps=8))[0].weight_kg, 75.0)
        self.assertEqual(backoff_sets(top, COMPOUND, 1, 2, [], PriorSet(100.0, 8, 8.0, backoff_reps=11))[0].weight_kg, 80.0)
        self.assertEqual(backoff_sets(top, COMPOUND, 1, 2, [], None)[0].weight_kg, 80.0)

    def test_the_reason_says_why(self):
        from prescribe import COMPOUND, PriorSet, SetSpec, backoff_sets
        reasons = []
        backoff_sets(SetSpec(95.0, 8, 10, 8.0, grid=5.0), COMPOUND, 1, 2, reasons, PriorSet(90.0, 10, 8.0, backoff_reps=15))
        self.assertIn("ran 15 against 10-12, over the top, so the drop shrinks to 15%", reasons[0])

    def test_progression_carries_the_first_back_off(self):
        from progression import find_current_loads
        rows = [
            {"exercise": "Lat Pulldown", "date": "2026-09-20", "is_warmup": False, "set_number": 1, "phase": "working", "actual_weight_kg": "90", "actual_reps": "7", "actual_rpe": "7"},
            {"exercise": "Lat Pulldown", "date": "2026-09-20", "is_warmup": False, "set_number": 2, "phase": "backoff", "actual_weight_kg": "70", "actual_reps": "13", "actual_rpe": "6"},
            {"exercise": "Cable Row", "date": "2026-09-20", "is_warmup": False, "set_number": 1, "phase": None, "actual_weight_kg": "94.5", "actual_reps": "6", "actual_rpe": "7"},
            {"exercise": "Cable Row", "date": "2026-09-20", "is_warmup": False, "set_number": 2, "phase": None, "actual_weight_kg": "74.5", "actual_reps": "11", "actual_rpe": "6"},
        ]
        by = {r["exercise"]: r for r in find_current_loads(rows)}
        self.assertEqual(by["Lat Pulldown"]["backoff_reps"], 13)
        self.assertEqual(by["Cable Row"]["backoff_reps"], 11)


class MissingRevisionNoteTests(unittest.TestCase):
    """The no-revised-block note is owed only when no block came at all."""

    STORED = {"working": [{"weight": 20, "reps": 9, "reps_high": 13, "rpe": 8}], "backoff": []}

    def test_a_block_for_the_next_lift_is_not_a_missing_revision(self):
        from plan import missing_revision_note
        fly = [{"exercise": "Reverse Cable Fly", "working": [{"weight": 12.5, "reps": 8, "reps_high": 16, "rpe": 8}], "backoff": []}]
        self.assertIsNone(missing_revision_note("Moving down to 12.5 on the fly after last session ran under range.", fly, "Hammer Curl", self.STORED))

    def test_a_claim_with_no_block_at_all_is_still_owed(self):
        from plan import missing_revision_note
        note = missing_revision_note("Revising the back-off up.", [], "Hammer Curl", self.STORED)
        self.assertIsNotNone(note)
        self.assertIn("No revised block came through", note)


class HistoryCacheTests(unittest.TestCase):
    """E3: a cache breakpoint under the older turns of today's history."""

    def test_the_breakpoint_sits_before_the_recent_tail_and_the_tail_stays_live(self):
        from coach_context import cache_older_turns
        msgs = [{"role": "user" if i % 2 == 0 else "assistant", "content": f"turn {i}"} for i in range(10)]
        out = cache_older_turns(msgs, keep_recent=6)
        self.assertEqual(out[3]["content"], [{"type": "text", "text": "turn 3", "cache_control": {"type": "ephemeral", "ttl": "1h"}}])
        self.assertTrue(all(isinstance(m["content"], str) for m in out[4:]))
        self.assertTrue(all(isinstance(m["content"], str) for m in out[:3]))
        self.assertEqual(msgs[3]["content"], "turn 3", "the input is not mutated")

    def test_a_short_conversation_is_left_alone(self):
        from coach_context import cache_older_turns
        msgs = [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}]
        self.assertEqual(cache_older_turns(msgs, keep_recent=6), msgs)


class BodyweightStepTests(unittest.TestCase):
    """C14: a bodyweight-plus lift's step is sized on the athlete plus the plate."""

    def test_the_step_is_the_plates_inside_six_percent_of_the_lifted_load(self):
        from prescribe import COMPOUND, _increment
        self.assertEqual(_increment(COMPOUND, True, None, lifted=92.0), 5.0)    # 5.52 -> two plates
        self.assertEqual(_increment(COMPOUND, True, None, lifted=40.0), 2.5)    # 2.4 -> one plate floor
        self.assertEqual(_increment(COMPOUND, True, None, lifted=None), 2.5)
        self.assertEqual(_increment(COMPOUND, True, 5.0, lifted=40.0), 5.0)     # the lift's own step still wins

    def test_dips_step_two_plates_when_the_athlete_is_known(self):
        from prescribe import COMPOUND, PriorSet, prescribe_exercise
        with_kg = prescribe_exercise("Dips", 2, COMPOUND, 2, PriorSet(20.0, 10, 8.0, bodyweight=True), set(), athlete_kg=82.0)
        without = prescribe_exercise("Dips", 2, COMPOUND, 2, PriorSet(20.0, 10, 8.0, bodyweight=True), set())
        self.assertEqual(with_kg.working[0].weight_kg, 25.0)
        self.assertEqual(without.working[0].weight_kg, 22.5)


class BulkRateTests(unittest.TestCase):
    """C16: the bulk rate in the Sunday report and, above the guide, one line to the coach."""

    WEIGH = [("2026-08-11", 80.8), ("2026-08-18", 81.1), ("2026-08-25", 81.4), ("2026-09-01", 81.8),
             ("2026-09-08", 82.1), ("2026-09-15", 82.4), ("2026-09-22", 82.6)]

    def test_the_rate_is_the_slope_over_the_window(self):
        from block_review import bulk_rate
        r = bulk_rate(self.WEIGH, weeks=6)
        self.assertAlmostEqual(r["kg_per_week"], 0.3, delta=0.02)
        self.assertAlmostEqual(r["pct_per_week"], 0.37, delta=0.03)
        self.assertIsNone(bulk_rate(self.WEIGH[:3]))

    def test_the_report_and_the_coach_line(self):
        from block_review import bulk_rate, bulk_rate_line, format_bulk_rate
        r = bulk_rate(self.WEIGH, weeks=6)
        self.assertIn("inside the guide", format_bulk_rate(r))
        self.assertIsNone(bulk_rate_line(r))
        fast = bulk_rate([("2026-08-11", 80.0), ("2026-08-18", 80.8), ("2026-08-25", 81.6), ("2026-09-01", 82.4), ("2026-09-08", 83.2)], weeks=6)
        self.assertIn("above the ~0.5%/week guide", format_bulk_rate(fast))
        self.assertIn("BULK RATE: +0.80 kg/week", bulk_rate_line(fast))


class BlockSlotsTests(unittest.TestCase):
    """U6: the review window follows the block length."""

    def test_a_five_week_block_is_twenty_sessions(self):
        import blocks
        with patch("data.block_weeks", return_value=5):
            self.assertEqual(blocks.block_slots(), 20)
            sessions = [{"date": f"2026-09-{d:02d}", "mesocycle_week": None, "mesocycle_day": None} for d in range(1, 26)]
            since, until = blocks.ended_block_range(sessions, "2026-09-25")
            self.assertEqual((since, until), ("2026-09-06", "2026-09-25"))
        with patch("data.block_weeks", return_value=4):
            self.assertEqual(blocks.block_slots(), 16)


class HomeAskTests(unittest.TestCase):
    """F4: the programme's deferrals become Home cards with the default stated."""

    def test_a_below_range_lift_asks_for_a_one_step_cut(self):
        from prescribe import ISOLATION, PriorSet, prescribe_exercise
        p = prescribe_exercise("Reverse Cable Fly", 2, ISOLATION, 2, PriorSet(15.0, 7, 8.0, step=2.5), set())
        self.assertEqual(p.asks, [{"kind": "cut", "exercise": "Reverse Cable Fly", "to": 12.5, "why": "ran 7 against 8-16 at 15kg"}])

    def test_a_stall_logged_harder_than_the_card_asks_for_a_cut(self):
        from prescribe import ISOLATION, PriorSet, prescribe_exercise, targets_for
        over = targets_for(2)["top"] + 1
        p = prescribe_exercise("Hammer Curl", 3, ISOLATION, 2, PriorSet(20.0, 9, over, held=4, step=2.0), set())
        self.assertEqual(len(p.asks), 1)
        self.assertEqual((p.asks[0]["kind"], p.asks[0]["to"]), ("cut", 18.0))

    def test_the_rollout_at_its_top_asks_for_the_standing_rung(self):
        from prescribe import ISOLATION, PriorSet, prescribe_exercise
        p = prescribe_exercise("Ab Wheel Rollout", 2, ISOLATION, 2, PriorSet(None, 12, 7.0, bodyweight=True), set())
        self.assertEqual(p.asks[0]["kind"], "rung")
        self.assertEqual(p.asks[0]["to"], "Standing Ab Wheel Rollout")
        standing = prescribe_exercise("Standing Ab Wheel Rollout", 2, ISOLATION, 2, PriorSet(None, 10, 7.0, bodyweight=True), set())
        self.assertEqual(standing.asks, [], "a farther stop is the same lift: no card")

    def test_the_lines_and_the_card_text(self):
        from decisions import RECORDABLE_RE, ask_line, describe, kind_of, subject_of
        cut = ask_line({"kind": "cut", "exercise": "Reverse Cable Fly", "to": 12.5, "why": "ran 7 against 8-16 at 15kg"})
        self.assertEqual(cut, "Cut: Reverse Cable Fly | to 12.5kg | ran 7 against 8-16 at 15kg")
        self.assertIsNotNone(RECORDABLE_RE.match(cut))
        self.assertEqual((kind_of(cut), subject_of(cut)), ("cut", "reversecablefly"))
        self.assertIn("open the next session at 12.5 kg", describe(cut))
        rung = ask_line({"kind": "rung", "exercise": "Ab Wheel Rollout", "to": "Standing Ab Wheel Rollout", "why": "lever"})
        self.assertEqual(kind_of(rung), "substitute")

    def test_asks_are_written_once(self):
        import decisions
        asks = [{"kind": "cut", "exercise": "Reverse Cable Fly", "to": 12.5, "why": "ran 7 against 8-16 at 15kg"},
                {"kind": "rung", "exercise": "Ab Wheel Rollout", "to": "Standing Ab Wheel Rollout", "why": "lever"}]
        fake = _Fake()
        with patch("decisions.get_supabase", return_value=fake):
            self.assertEqual(decisions.propose_asks(asks), 2)
            self.assertEqual(decisions.propose_asks(asks), 0)
        kinds = sorted(r["kind"] for r in fake.store["decision_captures"])
        self.assertEqual(kinds, ["cut", "substitute"])

    def test_a_recorded_cut_opens_the_next_session_at_the_named_load_then_is_spent(self):
        from progression import find_current_loads
        rows = [r for s in _sessions("Reverse Cable Fly", [12.5, 15.0, 15.0], reps=7).values() for r in s]
        answers = {"reversecablefly": {"to": 12.5, "answered_at": "2026-09-03T20:00:00+00:00"}}
        [row] = find_current_loads(rows, None, answers)
        self.assertEqual((row["load"], row["reps"], row["cut"]["from"]), (12.5, None, 15.0))
        # A session logged after the answer spends it.
        rows2 = rows + [r for r in _sessions("Reverse Cable Fly", [12.5]).values() for r in s] if False else rows + [
            {"exercise": "Reverse Cable Fly", "actual_weight_kg": "12.5", "actual_reps": "10", "is_warmup": False, "set_number": "1", "date": "2026-09-04"}]
        [row2] = find_current_loads(rows2, None, answers)
        self.assertEqual((row2["load"], row2["cut"]), (12.5, None))

    def test_the_card_names_the_recorded_cut(self):
        from programme import _ladder_notes
        notes = _ladder_notes((("Reverse Cable Fly", 2, "isolation"),),
                              [{"exercise": "Reverse Cable Fly", "cut": {"to": 12.5, "from": 15.0}, "off_ladder": None}])
        self.assertIn("Opens at 12.5kg, the cut you recorded on Home (was 15kg)", notes["reversecablefly"])


class RestFloorTextTests(unittest.TestCase):
    """The card reads the reply's blocks: their Rest is floored whichever path wrote them."""

    def test_rest_lines_under_the_floor_are_raised_per_lift_kind(self):
        from reply_contract import floor_rest_text
        reply = ("*Machine Chest Press*\nWarm-up: 93kg x10\nWorking Set: 149kg x6-10 RPE8 | Tempo: 3-1-2 | Rest: 2min\n"
                 "Back-off: 133kg x10-12 RPE8\n\n*Cable Lateral Raise*\nWorking Set: 12.5kg x15-17 RPE8 | Rest: 90s\n\n"
                 "*Face Pulls*\nWorking Set: 47.5kg x11-12 RPE8 | Rest: 3min\n")
        out, notes = floor_rest_text(reply)
        self.assertIn("149kg x6-10 RPE8 | Tempo: 3-1-2 | Rest: 3min", out)
        self.assertIn("12.5kg x15-17 RPE8 | Rest: 150s", out)
        self.assertIn("47.5kg x11-12 RPE8 | Rest: 3min", out)
        self.assertEqual(notes, ["Machine Chest Press: rest 120s → 180s", "Cable Lateral Raise: rest 90s → 150s"])

    def test_prose_without_blocks_is_untouched(self):
        from reply_contract import floor_rest_text
        self.assertEqual(floor_rest_text("Rest: 2min is plenty between sets of chat."), ("Rest: 2min is plenty between sets of chat.", []))


class RampFollowsTopTests(unittest.TestCase):
    """The ramp is a function of TODAY's working weight, whoever set it. On 26 Sep
    the coach cut the Machine Chest Press 165 -> 149 and the card's third warm-up
    was 149 x3: the programme's 165 ramp, unrescaled."""

    RAMP = [(93.0, 10), (125.0, 5), (149.0, 3)]

    def test_a_ramp_reaching_the_top_set_is_rederived_on_the_ladder(self):
        from prescribe import rescale_ramp
        self.assertEqual(rescale_ramp(self.RAMP, 149.0, 8.0), [(85.0, 10), (109.0, 5), (133.0, 3)])
        self.assertEqual(rescale_ramp(self.RAMP, 157.0, 8.0), [(85.0, 10), (117.0, 5), (141.0, 3)])

    def test_a_ramp_that_stops_short_of_the_top_is_left_alone(self):
        from prescribe import rescale_ramp
        self.assertIsNone(rescale_ramp(self.RAMP, 165.0, 8.0))
        self.assertIsNone(rescale_ramp([(60.0, 10), (85.0, 5)], 100.0, None))
        self.assertIsNone(rescale_ramp([], 100.0, None))

    def test_the_plan_path_rescales_the_typed_ramp(self):
        from plan import ExercisePlan, SessionPlan, SetPlan, warmup_follows_top
        plan = SessionPlan(opening="", exercises=[
            ExercisePlan(exercise="Machine Chest Press", decision="adjust", reason="", working=[SetPlan(149.0, 8, 12, 8.0)],
                         backoff=[], warmup=list(self.RAMP), rest_seconds=180)])
        notes = warmup_follows_top(plan, {"Machine Chest Press": 8.0})
        self.assertEqual(plan.exercises[0].warmup, [(85.0, 10), (109.0, 5), (133.0, 3)])
        self.assertEqual(len(notes), 1)

    def test_the_text_path_rescales_the_warm_up_line_of_its_own_block_only(self):
        from reply_contract import rescale_ramp_text
        reply = ("*Machine Chest Press*\nWarm-up: 93kg x10, 125kg x5, 149kg x3\nWorking Set: 149kg x8-12 RPE8 | Rest: 3min\n"
                 "Back-off: 125kg x10-12 RPE7\n\n*Shoulder Press*\nWarm-up: 40kg x8\nWorking Set: 65kg x8-12 RPE8 | Rest: 3min\n")
        out, notes = rescale_ramp_text(reply, {"Machine Chest Press": 8.0})
        self.assertIn("Warm-up: 85kg x10, 109kg x5, 133kg x3\nWorking Set: 149kg", out)
        self.assertIn("Warm-up: 40kg x8\nWorking Set: 65kg", out)
        self.assertEqual(len(notes), 1)
        self.assertEqual(rescale_ramp_text("No blocks here, warm-up: 149kg x3.", {}), ("No blocks here, warm-up: 149kg x3.", []))


class CutBoundTests(unittest.TestCase):
    """A coach cut below the programme's number is one step of the lift unless
    the reason names pain (the athlete's call, 26 Sep 2026: 165 x5 -> 157, not 149)."""

    PROPOSAL = {"Machine Chest Press": ("*Machine Chest Press*\nWarm-up: 93kg x10, 125kg x5, 149kg x3\n"
                                        "Working Set: 165kg x8-12 RPE8 | Rest: 3min\nBack-off: 141kg x10-12 RPE7, 141kg x8-10 RPE7")}
    TEMPLATE = "Session template:\nPush: Machine Chest Press 3\n"

    def _plan(self, reason):
        from plan import ExercisePlan, SessionPlan, SetPlan
        return SessionPlan(opening="", exercises=[
            ExercisePlan(exercise="Machine Chest Press", decision="adjust", reason=reason,
                         working=[SetPlan(149.0, 8, 12, 8.0)], backoff=[SetPlan(125.0, 10, 12, 7.0), SetPlan(125.0, 8, 10, 7.0)],
                         warmup=[(93.0, 10), (125.0, 5), (149.0, 3)], rest_seconds=180)])

    def test_a_two_step_cut_is_held_to_one_with_back_offs_and_ramp_following(self):
        from plan import validate
        plan = self._plan("last session ran 5 against 8-12 at 165, so the load comes down to bring the reps back in")
        problems = validate(plan, "Push", self.TEMPLATE, proposal=self.PROPOSAL, steps={"Machine Chest Press": 8.0})
        e = plan.exercises[0]
        self.assertEqual([s.load_kg for s in e.working], [157.0])
        self.assertEqual([b.load_kg for b in e.backoff], [133.0, 133.0])
        self.assertEqual(e.warmup, [(85.0, 10), (117.0, 5), (141.0, 3)])
        self.assertIn("held to one step, 157kg", e.reason)
        self.assertEqual([p for p in problems if "under the programme" in p], [])

    def test_pain_in_the_reason_keeps_the_deeper_cut(self):
        from plan import bound_cut, _normalise_exercise
        plan = self._plan("the left shoulder was painful on the last two presses, so two steps off today")
        self.assertEqual(bound_cut(plan, {_normalise_exercise(k): v for k, v in self.PROPOSAL.items()},
                                   {"Machine Chest Press": 8.0}), [])
        self.assertEqual(plan.exercises[0].working[0].load_kg, 149.0)

    def test_a_one_step_cut_and_an_accept_are_untouched(self):
        from plan import ExercisePlan, SessionPlan, SetPlan, bound_cut, _normalise_exercise
        by_key = {_normalise_exercise(k): v for k, v in self.PROPOSAL.items()}
        plan = self._plan("ran 5 against 8-12, one step off")
        plan.exercises[0].working = [SetPlan(157.0, 8, 12, 8.0)]
        self.assertEqual(bound_cut(plan, by_key, {"Machine Chest Press": 8.0}), [])
        plan = SessionPlan(opening="", exercises=[ExercisePlan(exercise="Machine Chest Press", decision="accept", reason="",
                                                               working=[SetPlan(165.0, 8, 12, 8.0)], backoff=[], rest_seconds=180)])
        self.assertEqual(bound_cut(plan, by_key, {"Machine Chest Press": 8.0}), [])


class StretchedRangeHeldTests(unittest.TestCase):
    """C15 in code: the coach may not take the step a stretched range refused."""

    PROPOSAL = {"Cable Lateral Raise": ("*Cable Lateral Raise*\nWorking Set: 12.5kg x15-17 RPE8 | Rest: 150s\n"
                                        "Back-off: 10kg x12-15 RPE7, 10kg x10-13 RPE7")}
    TEMPLATE = "Session template:\nPush: Cable Lateral Raise 3\n"

    def _plan(self, load, reason="beat its range at or under target RPE three sessions straight"):
        from plan import ExercisePlan, SessionPlan, SetPlan
        return SessionPlan(opening="", exercises=[
            ExercisePlan(exercise="Cable Lateral Raise", decision="adjust", reason=reason,
                         working=[SetPlan(load, 15, 17, 8.0)], backoff=[SetPlan(12.5, 12, 15, 8.0), SetPlan(12.5, 10, 13, 8.0)],
                         rest_seconds=150)])

    def test_the_refused_step_is_held_to_the_programmes_load_and_range(self):
        from plan import validate
        plan = self._plan(15.0)
        validate(plan, "Push", self.TEMPLATE, proposal=self.PROPOSAL, steps={"Cable Lateral Raise": 2.5})
        e = plan.exercises[0]
        self.assertEqual((e.working[0].load_kg, e.working[0].reps_low, e.working[0].reps_high), (12.5, 15, 17))
        self.assertIn("held at 12.5kg", e.reason)

    def test_an_unstretched_range_and_a_hold_are_untouched(self):
        from plan import _normalise_exercise, hold_stretched
        by_key = {_normalise_exercise(k): v for k, v in self.PROPOSAL.items()}
        self.assertEqual(hold_stretched(self._plan(12.5), by_key), [])
        plain = {_normalise_exercise("Cable Lateral Raise"):
                 "*Cable Lateral Raise*\nWorking Set: 12.5kg x8-12 RPE8 | Rest: 150s\nBack-off: 10kg x12-15 RPE7, 10kg x10-13 RPE7"}
        plan = self._plan(15.0)
        self.assertEqual(hold_stretched(plan, plain), [])
        self.assertEqual(plan.exercises[0].working[0].load_kg, 15.0)


class PlanStandsForUnstartedLiftsTests(unittest.TestCase):
    """26 Sep 2026: the prose fallback wrote Face Pulls at 20kg ("no logged
    history") and plan_follows stored it as the plan; the card read 20kg over
    a LAST TIME of 47.5. A block for a lift not on the board is replaced by
    the plan's; the card's lift and Revised: blocks still move the plan."""

    STORED = {"working": [{"load_kg": 47.5, "reps_low": 8, "reps_high": 12, "rpe": 8}],
              "backoff": [{"load_kg": 37.5, "reps_low": 12, "reps_high": 15, "rpe": 7}],
              "tempo": "2-1-2", "rest_seconds": 150, "warmup": []}
    REPLY = ("13 reps at 12.5kg, top of range.\n\nOnto Face Pulls — no logged history, so this is a genuine feel-out.\n\n"
             "*Face Pulls*\nWorking Set: 20kg x8-12 RPE8 | Rest: 90s\nBack-off: 15kg x12-15 RPE7\n\nTell me how it feels.")

    def _ctx(self, reply, card="Cable Lateral Raise"):
        from reply_contract import ReplyContext
        return ReplyContext(reply=reply, reply_kind="prose", system_prompt="", today_type="Push", set_log_session="s1",
                            card_exercise=card, programme_out={"logged_today": ["Cable Lateral Raise"]})

    def test_a_block_for_a_lift_not_started_is_replaced_by_the_plans_and_not_stored(self):
        from unittest.mock import patch
        from reply_contract import plan_follows
        ctx = self._ctx(self.REPLY)
        with patch("plan.load_today_plan", return_value=self.STORED), patch("plan.record_plan_update") as rec:
            plan_follows(ctx)
        self.assertFalse(rec.called)
        self.assertIn("Working Set: 47.5kg x8-12 RPE8 | Tempo: 2-1-2 | Rest: 150s", ctx.reply)
        self.assertNotIn("20kg", ctx.reply)
        self.assertEqual(ctx.record, [{"step": "plan_follows", "action": "held", "detail": "Face Pulls"}])

    def test_the_cards_lift_and_a_revised_block_still_move_the_plan(self):
        from unittest.mock import patch
        from reply_contract import plan_follows
        with patch("plan.load_today_plan", return_value=self.STORED), patch("plan.record_plan_update") as rec:
            ctx = self._ctx(self.REPLY, card="Face Pulls")
            plan_follows(ctx)
            self.assertTrue(rec.called)
            self.assertIn("20kg", ctx.reply)
            rec.reset_mock()
            ctx = self._ctx(self.REPLY.replace("*Face Pulls*\n", "*Face Pulls*\nRevised: rear delt niggle\n"))
            plan_follows(ctx)
            self.assertTrue(rec.called)


class HistoryClaimTests(unittest.TestCase):
    """A lift the reply calls unlogged while the handed context carries its load gets a correction line."""

    CONTEXT = ("CURRENT WORKING LOADS — the load each lift is ON:\n  Face Pulls: 47.5kg x10 @RPE8 on 2026-09-22 — met target\n"
               "  Dips: 10kg x8 @RPE8 on 2026-09-22 — met target\n\nPEAK WEEK REFERENCE LOADS — x")

    def test_a_denied_history_is_corrected_from_the_context(self):
        from reply_contract import history_claims
        notes = history_claims("Onto Face Pulls — no logged history, so this is a genuine feel-out. 20kg's a guess.", self.CONTEXT)
        self.assertEqual(notes, ["Correction: Face Pulls has logged history — 47.5kg x10 on 2026-09-22 is the load it is on. "
                                 "Progress from that, not from a guess."])

    def test_no_claim_or_no_load_or_another_lift_means_no_note(self):
        from reply_contract import history_claims
        self.assertEqual(history_claims("Onto Face Pulls at 47.5kg.", self.CONTEXT), [])
        self.assertEqual(history_claims("Onto Face Pulls — no logged history.", "nothing here"), [])
        self.assertEqual(history_claims("Landmine Press — no logged history, feel it out.", self.CONTEXT), [])

    def test_the_step_appends_to_prose_only(self):
        from reply_contract import ReplyContext, history_claim
        ctx = ReplyContext(reply="Face Pulls — no logged history.", reply_kind="prose", system_prompt="", today_type="Push",
                           context_text=self.CONTEXT)
        history_claim(ctx)
        self.assertTrue(ctx.reply.endswith("Progress from that, not from a guess."))
        self.assertEqual(ctx.record[0]["action"], "corrected")
        ctx = ReplyContext(reply="Face Pulls — no logged history.", reply_kind="set_reply", system_prompt="", today_type="Push",
                           context_text=self.CONTEXT)
        history_claim(ctx)
        self.assertEqual(ctx.reply, "Face Pulls — no logged history.")


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
