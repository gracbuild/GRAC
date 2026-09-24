-- =====================================================================
-- 260 Exception Centre: analyst-proposed effective dates
--
-- Sir's specification:
--
--   * The ANALYSIS page captures Effective From and Effective To.
--   * SUBMIT FOR APPROVAL refuses an analysis that has not set them --
--     an approver should never have to invent the window himself.
--   * The APPROVAL form DISPLAYS what the analyst proposed and lets the
--     approver CHANGE it.
--   * A change must be TRACEABLE: who moved the window, from what, to
--     what, and when.
--
-- WHY TWO NEW COLUMNS AND NOT effective_from / effective_until.
-- Those two are the APPROVED window -- they are written by
-- sp_exception_request_approve, they drive the "days left" badge, the
-- Expire-due sweep and the gap's own extension. Writing an analyst's
-- proposal into them would make an un-approved request look approved to
-- every one of those readers. The proposal is a separate fact with a
-- separate lifetime, so it gets its own pair.
--
-- WHY NO NEW AUDIT TABLE. exception_request_history (161) already
-- records action_code / from_status / to_status / remark / actor, and is
-- already written by create, approve, reject, withdraw and submit. A
-- second table for one more kind of change would be a second place to
-- look for the same question. The date change is one more action_code:
-- 'EffectiveDatesChanged'.
--
-- WHAT THIS MIGRATION DOES
--
--   1. exception_request gains proposed_effective_from / _until
--   2. sp_exception_request_analysis_save   -- captures the proposal
--   3. sp_exception_request_submit_for_approval -- requires it
--   4. sp_exception_request_get             -- returns it
--   5. sp_exception_request_approve         -- defaults from it, and
--                                              records any change
--   6. sp_exception_request_history_list    -- NEW, so the UI can show
--                                              the trail
--
-- BODIES RE-EMITTED FROM THEIR LIVE ANCESTORS, deliberately:
--     analysis_save         -> 257
--     submit_for_approval   -> 257
--     get                   -> 166
--     approve               -> 257
-- Nothing else in any body changes. Each is CREATE OR ALTER, so a
-- re-run is a no-op rather than a duplicate.
--
-- SAFE TO RE-RUN. Requires 161, 166, 257.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (260): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN PRINT 'ABORT (260): exception_request missing (run 161 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.exception_request_history','U') IS NULL
BEGIN PRINT 'ABORT (260): exception_request_history missing (run 161 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_exception_request_submit_for_approval','P') IS NULL
BEGIN PRINT 'ABORT (260): the analysis stage is missing (run 257 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('260_exception_proposed_effective_dates: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Columns
--
-- Nullable on purpose. Every request that already exists was analysed
-- (or decided) before this migration and has no proposal; a NOT NULL
-- column would need a fabricated default, and a fabricated exception
-- window is exactly the thing the approver is supposed to judge.
-- =====================================================================
IF COL_LENGTH('grac_practice.exception_request','proposed_effective_from') IS NULL
BEGIN
    ALTER TABLE grac_practice.exception_request ADD proposed_effective_from DATE NULL;
    PRINT '260: exception_request.proposed_effective_from added.';
END
ELSE
    PRINT '260: exception_request.proposed_effective_from already present.';
GO

IF COL_LENGTH('grac_practice.exception_request','proposed_effective_until') IS NULL
BEGIN
    ALTER TABLE grac_practice.exception_request ADD proposed_effective_until DATE NULL;
    PRINT '260: exception_request.proposed_effective_until added.';
END
ELSE
    PRINT '260: exception_request.proposed_effective_until already present.';
GO

