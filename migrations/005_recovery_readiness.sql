-- One tap at session start: how the athlete feels, 1 (wrecked) to 5 (fresh).
-- Self-report tracks training load more sensitively than HRV or resting HR
-- (Saw et al. 2016), and it gates the load cuts: readings and the athlete
-- have to agree before a top set comes down.
--
-- Run once against the live database. Safe to repeat.

ALTER TABLE recovery ADD COLUMN IF NOT EXISTS readiness INTEGER
    CHECK (readiness IS NULL OR (readiness BETWEEN 1 AND 5));
