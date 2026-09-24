-- =====================================================================
-- 326 Task view -- expose the task's Organization Name
--
-- WHY
-- ---
-- The new Task View full page (Task Center -- dedicated read-only view
-- of a single task, replacing the old "View" modal/drawer) needs a
-- "Related Organization" fact. vw_pm_practice_task (195) already
-- projects organization_id on every task row, but never the
-- organization's name -- every caller that wanted a name today had to
-- resolve it separately (there was no caller that needed to, until this
-- page). Everywhere else on the new page reuses the existing
-- GET /practice/api/tasks/{id} read as-is; this one column is the
-- single, minimal, additive exception, following the same
-- reissue-the-view-with-one-more-column pattern 325 used for
-- sp_custom_gap_header's IdentifiedDate.
--
-- WHAT THIS ADDS
-- --------------
-- vw_pm_practice_task (195's body, re-issued verbatim otherwise): one
-- new LEFT JOIN to grac_practice.organization, and one new projected
-- column, org.organization_name AS organization_name. No table/column
-- changes. TaskService.MapRow already reads v2 columns tolerantly via
-- GetString(reader, cols, "..."), so the C# side change (adding
-- OrganizationName to TaskListRow) degrades gracefully even against an
-- un-migrated database -- it will simply come back null until this
-- migration runs.
--
-- Depends on 195 (vw_pm_practice_task, sp_task_get and friends).
-- Rollback: 326_task_view_organization_name_rollback.sql.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (326): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
   OR OBJECT_ID('grac_practice.task_type_master','U') IS NULL
   OR OBJECT_ID('grac_practice.entity_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
BEGIN
    PRINT 'ABORT (326): practice_task / task_type_master / entity_status_master / organization missing (run 037, 192, 195 first).';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.organization','organization_name') IS NULL
BEGIN
    PRINT 'ABORT (326): organization.organization_name missing.';
    SET NOEXEC ON;
END
GO

-- View creation must be the only statement in its batch, and the column
-- list it depends on (org_sla_config, related_entity_type_master, ...)
-- may not exist on an older database -- same reason 195 wraps its own
-- CREATE VIEW in dynamic SQL rather than a plain top-level statement.
IF OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NOT NULL
    DROP VIEW grac_practice.vw_pm_practice_task;
GO

IF OBJECT_ID('grac_practice.practice_task','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.task_type_master','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.entity_status_master','U') IS NOT NULL
BEGIN
    EXEC sp_executesql N'
CREATE VIEW grac_practice.vw_pm_practice_task AS
WITH base AS (
    SELECT t.*,
           tt.type_code    AS task_type_code_x,
           tt.type_name    AS task_type_name_x,
           s.status_code   AS status_code_x,
           s.status_name   AS status_name_x,
           s.is_terminal   AS is_terminal_x,
           -- Warning threshold: org tuning first, then the master, then 75%.
           COALESCE(cfg.warning_pct, 75.0) AS warning_pct_x,
           COALESCE(t.start_date, t.entered_dt) AS sla_baseline_x
      FROM grac_practice.practice_task t
      JOIN grac_practice.task_type_master    tt ON tt.task_type_id    = t.task_type_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
 LEFT JOIN grac_practice.org_sla_config     cfg ON cfg.organization_id = t.organization_id
                                               AND cfg.sla_master_id   = t.sla_master_id
                                               AND cfg.is_active       = 1
),
timed AS (
    SELECT b.*,
           CASE
             WHEN b.closed_at IS NOT NULL OR b.is_terminal_x = 1 THEN N''Completed''
             WHEN b.sla_due_at IS NULL                            THEN N''NotSet''
             WHEN SYSUTCDATETIME() > b.sla_due_at                 THEN N''Breached''
             WHEN CAST(SYSUTCDATETIME() AS DATE) = CAST(b.sla_due_at AS DATE) THEN N''DueToday''
             WHEN DATEDIFF(SECOND, b.sla_baseline_x, b.sla_due_at) > 0
              AND (CAST(DATEDIFF(SECOND, b.sla_baseline_x, SYSUTCDATETIME()) AS DECIMAL(18,4))
                   / NULLIF(CAST(DATEDIFF(SECOND, b.sla_baseline_x, b.sla_due_at) AS DECIMAL(18,4)), 0)) * 100.0
                  >= b.warning_pct_x                              THEN N''DueSoon''
             ELSE N''OnTrack''
           END AS sla_timing_code
      FROM base b
)
SELECT t.task_id,
       t.task_number,
       t.organization_id,
       -- 326: resolved organization name, joined below. Every other
       -- column and join in this view is UNCHANGED from 195.
       org.organization_name                   AS organization_name,
       t.task_type_id,
       t.task_type_code_x                      AS task_type_code,
       t.task_type_name_x                      AS task_type_name,
       t.subject_entity_type,
       t.subject_entity_id,
       t.linked_release_id,
       t.linked_control_id,
       t.linked_practice_id,
       t.linked_instance_id,
       t.related_entity_type_id,
       ret.entity_code                         AS related_entity_type_code,
       ret.entity_name                         AS related_entity_type_name,
       t.related_record_id,
       t.assurance_activity_id,
       t.workflow_id,
       t.current_workflow_stage_id,
       t.subject_title,
       t.subject_description,
       t.assigned_to_employee_id,
       emp.employee_name                       AS assigned_to_employee_name,
       t.owner_source_code,
       t.current_status_id,
       t.status_code_x                         AS current_status_code,
       t.status_name_x                         AS current_status_name,
       t.is_terminal_x                         AS current_status_is_terminal,
       t.priority,
       t.criticality,
       t.origin_code,
       t.start_date,
       t.sla_due_at,
       CASE
         WHEN t.sla_due_at IS NULL THEN NULL
         WHEN t.is_terminal_x = 1 THEN NULL
         WHEN SYSUTCDATETIME() > t.sla_due_at THEN 1
         ELSE 0
       END                                     AS is_overdue,
       t.escalated_at,
       t.reason_code,
       t.reason_text,
       t.correlation_id,
       t.closed_at,

       -- ---- v2: SLA split (BRD Sec 8) -----------------------------------
       t.standard_sla_days,
       t.standard_due_at,
       t.approved_extended_due_at,
       t.sla_source_code,
       t.sla_master_id,
       t.sla_master_name,
       t.extension_status_code,
       t.requested_due_at,
       t.extension_reason,
       CASE WHEN t.extension_status_code = N''Approved''
             AND t.approved_extended_due_at IS NOT NULL
            THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_extended,

       -- ---- v2: SLA monitoring (BRD Sec 13, 17) --------------------------
       t.sla_timing_code,
       CASE
         WHEN t.sla_timing_code IN (N''Breached'', N''Completed'', N''NotSet'')
              THEN t.sla_timing_code
         WHEN t.extension_status_code = N''Approved''
              AND t.approved_extended_due_at IS NOT NULL
              THEN N''Extended''
         ELSE t.sla_timing_code
       END                                     AS sla_status_code,
       t.warning_pct_x                         AS sla_warning_pct,
       CASE WHEN t.sla_due_at IS NULL OR t.closed_at IS NOT NULL THEN NULL
            ELSE DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), CAST(t.sla_due_at AS DATE))
       END                                     AS days_to_due,

       -- ---- v2: priority governance (BRD Sec 7) ---------------------------
       t.requested_priority,
       t.priority_change_status_code,

       -- ---- v2: parent / child (BRD Sec 11, 12) --------------------------
       t.parent_task_id,
       p.task_number                           AS parent_task_number,
       p.subject_title                         AS parent_task_title,
       t.is_mandatory_child,
       t.child_target_date,
       CASE WHEN t.parent_task_id IS NOT NULL THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_child,
       ISNULL(ch.ChildCount, 0)                AS child_count,
       ISNULL(ch.MandatoryChildCount, 0)       AS mandatory_child_count,
       ISNULL(ch.MandatoryChildOpenCount, 0)   AS mandatory_child_open_count,
       CASE WHEN t.closed_at IS NOT NULL THEN CAST(0 AS BIT)
            WHEN ISNULL(ch.MandatoryChildOpenCount, 0) = 0 THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT) END            AS is_eligible_for_completion,

       -- ---- v2: source navigation (BRD Sec 15) ----------------------------
       t.source_type_code,
       t.source_record_id,
       t.source_reference,

       -- ---- v2: completion (BRD Sec 10) -----------------------------------
       t.completed_by_employee_id,
       cmp.employee_name                       AS completed_by_employee_name,
       t.completed_dt,

       t.entered_by, t.entered_dt, t.updated_by, t.updated_dt
