"""Legs, 23 Sep 2026: the cases the athlete met, each pinned."""

import re
import unittest
import blockfix  # noqa: F401  pins the block to four weeks for the legacy rules

import preflight
import progression
from coach_parsing import parse_all_prescriptions
from prescribe import COMPOUND, ISOLATION, PriorSet, Proposal, SetSpec, prescribe_exercise, render_block


def _row(ex, date, w, reps, rpe=8, warm=False, n=1):
    return {"exercise": ex, "date": date, "actual_weight_kg": w, "actual_reps": reps, "actual_rpe": rpe,
            "is_warmup": warm, "set_number": n}


class SumoStepTests(unittest.TestCase):

    def test_the_step_is_the_top_sets_movement_not_the_back_off_gap(self):
        # One peak-week session: top set 132.5 and back-offs at 107.5. The gap
        # (25kg) was taken as the equipment step and week 1 opened at 150.
        rows = [_row("Single Leg Sumo Press", "2026-09-14", 132.5, 10, 9, n=1),
                _row("Single Leg Sumo Press", "2026-09-14", 107.5, 12, 8, n=2),
                _row("Single Leg Sumo Press", "2026-09-14", 107.5, 10, 8, n=3)]
        self.assertIsNone(progression.find_current_loads(rows)[0]["step"])
        rows += [_row("Single Leg Sumo Press", "2026-09-09", 130, 9, 8)]
        self.assertEqual(progression.find_current_loads(rows)[0]["step"], 2.5)

    def test_an_unsized_jump_above_the_anchor_is_corrected_to_one_increment(self):
        peak = {"Single Leg Sumo Press": PriorSet(132.5, 10, 9.0, week=3, step=2.5)}
        p = Proposal(exercise="Single Leg Sumo Press", kind=COMPOUND,
                     working=[SetSpec(150.0, 5, 9, 7.0)], backoff=[SetSpec(120.0, 9, 11, 6.0)],
                     reasons=["Week 1 opens ~25kg ABOVE last cycle"])
        out, findings = preflight.enforce([p], {}, peak, 1)
        self.assertEqual(out[0].working[0].weight_kg, 135.0)
        self.assertEqual([f["kind"] for f in findings], ["jump"])

    def test_a_sized_overshoot_within_the_cap_is_left_alone(self):
        peak = {"Leg Press": PriorSet(245.0, 15, 9.0, week=3, step=5.0)}
        p = Proposal(exercise="Leg Press", kind=COMPOUND, working=[SetSpec(270.0, 5, 9, 7.0)],
                     reasons=["Week 1 opens ABOVE last cycle, sized to the miss."])
        out, findings = preflight.enforce([p], {}, peak, 1)
        self.assertEqual(out[0].working[0].weight_kg, 270.0)
        self.assertEqual([f for f in findings if f["kind"] == "jump"], [])


class CalfRampTests(unittest.TestCase):

    def test_the_calf_raise_keeps_its_ramp_and_ab_work_still_has_none(self):
        calf = prescribe_exercise("Machine Calf Raise", 5, ISOLATION, 1, PriorSet(125.0, 7, 6.0, week=3, step=5.0),
                                  {"Quads", "Glutes", "Hamstrings", "Back"})
        block = parse_all_prescriptions(render_block(calf))[0]
        self.assertEqual(len(block.get("warmup") or []), 3)
        self.assertEqual({w["weight"] for w in block["working"]}, {125.0})
        self.assertFalse(block.get("backoff"))
        crunch = prescribe_exercise("Cable Crunch", 3, ISOLATION, 1, PriorSet(105.0, 14, 7.0, week=3), set())
        self.assertNotIn("Warm-up:", render_block(crunch))


class PlanUpdateConstraintTests(unittest.TestCase):

    def test_every_decision_the_code_writes_is_allowed_by_the_table(self):
        schema = open("schema.sql").read()
        table = schema[schema.index("CREATE TABLE IF NOT EXISTS prescription_decisions"):]
        allowed = set(re.findall(r"'(\w+)'", re.search(r"decision\s+TEXT NOT NULL CHECK \(decision IN \(([^)]*)\)\)", table).group(1)))
        from plan import SET_DECISIONS
        with open("plan.py") as fh:
            code = fh.read()
        # Row writes only: a set reply's own decision names are not table values.
        written = set(re.findall(r'"decision":\s*"(\w+)"', code)) - set(SET_DECISIONS)
        self.assertTrue(written, "found the decision literals")
        self.assertLessEqual(written, allowed)
        migration = open("migrations/012_prescription_decisions_update.sql").read()
        self.assertIn("'update'", migration)


