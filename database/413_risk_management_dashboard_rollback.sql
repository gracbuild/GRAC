-- =====================================================================
-- 413 Risk Management dashboard -- ROLLBACK
--
-- Re-issues the four procedures exactly as 413 found them (214, 376,
-- 206 and 264 bodies; comment characters written as ASCII) and puts the
-- 'risk-centre' parent back to url '#'. Read-only procedures and one
-- menu url: no data is touched. Also revert 274_menu_master_seed.sql's
-- 'risk-centre' row to N'#' so a snapshot re-run matches.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_risk_dashboard_counts','P') IS NULL
BEGIN
    RAISERROR('413-rollback: sp_risk_dashboard_counts missing -- nothing to roll back.', 16, 1);
    SET NOEXEC ON;
END
GO

-- sp_risk_dashboard_counts (as before 413)
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
END;
GO

-- sp_risk_register_list (as before 413)
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_register_list
    @organization_id  BIGINT,
    @status_code      NVARCHAR(30) = NULL,
    @source_type_code NVARCHAR(40) = NULL,
    @category_code    NVARCHAR(60) = NULL,
    @rating_code      NVARCHAR(30) = NULL,
    @owner_employee_id BIGINT      = NULL,
    @search           NVARCHAR(200) = NULL,
    @page_number      INT = 1,
    @page_size        INT = 25,
    @analysis_pending BIT = NULL,
    @residual_rating_code NVARCHAR(30) = NULL,
    @residual_pending     BIT          = NULL,
    -- NEW in 264. All default to NULL = "no opinion".
    @treatment_option_code NVARCHAR(30)  = NULL,
    @workflow_stage_code   NVARCHAR(30)  = NULL,
    @review_due            BIT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 56150, 'sp_risk_register_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        r.risk_register_id      AS RiskRegisterId,
        r.risk_number           AS RiskNumber,
        r.organization_id       AS OrganizationId,
        r.risk_title            AS RiskTitle,
        r.risk_statement        AS RiskStatement,
        r.risk_category_code    AS RiskCategoryCode,
        r.risk_category_name    AS RiskCategoryName,
        r.source_type_code      AS SourceTypeCode,
        r.source_record_id      AS SourceRecordId,
        r.source_reference      AS SourceReference,
        r.source_centre_code    AS SourceCentreCode,
        r.risk_candidate_id     AS RiskCandidateId,
        r.risk_analysis_id      AS RiskAnalysisId,
        r.risk_owner_employee_id AS RiskOwnerEmployeeId,
        ow.employee_name        AS RiskOwnerName,
        r.business_unit         AS BusinessUnit,
        r.likelihood_name       AS LikelihoodName,
        r.impact_name           AS ImpactName,
        r.inherent_rating_code  AS InherentRatingCode,
        r.inherent_rating_name  AS InherentRatingName,
        r.inherent_rating_score AS InherentRatingScore,
        r.status_code           AS StatusCode,
        r.registered_dt         AS RegisteredOn,
        rb.employee_name        AS RegisteredByName,
        -- ---- 216 ----------------------------------------------------
        r.analysis_pending      AS AnalysisPending,
        r.threat_name           AS ThreatName,
        r.vulnerability_name    AS VulnerabilityName,
        r.business_function_name AS BusinessFunctionName,
        -- ---- 258 ----------------------------------------------------
        r.residual_likelihood_name AS ResidualLikelihoodName,
        r.residual_impact_name     AS ResidualImpactName,
        r.residual_rating_code     AS ResidualRatingCode,
        r.residual_rating_name     AS ResidualRatingName,
        r.residual_rating_score    AS ResidualRatingScore,
        r.residual_assessed_dt     AS ResidualAssessedOn,
        r.residual_pending         AS ResidualPending,
        -- ---- 261 / 263 / 264 ----------------------------------------
        r.treatment_option_code    AS TreatmentOptionCode,
        r.treatment_option_name    AS TreatmentOptionName,
        r.treatment_task_id        AS TreatmentTaskId,
        r.accepted_dt              AS AcceptedOn,
        COALESCE(ab.employee_name, r.accepted_by_name) AS AcceptedByName,
        r.next_review_date         AS NextReviewDate,
        r.last_reviewed_dt         AS LastReviewedOn,
        r.review_count             AS ReviewCount,
        st.workflow_stage_code     AS WorkflowStageCode,
        st.open_treatment_task_count AS OpenTreatmentTaskCount,
        st.treatment_task_count      AS TreatmentTaskCount,
        st.is_review_due             AS IsReviewDue,
        -- Counts for the mapping badges. Correlated subqueries in the
        -- SELECT list, not aggregates over a join -- a join would
        -- multiply the register rows and every score in the row would
        -- have to be wrapped in an aggregate to survive it.
        (SELECT COUNT(*) FROM grac_practice.risk_practice_map pm
          WHERE pm.risk_register_id = r.risk_register_id) AS MappedPracticeCount,
        (SELECT COUNT(*) FROM grac_practice.risk_dependency_map am
          WHERE am.risk_register_id = r.risk_register_id) AS MappedDependencyCount,
        -- 376: every category currently mapped to this risk, comma
        -- separated in the master's own display order -- the same order
        -- the analyst ticked them in on the Analysis form. NULL when the
        -- risk has no rows in risk_register_risk_category yet (a risk
        -- registered before 375's backfill matched nothing, or one whose
        -- code has since been retired) -- the caller falls back to
        -- RiskCategoryName, the legacy scalar, in that case.
        (SELECT STRING_AGG(cm.category_name, N', ') WITHIN GROUP (ORDER BY cm.display_order, cm.category_name)
           FROM grac_practice.risk_register_risk_category rc
           JOIN grac_practice.risk_category_master cm ON cm.risk_category_id = rc.risk_category_id
          WHERE rc.risk_register_id = r.risk_register_id) AS RiskCategoryNames,
        COUNT(*) OVER ()        AS TotalRows
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
 LEFT JOIN grac_practice.organization_employee rb ON rb.employee_id = r.registered_by_employee_id
 LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = r.accepted_by_employee_id
 LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
     WHERE r.organization_id = @organization_id
       AND (@status_code      IS NULL OR r.status_code         = @status_code)
       AND (@source_type_code IS NULL OR r.source_type_code    = @source_type_code)
       AND (@category_code    IS NULL OR r.risk_category_code  = @category_code)
       AND (@rating_code      IS NULL OR r.inherent_rating_code= @rating_code)
       AND (@owner_employee_id IS NULL OR r.risk_owner_employee_id = @owner_employee_id)
       AND (@analysis_pending IS NULL OR r.analysis_pending    = @analysis_pending)
       AND (@residual_rating_code IS NULL OR r.residual_rating_code = @residual_rating_code)
       AND (@residual_pending     IS NULL OR r.residual_pending     = @residual_pending)
       AND (@treatment_option_code IS NULL OR r.treatment_option_code = @treatment_option_code)
       AND (@workflow_stage_code   IS NULL OR st.workflow_stage_code  = @workflow_stage_code)
       AND (@review_due            IS NULL OR st.is_review_due        = @review_due)
       AND (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR r.risk_title     LIKE N'%' + @search + N'%'
            OR r.risk_statement LIKE N'%' + @search + N'%'
            OR r.risk_number    LIKE N'%' + @search + N'%')
     ORDER BY r.registered_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- sp_risk_candidate_list (as before 413)
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_list
    @organization_id  BIGINT,
    @status_code      NVARCHAR(30) = NULL,
    @page_number      INT = 1,
    @page_size        INT = 25,
    @source_type_code NVARCHAR(40) = NULL   -- NEW, optional (sec.23 "by source")
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 55410, 'sp_risk_candidate_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        r.risk_candidate_id         AS RiskCandidateId,
        r.organization_id           AS OrganizationId,
        r.custom_gap_id             AS CustomGapId,
        g.title                     AS GapTitle,
        r.candidate_title           AS CandidateTitle,
        r.severity_code             AS SeverityCode,
        r.status_code               AS StatusCode,
        r.requested_dt              AS RequestedOn,
        rq.employee_name            AS RequestedByName,
        r.accepted_dt               AS AcceptedOn,
        ac.employee_name            AS AcceptedByName,
        r.rejected_dt               AS RejectedOn,
        rj.employee_name            AS RejectedByName,
        r.formal_risk_ref           AS FormalRiskRef,
        (SELECT COUNT(*) FROM grac_practice.risk_candidate_attachment a
          WHERE a.risk_candidate_id = r.risk_candidate_id) AS AttachmentCount,
        -- ---- NEW in 206 ---------------------------------------------
        r.candidate_number          AS CandidateNumber,
        r.source_type_code          AS SourceTypeCode,
        sm.source_name              AS SourceName,
        r.source_record_id          AS SourceRecordId,
        r.source_reference          AS SourceReference,
        r.source_centre_code        AS SourceCentreCode,
        r.identified_dt             AS IdentifiedOn,
        r.assigned_analyst_employee_id AS AssignedAnalystEmployeeId,
        an.employee_name            AS AssignedAnalystName,
        r.registered_risk_id        AS RegisteredRiskId,
        rr.risk_number              AS RegisteredRiskNumber,
        r.duplicate_of_risk_id      AS DuplicateOfRiskId,
        cur.risk_analysis_id        AS CurrentAnalysisId,
        cur.analysis_version        AS CurrentAnalysisVersion,
        cur.inherent_rating_code    AS InherentRatingCode,
        COUNT(*) OVER ()            AS TotalRows
      FROM grac_practice.risk_candidate r
 LEFT JOIN grac_practice.custom_gap g            ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.risk_source_master sm   ON sm.source_type_code = r.source_type_code
 LEFT JOIN grac_practice.risk_register rr        ON rr.risk_register_id = r.registered_risk_id
 LEFT JOIN grac_practice.risk_analysis cur       ON cur.risk_candidate_id = r.risk_candidate_id
                                                AND cur.is_current = 1
 LEFT JOIN grac_practice.organization_employee rq ON rq.employee_id = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee ac ON ac.employee_id = r.accepted_by_employee_id
 LEFT JOIN grac_practice.organization_employee rj ON rj.employee_id = r.rejected_by_employee_id
 LEFT JOIN grac_practice.organization_employee an ON an.employee_id = r.assigned_analyst_employee_id
     WHERE r.organization_id = @organization_id
       AND (@status_code IS NULL OR r.status_code = @status_code)
       AND (@source_type_code IS NULL OR r.source_type_code = @source_type_code)
     ORDER BY r.requested_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- sp_risk_review_due_list (as before 413)
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_review_due_list
    @organization_id   BIGINT,
    @owner_employee_id BIGINT        = NULL,
    @rating_code       NVARCHAR(30)  = NULL,
    @search            NVARCHAR(200) = NULL,
    @include_future_days INT         = NULL,   -- NULL = due only
    @page_number       INT = 1,
    @page_size         INT = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 56611, 'sp_risk_review_due_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    -- One "today" for the whole call. See decision 3.
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- The horizon. NULL means "due and overdue only", which is the
    -- literal requirement; a number lets the same procedure feed a
    -- "coming up in the next N days" panel without a second query whose
    -- rules could drift from these.
    DECLARE @horizon DATE =
        CASE WHEN @include_future_days IS NULL OR @include_future_days <= 0
             THEN @today ELSE DATEADD(DAY, @include_future_days, @today) END;

    SELECT r.risk_register_id       AS RiskRegisterId,
           r.risk_number            AS RiskNumber,
           r.risk_title             AS RiskTitle,
           r.risk_statement         AS RiskStatement,
           r.risk_category_name     AS RiskCategoryName,
           r.status_code            AS StatusCode,
           r.risk_owner_employee_id AS RiskOwnerEmployeeId,
           ow.employee_name         AS RiskOwnerName,
           r.business_unit          AS BusinessUnit,
           r.inherent_rating_code   AS InherentRatingCode,
           r.inherent_rating_name   AS InherentRatingName,
           r.residual_rating_code   AS ResidualRatingCode,
           r.residual_rating_name   AS ResidualRatingName,
           r.treatment_option_code  AS TreatmentOptionCode,
           r.treatment_option_name  AS TreatmentOptionName,
           r.accepted_dt            AS AcceptedOn,
           COALESCE(ab.employee_name, r.accepted_by_name) AS AcceptedByName,
           r.next_review_date       AS NextReviewDate,
           r.last_reviewed_dt       AS LastReviewedOn,
           r.review_count           AS ReviewCount,
           DATEDIFF(DAY, r.next_review_date, @today) AS DaysOverdue,
           CAST(CASE WHEN r.next_review_date <= @today THEN 1 ELSE 0 END AS BIT) AS IsDue,
           st.workflow_stage_code   AS WorkflowStageCode,
           COUNT(*) OVER ()         AS TotalRows
      FROM grac_practice.risk_register r
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
      LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = r.accepted_by_employee_id
      LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
     WHERE r.organization_id = @organization_id
       AND r.next_review_date IS NOT NULL
       AND r.next_review_date <= @horizon
       AND r.status_code NOT IN (N'Closed', N'Retired')
       AND (@owner_employee_id IS NULL OR r.risk_owner_employee_id = @owner_employee_id)
       AND (@rating_code IS NULL
            OR r.inherent_rating_code = @rating_code
            OR r.residual_rating_code = @rating_code)
       AND (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR r.risk_title     LIKE N'%' + @search + N'%'
            OR r.risk_statement LIKE N'%' + @search + N'%'
            OR r.risk_number    LIKE N'%' + @search + N'%')
     -- Most overdue first: the list is a work queue, and the oldest
     -- breach is the one that has been ignored longest.
     ORDER BY r.next_review_date ASC, r.inherent_rating_score DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

UPDATE grac_practice.menu_master
   SET menu_url   = N'#',
       updated_by = N'rollback-413',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-centre'
   AND ISNULL(menu_url, N'') <> N'#';
GO

SELECT '413-rollback register list back to 376' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.parameters
                              WHERE object_id = OBJECT_ID('grac_practice.sp_risk_register_list')
                                AND name = '@no_owner')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO

PRINT '413 rolled back.';
GO

SET NOEXEC OFF;
GO
