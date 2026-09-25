"""The decision scorecard: the verdict rule, scoring a session, the coach's
outcomes block, the programme sizing to two lights, and the plan contract
asking about an unexamined accept."""
import json
import unittest
from unittest.mock import MagicMock, patch

try:
    import blockfix  # noqa: F401
except ImportError:  # run as tests.test_x (CI)
    from tests import blockfix  # noqa: F401
import scorecard
from scorecard import HEAVY, LIGHT, RIGHT, UNKNOWN, verdict


class VerdictTests(unittest.TestCase):
    def test_the_rule(self):
        self.assertEqual(verdict(15, 9, 6, 10, 9), LIGHT)      # Leg Press 245 x15 @9 against 6-10 @9
        self.assertEqual(verdict(11, 9.5, 6, 10, 9), LIGHT)    # half a point of slack
        self.assertEqual(verdict(11, 10, 6, 10, 9), RIGHT)     # over the range but a point over target: not light
        self.assertEqual(verdict(5, 9, 6, 10, 9), HEAVY)       # chest press 165 x5 @9 against 6-10
        self.assertEqual(verdict(8, 10.5, 6, 10, 9), HEAVY)    # in range, but more than a point over
        self.assertEqual(verdict(8, 8, 6, 10, 9), RIGHT)
        self.assertEqual(verdict(None, 8, 6, 10, 9), UNKNOWN)
        self.assertEqual(verdict(12, None, 6, 10, 9), LIGHT)   # no RPE: reps alone decide the light


def _supabase(decisions, sets, session):
    sb = MagicMock()
    def table(name):
        t = MagicMock()
        if name == "prescription_decisions":
            t.select.return_value.eq.return_value.order.return_value.execute.return_value.data = decisions
        elif name == "workout_sets":
            t.select.return_value.eq.return_value.execute.return_value.data = sets
        elif name == "workout_sessions":
            t.select.return_value.eq.return_value.limit.return_value.execute.return_value.data = [session]
        elif name == "decision_outcomes":
            t.upsert.return_value.execute.return_value.data = []
            sb.upserts.append(t)
        return t
    sb.upserts = []
    sb.table.side_effect = table
    return sb


class ScoreSessionTests(unittest.TestCase):
    SESSION = {"id": "s1", "date": "2026-09-14", "type": "Legs", "mesocycle_week": 3, "status": "completed"}
    PLAN = json.dumps({"working": [{"load_kg": 242.5, "reps_low": 6, "reps_high": 10, "rpe": 9.0}], "backoff": []})

    def test_scores_each_lift_against_range_and_programme(self):
        decisions = [
            {"exercise": "Leg Press", "decision": "accept", "top_load_kg": 242.5, "top_reps": 6, "top_rpe": 9,
             "programme_load_kg": 242.5, "plan": self.PLAN, "reason": "programme", "created_at": "1"},
            {"exercise": "Seated Leg Curl", "decision": "adjust", "top_load_kg": 106, "top_reps": 8, "top_rpe": 9,
             "programme_load_kg": 115, "plan": json.dumps({"working": [{"load_kg": 106, "reps_low": 8, "reps_high": 12, "rpe": 9.0}], "backoff": []}),
             "reason": "first hamstring loading", "created_at": "2"},
            {"exercise": "Weak-point: Hamstrings", "decision": "accept", "created_at": "0"},
        ]
        sets = [{"exercise": "Leg Press", "is_warmup": False, "actual_weight_kg": 245, "actual_reps": 15, "actual_rpe": 9, "set_number": 1, "phase": "working"},
                {"exercise": "Leg Press", "is_warmup": False, "actual_weight_kg": 196, "actual_reps": 10, "actual_rpe": 8, "set_number": 2, "phase": "backoff"},
                {"exercise": "Seated Leg Curl", "is_warmup": False, "actual_weight_kg": 110, "actual_reps": 16, "actual_rpe": 8, "set_number": 1},
                {"exercise": "Leg Press", "is_warmup": True, "actual_weight_kg": 125, "actual_reps": 5, "set_number": 0}]
        sb = _supabase(decisions, sets, self.SESSION)
        with patch("scorecard.get_supabase", return_value=sb):
            rows = scorecard.score_session("s1")
        by = {r["exercise"]: r for r in rows}
        self.assertEqual(set(by), {"Leg Press", "Seated Leg Curl"})
        self.assertEqual((by["Leg Press"]["verdict"], by["Leg Press"]["overrode"], by["Leg Press"]["lifted_reps"]), (LIGHT, False, 15))
        self.assertEqual((by["Seated Leg Curl"]["verdict"], by["Seated Leg Curl"]["overrode"],
                          by["Seated Leg Curl"]["programme_load_kg"], by["Seated Leg Curl"]["coach_load_kg"]), (LIGHT, True, 115.0, 106.0))
        self.assertEqual(len(sb.upserts), 2)

    def test_no_store_no_rows(self):
        with patch("scorecard.get_supabase", return_value=None):
            self.assertEqual(scorecard.score_session("s1"), [])


