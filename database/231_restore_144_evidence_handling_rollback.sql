-- =====================================================================
-- 231 Restore migration 144's evidence handling -- ROLLBACK
--
-- READ THIS BEFORE RUNNING IT
-- --------------------------
-- 231 is a correction. Rolling it back reinstates the defect it fixed:
-- adoption goes back to counting only DIRECT evidence, skipping an
-- existing unattached row instead of adopting it, and sharing one row
-- between two obligations that publish the same evidence type. That is
-- silent under-creation of compliance evidence.
--
-- Run this only to get out of a problem 231 itself caused -- never as
-- tidying up.
--
-- IT DOES NOT PUT THE PROCEDURE BODIES BACK
-- -----------------------------------------
-- Deliberately. Pasting the pre-231 bodies in here would make a third
-- copy of two long procedures, and a third copy is how the first
-- divergence happened. To return to the pre-231 state, re-run the two
-- migrations that produced it, in this order:
--
--     database/226_obligation_adoption_parameters.sql
--     database/227_organization_defined_obligations.sql
--
-- 227 must come second: it re-issues sp_resolve_obligation_list on top of
-- 226's body.
--
-- WHAT THIS SCRIPT DOES REMOVE
-- ----------------------------
-- Only 231's schema addition -- the column linking evidence to an
-- organisation-defined obligation -- and only when nothing is using it.
-- Rows carrying a value are an organisation's own evidence attachments;
-- dropping the column would discard which obligation each belongs to.
--
-- ASCII-only on purpose (see the forward script header).
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (231 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

DECLARE @attached INT = 0;

IF COL_LENGTH('grac_practice.practice_instance_evidence','source_practice_instance_obligation_id') IS NOT NULL
    SELECT @attached = COUNT(*)
    FROM   grac_practice.practice_instance_evidence
    WHERE  source_practice_instance_obligation_id IS NOT NULL;

IF @attached > 0
BEGIN
    PRINT '231 rollback: ' + CAST(@attached AS NVARCHAR(20))
        + ' evidence row(s) are attached to an organisation-defined obligation.';
    PRINT '              The column stays -- dropping it would discard which';
    PRINT '              obligation each of them belongs to.';
END
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_pie_local_obligation'
                  AND object_id = OBJECT_ID('grac_practice.practice_instance_evidence'))
    BEGIN
        DROP INDEX ix_pm_pie_local_obligation ON grac_practice.practice_instance_evidence;
        PRINT '231 rollback: ix_pm_pie_local_obligation dropped.';
    END

    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_pie_local_obligation')
    BEGIN
        ALTER TABLE grac_practice.practice_instance_evidence
            DROP CONSTRAINT fk_pm_pie_local_obligation;
        PRINT '231 rollback: fk_pm_pie_local_obligation dropped.';
    END

    IF COL_LENGTH('grac_practice.practice_instance_evidence','source_practice_instance_obligation_id') IS NOT NULL
    BEGIN
        ALTER TABLE grac_practice.practice_instance_evidence
            DROP COLUMN source_practice_instance_obligation_id;
        PRINT '231 rollback: source_practice_instance_obligation_id dropped.';
    END
END
GO

PRINT '=== 231 rollback verification ===';

SELECT 'procedures still carry the 144 fixes' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_adopt','P'))
                 LIKE '%vw_pm_obligation_evidence%'
            THEN 'YES -- re-run 226 then 227 to undo that too' ELSE 'no' END AS Result
UNION ALL
SELECT 'local evidence link column',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_evidence','source_practice_instance_obligation_id') IS NOT NULL
            THEN 'kept -- rows are using it' ELSE 'dropped' END;

PRINT '';
PRINT '231 rollback complete.';
GO

SET NOEXEC OFF;
GO
