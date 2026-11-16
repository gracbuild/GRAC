-- =====================================================================
-- 498  Exception designated approver (submit-for-approval + enforcement)
--
-- Change request 2026-10-27 (sir): when an exception (from gap analysis)
-- is Submitted for Approval, the submitter must pick WHO approves it, and
-- only employees whose role holds Approve on the Exceptions & Waivers menu
-- may be chosen. Only that designated approver can later approve the
-- request (strict -- no admin override; enforced in the Api approve path
-- which reads designated_approver_employee_id).
--
-- This migration:
--   1. adds exception_request.designated_approver_employee_id (FK),
--   2. sp_exception_approver_candidates -- the eligible-approver picker list,
--   3. re-issues sp_exception_request_submit_for_approval (260 body) to
--      require + validate + store the approver,
--   4. re-issues sp_exception_request_list (472) and sp_exception_request_get
--      (327) to return DesignatedApproverEmployeeId / Name so the UI can
--      show Approve only to the designated approver.
--
-- Idempotent. ASCII only.
--
-- DEPENDS ON, and now checks: 162 (exception_request), 166, 184, 192,
-- 260, 327, 470, 472. The prerequisite block below enforces it -- see
-- the note there for why it has to.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- =====================================================================
-- Prerequisites -- every column the four procedure bodies below READ
-- =====================================================================
-- A re-issued procedure body is validated against the live columns when
-- it is created, so one missing column fails that single CREATE with
-- Msg 207 and leaves the OLD body deployed -- while the rest of the
-- script carries on and still PRINTs its success. The run then reads as
-- complete and is not.
--
-- That happened on production on 2026-11-02: migration 470 had never
-- been applied, exception_request.exception_number did not exist, the
-- CREATE OR ALTER of sp_exception_request_list failed, and the script
-- still printed "498 complete". The list procedure silently kept its
-- 472 body, without DesignatedApproverEmployeeId / Name -- which is the
-- one thing the UI needs to decide who may approve.
--
-- Checked here instead, before anything is written, naming the migration
-- that owns each missing column rather than adding it inline: the owning
-- migration also seeds, backfills and updates its matching save path,
-- and half-applying it would leave a field on screen that cannot persist.
DECLARE @missing NVARCHAR(MAX) = NULL;

SELECT @missing = STRING_AGG(x.col + N' (migration ' + x.mig + N')', N', ')
FROM (VALUES
    (N'exception_type_id',         N'166'),
    (N'owner_employee_id',         N'166'),
    (N'review_frequency_id',       N'166'),
    (N'justification',             N'166'),
    (N'risk_impact',               N'166'),
    (N'compensating_control',      N'166'),
    (N'effective_from',            N'166'),
    (N'linked_practice_id',        N'166'),
    (N'linked_requirement_ref',    N'166'),
    (N'request_type_code',         N'184'),
    (N'sla_days_original',         N'184'),
    (N'sla_days_requested',        N'184'),
    (N'task_id',                   N'192'),
    (N'due_at_original',           N'192'),
    (N'due_at_requested',          N'192'),
    (N'priority_original',         N'192'),
    (N'priority_requested',        N'192'),
    (N'proposed_effective_from',   N'260'),
    (N'proposed_effective_until',  N'260'),
    (N'exception_number',          N'470')
) AS x(col, mig)
WHERE NOT EXISTS (
    SELECT 1 FROM sys.columns c
     WHERE c.object_id = OBJECT_ID('grac_practice.exception_request')
       AND c.name = x.col);

IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN
    PRINT 'ABORT (498): grac_practice.exception_request does not exist. Run 162 first. Nothing was changed.';
    SET NOEXEC ON;
