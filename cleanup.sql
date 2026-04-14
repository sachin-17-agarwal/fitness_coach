-- cleanup.sql — One-off DB cleanup for bugs fixed in PR #5.
--
-- Run these blocks in the Supabase SQL Editor (Dashboard → SQL Editor).
-- Each block is wrapped in a transaction so you can ROLLBACK if the SELECT
-- preview looks wrong. Read the preview SELECT before running the COMMIT.
--
-- Order: run 1 → 2 → 3. Do not skip step 1; it unblocks the bot.


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Close stale active sessions and reset workout_mode
-- ─────────────────────────────────────────────────────────────────────────────

-- Preview: what's stuck?
SELECT id, date, type, status, start_time
FROM workout_sessions
WHERE status = 'active'
  AND date < CURRENT_DATE;

-- Preview: current workout_mode state
SELECT key, value, updated_at
FROM memory
WHERE key IN ('workout_mode', 'current_session_id', 'session_start_time',
              'current_exercise_index', 'current_set_number',
              'current_exercise_name');

-- If both previews look as expected, run this:
BEGIN;

UPDATE workout_sessions
SET status = 'complete',
    end_time = NOW()
WHERE status = 'active'
  AND date < CURRENT_DATE;

UPDATE memory SET value = 'inactive', updated_at = NOW()
    WHERE key = 'workout_mode';
UPDATE memory SET value = '',         updated_at = NOW()
    WHERE key = 'current_session_id';
UPDATE memory SET value = '0',        updated_at = NOW()
    WHERE key = 'current_exercise_index';
UPDATE memory SET value = '0',        updated_at = NOW()
    WHERE key = 'current_set_number';
UPDATE memory SET value = '',         updated_at = NOW()
    WHERE key = 'current_exercise_name';

COMMIT;
-- If anything looks wrong: ROLLBACK; instead of COMMIT;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Delete mis-labeled "Warm up" / "Rest" / "Back-off" sets
-- ─────────────────────────────────────────────────────────────────────────────

-- Preview: how many and which dates?
SELECT date, exercise, COUNT(*) AS rows
FROM workout_sets
WHERE LOWER(TRIM(exercise)) IN (
    'warm up', 'warmup', 'warm-up',
    'rest', 'back-off', 'back off', 'backoff',
    'cool down', 'cool-down', 'cooldown',
    'working set', 'top set', 'drop set'
)
GROUP BY date, exercise
ORDER BY date, exercise;

-- Full list with weights/reps if you want to spot-check before deleting:
SELECT id, date, exercise, actual_weight_kg, actual_reps, workout_session_id
FROM workout_sets
WHERE LOWER(TRIM(exercise)) IN (
    'warm up', 'warmup', 'warm-up',
    'rest', 'back-off', 'back off', 'backoff',
    'cool down', 'cool-down', 'cooldown',
    'working set', 'top set', 'drop set'
)
ORDER BY date, set_number;

-- If you're sure, delete them:
BEGIN;

DELETE FROM workout_sets
WHERE LOWER(TRIM(exercise)) IN (
    'warm up', 'warmup', 'warm-up',
    'rest', 'back-off', 'back off', 'backoff',
    'cool down', 'cool-down', 'cooldown',
    'working set', 'top set', 'drop set'
);

COMMIT;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Dedupe memory rows for mesocycle_week / mesocycle_day
-- ─────────────────────────────────────────────────────────────────────────────

-- Preview: are there duplicates per key?
SELECT key, COUNT(*) AS rows, MAX(updated_at) AS newest
FROM memory
WHERE key IN ('mesocycle_week', 'mesocycle_day')
GROUP BY key;

-- Preview: all rows, newest first
SELECT id, key, value, updated_at
FROM memory
WHERE key IN ('mesocycle_week', 'mesocycle_day')
ORDER BY key, updated_at DESC;

-- Keep only the newest row per key; delete the rest
BEGIN;

DELETE FROM memory m
USING (
    SELECT id
    FROM (
        SELECT id,
               ROW_NUMBER() OVER (PARTITION BY key ORDER BY updated_at DESC) AS rn
        FROM memory
        WHERE key IN ('mesocycle_week', 'mesocycle_day')
    ) ranked
    WHERE rn > 1
) dupes
WHERE m.id = dupes.id;

COMMIT;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Sanity check — run after all three blocks
-- ─────────────────────────────────────────────────────────────────────────────

-- Should return zero active sessions older than today
SELECT COUNT(*) AS stale_sessions
FROM workout_sessions
WHERE status = 'active' AND date < CURRENT_DATE;

-- Should return zero bad exercise rows
SELECT COUNT(*) AS bad_exercise_rows
FROM workout_sets
WHERE LOWER(TRIM(exercise)) IN (
    'warm up', 'warmup', 'warm-up', 'rest',
    'back-off', 'back off', 'backoff',
    'cool down', 'cool-down', 'cooldown'
);

-- Should return 1 row per key
SELECT key, COUNT(*) FROM memory
WHERE key IN ('mesocycle_week', 'mesocycle_day')
GROUP BY key;

-- Should show workout_mode = inactive
SELECT key, value FROM memory
WHERE key IN ('workout_mode', 'current_session_id');
