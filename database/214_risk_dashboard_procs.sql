-- =====================================================================
-- 214 Risk Centre — dashboard and reporting  (BRD §23)  Phase B
--
-- WHAT §23 ASKS FOR
-- -----------------
-- Two separate blocks, and the BRD is emphatic that they ARE separate:
--
--   Risk Candidates          Risk Register
--   ----------------         -------------
--   Total candidates         Total active risks
--   By source                By category
--   Under analysis           By source
--   Awaiting clarification   By risk rating
--   Awaiting approval        By business unit
--   Rejected                 By owner
--   Converted to risks       High/Critical risks
--   Candidate ageing         Risks under treatment
--                            Accepted risks
--                            Overdue risk actions
--                            Risk trend
--
-- "The dashboard should allow drill-down from a risk to its analysis and
-- originating source."
--
-- WHY ONE PROCEDURE WITH MANY RESULT SETS
-- ---------------------------------------
-- A dashboard that fires eleven queries paints in eleven steps and shows
-- eleven different moments of the database. One call, one connection,
-- one point in time — every tile on screen agrees with every other,
-- which for a governance dashboard is not a nicety. It is also how
-- sp_risk_scoring_options_get already behaves, so the service reads
-- both the same way.
--
-- THE ONE THING THIS PROC DOES NOT INVENT
-- ---------------------------------------
-- §23 lists "Overdue risk actions". Risk actions are Task Centre's, not
-- Risk Centre's (§22), and their overdue state is already derived by
-- vw_pm_practice_task.sla_status_code. This proc READS that view rather
-- than recomputing overdue-ness from due dates — two definitions of
-- "overdue" in one product is how dashboards start disagreeing with the
-- screens they link to. If Task Centre is not installed, the tile
-- returns zero rather than failing the whole dashboard.
--
-- DRILL-DOWN
-- ----------
-- Every grouped row carries the filter value the grids already accept
-- (source_type_code, category_code, rating_code, status_code,
-- owner_employee_id), so a click becomes a query-string change rather
-- than a second API.
--
-- CONTENTS
--   sp_risk_dashboard_counts   11 result sets, fixed order
--   sp_risk_candidate_ageing   the ageing detail behind result set 8
--
-- NOTHING IN 204-207 OR 212-213 IS MODIFIED BY THIS MIGRATION.
--
-- ERROR CODE RANGE: 56350-56379
-- Rollback: database/214_risk_dashboard_procs_rollback.sql
-- Depends:  205, 206, 212
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN PRINT 'ABORT (214): risk_register missing — run 205 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_candidate','U') IS NULL
BEGIN PRINT 'ABORT (214): risk_candidate missing — run 169 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('214_risk_dashboard_procs: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_risk_dashboard_counts   (BRD §23)
--
-- RESULT SETS, in this fixed order — the API reads them positionally:
--
--    0  CandidateSummary        headline counts
--    1  CandidatesBySource
--    2  RegisterSummary         headline counts
--    3  RisksByCategory
--    4  RisksBySource
--    5  RisksByRating
--    6  RisksByBusinessUnit
--    7  RisksByOwner
--    8  CandidateAgeingBands
--    9  RiskTrend               registrations per month
--   10  OverdueRiskActions      from Task Centre, or empty
--
-- Adding a set at the END is safe. Inserting one in the middle silently
-- re-points every reader after it.
-- =====================================================================
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
    -- so every tile below counts "open" the same way — the Candidates
    -- grid, the approval queue and this dashboard must not disagree
    -- about what is outstanding.
    DECLARE @open TABLE (status_code NVARCHAR(30) PRIMARY KEY);
    INSERT INTO @open(status_code)
    VALUES (N'Pending'), (N'UnderAnalysis'), (N'ClarificationRequired'), (N'AnalysisCompleted');

    -- WHY THE "OPEN" TEST IS A JOIN AND NOT AN IN (SELECT ...)
    -- -------------------------------------------------------
    -- SQL Server rejects a subquery inside an aggregate (Msg 130), so
    -- SUM(CASE WHEN status IN (SELECT ... FROM @open) ...) will not
    -- compile. The obvious workaround — inlining the four literals at
    -- every call site — would defeat the point of declaring the set
    -- once, and is exactly how the dashboard and the grids drift apart.
    --
    -- So the openness test is resolved ONCE, in a LEFT JOIN, and every
    -- aggregate then works on a plain 0/1 column. One definition, and it
    -- compiles.
    --
    -- The @open set is also used in WHERE clauses further down (result
    -- sets 0's approval subquery and 8's ageing CTE). That form is legal
    -- — the restriction is aggregate-of-subquery, not subquery-anywhere.

    -- ---- 0. Candidate summary (§23) ----------------------------------
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
        -- (§6.2) rather than triage — see 205's note on identified_dt.
        AVG(CASE WHEN is_open = 1 THEN age_days END)                             AS AvgOpenAgeDays,
        MAX(CASE WHEN is_open = 1 THEN age_days END)                             AS MaxOpenAgeDays
      FROM cand;

    -- ---- 1. Candidates by source (§23) -------------------------------
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

    -- ---- 2. Register summary (§23) -----------------------------------
    -- "High/Critical risks" (§23). Resolved through the org's OWN matrix
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

    -- ---- 3. Risks by category (§23) ----------------------------------
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

    -- ---- 4. Risks by source (§23) ------------------------------------
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

    -- ---- 5. Risks by rating (§23) ------------------------------------
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

    -- ---- 6. Risks by business unit (§23) -----------------------------
    SELECT
        ISNULL(r.business_unit, N'(unassigned)') AS BusinessUnit,
        COUNT(*)                                  AS TotalCount,
        SUM(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0 ELSE 1 END) AS OpenCount,
        AVG(CAST(r.inherent_rating_score AS FLOAT)) AS AvgInherentScore
      FROM grac_practice.risk_register r
     WHERE r.organization_id = @organization_id
     GROUP BY r.business_unit
     ORDER BY COUNT(*) DESC;

    -- ---- 7. Risks by owner (§23) -------------------------------------
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

    -- ---- 8. Candidate ageing bands (§23 "Candidate ageing") ----------
    -- Only OPEN candidates age. A rejected candidate from last March is
    -- not "180 days old and getting older" — it is finished, and putting
    -- it in an ageing chart makes the backlog look permanently terrible.
    ;WITH aged AS (
        SELECT c.risk_candidate_id,
               DATEDIFF(DAY, COALESCE(c.identified_dt, c.requested_dt), SYSUTCDATETIME()) AS age_days
          FROM grac_practice.risk_candidate c
         WHERE c.organization_id = @organization_id
           AND c.status_code IN (SELECT status_code FROM @open)
    )
    SELECT b.BandCode, b.BandName, b.SortOrder,
           COUNT(a.risk_candidate_id) AS CandidateCount
      FROM (VALUES
              (N'0_7',    N'0-7 days',    1, 0,   7),
              (N'8_30',   N'8-30 days',   2, 8,   30),
              (N'31_90',  N'31-90 days',  3, 31,  90),
              (N'91_180', N'91-180 days', 4, 91,  180),
              (N'180_',   N'Over 180 days', 5, 181, 100000)
           ) AS b(BandCode, BandName, SortOrder, LowDays, HighDays)
 LEFT JOIN aged a ON a.age_days BETWEEN b.LowDays AND b.HighDays
     GROUP BY b.BandCode, b.BandName, b.SortOrder
     ORDER BY b.SortOrder;

    -- ---- 9. Risk trend (§23) -----------------------------------------
    -- Registrations and closures per month. Both, because a rising
    -- registration count alone says nothing — a register that gains 10
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

    -- ---- 10. Overdue risk actions (§23) ------------------------------
    -- Read from Task Centre's own view — see the header note on why this
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
END;
GO

