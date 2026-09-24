-- =====================================================================
-- 233 The evidence sync must not shift the caller's result set -- ROLLBACK
--
-- READ THIS BEFORE RUNNING IT
-- ---------------------------
-- 233 is a correction. Rolling it back reinstates the defect: saving an
-- organisation-defined obligation reports a failure it did not have,
-- leaves the dialog open, and creates a duplicate obligation on every
-- further click of Save.
--
-- There is no reason to want that. Run this only to get out of a problem
-- 233 itself caused.
--
-- IT DOES NOT PUT THE PROCEDURE BODIES BACK
-- -----------------------------------------
-- Deliberately -- the same reason 231's rollback gives. A third copy of
-- a long procedure is how the first divergence happened. To return to
-- the pre-233 state, re-run:
--
--     database/232_local_obligation_evidence.sql
--
-- That re-issues both procedures in their pre-233 form.
--
-- WHAT THIS SCRIPT DOES
-- ---------------------
-- Nothing destructive. 233 changed only procedure bodies and a
-- parameter list -- it added no table, column, constraint or index, so
-- there is nothing to drop. This script reports the current state and
-- says which file to re-run.
--
-- ASCII-only on purpose (see the forward script header).
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (233 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

PRINT '=== 233 rollback ===';
PRINT '';
PRINT '233 added no schema objects, so nothing is dropped here.';
PRINT 'To undo it, re-run database/232_local_obligation_evidence.sql --';
PRINT 'that re-issues both procedures in their pre-233 form.';
PRINT '';
PRINT 'Be aware of what you are reinstating: the sync procedure will';
PRINT 'again SELECT its counts, that SELECT again becomes the caller''s';
PRINT 'first result set, and the API again fails to find [Message] on a';
PRINT 'save that in fact committed.';
GO

PRINT '=== Current state ===';

SELECT 'sync returns counts by OUTPUT (233 applied)' AS Check_,
       CASE WHEN EXISTS (
            SELECT 1 FROM sys.parameters
            WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P')
              AND name = '@evidence_added' AND is_output = 1)
            THEN 'yes' ELSE 'no -- already back to 232' END AS Result
UNION ALL
SELECT 'save emits Message on its first result set',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P'))
                 LIKE '%AS Message%'
            THEN 'yes' ELSE 'no -- the API cannot read the outcome' END;

PRINT '';
PRINT '233 rollback complete.';
GO

SET NOEXEC OFF;
GO
