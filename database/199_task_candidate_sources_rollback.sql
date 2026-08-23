-- =====================================================================
-- 199 Task Candidate — source integrations ROLLBACK
--
-- Restores the three source procedures to their pre-Phase-2 bodies and
-- drops sp_task_source_items.
--
--   sp_custom_gap_task_create           -> 174 (direct Approved Task)
--   sp_risk_candidate_accept            -> 170 (no task candidate)
--   sp_org_assurance_observation_accept -> 102 (no task candidate)
--
-- Run this FIRST when unwinding Phase 2 (199 -> 198 -> 197): once these
-- three no longer call sp_task_candidate_create, 198's rollback can drop
-- it safely.
--
-- Candidates already raised are NOT deleted — they are a record of work
-- the organisation identified. 197's rollback drops the table if you
-- really want them gone.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '199-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_task_source_items','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_source_items;
GO

-- ---------------------------------------------------------------------
-- 1. sp_custom_gap_task_create -> the 174 body
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_task_create
    @custom_gap_id           BIGINT,
    @assigned_to_employee_id BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55500, 'sp_custom_gap_task_create: custom_gap_id is required.', 1;

    DECLARE @existing_id BIGINT =
        (SELECT TOP 1 task_id
           FROM grac_practice.practice_task
          WHERE subject_entity_type = N'CustomGap'
            AND subject_entity_id   = @custom_gap_id
            AND closed_at IS NULL
          ORDER BY task_id DESC);
    IF @existing_id IS NOT NULL
    BEGIN
        SELECT @existing_id AS TaskId, CAST(0 AS BIT) AS Created;
        RETURN;
    END

    DECLARE @org_id BIGINT, @gap_title NVARCHAR(250), @summary NVARCHAR(MAX);
    SELECT @org_id = organization_id, @gap_title = title
      FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;
    IF @org_id IS NULL
        THROW 55501, 'sp_custom_gap_task_create: custom_gap not found.', 1;

    SELECT @summary = recommended_action_summary
      FROM grac_practice.custom_gap_analysis WHERE custom_gap_id = @custom_gap_id;

    DECLARE @task_id    BIGINT;
    DECLARE @task_title NVARCHAR(250) = LEFT(CONCAT(N'Gap task: ', @gap_title), 250);
    BEGIN TRY
        EXEC grac_practice.sp_task_open
            @organization_id         = @org_id,
            @task_type_code          = N'Rectification',
            @subject_entity_type     = N'CustomGap',
            @subject_entity_id       = @custom_gap_id,
            @subject_title           = @task_title,
            @subject_description     = @summary,
            @priority                = N'Medium',
            @origin_code             = N'Custom',
            @assigned_to_employee_id = @assigned_to_employee_id,
            @actor_employee_id       = @assigned_to_employee_id,
            @task_id                 = @task_id OUTPUT;
    END TRY
    BEGIN CATCH
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
        THROW 55502, @msg, 1;
    END CATCH

    SELECT @task_id AS TaskId, CAST(1 AS BIT) AS Created;
END;
GO

-- ---------------------------------------------------------------------
-- 2. sp_risk_candidate_accept -> the 170 body
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.risk_candidate','U') IS NULL
BEGIN
    PRINT '199-rollback: risk_candidate missing — skipping sp_risk_candidate_accept restore.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_accept
    @risk_candidate_id       BIGINT,
    @acceptance_note         NVARCHAR(MAX),
    @accepted_by_employee_id BIGINT,
    @formal_risk_ref         NVARCHAR(200) = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
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

    SELECT @risk_candidate_id AS RiskCandidateId, N'Accepted' AS StatusCode;
END;
GO

SET NOEXEC OFF;
GO

-- ---------------------------------------------------------------------
-- 3. sp_org_assurance_observation_accept -> the 102 body
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_org_assurance_observation_transition','P') IS NULL
BEGIN
    PRINT '199-rollback: sp_org_assurance_observation_transition missing — skipping accept restore.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_accept
    @organization_id BIGINT, @observation_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_observation_transition
        @organization_id = @organization_id, @observation_id = @observation_id,
        @expected_from_codes = N'InReview', @to_code = N'Accepted',
        @stamp_field = N'accepted', @notes = @notes, @actor = @actor;
END;
GO

SET NOEXEC OFF;
GO

PRINT '199 source integrations rolled back — Gap / Risk / Continuous Assurance restored to pre-Phase-2 behaviour.';
IF OBJECT_ID('grac_practice.task_candidate','U') IS NOT NULL
    SELECT '199-rollback: candidates left behind (not deleted)' AS Check_,
           source_type_code AS SourceTypeCode, status_code AS StatusCode, COUNT(*) AS Rows_
      FROM grac_practice.task_candidate
     GROUP BY source_type_code, status_code;
GO
