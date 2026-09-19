"""The block review as a coach conversation (roadmap 2.5): numbers from
code, the model phrases and proposes, nothing recorded without a yes, the
first block a dry run."""

import json
import unittest
from unittest.mock import patch

import block_review as br


def _set(date, ex, w, reps, sid):
    return {"date": date, "exercise": ex, "workout_session_id": sid, "is_warmup": False,
            "actual_weight_kg": w, "actual_reps": reps, "actual_rpe": 8}


class WindowTests(unittest.TestCase):
    SESSIONS = [{"date": f"2026-08-{d:02d}", "mesocycle_week": None, "mesocycle_day": None} for d in range(1, 17)] + \
               [{"date": f"2026-09-{d:02d}", "mesocycle_week": None, "mesocycle_day": None} for d in range(1, 15)]

    def test_the_morning_after_rollover_reviews_the_block_just_ended(self):
        sessions = list(self.SESSIONS)
        sessions[16]["mesocycle_week"], sessions[16]["mesocycle_day"] = 1, 1   # 1 Sep opened the last block
        w = br.review_window(sessions, {"mesocycle_week": 1, "mesocycle_day": 1}, "2026-09-16")
        # Week 1 day 1 with no new session stamped: block_start still names
        # the block that just ended, so [1 Sep, today] is it, complete, and the
        # sixteen sessions before it are the previous block.
        self.assertTrue(w["complete"])
        self.assertEqual((w["since"], w["until"]), ("2026-09-01", "2026-09-16"))
        self.assertEqual((w["prev_since"], w["prev_until"]), ("2026-08-01", "2026-08-16"))

    def test_rollover_with_no_stamp_in_reach_is_still_the_last_sixteen_sessions(self):
        # 19 Sep 2026: no session stamped week 1 day 1, the last session is
        # today. block_start would say "today"; the review must not.
        sessions = [{"date": f"2026-08-{d:02d}", "mesocycle_week": None, "mesocycle_day": None} for d in range(1, 17)] + \
                   [{"date": f"2026-09-{d:02d}", "mesocycle_week": None, "mesocycle_day": None} for d in range(4, 20)]
        w = br.review_window(sessions, {"mesocycle_week": 1, "mesocycle_day": 1}, "2026-09-19")
        self.assertTrue(w["complete"])
        self.assertEqual((w["since"], w["until"]), ("2026-09-04", "2026-09-19"))
        self.assertEqual((w["prev_since"], w["prev_until"]), ("2026-08-01", "2026-08-16"))
        self.assertEqual(w["block_start"], "2026-09-04")
        self.assertEqual(w["last_session"], "2026-09-19")

    def test_a_block_that_ran_long_still_starts_at_its_stamped_opening(self):
        # Sixteen sessions over 45 days: the five-week floor in block_start
        # misses the stamp, the ended-block range does not.
        dates = [f"2026-08-{d:02d}" for d in range(5, 32, 3)] + [f"2026-09-{d:02d}" for d in range(3, 20, 3)]
        sessions = [{"date": d, "mesocycle_week": None, "mesocycle_day": None} for d in dates]
        sessions[0]["mesocycle_week"], sessions[0]["mesocycle_day"] = 1, 1
        w = br.review_window(sessions, {"mesocycle_week": 1, "mesocycle_day": 1}, "2026-09-19")
        self.assertEqual(w["since"], "2026-08-05")
        self.assertEqual(w["until"], "2026-09-19")

    def test_mid_block_reviews_the_block_in_progress(self):
        sessions = list(self.SESSIONS)
        sessions[16]["mesocycle_week"], sessions[16]["mesocycle_day"] = 1, 1
        w = br.review_window(sessions, {"mesocycle_week": 3, "mesocycle_day": 2}, "2026-09-16")
        self.assertFalse(w["complete"])
        self.assertEqual(w["since"], "2026-09-01")
        self.assertEqual(w["until"], "2026-09-16")


