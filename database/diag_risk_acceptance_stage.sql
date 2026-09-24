-- =====================================================================
-- diag_risk_acceptance_stage.sql
--
-- NOT A MIGRATION. Deliberately unnumbered so it never enters the
-- migration sequence. Read-only: it writes nothing and changes nothing,
-- so it is safe to run on production.
--
-- ANSWERS ONE QUESTION
--   "I reviewed these risks -- why are they not on the Accept tab?"
--
-- The Accept tab lists workflow_stage_code = 'AcceptanceDue'. This shows
-- what stage each risk is ACTUALLY in and, in plain English, what is
-- holding it there.
--
-- HOW TO RUN
--   Set @organization_id below, then execute. Section 1 is the summary;
--   section 2 is the recently-reviewed risks, newest first -- that is
--   the one that answers the question above.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @organization_id BIGINT = NULL;   -- <<< SET THIS, or leave NULL for every organisation

-- ---------------------------------------------------------------------
-- 1. Where does everything sit?
-- ---------------------------------------------------------------------
PRINT '=== 1. Risks by workflow stage ===';

SELECT st.workflow_stage_code            AS Stage,
       COUNT(*)                          AS Risks,
       SUM(CASE WHEN r.last_reviewed_dt IS NOT NULL THEN 1 ELSE 0 END) AS EverReviewed
  FROM grac_practice.risk_register r
  JOIN grac_practice.vw_pm_risk_workflow_stage st
    ON st.risk_register_id = r.risk_register_id
 WHERE (@organization_id IS NULL OR r.organization_id = @organization_id)
 GROUP BY st.workflow_stage_code
 ORDER BY Risks DESC;

-- ---------------------------------------------------------------------
-- 2. The recently reviewed risks, and what is blocking each one
--
-- The Blocker column walks the SAME order vw_pm_risk_workflow_stage
-- uses, so it explains the stage rather than second-guessing it.
-- ---------------------------------------------------------------------
PRINT '=== 2. Recently reviewed risks -- why are they not on the Accept tab? ===';

