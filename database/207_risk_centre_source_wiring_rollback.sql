-- =====================================================================
-- 207 Risk Centre source wiring ROLLBACK
--
-- Restores sp_risk_candidate_create to its 170 definition, byte-for-byte.
--
-- WHY THE DATA IS LEFT ALONE
-- --------------------------
-- 207's backfill only FILLED columns that 205 created. Undoing it would
-- mean blanking source_record_id / source_reference / source_centre_code,
-- which 205's own backfill also sets — so the rollback would fight the
-- migration below it. If the source columns must go, that is 205's
-- rollback, and it drops them outright.
--
-- CAUTION: after this rollback the 170 create proc runs again, and it
-- does not populate source_type_code. The column is NOT NULL with a
-- DEFAULT of 'Gap' (205), so inserts still succeed — every new candidate
-- is simply labelled 'Gap' with a NULL source_record_id until 207 is
-- re-applied. Re-run 207 to repair them; its backfill is idempotent.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.risk_candidate','U') IS NULL
BEGIN
    PRINT '207-rollback: risk_candidate missing — nothing to do.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_create
    @custom_gap_id            BIGINT,
    @candidate_title          NVARCHAR(300) = NULL,
    @candidate_summary        NVARCHAR(MAX) = NULL,
    @severity_code            NVARCHAR(30)  = NULL,
    @severity_name            NVARCHAR(120) = NULL,
    @impact_summary           NVARCHAR(MAX) = NULL,
    @likelihood_summary       NVARCHAR(MAX) = NULL,
    @requested_by_employee_id BIGINT        = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55400, 'sp_risk_candidate_create: custom_gap_id is required.', 1;

    DECLARE @org_id BIGINT, @gap_title NVARCHAR(250), @gap_severity NVARCHAR(30);
    SELECT @org_id = organization_id, @gap_title = title, @gap_severity = severity_code
      FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;
    IF @org_id IS NULL
        THROW 55401, 'sp_risk_candidate_create: custom_gap not found.', 1;

    DECLARE @existing_id BIGINT =
        (SELECT TOP 1 risk_candidate_id
           FROM grac_practice.risk_candidate
          WHERE custom_gap_id = @custom_gap_id
            AND status_code IN (N'Pending', N'Accepted')
          ORDER BY risk_candidate_id DESC);
    IF @existing_id IS NOT NULL
    BEGIN
        SELECT @existing_id AS RiskCandidateId, CAST(0 AS BIT) AS Created;
        RETURN;
    END

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    DECLARE @title    NVARCHAR(300) = COALESCE(@candidate_title, N'Risk: ' + @gap_title);
    DECLARE @severity NVARCHAR(30)  = COALESCE(@severity_code, @gap_severity);
    DECLARE @new_id   BIGINT;

    BEGIN TRY
        BEGIN TRAN;

        INSERT INTO grac_practice.risk_candidate
            (organization_id, custom_gap_id,
             candidate_title, candidate_summary,
             severity_code, severity_name,
             impact_summary, likelihood_summary,
             status_code,
             requested_by_employee_id, requested_dt,
             record_status_id, entered_by, entered_dt)
        VALUES
            (@org_id, @custom_gap_id,
             @title, @candidate_summary,
             @severity, @severity_name,
             @impact_summary, @likelihood_summary,
             N'Pending',
             @requested_by_employee_id, SYSUTCDATETIME(),
             @active_rs, @caller_display_name, SYSUTCDATETIME());

        SET @new_id = SCOPE_IDENTITY();

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@new_id, N'Create', NULL, N'Pending',
             @candidate_summary, @requested_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @new_id AS RiskCandidateId, CAST(1 AS BIT) AS Created;
END
GO

PRINT '207 Risk Centre source wiring rolled back; 170 sp_risk_candidate_create restored.';
GO

SET NOEXEC OFF;
GO