VERDICTS = {"legpress": [{"date": "2026-09-14", "verdict": LIGHT, "overrode": False, "coach_load_kg": 242.5, "lifted_load_kg": 245.0, "lifted_reps": 15, "lifted_rpe": 9.0},
                         {"date": "2026-09-09", "verdict": LIGHT, "overrode": False, "coach_load_kg": 240.0, "lifted_load_kg": 240.0, "lifted_reps": 13, "lifted_rpe": 8.0},
                         {"date": "2026-09-04", "verdict": RIGHT, "overrode": False, "coach_load_kg": 230.0, "lifted_load_kg": 230.0, "lifted_reps": 12, "lifted_rpe": 7.0}],
            "seatedlegcurl": [{"date": "2026-09-14", "verdict": LIGHT, "overrode": True, "coach_load_kg": 106.0, "lifted_load_kg": 110.0, "lifted_reps": 16, "lifted_rpe": 8.0},
                              {"date": "2026-09-09", "verdict": RIGHT, "overrode": False, "coach_load_kg": 105.0, "lifted_load_kg": 105.0, "lifted_reps": 15, "lifted_rpe": 8.0}]}


class ReadingTests(unittest.TestCase):
    def test_trends(self):
        self.assertTrue(scorecard.ran_light_twice(VERDICTS, "Leg Press"))
        self.assertFalse(scorecard.ran_light_twice(VERDICTS, "Seated Leg Curl"), "the light was an override's, not the programme's")
        self.assertEqual(scorecard.last_two_missed(VERDICTS, "Leg Press"), LIGHT)
        self.assertIsNone(scorecard.last_two_missed(VERDICTS, "Seated Leg Curl"))
        self.assertIsNone(scorecard.last_two_missed(VERDICTS, "Calf Raise"))

    def test_the_coach_reads_the_outcomes_and_the_record(self):
        rows = [r for v in VERDICTS.values() for r in v]
        text = scorecard.format_outcomes(["Leg Press", "Seated Leg Curl", "Calf Raise"], VERDICTS, scorecard.track_record(rows))
        self.assertIn("Leg Press: 2026-09-14 light (programme's 242.5kg → 245x15@9)", text)
        self.assertIn("LIGHT twice running", text)
        self.assertIn("your overrides: 0 right · 1 light · 0 heavy (n=1)", text)
        self.assertIn("the programme's numbers you accepted: 2 right · 2 light · 0 heavy (n=4)", text)
        self.assertNotIn("Calf Raise:", text)

    def test_the_report(self):
        rows = [{**r, "exercise": ex} for ex, v in (("Leg Press", VERDICTS["legpress"]), ("Seated Leg Curl", VERDICTS["seatedlegcurl"])) for r in v]
        text = scorecard.format_report(rows, 14)
        self.assertIn("5 lifts scored", text)
        self.assertIn("- Leg Press: right → light → light", text)
        self.assertIn("Nothing scored", scorecard.format_report([], 14))


