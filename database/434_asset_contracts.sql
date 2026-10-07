-- =====================================================================
-- 434  Contracts -- contract register, immutable contract versions and
--      vendor contact mapping
--      (Asset & Contract Management, Phase 5 increment 1)
--
-- REQUEST
-- -------
--   BRD v1.7 7 "Contract Management and Asset Mapping" (identity, parties,
--   dates, commercial, service domains), 7.2 "Contract Version
--   Management" (7.2.1 fields, 7.2.2 creation / approval rules, 7.2.3
--   historical view and subsections, 7.2.4 comparison), 7.4 "Vendor Module
--   Integration and Contract Contact Mapping" (7.4.1 vendor selection,
--   7.4.2 mapping fields, 7.4.3 roles, 7.4.4 history / data quality),
--   16.6 acceptance criteria. Plan in docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. ContractVersion statuses (7.2.1: Draft, In Review, Pending
--      Approval, Approved, Active, Superseded, Expired, Terminated,
--      Rejected) and their transitions on the state machine (035).
--   2. asset_contract -- one parent record per contract: contract ID
--      (unique per organization), name, type (the organization coverage
--      type list, 423), parent agreement, vendor (the Vendor Module record
--      organization_dependency_vendor -- not copied, D2), description and
--      the derived contract status / current version.
--   3. asset_contract_version -- every revision (7.2.1): number, type
--      (Initial, Renewal, Amendment, Extension, Variation, Correction,
--      Termination), status, effective start / end, notice, decision and
--      termination dates, value / currency / tax / payment / PO / invoice /
--      cost allocation, renewal terms, scope / SLA / support hours /
--      response / resolution / visits, internal contract and procurement
--      owners, change summary, created / submitted / reviewed / approved
--      by, approval date, supersedes / superseded by. Only a Draft can be
--      edited; after approval the row is immutable (7.2.2).
--   4. asset_contract_document -- signed agreement, schedules, amendments,
--      quotation / PO / invoice and supporting evidence per version, as
--      references (document number, link) -- D17.
--   5. asset_contract_contact_role (7.4.2 / 7.4.3 roles) and
--      asset_contract_contact -- vendor contact mappings: vendor user
--      (ThirdParty person of the contract vendor, D2), role, primary for
--      role, effective start / end, status (Active, Inactive, Pending
--      Validation), preferred channel, notification participation, notes,
--      created / validated by. Ending sets an end date; nothing is
--      deleted (7.4.4). asset_contract_version_contact is the vendor and
--      contact snapshot taken when a version is approved (7.2.1, 7.4.4).
--   6. sp_asset_contract_sync -- activates an approved version on its
--      effective date (the previous Active version becomes Superseded, or
--      Expired when it ended before), expires versions past their end
--      date, applies a Termination version, ends contact mappings past
--      their end date, and derives the contract status (D35). Called by
--      the readers and the writers -- no scheduler exists yet (Phase 6).
--   7. Writers: contract save (creates Version 1 as Draft), new version
--      (copy of the effective version), draft save, version actions
--      (Submit, Review, Return, Reject, Approve, Withdraw) with segregation
--      of duties, contact mapping save / validate / end, document add /
--      remove. Every change writes practice_audit_trace (before / after,
--      actor, reason); every status move writes the transition log.
--   8. Readers: list, contract (summary, version history, contacts,
--      documents, approval history, contact history, activation
--      warnings), version detail, version comparison (fields and contact
--      roles), lookups.
--   9. Menu "Contracts" (asset-contracts) under Asset & Contract; Admin
--      VIEW / ADD / EDIT / APPROVE.
--
-- NOT DONE HERE: asset coverage and entitlements (5.1.11, 7 Coverage --
--   next increment), renewal occurrences and coverage reconciliation
--   (7.3 -- next increment), contract activities, reminders and
--   notification recipients (7.1, 7.4.5 -> Phase 6), contract-to-service
--   mapping (19.6 -> Phase 7), formally approved version overlap (not
--   configured, so not allowed), file storage for documents (references
--   only, D17).
--
-- ERROR NUMBERS: 54510-54549
--   54510 organization not found          54511 contract not found
--   54512 contract ID required / in use    54513 contract name required
--   54514 contract type not in the list    54515 vendor not valid
--   54516 vendor / type locked             54517 parent agreement not valid
--   54518 contract changed by someone else 54519 version not found
--   54520 contract terminated              54521 version type not valid
--   54522 an open draft exists             54523 change summary required
--   54524 version is not a Draft           54525 version changed by someone else
--   54526 date sequence                    54527 value / currency
--   54528 owner not valid                  54529 wrong status for the action
--   54530 segregation of duties            54531 note / reason required
--   54532 overlapping version              54533 contract terminates first
--   54534 starts before the version it replaces 54535 version not usable
--   54536 vendor user not valid            54537 role / channel not valid
--   54538 duplicate primary for role       54539 person already mapped
--   54540 mapping not found                54541 mapping change not allowed
--   54542 documents locked                 54543 versions not comparable
--   54544 document not found               54545 document type / reference
--   54546 unknown action                   54547 version incomplete
--   54548 contact mapping changed by someone else
--
-- ALSO EDITED: 274_menu_master_seed.sql, API (AssetConfig service /
--   controller / models), Web proxy, PracticeScreen.cs, Manage.cshtml, both
--   appsettings.json, new partial + script asset-contracts, docs.
--   Also fixes 433 (option group names of the destination lists).
-- DEPENDS ON: 035, 133, 423.
-- Rollback: 434_asset_contracts_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_pm_state_transition','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_field_options') IS NULL
   OR OBJECT_ID('grac_practice.organization_dependency_vendor','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','provider_vendor_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','party_type') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-asset-contract')
BEGIN
    RAISERROR('ABORT (434): run 035, 133, 420 and 423 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. ContractVersion statuses (7.2.1) on the state machine
-- =====================================================================
MERGE grac_practice.entity_status_master AS t
USING (VALUES
    (N'ContractVersion', N'DRAFT',            N'Draft',            10, 0, 1),
    (N'ContractVersion', N'IN_REVIEW',        N'In Review',        20, 0, 0),
    (N'ContractVersion', N'PENDING_APPROVAL', N'Pending Approval', 30, 0, 0),
    (N'ContractVersion', N'APPROVED',         N'Approved',         40, 0, 0),
    (N'ContractVersion', N'ACTIVE',           N'Active',           50, 0, 0),
    (N'ContractVersion', N'SUPERSEDED',       N'Superseded',       60, 1, 0),
    (N'ContractVersion', N'EXPIRED',          N'Expired',          70, 1, 0),
    (N'ContractVersion', N'TERMINATED',       N'Terminated',       80, 1, 0),
    (N'ContractVersion', N'REJECTED',         N'Rejected',         90, 1, 0)
) AS s(entity_type, status_code, status_name, display_order, is_terminal, is_initial)
ON t.entity_type = s.entity_type AND t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, status_code, status_name, display_order, is_terminal, is_initial, description, entered_by)
    VALUES (s.entity_type, s.status_code, s.status_name, s.display_order, s.is_terminal, s.is_initial,
            N'BRD v1.7 7.2.1 contract version status.', N'seed-434');
PRINT CONCAT('434: contract version statuses inserted: ', @@ROWCOUNT);
GO

MERGE grac_practice.entity_state_transition_rule AS t
USING (VALUES
    (CAST(NULL AS NVARCHAR(60)), N'DRAFT', 0, N'Version created as a draft.'),
    (N'DRAFT', N'IN_REVIEW', 0, N'Submitted for review.'),
    (N'IN_REVIEW', N'PENDING_APPROVAL', 0, N'Review completed; awaiting approval.'),
    (N'IN_REVIEW', N'DRAFT', 1, N'Returned to draft.'),
    (N'PENDING_APPROVAL', N'DRAFT', 1, N'Returned to draft.'),
    (N'IN_REVIEW', N'REJECTED', 1, N'Rejected in review.'),
    (N'PENDING_APPROVAL', N'REJECTED', 1, N'Rejected at approval.'),
    (N'DRAFT', N'REJECTED', 1, N'Draft withdrawn (kept for audit, never effective).'),
    (N'PENDING_APPROVAL', N'APPROVED', 0, N'Approved; becomes Active on its effective start date.'),
    (N'APPROVED', N'ACTIVE', 0, N'Effective start date reached.'),
    (N'APPROVED', N'SUPERSEDED', 1, N'Replaced before taking effect (termination took effect first).'),
    (N'APPROVED', N'TERMINATED', 1, N'Termination version took effect.'),
    (N'ACTIVE', N'SUPERSEDED', 1, N'A later version took effect.'),
    (N'ACTIVE', N'EXPIRED', 1, N'Effective end date passed.'),
    (N'ACTIVE', N'TERMINATED', 1, N'Contract terminated.')
) AS s(from_status_code, to_status_code, requires_reason, description)
ON t.entity_type = N'ContractVersion'
   AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(s.from_status_code, N'__NULL__')
   AND t.to_status_code = s.to_status_code AND t.actor_role_code IS NULL
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, requires_approval, description, entered_by)
    VALUES (N'ContractVersion', s.from_status_code, s.to_status_code, NULL, s.requires_reason, 0, s.description, N'seed-434');
PRINT CONCAT('434: contract version transition rules inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 2. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_contract','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_contract (
        contract_id        BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_contract PRIMARY KEY,
        organization_id    BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_contract_org REFERENCES grac_practice.organization(organization_id),
        contract_number    NVARCHAR(60)   NOT NULL,
        contract_name      NVARCHAR(250)  NOT NULL,
        contract_type      NVARCHAR(160)  NOT NULL,      -- option value of asset_field.coverage_type (423)
        parent_contract_id BIGINT         NULL
            CONSTRAINT fk_pm_asset_contract_parent REFERENCES grac_practice.asset_contract(contract_id),
        vendor_id          BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_contract_vendor REFERENCES grac_practice.organization_dependency_vendor(vendor_id),
        description        NVARCHAR(2000) NULL,
        contract_status    NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_asset_contract_status DEFAULT N'DRAFT'
            CONSTRAINT ck_pm_asset_contract_status CHECK (contract_status IN (N'DRAFT', N'APPROVED', N'ACTIVE', N'EXPIRED', N'TERMINATED')),
        current_version_id BIGINT         NULL,
        record_version     ROWVERSION     NOT NULL,
        entered_by         NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_contract_eby DEFAULT N'system',
        entered_dt         DATETIME2      NOT NULL CONSTRAINT df_pm_asset_contract_edt DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100)  NULL,
        updated_dt         DATETIME2      NULL,
        CONSTRAINT uq_pm_asset_contract_number UNIQUE (organization_id, contract_number)
    );
    CREATE INDEX ix_pm_asset_contract_vendor ON grac_practice.asset_contract(organization_id, vendor_id);
    PRINT '434: asset_contract created.';
END
GO

IF OBJECT_ID('grac_practice.asset_contract_version','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_contract_version (
        version_id                 BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_contract_version PRIMARY KEY,
        contract_id                BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_cv_contract REFERENCES grac_practice.asset_contract(contract_id),
        organization_id            BIGINT         NOT NULL,
        version_no                 INT            NOT NULL,
        version_label              NVARCHAR(40)   NULL,
        version_type               NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_cv_type CHECK (version_type IN (N'INITIAL', N'RENEWAL', N'AMENDMENT', N'EXTENSION',
                                                                  N'VARIATION', N'CORRECTION', N'TERMINATION')),
        current_status_id          INT            NOT NULL
            CONSTRAINT fk_pm_asset_cv_status REFERENCES grac_practice.entity_status_master(entity_status_id),
        effective_start            DATE           NULL,
        effective_end              DATE           NULL,
        notice_date                DATE           NULL,
        decision_date              DATE           NULL,
        termination_date           DATE           NULL,
        contract_value             DECIMAL(18,2)  NULL,
        currency_code              NVARCHAR(3)    NULL,
        tax_details                NVARCHAR(200)  NULL,
        payment_terms              NVARCHAR(400)  NULL,
        po_reference               NVARCHAR(100)  NULL,
        invoice_reference          NVARCHAR(100)  NULL,
        cost_allocation            NVARCHAR(400)  NULL,
        renewal_terms              NVARCHAR(1000) NULL,
        service_scope              NVARCHAR(2000) NULL,
        sla_terms                  NVARCHAR(2000) NULL,
        support_hours              NVARCHAR(200)  NULL,
        response_time              NVARCHAR(100)  NULL,
        resolution_time            NVARCHAR(100)  NULL,
        service_visits             NVARCHAR(100)  NULL,
        contract_owner_id          BIGINT         NULL,
        procurement_owner_id       BIGINT         NULL,
        vendor_id                  BIGINT         NULL,      -- snapshot at approval (7.4.1)
        vendor_name_snapshot       NVARCHAR(220)  NULL,
        change_summary             NVARCHAR(2000) NULL,
        created_by_employee_id     BIGINT         NULL,
        submitted_by               NVARCHAR(100)  NULL,
        submitted_by_employee_id   BIGINT         NULL,
        submitted_dt               DATETIME2      NULL,
        reviewed_by                NVARCHAR(100)  NULL,
        reviewed_by_employee_id    BIGINT         NULL,
        reviewed_dt                DATETIME2      NULL,
        approved_by                NVARCHAR(100)  NULL,
        approved_by_employee_id    BIGINT         NULL,
        approval_dt                DATETIME2      NULL,
        decision_note              NVARCHAR(1000) NULL,
        supersedes_version_id      BIGINT         NULL,
        superseded_by_version_id   BIGINT         NULL,
        activated_dt               DATETIME2      NULL,
        closed_dt                  DATETIME2      NULL,
        record_version             ROWVERSION     NOT NULL,
        entered_by                 NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_cv_eby DEFAULT N'system',
        entered_dt                 DATETIME2      NOT NULL CONSTRAINT df_pm_asset_cv_edt DEFAULT SYSUTCDATETIME(),
        updated_by                 NVARCHAR(100)  NULL,
        updated_dt                 DATETIME2      NULL,
        CONSTRAINT uq_pm_asset_cv_no UNIQUE (contract_id, version_no)
    );
    CREATE INDEX ix_pm_asset_cv_status ON grac_practice.asset_contract_version(organization_id, current_status_id);
    PRINT '434: asset_contract_version created.';
