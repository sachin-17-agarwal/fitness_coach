-- 011: idempotent chat delivery.
--
-- The app tags every message it sends with a client_id (a UUID it made).
-- The backend writes the user turn with that id as soon as the request
-- arrives, and the assistant turn with the same id when it answers. A resend
-- of the same id, after the phone dropped the connection, then finds the
-- reply already written and returns it instead of running the coach again.
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS client_id TEXT;
CREATE INDEX IF NOT EXISTS conversations_client_id_idx ON conversations (client_id);
