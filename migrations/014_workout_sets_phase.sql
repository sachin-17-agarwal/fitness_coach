-- 014: the phase a set was logged under (warmup | working | backoff).
--
-- Until now a set's phase was inferred by position: the first N non-warm-up
-- rows were the working sets, the rest back-offs. A skipped working set then
-- mislabelled every set after it, on the card and in the coach's set reply.
-- The app knows the phase when it logs the set and now writes it; rows
-- without one (logged before this) still fall back to position.
ALTER TABLE workout_sets ADD COLUMN IF NOT EXISTS phase TEXT
    CHECK (phase IN ('warmup', 'working', 'backoff'));
