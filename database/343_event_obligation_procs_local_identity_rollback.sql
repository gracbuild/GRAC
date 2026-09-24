-- =====================================================================
-- 343 Event-obligation procedures learn the composite obligation identity
-- -- ROLLBACK
--
-- READ THIS BEFORE RUNNING IT
-- ---------------------------
-- Puts sp_event_obligation_mapping_list, sp_event_obligation_applicability_save,
-- sp_event_obligation_coverage_list and sp_event_obligation_raise back to
-- 331's bodies, and removes the local-identity columns this migration
-- added to event_instance_obligation and event_mapping_resolution.
--
-- REFUSES WHILE ANY ROW ACTUALLY USES A LOCAL IDENTITY
-- --------------------------------------------------------
-- A raised checklist item or a resolution trace row that names a custom
-- obligation has nowhere else to record that fact. This script counts
-- such rows on BOTH tables and stops rather than guessing whether losing
-- that record is wanted. To force it:
--
--     DELETE FROM grac_practice.event_instance_obligation
--     WHERE local_practice_obligation_id IS NOT NULL
--        OR local_instance_obligation_id IS NOT NULL;
--     UPDATE grac_practice.event_mapping_resolution
--     SET    local_practice_obligation_id = NULL, local_instance_obligation_id = NULL
--     WHERE  local_practice_obligation_id IS NOT NULL
--        OR  local_instance_obligation_id IS NOT NULL;
--
-- (event_mapping_resolution is cleared rather than deleted -- it is an
-- append-only audit trail by design, per 123's own header; losing the ROW
-- would erase the fact a resolution happened at all, not just which
-- obligation it named.)
--
-- IF 344 HAS ALREADY BEEN APPLIED, ROLL IT BACK FIRST
-- --------------------------------------------------------
-- The two Checklists-tab procedures (344) read the columns and the four
-- procedure bodies this script restores. Roll 344 back before this.
--
-- PROCEDURE BODIES ARE RESTORED BY RE-RUNNING 331, NOT PASTED HERE
-- --------------------------------------------------------------------
-- Same reason every other rollback in this migration set gives (231, 234,
-- 307, 340, 341, 342): re-run database/331_event_profile_resolution_procs.sql
-- to put the four procedures back to their pre-343 bodies.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (343 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.event_instance_obligation','local_practice_obligation_id') IS NULL
   AND COL_LENGTH('grac_practice.event_mapping_resolution','local_practice_obligation_id') IS NULL
BEGIN
    PRINT '343 rollback: neither table carries a local-identity column -- nothing from 343 to remove.';
    SET NOEXEC ON;
END
GO

DECLARE @instance_in_use INT = 0, @resolution_in_use INT = 0;

IF COL_LENGTH('grac_practice.event_instance_obligation','local_practice_obligation_id') IS NOT NULL
BEGIN
    DECLARE @sql1 NVARCHAR(600) = N'SELECT @c = COUNT(*) FROM grac_practice.event_instance_obligation
                                     WHERE local_practice_obligation_id IS NOT NULL
                                        OR local_instance_obligation_id IS NOT NULL;';
    EXEC sp_executesql @sql1, N'@c INT OUTPUT', @c = @instance_in_use OUTPUT;
END

IF COL_LENGTH('grac_practice.event_mapping_resolution','local_practice_obligation_id') IS NOT NULL
BEGIN
    DECLARE @sql2 NVARCHAR(600) = N'SELECT @c = COUNT(*) FROM grac_practice.event_mapping_resolution
                                     WHERE local_practice_obligation_id IS NOT NULL
                                        OR local_instance_obligation_id IS NOT NULL;';
    EXEC sp_executesql @sql2, N'@c INT OUTPUT', @c = @resolution_in_use OUTPUT;
END

IF @instance_in_use > 0 OR @resolution_in_use > 0
BEGIN
    PRINT '343 rollback: ' + CAST(@instance_in_use AS NVARCHAR(20))
        + ' event_instance_obligation row(s) and ' + CAST(@resolution_in_use AS NVARCHAR(20))
        + ' event_mapping_resolution row(s) name a custom obligation.';
    PRINT '               The columns stay -- dropping them would discard that record.';
    PRINT '               Clear them first if the rollback is really wanted (see header).';
END
ELSE
BEGIN
    BEGIN TRAN;

    -- ---- event_instance_obligation ----
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_instance_obl_obligation_kind')
        ALTER TABLE grac_practice.event_instance_obligation
            DROP CONSTRAINT ck_pm_event_instance_obl_obligation_kind;

    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_instance_obl_local_practice_obl')
        ALTER TABLE grac_practice.event_instance_obligation
            DROP CONSTRAINT fk_pm_event_instance_obl_local_practice_obl;

    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_instance_obl_local_instance_obl')
        ALTER TABLE grac_practice.event_instance_obligation
            DROP CONSTRAINT fk_pm_event_instance_obl_local_instance_obl;

    IF COL_LENGTH('grac_practice.event_instance_obligation','local_practice_obligation_id') IS NOT NULL
        ALTER TABLE grac_practice.event_instance_obligation DROP COLUMN local_practice_obligation_id;

    IF COL_LENGTH('grac_practice.event_instance_obligation','local_instance_obligation_id') IS NOT NULL
        ALTER TABLE grac_practice.event_instance_obligation DROP COLUMN local_instance_obligation_id;

    -- Safe: the branch above already established no row uses a local
    -- identity, so every remaining row's obligation_id is populated.
    IF EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('grac_practice.event_instance_obligation')
                 AND name = 'obligation_id' AND is_nullable = 1)
        ALTER TABLE grac_practice.event_instance_obligation
            ALTER COLUMN obligation_id BIGINT NOT NULL;

    -- ---- event_mapping_resolution ----
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_mapping_resolution_obligation_kind')
        ALTER TABLE grac_practice.event_mapping_resolution
            DROP CONSTRAINT ck_pm_event_mapping_resolution_obligation_kind;

    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_mapping_resolution_local_practice_obl')
        ALTER TABLE grac_practice.event_mapping_resolution
            DROP CONSTRAINT fk_pm_event_mapping_resolution_local_practice_obl;

    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_mapping_resolution_local_instance_obl')
        ALTER TABLE grac_practice.event_mapping_resolution
            DROP CONSTRAINT fk_pm_event_mapping_resolution_local_instance_obl;

    IF COL_LENGTH('grac_practice.event_mapping_resolution','local_practice_obligation_id') IS NOT NULL
        ALTER TABLE grac_practice.event_mapping_resolution DROP COLUMN local_practice_obligation_id;

    IF COL_LENGTH('grac_practice.event_mapping_resolution','local_instance_obligation_id') IS NOT NULL
        ALTER TABLE grac_practice.event_mapping_resolution DROP COLUMN local_instance_obligation_id;

    COMMIT TRAN;

    PRINT '343 rollback: local-identity columns removed from both tables.';
