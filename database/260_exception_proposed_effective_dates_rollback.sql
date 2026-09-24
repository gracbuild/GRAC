-- =====================================================================
-- 260 Exception proposed effective dates ROLLBACK
--
-- Reverses 260_exception_proposed_effective_dates.sql.
--
--   1. Drop 260's own procedure (sp_exception_request_history_list).
--   2. RESTORE the four procedures 260 REWROTE to their ancestors:
--          analysis_save        -> 257
--          submit_for_approval  -> 257
--          approve              -> 257
--          get                  -> 166
--   3. Drop the two proposed_* columns on exception_request.
--
-- STEP 2 IS THE PART THAT MATTERS, and it is the same trap 258's
-- rollback called out: 260 rewrote procedures that existed before it.
-- Dropping them would leave the API calling something that is gone. The
-- ancestors are CREATE OR ALTER and idempotent, so re-running 257 and
-- 166 restores them exactly. This script does NOT re-emit those bodies
-- itself -- a second copy would drift from the originals the first time
-- either is patched.
--
-- ORDER MATTERS. The four procedures reference the proposed_* columns,
-- so they are restored (dropping those references) BEFORE the columns
-- are dropped. Run 257 and 166 where this script says to, not after.
--
-- DATA LOSS WARNING
-- Step 3 destroys every analyst-proposed window. The APPROVED windows
-- (effective_from / effective_until) are untouched -- they are separate
-- columns, which is the reason 260 added new ones. History rows written
-- with action_code 'EffectiveDatesChanged' are left in place: they are
-- an audit trail, and deleting audit rows to undo a schema change is
-- worse than leaving a row whose action_code no longer occurs.
--
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (260 rollback): schema grac_practice missing.';
    RAISERROR('260 rollback: schema missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. 260's own procedure
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_exception_request_history_list','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_exception_request_history_list;
    PRINT '260 rollback: sp_exception_request_history_list dropped.';
END
GO

-- =====================================================================
-- 2. Restore the rewritten procedures
--
-- STOP HERE and run, in this order:
--
--     database/166_exception_centre_v2_full_capture.sql
--     database/257_exception_analysis_stage.sql
--
-- 166 restores sp_exception_request_get; 257 restores analysis_save,
-- submit_for_approval and approve (257 is later, so it wins for the
-- three it owns). Both are CREATE OR ALTER and safe to re-run.
--
-- The check below refuses to drop the columns until that is done, so a
-- half-finished rollback cannot leave a procedure compiled against a
-- column that has gone.
-- =====================================================================
DECLARE @still_referencing INT = 0;

SELECT @still_referencing = COUNT(*)
  FROM sys.sql_modules m
  JOIN sys.objects o ON o.object_id = m.object_id
 WHERE o.schema_id = SCHEMA_ID('grac_practice')
   AND o.type = 'P'
   AND (m.definition LIKE '%proposed_effective_from%'
     OR m.definition LIKE '%proposed_effective_until%');

IF @still_referencing > 0
BEGIN
    PRINT 'ABORT (260 rollback): procedures still reference the proposed_* columns.';
    PRINT 'Run 166_exception_centre_v2_full_capture.sql then 257_exception_analysis_stage.sql, then re-run this script.';
    RAISERROR('260 rollback: restore 166 and 257 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 3. Columns
-- =====================================================================
IF COL_LENGTH('grac_practice.exception_request','proposed_effective_until') IS NOT NULL
BEGIN
    ALTER TABLE grac_practice.exception_request DROP COLUMN proposed_effective_until;
    PRINT '260 rollback: exception_request.proposed_effective_until dropped.';
END
GO

IF COL_LENGTH('grac_practice.exception_request','proposed_effective_from') IS NOT NULL
BEGIN
    ALTER TABLE grac_practice.exception_request DROP COLUMN proposed_effective_from;
    PRINT '260 rollback: exception_request.proposed_effective_from dropped.';
END
GO

SELECT '260 rollback complete' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.exception_request','proposed_effective_from')  IS NULL
             AND COL_LENGTH('grac_practice.exception_request','proposed_effective_until') IS NULL
             AND OBJECT_ID('grac_practice.sp_exception_request_history_list','P')          IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO

SET NOEXEC OFF;
GO
