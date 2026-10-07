-- =====================================================================
-- 436  Contract renewal occurrences and coverage reconciliation
--      (Asset & Contract Management, Phase 5 increment 3)
--
-- REQUEST
-- -------
--   BRD v1.7 7.3 "Contract Renewal History": renewal occurrence ID, prior /
--   resulting contract version, renewal type (Renewal, Extension, Rebid,
--   Replacement, Non-renewal), old / new expiry date, renewal value /
--   currency, quotation / PO / invoice, decision and approval (decision,
--   approver, date, comments), coverage reconciliation (covered, removed,
--   added, excluded and unresolved assets / entitlements), outcome
--   (Renewed, Partially Renewed, Replaced, Not Renewed, Cancelled),
--   completed by / date; "completing a renewal shall create or activate
--   the resulting ContractVersion and shall not overwrite the prior
--   version"; "non-renewal shall retain the contract and versions";
--   7.1.5 one open occurrence per contract and due period; 7.2.3 Renewal
--   History; 9.1.5 earliest of notice / decision / end date and "an
--   excluded or unmatched asset remains in the exception queue until
--   mapped, separately renewed, replaced, uninstalled, exempted or
--   retired"; 16.6. Plan in docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. ContractRenewal statuses on the state machine: Open, Pending
--      Approval, Approved, Completed, Cancelled (D45 -- the BRD lists the
--      outcomes, not the steps).
--   2. asset_contract_renewal -- one occurrence per contract and prior
--      version (one open occurrence per contract): occurrence ID, prior and
--      resulting version, type, due date (earliest of notice date, decision
--      date and end minus the expiring window), old / new expiry, value /
--      currency, quotation / PO / invoice references, decision comments,
--      submitted / approved by and date, approval comments, outcome,
--      completed by / date, cancel reason.
--   3. fn_asset_contract_reconciliation -- prior version coverage and
--      entitlements against the resulting version: Covered, Added, Removed,
--      Excluded, Unresolved (removed / excluded / suspended where the asset
--      type requires the coverage and no other contract covers it -- D47).
--      asset_contract_renewal_item freezes it when the renewal completes;
--      each Unresolved row is resolved with one of the 9.1.5 resolutions.
--   4. Steps: start, save, Submit, Approve / Return (not the submitter),
--      Reopen, Create version (a Renewal / Extension draft of the contract
--      with the new expiry, value and references -- the normal version
--      approval follows), Link version (an existing version, or for a
--      rebid / replacement a version of another contract), Complete
--      (resulting version approved; reconciliation frozen; outcome
--      derived -- D46), Cancel. sp_asset_contract_version_create (435) is
--      re-issued with @suppress_result / @out_version_id so the renewal can
--      call it.
--   5. Readers: renewal list (organization or contract -- the contract
--      Renewal History), contracts due for renewal, renewal detail with the
--      live or frozen reconciliation and the versions it can link.
--
-- NOT DONE HERE: renewal reminders and recipients (9.1.5 / 7.4.5 -> Phase
--   6), automatic creation of the renewal occurrence by the scheduler
--   (Phase 6 -- started from the screen until then), termination actions
--   on non-renewal (the contract expires on its end date; uncovered assets
--   appear in the reconciliation and the coverage gaps -- D46).
--
-- ERROR NUMBERS: 54570-54599
--   54570 organization not found           54571 contract not found
--   54572 an open renewal exists           54573 no approved version to renew
--   54574 renewal not found                54575 renewal is not Open
--   54576 renewal changed by someone else  54577 renewal type
--   54578 new expiry / dates               54579 value / currency
--   54580 unknown action                   54581 wrong status for the action
--   54582 segregation of duties            54583 note / reason required
--   54584 decision comments required       54585 version cannot be linked
--   54586 resulting version not approved   54587 a resulting version is linked
--   54588 reconciliation item not found    54589 item not unresolved
--   54590 resolution code                  54591 contract terminated
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web proxy
--   (renewal approval), asset-contracts.cshtml / .js (Renewals tab,
--   Renewal history, renewal dialog), docs.
-- DEPENDS ON: 434, 435.
-- Rollback: 436_asset_contract_renewals_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_contract_coverage','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_contract_version_action','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_coverage_line_view') IS NULL
BEGIN
    RAISERROR('ABORT (436): run 434 and 435 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. ContractRenewal statuses (D45)
-- =====================================================================
MERGE grac_practice.entity_status_master AS t
USING (VALUES
    (N'ContractRenewal', N'OPEN',             N'Open',             10, 0, 1),
    (N'ContractRenewal', N'PENDING_APPROVAL', N'Pending Approval', 20, 0, 0),
    (N'ContractRenewal', N'APPROVED',         N'Approved',         30, 0, 0),
    (N'ContractRenewal', N'COMPLETED',        N'Completed',        40, 1, 0),
    (N'ContractRenewal', N'CANCELLED',        N'Cancelled',        50, 1, 0)
) AS s(entity_type, status_code, status_name, display_order, is_terminal, is_initial)
ON t.entity_type = s.entity_type AND t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, status_code, status_name, display_order, is_terminal, is_initial, description, entered_by)
    VALUES (s.entity_type, s.status_code, s.status_name, s.display_order, s.is_terminal, s.is_initial,
            N'Contract renewal occurrence status (BRD v1.7 7.3, D45).', N'seed-436');
PRINT CONCAT('436: renewal statuses inserted: ', @@ROWCOUNT);
GO

MERGE grac_practice.entity_state_transition_rule AS t
USING (VALUES
    (CAST(NULL AS NVARCHAR(60)), N'OPEN', 0, N'Renewal occurrence started.'),
    (N'OPEN', N'PENDING_APPROVAL', 0, N'Decision submitted for approval.'),
    (N'PENDING_APPROVAL', N'APPROVED', 0, N'Decision approved.'),
    (N'PENDING_APPROVAL', N'OPEN', 1, N'Decision returned.'),
    (N'APPROVED', N'OPEN', 1, N'Decision reopened.'),
    (N'APPROVED', N'COMPLETED', 0, N'Renewal completed; coverage reconciled.'),
    (N'OPEN', N'CANCELLED', 1, N'Renewal cancelled.'),
    (N'PENDING_APPROVAL', N'CANCELLED', 1, N'Renewal cancelled.'),
    (N'APPROVED', N'CANCELLED', 1, N'Renewal cancelled.')
) AS s(from_status_code, to_status_code, requires_reason, description)
ON t.entity_type = N'ContractRenewal'
   AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(s.from_status_code, N'__NULL__')
   AND t.to_status_code = s.to_status_code AND t.actor_role_code IS NULL
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, requires_approval, description, entered_by)
    VALUES (N'ContractRenewal', s.from_status_code, s.to_status_code, NULL, s.requires_reason, 0, s.description, N'seed-436');
