"""The programme, swept.

Every session type, every week, a dozen shapes of history (none, normal, at
the top of the range, over it, under it, bodyweight, zero, missing reps and
RPE, absurd, junk strings, a 1kg load, a half-kilo load, NaN) with and without
a peak week, under eleven recovery states including garbage readings. For
every combination: nothing raises, the same inputs give the same session, and
every prescribed set obeys the rules the prompt states — the week's RPE, the
rep range, the set count, a back-off 15-25% under the top set and descending,
and a rendered block that parses back to the numbers it was made from.

This is the "won't break anything" test. It runs in about two seconds.
"""

import math
import unittest

from coach_parsing import (parse_all_prescriptions, parse_session_template,
                           substitute_computed_blocks)
from prescribe import (TOP_SET_RANGE, WAVE, _is_straight_set, day_plan,
                       is_determined, prescribe_session, recovery_adjustment,
                       render_block, render_session)
from programme import _history, format_proposal

VARIANTS = ("none", "normal", "top", "over", "low", "bw", "zero", "missing",
            "huge", "strings", "tiny", "halfkilo", "nan")

RECOVERY = [
    None, {},
    {"hrv": "N/A", "hrv_avg": "N/A", "sleep_hours": "N/A",
     "resting_hr": "N/A", "resting_hr_baseline": "N/A"},
    {"hrv": 50, "hrv_avg": 60, "sleep_hours": 7.5, "resting_hr": 55, "resting_hr_baseline": 55},
    {"hrv": 45, "hrv_avg": 60, "sleep_hours": 7.5},
    {"hrv": 60, "hrv_avg": 60, "sleep_hours": 4.5},
    {"hrv": 60, "hrv_avg": 60, "sleep_hours": 5.5},
    {"hrv": 52, "hrv_avg": 60, "sleep_hours": 5.5, "resting_hr": 64, "resting_hr_baseline": 55},
    {"hrv": "58", "hrv_avg": "62", "sleep_hours": "6"},
    {"hrv": None, "hrv_avg": 0, "sleep_hours": -1},
    {"hrv": object(), "hrv_avg": [1], "sleep_hours": {}},
]


def _rows(plan, variant):
    out = []
    for i, (name, _sets, kind) in enumerate(plan):
        row = {"exercise": name, "date": "2026-08-20"}
        if variant == "none":
            return []
        if variant == "normal": row.update(load=100.0 - 7 * i, reps=8, rpe=8.0)
        if variant == "top": row.update(load=55.0 + i, reps=TOP_SET_RANGE[kind][1], rpe=8.0)
        if variant == "over": row.update(load=55.0 + i, reps=14, rpe=9.5)
        if variant == "low": row.update(load=12.5, reps=4, rpe=6.0)
        if variant == "bw": row.update(load="BW", reps=11, rpe=8.0)
        if variant == "zero": row.update(load=0.0, reps=0, rpe=0.0)
        if variant == "missing": row.update(load=80.0, reps=None, rpe=None)
        if variant == "huge": row.update(load=999.0, reps=40, rpe=10.0)
        if variant == "strings": row.update(load="abc", reps="x", rpe="y")
        if variant == "tiny": row.update(load=1.0, reps=6, rpe=8.0)
        if variant == "halfkilo": row.update(load=55.5, reps=12, rpe=7.5)
        if variant == "nan": row.update(load=math.nan, reps=8, rpe=8.0)
        out.append(row)
    return out