FROM timed t
LEFT JOIN grac_practice.related_entity_type_master ret ON ret.related_entity_type_id = t.related_entity_type_id
LEFT JOIN grac_practice.organization_employee      emp ON emp.employee_id = t.assigned_to_employee_id
LEFT JOIN grac_practice.organization_employee      cmp ON cmp.employee_id = t.completed_by_employee_id
LEFT JOIN grac_practice.practice_task              p   ON p.task_id       = t.parent_task_id
LEFT JOIN grac_practice.organization               org ON org.organization_id = t.organization_id
OUTER APPLY (
    SELECT COUNT(*)                                                                   AS ChildCount,
           SUM(CASE WHEN ISNULL(c.is_mandatory_child,1) = 1 THEN 1 ELSE 0 END)        AS MandatoryChildCount,
           SUM(CASE WHEN ISNULL(c.is_mandatory_child,1) = 1
                     AND c.closed_at IS NULL THEN 1 ELSE 0 END)                       AS MandatoryChildOpenCount
      FROM grac_practice.practice_task c
     WHERE c.parent_task_id = t.task_id
) ch;';
END
GO
PRINT '326: vw_pm_practice_task now projects organization_name.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 326 verification ===';

SELECT '326-a view exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '326-b view exposes organization_name',
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task')
                            AND name = 'organization_name')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '326-c view still exposes source_reference (195 regression check)',
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task')
                            AND name = 'source_reference')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '326-d view still exposes entered_by/entered_dt/updated_by/updated_dt (195 regression check)',
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'entered_by')
             AND EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'entered_dt')
             AND EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'updated_by')
             AND EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'updated_dt')
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- 326 diagnostic: a few recent tasks and their resolved organization ---';
SELECT TOP 5 task_id, task_number, organization_id, organization_name, subject_title
  FROM grac_practice.vw_pm_practice_task
 ORDER BY task_id DESC;

PRINT '';
PRINT '326 complete. Task View can now show Related Organization from the';
PRINT 'existing GET /practice/api/tasks/{id} read alone.';
GO

SET NOEXEC OFF;
GO
