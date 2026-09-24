-- 015: the decision scorecard (scorecard.py).
--
-- Every opening decision keeps the PROGRAMME's number beside the coach's, so
-- an adjust can be judged against what it departed from; and every finished
-- session is scored per lift — right, light or heavy — by what was lifted
-- against the range and RPE prescribed. The verdicts go back to the coach in
-- its context, to the Sunday report, and into the programme's next number.
ALTER TABLE prescription_decisions ADD COLUMN IF NOT EXISTS programme_load_kg  DOUBLE PRECISION;
ALTER TABLE prescription_decisions ADD COLUMN IF NOT EXISTS programme_reps_low INTEGER;
ALTER TABLE prescription_decisions ADD COLUMN IF NOT EXISTS programme_reps_high INTEGER;
ALTER TABLE prescription_decisions ADD COLUMN IF NOT EXISTS programme_rpe      DOUBLE PRECISION;

CREATE TABLE IF NOT EXISTS decision_outcomes (
    id               BIGSERIAL PRIMARY KEY,
    session_id       TEXT NOT NULL,
    date             DATE NOT NULL,
    session_type     TEXT,
    mesocycle_week   INTEGER,
    exercise         TEXT NOT NULL,
    decision         TEXT,                  -- accept | adjust | update (the last row that set the card)
    overrode         BOOLEAN NOT NULL DEFAULT FALSE,
    programme_load_kg DOUBLE PRECISION,
    coach_load_kg    DOUBLE PRECISION,
    reps_low         INTEGER,
    reps_high        INTEGER,
    rpe_target       DOUBLE PRECISION,
    lifted_load_kg   DOUBLE PRECISION,
    lifted_reps      INTEGER,
    lifted_rpe       DOUBLE PRECISION,
    verdict          TEXT NOT NULL,         -- right | light | heavy | unknown
    reason           TEXT,
    scored_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (session_id, exercise)
);
CREATE INDEX IF NOT EXISTS decision_outcomes_date_idx ON decision_outcomes (date DESC);