class CardStructureTests(unittest.TestCase):
    def test_the_narrative_splits_into_labelled_sections(self):
        text = ("Strength: peak week against peak week shows Leg Press up 3%.\n\n"
                "Volume: every tracked muscle sits under its band.\n\n"
                "What to change: the standing constraints remain in force.\n\n"
                "Cable Crunch held at 147.0kg: a stale comparison.")
        sections = br.review_sections(text)
        self.assertEqual([s["label"] for s in sections], ["STRENGTH", "VOLUME", "WHAT TO CHANGE", ""])
        self.assertEqual(sections[0]["body"], "peak week against peak week shows Leg Press up 3%.")
        self.assertEqual(sections[3]["body"], "Cable Crunch held at 147.0kg: a stale comparison.")

    def test_the_model_answers_in_four_named_paragraphs_that_become_the_narrative(self):
        data = {"strength": "Most lifts moved up; Dips led at +26.5%.", "volume": "Chest sat under its band.",
                "recovery": "", "changes": "Nothing to change.", "proposals": []}
        narrative = br.assemble_narrative(data)
        self.assertEqual(narrative, "Strength: Most lifts moved up; Dips led at +26.5%.\n\n"
                                    "Volume: Chest sat under its band.\n\nWhat to change: Nothing to change.")
        self.assertEqual([x["label"] for x in br.review_sections(narrative)], ["STRENGTH", "VOLUME", "WHAT TO CHANGE"])
        self.assertEqual(br.assemble_narrative({"narrative": "Legacy text."}), "Legacy text.")
        self.assertEqual(set(br.REVIEW_SCHEMA["required"]), {"strength", "volume", "recovery", "changes", "proposals"})

    def test_card_rows_come_from_the_sheet_largest_rise_first(self):
        facts = json.dumps({"strength": [
            {"exercise": "Leg Press", "delta_pct": -2.2, "verdict": "held", "this_set": "245kg x15", "prev_set": "240kg x14"},
            {"exercise": "Dips", "delta_pct": 26.5, "verdict": "pr", "this_set": "40kg x10", "prev_set": "30kg x10"},
            {"exercise": "Incline Press", "this_set": "91kg x8", "verdict": "first block"}],
            "volume": [{"muscle": "Chest", "sets_per_week": 6.0, "band": "10-16", "under_by": 4.0, "over_by": 0}]})
        rows = br.card_rows(facts)
        self.assertEqual([r["exercise"] for r in rows["lifts"]], ["Dips", "Leg Press", "Incline Press"])
        self.assertFalse(rows["lifts"][0]["loose"])
        self.assertIsNone(rows["lifts"][2]["delta_pct"])
        self.assertEqual(rows["volume"], [{"muscle": "Chest", "sets": 6.0, "band": "10-16", "under_by": 4.0, "over_by": 0}])
        self.assertEqual(br.card_rows(None), {"lifts": [], "volume": []})

    def test_a_proposal_line_splits_into_kind_subject_and_detail(self):
        self.assertEqual(br.proposal_parts("Emphasis-next: Triceps | still under band; keep as emphasis"),
                         {"kind": "emphasis", "subject": "Triceps", "detail": "still under band; keep as emphasis"})
        self.assertEqual(br.proposal_parts("Decision: Leg Press | max load 242.5kg | open heavier"),
                         {"kind": "decision", "subject": "Leg Press", "detail": "max load 242.5kg · open heavier"})
        clear = br.proposal_parts("Decision: Cable Crunch | clear")
        self.assertEqual(clear["kind"], "standing decision")
        self.assertEqual(clear["subject"], "Cable Crunch")
        self.assertTrue(clear["detail"].startswith("Clear it"))


