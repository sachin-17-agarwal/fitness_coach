-- 013: coach flags — a reply the athlete marked as wrong, with everything
-- around it (flags.py). Read from the app's Settings as one Markdown text,
-- from /api/flags, and, with a token configured, as an issue per flag.
CREATE TABLE IF NOT EXISTS coach_flags (
    id           BIGSERIAL PRIMARY KEY,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    date         DATE NOT NULL,
    session_id   TEXT,
    client_id    TEXT,
    exercise     TEXT,
    note         TEXT,
    user_message TEXT,
    coach_reply  TEXT,
    card         TEXT,
    logged_sets  JSONB,
    contract     JSONB,
    issue_url    TEXT
);
CREATE INDEX IF NOT EXISTS coach_flags_date_idx ON coach_flags (date);
