-- =====================================================================
-- 123 Event scope mapping schema -- ROLLBACK
--
-- Drops in reverse-dependency order: trace table, then the added
-- constraints / indexes / columns on the four extended tables, then
-- restores the pre-123 natural key on event_checklist_mapping.
--
-- NOTE: the natural-key restore can fail by design. If any organization
-- has already mapped the same checklist to two different roles, those
-- rows are duplicates under the old key. That is real data this rollback
-- cannot silently discard, so the restore is guarded and reports the
-- offending rows instead of dropping them. Resolve them by hand, then
-- re-run this script.
-- =====================================================================
SET NOCOUNT ON;
GO

-- ---------------------------------------------------------------------
-- 5. event_mapping_resolution
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.event_mapping_resolution','U') IS NOT NULL
    DROP TABLE grac_practice.event_mapping_resolution;
GO

-- ---------------------------------------------------------------------
-- 4. organization_employee
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_employee_lifecycle_dates')
    ALTER TABLE grac_practice.organization_employee
        DROP CONSTRAINT ck_pm_employee_lifecycle_dates;
GO

IF COL_LENGTH('grac_practice.organization_employee','offboarded_dt') IS NOT NULL
    ALTER TABLE grac_practice.organization_employee DROP COLUMN offboarded_dt;
GO

IF COL_LENGTH('grac_practice.organization_employee','onboarded_dt') IS NOT NULL
    ALTER TABLE grac_practice.organization_employee DROP COLUMN onboarded_dt;
GO

-- ---------------------------------------------------------------------
-- 3. organization_dependency_asset
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ix_pm_org_asset_lifecycle'
             AND object_id = OBJECT_ID('grac_practice.organization_dependency_asset'))
    DROP INDEX ix_pm_org_asset_lifecycle ON grac_practice.organization_dependency_asset;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_asset_lifecycle_dates')
    ALTER TABLE grac_practice.organization_dependency_asset
        DROP CONSTRAINT ck_pm_org_asset_lifecycle_dates;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_asset_lifecycle_status')
    ALTER TABLE grac_practice.organization_dependency_asset
        DROP CONSTRAINT ck_pm_org_asset_lifecycle_status;
GO

IF COL_LENGTH('grac_practice.organization_dependency_asset','decommissioned_dt') IS NOT NULL
    ALTER TABLE grac_practice.organization_dependency_asset DROP COLUMN decommissioned_dt;
GO

IF COL_LENGTH('grac_practice.organization_dependency_asset','commissioned_dt') IS NOT NULL
    ALTER TABLE grac_practice.organization_dependency_asset DROP COLUMN commissioned_dt;
GO

IF COL_LENGTH('grac_practice.organization_dependency_asset','lifecycle_status') IS NOT NULL
    ALTER TABLE grac_practice.organization_dependency_asset DROP COLUMN lifecycle_status;
GO

-- ---------------------------------------------------------------------
-- 2. event_instance
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ix_pm_event_instance_subject'
             AND object_id = OBJECT_ID('grac_practice.event_instance'))
    DROP INDEX ix_pm_event_instance_subject ON grac_practice.event_instance;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'uq_pm_event_instance_open_subject'
             AND object_id = OBJECT_ID('grac_practice.event_instance'))
    DROP INDEX uq_pm_event_instance_open_subject ON grac_practice.event_instance;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_instance_subject')
    ALTER TABLE grac_practice.event_instance DROP CONSTRAINT ck_pm_event_instance_subject;
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_instance_source_mapping')
    ALTER TABLE grac_practice.event_instance DROP CONSTRAINT fk_pm_event_instance_source_mapping;
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_instance_scope_asset_cat')
    ALTER TABLE grac_practice.event_instance DROP CONSTRAINT fk_pm_event_instance_scope_asset_cat;
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_instance_scope_role')
    ALTER TABLE grac_practice.event_instance DROP CONSTRAINT fk_pm_event_instance_scope_role;
GO

IF COL_LENGTH('grac_practice.event_instance','effective_date') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN effective_date;
GO
IF COL_LENGTH('grac_practice.event_instance','source_mapping_id') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN source_mapping_id;
GO
IF COL_LENGTH('grac_practice.event_instance','release_id') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN release_id;
GO
IF COL_LENGTH('grac_practice.event_instance','scope_asset_category_name') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN scope_asset_category_name;
GO
IF COL_LENGTH('grac_practice.event_instance','scope_asset_category_id') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN scope_asset_category_id;
GO
IF COL_LENGTH('grac_practice.event_instance','scope_role_name') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN scope_role_name;
GO
IF COL_LENGTH('grac_practice.event_instance','scope_role_id') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN scope_role_id;
GO
IF COL_LENGTH('grac_practice.event_instance','subject_record_id') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN subject_record_id;
GO
IF COL_LENGTH('grac_practice.event_instance','subject_entity') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN subject_entity;
GO

