-- The coach's decisions, stored: every exercise at a session's opening is the
-- programme's default accepted or a deliberate departure with its reason.
--
-- Run once against the live database. Safe to repeat: IF NOT EXISTS throughout.

CREATE TABLE IF NOT EXISTS prescription_decisions (
    id              BIGSERIAL PRIMARY KEY,
    date            DATE NOT NULL,
    session_id      UUID,
    session_type    TEXT NOT NULL,
    mesocycle_week  INTEGER,
    exercise        TEXT NOT NULL,
    decision        TEXT NOT NULL CHECK (decision IN ('accept', 'adjust')),
    reason          TEXT,
    top_load_kg     NUMERIC,
    top_reps        INTEGER,
    top_rpe         NUMERIC,
    plan            JSONB,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS prescription_decisions_date_idx ON prescription_decisions (date DESC);
