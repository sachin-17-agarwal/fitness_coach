"""Start on the programme; the coach catches up (roadmap 2.1b, backend half)."""

import json
import unittest
import blockfix  # noqa: F401  pins the block to four weeks for the legacy rules
from unittest.mock import patch

import session_open
from session_open import PROGRAMME_REASON, diff_plans, open_session, review_session, session_status

PROMPT = open("system_prompt.txt", encoding="utf-8").read()

def _block(name, top, back=None, warm="40kg x8"):
    """A block the way the programme renders it: header, then the lines."""
    lines = [f"*{name}*", f"Warm-up: {warm}", f"Working Set: {top} | Tempo: 3-1-2 | Rest: 2min"]
    if back:
        lines.append(f"Back-off: {back}")
    return "\n".join(lines)

COMPUTED = {name: _block(name, top, back) for name, top, back in [
    ("Pull-Ups", "BW x6-8 RPE8", "BW x10 RPE7"),
    ("Cable Row", "80kg x6-8 RPE8", "64kg x10-12 RPE7"),
    ("Lat Pulldown", "70kg x6-8 RPE8", "56kg x10-12 RPE7"),
    ("T-Bar Row", "60kg x6-8 RPE8", "48kg x10-12 RPE7"),
    ("Machine Bicep Curl", "30kg x8-10 RPE8", "24kg x12-15 RPE7, 24kg x12-15 RPE7"),
    ("Hammer Curl", "20kg x8-10 RPE8", "16kg x12-15 RPE7, 16kg x12-15 RPE7"),
    ("Reverse Cable Fly", "10kg x8-10 RPE8", "8kg x12-15 RPE7"),
]}


def _fake_context(*args, **kwargs):
    out = kwargs.get("out")
    if out is not None:
        out["computed"] = dict(COMPUTED)
    return "STABLE", "LIVE"


class OpenSessionTests(unittest.TestCase):

    def _open(self, computed=COMPUTED):
        def ctx(*a, **k):
            if k.get("out") is not None:
                k["out"]["computed"] = dict(computed)
            return "STABLE", "LIVE"
        calls = {}
        with patch("coach_context.build_context_block", side_effect=ctx), \
             patch("coach.load_system_prompt", return_value=PROMPT), \
             patch("plan.save_decisions", side_effect=lambda plan, *a, **k: calls.setdefault("saved", plan)), \
             patch("session_open.save_conversation_message", side_effect=lambda r, c: calls.setdefault("conv", []).append((r, c))), \
             patch("session_open.set_memory_value", side_effect=lambda k, v: calls.setdefault("memory", []).append((k, v))), \
             patch("session_open.threading.Thread") as thread:
            result = open_session("Pull", {"mesocycle_week": 2, "mesocycle_day": 1}, "Starting my Pull session.",
                                  recovery_override={"hrv": 44})
        calls["thread"] = thread
        return result, calls

    def test_the_programme_card_comes_back_at_once_with_every_template_exercise(self):
        result, calls = self._open()
        self.assertEqual(result["status"], "reviewing")
        for name in COMPUTED:
            self.assertIn(f"*{name}*", result["response"])
        self.assertIn("coach is reviewing it now", result["response"])
        # Stored as today's plan so a set logged meanwhile has a plan to move from.
        saved = calls["saved"]
        self.assertEqual(len(saved.exercises), len(COMPUTED))
        self.assertTrue(all(e.reason == PROGRAMME_REASON for e in saved.exercises))
        # The opening message is the athlete's turn; the coach's review answers it.
        self.assertEqual(calls["conv"], [("user", "Starting my Pull session.")])
        key, raw = calls["memory"][0]
        self.assertEqual(key, session_open.REVIEW_KEY)
        self.assertEqual(json.loads(raw)["status"], "reviewing")
        self.assertTrue(calls["thread"].return_value.start.called)
        kwargs = calls["thread"].call_args.kwargs["kwargs"]
        self.assertEqual(kwargs["session_type"], "Pull")
        self.assertEqual(kwargs["recovery_override"], {"hrv": 44})

    def test_no_computed_programme_means_unavailable_and_no_side_effects(self):
        result, calls = self._open(computed={})
        self.assertEqual(result, {"status": "unavailable"})
        self.assertNotIn("saved", calls)
        self.assertNotIn("conv", calls)
        self.assertNotIn("memory", calls)
        self.assertFalse(calls["thread"].called)


