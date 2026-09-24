-- =====================================================================
-- 352_enable_screens_on_org_create_rollback.sql
--
-- Drops the org-create screen-enable trigger and removes only the enable
-- rows this migration created (entered_by IN ('org-create','seed-352')).
-- Rows from 050/351/operators are left as-is. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.tr_pm_organization_enable_screens','TR') IS NOT NULL
    DROP TRIGGER grac_practice.tr_pm_organization_enable_screens;
GO
DELETE ff
FROM grac_practice.feature_flag ff
JOIN grac_practice.feature_flag_master m ON m.feature_flag_id = ff.feature_flag_id
WHERE m.feature_code LIKE N'screen.%'
  AND ff.entered_by IN (N'org-create', N'seed-352');
PRINT CONCAT('352 rollback: trigger dropped; enable rows removed = ', @@ROWCOUNT);
GO
