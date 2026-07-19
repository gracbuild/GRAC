-- =====================================================================
-- 063 Assurance group + Registers dissolve -- ROLLBACK
--
-- Reverses the sidebar changes made by 063:
--   * assurance-calendar back to menu_name 'Assurance Calendar',
--     module_type 'Assurance Management', parent_menu_id NULL (matches
--     what migration 028 originally seeded).
--   * Every other assurance-* / evidence-assurance / dependency-assurance /
--     practice-health / audit-intelligence / risk-intelligence row that
--     063 flipped Inactive is reactivated.
--   * nav-registers + workbench-* rows go back to Active.
--   * The synthetic nav-assurance parent is deleted (its can_view grant
--     is deleted first so the FK stays clean).
--
-- Only rows whose updated_by = 'seed-063' or entered_by = 'seed-063' are
-- touched, so any later manual change is preserved.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

-- Reactivate every other assurance-* sidebar row 063 hid.
UPDATE grac_practice.menu_master
   SET status     = N'Active',
       updated_by = 'rollback-063',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (
        N'assurance-dashboard',
        N'assurance-generation',
        N'assurance-activities',
        N'assurance-execution',
        N'evidence-assurance',
        N'dependency-assurance',
        N'assurance-results',
        N'assurance-findings',
        N'assurance-signals',
        N'assurance-trends',
        N'practice-health',
        N'audit-intelligence',
        N'risk-intelligence')
   AND updated_by = 'seed-063';

-- Restore assurance-calendar to its migration 028 shape.
UPDATE grac_practice.menu_master
   SET menu_name      = N'Assurance Calendar',
       menu_url       = N'Practice/Index/assurance-calendar',
       parent_menu_id = NULL,
       display_order  = 730,
       icon_class     = N'calendar-days',
       module_type    = N'Assurance Management',
       status         = N'Active',
       updated_by     = 'rollback-063',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key  = N'assurance-calendar'
   AND updated_by = 'seed-063';

-- Reactivate the Registers group + workbench-* children.
UPDATE grac_practice.menu_master
   SET status     = N'Active',
       updated_by = 'rollback-063',
       updated_dt = SYSUTCDATETIME()
 WHERE (menu_key = N'nav-registers' OR menu_key LIKE N'workbench-%')
   AND updated_by = 'seed-063';

-- Drop the synthetic parent (permission grants first so the FK stays clean).
DECLARE @assurance_parent_id BIGINT = (
    SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance'
);

IF @assurance_parent_id IS NOT NULL
BEGIN
    IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
    BEGIN
        DELETE FROM grac_practice.organization_role_menu_permission
        WHERE menu_id = @assurance_parent_id;
    END

    DELETE FROM grac_practice.menu_master
    WHERE menu_id    = @assurance_parent_id
      AND entered_by = 'seed-063';
END

COMMIT TRAN;

SELECT menu_key, menu_name, menu_url, parent_menu_id, display_order, status
FROM grac_practice.menu_master
WHERE menu_key = N'nav-assurance'
   OR menu_key LIKE N'assurance-%'
   OR menu_key IN (N'evidence-assurance', N'dependency-assurance',
                   N'practice-health', N'audit-intelligence', N'risk-intelligence',
                   N'nav-registers')
   OR menu_key LIKE N'workbench-%'
ORDER BY status DESC, display_order;

PRINT '063 rollback complete.';
GO
