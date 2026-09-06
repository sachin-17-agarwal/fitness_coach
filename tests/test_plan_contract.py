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
            ex("Machine Calf Raise", 3, 100.0),
            ex("Ab Crunch Machine", 3, 90.0, abs_=True),
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
        self.assertTrue(any("Ab Crunch Machine" in p and "missing" in p for p in self._problems(raw)))

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
        raw["exercises"][5]["backoff"] = [{"load_kg": 70, "reps_low": 12, "reps_high": 15, "rpe": 7}]
        self.assertTrue(any("straight sets" in p for p in self._problems(raw)))

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

    def test_unfilled_slots_are_named(self):
        problems = validate(parse_plan(json.dumps(self._plan(with_slots=False))), "Cardio+Abs", self.PROMPT)
        self.assertTrue(any("weak-point slot(s) unfilled" in p for p in problems))

    def test_a_slot_fill_must_say_which_muscle(self):
        raw = self._plan()
        raw["exercises"][4]["reason"] = "extra"
        problems = validate(parse_plan(json.dumps(raw)), "Cardio+Abs", self.PROMPT)
        self.assertTrue(any("which muscle" in p for p in problems))

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
        abs_ = cards["Ab Crunch Machine"]
        self.assertEqual(len(abs_["working"]), 3)
        self.assertNotIn("backoff", abs_)
        self.assertTrue(text.startswith("HRV is on baseline"))

    def test_a_departure_is_written_where_the_athlete_reads_it(self):
        raw = _legs_plan()
        raw["exercises"][2]["decision"] = "adjust"
        raw["exercises"][2]["reason"] = "Machine steps in 5kg, so 100 stays and reps carry the progression."
        text = render_plan(parse_plan(json.dumps(raw)))
        self.assertIn("Changed from the programme: Machine steps in 5kg", text)

    def test_bodyweight_renders_in_the_prompts_spelling(self):
        e = ExercisePlan("Dips", "accept", "default", warmup=[(0, 8)],
                         working=[SetPlan(5.0, 6, 10, 8.0)], backoff=[SetPlan(0.0, 10, 12, 7.0)],
                         tempo="2-1-2", rest_seconds=120)
        text = render_plan(SessionPlan("", [e]))
        self.assertIn("Warm-up: BW x8", text)
        self.assertIn("Working Set: BW + 5kg x6-10 RPE8", text)
        self.assertIn("Back-off: BW x10-12 RPE7", text)


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
        client = _FakeClient([json.dumps(_legs_plan())])
        plan, notes = request_session_plan(client, [{"type": "text", "text": "S"}],
                                           [{"role": "user", "content": "Starting my Legs session"}],
                                           "Legs", 2, self.PROMPT)
        self.assertIsNotNone(plan)
        req = client.requests[0]
        self.assertEqual(req["thinking"], {"type": "adaptive"})
        self.assertEqual(req["output_config"]["format"]["type"], "json_schema")
        self.assertEqual(req["output_config"]["format"]["schema"], PLAN_SCHEMA)
        self.assertGreaterEqual(req["max_tokens"], 8000)
        self.assertTrue(notes[-1].endswith("plan accepted"))

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

    def test_two_broken_plans_mean_no_plan(self):
        broken = _legs_plan()
        broken["exercises"] = broken["exercises"][:2]
        client = _FakeClient([json.dumps(broken), json.dumps(broken)])
        plan, notes = request_session_plan(client, [], [{"role": "user", "content": "go"}],
                                           "Legs", 2, self.PROMPT)
        self.assertIsNone(plan)
        self.assertEqual(len(client.requests), 2)

    def test_unparseable_output_means_no_plan(self):
        client = _FakeClient(["not json"])
        plan, notes = request_session_plan(client, [], [{"role": "user", "content": "go"}],
                                           "Legs", 2, self.PROMPT)
        self.assertIsNone(plan)


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
