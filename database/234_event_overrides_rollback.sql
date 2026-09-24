-- =====================================================================
-- 234 Event override on an adopted Assurance obligation -- ROLLBACK
--
-- READ THIS BEFORE RUNNING IT
-- ---------------------------
-- 234 gave the organisation somewhere to keep its EventDriven-Assurance
-- overrides. Rolling it back removes that store. Any override an org has
-- entered is DISCARDED, and the screen goes back to accepting only the
-- authority's event and SLA.
--
-- This script refuses when a row is actually using the columns -- an
-- accidental rollback should not silently throw away work. To force the
-- drop, clear the columns first:
--
--     UPDATE grac_practice.practice_instance_obligation
--     SET    event_type_id = NULL, sla_value = NULL, sla_unit = NULL
--     WHERE  event_type_id IS NOT NULL OR sla_value IS NOT NULL OR sla_unit IS NOT NULL;
--
-- IT DOES NOT PUT THE PROCEDURE BODIES BACK
-- -----------------------------------------
-- Deliberately -- same reason 231's rollback gives. Pasting the pre-234
-- bodies here would make a third copy of two long procedures, which is
-- how the first divergence started. To return to the pre-234 procedure
-- shape, re-run:
--
--     database/231_restore_144_evidence_handling.sql
--
-- 231 re-issues both procedures in their pre-234 form.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (234 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

DECLARE @in_use INT = 0;

IF COL_LENGTH('grac_practice.practice_instance_obligation','event_type_id') IS NOT NULL
    OR COL_LENGTH('grac_practice.practice_instance_obligation','sla_value')     IS NOT NULL
    OR COL_LENGTH('grac_practice.practice_instance_obligation','sla_unit')      IS NOT NULL
BEGIN
    -- Dynamic SQL so this parses on a database where these columns were
    -- never created (rollback should be re-runnable even after the drop
    -- above ran to completion).
    DECLARE @sql NVARCHAR(400) = N'SELECT @c = COUNT(*) FROM grac_practice.practice_instance_obligation
                                    WHERE event_type_id IS NOT NULL OR sla_value IS NOT NULL OR sla_unit IS NOT NULL;';
    EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @in_use OUTPUT;
END

IF @in_use > 0
BEGIN
    PRINT '234 rollback: ' + CAST(@in_use AS NVARCHAR(20))
        + ' obligation row(s) hold an EventDriven override.';
    PRINT '              The columns stay -- dropping them would discard those overrides.';
    PRINT '              Clear the values first if the drop is really wanted (see header).';
END
ELSE
BEGIN
    IF COL_LENGTH('grac_practice.practice_instance_obligation','sla_unit') IS NOT NULL
    BEGIN
        ALTER TABLE grac_practice.practice_instance_obligation DROP COLUMN sla_unit;
        PRINT '234 rollback: sla_unit dropped.';
    END
    IF COL_LENGTH('grac_practice.practice_instance_obligation','sla_value') IS NOT NULL
    BEGIN
        ALTER TABLE grac_practice.practice_instance_obligation DROP COLUMN sla_value;
        PRINT '234 rollback: sla_value dropped.';
    END
    IF COL_LENGTH('grac_practice.practice_instance_obligation','event_type_id') IS NOT NULL
    BEGIN
        ALTER TABLE grac_practice.practice_instance_obligation DROP COLUMN event_type_id;
        PRINT '234 rollback: event_type_id dropped.';
    END
END
GO

PRINT '=== 234 rollback verification ===';

SELECT 'procedure still reads eventTypeId (234 present in code)' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_adopt','P'))
                 LIKE '%''$.eventTypeId''%'
            THEN 'yes -- re-run 231 to revert the procedure bodies too' ELSE 'no' END AS Result
UNION ALL
SELECT 'event_type_id column',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_obligation','event_type_id') IS NOT NULL
            THEN 'kept -- rows are using it' ELSE 'dropped' END
UNION ALL
SELECT 'sla_value column',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_obligation','sla_value') IS NOT NULL
            THEN 'kept -- rows are using it' ELSE 'dropped' END
UNION ALL
SELECT 'sla_unit column',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_obligation','sla_unit') IS NOT NULL
            THEN 'kept -- rows are using it' ELSE 'dropped' END;

PRINT '';
PRINT '234 rollback complete.';
GO

SET NOEXEC OFF;
GO
