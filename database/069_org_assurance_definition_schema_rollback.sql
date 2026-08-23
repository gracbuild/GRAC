-- =====================================================================
-- 069 Organization Assurance -- Stage 1 rollback
--
-- Drops the four schema objects introduced by
-- 069_org_assurance_definition_schema.sql in reverse-dependency order.
--
-- Idempotent. Does NOT touch existing unrelated assurance_* objects.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_definition_history','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_definition_history;
GO

-- Break FKs from definition -> version before dropping the version table.
IF EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = 'fk_pm_org_assurance_def_current_version'
      AND parent_object_id = OBJECT_ID('grac_practice.org_assurance_definition')
)
ALTER TABLE grac_practice.org_assurance_definition
    DROP CONSTRAINT fk_pm_org_assurance_def_current_version;
GO

IF EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = 'fk_pm_org_assurance_def_active_version'
      AND parent_object_id = OBJECT_ID('grac_practice.org_assurance_definition')
)
ALTER TABLE grac_practice.org_assurance_definition
    DROP CONSTRAINT fk_pm_org_assurance_def_active_version;
GO

IF OBJECT_ID('grac_practice.org_assurance_definition_version','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_definition_version;
GO

IF OBJECT_ID('grac_practice.org_assurance_definition','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_definition;
GO

IF OBJECT_ID('grac_practice.org_assurance_status_master','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_status_master;
GO

PRINT '069 rollback complete.';
GO
