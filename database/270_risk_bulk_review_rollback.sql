-- =====================================================================
-- 270 ROLLBACK — remove bulk review
--
-- WHAT GOES
--     sp_risk_bulk_review
--
-- WHAT STAYS, AND WHY
--
-- 1. THE HISTORY ROWS. Every 'BulkReview' and 'FieldChange' entry is
--    audit history: those reviews happened, and dropping the procedure
--    that recorded them does not unhappen them. Deleting audit rows to
--    tidy a rollback is how an audit trail stops being one.
--
-- 2. THE THREE COLUMNS (field_code / from_value / to_value). Dropping
--    them would destroy the old -> new values in the rows above -- the
--    very thing the requirement asked to capture. They are NULLable and
--    nothing else writes them, so leaving them costs three empty columns
--    and preserves the record.
--
--    If you genuinely need them gone -- a schema comparison must match
--    exactly, say -- the statements are at the bottom, commented out,
--    with the data loss stated. That is deliberate: this is not
--    something to run by reflex.
--
-- 3. EVERYTHING IT COMPOSED. sp_risk_acceptance_save,
--    sp_risk_register_status_set and sp_risk_review_perform were never
--    modified by 270 -- it called them. That is the payoff of composing
--    rather than reimplementing: this rollback removes a caller, not an
--    implementation, and the single-risk Review keeps working.
--
-- AFTER THIS RUNS
--    The Bulk Review button will fail -- its endpoint has no procedure
--    behind it. Roll the UI back too, or remove the action.
--
-- IDEMPOTENT: re-running drops nothing the second time.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_risk_bulk_review','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_risk_bulk_review;
    PRINT '270 rollback: dropped sp_risk_bulk_review.';
END
ELSE
    PRINT '270 rollback: sp_risk_bulk_review not present -- nothing to drop.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 270 rollback verification ---';

SELECT '270r procedure is gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_bulk_review','P') IS NULL
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT '270r the composed procedures are untouched' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_acceptance_save','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_register_status_set','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_review_perform','P') IS NOT NULL
            THEN 'PASS -- single-risk review, acceptance and status still work'
            ELSE '*** FAIL -- something 270 did not own is missing' END AS Result;

SELECT '270r audit history retained (deliberately)' AS Check_,
       CONCAT(CAST(COUNT(*) AS NVARCHAR(20)), ' bulk-review history row(s) kept') AS Result
  FROM grac_practice.risk_register_history
 WHERE action_code IN (N'BulkReview', N'FieldChange');

PRINT '270 rollback complete.';
PRINT '     The three history columns were KEPT -- dropping them would destroy';
PRINT '     the old -> new review dates recorded against each risk.';
GO

-- =====================================================================
-- DESTRUCTIVE, AND OFF BY DEFAULT.
--
-- Uncomment ONLY if the columns must not exist. This permanently
-- destroys every recorded old -> new value on risk_register_history --
-- including review-date changes made through the UI. There is no way to
-- recover them afterwards.
-- =====================================================================
-- IF COL_LENGTH('grac_practice.risk_register_history','field_code') IS NOT NULL
--     ALTER TABLE grac_practice.risk_register_history DROP COLUMN field_code;
-- GO
-- IF COL_LENGTH('grac_practice.risk_register_history','from_value') IS NOT NULL
--     ALTER TABLE grac_practice.risk_register_history DROP COLUMN from_value;
-- GO
-- IF COL_LENGTH('grac_practice.risk_register_history','to_value') IS NOT NULL
--     ALTER TABLE grac_practice.risk_register_history DROP COLUMN to_value;
-- GO
