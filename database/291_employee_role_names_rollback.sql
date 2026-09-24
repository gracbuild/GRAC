-- =====================================================================
-- 291_employee_role_names_rollback.sql
--
-- Reverts 291: drops fn_employee_role_names and re-issues
-- sp_risk_acceptance_get exactly as 264 left it, without the
-- AcceptedByRoleNames column.
--
-- The procedure text below is a verbatim copy from
-- 264_risk_acceptance_review_procs.sql, so rolling back restores 264's
-- definition rather than an approximation of it.
--
-- ORDER MATTERS: the procedure is re-issued FIRST, so that nothing is
-- still referencing the function when it is dropped.
--
-- CONSEQUENCE OF RUNNING THIS
--   Risk Acceptance falls back to showing the accepting person's name
--   with no role suffix, and the dependency Person picker likewise --
--   the C# picker query calls this function, so roll the Web/API tier
--   back with it or the picker's query will fail on a missing function.
--
-- Re-runnable: yes.
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_acceptance_get
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56609, 'sp_risk_acceptance_get: risk_register_id is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_register
                    WHERE risk_register_id = @risk_register_id)
        THROW 56610, 'sp_risk_acceptance_get: risk not found.', 1;

    SELECT r.risk_register_id        AS RiskRegisterId,
           r.risk_number             AS RiskNumber,
           r.risk_title              AS RiskTitle,
           r.status_code             AS StatusCode,
           r.risk_owner_employee_id  AS RiskOwnerEmployeeId,
           ow.employee_name          AS RiskOwnerName,
           r.treatment_option_code   AS TreatmentOptionCode,
           r.treatment_option_name   AS TreatmentOptionName,
           r.inherent_rating_code    AS InherentRatingCode,
           r.residual_rating_code    AS ResidualRatingCode,
           r.residual_pending        AS ResidualPending,
           r.analysis_pending        AS AnalysisPending,

           r.accepted_by_employee_id AS AcceptedByEmployeeId,
           COALESCE(ab.employee_name, r.accepted_by_name) AS AcceptedByName,
           r.accepted_dt             AS AcceptedOn,
           r.acceptance_note         AS AcceptanceNote,
           r.next_review_date        AS NextReviewDate,
           r.last_reviewed_dt        AS LastReviewedOn,
           r.review_count            AS ReviewCount,
           st.workflow_stage_code    AS WorkflowStageCode,
           st.open_treatment_task_count AS OpenTreatmentTaskCount,

           CAST(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0
                     WHEN ISNULL(r.analysis_pending, 1) = 1        THEN 0
                     WHEN r.treatment_option_code IS NULL          THEN 0
                     ELSE 1 END AS BIT)              AS CanAccept,

           CASE WHEN r.status_code IN (N'Closed', N'Retired')
                     THEN N'This risk is closed or retired.'
                WHEN ISNULL(r.analysis_pending, 1) = 1
                     THEN N'Complete the risk analysis first.'
                WHEN r.treatment_option_code IS NULL
                     THEN N'Choose a treatment option first.'
                WHEN r.treatment_option_code = N'Tolerate'
                     THEN N'Tolerate / Accept -- this risk goes straight to acceptance.'
                WHEN ISNULL(r.residual_pending, 1) = 1
                     THEN N'Residual risk has not been assessed. You may still accept, but assessing it first is the intended order.'
                ELSE N'Ready to accept.'
           END                                        AS AcceptGuidance
      FROM grac_practice.risk_register r
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
      LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = r.accepted_by_employee_id
      LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
     WHERE r.risk_register_id = @risk_register_id;
END;
GO

IF OBJECT_ID('grac_practice.fn_employee_role_names','FN') IS NOT NULL
    DROP FUNCTION grac_practice.fn_employee_role_names;
GO

PRINT '291 rollback: AcceptedByRoleNames removed; fn_employee_role_names dropped.';
GO
