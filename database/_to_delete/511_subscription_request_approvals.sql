-- =====================================================================
-- 511  Framework Subscription Approvals -- the Organization Management
--      module's one screen
--
-- REQUEST (2026-11-02)
--   "organization setup and dependencies ee 2 menus ini organization
--    module lu venda. Framework subscription request approval nte oru
--    menu mathram mathi ee module lu."
--
--   Organization Management's sidebar is reduced to a single menu: the
--   approval of organizations' framework subscription requests.
--
-- WHAT ALREADY EXISTED, AND WHAT DID NOT
--   Migration 406 built the whole request lifecycle. The request is
--   raised in Practice Management (Standards & Frameworks -> Add Release
--   -> Subscribe from Repository) and, until now, decided only in
--   CONTROL MANAGEMENT (Repository Management -> Subscription Requests).
--
--   The two procedures that do the work already live HERE, in
--   grac_practice, created by 406 -- Control Management merely calls them
--   through its own dbo.cm_* dispatchers:
--
--     sp_repository_subscription_request_list    (all requests)
--     sp_repository_subscription_request_decide  (Approve / Reject)
--
--   So this migration adds NO approval logic and NO new table. It adds
--   the two gateway shims that let the Practice Management gateway reach
--   those same procedures, plus the menu row and its grants.
--
--   Control Management's screen is deliberately left alone: sir chose to
--   keep it. Both sides decide through the same procedure, which locks
--   the request and refuses a second decision (51414), so whichever acts
--   first wins and the other is told it is already decided.
--
-- HOW (the house gateway-shim pattern -- 134, 361, 419, 465, 510)
--   The monolith is NOT re-issued. Two per-entity shims take its same
--   seven parameters for the new entity type
--   'subscription-request-approvals':
--
--     sp_org_subscription_request_approvals_repository_get
--         -> sp_repository_subscription_request_list
--     sp_org_subscription_request_approvals_repository_manage
--         -> sp_repository_subscription_request_decide
--
--   PracticeRepositoryService.ResolveProcedureAsync routes the entity to
--   them and falls back to the monolith when they are absent, so SQL and
--   Api can be deployed in either order. The probe is cached per process
--   -- RESTART THE API after running this.
--
-- THE MENU ROW is Active (so the permission is one a role can actually
--   hold) with show_in_sidebar = 0 (migration 390). That pair is exactly
--   what this application uses for a screen that must exist as a
--   permission but must not appear in Practice Management's sidebar:
--   PracticeMenuService builds the sidebar tree from show_in_sidebar rows
--   only, while VisibleScreens -- which the Organization Management
--   module's own menu is projected from -- deliberately still includes
--   the hidden ones. So the screen appears in Organization Management and
--   nowhere else.
--
--   274_menu_master_seed.sql carries the same row and the same
--   show_in_sidebar step, or its next run would undo this one.
--
-- SAFE TO RE-RUN. Requires 406 (the request lifecycle) and 390
-- (show_in_sidebar).
-- Rollback: 511_subscription_request_approvals_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Guard on the COLUMNS and PROCEDURES the bodies below depend on, not
-- merely on the tables: a missing column fails CREATE with Msg 207, and
-- the script would carry on and still PRINT success.
IF OBJECT_ID('grac_practice.repository_subscription_request','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_repository_subscription_request_list','P')   IS NULL
   OR OBJECT_ID('grac_practice.sp_repository_subscription_request_decide','P') IS NULL
BEGIN
    PRINT 'ABORT (511): run 406_repository_subscription_requests.sql first. Nothing was changed.';
    SET NOEXEC ON;
END
GO
IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR COL_LENGTH('grac_practice.menu_master','show_in_sidebar') IS NULL
BEGIN
    PRINT 'ABORT (511): run 390_home_route_and_my_work_on_home.sql first (menu_master.show_in_sidebar). Nothing was changed.';
    SET NOEXEC ON;
END
GO
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (511): organization_role_menu_permission / record_status_master are missing. Nothing was changed.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Read shim -- the request list
--
--    @p_id maps to @request_id, so the generic grid's single-record read
--    works unchanged. @p_status is the request status (Pending /
--    Approved / Rejected); @p_search is 406's own search, over the
--    organization, artifact, release version and requester.
--
--    The list is NOT organization-scoped: this is the platform's
--    approval queue, and the Web tier governs who may open it through
--    the screen's own permission.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_subscription_request_approvals_repository_get
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30)  = 'QUERY',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30)  = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');

    -- The grid may send the id in the payload instead of @p_id (the
    -- generic query posts { data: { ... } }), so accept either.
    DECLARE @request_id BIGINT =
        COALESCE(NULLIF(TRY_CONVERT(BIGINT, JSON_VALUE(@p_payload, '$.requestId')), 0),
                 NULLIF(@p_id, 0),
                 0);
    DECLARE @status NVARCHAR(20) =
        COALESCE(NULLIF(@p_status, ''), NULLIF(JSON_VALUE(@p_payload, '$.status'), ''), N'');

    EXEC grac_practice.sp_repository_subscription_request_list
         @request_id = @request_id,
         @status     = @status,
         @search     = @p_search;
END;
GO
PRINT '511: sp_org_subscription_request_approvals_repository_get created.';
GO

