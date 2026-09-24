-- =====================================================================
-- tool_seed_risks_for_review.sql
--
-- NOT A MIGRATION. Unnumbered on purpose so it never enters the
-- migration sequence. A test-data helper, for putting a handful of
-- risks onto the Review Risk tab so the review -> acceptance flow can
-- be exercised end to end.
--
-- ---------------------------------------------------------------------
-- IT WRITES. READ THIS BEFORE RUNNING IT.
-- ---------------------------------------------------------------------
-- @commit defaults to 0, so a plain run CHANGES NOTHING and only shows
-- you what it would do. Set @commit = 1 to actually write.
--
-- The only column it touches is risk_register.next_review_date (plus
-- updated_by / updated_dt, which every write in this schema stamps). It
-- does NOT accept risks, does NOT touch review_count or
-- last_reviewed_dt, and does NOT change status -- pulling a date
-- backwards is the whole trick, because the Review tab's rule is
-- "next_review_date <= today".
--
-- Section 5 prints ready-made UNDO statements for exactly the rows it
-- changed. Copy them somewhere before you close the window.
--
-- ---------------------------------------------------------------------
-- WHICH RISKS IT PICKS, AND WHY IT MATTERS
-- ---------------------------------------------------------------------
-- It deliberately prefers risks that are ALREADY ELIGIBLE FOR
-- ACCEPTANCE -- stage AcceptanceDue or Accepted.
--
-- That is the point. Reviewing a risk does not make it acceptable:
-- nothing in any review completes an analysis, chooses a treatment
-- option, closes a treatment task or assesses residual risk. If this
-- script seeded risks that were stuck at InTreatment or ResidualDue,
-- you would review them, they would go nowhere, and the exercise would
-- prove nothing.
--
-- Seeded from eligible risks instead, the whole chain is demonstrable:
--
--     Review tab  --(review, next review date left BLANK)-->
--     Accept tab  --(accept, with a frequency)-->  scheduled again
--
-- Section 2 tells you how many eligible risks exist. If it says zero,
-- this script cannot help and the answer is upstream: close the open
-- treatment tasks, or assess residual risk, on some risks first.
--
-- REQUIRES: 296 (so a reviewed risk reaches the Accept tab at all).
-- =====================================================================
SET NOCOUNT ON;

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------
DECLARE @organization_id BIGINT = NULL;  -- <<< set this, or NULL for every organisation
DECLARE @how_many        INT    = 5;     -- how many risks to put on the Review tab
DECLARE @days_overdue    INT    = 3;     -- 0 = due today, 3 = three days overdue
DECLARE @commit          BIT    = 0;     -- <<< 0 = show only. 1 = write.

DECLARE @today     DATE = CAST(SYSUTCDATETIME() AS DATE);
DECLARE @due_date  DATE = DATEADD(DAY, -ABS(@days_overdue), @today);
DECLARE @actor     NVARCHAR(100) = N'seed-script';
-- Declared up here, not at the point of use: @@ROWCOUNT must be read by
-- the statement IMMEDIATELY after the UPDATE, and a DECLARE ... = @@ROWCOUNT
-- is its own statement, which sets @@ROWCOUNT itself.
DECLARE @n         INT = 0;

-- ---------------------------------------------------------------------
-- 1. Is 296 applied? Without it a reviewed risk goes nowhere, and
--    seeding data to prove that is a waste of your time.
-- ---------------------------------------------------------------------
PRINT '=== 1. Prerequisite ===';

IF NOT EXISTS (SELECT 1 FROM sys.sql_modules
                WHERE object_id = OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage')
                  AND definition LIKE '%next_review_date IS NULL%')
BEGIN
    PRINT '*** WARNING: migration 296 is NOT applied.';
    PRINT '    You can still seed the Review tab, but reviewing those risks will NOT';
    PRINT '    send them to Accept -- they will land on no list at all.';
    PRINT '    Run 296_reviewed_risk_returns_to_acceptance.sql first.';
END
ELSE
    PRINT '296 is applied. A reviewed risk with no review date will reach the Accept tab.';

-- ---------------------------------------------------------------------
-- 2. What is available to seed from?
-- ---------------------------------------------------------------------
PRINT '';
PRINT '=== 2. Risks by stage (what this script has to work with) ===';

SELECT st.workflow_stage_code AS Stage,
       COUNT(*)               AS Risks,
       CASE st.workflow_stage_code
         WHEN N'AcceptanceDue' THEN N'ELIGIBLE -- ideal to seed from'
         WHEN N'Accepted'      THEN N'ELIGIBLE -- ideal to seed from'
         WHEN N'ReviewDue'     THEN N'already on the Review tab'
         WHEN N'InTreatment'   THEN N'NOT eligible -- close its treatment tasks first'
         WHEN N'ResidualDue'   THEN N'NOT eligible -- assess residual risk first'
         WHEN N'AnalysisDue'   THEN N'NOT eligible -- complete the analysis first'
         WHEN N'TreatmentDue'  THEN N'NOT eligible -- choose a treatment option first'
         ELSE N'closed or retired'
       END                    AS Note
  FROM grac_practice.risk_register r
  JOIN grac_practice.vw_pm_risk_workflow_stage st
    ON st.risk_register_id = r.risk_register_id
 WHERE (@organization_id IS NULL OR r.organization_id = @organization_id)
 GROUP BY st.workflow_stage_code
 ORDER BY Risks DESC;

