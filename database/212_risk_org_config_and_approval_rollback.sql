-- =====================================================================
-- 212 Risk Centre org config + approval gate ROLLBACK
--
-- Reverses 212_risk_org_config_and_approval.sql.
--
--   1. Refuse while 213 / 215 still bind to org_risk_config.
--   2. Drop 212's own procedures.
--   3. RESTORE sp_risk_candidate_register to its 206 definition (no
--      approval gate) and sp_risk_candidate_accept to its 199 definition
--      (no deprecation guard).
--   4. Drop the config tables.
--
-- Step 3 is the part that matters. Dropping a rewritten proc instead of
-- restoring it would leave the API calling something that no longer
-- exists — the screen would 500 rather than degrade.
--
-- DATA LOSS WARNING: every organisation's approval configuration and
-- notify-role matrix is DROPPED. Approval decisions already recorded on
-- risk_analysis (approval_status_code, approved_by, approved_dt,
-- approval_note) SURVIVE — those columns belong to 205 — they simply
-- stop being enforced.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '212-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Guard
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.risk_notification_outbox','U') IS NOT NULL
BEGIN
    PRINT 'ABORT (212-rollback): risk_notification_outbox still exists.';
    PRINT '                      Run 213_risk_notification_outbox_rollback.sql first —';
    PRINT '                      its sweep reads org_risk_config.notifications_enabled.';
    RAISERROR('212-rollback: 213 objects still present.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 2. 212 procedures
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_risk_approval_queue_list','P')      IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_approval_queue_list;
IF OBJECT_ID('grac_practice.sp_risk_analysis_approve','P')         IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_analysis_approve;
IF OBJECT_ID('grac_practice.sp_risk_analysis_submit_approval','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_analysis_submit_approval;
IF OBJECT_ID('grac_practice.sp_risk_approval_required','P')        IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_approval_required;
IF OBJECT_ID('grac_practice.sp_risk_config_save','P')              IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_config_save;
IF OBJECT_ID('grac_practice.sp_risk_config_get','P')               IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_config_get;
GO

-- ---------------------------------------------------------------------
-- 3a. Restore sp_risk_candidate_register to its 206 definition
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_register
    @risk_candidate_id    BIGINT,
    @risk_title           NVARCHAR(300) = NULL,
    @registration_note    NVARCHAR(MAX) = NULL,
    @registered_by_employee_id BIGINT   = NULL,
    @linked_asset_id      BIGINT        = NULL,
    @linked_vendor_id     BIGINT        = NULL,
    @linked_practice_id   BIGINT        = NULL,
    @linked_obligation_id BIGINT        = NULL,
    @linked_control_id    BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_candidate_id IS NULL
        THROW 56130, 'sp_risk_candidate_register: risk_candidate_id is required.', 1;

    DECLARE @current NVARCHAR(30), @cand_title NVARCHAR(300),
            @src_type NVARCHAR(40), @src_id BIGINT, @src_ref NVARCHAR(200),
            @src_desc NVARCHAR(MAX), @src_centre NVARCHAR(60);

    SELECT @current    = status_code,
           @cand_title = candidate_title,
           @src_type   = source_type_code,
           @src_id     = source_record_id,
           @src_ref    = source_reference,
           @src_desc   = source_description,
           @src_centre = source_centre_code
      FROM grac_practice.risk_candidate
     WHERE risk_candidate_id = @risk_candidate_id;

    IF @current IS NULL
        THROW 56131, 'sp_risk_candidate_register: candidate not found.', 1;
    IF @current IN (N'Registered', N'Rejected', N'ClosedAsDuplicate', N'Withdrawn')
        THROW 56132, 'sp_risk_candidate_register: this candidate is already closed.', 1;

    DECLARE @analysis_id BIGINT =
        (SELECT risk_analysis_id FROM grac_practice.risk_analysis
          WHERE risk_candidate_id = @risk_candidate_id AND is_current = 1);
    IF @analysis_id IS NULL
        THROW 56133, 'sp_risk_candidate_register: no risk analysis exists for this candidate. Every risk entering the register must pass through an initial analysis (BRD 24.1).', 1;

    IF @src_type IS NULL
        THROW 56134, 'sp_risk_candidate_register: this candidate has no source type. Run 207_risk_centre_source_wiring.sql to backfill legacy candidates.', 1;

    DECLARE @new_risk_id BIGINT;
    DECLARE @title NVARCHAR(300) = COALESCE(NULLIF(LTRIM(RTRIM(@risk_title)), N''), @cand_title);

    BEGIN TRY
        BEGIN TRAN;

        EXEC grac_practice.sp_risk_register_insert
             @risk_analysis_id     = @analysis_id,
             @risk_title           = @title,
             @source_type_code     = @src_type,
             @source_record_id     = @src_id,
             @source_reference     = @src_ref,
             @source_description   = @src_desc,
             @source_centre_code   = @src_centre,
             @risk_candidate_id    = @risk_candidate_id,
             @linked_asset_id      = @linked_asset_id,
             @linked_vendor_id     = @linked_vendor_id,
             @linked_practice_id   = @linked_practice_id,
             @linked_obligation_id = @linked_obligation_id,
             @linked_control_id    = @linked_control_id,
             @registered_by_employee_id = @registered_by_employee_id,
             @caller_display_name  = @caller_display_name,
             @risk_register_id     = @new_risk_id OUTPUT;

        UPDATE grac_practice.risk_candidate
           SET status_code        = N'Registered',
               registered_risk_id = @new_risk_id,
               formal_risk_ref    = (SELECT risk_number FROM grac_practice.risk_register
                                      WHERE risk_register_id = @new_risk_id),
               acceptance_note    = COALESCE(@registration_note, acceptance_note),
               accepted_by_employee_id = COALESCE(@registered_by_employee_id, accepted_by_employee_id),
               accepted_dt        = COALESCE(accepted_dt, SYSUTCDATETIME()),
               updated_by         = @caller_display_name,
               updated_dt         = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        UPDATE grac_practice.risk_analysis
           SET decision_note = COALESCE(@registration_note, decision_note)
         WHERE risk_analysis_id = @analysis_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Register', @current, N'Registered',
             CONCAT(N'Registered as risk_register_id ', CAST(@new_risk_id AS NVARCHAR(20)),
                    CASE WHEN @registration_note IS NULL THEN N''
                         ELSE CONCAT(N'. ', @registration_note) END),
             @registered_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId,
           N'Registered'      AS StatusCode,
           @new_risk_id       AS RiskRegisterId,
           (SELECT risk_number FROM grac_practice.risk_register
             WHERE risk_register_id = @new_risk_id) AS RiskNumber;
END;
GO

-- ---------------------------------------------------------------------
-- 3b. Restore sp_risk_candidate_accept to its 199 definition
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_accept
    @risk_candidate_id       BIGINT,
    @acceptance_note         NVARCHAR(MAX),
    @accepted_by_employee_id BIGINT,
    @formal_risk_ref         NVARCHAR(200) = NULL,
    @caller_display_name     NVARCHAR(100) = N'system',
    @raise_task_candidate    BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55430, 'sp_risk_candidate_accept: risk_candidate_id is required.', 1;
    IF @acceptance_note IS NULL OR LEN(LTRIM(RTRIM(@acceptance_note))) = 0
        THROW 55431, 'sp_risk_candidate_accept: acceptance_note is required.', 1;
    IF @accepted_by_employee_id IS NULL
        THROW 55432, 'sp_risk_candidate_accept: accepted_by_employee_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code
      FROM grac_practice.risk_candidate WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 55433, 'sp_risk_candidate_accept: candidate not found.', 1;
    IF @current <> N'Pending'
        THROW 55434, 'sp_risk_candidate_accept: only Pending candidates can be accepted.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_candidate
           SET status_code             = N'Accepted',
               accepted_by_employee_id = @accepted_by_employee_id,
               accepted_dt             = SYSUTCDATETIME(),
               acceptance_note         = @acceptance_note,
               formal_risk_ref         = @formal_risk_ref,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Accept', N'Pending', N'Accepted',
             CONCAT(N'Note: ', @acceptance_note,
                    CASE WHEN @formal_risk_ref IS NOT NULL
                         THEN CONCAT(N'  Formal risk ref: ', @formal_risk_ref)
                         ELSE N'' END),
             @accepted_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    DECLARE @candidate_id BIGINT = NULL, @created BIT = 0;

    IF ISNULL(@raise_task_candidate, 1) = 1
    BEGIN
        BEGIN TRY
            DECLARE @org_id BIGINT, @risk_title NVARCHAR(300),
                    @risk_summary NVARCHAR(MAX), @severity NVARCHAR(30);

            SELECT @org_id       = organization_id,
                   @risk_title   = candidate_title,
                   @risk_summary = candidate_summary,
                   @severity     = severity_code
              FROM grac_practice.risk_candidate
             WHERE risk_candidate_id = @risk_candidate_id;

            DECLARE @priority NVARCHAR(30) =
                CASE WHEN @severity IN (N'Low', N'Medium', N'High', N'Critical')
                     THEN @severity ELSE N'Medium' END;

            DECLARE @cand_title NVARCHAR(250) =
                LEFT(CONCAT(N'Risk treatment: ', @risk_title), 250);
            DECLARE @cand_desc NVARCHAR(MAX) =
                CONCAT(ISNULL(@risk_summary, N''),
                       N'  Accepted as a formal risk: ', @acceptance_note);
            DECLARE @source_ref NVARCHAR(200) =
                CONCAT(N'RISK-', CAST(@risk_candidate_id AS NVARCHAR(20)));

            EXEC grac_practice.sp_task_candidate_create
                 @organization_id       = @org_id,
                 @source_type_code      = N'Risk',
                 @source_record_id      = @risk_candidate_id,
                 @candidate_title       = @cand_title,
                 @candidate_description = @cand_desc,
                 @source_reference      = @source_ref,
                 @source_dedupe_key     = N'RISK_TREATMENT',
                 @task_type_code        = N'RiskDriven',
                 @proposed_priority     = @priority,
                 @actor_employee_id     = @accepted_by_employee_id,
                 @caller_display_name   = @caller_display_name,
                 @task_candidate_id     = @candidate_id OUTPUT,
                 @created               = @created      OUTPUT;
        END TRY
        BEGIN CATCH
            DECLARE @tc_warn NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_risk_candidate_accept: task candidate warning: ', @tc_warn);
        END CATCH
    END

    SELECT @risk_candidate_id AS RiskCandidateId,
           N'Accepted'        AS StatusCode,
           @candidate_id      AS TaskCandidateId;
END;
GO

-- ---------------------------------------------------------------------
-- 4. Config tables
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.org_risk_config_notify_role','U') IS NOT NULL
    DROP TABLE grac_practice.org_risk_config_notify_role;
IF OBJECT_ID('grac_practice.org_risk_config','U') IS NOT NULL
    DROP TABLE grac_practice.org_risk_config;
GO

PRINT '212 Risk Centre org config + approval gate rolled back.';
PRINT '     206 register proc and 199 accept proc restored.';
GO

SET NOEXEC OFF;
GO
