-- The report's `out` column mixes thinking and the text the athlete actually
-- received. Recording the visible text's length per call lets the Sunday
-- report show the two apart, so the session-opening work (roadmap 2.1) is
-- judged on numbers: how much of an 82-second opening was reasoning.
--
-- Run once against the live database. Safe to repeat.

ALTER TABLE model_calls ADD COLUMN IF NOT EXISTS visible_chars INTEGER;
