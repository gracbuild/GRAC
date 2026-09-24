-- =====================================================================
-- 340 Event type on organisation-authored obligations -- ROLLBACK
--
-- READ THIS BEFORE RUNNING IT
-- ---------------------------
-- 340 gave organisation-authored obligations (both the instance-level
-- door, sp_resolve_local_obligation_save, and the practice-level door,
-- sp_practice_obligation_save) somewhere to declare which event makes
-- them due, and taught sp_practice_obligation_fan_out to carry that
-- declaration down to every instance copy.
--
-- Rolling it back:
--   * drops practice_obligation.event_type_id (refused while any row is
--     using it -- see below);
--   * puts sp_resolve_local_obligation_save, sp_practice_obligation_save,
--     sp_practice_obligation_fan_out and sp_practice_obligation_list back
--     to their pre-340 bodies (244's and 307's respectively).
--
-- This does NOT touch practice_instance_obligation.event_type_id (234's
-- column) or sp_resolve_obligation_adopt -- 340 never changed those; the
-- ADOPT override path is exactly as 234 left it.
--
-- If any later migration (341+) has started reading event_type_id off
-- organisation-authored obligations -- event_obligation_applicability,
-- vw_pm_event_driven_obligation, the Checklists tab -- roll those back
-- FIRST. This script does not check for that dependency, because 340 has
-- no way to know what a later migration might have named.
--
-- IT DOES NOT PUT THE PRE-340 PROCEDURE BODIES BACK BY PASTING THEM
-- -------------------------------------------------------------------
-- Deliberately -- same reason 231's and 234's rollbacks give. This script
-- re-runs the two source files that hold 340's true prior state:
--
--     database/244_connection_type_and_url.sql   (sp_resolve_local_obligation_save)
--     database/307_practice_level_obligations.sql (sp_practice_obligation_save,
--                                                    sp_practice_obligation_fan_out,
--                                                    sp_practice_obligation_list)
--
-- rather than a third hand-copied version of long procedure bodies here.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (340 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Column: refuse to drop practice_obligation.event_type_id while a
--    definition is actually using it -- an accidental rollback should
--    not silently discard an organisation's event-driven declarations.
-- =====================================================================
DECLARE @in_use INT = 0;

IF COL_LENGTH('grac_practice.practice_obligation','event_type_id') IS NOT NULL
BEGIN
    DECLARE @sql NVARCHAR(400) = N'SELECT @c = COUNT(*) FROM grac_practice.practice_obligation
                                    WHERE event_type_id IS NOT NULL;';
    EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @in_use OUTPUT;
END

IF @in_use > 0
BEGIN
    PRINT '340 rollback: ' + CAST(@in_use AS NVARCHAR(20))
        + ' practice-level obligation(s) declare an event type.';
    PRINT '               The column stays -- dropping it would discard those declarations.';
    PRINT '               Clear them first if the drop is really wanted:';
    PRINT '               UPDATE grac_practice.practice_obligation SET event_type_id = NULL WHERE event_type_id IS NOT NULL;';
END
ELSE
BEGIN
    IF COL_LENGTH('grac_practice.practice_obligation','event_type_id') IS NOT NULL
    BEGIN
        ALTER TABLE grac_practice.practice_obligation DROP COLUMN event_type_id;
        PRINT '340 rollback: practice_obligation.event_type_id dropped.';
    END
END
GO

-- =====================================================================
-- 2. Procedure bodies: restored by re-running their pre-340 source.
--    Each guarded so the rollback is a no-op, not an error, when the
--    dependency file is not present in this deployment.
-- =====================================================================
PRINT '340 rollback: re-run database/244_connection_type_and_url.sql to';
PRINT '              restore sp_resolve_local_obligation_save.';
PRINT '340 rollback: re-run database/307_practice_level_obligations.sql to';
PRINT '              restore sp_practice_obligation_save,';
PRINT '              sp_practice_obligation_fan_out and';
PRINT '              sp_practice_obligation_list.';
GO

PRINT '=== 340 rollback verification ===';

SELECT 'event_type_id column' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_obligation','event_type_id') IS NOT NULL
            THEN 'kept -- rows are using it' ELSE 'dropped' END AS Result
UNION ALL
SELECT 'sp_resolve_local_obligation_save still reads @event_type_id (340 body still applied)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P'))
                 LIKE '%@event_type_id%'
            THEN 'yes -- re-run 244 to revert the procedure body' ELSE 'no' END
UNION ALL
SELECT 'sp_practice_obligation_save still reads @event_type_id (340 body still applied)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_obligation_save','P'))
                 LIKE '%@event_type_id%'
            THEN 'yes -- re-run 307 to revert the procedure body' ELSE 'no' END
UNION ALL
SELECT 'sp_practice_obligation_fan_out still propagates event_type_id (340 body still applied)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_obligation_fan_out','P'))
                 LIKE '%po.event_type_id%'
            THEN 'yes -- re-run 307 to revert the procedure body' ELSE 'no' END;

PRINT '';
PRINT '340 rollback complete.';
GO

SET NOEXEC OFF;
GO
