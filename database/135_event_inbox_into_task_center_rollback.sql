-- =====================================================================
-- 135 Retire Event Checklist Inbox -- ROLLBACK
--
-- Restores the standalone menu row and reactivates its feature flag.
-- Re-adds the Admin permissions, matching what 125 granted.
--
-- Revert the Web tier too, or the menu will point at a screen the
-- application no longer renders:
--   * PracticeScreen.cs -- restore the "workflow-event-inbox" entry
--   * Manage.cshtml     -- restore "workflow-event-inbox" in workflowScreens
--
-- Note that after this, the same open checklists appear in two places --
-- here and in Task Center's Event Driven Assurance tab -- and both can
-- close them. That ambiguity is what 135 removed.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'workflow-event-inbox', N'Event Checklist Inbox',
     N'Practice/Index/workflow-event-inbox', 460, N'inbox', N'Workflow')
) AS source(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = source.menu_name, menu_url = source.menu_url,
    display_order = source.display_order, icon_class = source.icon_class,
    module_type = source.module_type, status = N'Active',
    updated_by = 'rollback-135', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
VALUES
    (source.menu_key, source.menu_name, source.menu_url, source.display_order,
     source.icon_class, source.module_type, N'Active', 'rollback-135');
GO

DECLARE @wf_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-workflow');
IF @wf_id IS NOT NULL
    UPDATE grac_practice.menu_master
       SET parent_menu_id = @wf_id, updated_by = 'rollback-135', updated_dt = SYSUTCDATETIME()
     WHERE menu_key = N'workflow-event-inbox';
GO

DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

MERGE grac_practice.organization_role_menu_permission AS target
USING (
    SELECT r.role_id, m.menu_id,
           CAST(1 AS BIT) can_view, CAST(1 AS BIT) can_add, CAST(1 AS BIT) can_edit,
           CAST(1 AS BIT) can_delete, CAST(1 AS BIT) can_approve,
           @active_record_status_id AS record_status_id
    FROM   grac_practice.organization_role r
    CROSS JOIN grac_practice.menu_master m
    WHERE  r.role_name = N'Admin' AND r.status = N'Active'
      AND  m.menu_key = N'workflow-event-inbox'
) AS source
ON target.role_id = source.role_id AND target.menu_id = source.menu_id
WHEN MATCHED THEN UPDATE SET
    can_view = source.can_view, can_add = source.can_add, can_edit = source.can_edit,
    can_delete = source.can_delete, can_approve = source.can_approve,
    status = N'Active', updated_by = 'rollback-135', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by)
VALUES
    (source.role_id, source.menu_id, source.can_view, source.can_add, source.can_edit,
     source.can_delete, source.can_approve, N'Active', source.record_status_id, 'rollback-135');
GO

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NOT NULL
    UPDATE grac_practice.feature_flag_master
       SET is_active  = 1,
           description = N'Raise people and asset lifecycle events and complete the resulting scoped checklists (migrations 123/124).',
           updated_by  = 'rollback-135', updated_dt = SYSUTCDATETIME()
     WHERE feature_code = N'screen.workflow-event-inbox';
GO

COMMIT TRAN;
GO

SELECT 'menu restored' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'workflow-event-inbox'
                            AND parent_menu_id IS NOT NULL AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'feature flag reactivated',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.feature_flag_master
                          WHERE feature_code = N'screen.workflow-event-inbox' AND is_active = 1)
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '135 rolled back. Restore PracticeScreen.cs and Manage.cshtml, or the menu leads nowhere.';
GO