PRINT CONCAT('436: renewal transition rules inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 2. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_contract_renewal','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_contract_renewal (
        renewal_id               BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_c_renewal PRIMARY KEY,
        organization_id          BIGINT         NOT NULL,
        contract_id              BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_c_ren_contract REFERENCES grac_practice.asset_contract(contract_id),
        occurrence_key           NVARCHAR(120)  NOT NULL CONSTRAINT uq_pm_asset_c_ren_key UNIQUE,
        prior_version_id         BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_c_ren_prior REFERENCES grac_practice.asset_contract_version(version_id),
        resulting_version_id     BIGINT         NULL
            CONSTRAINT fk_pm_asset_c_ren_result REFERENCES grac_practice.asset_contract_version(version_id),
        renewal_type             NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_c_ren_type CHECK (renewal_type IN (N'RENEWAL', N'EXTENSION', N'REBID', N'REPLACEMENT', N'NON_RENEWAL')),
        current_status_id        INT            NOT NULL
            CONSTRAINT fk_pm_asset_c_ren_status REFERENCES grac_practice.entity_status_master(entity_status_id),
        is_open                  BIT            NOT NULL CONSTRAINT df_pm_asset_c_ren_open DEFAULT 1,
        due_date                 DATE           NULL,
        old_expiry               DATE           NULL,
        new_expiry               DATE           NULL,
        renewal_value            DECIMAL(18,2)  NULL,
        currency_code            NVARCHAR(3)    NULL,
        quotation_reference      NVARCHAR(200)  NULL,
        po_reference             NVARCHAR(100)  NULL,
        invoice_reference        NVARCHAR(100)  NULL,
        decision_comments        NVARCHAR(2000) NULL,
        notes                    NVARCHAR(2000) NULL,
        submitted_by             NVARCHAR(100)  NULL,
        submitted_by_employee_id BIGINT         NULL,
        submitted_dt             DATETIME2      NULL,
        approved_by              NVARCHAR(100)  NULL,
        approved_by_employee_id  BIGINT         NULL,
        approval_dt              DATETIME2      NULL,
        approval_comments        NVARCHAR(1000) NULL,
        outcome                  NVARCHAR(20)   NULL
            CONSTRAINT ck_pm_asset_c_ren_outcome CHECK (outcome IS NULL OR outcome IN
                (N'RENEWED', N'PARTIALLY_RENEWED', N'REPLACED', N'NOT_RENEWED', N'CANCELLED')),
        completed_by             NVARCHAR(100)  NULL,
        completed_by_employee_id BIGINT         NULL,
        completed_dt             DATETIME2      NULL,
        cancel_reason            NVARCHAR(1000) NULL,
        started_by_employee_id   BIGINT         NULL,
        record_version           ROWVERSION     NOT NULL,
        entered_by               NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_c_ren_eby DEFAULT N'system',
        entered_dt               DATETIME2      NOT NULL CONSTRAINT df_pm_asset_c_ren_edt DEFAULT SYSUTCDATETIME(),
        updated_by               NVARCHAR(100)  NULL,
        updated_dt               DATETIME2      NULL
    );
    -- 7.1.5: no second open occurrence for the same contract.
    CREATE UNIQUE INDEX ux_pm_asset_c_ren_open ON grac_practice.asset_contract_renewal(contract_id) WHERE is_open = 1;
    PRINT '436: asset_contract_renewal created.';
END
GO