END
GO

PRINT '343 rollback: re-run database/331_event_profile_resolution_procs.sql to';
PRINT '              restore sp_event_obligation_mapping_list,';
PRINT '              sp_event_obligation_applicability_save,';
PRINT '              sp_event_obligation_coverage_list and';
PRINT '              sp_event_obligation_raise to their pre-343 bodies.';
GO

PRINT '=== 343 rollback verification ===';

SELECT 'event_instance_obligation local-identity columns' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.event_instance_obligation','local_practice_obligation_id') IS NOT NULL
            THEN 'kept -- rows are using it' ELSE 'dropped' END AS Result
UNION ALL
SELECT 'event_mapping_resolution local-identity columns',
       CASE WHEN COL_LENGTH('grac_practice.event_mapping_resolution','local_practice_obligation_id') IS NOT NULL
            THEN 'kept -- rows are using it' ELSE 'dropped' END
UNION ALL
SELECT 'sp_event_obligation_raise still 343''s body (cand_id surrogate present)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_obligation_raise','P'))
                 LIKE '%cand_id%IDENTITY%'
            THEN 'yes -- re-run 331 to revert the procedure body' ELSE 'no' END
UNION ALL
SELECT 'sp_event_obligation_applicability_save still 343''s body (@local_practice_obligation_id present)',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_event_obligation_applicability_save','P')
                            AND name = '@local_practice_obligation_id')
            THEN 'yes -- re-run 331 to revert the procedure body' ELSE 'no' END;

PRINT '';
PRINT '343 rollback complete.';
GO

SET NOEXEC OFF;
GO