SELECT TOP (50)
       r.risk_number                     AS RiskNumber,
       LEFT(r.risk_title, 50)            AS RiskTitle,
       st.workflow_stage_code            AS Stage,
       r.status_code                     AS Status,
       r.treatment_option_code           AS TreatmentOption,
       r.analysis_pending                AS AnalysisPending,
       r.residual_pending                AS ResidualPending,
       st.open_treatment_task_count      AS OpenTasks,
       st.treatment_task_count           AS TotalTasks,
       r.accepted_dt                     AS AcceptedOn,
       r.next_review_date                AS NextReviewDate,
       r.last_reviewed_dt                AS LastReviewedOn,
       r.review_count                    AS ReviewCount,

       -- Walks vw_pm_risk_workflow_stage's order EXACTLY, as of 299:
       -- status_code = 'Monitoring' is what routes a risk to the Accept
       -- tab. The date rule 296 used is gone, and so is the branch that
       -- used to blame it.
       CASE
         WHEN st.workflow_stage_code = N'AcceptanceDue'
              THEN N'READY -- it should be on the Accept tab right now.'
         WHEN r.status_code IN (N'Closed', N'Retired')
              THEN N'Closed or retired. Reopen it first.'
         WHEN r.next_review_date IS NOT NULL
          AND r.next_review_date <= CAST(SYSUTCDATETIME() AS DATE)
              THEN N'Its review date is today or past, so it is on the REVIEW tab. '
                 + N'ReviewDue outranks every other stage -- review it again, or push the date out.'
         WHEN ISNULL(r.analysis_pending, 1) = 1
              THEN N'Analysis is not complete. Reviewing does NOT complete it.'
         WHEN r.treatment_option_code IS NULL
              THEN N'No treatment option chosen. Choose Tolerate / Treat / Transfer / Terminate first.'

         -- THE ONE TO LOOK FOR after a review that did not land.
         WHEN r.status_code <> N'Monitoring'
              THEN N'*** STATUS IS ''' + ISNULL(r.status_code, N'(null)')
                 + N''', NOT ''Monitoring''. Since 299 the status is what puts a risk on the '
                 + N'Accept tab, and a review is supposed to set it. '
                 + CASE WHEN r.last_reviewed_dt IS NULL
                        THEN N'This risk has never been reviewed.'
                        ELSE N'It WAS reviewed (' + CONVERT(NVARCHAR(19), r.last_reviewed_dt, 120)
                           + N') but the status did not change -- so either 299 was applied '
                           + N'AFTER that review, or the review set a status explicitly '
                           + N'(picking Accepted in the bulk form does exactly that).' END

         WHEN r.treatment_option_code IN (N'Terminate', N'Treat', N'Transfer')
          AND ISNULL(st.open_treatment_task_count, 0) > 0
              THEN CONCAT(N'In treatment: ', st.open_treatment_task_count,
                          N' task(s) still open. Close them, then assess residual risk.')
         WHEN r.treatment_option_code IN (N'Terminate', N'Treat', N'Transfer')
          AND ISNULL(st.treatment_task_count, 0) = 0
              THEN N'In treatment, but no treatment task exists yet. Raise one, or change the option to Tolerate.'
         WHEN r.treatment_option_code <> N'Tolerate'
          AND ISNULL(r.residual_pending, 1) = 1
              THEN N'Residual risk has not been assessed. That is the step before acceptance '
                 + N'for a treated risk -- reviewing does not perform it.'
         ELSE N'Status is Monitoring and nothing blocks it, yet the stage says '
            + ISNULL(st.workflow_stage_code, N'(null)')
            + N' -- migration 299 is probably not applied. See section 3.'
       END                               AS Blocker

  FROM grac_practice.risk_register r
  JOIN grac_practice.vw_pm_risk_workflow_stage st
    ON st.risk_register_id = r.risk_register_id
 WHERE (@organization_id IS NULL OR r.organization_id = @organization_id)
   AND r.last_reviewed_dt IS NOT NULL
 ORDER BY r.last_reviewed_dt DESC;

-- ---------------------------------------------------------------------
-- 2b. THE LAST RISK YOU REVIEWED
--
-- One row, every field the stage view reads, and the history of what
-- actually touched it. When "I just reviewed one and it did not appear",
-- this is the row that says why.
-- ---------------------------------------------------------------------
PRINT '=== 2b. The most recently reviewed risk ===';

DECLARE @last_id BIGINT;

SELECT TOP (1) @last_id = r.risk_register_id
  FROM grac_practice.risk_register r
 WHERE (@organization_id IS NULL OR r.organization_id = @organization_id)
   AND r.last_reviewed_dt IS NOT NULL
 ORDER BY r.last_reviewed_dt DESC;

SELECT r.risk_number          AS RiskNumber,
       r.status_code          AS StatusCode,
       st.workflow_stage_code AS Stage,
       r.treatment_option_code AS TreatmentOption,
       r.analysis_pending     AS AnalysisPending,
       r.residual_pending     AS ResidualPending,
       r.accepted_dt          AS AcceptedOn,
       r.next_review_date     AS NextReviewDate,
       r.last_reviewed_dt     AS LastReviewedOn,
       r.review_frequency_id  AS ReviewFrequencyId,
       CASE WHEN r.status_code = N'Monitoring'
            THEN N'Status is correct -- a review DID set it.'
            ELSE N'Status is ' + ISNULL(r.status_code, N'(null)')
               + N' -- the review did NOT set Monitoring.' END AS Verdict
  FROM grac_practice.risk_register r
  LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st
    ON st.risk_register_id = r.risk_register_id
 WHERE r.risk_register_id = @last_id;

-- Its audit trail. A review writes a 'Review' or 'BulkReview' row; a
-- status change writes a 'FieldChange' with field_code = 'status_code'.
-- If the review row is there but no status change is, the review ran
-- against the pre-299 procedure.
SELECT TOP (12)
       h.entered_dt        AS EnteredOn,
       h.action_code       AS Action,
       h.from_status_code  AS FromStatus,
       h.to_status_code    AS ToStatus,
       h.field_code        AS FieldCode,
       h.from_value        AS FromValue,
       h.to_value          AS ToValue,
       LEFT(h.remark, 90)  AS Remark
  FROM grac_practice.risk_register_history h
 WHERE h.risk_register_id = @last_id
 ORDER BY h.entered_dt DESC;

-- ---------------------------------------------------------------------
-- 3. Which routing rule is in force?
--
-- There is only ever ONE, and since 299 it is the status. An earlier
-- version of this script tested for 296's null-date rule and reported
-- "NOT APPLIED -- run 296" once 299 had legitimately removed it --
-- advice that would have UNDONE 299. That check is gone.
-- ---------------------------------------------------------------------
PRINT '=== 3. Which rule routes a risk to the Accept tab? ===';

SELECT CASE
         WHEN OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NULL
              THEN '*** the stage view is MISSING -- run 264, then 296 and 299'
         WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                       WHERE object_id = OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage')
                         AND definition LIKE '%status_code = N''Monitoring''%')
              THEN 'CURRENT (299) -- status_code = Monitoring routes a risk to the Accept tab'
         WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                       WHERE object_id = OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage')
                         AND definition LIKE '%next_review_date IS NULL%')
              THEN '*** SUPERSEDED (296) -- still on the null-date rule; run 299'
         ELSE '*** UNKNOWN -- the view matches neither rule; run 296 then 299'
       END AS RoutingRule;

SELECT CASE WHEN OBJECT_ID('grac_practice.sp_risk_bulk_accept','P') IS NOT NULL
            THEN 'APPLIED -- the Accept tab bulk button will work'
            ELSE '*** NOT APPLIED -- run 295_risk_bulk_accept.sql'
       END AS Migration295;

-- 296 fixed the Tolerate branch as well. Without that fix an ACCEPTED
-- Tolerate risk reads ResidualDue forever, and never shows as Accepted.
SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage')
                            AND definition LIKE '%THEN CASE WHEN r.accepted_dt IS NULL%')
            THEN 'APPLIED -- Tolerate resolves to AcceptanceDue or Accepted only'
            ELSE '*** NOT APPLIED -- accepted Tolerate risks will read ResidualDue'
       END AS Migration296_ToleranceBranch;

-- 299 is the one that matters now. It replaced 296/297's date rule with
-- the status rule, so these two checks tell you whether the CURRENT
-- behaviour is in place.
SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage')
                            AND definition LIKE '%status_code = N''Monitoring''%')
            THEN 'APPLIED -- status routes a risk to the Accept tab'
            ELSE '*** NOT APPLIED -- the view still uses the old date rule; run 299'
       END AS Migration299_View;

SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_review_perform')
                            AND definition LIKE '%ELSE N''Monitoring'' END%')
            THEN 'APPLIED -- a single review always sets Monitoring'
            ELSE '*** NOT APPLIED -- run 299'
       END AS Migration299_SingleReview;

SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%SET @status_code = N''Monitoring'';%')
            THEN 'APPLIED -- a bulk review with no status chosen sets Monitoring'
            ELSE '*** NOT APPLIED -- run 299'
       END AS Migration299_BulkReview;

-- ---------------------------------------------------------------------
-- 4. The stranded set 296 was written to rescue
--
-- Risks that were accepted, then had their review date cleared by a
-- SINGLE review. Before 296 these appeared on no work list at all.
-- ---------------------------------------------------------------------
PRINT '=== 4. Accepted, then reviewed with no new date ===';

SELECT r.risk_number      AS RiskNumber,
       st.workflow_stage_code AS StageNow,
       r.accepted_dt      AS AcceptedOn,
       r.last_reviewed_dt AS LastReviewedOn
  FROM grac_practice.risk_register r
  JOIN grac_practice.vw_pm_risk_workflow_stage st
    ON st.risk_register_id = r.risk_register_id
 WHERE (@organization_id IS NULL OR r.organization_id = @organization_id)
   AND r.accepted_dt IS NOT NULL
   AND r.next_review_date IS NULL
   AND r.status_code NOT IN (N'Closed', N'Retired')
 ORDER BY r.last_reviewed_dt DESC;

PRINT 'Read section 2 first: the Blocker column says why each reviewed risk is where it is.';
