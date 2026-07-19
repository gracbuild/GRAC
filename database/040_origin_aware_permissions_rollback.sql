-- =====================================================================
-- 040 Origin-aware permission guards — ROLLBACK  (charter §9)
--
-- Reverses everything created by 040_origin_aware_permissions.sql.
-- Every DROP guarded with IF EXISTS.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 54050, 'PracticeManagement schema grac_practice is missing.', 1;
GO

IF OBJECT_ID('grac_practice.sp_pm_permissions_probe','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_pm_permissions_probe;
GO

IF OBJECT_ID('grac_practice.fn_pm_can_mutate','FN') IS NOT NULL
    DROP FUNCTION grac_practice.fn_pm_can_mutate;
GO

IF OBJECT_ID('grac_practice.rbac_rule','U') IS NOT NULL
    DROP TABLE grac_practice.rbac_rule;
GO

IF OBJECT_ID('grac_practice.origin_type_master','U') IS NOT NULL
    DROP TABLE grac_practice.origin_type_master;
GO

PRINT '040 origin-aware permissions rollback complete.';