-- ---------------------------------------------------------------------
-- 3. The selection
--
-- Eligible risks only, and never one that is already due -- re-dating a
-- risk that is on the Review tab already would change a number without
-- changing anything you can see.
-- ---------------------------------------------------------------------
DECLARE @picked TABLE (
    risk_register_id BIGINT PRIMARY KEY,
    risk_number      NVARCHAR(60),
    risk_title       NVARCHAR(300),
    old_review_date  DATE,
    old_stage        NVARCHAR(30)
);

INSERT INTO @picked (risk_register_id, risk_number, risk_title, old_review_date, old_stage)
SELECT TOP (@how_many)
       r.risk_register_id, r.risk_number, r.risk_title,
       r.next_review_date, st.workflow_stage_code
  FROM grac_practice.risk_register r
  JOIN grac_practice.vw_pm_risk_workflow_stage st
    ON st.risk_register_id = r.risk_register_id
 WHERE (@organization_id IS NULL OR r.organization_id = @organization_id)
   AND r.status_code NOT IN (N'Closed', N'Retired')
   AND st.workflow_stage_code IN (N'AcceptanceDue', N'Accepted')
 ORDER BY r.risk_register_id;

PRINT '';
PRINT '=== 3. Selected risks ===';

IF NOT EXISTS (SELECT 1 FROM @picked)
BEGIN
    PRINT 'NOTHING TO SEED. No risk is currently eligible for acceptance.';
    PRINT '';
    PRINT 'Section 2 says where they are stuck. Reviewing does not unstick them --';
    PRINT 'close the open treatment tasks, or assess residual risk, on a few risks';
    PRINT 'first, then run this again.';
END
ELSE
    SELECT p.risk_number                AS RiskNumber,
           LEFT(p.risk_title, 50)       AS RiskTitle,
           p.old_stage                  AS StageNow,
           p.old_review_date            AS ReviewDateNow,
           @due_date                    AS ReviewDateAfter,
           N'ReviewDue'                 AS StageAfter
      FROM @picked p
     ORDER BY p.risk_number;

-- ---------------------------------------------------------------------
-- 4. The write
-- ---------------------------------------------------------------------
PRINT '';
PRINT '=== 4. Write ===';

IF @commit = 0
BEGIN
    PRINT 'DRY RUN -- nothing was changed. Set @commit = 1 near the top to apply.';
END
ELSE IF NOT EXISTS (SELECT 1 FROM @picked)
BEGIN
    PRINT 'Nothing selected, so nothing was written.';
END
ELSE
BEGIN
    BEGIN TRY
        BEGIN TRAN;

        UPDATE r
           SET r.next_review_date = @due_date,
               r.updated_by       = @actor,
               r.updated_dt       = SYSUTCDATETIME()
          FROM grac_practice.risk_register r
          JOIN @picked p ON p.risk_register_id = r.risk_register_id;

        SET @n = @@ROWCOUNT;   -- must be the very next statement

        COMMIT;
        PRINT CONCAT(CAST(@n AS NVARCHAR(10)),
                     ' risk(s) dated ', CONVERT(NVARCHAR(10), @due_date, 23),
                     ' -- they are now on the Review Risk tab.');
        PRINT '';
        PRINT 'To finish the demonstration:';
        PRINT '  1. Review Risk tab -> select them -> Bulk review.';
        PRINT '  2. Leave NEXT REVIEW DATE BLANK (that is what returns them for acceptance).';
        PRINT '  3. They appear on the Accept Risk tab.';
        PRINT '  4. Accept them there, with a Review frequency, which sets the next date.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        PRINT '*** The update failed and was rolled back. Nothing changed.';
        THROW;
    END CATCH
END

-- ---------------------------------------------------------------------
-- 5. Undo
--
-- Generated for exactly the rows above, including the ones whose date
-- was NULL. Copy these before closing the window; nothing else records
-- what the dates used to be.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '=== 5. UNDO statements (copy these) ===';

IF EXISTS (SELECT 1 FROM @picked)
    SELECT CONCAT('UPDATE grac_practice.risk_register SET next_review_date = ',
                  CASE WHEN p.old_review_date IS NULL
                       THEN 'NULL'
                       ELSE CONCAT('''', CONVERT(NVARCHAR(10), p.old_review_date, 23), '''') END,
                  ' WHERE risk_register_id = ', CAST(p.risk_register_id AS NVARCHAR(20)),
                  ';   -- ', p.risk_number) AS UndoStatement
      FROM @picked p
     ORDER BY p.risk_number;
