-- =====================================================================
-- 329 ROLLBACK -- Event Profile schema
--
-- Reverses 329_event_profile_schema.sql:
--   * restores the 127 CHECK and natural key on
--     event_obligation_applicability
--   * drops profile_id from applicability, the profile snapshot from
--     event_instance and the profile trace from event_mapping_resolution
--   * drops the four profile tables
--
-- REFUSES RATHER THAN DESTROYS
-- ----------------------------
-- If any applicability row is scoped to a profile, rolling back would
-- either violate the restored CHECK or require deleting recorded
-- applicability decisions. Neither is a rollback's business, so the
-- script stops and names the rows. Clear them from the Profiles screen
-- (or re-point them) first.
--
-- Likewise if any event_instance carries a profile snapshot: those are
-- historical records explaining what was served, and dropping the column
-- would erase the explanation. Run 333's rollback first if the converter
-- produced them.
--
-- Run 331's and 330's rollbacks BEFORE this one -- their procedures
-- reference these tables and columns.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @scoped INT = 0, @instances INT = 0;

IF COL_LENGTH('grac_practice.event_obligation_applicability','profile_id') IS NOT NULL
    EXEC sp_executesql
        N'SELECT @c = COUNT(1) FROM grac_practice.event_obligation_applicability WHERE profile_id IS NOT NULL;',
        N'@c INT OUTPUT', @c = @scoped OUTPUT;

IF COL_LENGTH('grac_practice.event_instance','scope_profile_id') IS NOT NULL
    EXEC sp_executesql
        N'SELECT @c = COUNT(1) FROM grac_practice.event_instance WHERE scope_profile_id IS NOT NULL;',
        N'@c INT OUTPUT', @c = @instances OUTPUT;

IF @scoped > 0 OR @instances > 0
BEGIN
    RAISERROR('329 rollback refused: %d profile-scoped applicability row(s) and %d event instance(s) still reference a profile. Remove or re-scope them first.',
              16, 1, @scoped, @instances);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- ---------------------------------------------------------------------
-- 1. event_mapping_resolution
-- ---------------------------------------------------------------------
IF COL_LENGTH('grac_practice.event_mapping_resolution','profile_name') IS NOT NULL
    ALTER TABLE grac_practice.event_mapping_resolution DROP COLUMN profile_name;
GO

IF COL_LENGTH('grac_practice.event_mapping_resolution','profile_id') IS NOT NULL
    ALTER TABLE grac_practice.event_mapping_resolution DROP COLUMN profile_id;
GO

-- ---------------------------------------------------------------------
-- 2. event_instance
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_instance_scope_profile')
    ALTER TABLE grac_practice.event_instance DROP CONSTRAINT fk_pm_event_instance_scope_profile;
GO

IF COL_LENGTH('grac_practice.event_instance','scope_profile_name') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN scope_profile_name;
GO

IF COL_LENGTH('grac_practice.event_instance','scope_profile_id') IS NOT NULL
    ALTER TABLE grac_practice.event_instance DROP COLUMN scope_profile_id;
GO

-- ---------------------------------------------------------------------
-- 3. event_obligation_applicability -- restore the 127 shape
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ix_pm_event_obl_app_by_profile'
             AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    DROP INDEX ix_pm_event_obl_app_by_profile
        ON grac_practice.event_obligation_applicability;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'uq_pm_event_obl_app_natural'
             AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    DROP INDEX uq_pm_event_obl_app_natural
        ON grac_practice.event_obligation_applicability;
GO

-- The 127 definition, verbatim.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'uq_pm_event_obl_app_natural'
                 AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    CREATE UNIQUE INDEX uq_pm_event_obl_app_natural
        ON grac_practice.event_obligation_applicability(
            organization_id, obligation_id, event_type_id,
            scope_role_id, scope_asset_category_id);
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_obl_app_scope')
    ALTER TABLE grac_practice.event_obligation_applicability
        DROP CONSTRAINT ck_pm_event_obl_app_scope;
GO

-- The 127 definition, verbatim.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_obl_app_scope')
    ALTER TABLE grac_practice.event_obligation_applicability
        ADD CONSTRAINT ck_pm_event_obl_app_scope CHECK (
            (scope_dimension = N'ORG_ROLE'
                 AND scope_role_id IS NOT NULL AND scope_asset_category_id IS NULL)
         OR (scope_dimension = N'ASSET_CATEGORY'
                 AND scope_asset_category_id IS NOT NULL AND scope_role_id IS NULL));
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_obl_app_profile')
    ALTER TABLE grac_practice.event_obligation_applicability
        DROP CONSTRAINT fk_pm_event_obl_app_profile;
GO

IF COL_LENGTH('grac_practice.event_obligation_applicability','profile_id') IS NOT NULL
    ALTER TABLE grac_practice.event_obligation_applicability DROP COLUMN profile_id;
GO

-- ---------------------------------------------------------------------
-- 4. The profile tables, children before parents
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.event_profile_criteria_value','U') IS NOT NULL
    DROP TABLE grac_practice.event_profile_criteria_value;
GO

IF OBJECT_ID('grac_practice.event_profile_criteria','U') IS NOT NULL
    DROP TABLE grac_practice.event_profile_criteria;
GO

IF OBJECT_ID('grac_practice.event_profile','U') IS NOT NULL
    DROP TABLE grac_practice.event_profile;
GO

IF OBJECT_ID('grac_practice.event_profile_dimension_master','U') IS NOT NULL
    DROP TABLE grac_practice.event_profile_dimension_master;
GO

COMMIT TRAN;
GO

SELECT 'event_profile tables removed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.event_profile','U') IS NULL
             AND OBJECT_ID('grac_practice.event_profile_dimension_master','U') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'applicability.profile_id removed',
       CASE WHEN COL_LENGTH('grac_practice.event_obligation_applicability','profile_id') IS NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '127 CHECK restored',
       CASE WHEN EXISTS (SELECT 1 FROM sys.check_constraints
                          WHERE name = 'ck_pm_event_obl_app_scope'
                            AND OBJECT_DEFINITION(object_id) NOT LIKE '%PROFILE%')
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '329 rollback complete.';
GO

SET NOEXEC OFF;
GO