-- =====================================================================
-- 2. sp_exception_request_analysis_save   (257's body + the proposal)
--
-- The two dates are COALESCE-preserved like every other field here, so
-- a partial save from an older caller cannot blank a proposal that was
-- already made.
--
-- WHY THE ORDER CHECK READS THE STORED ROW. The analyst may send only
-- one of the two on a given save. Validating the pair as sent would let
-- a later save of From alone slide past an earlier Until, so the check
-- is made against the values the row will actually hold.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_analysis_save
    @exception_request_id     BIGINT,
    @exception_type_code      NVARCHAR(60)  = NULL,
    @justification            NVARCHAR(MAX) = NULL,
    @risk_impact              NVARCHAR(MAX) = NULL,
    @owner_employee_id        BIGINT        = NULL,
    @proposed_effective_from  DATE          = NULL,
    @proposed_effective_until DATE          = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @exception_request_id IS NULL
        THROW 55260, 'sp_exception_request_analysis_save: exception_request_id is required.', 1;

    DECLARE @current NVARCHAR(30), @cur_from DATE, @cur_until DATE;
    SELECT @current   = status_code,
           @cur_from  = proposed_effective_from,
           @cur_until = proposed_effective_until
      FROM grac_practice.exception_request
     WHERE exception_request_id = @exception_request_id;

    IF @current IS NULL
        THROW 55261, 'sp_exception_request_analysis_save: request not found.', 1;
    IF @current NOT IN (N'Pending', N'SubmittedForApproval')
        THROW 55262, 'sp_exception_request_analysis_save: analysis applies to a Pending or SubmittedForApproval request only.', 1;

    DECLARE @new_from  DATE = COALESCE(@proposed_effective_from,  @cur_from);
    DECLARE @new_until DATE = COALESCE(@proposed_effective_until, @cur_until);
    IF @new_from IS NOT NULL AND @new_until IS NOT NULL AND @new_from > @new_until
        THROW 55285, 'sp_exception_request_analysis_save: effective from must be on or before effective to.', 1;

    DECLARE @type_id INT = NULL;
    IF @exception_type_code IS NOT NULL AND LEN(LTRIM(RTRIM(@exception_type_code))) > 0
    BEGIN
        SELECT @type_id = exception_type_id
          FROM grac_practice.exception_type_master
         WHERE exception_type_code = @exception_type_code;
        IF @type_id IS NULL
            THROW 55263, 'sp_exception_request_analysis_save: unknown exception_type_code.', 1;
    END

    UPDATE grac_practice.exception_request
       SET exception_type_id        = COALESCE(@type_id,            exception_type_id),
           justification            = COALESCE(@justification,      justification),
           risk_impact              = COALESCE(@risk_impact,        risk_impact),
           owner_employee_id        = COALESCE(@owner_employee_id,  owner_employee_id),
           proposed_effective_from  = @new_from,
           proposed_effective_until = @new_until,
           updated_by               = @caller_display_name,
           updated_dt               = SYSUTCDATETIME()
     WHERE exception_request_id = @exception_request_id;

    SELECT @exception_request_id AS ExceptionRequestId,
           CAST(1 AS BIT)        AS Success,
           N'Analysis saved.'    AS Message;
END
GO
PRINT '260: sp_exception_request_analysis_save now captures the proposed window.';
GO

-- =====================================================================
-- 3. sp_exception_request_submit_for_approval   (257's body + the gate)
--
-- Same reasoning as 257's justification / risk checks: the questions an
-- approver cannot answer for himself must be answered before the button
-- forwards anything. "For how long" is one of them.
-- =====================================================================
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
PRINT '260: sp_exception_request_submit_for_approval now requires the proposed window.';
GO

-- =====================================================================
-- 4. sp_exception_request_get   (166's body + the two columns)
--
-- The approval form reads this to pre-fill its date inputs, and the
-- analysis page reads it to re-open a saved proposal.
-- =====================================================================
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
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.exception_type_master   et ON et.exception_type_id = r.exception_type_id
 LEFT JOIN grac_practice.organization_employee   ow ON ow.employee_id       = r.owner_employee_id
 LEFT JOIN grac_practice.organization_employee   rq ON rq.employee_id       = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee   ap ON ap.employee_id       = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee   rj ON rj.employee_id       = r.rejected_by_employee_id
 LEFT JOIN grac_practice.frequency_master        fm ON fm.frequency_id      = r.review_frequency_id
     WHERE r.exception_request_id = @exception_request_id;
END
GO
PRINT '260: sp_exception_request_get now returns the proposed window.';
GO

-- =====================================================================
-- 5. sp_exception_request_approve   (257's body + defaulting + trail)
--
-- TWO CHANGES, both small:
--
--   a) effective_from falls back to the PROPOSAL before it falls back to
--      today. 257 defaulted a blank From to SYSUTCDATETIME(), which
--      quietly overrode a window the analyst had already justified.
--
--   b) if the approved window differs from the proposed one, a second
--      history row records the move. It is a separate row from 'Approve'
--      on purpose: the approval is one fact, overruling the analyst is
--      another, and a reader looking for "who shortened this" should not
--      have to parse it out of an approval note.
--
-- The gate, the field preservation and the result-set shape are 257's,
-- unchanged -- the service binds those names.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_approve
    @exception_request_id    BIGINT,
    @effective_until         DATE,
    @approval_note           NVARCHAR(MAX),
    @approved_by_employee_id BIGINT,
    @effective_from          DATE           = NULL,
    @compensating_control    NVARCHAR(MAX)  = NULL,
    @review_frequency_id     INT            = NULL,
    -- Request-level fields. The analysis page owns these now; the
    -- parameters stay so an older caller still binds, and every one is
    -- COALESCE-preserved as before.
    @exception_type_code     NVARCHAR(60)   = NULL,
    @justification           NVARCHAR(MAX)  = NULL,
    @risk_impact             NVARCHAR(MAX)  = NULL,
    @owner_employee_id       BIGINT         = NULL,
    @linked_practice_id      BIGINT         = NULL,
    @linked_requirement_ref  NVARCHAR(200)  = NULL,
    @caller_display_name     NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55230, 'sp_exception_request_approve: exception_request_id is required.', 1;
    IF @effective_until IS NULL
        THROW 55231, 'sp_exception_request_approve: effective_until date is required.', 1;
    IF @approval_note IS NULL OR LEN(LTRIM(RTRIM(@approval_note))) = 0
        THROW 55232, 'sp_exception_request_approve: approval_note is required.', 1;
    IF @approved_by_employee_id IS NULL
        THROW 55233, 'sp_exception_request_approve: approved_by_employee_id is required.', 1;
    IF @effective_from IS NOT NULL AND @effective_from > @effective_until
        THROW 55236, 'sp_exception_request_approve: effective_from must be on or before effective_until.', 1;

    DECLARE @current NVARCHAR(30), @req_type NVARCHAR(30),
            @prop_from DATE, @prop_until DATE;
    SELECT @current    = status_code,
           @req_type   = request_type_code,
           @prop_from  = proposed_effective_from,
           @prop_until = proposed_effective_until
      FROM grac_practice.exception_request WHERE exception_request_id = @exception_request_id;
    IF @current IS NULL
        THROW 55234, 'sp_exception_request_approve: request not found.', 1;

    -- 257: the gate depends on the request type.
    DECLARE @required_status NVARCHAR(30) =
        CASE WHEN @req_type IN (N'TASK_SLA_EXTENSION', N'TASK_PRIORITY_REDUCTION')
             THEN N'Pending' ELSE N'SubmittedForApproval' END;

    IF @current <> @required_status
    BEGIN
        DECLARE @msg NVARCHAR(400) =
            CONCAT(N'sp_exception_request_approve: this request must be ', @required_status,
                   N' to be approved (current: ', @current,
                   N'). Complete the analysis and submit it for approval first.');
        THROW 55235, @msg, 1;
    END

    DECLARE @type_id INT = NULL;
    IF @exception_type_code IS NOT NULL AND LEN(LTRIM(RTRIM(@exception_type_code))) > 0
    BEGIN
        SELECT @type_id = exception_type_id FROM grac_practice.exception_type_master
         WHERE exception_type_code = @exception_type_code;
        IF @type_id IS NULL
            THROW 55237, 'sp_exception_request_approve: unknown exception_type_code.', 1;
    END

    -- The window that is actually granted. Resolved once, so the row,
    -- the history remark and the change test all read the same values.
    DECLARE @final_from DATE =
        COALESCE(@effective_from, @prop_from, CAST(SYSUTCDATETIME() AS DATE));
    DECLARE @final_until DATE = @effective_until;

    DECLARE @dates_changed BIT =
        CASE WHEN (@prop_from IS NOT NULL OR @prop_until IS NOT NULL)
              AND (@prop_from  IS NULL OR @prop_from  <> @final_from
                OR @prop_until IS NULL OR @prop_until <> @final_until)
             THEN 1 ELSE 0 END;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.exception_request
           SET status_code             = N'Approved',
               approved_by_employee_id = @approved_by_employee_id,
               approved_dt             = SYSUTCDATETIME(),
               effective_from          = @final_from,
               effective_until         = @final_until,
               approval_note           = @approval_note,
               compensating_control    = COALESCE(@compensating_control, compensating_control),
               review_frequency_id     = COALESCE(@review_frequency_id, review_frequency_id),
               exception_type_id       = COALESCE(@type_id,               exception_type_id),
               justification           = COALESCE(@justification,         justification),
               risk_impact             = COALESCE(@risk_impact,           risk_impact),
               owner_employee_id       = COALESCE(@owner_employee_id,     owner_employee_id),
               linked_practice_id      = COALESCE(@linked_practice_id,    linked_practice_id),
               linked_requirement_ref  = COALESCE(@linked_requirement_ref,linked_requirement_ref),
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE exception_request_id = @exception_request_id;

        -- The trail, before the approval row, so a reader sees the
        -- overrule and then the decision it belongs to.
        IF @dates_changed = 1
            INSERT INTO grac_practice.exception_request_history
                (exception_request_id, action_code, from_status_code, to_status_code,
                 remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
            VALUES
                (@exception_request_id, N'EffectiveDatesChanged', @current, @current,
                 CONCAT(N'Approver changed the effective window. Proposed ',
                        ISNULL(CONVERT(NVARCHAR(10), @prop_from,  23), N'(not set)'), N' -> ',
                        ISNULL(CONVERT(NVARCHAR(10), @prop_until, 23), N'(not set)'),
                        N'. Approved ',
                        CONVERT(NVARCHAR(10), @final_from,  23), N' -> ',
                        CONVERT(NVARCHAR(10), @final_until, 23), N'.'),
                 @approved_by_employee_id, @caller_display_name,
                 @caller_display_name, SYSUTCDATETIME());

        INSERT INTO grac_practice.exception_request_history
            (exception_request_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@exception_request_id, N'Approve', @current, N'Approved',
             CONCAT(
                 N'Valid ',
                 CONVERT(NVARCHAR(10), @final_from, 23),
                 N' -> ',
                 CONVERT(NVARCHAR(10), @final_until, 23),
                 N'. Note: ', @approval_note),
             @approved_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK; THROW; END CATCH

    -- 166's result-set shape, unchanged -- the service binds these names.
    SELECT @exception_request_id AS ExceptionRequestId, N'Approved' AS StatusCode;
END
GO
PRINT '260: sp_exception_request_approve defaults from the proposal and records changes.';
GO

-- =====================================================================
-- 6. sp_exception_request_history_list   (NEW)
--
-- The history table has been written since 161 and read by nobody. The
-- traceability asked for here is worth nothing if it cannot be seen, so
-- the whole trail is exposed -- not just the date change. One reader for
-- every action_code, rather than a query per feature.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_history_list
    @exception_request_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55288, 'sp_exception_request_history_list: exception_request_id is required.', 1;

    SELECT h.history_id           AS HistoryId,
           h.exception_request_id AS ExceptionRequestId,
           h.action_code          AS ActionCode,
           h.from_status_code     AS FromStatusCode,
           h.to_status_code       AS ToStatusCode,
           h.remark               AS Remark,
           h.actor_employee_id    AS ActorEmployeeId,
           COALESCE(e.employee_name, h.actor_display_name) AS ActorName,
           h.entered_dt           AS EnteredOn
      FROM grac_practice.exception_request_history h
 LEFT JOIN grac_practice.organization_employee e ON e.employee_id = h.actor_employee_id
     WHERE h.exception_request_id = @exception_request_id
     ORDER BY h.history_id DESC;
END
GO
PRINT '260: sp_exception_request_history_list created.';
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '260 objects present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.exception_request','proposed_effective_from')  IS NOT NULL
             AND COL_LENGTH('grac_practice.exception_request','proposed_effective_until') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_exception_request_analysis_save','P')        IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_exception_request_submit_for_approval','P')  IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_exception_request_get','P')                  IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_exception_request_approve','P')              IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_exception_request_history_list','P')         IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO

PRINT '260 Exception proposed effective dates installed.';
GO

SET NOEXEC OFF;
GO
