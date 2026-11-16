-- =====================================================================
-- 555  Phase 3 -- My Audits, live scope, Freeze Scope
--
-- REQUEST (2026-11-14, sir) -- docs/audit-flow-redesign.md Phase 3.
-- DECISIONS (sir):
--   * Executions are created AUTOMATICALLY when the auditor opens My Audits
--     on or after the engagement's From date; Start Execution on the plan
--     stays (an admin may start early).
--   * My Audits is a new sidebar menu item under Audit Assurance.
--   * Before freezing, the auditor may EXCLUDE items from the live scope,
--     each with a reason (kept on the execution).
--   * Frozen is FINAL -- to change the scope, cancel and start again.
--
-- MODEL
--   An engagement's execution is created with a LIVE scope: no entity rows
--   and scope_frozen_at NULL. Its live scope is the audit's scope resolved
--   now, narrowed to the engagement's Branch (554). The auditor (the
--   execution's owner = the engagement's Assigned Auditor) reviews it and
--   clicks Freeze Scope: the scope is resolved (EXECUTION), narrowed, the
--   exclusions removed and recorded, the entity rows copied, and the
--   execution moves Planned -> In Progress. Manual / trigger executions are
--   frozen at creation, as before. Executions that exist already are
--   marked frozen (they have their entities).
--
-- WHAT THIS DOES
--   1. org_assurance_execution + scope_frozen_at / scope_frozen_by
--      (backfilled for existing rows); NEW org_assurance_execution_scope_exclusion.
--   2. Menu: org-my-audits "My Audits" under nav-assurance (468, before
--      Executions), granted to every active role (it lists only the
--      caller's own audits).
--   3. sp_org_assurance_execution_materialize (545 body) + @live.
--   4. sp_org_assurance_plan_item_start_execution (554 body): creates the
--      executions LIVE (the 554 narrowing moves to the live view / freeze);
--      + @suppress_result.
--   5. sp_org_assurance_execution_start (099 body): refuses a live scope
--      (54030) -- the auditor starts by freezing.
--   6. sp_org_assurance_execution_get (120 body) + ScopeFrozenAt / By,
--      ScopeExclusionCount.
--   7. NEW sp_org_assurance_my_audits_prepare(@employee_id): starts the
--      due engagements of that auditor (From <= today, plan Approved /
--      Active, audits not started); one engagement failing does not stop
--      the others.
--   8. NEW sp_org_assurance_my_audit_list(@employee_id): one row per audit
--      of the auditor's engagements with its execution and state
--      (Upcoming / Ready / ScopeLive / InProgress / Completed / Cancelled).
--   9. NEW sp_org_assurance_execution_live_scope: the live scope (resolved
--      in a rolled-back transaction, branch-narrowed); nothing saved.
--  10. NEW sp_org_assurance_execution_freeze_scope (auditor only).
--  11. NEW sp_org_assurance_execution_scope_exclusion_list.
--
-- ERRORS: 54030 live scope -- freeze first; 54031 scope already frozen;
--   54032 only the assigned auditor can freeze; 54033 freeze only while
--   Planned; 54034 an exclusion is not in the scope or has no reason;
--   54035 nothing left in scope; 54036 employee required.
-- DEPENDS ON: 545, 552, 554.
-- Rollback: 555_my_audits_freeze_scope_rollback.sql.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_scope_resolution_narrow_location','P') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_engagement_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_assurance_execution_materialize','P') IS NULL
BEGIN
    PRINT 'ABORT (555): run 545, 552 and 554 first. Nothing was changed.';
    RAISERROR('555_my_audits_freeze_scope: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Schema
-- =====================================================================
IF COL_LENGTH('grac_practice.org_assurance_execution','scope_frozen_at') IS NULL
BEGIN
    ALTER TABLE grac_practice.org_assurance_execution ADD
        scope_frozen_at DATETIME2     NULL,
        scope_frozen_by NVARCHAR(100) NULL;
    PRINT '555.1: scope_frozen_at / scope_frozen_by added.';
    -- Every execution that exists already was snapshotted at creation.
    -- Only here, when the columns are new: on a re-run, a NULL is a live
    -- scope and must stay NULL. (Dynamic: the columns are new in this batch.)
    EXEC sp_executesql N'
        UPDATE grac_practice.org_assurance_execution
           SET scope_frozen_at = ISNULL(entered_dt, SYSUTCDATETIME()),
               scope_frozen_by = N''migration-555''
         WHERE scope_frozen_at IS NULL;
        PRINT ''555.1: existing executions marked frozen = '' + CAST(@@ROWCOUNT AS NVARCHAR(20));';
END
GO

IF OBJECT_ID('grac_practice.org_assurance_execution_scope_exclusion','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_execution_scope_exclusion(
        org_assurance_execution_scope_exclusion_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_oa_exec_scope_excl PRIMARY KEY,
        organization_id            BIGINT        NOT NULL,
        org_assurance_execution_id BIGINT        NOT NULL,
        dimension_code             NVARCHAR(60)  NOT NULL,
        dimension_name             NVARCHAR(160) NULL,
        entity_id                  BIGINT        NOT NULL,
        entity_code                NVARCHAR(120) NULL,
        entity_name                NVARCHAR(240) NULL,
        reason                     NVARCHAR(1000) NOT NULL,
        entered_by                 NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_oa_exec_scope_excl_ent_by DEFAULT 'system',
        entered_dt                 DATETIME2     NOT NULL
            CONSTRAINT df_pm_oa_exec_scope_excl_ent_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT fk_pm_oa_exec_scope_excl_exec
            FOREIGN KEY(org_assurance_execution_id)
            REFERENCES grac_practice.org_assurance_execution(org_assurance_execution_id),
        CONSTRAINT fk_pm_oa_exec_scope_excl_org
            FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT uq_pm_oa_exec_scope_excl
            UNIQUE(org_assurance_execution_id, dimension_code, entity_id)
    );
    PRINT '555.1: org_assurance_execution_scope_exclusion created.';
END
GO

-- =====================================================================
-- 2. Menu: Audit Assurance -> My Audits (also in 274's snapshot)
-- =====================================================================
DECLARE @assurance_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'org-my-audits', N'My Audits', N'Practice/org-my-audits', 468, N'user-check')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @assurance_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Audit Assurance',
    status = N'Active', updated_by = 'seed-555', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @assurance_id, src.display_order,
     src.icon_class, N'Audit Assurance', N'Active', 'seed-555');
PRINT '555.2: org-my-audits menu row upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- Every active role (the list shows only the caller's own audits), as 530.
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 0,
       N'Active', @active_rs, N'seed-555', SYSUTCDATETIME()
FROM   grac_practice.organization_role r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_practice.menu_master m ON m.menu_key = N'org-my-audits'
WHERE  o.status = N'Active' AND r.status = N'Active'
  AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission p
        WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);
PRINT '555.2: org-my-audits permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO
