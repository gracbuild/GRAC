-- =====================================================================
-- 452  Asset & Contract report catalogue and governed CSV export
--      (Asset & Contract Management, Phase 8 increment 5a)
--
-- REQUEST
-- -------
--   BRD v1.7 13.4 Standard Reporting Catalog ("governed report
--   definitions with filters, columns, grouping, authorized drill-down,
--   export controls, schedule, retention and distribution rules"; the
--   report families Asset, Attestation, CMDB and Service, Discovery and
--   Data Quality, Contract, Technology, Risk and CIA, Governance, Privacy
--   and Compliance), 13.4.1 Reporting Controls ("reports shall use the
--   same authorization, tenant, field sensitivity, active configuration
--   and calculation rules as application screens and APIs"; "exports
--   shall record report / version, filters, columns, user, tenant,
--   generation time and classification"; "sensitive exports may require
--   watermarking, encryption, approval, expiry or download restrictions
--   according to policy"; "report totals and dashboard drill-downs shall
--   reconcile to the same filtered source records"), 13.2.7 exports.
--   Plan: docs/asset-contract-management.md (Phase 8.5a, D194-D210).
--
-- WHAT THIS DOES
-- --------------
--   1. asset_report_definition -- the 13.4 catalogue: one row per
--      standard report (family, name, description, version, default
--      classification, the screen whose VIEW permission it needs, the
--      family procedure, the filters it takes and the status options);
--      reports the module cannot produce yet are listed as not available
--      with the place they live today. A changed definition gets a new
--      version number (re-running this script bumps only what changed).
--   2. asset_report_org_setting -- per organization and report: enabled,
--      a higher classification, the export policy (ALLOWED, APPROVER,
--      DISABLED).
--   3. asset_report_export -- immutable export log: report and version,
--      organization, filters, columns, row count, classification, user,
--      employee and time.
--   4. fn_asset_report_assets -- the register rows (sp_asset_register_list
--      status rule, 444 search incl. aliases, 450 "in use") shared by every
--      asset-based report.
--   5. Family procedures sp_asset_report_asset / _attestation / _cmdb /
--      _discovery / _contract / _technology / _risk / _governance /
--      _privacy: one branch per report, same filters and paging.
--   6. sp_asset_report_catalogue, sp_asset_report_run (permission, policy
--      and filter checks, then the family procedure), sp_asset_report_
--      export_log, sp_asset_report_exports, sp_asset_report_org_setting_save.
--   7. Menu Asset & Contract -> Asset Reports (366; also in 274).
--
-- NOT DONE HERE (Phase 8.5b): scheduled delivery, distribution lists and
--   report retention (13.4 "schedule, retention and distribution rules",
--   13.4.1 delivery-time recipient checks); encrypted or expiring files
--   (exports are CSV downloads with a classification watermark); the
--   reports listed as not available (see asset_report_definition).
--
-- ERROR NUMBERS: 53100-53119
--   53100 organization not found        53101 unknown report
--   53102 report not available yet     53103 no permission for the report screen
--   53104 report disabled for the organization
--   53105 export not allowed by policy (or needs Asset Reports APPROVE)
--   53106 filter invalid (dates, days)  53107 export too large
--   53108 classification lower than the default / invalid
--   53109 export policy invalid         53110 report procedure missing
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web
--   proxy (asset-reports area, caller screen areas), PracticeScreen +
--   Manage.cshtml + appsettings (new screen), new asset-reports.cshtml /
--   .js, 274 (menu), docs.
-- DEPENDS ON: 428-451.
-- Rollback: 452_asset_reports_rollback.sql (drops the 452 objects, the
--   export log and the menu row).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_dashboard_asset_contract','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_governance_assets') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_governance_items') IS NULL
   OR OBJECT_ID('grac_practice.asset_governance_snapshot_item','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_privacy_status') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_privacy_gaps') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_privacy_retention_calc') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_technology_status') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_coverage_gaps') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_coverage_summary') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_verification_exception_view') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_ci_catalog') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_discovery_confidence') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_stale_state') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_risk_value') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_field_options') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_contract_sync','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_merge_split_member','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_alias','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_evidence_field','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_valuation_result','U') IS NULL
   OR OBJECT_ID('grac_practice.risk_dependency_map','U') IS NULL
   OR COL_LENGTH('grac_practice.risk_register', 'residual_rating_name') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-asset-contract')