-- ---------------------------------------------------------------------
-- 1. event_checklist_mapping
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ix_pm_event_checklist_mapping_by_asset_cat'
             AND object_id = OBJECT_ID('grac_practice.event_checklist_mapping'))
    DROP INDEX ix_pm_event_checklist_mapping_by_asset_cat ON grac_practice.event_checklist_mapping;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ix_pm_event_checklist_mapping_by_role'
             AND object_id = OBJECT_ID('grac_practice.event_checklist_mapping'))
    DROP INDEX ix_pm_event_checklist_mapping_by_role ON grac_practice.event_checklist_mapping;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ix_pm_event_checklist_mapping_resolve'
             AND object_id = OBJECT_ID('grac_practice.event_checklist_mapping'))
    DROP INDEX ix_pm_event_checklist_mapping_resolve ON grac_practice.event_checklist_mapping;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'uq_pm_event_checklist_mapping_scoped'
             AND object_id = OBJECT_ID('grac_practice.event_checklist_mapping'))
    DROP INDEX uq_pm_event_checklist_mapping_scoped ON grac_practice.event_checklist_mapping;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_checklist_mapping_scope')
    ALTER TABLE grac_practice.event_checklist_mapping
        DROP CONSTRAINT ck_pm_event_checklist_mapping_scope;
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_checklist_mapping_owner_role')
    ALTER TABLE grac_practice.event_checklist_mapping
        DROP CONSTRAINT fk_pm_event_checklist_mapping_owner_role;
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_checklist_mapping_scope_asset_cat')
    ALTER TABLE grac_practice.event_checklist_mapping
        DROP CONSTRAINT fk_pm_event_checklist_mapping_scope_asset_cat;
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_checklist_mapping_scope_role')
    ALTER TABLE grac_practice.event_checklist_mapping
        DROP CONSTRAINT fk_pm_event_checklist_mapping_scope_role;
GO

IF COL_LENGTH('grac_practice.event_checklist_mapping','default_owner_role_id') IS NOT NULL
    ALTER TABLE grac_practice.event_checklist_mapping DROP COLUMN default_owner_role_id;
GO
IF COL_LENGTH('grac_practice.event_checklist_mapping','release_id') IS NOT NULL
    ALTER TABLE grac_practice.event_checklist_mapping DROP COLUMN release_id;
GO
IF COL_LENGTH('grac_practice.event_checklist_mapping','scope_asset_category_id') IS NOT NULL
    ALTER TABLE grac_practice.event_checklist_mapping DROP COLUMN scope_asset_category_id;
GO
IF COL_LENGTH('grac_practice.event_checklist_mapping','scope_role_id') IS NOT NULL
    ALTER TABLE grac_practice.event_checklist_mapping DROP COLUMN scope_role_id;
GO
IF COL_LENGTH('grac_practice.event_checklist_mapping','scope_dimension') IS NOT NULL
    ALTER TABLE grac_practice.event_checklist_mapping DROP COLUMN scope_dimension;
GO

-- Restore the pre-123 natural key, but only if the data still satisfies it.
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE name = 'uq_pm_event_checklist_mapping_natural'
                 AND parent_object_id = OBJECT_ID('grac_practice.event_checklist_mapping'))
BEGIN
    IF EXISTS (
        SELECT 1
        FROM   grac_practice.event_checklist_mapping
        GROUP BY organization_id, entity_type_id, event_definition_id, checklist_id
        HAVING COUNT(*) > 1)
    BEGIN
        PRINT '123 ROLLBACK: natural key NOT restored -- duplicate rows exist under the pre-123 key.';
        PRINT 'Review the rows listed below, de-duplicate, then re-run this script.';

        SELECT organization_id, entity_type_id, event_definition_id, checklist_id,
               COUNT(*) AS row_count
        FROM   grac_practice.event_checklist_mapping
        GROUP BY organization_id, entity_type_id, event_definition_id, checklist_id
        HAVING COUNT(*) > 1;
    END
    ELSE
    BEGIN
        ALTER TABLE grac_practice.event_checklist_mapping
            ADD CONSTRAINT uq_pm_event_checklist_mapping_natural
                UNIQUE (organization_id, entity_type_id, event_definition_id, checklist_id);
        PRINT '123 ROLLBACK: pre-123 natural key restored.';
    END
END
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'mapping scope columns removed' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.event_checklist_mapping','scope_dimension') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'event_instance subject columns removed' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.event_instance','subject_record_id') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'asset lifecycle columns removed' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.organization_dependency_asset','lifecycle_status') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'event_mapping_resolution dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.event_mapping_resolution','U') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '123 Event scope mapping schema rolled back.';
GO
