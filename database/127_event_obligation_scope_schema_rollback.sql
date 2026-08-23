-- =====================================================================
-- 127 Obligation-based event scoping -- ROLLBACK
--
-- Reverses in dependency order and restores the 123 constraint vocabulary
-- on event_mapping_resolution. Obligation-origin instances are DELETED
-- rather than left orphaned: without event_instance_obligation their
-- results are unreadable, so keeping the header would be worse than
-- removing it.
--
-- Run 128's rollback BEFORE this one -- its procedures reference these
-- objects.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

-- ---------------------------------------------------------------------
-- Trace rows and instances produced by the obligation path
-- ---------------------------------------------------------------------
-- EXEC() because 127 may have failed partway: these columns might not exist,
-- and a direct reference would fail at batch-compile time rather than being
-- skipped by the guard.
IF COL_LENGTH('grac_practice.event_mapping_resolution','obligation_id') IS NOT NULL
    EXEC('DELETE FROM grac_practice.event_mapping_resolution WHERE obligation_id IS NOT NULL;');
GO

IF OBJECT_ID('grac_practice.event_instance_obligation','U') IS NOT NULL
    DROP TABLE grac_practice.event_instance_obligation;
GO

IF COL_LENGTH('grac_practice.event_instance','origin_kind') IS NOT NULL
    EXEC('DELETE FROM grac_practice.event_instance WHERE origin_kind = N''OBLIGATION'';');
GO

IF OBJECT_ID('grac_practice.event_obligation_applicability','U') IS NOT NULL
    DROP TABLE grac_practice.event_obligation_applicability;
GO

-- ---------------------------------------------------------------------
-- event_mapping_resolution -- restore the 123 vocabulary
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ix_pm_event_mapping_resolution_obligation'
             AND object_id = OBJECT_ID('grac_practice.event_mapping_resolution'))
    DROP INDEX ix_pm_event_mapping_resolution_obligation ON grac_practice.event_mapping_resolution;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_mapping_resolution_included2')
    ALTER TABLE grac_practice.event_mapping_resolution DROP CONSTRAINT ck_pm_event_mapping_resolution_included2;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_mapping_resolution_reason2')
    ALTER TABLE grac_practice.event_mapping_resolution DROP CONSTRAINT ck_pm_event_mapping_resolution_reason2;
GO

IF COL_LENGTH('grac_practice.event_mapping_resolution','event_type_id') IS NOT NULL
    ALTER TABLE grac_practice.event_mapping_resolution DROP COLUMN event_type_id;
GO
IF COL_LENGTH('grac_practice.event_mapping_resolution','applicability_id') IS NOT NULL
    ALTER TABLE grac_practice.event_mapping_resolution DROP COLUMN applicability_id;
GO
IF COL_LENGTH('grac_practice.event_mapping_resolution','obligation_label') IS NOT NULL
    ALTER TABLE grac_practice.event_mapping_resolution DROP COLUMN obligation_label;
GO
IF COL_LENGTH('grac_practice.event_mapping_resolution','obligation_id') IS NOT NULL
    ALTER TABLE grac_practice.event_mapping_resolution DROP COLUMN obligation_id;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_mapping_resolution_reason')
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD CONSTRAINT ck_pm_event_mapping_resolution_reason CHECK (reason_code IN (
            N'ScopeMatched', N'UnscopedMapping', N'ScopeMismatch', N'NoMappingForEvent',
            N'SubjectScopeMissing', N'ReleaseNotSubscribed', N'MappingInactive',
            N'ChecklistInactive', N'NoChecklistItems', N'AlreadyOpen'));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_mapping_resolution_included')
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD CONSTRAINT ck_pm_event_mapping_resolution_included CHECK (
            decision = N'Excluded' OR mapping_id IS NOT NULL);
GO

-- ---------------------------------------------------------------------
-- event_instance -- drop obligation-origin columns
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_instance_origin_kind')
    ALTER TABLE grac_practice.event_instance DROP CONSTRAINT ck_pm_event_instance_origin_kind;
GO

IF COL_LENGTH('grac_practice.event_instance','event_type_code') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN event_type_code;
GO
IF COL_LENGTH('grac_practice.event_instance','event_type_id') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN event_type_id;
GO
IF COL_LENGTH('grac_practice.event_instance','origin_kind') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN origin_kind;
GO

COMMIT TRAN;
GO

IF OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V') IS NOT NULL
    DROP VIEW grac_practice.vw_pm_event_driven_obligation;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'applicability table dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.event_obligation_applicability','U') IS NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'instance_obligation dropped',
       CASE WHEN OBJECT_ID('grac_practice.event_instance_obligation','U') IS NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'origin_kind removed',
       CASE WHEN COL_LENGTH('grac_practice.event_instance','origin_kind') IS NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '123 reason vocabulary restored',
       CASE WHEN EXISTS (SELECT 1 FROM sys.check_constraints
                          WHERE name = 'ck_pm_event_mapping_resolution_reason') THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'diagnostic view dropped',
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V') IS NULL THEN 'PASS' ELSE 'FAIL' END;

PRINT '127 Obligation-based event scoping rolled back.';
GO
