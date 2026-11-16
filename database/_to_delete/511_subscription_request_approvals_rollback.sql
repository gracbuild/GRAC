-- =====================================================================
-- 511_subscription_request_approvals_rollback.sql
--
-- Undoes 511: drops the two gateway shims, removes the grants it
-- inserted and takes the menu row out of navigation.
--
-- WHAT IS NOT TOUCHED
--   406's own procedures and the repository_subscription_request table.
--   511 created no table and no approval logic -- only shims over what
--   406 already built -- so nothing about the request lifecycle changes
--   here, and Control Management's Subscription Requests screen keeps
--   working exactly as before.
--
-- After this, ResolveProcedureAsync's probe finds no shim and the entity
-- falls back to the monolith, which has no
-- 'subscription-request-approvals' branch -- so the screen reads nothing.
-- That is intended: the screen is gone with its menu row. RESTART THE API
-- (the probe is cached per process).
--
-- The menu row is set Inactive rather than deleted, so menu_id and any
-- grant an operator added by hand survive a re-run of 511. Delete it by
-- hand only if you are sure nothing references it.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_subscription_request_approvals_repository_manage','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_org_subscription_request_approvals_repository_manage;
    PRINT '511 rollback: manage shim dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_org_subscription_request_approvals_repository_get','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_org_subscription_request_approvals_repository_get;
    PRINT '511 rollback: get shim dropped.';
END
GO

-- Only the rows 511 inserted (entered_by = 'seed-511'), so a grant an
-- operator made in Role Master afterwards is left alone.
DELETE p
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'subscription-request-approvals'
   AND p.entered_by = N'seed-511';
PRINT CONCAT('511 rollback: grants removed: ', @@ROWCOUNT);
GO

UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = N'rollback-511', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'subscription-request-approvals'
   AND status <> N'Inactive';
PRINT CONCAT('511 rollback: menu row set Inactive: ', @@ROWCOUNT);
GO

PRINT '--- 511 rollback verification ---';
SELECT CASE WHEN OBJECT_ID('grac_practice.sp_org_subscription_request_approvals_repository_get','P') IS NULL
            THEN 'gone' ELSE 'STILL THERE' END AS get_shim,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_subscription_request_approvals_repository_manage','P') IS NULL
            THEN 'gone' ELSE 'STILL THERE' END AS manage_shim;
SELECT menu_key, status, show_in_sidebar
  FROM grac_practice.menu_master
 WHERE menu_key = N'subscription-request-approvals';
PRINT '511 rollback: done. Restart the Api.';
GO
