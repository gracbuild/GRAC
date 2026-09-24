-- =====================================================================
-- tool_backfill_reviewed_to_monitoring.sql
--
-- NOT A MIGRATION. A one-time data correction for risks that were
-- reviewed BEFORE migration 299.
--
-- ---------------------------------------------------------------------
-- WHAT IT FIXES
-- ---------------------------------------------------------------------
-- Since 299, status_code = 'Monitoring' is what puts a risk on the
-- Accept tab, and a review always sets it.
--
-- Risks reviewed BEFORE 299 never got that status:
--
--   * bulk review changed status only when the caller chose one, so a
--     bulk review with just a note and a date left the risk 'Accepted';
--   * the single review set 'Monitoring' only when the risk was already
--     'Accepted', so one reviewed from 'Active' kept 'Active'.
--
-- Those risks were reviewed -- last_reviewed_dt proves it -- but their
-- status still says settled, so 299's rule cannot see them and they sit
-- on no work list.
--
-- 299 fixes the behaviour going forward. It deliberately writes no rows,
-- which is why this is a separate, opt-in file rather than part of it.
--
-- ---------------------------------------------------------------------
-- WHICH ROWS
-- ---------------------------------------------------------------------
--   last_reviewed_dt > accepted_dt    reviewed SINCE it was accepted,
--                                     so the acceptance is superseded
--   status_code = 'Accepted'          still claims to be settled
--   not Closed / Retired              terminal states are left alone
--
-- The first condition is the important one. Without it this would sweep
-- up risks accepted AFTER their last review -- which are correctly
-- settled -- and drag them back onto the Accept tab.
--
-- ONLY status_code IS TOUCHED. Dates, cadences, accepted_by and
-- review_count are left exactly as they are: they are the reviewer's
-- proposals and the acceptance history, and 299 wants them carried to
-- the Accept screen, not erased.
--
-- @commit = 0 by default: a plain run shows the rows and changes nothing.
-- An audit row is written for each change when it does commit.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @organization_id BIGINT = NULL;   -- NULL = every organisation
DECLARE @commit          BIT    = 0;      -- <<< 0 = show only. 1 = apply.
DECLARE @actor           NVARCHAR(100) = N'backfill-299';

-- ---------------------------------------------------------------------
-- 1. Is 299 applied? Without it this backfill achieves nothing --
--    the stage view would still be looking at the review date.
-- ---------------------------------------------------------------------
SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage')
                            AND definition LIKE '%status_code = N''Monitoring''%')
            THEN 'APPLIED -- Monitoring routes a risk to the Accept tab'
            ELSE '*** NOT APPLIED -- run 299 first, or this changes status for nothing'
       END AS Migration299;

-- ---------------------------------------------------------------------
-- 2. The rows in question, and where they sit today
-- ---------------------------------------------------------------------
DECLARE @targets TABLE (risk_register_id BIGINT PRIMARY KEY);

INSERT INTO @targets (risk_register_id)
SELECT r.risk_register_id
  FROM grac_practice.risk_register r
 WHERE (@organization_id IS NULL OR r.organization_id = @organization_id)
   AND r.status_code = N'Accepted'
   AND r.last_reviewed_dt IS NOT NULL
   AND r.accepted_dt IS NOT NULL
   AND r.last_reviewed_dt > r.accepted_dt;

SELECT r.risk_number        AS RiskNumber,
       LEFT(r.risk_title, 45) AS RiskTitle,
       r.status_code        AS StatusNow,
       N'Monitoring'        AS StatusAfter,
       st.workflow_stage_code AS StageNow,
       N'AcceptanceDue'     AS StageAfter,
       r.accepted_dt        AS AcceptedOn,
       r.last_reviewed_dt   AS LastReviewedOn,
       r.next_review_date   AS ProposedNextReview
  FROM @targets t
  JOIN grac_practice.risk_register r ON r.risk_register_id = t.risk_register_id
  LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st
    ON st.risk_register_id = r.risk_register_id
 ORDER BY r.last_reviewed_dt DESC;

-- ---------------------------------------------------------------------
-- 3. Apply
-- ---------------------------------------------------------------------
IF @commit = 0
BEGIN
    SELECT 'DRY RUN' AS Result,
           CONCAT((SELECT COUNT(*) FROM @targets),
                  ' risk(s) would move to Monitoring. Set @commit = 1 to apply.') AS Detail;
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM @targets)
BEGIN
    SELECT 'NOTHING TO DO' AS Result,
           'No risk is Accepted-but-reviewed-since. Nothing was changed.' AS Detail;
    RETURN;
END

DECLARE @n INT = 0;

BEGIN TRY
    BEGIN TRAN;

    -- Written directly rather than through sp_risk_register_status_set,
    -- deliberately: that procedure stamps a StatusChange as though
    -- somebody decided this today. This is a correction of what the
    -- review SHOULD have written at the time, so the history row below
    -- says exactly that instead.
    UPDATE r
       SET r.status_code = N'Monitoring',
           r.updated_by  = @actor,
           r.updated_dt  = SYSUTCDATETIME()
      FROM grac_practice.risk_register r
      JOIN @targets t ON t.risk_register_id = r.risk_register_id;

    SET @n = @@ROWCOUNT;   -- must be the statement immediately after

    INSERT INTO grac_practice.risk_register_history
        (risk_register_id, action_code, from_status_code, to_status_code,
         field_code, from_value, to_value,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    SELECT t.risk_register_id, N'FieldChange', N'Accepted', N'Monitoring',
           N'status_code', N'Accepted', N'Monitoring',
           N'Backfill for migration 299: this risk was reviewed after it was accepted, '
         + N'but the review predates 299 and did not set Monitoring. Corrected so the '
         + N'risk appears for re-acceptance. No dates or cadences were changed.',
           NULL, @actor, @actor, SYSUTCDATETIME()
      FROM @targets t;

    COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT 'FAILED' AS Result, ERROR_MESSAGE() AS Detail;
    RETURN;
END CATCH

-- ---------------------------------------------------------------------
-- 4. Proof, read back from the view the Accept tab uses
-- ---------------------------------------------------------------------
SELECT 'DONE' AS Result,
       CONCAT(@n, ' risk(s) moved to Monitoring.') AS Detail;

SELECT r.risk_number        AS RiskNumber,
       r.status_code        AS StatusNow,
       st.workflow_stage_code AS StageNow,
       r.next_review_date   AS ProposedNextReview,
       CASE WHEN st.workflow_stage_code = N'AcceptanceDue'
            THEN N'On the Accept Risk tab'
            ELSE N'NOT on the Accept tab -- stage is ' + ISNULL(st.workflow_stage_code, N'(null)')
       END                  AS WhereItIs
  FROM @targets t
  JOIN grac_practice.risk_register r ON r.risk_register_id = t.risk_register_id
  LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st
    ON st.risk_register_id = r.risk_register_id
 ORDER BY r.risk_number;