class ReviewSessionTests(unittest.TestCase):

    PROGRAMME = ("Programme plan.\n\n*Cable Row*\nWorking Set: 80kg x6-8 RPE8 | Tempo: 3-1-2 | Rest: 2min\n"
                 "Back-off: 64kg x10-12 RPE7\nForm: brace\n\n*Hammer Curl*\nWorking Set: 20kg x8-10 RPE8 | "
                 "Tempo: 2-1-2 | Rest: 90s\nBack-off: 16kg x12-15 RPE7, 16kg x12-15 RPE7\nForm: pinned")
    COACH = ("Recovery is clean.\n\n*Cable Row*\nWorking Set: 75kg x6-8 RPE8 | Tempo: 3-1-2 | Rest: 2min\n"
             "Back-off: 60kg x10-12 RPE7\nForm: brace\nWhy: Changed from the programme (-5kg) — HRV below baseline\n\n"
             "*Hammer Curl*\nWorking Set: 20kg x8-10 RPE8 | Tempo: 2-1-2 | Rest: 90s\n"
             "Back-off: 16kg x12-15 RPE7, 16kg x12-15 RPE7\nForm: pinned")

    def test_the_coachs_plan_lands_on_top_and_the_diff_names_the_change_and_its_cause(self):
        written = []
        with patch("coach.chat_with_coach", return_value=self.COACH) as chat, \
             patch("session_open.load_today_conversation", return_value=[{"role": "user", "content": "Starting my Pull session."}]), \
             patch("session_open.set_memory_value", side_effect=lambda k, v: written.append(json.loads(v))):
            status = review_session("Pull", {"mesocycle_week": 2}, "Starting my Pull session.", None, self.PROGRAMME)
        self.assertEqual(status["status"], "reviewed")
        self.assertEqual(status["response"], self.COACH)
        self.assertEqual([c["exercise"] for c in status["changes"]], ["Cable Row"])
        self.assertIn("HRV below baseline", status["changes"][0]["why"])
        self.assertIn("80kg", status["changes"][0]["from"])
        self.assertIn("75kg", status["changes"][0]["to"])
        # The one call the opening always made, and the user turn is not saved twice.
        kwargs = chat.call_args.kwargs
        self.assertTrue(kwargs["plan_request"])
        self.assertFalse(kwargs["record_user_message"])
        self.assertEqual(kwargs["session_type"], "Pull")
        self.assertEqual(written[-1]["status"], "reviewed")

    def test_a_failed_review_leaves_the_programme_plan_standing(self):
        written = []
        with patch("coach.chat_with_coach", side_effect=RuntimeError("boom")), \
             patch("session_open.load_today_conversation", return_value=[]), \
             patch("session_open.set_memory_value", side_effect=lambda k, v: written.append(json.loads(v))):
            status = review_session("Pull", {}, "Starting my Pull session.", None, self.PROGRAMME)
        self.assertEqual(status["status"], "failed")
        self.assertIn("boom", status["error"])
        self.assertEqual(written[-1]["status"], "failed")


class SessionStatusTests(unittest.TestCase):

    def test_status_is_none_without_a_record_or_from_another_day(self):
        self.assertEqual(session_status({}), {"status": "none"})
        stale = json.dumps({"date": "2001-01-01", "status": "reviewed", "response": "x"})
        self.assertEqual(session_status({session_open.REVIEW_KEY: stale}), {"status": "none"})

    def test_a_reviewed_status_carries_the_response_and_the_changes(self):
        from data import now_local
        today = now_local().strftime("%Y-%m-%d")
        raw = json.dumps({"date": today, "session_type": "Pull", "status": "reviewed",
                          "response": "plan", "changes": [{"exercise": "Cable Row"}]})
        out = session_status({session_open.REVIEW_KEY: raw})
        self.assertEqual(out["status"], "reviewed")
        self.assertEqual(out["response"], "plan")
        self.assertEqual(out["changes"], [{"exercise": "Cable Row"}])


class DiffPlansTests(unittest.TestCase):

    def test_changed_added_and_removed(self):
        prog = "*A*\nWorking Set: 100kg x8 RPE8 | Tempo: 3-1-2 | Rest: 2min\n\n*B*\nWorking Set: 50kg x10 RPE8 | Tempo: 2-1-2 | Rest: 90s"
        coach = ("*A*\nWorking Set: 95kg x8 RPE8 | Tempo: 3-1-2 | Rest: 2min\nWhy: Changed from the programme — shoulder niggle\n\n"
                 "*C*\nWorking Set: 30kg x12 RPE8 | Tempo: 2-1-2 | Rest: 90s")
        changes = {c["exercise"]: c for c in diff_plans(prog, coach)}
        self.assertEqual(changes["A"]["change"], "changed")
        self.assertIn("shoulder niggle", changes["A"]["why"])
        self.assertEqual(changes["C"]["change"], "added")
        self.assertEqual(changes["B"]["change"], "removed")

    def test_identical_plans_produce_no_changes(self):
        text = "*A*\nWorking Set: 100kg x8 RPE8 | Tempo: 3-1-2 | Rest: 2min\nBack-off: 80kg x12 RPE7"
        self.assertEqual(diff_plans(text, text), [])
