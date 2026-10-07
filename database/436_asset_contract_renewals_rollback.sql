-- =====================================================================
-- 436 rollback -- Contract renewal occurrences and coverage reconciliation
--
--   * restores the 435 body of sp_asset_contract_version_create (verbatim
--     below);
--   * drops the renewal procedures and the reconciliation function;
--   * drops asset_contract_renewal_item and asset_contract_renewal (every
--     renewal occurrence and frozen reconciliation is lost; resulting
--     contract versions stay);
--   * removes the ContractRenewal transition rules. The statuses stay
--     because the immutable transition log references them.
-- practice_audit_trace rows stay as history. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

-- sp_asset_contract_version_create (435) body, verbatim
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_version_create
    @organization_id   BIGINT,
    @contract_id       BIGINT,
    @version_type      NVARCHAR(20),
    @change_summary    NVARCHAR(2000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
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

    SELECT @version_id AS VersionId, N'CREATED' AS Result;
END
GO
PRINT '436 rollback: sp_asset_contract_version_create restored.';
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_renewal_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_renewal_due;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_renewal_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_renewal_item_resolve;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_renewal_action;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_renewal_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_renewal_start;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_renewal_move;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_contract_reconciliation;
PRINT '436 rollback: procedures and function dropped.';
GO

DROP TABLE IF EXISTS grac_practice.asset_contract_renewal_item;
DROP TABLE IF EXISTS grac_practice.asset_contract_renewal;
DELETE FROM grac_practice.entity_state_transition_rule
 WHERE entity_type = N'ContractRenewal' AND entered_by = N'seed-436';
PRINT '436 rollback: tables and rules removed.';
GO

SELECT '436 rollback: renewal objects gone, 435 version create restored' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_contract_renewal','U') IS NULL
             AND OBJECT_ID('grac_practice.fn_asset_contract_reconciliation') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_contract_version_create')) NOT LIKE '%@suppress_result%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_contract_version_create')) LIKE '%asset_contract_coverage%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
