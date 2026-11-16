-- =====================================================================
-- 506_audit_assurance_dashboard_insights_rollback.sql
--
-- Restores sp_dashboard_audit_assurance to the 414 body (verbatim from
-- 414_management_dashboards.sql). The v2 page reads the 506 rows
-- defensively, so it keeps working without them. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_dashboard_audit_assurance
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 57311, 'sp_dashboard_audit_assurance: organization_id is required.', 1;

    SELECT xs.org_assurance_execution_id, xs.status_code, xs.stage_code, xs.is_overdue, xs.is_upcoming,
           s.status_name, s.display_order,
           e.execution_code, e.execution_name, e.owner_display_name,
           e.planned_start_dt, e.planned_end_dt
      INTO #aud
      FROM grac_practice.vw_pm_org_assurance_execution_state xs
      JOIN grac_practice.org_assurance_execution e
        ON e.org_assurance_execution_id = xs.org_assurance_execution_id
      JOIN grac_practice.org_assurance_execution_status_master s
        ON s.org_assurance_execution_status_id = e.execution_status_id
     WHERE xs.organization_id = @organization_id;

    SELECT os.org_assurance_observation_id, os.status_code, os.stage_code, os.is_overdue, os.age_days,
           os.severity_code, os.assigned_owner_employee_id,
           st.status_name, st.display_order
      INTO #obs
      FROM grac_practice.vw_pm_org_assurance_observation_state os
      JOIN grac_practice.org_assurance_observation o
        ON o.org_assurance_observation_id = os.org_assurance_observation_id
      JOIN grac_practice.org_assurance_observation_status_master st
        ON st.org_assurance_observation_status_id = o.observation_status_id
     WHERE os.organization_id = @organization_id;

    SELECT p.org_assurance_plan_id, ps.status_code, ps.status_name, ps.display_order
      INTO #pln
      FROM grac_practice.org_assurance_plan p
      JOIN grac_practice.org_assurance_plan_status_master ps
        ON ps.org_assurance_plan_status_id = p.status_id
     WHERE p.organization_id = @organization_id
       AND p.is_active = 1;

    -- ---- 0. KPIs --------------------------------------------------------
    SELECT k.SectionKey, k.SectionTitle, k.KpiKey, k.Label, k.Value, k.IsAlert, k.SortOrder
      FROM (
        SELECT N'audits' AS SectionKey, N'Audits (Executions)' AS SectionTitle, N'total' AS KpiKey,
               N'Total' AS Label, COUNT(*) AS Value, CAST(0 AS BIT) AS IsAlert, 1 AS SortOrder FROM #aud
        UNION ALL SELECT N'audits', N'Audits (Executions)', N'planned',    N'Planned',
                         SUM(CASE WHEN stage_code = N'Planned'    THEN 1 ELSE 0 END), 0, 2 FROM #aud
        UNION ALL SELECT N'audits', N'Audits (Executions)', N'inprogress', N'In progress',
                         SUM(CASE WHEN stage_code = N'InProgress' THEN 1 ELSE 0 END), 0, 3 FROM #aud
        UNION ALL SELECT N'audits', N'Audits (Executions)', N'completed',  N'Completed',
                         SUM(CASE WHEN stage_code = N'Completed'  THEN 1 ELSE 0 END), 0, 4 FROM #aud
        UNION ALL SELECT N'audits', N'Audits (Executions)', N'overdue',    N'Overdue',
                         SUM(CAST(is_overdue AS INT)), 1, 5 FROM #aud
        UNION ALL SELECT N'audits', N'Audits (Executions)', N'upcoming',   N'Starting in 30 days',
                         SUM(CAST(is_upcoming AS INT)), 0, 6 FROM #aud

        UNION ALL SELECT N'findings', N'Findings (Observations)', N'total',    N'Total', COUNT(*), 0, 1 FROM #obs
        UNION ALL SELECT N'findings', N'Findings (Observations)', N'pending',  N'Pending',
                         SUM(CASE WHEN stage_code = N'Pending'         THEN 1 ELSE 0 END), 0, 2 FROM #obs
        UNION ALL SELECT N'findings', N'Findings (Observations)', N'awaiting', N'Resolved, awaiting closure',
                         SUM(CASE WHEN stage_code = N'AwaitingClosure' THEN 1 ELSE 0 END), 0, 3 FROM #obs
        UNION ALL SELECT N'findings', N'Findings (Observations)', N'overdue',  N'Overdue',
                         SUM(CAST(is_overdue AS INT)), 1, 4 FROM #obs
        UNION ALL SELECT N'findings', N'Findings (Observations)', N'closed',   N'Closed',
                         SUM(CASE WHEN stage_code = N'Closed'          THEN 1 ELSE 0 END), 0, 5 FROM #obs
        UNION ALL SELECT N'findings', N'Findings (Observations)', N'noowner',  N'No owner',
                         SUM(CASE WHEN stage_code = N'Pending' AND assigned_owner_employee_id IS NULL THEN 1 ELSE 0 END), 1, 6 FROM #obs

        UNION ALL SELECT N'plans', N'Audit plans', N'total',  N'Total',  COUNT(*), 0, 1 FROM #pln
        UNION ALL SELECT N'plans', N'Audit plans', N'active', N'Active',
                         SUM(CASE WHEN status_code = N'Active' THEN 1 ELSE 0 END), 0, 2 FROM #pln
      ) k
     ORDER BY CASE k.SectionKey WHEN N'audits' THEN 1 WHEN N'findings' THEN 2 ELSE 3 END, k.SortOrder;

    -- ---- 1. Ageing: pending findings, from observed_dt ------------------
    SELECT N'findings' AS GroupKey, N'Pending findings' AS GroupTitle,
           b.BandCode, b.BandName, b.SortOrder, b.MinDays, b.MaxDays,
           (SELECT COUNT(*) FROM #obs x WHERE x.stage_code = N'Pending'
                                          AND x.age_days BETWEEN b.MinDays AND b.MaxDays) AS ItemCount
      FROM grac_practice.fn_pm_ageing_band() b
     ORDER BY b.SortOrder;

    -- ---- 2. Distributions ----------------------------------------------
    SELECT d.GroupKey, d.GroupTitle, d.ItemKey, d.ItemLabel, d.ItemCount, d.ColourHex, d.SortOrder
      FROM (
        SELECT N'audits_status' AS GroupKey, N'Audits by status' AS GroupTitle,
               status_code AS ItemKey, MAX(status_name) AS ItemLabel, COUNT(*) AS ItemCount,
               CAST(NULL AS NVARCHAR(20)) AS ColourHex, MIN(display_order) AS SortOrder
          FROM #aud GROUP BY status_code
        UNION ALL
        -- Colours are the severity master's own (101).
        SELECT N'findings_severity', N'Pending findings by severity',
               o.severity_code, ISNULL(MAX(sv.severity_name), ISNULL(o.severity_code, N'(not set)')),
               COUNT(*), MAX(sv.color_hex), ISNULL(MIN(sv.display_order), 99)
          FROM #obs o
          LEFT JOIN grac_practice.org_assurance_observation_severity_master sv
                 ON sv.severity_code = o.severity_code
         WHERE o.stage_code = N'Pending'
         GROUP BY o.severity_code
        UNION ALL
        SELECT N'findings_status', N'Findings by status',
               status_code, MAX(status_name), COUNT(*), NULL, MIN(display_order)
          FROM #obs GROUP BY status_code
        UNION ALL
        SELECT N'plans_status', N'Audit plans by status',
               status_code, MAX(status_name), COUNT(*), NULL, MIN(display_order)
          FROM #pln GROUP BY status_code
      ) d
     ORDER BY CASE d.GroupKey WHEN N'audits_status' THEN 1 WHEN N'findings_severity' THEN 2
                              WHEN N'findings_status' THEN 3 ELSE 4 END, d.SortOrder;

    -- ---- 3. Lists: upcoming and overdue audits ---------------------------
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName,
           l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'audits_upcoming' AS ListKey, N'Audits starting in the next 30 days' AS ListTitle,
               org_assurance_execution_id AS RecordId, execution_code AS RefText, execution_name AS Title,
               owner_display_name AS OwnerName, status_name AS StatusText,
               planned_start_dt AS DateValue,
               ROW_NUMBER() OVER (ORDER BY planned_start_dt, org_assurance_execution_id) AS SortOrder
          FROM #aud WHERE is_upcoming = 1
         ORDER BY planned_start_dt, org_assurance_execution_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName,
           l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (5) N'audits_overdue' AS ListKey, N'Overdue audits' AS ListTitle,
               org_assurance_execution_id AS RecordId, execution_code AS RefText, execution_name AS Title,
               owner_display_name AS OwnerName, status_name AS StatusText,
               planned_end_dt AS DateValue,
               ROW_NUMBER() OVER (ORDER BY planned_end_dt, org_assurance_execution_id) AS SortOrder
          FROM #aud WHERE is_overdue = 1
         ORDER BY planned_end_dt, org_assurance_execution_id
      ) l
     ORDER BY 1, 9;
END
GO
PRINT '506 rollback: sp_dashboard_audit_assurance restored to the 414 body.';
GO