class ProgrammeSweepTests(unittest.TestCase):
    PROMPT = None

    @classmethod
    def setUpClass(cls):
        with open("system_prompt.txt") as handle:
            cls.PROMPT = handle.read()

    def _check(self, session_type, plan, week, variant, peak_variant, recovery):
        history, _, _ = _history(plan, _rows(plan, variant))
        peak, _, _ = _history(plan, _rows(plan, peak_variant), week=3)
        props = prescribe_session(plan, week, history, recovery=recovery, peak_history=peak)
        again = prescribe_session(plan, week, history, recovery=recovery, peak_history=peak)
        blocks, _open = render_session(props)
        self.assertEqual(blocks, render_session(again)[0], "same inputs, same session")
        format_proposal(props, session_type, week, {}, {})

        adjustment = recovery_adjustment(recovery)
        determined = [p for p in props if is_determined(p)]
        parsed = {q["exercise"]: q for q in parse_all_prescriptions(blocks)}
        self.assertEqual(len(parsed), len(determined), "every determined block parses")

        for proposal, (name, sets, kind) in zip(props, plan):
            self.assertEqual(proposal.exercise, name)
            if adjustment.recovery_session:
                self.assertFalse(proposal.working, "a recovery day prescribes nothing")
                continue
            self.assertEqual(proposal.working_set_count, sets, f"{name}: set count")
            top = proposal.working[0]
            low, high = TOP_SET_RANGE[kind]
            self.assertAlmostEqual(top.rpe, WAVE[week]["top"] + adjustment.rpe_delta, msg=name)
            self.assertTrue(1 <= top.reps_low <= top.reps_high, f"{name}: reps {top}")
            if week != 4:
                self.assertGreaterEqual(top.reps_low, low - 1, f"{name}: below range")
                self.assertLessEqual(top.reps_high, high, f"{name}: above range")
            if top.weight_kg is not None:
                self.assertGreaterEqual(top.weight_kg, 0, name)
                self.assertAlmostEqual(top.weight_kg * 2, round(top.weight_kg * 2), msg=f"{name}: off the half-kilo grid")
            for back in proposal.backoff:
                self.assertAlmostEqual(back.rpe, WAVE[week]["backoff"] + adjustment.rpe_delta, msg=name)
                self.assertTrue(1 <= back.reps_low <= back.reps_high, name)
                if top.weight_kg and back.weight_kg is not None and not top.bodyweight:
                    self.assertLess(back.weight_kg, top.weight_kg, f"{name}: back-off not lighter")
                    if top.weight_kg >= 5:
                        drop = 1 - back.weight_kg / top.weight_kg
                        self.assertTrue(0.14 <= drop <= 0.26, f"{name}: back-off drop {drop:.2f}")
            if len(proposal.backoff) > 1:
                self.assertLess(proposal.backoff[1].reps_low, proposal.backoff[0].reps_low, name)
                self.assertEqual(proposal.backoff[1].weight_kg, proposal.backoff[0].weight_kg, name)
            if is_determined(proposal):
                card = parsed[name]["working"][0]
                self.assertEqual(card["reps"], top.reps_low, name)
                self.assertEqual(card.get("reps_high", top.reps_low), top.reps_high, f"{name}: band lost")
                self.assertEqual(card["rpe"], top.rpe, name)
                self.assertEqual(card["weight"], top.weight_kg or 0.0, name)
                if _is_straight_set(name):
                    self.assertEqual(len(parsed[name]["working"]), sets, name)
                    self.assertFalse(parsed[name].get("backoff"), name)
                else:
                    self.assertEqual(len(parsed[name].get("backoff", [])), len(proposal.backoff), name)

        reply = "\n\n".join(
            f"*{n}*\nWorking Set: 50kg x8 RPE7 | Rest: 2min\nBack-off: 40kg x10 RPE7"
            for n, _, _ in plan)
        computed = {p.exercise: render_block(p) for p in determined}
        out, swapped = substitute_computed_blocks(reply, computed)
        self.assertEqual(len(parse_all_prescriptions(out)), len(plan), "substitution lost a block")
        self.assertEqual(set(swapped), set(computed))

    def test_every_combination_holds(self):
        cases = 0
        for session_type in ("Push", "Pull", "Legs", "Cardio+Abs"):
            pairs, _ = parse_session_template(self.PROMPT, session_type)
            plan = day_plan(pairs)
            self.assertTrue(plan, session_type)
            for week in (1, 2, 3, 4):
                for variant in VARIANTS:
                    for peak_variant in ("none", "top"):
                        for recovery in RECOVERY:
                            cases += 1
                            with self.subTest(session=session_type, week=week, history=variant,
                                              peak=peak_variant, recovery=str(recovery)[:40]):
                                self._check(session_type, plan, week, variant, peak_variant, recovery)
        self.assertGreater(cases, 4000)


if __name__ == "__main__":
    unittest.main()
