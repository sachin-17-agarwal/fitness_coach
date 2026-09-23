"""The diet prompt (system_prompt.next.txt) parses exactly like the full one
wherever code reads the prompt, and is a fraction of its size."""

import os
import re
import unittest

from coach_parsing import _WEAK_POINT_SLOT_RE, parse_session_template
from weakpoints import parse_volume_bands


def _read(name):
    with open(name, encoding="utf-8") as handle:
        return handle.read()


FULL, DIET = _read("system_prompt.txt"), _read("system_prompt.next.txt")


class PromptDietTests(unittest.TestCase):

    def test_the_templates_parse_identically(self):
        for session in ("Pull", "Push", "Legs", "Cardio+Abs"):
            self.assertEqual(parse_session_template(DIET, session), parse_session_template(FULL, session), session)
            pairs, total = parse_session_template(DIET, session)
            self.assertTrue(pairs, session)
            self.assertEqual(sum(sets for _, sets in pairs), total, session)

    def test_the_bands_parse_identically(self):
        self.assertEqual(parse_volume_bands(DIET), parse_volume_bands(FULL))
        self.assertEqual(parse_volume_bands(DIET)["Rear Delts"], (8, 14))

    def test_the_weak_point_slots_are_still_named(self):
        pairs, _ = parse_session_template(DIET, "Cardio+Abs")
        self.assertEqual(sum(1 for name, _ in pairs if _WEAK_POINT_SLOT_RE.match(name)), 2)

    def test_the_formats_the_app_parses_are_present(self):
        for needle in ("Working Set:", "Back-off:", "Warm-up:", "Form:", "Revised:", "Decision: Cable Crunch | clear",
                       "Proposed: Emphasis-next:", "Session done"):
            self.assertIn(needle, DIET, needle)

    def test_the_rules_the_22_and_23_sep_sessions_broke_are_said(self):
        for needle in ("Back-off: 85kg x10 RPE7, 85kg x8 RPE7", "Never two `Back-off:` lines",
                       "only a week 3 that reached the top of the range opens one increment up",
                       "15-25% under the top set he actually lifted", "beats the top of its range at or under the target RPE",
                       "transition parser", "Another lift's sets are never evidence for this one",
                       "the calf raise keeps its `Warm-up:` line", "a recovery-cut rep band is today's reps in reserve".capitalize()[0:0] + "A recovery-cut rep band is today's reps in reserve",
                       "refusing twice is not"):
            self.assertIn(needle, DIET, needle)

    def test_the_diet_is_a_fraction_of_the_full_prompt_and_has_no_briefing(self):
        self.assertLess(len(DIET), 0.45 * len(FULL))
        self.assertGreater(len(DIET), 20_000)
        self.assertNotIn("briefing", DIET.lower())      # retired 20 Sep 2026: nothing ever sent one

    def test_the_loader_defaults_to_the_diet_and_honours_prompt_file(self):
        import coach
        saved, coach._SYSTEM_PROMPT_CACHE = coach._SYSTEM_PROMPT_CACHE, None
        try:
            os.environ.pop("PROMPT_FILE", None)
            self.assertEqual(coach.load_system_prompt(), DIET)
            coach._SYSTEM_PROMPT_CACHE = None
            os.environ["PROMPT_FILE"] = "system_prompt.txt"
            self.assertEqual(coach.load_system_prompt(), FULL)
        finally:
            os.environ.pop("PROMPT_FILE", None)
            coach._SYSTEM_PROMPT_CACHE = saved
