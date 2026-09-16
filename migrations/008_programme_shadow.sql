-- The programme shadow, as a table instead of a log line. On every reply the
-- backend computes what the programme would have prescribed and compares it
-- with what the coach sent; a difference used to be a Railway log line that
-- nobody read. Now it is a row, and the Sunday report aggregates it, so the
-- substitution flag is judged on numbers.
--
-- Run once against the live database. Safe to repeat.

CREATE TABLE IF NOT EXISTS programme_shadow (
    id            BIGSERIAL PRIMARY KEY,
    date          DATE NOT NULL,
    session_type  TEXT,
    mesocycle_week INTEGER,
    kind          TEXT NOT NULL,            -- plan | set_reply | prose
    exercise      TEXT NOT NULL,
    sent          JSONB NOT NULL,           -- {working: [...], backoff: [...]}
    computed      JSONB NOT NULL,
    created_at    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS programme_shadow_date_idx ON programme_shadow (date DESC);