-- =====================================================================
-- sp_risk_candidate_ageing   (the drill-down behind result set 8)
--
-- "Which candidates are actually old?" — the question a manager asks
-- immediately after seeing the ageing chart. Returning it as its own
-- proc keeps the dashboard call cheap.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_ageing
    @organization_id BIGINT,
    @min_age_days    INT = 0,
    @page_number     INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 56360, 'sp_risk_candidate_ageing: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        c.risk_candidate_id      AS RiskCandidateId,
        c.candidate_number       AS CandidateNumber,
        c.candidate_title        AS CandidateTitle,
        c.source_type_code       AS SourceTypeCode,
        c.source_reference       AS SourceReference,
        c.status_code            AS StatusCode,
        c.assigned_analyst_employee_id AS AssignedAnalystEmployeeId,
        an.employee_name         AS AssignedAnalystName,
        COALESCE(c.identified_dt, c.requested_dt) AS IdentifiedOn,
        DATEDIFF(DAY, COALESCE(c.identified_dt, c.requested_dt), SYSUTCDATETIME()) AS AgeDays,
        a.inherent_rating_code   AS InherentRatingCode,
        a.approval_status_code   AS ApprovalStatusCode,
        COUNT(*) OVER ()         AS TotalRows
      FROM grac_practice.risk_candidate c
 LEFT JOIN grac_practice.organization_employee an ON an.employee_id = c.assigned_analyst_employee_id
 LEFT JOIN grac_practice.risk_analysis a
        ON a.risk_candidate_id = c.risk_candidate_id AND a.is_current = 1
     WHERE c.organization_id = @organization_id
       AND c.status_code IN (N'Pending', N'UnderAnalysis',
                             N'ClarificationRequired', N'AnalysisCompleted')
       AND DATEDIFF(DAY, COALESCE(c.identified_dt, c.requested_dt), SYSUTCDATETIME())
             >= ISNULL(@min_age_days, 0)
     ORDER BY DATEDIFF(DAY, COALESCE(c.identified_dt, c.requested_dt), SYSUTCDATETIME()) DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '214 procedures present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_dashboard_counts','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_candidate_ageing','P')  IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '214 Risk dashboard procedures installed. Next: 215_risk_treatment_task_optin.sql';
PRINT 'NOTE: sp_risk_dashboard_counts returns 11 result sets in a FIXED order.';
PRINT '      Append new ones at the end; inserting in the middle re-points every reader.';
GO

SET NOEXEC OFF;
GO
