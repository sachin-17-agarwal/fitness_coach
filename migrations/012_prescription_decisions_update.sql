-- 012: allow the 'update' decision in prescription_decisions.
--
-- Since 18 Sep 2026 every mid-session change to the card is stored as a row
-- with decision 'update' (plan.record_plan_update), so the next set reply is
-- computed from the numbers on the athlete's screen. The column's CHECK only
-- allowed 'accept' and 'adjust', so every one of those writes was rejected
-- and the stored plan stayed at the opening's numbers: a "heavier" worked out
-- from stale loads came back as the load already on the card.
ALTER TABLE prescription_decisions DROP CONSTRAINT IF EXISTS prescription_decisions_decision_check;
ALTER TABLE prescription_decisions ADD CONSTRAINT prescription_decisions_decision_check
    CHECK (decision IN ('accept', 'adjust', 'update'));