class FactTests(unittest.TestCase):
    WINDOW = {"since": "2026-09-01", "until": "2026-09-14", "prev_since": "2026-08-16", "prev_until": "2026-08-31"}

    def test_strength_is_peak_week_against_peak_week_with_a_verdict(self):
        rows = [_set("2026-08-28", "Leg Press", 200, 10, "p3"), _set("2026-08-20", "Leg Press", 220, 8, "p1"),
                _set("2026-09-12", "Leg Press", 230, 10, "t3"), _set("2026-09-04", "Leg Press", 240, 6, "t1"),
                _set("2026-09-12", "Seated Leg Curl", 110, 16, "t3"), _set("2026-09-05", "Seated Leg Curl", 105, 11, "t1")]
        weeks = {"p3": 3, "p1": 1, "t3": 3, "t1": 1}
        facts = {f["exercise"]: f for f in br.strength_facts(rows, weeks, self.WINDOW)}
        lp = facts["Leg Press"]
        self.assertEqual((lp["this_set"], lp["prev_set"]), ("230kg x10", "200kg x10"))   # peak weeks, not block bests
        self.assertEqual(lp["delta_pct"], 15.0)
        self.assertEqual(lp["verdict"], "up")
        # A 16-rep peak-week set is a looser estimate, not a missing one: it
        # stands, marked loose, exactly as the app's strength page reads it.
        slc = facts["Seated Leg Curl"]
        self.assertEqual(slc["this_set"], "110kg x16")
        self.assertTrue(slc["this_from_peak_week"])
        self.assertTrue(slc["this_loose"])
        self.assertEqual(slc["verdict"], "first block")
        self.assertFalse(lp["this_loose"])

    def test_a_lift_under_a_standing_decision_reads_held_not_down_unless_it_rose(self):
        # 19 Sep 2026: Machine Shoulder Press -21.7% under its 70kg cap read
        # red "down" on the card while the strength page read HELD.
        rows = [_set("2026-08-20", "Machine Shoulder Press", 70, 12, "p3"), _set("2026-09-12", "Machine Shoulder Press", 55, 11, "t3"),
                _set("2026-08-20", "Cable Crunch", 100, 12, "p3"), _set("2026-09-12", "Cable Crunch", 105, 12, "t3"),
                _set("2026-08-20", "Leg Press", 240, 12, "p3"), _set("2026-09-12", "Leg Press", 205, 12, "t3")]
        weeks = {"p3": 3, "t3": 3}
        from constraints import norm_name
        held = {norm_name("Machine Shoulder Press"), norm_name("Cable Crunch")}
        facts = {f["exercise"]: f for f in br.strength_facts(rows, weeks, self.WINDOW, held)}
        self.assertEqual(facts["Machine Shoulder Press"]["verdict"], "held")
        self.assertTrue(facts["Machine Shoulder Press"]["held_by_decision"])
        self.assertEqual(facts["Cable Crunch"]["verdict"], "up")          # a rise under a hold still reads up
        self.assertEqual(facts["Leg Press"]["verdict"], "down")           # no decision on it: a drop is a drop
        # Flat with no decision is "flat", never "held": Lat Pulldown -0.6% read HELD on the card.
        flat = br.strength_facts([_set("2026-08-20", "Lat Pulldown", 85, 10, "p3"), _set("2026-09-12", "Lat Pulldown", 85, 10, "t3")],
                                 weeks, self.WINDOW, held)
        self.assertEqual(flat[0]["verdict"], "flat")
        self.assertNotIn("held_by_decision", flat[0])
        sheet = br.format_facts({"window": {"since": "2026-09-01", "until": "2026-09-14", "complete": True},
                                 "strength": [facts["Machine Shoulder Press"]], "volume": [], "recovery": {},
                                 "emphasis": [], "emphasis_next": [], "standing_constraints": "", "adjustments": []})
        self.assertIn("— held (standing decision: flat because it was told to be)", sheet)

    def test_the_best_estimate_wins_and_a_set_past_12_reps_is_marked(self):
        # 19 Sep 2026: the leg curl's peak week was 110 x 16 and the review
        # had compared a week-1 100 x 11 instead; Leg Press's 245 x 15 top set
        # lost to a lighter 12-rep set beside it and read "flat".
        rows = [_set("2026-08-20", "Seated Leg Curl", 100, 12, "p3"),
                _set("2026-09-05", "Seated Leg Curl", 100, 11, "t1"), _set("2026-09-14", "Seated Leg Curl", 110, 16, "t3"),
                _set("2026-08-20", "Leg Press", 240, 14, "p3"),
                _set("2026-09-14", "Leg Press", 245, 15, "t3"), _set("2026-09-14", "Leg Press", 205, 12, "t3")]
        weeks = {"p3": 3, "t1": 1, "t3": 3}
        facts = {f["exercise"]: f for f in br.strength_facts(rows, weeks, self.WINDOW)}
        slc = facts["Seated Leg Curl"]
        self.assertEqual((slc["this_set"], slc["prev_set"]), ("110kg x16", "100kg x12"))
        self.assertTrue(slc["this_loose"]); self.assertFalse(slc["prev_loose"])
        self.assertEqual(slc["verdict"], "up")
        lp = facts["Leg Press"]
        self.assertEqual((lp["this_set"], lp["prev_set"]), ("245kg x15", "240kg x14"))
        self.assertTrue(lp["this_loose"])
        self.assertEqual(lp["verdict"], "up")
        self.assertAlmostEqual(lp["delta_pct"], 4.5, places=0)
        # A set past 20 reps is still ignored.
        self.assertEqual(br.strength_facts([_set("2026-09-14", "Calf Raise", 60, 25, "t3")], weeks, self.WINDOW), [])
        sheet = br.format_facts({"window": {"since": "2026-09-01", "until": "2026-09-14", "complete": True},
                                 "strength": [slc], "volume": [], "recovery": {}, "emphasis": [], "emphasis_next": [],
                                 "standing_constraints": "", "adjustments": []})
        self.assertIn("[estimate from a set past 12 reps, as the app shows it]", sheet)

    def test_recovery_is_the_block_mean_against_the_42_days_before(self):
        rows = [{"date": "2026-08-01", "hrv": 40, "resting_hr": 60, "sleep_hours": 7.5},
                {"date": "2026-08-20", "hrv": 44, "resting_hr": 58, "sleep_hours": 6.0},
                {"date": "2026-09-03", "hrv": 50, "resting_hr": 56, "sleep_hours": 6.5, "readiness": 4},
                {"date": "2026-09-10", "hrv": 46, "resting_hr": 58, "sleep_hours": 8.0, "readiness": 5}]
        r = br.recovery_facts(rows, self.WINDOW)
        self.assertEqual(r["hrv_block_mean"], 48.0)
        self.assertEqual(r["hrv_baseline_mean"], 42.0)
        self.assertEqual(r["short_nights"], 1)
        self.assertEqual(r["nights_recorded"], 2)
        self.assertEqual((r["readiness_taps"], r["readiness_mean"]), (2, 4.5))

    def test_the_sheet_reads_as_lines_the_model_can_quote(self):
        facts = {"window": {**self.WINDOW, "complete": True},
                 "strength": [{"exercise": "Leg Press", "this_e1rm": 306.7, "this_set": "230kg x10", "prev_e1rm": 266.7,
                               "prev_set": "200kg x10", "delta_pct": 15.0, "verdict": "up", "this_from_peak_week": True}],
                 "volume": [{"muscle": "Hamstrings", "sets_per_week": 8.1, "band": "10-16", "under_by": 1.9}],
                 "recovery": {"hrv_block_mean": 48.0, "hrv_baseline_mean": 42.0, "short_nights": 1, "nights_recorded": 2},
                 "emphasis": ["triceps"], "standing_constraints": "", "adjustments": []}
        text = br.format_facts(facts)
        self.assertIn("Leg Press: 306.7kg (230kg x10) vs 266.7kg (200kg x10) = +15% — up", text)
        self.assertIn("Hamstrings: 8.1 against 10-16 — UNDER by 1.9", text)
        self.assertIn("HRV: 48.0 vs baseline 42.0", text)
        self.assertIn("WEAK-POINT WORK THAT RAN THIS BLOCK", text)


