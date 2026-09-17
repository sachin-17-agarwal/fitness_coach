-- Decisions captured when reached (docs/DECISION_CAPTURE.md).
--
-- A `Proposed:` line the coach writes when something lasting is agreed in
-- chat, held here until the athlete records or declines it from the Home
-- card or in chat; and a `missed` row each time the athlete said something
-- lasting and the reply carried no recordable line, so the Sunday report can
-- count how often the rule failed.
--
-- Run once against the live database. Safe to repeat.

CREATE TABLE IF NOT EXISTS decision_captures (
    id             BIGSERIAL PRIMARY KEY,
    line           TEXT NOT NULL,                     -- the recordable line, or what the athlete said (detector)
    kind           TEXT NOT NULL,                     -- constraint | emphasis | detector
    source         TEXT NOT NULL,                     -- coach | review | athlete | detector
    status         TEXT NOT NULL DEFAULT 'proposed',  -- proposed | recorded | declined | superseded | missed
    rationale      TEXT,
    session_id     TEXT,
    phrase         TEXT,                              -- detector: the lasting phrase matched
    reply_excerpt  TEXT,                              -- detector: the reply's first sentence
    proposed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    answered_at    TIMESTAMPTZ,
    answer_text    TEXT
);
CREATE INDEX IF NOT EXISTS decision_captures_status_idx ON decision_captures (status, proposed_at DESC);
