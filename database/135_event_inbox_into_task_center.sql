-- =====================================================================
-- 135 Retire the standalone Event Checklist Inbox screen
--
-- Its contents now live in the Event Driven Assurance tab of Task Center,
-- under Oversight. Task Center's Assurance tab is split in two:
--     Continuous Assurance     -- practice_task rows, as before
--     Event Driven Assurance   -- open event_instance checklists
--
-- WHY THE MENU ROW GOES
-- ---------------------
-- Leaving both would give an organization two screens listing the same open
-- checklists, each able to close them, and no answer to which one is the
-- queue of record. For an operational queue that is worse than having no
-- screen at all: work gets closed in one place and chased in the other.
--
-- WHAT IS NOT REMOVED
-- -------------------
-- screen.workflow-scope-mapping and its menu row stay -- Scoped Obligation
-- Mapping is configuration, not a queue, and belongs under Workflow.
--
-- No data is touched. event_instance, event_instance_obligation and the
-- resolution trace are all untouched; only navigation changes.
--
-- Depends on 125.
-- Rollback: 135_event_inbox_into_task_center_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    RAISERROR('135: menu_master missing.', 16, 1);
    RETURN;
END
GO

BEGIN TRAN;

-- Permissions first: they reference menu_id.
DELETE p
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master m ON m.menu_id = p.menu_id
WHERE  m.menu_key = N'workflow-event-inbox';
GO

DELETE FROM grac_practice.menu_master
 WHERE menu_key = N'workflow-event-inbox';
GO

-- The feature flag is kept. The panel is still feature-gated through Task
-- Center's own screen.tasks flag, and deleting screen.workflow-event-inbox
-- would silently discard whichever organizations had deliberately switched
-- it off. It is marked inactive instead, so it stops appearing in flag
-- administration without losing that record.
IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NOT NULL
    UPDATE grac_practice.feature_flag_master
       SET is_active   = 0,
           description  = N'RETIRED by migration 135. The Event Checklist Inbox is now the Event Driven Assurance tab of Task Center.',
           updated_by   = 'seed-135',
           updated_dt   = SYSUTCDATETIME()
     WHERE feature_code = N'screen.workflow-event-inbox';
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'event-inbox menu removed' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'workflow-event-inbox')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'scope-mapping menu retained',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'workflow-scope-mapping')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'task center menu present',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'tasks')
            THEN 'PASS' ELSE 'FAIL -- Task Center menu missing; the tab has no host' END;

-- Task Center is where the checklists now appear, so its flag has to be on
-- wherever the retired one was.
SELECT o.organization_id,
       o.organization_name AS OrganizationName,
       grac_practice.fn_pm_feature_enabled(o.organization_id, N'screen.tasks') AS TaskCenterEnabled
FROM   grac_practice.organization o
WHERE  o.status = N'Active'
ORDER BY o.organization_id;

PRINT '135 Event Checklist Inbox retired into Task Center.';
PRINT 'Any organization showing TaskCenterEnabled = 0 above has lost access to these';
PRINT 'checklists -- enable screen.tasks for it.';
GO