class ProgrammeLearnsTests(unittest.TestCase):
    def test_two_lights_size_the_next_number_up_one_step(self):
        from prescribe import COMPOUND, PriorSet, prescribe_session
        from programme import sized_to_outcomes
        plan = (("Leg Press", 3, COMPOUND),)
        history = {"Leg Press": PriorSet(245.0, 9, 9.0, week=3, step=2.5)}   # mid-range: the rule alone reopens at 245
        [p] = prescribe_session(plan, 1, history, peak_history=history)
        base = p.working[0].weight_kg
        self.assertEqual(base, 245.0)
        [q] = sized_to_outcomes([p], VERDICTS, 1, None)
        self.assertEqual(q.working[0].weight_kg, base + 2.5)
        self.assertTrue(q.reasons[0].startswith("Sized to the outcomes"))
        self.assertTrue(all(b.weight_kg < q.working[0].weight_kg for b in q.backoff))
        # and the pre-flight lets a sized increase through
        from preflight import enforce
        out, findings = enforce([q], history, history, 1)
        self.assertEqual(out[0].working[0].weight_kg, base + 2.5, findings)

    def test_not_on_top_of_a_number_already_sized_to_this_sessions_miss(self):
        from prescribe import COMPOUND, PriorSet, prescribe_session
        from programme import sized_to_outcomes
        plan = (("Leg Press", 3, COMPOUND),)
        history = {"Leg Press": PriorSet(245.0, 15, 9.0, week=3, step=2.5)}   # 5 over the range: sized already
        [p] = prescribe_session(plan, 1, history, peak_history=history)
        self.assertTrue(any("sized" in r.lower() for r in p.reasons))
        self.assertEqual(sized_to_outcomes([p], VERDICTS, 1, None)[0].working[0].weight_kg, p.working[0].weight_kg)

    def test_not_on_the_deload_and_not_without_a_trend(self):
        from prescribe import COMPOUND, PriorSet, prescribe_session
        from programme import sized_to_outcomes
        plan = (("Leg Press", 3, COMPOUND),)
        history = {"Leg Press": PriorSet(245.0, 15, 9.0, week=3)}
        [p] = prescribe_session(plan, 4, history, peak_history=history)
        self.assertEqual(sized_to_outcomes([p], VERDICTS, 4, None)[0].working[0].weight_kg, p.working[0].weight_kg)
        [p1] = prescribe_session(plan, 1, history, peak_history=history)
        self.assertEqual(sized_to_outcomes([p1], {}, 1, None)[0].working[0].weight_kg, p1.working[0].weight_kg)


class AcceptIsADecisionTests(unittest.TestCase):
    def test_an_unexamined_accept_on_a_trend_is_asked_about_softly(self):
        from plan import validate
        try:
            from test_plan_contract import _legs_plan, _legs_proposal, _prompt, parse_plan
        except ImportError:
            from tests.test_plan_contract import _legs_plan, _legs_proposal, _prompt, parse_plan
        plan = parse_plan(json.dumps(_legs_plan()), _legs_proposal())
        problems = validate(plan, "Legs", _prompt(), _legs_proposal(), verdicts=VERDICTS)
        hits = [p for p in problems if "came in LIGHT" in p]
        self.assertEqual(len(hits), 1, problems)
        self.assertTrue(hits[0].startswith("Leg Press:") and hits[0].endswith("[soft]"))
        # a reason on the accept answers it
        raw = _legs_plan(); raw["exercises"][0]["reason"] = "Knee is niggling; the programme's number stands today."
        plan = parse_plan(json.dumps(raw), _legs_proposal())
        self.assertEqual([p for p in validate(plan, "Legs", _prompt(), _legs_proposal(), verdicts=VERDICTS) if "came in" in p], [])


class OffTheRequestPathTests(unittest.TestCase):
    def test_the_context_build_only_reads_verdicts(self):
        import coach_context
        with patch("scorecard.score_pending") as scoring, patch("scorecard.recent_outcomes", return_value=[{"verdict": "light"}]):
            rows = coach_context._outcomes()
        scoring.assert_not_called()
        self.assertEqual(rows, [{"verdict": "light"}])

    def test_background_scoring_runs_on_a_thread(self):
        import threading
        done = threading.Event()
        def fake(days=14):
            done.set(); return 3
        with patch("scorecard.score_pending", side_effect=fake):
            scorecard.score_in_background()
            self.assertTrue(done.wait(2))


