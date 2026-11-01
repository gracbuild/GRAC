-- =====================================================================
-- 461  Contract renewal approval: clear message for a sign-in with no
--      employee record (Asset & Contract Management, fix to 436)
--
-- REQUEST
-- -------
--   Contracts -> Renewals: user A saved and submitted a renewal decision.
--   Signed in as A, Approve is not shown (correct: another person must
--   approve, 436 D45). Signed in as another user, Approve is shown, but
--   Approve fails with "Another person (not the one who submitted the
--   decision) must approve it."
--
-- CAUSE
-- -----
--   sp_asset_contract_renewal_action refused APPROVE with that one message
--   in two different cases: the approver is the submitter, OR the request
--   carries no employee (X-PM-Caller-Employee-Id is sent only when the
--   session has an employee: every database sign-in has one; the
--   configured bootstrap sign-in (ReviewLogin) has one only when an
--   organization_employee row matches its e-mail / code). The second user
--   was a sign-in with no employee record, so the procedure refused it,
--   and the screen showed Approve because it only hid the button from the
--   submitter.
--
-- WHAT THIS DOES
-- --------------
--   sp_asset_contract_renewal_action (436) is re-issued unchanged except
--   that the APPROVE check is split: no employee -> "Approval needs a
--   sign-in linked to an employee of the organization ..." (same wording
--   as the 434 version approval, 54530); submitter -> the existing
--   message. Same error number 54582 for both (the API maps it to 400 as
--   before). The maker-checker rule itself is not changed.
--
-- NOT DONE HERE: nothing else in 436 is re-issued.
--
-- ERROR NUMBERS: none new (54582 kept).
--
-- ALSO EDITED: Views/Practice/Partials/asset-contracts.cshtml (the page
--   now knows whether the session has an employee) and
--   wwwroot/js/AssetConfig/asset-contracts.js (Approve decision, version
--   Review / Approve / Reject and contact Validate are offered only to a
--   sign-in with an employee who is not the submitter / creator, with a
--   note saying why otherwise); docs/asset-contract-management.md (D231);
--   database/deployment/16_UAT_Diagnostics_AssetContract.sql (probe).
-- DEPENDS ON: 436.
-- Rollback: 461_asset_contract_renewal_approver_message_rollback.sql
--   (restores the 436 body).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_asset_contract_renewal_action','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_contract_renewal_move','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_contract_reconciliation') IS NULL
   OR COL_LENGTH('grac_practice.asset_contract_renewal', 'submitted_by_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.asset_contract_renewal', 'completed_by_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.asset_contract_renewal_item', 'reconciliation_result') IS NULL
   OR OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_contract_version_create')) NOT LIKE '%@suppress_result%'