class NarrativeChecksTests(unittest.TestCase):

    def test_a_number_the_sheet_lacks_is_caught_and_small_counts_are_allowed(self):
        sheet = "Leg Press: 306.7kg vs 266.7kg = +15% — up\nHRV: 48.0 vs baseline 42.0"
        self.assertEqual(br.numbers_not_in_sheet("Leg press up 15% to 306.7kg; HRV 48.0. Two lifts held.", sheet), [])
        self.assertEqual(br.numbers_not_in_sheet("Leg press up 17% to 310kg", sheet), ["17", "310"])

    def test_only_recordable_lines_survive_as_proposals(self):
        props = [{"line": "Decision: Machine Shoulder Press | max load 70kg | shoulder niggle", "rationale": "held"},
                 {"line": "Emphasis-next: triceps | overhead cable extension", "rationale": "band top"},
                 {"line": "Add a fifth set of curls", "rationale": "vibes"},
                 {"line": "Decision: Cable Crunch | clear", "rationale": "stack changed"},
                 {"line": "Emphasis-next: chest | fly", "rationale": "x"}]
        kept = [p["line"] for p in br.valid_proposals(props)]
        self.assertEqual(len(kept), 3)
        self.assertNotIn("Add a fifth set of curls", kept)

    def test_an_emphasis_must_name_a_muscle_under_its_band_and_not_already_set(self):
        # 19 Sep 2026: "Emphasis-next: Triceps | Trim weekly sets…" for a
        # muscle over its band that was already queued with its movement.
        facts = {"volume": [{"muscle": "Biceps", "sets_per_week": 15.6, "band": "8-12", "under_by": 0, "over_by": 3.6},
                            {"muscle": "Triceps", "sets_per_week": 13.2, "band": "8-12", "under_by": 0, "over_by": 1.2},
                            {"muscle": "Rear Delts", "sets_per_week": 4.0, "band": "8-14", "under_by": 4.0, "over_by": 0},
                            {"muscle": "Chest", "sets_per_week": 6.0, "band": "10-16", "under_by": 4.0, "over_by": 0}],
                 "emphasis_next": [{"muscle": "Triceps", "note": "Overhead Cable Extension"},
                                   {"muscle": "Chest", "note": "Cable Fly (Low To High)"}]}
        props = [{"line": "Emphasis-next: Biceps | Trim weekly sets toward the 8-12 band", "rationale": "over"},
                 {"line": "Emphasis-next: Triceps | Trim weekly sets toward the 8-12 band", "rationale": "over"},
                 {"line": "Emphasis-next: Chest | Cable Fly", "rationale": "already set"},
                 {"line": "Emphasis-next: Rear Delts | Face Pull", "rationale": "under by 4.0"},
                 {"line": "Decision: Leg Press | max load 242.5kg | open heavier", "rationale": "note"}]
        kept = [p["line"] for p in br.valid_proposals(props, facts)]
        self.assertEqual(kept, ["Emphasis-next: Rear Delts | Face Pull",
                                "Decision: Leg Press | max load 242.5kg | open heavier"])
        # Without a sheet the grammar alone decides, as before.
        self.assertEqual(len(br.valid_proposals(props)), 3)

    def test_the_sheet_names_next_blocks_emphasis_and_over_band_muscles(self):
        facts = {"window": {"since": "2026-09-02", "until": "2026-09-19", "complete": True},
                 "strength": [], "recovery": {},
                 "volume": [{"muscle": "Biceps", "sets_per_week": 15.6, "band": "8-12", "under_by": 0, "over_by": 3.6},
                            {"muscle": "Chest", "sets_per_week": 6.0, "band": "10-16", "under_by": 4.0, "over_by": 0}],
                 "emphasis": ["Triceps", "Chest"],
                 "emphasis_next": [{"muscle": "Triceps", "note": "Overhead Cable Extension"}],
                 "standing_constraints": "", "adjustments": []}
        sheet = br.format_facts(facts)
        self.assertIn("Biceps: 15.6 against 8-12 — OVER by 3.6 (not an Emphasis-next)", sheet)
        self.assertIn("Chest: 6.0 against 10-16 — UNDER by 4.0", sheet)
        self.assertIn("NEXT BLOCK'S EMPHASIS, already set by the athlete (do not propose again): Triceps → Overhead Cable Extension", sheet)


    def test_a_bodyweight_lift_is_scored_plate_plus_body_as_the_app_does(self):
        # Dips +26.5% on the plate alone (20kg vs 15kg); with an 80kg body
        # behind both it is a few percent.
        rows = [_set("2026-08-20", "Dips", 15, 8, "p3"), _set("2026-09-12", "Dips", 20, 7, "t3")]
        weeks = {"p3": 3, "t3": 3}
        weigh = [("2026-08-01", 79.0), ("2026-09-10", 81.0)]
        fact = br.strength_facts(rows, weeks, FactTests.WINDOW, weigh=weigh)[0]
        self.assertTrue(fact["bodyweight"])
        self.assertEqual(fact["this_set"], "20kg x7")                       # the plate is what is shown
        self.assertAlmostEqual(fact["this_e1rm"], (20 + 81) * (1 + 7 / 30), places=1)
        self.assertAlmostEqual(fact["prev_e1rm"], (15 + 79) * (1 + 8 / 30), places=1)
        self.assertTrue(-2 < fact["delta_pct"] < 6)
        # Without weigh-ins the plate alone, and the flag says so.
        bare = br.strength_facts(rows, weeks, FactTests.WINDOW)[0]
        self.assertFalse(bare["bodyweight"])
        self.assertEqual(br.kg_on(weigh, "2026-09-11"), 81.0)
        self.assertEqual(br.kg_on(weigh, "2026-07-01"), 79.0)
        self.assertIsNone(br.kg_on([], "2026-09-11"))

    def test_one_lift_under_two_names_is_one_lift_when_the_library_says_so(self):
        rows = [_set("2026-08-20", "Incline Barbell Press", 65, 8, "p3"),
                _set("2026-09-05", "Incline Press", 70, 9, "t1"), _set("2026-09-12", "Incline Barbell Press", 70, 7, "t3")]
        weeks = {"p3": 3, "t1": 1, "t3": 3}
        canon = {"incline barbell press": "Incline Barbell Press", "incline press": "Incline Barbell Press"}
        facts = br.strength_facts(rows, weeks, FactTests.WINDOW, canon=canon)
        self.assertEqual([f["exercise"] for f in facts], ["Incline Barbell Press"])
        self.assertEqual(facts[0]["this_set"], "70kg x7")          # the peak-week set, under either spelling
        self.assertEqual(facts[0]["verdict"], "up")
        # Without the alias they stay two lifts, one of them "first block".
        split = {f["exercise"]: f["verdict"] for f in br.strength_facts(rows, weeks, FactTests.WINDOW)}
        self.assertEqual(split, {"Incline Barbell Press": "up", "Incline Press": "first block"})

    def test_the_emphasis_that_ran_comes_from_cardio_abs_sets_not_a_pick_row(self):
        sessions = [{"id": "c1", "date": "2026-09-05", "type": "Cardio+Abs"}, {"id": "l1", "date": "2026-09-06", "type": "Legs"},
                    {"id": "c2", "date": "2026-09-09", "type": "Cardio+Abs"}]
        rows = [_set("2026-09-05", "Cable Crunch", 100, 12, "c1"), _set("2026-09-05", "Pallof Press", 50, 12, "c1"),
                _set("2026-09-06", "Seated Leg Curl", 110, 12, "l1"),
                _set("2026-09-09", "Overhead Cable Extension", 25, 12, "c2"), _set("2026-09-09", "Overhead Cable Extension", 25, 11, "c2")]
        window = {"since": "2026-09-01", "until": "2026-09-14"}
        ran = br.emphasis_that_ran(rows, sessions, window)
        self.assertEqual(ran, [{"muscle": "Triceps", "sets": 2, "exercises": ["Overhead Cable Extension"]}])
        abs_only = [r for r in rows if r["workout_session_id"] == "c1"]
        self.assertEqual(br.emphasis_that_ran(abs_only, sessions, window), [])
        sheet = br.format_facts({"window": {"since": "2026-09-01", "until": "2026-09-14", "complete": True},
                                 "strength": [], "volume": [], "recovery": {}, "emphasis": [], "emphasis_ran": [],
                                 "emphasis_stored": ["Hamstrings"], "emphasis_next": [], "standing_constraints": "",
                                 "adjustments": []})
        self.assertIn("none — every Cardio+Abs day ended after the ab block", sheet)
        self.assertIn("a stored pick named Hamstrings; it did not run, so it was not this block's emphasis", sheet)

    def test_every_standing_decision_is_put_to_the_athlete_as_keep_or_clear(self):
        constraints = [{"exercise": "Machine Shoulder Press", "max_load_kg": 70, "note": "shoulder niggle", "set_on": "2026-09-13"},
                       {"exercise": "Leg Press", "max_load_kg": None, "note": "open heavier than 242.5kg", "set_on": "2026-09-14"}]
        strength = [{"exercise": "Machine Shoulder Press", "this_e1rm": 75.2, "this_set": "55kg x11", "prev_e1rm": 96.0,
                     "prev_set": "70kg x12", "delta_pct": -21.7, "verdict": "held", "held_by_decision": True,
                     "this_from_peak_week": True, "this_loose": False, "prev_loose": False}]
        props = br.constraint_proposals(constraints, strength)
        self.assertEqual([p["line"] for p in props], ["Decision: Machine Shoulder Press | clear", "Decision: Leg Press | clear"])
        self.assertIn("70kg cap since 2026-09-13: shoulder niggle. This block: 55kg x11, -21.7% on last block's peak.", props[0]["rationale"])
        self.assertIn("Approve to clear it; leave it to keep it.", props[1]["rationale"])
        for p in props:
            self.assertTrue(br._LINE_RE.match(p["line"]), p["line"])
        sheet = br.format_facts({"window": {"since": "2026-09-01", "until": "2026-09-14", "complete": True},
                                 "strength": strength, "volume": [], "recovery": {}, "emphasis": [], "emphasis_ran": [],
                                 "emphasis_next": [], "standing_constraints": "x", "adjustments": [],
                                 "standing": constraints})
        self.assertIn("STANDING DECISIONS IN FORCE — the card asks keep-or-clear for each; recommend one:", sheet)
        self.assertIn("Machine Shoulder Press: max load 70kg, since 2026-09-13 — shoulder niggle — this block 55kg x11, -21.7%", sheet)
        self.assertIn("Leg Press: note, since 2026-09-14 — open heavier than 242.5kg", sheet)


