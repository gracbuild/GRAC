-- =====================================================================
-- 203 My Notifications — menu, permissions, feature flag, bulk mark
--     (Phase 4; BRD §13 delivery)
--
-- Phase 3 populated task_notification_outbox but nothing drained it. The
-- chosen dispatcher is an IN-APP notification centre: the recipient opens
-- a screen, sees their obligations, and marks them read. For this channel
-- "read by the recipient" IS delivery, so a read maps to status_code
-- 'Sent' and no new lifecycle state is needed.
--
-- WHY NOT MARK-ON-RENDER
-- ----------------------
-- Auto-marking everything the moment a list renders is the usual
-- shortcut, and it is dishonest: it records "delivered" for rows the user
-- scrolled past without reading. Since these rows are the evidence that
-- somebody was told about an SLA breach, the marking is explicit —
-- per-row, or an intentional "mark all read". The unread badge therefore
-- means what it says.
--
-- CONTENTS
--   1. Feature flag  screen.my-notifications
--   2. Menu row under nav-oversight, granted to EVERY active role
--   3. Per-organisation enable
--   4. sp_task_notification_mark_all — bulk read for one recipient
--
-- Follows 154 (My Acknowledgements) exactly: same parent, same
-- grant-to-all-roles reasoning — an SLA notification is addressed to a
-- named individual, so restricting the screen to Admin would hide from
-- people the very thing that was addressed to them.
--
-- Rollback: database/203_task_notification_menu_seed_rollback.sql
-- ERROR CODE RANGE: 55900-55999 (shared with 202)
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (203): menu_master missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN PRINT 'ABORT (203): organization_role / permission missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN PRINT 'ABORT (203): feature_flag master missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.task_notification_outbox','U') IS NULL
BEGIN PRINT 'ABORT (203): task_notification_outbox missing. Run 201 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('203_task_notification_menu_seed: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Feature flag
-- =====================================================================
MERGE grac_practice.feature_flag_master AS t
USING (VALUES
    (N'screen.my-notifications', N'My Notifications',
     N'Recipient inbox for SLA task notifications (migrations 201-203).')
) AS src(feature_code, feature_name, description)
ON t.feature_code = src.feature_code
WHEN MATCHED THEN UPDATE SET
    feature_name = src.feature_name, description = src.description,
    updated_by = 'seed-203', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (feature_code, feature_name, description, default_enabled, entered_by)
VALUES (src.feature_code, src.feature_name, src.description, 0, 'seed-203');
GO

-- =====================================================================
-- 2. Menu row
--     display_order 270 — immediately after my-acknowledgements (260),
--     so the two personal inboxes sit together.
-- =====================================================================
DECLARE @oversight_menu_id BIGINT =
    (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight');
IF @oversight_menu_id IS NULL
BEGIN
    RAISERROR('203: parent menu nav-oversight is missing. Run 052 first.', 16, 1);
    SET NOEXEC ON;
END

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'my-notifications', N'My Notifications',
     N'Practice/Index/my-notifications',
     @oversight_menu_id, 270, N'bell', N'Oversight')
) AS source(menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = source.menu_name, menu_url = source.menu_url,
    parent_menu_id = source.parent_menu_id, display_order = source.display_order,
    icon_class = source.icon_class, module_type = source.module_type,
    status = N'Active', updated_by = 'seed-203', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order,
     icon_class, module_type, status, entered_by)
VALUES (source.menu_key, source.menu_name, source.menu_url, source.parent_menu_id,
        source.display_order, source.icon_class, source.module_type, N'Active', 'seed-203');
GO

-- =====================================================================
-- 3. Grant to EVERY active organization role
--
--    can_edit = 1 because marking your own notification read is an edit.
--    can_delete = 0: an outbox row is evidence that GRAC determined
--    somebody should be told, and a recipient must not be able to erase
--    it. Suppressing is an administrative action, not a personal one.
-- =====================================================================
DECLARE @menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'my-notifications');
DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

