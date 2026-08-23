-- =====================================================================
-- 203 My Notifications — menu seed ROLLBACK
--
-- Removes the screen from the sidebar and drops the bulk-mark proc.
--
-- Deactivates rather than deletes the menu row, matching how the other
-- menu-seed rollbacks in this repository behave: menu_id may be
-- referenced by organization_role_menu_permission rows and by audit
-- history, and a hard delete would cascade further than a rollback
-- should.
--
-- The outbox and its rows are NOT touched — 201's rollback owns those.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '203-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_task_notification_mark_all','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_notification_mark_all;
GO

-- Revoke access before hiding the row, so a cached menu cannot leave a
-- reachable screen with live permissions behind it.
DECLARE @menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'my-notifications');

IF @menu_id IS NOT NULL
BEGIN
    UPDATE grac_practice.organization_role_menu_permission
       SET can_view = 0, can_add = 0, can_edit = 0, can_delete = 0, can_approve = 0,
           status = N'Inactive', updated_by = 'rollback-203', updated_dt = SYSUTCDATETIME()
     WHERE menu_id = @menu_id;

    UPDATE grac_practice.menu_master
       SET status = N'Inactive', updated_by = 'rollback-203', updated_dt = SYSUTCDATETIME()
     WHERE menu_id = @menu_id;
END
GO

-- Turn the feature off everywhere; leave the master row so re-running
-- 203 restores the previous state without re-seeding definitions.
DECLARE @f_id INT = (SELECT feature_flag_id FROM grac_practice.feature_flag_master
                      WHERE feature_code = N'screen.my-notifications');
IF @f_id IS NOT NULL
    UPDATE grac_practice.feature_flag
       SET is_enabled = 0, updated_by = 'rollback-203', updated_dt = SYSUTCDATETIME()
     WHERE feature_flag_id = @f_id;
GO

IF OBJECT_ID('grac_practice.task_notification_outbox','U') IS NOT NULL
    SELECT '203-rollback: unread notifications now unreachable in the UI' AS Check_,
           COUNT(*) AS Rows_
      FROM grac_practice.task_notification_outbox
     WHERE status_code = N'Pending';
GO

PRINT '203 My Notifications menu seed rolled back (menu deactivated, not deleted).';
GO

SET NOEXEC OFF;
GO