class SetReplyAgreementTests(unittest.TestCase):
    CURL = {"working": [{"load_kg": 120, "reps_low": 9, "reps_high": 12, "rpe": 7}],
            "backoff": [{"load_kg": 100, "reps_low": 11, "reps_high": 14, "rpe": 6},
                        {"load_kg": 100, "reps_low": 9, "reps_high": 12, "rpe": 6}], "tempo": "", "rest_seconds": 90}
    PRESS = {"working": [{"load_kg": 270, "reps_low": 5, "reps_high": 9, "rpe": 7}],
             "backoff": [{"load_kg": 215, "reps_low": 9, "reps_high": 11, "rpe": 6},
                         {"load_kg": 215, "reps_low": 7, "reps_high": 9, "rpe": 6}], "tempo": "", "rest_seconds": 120}

    def test_a_heavier_note_under_hold_is_handed_back(self):
        from plan import set_reply_problems
        reply = {"decision": "hold", "note": "The bump wasn't enough; take the last back-off heavier so it actually trains something.",
                 "reason": "", "steps": 1, "scope": "next"}
        problems = set_reply_problems(reply, "Seated Leg Curl", self.CURL, 2)
        self.assertTrue(problems and "heavier" in problems[0])
        self.assertEqual(set_reply_problems({**reply, "note": "Felt heavier than Thursday. Same again."},
                                            "Seated Leg Curl", self.CURL, 2), [])

    def test_a_back_off_never_leaves_the_band_and_the_note_says_so(self):
        from plan import render_set_reply
        reply = {"decision": "heavier", "steps": 1, "scope": "next", "reason": "fifteen reps at RPE 6 on the first back-off",
                 "note": "Take the last back-off heavier."}
        text = render_set_reply(reply, "Seated Leg Curl", self.CURL, 2)
        # 105 would be 12.5% under 120: the back-off stays at 100 and he is told why.
        self.assertIn("The card stays as it is", text)
        self.assertEqual(parse_all_prescriptions(text)[0]["backoff"][-1]["weight"], 100.0)

    def test_beating_the_range_moves_the_back_offs_up_and_names_the_load(self):
        from plan import owed_set_decision, render_set_reply
        owed = owed_set_decision({"actual_weight_kg": 270, "actual_reps": 11, "actual_rpe": 7}, self.PRESS, 1)
        self.assertEqual((owed["decision"], owed["scope"]), ("heavier", "remaining"))
        text = render_set_reply({**owed, "note": "Top set flew past the range."}, "Leg Press", self.PRESS, 1)
        backs = [b["weight"] for b in parse_all_prescriptions(text)[0]["backoff"]]
        self.assertEqual(len(set(backs)), 1)
        self.assertGreater(backs[0], 215)
        self.assertLessEqual(backs[0], 0.85 * 270)
        self.assertIn("Card: Back-off 1:", text)
        self.assertIn("(from 215kg)", text)
        # Inside the range, or above the target RPE: nothing is owed.
        self.assertIsNone(owed_set_decision({"actual_weight_kg": 270, "actual_reps": 9, "actual_rpe": 7}, self.PRESS, 1))
        self.assertIsNone(owed_set_decision({"actual_weight_kg": 270, "actual_reps": 11, "actual_rpe": 8.5}, self.PRESS, 1))

    def test_a_revised_back_off_far_under_the_top_set_is_handed_back_unless_a_cause_is_named(self):
        from plan import set_reply_problems
        tri = {"working": [{"load_kg": 37.5, "reps_low": 8, "reps_high": 12, "rpe": 8}],
               "backoff": [{"load_kg": 30, "reps_low": 12, "reps_high": 15, "rpe": 7}], "tempo": "", "rest_seconds": 90}
        reply = {"decision": "revise", "note": "Real drop for the back-off.", "steps": 1, "scope": "next",
                 "reason": "you missed the floor at RPE9 so the back-off needs a real drop",
                 "revised": {"load_kg": 27.5, "reps_low": 12, "reps_high": 15, "rpe": 7}}
        self.assertTrue(set_reply_problems(reply, "Tricep Pushdown", tri, 1, logged_top=40.0))
        pain = {**reply, "reason": "elbow pain on the top set, lighter back-off"}
        self.assertEqual(set_reply_problems(pain, "Tricep Pushdown", tri, 1, logged_top=40.0), [])


