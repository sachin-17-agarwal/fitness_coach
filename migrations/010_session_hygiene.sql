-- Session hygiene (roadmap 2.12), the SQL half.
--
-- `workout_sessions.status` carries four spellings for two states because
-- the backend wrote complete/active and the app wrote completed/in_progress.
-- Every reader already accepts all four; this makes the table say one thing.
-- Ten sessions have a blank type and two read 'Unknown'; both become NULL
-- here so the hygiene step (cleanup.py, step "hygiene") can infer the type
-- from the sets logged that day, and so nothing downstream matches the
-- literal word 'Unknown'.
--
-- Duplicate same-day rows are NOT touched here: which row to keep depends
-- on which one has the sets, and that is the hygiene step's job (dry-run
-- first). Run once against the live database. Safe to repeat.

UPDATE workout_sessions SET status = 'completed'   WHERE lower(status) = 'complete';
UPDATE workout_sessions SET status = 'in_progress' WHERE lower(status) = 'active';
UPDATE workout_sessions SET type = NULL WHERE type IS NOT NULL AND (btrim(type) = '' OR lower(type) = 'unknown');

-- What is left for the hygiene step: one line per (date, type) with more
-- than one row, and the rows with no type.
SELECT date, type, count(*) AS rows FROM workout_sessions GROUP BY date, type HAVING count(*) > 1 ORDER BY date;
SELECT id, date, status FROM workout_sessions WHERE type IS NULL ORDER BY date;