class ParityTests(unittest.TestCase):
    """The programme against the coach, lift by lift (26 Sep 2026)."""

    ROWS = [
        {"date": "2026-09-20", "exercise": "Leg Press", "overrode": False, "verdict": RIGHT,
         "programme_load_kg": 240.0, "coach_load_kg": 240.0, "lifted_load_kg": 240.0, "lifted_reps": 8},
        {"date": "2026-09-20", "exercise": "Cable Row", "overrode": False, "verdict": LIGHT,
         "programme_load_kg": 90.0, "coach_load_kg": 90.0, "lifted_load_kg": 90.0, "lifted_reps": 13},
        # coach cut the load; the card still came out light -> the programme's higher number was closer
        {"date": "2026-09-21", "exercise": "Seated Leg Curl", "overrode": True, "verdict": LIGHT,
         "programme_load_kg": 115.0, "coach_load_kg": 106.0, "lifted_load_kg": 106.0, "lifted_reps": 16, "reason": "first hamstring loading"},
        # coach raised it and the card was right
        {"date": "2026-09-22", "exercise": "Lat Pulldown", "overrode": True, "verdict": RIGHT,
         "programme_load_kg": 85.0, "coach_load_kg": 90.0, "lifted_load_kg": 90.0, "lifted_reps": 8, "reason": "ready to load"},
        # coach raised it, card heavy, programme lower -> programme closer
        {"date": "2026-09-23", "exercise": "Shoulder Press", "overrode": True, "verdict": HEAVY,
         "programme_load_kg": 70.0, "coach_load_kg": 80.0, "lifted_load_kg": 80.0, "lifted_reps": 3, "reason": "felt strong"},
        # coach cut it and the card was still heavy -> both wrong
        {"date": "2026-09-23", "exercise": "Dips", "overrode": True, "verdict": HEAVY,
         "programme_load_kg": 20.0, "coach_load_kg": 17.5, "lifted_load_kg": 17.5, "lifted_reps": 4, "reason": "shoulder"},
        {"date": "2026-09-23", "exercise": "Plank", "overrode": True, "verdict": UNKNOWN},
    ]

    def test_each_override_is_judged_by_direction(self):
        j = {r["exercise"]: scorecard.judge_override(r) for r in self.ROWS if r.get("overrode")}
        self.assertEqual(j["Seated Leg Curl"], scorecard.PROGRAMME_CLOSER)
        self.assertEqual(j["Lat Pulldown"], scorecard.COACH_RIGHT)
        self.assertEqual(j["Shoulder Press"], scorecard.PROGRAMME_CLOSER)
        self.assertEqual(j["Dips"], scorecard.BOTH_WRONG)
        self.assertEqual(j["Plank"], scorecard.UNJUDGED)

    def test_the_head_to_head_counts(self):
        h = scorecard.head_to_head(self.ROWS)
        self.assertEqual((h["scored"], h["agreed"], h["agreed_right"], h["overrides"]), (6, 2, 1, 4))
        self.assertEqual(h["judged"], {scorecard.PROGRAMME_CLOSER: 2, scorecard.COACH_RIGHT: 1, scorecard.BOTH_WRONG: 1})

    def test_the_report_section_reads_the_verdict_out(self):
        text = scorecard.format_head_to_head(self.ROWS, 28)
        self.assertIn("Agreed on 2 (33%)", text)
        self.assertIn("coach right 1 · programme would have been closer 2 · both wrong 1", text)
        self.assertIn("Parity:", text)
        self.assertIn("| 2026-09-21 | Seated Leg Curl | 115 | 106 | 106x16 | light | programme closer | first hamstring loading |", text)
        self.assertIn("Programme vs coach — parity", scorecard.format_report(self.ROWS, 28))

    def test_not_at_parity_names_the_count(self):
        rows = [dict(r) for r in self.ROWS]
        rows[2]["verdict"] = RIGHT   # the leg curl cut was right after all
        text = scorecard.format_head_to_head(rows, 28)
        self.assertIn("Not at parity: the coach was right on 2 of the 3 judged overrides", text)


