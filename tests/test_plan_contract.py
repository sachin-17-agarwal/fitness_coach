"""The session plan as a contract: schema, checks, rendering, decisions, wiring."""

import json
import os
import unittest
from unittest.mock import patch

import plan as plan_module
from coach_parsing import parse_all_prescriptions
from plan import (PLAN_SCHEMA, ExercisePlan, SessionPlan, SetPlan, format_decisions,
                  is_plan_request, parse_plan, render_plan, request_session_plan,
                  validate)


def _prompt():
    with open("system_prompt.txt") as handle:
        return handle.read()


def _legs_plan(**overrides):
    """A correct Legs plan: 3/3/2/3/3/3 per the template, abs straight."""
    def ex(name, sets, load, decision="accept", reason="programme default", abs_=False, backoff_reps=(10, 8)):
        if abs_:
            return {"exercise": name, "decision": decision, "reason": reason, "warmup": [],
                    "working": [{"load_kg": load, "reps_low": 12, "reps_high": 15, "rpe": 8}] * sets,
                    "backoff": [], "tempo": "2-1-2", "rest_seconds": 90, "form_cue": "Flex the spine.", "note": ""}
        return {"exercise": name, "decision": decision, "reason": reason,
                "warmup": [{"load_kg": round(load * 0.6, 1), "reps": 8}],
                "working": [{"load_kg": load, "reps_low": 6, "reps_high": 10, "rpe": 8}],
                "backoff": [{"load_kg": round(load * 0.8, 1), "reps_low": r, "reps_high": r + 2, "rpe": 7}
                            for r in backoff_reps[:sets - 1]],
                "tempo": "3-1-2", "rest_seconds": 120, "form_cue": "Drive through the heel.", "note": ""}
    raw = {
        "opening": "HRV is on baseline, sleep 7.4h. Week 2: same loads, more reps.",
        "exercises": [
            ex("Leg Press", 3, 220.0),
            ex("Single Leg Sumo Press", 3, 120.0),
            ex("Leg Extension", 2, 100.0),
            ex("Seated Leg Curl", 3, 90.0),
            ex("45° Back Extension", 3, 20.0),
            ex("Machine Calf Raise", 5, 100.0, abs_=True),   # straight sets, like abs
        ],
        "carried": [],
    }
    raw.update(overrides)
    return raw