class AnswerTests(unittest.TestCase):

    def test_parse_answer_forms(self):
        self.assertEqual(br.parse_answer("yes to 1 and 3", 3), [1, 3])
        self.assertEqual(br.parse_answer("Approve all", 3), [1, 2, 3])
        self.assertEqual(br.parse_answer("yes", 1), [1])
        self.assertEqual(br.parse_answer("no", 3), [])
        self.assertIsNone(br.parse_answer("yes to 7", 3))
        self.assertIsNone(br.parse_answer("what about the leg curl?", 3))

    def test_a_dry_run_answer_records_nothing_and_says_so(self):
        row = {"id": 1, "dry_run": True, "proposals_list": [
            {"line": "Decision: Machine Shoulder Press | max load 70kg | shoulder niggle", "rationale": ""},
            {"line": "Emphasis-next: triceps | overhead cable extension", "rationale": ""}]}
        with patch("constraints.record_decisions") as rec, patch("weakpoints.set_next_emphasis") as emph, \
             patch("block_review.get_supabase", return_value=None):
            msg = br.answer_block_review(row, "yes to 1 and 2", "PROMPT")
        self.assertFalse(rec.called)
        self.assertFalse(emph.called)
        self.assertIn("dry run", msg)
        self.assertIn("Machine Shoulder Press", msg)

    def test_a_live_answer_applies_each_line_through_the_existing_path(self):
        row = {"id": 1, "dry_run": False, "proposals_list": [
            {"line": "Decision: Machine Shoulder Press | max load 70kg | shoulder niggle", "rationale": ""},
            {"line": "Emphasis-next: triceps | overhead cable extension", "rationale": ""}]}
        with patch("constraints.record_decisions") as rec, patch("weakpoints.set_next_emphasis") as emph, \
             patch("block_review.get_supabase", return_value=None):
            msg = br.answer_block_review(row, "approve all", "PROMPT")
        rec.assert_called_once_with("Decision: Machine Shoulder Press | max load 70kg | shoulder niggle")
        emph.assert_called_once_with("PROMPT", "triceps", "overhead cable extension")
        self.assertIn("Recorded for next block", msg)

    def test_render_numbers_the_proposals_and_flags_the_dry_run(self):
        row = {"narrative": "A good block.", "dry_run": True,
               "proposals_list": [{"line": "Emphasis-next: chest | low-to-high fly", "rationale": "band has room"}]}
        text = br.render_review(row)
        self.assertIn("1. Emphasis-next: chest | low-to-high fly", text)
        self.assertIn("yes to 1 and 3", text)
        self.assertIn("Dry run", text)


class PrepareIfDueTests(unittest.TestCase):

    def test_nothing_is_prepared_mid_block_or_mid_session(self):
        self.assertIsNone(br.prepare_if_due({"mesocycle_week": 2, "mesocycle_day": 3}, "P", None))
        with patch("workout.get_workout_state", return_value={"workout_mode": "active"}):
            self.assertIsNone(br.prepare_if_due({"mesocycle_week": 1, "mesocycle_day": 1}, "P", None))
