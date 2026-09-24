-- =====================================================================
-- 296_reviewed_risk_returns_to_acceptance.sql
--
-- THE BUG
--   Review three risks; they vanish. Not on the Accept tab, not on the
--   Review tab, visible only under Accept -> "Already accepted", which
--   is the one place they do not belong.
--
-- WHY
--   sp_risk_review_perform (264) does three things:
--       next_review_date -> CLEARED (unless the reviewer supplied one)
--       status_code      -> Accepted becomes Monitoring
--       accepted_dt      -> LEFT EXACTLY AS IT WAS
--
--   and vw_pm_risk_workflow_stage ends:
--       WHEN r.accepted_dt IS NULL  THEN 'AcceptanceDue'
--       ELSE                             'Accepted'
--
--   The stale accepted_dt sends every reviewed risk to ELSE. So the
--   stage says 'Accepted' while status_code says 'Monitoring' and there
--   is no review date -- a risk that is settled according to one column,
--   unsettled according to another, and scheduled according to neither.
--
--   It is not on the review list (that needs a date) and not on the
--   acceptance list (that needs accepted_dt to be NULL). It is nowhere.
--
-- WHY THIS IS THE VIEW'S BUG AND NOT THE PROCEDURE'S
--   264's own header for sp_risk_review_perform says the opposite of
--   what the view does:
--
--     "after a review, the risk is back in the flow -- it may need new
--      treatment, a new residual assessment, or a fresh acceptance. The
--      next review date is set again when the risk is next ACCEPTED, by
--      sp_risk_acceptance_save, which is the one procedure that requires
--      it."
--
--   The intent was always review -> acceptance. The stage view simply
--   never expressed it. So the procedure is left alone and the view is
--   corrected.
--
-- THE TEST, AND WHY IT IS EXACT
--   A ready risk with NO next_review_date is awaiting acceptance.
--
--   That is not a heuristic. sp_risk_acceptance_save REQUIRES a next
--   review date and throws 56601 without one, so every accepted risk has
--   a date by construction. A risk that is otherwise ready and has no
--   date can therefore only be one a review cleared -- exactly the case
--   above. Nothing else in the schema produces that combination:
--   sp_risk_bulk_review COALESCEs the existing date rather than clearing
--   it, and so does 294.
--
--   Reviewing WITH a date still means "see me again then" and keeps the
--   risk scheduled, which is the behaviour 264's header describes for a
--   caller that passes @next_review_date. Only the blank-date review --
--   what the Review form does by default -- routes back to acceptance.
--
-- BOTH BRANCHES, NOT ONE
--   The Tolerate branch sits ABOVE the residual check, deliberately, so
--   that a Tolerate risk never waits on a residual assessment it will
--   never have. Fixing only the lower branch would therefore miss every
--   Tolerate risk: with accepted_dt set it would fall past Tolerate,
--   past the two InTreatment tests (Tolerate is in neither list), and
--   land on ResidualDue -- sending a reviewed Tolerate risk to a residual
--   assessment instead of to acceptance.
--
-- A SECOND DEFECT, FOUND WHILE PROVING THE FIRST
--   Tracing that fall-through showed the same path is ALREADY wrong for
--   a Tolerate risk that has simply been accepted and scheduled. 264
--   guards the branch with "accepted_dt IS NULL", so the moment such a
--   risk is accepted it falls through to ResidualDue -- and nothing ever
--   clears residual_pending for a Tolerate risk, because a Tolerate risk
--   never has a residual assessment. Every accepted Tolerate risk has
--   therefore been displaying as "ResidualDue", waiting forever on an
--   assessment that will never come, in the register grid, the dashboard
--   and the new Accept tab's "Already accepted" view alike.
--
--   So Tolerate is now decided entirely inside its own branch by a
--   nested CASE -- AcceptanceDue or Accepted, never anything else. That
--   fixes the review case and the accepted case together, and makes it
--   structurally impossible for a Tolerate risk to reach a branch that
--   does not apply to it.
--
-- BLAST RADIUS
--   vw_pm_risk_workflow_stage is joined by sp_risk_register_list,
--   sp_risk_register_get, sp_risk_acceptance_get and the calendar feed.
--   That is the point: one definition of "ready to accept", corrected
--   once, so the Accept tab, the register grid and the dashboard agree.
--   No other object changes and no data is written.
--
-- Re-runnable: yes (DROP + CREATE inside a guard).
-- Rollback: database/296_reviewed_risk_returns_to_acceptance_rollback.sql
-- DEPENDS ON: 264 (the view and sp_risk_review_perform).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NULL
BEGIN
    PRINT 'ABORT (296): risk_register or vw_pm_practice_task missing -- run 205 / the task views first.';
    RAISERROR('296_reviewed_risk_returns_to_acceptance: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NULL
BEGIN
    PRINT 'ABORT (296): vw_pm_risk_workflow_stage missing -- run 264 first.';
    RAISERROR('296_reviewed_risk_returns_to_acceptance: the view does not exist.', 16, 1);
    SET NOEXEC ON;
END
GO

DROP VIEW grac_practice.vw_pm_risk_workflow_stage;
GO

-- Re-issued from 264 verbatim except the two marked clauses. Built
-- through sp_executesql for the same reason 264 does: CREATE VIEW must
-- be the first statement in its batch, and this file needs the guards
-- above it.
EXEC sp_executesql N'
CREATE VIEW grac_practice.vw_pm_risk_workflow_stage AS
WITH tt AS (
    SELECT r.risk_register_id,
           -- Parents only. BRD 11: the parent owns the commitment, so a
           -- parent with two open children is ONE open treatment task.
           SUM(CASE WHEN v.parent_task_id IS NULL THEN 1 ELSE 0 END) AS TaskCount,
           SUM(CASE WHEN v.parent_task_id IS NULL
                     AND v.closed_at IS NULL
                     AND v.current_status_is_terminal = 0
                    THEN 1 ELSE 0 END)                               AS OpenCount
      FROM grac_practice.risk_register r
      JOIN grac_practice.vw_pm_practice_task v
        ON v.organization_id = r.organization_id
       AND ((v.source_type_code = N''RiskRegister''
             AND v.source_record_id = r.risk_register_id)
         OR (r.risk_candidate_id IS NOT NULL
             AND v.source_type_code = N''Risk''
             AND v.source_record_id = r.risk_candidate_id))
     GROUP BY r.risk_register_id
)
SELECT r.risk_register_id,
       r.organization_id,
       ISNULL(tt.TaskCount, 0) AS treatment_task_count,
       ISNULL(tt.OpenCount, 0) AS open_treatment_task_count,
       CAST(CASE WHEN r.next_review_date IS NOT NULL
                  AND r.next_review_date <= CAST(SYSUTCDATETIME() AS DATE)
                  AND r.status_code NOT IN (N''Closed'', N''Retired'')
                 THEN 1 ELSE 0 END AS BIT) AS is_review_due,
       CASE
         WHEN r.status_code IN (N''Closed'', N''Retired'')      THEN N''Closed''
         WHEN r.next_review_date IS NOT NULL
          AND r.next_review_date <= CAST(SYSUTCDATETIME() AS DATE)
                                                               THEN N''ReviewDue''
         WHEN ISNULL(r.analysis_pending, 1) = 1                THEN N''AnalysisDue''
         WHEN r.treatment_option_code IS NULL                  THEN N''TreatmentDue''
         -- CHANGED IN 296. Tolerate is now decided ENTIRELY here, by a
         -- nested CASE, instead of falling through when it does not
         -- match.
         --
         -- 264 wrote this branch as "Tolerate AND accepted_dt IS NULL",
         -- which is right until the risk IS accepted -- after that it
         -- falls past Tolerate, past both InTreatment tests (Tolerate is
         -- in neither list) and lands on ResidualDue. Nothing ever
         -- clears residual_pending for a Tolerate risk, because a
         -- Tolerate risk never HAS a residual assessment -- that is the
         -- very reason this branch sits above that check. So every
         -- accepted Tolerate risk has been reading "ResidualDue",
         -- waiting forever on an assessment it will never receive.
         --
         -- Owning the option outright fixes that and the review case in
         -- one move: a Tolerate risk is AcceptanceDue or Accepted, and
         -- can no longer reach a branch that does not apply to it.
         WHEN r.treatment_option_code = N''Tolerate''
              THEN CASE WHEN r.accepted_dt IS NULL
                          OR r.next_review_date IS NULL
                         THEN N''AcceptanceDue''
                        ELSE N''Accepted'' END
         WHEN r.treatment_option_code IN (N''Terminate'', N''Treat'', N''Transfer'')
          AND ISNULL(tt.OpenCount, 0) > 0                      THEN N''InTreatment''
         WHEN r.treatment_option_code IN (N''Terminate'', N''Treat'', N''Transfer'')
          AND ISNULL(tt.TaskCount, 0) = 0                      THEN N''InTreatment''
         WHEN ISNULL(r.residual_pending, 1) = 1                THEN N''ResidualDue''
         -- CHANGED IN 296. Acceptance REQUIRES a next review date
         -- (56601), so every accepted risk has one; a ready risk without
         -- one can only be a risk a review cleared, and it is waiting to
         -- be accepted again.
         WHEN r.accepted_dt IS NULL
           OR r.next_review_date IS NULL                        THEN N''AcceptanceDue''
         ELSE N''Accepted''
       END AS workflow_stage_code
  FROM grac_practice.risk_register r
  LEFT JOIN tt ON tt.risk_register_id = r.risk_register_id;';
GO

IF OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NULL
BEGIN
    PRINT '*** ABORT (296): the view was NOT recreated. sp_risk_register_list,';
    PRINT '    sp_risk_register_get and sp_risk_acceptance_get all join it and';
    PRINT '    will fail at run time. Re-run 264 to restore it.';
    RAISERROR('296: vw_pm_risk_workflow_stage was dropped and not recreated.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 296 verification ---';

SELECT '296 the view exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NOT NULL
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT '296 both AcceptanceDue routes test the review date' AS Check_,
       CASE WHEN (SELECT LEN(definition) - LEN(REPLACE(definition, 'next_review_date IS NULL', ''))
                    FROM sys.sql_modules
                   WHERE object_id = OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage'))
                 / LEN('next_review_date IS NULL') >= 2
            THEN 'PASS -- Tolerate and residual-assessed routes both covered'
            ELSE '*** FAIL -- one route still strands reviewed risks' END AS Result;

-- Should be zero. A Tolerate risk must never read ResidualDue: it has no
-- residual assessment by definition, and before 296 every accepted one
-- did.
SELECT '296 no Tolerate risk is waiting on a residual assessment' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1
                  FROM grac_practice.risk_register r
                  JOIN grac_practice.vw_pm_risk_workflow_stage st
                    ON st.risk_register_id = r.risk_register_id
                 WHERE r.treatment_option_code = N'Tolerate'
                   AND st.workflow_stage_code IN (N'ResidualDue', N'InTreatment'))
            THEN 'PASS -- Tolerate resolves to AcceptanceDue or Accepted only'
            ELSE '*** FAIL -- a Tolerate risk reached a branch that cannot apply to it' END AS Result;

-- The point of the whole migration, asked of the real data: a risk that
-- is ready, unscheduled and previously accepted must now read
-- AcceptanceDue rather than Accepted.
SELECT '296 reviewed risks now read AcceptanceDue' AS Check_,
       CONCAT(COUNT(*), ' risk(s) moved out of the nowhere state') AS Result
  FROM grac_practice.risk_register r
  JOIN grac_practice.vw_pm_risk_workflow_stage st
    ON st.risk_register_id = r.risk_register_id
 WHERE r.accepted_dt IS NOT NULL
   AND r.next_review_date IS NULL
   AND r.status_code NOT IN (N'Closed', N'Retired')
   AND st.workflow_stage_code = N'AcceptanceDue';

-- Should be zero. A risk with a future date and an acceptance is
-- settled, and 296 must not have disturbed that.
SELECT '296 scheduled acceptances are untouched' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1
                  FROM grac_practice.risk_register r
                  JOIN grac_practice.vw_pm_risk_workflow_stage st
                    ON st.risk_register_id = r.risk_register_id
                 WHERE r.accepted_dt IS NOT NULL
                   AND r.next_review_date > CAST(SYSUTCDATETIME() AS DATE)
                   AND ISNULL(r.residual_pending, 1) = 0
                   AND st.workflow_stage_code = N'AcceptanceDue')
            THEN 'PASS -- accepted-and-scheduled risks still read Accepted'
            ELSE '*** FAIL -- settled risks are being sent back to acceptance' END AS Result;

PRINT '296 Reviewed risks return to Acceptance.';
PRINT '     A ready risk with no next_review_date is AcceptanceDue -- acceptance';
PRINT '     requires a date (56601), so it can only be one a review cleared.';
PRINT '     Reviewing WITH a date still means "see me again then" and is unchanged.';
GO

SET NOEXEC OFF;
GO