BEGIN
    RAISERROR('ABORT (452): run 428-451 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Report catalogue (global) -- BRD 13.4
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_report_definition','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_report_definition (
        report_code            NVARCHAR(40)   NOT NULL CONSTRAINT pk_pm_arpt_def PRIMARY KEY,
        family_code            NVARCHAR(20)   NOT NULL,
        family_name            NVARCHAR(60)   NOT NULL,
        report_name            NVARCHAR(120)  NOT NULL,
        description            NVARCHAR(1000) NOT NULL,
        version_no             INT            NOT NULL CONSTRAINT df_pm_arpt_def_ver DEFAULT 1,
        default_classification NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_arpt_def_cls CHECK (default_classification IN (N'PUBLIC', N'INTERNAL', N'CONFIDENTIAL', N'RESTRICTED')),
        view_area              NVARCHAR(100)  NOT NULL,      -- the screen whose VIEW permission the report needs
        proc_name              NVARCHAR(128)  NULL,          -- family procedure (grac_practice schema)
        is_available           BIT            NOT NULL,
        unavailable_reason     NVARCHAR(400)  NULL,
        filter_keys            NVARCHAR(200)  NOT NULL,      -- comma list: SEARCH, STATUS, ASSET_TYPE, DATE_RANGE, DAYS
        status_label           NVARCHAR(60)   NULL,
        status_options         NVARCHAR(1000) NULL,          -- CODE=Label|CODE=Label, or @ASSET_STATUS
        date_label             NVARCHAR(60)   NULL,
        default_days           INT            NULL,
        display_order          INT            NOT NULL,
        brd_reference          NVARCHAR(40)   NOT NULL,
        is_active              BIT            NOT NULL CONSTRAINT df_pm_arpt_def_act DEFAULT 1,
        entered_by             NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_arpt_def_eby DEFAULT N'system',
        entered_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_arpt_def_edt DEFAULT SYSUTCDATETIME(),
        updated_by             NVARCHAR(100)  NULL,
        updated_dt             DATETIME2      NULL,
        CONSTRAINT ck_pm_arpt_def_avail CHECK (is_available = 0 OR proc_name IS NOT NULL)
    );
    PRINT '452: asset_report_definition created.';
END
GO

IF OBJECT_ID('grac_practice.asset_report_org_setting','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_report_org_setting (
        organization_id BIGINT        NOT NULL
            CONSTRAINT fk_pm_arpt_os_org REFERENCES grac_practice.organization(organization_id),
        report_code     NVARCHAR(40)  NOT NULL
            CONSTRAINT fk_pm_arpt_os_def REFERENCES grac_practice.asset_report_definition(report_code),
        is_enabled      BIT           NOT NULL CONSTRAINT df_pm_arpt_os_en DEFAULT 1,
        classification  NVARCHAR(20)  NULL           -- NULL = the default classification
            CONSTRAINT ck_pm_arpt_os_cls CHECK (classification IS NULL
                OR classification IN (N'PUBLIC', N'INTERNAL', N'CONFIDENTIAL', N'RESTRICTED')),
        export_policy   NVARCHAR(10)  NULL           -- NULL = APPROVER when RESTRICTED, else ALLOWED
            CONSTRAINT ck_pm_arpt_os_pol CHECK (export_policy IS NULL OR export_policy IN (N'ALLOWED', N'APPROVER', N'DISABLED')),
        entered_by      NVARCHAR(100) NOT NULL CONSTRAINT df_pm_arpt_os_eby DEFAULT N'system',
        entered_dt      DATETIME2     NOT NULL CONSTRAINT df_pm_arpt_os_edt DEFAULT SYSUTCDATETIME(),
        updated_by      NVARCHAR(100) NULL,
        updated_dt      DATETIME2     NULL,
        CONSTRAINT pk_pm_arpt_os PRIMARY KEY (organization_id, report_code)
    );
    PRINT '452: asset_report_org_setting created.';
END
GO

IF OBJECT_ID('grac_practice.asset_report_export','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_report_export (
        export_id            BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_arpt_exp PRIMARY KEY,
        organization_id      BIGINT         NOT NULL
            CONSTRAINT fk_pm_arpt_exp_org REFERENCES grac_practice.organization(organization_id),
        report_code          NVARCHAR(40)   NOT NULL
            CONSTRAINT fk_pm_arpt_exp_def REFERENCES grac_practice.asset_report_definition(report_code),
        report_version       INT            NOT NULL,
        report_name          NVARCHAR(120)  NOT NULL,
        classification       NVARCHAR(20)   NOT NULL,
        file_format          NVARCHAR(10)   NOT NULL CONSTRAINT df_pm_arpt_exp_fmt DEFAULT N'CSV'
            CONSTRAINT ck_pm_arpt_exp_fmt CHECK (file_format IN (N'CSV')),
        filters_json         NVARCHAR(MAX)  NULL,
        columns_json         NVARCHAR(MAX)  NULL,
        row_count            INT            NOT NULL,
        exported_by          NVARCHAR(100)  NOT NULL,
        exported_employee_id BIGINT         NULL,
        exported_dt          DATETIME2      NOT NULL CONSTRAINT df_pm_arpt_exp_dt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_arpt_exp_org ON grac_practice.asset_report_export(organization_id, exported_dt DESC);
    PRINT '452: asset_report_export created.';
END
GO
-- =====================================================================
-- 2. The standard reports (13.4). A changed definition gets the next
--    version number; reports the module cannot produce are listed as not
--    available with the place they live today (D196).
-- =====================================================================
MERGE grac_practice.asset_report_definition AS t
USING (VALUES
    (N'ASSET_REGISTER', N'ASSET', N'Asset', N'Complete Asset Register', N'Every asset record of the organization with category, type, lifecycle status and phase, owner, location, criticality, Asset Value, coverage status and whether it is in use. Same status rule and search (name, ID, alias) as the Asset Register.', N'INTERNAL', N'asset-register', N'sp_asset_report_asset', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'Lifecycle status', N'@ASSET_STATUS', NULL, NULL, 110, N'13.4 Asset'),
    (N'ASSET_OWNERSHIP', N'ASSET', N'Asset', N'Ownership and Custody', N'The current assignment of each asset: owner, custodian (person or team), department, site, building, floor, room and since when. Status picks assets with no owner, no custodian or both recorded.', N'CONFIDENTIAL', N'asset-register', N'sp_asset_report_asset', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'Assignment', N'NO_OWNER=No owner|NO_CUSTODIAN=No custodian|ASSIGNED=Owner and custodian recorded', NULL, NULL, 120, N'13.4 Asset'),
    (N'ASSET_LIFECYCLE', N'ASSET', N'Asset', N'Lifecycle Status', N'Each asset with its lifecycle status and phase, the date it entered that status, days in status and the lifecycle change awaiting approval (target status, requested by and when).', N'INTERNAL', N'asset-register', N'sp_asset_report_asset', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'Lifecycle status', N'@ASSET_STATUS', NULL, NULL, 130, N'13.4 Asset'),
    (N'ASSET_MISSING_DATA', N'ASSET', N'Asset', N'Missing Mandatory Data', N'Assets in use whose asset form has mandatory fields left empty, evaluated now by the form engine (the Metadata Completeness rule): how many of the mandatory fields are empty and which.', N'INTERNAL', N'asset-register', N'sp_asset_report_asset', 1, NULL, N'SEARCH,ASSET_TYPE', NULL, NULL, NULL, NULL, 140, N'13.4 Asset'),
    (N'ASSET_MOVEMENT', N'ASSET', N'Asset', N'Asset Movement', N'Assignment history: every change of owner, custodian, department or place with the previous site, effective dates and who recorded it. Dates filter the effective-from date.', N'CONFIDENTIAL', N'asset-register', N'sp_asset_report_asset', 1, NULL, N'SEARCH,ASSET_TYPE,DATE_RANGE', NULL, NULL, N'Effective from', NULL, 150, N'13.4 Asset'),
    (N'ASSET_DISPOSAL', N'ASSET', N'Asset', N'Disposal and Sanitization', N'Assets on the way out or disposed (Pending Decommission, Sanitization Pending, Disposal Approval, Disposed, Archived) with deletion / sanitization required, method, date, evidence and what is still missing.', N'CONFIDENTIAL', N'asset-register', N'sp_asset_report_asset', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'Lifecycle status', N'PENDING_DECOMMISSION=Pending Decommission|SANITIZATION_PENDING=Sanitization Pending|DISPOSAL_APPROVAL=Disposal Approval|DISPOSED=Disposed|ARCHIVED=Archived', NULL, NULL, 160, N'13.4 Asset'),
    (N'ATT_COMPLIANCE', N'ATTESTATION', N'Attestation', N'Attestation Compliance', N'Attestation occurrences with their display status (open and past due = Overdue) and whether each counts as compliant (Confirmed, Resolved or Closed; Cancelled is excluded), the Attestation Compliance KPI rule. Dates filter the due date.', N'INTERNAL', N'asset-attestation', N'sp_asset_report_attestation', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE,DATE_RANGE', N'Display status', N'GENERATED=Generated|PENDING=Pending|IN_PROGRESS=In progress|OVERDUE=Overdue|ESCALATED=Escalated|CONFIRMED=Confirmed|DISPUTED=Disputed|EXCEPTION=Exception|RESOLVED=Resolved|CLOSED=Closed|CANCELLED=Cancelled', N'Due date', NULL, 210, N'13.4 Attestation'),
    (N'ATT_OVERDUE', N'ATTESTATION', N'Attestation', N'Overdue Attestations', N'Open attestations past their due date (and escalated ones) with the assignee, due date and days overdue.', N'INTERNAL', N'asset-attestation', N'sp_asset_report_attestation', 1, NULL, N'SEARCH,ASSET_TYPE', NULL, NULL, NULL, NULL, 220, N'13.4 Attestation'),
    (N'ATT_EXCEPTIONS', N'ATTESTATION', N'Attestation', N'Disagreement and Exception Register', N'Verification exceptions raised from attestation disagreements: category, severity, investigator, status, SLA dates, outcome and resolution. Dates filter the reported date.', N'CONFIDENTIAL', N'asset-attestation', N'sp_asset_report_attestation', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE,DATE_RANGE', N'Exception status', N'OPEN=Open|ASSIGNED=Assigned|UNDER_REVIEW=Under Review|AWAITING_EVIDENCE=Awaiting Evidence|AWAITING_APPROVAL=Awaiting Approval|RESOLVED=Resolved|CLOSED=Closed|CANCELLED=Cancelled', N'Reported', NULL, 230, N'13.4 Attestation'),
    (N'ATT_LOST_DAMAGED', N'ATTESTATION', N'Attestation', N'Lost/Damaged Assets', N'Verification exceptions for assets not found, lost or damaged, and exceptions closed with loss or damage confirmed, with the current lifecycle status of the asset and the lost-asset security review.', N'CONFIDENTIAL', N'asset-attestation', N'sp_asset_report_attestation', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'Exception', N'OPEN=Not closed|CONFIRMED=Loss or damage confirmed', NULL, NULL, 240, N'13.4 Attestation'),
    (N'ATT_SLA', N'ATTESTATION', N'Attestation', N'SLA Breach and Ageing', N'Open verification exceptions with age, start and resolution due dates, days overdue and escalation level (5.3.9 levels).', N'INTERNAL', N'asset-attestation', N'sp_asset_report_attestation', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'SLA', N'BREACHED=Start or resolution overdue|ON_TRACK=Within SLA', NULL, NULL, 250, N'13.4 Attestation'),
    (N'CMDB_RELATIONSHIPS', N'CMDB', N'CMDB and Service', N'Asset Relationships', N'Every CMDB relationship: source, relationship type, target, critical flag and dependency criticality, status, effective dates, source of the record, confidence, verification and owner.', N'INTERNAL', N'asset-relationships', N'sp_asset_report_cmdb', 1, NULL, N'SEARCH,STATUS', N'Relationship status', N'PROPOSED=Proposed|ACTIVE=Active|DISPUTED=Disputed|INACTIVE=Inactive|RETIRED=Retired', NULL, NULL, 310, N'13.4 CMDB and Service'),
    (N'CMDB_ORPHANS', N'CMDB', N'CMDB and Service', N'Orphan Assets', N'Assets in use with no relationship (proposed, active or disputed) on either side.', N'INTERNAL', N'asset-relationships', N'sp_asset_report_cmdb', 1, NULL, N'SEARCH,ASSET_TYPE', NULL, NULL, NULL, NULL, 320, N'13.4 CMDB and Service'),
    (N'CMDB_TOPOLOGY', N'CMDB', N'CMDB and Service', N'Business Service Topology', N'Business services with the items that support them (Supports Service relationships): item kind and name, relationship status, critical flag and dependency criticality; services with no supporting item are listed once.', N'INTERNAL', N'business-services', N'sp_asset_report_cmdb', 1, NULL, N'SEARCH,STATUS', N'Service status', N'DRAFT=Draft|DESIGN=Design|ACTIVE=Active|DEGRADED=Degraded|SUSPENDED=Suspended|RETIRING=Retiring|RETIRED=Retired', NULL, NULL, 330, N'13.4 CMDB and Service'),
    (N'CMDB_CRITICAL', N'CMDB', N'CMDB and Service', N'Critical Dependencies', N'Active relationships marked critical or with a Critical / High dependency criticality.', N'INTERNAL', N'asset-relationships', N'sp_asset_report_cmdb', 1, NULL, N'SEARCH,STATUS', N'Dependency criticality', N'CRITICAL=Critical|HIGH=High|MEDIUM=Medium|LOW=Low', NULL, NULL, 340, N'13.4 CMDB and Service'),
    (N'CMDB_SERVICE_IMPACT', N'CMDB', N'CMDB and Service', N'Service Impact', N'Upstream and downstream impact of one configuration item.', N'INTERNAL', N'business-services', N'sp_asset_report_cmdb', 0, N'Shown per service in Business Services (Service impact); a catalogue report needs one item chosen first.', N'SEARCH', NULL, NULL, NULL, NULL, 350, N'13.4 CMDB and Service'),
    (N'CMDB_QUALITY', N'CMDB', N'CMDB and Service', N'Relationship Data Quality', N'One row per relationship issue: disputed, awaiting approval, active but unverified, active past its end date, active with an endpoint that is no longer usable, a change awaiting approval, confidence below 50.', N'INTERNAL', N'asset-relationships', N'sp_asset_report_cmdb', 1, NULL, N'SEARCH,STATUS', N'Issue', N'DISPUTED=Disputed|PROPOSED=Awaiting approval|UNVERIFIED=Active, unverified|EXPIRED=Active past end date|UNUSABLE=Endpoint not usable|PENDING_CHANGE=Change awaiting approval|LOW_CONFIDENCE=Confidence below 50', NULL, NULL, 360, N'13.4 CMDB and Service'),
    (N'DSC_COVERAGE', N'DISCOVERY', N'Discovery and Data Quality', N'Discovery Coverage', N'Data confidence of every asset not disposed or archived: discovery links, fresh links, identity score, last observed, open conflicts, attribute disagreements, last verified date and the overall confidence.', N'INTERNAL', N'asset-discovery', N'sp_asset_report_discovery', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'Data confidence', N'VERIFIED=Verified|PROBABLE=Probable|UNVERIFIED=Unverified|STALE=Stale|CONFLICTING=Conflicting', NULL, NULL, 410, N'13.4 Discovery and Data Quality'),
    (N'DSC_STALE', N'DISCOVERY', N'Discovery and Data Quality', N'Stale Assets', N'Assets on the stale list (unseen by every source longer than the aging rule, or with an open stale review): last observed, days unseen and the open review.', N'INTERNAL', N'asset-discovery', N'sp_asset_report_discovery', 1, NULL, N'SEARCH,ASSET_TYPE', NULL, NULL, NULL, NULL, 420, N'13.4 Discovery and Data Quality'),
    (N'DSC_SOURCES', N'DISCOVERY', N'Discovery and Data Quality', N'Source Health', N'Discovery sources with their health (Never run, Failed, Warning, Success; the source list rule) and the batches received in the last N days: count, records, updated, exceptions and errors.', N'INTERNAL', N'asset-discovery', N'sp_asset_report_discovery', 1, NULL, N'SEARCH,STATUS,DAYS', N'Health', N'NEVER=Never run|FAILED=Failed|WARNING=Warning|SUCCESS=Success', NULL, 30, 430, N'13.4 Discovery and Data Quality'),
    (N'DSC_RECON', N'DISCOVERY', N'Discovery and Data Quality', N'Reconciliation Queue', N'Open reconciliation exceptions of every kind with the source, external key, asset, field, current and observed values, match score and age.', N'INTERNAL', N'asset-discovery', N'sp_asset_report_discovery', 1, NULL, N'SEARCH,STATUS', N'Kind', N'SUGGESTED_MATCH=Suggested match|MANUAL_REVIEW=Manual review|NEW_CANDIDATE=New candidate|DUPLICATE=Duplicate|CONFLICT=Conflict', NULL, NULL, 440, N'13.4 Discovery and Data Quality'),
    (N'DSC_CONFLICTS', N'DISCOVERY', N'Discovery and Data Quality', N'Conflicts', N'Open attribute conflicts: asset, field, current and observed value, source and age.', N'INTERNAL', N'asset-discovery', N'sp_asset_report_discovery', 1, NULL, N'SEARCH', NULL, NULL, NULL, NULL, 450, N'13.4 Discovery and Data Quality'),
    (N'DSC_DUPLICATES', N'DISCOVERY', N'Discovery and Data Quality', N'Potential Duplicates', N'Open potential-duplicate exceptions: the two assets, match score, source and age.', N'INTERNAL', N'asset-discovery', N'sp_asset_report_discovery', 1, NULL, N'SEARCH', NULL, NULL, NULL, NULL, 460, N'13.4 Discovery and Data Quality'),
    (N'DSC_MERGE_SPLIT', N'DISCOVERY', N'Discovery and Data Quality', N'Merge/Split History', N'Merge and split events: kind, surviving asset, member count, status, reason, requested, executed and recovered. Dates filter the requested date.', N'INTERNAL', N'asset-discovery', N'sp_asset_report_discovery', 1, NULL, N'SEARCH,STATUS,DATE_RANGE', N'Event status', N'DRAFT=Draft|PENDING_APPROVAL=Pending approval|APPROVED=Approved|EXECUTED=Executed|RECOVERED=Recovered|REJECTED=Rejected|CANCELLED=Cancelled', N'Requested', NULL, 470, N'13.4 Discovery and Data Quality'),
    (N'CON_EXPIRY', N'CONTRACT', N'Contract', N'Expiry and Notice Calendar', N'Contracts whose version in force ends, or whose notice or decision date falls, within the next N days (or has passed while the contract is still Active / Approved), with days to end, owner and value.', N'INTERNAL', N'asset-contracts', N'sp_asset_report_contract', 1, NULL, N'SEARCH,STATUS,DAYS', N'Contract status', N'DRAFT=Draft|APPROVED=Approved|ACTIVE=Active|EXPIRED=Expired|TERMINATED=Terminated', NULL, 90, 510, N'13.4 Contract'),
    (N'CON_RENEWALS', N'CONTRACT', N'Contract', N'Renewal Forecast', N'Open renewals: contract, renewal type, status, due date, current and proposed expiry, renewal value and currency. Dates filter the due date.', N'INTERNAL', N'asset-contracts', N'sp_asset_report_contract', 1, NULL, N'SEARCH,STATUS,DATE_RANGE', N'Renewal type', N'RENEWAL=Renewal|EXTENSION=Extension|REBID=Rebid|REPLACEMENT=Replacement|NON_RENEWAL=Non-renewal', N'Due date', NULL, 520, N'13.4 Contract'),
    (N'CON_COVERAGE_GAPS', N'CONTRACT', N'Contract', N'Coverage Gaps', N'Assets missing coverage their asset type requires, or covered for less than the minimum period (the coverage requirement rule).', N'INTERNAL', N'asset-contracts', N'sp_asset_report_contract', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'Gap', N'MISSING=Missing|SHORT=Shorter than the minimum period', NULL, NULL, 530, N'13.4 Contract'),
    (N'CON_ENTITLEMENTS', N'CONTRACT', N'Contract', N'Entitlements', N'Entitlement lines of the version in force of each contract: product / SKU, coverage type, quantity, service level, support hours, dates and exclusions.', N'INTERNAL', N'asset-contracts', N'sp_asset_report_contract', 1, NULL, N'SEARCH,STATUS', N'Contract status', N'DRAFT=Draft|APPROVED=Approved|ACTIVE=Active|EXPIRED=Expired|TERMINATED=Terminated', NULL, NULL, 540, N'13.4 Contract'),
    (N'CON_CONTACTS', N'CONTRACT', N'Contract', N'Vendor Contact Matrix', N'Vendor contacts mapped to contracts: role, contact, email, primary, preferred channel, notifications, dates and mapping status.', N'CONFIDENTIAL', N'asset-contracts', N'sp_asset_report_contract', 1, NULL, N'SEARCH,STATUS', N'Mapping status', N'ACTIVE=Active|PENDING_VALIDATION=Pending validation|INACTIVE=Inactive', NULL, NULL, 550, N'13.4 Contract'),
    (N'CON_VERSION_COMPARE', N'CONTRACT', N'Contract', N'Version Comparison', N'Field-by-field comparison of two contract versions.', N'INTERNAL', N'asset-contracts', N'sp_asset_report_contract', 0, N'Asset Contracts -> a contract -> Compare versions, which has its own CSV export; it compares two chosen versions.', N'SEARCH', NULL, NULL, NULL, NULL, 560, N'13.4 Contract'),
    (N'TECH_UNSUPPORTED', N'TECHNOLOGY', N'Technology', N'Unsupported Assets', N'Assets in use running firmware or an operating system that is unsupported (end of support / life, withdrawn, or not approved for the model), including those covered by an approved technology exception.', N'INTERNAL', N'asset-register', N'sp_asset_report_technology', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'Classification', N'UNSUPPORTED=Unsupported|EXCEPTION=Exception', NULL, NULL, 610, N'13.4 Technology'),
    (N'TECH_DUE_SOON', N'TECHNOLOGY', N'Technology', N'Support Ending Soon', N'Assets in use whose firmware or operating system is deprecated / approaching end of support, or whose support ends within the next N days.', N'INTERNAL', N'asset-register', N'sp_asset_report_technology', 1, NULL, N'SEARCH,ASSET_TYPE,DAYS', NULL, NULL, NULL, 180, 620, N'13.4 Technology'),
    (N'TECH_FIRMWARE', N'TECHNOLOGY', N'Technology', N'Firmware Compliance', N'Firmware of every asset in use whose form records firmware: current version, release status, support end, recommended target and classification.', N'INTERNAL', N'asset-register', N'sp_asset_report_technology', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'Classification', N'CURRENT=Current|DUE_SOON=Due soon|UNSUPPORTED=Unsupported|EXCEPTION=Exception|UNKNOWN=Unknown', NULL, NULL, 630, N'13.4 Technology'),
    (N'TECH_OS', N'TECHNOLOGY', N'Technology', N'OS Compliance', N'Operating system of every asset in use whose form records one: current release, status, support end, recommended target and classification.', N'INTERNAL', N'asset-register', N'sp_asset_report_technology', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'Classification', N'CURRENT=Current|DUE_SOON=Due soon|UNSUPPORTED=Unsupported|EXCEPTION=Exception|UNKNOWN=Unknown', NULL, NULL, 640, N'13.4 Technology'),
    (N'TECH_UNKNOWN', N'TECHNOLOGY', N'Technology', N'Unknown Versions', N'Assets in use whose form has a firmware or operating-system field but no version recorded.', N'INTERNAL', N'asset-register', N'sp_asset_report_technology', 1, NULL, N'SEARCH,ASSET_TYPE', NULL, NULL, NULL, NULL, 650, N'13.4 Technology'),
    (N'TECH_REFRESH', N'TECHNOLOGY', N'Technology', N'Refresh Campaign Progress', N'Progress of a technology refresh campaign.', N'INTERNAL', N'asset-register', N'sp_asset_report_technology', 0, N'The module has no technology refresh campaign; unsupported and ending-soon assets are listed by the reports above.', N'SEARCH', NULL, NULL, NULL, NULL, 660, N'13.4 Technology'),
    (N'RISK_CIA', N'RISK', N'Risk and CIA', N'CIA Classification', N'Confidentiality, integrity and availability of each asset with the valuation method, Asset Value score and category and the validation status (no result = Not rated).', N'INTERNAL', N'asset-register', N'sp_asset_report_risk', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'Validation', N'VALID=Valid|INCOMPLETE=Incomplete|INVALID=Invalid|NOT_RATED=Not rated', NULL, NULL, 710, N'13.4 Risk and CIA'),
    (N'RISK_VALUE_DIST', N'RISK', N'Risk and CIA', N'Asset Value Distribution', N'Assets per Asset Value category (valid results; the rest as Not rated / Incomplete / Invalid) with share, lowest and highest score.', N'INTERNAL', N'asset-register', N'sp_asset_report_risk', 1, NULL, N'ASSET_TYPE', NULL, NULL, NULL, NULL, 720, N'13.4 Risk and CIA'),
    (N'RISK_INHERENT_RESIDUAL', N'RISK', N'Risk and CIA', N'Inherent/Residual Risk', N'Registered risks linked to assets: risk number, title, status, inherent and residual rating, the linked asset and its Asset Value, and whether a review is suggested because an Asset Value changed after the last assessment.', N'CONFIDENTIAL', N'risk-centre-register', N'sp_asset_report_risk', 1, NULL, N'SEARCH,ASSET_TYPE', NULL, NULL, NULL, NULL, 730, N'13.4 Risk and CIA'),
    (N'RISK_TREATMENT', N'RISK', N'Risk and CIA', N'Risk Treatment', N'Treatment plans of asset risks.', N'CONFIDENTIAL', N'risk-centre-register', N'sp_asset_report_risk', 0, N'Risk treatment integration is out of scope for this module; treatments are reported in the Risk Centre.', N'SEARCH', NULL, NULL, NULL, NULL, 740, N'13.4 Risk and CIA'),
    (N'RISK_ACCEPTED', N'RISK', N'Risk and CIA', N'Accepted Risk and Expiry', N'Accepted asset risks and their acceptance expiry.', N'CONFIDENTIAL', N'risk-centre-register', N'sp_asset_report_risk', 0, N'Risk acceptance is reported in the Risk Centre (Accept Risk, Review Risk).', N'SEARCH', NULL, NULL, NULL, NULL, 750, N'13.4 Risk and CIA'),
    (N'GOV_SCORE', N'GOVERNANCE', N'Governance', N'Governance Score', N'Governance snapshots: as-of date, version, overall score, rating, target and warning thresholds, source and who took it. Dates filter the as-of date.', N'INTERNAL', N'asset-governance', N'sp_asset_report_governance', 1, NULL, N'STATUS,DATE_RANGE', N'Rating', N'GREEN=On target|AMBER=Warning|RED=Below threshold|NA=Not applicable', N'As of', NULL, 810, N'13.4 Governance'),
    (N'GOV_COMPONENTS', N'GOVERNANCE', N'Governance', N'Metric Components', N'The KPIs of the latest governance snapshot: numerator, denominator, excluded, failing, score, rating, thresholds, weight and direction.', N'INTERNAL', N'asset-governance', N'sp_asset_report_governance', 1, NULL, N'STATUS', N'Rating', N'GREEN=On target|AMBER=Warning|RED=Below threshold|NA=Not applicable', NULL, NULL, 820, N'13.4 Governance'),
    (N'GOV_METADATA', N'GOVERNANCE', N'Governance', N'Metadata Completeness', N'Record-level detail of the Metadata Completeness KPI in the latest snapshot: outcome, numerator, denominator and reason.', N'INTERNAL', N'asset-governance', N'sp_asset_report_governance', 1, NULL, N'SEARCH,STATUS', N'Outcome', N'PASS=Pass|FAIL=Fail|EXCLUDED=Excluded', NULL, NULL, 830, N'13.4 Governance'),
    (N'GOV_OWNERSHIP', N'GOVERNANCE', N'Governance', N'Ownership Completeness', N'Record-level detail of the Ownership Completeness KPI in the latest snapshot.', N'INTERNAL', N'asset-governance', N'sp_asset_report_governance', 1, NULL, N'SEARCH,STATUS', N'Outcome', N'PASS=Pass|FAIL=Fail|EXCLUDED=Excluded', NULL, NULL, 840, N'13.4 Governance'),
    (N'GOV_COVERAGE', N'GOVERNANCE', N'Governance', N'Coverage Compliance', N'Record-level detail of the Coverage Compliance KPI in the latest snapshot.', N'INTERNAL', N'asset-governance', N'sp_asset_report_governance', 1, NULL, N'SEARCH,STATUS', N'Outcome', N'PASS=Pass|FAIL=Fail|EXCLUDED=Excluded', NULL, NULL, 850, N'13.4 Governance'),
    (N'GOV_EXCEPTION', N'GOVERNANCE', N'Governance', N'Exception Health', N'Record-level detail of the Exception Health KPI in the latest snapshot.', N'INTERNAL', N'asset-governance', N'sp_asset_report_governance', 1, NULL, N'SEARCH,STATUS', N'Outcome', N'PASS=Pass|FAIL=Fail|EXCLUDED=Excluded', NULL, NULL, 860, N'13.4 Governance'),
    (N'PRV_PERSONAL_DATA', N'PRIVACY', N'Privacy and Compliance', N'Personal-Data Assets', N'Assets that process personal data (Yes or Unknown): privacy owner, assessment status, review date, retention end, legal hold, privacy status and the failed / missing / partial / excepted requirement counts.', N'CONFIDENTIAL', N'asset-privacy', N'sp_asset_report_privacy', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'Privacy status', N'COMPLIANT=Compliant|CONDITIONAL=Conditional|INCOMPLETE=Incomplete|NON_COMPLIANT=Non-compliant', NULL, NULL, 910, N'13.4 Privacy and Compliance'),
    (N'PRV_DPIA', N'PRIVACY', N'Privacy and Compliance', N'DPIA/PIA', N'Personal-data assets with high-risk processing, special-category / health and children data, DPIA / PIA required and status, the privacy assessment and the DPIA gaps.', N'CONFIDENTIAL', N'asset-privacy', N'sp_asset_report_privacy', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'DPIA gap', N'GAP=Has a DPIA gap|NO_GAP=No DPIA gap', NULL, NULL, 920, N'13.4 Privacy and Compliance'),
    (N'PRV_MASK_ENC', N'PRIVACY', N'Privacy and Compliance', N'Masking/Encryption Gaps', N'Masking and encryption gaps of personal-data assets: requirement, gap kind, message, enforcement and the approved exception covering it.', N'CONFIDENTIAL', N'asset-privacy', N'sp_asset_report_privacy', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE', N'Requirement', N'MASKING=Masking|ENCRYPTION=Encryption', NULL, NULL, 930, N'13.4 Privacy and Compliance'),
    (N'PRV_RETENTION', N'PRIVACY', N'Privacy and Compliance', N'Retention/Deletion', N'Personal-data assets with a retention end: policy, period, trigger, legal hold, retention end, days left, the open retention review and the last completed decision.', N'CONFIDENTIAL', N'asset-privacy', N'sp_asset_report_privacy', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE,DAYS', N'Retention', N'ENDED=Retention ended|ENDING=Ends within N days', NULL, 90, 940, N'13.4 Privacy and Compliance'),
    (N'PRV_EVIDENCE', N'PRIVACY', N'Privacy and Compliance', N'Evidence Expiry', N'Evidence and certificate dates (calibration, insurance, fitness, pollution, permit, registration, road tax) of assets in use that have expired or expire within the next N days.', N'INTERNAL', N'asset-activities', N'sp_asset_report_privacy', 1, NULL, N'SEARCH,STATUS,ASSET_TYPE,DAYS', N'Expiry', N'EXPIRED=Expired|EXPIRING=Expires within N days', NULL, 60, 950, N'13.4 Privacy and Compliance'),
    (N'PRV_FRAMEWORK', N'PRIVACY', N'Privacy and Compliance', N'Framework/Practice Status', N'Compliance framework and practice status of the assets.', N'INTERNAL', N'asset-privacy', N'sp_asset_report_privacy', 0, N'Framework and practice status is reported by the Governance and practice dashboards, outside the asset module.', N'SEARCH', NULL, NULL, NULL, NULL, 960, N'13.4 Privacy and Compliance')
) AS s(report_code, family_code, family_name, report_name, description, default_classification, view_area, proc_name, is_available, unavailable_reason, filter_keys, status_label, status_options, date_label, default_days, display_order, brd_reference)
ON t.report_code = s.report_code
WHEN MATCHED AND (t.is_active = 0 OR EXISTS (SELECT s.family_code, s.family_name, s.report_name, s.description, s.default_classification, s.view_area, s.proc_name, s.is_available, s.unavailable_reason, s.filter_keys, s.status_label, s.status_options, s.date_label, s.default_days, s.display_order, s.brd_reference
                                         EXCEPT SELECT t.family_code, t.family_name, t.report_name, t.description, t.default_classification, t.view_area, t.proc_name, t.is_available, t.unavailable_reason, t.filter_keys, t.status_label, t.status_options, t.date_label, t.default_days, t.display_order, t.brd_reference)) THEN UPDATE SET
    family_code = s.family_code, family_name = s.family_name, report_name = s.report_name, description = s.description, default_classification = s.default_classification, view_area = s.view_area, proc_name = s.proc_name, is_available = s.is_available, unavailable_reason = s.unavailable_reason, filter_keys = s.filter_keys, status_label = s.status_label, status_options = s.status_options, date_label = s.date_label, default_days = s.default_days, display_order = s.display_order, brd_reference = s.brd_reference,
    version_no = t.version_no + CASE WHEN EXISTS (SELECT s.family_code, s.family_name, s.report_name, s.description, s.default_classification, s.view_area, s.proc_name, s.is_available, s.unavailable_reason, s.filter_keys, s.status_label, s.status_options, s.date_label, s.default_days, s.display_order, s.brd_reference
                                                  EXCEPT SELECT t.family_code, t.family_name, t.report_name, t.description, t.default_classification, t.view_area, t.proc_name, t.is_available, t.unavailable_reason, t.filter_keys, t.status_label, t.status_options, t.date_label, t.default_days, t.display_order, t.brd_reference) THEN 1 ELSE 0 END,
    is_active = 1, updated_by = N'seed-452', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (report_code, family_code, family_name, report_name, description, default_classification, view_area, proc_name, is_available, unavailable_reason, filter_keys, status_label, status_options, date_label, default_days, display_order, brd_reference, entered_by)
    VALUES (s.report_code, s.family_code, s.family_name, s.report_name, s.description, s.default_classification, s.view_area, s.proc_name, s.is_available, s.unavailable_reason, s.filter_keys, s.status_label, s.status_options, s.date_label, s.default_days, s.display_order, s.brd_reference, N'seed-452');
PRINT CONCAT('452: report definitions upserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 3. Shared report sources (one rule per thing, reused by every report)
-- =====================================================================
-- Register rows: the status rule of sp_asset_register_list (current
-- status, else the legacy map), its search (name, ID, active alias -- 444)
-- and asset type filter, and "in use" from fn_asset_governance_assets
-- (450: active record, not Draft / Disposed / Archived).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_report_assets (@organization_id BIGINT, @search NVARCHAR(200), @asset_type_id INT)
RETURNS TABLE
AS
RETURN
    SELECT a.asset_id AS AssetId, a.asset_name AS AssetName, a.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName,
           c.asset_category_name AS CategoryName, sc.subcategory_name AS SubcategoryName,
           st.status_code AS StatusCode, sm.status_name AS StatusName, ph.phase_name AS PhaseName,
           a.owner_id AS OwnerId, e.employee_name AS OwnerName, l.location_name AS LocationName, cr.criticality_name AS CriticalityName,
           CAST(CASE WHEN g.ExclusionReason IS NULL THEN 1 ELSE 0 END AS BIT) AS InUse,
           a.entered_dt AS EnteredDt, ISNULL(a.updated_dt, a.entered_dt) AS LastChanged
      FROM grac_practice.organization_dependency_asset a
      JOIN grac_practice.fn_asset_governance_assets(@organization_id) g ON g.AssetId = a.asset_id
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
     CROSS APPLY (SELECT COALESCE(cs.status_code, ls.status_code) AS status_code) st
      LEFT JOIN grac_practice.dependency_asset_category_master c ON c.asset_category_id = a.asset_category_id
      LEFT JOIN grac_practice.dependency_asset_subcategory_master sc ON sc.subcategory_id = a.asset_subcategory_id
      LEFT JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = a.asset_type_id
      LEFT JOIN grac_practice.entity_status_master sm ON sm.entity_type = N'Asset' AND sm.status_code = st.status_code
      LEFT JOIN grac_practice.asset_lifecycle_status_phase ph ON ph.status_code = st.status_code
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = a.owner_id
      LEFT JOIN grac_practice.organization_location l ON l.location_id = a.location_id
      LEFT JOIN grac_practice.criticality_master cr ON cr.criticality_id = a.criticality_id
     WHERE a.organization_id = @organization_id
       AND (@asset_type_id IS NULL OR a.asset_type_id = @asset_type_id)
       AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR CAST(a.asset_id AS NVARCHAR(30)) = @search
            OR EXISTS (SELECT 1 FROM grac_practice.asset_alias al
                        WHERE al.asset_id = a.asset_id AND al.is_active = 1 AND al.alias_value LIKE N'%' + @search + N'%'));
GO

-- Contracts with the version in force: the columns and search (number,
-- name, vendor) of sp_asset_contract_list; the owner of the version in
-- force, else of the latest version (same rule as the list).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_report_contracts (@organization_id BIGINT, @search NVARCHAR(200))
RETURNS TABLE
AS
RETURN
    SELECT c.contract_id AS ContractId, c.contract_number AS ContractNumber, c.contract_name AS ContractName,
           vd.vendor_name AS VendorName, ISNULL(opt.OptionLabel, c.contract_type) AS ContractType, c.contract_status AS ContractStatus,
           c.current_version_id AS CurrentVersionId, cv.version_no AS VersionInForce,
           cv.effective_start AS EffectiveStart, cv.effective_end AS EffectiveEnd, cv.notice_date AS NoticeDate, cv.decision_date AS DecisionDate,
           cv.contract_value AS ContractValue, cv.currency_code AS CurrencyCode, ow.employee_name AS ContractOwner
      FROM grac_practice.asset_contract c
      JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = c.vendor_id
      LEFT JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
     OUTER APPLY (SELECT TOP 1 v.contract_owner_id FROM grac_practice.asset_contract_version v
                   WHERE v.contract_id = c.contract_id ORDER BY v.version_no DESC) lv
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = COALESCE(cv.contract_owner_id, lv.contract_owner_id)
     OUTER APPLY (SELECT TOP 1 o.OptionLabel FROM grac_practice.fn_asset_field_options(@organization_id) o
                   WHERE o.OptionGroup = N'asset_field.coverage_type' AND o.OptionValue = c.contract_type) opt
     WHERE c.organization_id = @organization_id
       AND (@search IS NULL OR c.contract_number LIKE N'%' + @search + N'%' OR c.contract_name LIKE N'%' + @search + N'%'
            OR vd.vendor_name LIKE N'%' + @search + N'%');
GO

-- CMDB relationships with both ends resolved through the CI catalogue
-- (440 / 441 rule: an endpoint is usable until disposed / archived /
-- retired / terminated or inactive).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_report_relationships (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT r.relationship_id AS RelationshipId, r.relationship_type_code AS TypeCode, rt.type_name AS RelationshipName,
           r.source_kind AS SourceKind, r.source_id AS SourceId, sc.CiName AS SourceName, ISNULL(sc.IsUsable, 0) AS SourceUsable,
           r.target_kind AS TargetKind, r.target_id AS TargetId, tc.CiName AS TargetName, ISNULL(tc.IsUsable, 0) AS TargetUsable,
           r.is_critical AS IsCritical, r.dependency_criticality AS DependencyCriticality, r.status AS Status,
           r.effective_from AS EffectiveFrom, r.effective_to AS EffectiveTo, r.source_code AS RecordSource,
           r.confidence_pct AS ConfidencePct, r.verification_status AS Verification, r.pending_action AS PendingAction,
           ow.employee_name AS OwnerName
      FROM grac_practice.asset_relationship r
      JOIN grac_practice.asset_relationship_type rt ON rt.type_code = r.relationship_type_code
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) sc ON sc.CiKind = r.source_kind AND sc.CiId = r.source_id
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) tc ON tc.CiKind = r.target_kind AND tc.CiId = r.target_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.owner_employee_id
     WHERE r.organization_id = @organization_id;
GO
PRINT '452: shared report sources created.';
GO

-- =====================================================================
-- 4. Family procedures. Called by sp_asset_report_run only, which has
--    checked the report, the permission and the filters, cleared the
--    filters the report does not take and set the paging. One result set
--    per report; TotalRows on every row (the paging contract of the list
--    procedures).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_asset
    @report_code     NVARCHAR(40),
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @status          NVARCHAR(60)  = NULL,
    @asset_type_id   INT           = NULL,
    @date_from       DATE          = NULL,
    @date_to         DATE          = NULL,
    @days            INT           = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF @report_code = N'ASSET_REGISTER'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.CategoryName AS Category, x.SubcategoryName AS Subcategory, x.AssetTypeName AS AssetType,
               x.StatusName AS LifecycleStatus, x.PhaseName AS Phase, x.OwnerName AS Owner, x.LocationName AS Location,
               x.CriticalityName AS Criticality, vr.asset_value_category AS AssetValue, cv.CoverageStatusLabel AS Coverage,
               CASE WHEN x.InUse = 1 THEN N'Yes' ELSE N'No' END AS InUse, x.LastChanged,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x
          LEFT JOIN grac_practice.asset_valuation_result vr ON vr.asset_id = x.AssetId AND vr.validation_status = N'VALID'
         OUTER APPLY grac_practice.fn_asset_coverage_summary(@organization_id, x.AssetId) cv
         WHERE (@status IS NULL OR x.StatusCode = @status)
         ORDER BY x.AssetName, x.AssetId
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'ASSET_OWNERSHIP'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, x.StatusName AS LifecycleStatus,
               ow.employee_name AS Owner, COALESCE(ce.employee_name, ct.team_name + N' (team)') AS Custodian,
               d.department_name AS Department, l.location_name AS Site, h.building AS Building, h.floor AS Floor, h.room AS Room,
               h.effective_from AS AssignedSince, h.change_source AS ChangeSource,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x
          LEFT JOIN grac_practice.asset_assignment_history h ON h.asset_id = x.AssetId AND h.is_current = 1
         CROSS APPLY (SELECT ISNULL(h.asset_owner_id, x.OwnerId) AS owner_id) o
          LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = o.owner_id
          LEFT JOIN grac_practice.organization_employee ce ON h.custodian LIKE N'E:%' AND ce.employee_id = TRY_CONVERT(BIGINT, SUBSTRING(h.custodian, 3, 38))
          LEFT JOIN grac_practice.organization_team ct ON h.custodian LIKE N'T:%' AND ct.team_id = TRY_CONVERT(BIGINT, SUBSTRING(h.custodian, 3, 38))
          LEFT JOIN grac_practice.organization_department d ON d.department_id = h.department_id
          LEFT JOIN grac_practice.organization_location l ON l.location_id = h.location_id
         WHERE @status IS NULL
            OR (@status = N'NO_OWNER' AND o.owner_id IS NULL)
            OR (@status = N'NO_CUSTODIAN' AND h.custodian IS NULL)
            OR (@status = N'ASSIGNED' AND o.owner_id IS NOT NULL AND h.custodian IS NOT NULL)
         ORDER BY x.AssetName, x.AssetId
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'ASSET_LIFECYCLE'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, x.StatusName AS LifecycleStatus, x.PhaseName AS Phase,
               COALESCE(sc.since_dt, x.EnteredDt) AS InStatusSince,
               DATEDIFF(DAY, COALESCE(sc.since_dt, x.EnteredDt), SYSUTCDATETIME()) AS DaysInStatus,
               ps.status_name AS PendingChangeTo, pc.requested_by AS PendingRequestedBy, pc.requested_dt AS PendingRequestedDt,
               x.OwnerName AS Owner, CASE WHEN x.InUse = 1 THEN N'Yes' ELSE N'No' END AS InUse,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x
         OUTER APPLY (SELECT MAX(COALESCE(c.decided_dt, c.requested_dt)) AS since_dt
                        FROM grac_practice.asset_lifecycle_change c
                       WHERE c.asset_id = x.AssetId AND c.to_status_code = x.StatusCode
                         AND c.change_status IN (N'COMPLETED', N'APPROVED')) sc
          LEFT JOIN grac_practice.asset_lifecycle_change pc ON pc.asset_id = x.AssetId AND pc.change_status = N'PENDING_APPROVAL'
          LEFT JOIN grac_practice.entity_status_master ps ON ps.entity_type = N'Asset' AND ps.status_code = pc.to_status_code
         WHERE (@status IS NULL OR x.StatusCode = @status)
         ORDER BY x.AssetName, x.AssetId
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'ASSET_MISSING_DATA'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, x.StatusName AS LifecycleStatus, x.OwnerName AS Owner,
               gi.Denominator AS MandatoryFields, gi.Denominator - gi.Numerator AS EmptyFields, gi.Reason AS Detail,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x
          JOIN grac_practice.fn_asset_governance_items(@organization_id, N'METADATA_COMPLETENESS') gi
            ON gi.RecordKind = N'ASSET' AND gi.RecordId = x.AssetId AND gi.Outcome = N'FAIL'
         ORDER BY gi.Denominator - gi.Numerator DESC, x.AssetName, x.AssetId
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'ASSET_MOVEMENT'
    BEGIN
        ;WITH mv AS (
            SELECT hh.assignment_id, hh.asset_id, hh.asset_owner_id, hh.custodian, hh.department_id, hh.location_id,
                   hh.building, hh.floor, hh.room, hh.effective_from, hh.effective_to, hh.is_current, hh.change_source,
                   hh.entered_by, hh.entered_dt,
                   LAG(hh.location_id) OVER (PARTITION BY hh.asset_id ORDER BY hh.effective_from, hh.assignment_id) AS prev_location_id,
                   LAG(hh.asset_owner_id) OVER (PARTITION BY hh.asset_id ORDER BY hh.effective_from, hh.assignment_id) AS prev_owner_id,
                   LAG(hh.custodian) OVER (PARTITION BY hh.asset_id ORDER BY hh.effective_from, hh.assignment_id) AS prev_custodian
              FROM grac_practice.asset_assignment_history hh
             WHERE hh.organization_id = @organization_id
        )
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, mv.effective_from AS EffectiveFrom, mv.effective_to AS EffectiveTo,
               pl.location_name AS PreviousSite, l.location_name AS Site, mv.building AS Building, mv.floor AS Floor, mv.room AS Room,
               po.employee_name AS PreviousOwner, ow.employee_name AS Owner,
               COALESCE(pce.employee_name, pct.team_name + N' (team)') AS PreviousCustodian,
               COALESCE(ce.employee_name, ct.team_name + N' (team)') AS Custodian,
               d.department_name AS Department, mv.change_source AS ChangeSource, mv.entered_by AS RecordedBy, mv.entered_dt AS RecordedDt,
               CASE WHEN mv.is_current = 1 THEN N'Yes' ELSE N'No' END AS IsCurrent,
               COUNT(*) OVER () AS TotalRows
          FROM mv
          JOIN grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x ON x.AssetId = mv.asset_id
          LEFT JOIN grac_practice.organization_location pl ON pl.location_id = mv.prev_location_id
          LEFT JOIN grac_practice.organization_location l ON l.location_id = mv.location_id
          LEFT JOIN grac_practice.organization_employee po ON po.employee_id = mv.prev_owner_id
          LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = mv.asset_owner_id
          LEFT JOIN grac_practice.organization_employee pce ON mv.prev_custodian LIKE N'E:%' AND pce.employee_id = TRY_CONVERT(BIGINT, SUBSTRING(mv.prev_custodian, 3, 38))
          LEFT JOIN grac_practice.organization_team pct ON mv.prev_custodian LIKE N'T:%' AND pct.team_id = TRY_CONVERT(BIGINT, SUBSTRING(mv.prev_custodian, 3, 38))
          LEFT JOIN grac_practice.organization_employee ce ON mv.custodian LIKE N'E:%' AND ce.employee_id = TRY_CONVERT(BIGINT, SUBSTRING(mv.custodian, 3, 38))
          LEFT JOIN grac_practice.organization_team ct ON mv.custodian LIKE N'T:%' AND ct.team_id = TRY_CONVERT(BIGINT, SUBSTRING(mv.custodian, 3, 38))
          LEFT JOIN grac_practice.organization_department d ON d.department_id = mv.department_id
         WHERE (@date_from IS NULL OR mv.effective_from >= @date_from)
           AND (@date_to IS NULL OR mv.effective_from <= @date_to)
         ORDER BY mv.effective_from DESC, mv.assignment_id DESC
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'ASSET_DISPOSAL'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, x.StatusName AS LifecycleStatus, x.OwnerName AS Owner,
               pv.dsreq AS DeletionSanitizationRequired, pv.sreq AS SanitizationRequired, pv.smeth AS SanitizationMethod,
               pv.sdate AS SanitizationDate, CASE WHEN pv.sev IS NULL THEN N'No' ELSE N'Yes' END AS EvidenceRecorded,
               CAST(NULLIF(CONCAT_WS(N', ',
                    CASE WHEN pv.dsreq IS NULL THEN N'deletion / sanitization required' END,
                    CASE WHEN (pv.sreq = N'YES' OR pv.dsreq = N'YES') AND pv.smeth IS NULL THEN N'method' END,
                    CASE WHEN (pv.sreq = N'YES' OR pv.dsreq = N'YES') AND pv.sdate IS NULL THEN N'date' END,
                    CASE WHEN (pv.sreq = N'YES' OR pv.dsreq = N'YES') AND pv.sev IS NULL THEN N'evidence' END), N'') AS NVARCHAR(200)) AS NotRecorded,
               ps.status_name AS PendingChangeTo,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x
         OUTER APPLY grac_practice.fn_asset_privacy_values(@organization_id, x.AssetId) pv
          LEFT JOIN grac_practice.asset_lifecycle_change pc ON pc.asset_id = x.AssetId AND pc.change_status = N'PENDING_APPROVAL'
          LEFT JOIN grac_practice.entity_status_master ps ON ps.entity_type = N'Asset' AND ps.status_code = pc.to_status_code
         WHERE x.StatusCode IN (N'PENDING_DECOMMISSION', N'SANITIZATION_PENDING', N'DISPOSAL_APPROVAL', N'DISPOSED', N'ARCHIVED')
           AND (@status IS NULL OR x.StatusCode = @status)
         ORDER BY x.AssetName, x.AssetId
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE
        THROW 53101, 'Unknown report for the Asset family.', 1;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_attestation
    @report_code     NVARCHAR(40),
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @status          NVARCHAR(60)  = NULL,
    @asset_type_id   INT           = NULL,
    @date_from       DATE          = NULL,
    @date_to         DATE          = NULL,
    @days            INT           = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF @report_code IN (N'ATT_COMPLIANCE', N'ATT_OVERDUE')
    BEGIN
        -- Display status of the attestation list (431): open and past due = Overdue.
        SELECT t.attestation_id AS AttestationId, x.AssetId, x.AssetName, x.AssetTypeName AS AssetType,
               t.attestation_type AS AttestationType, t.assignee_role AS AssigneeRole,
               COALESCE(e.employee_name, tm.team_name + N' (team)') AS Assignee, t.due_date AS DueDate, ds.display_status AS DisplayStatus,
               CASE WHEN t.due_date < @today AND ds.display_status IN (N'OVERDUE', N'ESCALATED')
                    THEN DATEDIFF(DAY, t.due_date, @today) ELSE 0 END AS DaysOverdue,
               t.response AS Response, t.response_dt AS RespondedDt, t.closed_dt AS ClosedDt,
               CASE WHEN t.status = N'CANCELLED' THEN N'Excluded'
                    WHEN t.status IN (N'CONFIRMED', N'CLOSED', N'RESOLVED') THEN N'Yes' ELSE N'No' END AS Compliant,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.asset_attestation t
          JOIN grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x ON x.AssetId = t.asset_id
         CROSS APPLY (SELECT CASE WHEN t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS') AND t.due_date < @today
                                  THEN N'OVERDUE' ELSE t.status END AS display_status) ds
          LEFT JOIN grac_practice.organization_employee e ON e.employee_id = t.assignee_employee_id
          LEFT JOIN grac_practice.organization_team tm ON tm.team_id = t.assignee_team_id
         WHERE t.organization_id = @organization_id
           AND (@report_code = N'ATT_COMPLIANCE' OR ds.display_status IN (N'OVERDUE', N'ESCALATED'))
           AND (@status IS NULL OR ds.display_status = @status)
           AND (@date_from IS NULL OR t.due_date >= @date_from)
           AND (@date_to IS NULL OR t.due_date <= @date_to)
         ORDER BY t.due_date DESC, t.attestation_id DESC
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code IN (N'ATT_EXCEPTIONS', N'ATT_LOST_DAMAGED', N'ATT_SLA')
    BEGIN
        -- One display shape of the exception list (432): SLA state and escalation level.
        SELECT v.ExceptionId, v.AssetId, v.AssetName, v.AssetTypeName AS AssetType, x.StatusName AS AssetLifecycleStatus,
               v.AttestationId, v.Category, v.Severity, v.CriticalityName AS Criticality, v.Description,
               v.ReportedByName AS ReportedBy, v.ReportedDt, DATEDIFF(DAY, v.ReportedDt, SYSUTCDATETIME()) AS AgeDays,
               v.InvestigatorName AS Investigator, v.StatusName AS Status,
               v.StartDueDate, v.StartedDt, CASE WHEN v.StartOverdue = 1 THEN N'Yes' ELSE N'No' END AS StartOverdue,
               v.ResolutionDue, v.PausedDays, v.OverdueDays, v.EscalationLevel,
               v.Outcome, v.ResolutionNarrative, v.ResolvedByName AS ResolvedBy, v.ResolvedDt, v.ApprovedByName AS ApprovedBy, v.ClosedDt,
               v.SecRemoteLockWipe AS RemoteLockWipe, v.SecCredentialReview AS CredentialReview,
               v.SecPrivacyAssessment AS PrivacyAssessment, v.SecAccessRevocation AS AccessRevocation, v.SecMonitoring AS Monitoring,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_verification_exception_view(@organization_id, NULL) v
          JOIN grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x ON x.AssetId = v.AssetId
         WHERE (@report_code <> N'ATT_EXCEPTIONS'
                OR ((@status IS NULL OR v.StatusCode = @status)
                    AND (@date_from IS NULL OR CAST(v.ReportedDt AS DATE) >= @date_from)
                    AND (@date_to IS NULL OR CAST(v.ReportedDt AS DATE) <= @date_to)))
           AND (@report_code <> N'ATT_LOST_DAMAGED'
                OR ((v.Category IN (N'ASSET_LOST', N'ASSET_DAMAGED', N'ASSET_NOT_FOUND') OR v.Outcome IN (N'LOST_CONFIRMED', N'DAMAGE_CONFIRMED'))
                    AND (@status IS NULL
                         OR (@status = N'OPEN' AND v.StatusCode NOT IN (N'CLOSED', N'CANCELLED'))
                         OR (@status = N'CONFIRMED' AND v.Outcome IN (N'LOST_CONFIRMED', N'DAMAGE_CONFIRMED')))))
           AND (@report_code <> N'ATT_SLA'
                OR (v.StatusCode NOT IN (N'CLOSED', N'CANCELLED')
                    AND (@status IS NULL
                         OR (@status = N'BREACHED' AND (v.StartOverdue = 1 OR v.OverdueDays > 0))
                         OR (@status = N'ON_TRACK' AND v.StartOverdue = 0 AND v.OverdueDays = 0))))
         ORDER BY v.OverdueDays DESC, v.ReportedDt DESC, v.ExceptionId DESC
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE
        THROW 53101, 'Unknown report for the Attestation family.', 1;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_cmdb
    @report_code     NVARCHAR(40),
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @status          NVARCHAR(60)  = NULL,
    @asset_type_id   INT           = NULL,
    @date_from       DATE          = NULL,
    @date_to         DATE          = NULL,
    @days            INT           = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF @report_code IN (N'CMDB_RELATIONSHIPS', N'CMDB_CRITICAL')
    BEGIN
        SELECT r.RelationshipId, r.SourceKind, r.SourceName, r.RelationshipName AS Relationship, r.TargetKind, r.TargetName,
               CASE WHEN r.IsCritical = 1 THEN N'Yes' ELSE N'No' END AS Critical, r.DependencyCriticality, r.Status,
               r.EffectiveFrom, r.EffectiveTo, r.RecordSource, r.ConfidencePct, r.Verification, r.OwnerName AS Owner,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_report_relationships(@organization_id) r
         WHERE (@search IS NULL OR r.SourceName LIKE N'%' + @search + N'%' OR r.TargetName LIKE N'%' + @search + N'%'
                OR r.RelationshipName LIKE N'%' + @search + N'%')
           AND (@report_code <> N'CMDB_RELATIONSHIPS' OR @status IS NULL OR r.Status = @status)
           AND (@report_code <> N'CMDB_CRITICAL'
                OR (r.Status = N'ACTIVE' AND (r.IsCritical = 1 OR r.DependencyCriticality IN (N'CRITICAL', N'HIGH'))
                    AND (@status IS NULL OR r.DependencyCriticality = @status)))
         ORDER BY r.SourceName, r.RelationshipName, r.TargetName, r.RelationshipId
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'CMDB_QUALITY'
    BEGIN
        SELECT r.RelationshipId, q.issue_label AS Issue, r.SourceKind, r.SourceName, r.RelationshipName AS Relationship,
               r.TargetKind, r.TargetName, r.Status, r.Verification, r.EffectiveTo, r.ConfidencePct, r.PendingAction, r.OwnerName AS Owner,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_report_relationships(@organization_id) r
         CROSS APPLY (VALUES
                (N'DISPUTED', N'Disputed', CASE WHEN r.Status = N'DISPUTED' THEN 1 ELSE 0 END),
                (N'PROPOSED', N'Awaiting approval', CASE WHEN r.Status = N'PROPOSED' THEN 1 ELSE 0 END),
                (N'UNVERIFIED', N'Active, unverified', CASE WHEN r.Status = N'ACTIVE' AND r.Verification = N'UNVERIFIED' THEN 1 ELSE 0 END),
                (N'EXPIRED', N'Active past end date', CASE WHEN r.Status = N'ACTIVE' AND r.EffectiveTo < @today THEN 1 ELSE 0 END),
                (N'UNUSABLE', N'Endpoint not usable', CASE WHEN r.Status = N'ACTIVE' AND (r.SourceUsable = 0 OR r.TargetUsable = 0) THEN 1 ELSE 0 END),
                (N'PENDING_CHANGE', N'Change awaiting approval', CASE WHEN r.PendingAction IS NOT NULL THEN 1 ELSE 0 END),
                (N'LOW_CONFIDENCE', N'Confidence below 50',
                    CASE WHEN r.ConfidencePct < 50 AND r.Status NOT IN (N'INACTIVE', N'RETIRED') THEN 1 ELSE 0 END)
             ) q(issue_code, issue_label, hit)
         WHERE q.hit = 1 AND (@status IS NULL OR q.issue_code = @status)
           AND (@search IS NULL OR r.SourceName LIKE N'%' + @search + N'%' OR r.TargetName LIKE N'%' + @search + N'%'
                OR r.RelationshipName LIKE N'%' + @search + N'%')
         ORDER BY q.issue_code, r.SourceName, r.RelationshipId
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'CMDB_ORPHANS'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, x.StatusName AS LifecycleStatus, x.OwnerName AS Owner,
               x.LocationName AS Location, x.CriticalityName AS Criticality,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x
         WHERE x.InUse = 1
           AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_relationship r
                            WHERE r.organization_id = @organization_id AND r.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
                              AND ((r.source_kind = N'ASSET' AND r.source_id = x.AssetId)
                                   OR (r.target_kind = N'ASSET' AND r.target_id = x.AssetId)))
         ORDER BY x.AssetName, x.AssetId
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'CMDB_TOPOLOGY'
    BEGIN
        SELECT b.service_code AS ServiceCode, b.service_name AS ServiceName, b.service_type AS ServiceType, b.status AS ServiceStatus,
               bo.employee_name AS BusinessOwner, r.SourceKind AS SupportingKind, r.SourceName AS SupportingItem,
               r.Status AS RelationshipStatus, CASE WHEN r.IsCritical = 1 THEN N'Yes' WHEN r.IsCritical = 0 THEN N'No' END AS Critical,
               r.DependencyCriticality,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.business_service b
          LEFT JOIN grac_practice.fn_asset_report_relationships(@organization_id) r
            ON r.TypeCode = N'SUPPORTS_SERVICE' AND r.TargetKind = N'SERVICE' AND r.TargetId = b.service_id
           AND r.Status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
          LEFT JOIN grac_practice.organization_employee bo ON bo.employee_id = b.business_owner_employee_id
         WHERE b.organization_id = @organization_id
           AND (@status IS NULL OR b.status = @status)
           AND (@search IS NULL OR b.service_name LIKE N'%' + @search + N'%' OR b.service_code LIKE N'%' + @search + N'%'
                OR r.SourceName LIKE N'%' + @search + N'%')
         ORDER BY b.service_name, b.service_id, r.SourceKind, r.SourceName
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE
        THROW 53101, 'Unknown report for the CMDB and Service family.', 1;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_discovery
    @report_code     NVARCHAR(40),
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @status          NVARCHAR(60)  = NULL,
    @asset_type_id   INT           = NULL,
    @date_from       DATE          = NULL,
    @date_to         DATE          = NULL,
    @days            INT           = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @kind NVARCHAR(16) = CASE @report_code WHEN N'DSC_CONFLICTS' THEN N'CONFLICT'
                                                   WHEN N'DSC_DUPLICATES' THEN N'DUPLICATE' ELSE @status END;

    IF @report_code = N'DSC_COVERAGE'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, x.StatusName AS LifecycleStatus,
               dc.LinkCount, dc.FreshLinkCount, dc.IdentityScore, dc.LastObservedDt, dc.OpenConflictCount,
               dc.AttributeDisagreementCount, dc.LastVerifiedDate, dc.OverallStatus AS DataConfidence,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_discovery_confidence(@organization_id) dc
          JOIN grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x ON x.AssetId = dc.AssetId
         WHERE (@status IS NULL OR dc.OverallStatus = @status)
         ORDER BY x.AssetName, x.AssetId
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'DSC_STALE'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, ss.StatusName AS LifecycleStatus, ss.LinkCount,
               ss.LastObservedDt, ss.DaysUnseen, ss.RetireAfterDays AS AgingRuleDays,
               CASE WHEN ss.IsStale = 1 THEN N'Yes' ELSE N'No' END AS Stale, ss.OpenReviewId, ss.LastDismissedDt,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_stale_state(@organization_id) ss
          JOIN grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x ON x.AssetId = ss.AssetId
         WHERE ss.IsListed = 1
         ORDER BY ss.DaysUnseen DESC, x.AssetName
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'DSC_SOURCES'
    BEGIN
        -- Health: the source list rule (442).
        SELECT s.source_code AS SourceCode, s.source_name AS SourceName, s.source_type AS SourceType, s.collection_mode AS CollectionMode,
               ow.employee_name AS Owner, CASE WHEN s.is_active = 1 THEN N'Yes' ELSE N'No' END AS Active,
               s.expected_interval_hours AS ExpectedIntervalHours, s.last_run_dt AS LastRunDt, s.last_run_status AS LastRunStatus,
               DATEADD(HOUR, s.expected_interval_hours, s.last_run_dt) AS NextRunDueDt, h.health AS Health,
               b.batches AS Batches, b.failed AS FailedBatches, b.records AS Records, b.updated AS Updated,
               b.exceptions AS Exceptions, b.errors AS Errors,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.asset_discovery_source s
          LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = s.owner_employee_id
         CROSS APPLY (SELECT CASE WHEN s.last_run_dt IS NULL THEN N'NEVER'
                                  WHEN s.last_run_status = N'FAILED' THEN N'FAILED'
                                  WHEN s.last_run_status = N'PARTIAL'
                                       OR DATEADD(HOUR, s.expected_interval_hours, s.last_run_dt) < SYSUTCDATETIME() THEN N'WARNING'
                                  ELSE N'SUCCESS' END AS health) h
         OUTER APPLY (SELECT COUNT(*) AS batches, SUM(CASE WHEN bt.status = N'FAILED' THEN 1 ELSE 0 END) AS failed,
                             ISNULL(SUM(bt.record_count), 0) AS records, ISNULL(SUM(bt.updated_count), 0) AS updated,
                             ISNULL(SUM(bt.exception_count), 0) AS exceptions, ISNULL(SUM(bt.error_count), 0) AS errors
                        FROM grac_practice.asset_discovery_batch bt
                       WHERE bt.source_id = s.source_id AND bt.received_dt >= DATEADD(DAY, -@days, SYSUTCDATETIME())) b
         WHERE s.organization_id = @organization_id
           AND (@status IS NULL OR h.health = @status)
           AND (@search IS NULL OR s.source_name LIKE N'%' + @search + N'%' OR s.source_code LIKE N'%' + @search + N'%')
         ORDER BY s.source_name
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code IN (N'DSC_RECON', N'DSC_CONFLICTS', N'DSC_DUPLICATES')
    BEGIN
        SELECT e.exception_id AS ExceptionId, e.exception_kind AS Kind, src.source_name AS Source, e.external_key AS ExternalKey,
               a.asset_name AS Asset, oa.asset_name AS OtherAsset, e.field_key AS FieldKey,
               e.current_value AS CurrentValue, e.observed_value AS ObservedValue, e.match_score AS MatchScore,
               e.raised_count AS RaisedCount, e.entered_dt AS RaisedDt, DATEDIFF(DAY, e.entered_dt, SYSUTCDATETIME()) AS AgeDays,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.asset_reconciliation_exception e
          JOIN grac_practice.asset_discovery_source src ON src.source_id = e.source_id
          LEFT JOIN grac_practice.organization_dependency_asset a ON a.asset_id = e.asset_id
          LEFT JOIN grac_practice.organization_dependency_asset oa ON oa.asset_id = e.other_asset_id
         WHERE e.organization_id = @organization_id AND e.status = N'OPEN'
           AND (@kind IS NULL OR e.exception_kind = @kind)
           AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR oa.asset_name LIKE N'%' + @search + N'%'
                OR e.external_key LIKE N'%' + @search + N'%' OR e.field_key LIKE N'%' + @search + N'%')
         ORDER BY e.entered_dt, e.exception_id
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'DSC_MERGE_SPLIT'
    BEGIN
        SELECT ev.event_id AS EventId, ev.event_kind AS Kind, sv.asset_name AS SurvivingAsset, m.member_count AS MemberCount,
               m.members AS Members, ev.status AS Status, CASE WHEN ev.is_critical = 1 THEN N'Yes' ELSE N'No' END AS Critical,
               ev.reason AS Reason, ev.requested_by AS RequestedBy, ev.requested_dt AS RequestedDt,
               ev.executed_by AS ExecutedBy, ev.executed_dt AS ExecutedDt, ev.recovered_by AS RecoveredBy, ev.recovered_dt AS RecoveredDt,
               ev.recovery_reason AS RecoveryReason,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.asset_merge_split_event ev
          JOIN grac_practice.organization_dependency_asset sv ON sv.asset_id = ev.survivor_asset_id
         OUTER APPLY (SELECT COUNT(*) AS member_count,
                             STRING_AGG(CAST(ma.asset_name AS NVARCHAR(MAX)), N'; ') WITHIN GROUP (ORDER BY mm.sequence_no) AS members
                        FROM grac_practice.asset_merge_split_member mm
                        JOIN grac_practice.organization_dependency_asset ma ON ma.asset_id = mm.asset_id
                       WHERE mm.event_id = ev.event_id) m
         WHERE ev.organization_id = @organization_id
           AND (@status IS NULL OR ev.status = @status)
           AND (@date_from IS NULL OR CAST(ev.requested_dt AS DATE) >= @date_from)
           AND (@date_to IS NULL OR CAST(ev.requested_dt AS DATE) <= @date_to)
           AND (@search IS NULL OR sv.asset_name LIKE N'%' + @search + N'%' OR m.members LIKE N'%' + @search + N'%')
         ORDER BY ev.requested_dt DESC, ev.event_id DESC
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE
        THROW 53101, 'Unknown report for the Discovery and Data Quality family.', 1;
END
GO
PRINT '452: Asset, Attestation, CMDB and Discovery report procedures created.';
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_contract
    @report_code     NVARCHAR(40),
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @status          NVARCHAR(60)  = NULL,
    @asset_type_id   INT           = NULL,
    @date_from       DATE          = NULL,
    @date_to         DATE          = NULL,
    @days            INT           = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    -- Same date-driven processing as the contract list before reading (434, D35).
    EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id;

    IF @report_code = N'CON_EXPIRY'
    BEGIN
        SELECT k.ContractId, k.ContractNumber, k.ContractName, k.VendorName AS Vendor, k.ContractType, k.ContractStatus,
               k.VersionInForce, k.EffectiveStart, k.EffectiveEnd, k.NoticeDate, k.DecisionDate, nx.next_date AS NextKeyDate,
               DATEDIFF(DAY, @today, k.EffectiveEnd) AS DaysToEnd, k.ContractOwner, k.ContractValue, k.CurrencyCode AS Currency,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_report_contracts(@organization_id, @search) k
         CROSS APPLY (SELECT MIN(d.dt) AS next_date
                        FROM (VALUES (k.EffectiveEnd), (k.NoticeDate), (k.DecisionDate)) d(dt)) nx
         WHERE ((@status IS NULL AND k.ContractStatus IN (N'ACTIVE', N'APPROVED')) OR k.ContractStatus = @status)
           AND (k.EffectiveEnd <= DATEADD(DAY, @days, @today) OR k.NoticeDate <= DATEADD(DAY, @days, @today)
                OR k.DecisionDate <= DATEADD(DAY, @days, @today))
         ORDER BY nx.next_date, k.ContractNumber
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'CON_RENEWALS'
    BEGIN
        SELECT r.renewal_id AS RenewalId, k.ContractNumber, k.ContractName, k.VendorName AS Vendor, r.renewal_type AS RenewalType,
               s.status_name AS Status, r.due_date AS DueDate, r.old_expiry AS CurrentExpiry, r.new_expiry AS ProposedExpiry,
               r.renewal_value AS RenewalValue, r.currency_code AS Currency, r.quotation_reference AS QuotationReference,
               k.ContractOwner,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.asset_contract_renewal r
          JOIN grac_practice.fn_asset_report_contracts(@organization_id, @search) k ON k.ContractId = r.contract_id
          JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
         WHERE r.organization_id = @organization_id AND r.is_open = 1
           AND (@status IS NULL OR r.renewal_type = @status)
           AND (@date_from IS NULL OR r.due_date >= @date_from)
           AND (@date_to IS NULL OR r.due_date <= @date_to)
         ORDER BY r.due_date, k.ContractNumber
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'CON_COVERAGE_GAPS'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, x.StatusName AS LifecycleStatus, x.OwnerName AS Owner,
               g.CoverageTypeLabel AS CoverageType, g.GapKind AS Gap, g.CoverageStatus, g.ContractNumber,
               g.EffectiveStart, g.EffectiveEnd, g.MinimumPeriodMonths, g.MissingAction, g.Message,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_coverage_gaps(@organization_id) g
          JOIN grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x ON x.AssetId = g.AssetId
         WHERE (@status IS NULL OR g.GapKind = @status)
         ORDER BY x.AssetName, x.AssetId, g.CoverageType
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'CON_ENTITLEMENTS'
    BEGIN
        SELECT k.ContractNumber, k.ContractName, k.VendorName AS Vendor, k.ContractStatus, k.VersionInForce,
               en.product_sku AS ProductSku, en.description AS Description, ISNULL(opt.OptionLabel, en.coverage_type) AS CoverageType,
               en.quantity AS Quantity, en.unit AS Unit, en.service_level AS ServiceLevel, en.support_hours AS SupportHours,
               ISNULL(en.start_date, k.EffectiveStart) AS StartDate, ISNULL(en.end_date, k.EffectiveEnd) AS EndDate,
               en.exclusions AS Exclusions,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_report_contracts(@organization_id, @search) k
          JOIN grac_practice.asset_contract_entitlement en ON en.contract_id = k.ContractId AND en.version_id = k.CurrentVersionId
         OUTER APPLY (SELECT TOP 1 o.OptionLabel FROM grac_practice.fn_asset_field_options(@organization_id) o
                       WHERE o.OptionGroup = N'asset_field.coverage_type' AND o.OptionValue = en.coverage_type) opt
         WHERE (@status IS NULL OR k.ContractStatus = @status)
         ORDER BY k.ContractNumber, en.product_sku, en.entitlement_id
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'CON_CONTACTS'
    BEGIN
        SELECT k.ContractNumber, k.ContractName, vd.vendor_name AS Vendor, rl.role_name AS Role, e.employee_name AS Contact,
               e.email AS Email, CASE WHEN m.is_primary = 1 THEN N'Yes' ELSE N'No' END AS IsPrimary,
               m.preferred_channel AS PreferredChannel, CASE WHEN m.notification_participation = 1 THEN N'Yes' ELSE N'No' END AS Notifications,
               CASE WHEN m.version_id IS NULL THEN N'All versions' ELSE CONCAT(N'Version ', v.version_no) END AS AppliesTo,
               m.effective_start AS EffectiveStart, m.effective_end AS EffectiveEnd, m.status AS MappingStatus,
               m.validated_by AS ValidatedBy, m.validated_dt AS ValidatedDt,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.asset_contract_contact m
          JOIN grac_practice.fn_asset_report_contracts(@organization_id, @search) k ON k.ContractId = m.contract_id
          JOIN grac_practice.asset_contract_contact_role rl ON rl.role_code = m.role_code
          JOIN grac_practice.organization_employee e ON e.employee_id = m.employee_id
          JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = m.vendor_id
          LEFT JOIN grac_practice.asset_contract_version v ON v.version_id = m.version_id
         WHERE m.organization_id = @organization_id
           AND (@status IS NULL OR m.status = @status)
         ORDER BY k.ContractNumber, rl.display_order, e.employee_name
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE
        THROW 53101, 'Unknown report for the Contract family.', 1;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_technology
    @report_code     NVARCHAR(40),
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @status          NVARCHAR(60)  = NULL,
    @asset_type_id   INT           = NULL,
    @date_from       DATE          = NULL,
    @date_to         DATE          = NULL,
    @days            INT           = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    IF @report_code NOT IN (N'TECH_UNSUPPORTED', N'TECH_DUE_SOON', N'TECH_FIRMWARE', N'TECH_OS', N'TECH_UNKNOWN')
        THROW 53101, 'Unknown report for the Technology family.', 1;

    -- Assets in use and the 430 classification (the dashboard technology rule, 451).
    SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, x.StatusName AS LifecycleStatus, x.OwnerName AS Owner,
           CASE ts.Kind WHEN N'FIRMWARE' THEN N'Firmware' ELSE N'Operating system' END AS Technology,
           ts.CurrentLabel AS CurrentVersion, ts.ReleaseStatusName AS ReleaseStatus, ts.SupportEndDate, ts.EndOfLifeDate,
           ts.RecommendedLabel AS RecommendedTarget, ts.Classification, ts.ClassificationReason, ts.ExceptionExpiry,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x
     CROSS APPLY grac_practice.fn_asset_technology_status(@organization_id, x.AssetId) ts
     WHERE x.InUse = 1 AND ts.Classification <> N'NOT_APPLICABLE'
       AND ((@report_code = N'TECH_UNSUPPORTED' AND ts.Classification IN (N'UNSUPPORTED', N'EXCEPTION'))
            OR (@report_code = N'TECH_DUE_SOON'
                AND (ts.Classification = N'DUE_SOON'
                     OR (ts.Classification = N'CURRENT' AND ts.SupportEndDate BETWEEN @today AND DATEADD(DAY, @days, @today))))
            OR (@report_code = N'TECH_FIRMWARE' AND ts.Kind = N'FIRMWARE')
            OR (@report_code = N'TECH_OS' AND ts.Kind = N'OS')
            OR (@report_code = N'TECH_UNKNOWN' AND ts.Classification = N'UNKNOWN'))
       AND (@status IS NULL OR ts.Classification = @status)
     ORDER BY x.AssetName, x.AssetId, ts.Kind
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_risk
    @report_code     NVARCHAR(40),
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @status          NVARCHAR(60)  = NULL,
    @asset_type_id   INT           = NULL,
    @date_from       DATE          = NULL,
    @date_to         DATE          = NULL,
    @days            INT           = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @report_code = N'RISK_CIA'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, x.StatusName AS LifecycleStatus, x.OwnerName AS Owner,
               vr.confidentiality AS Confidentiality, vr.integrity AS Integrity, vr.availability AS Availability,
               vr.method_used AS Method, vr.method_source AS MethodSource, vr.asset_value_score AS AssetValueScore,
               vr.asset_value_category AS AssetValue, vs.validation AS Validation, vr.validation_message AS ValidationMessage,
               vr.calculated_dt AS CalculatedDt,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x
          LEFT JOIN grac_practice.asset_valuation_result vr ON vr.asset_id = x.AssetId
         CROSS APPLY (SELECT ISNULL(vr.validation_status, N'NOT_RATED') AS validation) vs
         WHERE (@status IS NULL OR vs.validation = @status)
         ORDER BY x.AssetName, x.AssetId
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'RISK_VALUE_DIST'
    BEGIN
        -- Assets in use by Asset Value: the dashboard distribution (451), with share and score range.
        SELECT d.category AS AssetValue, COUNT(*) AS Assets,
               CAST(ROUND(100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (), 0), 1) AS DECIMAL(5, 1)) AS SharePct,
               MIN(d.score) AS LowestScore, MAX(d.score) AS HighestScore,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_report_assets(@organization_id, NULL, @asset_type_id) x
          LEFT JOIN grac_practice.asset_valuation_result vr ON vr.asset_id = x.AssetId AND vr.validation_status = N'VALID'
         CROSS APPLY (SELECT ISNULL(vr.asset_value_category, N'Not rated') AS category, vr.asset_value_score AS score,
                             CASE WHEN vr.asset_value_category IS NULL THEN 1 ELSE 0 END AS last_) d
         WHERE x.InUse = 1
         GROUP BY d.category, d.last_
         ORDER BY d.last_, MAX(d.score) DESC, d.category
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'RISK_INHERENT_RESIDUAL'
    BEGIN
        -- Asset links of registered risks: the risk-value rule of 447 (dependency type Asset).
        SELECT rr.risk_number AS RiskNumber, rr.risk_title AS RiskTitle, rr.status_code AS RiskStatus,
               rr.inherent_rating_name AS InherentRating, rr.inherent_rating_score AS InherentScore,
               rr.residual_rating_name AS ResidualRating, ro.employee_name AS RiskOwner,
               x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, vr.asset_value_category AS AssetValue,
               vr.asset_value_score AS AssetValueScore,
               CASE WHEN rv.ReviewSuggested = 1 THEN N'Yes' ELSE N'No' END AS ReviewSuggested,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.risk_dependency_map m
          JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id = m.dependency_type_id
                                                      AND (dt.dependency_type_code = N'ASSET' OR dt.dependency_type_name = N'Asset')
          JOIN grac_practice.risk_register rr ON rr.risk_register_id = m.risk_register_id AND rr.organization_id = @organization_id
          JOIN grac_practice.fn_asset_report_assets(@organization_id, NULL, @asset_type_id) x ON x.AssetId = m.dependency_object_id
          LEFT JOIN grac_practice.asset_valuation_result vr ON vr.asset_id = x.AssetId AND vr.validation_status = N'VALID'
          LEFT JOIN grac_practice.fn_asset_risk_value(@organization_id) rv ON rv.RiskRegisterId = rr.risk_register_id
          LEFT JOIN grac_practice.organization_employee ro ON ro.employee_id = rr.risk_owner_employee_id
         WHERE (@search IS NULL OR x.AssetName LIKE N'%' + @search + N'%' OR rr.risk_title LIKE N'%' + @search + N'%'
                OR rr.risk_number LIKE N'%' + @search + N'%')
         ORDER BY rr.risk_number, x.AssetName
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE
        THROW 53101, 'Unknown report for the Risk and CIA family.', 1;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_governance
    @report_code     NVARCHAR(40),
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @status          NVARCHAR(60)  = NULL,
    @asset_type_id   INT           = NULL,
    @date_from       DATE          = NULL,
    @date_to         DATE          = NULL,
    @days            INT           = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    -- The latest current snapshot: what the scorecard and the dashboard show (450 / 451).
    DECLARE @snap BIGINT = (SELECT TOP (1) snapshot_id FROM grac_practice.asset_governance_snapshot
                             WHERE organization_id = @organization_id AND is_current = 1 ORDER BY as_of_date DESC);
    DECLARE @kpi NVARCHAR(30) = CASE @report_code WHEN N'GOV_METADATA' THEN N'METADATA_COMPLETENESS'
                                                  WHEN N'GOV_OWNERSHIP' THEN N'OWNERSHIP_COMPLETENESS'
                                                  WHEN N'GOV_COVERAGE' THEN N'COVERAGE_COMPLIANCE'
                                                  WHEN N'GOV_EXCEPTION' THEN N'EXCEPTION_HEALTH' END;

    IF @report_code = N'GOV_SCORE'
    BEGIN
        SELECT s.snapshot_id AS SnapshotId, s.as_of_date AS AsOfDate, s.version_no AS VersionNo,
               CASE WHEN s.is_current = 1 THEN N'Yes' ELSE N'No' END AS IsCurrent, s.overall_score AS OverallScore,
               s.overall_rag AS Rating, s.overall_target AS Target, s.overall_warning AS Warning, s.source_code AS Source,
               s.item_count AS RecordCount, s.taken_by AS TakenBy, s.taken_dt AS TakenDt, s.superseded_dt AS SupersededDt,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.asset_governance_snapshot s
         WHERE s.organization_id = @organization_id
           AND (@status IS NULL OR s.overall_rag = @status)
           AND (@date_from IS NULL OR s.as_of_date >= @date_from)
           AND (@date_to IS NULL OR s.as_of_date <= @date_to)
         ORDER BY s.as_of_date DESC, s.version_no DESC
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'GOV_COMPONENTS'
    BEGIN
        SELECT s.as_of_date AS AsOfDate, s.version_no AS SnapshotVersion, d.kpi_name AS Kpi,
               CASE WHEN k.is_enabled = 1 THEN N'Yes' ELSE N'No' END AS Enabled, k.numerator AS Numerator, k.denominator AS Denominator,
               k.excluded_count AS Excluded, k.failing_count AS Failing, k.score AS Score, k.rag AS Rating,
               k.target_value AS Target, k.warning_value AS Warning, k.weight AS Weight, k.direction AS Direction,
               k.period_days AS PeriodDays,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.asset_governance_snapshot_kpi k
          JOIN grac_practice.asset_governance_snapshot s ON s.snapshot_id = k.snapshot_id
          JOIN grac_practice.asset_governance_kpi d ON d.kpi_code = k.kpi_code
         WHERE k.snapshot_id = @snap
           AND (@status IS NULL OR k.rag = @status)
         ORDER BY d.display_order
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @kpi IS NOT NULL
    BEGIN
        SELECT s.as_of_date AS AsOfDate, s.version_no AS SnapshotVersion, i.record_kind AS RecordKind, i.record_id AS RecordId,
               i.record_name AS RecordName, i.outcome AS Outcome, i.numerator AS Numerator, i.denominator AS Denominator,
               i.reason AS Reason,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.asset_governance_snapshot_item i
          JOIN grac_practice.asset_governance_snapshot s ON s.snapshot_id = i.snapshot_id
         WHERE i.snapshot_id = @snap AND i.kpi_code = @kpi
           AND (@status IS NULL OR i.outcome = @status)
           AND (@search IS NULL OR i.record_name LIKE N'%' + @search + N'%')
         ORDER BY CASE i.outcome WHEN N'FAIL' THEN 1 WHEN N'PASS' THEN 2 ELSE 3 END, i.record_name, i.record_id
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE
        THROW 53101, 'Unknown report for the Governance family.', 1;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_privacy
    @report_code     NVARCHAR(40),
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @status          NVARCHAR(60)  = NULL,
    @asset_type_id   INT           = NULL,
    @date_from       DATE          = NULL,
    @date_to         DATE          = NULL,
    @days            INT           = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF @report_code = N'PRV_PERSONAL_DATA'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, x.StatusName AS LifecycleStatus,
               ps.PersonalDataProcessed, po.employee_name AS PrivacyOwner, ps.AssessmentStatus, ps.PrivacyReviewDate,
               ps.RetentionDueDate AS RetentionEnds, ps.LegalHold, ps.PrivacyStatus, ps.Failed, ps.Missing, ps.Partial,
               ps.Excepted, ps.Blocking,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_privacy_status(@organization_id, NULL) ps
          JOIN grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x ON x.AssetId = ps.AssetId
          LEFT JOIN grac_practice.organization_employee po ON po.employee_id = ps.PrivacyOwnerId
         WHERE ps.Applicability = N'APPLICABLE'
           AND (@status IS NULL OR ps.PrivacyStatus = @status)
         ORDER BY x.AssetName, x.AssetId
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'PRV_DPIA'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, x.StatusName AS LifecycleStatus,
               v.hrp AS HighRiskProcessing, v.spc AS SpecialCategoryOrHealthData, v.chd AS ChildrenData,
               v.dreq AS DpiaRequired, v.dst AS DpiaStatus, v.pas AS PrivacyAssessment,
               dg.gap_count AS DpiaGaps, dg.messages AS DpiaGapDetail,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_privacy_values(@organization_id, NULL) v
          JOIN grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x ON x.AssetId = v.AssetId
         OUTER APPLY (SELECT COUNT(*) AS gap_count, STRING_AGG(CAST(g.Message AS NVARCHAR(MAX)), N' ') AS messages
                        FROM grac_practice.fn_asset_privacy_gaps(@organization_id, v.AssetId) g
                       WHERE g.RequirementCode = N'DPIA' AND g.IsExcepted = 0) dg
         WHERE v.pd IN (N'YES', N'UNKNOWN')
           AND (@status IS NULL OR (@status = N'GAP' AND dg.gap_count > 0) OR (@status = N'NO_GAP' AND dg.gap_count = 0))
         ORDER BY dg.gap_count DESC, x.AssetName, x.AssetId
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'PRV_MASK_ENC'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, g.RequirementName AS Requirement, g.GapKind AS Gap,
               g.Message, g.Enforcement, CASE WHEN g.IsExcepted = 1 THEN N'Yes' ELSE N'No' END AS Excepted, g.ExceptionExpiry,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_privacy_gaps(@organization_id, NULL) g
          JOIN grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x ON x.AssetId = g.AssetId
         WHERE g.RequirementCode IN (N'MASKING', N'ENCRYPTION')
           AND (@status IS NULL OR g.RequirementCode = @status)
         ORDER BY x.AssetName, x.AssetId, g.DisplayOrder
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'PRV_RETENTION'
    BEGIN
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, x.StatusName AS LifecycleStatus,
               v.rpol AS RetentionPolicy, v.rper AS RetentionPeriod, v.rtrg AS RetentionTrigger, v.lhold AS LegalHold,
               rt.RetentionDueDate AS RetentionEnds, DATEDIFF(DAY, @today, rt.RetentionDueDate) AS DaysLeft,
               orv.due_date AS OpenReviewDue, lrv.outcome AS LastDecision, lrv.completed_dt AS LastDecisionDt,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_privacy_values(@organization_id, NULL) v
          JOIN grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x ON x.AssetId = v.AssetId
         CROSS APPLY grac_practice.fn_asset_privacy_retention_calc(@organization_id, v.AssetId, v.rper, v.rtrg, v.RegisteredDate, v.psc) rt
         OUTER APPLY (SELECT TOP (1) r.due_date FROM grac_practice.asset_privacy_review r
                       WHERE r.asset_id = v.AssetId AND r.review_kind = N'RETENTION' AND r.status = N'OPEN'
                       ORDER BY r.due_date) orv
         OUTER APPLY (SELECT TOP (1) r.outcome, r.completed_dt FROM grac_practice.asset_privacy_review r
                       WHERE r.asset_id = v.AssetId AND r.review_kind = N'RETENTION' AND r.status = N'COMPLETED'
                       ORDER BY r.completed_dt DESC) lrv
         WHERE v.pd IN (N'YES', N'UNKNOWN') AND rt.RetentionDueDate IS NOT NULL
           AND rt.RetentionDueDate <= DATEADD(DAY, @days, @today)
           AND (@status IS NULL OR (@status = N'ENDED' AND rt.RetentionDueDate < @today)
                OR (@status = N'ENDING' AND rt.RetentionDueDate >= @today))
         ORDER BY rt.RetentionDueDate, x.AssetName
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE IF @report_code = N'PRV_EVIDENCE'
    BEGIN
        -- Evidence / certificate dates of assets in use (439, 9.1.7).
        SELECT x.AssetId, x.AssetName, x.AssetTypeName AS AssetType, x.OwnerName AS Owner, ef.evidence_name AS Evidence,
               v.value_date AS ExpiryDate, DATEDIFF(DAY, @today, v.value_date) AS DaysLeft,
               CASE WHEN v.value_date < @today THEN N'Expired' ELSE N'Expiring' END AS ExpiryState,
               CASE WHEN ef.restrict_on_expiry = 1 THEN N'Yes' ELSE N'No' END AS RestrictsUseOnExpiry,
               COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_report_assets(@organization_id, @search, @asset_type_id) x
          JOIN grac_practice.asset_field_value v ON v.asset_id = x.AssetId AND v.value_date IS NOT NULL
          JOIN grac_practice.asset_field_definition fd ON fd.field_definition_id = v.field_definition_id
          JOIN grac_practice.asset_evidence_field ef ON ef.field_key = fd.field_key AND ef.is_active = 1
         WHERE x.InUse = 1 AND v.value_date <= DATEADD(DAY, @days, @today)
           AND (@status IS NULL OR (@status = N'EXPIRED' AND v.value_date < @today)
                OR (@status = N'EXPIRING' AND v.value_date >= @today))
         ORDER BY v.value_date, x.AssetName
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE
        THROW 53101, 'Unknown report for the Privacy and Compliance family.', 1;
END
GO
PRINT '452: Contract, Technology, Risk, Governance and Privacy report procedures created.';
GO

-- =====================================================================
-- 5. Effective settings, catalogue, run, export log, history, settings
-- =====================================================================
-- Per report for an organization: enabled, classification (the
-- organization may raise it, never lower it) and export policy (default:
-- APPROVER for RESTRICTED, else ALLOWED).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_report_effective (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT d.report_code AS ReportCode, CAST(ISNULL(os.is_enabled, 1) AS BIT) AS IsEnabled,
           ISNULL(os.classification, d.default_classification) AS Classification,
           ISNULL(os.export_policy, CASE WHEN ISNULL(os.classification, d.default_classification) = N'RESTRICTED'
                                         THEN N'APPROVER' ELSE N'ALLOWED' END) AS ExportPolicy,
           os.classification AS ClassificationOverride, os.export_policy AS ExportPolicyOverride
      FROM grac_practice.asset_report_definition d
      LEFT JOIN grac_practice.asset_report_org_setting os ON os.organization_id = @organization_id AND os.report_code = d.report_code;
GO

-- 1. reports the caller may view (the screen of each report is in
--    @allowed_areas, a comma list the Web tier builds from the session)
-- 2. asset lifecycle statuses (status filter of the asset reports)
-- 3. asset types in use in the organization (asset type filter)
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_catalogue
    @organization_id BIGINT,
    @allowed_areas   NVARCHAR(2000) = NULL,
    @can_approve     BIT            = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53100, 'Organization not found.', 1;
    DECLARE @areas NVARCHAR(2004) = N',' + REPLACE(ISNULL(@allowed_areas, N''), N' ', N'') + N',';

    SELECT d.report_code AS ReportCode, d.family_code AS FamilyCode, d.family_name AS FamilyName, d.report_name AS ReportName,
           d.description AS Description, d.version_no AS VersionNo, d.is_available AS IsAvailable,
           d.unavailable_reason AS UnavailableReason, e.IsEnabled, d.default_classification AS DefaultClassification,
           e.Classification, e.ExportPolicy, e.ClassificationOverride, e.ExportPolicyOverride,
           CAST(CASE WHEN d.is_available = 1 AND e.IsEnabled = 1
                      AND (e.ExportPolicy = N'ALLOWED' OR (e.ExportPolicy = N'APPROVER' AND ISNULL(@can_approve, 0) = 1))
                     THEN 1 ELSE 0 END AS BIT) AS CanExport,
           d.view_area AS ViewArea, d.filter_keys AS FilterKeys, d.status_label AS StatusLabel, d.status_options AS StatusOptions,
           d.date_label AS DateLabel, d.default_days AS DefaultDays, d.brd_reference AS BrdReference, d.display_order AS DisplayOrder
      FROM grac_practice.asset_report_definition d
      JOIN grac_practice.fn_asset_report_effective(@organization_id) e ON e.ReportCode = d.report_code
     WHERE d.is_active = 1 AND CHARINDEX(N',' + d.view_area + N',', @areas) > 0
     ORDER BY d.display_order;

    SELECT s.status_code AS Code, s.status_name AS Name
      FROM grac_practice.entity_status_master s
     WHERE s.entity_type = N'Asset'
     ORDER BY s.display_order;

    SELECT t.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName
      FROM grac_practice.dependency_asset_type_master t
     WHERE EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                    WHERE a.organization_id = @organization_id AND a.asset_type_id = t.asset_type_id)
     ORDER BY t.asset_type_name;
END
GO

-- Runs one report (screen grid or export). Checks: report known and
-- available, its screen in @allowed_areas, enabled for the organization,
-- for an export the policy (APPROVER needs @can_approve), filters valid.
-- Filters the report does not take are ignored. Export: page 1 of up to
-- 50001 rows (the API refuses more than 50000 -- 53107).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_run
    @organization_id BIGINT,
    @report_code     NVARCHAR(40),
    @allowed_areas   NVARCHAR(2000) = NULL,
    @can_approve     BIT            = 0,
    @for_export      BIT            = 0,
    @search          NVARCHAR(200)  = NULL,
    @status          NVARCHAR(60)   = NULL,
    @asset_type_id   INT            = NULL,
    @date_from       DATE           = NULL,
    @date_to         DATE           = NULL,
    @days            INT            = NULL,
    @page_number     INT            = 1,
    @page_size       INT            = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53100, 'Organization not found.', 1;
    SET @report_code = UPPER(NULLIF(LTRIM(RTRIM(@report_code)), N''));
    DECLARE @areas NVARCHAR(2004) = N',' + REPLACE(ISNULL(@allowed_areas, N''), N' ', N'') + N',';
    DECLARE @proc NVARCHAR(128), @area NVARCHAR(100), @available BIT, @keys NVARCHAR(204), @options NVARCHAR(1000),
            @default_days INT, @enabled BIT, @policy NVARCHAR(10);
    SELECT @proc = d.proc_name, @area = d.view_area, @available = d.is_available, @keys = N',' + d.filter_keys + N',',
           @options = d.status_options, @default_days = d.default_days, @enabled = e.IsEnabled, @policy = e.ExportPolicy
      FROM grac_practice.asset_report_definition d
      JOIN grac_practice.fn_asset_report_effective(@organization_id) e ON e.ReportCode = d.report_code
     WHERE d.report_code = @report_code AND d.is_active = 1;
    IF @area IS NULL
        THROW 53101, 'Unknown report.', 1;
    IF CHARINDEX(N',' + @area + N',', @areas) = 0
        THROW 53103, 'You do not have permission to view the screen this report is based on.', 1;
    IF @available = 0
        THROW 53102, 'This report is not available yet; see the catalogue for where the information is today.', 1;
    IF @enabled = 0
        THROW 53104, 'This report is disabled for the organization.', 1;
    IF ISNULL(@for_export, 0) = 1
       AND NOT (@policy = N'ALLOWED' OR (@policy = N'APPROVER' AND ISNULL(@can_approve, 0) = 1))
        THROW 53105, 'Export of this report is not allowed by the organization policy, or needs Asset Reports APPROVE.', 1;

    -- Filters the report does not take are ignored.
    SET @search = CASE WHEN CHARINDEX(N',SEARCH,', @keys) > 0 THEN NULLIF(LTRIM(RTRIM(@search)), N'') END;
    SET @status = CASE WHEN CHARINDEX(N',STATUS,', @keys) > 0 THEN NULLIF(UPPER(LTRIM(RTRIM(@status))), N'') END;
    SET @asset_type_id = CASE WHEN CHARINDEX(N',ASSET_TYPE,', @keys) > 0 THEN @asset_type_id END;
    IF CHARINDEX(N',DATE_RANGE,', @keys) = 0 SELECT @date_from = NULL, @date_to = NULL;
    SET @days = CASE WHEN CHARINDEX(N',DAYS,', @keys) > 0 THEN ISNULL(@days, @default_days) END;

    IF @status IS NOT NULL
       AND NOT ((@options = N'@ASSET_STATUS'
                 AND EXISTS (SELECT 1 FROM grac_practice.entity_status_master WHERE entity_type = N'Asset' AND status_code = @status))
                OR (@options <> N'@ASSET_STATUS' AND CHARINDEX(N'|' + @status + N'=', N'|' + @options) > 0))
        THROW 53106, 'Unknown status for this report.', 1;
    IF @date_from IS NOT NULL AND @date_to IS NOT NULL AND @date_from > @date_to
        THROW 53106, 'The from date is after the to date.', 1;
    IF CHARINDEX(N',DAYS,', @keys) > 0 AND (@days IS NULL OR @days NOT BETWEEN 1 AND 3650)
        THROW 53106, 'Days must be between 1 and 3650.', 1;

    IF ISNULL(@for_export, 0) = 1
    BEGIN
        SELECT @page_number = 1, @page_size = 50001;
    END
    ELSE
    BEGIN
        SELECT @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END,
               @page_size = CASE WHEN ISNULL(@page_size, 25) NOT BETWEEN 1 AND 200 THEN 25 ELSE @page_size END;
    END

    IF @proc IS NULL OR @proc NOT LIKE N'sp[_]asset[_]report[_]%' OR OBJECT_ID(N'grac_practice.' + QUOTENAME(@proc), 'P') IS NULL
        THROW 53110, 'The report procedure is missing; re-run migration 452.', 1;
    DECLARE @module NVARCHAR(300) = N'grac_practice.' + QUOTENAME(@proc);
    EXEC @module @report_code = @report_code, @organization_id = @organization_id, @search = @search, @status = @status,
         @asset_type_id = @asset_type_id, @date_from = @date_from, @date_to = @date_to, @days = @days,
         @page_number = @page_number, @page_size = @page_size;
END
GO

-- Export record (13.4.1): report and version, organization, filters,
-- columns, row count, classification, user, employee and time. Written
-- by the API after the rows were read and before they are returned.
-- Returns what the file watermark shows.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_export_log
    @organization_id   BIGINT,
    @report_code       NVARCHAR(40),
    @filters_json      NVARCHAR(MAX) = NULL,
    @columns_json      NVARCHAR(MAX) = NULL,
    @row_count         INT,
    @actor             NVARCHAR(100) = N'system',
    @actor_employee_id BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53100, 'Organization not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_report_definition WHERE report_code = @report_code AND is_active = 1)
        THROW 53101, 'Unknown report.', 1;
    IF (@filters_json IS NOT NULL AND ISJSON(@filters_json) = 0) OR (@columns_json IS NOT NULL AND ISJSON(@columns_json) = 0)
       OR @row_count IS NULL OR @row_count < 0
        THROW 53106, 'Export filters, columns or row count invalid.', 1;
    DECLARE @id TABLE (export_id BIGINT NOT NULL);
    INSERT grac_practice.asset_report_export (organization_id, report_code, report_version, report_name, classification,
                                              filters_json, columns_json, row_count, exported_by, exported_employee_id)
    OUTPUT inserted.export_id INTO @id (export_id)
    SELECT @organization_id, d.report_code, d.version_no, d.report_name, e.Classification,
           @filters_json, @columns_json, @row_count, @actor, @actor_employee_id
      FROM grac_practice.asset_report_definition d
      JOIN grac_practice.fn_asset_report_effective(@organization_id) e ON e.ReportCode = d.report_code
     WHERE d.report_code = @report_code;

    SELECT x.export_id AS ExportId, x.report_code AS ReportCode, x.report_name AS ReportName, x.report_version AS ReportVersion,
           x.classification AS Classification, o.organization_name AS OrganizationName, x.row_count AS [RowCount],
           COALESCE(emp.employee_name, x.exported_by) AS ExportedBy, x.exported_dt AS ExportedDt, x.filters_json AS FiltersJson
      FROM grac_practice.asset_report_export x
      JOIN @id i ON i.export_id = x.export_id
      JOIN grac_practice.organization o ON o.organization_id = x.organization_id
      LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id = x.exported_employee_id;
END
GO

-- Export history of the reports the caller may view.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_exports
    @organization_id BIGINT,
    @allowed_areas   NVARCHAR(2000) = NULL,
    @report_code     NVARCHAR(40)   = NULL,
    @page_number     INT            = 1,
    @page_size       INT            = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53100, 'Organization not found.', 1;
    DECLARE @areas NVARCHAR(2004) = N',' + REPLACE(ISNULL(@allowed_areas, N''), N' ', N'') + N',';
    SET @report_code = NULLIF(LTRIM(RTRIM(@report_code)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) NOT BETWEEN 1 AND 200 THEN 25 ELSE @page_size END;

    SELECT x.export_id AS ExportId, x.report_code AS ReportCode, x.report_name AS ReportName, x.report_version AS ReportVersion,
           d.family_name AS FamilyName, x.classification AS Classification, x.file_format AS FileFormat, x.row_count AS [RowCount],
           x.filters_json AS FiltersJson, x.columns_json AS ColumnsJson,
           COALESCE(emp.employee_name, x.exported_by) AS ExportedBy, x.exported_dt AS ExportedDt,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_report_export x
      JOIN grac_practice.asset_report_definition d ON d.report_code = x.report_code
      LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id = x.exported_employee_id
     WHERE x.organization_id = @organization_id
       AND CHARINDEX(N',' + d.view_area + N',', @areas) > 0
       AND (@report_code IS NULL OR x.report_code = @report_code)
     ORDER BY x.exported_dt DESC, x.export_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Organization setting of one report: enabled, classification (not below
-- the default; NULL = default), export policy (NULL = default). Audited.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_org_setting_save
    @organization_id BIGINT,
    @report_code     NVARCHAR(40),
    @allowed_areas   NVARCHAR(2000) = NULL,
    @is_enabled      BIT            = 1,
    @classification  NVARCHAR(20)   = NULL,
    @export_policy   NVARCHAR(10)   = NULL,
    @actor           NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @report_code = UPPER(NULLIF(LTRIM(RTRIM(@report_code)), N''));
    SET @classification = UPPER(NULLIF(LTRIM(RTRIM(@classification)), N''));
    SET @export_policy = UPPER(NULLIF(LTRIM(RTRIM(@export_policy)), N''));
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53100, 'Organization not found.', 1;
    DECLARE @area NVARCHAR(100), @default NVARCHAR(20);
    SELECT @area = view_area, @default = default_classification
      FROM grac_practice.asset_report_definition WHERE report_code = @report_code AND is_active = 1;
    IF @area IS NULL
        THROW 53101, 'Unknown report.', 1;
    IF CHARINDEX(N',' + @area + N',', N',' + REPLACE(ISNULL(@allowed_areas, N''), N' ', N'') + N',') = 0
        THROW 53103, 'You do not have permission to view the screen this report is based on.', 1;
    IF @classification IS NOT NULL
       AND (@classification NOT IN (N'PUBLIC', N'INTERNAL', N'CONFIDENTIAL', N'RESTRICTED')
            OR CASE @classification WHEN N'PUBLIC' THEN 1 WHEN N'INTERNAL' THEN 2 WHEN N'CONFIDENTIAL' THEN 3 ELSE 4 END
             < CASE @default WHEN N'PUBLIC' THEN 1 WHEN N'INTERNAL' THEN 2 WHEN N'CONFIDENTIAL' THEN 3 ELSE 4 END)
        THROW 53108, 'The classification is unknown or lower than the default classification of the report.', 1;
    IF @export_policy IS NOT NULL AND @export_policy NOT IN (N'ALLOWED', N'APPROVER', N'DISABLED')
        THROW 53109, 'Export policy must be ALLOWED, APPROVER or DISABLED.', 1;
    IF @classification = @default SET @classification = NULL;

    DECLARE @before NVARCHAR(MAX) = (SELECT os.report_code AS reportCode, os.is_enabled AS isEnabled, os.classification,
                                            os.export_policy AS exportPolicy
                                       FROM grac_practice.asset_report_org_setting os
                                      WHERE os.organization_id = @organization_id AND os.report_code = @report_code
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    UPDATE grac_practice.asset_report_org_setting
       SET is_enabled = ISNULL(@is_enabled, 1), classification = @classification, export_policy = @export_policy,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE organization_id = @organization_id AND report_code = @report_code;
    IF @@ROWCOUNT = 0
        INSERT grac_practice.asset_report_org_setting (organization_id, report_code, is_enabled, classification, export_policy, entered_by)
        VALUES (@organization_id, @report_code, ISNULL(@is_enabled, 1), @classification, @export_policy, @actor);
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-report-org-setting', @organization_id, N'SAVE', @before,
            (SELECT @report_code AS reportCode, ISNULL(@is_enabled, 1) AS isEnabled, @classification AS classification,
                    @export_policy AS exportPolicy FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @organization_id AS OrganizationId, @report_code AS ReportCode, N'SAVED' AS Result;
END
GO
PRINT '452: catalogue, run, export log, history and settings procedures created.';
GO

-- =====================================================================
-- 6. Menu: Asset & Contract -> Asset Reports (also carried in 274).
--    Admin: VIEW, EDIT (organization settings), APPROVE (exports whose
--    policy needs an approver). VIEW for every role that can VIEW a
--    screen one of the reports is based on (the reports themselves stay
--    limited to those screens, D199).
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-reports', N'Asset Reports', N'Practice/Index/asset-reports', 366, N'file-lines', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-452', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-452');
PRINT CONCAT('452: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-452', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-reports' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 0, 1, 0, 1, N'Active', @active_rs, N'seed-452', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-reports'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('452: Admin grants inserted: ', @@ROWCOUNT);

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT DISTINCT p.role_id, m.menu_id, 1, 0, 0, 0, 0, N'Active', @active_rs, N'seed-452', SYSUTCDATETIME()
  FROM (SELECT DISTINCT view_area FROM grac_practice.asset_report_definition WHERE is_active = 1 AND is_available = 1) a
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-reports'
  JOIN grac_practice.menu_master c ON c.menu_key = a.view_area AND c.status = N'Active'
  JOIN grac_practice.organization_role_menu_permission p ON p.menu_id = c.menu_id AND p.can_view = 1 AND p.status = N'Active'
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = p.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('452: report VIEW grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 7. Verification
-- =====================================================================
SELECT '452-a tables' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_report_definition','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_report_org_setting','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_report_export','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '452-b functions and procedures present',
       CASE WHEN OBJECT_ID('grac_practice.fn_asset_report_assets') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_report_contracts') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_report_relationships') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_report_effective') IS NOT NULL
             AND (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_report_asset', 'sp_asset_report_attestation', 'sp_asset_report_cmdb',
                                'sp_asset_report_discovery', 'sp_asset_report_contract', 'sp_asset_report_technology',
                                'sp_asset_report_risk', 'sp_asset_report_governance', 'sp_asset_report_privacy',
                                'sp_asset_report_catalogue', 'sp_asset_report_run', 'sp_asset_report_export_log',
                                'sp_asset_report_exports', 'sp_asset_report_org_setting_save')) = 14
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '452-c catalogue: 53 reports in 9 families, 47 available, every family procedure exists',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.asset_report_definition WHERE is_active = 1) = 53
             AND (SELECT COUNT(DISTINCT family_code) FROM grac_practice.asset_report_definition WHERE is_active = 1) = 9
             AND (SELECT COUNT(*) FROM grac_practice.asset_report_definition WHERE is_active = 1 AND is_available = 1) = 47
             AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_report_definition
                              WHERE is_active = 1 AND OBJECT_ID(N'grac_practice.' + QUOTENAME(proc_name), 'P') IS NULL)
             AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_report_definition
                              WHERE is_available = 0 AND unavailable_reason IS NULL)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '452-d filter keys are known tokens',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.asset_report_definition d
                             CROSS APPLY STRING_SPLIT(d.filter_keys, N',') k
                              WHERE k.value NOT IN (N'SEARCH', N'STATUS', N'ASSET_TYPE', N'DATE_RANGE', N'DAYS'))
             AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_report_definition
                              WHERE CHARINDEX(N'DAYS', filter_keys) > 0 AND default_days IS NULL)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '452-e menu: Asset Reports under Asset & Contract with Admin VIEW / EDIT / APPROVE',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-reports' AND c.status = N'Active')
             AND EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission g
                           JOIN grac_practice.menu_master m ON m.menu_id = g.menu_id AND m.menu_key = N'asset-reports'
                           JOIN grac_practice.organization_role r ON r.role_id = g.role_id AND r.role_name = N'Admin'
                          WHERE g.can_view = 1 AND g.can_edit = 1 AND g.can_approve = 1)
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- Every available report runs for the first organization with assets
-- (one page of one row each; the grids are the smoke output). The last
-- result lists the reports that raised an error (none expected).
DECLARE @org BIGINT = (SELECT TOP (1) organization_id FROM grac_practice.organization_dependency_asset ORDER BY organization_id);
DECLARE @areas NVARCHAR(2000) = (SELECT STRING_AGG(v.view_area, N',')
                                   FROM (SELECT DISTINCT view_area FROM grac_practice.asset_report_definition) v);
