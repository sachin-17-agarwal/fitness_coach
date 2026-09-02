-- Record which point of the mesocycle each session belonged to.
--
-- schema.sql uses CREATE TABLE IF NOT EXISTS, so it does not alter a table that
-- already exists. Run this once against the live database.
--
-- Safe to run repeatedly: IF NOT EXISTS on both columns, and no data is
-- touched. Existing rows keep NULL, which is the honest value — the mesocycle
-- position at the time they were written was never recorded anywhere, so there
-- is nothing to backfill from.

ALTER TABLE workout_sessions ADD COLUMN IF NOT EXISTS mesocycle_week INTEGER;
ALTER TABLE workout_sessions ADD COLUMN IF NOT EXISTS mesocycle_day  INTEGER;
