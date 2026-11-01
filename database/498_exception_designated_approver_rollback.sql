-- =====================================================================
-- 498 ROLLBACK -- restore 260/472/327 bodies, drop candidates proc,
-- drop designated_approver_employee_id (and its FK).
-- =====================================================================
SET NOCOUNT ON;
GO
DROP PROCEDURE IF EXISTS grac_practice.sp_exception_approver_candidates;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_submit_for_approval
    @exception_request_id BIGINT,
    @actor_employee_id    BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @exception_request_id IS NULL
        THROW 55265, 'sp_exception_request_submit_for_approval: exception_request_id is required.', 1;

    DECLARE @current NVARCHAR(30), @just NVARCHAR(MAX), @risk NVARCHAR(MAX),
            @prop_from DATE, @prop_until DATE;
    SELECT @current    = status_code,
           @just       = justification,
           @risk       = risk_impact,
           @prop_from  = proposed_effective_from,
           @prop_until = proposed_effective_until
      FROM grac_practice.exception_request
     WHERE exception_request_id = @exception_request_id;

    IF @current IS NULL
        THROW 55266, 'sp_exception_request_submit_for_approval: request not found.', 1;
    IF @current <> N'Pending'
        THROW 55267, 'sp_exception_request_submit_for_approval: only a Pending request can be submitted for approval.', 1;
    IF @just IS NULL OR LEN(LTRIM(RTRIM(@just))) = 0
        THROW 55268, 'sp_exception_request_submit_for_approval: justification is required before submitting for approval.', 1;
    IF @risk IS NULL OR LEN(LTRIM(RTRIM(@risk))) = 0
        THROW 55269, 'sp_exception_request_submit_for_approval: risk / impact is required before submitting for approval.', 1;
    IF @prop_from IS NULL OR @prop_until IS NULL
        THROW 55286, 'sp_exception_request_submit_for_approval: effective from and effective to are required before submitting for approval.', 1;
    IF @prop_from > @prop_until
        THROW 55287, 'sp_exception_request_submit_for_approval: effective from must be on or before effective to.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.exception_request
           SET status_code = N'SubmittedForApproval',
               updated_by  = @caller_display_name,
               updated_dt  = SYSUTCDATETIME()
         WHERE exception_request_id = @exception_request_id;

        INSERT INTO grac_practice.exception_request_history
            (exception_request_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@exception_request_id, N'SubmitForApproval', N'Pending', N'SubmittedForApproval',
             CONCAT(N'Analysis completed and submitted for approval. Proposed window ',
                    CONVERT(NVARCHAR(10), @prop_from, 23), N' -> ',
                    CONVERT(NVARCHAR(10), @prop_until, 23), N'.'),
             @actor_employee_id, @caller_display_name, @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @exception_request_id AS ExceptionRequestId,
           CAST(1 AS BIT)        AS Success,
           N'Submitted for approval.' AS Message;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_list
    @organization_id   BIGINT,
    @status_code       NVARCHAR(30) = NULL,
    @request_type_code NVARCHAR(30) = NULL,
    @page_number       INT = 1,
    @page_size         INT = 25,
    @drill_code        NVARCHAR(20) = NULL,
    @min_age_days      INT          = NULL,
    @max_age_days      INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 55210, 'sp_exception_request_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        r.exception_request_id  AS ExceptionRequestId,
        r.exception_number      AS ExceptionNumber,   -- 470/472
        r.organization_id       AS OrganizationId,
        r.custom_gap_id         AS CustomGapId,
        g.title                 AS GapTitle,
        r.task_id               AS TaskId,
        t.task_number           AS TaskNumber,
        t.subject_title         AS TaskTitle,
        r.request_title         AS RequestTitle,
        et.exception_type_name  AS ExceptionTypeName,
        r.status_code           AS StatusCode,
        r.request_type_code     AS RequestTypeCode,
        r.sla_days_original     AS SlaDaysOriginal,
        r.sla_days_requested    AS SlaDaysRequested,
        r.due_at_original       AS DueAtOriginal,
        r.due_at_requested      AS DueAtRequested,
        r.priority_original     AS PriorityOriginal,
        r.priority_requested    AS PriorityRequested,
        r.requested_dt          AS RequestedOn,
        rq.employee_name        AS RequestedByName,
        r.approved_dt           AS ApprovedOn,
        ap.employee_name        AS ApprovedByName,
        r.effective_from        AS EffectiveFrom,
        r.effective_until       AS EffectiveUntil,
        r.rejected_dt           AS RejectedOn,
        rj.employee_name        AS RejectedByName,
        (SELECT COUNT(*) FROM grac_practice.exception_request_attachment a
          WHERE a.exception_request_id = r.exception_request_id) AS AttachmentCount,
        COUNT(*) OVER () AS TotalRows
      FROM grac_practice.exception_request r
 LEFT JOIN grac_practice.custom_gap                g  ON g.custom_gap_id     = r.custom_gap_id
 LEFT JOIN grac_practice.practice_task             t  ON t.task_id           = r.task_id
 LEFT JOIN grac_practice.exception_type_master     et ON et.exception_type_id = r.exception_type_id
 LEFT JOIN grac_practice.organization_employee     rq ON rq.employee_id       = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee     ap ON ap.employee_id       = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee     rj ON rj.employee_id       = r.rejected_by_employee_id
      JOIN grac_practice.vw_pm_exception_request_state xs ON xs.exception_request_id = r.exception_request_id
     WHERE r.organization_id = @organization_id
       AND (@status_code IS NULL OR r.status_code = @status_code)
       AND (@request_type_code IS NULL OR r.request_type_code = @request_type_code)
       AND (NULLIF(@drill_code, N'') IS NULL
            OR (@drill_code = N'open'    AND xs.is_open   = 1)
            OR (@drill_code = N'lapsed'  AND xs.is_lapsed = 1)
            OR (@drill_code = N'noowner' AND xs.is_open   = 1 AND xs.owner_employee_id IS NULL))
       AND (@min_age_days IS NULL OR xs.age_days >= @min_age_days)
       AND (@max_age_days IS NULL OR xs.age_days <= @max_age_days)
     ORDER BY r.requested_dt DESC, r.exception_request_id DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_get
    @exception_request_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55220, 'sp_exception_request_get: exception_request_id is required.', 1;

    SELECT
        r.exception_request_id       AS ExceptionRequestId,
        r.organization_id            AS OrganizationId,
        r.custom_gap_id              AS CustomGapId,
        g.title                      AS GapTitle,
        r.request_title              AS RequestTitle,
        r.request_reason             AS RequestReason,
        r.justification              AS Justification,
        r.risk_impact                AS RiskImpact,
        et.exception_type_code       AS ExceptionTypeCode,
        et.exception_type_name       AS ExceptionTypeName,
        r.owner_employee_id          AS OwnerEmployeeId,
        ow.employee_name             AS OwnerName,
        r.linked_practice_id         AS LinkedPracticeId,
        r.linked_requirement_ref     AS LinkedRequirementRef,
        r.status_code                AS StatusCode,
        -- 327: so the UI can render "Source: Custom Exception" the same
        -- way exception-centre.js already reads this column for its
        -- Type filter and row-menu gating.
        r.request_type_code          AS RequestTypeCode,
        r.requested_by_employee_id   AS RequestedByEmployeeId,
        rq.employee_name             AS RequestedByName,
        r.requested_dt               AS RequestedOn,
        r.proposed_effective_from    AS ProposedEffectiveFrom,
        r.proposed_effective_until   AS ProposedEffectiveUntil,
        r.approved_by_employee_id    AS ApprovedByEmployeeId,
        ap.employee_name             AS ApprovedByName,
        r.approved_dt                AS ApprovedOn,
        r.effective_from             AS EffectiveFrom,
        r.effective_until            AS EffectiveUntil,
        r.approval_note              AS ApprovalNote,
        r.compensating_control       AS CompensatingControl,
        r.review_frequency_id        AS ReviewFrequencyId,
        fm.frequency_name            AS ReviewFrequencyName,
        r.rejected_by_employee_id    AS RejectedByEmployeeId,
        rj.employee_name             AS RejectedByName,
        r.rejected_dt                AS RejectedOn,
        r.rejection_reason           AS RejectionReason
      FROM grac_practice.exception_request r
      -- 327: was INNER JOIN. A CUSTOM (or task-side) request has no gap
      -- at all -- g.title simply comes back NULL for one, same as every
      -- other optional fact here.
 LEFT JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.exception_type_master   et ON et.exception_type_id = r.exception_type_id
 LEFT JOIN grac_practice.organization_employee   ow ON ow.employee_id       = r.owner_employee_id
 LEFT JOIN grac_practice.organization_employee   rq ON rq.employee_id       = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee   ap ON ap.employee_id       = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee   rj ON rj.employee_id       = r.rejected_by_employee_id
 LEFT JOIN grac_practice.frequency_master        fm ON fm.frequency_id      = r.review_frequency_id
     WHERE r.exception_request_id = @exception_request_id;
END
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_exception_request_designated_approver')
    ALTER TABLE grac_practice.exception_request DROP CONSTRAINT fk_pm_exception_request_designated_approver;
GO
IF COL_LENGTH('grac_practice.exception_request','designated_approver_employee_id') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN designated_approver_employee_id;
GO
PRINT '498 rollback complete.';
GO
