-- The block review: the coach's written review of the block just ended and
-- its proposed changes, prepared once the block's last session is logged,
-- shown the next morning, answered by the athlete ("yes to 1 and 3"). The
-- first block is a dry run: the review is written and shown, nothing is
-- recordable, and the answer is kept for comparison.
--
-- Run once against the live database. Safe to repeat.

CREATE TABLE IF NOT EXISTS block_reviews (
    id            BIGSERIAL PRIMARY KEY,
    block_start   DATE NOT NULL,
    window_since  DATE NOT NULL,
    window_until  DATE NOT NULL,
    facts         JSONB NOT NULL,
    narrative     TEXT NOT NULL,
    proposals     JSONB NOT NULL,
    status        TEXT NOT NULL DEFAULT 'shown',   -- shown | answered
    dry_run       BOOLEAN NOT NULL DEFAULT TRUE,
    answer        TEXT,
    approved      JSONB,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    answered_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS block_reviews_block_idx ON block_reviews (block_start DESC);