DECLARE @failed TABLE (report_code NVARCHAR(40), error_number INT, error_message NVARCHAR(4000));
DECLARE @code NVARCHAR(40);
DECLARE rpt CURSOR LOCAL FAST_FORWARD FOR
    SELECT report_code FROM grac_practice.asset_report_definition
     WHERE @org IS NOT NULL AND is_active = 1 AND is_available = 1 ORDER BY display_order;
OPEN rpt;
FETCH NEXT FROM rpt INTO @code;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC grac_practice.sp_asset_report_run @organization_id = @org, @report_code = @code, @allowed_areas = @areas,
             @page_number = 1, @page_size = 1;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        INSERT @failed VALUES (@code, ERROR_NUMBER(), ERROR_MESSAGE());
    END CATCH
    FETCH NEXT FROM rpt INTO @code;
END
CLOSE rpt;
DEALLOCATE rpt;
SELECT '452-f every available report runs' AS Check_,
       CASE WHEN @org IS NULL THEN 'SKIPPED (no organization has assets)'
            WHEN NOT EXISTS (SELECT 1 FROM @failed) THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT report_code AS FailedReport, error_number AS ErrorNumber, error_message AS ErrorMessage FROM @failed;
GO

/* =====================================================================
   UAT (re-login after running 452; Admin, then a role with VIEW on
   Asset Register only)
   ---------------------------------------------------------------------
   1. Asset & Contract -> Asset Reports: the catalogue lists the reports
      of the screens the role may VIEW, grouped by family, each with its
      classification and version; not-available reports show where the
      information lives today and cannot be run.
   2. Complete Asset Register, status Active: the total equals the Asset
      Register filtered to Active (same search, alias search included).
   3. Coverage Gaps: the total equals Asset Contracts -> Coverage gaps;
      Overdue Attestations equals Asset Attestation filtered to Overdue;
      Asset Value Distribution equals the dashboard bars "Assets in use
      by Asset Value".
   4. Export CSV: the file starts with the report, version, organization,
      classification, exported by, UTC time and filters lines, then the
      columns shown on screen; Export history lists it with the same
      filters, columns and row count.
   5. Settings (Admin): set Vendor Contact Matrix to RESTRICTED -> its
      export needs Asset Reports APPROVE (a role without it gets 53105);
      set a report to INTERNAL below its CONFIDENTIAL default -> refused
      (53108); disable a report -> it cannot be run (53104).
   6. Role with Asset Register VIEW only: contract, privacy and risk
      reports are not listed; calling their run URL directly returns 403
      (53103).
   7. Source Health with Days 7: batch counts cover the last 7 days only.
   ===================================================================== */
