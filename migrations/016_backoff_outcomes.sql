-- 016: back-offs scored (C24, 26 Sep 2026).
--
-- The back-off is 45% of the working sets and 48% of the tonnage (September
-- 2026, measured) and was the half of the session nobody scored. The same
-- verdict rule now runs on the first back-off of each lift, stored beside
-- the top set's. scorecard.py writes these columns and falls back to the
-- row without them until this runs.
ALTER TABLE decision_outcomes ADD COLUMN IF NOT EXISTS backoff_verdict        TEXT;
ALTER TABLE decision_outcomes ADD COLUMN IF NOT EXISTS backoff_reps_low       INTEGER;
ALTER TABLE decision_outcomes ADD COLUMN IF NOT EXISTS backoff_reps_high      INTEGER;
ALTER TABLE decision_outcomes ADD COLUMN IF NOT EXISTS backoff_lifted_load_kg DOUBLE PRECISION;
ALTER TABLE decision_outcomes ADD COLUMN IF NOT EXISTS backoff_lifted_reps    INTEGER;
