-- =====================================================================
-- 504_issues_actions_dashboard_insights_rollback.sql
--
-- Restores sp_dashboard_issues_actions to the 414 body (copied verbatim
-- from 414_management_dashboards.sql). Revert management-dashboard.js
-- with it -- the v2 page reads the 504 rows defensively and also runs on
-- the 414 body (the four added figures are then simply not shown).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_dashboard_issues_actions
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 57310, 'sp_dashboard_issues_actions: organization_id is required.', 1;

    -- Gap Register rows, exactly as the Gap Register lists them.
    SELECT f.RowKey, f.CustomGapId, f.Title, f.StatusText, f.SeverityText, f.OwnerText,
           f.OwnerEmployeeId, f.DueDate, f.IsOpen, f.IsPending, f.IsCompleted, f.IsOverdue, f.AgeDays
      INTO #gap
      FROM grac_practice.fn_pm_gap_centre_rows(@organization_id, NULL, NULL, NULL, NULL) f;

    -- Task Board rows: top-level tasks (sp_task_list shows children only
    -- when asked), with the view's own terminal / overdue flags. Age is
    -- measured from the SLA baseline, COALESCE(start_date, entered_dt).
    SELECT v.task_id, v.task_number, v.subject_title,
           v.current_status_code, v.current_status_name, v.current_status_is_terminal,
           v.is_overdue, v.assigned_to_employee_id, v.assigned_to_employee_name,
           v.priority, v.sla_due_at,
           DATEDIFF(DAY, COALESCE(v.start_date, v.entered_dt), SYSUTCDATETIME()) AS age_days
      INTO #task
      FROM grac_practice.vw_pm_practice_task v
     WHERE v.organization_id = @organization_id
       AND v.parent_task_id IS NULL;

    SELECT x.* INTO #exc
      FROM grac_practice.vw_pm_exception_request_state x
     WHERE x.organization_id = @organization_id;

    -- ---- 0. KPIs --------------------------------------------------------
    SELECT k.SectionKey, k.SectionTitle, k.KpiKey, k.Label, k.Value, k.IsAlert, k.SortOrder
      FROM (
        SELECT N'gaps' AS SectionKey, N'Issues (Gap Register)' AS SectionTitle, N'total' AS KpiKey,
               N'Total' AS Label, COUNT(*) AS Value, CAST(0 AS BIT) AS IsAlert, 1 AS SortOrder FROM #gap
        UNION ALL SELECT N'gaps', N'Issues (Gap Register)', N'open',      N'Open',              SUM(CAST(IsOpen AS INT)),      0, 2 FROM #gap
        UNION ALL SELECT N'gaps', N'Issues (Gap Register)', N'pending',   N'Pending analysis',  SUM(CAST(IsPending AS INT)),   0, 3 FROM #gap
        UNION ALL SELECT N'gaps', N'Issues (Gap Register)', N'overdue',   N'Overdue',           SUM(CAST(IsOverdue AS INT)),   1, 4 FROM #gap
        UNION ALL SELECT N'gaps', N'Issues (Gap Register)', N'completed', N'Closed',            SUM(CAST(IsCompleted AS INT)), 0, 5 FROM #gap
        UNION ALL SELECT N'gaps', N'Issues (Gap Register)', N'noowner',   N'No owner',
                         SUM(CASE WHEN IsOpen = 1 AND OwnerEmployeeId IS NULL THEN 1 ELSE 0 END), 1, 6 FROM #gap

        UNION ALL SELECT N'tasks', N'Tasks (Task Board)', N'total',     N'Total',          COUNT(*), 0, 1 FROM #task
        UNION ALL SELECT N'tasks', N'Tasks (Task Board)', N'open',      N'Open',
                         SUM(CASE WHEN current_status_is_terminal = 0 THEN 1 ELSE 0 END), 0, 2 FROM #task
        UNION ALL SELECT N'tasks', N'Tasks (Task Board)', N'pending',   N'Pending review',
                         SUM(CASE WHEN current_status_code = N'PendingReview' THEN 1 ELSE 0 END), 0, 3 FROM #task
        UNION ALL SELECT N'tasks', N'Tasks (Task Board)', N'overdue',   N'Overdue',
                         SUM(CASE WHEN is_overdue = 1 THEN 1 ELSE 0 END), 1, 4 FROM #task
        UNION ALL SELECT N'tasks', N'Tasks (Task Board)', N'completed', N'Completed',
                         SUM(CASE WHEN current_status_code = N'Closed' THEN 1 ELSE 0 END), 0, 5 FROM #task
        UNION ALL SELECT N'tasks', N'Tasks (Task Board)', N'noowner',   N'No owner',
                         SUM(CASE WHEN current_status_is_terminal = 0 AND assigned_to_employee_id IS NULL THEN 1 ELSE 0 END), 1, 6 FROM #task

        UNION ALL SELECT N'exceptions', N'Exceptions & Waivers', N'total',    N'Total',             COUNT(*), 0, 1 FROM #exc
        UNION ALL SELECT N'exceptions', N'Exceptions & Waivers', N'open',     N'Open requests',     SUM(CAST(is_open AS INT)), 0, 2 FROM #exc
        UNION ALL SELECT N'exceptions', N'Exceptions & Waivers', N'pending',  N'Awaiting approval',
                         SUM(CASE WHEN status_code = N'SubmittedForApproval' THEN 1 ELSE 0 END), 0, 3 FROM #exc
        UNION ALL SELECT N'exceptions', N'Exceptions & Waivers', N'lapsed',   N'Lapsed waivers',    SUM(CAST(is_lapsed AS INT)), 1, 4 FROM #exc
        UNION ALL SELECT N'exceptions', N'Exceptions & Waivers', N'approved', N'Approved',
                         SUM(CASE WHEN status_code = N'Approved' THEN 1 ELSE 0 END), 0, 5 FROM #exc
        UNION ALL SELECT N'exceptions', N'Exceptions & Waivers', N'noowner',  N'No owner',
                         SUM(CASE WHEN is_open = 1 AND owner_employee_id IS NULL THEN 1 ELSE 0 END), 1, 6 FROM #exc
      ) k
     ORDER BY CASE k.SectionKey WHEN N'gaps' THEN 1 WHEN N'tasks' THEN 2 ELSE 3 END, k.SortOrder;

    -- ---- 1. Ageing: OPEN items only ------------------------------------
    SELECT g.GroupKey, g.GroupTitle, b.BandCode, b.BandName, b.SortOrder, b.MinDays, b.MaxDays,
           (SELECT COUNT(*) FROM #gap  x WHERE g.GroupKey = N'gaps'       AND x.IsOpen = 1
                                           AND x.AgeDays BETWEEN b.MinDays AND b.MaxDays)
         + (SELECT COUNT(*) FROM #task x WHERE g.GroupKey = N'tasks'      AND x.current_status_is_terminal = 0
                                           AND x.age_days BETWEEN b.MinDays AND b.MaxDays)
         + (SELECT COUNT(*) FROM #exc  x WHERE g.GroupKey = N'exceptions' AND x.is_open = 1
                                           AND x.age_days BETWEEN b.MinDays AND b.MaxDays) AS ItemCount
      FROM (VALUES (N'gaps',       N'Open issues',              1),
                   (N'tasks',      N'Open tasks',               2),
                   (N'exceptions', N'Open exception requests',  3)) g(GroupKey, GroupTitle, GroupOrder)
     CROSS JOIN grac_practice.fn_pm_ageing_band() b
     ORDER BY g.GroupOrder, b.SortOrder;

    -- ---- 2. Distributions ----------------------------------------------
    SELECT d.GroupKey, d.GroupTitle, d.ItemKey, d.ItemLabel, d.ItemCount, d.ColourHex, d.SortOrder
      FROM (
        -- Issues by the Gap Register's own Status column.
        SELECT N'gaps_status' AS GroupKey, N'Issues by status' AS GroupTitle,
               StatusText AS ItemKey, ISNULL(StatusText, N'(none)') AS ItemLabel,
               COUNT(*) AS ItemCount, CAST(NULL AS NVARCHAR(20)) AS ColourHex,
               ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, StatusText) AS SortOrder
          FROM #gap GROUP BY StatusText
        UNION ALL
        -- Open issues by the list's Severity column.
        SELECT N'gaps_severity', N'Open issues by severity',
               SeverityText, ISNULL(SeverityText, N'(not set)'), COUNT(*), NULL,
               ROW_NUMBER() OVER (ORDER BY CASE SeverityText WHEN N'Critical' THEN 1 WHEN N'High' THEN 2
                                              WHEN N'Medium' THEN 3 WHEN N'Low' THEN 4 ELSE 5 END, SeverityText)
          FROM #gap WHERE IsOpen = 1 GROUP BY SeverityText
        UNION ALL
        SELECT N'tasks_status', N'Tasks by status',
               current_status_code, MAX(current_status_name), COUNT(*), NULL,
               ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, current_status_code)
          FROM #task GROUP BY current_status_code
        UNION ALL
        SELECT N'tasks_priority', N'Open tasks by priority',
               priority, ISNULL(priority, N'(not set)'), COUNT(*), NULL,
               ROW_NUMBER() OVER (ORDER BY CASE priority WHEN N'Critical' THEN 1 WHEN N'High' THEN 2
                                              WHEN N'Medium' THEN 3 WHEN N'Low' THEN 4 ELSE 5 END, priority)
          FROM #task WHERE current_status_is_terminal = 0 GROUP BY priority
        UNION ALL
        -- Labels are the Exceptions & Waivers filter's own labels.
        SELECT N'exceptions_status', N'Exception requests by status',
               status_code,
               CASE status_code WHEN N'SubmittedForApproval' THEN N'Submitted for approval' ELSE status_code END,
               COUNT(*), NULL,
               ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, status_code)
          FROM #exc GROUP BY status_code
        UNION ALL
        SELECT N'exceptions_type', N'Exception requests by type',
               request_type_code,
               CASE request_type_code WHEN N'GAP_CANDIDATE'            THEN N'Gap Candidate'
                                      WHEN N'SLA_CANDIDATE'            THEN N'SLA Candidate'
                                      WHEN N'TASK_SLA_EXTENSION'       THEN N'Task SLA Extension'
                                      WHEN N'TASK_PRIORITY_REDUCTION'  THEN N'Task Priority Reduction'
                                      WHEN N'CUSTOM'                   THEN N'Custom Exception'
                                      ELSE ISNULL(request_type_code, N'(not set)') END,
               COUNT(*), NULL,
               ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, request_type_code)
          FROM #exc GROUP BY request_type_code
      ) d
     ORDER BY CASE d.GroupKey WHEN N'gaps_status' THEN 1 WHEN N'gaps_severity' THEN 2
                              WHEN N'tasks_status' THEN 3 WHEN N'tasks_priority' THEN 4
                              WHEN N'exceptions_status' THEN 5 ELSE 6 END, d.SortOrder;

    -- ---- 3. Lists: the oldest overdue work -----------------------------
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName,
           l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (5) N'tasks_overdue' AS ListKey, N'Overdue tasks' AS ListTitle,
               task_id AS RecordId, task_number AS RefText, subject_title AS Title,
               assigned_to_employee_name AS OwnerName, current_status_name AS StatusText,
               CAST(sla_due_at AS DATE) AS DateValue,
               ROW_NUMBER() OVER (ORDER BY sla_due_at, task_id) AS SortOrder
          FROM #task WHERE is_overdue = 1
         ORDER BY sla_due_at, task_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName,
           l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (5) N'gaps_overdue' AS ListKey, N'Overdue issues' AS ListTitle,
               CustomGapId AS RecordId, RowKey AS RefText, Title,
               OwnerText AS OwnerName, StatusText, DueDate AS DateValue,
               ROW_NUMBER() OVER (ORDER BY DueDate, RowKey) AS SortOrder
          FROM #gap WHERE IsOverdue = 1
         ORDER BY DueDate, RowKey
      ) l
     ORDER BY 1, 9;
END
GO
PRINT '504 rollback: sp_dashboard_issues_actions restored to the 414 body.';
GO
