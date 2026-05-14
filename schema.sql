-- schema.sql — Reference DDL for the Supabase tables the app reads/writes.
--
-- This is documentation, not a migration tool. Columns and types are
-- reverse-engineered from how the Python and Swift code references them
-- (see coach.py, workout.py, memory.py, exercises.py, parse_workouts.py).
-- If you bring up a fresh Supabase project, running this with `psql -f
-- schema.sql` should be enough to make the bot boot. Indexes and RLS
-- policies are intentionally omitted.

-- ─────────────────────────────────────────────────────────────────────────────
-- memory: key/value bag for mesocycle position, workout-mode flags, and
-- Telegram update_id dedup markers.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS memory (
    id          BIGSERIAL PRIMARY KEY,
    key         TEXT NOT NULL UNIQUE,
    value       TEXT,
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- conversations: every user/assistant turn, scoped by local date.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS conversations (
    id          BIGSERIAL PRIMARY KEY,
    date        DATE NOT NULL,
    role        TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
    content     TEXT NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- recovery: daily Apple Health snapshot, one row per local date.
-- Upserted via on_conflict="date".
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS recovery (
    date                 DATE PRIMARY KEY,
    sleep_hours          NUMERIC,
    hrv                  NUMERIC,
    hrv_status           TEXT,
    resting_hr           NUMERIC,
    heart_rate           NUMERIC,
    steps                INTEGER,
    active_energy_kcal   NUMERIC,
    weight_kg            NUMERIC,
    body_fat_pct         NUMERIC,
    exercise_minutes     NUMERIC,
    respiratory_rate     NUMERIC,
    vo2_max              NUMERIC
);

-- ─────────────────────────────────────────────────────────────────────────────
-- workout_sessions: the current sessions table the iOS app + coach write to.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS workout_sessions (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    date         DATE NOT NULL,
    type         TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'active',
    start_time   TIMESTAMPTZ,
    end_time     TIMESTAMPTZ,
    tonnage_kg   NUMERIC
);

-- ─────────────────────────────────────────────────────────────────────────────
-- workout_sets: each logged set inside a workout_session.
-- The dedup check in workout.log_set filters by (workout_session_id,
-- exercise, set_number, is_warmup).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS workout_sets (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workout_session_id  UUID NOT NULL REFERENCES workout_sessions(id) ON DELETE CASCADE,
    date                DATE NOT NULL,
    exercise            TEXT NOT NULL,
    set_number          INTEGER NOT NULL,
    is_warmup           BOOLEAN DEFAULT FALSE,
    target_weight_kg    NUMERIC,
    target_reps         INTEGER,
    target_rpe          NUMERIC,
    actual_weight_kg    NUMERIC,
    actual_reps         INTEGER,
    actual_rpe          NUMERIC,
    rest_seconds        INTEGER,
    notes               TEXT,
    logged_at           TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- sets: legacy/historical set table the PR check still reads from.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sets (
    id          BIGSERIAL PRIMARY KEY,
    date        DATE,
    exercise    TEXT NOT NULL,
    weight_kg   NUMERIC,
    reps        INTEGER
);

-- ─────────────────────────────────────────────────────────────────────────────
-- sessions: legacy/historical session summaries fed to the coach context.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sessions (
    id                 BIGSERIAL PRIMARY KEY,
    date               DATE NOT NULL,
    type               TEXT,
    summary            TEXT,
    tonnage_kg         NUMERIC,
    notes              TEXT,
    mesocycle_week     INTEGER,
    mesocycle_day      INTEGER
);

-- ─────────────────────────────────────────────────────────────────────────────
-- exercises: canonical exercise library used by the name-resolver.
-- aliases is a JSON array (e.g. ["incline bench", "incline press"]).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS exercises (
    id            BIGSERIAL PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE,
    muscle_group  TEXT,
    aliases       JSONB DEFAULT '[]'::jsonb
);

-- ─────────────────────────────────────────────────────────────────────────────
-- exercise_substitutions: free-form history of "did X instead of Y".
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS exercise_substitutions (
    id                  BIGSERIAL PRIMARY KEY,
    original_exercise   TEXT NOT NULL,
    substitution        TEXT NOT NULL,
    reason              TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- apple_workouts: parsed Health Auto Export workouts from the iOS shortcut.
-- Composite uniqueness is on (date, workout_type, start_time).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS apple_workouts (
    id                   BIGSERIAL PRIMARY KEY,
    date                 DATE NOT NULL,
    workout_type         TEXT NOT NULL,
    start_time           TIMESTAMPTZ NOT NULL,
    end_time             TIMESTAMPTZ,
    duration_minutes     NUMERIC,
    avg_heart_rate       NUMERIC,
    min_heart_rate       NUMERIC,
    max_heart_rate       NUMERIC,
    active_energy_kcal   NUMERIC,
    source               TEXT,
    UNIQUE (date, workout_type, start_time)
);