IF @menu_id IS NOT NULL
BEGIN
    MERGE grac_practice.organization_role_menu_permission AS target
    USING (
        SELECT r.role_id, @menu_id AS menu_id,
               CAST(1 AS BIT) AS can_view, CAST(0 AS BIT) AS can_add,
               CAST(1 AS BIT) AS can_edit, CAST(0 AS BIT) AS can_delete,
               CAST(0 AS BIT) AS can_approve, @active_record_status_id AS record_status_id
          FROM grac_practice.organization_role r
         WHERE r.status = N'Active'
    ) AS source
    ON target.role_id = source.role_id AND target.menu_id = source.menu_id
    WHEN MATCHED THEN UPDATE SET
        can_view = source.can_view, can_add = source.can_add,
        can_edit = source.can_edit, can_delete = source.can_delete,
        can_approve = source.can_approve,
        status = N'Active', updated_by = 'seed-203', updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
         status, record_status_id, entered_by)
    VALUES (source.role_id, source.menu_id, source.can_view, source.can_add,
            source.can_edit, source.can_delete, source.can_approve,
            N'Active', source.record_status_id, 'seed-203');
END
GO

-- =====================================================================
-- 4. Enable per organisation
-- =====================================================================
DECLARE @f_id INT = (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.my-notifications');
IF @f_id IS NOT NULL
BEGIN
    MERGE grac_practice.feature_flag AS target
    USING (
        SELECT o.organization_id, @f_id AS feature_flag_id
          FROM grac_practice.organization o WHERE o.status = N'Active'
    ) AS source
    ON target.organization_id = source.organization_id AND target.feature_flag_id = source.feature_flag_id
    WHEN MATCHED THEN UPDATE SET is_enabled = 1,
        notes = COALESCE(target.notes, N'Enabled by seed-203'),
        updated_by = 'seed-203', updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (organization_id, feature_flag_id, is_enabled, notes, entered_by)
    VALUES (source.organization_id, source.feature_flag_id, 1, N'Enabled by seed-203', 'seed-203');
END
GO

-- =====================================================================
-- 5. sp_task_notification_mark_all
--
-- "Mark all read" for one recipient. Scoped to a single employee on
-- purpose — there is no all-organisations variant, because marking
-- somebody ELSE's notification read would destroy the only evidence that
-- they had not seen it.
--
-- @notify_event_code lets a user clear just their warnings while leaving
-- breaches standing.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_notification_mark_all
    @recipient_employee_id BIGINT,
    @organization_id       BIGINT       = NULL,
    @notify_event_code     NVARCHAR(30) = NULL,
    @caller_display_name   NVARCHAR(100) = N'system',
    @marked_count          INT          = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @marked_count = 0;

    IF @recipient_employee_id IS NULL
        THROW 55920, 'sp_task_notification_mark_all: recipient_employee_id is required. Marking notifications read is always personal.', 1;

    UPDATE grac_practice.task_notification_outbox
       SET status_code     = N'Sent',
           sent_dt         = SYSUTCDATETIME(),
           last_attempt_dt = SYSUTCDATETIME(),
           attempt_count   = attempt_count + 1
     WHERE recipient_employee_id = @recipient_employee_id
       AND status_code           = N'Pending'
       AND (@organization_id IS NULL   OR organization_id   = @organization_id)
       AND (@notify_event_code IS NULL OR notify_event_code = @notify_event_code);

    SET @marked_count = @@ROWCOUNT;

    SELECT @recipient_employee_id AS RecipientEmployeeId,
           @marked_count          AS MarkedCount;
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT 'my-notifications menu row' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'my-notifications' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'feature flag registered' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.feature_flag_master
                          WHERE feature_code = N'screen.my-notifications')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'roles granted view' AS Check_, COUNT(*) AS Roles_
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'my-notifications' AND p.can_view = 1;

SELECT 'sp_task_notification_mark_all present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_task_notification_mark_all','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '203 My Notifications menu + permissions + feature flag + bulk mark installed.';
GO

SET NOEXEC OFF;
GO
