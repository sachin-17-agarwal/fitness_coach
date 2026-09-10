-- Standing constraints the coach declares in any reply with a `Decision:`
-- line: a machine's top plate, a movement off the table for the block. Held
-- until cleared, shown to the coach every session, and respected by the
-- programme's arithmetic — so a ceiling stated in chat on a Sunday is not
-- forgotten by the proposal on Thursday.
--
-- Run once against the live database. Safe to repeat: IF NOT EXISTS throughout.

CREATE TABLE IF NOT EXISTS exercise_constraints (
    id            BIGSERIAL PRIMARY KEY,
    exercise      TEXT NOT NULL,
    max_load_kg   NUMERIC,
    note          TEXT,
    set_on        DATE NOT NULL,
    active        BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS exercise_constraints_active_idx ON exercise_constraints (active, exercise);
