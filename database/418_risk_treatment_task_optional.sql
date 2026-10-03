-- =====================================================================
-- 418  Ask before raising the treatment task
--
-- REQUEST (2026-10-03)
-- --------------------
--   On Risk Treatment, applying Terminate / Treat / Transfer raised the
--   treatment task automatically. The page must first ask "Generate a
--   treatment task?" and raise it only on Yes.
--
-- WHAT THIS DOES
-- --------------
--   sp_risk_treatment_option_set -- 263's body re-issued with ONE new
--   trailing parameter, @raise_task BIT = 1. On 0 the decision, the
--   status move and the BRD s20 history row are written exactly as
--   before, but sp_risk_treatment_task_ensure is not called (TaskCreated
--   0, TreatmentTaskId NULL) and the history remark says it was declined.
--   Default 1 = 263's behaviour, so sp_risk_review_perform (264/299) and
--   sp_risk_residual_analysis_save (263), which call it with named
--   parameters, are untouched.
--
--   Tolerate is unchanged: it never raised a task.
--
-- DEPLOY WITH the matching Api + Web build. An Api deployed ahead of this
-- script refuses a "No" (probed) with a message naming 418, and a
-- "Yes" keeps working (263 always raised the task).
-- Rollback: 418_risk_treatment_task_optional_rollback.sql
-- Re-runnable. ASCII-only.
-- DEPENDS ON: 261 (treatment columns), 263 (this procedure,
--             sp_risk_treatment_task_ensure).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

-- The re-issued body reads these; guard on them, not only on the proc.
IF OBJECT_ID('grac_practice.sp_risk_treatment_task_ensure','P') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','treatment_option_code') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','treatment_option_name') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','treatment_decided_dt') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','treatment_decided_by_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.risk_analysis','treatment_option_code') IS NULL
   OR COL_LENGTH('grac_practice.risk_analysis','treatment_option_name') IS NULL