IF OBJECT_ID('grac_practice.asset_contract_renewal_item','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_contract_renewal_item (
        item_id                   BIGINT           IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_c_ren_item PRIMARY KEY,
        renewal_id                BIGINT           NOT NULL
            CONSTRAINT fk_pm_asset_c_ren_item_renewal REFERENCES grac_practice.asset_contract_renewal(renewal_id),
        item_kind                 NVARCHAR(12)     NOT NULL
            CONSTRAINT ck_pm_asset_c_ren_item_kind CHECK (item_kind IN (N'ASSET', N'ENTITLEMENT')),
        asset_id                  BIGINT           NULL,
        asset_name                NVARCHAR(220)    NULL,
        coverage_type             NVARCHAR(160)    NULL,
        product_sku               NVARCHAR(160)    NULL,
        line_key                  UNIQUEIDENTIFIER NULL,
        prior_state               NVARCHAR(10)     NULL,
        result_state              NVARCHAR(10)     NULL,
        prior_quantity            DECIMAL(18,2)    NULL,
        result_quantity           DECIMAL(18,2)    NULL,
        reconciliation_result     NVARCHAR(12)     NOT NULL
            CONSTRAINT ck_pm_asset_c_ren_item_result CHECK (reconciliation_result IN (N'COVERED', N'ADDED', N'REMOVED', N'EXCLUDED', N'UNRESOLVED')),
        resolution_code           NVARCHAR(20)     NULL
            CONSTRAINT ck_pm_asset_c_ren_item_res CHECK (resolution_code IS NULL OR resolution_code IN
                (N'MAPPED', N'SEPARATELY_RENEWED', N'REPLACED', N'UNINSTALLED', N'EXEMPTED', N'RETIRED')),
        resolution_note           NVARCHAR(1000)   NULL,
        resolved_by               NVARCHAR(100)    NULL,
        resolved_dt               DATETIME2        NULL,
        entered_by                NVARCHAR(100)    NOT NULL CONSTRAINT df_pm_asset_c_ren_item_eby DEFAULT N'system',
        entered_dt                DATETIME2        NOT NULL CONSTRAINT df_pm_asset_c_ren_item_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_asset_c_ren_item ON grac_practice.asset_contract_renewal_item(renewal_id);
    PRINT '436: asset_contract_renewal_item created.';
END
GO

-- =====================================================================
-- 3. Reconciliation (7.3, D47)
-- =====================================================================
-- Prior version against the resulting version (NULL = non-renewal: every
-- prior line is removed). Asset rows by asset + coverage type, entitlement
-- rows by line key. Removed / excluded / suspended assets whose asset type
-- requires the coverage, and that no other contract covers after the prior
-- expiry, are Unresolved.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_contract_reconciliation
    (@organization_id BIGINT, @prior_version_id BIGINT, @result_version_id BIGINT)
RETURNS TABLE
AS
RETURN
    WITH pv AS (
        SELECT v.contract_id, v.effective_end FROM grac_practice.asset_contract_version v WHERE v.version_id = @prior_version_id),
    p AS (SELECT asset_id, coverage_type, coverage_state FROM grac_practice.asset_contract_coverage WHERE version_id = @prior_version_id),
    r AS (SELECT asset_id, coverage_type, coverage_state FROM grac_practice.asset_contract_coverage
           WHERE version_id = @result_version_id AND @result_version_id IS NOT NULL),
    a AS (
        SELECT COALESCE(p.asset_id, r.asset_id) AS asset_id, COALESCE(p.coverage_type, r.coverage_type) AS coverage_type,
               p.coverage_state AS prior_state, r.coverage_state AS result_state,
               CASE WHEN r.asset_id IS NULL THEN N'REMOVED' WHEN r.coverage_state = N'SUSPENDED' THEN N'SUSPENDED'
                    WHEN r.coverage_state = N'EXCLUDED' THEN N'EXCLUDED' WHEN p.asset_id IS NULL THEN N'ADDED'
                    ELSE N'COVERED' END AS base_result
          FROM p FULL OUTER JOIN r ON r.asset_id = p.asset_id AND r.coverage_type = p.coverage_type),
    ep AS (SELECT line_key, product_sku, coverage_type, quantity FROM grac_practice.asset_contract_entitlement WHERE version_id = @prior_version_id),
    er AS (SELECT line_key, product_sku, coverage_type, quantity FROM grac_practice.asset_contract_entitlement
            WHERE version_id = @result_version_id AND @result_version_id IS NOT NULL)
    SELECT CAST(N'ASSET' AS NVARCHAR(12)) AS ItemKind, a.asset_id AS AssetId, ast.asset_name AS AssetName, a.coverage_type AS CoverageType,
           CAST(NULL AS NVARCHAR(160)) AS ProductSku, CAST(NULL AS UNIQUEIDENTIFIER) AS LineKey,
           a.prior_state AS PriorState, a.result_state AS ResultState,
           CAST(NULL AS DECIMAL(18,2)) AS PriorQuantity, CAST(NULL AS DECIMAL(18,2)) AS ResultQuantity,
           CAST(CASE WHEN a.base_result IN (N'REMOVED', N'EXCLUDED', N'SUSPENDED')
                      AND (a.base_result = N'SUSPENDED'
                           OR (EXISTS (SELECT 1 FROM grac_practice.asset_coverage_requirement q
                                        WHERE q.organization_id = @organization_id AND q.asset_type_id = ast.asset_type_id
                                          AND q.coverage_type = a.coverage_type AND q.requirement_level = N'REQUIRED')
                               AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_coverage c2
                                                 JOIN grac_practice.asset_contract_version v2 ON v2.version_id = c2.version_id
                                                 JOIN grac_practice.entity_status_master s2 ON s2.entity_status_id = v2.current_status_id
                                                 CROSS JOIN pv
                                                WHERE c2.asset_id = a.asset_id AND c2.coverage_type = a.coverage_type
                                                  AND c2.contract_id <> pv.contract_id AND c2.coverage_state = N'COVERED'
                                                  AND s2.status_code IN (N'APPROVED', N'ACTIVE')
                                                  AND ISNULL(COALESCE(c2.coverage_end, v2.effective_end), CAST('9999-12-31' AS DATE))
                                                      > ISNULL(pv.effective_end, CAST('0001-01-01' AS DATE)))))
                     THEN N'UNRESOLVED'
                     WHEN a.base_result = N'SUSPENDED' THEN N'UNRESOLVED'
                     ELSE a.base_result END AS NVARCHAR(12)) AS ReconciliationResult
      FROM a
      LEFT JOIN grac_practice.organization_dependency_asset ast ON ast.asset_id = a.asset_id
    UNION ALL
    SELECT CAST(N'ENTITLEMENT' AS NVARCHAR(12)), NULL, NULL, COALESCE(er.coverage_type, ep.coverage_type),
           COALESCE(er.product_sku, ep.product_sku), COALESCE(er.line_key, ep.line_key), NULL, NULL, ep.quantity, er.quantity,
           CAST(CASE WHEN er.line_key IS NULL THEN N'REMOVED' WHEN ep.line_key IS NULL THEN N'ADDED' ELSE N'COVERED' END AS NVARCHAR(12))
      FROM ep FULL OUTER JOIN er ON er.line_key = ep.line_key;
GO
PRINT '436: reconciliation function created.';
GO