-- =====================================================================
-- 2. Write shim -- Approve / Reject
--
--    The decision travels in the payload ({ decision, remark }) rather
--    than in @p_action, because the gateway sends its own generic action
--    ('SAVE') for every write. @p_usr_id is the deciding login, which is
--    what 406 records in decided_by.
--
--    Every validation stays in sp_repository_subscription_request_decide:
--    Pending-only (51414), organization still active (51415), release
--    still eligible (51416), reject reason mandatory (51412). None of it
--    is repeated here -- this shim only unpacks the payload.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_subscription_request_approvals_repository_manage
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30),
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30)  = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');

    DECLARE @request_id BIGINT =
        COALESCE(NULLIF(TRY_CONVERT(BIGINT, JSON_VALUE(@p_payload, '$.requestId')), 0),
                 NULLIF(@p_id, 0));
    DECLARE @decision NVARCHAR(20) = NULLIF(LTRIM(RTRIM(ISNULL(JSON_VALUE(@p_payload, '$.decision'), ''))), '');
    DECLARE @remark   NVARCHAR(1000) = NULLIF(LTRIM(RTRIM(ISNULL(JSON_VALUE(@p_payload, '$.remark'), ''))), '');

    IF @request_id IS NULL OR @request_id <= 0
        THROW 51413, 'The subscription request was not found.', 1;
    -- 51411 is 406's own code for exactly this, reused rather than
    -- inventing a second one for the same condition.
    IF @decision IS NULL OR @decision NOT IN (N'Approve', N'Reject')
        THROW 51411, 'The decision must be Approve or Reject.', 1;

    EXEC grac_practice.sp_repository_subscription_request_decide
         @request_id = @request_id,
         @decision   = @decision,
         @remark     = @remark,
         @actor      = @p_usr_id;
END;
GO
PRINT '511: sp_org_subscription_request_approvals_repository_manage created.';
GO

-- =====================================================================
-- 3. Menu row -- Active, and hidden from the Practice Management sidebar
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'subscription-request-approvals', N'Framework Subscription Approvals',
     N'Practice/Index/subscription-request-approvals', 20, N'clipboard-check', N'Organization Setup')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name
               OR ISNULL(t.menu_url, N'') <> ISNULL(s.menu_url, N'')
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

-- Same parent as Organization Setup, so Practice Management's tree
-- treats the two identically.
UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-511', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'Organization'
 WHERE c.menu_key = N'subscription-request-approvals'
   AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
PRINT '511: menu parent wired.';
GO

-- Out of the Practice Management sidebar, Active everywhere else. See
-- the header: this is the 390 pair that makes a screen permission-bearing
-- without putting it in navigation.
UPDATE grac_practice.menu_master
   SET show_in_sidebar = 0, updated_by = N'seed-511', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'subscription-request-approvals'
   AND show_in_sidebar = 1;
PRINT '511: hidden from the Practice Management sidebar.';
GO

-- =====================================================================
-- 4. Grants -- VIEW and APPROVE for every role that can already VIEW
--    Organization Setup, which is the GRAC-admin screen this module is
--    for. Missing rows only, so a re-run never re-grants a right someone
--    removed in Role Master (the 451 / 490 / 508 rule).
-- =====================================================================
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT DISTINCT p.role_id, d.menu_id, 1, 0, 0, 0, 1, N'Active', @active_rs, N'seed-511', SYSUTCDATETIME()
  FROM grac_practice.menu_master d
  JOIN grac_practice.menu_master c ON c.menu_key = N'organization-setup' AND c.status = N'Active'
  JOIN grac_practice.organization_role_menu_permission p ON p.menu_id = c.menu_id AND p.can_view = 1 AND p.status = N'Active'
 WHERE d.menu_key = N'subscription-request-approvals'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = p.role_id AND e.menu_id = d.menu_id);
PRINT CONCAT('511: approval grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 5. Verification
-- =====================================================================
PRINT '--- 511 verification ---';
SELECT CASE WHEN OBJECT_ID('grac_practice.sp_org_subscription_request_approvals_repository_get','P') IS NULL
            THEN 'MISSING' ELSE 'ok' END AS get_shim,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_subscription_request_approvals_repository_manage','P') IS NULL
            THEN 'MISSING' ELSE 'ok' END AS manage_shim;

SELECT menu_key, menu_name, status, show_in_sidebar, display_order,
       (SELECT p.menu_key FROM grac_practice.menu_master p WHERE p.menu_id = m.parent_menu_id) AS parent_key
  FROM grac_practice.menu_master m
 WHERE m.menu_key = N'subscription-request-approvals';

DECLARE @grants INT = (
    SELECT COUNT(*) FROM grac_practice.organization_role_menu_permission p
      JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
     WHERE m.menu_key = N'subscription-request-approvals' AND p.status = N'Active');
PRINT CONCAT('511: roles that can see the screen: ', @grants);

-- The read shim must answer, whether or not any request exists yet.
EXEC grac_practice.sp_org_subscription_request_approvals_repository_get
     @p_entity_type = N'subscription-request-approvals', @p_action = N'QUERY';
GO

SET NOEXEC OFF;
GO
PRINT '511 complete. Restart the Api (the shim probe is cached per process), then sign out and in again -- permissions are read at sign-in.';
GO
