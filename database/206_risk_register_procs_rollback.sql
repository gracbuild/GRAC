-- =====================================================================
-- 206 Risk Register procedures ROLLBACK
--
-- Reverses 206_risk_register_procs.sql.
--
--   1. Drop the fifteen procedures 206 introduced.
--   2. RESTORE the four 170 procedures 206 rewrote
--      (list / get / reject / withdraw), byte-for-byte as 170 wrote
--      them, so the Risk Centre screen keeps working after the rollback.
--
-- Step 2 is the part that matters. Dropping a rewritten proc instead of
-- restoring it would leave the API calling something that no longer
-- exists — the screen would 500 rather than degrade.
--
-- NO DATA IS TOUCHED. risk_analysis and risk_register rows survive; they
-- simply become unreachable until 206 is re-run. Run
-- 205_risk_register_schema_rollback.sql if the data must go too.
--
-- CAUTION: after this rollback sp_risk_candidate_list INNER JOINs
-- custom_gap again, so any candidate whose source is not a gap will
-- DISAPPEAR from the screen. It is still in the table. Re-run 206 to see
-- it.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '206-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Drop 206's own procedures (dependents first)
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_risk_custom_create','P')             IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_custom_create;
IF OBJECT_ID('grac_practice.sp_risk_candidate_register','P')        IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_register;
IF OBJECT_ID('grac_practice.sp_risk_register_insert','P')           IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_register_insert;
IF OBJECT_ID('grac_practice.sp_risk_register_owner_set','P')        IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_register_owner_set;
IF OBJECT_ID('grac_practice.sp_risk_register_status_set','P')       IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_register_status_set;
IF OBJECT_ID('grac_practice.sp_risk_register_get','P')              IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_register_get;
IF OBJECT_ID('grac_practice.sp_risk_register_list','P')             IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_register_list;
IF OBJECT_ID('grac_practice.sp_risk_candidate_close_duplicate','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_close_duplicate;
IF OBJECT_ID('grac_practice.sp_risk_candidate_clarify','P')         IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_clarify;
IF OBJECT_ID('grac_practice.sp_risk_candidate_assign','P')          IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_assign;
IF OBJECT_ID('grac_practice.sp_risk_duplicate_check','P')           IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_duplicate_check;
IF OBJECT_ID('grac_practice.sp_risk_analysis_history','P')          IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_analysis_history;
IF OBJECT_ID('grac_practice.sp_risk_analysis_get','P')              IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_analysis_get;
IF OBJECT_ID('grac_practice.sp_risk_analysis_save','P')             IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_analysis_save;
IF OBJECT_ID('grac_practice.sp_risk_rating_resolve','P')            IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_rating_resolve;
IF OBJECT_ID('grac_practice.sp_risk_scoring_options_get','P')       IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_scoring_options_get;
GO

-- ---------------------------------------------------------------------
-- 2. Restore 170's list / get / reject / withdraw
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_list
    @organization_id BIGINT,
    @status_code     NVARCHAR(30) = NULL,
    @page_number     INT = 1,
    @page_size       INT = 25
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
        COUNT(*) OVER ()            AS TotalRows
      FROM grac_practice.risk_candidate r
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.organization_employee rq ON rq.employee_id = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee ac ON ac.employee_id = r.accepted_by_employee_id
 LEFT JOIN grac_practice.organization_employee rj ON rj.employee_id = r.rejected_by_employee_id
     WHERE r.organization_id = @organization_id
       AND (@status_code IS NULL OR r.status_code = @status_code)
     ORDER BY r.requested_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_get
    @risk_candidate_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55420, 'sp_risk_candidate_get: risk_candidate_id is required.', 1;

    SELECT
        r.risk_candidate_id         AS RiskCandidateId,
        r.organization_id           AS OrganizationId,
        r.custom_gap_id             AS CustomGapId,
        g.title                     AS GapTitle,
        r.candidate_title           AS CandidateTitle,
        r.candidate_summary         AS CandidateSummary,
        r.severity_code             AS SeverityCode,
        r.severity_name             AS SeverityName,
        r.impact_summary            AS ImpactSummary,
        r.likelihood_summary        AS LikelihoodSummary,
        r.status_code               AS StatusCode,
        r.requested_by_employee_id  AS RequestedByEmployeeId,
        rq.employee_name            AS RequestedByName,
        r.requested_dt              AS RequestedOn,
        r.accepted_by_employee_id   AS AcceptedByEmployeeId,
        ac.employee_name            AS AcceptedByName,
        r.accepted_dt               AS AcceptedOn,
        r.acceptance_note           AS AcceptanceNote,
        r.formal_risk_ref           AS FormalRiskRef,
        r.rejected_by_employee_id   AS RejectedByEmployeeId,
        rj.employee_name            AS RejectedByName,
        r.rejected_dt               AS RejectedOn,
        r.rejection_reason          AS RejectionReason
      FROM grac_practice.risk_candidate r
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.organization_employee rq ON rq.employee_id = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee ac ON ac.employee_id = r.accepted_by_employee_id
 LEFT JOIN grac_practice.organization_employee rj ON rj.employee_id = r.rejected_by_employee_id
     WHERE r.risk_candidate_id = @risk_candidate_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_reject
    @risk_candidate_id       BIGINT,
    @rejection_reason        NVARCHAR(MAX),
    @rejected_by_employee_id BIGINT,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55440, 'sp_risk_candidate_reject: risk_candidate_id is required.', 1;
    IF @rejection_reason IS NULL OR LEN(LTRIM(RTRIM(@rejection_reason))) = 0
        THROW 55441, 'sp_risk_candidate_reject: rejection_reason is required.', 1;
    IF @rejected_by_employee_id IS NULL
        THROW 55442, 'sp_risk_candidate_reject: rejected_by_employee_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code
      FROM grac_practice.risk_candidate WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 55443, 'sp_risk_candidate_reject: candidate not found.', 1;
    IF @current <> N'Pending'
        THROW 55444, 'sp_risk_candidate_reject: only Pending candidates can be rejected.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_candidate
           SET status_code             = N'Rejected',
               rejected_by_employee_id = @rejected_by_employee_id,
               rejected_dt             = SYSUTCDATETIME(),
               rejection_reason        = @rejection_reason,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Reject', N'Pending', N'Rejected',
             @rejection_reason, @rejected_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId, N'Rejected' AS StatusCode;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_withdraw
    @risk_candidate_id       BIGINT,
    @withdraw_reason         NVARCHAR(MAX) = NULL,
    @actor_employee_id       BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55450, 'sp_risk_candidate_withdraw: risk_candidate_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code
      FROM grac_practice.risk_candidate WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 55451, 'sp_risk_candidate_withdraw: candidate not found.', 1;
    IF @current <> N'Pending'
        THROW 55452, 'sp_risk_candidate_withdraw: only Pending candidates can be withdrawn.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_candidate
           SET status_code = N'Withdrawn',
               updated_by  = @caller_display_name,
               updated_dt  = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Withdraw', N'Pending', N'Withdrawn',
             @withdraw_reason, @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId, N'Withdrawn' AS StatusCode;
END
GO

PRINT '206 Risk Register procedures rolled back; 170 definitions restored.';
GO

SET NOEXEC OFF;
GO