class BackoffScoringTests(unittest.TestCase):
    """C24: the first back-off is scored beside the top set."""

    SESSION = {"id": "s2", "date": "2026-09-26", "type": "Pull", "mesocycle_week": 2, "status": "completed"}

    def test_the_back_off_gets_its_own_verdict(self):
        plan = json.dumps({"working": [{"load_kg": 90, "reps_low": 8, "reps_high": 10, "rpe": 8.0}],
                           "backoff": [{"load_kg": 70, "reps_low": 10, "reps_high": 12, "rpe": 8.0}]})
        decisions = [{"exercise": "Lat Pulldown", "decision": "accept", "top_load_kg": 90, "top_reps": 8, "top_rpe": 8,
                      "programme_load_kg": 90, "plan": plan, "reason": "programme", "created_at": "1"}]
        sets = [{"exercise": "Lat Pulldown", "is_warmup": False, "actual_weight_kg": 90, "actual_reps": 10, "actual_rpe": 8, "set_number": 1, "phase": "working"},
                {"exercise": "Lat Pulldown", "is_warmup": False, "actual_weight_kg": 70, "actual_reps": 15, "actual_rpe": 8, "set_number": 2, "phase": "backoff"}]
        sb = _supabase(decisions, sets, self.SESSION)
        with patch("scorecard.get_supabase", return_value=sb):
            [row] = scorecard.score_session("s2")
        self.assertEqual((row["verdict"], row["backoff_verdict"], row["backoff_lifted_reps"], row["backoff_reps_high"]), (RIGHT, LIGHT, 15, 12))

    def test_a_store_without_the_columns_takes_the_row_without_them(self):
        plan = json.dumps({"working": [{"load_kg": 90, "reps_low": 8, "reps_high": 10, "rpe": 8.0}],
                           "backoff": [{"load_kg": 70, "reps_low": 10, "reps_high": 12, "rpe": 8.0}]})
        decisions = [{"exercise": "Lat Pulldown", "decision": "accept", "top_load_kg": 90, "top_reps": 8, "top_rpe": 8,
                      "programme_load_kg": 90, "plan": plan, "reason": "programme", "created_at": "1"}]
        sets = [{"exercise": "Lat Pulldown", "is_warmup": False, "actual_weight_kg": 90, "actual_reps": 10, "actual_rpe": 8, "set_number": 1, "phase": "working"},
                {"exercise": "Lat Pulldown", "is_warmup": False, "actual_weight_kg": 70, "actual_reps": 15, "actual_rpe": 8, "set_number": 2, "phase": "backoff"}]
        sb = _supabase(decisions, sets, self.SESSION)
        calls = {"n": 0}
        def upsert(row, on_conflict=None):
            calls["n"] += 1
            m = MagicMock()
            if any(k.startswith("backoff_") for k in row):
                m.execute.side_effect = RuntimeError("column does not exist")
            return m
        orig = sb.table.side_effect
        def table(name):
            t = orig(name)
            if name == "decision_outcomes":
                t.upsert.side_effect = upsert
            return t
        sb.table.side_effect = table
        with patch("scorecard.get_supabase", return_value=sb):
            [row] = scorecard.score_session("s2")
        self.assertNotIn("backoff_verdict", row)
        self.assertEqual(calls["n"], 2)

    def test_the_report_counts_back_offs(self):
        rows = [{"date": "2026-09-26", "exercise": "Lat Pulldown", "overrode": False, "verdict": RIGHT, "backoff_verdict": LIGHT,
                 "programme_load_kg": 90.0, "coach_load_kg": 90.0, "lifted_load_kg": 90.0, "lifted_reps": 10},
                {"date": "2026-09-26", "exercise": "Cable Row", "overrode": False, "verdict": RIGHT, "backoff_verdict": HEAVY,
                 "programme_load_kg": 94.5, "coach_load_kg": 94.5, "lifted_load_kg": 94.5, "lifted_reps": 7}]
        text = scorecard.format_report(rows, 7)
        self.assertIn("Back-offs, scored the same way (C24): 0 right · 1 light · 1 heavy (n=2) — 50% came in under their range, 50% over.", text)
