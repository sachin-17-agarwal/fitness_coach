"""Pre-flight: the card the rules produce TOGETHER, checked and corrected by
code before anyone sees it. Nothing here asks the athlete to check anything."""

import json
import unittest
import blockfix  # noqa: F401  pins the block to four weeks for the legacy rules
from unittest.mock import patch

import preflight
import programme
from prescribe import ISOLATION, COMPOUND, PriorSet, Proposal, SetSpec


def _prompt():
    with open("system_prompt.txt") as handle:
        return handle.read()


def _proposal(exercise, kind, top, backoff=None, reasons=(), deferred=()):
    return Proposal(exercise=exercise, kind=kind, working=[top], backoff=[backoff] if backoff else [],
                    reasons=list(reasons), deferred=list(deferred))


class EnforceTests(unittest.TestCase):

    def test_a_load_the_stack_does_not_have_is_rounded_to_one_it_has(self):
        # Reverse Cable Fly 20 Sep: "12kg x7-11" on a 2.5kg stack.
        history = {"Reverse Cable Fly": PriorSet(12.5, 12, 7.0, week=4, step=2.5)}
        p = _proposal("Reverse Cable Fly", ISOLATION, SetSpec(12.0, 7, 11, 6.0), SetSpec(9.5, 12, 15, 6.0),
                      reasons=["Week 1 opens at last cycle's week 3 load", "Recovery: RPE targets come down a point"])
        out, findings = preflight.enforce([p], history, {}, 1)
        self.assertEqual(out[0].working[0].weight_kg, 12.5)
        self.assertEqual(out[0].backoff[0].weight_kg, 10.0)
        self.assertTrue(out[0].reasons[0].startswith("Pre-flight corrected this card"))
        self.assertIn("12kg is not a load on this lift's 2.5kg step; 12.5kg is", out[0].reasons[0])
        self.assertEqual([f["kind"] for f in findings], ["loadable", "loadable"])
        self.assertTrue(all(f["fixed"] for f in findings))

    def test_a_drop_below_the_anchor_with_no_rule_behind_it_is_held(self):
        peak = {"Cable Row": PriorSet(90.5, 10, 8.0, week=3, step=0.5)}
        p = _proposal("Cable Row", COMPOUND, SetSpec(85.0, 6, 10, 8.0), SetSpec(68.0, 10, 12, 7.0),
                      reasons=["Week 1 opens at last cycle's week 3 load with reps reset to the bottom"])
        out, findings = preflight.enforce([p], {}, peak, 1)
        self.assertEqual(out[0].working[0].weight_kg, 90.5)
        self.assertAlmostEqual(out[0].backoff[0].weight_kg, 72.5, places=1)     # the back-off scales with it
        self.assertEqual(findings[0]["kind"], "regression")
        self.assertIn("no rule lowers this lift below its last top set of 90.5kg", out[0].reasons[0])

    def test_a_drop_the_rules_explain_is_left_alone(self):
        peak = {"Cable Row": PriorSet(90.5, 10, 8.0, week=3)}
        for reason in ("Recovery cut taken as LOAD", "standing decision caps it", "week 4 deload drops the load 10%"):
            p = _proposal("Cable Row", COMPOUND, SetSpec(85.0, 6, 10, 8.0), reasons=[reason])
            out, findings = preflight.enforce([p], {}, peak, 1)
            self.assertEqual(out[0].working[0].weight_kg, 85.0, reason)
            self.assertEqual(findings, [], reason)
        # Week 4 is meant to sit below the anchor.
        p = _proposal("Cable Row", COMPOUND, SetSpec(85.0, 6, 10, 7.0), reasons=["deload"])
        self.assertEqual(preflight.enforce([p], {}, peak, 4)[1], [])

    def test_reps_are_kept_inside_the_range_one_step_under_the_floor_allowed(self):
        p = _proposal("Face Pulls", ISOLATION, SetSpec(42.5, 7, 11, 6.0))        # a recovery step: fine
        self.assertEqual(preflight.enforce([p], {}, {}, 2)[1], [])
        p = _proposal("Face Pulls", ISOLATION, SetSpec(42.5, 5, 14, 8.0))
        out, findings = preflight.enforce([p], {}, {}, 2)
        self.assertEqual((out[0].working[0].reps_low, out[0].working[0].reps_high), (7, 12))
        self.assertEqual(findings[0]["kind"], "range")
        # A straight-set slot has its own range.
        p = _proposal("Overhead Cable Extension", ISOLATION, SetSpec(25.0, 6, 16, 8.0))
        out, _ = preflight.enforce([p], {}, {}, 2, straight_lifts={"Overhead Cable Extension": (10, 15)})
        self.assertEqual((out[0].working[0].reps_low, out[0].working[0].reps_high), (9, 15))

    def test_nothing_goes_above_a_standing_cap(self):
        p = _proposal("Machine Shoulder Press", COMPOUND, SetSpec(72.5, 6, 10, 8.0), SetSpec(58.0, 10, 12, 7.0),
                      reasons=["Week 2 adds a step"])
        out, findings = preflight.enforce([p], {}, {}, 2, ceilings={"Machine Shoulder Press": 70})
        self.assertEqual(out[0].working[0].weight_kg, 70.0)
        self.assertEqual([f["kind"] for f in findings], ["ceiling"])

    def test_a_queued_emphasis_missing_from_a_cardio_abs_card_is_reported_not_hidden(self):
        p = _proposal("Cable Crunch", ISOLATION, SetSpec(105.0, 12, 15, 8.0))
        picks = [{"muscle": "Triceps", "exercise": "Overhead Cable Extension"}, {"muscle": "Chest", "exercise": "Cable Fly (Low To High)"}]
        _, findings = preflight.enforce([p], {}, {}, 1, session_type="Cardio+Abs", weak_points=picks)
        self.assertEqual([(f["kind"], f["fixed"]) for f in findings], [("slots", False), ("slots", False)])
        self.assertIn("Triceps emphasis names Overhead Cable Extension, which is not on the card", findings[0]["detail"])
        _, findings = preflight.enforce([p], {}, {}, 1, session_type="Pull", weak_points=picks)
        self.assertEqual(findings, [])

    def test_a_clean_card_is_untouched(self):
        history = {"Cable Row": PriorSet(90.5, 10, 8.0, week=3, step=0.5)}
        p = _proposal("Cable Row", COMPOUND, SetSpec(93.0, 6, 10, 8.0), SetSpec(74.5, 10, 12, 7.0), reasons=["Week 2 adds a step"])
        out, findings = preflight.enforce([p], history, {}, 2)
        self.assertEqual(findings, [])
        self.assertEqual(out[0].reasons, ["Week 2 adds a step"])
        self.assertEqual(preflight.summarise([]), "clean")