-- =====================================================================
-- 4. sp_asset_contract_version_create (435) re-issued -- marked 436
--    (@suppress_result / @out_version_id so the renewal can call it)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_version_create
    @organization_id   BIGINT,
    @contract_id       BIGINT,
    @version_type      NVARCHAR(20),
    @change_summary    NVARCHAR(2000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system',
    @suppress_result   BIT            = 0,        -- 436: called by the renewal (no result set)
    @out_version_id    BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @version_type = UPPER(LTRIM(RTRIM(ISNULL(@version_type, N''))));
    SET @change_summary = NULLIF(LTRIM(RTRIM(@change_summary)), N'');

    DECLARE @found BIT = 0, @status NVARCHAR(20);
    SELECT @found = 1, @status = contract_status FROM grac_practice.asset_contract
     WHERE contract_id = @contract_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54511, 'Contract not found for this organization.', 1;
    EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id, @contract_id = @contract_id, @actor = @actor;
    SELECT @status = contract_status FROM grac_practice.asset_contract WHERE contract_id = @contract_id;
    IF @status = N'TERMINATED'
        THROW 54520, 'The contract is terminated; its versions are kept for history only.', 1;
    IF @version_type NOT IN (N'INITIAL', N'RENEWAL', N'AMENDMENT', N'EXTENSION', N'VARIATION', N'CORRECTION', N'TERMINATION')
        THROW 54521, 'Select the version type.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_contract_version v
                 JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
                WHERE v.contract_id = @contract_id AND s.status_code IN (N'DRAFT', N'IN_REVIEW', N'PENDING_APPROVAL'))
        THROW 54522, 'The contract already has a version in progress; finish or withdraw it first.', 1;

    -- Base: the Active version, else the latest approved / ended one.
    DECLARE @base BIGINT = (SELECT TOP 1 v.version_id FROM grac_practice.asset_contract_version v
                              JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
                             WHERE v.contract_id = @contract_id AND s.status_code IN (N'ACTIVE', N'APPROVED', N'EXPIRED', N'SUPERSEDED')
                             ORDER BY CASE WHEN s.status_code = N'ACTIVE' THEN 0 ELSE 1 END, v.effective_start DESC, v.version_no DESC);
    IF @version_type = N'INITIAL' AND @base IS NOT NULL
        THROW 54521, 'The contract already has an approved version; choose renewal, amendment, extension, variation, correction or termination.', 1;
    IF @version_type <> N'INITIAL' AND @base IS NULL
        THROW 54521, 'The contract has no approved version yet; add an Initial version.', 1;
    IF @version_type <> N'INITIAL' AND @change_summary IS NULL
        THROW 54523, 'Enter the change summary / reason (required for every version after the initial one).', 1;
    -- Source of the copied terms: the base, or for a new Initial version the latest (rejected) draft.
    DECLARE @src BIGINT = ISNULL(@base, (SELECT TOP 1 version_id FROM grac_practice.asset_contract_version
                                          WHERE contract_id = @contract_id ORDER BY version_no DESC));
    DECLARE @no INT = ISNULL((SELECT MAX(version_no) FROM grac_practice.asset_contract_version WHERE contract_id = @contract_id), 0) + 1;
    DECLARE @version_id BIGINT;

    BEGIN TRAN;
    INSERT grac_practice.asset_contract_version
        (contract_id, organization_id, version_no, version_type, current_status_id, effective_start, effective_end, notice_date,
         decision_date, termination_date, contract_value, currency_code, tax_details, payment_terms, po_reference, invoice_reference,
         cost_allocation, renewal_terms, service_scope, sla_terms, support_hours, response_time, resolution_time, service_visits,
         contract_owner_id, procurement_owner_id, change_summary, created_by_employee_id, supersedes_version_id, entered_by)
    SELECT @contract_id, @organization_id, @no, @version_type, grac_practice.fn_get_entity_status_id(N'ContractVersion', N'DRAFT'),
           CASE @version_type WHEN N'RENEWAL' THEN DATEADD(DAY, 1, s.effective_end) WHEN N'TERMINATION' THEN NULL ELSE s.effective_start END,
           CASE WHEN @version_type IN (N'RENEWAL', N'TERMINATION') THEN NULL ELSE s.effective_end END,
           CASE WHEN @version_type IN (N'RENEWAL', N'TERMINATION') THEN NULL ELSE s.notice_date END,
           CASE WHEN @version_type IN (N'RENEWAL', N'TERMINATION') THEN NULL ELSE s.decision_date END,
           NULL, s.contract_value, s.currency_code, s.tax_details, s.payment_terms,
           CASE WHEN @version_type = N'RENEWAL' THEN NULL ELSE s.po_reference END,
           CASE WHEN @version_type = N'RENEWAL' THEN NULL ELSE s.invoice_reference END,
           s.cost_allocation, s.renewal_terms, s.service_scope, s.sla_terms, s.support_hours, s.response_time, s.resolution_time,
           s.service_visits, s.contract_owner_id, s.procurement_owner_id, @change_summary, @actor_employee_id, @base, @actor
      FROM grac_practice.asset_contract_version s
     WHERE s.version_id = @src;
    SET @version_id = SCOPE_IDENTITY();
    -- 435: entitlements and asset coverage are copied with their line keys (7.2.1 snapshot; 7.3 a renewal
    -- preserves coverage and entitlement quantities). A renewal clears line dates (they follow the new
    -- version); a termination version covers nothing.
    IF @version_type <> N'TERMINATION'
    BEGIN
        INSERT grac_practice.asset_contract_entitlement
            (organization_id, contract_id, version_id, line_key, product_sku, description, coverage_type, quantity, unit,
             service_level, support_hours, start_date, end_date, exclusions, entered_by)
        SELECT organization_id, contract_id, @version_id, line_key, product_sku, description, coverage_type, quantity, unit,
               service_level, support_hours,
               CASE WHEN @version_type = N'RENEWAL' THEN NULL ELSE start_date END,
               CASE WHEN @version_type = N'RENEWAL' THEN NULL ELSE end_date END, exclusions, @actor
          FROM grac_practice.asset_contract_entitlement WHERE version_id = @src;
        INSERT grac_practice.asset_contract_coverage
            (organization_id, contract_id, version_id, line_key, asset_id, coverage_type, coverage_state, entitlement_line_key,
             coverage_start, coverage_end, service_level, support_hours, vendor_support_reference, exclusion_reason, entered_by)
        SELECT organization_id, contract_id, @version_id, line_key, asset_id, coverage_type, coverage_state, entitlement_line_key,
               CASE WHEN @version_type = N'RENEWAL' THEN NULL ELSE coverage_start END,
               CASE WHEN @version_type = N'RENEWAL' THEN NULL ELSE coverage_end END,
               service_level, support_hours, vendor_support_reference, exclusion_reason, @actor
          FROM grac_practice.asset_contract_coverage WHERE version_id = @src;
    END
    EXEC grac_practice.sp_asset_contract_version_move @version_id = @version_id, @from_code = NULL, @to_code = N'DRAFT',
         @reason_code = @version_type, @reason_text = @change_summary, @actor_employee_id = @actor_employee_id, @actor = @actor;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-version', @version_id, N'CREATE', NULL,
            (SELECT @contract_id AS contractId, @no AS versionNo, @version_type AS versionType, @base AS supersedesVersionId,
                    @change_summary AS changeSummary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SET @out_version_id = @version_id;   -- 436
    IF ISNULL(@suppress_result, 0) = 0
        SELECT @version_id AS VersionId, N'CREATED' AS Result;
END
GO
PRINT '436: sp_asset_contract_version_create re-issued.';
GO

-- =====================================================================
-- 5. Writers
-- =====================================================================
-- One status move of a renewal: transition log + audit (035) and the row.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_renewal_move
    @renewal_id        BIGINT,
    @from_code         NVARCHAR(60)   = NULL,
    @to_code           NVARCHAR(60),
    @reason_code       NVARCHAR(60)   = NULL,
    @reason_text       NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @sid INT, @log BIGINT;
    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'ContractRenewal', @entity_id = @renewal_id,
         @from_status_code = @from_code, @to_status_code = @to_code,
         @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
         @reason_code = @reason_code, @reason_text = @reason_text,
         @to_status_id = @sid OUTPUT, @transition_log_id = @log OUTPUT;
    UPDATE grac_practice.asset_contract_renewal
       SET current_status_id = @sid, is_open = CASE WHEN @to_code IN (N'COMPLETED', N'CANCELLED') THEN 0 ELSE 1 END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE renewal_id = @renewal_id;
END
GO

-- Start a renewal occurrence for the version in force (or the last one that
-- ended). One open occurrence per contract (7.1.5).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_renewal_start
    @organization_id   BIGINT,
    @contract_id       BIGINT,
    @renewal_type      NVARCHAR(20)   = N'RENEWAL',
    @notes             NVARCHAR(2000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @renewal_type = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@renewal_type)), N''), N'RENEWAL'));
    SET @notes = NULLIF(LTRIM(RTRIM(@notes)), N'');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54570, 'Organization not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract WHERE contract_id = @contract_id AND organization_id = @organization_id)
        THROW 54571, 'Contract not found for this organization.', 1;
    EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id, @contract_id = @contract_id, @actor = @actor;

    DECLARE @cstatus NVARCHAR(20), @number NVARCHAR(60), @prior BIGINT;
    SELECT @cstatus = contract_status, @number = contract_number, @prior = current_version_id
      FROM grac_practice.asset_contract WHERE contract_id = @contract_id;
    IF @cstatus = N'TERMINATED'
        THROW 54591, 'The contract is terminated; it cannot be renewed.', 1;
    IF @renewal_type NOT IN (N'RENEWAL', N'EXTENSION', N'REBID', N'REPLACEMENT', N'NON_RENEWAL')
        THROW 54577, 'Select the renewal type: renewal, extension, rebid, replacement or non-renewal.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_contract_renewal WHERE contract_id = @contract_id AND is_open = 1)
        THROW 54572, 'The contract already has an open renewal; finish or cancel it first.', 1;
    DECLARE @pno INT, @pend DATE, @notice DATE, @decision DATE;
    SELECT @pno = v.version_no, @pend = v.effective_end, @notice = v.notice_date, @decision = v.decision_date
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
     WHERE v.version_id = @prior AND s.status_code IN (N'APPROVED', N'ACTIVE', N'EXPIRED', N'SUPERSEDED') AND v.version_type <> N'TERMINATION';
    IF @pno IS NULL
        THROW 54573, 'The contract has no approved version to renew yet.', 1;

    -- 9.1.5: the earliest of notice date, decision date and end minus the expiring window (435).
    DECLARE @win INT = ISNULL((SELECT expiring_window_days FROM grac_practice.asset_coverage_settings WHERE organization_id = @organization_id), 30);
    DECLARE @due DATE = (SELECT MIN(x.d) FROM (VALUES (DATEADD(DAY, -@win, @pend)), (@notice), (@decision)) x(d));
    DECLARE @seq INT = 1 + (SELECT COUNT(*) FROM grac_practice.asset_contract_renewal WHERE contract_id = @contract_id AND prior_version_id = @prior);
    DECLARE @key NVARCHAR(120) = CONCAT(N'CR-', @number, N'-V', @pno, N'-', @seq);
    DECLARE @id BIGINT;

    BEGIN TRAN;
    INSERT grac_practice.asset_contract_renewal
        (organization_id, contract_id, occurrence_key, prior_version_id, renewal_type, current_status_id, is_open, due_date, old_expiry,
         notes, started_by_employee_id, entered_by)
    VALUES (@organization_id, @contract_id, @key, @prior, @renewal_type,
            grac_practice.fn_get_entity_status_id(N'ContractRenewal', N'OPEN'), 1, @due, @pend, @notes, @actor_employee_id, @actor);
    SET @id = SCOPE_IDENTITY();
    EXEC grac_practice.sp_asset_contract_renewal_move @renewal_id = @id, @from_code = NULL, @to_code = N'OPEN',
         @reason_code = @renewal_type, @reason_text = @notes, @actor_employee_id = @actor_employee_id, @actor = @actor;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-renewal', @id, N'CREATE', NULL,
            (SELECT @contract_id AS contractId, @key AS occurrenceKey, @prior AS priorVersionId, @renewal_type AS renewalType,
                    @due AS dueDate, @pend AS oldExpiry FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @id AS RenewalId, N'OPEN' AS Result;
END
GO

-- Edit an Open renewal: type (the decision), new expiry, value, procurement
-- references, decision comments, notes.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_renewal_save
    @organization_id         BIGINT,
    @renewal_id              BIGINT,
    @renewal_type            NVARCHAR(20),
    @new_expiry              DATE           = NULL,
    @renewal_value           DECIMAL(18,2)  = NULL,
    @currency_code           NVARCHAR(3)    = NULL,
    @quotation_reference     NVARCHAR(200)  = NULL,
    @po_reference            NVARCHAR(100)  = NULL,
    @invoice_reference       NVARCHAR(100)  = NULL,
    @decision_comments       NVARCHAR(2000) = NULL,
    @notes                   NVARCHAR(2000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @renewal_type = UPPER(NULLIF(LTRIM(RTRIM(@renewal_type)), N''));
    SET @currency_code = UPPER(NULLIF(LTRIM(RTRIM(@currency_code)), N''));
    SET @quotation_reference = NULLIF(LTRIM(RTRIM(@quotation_reference)), N'');
    SET @po_reference = NULLIF(LTRIM(RTRIM(@po_reference)), N'');
    SET @invoice_reference = NULLIF(LTRIM(RTRIM(@invoice_reference)), N'');
    SET @decision_comments = NULLIF(LTRIM(RTRIM(@decision_comments)), N'');
    SET @notes = NULLIF(LTRIM(RTRIM(@notes)), N'');

    DECLARE @found BIT = 0, @status NVARCHAR(60), @rv BIGINT, @old DATE;
    SELECT @found = 1, @status = s.status_code, @rv = CONVERT(BIGINT, r.record_version), @old = r.old_expiry
      FROM grac_practice.asset_contract_renewal r
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
     WHERE r.renewal_id = @renewal_id AND r.organization_id = @organization_id;
    IF @found = 0 THROW 54574, 'Renewal not found for this organization.', 1;
    IF @status <> N'OPEN'
        THROW 54575, 'Only an Open renewal can be edited; return or reopen it first.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54576, 'This renewal was changed by someone else. Reload and try again.', 1;
    IF @renewal_type IS NULL OR @renewal_type NOT IN (N'RENEWAL', N'EXTENSION', N'REBID', N'REPLACEMENT', N'NON_RENEWAL')
        THROW 54577, 'Select the renewal type: renewal, extension, rebid, replacement or non-renewal.', 1;
    IF @renewal_type = N'NON_RENEWAL'
        SELECT @new_expiry = NULL, @renewal_value = NULL, @currency_code = NULL;
    IF @renewal_type IN (N'RENEWAL', N'EXTENSION') AND @new_expiry IS NOT NULL AND @old IS NOT NULL AND @new_expiry <= @old
        THROW 54578, 'The new expiry date must follow the old expiry date.', 1;
    IF @renewal_value < 0
       OR (@renewal_value IS NULL AND @currency_code IS NOT NULL) OR (@renewal_value IS NOT NULL AND @currency_code IS NULL)
       OR (@currency_code IS NOT NULL AND (LEN(@currency_code) <> 3 OR @currency_code LIKE N'%[^A-Z]%'))
        THROW 54579, 'Enter the renewal value (not negative) together with a three-letter currency code.', 1;

    DECLARE @before NVARCHAR(MAX) = (SELECT renewal_type, new_expiry, renewal_value, currency_code, quotation_reference, po_reference,
                                            invoice_reference, decision_comments, notes
                                       FROM grac_practice.asset_contract_renewal WHERE renewal_id = @renewal_id
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    UPDATE grac_practice.asset_contract_renewal
       SET renewal_type = @renewal_type, new_expiry = @new_expiry, renewal_value = @renewal_value, currency_code = @currency_code,
           quotation_reference = @quotation_reference, po_reference = @po_reference, invoice_reference = @invoice_reference,
           decision_comments = @decision_comments, notes = @notes, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE renewal_id = @renewal_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-renewal', @renewal_id, N'UPDATE', @before,
            (SELECT renewal_type, new_expiry, renewal_value, currency_code, quotation_reference, po_reference, invoice_reference,
                    decision_comments, notes
               FROM grac_practice.asset_contract_renewal WHERE renewal_id = @renewal_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @renewal_id AS RenewalId, N'SAVED' AS Result;
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
    IF @action = N'APPROVE' AND (@actor_employee_id IS NULL OR @actor_employee_id = @submitter)
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

-- 9.1.5: an unresolved asset stays in the queue until mapped, separately
-- renewed, replaced, uninstalled, exempted or retired.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_renewal_item_resolve
    @organization_id BIGINT,
    @item_id         BIGINT,
    @resolution_code NVARCHAR(20),
    @note            NVARCHAR(1000),
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @resolution_code = UPPER(NULLIF(LTRIM(RTRIM(@resolution_code)), N''));
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    DECLARE @found BIT = 0, @result NVARCHAR(12), @code NVARCHAR(20);
    SELECT @found = 1, @result = i.reconciliation_result, @code = i.resolution_code
      FROM grac_practice.asset_contract_renewal_item i
      JOIN grac_practice.asset_contract_renewal r ON r.renewal_id = i.renewal_id
     WHERE i.item_id = @item_id AND r.organization_id = @organization_id;
    IF @found = 0 THROW 54588, 'Reconciliation item not found for this organization.', 1;
    IF @result <> N'UNRESOLVED' OR @code IS NOT NULL
        THROW 54589, 'Only an unresolved item that is not yet resolved can be resolved.', 1;
    IF @resolution_code IS NULL OR @resolution_code NOT IN (N'MAPPED', N'SEPARATELY_RENEWED', N'REPLACED', N'UNINSTALLED', N'EXEMPTED', N'RETIRED')
        THROW 54590, 'Select how it was resolved: mapped, separately renewed, replaced, uninstalled, exempted or retired.', 1;
    IF @note IS NULL THROW 54583, 'Give the reason.', 1;
    BEGIN TRAN;
    UPDATE grac_practice.asset_contract_renewal_item
       SET resolution_code = @resolution_code, resolution_note = @note, resolved_by = @actor, resolved_dt = SYSUTCDATETIME()
     WHERE item_id = @item_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-renewal-item', @item_id, N'RESOLVE', N'{"resolution":null}',
            (SELECT @resolution_code AS resolutionCode, @note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    COMMIT;
    SELECT @item_id AS ItemId, N'RESOLVED' AS Result;
END
GO
PRINT '436: renewal writers created.';
GO

-- =====================================================================
-- 6. Readers
-- =====================================================================
-- Renewal occurrences of the organization, or of one contract (7.2.3
-- Renewal History). @status: OPEN_ALL (open ones), a status code, or NULL.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_renewal_list
    @organization_id BIGINT,
    @contract_id     BIGINT        = NULL,
    @status          NVARCHAR(20)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SELECT r.renewal_id AS RenewalId, r.occurrence_key AS OccurrenceKey, r.contract_id AS ContractId, c.contract_number AS ContractNumber,
           c.contract_name AS ContractName, vd.vendor_name AS VendorName, r.renewal_type AS RenewalType, s.status_code AS StatusCode,
           s.status_name AS StatusName, r.due_date AS DueDate, r.old_expiry AS OldExpiry, r.new_expiry AS NewExpiry,
           r.renewal_value AS RenewalValue, r.currency_code AS CurrencyCode, r.quotation_reference AS QuotationReference,
           r.po_reference AS PoReference, r.invoice_reference AS InvoiceReference, pv.version_no AS PriorVersionNo,
           rv.version_no AS ResultingVersionNo, rc.contract_number AS ResultingContractNumber, r.outcome AS Outcome,
           ae.employee_name AS ApprovedByName, r.approval_dt AS ApprovalDt, r.completed_dt AS CompletedDt,
           (SELECT COUNT(*) FROM grac_practice.asset_contract_renewal_item i
             WHERE i.renewal_id = r.renewal_id AND i.reconciliation_result = N'UNRESOLVED' AND i.resolution_code IS NULL) AS OpenUnresolved,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_contract_renewal r
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
      JOIN grac_practice.asset_contract c ON c.contract_id = r.contract_id
      JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = c.vendor_id
      JOIN grac_practice.asset_contract_version pv ON pv.version_id = r.prior_version_id
      LEFT JOIN grac_practice.asset_contract_version rv ON rv.version_id = r.resulting_version_id
      LEFT JOIN grac_practice.asset_contract rc ON rc.contract_id = rv.contract_id
      LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = r.approved_by_employee_id
     WHERE r.organization_id = @organization_id
       AND (@contract_id IS NULL OR r.contract_id = @contract_id)
       AND (@status IS NULL OR (@status = N'OPEN_ALL' AND r.is_open = 1) OR s.status_code = @status)
       AND (@search IS NULL OR r.occurrence_key LIKE N'%' + @search + N'%' OR c.contract_number LIKE N'%' + @search + N'%'
            OR c.contract_name LIKE N'%' + @search + N'%' OR vd.vendor_name LIKE N'%' + @search + N'%')
     ORDER BY r.is_open DESC, r.due_date, r.renewal_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Contracts whose version in force (or last one that ended) reaches its
-- renewal alert date within @within_days and has no open or completed
-- renewal yet (9.1.5 earliest of notice date, decision date and end minus
-- the expiring window).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_renewal_due
    @organization_id BIGINT,
    @within_days     INT = 90
AS
BEGIN
    SET NOCOUNT ON;
    SET @within_days = CASE WHEN ISNULL(@within_days, 0) < 0 THEN 0 WHEN @within_days > 730 THEN 730 ELSE @within_days END;
    EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @win INT = ISNULL((SELECT expiring_window_days FROM grac_practice.asset_coverage_settings WHERE organization_id = @organization_id), 30);
    SELECT c.contract_id AS ContractId, c.contract_number AS ContractNumber, c.contract_name AS ContractName, vd.vendor_name AS VendorName,
           c.contract_status AS ContractStatus, cv.version_id AS VersionId, cv.version_no AS VersionNo, cv.effective_end AS EffectiveEnd,
           cv.notice_date AS NoticeDate, cv.decision_date AS DecisionDate, d.due AS DueDate, DATEDIFF(DAY, @today, d.due) AS DaysToDue,
           ow.employee_name AS ContractOwnerName
      FROM grac_practice.asset_contract c
      JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = c.vendor_id
      JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = cv.contract_owner_id
     CROSS APPLY (SELECT MIN(x.d) AS due FROM (VALUES (DATEADD(DAY, -@win, cv.effective_end)), (cv.notice_date), (cv.decision_date)) x(d)) d
     WHERE c.organization_id = @organization_id AND c.contract_status IN (N'ACTIVE', N'APPROVED', N'EXPIRED')
       AND cv.version_type <> N'TERMINATION' AND d.due <= DATEADD(DAY, @within_days, @today)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_renewal r
                        WHERE r.contract_id = c.contract_id
                          AND (r.is_open = 1 OR (r.prior_version_id = cv.version_id AND ISNULL(r.outcome, N'') <> N'CANCELLED')))
     ORDER BY d.due, c.contract_number;
END
GO

-- Renewal detail: 1. the occurrence  2. reconciliation (frozen when
-- completed, otherwise live against the linked version)  3. status history
-- 4. versions that can be linked (Approved, nothing linked yet).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_renewal_get
    @organization_id   BIGINT,
    @renewal_id        BIGINT,
    @actor_employee_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @status NVARCHAR(60), @prior BIGINT, @result BIGINT, @type NVARCHAR(20), @c BIGINT, @pno INT;
    SELECT @status = s.status_code, @prior = r.prior_version_id, @result = r.resulting_version_id, @type = r.renewal_type,
           @c = r.contract_id, @pno = pv.version_no
      FROM grac_practice.asset_contract_renewal r
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
      JOIN grac_practice.asset_contract_version pv ON pv.version_id = r.prior_version_id
     WHERE r.renewal_id = @renewal_id AND r.organization_id = @organization_id;
    IF @status IS NULL THROW 54574, 'Renewal not found for this organization.', 1;
    EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id;

    SELECT r.renewal_id AS RenewalId, r.occurrence_key AS OccurrenceKey, r.contract_id AS ContractId, c.contract_number AS ContractNumber,
           c.contract_name AS ContractName, vd.vendor_name AS VendorName, r.renewal_type AS RenewalType, s.status_code AS StatusCode,
           s.status_name AS StatusName, r.due_date AS DueDate, r.old_expiry AS OldExpiry, r.new_expiry AS NewExpiry,
           r.renewal_value AS RenewalValue, r.currency_code AS CurrencyCode, r.quotation_reference AS QuotationReference,
           r.po_reference AS PoReference, r.invoice_reference AS InvoiceReference, r.decision_comments AS DecisionComments,
           r.notes AS Notes, se.employee_name AS SubmittedByName, r.submitted_dt AS SubmittedDt, ae.employee_name AS ApprovedByName,
           r.approved_by AS ApprovedBy, r.approval_dt AS ApprovalDt, r.approval_comments AS ApprovalComments, r.outcome AS Outcome,
           ce.employee_name AS CompletedByName, r.completed_by AS CompletedBy, r.completed_dt AS CompletedDt, r.cancel_reason AS CancelReason,
           r.entered_by AS StartedBy, r.entered_dt AS StartedDt,
           pv.version_id AS PriorVersionId, pv.version_no AS PriorVersionNo, ps.status_name AS PriorVersionStatus,
           pv.effective_start AS PriorEffectiveStart, pv.effective_end AS PriorEffectiveEnd,
           rv.version_id AS ResultingVersionId, rv.version_no AS ResultingVersionNo, rs.status_name AS ResultingVersionStatus,
           rs.status_code AS ResultingVersionStatusCode, rv.effective_start AS ResultingEffectiveStart, rv.effective_end AS ResultingEffectiveEnd,
           rv.approval_dt AS ResultingApprovalDt, rc.contract_id AS ResultingContractId, rc.contract_number AS ResultingContractNumber,
           CASE WHEN @actor_employee_id IS NOT NULL AND r.submitted_by_employee_id = @actor_employee_id THEN 1 ELSE 0 END AS ActorIsSubmitter,
           CONVERT(BIGINT, r.record_version) AS RecordVersion
      FROM grac_practice.asset_contract_renewal r
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
      JOIN grac_practice.asset_contract c ON c.contract_id = r.contract_id
      JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = c.vendor_id
      JOIN grac_practice.asset_contract_version pv ON pv.version_id = r.prior_version_id
      JOIN grac_practice.entity_status_master ps ON ps.entity_status_id = pv.current_status_id
      LEFT JOIN grac_practice.asset_contract_version rv ON rv.version_id = r.resulting_version_id
      LEFT JOIN grac_practice.entity_status_master rs ON rs.entity_status_id = rv.current_status_id
      LEFT JOIN grac_practice.asset_contract rc ON rc.contract_id = rv.contract_id
      LEFT JOIN grac_practice.organization_employee se ON se.employee_id = r.submitted_by_employee_id
      LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = r.approved_by_employee_id
      LEFT JOIN grac_practice.organization_employee ce ON ce.employee_id = r.completed_by_employee_id
     WHERE r.renewal_id = @renewal_id;

    IF @status = N'COMPLETED'
    BEGIN
        SELECT i.item_id AS ItemId, i.item_kind AS ItemKind, i.asset_id AS AssetId, i.asset_name AS AssetName, i.coverage_type AS CoverageType,
               i.product_sku AS ProductSku, i.prior_state AS PriorState, i.result_state AS ResultState, i.prior_quantity AS PriorQuantity,
               i.result_quantity AS ResultQuantity, i.reconciliation_result AS ReconciliationResult, i.resolution_code AS ResolutionCode,
               i.resolution_note AS ResolutionNote, i.resolved_by AS ResolvedBy, i.resolved_dt AS ResolvedDt, CAST(1 AS BIT) AS IsFrozen
          FROM grac_practice.asset_contract_renewal_item i
         WHERE i.renewal_id = @renewal_id
         ORDER BY i.item_kind, CASE i.reconciliation_result WHEN N'UNRESOLVED' THEN 0 ELSE 1 END, i.asset_name, i.product_sku;
    END
    ELSE
    BEGIN
        DECLARE @rec_result BIGINT = CASE WHEN @type = N'NON_RENEWAL' THEN NULL ELSE @result END;
        SELECT CAST(NULL AS BIGINT) AS ItemId, x.ItemKind, x.AssetId, x.AssetName, x.CoverageType, x.ProductSku, x.PriorState, x.ResultState,
               x.PriorQuantity, x.ResultQuantity, x.ReconciliationResult, CAST(NULL AS NVARCHAR(20)) AS ResolutionCode,
               CAST(NULL AS NVARCHAR(1000)) AS ResolutionNote, CAST(NULL AS NVARCHAR(100)) AS ResolvedBy, CAST(NULL AS DATETIME2) AS ResolvedDt,
               CAST(0 AS BIT) AS IsFrozen
          FROM grac_practice.fn_asset_contract_reconciliation(@organization_id, @prior, @rec_result) x
         WHERE @type = N'NON_RENEWAL' OR @rec_result IS NOT NULL
         ORDER BY x.ItemKind, CASE x.ReconciliationResult WHEN N'UNRESOLVED' THEN 0 ELSE 1 END, x.AssetName, x.ProductSku;
    END

    SELECT l.transition_log_id AS TransitionLogId, fs.status_name AS FromStatus, ts.status_name AS ToStatus, l.reason_code AS ReasonCode,
           l.reason_text AS ReasonText, emp.employee_name AS ActorName, l.transitioned_at AS TransitionedAt
      FROM grac_practice.entity_state_transition_log l
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_status_id = l.from_status_id
      JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = l.to_status_id
      LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id = l.actor_employee_id
     WHERE l.entity_type = N'ContractRenewal' AND l.entity_id = @renewal_id
     ORDER BY l.transitioned_at DESC, l.transition_log_id DESC;

    SELECT v.version_id AS VersionId, v.version_no AS VersionNo, v.version_type AS VersionType, s.status_name AS StatusName,
           c.contract_number AS ContractNumber, c.contract_name AS ContractName, v.effective_start AS EffectiveStart, v.effective_end AS EffectiveEnd
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
      JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
     WHERE @status = N'APPROVED' AND @result IS NULL AND @type <> N'NON_RENEWAL'
       AND v.organization_id = @organization_id AND v.version_id <> @prior AND s.status_code <> N'REJECTED'
       AND v.version_type <> N'TERMINATION'
       AND (@type IN (N'REBID', N'REPLACEMENT') OR (v.contract_id = @c AND v.version_no > @pno))
     ORDER BY CASE WHEN v.contract_id = @c THEN 0 ELSE 1 END, c.contract_number, v.version_no DESC;
END
GO
PRINT '436: renewal readers created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '436-a renewal statuses and transitions seeded' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.entity_status_master WHERE entity_type = N'ContractRenewal') = 5
             AND (SELECT COUNT(*) FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'ContractRenewal') >= 9
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '436-b tables and the one-open-renewal index present',
       CASE WHEN OBJECT_ID('grac_practice.asset_contract_renewal','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_contract_renewal_item','U') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_asset_c_ren_open' AND is_unique = 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '436-c procedures and function present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_contract_renewal_move', 'sp_asset_contract_renewal_start', 'sp_asset_contract_renewal_save',
                                'sp_asset_contract_renewal_action', 'sp_asset_contract_renewal_item_resolve', 'sp_asset_contract_renewal_list',
                                'sp_asset_contract_renewal_due', 'sp_asset_contract_renewal_get')) = 8
             AND OBJECT_ID('grac_practice.fn_asset_contract_reconciliation') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '436-d version create re-issued (suppress result, coverage copy kept)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_contract_version_create')) LIKE '%@suppress_result%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_contract_version_create')) LIKE '%asset_contract_coverage%'
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build)
--   Needs an Active contract (434) whose version covers two assets (435)
--   of an asset type that requires AMC coverage, and two people (A, B).
--   1. Contracts -> Renewals -> Due for renewal (180 days): the contract is
--      listed with its due date (earliest of notice, decision, end minus
--      the window). Start renewal (Renewal) -> occurrence CR-<id>-V1-1, Open.
--      Starting a second renewal for the contract is refused.
--   2. As A: enter the new expiry (before the old one -> refused), value +
--      currency, quotation / PO, decision comments; Submit. A cannot
--      approve; as B: Approve.
--   3. Create version -> a Renewal draft of the contract with the new expiry
--      and value, copied coverage and entitlements. Remove one asset from
--      its coverage. The renewal shows the live reconciliation: one
--      Covered, one Unresolved (AMC required, no other contract).
--   4. Complete before the version is approved -> refused. Approve the
--      version (434 workflow), then Complete -> outcome Partially Renewed,
--      new expiry = version end, reconciliation frozen. Resolve the
--      unresolved asset (Exempted + reason) -> resolved.
--   5. Contract dialog -> Renewal history shows the occurrence with old /
--      new expiry, value, references, resulting version and outcome.
--   6. A Non-renewal completed without a version -> Not Renewed, every
--      prior asset Removed / Unresolved; the contract and its versions stay.
-- =====================================================================