BEGIN
    RAISERROR('418_risk_treatment_task_optional: 261/263 objects are missing. Run 263 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- sp_risk_treatment_option_set -- 263's body + @raise_task
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_treatment_option_set
    @risk_register_id    BIGINT,
    @treatment_option_code NVARCHAR(30),
    @task_title          NVARCHAR(250) = NULL,
    @task_description    NVARCHAR(MAX) = NULL,
    @target_date         DATETIME2     = NULL,
    @remark              NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system',
    -- Same device, and the same reason, as sp_risk_analysis_save's
    -- @suppress_result (206): this procedure is called BOTH directly by
    -- the API -- which needs the result set -- and from inside
    -- sp_risk_residual_analysis_save and sp_risk_review_perform, which
    -- emit result sets of their own afterwards.
    --
    -- Without this, an inner call's SELECT becomes result set 1 of the
    -- OUTER procedure, and the caller reading "the first result set"
    -- gets the treatment dispatch instead of the residual score. That is
    -- not a hypothetical: it is why this parameter was added.
    @suppress_result     BIT           = 0,
    -- 418: 0 = record the decision WITHOUT raising the treatment task.
    -- The Risk Treatment page now asks "Generate a treatment task?" and
    -- sends 0 on No; the task can be added later with "Add treatment
    -- task" or "Map open task". Default 1 keeps every existing caller
    -- (review perform, residual save, the API before 418) unchanged.
    @raise_task          BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56564, 'sp_risk_treatment_option_set: risk_register_id is required.', 1;
    IF @treatment_option_code IS NULL OR LEN(LTRIM(RTRIM(@treatment_option_code))) = 0
        THROW 56565, 'sp_risk_treatment_option_set: a treatment option is required.', 1;

    SET @treatment_option_code = LTRIM(RTRIM(@treatment_option_code));

    IF @treatment_option_code NOT IN (N'Terminate', N'Treat', N'Transfer', N'Tolerate')
        THROW 56566, 'sp_risk_treatment_option_set: treatment option must be Terminate, Treat, Transfer or Tolerate.', 1;

    -- The label the user saw, frozen beside the code. One mapping, here,
    -- so the API and the UI never invent their own wording.
    DECLARE @option_name NVARCHAR(120) =
        CASE @treatment_option_code
             WHEN N'Terminate' THEN N'Terminate / Avoid'
             WHEN N'Treat'     THEN N'Treat / Reduce'
             WHEN N'Transfer'  THEN N'Transfer / Share'
             WHEN N'Tolerate'  THEN N'Tolerate / Accept'
        END;

    DECLARE @org_id BIGINT, @status NVARCHAR(30), @analysis_pending BIT,
            @analysis_id BIGINT, @prev_option NVARCHAR(30), @owner BIGINT;

    SELECT @org_id           = organization_id,
           @status           = status_code,
           @analysis_pending = analysis_pending,
           @analysis_id      = risk_analysis_id,
           @prev_option      = treatment_option_code,
           @owner            = risk_owner_employee_id
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56567, 'sp_risk_treatment_option_set: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56568, 'sp_risk_treatment_option_set: this risk is closed or retired -- reopen it before choosing a treatment option.', 1;

    -- A treatment decision is a response to a rating. Without one there
    -- is nothing to respond to, and the task's priority would be a
    -- guess dressed up as a derivation.
    IF ISNULL(@analysis_pending, 1) = 1
        THROW 56569, 'sp_risk_treatment_option_set: complete the risk analysis before choosing a treatment option.', 1;

    DECLARE @task_id BIGINT = NULL, @created BIT = 0,
            @new_status NVARCHAR(30) = @status;

    BEGIN TRY
        BEGIN TRAN;

        -- ---- 2a / 2b. Record the decision ----------------------------
        UPDATE grac_practice.risk_register
           SET treatment_option_code            = @treatment_option_code,
               treatment_option_name            = @option_name,
               treatment_decided_dt             = SYSUTCDATETIME(),
               treatment_decided_by_employee_id = @actor_employee_id,
               updated_by                       = @caller_display_name,
               updated_dt                       = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id;

        -- The current analysis version carries the option it concluded
        -- with. Guarded on the id because a custom risk registered before
        -- 216 can have a NULL analysis link.
        IF @analysis_id IS NOT NULL
            UPDATE grac_practice.risk_analysis
               SET treatment_option_code = @treatment_option_code,
                   treatment_option_name = @option_name,
                   updated_by            = @caller_display_name,
                   updated_dt            = SYSUTCDATETIME()
             WHERE risk_analysis_id = @analysis_id;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    -- ---- 2c. Dispatch ------------------------------------------------
    -- Outside the transaction above on purpose. sp_task_open runs its
    -- own transaction and calls the owner ladder; nesting it under a
    -- Risk Centre transaction would hold Task Centre locks for the
    -- duration of a Risk Centre write. The decision is already durable
    -- if the task raise fails, and the failure is reported -- which is
    -- the right split: the decision was made, the work was not raised,
    -- and the operator can see exactly that.
    IF @treatment_option_code IN (N'Terminate', N'Treat', N'Transfer')
    BEGIN
        IF ISNULL(@raise_task, 1) = 1
        EXEC grac_practice.sp_risk_treatment_task_ensure
             @risk_register_id    = @risk_register_id,
             @task_title          = @task_title,
             @task_description    = @task_description,
             @target_date         = @target_date,
             @actor_employee_id   = @actor_employee_id,
             @caller_display_name = @caller_display_name,
             @task_id             = @task_id OUTPUT,
             @created             = @created OUTPUT;

        -- Only Active moves. A risk already Monitoring or Accepted that
        -- gains new treatment work goes back to UnderTreatment; one that
        -- is already UnderTreatment stays put.
        -- 418: also when the task is declined. The decision IS treatment;
        -- the task is added afterwards from the same page, and
        -- sp_risk_treatment_sync never moves a risk with no task to
        -- Monitoring (its EXISTS clause), so the risk waits here.
        IF @status <> N'UnderTreatment'
            SET @new_status = N'UnderTreatment';
    END

    BEGIN TRY
        BEGIN TRAN;

        IF @new_status <> @status
            UPDATE grac_practice.risk_register
               SET status_code = @new_status,
                   updated_by  = @caller_display_name,
                   updated_dt  = SYSUTCDATETIME()
             WHERE risk_register_id = @risk_register_id;

        -- ---- 2d. BRD s20 ------------------------------------------------
        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'TreatmentDecided', @status, @new_status,
             CONCAT(N'Treatment option ', @option_name,
                    CASE WHEN @prev_option IS NULL THEN N' chosen.'
                         WHEN @prev_option = @treatment_option_code THEN N' re-confirmed.'
                         ELSE CONCAT(N' chosen (was ', @prev_option, N').') END,
                    CASE WHEN @treatment_option_code = N'Tolerate'
                         THEN N' No treatment task raised -- proceed to Risk Acceptance.'
                         WHEN ISNULL(@raise_task, 1) = 0
                         THEN N' Treatment task not generated (declined) -- add one from Risk Treatment.'
                         WHEN @created = 1
                         THEN CONCAT(N' Treatment task ', CAST(@task_id AS NVARCHAR(20)),
                                     N' raised, owned by the risk owner.')
                         ELSE CONCAT(N' Treatment task ', ISNULL(CAST(@task_id AS NVARCHAR(20)), N'?'),
                                     N' already open -- not duplicated.') END,
                    CASE WHEN @remark IS NULL THEN N''
                         ELSE CONCAT(N' ', @remark) END),
             @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    IF ISNULL(@suppress_result, 0) = 0
        SELECT @risk_register_id      AS RiskRegisterId,
               @treatment_option_code AS TreatmentOptionCode,
               @option_name           AS TreatmentOptionName,
               @task_id               AS TreatmentTaskId,
               @created               AS TaskCreated,
               @new_status            AS StatusCode,
               -- What the client should do next. Computed here so the
               -- flow has one definition rather than one per screen.
               CASE WHEN @treatment_option_code = N'Tolerate'
                    THEN N'Acceptance' ELSE N'Treatment' END AS NextStep;
END;
GO

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
SELECT '418-a sp_risk_treatment_option_set has @raise_task' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_treatment_option_set')
                            AND name = '@raise_task')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
PRINT '418 complete.';
GO
SET NOEXEC OFF;
GO