class SetCountGuardTests(unittest.TestCase):
    def _prompt(self):
        with open("system_prompt.txt") as fh:
            return fh.read()

    def test_ordinary_words_are_not_a_reason_to_owe_fewer_sets(self):
        from coach_parsing import _revision_names_a_cause
        for line in ("Revised: back-off dropped to 27.5kg after the RPE9 top set",
                     "Revised: 12.5kg on the lateral raise", "Revised: still 27.5, you will get 12 this time",
                     "Revised: add a plate", "Revised: cable stack jump"):
            self.assertFalse(_revision_names_a_cause(line), line)
        for line in ("Revised: elbow pain on the last back-off", "Revised: machine taken, one back-off today",
                     "Revised: out of time, one back-off", "Revised: knee is sore"):
            self.assertTrue(_revision_names_a_cause(line), line)

    def test_a_revised_one_back_off_block_for_a_three_set_lift_is_padded(self):
        from coach_parsing import enforce_set_counts
        reply = "*Tricep Pushdown*\nWorking Set: 37.5kg x8-12 RPE8 | Rest: 90s\nBack-off: 27.5kg x12-15 RPE7\nRevised: back-off dropped to 27.5kg\n"
        out, _ = enforce_set_counts(reply, self._prompt(), "Push")
        self.assertEqual(len(parse_all_prescriptions(out)[0]["backoff"]), 2)

    def test_two_back_off_lines_are_folded_into_one_the_parsers_can_read(self):
        from coach_parsing import enforce_set_counts
        reply = ("*Tricep Pushdown*\nWorking Set: 37.5kg x8-12 RPE8 | Rest: 90s\n"
                 "Back-off: 30kg x12-15 RPE7\nBack-off: 30kg x10-13 RPE7\n")
        out, _ = enforce_set_counts(reply, self._prompt(), "Push")
        self.assertEqual(len(parse_all_prescriptions(out)[0]["backoff"]), 2)
        self.assertEqual(out.count("Back-off:"), 1)

    def test_a_revised_surplus_is_trimmed_unless_the_revision_adds_a_set(self):
        from coach_parsing import enforce_set_counts
        three = ("*Tricep Pushdown*\nWorking Set: 40kg x7 RPE9 | Rest: 90s\n"
                 "Back-off: 27.5kg x14 RPE7, 27.5kg x12-15 RPE7, 25kg x12-15 RPE7\nRevised: corrected the back-off count\n")
        out, _ = enforce_set_counts(three, self._prompt(), "Push")
        self.assertEqual(len(parse_all_prescriptions(out)[0]["backoff"]), 2)
        added = three.replace("corrected the back-off count", "an extra back-off today, he asked for one")
        out, _ = enforce_set_counts(added, self._prompt(), "Push")
        self.assertEqual(len(parse_all_prescriptions(out)[0]["backoff"]), 3)


class WatchAgreesWithTheProgrammeTests(unittest.TestCase):
    def test_a_deload_done_as_prescribed_is_not_ready_to_load(self):
        # Leg Extension: 115 x11 @9 in week 3, then 115 x8 @6 on the deload card.
        rows = [dict(_row("Leg Extension", d, 115, r, rpe), target_reps=t, target_rpe=tr)
                for d, r, rpe, t, tr in (("2026-09-09", 10, 8, 8, 8), ("2026-09-14", 11, 9, 8, 9), ("2026-09-18", 8, 6, 8, 6))]
        stall = progression.find_stalls(rows, min_sessions=3)[0]
        self.assertFalse(stall["increase_indicated"])
        self.assertNotIn("READY TO LOAD", progression.format_stalls([stall]))
        rows[1] = dict(rows[1], actual_reps=12)          # week 3 reached the top of 8-12
        self.assertTrue(progression.find_stalls(rows, min_sessions=3)[0]["increase_indicated"])

    def test_leg_extension_keeps_one_ramp_when_the_quads_are_warm(self):
        p = prescribe_exercise("Leg Extension", 2, ISOLATION, 1, PriorSet(115.0, 11, 9.0, week=3, step=5.0), {"Quads"})
        self.assertEqual(len(p.warmup), 1)
        curl = prescribe_exercise("Seated Leg Curl", 3, ISOLATION, 1, PriorSet(110.0, 11, 8.0, week=3, step=5.0), {"Hamstrings"})
        self.assertEqual(curl.warmup, [])


class CardSaysWhyTests(unittest.TestCase):
    def test_a_recovery_cut_is_explained_on_the_card(self):
        from prescribe import prescribe_session
        read = {"read": {"rpe_delta": -1.0, "load_multiplier": 1.0, "recovery_session": False,
                         "reasons": ["7-day HRV 8% below baseline, so RPE targets come down a point"]}}
        p = prescribe_session((("Leg Press", 3, COMPOUND),), 1, {"Leg Press": PriorSet(245, 15, 9.0, week=3, step=5)},
                              recovery=read)[0]
        block = parse_all_prescriptions(render_block(p))[0]
        self.assertIn("HRV", block.get("note") or "")

    def test_watch_dates_read_as_days(self):
        self.assertEqual(progression._day("2026-09-09"), "9 Sep")
