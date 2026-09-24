-- =====================================================================
-- 293_risk_review_frequency_rollback.sql
--
-- Reverts 293:
--   1. Restores sp_risk_acceptance_save verbatim from 264.
--   2. Restores sp_risk_acceptance_get verbatim from 291 (NOT 264 --
--      291 owns AcceptedByRoleNames, and restoring 264's text here
--      would silently drop it).
--   3. Drops sp_risk_review_frequency_list.
--   4. Drops the FK, then the column.
--
-- ORDER MATTERS: the procedures stop referencing review_frequency_id
-- before the column is dropped.
--
-- DATA LOSS: dropping the column discards every recorded cadence.
-- next_review_date is untouched, so nothing about when risks come back
-- changes -- only the record of what the date was derived from.
--
-- Re-runnable: yes. ASCII-only (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_acceptance_save
    @risk_register_id        BIGINT,
    @next_review_date        DATE,
    @accepted_by_employee_id BIGINT        = NULL,
    @accepted_date           DATE          = NULL,   -- NULL = today
    @acceptance_note         NVARCHAR(MAX) = NULL,
    @actor_employee_id       BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56600, 'sp_risk_acceptance_save: risk_register_id is required.', 1;

    -- Validation case 10. See the header for why this is a THROW.
    IF @next_review_date IS NULL
        THROW 56601, 'sp_risk_acceptance_save: a next review date is required. Without one this risk would never return for review.', 1;

    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF @next_review_date <= @today
        THROW 56602, 'sp_risk_acceptance_save: the next review date must be in the future.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30), @analysis_pending BIT,
            @option_code NVARCHAR(30), @residual_pending BIT,
            @owner BIGINT, @risk_number NVARCHAR(60);

    SELECT @org_id           = organization_id,
           @status           = status_code,
           @analysis_pending = analysis_pending,
           @option_code      = treatment_option_code,
           @residual_pending = residual_pending,
           @owner            = risk_owner_employee_id,
           @risk_number      = risk_number
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56603, 'sp_risk_acceptance_save: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56604, 'sp_risk_acceptance_save: this risk is closed or retired -- reopen it before accepting it.', 1;

    -- Accepting a risk nobody has scored is accepting an unknown
    -- quantity. section 19's whole apparatus exists to make the rating
    -- trustworthy before decisions rest on it.
    IF ISNULL(@analysis_pending, 1) = 1
        THROW 56605, 'sp_risk_acceptance_save: complete the risk analysis before accepting this risk.', 1;

    -- A treatment decision must exist. Acceptance is the endpoint of two
    -- routes -- Tolerate, or treatment-then-residual -- and a risk that
    -- has taken neither has not reached it.
    IF @option_code IS NULL
        THROW 56606, 'sp_risk_acceptance_save: choose a treatment option before accepting this risk.', 1;

    DECLARE @accept_by BIGINT = COALESCE(@accepted_by_employee_id, @owner, @actor_employee_id);
    DECLARE @accept_name NVARCHAR(240) = NULL;

    IF @accept_by IS NOT NULL
    BEGIN
        DECLARE @emp_org BIGINT;
        SELECT @emp_org = organization_id, @accept_name = employee_name
          FROM grac_practice.organization_employee
         WHERE employee_id = @accept_by;

        IF @emp_org IS NULL
            THROW 56607, 'sp_risk_acceptance_save: the accepting employee was not found.', 1;
        IF @emp_org <> @org_id
            THROW 56608, 'sp_risk_acceptance_save: the accepting employee belongs to a different organisation.', 1;
    END

    DECLARE @accepted_on DATETIME2 =
        CASE WHEN @accepted_date IS NULL THEN SYSUTCDATETIME()
             ELSE CAST(@accepted_date AS DATETIME2) END;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_register
           SET accepted_by_employee_id = @accept_by,
               accepted_by_name        = @accept_name,
               accepted_dt             = @accepted_on,
               acceptance_note         = @acceptance_note,
               next_review_date        = @next_review_date,
               status_code             = N'Accepted',
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id;

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'RiskAccepted', @status, N'Accepted',
             CONCAT(N'Risk accepted by ', ISNULL(@accept_name, N'(unnamed)'),
                    N' on ', CONVERT(NVARCHAR(10), @accepted_on, 23),
                    N'. Next review ', CONVERT(NVARCHAR(10), @next_review_date, 23), N'.',
                    CASE WHEN @option_code = N'Tolerate'
                         THEN N' Route: Tolerate / Accept (no treatment work).'
                         WHEN ISNULL(@residual_pending, 1) = 0
                         THEN N' Route: treated, residual assessed.'
                         ELSE N' Route: treated.' END,
                    CASE WHEN @acceptance_note IS NULL THEN N''
                         ELSE CONCAT(N' ', @acceptance_note) END),
             @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_register_id AS RiskRegisterId,
           @risk_number      AS RiskNumber,
           @accept_by        AS AcceptedByEmployeeId,
           @accept_name      AS AcceptedByName,
           @accepted_on      AS AcceptedOn,
           @next_review_date AS NextReviewDate,
           N'Accepted'       AS StatusCode;
END;
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
           -- THE ONLY ADDITION IN 291. Separate from AcceptedByName on
           -- purpose: the name stays exactly what it was, and the UI
           -- composes "Name - Role" for display only. NULL when the
           -- acceptor holds no active role, or when acceptance recorded
           -- only a free-text name with no employee row behind it.
           grac_practice.fn_employee_role_names(r.accepted_by_employee_id)
                                     AS AcceptedByRoleNames,
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

IF OBJECT_ID('grac_practice.sp_risk_review_frequency_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_risk_review_frequency_list;
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_risk_register_review_frequency')
    ALTER TABLE grac_practice.risk_register DROP CONSTRAINT fk_pm_risk_register_review_frequency;
GO

IF COL_LENGTH('grac_practice.risk_register','review_frequency_id') IS NOT NULL
    ALTER TABLE grac_practice.risk_register DROP COLUMN review_frequency_id;
GO

PRINT '293 rollback: review_frequency_id removed; acceptance procs restored (get from 291).';
GO
