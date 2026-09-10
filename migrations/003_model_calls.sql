-- Every model call the coach makes, costed: what kind, how long, how many
-- tokens and how many of those were cache reads. The optimisation plan
-- (docs/OPTIMISATION.md) runs on this table rather than on guesses, and the
-- weekly report in .github/workflows/usage_report.yml reads it.
--
-- Run once against the live database. Safe to repeat: IF NOT EXISTS throughout.

CREATE TABLE IF NOT EXISTS model_calls (
    id                  BIGSERIAL PRIMARY KEY,
    called_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    kind                TEXT NOT NULL,          -- plan | set_reply | prose
    attempt             INTEGER NOT NULL DEFAULT 1,
    ok                  BOOLEAN NOT NULL DEFAULT TRUE,
    seconds             NUMERIC,
    input_tokens        INTEGER,
    cache_read_tokens   INTEGER,
    cache_write_tokens  INTEGER,
    output_tokens       INTEGER,
    model               TEXT,
    note                TEXT
);
CREATE INDEX IF NOT EXISTS model_calls_called_at_idx ON model_calls (called_at DESC);