class SchemaTests(unittest.TestCase):
    def test_the_schema_stays_inside_the_supported_subset(self):
        allowed = {"type", "properties", "required", "additionalProperties", "items", "enum", "description"}
        def walk(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    if key not in ("properties",):
                        self.assertIn(key, allowed, f"unsupported keyword {key}")
                    if key == "properties":
                        for sub in value.values():
                            walk(sub)
                    else:
                        walk(value)
            elif isinstance(node, list):
                for item in node:
                    walk(item)
        walk(PLAN_SCHEMA)
        self.assertFalse(PLAN_SCHEMA["additionalProperties"])

    def test_a_plan_parses_into_typed_objects(self):
        p = parse_plan(json.dumps(_legs_plan()))
        self.assertEqual(len(p.exercises), 6)
        self.assertEqual(p.exercises[0].working[0], SetPlan(220.0, 6, 10, 8.0))


class ProposalRenderingTests(unittest.TestCase):
    def test_ab_work_is_shown_to_the_coach_as_straight_sets(self):
        import programme
        rows = [{"exercise": "Cable Crunch", "load": 25.0, "reps": 12, "rpe": 8.0},
                {"exercise": "Machine Calf Raise", "load": 100.0, "reps": 10, "rpe": 8.0}]
        props, _, _ = programme.build_proposal(_prompt(), "Cardio+Abs", 2, rows)
        text = programme.format_proposal(props, "Cardio+Abs", 2, {}, {})
        line = next(l for l in text.split("\n") if "Cable Crunch —" in l)
        self.assertIn("3 straight sets at one load", line)
        self.assertNotIn("back-off", line)
        props, _, _ = programme.build_proposal(_prompt(), "Legs", 2, rows)
        text = programme.format_proposal(props, "Legs", 2, {}, {})
        line = next(l for l in text.split("\n") if "Machine Calf Raise —" in l)
        self.assertIn("5 straight sets at one load", line, "calves run straight, like abs")


class ValidationTests(unittest.TestCase):
    PROMPT = None

    @classmethod
    def setUpClass(cls):
        cls.PROMPT = _prompt()

    def _problems(self, raw):
        return validate(parse_plan(json.dumps(raw)), "Legs", self.PROMPT)

    def test_a_correct_plan_has_no_problems(self):
        self.assertEqual(self._problems(_legs_plan()), [])

    def test_a_missing_template_exercise_is_named(self):
        raw = _legs_plan()
        raw["exercises"] = raw["exercises"][:-1]
        self.assertTrue(any("Machine Calf Raise" in p and "missing" in p for p in self._problems(raw)))

    def test_the_wrong_set_count_is_named(self):
        raw = _legs_plan()
        raw["exercises"][0]["backoff"] = raw["exercises"][0]["backoff"][:1]
        self.assertTrue(any("Leg Press" in p and "template of 3" in p for p in self._problems(raw)))

    def test_backoffs_must_share_a_load_and_descend(self):
        raw = _legs_plan()
        raw["exercises"][0]["backoff"][1]["load_kg"] = 170.0
        raw["exercises"][0]["backoff"][1]["reps_low"] = 12
        problems = self._problems(raw)
        self.assertTrue(any("SAME load" in p for p in problems))
        self.assertTrue(any("fewer reps" in p for p in problems))

    def test_ab_work_is_straight_sets(self):
        raw = _legs_plan()
        raw["exercises"][5]["backoff"] = [{"load_kg": 80, "reps_low": 12, "reps_high": 15, "rpe": 7}]
        self.assertTrue(any("straight sets" in p for p in self._problems(raw)), "calves are straight sets")

    def test_an_adjust_needs_a_reason(self):
        raw = _legs_plan()
        raw["exercises"][2]["decision"] = "adjust"
        raw["exercises"][2]["reason"] = "felt like it"
        self.assertTrue(any("without a reason" in p for p in self._problems(raw)))

    def test_accept_must_carry_the_programmes_numbers(self):
        computed = {"Leg Press": ("*Leg Press*\nWorking Set: 222.5kg x6-10 RPE8 | Rest: 2min\n"
                                  "Back-off: 178kg x10-12 RPE7, 178kg x8-10 RPE7")}
        problems = validate(parse_plan(json.dumps(_legs_plan())), "Legs", self.PROMPT, computed)
        self.assertTrue(any("marked accept but the numbers differ" in p for p in problems))
        raw = _legs_plan()
        raw["exercises"][0]["decision"] = "adjust"
        raw["exercises"][0]["reason"] = "Knee was sore on the last top set; holding 220 this week."
        self.assertEqual(validate(parse_plan(json.dumps(raw)), "Legs", self.PROMPT, computed), [])

    def test_a_back_off_at_the_top_sets_rpe_is_refused_on_any_exercise(self):
        raw = _legs_plan()
        for b in raw["exercises"][0]["backoff"]:
            b["rpe"] = 8
        self.assertTrue(any("LOWER RPE" in p for p in self._problems(raw)))

    def test_a_back_off_far_outside_the_band_is_named(self):
        raw = _legs_plan()
        for b in raw["exercises"][0]["backoff"]:
            b["load_kg"] = 120.0
        self.assertTrue(any("15-25%" in p for p in self._problems(raw)))


class CardioAbsTests(unittest.TestCase):
    PROMPT = None

    @classmethod
    def setUpClass(cls):
        cls.PROMPT = _prompt()

    @staticmethod
    def _plan(with_slots=True):
        def straight(name, sets, load, reason="programme default"):
            return {"exercise": name, "decision": "accept", "reason": reason, "warmup": [],
                    "working": [{"load_kg": load, "reps_low": 12, "reps_high": 15, "rpe": 8}] * sets,
                    "backoff": [], "tempo": "2-1-2", "rest_seconds": 90, "form_cue": "Brace.", "note": ""}
        exercises = [straight("Cable Crunch", 3, 25), straight("Hanging Leg Raises", 3, 0),
                     straight("Ab Wheel Rollout", 2, 0), straight("Pallof Press", 2, 15)]
        if with_slots:
            exercises.append({"exercise": "Overhead Cable Extension", "decision": "accept",
                              "reason": "Weak-point slot: triceps are the lowest muscle this week.",
                              "warmup": [], "working": [{"load_kg": 30, "reps_low": 8, "reps_high": 12, "rpe": 8}],
                              "backoff": [{"load_kg": 24, "reps_low": 12, "reps_high": 15, "rpe": 7},
                                          {"load_kg": 24, "reps_low": 10, "reps_high": 13, "rpe": 7}],
                              "tempo": "2-1-2", "rest_seconds": 90, "form_cue": "Elbows still.", "note": ""})
            exercises.append(straight("Machine Calf Raise", 3, 100,
                                      reason="Weak-point slot: calves sit under their band at 4.5 sets."))
        return {"opening": "Cardio is in: boxing, 32 min. Now the ab block.", "exercises": exercises, "carried": []}

    def test_a_cardio_abs_plan_with_both_slots_filled_is_clean(self):
        self.assertEqual(validate(parse_plan(json.dumps(self._plan())), "Cardio+Abs", self.PROMPT), [])

    def test_an_unplaced_block_leaves_the_slots_optional(self):
        """No block pick to hand: an empty slot is the normal day, not a gap."""
        problems = validate(parse_plan(json.dumps(self._plan(with_slots=False))), "Cardio+Abs", self.PROMPT)
        self.assertEqual(problems, [])

    def test_a_named_weak_point_left_unfilled_is_a_problem(self):
        problems = validate(parse_plan(json.dumps(self._plan(with_slots=False))), "Cardio+Abs", self.PROMPT,
                            weak_points=["Triceps"])
        self.assertTrue(any("weak-point slot(s) unfilled" in p and "Triceps" in p for p in problems))

    def test_a_slot_fill_must_say_which_muscle(self):
        raw = self._plan()
        raw["exercises"][4]["reason"] = "extra"
        problems = validate(parse_plan(json.dumps(raw)), "Cardio+Abs", self.PROMPT)
        self.assertTrue(any("which muscle" in p for p in problems))

    def test_when_the_block_names_no_weak_point_the_slots_stay_empty(self):
        no_slots = self._plan(with_slots=False)
        self.assertEqual(validate(parse_plan(json.dumps(no_slots)), "Cardio+Abs", self.PROMPT, weak_points=[]), [])
        filled = self._plan()
        problems = validate(parse_plan(json.dumps(filled)), "Cardio+Abs", self.PROMPT, weak_points=[])
        self.assertTrue(any("names no weak point" in p for p in problems))

    def test_one_named_weak_point_means_one_live_slot(self):
        raw = self._plan()
        raw["exercises"] = raw["exercises"][:5]          # only the triceps fill
        problems = validate(parse_plan(json.dumps(raw)), "Cardio+Abs", self.PROMPT, weak_points=["Triceps"])
        self.assertEqual(problems, [])

    def test_a_slot_fill_with_same_load_back_offs_is_refused(self):
        """The first live fill: 105kg x11 @8 with back-offs of 105kg x10 @8 and
        105kg x9 @8. Three top sets, not a top set and two back-offs."""
        raw = self._plan()
        raw["exercises"][4] = {"exercise": "Seated Leg Curl", "decision": "accept",
                               "reason": "Weak-point slot: hamstrings are the lowest muscle this block.",
                               "warmup": [{"load_kg": 58, "reps": 10}],
                               "working": [{"load_kg": 105, "reps_low": 11, "reps_high": 11, "rpe": 8}],
                               "backoff": [{"load_kg": 105, "reps_low": 10, "reps_high": 10, "rpe": 8},
                                           {"load_kg": 105, "reps_low": 9, "reps_high": 9, "rpe": 8}],
                               "tempo": "3-1-2", "rest_seconds": 90, "form_cue": "Full stretch.", "note": ""}
        problems = validate(parse_plan(json.dumps(raw)), "Cardio+Abs", self.PROMPT)
        self.assertTrue(any("LIGHTER than the top set" in p for p in problems))
        self.assertTrue(any("LOWER RPE" in p for p in problems))
        raw["exercises"][4]["backoff"] = [{"load_kg": 85, "reps_low": 12, "reps_high": 15, "rpe": 7},
                                          {"load_kg": 85, "reps_low": 10, "reps_high": 13, "rpe": 7}]
        self.assertEqual(validate(parse_plan(json.dumps(raw)), "Cardio+Abs", self.PROMPT), [])

    def test_the_abs_opening_is_a_plan_request(self):
        self.assertTrue(is_plan_request("Starting the ab work of my Cardio+Abs session. Cardio is done", "Cardio+Abs"))
        self.assertTrue(is_plan_request("Starting my Cardio+Abs session", "Cardio+Abs"))
        self.assertTrue(is_plan_request("I've finished cardio for my Cardio+Abs session — it is logged", "Cardio+Abs"))
        self.assertFalse(is_plan_request("Starting my Yoga session", "Yoga"))


class RenderTests(unittest.TestCase):
    def test_the_rendered_plan_parses_back_to_the_same_numbers(self):
        p = parse_plan(json.dumps(_legs_plan()))
        text = render_plan(p)
        cards = {c["exercise"]: c for c in parse_all_prescriptions(text)}
        self.assertEqual(len(cards), 6)
        press = cards["Leg Press"]
        self.assertEqual(press["working"][0], {"weight": 220.0, "reps": 6, "reps_high": 10, "rpe": 8.0})
        self.assertEqual(len(press["backoff"]), 2)
        self.assertEqual(press["tempo"], "3-1-2")
        self.assertEqual(len(press["warmup"]), 1)
        calves = cards["Machine Calf Raise"]
        self.assertEqual(len(calves["working"]), 5)
        self.assertNotIn("backoff", calves)
        self.assertIn("*45° Back Extension*", text)
        self.assertTrue(text.startswith("HRV is on baseline"))

    def test_the_note_travels_with_its_exercise_as_a_note_line(self):
        """Six unprefixed notes stacked in the opening as anonymous 'Week 2
        volume step' paragraphs. Prefixed, the card keeps each with its lift."""
        raw = _legs_plan()
        raw["exercises"][0]["note"] = "If 10 comes clean at RPE8, the next session steps to 225."
        text = render_plan(parse_plan(json.dumps(raw)))
        self.assertIn("Note: If 10 comes clean at RPE8", text)
        cards = {c["exercise"]: c for c in parse_all_prescriptions(text)}
        self.assertEqual(cards["Leg Press"]["note"], "If 10 comes clean at RPE8, the next session steps to 225.")
        self.assertNotIn("note", cards["Leg Extension"])

    def test_a_departure_travels_with_its_exercise_as_a_why_line(self):
        raw = _legs_plan()
        raw["exercises"][2]["decision"] = "adjust"
        raw["exercises"][2]["reason"] = "Machine steps in 5kg, so 100 stays and reps carry the progression."
        text = render_plan(parse_plan(json.dumps(raw)))
        self.assertIn("Why: Changed from the programme — Machine steps in 5kg", text)
        # With the programme's block to hand, the numbers come from the code.
        proposal = {"Leg Extension": "*Leg Extension*\nWorking Set: 102.5kg x8-12 RPE8 | Rest: 90s\nBack-off: 82kg x12-15 RPE7"}
        text = render_plan(parse_plan(json.dumps(raw)), proposal)
        self.assertIn("Why: Changed from the programme (programme 102.5kg x8-12 RPE8 + 1 back-off → "
                      "today 100kg x6-10 RPE8 + 1 back-off) — Machine steps in 5kg", text)
        card = {c["exercise"]: c for c in parse_all_prescriptions(text)}["Leg Extension"]
        self.assertTrue(card["why"].startswith("Changed from the programme"))
        self.assertNotIn("why", {c["exercise"]: c for c in parse_all_prescriptions(text)}["Leg Press"])

    def test_a_slot_fill_is_labelled_as_the_programme_asking_not_a_departure(self):
        raw = CardioAbsTests._plan()
        plan = parse_plan(json.dumps(raw))
        self.assertEqual(validate(plan, "Cardio+Abs", _prompt()), [])
        text = render_plan(plan)
        self.assertIn("Why: Weak-point slot — Weak-point slot: triceps", text)
        self.assertNotIn("Changed from the programme", text)

    def test_bodyweight_renders_in_the_prompts_spelling(self):
        e = ExercisePlan("Dips", "accept", "default", warmup=[(0, 8)],
                         working=[SetPlan(5.0, 6, 10, 8.0)], backoff=[SetPlan(0.0, 10, 12, 7.0)],
                         tempo="2-1-2", rest_seconds=120)
        text = render_plan(SessionPlan("", [e]))
        self.assertIn("Warm-up: BW x8", text)
        self.assertIn("Working Set: BW + 5kg x6-10 RPE8", text)
        self.assertIn("Back-off: BW x10-12 RPE7", text)


class LiveWorkoutCardioTests(unittest.TestCase):
    def test_imported_cardio_is_stated_as_a_fact(self):
        import workout

        class Q:
            def __init__(self, rows): self.rows = rows
            def __getattr__(self, name):
                return lambda *a, **k: self
            def execute(self): return type("R", (), {"data": self.rows})()

        class S:
            def table(self, name):
                if name == "workout_sessions":
                    return Q([{"type": "Cardio+Abs"}])
                return Q([{"exercise": "Boxing", "set_number": 1, "actual_weight_kg": 0, "actual_reps": 32,
                           "actual_rpe": None, "is_warmup": False, "notes": "cardio · hk:ABC · 310kcal",
                           "logged_at": "2026-09-06T08:12:00Z"}])

        with patch.object(workout, "get_supabase", return_value=S()), \
             patch.object(workout, "get_session_duration_minutes", return_value=5):
            block = workout.get_workout_context({"workout_mode": "active", "current_session_id": "sid"})
        self.assertIn("Cardio logged this session", block)
        self.assertIn("Boxing — 32 min — imported from the Watch", block)
        self.assertIn("Working sets logged this session: 0", block)

    def test_no_cardio_on_a_cardio_day_is_stated_too(self):
        import workout

        class Q:
            def __init__(self, rows): self.rows = rows
            def __getattr__(self, name):
                return lambda *a, **k: self
            def execute(self): return type("R", (), {"data": self.rows})()

        class S:
            def table(self, name):
                return Q([{"type": "Cardio+Abs"}]) if name == "workout_sessions" else Q([])

        with patch.object(workout, "get_supabase", return_value=S()), \
             patch.object(workout, "get_session_duration_minutes", return_value=1):
            block = workout.get_workout_context({"workout_mode": "active", "current_session_id": "sid"})
        self.assertIn("NONE yet — the cardio half has not been logged or imported", block)


def _legs_proposal():
    """The programme's blocks for the same Legs day _legs_plan accepts."""
    def block(name, load, sets, straight=False):
        if straight:
            return (f"*{name}*\nWorking Set: " + ", ".join([f"{load:g}kg x12-15 RPE8"] * sets)
                    + " | Tempo: 2-1-2 | Rest: 90s\nForm: Full stretch.\n")
        bo = ", ".join(f"{round(load * 0.8, 1):g}kg x{r}-{r + 2} RPE7" for r in (10, 8)[:sets - 1])
        return (f"*{name}*\nWarm-up: {round(load * 0.6, 1):g}kg x8\n"
                f"Working Set: {load:g}kg x6-10 RPE8 | Tempo: 3-1-2 | Rest: 2min\n"
                f"Back-off: {bo}\nForm: Drive through the heel.\n")
    return {
        "Leg Press": block("Leg Press", 220.0, 3),
        "Single Leg Sumo Press": block("Single Leg Sumo Press", 120.0, 3),
        "Leg Extension": block("Leg Extension", 100.0, 2),
        "Seated Leg Curl": block("Seated Leg Curl", 90.0, 3),
        "45° Back Extension": block("45° Back Extension", 20.0, 3),
        "Machine Calf Raise": block("Machine Calf Raise", 100.0, 5, straight=True),
    }


class _FakeClient:
    """Returns canned plan texts in order and records every request."""

    def __init__(self, texts, stop="end_turn"):
        self.texts, self.requests, self.stop = list(texts), [], stop
        parent = self

        class Messages:
            def create(self, **kwargs):
                parent.requests.append(kwargs)
                text = parent.texts.pop(0)
                return type("R", (), {"content": [type("B", (), {"type": "text", "text": text})()],
                                      "stop_reason": parent.stop, "usage": None})()
        self.messages = Messages()


class RequestTests(unittest.TestCase):
    PROMPT = None

    @classmethod
    def setUpClass(cls):
        cls.PROMPT = _prompt()

    def test_a_valid_plan_is_accepted_on_the_first_call_with_thinking_on(self):
        """Quality first: the coach deliberates over the day. The speed came
        from terse accepts and the programme fallback, not from removing
        thought."""
        client = _FakeClient([json.dumps(_legs_plan())])
        plan, notes = request_session_plan(client, [{"type": "text", "text": "S"}],
                                           [{"role": "user", "content": "Starting my Legs session"}],
                                           "Legs", 2, self.PROMPT)
        self.assertIsNotNone(plan)
        req = client.requests[0]
        self.assertEqual(req["thinking"], {"type": "adaptive"})
        self.assertEqual(req["output_config"]["format"]["type"], "json_schema")
        self.assertEqual(req["output_config"]["format"]["schema"], PLAN_SCHEMA)
        self.assertEqual(req["output_config"]["effort"], "medium")
        self.assertEqual(req["max_tokens"], 8000)
        self.assertTrue(notes[-1].endswith("plan accepted"))

    def test_an_accept_may_omit_its_sets_and_gets_the_programmes(self):
        """Restating the programme's numbers on every accept was most of the
        output; the numbers are what accept means."""
        raw = _legs_plan()
        for e in raw["exercises"]:
            for key in ("warmup", "working", "backoff"):
                e.pop(key, None)
        client = _FakeClient([json.dumps(raw)])
        plan, notes = request_session_plan(client, [], [{"role": "user", "content": "go"}],
                                           "Legs", 2, self.PROMPT, proposal=_legs_proposal())
        self.assertIsNotNone(plan, notes)
        lp = next(e for e in plan.exercises if e.exercise == "Leg Press")
        self.assertEqual((lp.working[0].load_kg, lp.working[0].reps_low, lp.working[0].reps_high, lp.working[0].rpe),
                         (220.0, 6, 10, 8.0))
        self.assertEqual([b.load_kg for b in lp.backoff], [176.0, 176.0])
        self.assertEqual(lp.warmup, [(132.0, 8)])
        self.assertEqual(lp.rest_seconds, 120)
        calf = next(e for e in plan.exercises if e.exercise == "Machine Calf Raise")
        self.assertEqual(len(calf.working), 5)
        self.assertEqual(calf.rest_seconds, 90)

    def test_a_slow_first_attempt_is_not_given_a_retry(self):
        import time
        broken = _legs_plan()
        broken["exercises"][0]["backoff"] = broken["exercises"][0]["backoff"][:1]
        client = _FakeClient([json.dumps(broken), json.dumps(_legs_plan())])
        ticks = iter([0.0, 45.0, 46.0, 47.0])
        with patch("time.monotonic", side_effect=lambda: next(ticks, 48.0)):
            plan, notes = request_session_plan(client, [], [{"role": "user", "content": "go"}],
                                               "Legs", 2, self.PROMPT, proposal=_legs_proposal())
        self.assertEqual(len(client.requests), 1)
        self.assertTrue(any("no retry" in n for n in notes))
        # And the invalid exercise is the programme's, not a prose fallback.
        self.assertIsNotNone(plan)
        lp = next(e for e in plan.exercises if e.exercise == "Leg Press")
        self.assertEqual(len(lp.backoff), 2)
        self.assertEqual(lp.decision, "accept")
        self.assertIn("programme default", lp.reason)

    def test_the_retry_runs_at_low_effort(self):
        broken = _legs_plan()
        broken["exercises"][0]["backoff"] = broken["exercises"][0]["backoff"][:1]
        client = _FakeClient([json.dumps(broken), json.dumps(_legs_plan())])
        plan, notes = request_session_plan(client, [], [{"role": "user", "content": "go"}],
                                           "Legs", 2, self.PROMPT)
        self.assertIsNotNone(plan)
        self.assertEqual([r["output_config"]["effort"] for r in client.requests], ["medium", "low"])

    def test_a_broken_plan_is_handed_back_once_and_the_model_fixes_it(self):
        broken = _legs_plan()
        broken["exercises"][0]["backoff"] = broken["exercises"][0]["backoff"][:1]
        client = _FakeClient([json.dumps(broken), json.dumps(_legs_plan())])
        plan, notes = request_session_plan(client, [], [{"role": "user", "content": "go"}],
                                           "Legs", 2, self.PROMPT)
        self.assertIsNotNone(plan)
        self.assertEqual(len(client.requests), 2)
        fix = client.requests[1]["messages"][-1]["content"]
        self.assertIn("template of 3", fix)
        self.assertEqual(client.requests[1]["messages"][-2]["role"], "assistant")

    def test_two_broken_plans_with_no_programme_mean_no_plan(self):
        broken = _legs_plan()
        broken["exercises"] = broken["exercises"][:2]
        client = _FakeClient([json.dumps(broken), json.dumps(broken)])
        plan, notes = request_session_plan(client, [], [{"role": "user", "content": "go"}],
                                           "Legs", 2, self.PROMPT)
        self.assertIsNone(plan)
        self.assertEqual(len(client.requests), 2)

    def test_two_broken_plans_are_completed_by_the_programme(self):
        """The coach's valid decisions stand; what it left out is the
        programme's, labelled as such, and the athlete is told."""
        broken = _legs_plan()
        broken["exercises"] = broken["exercises"][:2]
        broken["exercises"][0]["decision"] = "adjust"
        broken["exercises"][0]["reason"] = "Left knee was sore on the last set last time, holding the load."
        broken["exercises"][0]["working"][0]["load_kg"] = 215.0
        client = _FakeClient([json.dumps(broken), json.dumps(broken)])
        plan, notes = request_session_plan(client, [], [{"role": "user", "content": "go"}],
                                           "Legs", 2, self.PROMPT, proposal=_legs_proposal())
        self.assertIsNotNone(plan, notes)
        names = [e.exercise for e in plan.exercises]
        self.assertEqual(set(names), set(_legs_proposal().keys()))
        lp = next(e for e in plan.exercises if e.exercise == "Leg Press")
        self.assertEqual((lp.decision, lp.working[0].load_kg), ("adjust", 215.0))
        filled = [e for e in plan.exercises if "missing from the coach's plan" in e.reason]
        self.assertEqual(len(filled), 4)
        self.assertTrue(any(n.startswith("filled from programme") for n in notes))
        self.assertTrue(plan.carried and "set aside" in plan.carried[-1])
        self.assertEqual(validate(plan, "Legs", self.PROMPT, _legs_proposal()), [])

    def test_unparseable_output_with_a_programme_is_the_programme(self):
        client = _FakeClient(["not json"])
        plan, notes = request_session_plan(client, [], [{"role": "user", "content": "go"}],
                                           "Legs", 2, self.PROMPT, proposal=_legs_proposal())
        self.assertIsNotNone(plan, notes)
        self.assertEqual(len(plan.exercises), 6)
        self.assertTrue(all(e.decision == "accept" for e in plan.exercises))

    def test_unparseable_output_with_no_programme_means_no_plan(self):
        client = _FakeClient(["not json"])
        plan, notes = request_session_plan(client, [], [{"role": "user", "content": "go"}],
                                           "Legs", 2, self.PROMPT)
        self.assertIsNone(plan)

    def test_usage_is_noted_when_the_response_carries_it(self):
        client = _FakeClient([json.dumps(_legs_plan())])
        usage = type("U", (), {"input_tokens": 1200, "cache_read_input_tokens": 28000,
                               "cache_creation_input_tokens": 0, "output_tokens": 900})()
        real_create = client.messages.create

        def create(**kw):
            r = real_create(**kw)
            r.usage = usage
            return r
        client.messages.create = create
        plan, notes = request_session_plan(client, [], [{"role": "user", "content": "go"}],
                                           "Legs", 2, self.PROMPT)
        self.assertTrue(any("cached 28000" in n and "out 900" in n for n in notes), notes)


class DownwardAdjustTests(unittest.TestCase):
    """The reported case: Leg Press opened at 207.5kg the week after 230kg
    x12 @7, with "hold last week's loads" as the reason — a rule misapplied,
    not a cause."""

    @classmethod
    def setUpClass(cls):
        cls.PROMPT = _prompt()

    def _plan_with(self, load, reason):
        raw = _legs_plan()
        raw["exercises"][0]["decision"] = "adjust"
        raw["exercises"][0]["reason"] = reason
        raw["exercises"][0]["working"][0]["load_kg"] = load
        raw["exercises"][0]["backoff"] = [dict(b, load_kg=round(load * 0.8, 1)) for b in raw["exercises"][0]["backoff"]]
        return parse_plan(json.dumps(raw), _legs_proposal())

    def test_a_cut_below_the_programme_without_a_cause_is_queried(self):
        from plan import is_soft
        plan = self._plan_with(195.0, "Week 2 is volume week, so holding last week's loads and chasing reps.")
        problems = validate(plan, "Legs", self.PROMPT, _legs_proposal())
        self.assertTrue(any("names no cause" in p for p in problems), problems)
        self.assertTrue(all(is_soft(p) for p in problems if "names no cause" in p))

    def test_a_cut_the_coach_stands_by_is_the_coachs_call(self):
        """Asked once for the cause; the coach repeats its plan; the cut
        stands and the programme does NOT replace it. Quality of coaching
        outranks the rulebook."""
        raw = _legs_plan()
        raw["exercises"][0]["decision"] = "adjust"
        raw["exercises"][0]["reason"] = "Week 2 is volume week, so holding last week's loads and chasing reps."
        raw["exercises"][0]["working"][0]["load_kg"] = 195.0
        raw["exercises"][0]["backoff"] = [dict(b, load_kg=156.0) for b in raw["exercises"][0]["backoff"]]
        client = _FakeClient([json.dumps(raw), json.dumps(raw)])
        plan, notes = request_session_plan(client, [], [{"role": "user", "content": "go"}],
                                           "Legs", 2, self.PROMPT, proposal=_legs_proposal())
        self.assertIsNotNone(plan, notes)
        self.assertEqual(len(client.requests), 2)
        self.assertIn("names no cause", client.requests[1]["messages"][-1]["content"])
        lp = next(e for e in plan.exercises if e.exercise == "Leg Press")
        self.assertEqual((lp.decision, lp.working[0].load_kg), ("adjust", 195.0))
        self.assertTrue(any(n.startswith("coach's call stands") for n in notes), notes)

    def test_a_cut_with_a_cause_stands(self):
        plan = self._plan_with(195.0, "HRV 35 against a 39 baseline and 5.8h sleep — taking 10% off the top set today.")
        self.assertEqual(validate(plan, "Legs", self.PROMPT, _legs_proposal()), [])

    def test_a_small_step_for_the_machines_increment_is_not_a_cut(self):
        plan = self._plan_with(215.0, "Nearest plate on the leg press.")
        self.assertEqual(validate(plan, "Legs", self.PROMPT, _legs_proposal()), [])


class DecisionLogTests(unittest.TestCase):
    def test_every_exercise_is_written_with_its_decision(self):
        written = []

        class Q:
            def __init__(self, rows=None): self.rows = rows
            def insert(self, rows): written.extend(rows); return self
            def execute(self): return type("R", (), {"data": self.rows or []})()

        class S:
            def table(self, name): return Q()

        with patch.object(plan_module, "get_supabase", return_value=S()):
            n = plan_module.save_decisions(parse_plan(json.dumps(_legs_plan())), "Legs", 2, "abc")
        self.assertEqual(n, 6)
        self.assertEqual({r["decision"] for r in written}, {"accept"})
        self.assertEqual(written[0]["top_load_kg"], 220.0)
        self.assertEqual(written[0]["session_type"], "Legs")

    def test_a_missing_table_costs_nothing(self):
        class Q:
            def insert(self, rows): return self
            def execute(self): raise RuntimeError("relation does not exist")

        class S:
            def table(self, name): return Q()

        with patch.object(plan_module, "get_supabase", return_value=S()):
            self.assertEqual(plan_module.save_decisions(parse_plan(json.dumps(_legs_plan())), "Legs", 2), 0)

    def test_decisions_in_force_read_as_the_answer_to_why(self):
        rows = [{"date": "2026-09-02", "session_type": "Push", "mesocycle_week": 1,
                 "exercise": "Cable Chest Fly", "reason": "One back-off: shoulder unhappy on the top set.",
                 "top_load_kg": 30.0, "top_reps": 10, "top_rpe": 8.0}]
        text = format_decisions(rows)
        self.assertIn("Cable Chest Fly (30kg x10 @8): One back-off", text)
        self.assertIn("do not invent another", text)


class WiringTests(unittest.TestCase):
    def test_only_a_strength_day_opening_is_a_plan_request(self):
        self.assertTrue(is_plan_request("Starting my Legs session. List today's full plan", "Legs"))
        self.assertTrue(is_plan_request("Resend today's Push plan", "Push"))
        self.assertTrue(is_plan_request("starting pull", "Pull"))
        self.assertFalse(is_plan_request("how did that set look?", "Legs"))
        self.assertFalse(is_plan_request("Leg Press 220kg x8 @8", "Legs"))

    def test_the_opening_reply_is_the_rendered_plan_and_falls_back_on_failure(self):
        import coach

        class Rec:
            def __init__(self): self.calls = []

        rec = Rec()

        class FakeMessages:
            def create(self, **kwargs):
                rec.calls.append(kwargs)
                if "output_config" in kwargs:
                    text = json.dumps(_legs_plan())
                else:
                    text = "prose reply"
                return type("R", (), {"content": [type("B", (), {"type": "text", "text": text})()],
                                      "usage": None, "stop_reason": "end_turn"})()

        fake_client = type("C", (), {"messages": FakeMessages()})()
        with patch("coach.get_anthropic_client", return_value=fake_client), \
             patch("coach.load_system_prompt", return_value=_prompt()), \
             patch("coach.build_context_block", return_value=("STABLE", "LIVE")), \
             patch("coach._truncate_history", side_effect=lambda h: h), \
             patch("coach.save_conversation_message"), \
             patch("coach.get_workout_state", return_value={}), \
             patch("coach.session_type_for", return_value="Legs"), \
             patch.object(plan_module, "save_decisions", return_value=6), \
             patch.dict(os.environ, {"PLAN_CONTRACT": "1"}):
            reply = coach.chat_with_coach("Starting my Legs session", [], {"mesocycle_week": 2},
                                          plan_request=True)
        self.assertIn("*Leg Press*", reply)
        self.assertIn("Working Set: 220kg x6-10 RPE8", reply)
        self.assertEqual(len(rec.calls), 1, "the plan call replaced the prose call")

        rec.calls.clear()

        class Broken(FakeMessages):
            def create(self, **kwargs):
                if "output_config" in kwargs:
                    rec.calls.append(kwargs)
                    raise RuntimeError("structured output unavailable")
                return super().create(**kwargs)

        broken_client = type("C", (), {"messages": Broken()})()
        with patch("coach.get_anthropic_client", return_value=broken_client), \
             patch("coach.load_system_prompt", return_value=_prompt()), \
             patch("coach.build_context_block", return_value=("STABLE", "LIVE")), \
             patch("coach._truncate_history", side_effect=lambda h: h), \
             patch("coach.save_conversation_message"), \
             patch("coach.get_workout_state", return_value={}), \
             patch("coach.session_type_for", return_value="Legs"), \
             patch.dict(os.environ, {"PLAN_CONTRACT": "1"}):
            reply = coach.chat_with_coach("Starting my Legs session", [], {"mesocycle_week": 2},
                                          plan_request=True)
        self.assertEqual(reply, "prose reply")
        self.assertEqual(len(rec.calls), 2, "the failed plan call fell back to prose")

    def test_the_switch_off_means_prose_as_before(self):
        import coach
        calls = []

        class FakeMessages:
            def create(self, **kwargs):
                calls.append(kwargs)
                return type("R", (), {"content": [type("B", (), {"type": "text", "text": "prose"})()],
                                      "usage": None, "stop_reason": "end_turn"})()

        fake_client = type("C", (), {"messages": FakeMessages()})()
        with patch("coach.get_anthropic_client", return_value=fake_client), \
             patch("coach.load_system_prompt", return_value="SYSTEM"), \
             patch("coach.build_context_block", return_value=("STABLE", "LIVE")), \
             patch("coach._truncate_history", side_effect=lambda h: h), \
             patch("coach.save_conversation_message"), \
             patch.dict(os.environ, {"PLAN_CONTRACT": "0"}):
            reply = coach.chat_with_coach("Starting my Legs session", [], {}, plan_request=True)
        self.assertEqual(reply, "prose")
        self.assertEqual(len(calls), 1)
        self.assertNotIn("output_config", calls[0])


if __name__ == "__main__":
    unittest.main()


class SetReplyTests(unittest.TestCase):
    """A mid-session change is a decision; the programme computes the sets."""

    STRAIGHT = {"working": [{"load_kg": 97.5, "reps_low": 9, "reps_high": 9, "rpe": 8}] * 3,
                "backoff": [], "tempo": "2-1-2", "rest_seconds": 90}
    TOPBACK = {"working": [{"load_kg": 220, "reps_low": 6, "reps_high": 10, "rpe": 8}],
               "backoff": [{"load_kg": 176, "reps_low": 10, "reps_high": 12, "rpe": 7},
                           {"load_kg": 176, "reps_low": 8, "reps_high": 10, "rpe": 7}],
               "tempo": "3-1-2", "rest_seconds": 120}

    @staticmethod
    def _reply(decision, steps=1, scope="remaining", reason="It came in at RPE 7 against 8.", revised=None):
        return {"note": "Read.", "decision": decision, "steps": steps, "scope": scope, "reason": reason,
                "revised": revised or {"load_kg": 0, "reps_low": 1, "reps_high": 1, "rpe": 8}}

    def test_heavier_moves_the_remaining_straight_sets_by_a_computed_step(self):
        from plan import render_set_reply
        text = render_set_reply(self._reply("heavier"), "Cable Crunch", self.STRAIGHT, done=1)
        card = parse_all_prescriptions(text)[0]
        self.assertEqual([s["weight"] for s in card["working"]], [97.5, 102.5, 102.5],
                         "5% of 97.5 rounds to a 5kg step; the logged set keeps its target")
        self.assertTrue(text.startswith("Read."))

    def test_next_only_moves_one_set(self):
        from plan import render_set_reply
        card = parse_all_prescriptions(render_set_reply(self._reply("more_reps", scope="next"),
                                                        "Cable Crunch", self.STRAIGHT, done=1))[0]
        self.assertEqual([s["reps"] for s in card["working"]], [9, 10, 9])

    def test_easier_on_a_back_off_is_a_rep_change_at_the_same_load(self):
        from plan import render_set_reply
        card = parse_all_prescriptions(render_set_reply(self._reply("easier"), "Leg Press", self.TOPBACK, done=1))[0]
        self.assertEqual(card["working"][0]["weight"], 220.0, "the logged top set is untouched")
        self.assertEqual([(b["weight"], b["reps"], b["rpe"]) for b in card["backoff"]],
                         [(176.0, 9, 6.0), (176.0, 7, 6.0)])

    def test_easier_under_five_reps_moves_the_load_instead(self):
        from plan import apply_set_decision, SetPlan
        moved = apply_set_decision("easier", 1, SetPlan(100.0, 5, 6, 8.0), "Leg Press")
        self.assertEqual((moved.load_kg, moved.reps_low, moved.rpe), (92.5, 5, 7.0))

    def test_hold_is_just_the_note(self):
        from plan import render_set_reply
        self.assertEqual(render_set_reply(self._reply("hold", reason=""), "Cable Crunch", self.STRAIGHT, done=1), "Read.")

    def test_there_is_no_move_that_makes_a_ramp_single_out_of_a_top_set(self):
        """The live failure: 108kg x10-12 @8 became 95kg x3 @6. No decision in
        the vocabulary reaches that set; the widest moves stay in shape."""
        from plan import SET_DECISIONS, apply_set_decision, SetPlan
        planned = SetPlan(108.0, 10, 12, 8.0)
        for decision in SET_DECISIONS:
            if decision == "revise":
                continue
            for steps in (1, 2):
                moved = apply_set_decision(decision, steps, planned, "Machine Calf Raise")
                self.assertGreaterEqual(moved.reps_low, 8, decision)
                self.assertGreaterEqual(moved.rpe, 6.0, decision)
                self.assertGreaterEqual(moved.load_kg, 97.0, decision)

    def test_a_revision_is_marked_and_needs_a_reason(self):
        from plan import render_set_reply, set_reply_problems
        bad = self._reply("revise", reason="pain", revised={"load_kg": 60, "reps_low": 15, "reps_high": 15, "rpe": 7})
        self.assertTrue(set_reply_problems(bad, "Leg Press", self.TOPBACK, done=1))
        good = self._reply("revise", reason="Knee complained on the top set; high-rep back-offs instead.",
                           revised={"load_kg": 120, "reps_low": 15, "reps_high": 15, "rpe": 7})
        text = render_set_reply(good, "Leg Press", self.TOPBACK, done=1)
        self.assertIn("Revised: Knee complained", text)
        card = parse_all_prescriptions(text)[0]
        self.assertTrue(card.get("revised"))
        self.assertEqual([b["weight"] for b in card["backoff"]], [120.0, 120.0])

    def test_a_change_without_a_reason_is_handed_back_then_falls_back(self):
        from plan import request_set_reply
        bad = self._reply("lighter", reason="")
        good = self._reply("lighter")
        client = _FakeClient([json.dumps(bad), json.dumps(good)])
        reply, notes = request_set_reply(client, [], [{"role": "user", "content": "Logged working set 1 of 3"}],
                                         "Leg Press", 1, 3, stored=self.TOPBACK)
        self.assertEqual(reply["decision"], "lighter")
        self.assertEqual(len(client.requests), 2)
        client = _FakeClient([json.dumps(bad), json.dumps(bad)])
        reply, notes = request_set_reply(client, [], [{"role": "user", "content": "x"}], "Leg Press", 1, 3,
                                         stored=self.TOPBACK)
        self.assertIsNone(reply)

    def test_the_request_runs_cheap_and_parses(self):
        from plan import request_set_reply, SET_REPLY_SCHEMA
        client = _FakeClient([json.dumps(self._reply("hold", reason=""))])
        reply, notes = request_set_reply(client, [], [{"role": "user", "content": "Logged working set 1 of 3"}],
                                         "Cable Crunch", 1, 3, stored=self.STRAIGHT)
        self.assertEqual(reply["decision"], "hold")
        req = client.requests[0]
        self.assertEqual(req["output_config"]["effort"], "low")
        self.assertEqual(req["output_config"]["format"]["schema"], SET_REPLY_SCHEMA)

    def test_a_logged_set_message_goes_through_the_contract_and_falls_back_without_a_plan(self):
        import coach
        calls = []

        class FakeMessages:
            def create(self, **kwargs):
                calls.append(kwargs)
                if "output_config" in kwargs:
                    text = json.dumps(SetReplyTests._reply("heavier"))
                else:
                    text = "prose reply"
                return type("R", (), {"content": [type("B", (), {"type": "text", "text": text})()],
                                      "usage": None, "stop_reason": "end_turn"})()

        fake_client = type("C", (), {"messages": FakeMessages()})()
        with patch("coach.get_anthropic_client", return_value=fake_client), \
             patch("coach.load_system_prompt", return_value=_prompt()), \
             patch("coach.build_context_block", return_value=("STABLE", "LIVE")), \
             patch("coach._truncate_history", side_effect=lambda h: h), \
             patch("coach.save_conversation_message"), \
             patch("coach.session_type_for", return_value="Cardio+Abs"), \
             patch.object(plan_module, "latest_exercise", lambda sid: "Cable Crunch"), \
             patch.object(plan_module, "logged_sets_for", lambda sid, ex: 1), \
             patch.object(plan_module, "load_today_plan", lambda ex: SetReplyTests.STRAIGHT), \
             patch.dict(os.environ, {"PLAN_CONTRACT": "1"}):
            reply = coach.chat_with_coach("Logged working set 1 of 3: 97.5kg x 9 @ RPE 8.", [], {"mesocycle_week": 2},
                                          set_log_session="sid")
        self.assertIn("*Cable Crunch*", reply)
        self.assertIn("102.5kg x9 RPE8", reply)
        self.assertEqual(len(calls), 1)

        calls.clear()
        with patch("coach.get_anthropic_client", return_value=fake_client), \
             patch("coach.load_system_prompt", return_value=_prompt()), \
             patch("coach.build_context_block", return_value=("STABLE", "LIVE")), \
             patch("coach._truncate_history", side_effect=lambda h: h), \
             patch("coach.save_conversation_message"), \
             patch("coach.session_type_for", return_value="Cardio+Abs"), \
             patch.object(plan_module, "latest_exercise", lambda sid: "Cable Crunch"), \
             patch.object(plan_module, "load_today_plan", lambda ex: None), \
             patch.dict(os.environ, {"PLAN_CONTRACT": "1"}):
            reply = coach.chat_with_coach("Logged working set 1 of 3: 97.5kg x 9 @ RPE 8.", [], {}, set_log_session="sid")
        self.assertEqual(reply, "prose reply", "no stored plan for the exercise means prose, as before")


class WeakPointHistoryTests(unittest.TestCase):
    def test_history_is_per_training_day_not_per_row(self):
        import volume

        class Q:
            def __init__(self, rows): self.rows = rows
            def __getattr__(self, name):
                return lambda *a, **k: self
            def execute(self): return type("R", (), {"data": self.rows})()

        sessions = [{"id": "a1", "date": "2026-09-01"}, {"id": "a2", "date": "2026-09-01"},   # two rows, one day
                    {"id": "b1", "date": "2026-08-27"}, {"id": "b2", "date": "2026-08-27"},
                    {"id": "c1", "date": "2026-08-23"}]
        sets = [{"workout_session_id": "a1", "exercise": "Boxing", "is_warmup": False, "notes": "cardio · hk:x"},
                {"workout_session_id": "a2", "exercise": "Machine Calf Raise", "is_warmup": False, "notes": ""},
                {"workout_session_id": "b1", "exercise": "Boxing", "is_warmup": False, "notes": "cardio"},
                {"workout_session_id": "b2", "exercise": "Seated Leg Curl", "is_warmup": False, "notes": ""},
                {"workout_session_id": "c1", "exercise": "Cable Crunch", "is_warmup": False, "notes": ""}]

        class S:
            def table(self, name):
                return Q(sessions) if name == "workout_sessions" else Q(sets)

        with patch.object(volume, "get_supabase", return_value=S()):
            history = volume.get_weak_point_history(4)
        self.assertEqual([h["date"] for h in history], ["2026-09-01", "2026-08-27", "2026-08-23"])
        self.assertTrue(history[0]["muscles"], "the calf work on the second row of the day counts")
        self.assertTrue(history[1]["muscles"])
        self.assertFalse(history[2]["muscles"], "a day with only ab work carried no block work")


class StaleSessionTests(unittest.TestCase):
    """A session left active from an earlier day, settled from the row. The
    rotation is never moved here — the app owns it and advances on END."""

    def _run(self, status, stamp=(1, 4), state=(1, 4)):
        import coach
        advanced, ended, cleared = [], [], []
        flag = {"workout_mode": "active", "current_session_id": "sid",
                "session_start_time": "2026-09-05T18:00:00+10:00"}
        row = {"status": status, "mesocycle_week": stamp[0], "mesocycle_day": stamp[1]}
        memory = {"mesocycle_week": state[0], "mesocycle_day": state[1]}
        with patch("coach.get_workout_state", return_value=flag), \
             patch("coach.set_workout_state", side_effect=lambda d: cleared.append(d)), \
             patch("coach.end_session", side_effect=lambda sid: ended.append(sid)), \
             patch("coach.advance_mesocycle", side_effect=lambda m: advanced.append(1)), \
             patch("workout.session_row", return_value=row), \
             patch("coach.now_local", return_value=__import__("datetime").datetime(2026, 9, 6, 9, 0)):
            coach._settle_stale_session(memory)
        return memory, advanced, ended, cleared

    def test_a_finished_session_only_clears_the_flag(self):
        memory, advanced, ended, cleared = self._run("completed")
        self.assertEqual((advanced, ended), ([], []))
        self.assertEqual(cleared[0]["workout_mode"], "inactive")

    def test_an_abandoned_session_on_its_own_slot_is_ended_and_not_advanced(self):
        """The case that used to advance. The app's END is the only thing
        that moves the rotation now, so an abandoned row ends where it is."""
        memory, advanced, ended, cleared = self._run("in_progress", stamp=(1, 4), state=(1, 4))
        self.assertEqual((advanced, ended), ([], ["sid"]))
        self.assertEqual((memory["mesocycle_week"], memory["mesocycle_day"]), (1, 4))

    def test_a_session_the_state_has_already_moved_past_is_ended_but_not_advanced(self):
        memory, advanced, ended, cleared = self._run("in_progress", stamp=(1, 4), state=(2, 1))
        self.assertEqual((advanced, ended), ([], ["sid"]))

    def test_an_unstamped_open_session_is_ended_but_not_advanced(self):
        memory, advanced, ended, cleared = self._run("in_progress", stamp=(None, None), state=(1, 4))
        self.assertEqual((advanced, ended), ([], ["sid"]))

    def test_a_session_started_today_is_left_alone(self):
        import coach
        flag = {"workout_mode": "active", "current_session_id": "sid",
                "session_start_time": "2026-09-06T08:00:00+10:00"}
        touched = []
        with patch("coach.get_workout_state", return_value=flag), \
             patch("coach.set_workout_state", side_effect=lambda d: touched.append(d)), \
             patch("coach.end_session", side_effect=lambda sid: touched.append(sid)), \
             patch("coach.now_local", return_value=__import__("datetime").datetime(2026, 9, 6, 9, 0)):
            coach._settle_stale_session({"mesocycle_week": 1, "mesocycle_day": 4})
        self.assertEqual(touched, [])


class _FakeProse:
    stop_reason = "end_turn"
    content = [type("T", (), {"text": "prose"})()]


class NamedSessionTests(unittest.TestCase):
    """The app names the session it opened; that name outranks the rotation."""

    def test_the_openers_the_app_sends_name_their_session(self):
        from coach_parsing import session_type_named
        self.assertEqual(session_type_named("Starting my Pull session. List today's full exercise plan"), "Pull")
        self.assertEqual(session_type_named("Starting my Cardio+Abs session from the abs side"), "Cardio+Abs")
        self.assertEqual(session_type_named("Resuming my Legs session"), "Legs")
        self.assertEqual(session_type_named("starting push day"), "Push")

    def test_ordinary_messages_name_nothing(self):
        from coach_parsing import session_type_named
        for text in ("Logged working set 2 of 3: Lat Pulldown 80kg x 10",
                     "how many sets on pull day?", "Starting my day", ""):
            self.assertIsNone(session_type_named(text), text)

    def test_the_named_session_reaches_the_plan_and_the_context(self):
        """Rotation on Push (W2 D2) after a stray advance; the app opens Pull.
        The plan, the template and the context all describe Pull."""
        import coach
        seen = {}

        def fake_context(memory, *a, session_type=None, out=None, **k):
            seen["context_type"] = session_type
            if out is not None:
                out["computed"] = {}
            return "stable", "live"

        def fake_plan(client, **kw):
            seen["plan_type"] = kw["session_type"]
            return None, ["stub"]

        memory = {"mesocycle_week": 2, "mesocycle_day": 2}
        with patch("coach.build_context_block", side_effect=fake_context), \
             patch("coach.load_system_prompt", return_value=""), \
             patch("coach.format_session_template", side_effect=lambda p, t: seen.setdefault("template_type", t) or ""), \
             patch("coach.save_conversation_message", lambda *a, **k: None), \
             patch("coach.get_settings", return_value=type("S", (), {"plan_contract": True, "programme_substitution": False})()), \
             patch("coach.get_anthropic_client", return_value=None), \
             patch("plan.request_session_plan", side_effect=fake_plan), \
             patch("coach._prose_reply", return_value=_FakeProse()):
            coach.chat_with_coach("Starting my Pull session. List today's full exercise plan",
                                  [], memory, plan_request=True, session_type="Pull")
        self.assertEqual(seen["context_type"], "Pull")
        self.assertEqual(seen["template_type"], "Pull")
        self.assertEqual(seen["plan_type"], "Pull")

    def test_without_a_name_the_rotation_decides(self):
        import coach
        seen = {}

        def fake_context(memory, *a, session_type=None, out=None, **k):
            seen["context_type"] = session_type
            return "stable", "live"

        memory = {"mesocycle_week": 2, "mesocycle_day": 2}
        with patch("coach.build_context_block", side_effect=fake_context), \
             patch("coach.load_system_prompt", return_value=""), \
             patch("coach.format_session_template", side_effect=lambda p, t: seen.setdefault("template_type", t) or ""), \
             patch("coach.save_conversation_message", lambda *a, **k: None), \
             patch("coach.get_settings", return_value=type("S", (), {"plan_contract": True, "programme_substitution": False})()), \
             patch("coach._prose_reply", return_value=_FakeProse()):
            coach.chat_with_coach("how many sets today?", [], memory)
        self.assertIsNone(seen["context_type"])
        self.assertEqual(seen["template_type"], "Push")


class BodyweightLoadTests(unittest.TestCase):
    """A set of a bodyweight movement lifted the athlete, not just the plate."""

    def test_the_plate_alone_for_stack_lifts(self):
        from prescribe import effective_load, bodyweight_fraction
        self.assertIsNone(bodyweight_fraction("Machine Chest Press"))
        self.assertEqual(effective_load(100, "Machine Chest Press", 80.7), 100)

    def test_dips_and_pull_ups_carry_the_whole_athlete(self):
        from prescribe import effective_load
        self.assertAlmostEqual(effective_load(0, "Dips", 80.7), 80.7)
        self.assertAlmostEqual(effective_load(19, "Dips", 80.7), 99.7)
        self.assertAlmostEqual(effective_load(17.5, "Pull-Ups", 80.7), 98.2)

    def test_leg_raises_carry_the_legs_and_holds_carry_nothing(self):
        from prescribe import effective_load, bodyweight_fraction
        self.assertAlmostEqual(effective_load(0, "Hanging Leg Raises", 80), 28.0)
        self.assertIsNone(bodyweight_fraction("Ab Wheel Rollout"))
        self.assertIsNone(bodyweight_fraction("Assisted Dip Machine"))

    def test_no_weigh_in_means_the_plate_alone(self):
        from prescribe import effective_load
        self.assertEqual(effective_load(0, "Dips", None), 0)
        self.assertEqual(effective_load(5, "Dips", 0), 5)

    def test_the_back_off_that_looked_unfair(self):
        """Bodyweight x13 versus +5 x10 at 80.7kg: the first is more work."""
        from prescribe import effective_load
        today = effective_load(0, "Dips", 80.7) * 13
        last = effective_load(5, "Dips", 80.7) * 10
        self.assertGreater(today, last)
        self.assertAlmostEqual(today, 1049.1)
        self.assertAlmostEqual(last, 857.0)


class EndSessionTimeTests(unittest.TestCase):
    def test_a_session_closed_later_ends_at_its_last_logged_set(self):
        import workout
        updates = []

        class Q:
            def __init__(self, rows): self.rows = rows
            def __getattr__(self, name):
                return lambda *a, **k: self
            def update(self, body): updates.append(body); return self
            def execute(self): return type("R", (), {"data": self.rows})()

        class S:
            def table(self, name):
                if name == "workout_sets":
                    return Q([{"actual_weight_kg": 100, "actual_reps": 10, "is_warmup": False,
                               "logged_at": "2026-09-05T19:41:00+10:00"},
                              {"actual_weight_kg": 100, "actual_reps": 9, "is_warmup": False,
                               "logged_at": "2026-09-05T19:44:00+10:00"}])
                return Q([])

        with patch.object(workout, "get_supabase", return_value=S()), \
             patch.object(workout, "set_workout_state", lambda d: None), \
             patch("data.latest_bodyweight_kg", return_value=80.0):
            workout.end_session("sid")
        self.assertEqual(updates[0]["end_time"], "2026-09-05T19:44:00+10:00")
        self.assertEqual(updates[0]["tonnage_kg"], 1900.0)

    def test_dips_at_bodyweight_are_counted_as_work(self):
        import workout
        updates = []

        class Q:
            def __init__(self, rows): self.rows = rows
            def __getattr__(self, name):
                return lambda *a, **k: self
            def update(self, body): updates.append(body); return self
            def execute(self): return type("R", (), {"data": self.rows})()

        class S:
            def table(self, name):
                if name == "workout_sets":
                    return Q([{"exercise": "Dips", "actual_weight_kg": 19, "actual_reps": 9, "is_warmup": False,
                               "logged_at": "2026-09-08T18:00:00+10:00"},
                              {"exercise": "Dips", "actual_weight_kg": 0, "actual_reps": 13, "is_warmup": False,
                               "logged_at": "2026-09-08T18:04:00+10:00"}])
                return Q([])

        with patch.object(workout, "get_supabase", return_value=S()), \
             patch.object(workout, "set_workout_state", lambda d: None), \
             patch("data.latest_bodyweight_kg", return_value=80.0):
            workout.end_session("sid")
        # (80+19) x 9 + 80 x 13 = 891 + 1040
        self.assertEqual(updates[0]["tonnage_kg"], 1931.0)


class UsageRecordTests(unittest.TestCase):
    """Every call leaves its cost as a row; the report reads them back."""

    def test_usage_fields_read_the_response_and_default_to_zero(self):
        from usage import usage_fields
        u = type("U", (), {"input_tokens": 1200, "cache_read_input_tokens": 28000,
                           "cache_creation_input_tokens": 0, "output_tokens": 900})()
        r = type("R", (), {"usage": u})()
        self.assertEqual(usage_fields(r), {"input_tokens": 1200, "cache_read_tokens": 28000,
                                           "cache_write_tokens": 0, "output_tokens": 900})
        self.assertEqual(usage_fields(type("R", (), {"usage": None})())["output_tokens"], 0)

    def test_a_plan_call_records_a_row_and_a_failed_write_never_raises(self):
        written = []

        class T:
            def insert(self, row): written.append(row); return self
            def execute(self): return None

        class S:
            def table(self, name): assert name == "model_calls"; return T()
        client = _FakeClient([json.dumps(_legs_plan())])
        with patch("data.get_supabase", return_value=S()):
            request_session_plan(client, [], [{"role": "user", "content": "go"}], "Legs", 2, _prompt())
        self.assertEqual(len(written), 1)
        self.assertEqual((written[0]["kind"], written[0]["attempt"], written[0]["ok"]), ("plan", 1, True))
        self.assertIn("Legs wk2", written[0]["note"])

        class Broken:
            def table(self, name): raise RuntimeError("no table")
        client = _FakeClient([json.dumps(_legs_plan())])
        with patch("data.get_supabase", return_value=Broken()):
            plan, notes = request_session_plan(client, [], [{"role": "user", "content": "go"}], "Legs", 2, _prompt())
        self.assertIsNotNone(plan)

    def test_the_report_summarises_by_kind(self):
        from usage import summarise, format_report
        rows = [
            {"kind": "plan", "attempt": 1, "ok": True, "seconds": 22.0, "input_tokens": 900, "cache_read_tokens": 27000, "output_tokens": 1800},
            {"kind": "plan", "attempt": 2, "ok": True, "seconds": 9.0, "input_tokens": 3000, "cache_read_tokens": 27000, "output_tokens": 700},
            {"kind": "set_reply", "attempt": 1, "ok": True, "seconds": 4.0, "input_tokens": 500, "cache_read_tokens": 27000, "output_tokens": 200},
            {"kind": "prose", "attempt": 1, "ok": False, "seconds": 30.0, "input_tokens": 28000, "cache_read_tokens": 0, "output_tokens": 0},
        ]
        s = summarise(rows)
        self.assertEqual(s["plan"]["calls"], 2)
        self.assertEqual(s["plan"]["retries"], 1)
        self.assertAlmostEqual(s["plan"]["cache_hit"], 54000 / (54000 + 3900))
        self.assertEqual(s["prose"]["failed"], 1)
        self.assertAlmostEqual(s["prose"]["cache_hit"], 0.0)
        text = format_report(s, 14, "2026-08-27")
        self.assertIn("| plan | 2 | 1 | 0 |", text)
        self.assertIn("docs/OPTIMISATION.md", text)


class StandingConstraintTests(unittest.TestCase):
    """A fact stated in chat outlives the session: stored, shown, respected."""

    def test_decision_lines_parse(self):
        from constraints import parse_decision_lines
        reply = ("Good call.\n\nDecision: Cable Crunch | max load 105kg | stack tops out; reps to 12-15 @8, then tempo\n"
                 "Decision: Ab Wheel Rollout | clear\nSee you Thursday.")
        d = parse_decision_lines(reply)
        self.assertEqual(d[0], {"exercise": "Cable Crunch", "max_load_kg": 105.0,
                                "note": "stack tops out; reps to 12-15 @8, then tempo", "clear": False})
        self.assertEqual(d[1], {"exercise": "Ab Wheel Rollout", "clear": True})
        self.assertEqual(parse_decision_lines("no decisions here"), [])

    def test_the_programme_caps_at_the_ceiling_and_moves_to_reps(self):
        from constraints import apply_ceilings
        from prescribe import Proposal, SetSpec
        p = Proposal(exercise="Cable Crunch", kind="isolation",
                     warmup=[], working=[SetSpec(107.5, 8, 12, 8.0)] * 3, backoff=[],
                     reasons=["week 2 step"])
        out = apply_ceilings([p], {"cable crunch": 105.0})[0]
        self.assertEqual([s.weight_kg for s in out.working], [105.0] * 3)
        self.assertEqual((out.working[0].reps_low, out.working[0].reps_high), (12, 15))
        self.assertTrue(any("standing decision caps this machine at 105kg" in r for r in out.reasons))
        # Under the ceiling, nothing changes.
        q = Proposal(exercise="Cable Crunch", kind="isolation", working=[SetSpec(100.0, 8, 12, 8.0)])
        self.assertEqual(apply_ceilings([q], {"cable crunch": 105.0})[0].working[0].weight_kg, 100.0)

    def test_a_top_set_with_back_offs_keeps_its_shape_under_the_cap(self):
        from constraints import apply_ceilings
        from prescribe import Proposal, SetSpec
        p = Proposal(exercise="Leg Extension", kind="isolation",
                     warmup=[SetSpec(60.0, 8, 8, 6.0)], working=[SetSpec(115.0, 8, 12, 8.0)],
                     backoff=[SetSpec(92.0, 12, 15, 7.0)])
        out = apply_ceilings([p], {"leg extension": 110.0})[0]
        self.assertEqual(out.working[0].weight_kg, 110.0)
        self.assertAlmostEqual(out.backoff[0].weight_kg, 88.0)
        self.assertAlmostEqual(out.warmup[0].weight_kg, 57.5)

    def test_the_plan_may_not_exceed_a_ceiling(self):
        raw = _legs_plan()
        raw["exercises"][2]["decision"] = "adjust"
        raw["exercises"][2]["reason"] = "Quads felt fresh after the presses, taking the step up today."
        raw["exercises"][2]["working"][0]["load_kg"] = 112.5
        raw["exercises"][2]["backoff"][0]["load_kg"] = 90.0
        plan = parse_plan(json.dumps(raw), _legs_proposal())
        problems = validate(plan, "Legs", _prompt(), _legs_proposal(), ceilings={"leg extension": 110.0})
        self.assertTrue(any("standing ceiling of 110kg" in p for p in problems), problems)
        self.assertEqual(validate(plan, "Legs", _prompt(), _legs_proposal(), ceilings={"leg extension": 115.0}), [])

    def test_constraints_read_back_for_the_coach(self):
        from constraints import format_constraints, ceilings
        rows = [{"exercise": "Cable Crunch", "max_load_kg": 105, "note": "stack tops out", "set_on": "2026-09-10"}]
        text = format_constraints(rows)
        self.assertIn("Cable Crunch · max load 105kg (since 2026-09-10) — stack tops out", text)
        from prescribe import norm_name
        self.assertEqual(ceilings(rows), {norm_name("Cable Crunch"): 105.0})
        self.assertIn("None recorded", format_constraints([]))


class UsageReportRobustnessTests(unittest.TestCase):
    def test_a_missing_table_reads_as_no_calls(self):
        from usage import fetch_rows

        class Broken:
            def table(self, name): raise RuntimeError("Could not find the table 'public.model_calls'")
        with patch("data.get_supabase", return_value=Broken()):
            self.assertEqual(fetch_rows(14), [])