BEGIN
    RAISERROR('ABORT (461): run 436 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Renewal steps (D45, D46):
--   SUBMIT          Open -> Pending Approval (decision comments; new expiry for a renewal / extension)
--   APPROVE         Pending Approval -> Approved (not the submitter)
--   RETURN          Pending Approval -> Open (note)
--   REOPEN          Approved -> Open (note; no resulting version linked)
--   CREATE_VERSION  Approved, renewal / extension: new Draft version of the contract with the new
--                   expiry, value and references; the version is then reviewed and approved as usual
--   LINK_VERSION    Approved: link an existing version (rebid / replacement: of any contract)
--   COMPLETE        Approved -> Completed (resulting version approved, or none for a non-renewal);
--                   reconciliation frozen, outcome derived
--   CANCEL          Open / Pending Approval / Approved -> Cancelled (note)
-- sp_asset_contract_renewal_action (436) re-issued -- marked 461
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_renewal_action
    @organization_id         BIGINT,
    @renewal_id              BIGINT,
    @action                  NVARCHAR(20),
    @note                    NVARCHAR(1000) = NULL,
    @version_id              BIGINT         = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @action = UPPER(LTRIM(RTRIM(ISNULL(@action, N''))));
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');

    DECLARE @found BIT = 0, @status NVARCHAR(60), @rv BIGINT, @c BIGINT, @prior BIGINT, @result BIGINT, @type NVARCHAR(20),
            @submitter BIGINT, @new_expiry DATE, @value DECIMAL(18,2), @cur NVARCHAR(3), @po NVARCHAR(100), @inv NVARCHAR(100),
            @comments NVARCHAR(2000), @key NVARCHAR(120), @pno INT;
    SELECT @found = 1, @status = s.status_code, @rv = CONVERT(BIGINT, r.record_version), @c = r.contract_id, @prior = r.prior_version_id,
           @result = r.resulting_version_id, @type = r.renewal_type, @submitter = r.submitted_by_employee_id, @new_expiry = r.new_expiry,
           @value = r.renewal_value, @cur = r.currency_code, @po = r.po_reference, @inv = r.invoice_reference,
           @comments = r.decision_comments, @key = r.occurrence_key, @pno = pv.version_no
      FROM grac_practice.asset_contract_renewal r
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
      JOIN grac_practice.asset_contract_version pv ON pv.version_id = r.prior_version_id
     WHERE r.renewal_id = @renewal_id AND r.organization_id = @organization_id;
    IF @found = 0 THROW 54574, 'Renewal not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54576, 'This renewal was changed by someone else. Reload and try again.', 1;
    IF @action NOT IN (N'SUBMIT', N'APPROVE', N'RETURN', N'REOPEN', N'CREATE_VERSION', N'LINK_VERSION', N'COMPLETE', N'CANCEL')
        THROW 54580, 'Unknown action.', 1;
    IF NOT ((@action = N'SUBMIT' AND @status = N'OPEN')
            OR (@action IN (N'APPROVE', N'RETURN') AND @status = N'PENDING_APPROVAL')
            OR (@action IN (N'REOPEN', N'CREATE_VERSION', N'LINK_VERSION', N'COMPLETE') AND @status = N'APPROVED')
            OR (@action = N'CANCEL' AND @status IN (N'OPEN', N'PENDING_APPROVAL', N'APPROVED')))
    BEGIN
        DECLARE @msg NVARCHAR(400) = CONCAT(N'The renewal is ', LOWER(REPLACE(@status, N'_', N' ')), N'; this step is not possible now.');
        THROW 54581, @msg, 1;
    END
    IF @action IN (N'RETURN', N'REOPEN', N'CANCEL') AND @note IS NULL
        THROW 54583, 'Give the reason.', 1;
    IF @action = N'SUBMIT' AND @comments IS NULL
        THROW 54584, 'Record the decision comments before submitting the renewal decision.', 1;
    IF @action = N'SUBMIT' AND @type IN (N'RENEWAL', N'EXTENSION') AND @new_expiry IS NULL
        THROW 54578, 'Enter the new expiry date of the renewal / extension.', 1;
    -- 461: a sign-in without an employee record is told so, instead of the
    -- maker-checker message (the decision and the rule are unchanged).
    IF @action = N'APPROVE' AND @actor_employee_id IS NULL
        THROW 54582, 'Approval needs a sign-in linked to an employee of the organization. This sign-in has no employee record.', 1;
    IF @action = N'APPROVE' AND @actor_employee_id = @submitter
        THROW 54582, 'Another person (not the one who submitted the decision) must approve it.', 1;
    IF @action IN (N'REOPEN', N'CREATE_VERSION', N'LINK_VERSION') AND @result IS NOT NULL
        THROW 54587, 'A resulting version is already linked to this renewal.', 1;
    IF @action = N'CREATE_VERSION' AND @type NOT IN (N'RENEWAL', N'EXTENSION')
        THROW 54585, 'Create version is for a renewal or an extension; for a rebid or replacement link the version of the new contract.', 1;
    IF @action = N'LINK_VERSION'
    BEGIN
        IF @type = N'NON_RENEWAL'
            THROW 54585, 'A non-renewal has no resulting version.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_version v
                         JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
                        WHERE v.version_id = @version_id AND v.organization_id = @organization_id AND v.version_id <> @prior
                          AND s.status_code <> N'REJECTED' AND v.version_type <> N'TERMINATION'
                          AND (@type IN (N'REBID', N'REPLACEMENT') OR (v.contract_id = @c AND v.version_no > @pno)))
            THROW 54585, 'Link a later version of this contract (rebid / replacement: a version of any contract of the organization) that is not rejected.', 1;
    END
    IF @action = N'COMPLETE'
    BEGIN
        IF @type = N'NON_RENEWAL' AND @result IS NOT NULL
            THROW 54587, 'A non-renewal has no resulting version.', 1;
        IF @type <> N'NON_RENEWAL'
           AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_version WHERE version_id = @result AND approval_dt IS NOT NULL)
            THROW 54586, 'The resulting version must be approved before the renewal is completed (7.3).', 1;
    END

    DECLARE @to NVARCHAR(60) = CASE @action WHEN N'SUBMIT' THEN N'PENDING_APPROVAL' WHEN N'APPROVE' THEN N'APPROVED'
                                            WHEN N'RETURN' THEN N'OPEN' WHEN N'REOPEN' THEN N'OPEN' WHEN N'COMPLETE' THEN N'COMPLETED'
                                            WHEN N'CANCEL' THEN N'CANCELLED' END;
    DECLARE @before NVARCHAR(MAX) = (SELECT @status AS status, resulting_version_id, outcome FROM grac_practice.asset_contract_renewal
                                      WHERE renewal_id = @renewal_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @new_version BIGINT, @outcome NVARCHAR(20), @rec_result BIGINT = CASE WHEN @type = N'NON_RENEWAL' THEN NULL ELSE @result END;

    BEGIN TRAN;
    IF @to IS NOT NULL
        EXEC grac_practice.sp_asset_contract_renewal_move @renewal_id = @renewal_id, @from_code = @status, @to_code = @to,
             @reason_code = @action, @reason_text = @note, @actor_employee_id = @actor_employee_id, @actor = @actor;

    IF @action = N'SUBMIT'
    BEGIN
        UPDATE grac_practice.asset_contract_renewal
           SET submitted_by = @actor, submitted_by_employee_id = @actor_employee_id, submitted_dt = SYSUTCDATETIME()
         WHERE renewal_id = @renewal_id;
    END
    IF @action = N'APPROVE'
    BEGIN
        UPDATE grac_practice.asset_contract_renewal
           SET approved_by = @actor, approved_by_employee_id = @actor_employee_id, approval_dt = SYSUTCDATETIME(), approval_comments = @note
         WHERE renewal_id = @renewal_id;
    END
    IF @action IN (N'RETURN', N'REOPEN')
    BEGIN
        UPDATE grac_practice.asset_contract_renewal
           SET approved_by = NULL, approved_by_employee_id = NULL, approval_dt = NULL, approval_comments = @note
         WHERE renewal_id = @renewal_id;
    END
    IF @action = N'CREATE_VERSION'
    BEGIN
        DECLARE @summary NVARCHAR(2000) = LEFT(CONCAT(N'Renewal ', @key, N': ', @comments), 2000);
        EXEC grac_practice.sp_asset_contract_version_create
             @organization_id = @organization_id, @contract_id = @c, @version_type = @type, @change_summary = @summary,
             @actor_employee_id = @actor_employee_id, @actor = @actor, @suppress_result = 1, @out_version_id = @new_version OUTPUT;
        UPDATE grac_practice.asset_contract_version
           SET effective_end = ISNULL(@new_expiry, effective_end),
               contract_value = CASE WHEN @value IS NOT NULL THEN @value ELSE contract_value END,
               currency_code = CASE WHEN @value IS NOT NULL THEN @cur ELSE currency_code END,
               po_reference = ISNULL(@po, po_reference), invoice_reference = ISNULL(@inv, invoice_reference),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE version_id = @new_version;
        UPDATE grac_practice.asset_contract_renewal SET resulting_version_id = @new_version WHERE renewal_id = @renewal_id;
    END
    IF @action = N'LINK_VERSION'
    BEGIN
        UPDATE grac_practice.asset_contract_renewal SET resulting_version_id = @version_id WHERE renewal_id = @renewal_id;
    END
    IF @action = N'COMPLETE'
    BEGIN
        INSERT grac_practice.asset_contract_renewal_item
            (renewal_id, item_kind, asset_id, asset_name, coverage_type, product_sku, line_key, prior_state, result_state,
             prior_quantity, result_quantity, reconciliation_result, entered_by)
        SELECT @renewal_id, x.ItemKind, x.AssetId, x.AssetName, x.CoverageType, x.ProductSku, x.LineKey, x.PriorState, x.ResultState,
               x.PriorQuantity, x.ResultQuantity, x.ReconciliationResult, @actor
          FROM grac_practice.fn_asset_contract_reconciliation(@organization_id, @prior, @rec_result) x;
        SET @outcome = CASE WHEN @type = N'NON_RENEWAL' THEN N'NOT_RENEWED'
                            WHEN @type IN (N'REBID', N'REPLACEMENT') THEN N'REPLACED'
                            WHEN EXISTS (SELECT 1 FROM grac_practice.asset_contract_renewal_item
                                          WHERE renewal_id = @renewal_id AND reconciliation_result IN (N'REMOVED', N'UNRESOLVED'))
                                 THEN N'PARTIALLY_RENEWED'
                            ELSE N'RENEWED' END;
        UPDATE r
           SET outcome = @outcome, new_expiry = CASE WHEN v.version_id IS NOT NULL THEN v.effective_end ELSE r.new_expiry END,
               completed_by = @actor, completed_by_employee_id = @actor_employee_id, completed_dt = SYSUTCDATETIME()
          FROM grac_practice.asset_contract_renewal r
          LEFT JOIN grac_practice.asset_contract_version v ON v.version_id = r.resulting_version_id AND @type <> N'NON_RENEWAL'
         WHERE r.renewal_id = @renewal_id;
    END
    IF @action = N'CANCEL'
    BEGIN
        UPDATE grac_practice.asset_contract_renewal SET outcome = N'CANCELLED', cancel_reason = @note WHERE renewal_id = @renewal_id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-renewal', @renewal_id, @action, @before,
            (SELECT ISNULL(@to, @status) AS status, resulting_version_id, outcome, @note AS note
               FROM grac_practice.asset_contract_renewal WHERE renewal_id = @renewal_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @renewal_id AS RenewalId,
           CASE WHEN @action = N'COMPLETE' THEN @outcome WHEN @action = N'CREATE_VERSION' THEN N'VERSION_CREATED'
                WHEN @action = N'LINK_VERSION' THEN N'VERSION_LINKED' ELSE @to END AS Result,
           @new_version AS VersionId;
END
GO

PRINT '461: sp_asset_contract_renewal_action re-issued.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '461-a renewal approval tells a sign-in without an employee' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_contract_renewal_action')) LIKE '%sign-in linked to an employee%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_contract_renewal_action')) LIKE '%not the one who submitted the decision%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
SET NOEXEC OFF;
GO

-- =====================================================================
-- UAT (after deploying the Web build)
--   1. As A (a database sign-in): submit a renewal decision. Approve
--      decision is not shown; the note says another person approves it.
--   2. As the bootstrap sign-in with no employee record: Approve decision
--      is not shown; the note says approval needs a sign-in linked to an
--      employee. (Calling the API directly returns the new message.)
--   3. As B (another database sign-in with Contracts APPROVE): Approve
--      decision is shown and succeeds.
-- =====================================================================