END
ELSE IF @missing IS NOT NULL
BEGIN
    PRINT 'ABORT (498): exception_request is missing column(s) that this migration''s procedure bodies read: '
          + @missing
          + '. Run the migration named beside each, in number order, then re-run 498. Nothing was changed.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.exception_request','designated_approver_employee_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.exception_request
        ADD designated_approver_employee_id BIGINT NULL;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_exception_request_designated_approver')
   AND COL_LENGTH('grac_practice.exception_request','designated_approver_employee_id') IS NOT NULL
    ALTER TABLE grac_practice.exception_request
        ADD CONSTRAINT fk_pm_exception_request_designated_approver
        FOREIGN KEY (designated_approver_employee_id)
        REFERENCES grac_practice.organization_employee(employee_id);
GO

-- ---------------------------------------------------------------------
-- Eligible approvers: active employees of the org whose role holds
-- Approve (can_approve) on the Exceptions & Waivers menu.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_approver_candidates
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 55295, 'sp_exception_approver_candidates: organization_id is required.', 1;

    SELECT DISTINCT
           e.employee_id   AS EmployeeId,
           e.employee_name AS EmployeeName,
           e.employee_code AS EmployeeCode
      FROM grac_practice.organization_employee e
      JOIN grac_practice.organization_role_menu_permission p
            ON p.role_id = e.role_id AND p.can_approve = 1 AND p.status = N'Active'
      JOIN grac_practice.menu_master m
            ON m.menu_id = p.menu_id AND m.menu_key = N'exception-centre'
     WHERE e.organization_id = @organization_id
       AND e.status = N'Active'
       AND e.role_id IS NOT NULL
     ORDER BY e.employee_name;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_submit_for_approval
    @exception_request_id BIGINT,
    @actor_employee_id    BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system',
    -- 498: the mandatory designated approver -- only this employee may
    -- later approve this exception (enforced in the Api approve path).
    @designated_approver_employee_id BIGINT = NULL
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

    -- 498: a designated approver is mandatory and must be an active employee
    -- of this request's organisation whose role holds Approve on the
    -- Exceptions & Waivers menu.
    IF @designated_approver_employee_id IS NULL
        THROW 55288, 'sp_exception_request_submit_for_approval: a designated approver is required.', 1;
    DECLARE @req_org BIGINT = (SELECT organization_id FROM grac_practice.exception_request
                                WHERE exception_request_id = @exception_request_id);
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_employee e
          JOIN grac_practice.organization_role_menu_permission p
                ON p.role_id = e.role_id AND p.can_approve = 1 AND p.status = N'Active'
          JOIN grac_practice.menu_master m
                ON m.menu_id = p.menu_id AND m.menu_key = N'exception-centre'
         WHERE e.employee_id = @designated_approver_employee_id
           AND e.organization_id = @req_org
           AND e.status = N'Active' AND e.role_id IS NOT NULL)
        THROW 55289, 'sp_exception_request_submit_for_approval: the selected approver does not have Exception approval permission in this organisation.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.exception_request
           SET status_code = N'SubmittedForApproval',
               designated_approver_employee_id = @designated_approver_employee_id,
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
        r.designated_approver_employee_id AS DesignatedApproverEmployeeId,
        da.employee_name        AS DesignatedApproverName,
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
 LEFT JOIN grac_practice.organization_employee     da ON da.employee_id       = r.designated_approver_employee_id
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
        r.designated_approver_employee_id AS DesignatedApproverEmployeeId,
        da.employee_name             AS DesignatedApproverName,
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
 LEFT JOIN grac_practice.organization_employee da ON da.employee_id = r.designated_approver_employee_id
 LEFT JOIN grac_practice.organization_employee   ap ON ap.employee_id       = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee   rj ON rj.employee_id       = r.rejected_by_employee_id
 LEFT JOIN grac_practice.frequency_master        fm ON fm.frequency_id      = r.review_frequency_id
     WHERE r.exception_request_id = @exception_request_id;
END
GO


PRINT '498 complete: designated approver added; submit/list/get re-issued; candidates proc ready.';
GO
-- Clears the guard above so an aborted run does not leave the session in
-- NOEXEC, silently swallowing whatever the operator runs next.
SET NOEXEC OFF;
GO