class ThroughTheProgrammeTests(unittest.TestCase):
    """The same card the opening builds, with the lift's real step in its
    history, comes out loadable — and the step is what makes it so."""

    def test_the_reverse_cable_fly_case_end_to_end(self):
        current = [{"exercise": "Reverse Cable Fly", "load": 12.5, "reps": 12, "rpe": 7.0, "date": "2026-09-16",
                    "mesocycle_week": 4, "held": 1, "step": 2.5}]
        peak = [{"exercise": "Reverse Cable Fly", "load": 12.5, "reps": 11, "rpe": 8.0, "date": "2026-09-10", "step": 2.5}]
        # A red morning: RPE down a point and the load down 5%.
        recovery = {"read": {"rpe_delta": -1.0, "load_multiplier": 0.95, "recovery_session": False,
                             "reasons": ["HRV 10% below", "5.7h sleep"]}}
        props, _, _ = programme.build_proposal(_prompt(), "Pull", 1, current, recovery=recovery, peak_week_loads=peak)
        fly = next(p for p in props if p.exercise == "Reverse Cable Fly")
        top = fly.working[0]
        self.assertEqual((top.weight_kg, top.reps_low, top.reps_high), (12.5, 7, 11))
        self.assertTrue(all(w.weight_kg is None or abs(w.weight_kg / 2.5 - round(w.weight_kg / 2.5)) < 1e-6
                            for w in fly.warmup + fly.working + fly.backoff),
                        "every load on the card exists on a 2.5kg stack")
        self.assertIn("load holds at 12.5kg", " ".join(fly.reasons + fly.recovery_reasons))

    def test_the_dry_run_happens_once_a_day_and_never_inside_a_session(self):
        stored = {}
        with patch("preflight.run_for_next_session", return_value={"session": "Push", "findings": []}) as run, \
             patch("data.get_supabase", return_value=object()), \
             patch("workout.get_workout_state", return_value={"workout_mode": "idle"}), \
             patch("memory.set_memory_value", side_effect=lambda k, v: stored.__setitem__(k, v)), \
             patch("preflight.now_local", create=True), patch("data.now_local") as now:
            now.return_value.strftime.return_value = "2026-09-20"
            self.assertIsNotNone(preflight.run_if_due({}))
            run.assert_called_once()
            self.assertEqual(stored[preflight.PREFLIGHT_DATE_KEY], "2026-09-20")
            self.assertEqual(json.loads(stored[preflight.PREFLIGHT_LAST_KEY])["session"], "Push")
            # Same day again: nothing.
            self.assertIsNone(preflight.run_if_due({preflight.PREFLIGHT_DATE_KEY: "2026-09-20"}))
            run.assert_called_once()
        with patch("preflight.run_for_next_session") as run, patch("data.get_supabase", return_value=object()), \
             patch("workout.get_workout_state", return_value={"workout_mode": "active"}), patch("data.now_local") as now:
            now.return_value.strftime.return_value = "2026-09-21"
            self.assertIsNone(preflight.run_if_due({}))
            run.assert_not_called()