END
GO

IF OBJECT_ID('grac_practice.asset_contract_document','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_contract_document (
        document_id     BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_contract_doc PRIMARY KEY,
        organization_id BIGINT         NOT NULL,
        contract_id     BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_cdoc_contract REFERENCES grac_practice.asset_contract(contract_id),
        version_id      BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_cdoc_version REFERENCES grac_practice.asset_contract_version(version_id),
        document_type   NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_asset_cdoc_type CHECK (document_type IN (N'SIGNED_AGREEMENT', N'SCHEDULE', N'AMENDMENT', N'QUOTATION',
                                                                      N'PURCHASE_ORDER', N'INVOICE', N'SUPPORTING_EVIDENCE', N'OTHER')),
        title           NVARCHAR(250)  NOT NULL,
        reference_text  NVARCHAR(1000) NOT NULL,
        status          NVARCHAR(10)   NOT NULL CONSTRAINT df_pm_asset_cdoc_status DEFAULT N'ACTIVE'
            CONSTRAINT ck_pm_asset_cdoc_status CHECK (status IN (N'ACTIVE', N'REMOVED')),
        removed_by      NVARCHAR(100)  NULL,
        removed_dt      DATETIME2      NULL,
        entered_by      NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_cdoc_eby DEFAULT N'system',
        entered_dt      DATETIME2      NOT NULL CONSTRAINT df_pm_asset_cdoc_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_asset_cdoc_version ON grac_practice.asset_contract_document(version_id);
    PRINT '434: asset_contract_document created.';
END
GO

IF OBJECT_ID('grac_practice.asset_contract_contact_role','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_contract_contact_role (
        role_code     NVARCHAR(40)  NOT NULL CONSTRAINT pk_pm_asset_contract_role PRIMARY KEY,
        role_name     NVARCHAR(100) NOT NULL,
        typical_use   NVARCHAR(300) NULL,
        is_mandatory  BIT           NOT NULL CONSTRAINT df_pm_asset_contract_role_mand DEFAULT 0,
        display_order INT           NOT NULL,
        is_active     BIT           NOT NULL CONSTRAINT df_pm_asset_contract_role_active DEFAULT 1,
        entered_by    NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_contract_role_eby DEFAULT N'system',
        entered_dt    DATETIME2     NOT NULL CONSTRAINT df_pm_asset_contract_role_edt DEFAULT SYSUTCDATETIME()
    );
    PRINT '434: asset_contract_contact_role created.';
END
GO

-- 7.4.2 role list with the 7.4.3 typical use. Primary Contact is the
-- default vendor contact, so it is the one mandatory role (D38).
MERGE grac_practice.asset_contract_contact_role AS t
USING (VALUES
    (N'PRIMARY_CONTACT',          N'Primary Contact',          N'Default vendor contact for the contract', 1, 10),
    (N'ACCOUNT_MANAGER',          N'Account Manager',          N'Pricing, quotation, renewal and commercial discussion', 0, 20),
    (N'COMMERCIAL',               N'Commercial',               N'Pricing, quotation, renewal and commercial discussion', 0, 30),
    (N'TECHNICAL',                N'Technical',                N'Technical incidents, support cases and service coordination', 0, 40),
    (N'SERVICE_DELIVERY_MANAGER', N'Service Delivery Manager', N'Operational reviews, SLA and service performance', 0, 50),
    (N'SUPPORT',                  N'Support',                  N'Technical incidents, support cases and service coordination', 0, 60),
    (N'ESCALATION',               N'Escalation',               N'Management escalation for unresolved or critical issues', 0, 70),
    (N'BILLING',                  N'Billing',                  N'Invoice, tax and payment coordination', 0, 80),
    (N'LEGAL',                    N'Legal',                    N'Terms, amendment and legal notices', 0, 90),
    (N'DATA_PROTECTION',          N'Data Protection',          N'Privacy, processor and data-protection matters', 0, 100),
    (N'OTHER',                    N'Other',                    NULL, 0, 110)
) AS s(role_code, role_name, typical_use, is_mandatory, display_order)
ON t.role_code = s.role_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (role_code, role_name, typical_use, is_mandatory, display_order, entered_by)
    VALUES (s.role_code, s.role_name, s.typical_use, s.is_mandatory, s.display_order, N'seed-434');
PRINT CONCAT('434: contact roles inserted: ', @@ROWCOUNT);
GO

IF OBJECT_ID('grac_practice.asset_contract_contact','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_contract_contact (
        mapping_id                 BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_contract_contact PRIMARY KEY,
        organization_id            BIGINT         NOT NULL,
        contract_id                BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_cc_contract REFERENCES grac_practice.asset_contract(contract_id),
        version_id                 BIGINT         NULL      -- NULL = every version (contract-wide)
            CONSTRAINT fk_pm_asset_cc_version REFERENCES grac_practice.asset_contract_version(version_id),
        vendor_id                  BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_cc_vendor REFERENCES grac_practice.organization_dependency_vendor(vendor_id),
        employee_id                BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_cc_employee REFERENCES grac_practice.organization_employee(employee_id),
        role_code                  NVARCHAR(40)   NOT NULL
            CONSTRAINT fk_pm_asset_cc_role REFERENCES grac_practice.asset_contract_contact_role(role_code),
        is_primary                 BIT            NOT NULL CONSTRAINT df_pm_asset_cc_primary DEFAULT 0,
        effective_start            DATE           NOT NULL,
        effective_end              DATE           NULL,
        status                     NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_asset_cc_status DEFAULT N'PENDING_VALIDATION'
            CONSTRAINT ck_pm_asset_cc_status CHECK (status IN (N'ACTIVE', N'INACTIVE', N'PENDING_VALIDATION')),
        preferred_channel          NVARCHAR(10)   NOT NULL CONSTRAINT df_pm_asset_cc_channel DEFAULT N'EMAIL'
            CONSTRAINT ck_pm_asset_cc_channel CHECK (preferred_channel IN (N'EMAIL', N'PHONE', N'PORTAL', N'OTHER')),
        notification_participation BIT            NOT NULL CONSTRAINT df_pm_asset_cc_notify DEFAULT 1,
        notes                      NVARCHAR(1000) NULL,
        created_by_employee_id     BIGINT         NULL,
        validated_by               NVARCHAR(100)  NULL,
        validated_by_employee_id   BIGINT         NULL,
        validated_dt               DATETIME2      NULL,
        end_reason                 NVARCHAR(1000) NULL,
        record_version             ROWVERSION     NOT NULL,
        entered_by                 NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_cc_eby DEFAULT N'system',
        entered_dt                 DATETIME2      NOT NULL CONSTRAINT df_pm_asset_cc_edt DEFAULT SYSUTCDATETIME(),
        updated_by                 NVARCHAR(100)  NULL,
        updated_dt                 DATETIME2      NULL
    );
    CREATE INDEX ix_pm_asset_cc_contract ON grac_practice.asset_contract_contact(contract_id, role_code, status);
    PRINT '434: asset_contract_contact created.';
END
GO

IF OBJECT_ID('grac_practice.asset_contract_version_contact','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_contract_version_contact (
        snapshot_id                BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_cv_contact PRIMARY KEY,
        version_id                 BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_cvc_version REFERENCES grac_practice.asset_contract_version(version_id),
        mapping_id                 BIGINT         NOT NULL,
        role_code                  NVARCHAR(40)   NOT NULL,
        role_name                  NVARCHAR(100)  NOT NULL,
        is_primary                 BIT            NOT NULL,
        employee_id                BIGINT         NOT NULL,
        contact_name               NVARCHAR(200)  NOT NULL,
        contact_email              NVARCHAR(250)  NULL,
        vendor_id                  BIGINT         NOT NULL,
        vendor_name                NVARCHAR(220)  NOT NULL,
        preferred_channel          NVARCHAR(10)   NOT NULL,
        notification_participation BIT            NOT NULL,
        effective_start            DATE           NOT NULL,
        effective_end              DATE           NULL,
        entered_by                 NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_cvc_eby DEFAULT N'system',
        entered_dt                 DATETIME2      NOT NULL CONSTRAINT df_pm_asset_cvc_edt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_asset_cvc UNIQUE (version_id, mapping_id)
    );
    PRINT '434: asset_contract_version_contact created.';
END
GO

-- =====================================================================
-- 3. Functions
-- =====================================================================
-- Vendor contacts of a version: the snapshot taken at approval; before
-- approval, the live mappings (contract-wide or for this version) that
-- overlap the version dates (7.2.1 Vendor and Contact Snapshot, 7.4.4).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_contract_version_contacts (@version_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT s.mapping_id AS MappingId, s.role_code AS RoleCode, s.role_name AS RoleName, s.is_primary AS IsPrimary,
           s.employee_id AS EmployeeId, s.contact_name AS ContactName, s.contact_email AS ContactEmail, s.vendor_name AS VendorName,
           s.preferred_channel AS PreferredChannel, s.notification_participation AS NotificationParticipation,
           s.effective_start AS EffectiveStart, s.effective_end AS EffectiveEnd,
           CAST(N'SNAPSHOT' AS NVARCHAR(10)) AS Source, CAST(N'ACTIVE' AS NVARCHAR(20)) AS MappingStatus
      FROM grac_practice.asset_contract_version_contact s
      JOIN grac_practice.asset_contract_version v ON v.version_id = s.version_id
     WHERE s.version_id = @version_id AND v.approval_dt IS NOT NULL
    UNION ALL
    SELECT m.mapping_id, m.role_code, r.role_name, m.is_primary, m.employee_id, e.employee_name, e.email, vd.vendor_name,
           m.preferred_channel, m.notification_participation, m.effective_start, m.effective_end,
           CAST(N'LIVE' AS NVARCHAR(10)), m.status
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.asset_contract_contact m
        ON m.contract_id = v.contract_id AND (m.version_id IS NULL OR m.version_id = v.version_id)
      JOIN grac_practice.asset_contract_contact_role r ON r.role_code = m.role_code
      JOIN grac_practice.organization_employee e ON e.employee_id = m.employee_id
      JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = m.vendor_id
     WHERE v.version_id = @version_id AND v.approval_dt IS NULL
       AND m.status IN (N'ACTIVE', N'PENDING_VALIDATION')
       AND m.effective_start <= ISNULL(v.effective_end, CAST('9999-12-31' AS DATE))
       AND ISNULL(m.effective_end, CAST('9999-12-31' AS DATE)) >= ISNULL(v.effective_start, CAST('0001-01-01' AS DATE));
GO

-- Warnings shown before submission / approval (7.4.4: missing or inactive
-- mandatory contacts create a validation warning before activation or
-- renewal approval). They do not block (D38).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_contract_readiness (@version_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT CAST(N'MISSING_ROLE' AS NVARCHAR(30)) AS WarningCode, r.role_code AS RoleCode,
           CAST(CONCAT(N'No validated ', r.role_name, N' contact is effective on ', CONVERT(NVARCHAR(10), d.on_date, 23), N'.')
                AS NVARCHAR(400)) AS Warning
      FROM grac_practice.asset_contract_version v
     CROSS APPLY (SELECT ISNULL(v.effective_start, CAST(SYSUTCDATETIME() AS DATE)) AS on_date) d
      JOIN grac_practice.asset_contract_contact_role r ON r.is_mandatory = 1 AND r.is_active = 1
     WHERE v.version_id = @version_id
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_contact m
                         JOIN grac_practice.organization_employee e ON e.employee_id = m.employee_id
                        WHERE m.contract_id = v.contract_id AND m.role_code = r.role_code AND m.status = N'ACTIVE'
                          AND (m.version_id IS NULL OR m.version_id = v.version_id)
                          AND m.effective_start <= d.on_date
                          AND ISNULL(m.effective_end, CAST('9999-12-31' AS DATE)) >= d.on_date
                          AND e.status = N'Active')
    UNION ALL
    SELECT CAST(N'INACTIVE_USER' AS NVARCHAR(30)), m.role_code,
           CAST(CONCAT(e.employee_name, N' (', r.role_name, N') is not an active user of the contract vendor.') AS NVARCHAR(400))
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
      JOIN grac_practice.asset_contract_contact m
        ON m.contract_id = v.contract_id AND (m.version_id IS NULL OR m.version_id = v.version_id)
      JOIN grac_practice.asset_contract_contact_role r ON r.role_code = m.role_code
      JOIN grac_practice.organization_employee e ON e.employee_id = m.employee_id
     WHERE v.version_id = @version_id AND m.status IN (N'ACTIVE', N'PENDING_VALIDATION')
       AND ISNULL(m.effective_end, CAST('9999-12-31' AS DATE)) >= CAST(SYSUTCDATETIME() AS DATE)
       AND (e.status <> N'Active' OR ISNULL(e.provider_vendor_id, -1) <> c.vendor_id)
    UNION ALL
    SELECT CAST(N'PENDING_VALIDATION' AS NVARCHAR(30)), m.role_code,
           CAST(CONCAT(e.employee_name, N' (', r.role_name, N') is pending validation and will not be part of the approved version.')
                AS NVARCHAR(400))
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.asset_contract_contact m
        ON m.contract_id = v.contract_id AND (m.version_id IS NULL OR m.version_id = v.version_id)
      JOIN grac_practice.asset_contract_contact_role r ON r.role_code = m.role_code
      JOIN grac_practice.organization_employee e ON e.employee_id = m.employee_id
     WHERE v.version_id = @version_id AND m.status = N'PENDING_VALIDATION';
GO
PRINT '434: functions created.';
GO

-- =====================================================================
-- 4. Internal procedures
-- =====================================================================
-- One status move of a version: transition log + audit (035) and the row.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_version_move
    @version_id        BIGINT,
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
         @entity_type = N'ContractVersion', @entity_id = @version_id,
         @from_status_code = @from_code, @to_status_code = @to_code,
         @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
         @reason_code = @reason_code, @reason_text = @reason_text,
         @to_status_id = @sid OUTPUT, @transition_log_id = @log OUTPUT;
    UPDATE grac_practice.asset_contract_version
       SET current_status_id = @sid,
           activated_dt = CASE WHEN @to_code = N'ACTIVE' THEN SYSUTCDATETIME() ELSE activated_dt END,
           closed_dt = CASE WHEN @to_code IN (N'SUPERSEDED', N'EXPIRED', N'TERMINATED', N'REJECTED') THEN SYSUTCDATETIME() ELSE closed_dt END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE version_id = @version_id;
END
GO

-- Date-driven processing (D35): activation on the effective start date,
-- expiry after the end date, termination, contact mappings past their end
-- date, and the derived contract status / current version. Idempotent.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_sync
    @organization_id BIGINT,
    @contract_id     BIGINT        = NULL,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @st_approved INT = grac_practice.fn_get_entity_status_id(N'ContractVersion', N'APPROVED'),
            @st_active   INT = grac_practice.fn_get_entity_status_id(N'ContractVersion', N'ACTIVE');
    DECLARE @v BIGINT, @c BIGINT, @type NVARCHAR(20), @start DATE, @no INT, @prev BIGINT, @prev_end DATE, @prev_to NVARCHAR(20),
            @x BIGINT, @why NVARCHAR(400);

    -- 1. Approved versions whose effective start date has been reached.
    DECLARE act_cur CURSOR LOCAL STATIC FOR
        SELECT version_id, contract_id, version_type, effective_start, version_no
          FROM grac_practice.asset_contract_version
         WHERE organization_id = @organization_id AND (@contract_id IS NULL OR contract_id = @contract_id)
           AND current_status_id = @st_approved AND effective_start <= @today
         ORDER BY contract_id, effective_start, version_no;
    OPEN act_cur;
    FETCH NEXT FROM act_cur INTO @v, @c, @type, @start, @no;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.asset_contract_version WHERE version_id = @v AND current_status_id = @st_approved)
        BEGIN
            SELECT @prev = NULL, @prev_end = NULL;
            SELECT TOP 1 @prev = version_id, @prev_end = effective_end
              FROM grac_practice.asset_contract_version
             WHERE contract_id = @c AND current_status_id = @st_active AND version_id <> @v
             ORDER BY effective_start DESC, version_no DESC;
            BEGIN TRAN;
            IF @type = N'TERMINATION'
            BEGIN
                SET @why = CONCAT(N'Terminated by version ', @no, N' from ', CONVERT(NVARCHAR(10), @start, 23), N'.');
                IF @prev IS NOT NULL
                BEGIN
                    EXEC grac_practice.sp_asset_contract_version_move @version_id = @prev, @from_code = N'ACTIVE', @to_code = N'TERMINATED',
                         @reason_code = N'TERMINATED', @reason_text = @why, @actor = @actor;
                    UPDATE grac_practice.asset_contract_version SET superseded_by_version_id = @v WHERE version_id = @prev;
                END
                EXEC grac_practice.sp_asset_contract_version_move @version_id = @v, @from_code = N'APPROVED', @to_code = N'TERMINATED',
                     @reason_code = N'TERMINATED', @reason_text = N'Termination took effect.', @actor = @actor;
                -- Approved versions that would start on or after the termination date never take effect.
                SET @x = (SELECT TOP 1 version_id FROM grac_practice.asset_contract_version
                           WHERE contract_id = @c AND current_status_id = @st_approved AND version_id <> @v AND effective_start >= @start
                           ORDER BY version_id);
                WHILE @x IS NOT NULL
                BEGIN
                    EXEC grac_practice.sp_asset_contract_version_move @version_id = @x, @from_code = N'APPROVED', @to_code = N'SUPERSEDED',
                         @reason_code = N'TERMINATED', @reason_text = @why, @actor = @actor;
                    UPDATE grac_practice.asset_contract_version SET superseded_by_version_id = @v WHERE version_id = @x;
                    SET @x = (SELECT TOP 1 version_id FROM grac_practice.asset_contract_version
                               WHERE contract_id = @c AND current_status_id = @st_approved AND version_id <> @v AND effective_start >= @start
                               ORDER BY version_id);
                END
            END
            ELSE
            BEGIN
                IF @prev IS NOT NULL
                BEGIN
                    -- 7.2.2: the previous applicable version becomes Superseded, or Expired when it ended before.
                    SET @prev_to = CASE WHEN @prev_end IS NOT NULL AND @prev_end < @start THEN N'EXPIRED' ELSE N'SUPERSEDED' END;
                    SET @why = CASE WHEN @prev_to = N'EXPIRED' THEN N'Effective end date passed.'
                                    ELSE CONCAT(N'Version ', @no, N' took effect on ', CONVERT(NVARCHAR(10), @start, 23), N'.') END;
                    EXEC grac_practice.sp_asset_contract_version_move @version_id = @prev, @from_code = N'ACTIVE', @to_code = @prev_to,
                         @reason_code = @prev_to, @reason_text = @why, @actor = @actor;
                    IF @prev_to = N'SUPERSEDED'
                        UPDATE grac_practice.asset_contract_version SET superseded_by_version_id = @v WHERE version_id = @prev;
                END
                EXEC grac_practice.sp_asset_contract_version_move @version_id = @v, @from_code = N'APPROVED', @to_code = N'ACTIVE',
                     @reason_code = N'EFFECTIVE', @reason_text = N'Effective start date reached.', @actor = @actor;
            END
            COMMIT;
        END
        FETCH NEXT FROM act_cur INTO @v, @c, @type, @start, @no;
    END
    CLOSE act_cur;
    DEALLOCATE act_cur;

    -- 2. Active versions past their effective end date.
    SET @x = (SELECT TOP 1 version_id FROM grac_practice.asset_contract_version
               WHERE organization_id = @organization_id AND (@contract_id IS NULL OR contract_id = @contract_id)
                 AND current_status_id = @st_active AND effective_end < @today ORDER BY version_id);
    WHILE @x IS NOT NULL
    BEGIN
        BEGIN TRAN;
        EXEC grac_practice.sp_asset_contract_version_move @version_id = @x, @from_code = N'ACTIVE', @to_code = N'EXPIRED',
             @reason_code = N'EXPIRED', @reason_text = N'Effective end date passed.', @actor = @actor;
        COMMIT;
        SET @x = (SELECT TOP 1 version_id FROM grac_practice.asset_contract_version
                   WHERE organization_id = @organization_id AND (@contract_id IS NULL OR contract_id = @contract_id)
                     AND current_status_id = @st_active AND effective_end < @today ORDER BY version_id);
    END

    -- 3. Contact mappings past their end date (7.4.4: ended, never deleted).
    DECLARE @ended TABLE (mapping_id BIGINT NOT NULL, effective_end DATE NULL);
    UPDATE grac_practice.asset_contract_contact
       SET status = N'INACTIVE', updated_by = @actor, updated_dt = SYSUTCDATETIME()
    OUTPUT inserted.mapping_id, inserted.effective_end INTO @ended (mapping_id, effective_end)
     WHERE organization_id = @organization_id AND (@contract_id IS NULL OR contract_id = @contract_id)
       AND status = N'ACTIVE' AND effective_end < @today;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'asset-contract-contact', e.mapping_id, N'ENDED', N'{"status":"ACTIVE"}',
           CONCAT(N'{"status":"INACTIVE","effectiveEnd":"', CONVERT(NVARCHAR(10), e.effective_end, 23), N'"}'), N'Active', @actor
      FROM @ended e;

    -- 4. Derived contract status and current version.
    ;WITH vs AS (
        SELECT v.contract_id, v.version_id, v.version_no, v.version_type, v.effective_start, s.status_code
          FROM grac_practice.asset_contract_version v
          JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
         WHERE v.organization_id = @organization_id AND (@contract_id IS NULL OR v.contract_id = @contract_id)),
    d AS (
        SELECT c.contract_id,
               CASE WHEN EXISTS (SELECT 1 FROM vs WHERE vs.contract_id = c.contract_id AND vs.version_type = N'TERMINATION'
                                                    AND vs.status_code = N'TERMINATED') THEN N'TERMINATED'
                    WHEN EXISTS (SELECT 1 FROM vs WHERE vs.contract_id = c.contract_id AND vs.status_code = N'ACTIVE') THEN N'ACTIVE'
                    WHEN EXISTS (SELECT 1 FROM vs WHERE vs.contract_id = c.contract_id AND vs.status_code IN (N'EXPIRED', N'SUPERSEDED')) THEN N'EXPIRED'
                    WHEN EXISTS (SELECT 1 FROM vs WHERE vs.contract_id = c.contract_id AND vs.status_code = N'APPROVED') THEN N'APPROVED'
                    ELSE N'DRAFT' END AS st,
               COALESCE((SELECT TOP 1 vs.version_id FROM vs WHERE vs.contract_id = c.contract_id AND vs.status_code = N'ACTIVE'
                          ORDER BY vs.effective_start DESC, vs.version_no DESC),
                        (SELECT TOP 1 vs.version_id FROM vs WHERE vs.contract_id = c.contract_id
                                                              AND vs.status_code IN (N'TERMINATED', N'EXPIRED', N'SUPERSEDED')
                          ORDER BY vs.effective_start DESC, vs.version_no DESC),
                        (SELECT TOP 1 vs.version_id FROM vs WHERE vs.contract_id = c.contract_id AND vs.status_code = N'APPROVED'
                          ORDER BY vs.effective_start, vs.version_no)) AS cur
          FROM grac_practice.asset_contract c
         WHERE c.organization_id = @organization_id AND (@contract_id IS NULL OR c.contract_id = @contract_id))
    UPDATE c
       SET contract_status = d.st, current_version_id = d.cur, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_contract c
      JOIN d ON d.contract_id = c.contract_id
     WHERE c.contract_status <> d.st OR ISNULL(c.current_version_id, -1) <> ISNULL(d.cur, -1);
END
GO

-- Completeness and effective-period rules checked at Submit and again at
-- Approve (7.2.1 required fields, 7.2.2 one applicable version per date).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_version_check
    @version_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c BIGINT, @type NVARCHAR(20), @start DATE, @eff_end DATE, @term DATE, @value DECIMAL(18,2), @cur NVARCHAR(3),
            @owner BIGINT, @summary NVARCHAR(2000), @base BIGINT, @msg NVARCHAR(400), @other INT;
    SELECT @c = contract_id, @type = version_type, @start = effective_start, @eff_end = effective_end, @term = termination_date,
           @value = contract_value, @cur = currency_code, @owner = contract_owner_id, @summary = change_summary,
           @base = supersedes_version_id
      FROM grac_practice.asset_contract_version WHERE version_id = @version_id;

    IF @type = N'TERMINATION' AND @term IS NULL
        THROW 54547, 'Set the termination date of the termination version.', 1;
    IF @start IS NULL OR (@type <> N'TERMINATION' AND @eff_end IS NULL)
        THROW 54547, 'Set the effective start and end dates of the version.', 1;
    IF @owner IS NULL
        THROW 54547, 'Select the internal contract owner.', 1;
    IF @type <> N'INITIAL' AND @summary IS NULL
        THROW 54523, 'Enter the change summary / reason (required for every version after the initial one).', 1;
    IF (@value IS NULL AND @cur IS NOT NULL) OR (@value IS NOT NULL AND @cur IS NULL)
        THROW 54527, 'Enter the contract value together with its currency.', 1;
    IF @base IS NOT NULL AND @start < (SELECT effective_start FROM grac_practice.asset_contract_version WHERE version_id = @base)
        THROW 54534, 'The version cannot start before the version it replaces.', 1;

    SET @other = NULL;
    SELECT TOP 1 @other = x.version_no
      FROM grac_practice.asset_contract_version x
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = x.current_status_id
     WHERE x.contract_id = @c AND x.version_id <> @version_id AND x.version_type = N'TERMINATION'
       AND s.status_code IN (N'APPROVED', N'TERMINATED')
       AND (@type = N'TERMINATION' OR x.effective_start <= ISNULL(@eff_end, @start))
     ORDER BY x.effective_start;
    IF @other IS NOT NULL
    BEGIN
        SET @msg = CONCAT(N'Termination version ', @other, N' ends the contract on or before this version.');
        THROW 54533, @msg, 1;
    END

    -- Only one applicable version per date (no approved overlap is configured): an approved / active
    -- version other than the one this version replaces may not share a date with it.
    IF @type <> N'TERMINATION'
    BEGIN
        SET @other = NULL;
        SELECT TOP 1 @other = x.version_no
          FROM grac_practice.asset_contract_version x
          JOIN grac_practice.entity_status_master s ON s.entity_status_id = x.current_status_id
         WHERE x.contract_id = @c AND x.version_id <> @version_id AND x.version_id <> ISNULL(@base, -1)
           AND x.version_type <> N'TERMINATION' AND s.status_code IN (N'APPROVED', N'ACTIVE')
           AND x.effective_start <= @eff_end AND ISNULL(x.effective_end, CAST('9999-12-31' AS DATE)) >= @start
         ORDER BY x.effective_start;
        IF @other IS NOT NULL
        BEGIN
            SET @msg = CONCAT(N'The effective dates overlap version ', @other, N', which is approved or active. Only one version may apply on a date.');
            THROW 54532, @msg, 1;
        END
    END
END
GO
PRINT '434: internal procedures created.';
GO

-- =====================================================================
-- 5. Writers
-- =====================================================================
-- Contract header. A new contract gets Version 1 (Initial) as a Draft,
-- owned by the creator when the creator is an employee of the organization.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_save
    @organization_id         BIGINT,
    @contract_id             BIGINT         = NULL,
    @contract_number         NVARCHAR(60),
    @contract_name           NVARCHAR(250),
    @contract_type           NVARCHAR(160),
    @parent_contract_id      BIGINT         = NULL,
    @vendor_id               BIGINT,
    @description             NVARCHAR(2000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @contract_number = NULLIF(LTRIM(RTRIM(@contract_number)), N'');
    SET @contract_name = NULLIF(LTRIM(RTRIM(@contract_name)), N'');
    SET @contract_type = NULLIF(LTRIM(RTRIM(@contract_type)), N'');
    SET @description = NULLIF(LTRIM(RTRIM(@description)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54510, 'Organization not found.', 1;

    DECLARE @found BIT = 0, @rv BIGINT, @old_vendor BIGINT, @old_type NVARCHAR(160), @locked BIT = 0, @version_id BIGINT;
    IF @contract_id IS NOT NULL
    BEGIN
        SELECT @found = 1, @rv = CONVERT(BIGINT, record_version), @old_vendor = vendor_id, @old_type = contract_type
          FROM grac_practice.asset_contract WHERE contract_id = @contract_id AND organization_id = @organization_id;
        IF @found = 0 THROW 54511, 'Contract not found for this organization.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54518, 'This contract was changed by someone else. Reload and try again.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.asset_contract_version WHERE contract_id = @contract_id AND approval_dt IS NOT NULL)
            SET @locked = 1;
    END
    IF @contract_number IS NULL
        THROW 54512, 'Enter the contract ID.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_contract WHERE organization_id = @organization_id AND contract_number = @contract_number
                                                             AND contract_id <> ISNULL(@contract_id, -1))
        THROW 54512, 'This contract ID is already used by another contract of the organization.', 1;
    IF @contract_name IS NULL
        THROW 54513, 'Enter the contract name.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_field_options(@organization_id)
                    WHERE OptionGroup = N'asset_field.coverage_type' AND OptionValue = @contract_type)
        THROW 54514, 'Select a contract type from the organization coverage type list.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_vendor WHERE vendor_id = @vendor_id AND organization_id = @organization_id)
        THROW 54515, 'Select a vendor of this organization (Settings -> Dependencies -> Vendors).', 1;
    -- 7.4.1: new contracts use an active vendor (D36).
    IF (@contract_id IS NULL OR @vendor_id <> @old_vendor)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_vendor WHERE vendor_id = @vendor_id AND status = N'Active')
        THROW 54515, 'The vendor is not active; inactive vendors cannot be used for a new contract.', 1;
    IF @locked = 1 AND (@vendor_id <> @old_vendor OR @contract_type <> @old_type)
        THROW 54516, 'The vendor and contract type cannot change once a version has been approved.', 1;
    IF @parent_contract_id IS NOT NULL
    BEGIN
        IF @parent_contract_id = ISNULL(@contract_id, -1)
           OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract WHERE contract_id = @parent_contract_id AND organization_id = @organization_id)
            THROW 54517, 'Select another contract of this organization as the parent agreement.', 1;
        DECLARE @p BIGINT = @parent_contract_id, @guard INT = 0;
        WHILE @p IS NOT NULL AND @guard < 100
        BEGIN
            IF @p = @contract_id THROW 54517, 'The parent agreement cannot be one of the sub-agreements of this contract.', 1;
            SET @p = (SELECT parent_contract_id FROM grac_practice.asset_contract WHERE contract_id = @p);
            SET @guard += 1;
        END
    END

    DECLARE @before NVARCHAR(MAX) = NULL, @result NVARCHAR(20);
    BEGIN TRAN;
    IF @contract_id IS NULL
    BEGIN
        INSERT grac_practice.asset_contract
            (organization_id, contract_number, contract_name, contract_type, parent_contract_id, vendor_id, description, entered_by)
        VALUES (@organization_id, @contract_number, @contract_name, @contract_type, @parent_contract_id, @vendor_id, @description, @actor);
        SET @contract_id = SCOPE_IDENTITY();
        DECLARE @owner BIGINT = (SELECT employee_id FROM grac_practice.organization_employee
                                  WHERE employee_id = @actor_employee_id AND organization_id = @organization_id AND status = N'Active'
                                    AND ISNULL(party_type, N'Employee') = N'Employee');
        INSERT grac_practice.asset_contract_version
            (contract_id, organization_id, version_no, version_type, current_status_id, contract_owner_id,
             created_by_employee_id, entered_by)
        VALUES (@contract_id, @organization_id, 1, N'INITIAL', grac_practice.fn_get_entity_status_id(N'ContractVersion', N'DRAFT'),
                @owner, @actor_employee_id, @actor);
        SET @version_id = SCOPE_IDENTITY();
        EXEC grac_practice.sp_asset_contract_version_move @version_id = @version_id, @from_code = NULL, @to_code = N'DRAFT',
             @reason_code = N'CREATED', @reason_text = N'Initial version created with the contract.',
             @actor_employee_id = @actor_employee_id, @actor = @actor;
        SET @result = N'CREATED';
    END
    ELSE
    BEGIN
        SET @before = (SELECT contract_number, contract_name, contract_type, parent_contract_id, vendor_id, description
                         FROM grac_practice.asset_contract WHERE contract_id = @contract_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        UPDATE grac_practice.asset_contract
           SET contract_number = @contract_number, contract_name = @contract_name, contract_type = @contract_type,
               parent_contract_id = @parent_contract_id, vendor_id = @vendor_id, description = @description,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE contract_id = @contract_id;
        SET @result = N'SAVED';
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract', @contract_id, CASE WHEN @before IS NULL THEN N'CREATE' ELSE N'UPDATE' END, @before,
            (SELECT contract_number, contract_name, contract_type, parent_contract_id, vendor_id, description
               FROM grac_practice.asset_contract WHERE contract_id = @contract_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @contract_id AS ContractId, @version_id AS VersionId, @result AS Result;
END
GO

-- New draft version (7.2.2: a renewal, amendment, extension, commercial or
-- scope change creates a new draft; the approved version stays in force
-- until the new one takes effect). Copied from the effective version.
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

-- Edit a Draft version (7.2.2: an approved version is immutable).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_version_save
    @organization_id         BIGINT,
    @version_id              BIGINT,
    @version_label           NVARCHAR(40)   = NULL,
    @effective_start         DATE           = NULL,
    @effective_end           DATE           = NULL,
    @notice_date             DATE           = NULL,
    @decision_date           DATE           = NULL,
    @termination_date        DATE           = NULL,
    @contract_value          DECIMAL(18,2)  = NULL,
    @currency_code           NVARCHAR(3)    = NULL,
    @tax_details             NVARCHAR(200)  = NULL,
    @payment_terms           NVARCHAR(400)  = NULL,
    @po_reference            NVARCHAR(100)  = NULL,
    @invoice_reference       NVARCHAR(100)  = NULL,
    @cost_allocation         NVARCHAR(400)  = NULL,
    @renewal_terms           NVARCHAR(1000) = NULL,
    @service_scope           NVARCHAR(2000) = NULL,
    @sla_terms               NVARCHAR(2000) = NULL,
    @support_hours           NVARCHAR(200)  = NULL,
    @response_time           NVARCHAR(100)  = NULL,
    @resolution_time         NVARCHAR(100)  = NULL,
    @service_visits          NVARCHAR(100)  = NULL,
    @contract_owner_id       BIGINT         = NULL,
    @procurement_owner_id    BIGINT         = NULL,
    @change_summary          NVARCHAR(2000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @version_label = NULLIF(LTRIM(RTRIM(@version_label)), N'');
    SET @currency_code = UPPER(NULLIF(LTRIM(RTRIM(@currency_code)), N''));
    SET @tax_details = NULLIF(LTRIM(RTRIM(@tax_details)), N'');
    SET @payment_terms = NULLIF(LTRIM(RTRIM(@payment_terms)), N'');
    SET @po_reference = NULLIF(LTRIM(RTRIM(@po_reference)), N'');
    SET @invoice_reference = NULLIF(LTRIM(RTRIM(@invoice_reference)), N'');
    SET @cost_allocation = NULLIF(LTRIM(RTRIM(@cost_allocation)), N'');
    SET @renewal_terms = NULLIF(LTRIM(RTRIM(@renewal_terms)), N'');
    SET @service_scope = NULLIF(LTRIM(RTRIM(@service_scope)), N'');
    SET @sla_terms = NULLIF(LTRIM(RTRIM(@sla_terms)), N'');
    SET @support_hours = NULLIF(LTRIM(RTRIM(@support_hours)), N'');
    SET @response_time = NULLIF(LTRIM(RTRIM(@response_time)), N'');
    SET @resolution_time = NULLIF(LTRIM(RTRIM(@resolution_time)), N'');
    SET @service_visits = NULLIF(LTRIM(RTRIM(@service_visits)), N'');
    SET @change_summary = NULLIF(LTRIM(RTRIM(@change_summary)), N'');

    DECLARE @found BIT = 0, @status NVARCHAR(60), @rv BIGINT, @type NVARCHAR(20);
    SELECT @found = 1, @status = s.status_code, @rv = CONVERT(BIGINT, v.record_version), @type = v.version_type
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
     WHERE v.version_id = @version_id AND v.organization_id = @organization_id;
    IF @found = 0 THROW 54519, 'Contract version not found for this organization.', 1;
    IF @status <> N'DRAFT'
        THROW 54524, 'Only a Draft version can be edited. An approved version is immutable; create a correction version instead.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54525, 'This version was changed by someone else. Reload and try again.', 1;

    IF @type = N'TERMINATION'
        SELECT @effective_start = @termination_date, @effective_end = NULL;
    IF @effective_start IS NOT NULL AND @effective_end IS NOT NULL AND @effective_end < @effective_start
        THROW 54526, 'The effective end date must follow the effective start date.', 1;
    IF @effective_end IS NOT NULL AND (@notice_date > @effective_end OR @decision_date > @effective_end)
        THROW 54526, 'The notice and decision dates cannot follow the effective end date.', 1;
    IF @type <> N'TERMINATION' AND @termination_date IS NOT NULL
       AND ((@effective_start IS NOT NULL AND @termination_date < @effective_start)
            OR (@effective_end IS NOT NULL AND @termination_date > @effective_end))
        THROW 54526, 'The termination date must fall within the effective dates.', 1;
    IF @contract_value < 0
        THROW 54527, 'The contract value cannot be negative.', 1;
    IF @currency_code IS NOT NULL AND (LEN(@currency_code) <> 3 OR @currency_code LIKE N'%[^A-Z]%')
        THROW 54527, 'Enter the currency as a three-letter code (for example INR, USD).', 1;
    IF (@contract_owner_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                        WHERE employee_id = @contract_owner_id AND organization_id = @organization_id
                                                          AND status = N'Active' AND ISNULL(party_type, N'Employee') = N'Employee'))
       OR (@procurement_owner_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                        WHERE employee_id = @procurement_owner_id AND organization_id = @organization_id
                                                          AND status = N'Active' AND ISNULL(party_type, N'Employee') = N'Employee'))
        THROW 54528, 'Contract and procurement owners must be active employees of the organization.', 1;

    DECLARE @before NVARCHAR(MAX) = (SELECT * FROM grac_practice.asset_contract_version WHERE version_id = @version_id
                                      FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    UPDATE grac_practice.asset_contract_version
       SET version_label = @version_label, effective_start = @effective_start, effective_end = @effective_end,
           notice_date = @notice_date, decision_date = @decision_date, termination_date = @termination_date,
           contract_value = @contract_value, currency_code = @currency_code, tax_details = @tax_details,
           payment_terms = @payment_terms, po_reference = @po_reference, invoice_reference = @invoice_reference,
           cost_allocation = @cost_allocation, renewal_terms = @renewal_terms, service_scope = @service_scope,
           sla_terms = @sla_terms, support_hours = @support_hours, response_time = @response_time,
           resolution_time = @resolution_time, service_visits = @service_visits, contract_owner_id = @contract_owner_id,
           procurement_owner_id = @procurement_owner_id, change_summary = @change_summary,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE version_id = @version_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-version', @version_id, N'UPDATE', @before,
            (SELECT * FROM grac_practice.asset_contract_version WHERE version_id = @version_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @version_id AS VersionId, N'SAVED' AS Result;
END
GO

-- Version workflow (7.2.1 Created / Submitted / Approved By, 7.2.3 review,
-- approval, rejection and return events):
--   SUBMIT   Draft -> In Review              (completeness + period check)
--   REVIEW   In Review -> Pending Approval   (not the submitter)
--   RETURN   In Review / Pending Approval -> Draft (note)
--   REJECT   In Review / Pending Approval -> Rejected (note; not the submitter)
--   APPROVE  Pending Approval -> Approved    (not the submitter; vendor +
--            contact snapshot; becomes Active on its start date)
--   WITHDRAW Draft -> Rejected               (note; kept for audit)
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_version_action
    @organization_id         BIGINT,
    @version_id              BIGINT,
    @action                  NVARCHAR(20),
    @note                    NVARCHAR(1000) = NULL,
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

    DECLARE @found BIT = 0, @status NVARCHAR(60), @rv BIGINT, @c BIGINT, @submitter BIGINT, @msg NVARCHAR(400);
    SELECT @found = 1, @status = s.status_code, @rv = CONVERT(BIGINT, v.record_version), @c = v.contract_id,
           @submitter = v.submitted_by_employee_id
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
     WHERE v.version_id = @version_id AND v.organization_id = @organization_id;
    IF @found = 0 THROW 54519, 'Contract version not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54525, 'This version was changed by someone else. Reload and try again.', 1;
    IF @action NOT IN (N'SUBMIT', N'REVIEW', N'RETURN', N'REJECT', N'APPROVE', N'WITHDRAW')
        THROW 54546, 'Unknown action. Use Submit, Review, Return, Reject, Approve or Withdraw.', 1;
    IF NOT ((@action IN (N'SUBMIT', N'WITHDRAW') AND @status = N'DRAFT')
            OR (@action = N'REVIEW' AND @status = N'IN_REVIEW')
            OR (@action IN (N'RETURN', N'REJECT') AND @status IN (N'IN_REVIEW', N'PENDING_APPROVAL'))
            OR (@action = N'APPROVE' AND @status = N'PENDING_APPROVAL'))
    BEGIN
        SET @msg = CONCAT(N'The version is ', LOWER(REPLACE(@status, N'_', N' ')), N'; ', LOWER(@action), N' is not possible now.');
        THROW 54529, @msg, 1;
    END
    IF @action IN (N'RETURN', N'REJECT', N'WITHDRAW') AND @note IS NULL
        THROW 54531, 'Give the reason.', 1;
    IF @action IN (N'REVIEW', N'REJECT', N'APPROVE')
    BEGIN
        IF @actor_employee_id IS NULL
            THROW 54530, 'Review and approval need a sign-in linked to an employee of the organization.', 1;
        IF @actor_employee_id = @submitter
            THROW 54530, 'The person who submitted the version cannot review, reject or approve it.', 1;
    END
    IF @action IN (N'SUBMIT', N'APPROVE')
        EXEC grac_practice.sp_asset_contract_version_check @version_id = @version_id;

    DECLARE @to NVARCHAR(60) = CASE @action WHEN N'SUBMIT' THEN N'IN_REVIEW' WHEN N'REVIEW' THEN N'PENDING_APPROVAL'
                                            WHEN N'RETURN' THEN N'DRAFT' WHEN N'APPROVE' THEN N'APPROVED' ELSE N'REJECTED' END;
    DECLARE @before NVARCHAR(MAX) = (SELECT @status AS status, submitted_by, reviewed_by, approved_by, decision_note
                                       FROM grac_practice.asset_contract_version WHERE version_id = @version_id
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    EXEC grac_practice.sp_asset_contract_version_move @version_id = @version_id, @from_code = @status, @to_code = @to,
         @reason_code = @action, @reason_text = @note, @actor_employee_id = @actor_employee_id, @actor = @actor;
    UPDATE v
       SET submitted_by = CASE WHEN @action = N'SUBMIT' THEN @actor ELSE v.submitted_by END,
           submitted_by_employee_id = CASE WHEN @action = N'SUBMIT' THEN @actor_employee_id ELSE v.submitted_by_employee_id END,
           submitted_dt = CASE WHEN @action = N'SUBMIT' THEN SYSUTCDATETIME() ELSE v.submitted_dt END,
           reviewed_by = CASE WHEN @action = N'REVIEW' THEN @actor ELSE v.reviewed_by END,
           reviewed_by_employee_id = CASE WHEN @action = N'REVIEW' THEN @actor_employee_id ELSE v.reviewed_by_employee_id END,
           reviewed_dt = CASE WHEN @action = N'REVIEW' THEN SYSUTCDATETIME() ELSE v.reviewed_dt END,
           approved_by = CASE WHEN @action = N'APPROVE' THEN @actor ELSE v.approved_by END,
           approved_by_employee_id = CASE WHEN @action = N'APPROVE' THEN @actor_employee_id ELSE v.approved_by_employee_id END,
           approval_dt = CASE WHEN @action = N'APPROVE' THEN SYSUTCDATETIME() ELSE v.approval_dt END,
           vendor_id = CASE WHEN @action = N'APPROVE' THEN c.vendor_id ELSE v.vendor_id END,
           vendor_name_snapshot = CASE WHEN @action = N'APPROVE' THEN vd.vendor_name ELSE v.vendor_name_snapshot END,
           decision_note = CASE WHEN @action = N'SUBMIT' THEN NULL WHEN @note IS NOT NULL THEN @note ELSE v.decision_note END
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
      JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = c.vendor_id
     WHERE v.version_id = @version_id;
    -- 7.2.1 / 7.4.4: the vendor contacts effective for the version, frozen with it.
    IF @action = N'APPROVE'
        INSERT grac_practice.asset_contract_version_contact
            (version_id, mapping_id, role_code, role_name, is_primary, employee_id, contact_name, contact_email, vendor_id,
             vendor_name, preferred_channel, notification_participation, effective_start, effective_end, entered_by)
        SELECT v.version_id, m.mapping_id, m.role_code, r.role_name, m.is_primary, m.employee_id, e.employee_name, e.email,
               m.vendor_id, vd.vendor_name, m.preferred_channel, m.notification_participation, m.effective_start, m.effective_end, @actor
          FROM grac_practice.asset_contract_version v
          JOIN grac_practice.asset_contract_contact m
            ON m.contract_id = v.contract_id AND (m.version_id IS NULL OR m.version_id = v.version_id)
          JOIN grac_practice.asset_contract_contact_role r ON r.role_code = m.role_code
          JOIN grac_practice.organization_employee e ON e.employee_id = m.employee_id
          JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = m.vendor_id
         WHERE v.version_id = @version_id AND m.status = N'ACTIVE'
           AND m.effective_start <= ISNULL(v.effective_end, CAST('9999-12-31' AS DATE))
           AND ISNULL(m.effective_end, CAST('9999-12-31' AS DATE)) >= v.effective_start
           AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_version_contact x
                            WHERE x.version_id = v.version_id AND x.mapping_id = m.mapping_id);
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-version', @version_id, @action, @before,
            (SELECT @to AS status, submitted_by, reviewed_by, approved_by, approval_dt, decision_note
               FROM grac_practice.asset_contract_version WHERE version_id = @version_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    IF @action = N'APPROVE'
        EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id, @contract_id = @c, @actor = @actor;

    SELECT @version_id AS VersionId, s.status_code AS Result
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
     WHERE v.version_id = @version_id;
END
GO

-- Vendor contact mapping (7.4.2). New mappings start as Pending
-- Validation; another person validates them (D37). An Active mapping keeps
-- its person, role, primary flag and dates -- end it and add a new one;
-- channel, notification participation and notes stay editable.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_contact_save
    @organization_id            BIGINT,
    @mapping_id                 BIGINT         = NULL,
    @contract_id                BIGINT,
    @version_id                 BIGINT         = NULL,
    @employee_id                BIGINT         = NULL,
    @role_code                  NVARCHAR(40)   = NULL,
    @is_primary                 BIT            = 0,
    @effective_start            DATE           = NULL,
    @effective_end              DATE           = NULL,
    @preferred_channel          NVARCHAR(10)   = N'EMAIL',
    @notification_participation BIT            = 1,
    @notes                      NVARCHAR(1000) = NULL,
    @expected_record_version    BIGINT         = NULL,
    @actor_employee_id          BIGINT         = NULL,
    @actor                      NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @role_code = UPPER(NULLIF(LTRIM(RTRIM(@role_code)), N''));
    SET @preferred_channel = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@preferred_channel)), N''), N'EMAIL'));
    SET @notes = NULLIF(LTRIM(RTRIM(@notes)), N'');
    SET @is_primary = ISNULL(@is_primary, 0);
    SET @notification_participation = ISNULL(@notification_participation, 1);

    DECLARE @found BIT = 0, @cstatus NVARCHAR(20), @vendor BIGINT;
    SELECT @found = 1, @cstatus = contract_status, @vendor = vendor_id FROM grac_practice.asset_contract
     WHERE contract_id = @contract_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54511, 'Contract not found for this organization.', 1;
    IF @cstatus = N'TERMINATED'
        THROW 54520, 'The contract is terminated; its contacts are kept for history only.', 1;

    DECLARE @mstatus NVARCHAR(20), @rv BIGINT, @old_primary BIT, @old_start DATE, @old_end DATE;
    IF @mapping_id IS NOT NULL
    BEGIN
        SET @found = 0;
        SELECT @found = 1, @mstatus = status, @rv = CONVERT(BIGINT, record_version), @employee_id = employee_id,
               @role_code = role_code, @version_id = version_id, @old_primary = is_primary, @old_start = effective_start,
               @old_end = effective_end
          FROM grac_practice.asset_contract_contact WHERE mapping_id = @mapping_id AND contract_id = @contract_id;
        IF @found = 0 THROW 54540, 'Contact mapping not found for this contract.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54548, 'This contact mapping was changed by someone else. Reload and try again.', 1;
        IF @mstatus = N'INACTIVE'
            THROW 54541, 'This assignment has ended; add a new one.', 1;
        IF @mstatus = N'ACTIVE' AND (@is_primary <> @old_primary OR @effective_start <> @old_start
                                     OR ISNULL(@effective_end, CAST('9999-12-31' AS DATE)) <> ISNULL(@old_end, CAST('9999-12-31' AS DATE)))
            THROW 54541, 'A validated assignment keeps its primary flag and dates; end it and add a new assignment.', 1;
    END
    ELSE
    BEGIN
        -- 7.4.1 / 7.4.2: an active user of the contract vendor at assignment time.
        IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                        WHERE employee_id = @employee_id AND organization_id = @organization_id AND party_type = N'ThirdParty'
                          AND provider_vendor_id = @vendor AND status = N'Active')
            THROW 54536, 'Select an active user of the contract vendor (third-party person linked to the vendor).', 1;
    END
    IF @version_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_version v
                         JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
                        WHERE v.version_id = @version_id AND v.contract_id = @contract_id
                          AND s.status_code IN (N'DRAFT', N'IN_REVIEW', N'PENDING_APPROVAL'))
        THROW 54535, 'A version-specific contact can only be added to a version that is not yet approved.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_contact_role WHERE role_code = @role_code AND is_active = 1)
        THROW 54537, 'Select the contact role.', 1;
    IF @preferred_channel NOT IN (N'EMAIL', N'PHONE', N'PORTAL', N'OTHER')
        THROW 54537, 'Select the preferred channel: email, phone, portal or other.', 1;
    IF @effective_start IS NULL
        THROW 54526, 'Enter the effective start date.', 1;
    IF @effective_end IS NOT NULL AND @effective_end < @effective_start
        THROW 54526, 'The effective end date must follow the effective start date.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_contract_contact x
                WHERE x.contract_id = @contract_id AND x.mapping_id <> ISNULL(@mapping_id, -1) AND x.employee_id = @employee_id
                  AND x.role_code = @role_code AND x.status IN (N'ACTIVE', N'PENDING_VALIDATION')
                  AND (x.version_id IS NULL OR @version_id IS NULL OR x.version_id = @version_id)
                  AND x.effective_start <= ISNULL(@effective_end, CAST('9999-12-31' AS DATE))
                  AND ISNULL(x.effective_end, CAST('9999-12-31' AS DATE)) >= @effective_start)
        THROW 54539, 'This person already holds this role on the contract for an overlapping period.', 1;
    -- 7.4.4: duplicate active primary assignments for the same contract, role and period are blocked.
    IF @is_primary = 1 AND EXISTS (SELECT 1 FROM grac_practice.asset_contract_contact x
                WHERE x.contract_id = @contract_id AND x.mapping_id <> ISNULL(@mapping_id, -1) AND x.role_code = @role_code
                  AND x.is_primary = 1 AND x.status IN (N'ACTIVE', N'PENDING_VALIDATION')
                  AND (x.version_id IS NULL OR @version_id IS NULL OR x.version_id = @version_id)
                  AND x.effective_start <= ISNULL(@effective_end, CAST('9999-12-31' AS DATE))
                  AND ISNULL(x.effective_end, CAST('9999-12-31' AS DATE)) >= @effective_start)
        THROW 54538, 'Another person is already primary for this role in an overlapping period.', 1;

    DECLARE @before NVARCHAR(MAX) = NULL;
    BEGIN TRAN;
    IF @mapping_id IS NULL
    BEGIN
        INSERT grac_practice.asset_contract_contact
            (organization_id, contract_id, version_id, vendor_id, employee_id, role_code, is_primary, effective_start, effective_end,
             status, preferred_channel, notification_participation, notes, created_by_employee_id, entered_by)
        VALUES (@organization_id, @contract_id, @version_id, @vendor, @employee_id, @role_code, @is_primary, @effective_start,
                @effective_end, N'PENDING_VALIDATION', @preferred_channel, @notification_participation, @notes, @actor_employee_id, @actor);
        SET @mapping_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        SET @before = (SELECT is_primary, effective_start, effective_end, preferred_channel, notification_participation, notes
                         FROM grac_practice.asset_contract_contact WHERE mapping_id = @mapping_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        UPDATE grac_practice.asset_contract_contact
           SET is_primary = @is_primary, effective_start = @effective_start, effective_end = @effective_end,
               preferred_channel = @preferred_channel, notification_participation = @notification_participation, notes = @notes,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE mapping_id = @mapping_id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-contact', @mapping_id, CASE WHEN @before IS NULL THEN N'CREATE' ELSE N'UPDATE' END, @before,
            (SELECT contract_id, version_id, vendor_id, employee_id, role_code, is_primary, effective_start, effective_end, status,
                    preferred_channel, notification_participation, notes
               FROM grac_practice.asset_contract_contact WHERE mapping_id = @mapping_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @mapping_id AS MappingId, CASE WHEN @before IS NULL THEN N'CREATED' ELSE N'SAVED' END AS Result;
END
GO

-- VALIDATE (Pending Validation -> Active, by another person) or END (sets
-- the end date; the mapping is kept -- 7.4.4).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_contact_action
    @organization_id         BIGINT,
    @mapping_id              BIGINT,
    @action                  NVARCHAR(20),
    @end_date                DATE           = NULL,
    @note                    NVARCHAR(1000) = NULL,
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
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @found BIT = 0, @status NVARCHAR(20), @rv BIGINT, @creator BIGINT, @c BIGINT, @emp BIGINT, @vendor BIGINT, @role NVARCHAR(40),
            @primary BIT, @start DATE, @eff_end DATE, @version BIGINT;
    SELECT @found = 1, @status = m.status, @rv = CONVERT(BIGINT, m.record_version), @creator = m.created_by_employee_id,
           @c = m.contract_id, @emp = m.employee_id, @vendor = c.vendor_id, @role = m.role_code, @primary = m.is_primary,
           @start = m.effective_start, @eff_end = m.effective_end, @version = m.version_id
      FROM grac_practice.asset_contract_contact m
      JOIN grac_practice.asset_contract c ON c.contract_id = m.contract_id
     WHERE m.mapping_id = @mapping_id AND c.organization_id = @organization_id;
    IF @found = 0 THROW 54540, 'Contact mapping not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54548, 'This contact mapping was changed by someone else. Reload and try again.', 1;
    IF @action NOT IN (N'VALIDATE', N'END')
        THROW 54546, 'Unknown action. Use Validate or End.', 1;
    IF (@action = N'VALIDATE' AND @status <> N'PENDING_VALIDATION') OR (@action = N'END' AND @status = N'INACTIVE')
        THROW 54529, 'The contact mapping is not in a status that allows this action.', 1;

    DECLARE @new_status NVARCHAR(20) = @status, @new_end DATE = @eff_end;
    IF @action = N'VALIDATE'
    BEGIN
        IF @actor_employee_id IS NULL OR @actor_employee_id = @creator
            THROW 54530, 'Another person must validate the contact mapping.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                        WHERE employee_id = @emp AND party_type = N'ThirdParty' AND provider_vendor_id = @vendor AND status = N'Active')
            THROW 54536, 'The person is no longer an active user of the contract vendor; end this mapping instead.', 1;
        IF @primary = 1 AND EXISTS (SELECT 1 FROM grac_practice.asset_contract_contact x
                    WHERE x.contract_id = @c AND x.mapping_id <> @mapping_id AND x.role_code = @role AND x.is_primary = 1
                      AND x.status = N'ACTIVE' AND (x.version_id IS NULL OR @version IS NULL OR x.version_id = @version)
                      AND x.effective_start <= ISNULL(@eff_end, CAST('9999-12-31' AS DATE))
                      AND ISNULL(x.effective_end, CAST('9999-12-31' AS DATE)) >= @start)
            THROW 54538, 'Another person is already primary for this role in an overlapping period.', 1;
        SET @new_status = N'ACTIVE';
    END
    ELSE
    BEGIN
        IF @note IS NULL THROW 54531, 'Give the reason for ending the assignment.', 1;
        SET @new_end = ISNULL(@end_date, @today);
        IF @status = N'PENDING_VALIDATION'
        BEGIN
            SELECT @new_status = N'INACTIVE', @new_end = CASE WHEN @new_end < @start THEN @start ELSE @new_end END;
        END
        ELSE
        BEGIN
            IF @new_end < @start THROW 54526, 'The end date cannot precede the start date of the assignment.', 1;
            SET @new_status = CASE WHEN @new_end < @today THEN N'INACTIVE' ELSE N'ACTIVE' END;
        END
    END

    BEGIN TRAN;
    UPDATE grac_practice.asset_contract_contact
       SET status = @new_status, effective_end = @new_end,
           validated_by = CASE WHEN @action = N'VALIDATE' THEN @actor ELSE validated_by END,
           validated_by_employee_id = CASE WHEN @action = N'VALIDATE' THEN @actor_employee_id ELSE validated_by_employee_id END,
           validated_dt = CASE WHEN @action = N'VALIDATE' THEN SYSUTCDATETIME() ELSE validated_dt END,
           end_reason = CASE WHEN @action = N'END' THEN @note ELSE end_reason END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE mapping_id = @mapping_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-contact', @mapping_id, @action,
            (SELECT @status AS status, @eff_end AS effectiveEnd FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @new_status AS status, @new_end AS effectiveEnd, @note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @mapping_id AS MappingId, @new_status AS Result;
END
GO

-- Signed documents and procurement references of a version (7.2.1). Added
-- until the version is approved; removed (kept, marked Removed) while Draft.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_document_add
    @organization_id BIGINT,
    @version_id      BIGINT,
    @document_type   NVARCHAR(30),
    @title           NVARCHAR(250),
    @reference_text  NVARCHAR(1000),
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @document_type = UPPER(NULLIF(LTRIM(RTRIM(@document_type)), N''));
    SET @title = NULLIF(LTRIM(RTRIM(@title)), N'');
    SET @reference_text = NULLIF(LTRIM(RTRIM(@reference_text)), N'');

    DECLARE @found BIT = 0, @status NVARCHAR(60), @c BIGINT;
    SELECT @found = 1, @status = s.status_code, @c = v.contract_id
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
     WHERE v.version_id = @version_id AND v.organization_id = @organization_id;
    IF @found = 0 THROW 54519, 'Contract version not found for this organization.', 1;
    IF @status NOT IN (N'DRAFT', N'IN_REVIEW', N'PENDING_APPROVAL')
        THROW 54542, 'Documents of an approved version are fixed; add them to a new version.', 1;
    IF @document_type IS NULL OR @document_type NOT IN (N'SIGNED_AGREEMENT', N'SCHEDULE', N'AMENDMENT', N'QUOTATION',
                                                        N'PURCHASE_ORDER', N'INVOICE', N'SUPPORTING_EVIDENCE', N'OTHER')
       OR @title IS NULL OR @reference_text IS NULL
        THROW 54545, 'Select the document type and enter the title and the reference (document number or link).', 1;

    DECLARE @id BIGINT;
    BEGIN TRAN;
    INSERT grac_practice.asset_contract_document (organization_id, contract_id, version_id, document_type, title, reference_text, entered_by)
    VALUES (@organization_id, @c, @version_id, @document_type, @title, @reference_text, @actor);
    SET @id = SCOPE_IDENTITY();
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-document', @id, N'CREATE', NULL,
            (SELECT @version_id AS versionId, @document_type AS documentType, @title AS title, @reference_text AS reference
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @id AS DocumentId, N'CREATED' AS Result;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_document_remove
    @organization_id BIGINT,
    @document_id     BIGINT,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    DECLARE @found BIT = 0, @status NVARCHAR(60);
    SELECT @found = 1, @status = s.status_code
      FROM grac_practice.asset_contract_document d
      JOIN grac_practice.asset_contract_version v ON v.version_id = d.version_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
     WHERE d.document_id = @document_id AND d.organization_id = @organization_id AND d.status = N'ACTIVE';
    IF @found = 0 THROW 54544, 'Document not found for this organization.', 1;
    IF @status <> N'DRAFT'
        THROW 54542, 'Documents can only be removed while the version is a Draft.', 1;
    BEGIN TRAN;
    UPDATE grac_practice.asset_contract_document
       SET status = N'REMOVED', removed_by = @actor, removed_dt = SYSUTCDATETIME()
     WHERE document_id = @document_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-document', @document_id, N'REMOVE', N'{"status":"ACTIVE"}', N'{"status":"REMOVED"}', N'Active', @actor);
    COMMIT;
    SELECT @document_id AS DocumentId, N'REMOVED' AS Result;
END
GO
PRINT '434: writers created.';
GO

-- =====================================================================
-- 6. Readers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @status          NVARCHAR(20)  = NULL,
    @vendor_id       BIGINT        = NULL,
    @contract_type   NVARCHAR(160) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @contract_type = NULLIF(LTRIM(RTRIM(@contract_type)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id;

    SELECT c.contract_id AS ContractId, c.contract_number AS ContractNumber, c.contract_name AS ContractName,
           c.contract_type AS ContractType, ISNULL(opt.OptionLabel, c.contract_type) AS ContractTypeLabel,
           c.vendor_id AS VendorId, vd.vendor_name AS VendorName, vd.status AS VendorStatus,
           p.contract_number AS ParentContractNumber, c.contract_status AS ContractStatus,
           cv.version_no AS CurrentVersionNo, cv.effective_start AS EffectiveStart, cv.effective_end AS EffectiveEnd,
           cv.contract_value AS ContractValue, cv.currency_code AS CurrencyCode,
           ow.employee_name AS ContractOwnerName,
           ov.version_no AS OpenVersionNo, ov.status_code AS OpenVersionStatus,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_contract c
      JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = c.vendor_id
      LEFT JOIN grac_practice.asset_contract p ON p.contract_id = c.parent_contract_id
      LEFT JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
      OUTER APPLY (SELECT TOP 1 v.version_no, v.contract_owner_id FROM grac_practice.asset_contract_version v
                    WHERE v.contract_id = c.contract_id ORDER BY v.version_no DESC) lv
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = COALESCE(cv.contract_owner_id, lv.contract_owner_id)
      OUTER APPLY (SELECT TOP 1 v.version_no, s.status_code FROM grac_practice.asset_contract_version v
                     JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
                    WHERE v.contract_id = c.contract_id AND s.status_code IN (N'DRAFT', N'IN_REVIEW', N'PENDING_APPROVAL')
                    ORDER BY v.version_no DESC) ov
      OUTER APPLY (SELECT TOP 1 o.OptionLabel FROM grac_practice.fn_asset_field_options(@organization_id) o
                    WHERE o.OptionGroup = N'asset_field.coverage_type' AND o.OptionValue = c.contract_type) opt
     WHERE c.organization_id = @organization_id
       AND (@search IS NULL OR c.contract_number LIKE N'%' + @search + N'%' OR c.contract_name LIKE N'%' + @search + N'%'
            OR vd.vendor_name LIKE N'%' + @search + N'%')
       AND (@status IS NULL OR c.contract_status = @status)
       AND (@vendor_id IS NULL OR c.vendor_id = @vendor_id)
       AND (@contract_type IS NULL OR c.contract_type = @contract_type)
     ORDER BY c.contract_number
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- 7.2.3 contract screen: 1. current summary  2. version history
-- 3. vendor contact mappings  4. documents (every version)
-- 5. approval history  6. warnings for the version in progress
-- 7. vendor contact history (snapshot per approved version)
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_get
    @organization_id   BIGINT,
    @contract_id       BIGINT,
    @actor_employee_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract WHERE contract_id = @contract_id AND organization_id = @organization_id)
        THROW 54511, 'Contract not found for this organization.', 1;
    EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id, @contract_id = @contract_id;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @open BIGINT = (SELECT TOP 1 v.version_id FROM grac_practice.asset_contract_version v
                              JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
                             WHERE v.contract_id = @contract_id AND s.status_code IN (N'DRAFT', N'IN_REVIEW', N'PENDING_APPROVAL')
                             ORDER BY v.version_no DESC);

    SELECT c.contract_id AS ContractId, c.contract_number AS ContractNumber, c.contract_name AS ContractName,
           c.contract_type AS ContractType, ISNULL(opt.OptionLabel, c.contract_type) AS ContractTypeLabel,
           c.parent_contract_id AS ParentContractId, p.contract_number AS ParentContractNumber, p.contract_name AS ParentContractName,
           c.vendor_id AS VendorId, vd.vendor_name AS VendorName, vd.status AS VendorStatus, c.description AS Description,
           c.contract_status AS ContractStatus, CONVERT(BIGINT, c.record_version) AS RecordVersion,
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_contract_version x WHERE x.contract_id = c.contract_id AND x.approval_dt IS NOT NULL)
                THEN 1 ELSE 0 END AS IdentityLocked,
           cv.version_id AS CurrentVersionId, cv.version_no AS CurrentVersionNo, cv.version_type AS CurrentVersionType,
           cs.status_code AS CurrentVersionStatus, cv.effective_start AS EffectiveStart, cv.effective_end AS EffectiveEnd,
           cv.notice_date AS NoticeDate, cv.decision_date AS DecisionDate, cv.termination_date AS TerminationDate,
           cv.contract_value AS ContractValue, cv.currency_code AS CurrencyCode, cv.payment_terms AS PaymentTerms,
           cv.support_hours AS SupportHours, cv.sla_terms AS SlaTerms, cv.renewal_terms AS RenewalTerms,
           o1.employee_name AS ContractOwnerName, o2.employee_name AS ProcurementOwnerName,
           @open AS OpenVersionId, ov.version_no AS OpenVersionNo, os.status_code AS OpenVersionStatus,
           c.entered_by AS EnteredBy, c.entered_dt AS EnteredDt
      FROM grac_practice.asset_contract c
      JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = c.vendor_id
      LEFT JOIN grac_practice.asset_contract p ON p.contract_id = c.parent_contract_id
      LEFT JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = cv.current_status_id
      LEFT JOIN grac_practice.organization_employee o1 ON o1.employee_id = cv.contract_owner_id
      LEFT JOIN grac_practice.organization_employee o2 ON o2.employee_id = cv.procurement_owner_id
      LEFT JOIN grac_practice.asset_contract_version ov ON ov.version_id = @open
      LEFT JOIN grac_practice.entity_status_master os ON os.entity_status_id = ov.current_status_id
      OUTER APPLY (SELECT TOP 1 o.OptionLabel FROM grac_practice.fn_asset_field_options(@organization_id) o
                    WHERE o.OptionGroup = N'asset_field.coverage_type' AND o.OptionValue = c.contract_type) opt
     WHERE c.contract_id = @contract_id;

    SELECT v.version_id AS VersionId, v.version_no AS VersionNo, v.version_label AS VersionLabel, v.version_type AS VersionType,
           s.status_code AS StatusCode, s.status_name AS StatusName, v.effective_start AS EffectiveStart, v.effective_end AS EffectiveEnd,
           v.contract_value AS ContractValue, v.currency_code AS CurrencyCode, v.change_summary AS ChangeSummary,
           v.entered_by AS CreatedBy, ce.employee_name AS CreatedByName, v.entered_dt AS CreatedDt,
           se.employee_name AS SubmittedByName, v.submitted_dt AS SubmittedDt, re.employee_name AS ReviewedByName, v.reviewed_dt AS ReviewedDt,
           ae.employee_name AS ApprovedByName, v.approved_by AS ApprovedBy, v.approval_dt AS ApprovalDt,
           sv.version_no AS SupersedesVersionNo, bv.version_no AS SupersededByVersionNo, v.decision_note AS DecisionNote,
           CASE WHEN @actor_employee_id IS NOT NULL AND v.submitted_by_employee_id = @actor_employee_id THEN 1 ELSE 0 END AS ActorIsSubmitter,
           CONVERT(BIGINT, v.record_version) AS RecordVersion
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
      LEFT JOIN grac_practice.organization_employee ce ON ce.employee_id = v.created_by_employee_id
      LEFT JOIN grac_practice.organization_employee se ON se.employee_id = v.submitted_by_employee_id
      LEFT JOIN grac_practice.organization_employee re ON re.employee_id = v.reviewed_by_employee_id
      LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = v.approved_by_employee_id
      LEFT JOIN grac_practice.asset_contract_version sv ON sv.version_id = v.supersedes_version_id
      LEFT JOIN grac_practice.asset_contract_version bv ON bv.version_id = v.superseded_by_version_id
     WHERE v.contract_id = @contract_id
     ORDER BY v.version_no DESC;

    SELECT m.mapping_id AS MappingId, m.version_id AS VersionId, xv.version_no AS VersionNo, m.employee_id AS EmployeeId,
           e.employee_name AS ContactName, e.email AS ContactEmail, e.status AS ContactStatus, m.role_code AS RoleCode,
           r.role_name AS RoleName, r.is_mandatory AS RoleMandatory, m.is_primary AS IsPrimary, m.effective_start AS EffectiveStart,
           m.effective_end AS EffectiveEnd, m.status AS Status,
           CASE WHEN m.status = N'PENDING_VALIDATION' THEN N'PENDING'
                WHEN m.status = N'INACTIVE' OR m.effective_end < @today THEN N'ENDED'
                WHEN m.effective_start > @today THEN N'FUTURE' ELSE N'CURRENT' END AS EffectiveState,
           m.preferred_channel AS PreferredChannel, m.notification_participation AS NotificationParticipation, m.notes AS Notes,
           ce.employee_name AS CreatedByName, m.entered_dt AS CreatedDt, ve.employee_name AS ValidatedByName, m.validated_dt AS ValidatedDt,
           m.end_reason AS EndReason,
           CASE WHEN @actor_employee_id IS NOT NULL AND m.created_by_employee_id = @actor_employee_id THEN 1 ELSE 0 END AS ActorIsCreator,
           CONVERT(BIGINT, m.record_version) AS RecordVersion
      FROM grac_practice.asset_contract_contact m
      JOIN grac_practice.asset_contract_contact_role r ON r.role_code = m.role_code
      JOIN grac_practice.organization_employee e ON e.employee_id = m.employee_id
      LEFT JOIN grac_practice.asset_contract_version xv ON xv.version_id = m.version_id
      LEFT JOIN grac_practice.organization_employee ce ON ce.employee_id = m.created_by_employee_id
      LEFT JOIN grac_practice.organization_employee ve ON ve.employee_id = m.validated_by_employee_id
     WHERE m.contract_id = @contract_id
     ORDER BY CASE WHEN m.status = N'INACTIVE' THEN 1 ELSE 0 END, r.display_order, m.is_primary DESC, m.effective_start DESC;

    SELECT d.document_id AS DocumentId, d.version_id AS VersionId, v.version_no AS VersionNo, d.document_type AS DocumentType,
           d.title AS Title, d.reference_text AS ReferenceText, d.status AS Status, d.entered_by AS AddedBy, d.entered_dt AS AddedDt,
           d.removed_by AS RemovedBy, d.removed_dt AS RemovedDt
      FROM grac_practice.asset_contract_document d
      JOIN grac_practice.asset_contract_version v ON v.version_id = d.version_id
     WHERE d.contract_id = @contract_id
     ORDER BY v.version_no DESC, d.entered_dt DESC;

    SELECT l.transition_log_id AS TransitionLogId, v.version_id AS VersionId, v.version_no AS VersionNo,
           fs.status_name AS FromStatus, ts.status_name AS ToStatus, l.reason_code AS ReasonCode, l.reason_text AS ReasonText,
           emp.employee_name AS ActorName, l.transitioned_at AS TransitionedAt
      FROM grac_practice.entity_state_transition_log l
      JOIN grac_practice.asset_contract_version v ON v.version_id = l.entity_id
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_status_id = l.from_status_id
      JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = l.to_status_id
      LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id = l.actor_employee_id
     WHERE l.entity_type = N'ContractVersion' AND v.contract_id = @contract_id
     ORDER BY l.transitioned_at DESC, l.transition_log_id DESC;

    SELECT w.WarningCode, w.RoleCode, w.Warning
      FROM grac_practice.fn_asset_contract_readiness(@open) w
     WHERE @open IS NOT NULL;

    SELECT v.version_id AS VersionId, v.version_no AS VersionNo, s.role_name AS RoleName, s.contact_name AS ContactName,
           s.contact_email AS ContactEmail, s.vendor_name AS VendorName, s.is_primary AS IsPrimary, s.preferred_channel AS PreferredChannel,
           s.notification_participation AS NotificationParticipation, s.effective_start AS EffectiveStart, s.effective_end AS EffectiveEnd
      FROM grac_practice.asset_contract_version_contact s
      JOIN grac_practice.asset_contract_version v ON v.version_id = s.version_id
      JOIN grac_practice.asset_contract_contact_role r ON r.role_code = s.role_code
     WHERE v.contract_id = @contract_id
     ORDER BY v.version_no DESC, r.display_order, s.is_primary DESC, s.contact_name;
END
GO

-- 7.2.3 Version Details: 1. the version  2. its vendor contacts (snapshot
-- or live)  3. its documents  4. its status history  5. warnings while open
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_version_get
    @organization_id   BIGINT,
    @version_id        BIGINT,
    @actor_employee_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c BIGINT = (SELECT contract_id FROM grac_practice.asset_contract_version
                          WHERE version_id = @version_id AND organization_id = @organization_id);
    IF @c IS NULL THROW 54519, 'Contract version not found for this organization.', 1;
    EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id, @contract_id = @c;

    SELECT v.version_id AS VersionId, v.contract_id AS ContractId, c.contract_number AS ContractNumber, c.contract_name AS ContractName,
           v.version_no AS VersionNo, v.version_label AS VersionLabel, v.version_type AS VersionType, s.status_code AS StatusCode,
           s.status_name AS StatusName, v.effective_start AS EffectiveStart, v.effective_end AS EffectiveEnd, v.notice_date AS NoticeDate,
           v.decision_date AS DecisionDate, v.termination_date AS TerminationDate, v.contract_value AS ContractValue,
           v.currency_code AS CurrencyCode, v.tax_details AS TaxDetails, v.payment_terms AS PaymentTerms, v.po_reference AS PoReference,
           v.invoice_reference AS InvoiceReference, v.cost_allocation AS CostAllocation, v.renewal_terms AS RenewalTerms,
           v.service_scope AS ServiceScope, v.sla_terms AS SlaTerms, v.support_hours AS SupportHours, v.response_time AS ResponseTime,
           v.resolution_time AS ResolutionTime, v.service_visits AS ServiceVisits,
           v.contract_owner_id AS ContractOwnerId, o1.employee_name AS ContractOwnerName,
           v.procurement_owner_id AS ProcurementOwnerId, o2.employee_name AS ProcurementOwnerName,
           COALESCE(v.vendor_name_snapshot, vd.vendor_name) AS VendorName, v.change_summary AS ChangeSummary,
           v.entered_by AS CreatedBy, ce.employee_name AS CreatedByName, v.entered_dt AS CreatedDt,
           se.employee_name AS SubmittedByName, v.submitted_dt AS SubmittedDt, re.employee_name AS ReviewedByName, v.reviewed_dt AS ReviewedDt,
           ae.employee_name AS ApprovedByName, v.approved_by AS ApprovedBy, v.approval_dt AS ApprovalDt, v.decision_note AS DecisionNote,
           sv.version_no AS SupersedesVersionNo, bv.version_no AS SupersededByVersionNo, v.activated_dt AS ActivatedDt, v.closed_dt AS ClosedDt,
           CASE WHEN @actor_employee_id IS NOT NULL AND v.submitted_by_employee_id = @actor_employee_id THEN 1 ELSE 0 END AS ActorIsSubmitter,
           CONVERT(BIGINT, v.record_version) AS RecordVersion
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
      JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = c.vendor_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
      LEFT JOIN grac_practice.organization_employee o1 ON o1.employee_id = v.contract_owner_id
      LEFT JOIN grac_practice.organization_employee o2 ON o2.employee_id = v.procurement_owner_id
      LEFT JOIN grac_practice.organization_employee ce ON ce.employee_id = v.created_by_employee_id
      LEFT JOIN grac_practice.organization_employee se ON se.employee_id = v.submitted_by_employee_id
      LEFT JOIN grac_practice.organization_employee re ON re.employee_id = v.reviewed_by_employee_id
      LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = v.approved_by_employee_id
      LEFT JOIN grac_practice.asset_contract_version sv ON sv.version_id = v.supersedes_version_id
      LEFT JOIN grac_practice.asset_contract_version bv ON bv.version_id = v.superseded_by_version_id
     WHERE v.version_id = @version_id;

    SELECT k.MappingId, k.RoleCode, k.RoleName, k.IsPrimary, k.EmployeeId, k.ContactName, k.ContactEmail, k.VendorName,
           k.PreferredChannel, k.NotificationParticipation, k.EffectiveStart, k.EffectiveEnd, k.Source, k.MappingStatus
      FROM grac_practice.fn_asset_contract_version_contacts(@version_id) k
     ORDER BY k.RoleName, k.IsPrimary DESC, k.ContactName;

    SELECT d.document_id AS DocumentId, d.document_type AS DocumentType, d.title AS Title, d.reference_text AS ReferenceText,
           d.status AS Status, d.entered_by AS AddedBy, d.entered_dt AS AddedDt, d.removed_by AS RemovedBy, d.removed_dt AS RemovedDt
      FROM grac_practice.asset_contract_document d
     WHERE d.version_id = @version_id
     ORDER BY d.entered_dt DESC;

    SELECT l.transition_log_id AS TransitionLogId, fs.status_name AS FromStatus, ts.status_name AS ToStatus, l.reason_code AS ReasonCode,
           l.reason_text AS ReasonText, emp.employee_name AS ActorName, l.transitioned_at AS TransitionedAt
      FROM grac_practice.entity_state_transition_log l
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_status_id = l.from_status_id
      JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = l.to_status_id
      LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id = l.actor_employee_id
     WHERE l.entity_type = N'ContractVersion' AND l.entity_id = @version_id
     ORDER BY l.transitioned_at DESC, l.transition_log_id DESC;

    SELECT w.WarningCode, w.RoleCode, w.Warning
      FROM grac_practice.fn_asset_contract_readiness(@version_id) w
      JOIN grac_practice.asset_contract_version v ON v.version_id = @version_id
     WHERE v.approval_dt IS NULL;
END
GO

-- 7.2.4 comparison (read-only): 1. heading for the export (contract,
-- versions, user, generated timestamp)  2. field differences  3. vendor
-- contact-role differences.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_version_compare
    @organization_id   BIGINT,
    @version_a         BIGINT,
    @version_b         BIGINT,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ca BIGINT = (SELECT contract_id FROM grac_practice.asset_contract_version WHERE version_id = @version_a AND organization_id = @organization_id),
            @cb BIGINT = (SELECT contract_id FROM grac_practice.asset_contract_version WHERE version_id = @version_b AND organization_id = @organization_id);
    IF @ca IS NULL OR @cb IS NULL OR @ca <> @cb OR @version_a = @version_b
        THROW 54543, 'Select two different versions of the same contract.', 1;

    SELECT c.contract_id AS ContractId, c.contract_number AS ContractNumber, c.contract_name AS ContractName,
           va.version_no AS VersionANo, vb.version_no AS VersionBNo,
           COALESCE((SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id = @actor_employee_id), @actor) AS GeneratedBy,
           SYSUTCDATETIME() AS GeneratedAt
      FROM grac_practice.asset_contract c
      JOIN grac_practice.asset_contract_version va ON va.version_id = @version_a
      JOIN grac_practice.asset_contract_version vb ON vb.version_id = @version_b
     WHERE c.contract_id = @ca;

    ;WITH f AS (
        SELECT x.version_id, k.FieldKey, k.Label, k.Ord, k.Val
          FROM grac_practice.asset_contract_version x
          JOIN grac_practice.asset_contract c ON c.contract_id = x.contract_id
          JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = c.vendor_id
          JOIN grac_practice.entity_status_master s ON s.entity_status_id = x.current_status_id
          LEFT JOIN grac_practice.organization_employee o1 ON o1.employee_id = x.contract_owner_id
          LEFT JOIN grac_practice.organization_employee o2 ON o2.employee_id = x.procurement_owner_id
         CROSS APPLY (VALUES
            (N'versionType',      N'Version type',          10, CAST(x.version_type AS NVARCHAR(2000))),
            (N'status',           N'Status',                20, CAST(s.status_name AS NVARCHAR(2000))),
            (N'effectiveStart',   N'Effective start',       30, CONVERT(NVARCHAR(10), x.effective_start, 23)),
            (N'effectiveEnd',     N'Effective end',         40, CONVERT(NVARCHAR(10), x.effective_end, 23)),
            (N'noticeDate',       N'Notice date',           50, CONVERT(NVARCHAR(10), x.notice_date, 23)),
            (N'decisionDate',     N'Decision date',         60, CONVERT(NVARCHAR(10), x.decision_date, 23)),
            (N'terminationDate',  N'Termination date',      70, CONVERT(NVARCHAR(10), x.termination_date, 23)),
            (N'contractValue',    N'Contract value',        80, CONVERT(NVARCHAR(40), x.contract_value)),
            (N'currencyCode',     N'Currency',              90, CAST(x.currency_code AS NVARCHAR(2000))),
            (N'taxDetails',       N'Tax',                  100, CAST(x.tax_details AS NVARCHAR(2000))),
            (N'paymentTerms',     N'Payment terms',        110, CAST(x.payment_terms AS NVARCHAR(2000))),
            (N'poReference',      N'PO reference',         120, CAST(x.po_reference AS NVARCHAR(2000))),
            (N'invoiceReference', N'Invoice reference',    130, CAST(x.invoice_reference AS NVARCHAR(2000))),
            (N'costAllocation',   N'Cost allocation',      140, CAST(x.cost_allocation AS NVARCHAR(2000))),
            (N'renewalTerms',     N'Renewal terms',        150, CAST(x.renewal_terms AS NVARCHAR(2000))),
            (N'serviceScope',     N'Service scope',        160, CAST(x.service_scope AS NVARCHAR(2000))),
            (N'slaTerms',         N'SLA',                  170, CAST(x.sla_terms AS NVARCHAR(2000))),
            (N'supportHours',     N'Support hours',        180, CAST(x.support_hours AS NVARCHAR(2000))),
            (N'responseTime',     N'Response time',        190, CAST(x.response_time AS NVARCHAR(2000))),
            (N'resolutionTime',   N'Resolution time',      200, CAST(x.resolution_time AS NVARCHAR(2000))),
            (N'serviceVisits',    N'Visits',               210, CAST(x.service_visits AS NVARCHAR(2000))),
            (N'contractOwner',    N'Contract owner',       220, CAST(o1.employee_name AS NVARCHAR(2000))),
            (N'procurementOwner', N'Procurement owner',    230, CAST(o2.employee_name AS NVARCHAR(2000))),
            (N'vendor',           N'Vendor',               240, CAST(COALESCE(x.vendor_name_snapshot, vd.vendor_name) AS NVARCHAR(2000))),
            (N'changeSummary',    N'Change summary',       250, CAST(x.change_summary AS NVARCHAR(2000)))
         ) k(FieldKey, Label, Ord, Val)
         WHERE x.version_id IN (@version_a, @version_b))
    SELECT a.FieldKey, a.Label, a.Val AS ValueA, b.Val AS ValueB,
           CASE WHEN ISNULL(a.Val, N'') COLLATE Latin1_General_BIN2 = ISNULL(b.Val, N'') COLLATE Latin1_General_BIN2 THEN 0 ELSE 1 END AS Changed
      FROM f a
      JOIN f b ON b.FieldKey = a.FieldKey AND b.version_id = @version_b
     WHERE a.version_id = @version_a
     ORDER BY a.Ord;

    ;WITH ca AS (SELECT RoleCode, RoleName, EmployeeId, ContactName, IsPrimary FROM grac_practice.fn_asset_contract_version_contacts(@version_a)),
          cb AS (SELECT RoleCode, RoleName, EmployeeId, ContactName, IsPrimary FROM grac_practice.fn_asset_contract_version_contacts(@version_b))
    SELECT COALESCE(ca.RoleCode, cb.RoleCode) AS RoleCode, COALESCE(ca.RoleName, cb.RoleName) AS RoleName,
           COALESCE(ca.ContactName, cb.ContactName) AS ContactName, ca.IsPrimary AS PrimaryInA, cb.IsPrimary AS PrimaryInB,
           CASE WHEN ca.EmployeeId IS NULL THEN N'ADDED' WHEN cb.EmployeeId IS NULL THEN N'REMOVED'
                WHEN ca.IsPrimary <> cb.IsPrimary THEN N'CHANGED' ELSE N'SAME' END AS ChangeType
      FROM ca
      FULL OUTER JOIN cb ON cb.RoleCode = ca.RoleCode AND cb.EmployeeId = ca.EmployeeId
     ORDER BY RoleName, ContactName;
END
GO

-- Pickers: 1. vendors  2. vendor users (ThirdParty people by vendor)
-- 3. employees (owners)  4. contract types  5. contact roles  6. contracts
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_lookups
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT vendor_id AS VendorId, vendor_name AS VendorName, status AS Status
      FROM grac_practice.organization_dependency_vendor WHERE organization_id = @organization_id ORDER BY vendor_name;
    SELECT employee_id AS EmployeeId, employee_name AS EmployeeName, email AS Email, provider_vendor_id AS VendorId, status AS Status
      FROM grac_practice.organization_employee
     WHERE organization_id = @organization_id AND party_type = N'ThirdParty' AND provider_vendor_id IS NOT NULL
     ORDER BY employee_name;
    SELECT employee_id AS EmployeeId, employee_name AS EmployeeName
      FROM grac_practice.organization_employee
     WHERE organization_id = @organization_id AND status = N'Active' AND ISNULL(party_type, N'Employee') = N'Employee'
     ORDER BY employee_name;
    SELECT OptionValue, OptionLabel
      FROM grac_practice.fn_asset_field_options(@organization_id)
     WHERE OptionGroup = N'asset_field.coverage_type'
     ORDER BY DisplayOrder, OptionLabel;
    SELECT role_code AS RoleCode, role_name AS RoleName, typical_use AS TypicalUse, is_mandatory AS IsMandatory
      FROM grac_practice.asset_contract_contact_role WHERE is_active = 1 ORDER BY display_order;
    SELECT contract_id AS ContractId, contract_number AS ContractNumber, contract_name AS ContractName, contract_status AS ContractStatus
      FROM grac_practice.asset_contract WHERE organization_id = @organization_id ORDER BY contract_number;
END
GO
PRINT '434: readers created.';
GO

-- =====================================================================
-- 7. Menu: Asset & Contract -> Contracts (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-contracts', N'Contracts', N'Practice/Index/asset-contracts', 358, N'file-contract', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-434', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-434');
PRINT CONCAT('434: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-434', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-contracts' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 1, N'Active', @active_rs, N'seed-434', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-contracts'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('434: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '434-a version statuses and transitions seeded' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.entity_status_master WHERE entity_type = N'ContractVersion') = 9
             AND (SELECT COUNT(*) FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'ContractVersion') >= 15
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '434-b tables present',
       CASE WHEN OBJECT_ID('grac_practice.asset_contract','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_contract_version','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_contract_document','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_contract_contact_role','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_contract_contact','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_contract_version_contact','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '434-c 11 contact roles, Primary Contact mandatory',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.asset_contract_contact_role) >= 11
             AND EXISTS (SELECT 1 FROM grac_practice.asset_contract_contact_role WHERE role_code = N'PRIMARY_CONTACT' AND is_mandatory = 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '434-d procedures and functions present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_contract_version_move', 'sp_asset_contract_sync', 'sp_asset_contract_version_check',
                                'sp_asset_contract_save', 'sp_asset_contract_version_create', 'sp_asset_contract_version_save',
                                'sp_asset_contract_version_action', 'sp_asset_contract_contact_save', 'sp_asset_contract_contact_action',
                                'sp_asset_contract_document_add', 'sp_asset_contract_document_remove', 'sp_asset_contract_list',
                                'sp_asset_contract_get', 'sp_asset_contract_version_get', 'sp_asset_contract_version_compare',
                                'sp_asset_contract_lookups')) = 16
             AND OBJECT_ID('grac_practice.fn_asset_contract_version_contacts') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_contract_readiness') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '434-e coverage type list available for contract types',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_option_list_master WHERE option_group = N'asset_field.coverage_type' AND is_active = 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '434-f menu row Active under Asset & Contract',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-contracts' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; re-login for the menu grant)
--   Needs: an active vendor (Settings -> Dependencies -> Vendors) with at
--   least two ThirdParty people linked to it (Settings -> People, party
--   type Third party, provider vendor), and two employees with logins
--   (A prepares, B reviews / approves).
--   1. As A: Contracts -> New contract (ID, name, type AMC, vendor) ->
--      Version 1 Draft opens. Saving with an end date before the start
--      date is refused. Fill dates, value + currency, owner; Submit.
--      Warnings list "No validated Primary Contact ...".
--   2. As A: Contacts -> add vendor user X as Primary Contact (Pending
--      validation). Adding a second primary for the same role and period
--      is refused. As B: Validate X (A cannot validate own mapping).
--   3. As B: Review -> Pending Approval; Approve -> Approved, and Active at
--      once when the start date is today or earlier. A cannot review or
--      approve the version A submitted.
--   4. Editing Version 1 is refused (immutable). New version -> Amendment
--      with a change summary -> Version 2 Draft copied from Version 1.
--      Change the value; Compare 1 and 2 -> value changed; export CSV.
--   5. Approve Version 2 effective today -> Version 1 Superseded, Version 2
--      Active; Version history and Approval history show every step;
--      Contact history shows the contacts frozen with each version.
--   6. End X (reason) -> end date set, mapping kept. Approve a Renewal
--      (Version 3) starting after Version 2 ends; then an Amendment whose
--      dates reach into Version 3 is refused at Submit (one version per
--      date). An approved Termination version dated today or earlier
--      makes the contract Terminated, marks Version 3 Superseded and
--      blocks new versions.
-- =====================================================================
