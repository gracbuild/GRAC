-- =====================================================================
-- 505_risk_dashboard_insights_rollback.sql
--
-- Restores sp_risk_dashboard_counts to the 413 body (copied verbatim
-- from 413_risk_management_dashboard.sql). The Api reads sets 17-19 only
-- when present, so it keeps working; the v2 page then omits the lifecycle,
-- treatment and residual-rating charts. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_dashboard_counts
    @organization_id BIGINT,
    @trend_months    INT = 12
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 56350, 'sp_risk_dashboard_counts: organization_id is required.', 1;
    IF @trend_months IS NULL OR @trend_months <= 0 SET @trend_months = 12;
    IF @trend_months > 60 SET @trend_months = 60;

    -- The statuses a candidate is still being worked in. Declared once
    -- so every tile below counts "open" the same way -- the Candidates
    -- grid, the approval queue and this dashboard must not disagree
    -- about what is outstanding.
    DECLARE @open TABLE (status_code NVARCHAR(30) PRIMARY KEY);
    INSERT INTO @open(status_code)
    VALUES (N'Pending'), (N'UnderAnalysis'), (N'ClarificationRequired'), (N'AnalysisCompleted');

    -- WHY THE "OPEN" TEST IS A JOIN AND NOT AN IN (SELECT ...)
    -- -------------------------------------------------------
    -- SQL Server rejects a subquery inside an aggregate (Msg 130), so
    -- SUM(CASE WHEN status IN (SELECT ... FROM @open) ...) will not
    -- compile. The obvious workaround -- inlining the four literals at
    -- every call site -- would defeat the point of declaring the set
    -- once, and is exactly how the dashboard and the grids drift apart.
    --
    -- So the openness test is resolved ONCE, in a LEFT JOIN, and every
    -- aggregate then works on a plain 0/1 column. One definition, and it
    -- compiles.
    --
    -- The @open set is also used in WHERE clauses further down (result
    -- sets 0's approval subquery and 8's ageing CTE). That form is legal
    -- -- the restriction is aggregate-of-subquery, not subquery-anywhere.

    -- ---- 0. Candidate summary (sec.23) ----------------------------------
    ;WITH cand AS (
        SELECT c.status_code,
               CASE WHEN o.status_code IS NULL THEN 0 ELSE 1 END AS is_open,
               DATEDIFF(DAY, COALESCE(c.identified_dt, c.requested_dt), SYSUTCDATETIME()) AS age_days
          FROM grac_practice.risk_candidate c
     LEFT JOIN @open o ON o.status_code = c.status_code
         WHERE c.organization_id = @organization_id
    )
    SELECT
        COUNT(*)                                                                 AS TotalCandidates,
        SUM(is_open)                                                             AS OpenCandidates,
        SUM(CASE WHEN status_code = N'Pending'               THEN 1 ELSE 0 END)  AS NewCandidates,
        SUM(CASE WHEN status_code = N'UnderAnalysis'         THEN 1 ELSE 0 END)  AS UnderAnalysisCount,
        SUM(CASE WHEN status_code = N'ClarificationRequired' THEN 1 ELSE 0 END)  AS AwaitingClarificationCount,
        -- "Awaiting approval" is the analysis-level fact, not a candidate
        -- status: a candidate sits in AnalysisCompleted whether or not
        -- anyone has submitted it. Counting the status would overstate
        -- the approver's queue.
        --
        -- A scalar subquery in the SELECT list is fine; it is only
        -- aggregates that may not contain one.
        (SELECT COUNT(*) FROM grac_practice.risk_analysis a
           JOIN grac_practice.risk_candidate ac ON ac.risk_candidate_id = a.risk_candidate_id
          WHERE a.organization_id = @organization_id
            AND a.is_current = 1
            AND a.approval_status_code = N'Pending'
            AND ac.status_code IN (SELECT status_code FROM @open))               AS AwaitingApprovalCount,
        SUM(CASE WHEN status_code = N'AnalysisCompleted'     THEN 1 ELSE 0 END)  AS AnalysisCompletedCount,
        SUM(CASE WHEN status_code = N'Rejected'              THEN 1 ELSE 0 END)  AS RejectedCount,
        SUM(CASE WHEN status_code = N'ClosedAsDuplicate'     THEN 1 ELSE 0 END)  AS ClosedAsDuplicateCount,
        SUM(CASE WHEN status_code = N'Withdrawn'             THEN 1 ELSE 0 END)  AS WithdrawnCount,
        SUM(CASE WHEN status_code = N'Registered'            THEN 1 ELSE 0 END)  AS ConvertedToRiskCount,
        SUM(CASE WHEN status_code = N'Accepted'              THEN 1 ELSE 0 END)  AS LegacyAcceptedCount,
        -- Ageing of what is still open, measured from identification
        -- (sec.6.2) rather than triage -- see 205's note on identified_dt.
        AVG(CASE WHEN is_open = 1 THEN age_days END)                             AS AvgOpenAgeDays,
        MAX(CASE WHEN is_open = 1 THEN age_days END)                             AS MaxOpenAgeDays
      FROM cand;

    -- ---- 1. Candidates by source (sec.23) -------------------------------
    ;WITH cand_src AS (
        SELECT c.source_type_code,
               ISNULL(s.source_name, c.source_type_code) AS source_name,
               c.status_code,
               CASE WHEN o.status_code IS NULL THEN 0 ELSE 1 END AS is_open
          FROM grac_practice.risk_candidate c
     LEFT JOIN grac_practice.risk_source_master s ON s.source_type_code = c.source_type_code
     LEFT JOIN @open o ON o.status_code = c.status_code
         WHERE c.organization_id = @organization_id
    )
    SELECT
        source_type_code   AS SourceTypeCode,
        MAX(source_name)   AS SourceName,
        COUNT(*)           AS TotalCount,
        SUM(is_open)       AS OpenCount,
        SUM(CASE WHEN status_code = N'Registered' THEN 1 ELSE 0 END) AS RegisteredCount,
        SUM(CASE WHEN status_code IN (N'Rejected', N'ClosedAsDuplicate', N'Withdrawn')
                 THEN 1 ELSE 0 END) AS ClosedCount
      FROM cand_src
     GROUP BY source_type_code
     ORDER BY COUNT(*) DESC;

    -- ---- 2. Register summary (sec.23) -----------------------------------
    -- "High/Critical risks" (sec.23). Resolved through the org's OWN matrix
    -- rather than string-matching 'High'/'Critical', so a framework using
    -- colour bands or 1-4 still gets a meaningful number. The threshold
    -- is the midpoint of this organisation's own rating scores.
    --
    -- Computed into a variable rather than written inline, for the same
    -- Msg 130 reason as the openness test above: a subquery may not sit
    -- inside SUM(). An organisation with no matrix yet leaves this NULL,
    -- and the comparison below then yields 0 rather than failing.
    DECLARE @elevated_threshold INT =
        (SELECT (MIN(rating_score) + MAX(rating_score)) / 2
           FROM grac_practice.risk_matrix_cell
          WHERE organization_id = @organization_id);

    SELECT
        COUNT(*)                                                              AS TotalRisks,
        SUM(CASE WHEN r.status_code = N'Active'         THEN 1 ELSE 0 END)     AS ActiveCount,
        SUM(CASE WHEN r.status_code = N'UnderTreatment' THEN 1 ELSE 0 END)     AS UnderTreatmentCount,
        SUM(CASE WHEN r.status_code = N'Accepted'       THEN 1 ELSE 0 END)     AS AcceptedCount,
        SUM(CASE WHEN r.status_code = N'Monitoring'     THEN 1 ELSE 0 END)     AS MonitoringCount,
        SUM(CASE WHEN r.status_code = N'Closed'         THEN 1 ELSE 0 END)     AS ClosedCount,
        SUM(CASE WHEN r.status_code = N'Retired'        THEN 1 ELSE 0 END)     AS RetiredCount,
        SUM(CASE WHEN @elevated_threshold IS NOT NULL
                       AND r.inherent_rating_score >= @elevated_threshold
                 THEN 1 ELSE 0 END)                                            AS ElevatedRatingCount,
        SUM(CASE WHEN r.source_type_code = N'Custom' THEN 1 ELSE 0 END)        AS CustomRiskCount,
        SUM(CASE WHEN r.risk_owner_employee_id IS NULL THEN 1 ELSE 0 END)      AS UnownedCount,
        AVG(CAST(r.inherent_rating_score AS FLOAT))                            AS AvgInherentScore
      FROM grac_practice.risk_register r
     WHERE r.organization_id = @organization_id;

    -- ---- 3. Risks by category (sec.23) ----------------------------------
    SELECT
        ISNULL(r.risk_category_code, N'(uncategorised)') AS CategoryCode,
        ISNULL(r.risk_category_name, N'(uncategorised)') AS CategoryName,
        COUNT(*)                                          AS TotalCount,
        SUM(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0 ELSE 1 END) AS OpenCount,
        AVG(CAST(r.inherent_rating_score AS FLOAT))       AS AvgInherentScore
      FROM grac_practice.risk_register r
     WHERE r.organization_id = @organization_id
     GROUP BY r.risk_category_code, r.risk_category_name
     ORDER BY COUNT(*) DESC;

    -- ---- 4. Risks by source (sec.23) ------------------------------------
    SELECT
        r.source_type_code AS SourceTypeCode,
        MAX(ISNULL(s.source_name, r.source_type_code)) AS SourceName,
        COUNT(*)           AS TotalCount,
        SUM(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0 ELSE 1 END) AS OpenCount
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.risk_source_master s ON s.source_type_code = r.source_type_code
     WHERE r.organization_id = @organization_id
     GROUP BY r.source_type_code
     ORDER BY COUNT(*) DESC;

    -- ---- 5. Risks by rating (sec.23) ------------------------------------
    -- Ordered by the org's own score, not alphabetically, so the heat
    -- reads top-down whatever the rating words are.
    SELECT
        ISNULL(r.inherent_rating_code, N'(unrated)') AS RatingCode,
        ISNULL(r.inherent_rating_name, N'(unrated)') AS RatingName,
        MAX(r.inherent_rating_score)                  AS RatingScore,
        MAX(m.colour_hex)                             AS ColourHex,
        COUNT(*)                                      AS TotalCount,
        SUM(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0 ELSE 1 END) AS OpenCount
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.risk_matrix_cell m
        ON m.organization_id  = r.organization_id
       AND m.likelihood_value = r.likelihood_value
       AND m.impact_value     = r.impact_value
     WHERE r.organization_id = @organization_id
     GROUP BY r.inherent_rating_code, r.inherent_rating_name
     ORDER BY MAX(r.inherent_rating_score) DESC;

    -- ---- 6. Risks by business unit (sec.23) -----------------------------
    SELECT
        ISNULL(r.business_unit, N'(unassigned)') AS BusinessUnit,
        COUNT(*)                                  AS TotalCount,
        SUM(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0 ELSE 1 END) AS OpenCount,
        AVG(CAST(r.inherent_rating_score AS FLOAT)) AS AvgInherentScore
      FROM grac_practice.risk_register r
     WHERE r.organization_id = @organization_id
     GROUP BY r.business_unit
     ORDER BY COUNT(*) DESC;

    -- ---- 7. Risks by owner (sec.23) -------------------------------------
    SELECT
        r.risk_owner_employee_id                  AS OwnerEmployeeId,
        ISNULL(e.employee_name, N'(unassigned)')  AS OwnerName,
        COUNT(*)                                  AS TotalCount,
        SUM(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0 ELSE 1 END) AS OpenCount,
        AVG(CAST(r.inherent_rating_score AS FLOAT)) AS AvgInherentScore
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.risk_owner_employee_id
     WHERE r.organization_id = @organization_id
     GROUP BY r.risk_owner_employee_id, e.employee_name
     ORDER BY COUNT(*) DESC;

    -- ---- 8. Candidate ageing bands (sec.23 "Candidate ageing") ----------
    -- Only OPEN candidates age. A rejected candidate from last March is
    -- not "180 days old and getting older" -- it is finished, and putting
    -- it in an ageing chart makes the backlog look permanently terrible.
    ;WITH aged AS (
        SELECT c.risk_candidate_id,
               DATEDIFF(DAY, COALESCE(c.identified_dt, c.requested_dt), SYSUTCDATETIME()) AS age_days
          FROM grac_practice.risk_candidate c
         WHERE c.organization_id = @organization_id
           AND c.status_code IN (SELECT status_code FROM @open)
    )
    -- 413: the band's own day range is returned too, so a click on the
    -- band filters the Candidates list by exactly these days.
    SELECT b.BandCode, b.BandName, b.SortOrder,
           COUNT(a.risk_candidate_id) AS CandidateCount,
           b.LowDays  AS MinAgeDays,
           b.HighDays AS MaxAgeDays
      FROM (VALUES
              (N'0_7',    N'0-7 days',    1, 0,   7),
              (N'8_30',   N'8-30 days',   2, 8,   30),
              (N'31_90',  N'31-90 days',  3, 31,  90),
              (N'91_180', N'91-180 days', 4, 91,  180),
              (N'180_',   N'Over 180 days', 5, 181, 100000)
           ) AS b(BandCode, BandName, SortOrder, LowDays, HighDays)
 LEFT JOIN aged a ON a.age_days BETWEEN b.LowDays AND b.HighDays
     GROUP BY b.BandCode, b.BandName, b.SortOrder, b.LowDays, b.HighDays
     ORDER BY b.SortOrder;

    -- ---- 9. Risk trend (sec.23) -----------------------------------------
    -- Registrations and closures per month. Both, because a rising
    -- registration count alone says nothing -- a register that gains 10
    -- and closes 12 is improving, and a trend line that hides the second
    -- number invites the wrong conclusion.
    ;WITH months AS (
        SELECT DATEFROMPARTS(YEAR(SYSUTCDATETIME()), MONTH(SYSUTCDATETIME()), 1) AS month_start, 0 AS n
        UNION ALL
        SELECT DATEADD(MONTH, -1, month_start), n + 1 FROM months WHERE n < @trend_months - 1
    )
    SELECT
        m.month_start AS MonthStart,
        (SELECT COUNT(*) FROM grac_practice.risk_register r
          WHERE r.organization_id = @organization_id
            AND r.registered_dt >= m.month_start
            AND r.registered_dt <  DATEADD(MONTH, 1, m.month_start))            AS RegisteredCount,
        (SELECT COUNT(*) FROM grac_practice.risk_register r
          WHERE r.organization_id = @organization_id
            AND r.closed_dt IS NOT NULL
            AND r.closed_dt >= m.month_start
            AND r.closed_dt <  DATEADD(MONTH, 1, m.month_start))                AS ClosedCount,
        (SELECT COUNT(*) FROM grac_practice.risk_candidate c
          WHERE c.organization_id = @organization_id
            AND COALESCE(c.identified_dt, c.requested_dt) >= m.month_start
            AND COALESCE(c.identified_dt, c.requested_dt) <  DATEADD(MONTH, 1, m.month_start))
                                                                                AS CandidatesRaisedCount
      FROM months m
     ORDER BY m.month_start
     OPTION (MAXRECURSION 100);

    -- ---- 10. Overdue risk actions (sec.23) ------------------------------
    -- Read from Task Centre's own view -- see the header note on why this
    -- does not recompute overdue-ness. Degrades to an empty set when
    -- Task Centre is not installed, so the dashboard still paints.
    IF OBJECT_ID('grac_practice.vw_pm_practice_task', 'V') IS NOT NULL
        EXEC sp_executesql N'
            SELECT v.task_id             AS TaskId,
                   v.task_number         AS TaskNumber,
                   v.subject_title       AS TaskTitle,
                   v.source_record_id    AS RiskCandidateId,
                   v.assigned_to_employee_name AS OwnerName,
                   v.priority            AS Priority,
                   v.sla_due_at          AS DueAt,
                   v.sla_status_code     AS SlaStatusCode,
                   v.current_status_name AS TaskStatusName
              FROM grac_practice.vw_pm_practice_task v
             WHERE v.organization_id  = @org
               AND v.source_type_code = N''Risk''
               AND v.completed_dt IS NULL
               AND v.sla_status_code IN (N''Breached'', N''DueToday'', N''DueSoon'')
             ORDER BY v.sla_due_at;',
            N'@org BIGINT', @org = @organization_id;
    ELSE
        SELECT CAST(NULL AS BIGINT)       AS TaskId,
               CAST(NULL AS NVARCHAR(60)) AS TaskNumber,
               CAST(NULL AS NVARCHAR(250))AS TaskTitle,
               CAST(NULL AS BIGINT)       AS RiskCandidateId,
               CAST(NULL AS NVARCHAR(240))AS OwnerName,
               CAST(NULL AS NVARCHAR(30)) AS Priority,
               CAST(NULL AS DATETIME2)    AS DueAt,
               CAST(NULL AS NVARCHAR(30)) AS SlaStatusCode,
               CAST(NULL AS NVARCHAR(120))AS TaskStatusName
         WHERE 1 = 0;

    -- =================================================================
    -- 413: Risk Management dashboard. Six result sets APPENDED after
    -- set 10, as 214's header requires -- every reader of sets 0-10 is
    -- untouched. "Open" for a registered risk is the rule sets 3-7
    -- already use: status_code NOT IN ('Closed','Retired').
    -- =================================================================

    -- ---- 11. Matrix axes -------------------------------------------
    -- The organisation's OWN scale: every likelihood and impact value
    -- its risk_matrix_cell grid uses, named from the scoring masters
    -- (204). Axis 'L' = likelihood, 'I' = impact.
    SELECT ax.Axis, ax.LevelValue,
           MAX(ax.LevelCode) AS LevelCode,
           MAX(ax.LevelName) AS LevelName
      FROM (
            SELECT N'L' AS Axis, m.likelihood_value AS LevelValue,
                   lm.likelihood_code AS LevelCode,
                   ISNULL(lm.likelihood_name, CAST(m.likelihood_value AS NVARCHAR(20))) AS LevelName
              FROM grac_practice.risk_matrix_cell m
         LEFT JOIN grac_practice.risk_likelihood_master lm
                ON lm.organization_id = m.organization_id
               AND lm.level_value     = m.likelihood_value
             WHERE m.organization_id = @organization_id
            UNION ALL
            SELECT N'I', m.impact_value,
                   im.impact_code,
                   ISNULL(im.impact_name, CAST(m.impact_value AS NVARCHAR(20)))
              FROM grac_practice.risk_matrix_cell m
         LEFT JOIN grac_practice.risk_impact_master im
                ON im.organization_id = m.organization_id
               AND im.level_value     = m.impact_value
             WHERE m.organization_id = @organization_id
           ) ax
     GROUP BY ax.Axis, ax.LevelValue
     ORDER BY ax.Axis, ax.LevelValue;

    -- ---- 12. Inherent heatmap --------------------------------------
    -- One row per matrix cell. The cell's rating is the matrix's own
    -- (the scale sp_risk_rating_resolve reads); RiskCount is the open
    -- risks whose INHERENT likelihood x impact land on it.
    SELECT m.likelihood_value AS LikelihoodValue,
           m.impact_value     AS ImpactValue,
           m.rating_code      AS RatingCode,
           m.rating_name      AS RatingName,
           m.rating_score     AS RatingScore,
           m.colour_hex       AS ColourHex,
           (SELECT COUNT(*) FROM grac_practice.risk_register r
             WHERE r.organization_id  = @organization_id
               AND r.status_code NOT IN (N'Closed', N'Retired')
               AND r.likelihood_value = m.likelihood_value
               AND r.impact_value     = m.impact_value) AS RiskCount
      FROM grac_practice.risk_matrix_cell m
     WHERE m.organization_id = @organization_id
     ORDER BY m.likelihood_value, m.impact_value;

    -- ---- 13. Residual heatmap --------------------------------------
    -- Same matrix, the RESIDUAL likelihood x impact (258). A risk with
    -- no residual assessment yet has NULL residual values and is not
    -- plotted; set 14 counts those separately.
    SELECT m.likelihood_value AS LikelihoodValue,
           m.impact_value     AS ImpactValue,
           m.rating_code      AS RatingCode,
           m.rating_name      AS RatingName,
           m.rating_score     AS RatingScore,
           m.colour_hex       AS ColourHex,
           (SELECT COUNT(*) FROM grac_practice.risk_register r
             WHERE r.organization_id           = @organization_id
               AND r.status_code NOT IN (N'Closed', N'Retired')
               AND r.residual_likelihood_value = m.likelihood_value
               AND r.residual_impact_value     = m.impact_value) AS RiskCount
      FROM grac_practice.risk_matrix_cell m
     WHERE m.organization_id = @organization_id
     ORDER BY m.likelihood_value, m.impact_value;

    -- ---- 14. Heatmap coverage --------------------------------------
    -- How many open risks each map shows, and how many it cannot: a
    -- heatmap that silently drops unrated risks overstates coverage.
    SELECT COUNT(*) AS OpenRisks,
           SUM(CASE WHEN r.likelihood_value IS NOT NULL AND r.impact_value IS NOT NULL
                    THEN 1 ELSE 0 END) AS InherentRated,
           SUM(CASE WHEN r.residual_likelihood_value IS NOT NULL AND r.residual_impact_value IS NOT NULL
                    THEN 1 ELSE 0 END) AS ResidualRated,
           SUM(CASE WHEN ISNULL(r.residual_pending, 1) = 1 THEN 1 ELSE 0 END) AS ResidualPending
      FROM grac_practice.risk_register r
     WHERE r.organization_id = @organization_id
       AND r.status_code NOT IN (N'Closed', N'Retired');

    -- ---- 15. Review ageing -----------------------------------------
    -- Pending and overdue reviews only, on the rule
    -- vw_pm_risk_workflow_stage.is_review_due and sp_risk_review_due_list
    -- use: open risk, next_review_date set; due when it is on or before
    -- today. DaysOverdue = today - next_review_date (negative = still
    -- upcoming). The overdue bands are 214 set 8's bands; the two
    -- upcoming bands match the Review Risk horizon (7 / 30 days).
    DECLARE @today413 DATE = CAST(SYSUTCDATETIME() AS DATE);
    ;WITH rv AS (
        SELECT DATEDIFF(DAY, r.next_review_date, @today413) AS days_overdue
          FROM grac_practice.risk_register r
         WHERE r.organization_id = @organization_id
           AND r.next_review_date IS NOT NULL
           AND r.status_code NOT IN (N'Closed', N'Retired')
    )
    SELECT b.BandCode, b.BandName, b.BandGroup, b.SortOrder,
           b.MinDaysOverdue, b.MaxDaysOverdue,
           COUNT(rv.days_overdue) AS RiskCount
      FROM (VALUES
              (N'due_8_30', N'Due in 8-30 days', N'Pending', 1, -30,  -8),
              (N'due_1_7',  N'Due in 1-7 days',  N'Pending', 2, -7,   -1),
              (N'0_7',      N'0-7 days',         N'Overdue', 3,  0,    7),
              (N'8_30',     N'8-30 days',        N'Overdue', 4,  8,   30),
              (N'31_90',    N'31-90 days',       N'Overdue', 5, 31,   90),
              (N'91_180',   N'91-180 days',      N'Overdue', 6, 91,  180),
              (N'180_',     N'Over 180 days',    N'Overdue', 7, 181, 100000)
           ) AS b(BandCode, BandName, BandGroup, SortOrder, MinDaysOverdue, MaxDaysOverdue)
 LEFT JOIN rv ON rv.days_overdue BETWEEN b.MinDaysOverdue AND b.MaxDaysOverdue
     GROUP BY b.BandCode, b.BandName, b.BandGroup, b.SortOrder, b.MinDaysOverdue, b.MaxDaysOverdue
     ORDER BY b.SortOrder;

    -- ---- 16. Top 5 risks by rating ---------------------------------
    -- Open risks, highest INHERENT score first (the score every "by
    -- rating" set above already ranks by), then residual score, then
    -- the older registration, then the id -- so two equal risks never
    -- swap places between refreshes.
    SELECT TOP (5)
           r.risk_register_id       AS RiskRegisterId,
           r.risk_number            AS RiskNumber,
           r.risk_title             AS RiskTitle,
           r.risk_owner_employee_id AS RiskOwnerEmployeeId,
           ow.employee_name         AS RiskOwnerName,
           r.inherent_rating_code   AS InherentRatingCode,
           r.inherent_rating_name   AS InherentRatingName,
           r.inherent_rating_score  AS InherentRatingScore,
           r.residual_rating_code   AS ResidualRatingCode,
           r.residual_rating_name   AS ResidualRatingName,
           r.residual_rating_score  AS ResidualRatingScore,
           r.status_code            AS StatusCode
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
     WHERE r.organization_id = @organization_id
       AND r.status_code NOT IN (N'Closed', N'Retired')
     ORDER BY CASE WHEN r.inherent_rating_score IS NULL THEN 1 ELSE 0 END,
              r.inherent_rating_score DESC,
              CASE WHEN r.residual_rating_score IS NULL THEN 1 ELSE 0 END,
              r.residual_rating_score DESC,
              r.registered_dt ASC,
              r.risk_register_id ASC;
END;
GO
PRINT '505 rollback: sp_risk_dashboard_counts restored to the 413 body.';
GO
