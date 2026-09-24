-- =====================================================================
-- 345_user_ownership_management_rollback.sql
-- Removes everything 345 added: the deactivation-guard trigger, the
-- reassign/list procs, the ownership function, and the Ownership
-- Management menu row + its role permissions. ASCII-only.
--
-- NOTE: the 274_menu_master_seed.sql source edit (the ownership-management
-- VALUES/parent lines) is a source change, not reverted here; use git to
-- revert that file if the snapshot must also drop the row. This script
-- removes the live menu row so the screen disappears immediately.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.tr_pm_org_employee_ownership_deactivate_guard','TR') IS NOT NULL
    DROP TRIGGER grac_practice.tr_pm_org_employee_ownership_deactivate_guard;
GO
IF OBJECT_ID('grac_practice.sp_pm_user_ownership_reassign','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_pm_user_ownership_reassign;
GO
IF OBJECT_ID('grac_practice.sp_pm_user_ownership_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_pm_user_ownership_list;
GO
IF OBJECT_ID('grac_practice.fn_pm_user_ownership','IF') IS NOT NULL
    DROP FUNCTION grac_practice.fn_pm_user_ownership;
GO

-- Remove role permissions then the menu row.
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'ownership-management')
BEGIN
    DECLARE @mid BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'ownership-management');
    DELETE FROM grac_practice.organization_role_menu_permission WHERE menu_id = @mid;
END
GO
DELETE FROM grac_practice.menu_master WHERE menu_key = N'ownership-management';
GO
PRINT '345 rollback: ownership management objects, menu row and permissions removed.';
GO
