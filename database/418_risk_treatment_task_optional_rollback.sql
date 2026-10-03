-- =====================================================================
-- 418 ROLLBACK -- restores 263's sp_risk_treatment_option_set (no
-- @raise_task; the treatment task is always raised for Terminate /
-- Treat / Transfer). Body verbatim from 263 (the section-sign in one
-- comment written as "BRD s" to keep this file ASCII).
-- Roll back the Api + Web first: the 418 Api only sends @raise_task when
-- the procedure declares it, so it also runs against this.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_risk_treatment_task_ensure','P') IS NULL
BEGIN
    RAISERROR('418 rollback: sp_risk_treatment_task_ensure (263) is missing.', 16, 1);
    SET NOEXEC ON;
END
GO

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
    @suppress_result     BIT           = 0
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

SELECT '418 rollback: @raise_task removed' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.parameters
                              WHERE object_id = OBJECT_ID('grac_practice.sp_risk_treatment_option_set')
                                AND name = '@raise_task')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
SET NOEXEC OFF;
GO
