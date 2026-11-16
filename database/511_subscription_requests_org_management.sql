-- =====================================================================
-- 511 Subscription Requests in Organization Management
--
-- REQUEST (2026-11-03)
--   "framework subscription request nte approval ee module leku akkanam.
--    ipo control management nte module lanu athu ... organization setup
--    lanu ithu vendathu"
--   Decided in the same exchange: a separate menu page in Organization
--   Management, and Control Management KEEPS its own screen (both work the
--   same queue).
--
-- WHAT THIS DOES
--   1. menu_master row 'subscription-requests' ("Subscription Requests",
--      display_order 20, module_type 'Organization Setup'), parented to the
--      inactive 'Organization' group -- exactly where organization-setup
--      sits. An active row under an inactive parent never reaches the
--      Practice Management sidebar tree, while the row itself stays Active,
--      which is what makes the screen permission-bearing. Organization
--      Management lists it through PracticeController's
--      OrganizationManagementAreas. Also carried in 274 (the authoritative
--      snapshot).
--   2. Grants: VIEW + APPROVE for every Active GLOBAL-scope role (the
--      platform administrators -- 220's GRAC admins). Missing rows only, so
--      a re-run never re-grants a right someone removed in Role Master.
--      APPROVE covers Approve and Reject alike. No ADD / EDIT / DELETE:
--      requests are raised only by organizations and never deleted.
--      An organization-scoped role may still be given the menu (274 section
--      3 and pm_grant_organization_default_access grant every active row),
--      but the Web tier also requires a GLOBAL-scope sign-in to list or
--      decide, so an organization admin can never approve its own request.
--
-- NO PROCEDURE CHANGES. The page calls the 406 procedures Control
-- Management already uses -- sp_repository_subscription_request_list and
-- sp_repository_subscription_request_decide -- through the new
-- PracticeManagement Api endpoint /api/practice/subscription-requests.
-- The decide procedure locks the request and refuses one already decided
-- (51414), so the two modules cannot both decide it.
--
-- DEPENDS ON: 022 (menu_master, organization_role_menu_permission),
--             032 (organization_role.data_scope), 274, 406.
-- Rollback: 511_subscription_requests_org_management_rollback.sql
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_role','data_scope') IS NULL
   OR OBJECT_ID('grac_practice.repository_subscription_request','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_repository_subscription_request_list','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_repository_subscription_request_decide','P') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'Organization')
BEGIN
    RAISERROR('ABORT (511): run 022, 032, 274 and 406 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Menu row (also in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'subscription-requests', N'Subscription Requests', N'Practice/Index/subscription-requests', 20, N'file-circle-check', N'Organization Setup')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name
               OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order
               OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type
               OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order,
    icon_class = s.icon_class, module_type = s.module_type, status = N'Active',
    updated_by = N'seed-511', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-511');
PRINT CONCAT('511: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-511', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'Organization'
 WHERE c.menu_key = N'subscription-requests'
   AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
PRINT '511: menu parent wired (Organization).';
GO

-- =====================================================================
-- 2. Grants: GLOBAL-scope roles -- VIEW + APPROVE. Missing rows only.
-- =====================================================================
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 0, 0, 0, 1,
       N'Active', @active_rs, N'seed-511', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'subscription-requests'
 WHERE r.data_scope = N'GLOBAL' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('511: GLOBAL-scope role grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 3. Verification
-- =====================================================================
SELECT '511 menu row Active' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'subscription-requests' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '511 parented to Organization (hidden from the Practice Management sidebar)',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'Organization'
                          WHERE c.menu_key = N'subscription-requests')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '511 every Active GLOBAL role holds VIEW + APPROVE',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.organization_role r
                              WHERE r.data_scope = N'GLOBAL' AND r.status = N'Active'
                                AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                                                  JOIN grac_practice.menu_master m ON m.menu_id = e.menu_id
                                                 WHERE m.menu_key = N'subscription-requests'
                                                   AND e.role_id = r.role_id AND e.can_view = 1 AND e.can_approve = 1))
            THEN 'PASS' ELSE 'CHECK (a grant was removed in Role Master, or a GLOBAL role was added after this ran)' END;

SELECT r.role_id, r.role_name, r.organization_id, r.data_scope, e.can_view, e.can_approve, e.status
  FROM grac_practice.organization_role_menu_permission e
  JOIN grac_practice.menu_master m ON m.menu_id = e.menu_id AND m.menu_key = N'subscription-requests'
  JOIN grac_practice.organization_role r ON r.role_id = e.role_id
 ORDER BY r.data_scope, r.organization_id, r.role_name;
PRINT '511 complete. Deploy Api + Web, restart both, then sign out and back in (menu permissions are read at sign-in).';
GO

SET NOEXEC OFF;
GO
