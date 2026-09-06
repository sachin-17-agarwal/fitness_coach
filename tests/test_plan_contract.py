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


class SetReplyTests(unittest.TestCase):
    """A change to the next set is a number too: typed, rendered into the block."""

    STRAIGHT = {"working": [{"load_kg": 97.5, "reps_low": 9, "reps_high": 9, "rpe": 8}] * 3,
                "backoff": [], "tempo": "2-1-2", "rest_seconds": 90}
    TOPBACK = {"working": [{"load_kg": 220, "reps_low": 6, "reps_high": 10, "rpe": 8}],
               "backoff": [{"load_kg": 176, "reps_low": 10, "reps_high": 12, "rpe": 7},
                           {"load_kg": 176, "reps_low": 8, "reps_high": 10, "rpe": 7}],
               "tempo": "3-1-2", "rest_seconds": 120}

    def test_the_next_set_moves_on_the_card_not_only_in_prose(self):
        from plan import render_set_reply
        reply = {"note": "That flew up at RPE 7. Next set at 100.",
                 "next_set": {"changed": True, "load_kg": 100, "reps_low": 12, "reps_high": 12, "rpe": 8,
                              "apply_to_remaining": True}}
        text = render_set_reply(reply, "Cable Crunch", self.STRAIGHT, done=1)
        card = parse_all_prescriptions(text)[0]
        self.assertEqual([s["weight"] for s in card["working"]], [97.5, 100.0, 100.0],
                         "the logged set keeps its target; the remaining two move")
        self.assertEqual(card["working"][1]["reps"], 12)
        self.assertTrue(text.startswith("That flew up"))
        self.assertNotIn("backoff", card)

    def test_next_only_moves_one_set(self):
        from plan import render_set_reply
        reply = {"note": "", "next_set": {"changed": True, "load_kg": 100, "reps_low": 12, "reps_high": 12,
                                          "rpe": 8, "apply_to_remaining": False}}
        card = parse_all_prescriptions(render_set_reply(reply, "Cable Crunch", self.STRAIGHT, done=1))[0]
        self.assertEqual([s["weight"] for s in card["working"]], [97.5, 100.0, 97.5])

    def test_a_back_off_change_lands_on_the_back_off_line(self):
        from plan import render_set_reply
        reply = {"note": "Top set was RPE 9.5; back-offs come down.",
                 "next_set": {"changed": True, "load_kg": 170, "reps_low": 10, "reps_high": 12, "rpe": 7,
                              "apply_to_remaining": True}}
        card = parse_all_prescriptions(render_set_reply(reply, "Leg Press", self.TOPBACK, done=1))[0]
        self.assertEqual(card["working"][0]["weight"], 220.0, "the logged top set is untouched")
        self.assertEqual([b["weight"] for b in card["backoff"]], [170.0, 170.0])
        self.assertEqual(card["tempo"], "3-1-2")

    def test_no_change_is_just_the_note(self):
        from plan import render_set_reply
        reply = {"note": "Good set. Same again.", "next_set": {"changed": False, "load_kg": 0, "reps_low": 1,
                                                                "reps_high": 1, "rpe": 8, "apply_to_remaining": True}}
        self.assertEqual(render_set_reply(reply, "Cable Crunch", self.STRAIGHT, done=1), "Good set. Same again.")
        self.assertEqual(parse_all_prescriptions("Good set. Same again."), [])

    def test_nonsense_numbers_fall_back_to_prose(self):
        from plan import render_set_reply
        reply = {"note": "x", "next_set": {"changed": True, "load_kg": 100, "reps_low": 0, "reps_high": 0,
                                           "rpe": 12, "apply_to_remaining": True}}
        self.assertIsNone(render_set_reply(reply, "Cable Crunch", self.STRAIGHT, done=1))

    def test_the_request_runs_cheap_and_parses(self):
        from plan import request_set_reply, SET_REPLY_SCHEMA
        client = _FakeClient([json.dumps({"note": "ok", "next_set": {"changed": False, "load_kg": 0, "reps_low": 1,
                                                                    "reps_high": 1, "rpe": 8, "apply_to_remaining": True}})])
        reply, notes = request_set_reply(client, [], [{"role": "user", "content": "Logged working set 1 of 3: 97.5kg x 9 @ RPE 8."}],
                                         "Cable Crunch", 1, 3)
        self.assertEqual(reply["note"], "ok")
        req = client.requests[0]
        self.assertEqual(req["output_config"]["effort"], "low")
        self.assertEqual(req["output_config"]["format"]["schema"], SET_REPLY_SCHEMA)
        self.assertEqual(len(client.requests), 1, "no retry on a set reply")

    def test_a_logged_set_message_goes_through_the_contract_and_falls_back_without_a_plan(self):
        import coach
        calls = []

        class FakeMessages:
            def create(self, **kwargs):
                calls.append(kwargs)
                if "output_config" in kwargs:
                    text = json.dumps({"note": "Flew up. Next at 100.",
                                       "next_set": {"changed": True, "load_kg": 100, "reps_low": 12, "reps_high": 12,
                                                    "rpe": 8, "apply_to_remaining": True}})
                else:
                    text = "prose reply"
                return type("R", (), {"content": [type("B", (), {"type": "text", "text": text})()],
                                      "usage": None, "stop_reason": "end_turn"})()

        fake_client = type("C", (), {"messages": FakeMessages()})()
        common = dict(
            latest_exercise=lambda sid: "Cable Crunch",
            logged_sets_for=lambda sid, ex: 1,
        )
        with patch("coach.get_anthropic_client", return_value=fake_client), \
             patch("coach.load_system_prompt", return_value=_prompt()), \
             patch("coach.build_context_block", return_value=("STABLE", "LIVE")), \
             patch("coach._truncate_history", side_effect=lambda h: h), \
             patch("coach.save_conversation_message"), \
             patch("coach.session_type_for", return_value="Cardio+Abs"), \
             patch.object(plan_module, "latest_exercise", common["latest_exercise"]), \
             patch.object(plan_module, "logged_sets_for", common["logged_sets_for"]), \
             patch.object(plan_module, "load_today_plan", lambda ex: SetReplyTests.STRAIGHT), \
             patch.dict(os.environ, {"PLAN_CONTRACT": "1"}):
            reply = coach.chat_with_coach("Logged working set 1 of 3: 97.5kg x 9 @ RPE 8.", [], {"mesocycle_week": 2},
                                          set_log_session="sid")
        self.assertIn("*Cable Crunch*", reply)
        self.assertIn("100kg x12 RPE8", reply)
        self.assertEqual(len(calls), 1)

        calls.clear()
        with patch("coach.get_anthropic_client", return_value=fake_client), \
             patch("coach.load_system_prompt", return_value=_prompt()), \
             patch("coach.build_context_block", return_value=("STABLE", "LIVE")), \
             patch("coach._truncate_history", side_effect=lambda h: h), \
             patch("coach.save_conversation_message"), \
             patch("coach.session_type_for", return_value="Cardio+Abs"), \
             patch.object(plan_module, "latest_exercise", common["latest_exercise"]), \
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
    """A session the app already ended must not advance the mesocycle again."""

    def _run(self, status):
        import coach
        advanced, ended, cleared = [], [], []
        state = {"workout_mode": "active", "current_session_id": "sid",
                 "session_start_time": "2026-09-05T18:00:00+10:00"}
        with patch("coach.get_workout_state", return_value=state), \
             patch("coach.set_workout_state", side_effect=lambda d: cleared.append(d)), \
             patch("coach.end_session", side_effect=lambda sid: ended.append(sid)), \
             patch("coach.advance_mesocycle", side_effect=lambda m: advanced.append(1)), \
             patch("workout.session_status", return_value=status), \
             patch("coach.now_local", return_value=__import__("datetime").datetime(2026, 9, 6, 9, 0)):
            moved = coach._settle_stale_session({"mesocycle_week": 1, "mesocycle_day": 4})
        return moved, advanced, ended, cleared

    def test_a_finished_session_only_clears_the_flag(self):
        moved, advanced, ended, cleared = self._run("completed")
        self.assertFalse(moved)
        self.assertEqual(advanced, [])
        self.assertEqual(ended, [])
        self.assertEqual(cleared[0]["workout_mode"], "inactive")

    def test_an_abandoned_session_is_ended_and_advanced_once(self):
        moved, advanced, ended, cleared = self._run("in_progress")
        self.assertTrue(moved)
        self.assertEqual(advanced, [1])
        self.assertEqual(ended, ["sid"])
