-- =====================================================================
-- 450  Asset governance KPIs -- formula definitions, organization
--      thresholds and weights, scored snapshots with record-level
--      drill-down, governance score, Asset Governance screen
--      (Asset & Contract Management, Phase 8 increment 4a)
--
-- REQUEST
-- -------
--   BRD v1.7 19.8 (Governance KPI formula definitions: Attestation
--   Compliance, Metadata Completeness, Ownership Completeness,
--   Relationship Completeness, Coverage Compliance, Technology Support
--   Compliance, Exception Health, Discovery Freshness, Reconciliation
--   Backlog Rate, Connector Availability; "every KPI definition includes
--   population / as-of logic, exclusions, zero-denominator behaviour,
--   rounding, thresholds and authorization"; "every score drills down to
--   exact numerator, denominator, excluded and failing records"; "late-
--   arriving data creates a new snapshot and preserves the prior
--   result"), 13.5 Governance dashboard ("overall score, component
--   scores, trends, threshold breaches and exact numerator / denominator
--   drill-down"), 19.10 Governance KPI Detail report ("formula,
--   population, numerator, denominator, exclusions and failures").
--   Plan: docs/asset-contract-management.md (Phase 8.4a, D167-D182).
--
-- WHAT THIS DOES
-- --------------
--   1. asset_governance_kpi -- the 10 KPIs with their formula, numerator,
--      denominator, population, as-of, exclusion, zero-denominator,
--      rounding and authorization text, direction (higher / lower is
--      better), default target / warning thresholds, weight and period.
--   2. asset_governance_setting (per organization and KPI: enabled,
--      weight, target, warning, period) and asset_governance_org_setting
--      (overall target / warning, record-detail retention).
--   3. asset_governance_relationship_rule -- which relationships an asset
--      type requires (type, side, minimum); business services use the 441
--      minimum supporting relationships.
--   4. fn_asset_governance_assets / fn_asset_governance_items: one row per
--      record of each KPI -- PASS, FAIL or EXCLUDED, its numerator and
--      denominator contribution and the reason -- computed from the
--      records the modules already keep (431, 421 / 428, 435, 430, 432,
--      439, 447, 448, 440 / 441, 442).
--   5. asset_governance_snapshot / _snapshot_kpi / _snapshot_item and
--      sp_asset_governance_snapshot_take: a snapshot stores every KPI row
--      and every record row; a later snapshot of the same date whose
--      results differ supersedes it (the prior one is kept); an unchanged
--      result creates nothing. Daily by the scheduler, on demand by EDIT.
--   6. Readers: sp_asset_governance_get (scorecard, trend),
--      _items (drill-down), _snapshots (history), _settings; writers
--      _setting_save, _org_setting_save, _relationship_rule_save.
--   7. sp_asset_scheduler_run (448 body) re-issued: one snapshot per
--      organization per day after the notification sweep.
--   8. Menu Asset & Contract -> Asset Governance (365; also in 274).
--
-- NOT DONE HERE: the Asset & Contract module dashboards (13.1 / 13.2 /
--   13.3 / 13.5 / 19.10 widgets -- Phase 8.4b); notifications on
--   threshold breaches; KPIs for business-service coverage (no service
--   coverage requirement exists); recomputing a past date (records keep
--   their current state, so a snapshot is always "as of when taken").
--
-- ERROR NUMBERS: 53080-53099
--   53080 organization not found        53081 unknown KPI
--   53082 threshold / weight / period invalid
--   53083 snapshot not found            53084 asset type not found
--   53085 relationship type not found or not for assets
--   53086 relationship rule not found   53087 side / minimum invalid
--   53088 a rule for this type, relationship and side exists
--   53089 retention / overall threshold invalid
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web
--   proxy (asset-governance area), PracticeScreen + Manage.cshtml +
--   appsettings (new screen), new asset-governance.cshtml / .js, 274
--   (menu), docs.
-- DEPENDS ON: 428, 430, 431, 432, 435, 439, 440, 441, 442, 447, 448.
-- Rollback: 450_asset_governance_kpis_rollback.sql (restores the 448
--   scheduler body, drops the 450 objects and the menu row).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_asset_privacy_sync','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_privacy_gaps') IS NULL
   OR OBJECT_ID('grac_practice.asset_privacy_exception','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_consistency_finding','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_form_evaluate') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_stored_values') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_technology_status') IS NULL
   OR OBJECT_ID('grac_practice.asset_technology_exception','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_attestation','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_verification_exception','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_coverage_gaps') IS NULL
   OR OBJECT_ID('grac_practice.asset_coverage_requirement','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_activity_disposition','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_relationship','U') IS NULL
   OR OBJECT_ID('grac_practice.business_service_setting','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_discovery_confidence') IS NULL
   OR OBJECT_ID('grac_practice.asset_reconciliation_exception','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_discovery_batch','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_scheduler_run','P') IS NULL
   OR OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_scheduler_run')) NOT LIKE '%sp_asset_privacy_sync%'
   OR COL_LENGTH('grac_practice.asset_consistency_finding', 'reopened_count') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset', 'template_id') IS NULL
BEGIN
    RAISERROR('ABORT (450): run 428-448 first (450 re-issues the 448 scheduler body).', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. KPI catalogue (global) -- BRD 19.8
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_governance_kpi','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_governance_kpi (
        kpi_code            NVARCHAR(30)   NOT NULL CONSTRAINT pk_pm_agov_kpi PRIMARY KEY,
        kpi_name            NVARCHAR(120)  NOT NULL,
        formula_text        NVARCHAR(400)  NOT NULL,
        numerator_text      NVARCHAR(600)  NOT NULL,
        denominator_text    NVARCHAR(600)  NOT NULL,
        population_text     NVARCHAR(1000) NOT NULL,
        exclusions_text     NVARCHAR(1000) NOT NULL,
        as_of_text          NVARCHAR(600)  NOT NULL,
        record_label        NVARCHAR(40)   NOT NULL,     -- what one drill-down row is
        direction           NVARCHAR(6)    NOT NULL
            CONSTRAINT ck_pm_agov_kpi_dir CHECK (direction IN (N'HIGHER', N'LOWER')),
        default_target      DECIMAL(5, 1)  NOT NULL,
        default_warning     DECIMAL(5, 1)  NOT NULL,
        default_weight      INT            NOT NULL,
        default_period_days INT            NULL,         -- NULL: the KPI has no period
        brd_reference       NVARCHAR(60)   NOT NULL,
        display_order       INT            NOT NULL,
        entered_by          NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_agov_kpi_eby DEFAULT N'system',
        entered_dt          DATETIME2      NOT NULL CONSTRAINT df_pm_agov_kpi_edt DEFAULT SYSUTCDATETIME()
    );
    PRINT '450: asset_governance_kpi created.';
END
GO

MERGE grac_practice.asset_governance_kpi AS t
USING (VALUES
    (N'ATTESTATION_COMPLIANCE', N'Attestation Compliance',
     N'Confirmed or approved-closed occurrences due in period / required occurrences due in period x 100',
     N'Attestation occurrences due in the period that are Confirmed (awaiting manager approval), Closed (verified) or Resolved (a dispute resolved and closed).',
     N'Attestation occurrences due in the period, except cancelled ones.',
     N'Every attestation occurrence (initial, periodic, transfer, return, event, campaign) of the organization whose due date falls in the period.',
     N'Cancelled occurrences.',
     N'Period = the last N days up to the snapshot date (due date between snapshot date - N + 1 and the snapshot date); status as at the snapshot.',
     N'Attestation occurrence', N'HIGHER', 95.0, 85.0, 10, 90, N'19.8, 5.3, 13.1', 10),
    (N'METADATA_COMPLETENESS', N'Metadata Completeness',
     N'Completed applicable mandatory fields / applicable mandatory fields x 100',
     N'Mandatory fields of each asset that hold a value.',
     N'Fields mandatory for each asset on its asset form -- marked mandatory, or made mandatory by a form rule, and visible -- evaluated on the stored values (the same engine as the asset form save).',
     N'Assets in use (registered, not Draft, not Disposed / Archived, record active) that have an asset form.',
     N'Assets not in use; assets created before asset types (no form); assets whose form makes no field mandatory.',
     N'Stored values as at the snapshot.',
     N'Asset (fields)', N'HIGHER', 95.0, 85.0, 10, NULL, N'19.8, 5.1, 5.2', 20),
    (N'OWNERSHIP_COMPLETENESS', N'Ownership Completeness',
     N'Assets with valid required owner / custodian / applicable active assets x 100',
     N'Assets whose asset owner is an active employee of the organization and whose custodian, when recorded or required, is an active employee or team.',
     N'Assets in use.',
     N'Assets in use (registered, not Draft, not Disposed / Archived, record active).',
     N'Assets not in use. The custodian is required when the asset form marks it mandatory.',
     N'Owner, custodian and employee / team status as at the snapshot.',
     N'Asset', N'HIGHER', 98.0, 90.0, 10, NULL, N'19.8, 5.3.1', 30),
    (N'RELATIONSHIP_COMPLETENESS', N'Relationship Completeness',
     N'In-scope records with required active relationships / records requiring relationships x 100',
     N'Records with at least the required number of Active, currently effective relationships of each required kind.',
     N'Assets whose asset type has a relationship requirement (Settings) and business services in operation (Active, Degraded) when the minimum supporting relationships is above 0.',
     N'Assets in use of an asset type with an active relationship requirement; business services in operation.',
     N'Assets of those types that are not in use; services in Draft, Design, Suspended, Retiring or Retired.',
     N'Relationships Active and effective on the snapshot date (effective from on or before, effective to empty or on / after).',
     N'Asset or business service', N'HIGHER', 90.0, 75.0, 10, NULL, N'19.8, 5.4, 5.5', 40),
    (N'COVERAGE_COMPLIANCE', N'Coverage Compliance',
     N'Assets with valid required coverage / assets requiring coverage x 100',
     N'Assets with a Covered or Expiring line of every coverage type their asset type requires, at least the minimum period long.',
     N'Assets whose asset type has a Required coverage requirement (435).',
     N'Assets in use of an asset type with a Required coverage requirement.',
     N'Assets of those types that are not in use. Business services have no coverage requirement in this application and are not counted.',
     N'Coverage line status (Covered, Expiring, Suspended, Excluded, Expired) on the snapshot date.',
     N'Asset', N'HIGHER', 95.0, 85.0, 10, NULL, N'19.8, 5.2.14, 7.4', 50),
    (N'TECHNOLOGY_SUPPORT', N'Technology Support Compliance',
     N'Supported approved technology or valid exception / technology-applicable assets x 100',
     N'Assets whose firmware and operating system are Current, Due Soon or covered by an approved, unexpired technology exception.',
     N'Assets with at least one technology that applies (the form has the firmware or operating-system field, or a version is recorded).',
     N'Assets in use with an applicable firmware or operating system.',
     N'Assets not in use; assets where neither technology applies. Unknown (no version recorded) and Unsupported fail.',
     N'Release status, compatibility and exceptions on the snapshot date (430 classification).',
     N'Asset', N'HIGHER', 95.0, 85.0, 10, NULL, N'19.8, 4.7, 13.2', 60),
    (N'EXCEPTION_HEALTH', N'Exception Health',
     N'Applicable assets without overdue / expired exceptions / applicable assets x 100',
     N'Assets with no overdue or expired exception.',
     N'Assets in use.',
     N'Assets in use. Failing: an expired technology exception the asset still relies on (still unsupported) or one past its review date; a verification exception past its resolution due date; an activity exception past its review date; a consistency acceptance past its review date or reopened by it; a privacy exception past its expiry, or expired while the gap is still open and not covered again.',
     N'Assets not in use.',
     N'Exception status and dates on the snapshot date.',
     N'Asset', N'HIGHER', 98.0, 90.0, 10, NULL, N'19.8, 4.7, 5.3.7, 7.1.5, 19.7, 5.2.15', 70),
    (N'DISCOVERY_FRESHNESS', N'Discovery Freshness',
     N'Discoverable assets observed within threshold / discoverable active assets x 100',
     N'Discoverable assets with at least one source link observed within that source expected interval x the stale multiplier (discovery settings).',
     N'Assets linked to at least one discovery source.',
     N'Assets in use linked to a discovery source (5.6.4).',
     N'Assets not in use.',
     N'Last observation of each link at the snapshot time (same freshness rule as Data confidence).',
     N'Asset', N'HIGHER', 90.0, 75.0, 10, NULL, N'19.8, 5.6.4', 80),
    (N'RECONCILIATION_BACKLOG', N'Reconciliation Backlog Rate',
     N'Open reconciliation exceptions / observations requiring reconciliation x 100',
     N'Reconciliation exceptions still Open.',
     N'Reconciliation exceptions raised in the period plus those raised earlier and still Open (each exception stands for the observations that required reconciliation; a repeat observation is counted on the same exception).',
     N'Reconciliation exceptions (suggested match, manual review, new candidate, duplicate, conflict) of the organization.',
     N'Exceptions resolved before the period.',
     N'Period = the last N days up to the snapshot time (raised on or after); status at the snapshot. Lower is better.',
     N'Reconciliation exception', N'LOWER', 5.0, 15.0, 10, 30, N'19.8, 5.6.3', 90),
    (N'CONNECTOR_AVAILABILITY', N'Connector Availability',
     N'Successful scheduled runs / scheduled runs x 100',
     N'Expected run intervals of each active source in the period that received a Completed batch.',
     N'Expected run intervals of each active source in the period -- the period (or the time since the source was added, if shorter) divided into whole intervals of the source expected interval.',
     N'Active discovery sources of the organization.',
     N'Inactive sources; sources added less than one expected interval ago. Partial, failed and running batches are not successful runs.',
     N'Period = the last N days up to the snapshot time.',
     N'Discovery source (runs)', N'HIGHER', 98.0, 90.0, 10, 30, N'19.8, 5.6.1, 13.5', 100)
) AS s(kpi_code, kpi_name, formula_text, numerator_text, denominator_text, population_text, exclusions_text, as_of_text,
       record_label, direction, default_target, default_warning, default_weight, default_period_days, brd_reference, display_order)
ON t.kpi_code = s.kpi_code
WHEN MATCHED THEN UPDATE SET
    kpi_name = s.kpi_name, formula_text = s.formula_text, numerator_text = s.numerator_text, denominator_text = s.denominator_text,
    population_text = s.population_text, exclusions_text = s.exclusions_text, as_of_text = s.as_of_text, record_label = s.record_label,
    direction = s.direction, default_target = s.default_target, default_warning = s.default_warning, default_weight = s.default_weight,
    default_period_days = s.default_period_days, brd_reference = s.brd_reference, display_order = s.display_order
WHEN NOT MATCHED BY TARGET THEN
    INSERT (kpi_code, kpi_name, formula_text, numerator_text, denominator_text, population_text, exclusions_text, as_of_text,
            record_label, direction, default_target, default_warning, default_weight, default_period_days, brd_reference,
            display_order, entered_by)
    VALUES (s.kpi_code, s.kpi_name, s.formula_text, s.numerator_text, s.denominator_text, s.population_text, s.exclusions_text,
            s.as_of_text, s.record_label, s.direction, s.default_target, s.default_warning, s.default_weight,
            s.default_period_days, s.brd_reference, s.display_order, N'seed-450');
PRINT CONCAT('450: KPI catalogue rows merged: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 2. Organization settings
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_governance_setting','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_governance_setting (
        organization_id BIGINT        NOT NULL
            CONSTRAINT fk_pm_agov_set_org REFERENCES grac_practice.organization(organization_id),
        kpi_code        NVARCHAR(30)  NOT NULL
            CONSTRAINT fk_pm_agov_set_kpi REFERENCES grac_practice.asset_governance_kpi(kpi_code),
        is_enabled      BIT           NOT NULL,
        weight          INT           NOT NULL CONSTRAINT ck_pm_agov_set_w CHECK (weight BETWEEN 0 AND 100),
        target_value    DECIMAL(5, 1) NOT NULL CONSTRAINT ck_pm_agov_set_t CHECK (target_value BETWEEN 0 AND 100),
        warning_value   DECIMAL(5, 1) NOT NULL CONSTRAINT ck_pm_agov_set_wv CHECK (warning_value BETWEEN 0 AND 100),
        period_days     INT           NULL CONSTRAINT ck_pm_agov_set_p CHECK (period_days IS NULL OR period_days BETWEEN 1 AND 3650),
        entered_by      NVARCHAR(100) NOT NULL,
        entered_dt      DATETIME2     NOT NULL CONSTRAINT df_pm_agov_set_edt DEFAULT SYSUTCDATETIME(),
        updated_by      NVARCHAR(100) NULL,
        updated_dt      DATETIME2     NULL,
        CONSTRAINT pk_pm_agov_set PRIMARY KEY (organization_id, kpi_code)
    );
    PRINT '450: asset_governance_setting created.';
END
GO

IF OBJECT_ID('grac_practice.asset_governance_org_setting','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_governance_org_setting (
        organization_id       BIGINT        NOT NULL CONSTRAINT pk_pm_agov_org PRIMARY KEY
            CONSTRAINT fk_pm_agov_org_org REFERENCES grac_practice.organization(organization_id),
        overall_target        DECIMAL(5, 1) NOT NULL CONSTRAINT ck_pm_agov_org_t CHECK (overall_target BETWEEN 0 AND 100),
        overall_warning       DECIMAL(5, 1) NOT NULL CONSTRAINT ck_pm_agov_org_w CHECK (overall_warning BETWEEN 0 AND 100),
        item_retention_days   INT           NOT NULL CONSTRAINT ck_pm_agov_org_ret CHECK (item_retention_days BETWEEN 7 AND 3650),
        entered_by            NVARCHAR(100) NOT NULL,
        entered_dt            DATETIME2     NOT NULL CONSTRAINT df_pm_agov_org_edt DEFAULT SYSUTCDATETIME(),
        updated_by            NVARCHAR(100) NULL,
        updated_dt            DATETIME2     NULL,
        CONSTRAINT ck_pm_agov_org_tw CHECK (overall_warning <= overall_target)
    );
    PRINT '450: asset_governance_org_setting created.';
END
GO

-- Relationships an asset type requires (Relationship Completeness).
IF OBJECT_ID('grac_practice.asset_governance_relationship_rule','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_governance_relationship_rule (
        rule_id                BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_agov_rel PRIMARY KEY,
        organization_id        BIGINT        NOT NULL
            CONSTRAINT fk_pm_agov_rel_org REFERENCES grac_practice.organization(organization_id),
        asset_type_id          INT           NOT NULL
            CONSTRAINT fk_pm_agov_rel_type REFERENCES grac_practice.dependency_asset_type_master(asset_type_id),
        relationship_type_code NVARCHAR(30)  NOT NULL
            CONSTRAINT fk_pm_agov_rel_rtype REFERENCES grac_practice.asset_relationship_type(type_code),
        asset_side             NVARCHAR(6)   NOT NULL     -- the asset is the SOURCE or the TARGET of the relationship
            CONSTRAINT ck_pm_agov_rel_side CHECK (asset_side IN (N'SOURCE', N'TARGET')),
        min_count              INT           NOT NULL CONSTRAINT ck_pm_agov_rel_min CHECK (min_count BETWEEN 1 AND 50),
        is_active              BIT           NOT NULL,
        entered_by             NVARCHAR(100) NOT NULL,
        entered_dt             DATETIME2     NOT NULL CONSTRAINT df_pm_agov_rel_edt DEFAULT SYSUTCDATETIME(),
        updated_by             NVARCHAR(100) NULL,
        updated_dt             DATETIME2     NULL,
        CONSTRAINT uq_pm_agov_rel UNIQUE (organization_id, asset_type_id, relationship_type_code, asset_side)
    );
    PRINT '450: asset_governance_relationship_rule created.';
END
GO

-- =====================================================================
-- 3. Snapshots (append-only; a superseded snapshot is kept)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_governance_snapshot','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_governance_snapshot (
        snapshot_id     BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_agov_snap PRIMARY KEY,
        organization_id BIGINT        NOT NULL
            CONSTRAINT fk_pm_agov_snap_org REFERENCES grac_practice.organization(organization_id),
        as_of_date      DATE          NOT NULL,
        version_no      INT           NOT NULL,      -- 1, 2, ... per organization and date
        is_current      BIT           NOT NULL,
        source_code     NVARCHAR(10)  NOT NULL
            CONSTRAINT ck_pm_agov_snap_src CHECK (source_code IN (N'SCHEDULER', N'MANUAL')),
        overall_score   DECIMAL(5, 1) NULL,
        overall_rag     NVARCHAR(6)   NOT NULL
            CONSTRAINT ck_pm_agov_snap_rag CHECK (overall_rag IN (N'GREEN', N'AMBER', N'RED', N'NA')),
        overall_target  DECIMAL(5, 1) NOT NULL,
        overall_warning DECIMAL(5, 1) NOT NULL,
        item_count      INT           NOT NULL,
        items_purged    BIT           NOT NULL CONSTRAINT df_pm_agov_snap_purged DEFAULT 0,
        taken_by        NVARCHAR(100) NOT NULL,
        taken_dt        DATETIME2     NOT NULL CONSTRAINT df_pm_agov_snap_tdt DEFAULT SYSUTCDATETIME(),
        superseded_dt   DATETIME2     NULL,
        CONSTRAINT uq_pm_agov_snap_ver UNIQUE (organization_id, as_of_date, version_no)
    );
    CREATE UNIQUE INDEX ux_pm_agov_snap_current ON grac_practice.asset_governance_snapshot(organization_id, as_of_date) WHERE is_current = 1;
    PRINT '450: asset_governance_snapshot created.';
END
GO

IF OBJECT_ID('grac_practice.asset_governance_snapshot_kpi','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_governance_snapshot_kpi (
        snapshot_id    BIGINT        NOT NULL
            CONSTRAINT fk_pm_agov_skpi_snap REFERENCES grac_practice.asset_governance_snapshot(snapshot_id),
        kpi_code       NVARCHAR(30)  NOT NULL,
        is_enabled     BIT           NOT NULL,
        numerator      INT           NOT NULL,
        denominator    INT           NOT NULL,
        excluded_count INT           NOT NULL,
        failing_count  INT           NOT NULL,
        score          DECIMAL(5, 1) NULL,          -- NULL: zero denominator (not applicable) or disabled
        rag            NVARCHAR(6)   NOT NULL
            CONSTRAINT ck_pm_agov_skpi_rag CHECK (rag IN (N'GREEN', N'AMBER', N'RED', N'NA')),
        direction      NVARCHAR(6)   NOT NULL,
        target_value   DECIMAL(5, 1) NOT NULL,
        warning_value  DECIMAL(5, 1) NOT NULL,
        weight         INT           NOT NULL,
        period_days    INT           NULL,
        CONSTRAINT pk_pm_agov_skpi PRIMARY KEY (snapshot_id, kpi_code)
    );
    PRINT '450: asset_governance_snapshot_kpi created.';
END
GO

IF OBJECT_ID('grac_practice.asset_governance_snapshot_item','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_governance_snapshot_item (
        snapshot_id BIGINT         NOT NULL
            CONSTRAINT fk_pm_agov_sitem_snap REFERENCES grac_practice.asset_governance_snapshot(snapshot_id),
        kpi_code    NVARCHAR(30)   NOT NULL,
        record_kind NVARCHAR(16)   NOT NULL,
        record_id   BIGINT         NOT NULL,
        record_name NVARCHAR(400)  NULL,
        outcome     NVARCHAR(8)    NOT NULL
            CONSTRAINT ck_pm_agov_sitem_out CHECK (outcome IN (N'PASS', N'FAIL', N'EXCLUDED')),
        numerator   INT            NOT NULL,
        denominator INT            NOT NULL,
        reason      NVARCHAR(1000) NULL,
        CONSTRAINT pk_pm_agov_sitem PRIMARY KEY (snapshot_id, kpi_code, record_kind, record_id)
    );
    CREATE INDEX ix_pm_agov_sitem_out ON grac_practice.asset_governance_snapshot_item(snapshot_id, kpi_code, outcome);
    PRINT '450: asset_governance_snapshot_item created.';
END
GO

-- =====================================================================
-- 4. Effective settings, population and the record rows of each KPI
-- =====================================================================
-- Effective setting per KPI: the organization row, else the catalogue
-- default. A KPI without a period keeps PeriodDays NULL.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_governance_effective (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT k.kpi_code AS KpiCode, k.kpi_name AS KpiName, k.direction AS Direction, k.display_order AS DisplayOrder,
           CAST(ISNULL(s.is_enabled, 1) AS BIT) AS IsEnabled, ISNULL(s.weight, k.default_weight) AS Weight,
           ISNULL(s.target_value, k.default_target) AS TargetValue, ISNULL(s.warning_value, k.default_warning) AS WarningValue,
           CASE WHEN k.default_period_days IS NULL THEN NULL ELSE ISNULL(s.period_days, k.default_period_days) END AS PeriodDays,
           CAST(CASE WHEN s.kpi_code IS NULL THEN 0 ELSE 1 END AS BIT) AS IsCustomised
      FROM grac_practice.asset_governance_kpi k
      LEFT JOIN grac_practice.asset_governance_setting s ON s.organization_id = @organization_id AND s.kpi_code = k.kpi_code;
GO

-- Assets of the organization and whether they are in use (D169): record
-- active, lifecycle status not Draft / Disposed / Archived. ExclusionReason
-- is NULL for an asset in use.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_governance_assets (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT a.asset_id AS AssetId, CAST(a.asset_name AS NVARCHAR(400)) AS AssetName, a.asset_type_id AS AssetTypeId,
           a.template_id AS TemplateId, a.owner_id AS OwnerId, ISNULL(s.status_code, N'ACTIVE') AS StatusCode,
           CAST(CASE WHEN ISNULL(a.status, N'Active') <> N'Active' THEN N'Not in use: the record is inactive (merged or deactivated).'
                     WHEN s.status_code = N'DRAFT' THEN N'Not in use: Draft.'
                     WHEN s.status_code IN (N'DISPOSED', N'ARCHIVED') THEN CONCAT(N'Not in use: ', s.status_name, N'.')
                END AS NVARCHAR(200)) AS ExclusionReason
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
     WHERE a.organization_id = @organization_id;
GO

-- One row per record of a KPI (@kpi_code NULL = every KPI): PASS / FAIL /
-- EXCLUDED, its numerator and denominator contribution and the reason.
-- The score of a KPI is SUM(Numerator) / SUM(Denominator) x 100 over the
-- rows that are not EXCLUDED (D170). Each branch reads the records its
-- module keeps; see asset_governance_kpi for the definitions.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_governance_items (@organization_id BIGINT, @kpi_code NVARCHAR(30))
RETURNS TABLE
AS
RETURN
    -- 1. Attestation Compliance (431 / 432): occurrences due in the period.
    SELECT CAST(N'ATTESTATION_COMPLIANCE' AS NVARCHAR(30)) AS KpiCode, CAST(N'ATTESTATION' AS NVARCHAR(16)) AS RecordKind,
           t.attestation_id AS RecordId,
           CAST(CONCAT(a.asset_name, N' - ', LOWER(t.attestation_type), N' attestation due ', CONVERT(NVARCHAR(10), t.due_date, 23)) AS NVARCHAR(400)) AS RecordName,
           CAST(o.outcome AS NVARCHAR(8)) AS Outcome,
           CASE WHEN o.outcome = N'PASS' THEN 1 ELSE 0 END AS Numerator,
           CASE WHEN o.outcome = N'EXCLUDED' THEN 0 ELSE 1 END AS Denominator,
           CAST(CASE o.outcome
                WHEN N'EXCLUDED' THEN N'Cancelled.'
                WHEN N'FAIL' THEN CONCAT(N'Not confirmed: ',
                     CASE t.status WHEN N'GENERATED' THEN N'generated' WHEN N'PENDING' THEN N'pending' WHEN N'IN_PROGRESS' THEN N'in progress'
                                   WHEN N'DISPUTED' THEN N'disputed' WHEN N'OVERDUE' THEN N'overdue' WHEN N'ESCALATED' THEN N'escalated'
                                   WHEN N'EXCEPTION' THEN N'verification exception open' ELSE LOWER(t.status) END,
                     CASE WHEN t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS') AND t.due_date < CAST(SYSUTCDATETIME() AS DATE)
                          THEN N' (past its due date)' ELSE N'' END, N'.')
                END AS NVARCHAR(1000)) AS Reason
      FROM grac_practice.asset_attestation t
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = t.asset_id
     CROSS APPLY (SELECT e.PeriodDays AS p FROM grac_practice.fn_asset_governance_effective(@organization_id) e
                   WHERE e.KpiCode = N'ATTESTATION_COMPLIANCE') pd
     CROSS APPLY (SELECT CASE WHEN t.status = N'CANCELLED' THEN N'EXCLUDED'
                              WHEN t.status IN (N'CONFIRMED', N'CLOSED', N'RESOLVED') THEN N'PASS'
                              ELSE N'FAIL' END AS outcome) o
     WHERE (@kpi_code IS NULL OR @kpi_code = N'ATTESTATION_COMPLIANCE')
       AND t.organization_id = @organization_id
       AND t.due_date BETWEEN DATEADD(DAY, 1 - pd.p, CAST(SYSUTCDATETIME() AS DATE)) AND CAST(SYSUTCDATETIME() AS DATE)

    UNION ALL
    -- 2. Metadata Completeness (421 / 428): the form engine on the stored values.
    SELECT N'METADATA_COMPLETENESS', N'ASSET', p.AssetId, p.AssetName, o.outcome,
           CASE WHEN o.outcome = N'EXCLUDED' THEN 0 ELSE ev.done END,
           CASE WHEN o.outcome = N'EXCLUDED' THEN 0 ELSE ev.mand END,
           CAST(CASE WHEN p.ExclusionReason IS NOT NULL THEN p.ExclusionReason
                     WHEN p.TemplateId IS NULL THEN N'No asset form: created before asset types.'
                     WHEN ISNULL(ev.mand, 0) = 0 THEN N'Its asset form makes no field mandatory.'
                     WHEN o.outcome = N'FAIL' THEN CONCAT(ev.mand - ev.done, N' of ', ev.mand, N' mandatory fields empty: ', ev.missing, N'.')
                END AS NVARCHAR(1000))
      FROM grac_practice.fn_asset_governance_assets(@organization_id) p
     OUTER APPLY (SELECT CONCAT(N'{', STRING_AGG(CAST(CONCAT(N'"', STRING_ESCAPE(v.FieldKey, 'json'), N'":',
                                          CASE WHEN LEFT(LTRIM(v.Value), 1) = N'[' AND ISJSON(v.Value) = 1 THEN v.Value
                                               ELSE CONCAT(N'"', STRING_ESCAPE(v.Value, 'json'), N'"') END) AS NVARCHAR(MAX)), N','), N'}') AS j
                    FROM grac_practice.fn_asset_stored_values(p.AssetId) v
                   WHERE p.ExclusionReason IS NULL AND p.TemplateId IS NOT NULL
                     AND NULLIF(NULLIF(LTRIM(RTRIM(v.Value)), N''), N'[]') IS NOT NULL) sv
     OUTER APPLY (SELECT SUM(e.IsMandatory) AS mand,
                         SUM(CASE WHEN e.IsMandatory = 1 AND e.ValueSupplied = 1 THEN 1 ELSE 0 END) AS done,
                         STRING_AGG(CASE WHEN e.IsMandatory = 1 AND e.ValueSupplied = 0 THEN CAST(e.DisplayLabel AS NVARCHAR(MAX)) END, N', ')
                             WITHIN GROUP (ORDER BY e.SectionOrder, e.FieldOrder) AS missing
                    FROM grac_practice.fn_asset_form_evaluate(p.TemplateId, ISNULL(sv.j, N'{}')) e
                   WHERE p.ExclusionReason IS NULL AND p.TemplateId IS NOT NULL) ev
     CROSS APPLY (SELECT CASE WHEN p.ExclusionReason IS NOT NULL OR p.TemplateId IS NULL OR ISNULL(ev.mand, 0) = 0 THEN N'EXCLUDED'
                              WHEN ev.done = ev.mand THEN N'PASS' ELSE N'FAIL' END AS outcome) o
     WHERE (@kpi_code IS NULL OR @kpi_code = N'METADATA_COMPLETENESS')

    UNION ALL
    -- 3. Ownership Completeness (428 owner, 431 custodian).
    SELECT N'OWNERSHIP_COMPLETENESS', N'ASSET', p.AssetId, p.AssetName, o.outcome,
           CASE WHEN o.outcome = N'PASS' THEN 1 ELSE 0 END,
           CASE WHEN o.outcome = N'EXCLUDED' THEN 0 ELSE 1 END,
           CAST(CASE WHEN p.ExclusionReason IS NOT NULL THEN p.ExclusionReason
                     WHEN o.outcome = N'FAIL' THEN CONCAT_WS(N' ', x.owner_issue, x.cust_issue) END AS NVARCHAR(1000))
      FROM grac_practice.fn_asset_governance_assets(@organization_id) p
     OUTER APPLY (SELECT TOP (1) NULLIF(LTRIM(RTRIM(v.value_text)), N'') AS cust
                    FROM grac_practice.asset_field_value v
                    JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'custodian'
                   WHERE v.asset_id = p.AssetId) c
     CROSS APPLY (SELECT
            CASE WHEN p.OwnerId IS NULL THEN N'No asset owner.'
                 WHEN NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                                   WHERE e.employee_id = p.OwnerId AND e.organization_id = @organization_id AND e.status = N'Active')
                      THEN N'The asset owner is not an active employee of the organization.' END AS owner_issue,
            CASE WHEN c.cust IS NULL
                      THEN CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field f
                                               JOIN grac_practice.asset_field_definition d
                                                 ON d.field_definition_id = f.field_definition_id AND d.field_key = N'custodian'
                                              WHERE f.template_id = p.TemplateId AND f.is_mandatory = 1)
                                THEN N'No custodian (the asset form requires one).' END
                 WHEN c.cust LIKE N'E:%' AND EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                                                      WHERE e.employee_id = TRY_CONVERT(BIGINT, SUBSTRING(c.cust, 3, 38))
                                                        AND e.organization_id = @organization_id AND e.status = N'Active') THEN NULL
                 WHEN c.cust LIKE N'T:%' AND EXISTS (SELECT 1 FROM grac_practice.organization_team tm
                                                      WHERE tm.team_id = TRY_CONVERT(BIGINT, SUBSTRING(c.cust, 3, 38))
                                                        AND tm.organization_id = @organization_id AND tm.status = N'Active') THEN NULL
                 ELSE N'The custodian is not an active employee or team of the organization.' END AS cust_issue) x
     CROSS APPLY (SELECT CASE WHEN p.ExclusionReason IS NOT NULL THEN N'EXCLUDED'
                              WHEN x.owner_issue IS NULL AND x.cust_issue IS NULL THEN N'PASS' ELSE N'FAIL' END AS outcome) o
     WHERE (@kpi_code IS NULL OR @kpi_code = N'OWNERSHIP_COMPLETENESS')

    UNION ALL
    -- 4a. Relationship Completeness -- assets of a type with a requirement (440).
    SELECT N'RELATIONSHIP_COMPLETENESS', N'ASSET', p.AssetId, p.AssetName, o.outcome,
           CASE WHEN o.outcome = N'PASS' THEN 1 ELSE 0 END,
           CASE WHEN o.outcome = N'EXCLUDED' THEN 0 ELSE 1 END,
           CAST(CASE WHEN p.ExclusionReason IS NOT NULL THEN p.ExclusionReason
                     WHEN o.outcome = N'FAIL' THEN CONCAT(q.unmet, N'.') END AS NVARCHAR(1000))
      FROM grac_practice.fn_asset_governance_assets(@organization_id) p
     CROSS APPLY (SELECT COUNT(*) AS rules, SUM(m.ok) AS met,
                         STRING_AGG(CASE WHEN m.ok = 0 THEN CAST(CONCAT(N'Needs ', r.min_count, N' active "',
                                         CASE r.asset_side WHEN N'SOURCE' THEN rt.type_name ELSE rt.inverse_label END,
                                         N'" relationship(s), has ', c.n) AS NVARCHAR(MAX)) END, N'; ') AS unmet
                    FROM grac_practice.asset_governance_relationship_rule r
                    JOIN grac_practice.asset_relationship_type rt ON rt.type_code = r.relationship_type_code
                   CROSS APPLY (SELECT COUNT(*) AS n
                                  FROM grac_practice.asset_relationship x
                                 WHERE x.organization_id = @organization_id AND x.relationship_type_code = r.relationship_type_code
                                   AND x.status = N'ACTIVE' AND x.effective_from <= CAST(SYSUTCDATETIME() AS DATE)
                                   AND (x.effective_to IS NULL OR x.effective_to >= CAST(SYSUTCDATETIME() AS DATE))
                                   AND ((r.asset_side = N'SOURCE' AND x.source_kind = N'ASSET' AND x.source_id = p.AssetId)
                                        OR (r.asset_side = N'TARGET' AND x.target_kind = N'ASSET' AND x.target_id = p.AssetId))) c
                   CROSS APPLY (SELECT CASE WHEN c.n >= r.min_count THEN 1 ELSE 0 END AS ok) m
                   WHERE r.organization_id = @organization_id AND r.is_active = 1 AND r.asset_type_id = p.AssetTypeId) q
     CROSS APPLY (SELECT CASE WHEN p.ExclusionReason IS NOT NULL THEN N'EXCLUDED'
                              WHEN q.met = q.rules THEN N'PASS' ELSE N'FAIL' END AS outcome) o
     WHERE (@kpi_code IS NULL OR @kpi_code = N'RELATIONSHIP_COMPLETENESS') AND q.rules > 0

    UNION ALL
    -- 4b. Relationship Completeness -- business services in operation (441 minimum supporting relationships).
    SELECT N'RELATIONSHIP_COMPLETENESS', N'SERVICE', b.service_id, CAST(CONCAT(b.service_code, N' - ', b.service_name) AS NVARCHAR(400)),
           o.outcome,
           CASE WHEN o.outcome = N'PASS' THEN 1 ELSE 0 END,
           CASE WHEN o.outcome = N'EXCLUDED' THEN 0 ELSE 1 END,
           CAST(CASE o.outcome
                WHEN N'EXCLUDED' THEN CONCAT(N'Service not in operation (', LOWER(b.status), N').')
                WHEN N'FAIL' THEN CONCAT(N'Needs ', st.mn, N' active "Is supported by" relationship(s), has ', c.n, N'.') END AS NVARCHAR(1000))
      FROM grac_practice.business_service b
     CROSS APPLY (SELECT ISNULL((SELECT bs.min_supporting_relationships FROM grac_practice.business_service_setting bs
                                  WHERE bs.organization_id = @organization_id), 1) AS mn) st
     CROSS APPLY (SELECT COUNT(*) AS n
                    FROM grac_practice.asset_relationship x
                   WHERE x.organization_id = @organization_id AND x.relationship_type_code = N'SUPPORTS_SERVICE'
                     AND x.target_kind = N'SERVICE' AND x.target_id = b.service_id AND x.status = N'ACTIVE'
                     AND x.effective_from <= CAST(SYSUTCDATETIME() AS DATE)
                     AND (x.effective_to IS NULL OR x.effective_to >= CAST(SYSUTCDATETIME() AS DATE))) c
     CROSS APPLY (SELECT CASE WHEN b.status NOT IN (N'ACTIVE', N'DEGRADED') THEN N'EXCLUDED'
                              WHEN c.n >= st.mn THEN N'PASS' ELSE N'FAIL' END AS outcome) o
     WHERE (@kpi_code IS NULL OR @kpi_code = N'RELATIONSHIP_COMPLETENESS')
       AND b.organization_id = @organization_id AND st.mn > 0

    UNION ALL
    -- 5. Coverage Compliance (435): assets of a type with a Required coverage requirement.
    SELECT N'COVERAGE_COMPLIANCE', N'ASSET', p.AssetId, p.AssetName, o.outcome,
           CASE WHEN o.outcome = N'PASS' THEN 1 ELSE 0 END,
           CASE WHEN o.outcome = N'EXCLUDED' THEN 0 ELSE 1 END,
           CAST(CASE WHEN p.ExclusionReason IS NOT NULL THEN p.ExclusionReason
                     WHEN o.outcome = N'FAIL' THEN g.msg END AS NVARCHAR(1000))
      FROM grac_practice.fn_asset_governance_assets(@organization_id) p
     CROSS APPLY (SELECT COUNT(*) AS req FROM grac_practice.asset_coverage_requirement r
                   WHERE r.organization_id = @organization_id AND r.asset_type_id = p.AssetTypeId AND r.requirement_level = N'REQUIRED') q
      LEFT JOIN (SELECT cg.AssetId, COUNT(*) AS gaps, STRING_AGG(CAST(cg.Message AS NVARCHAR(MAX)), N' ') AS msg
                   FROM grac_practice.fn_asset_coverage_gaps(@organization_id) cg
                  GROUP BY cg.AssetId) g ON g.AssetId = p.AssetId
     CROSS APPLY (SELECT CASE WHEN p.ExclusionReason IS NOT NULL THEN N'EXCLUDED'
                              WHEN ISNULL(g.gaps, 0) = 0 THEN N'PASS' ELSE N'FAIL' END AS outcome) o
     WHERE (@kpi_code IS NULL OR @kpi_code = N'COVERAGE_COMPLIANCE') AND q.req > 0

    UNION ALL
    -- 6. Technology Support Compliance (430 classification).
    SELECT N'TECHNOLOGY_SUPPORT', N'ASSET', p.AssetId, p.AssetName, o.outcome,
           CASE WHEN o.outcome = N'PASS' THEN 1 ELSE 0 END,
           CASE WHEN o.outcome = N'EXCLUDED' THEN 0 ELSE 1 END,
           CAST(CASE WHEN p.ExclusionReason IS NOT NULL THEN p.ExclusionReason
                     WHEN o.outcome = N'FAIL' THEN t.why END AS NVARCHAR(1000))
      FROM grac_practice.fn_asset_governance_assets(@organization_id) p
      JOIN (SELECT ts.AssetId,
                   SUM(CASE WHEN ts.Classification <> N'NOT_APPLICABLE' THEN 1 ELSE 0 END) AS app,
                   SUM(CASE WHEN ts.Classification IN (N'UNSUPPORTED', N'UNKNOWN') THEN 1 ELSE 0 END) AS bad,
                   STRING_AGG(CASE WHEN ts.Classification IN (N'UNSUPPORTED', N'UNKNOWN')
                                   THEN CAST(CONCAT(CASE ts.Kind WHEN N'FIRMWARE' THEN N'Firmware' ELSE N'Operating system' END,
                                                    CASE ts.Classification WHEN N'UNKNOWN' THEN N' unknown: ' ELSE N' unsupported: ' END,
                                                    ISNULL(ts.CurrentLabel + N' - ', N''), ts.ClassificationReason) AS NVARCHAR(MAX)) END, N' ') AS why
              FROM grac_practice.fn_asset_technology_status(@organization_id, NULL) ts
             GROUP BY ts.AssetId) t ON t.AssetId = p.AssetId
     CROSS APPLY (SELECT CASE WHEN p.ExclusionReason IS NOT NULL THEN N'EXCLUDED'
                              WHEN t.bad = 0 THEN N'PASS' ELSE N'FAIL' END AS outcome) o
     WHERE (@kpi_code IS NULL OR @kpi_code = N'TECHNOLOGY_SUPPORT') AND t.app > 0

    UNION ALL
    -- 7. Exception Health (430, 432, 439, 447, 448): overdue or expired exceptions.
    SELECT N'EXCEPTION_HEALTH', N'ASSET', p.AssetId, p.AssetName, o.outcome,
           CASE WHEN o.outcome = N'PASS' THEN 1 ELSE 0 END,
           CASE WHEN o.outcome = N'EXCLUDED' THEN 0 ELSE 1 END,
           CAST(CASE WHEN p.ExclusionReason IS NOT NULL THEN p.ExclusionReason
                     WHEN o.outcome = N'FAIL' THEN ex.msg END AS NVARCHAR(1000))
      FROM grac_practice.fn_asset_governance_assets(@organization_id) p
      LEFT JOIN (SELECT f.asset_id, COUNT(*) AS n, STRING_AGG(f.msg, N' ') AS msg
                   FROM (
                        -- technology: expired and still relied on, or in use and past its review date
                        SELECT ts.AssetId AS asset_id,
                               CAST(CONCAT(N'Technology exception #', e.exception_id, N' (',
                                           CASE ts.Kind WHEN N'FIRMWARE' THEN N'firmware' ELSE N'operating system' END, N') ',
                                           CASE WHEN ts.Classification = N'UNSUPPORTED'
                                                THEN CONCAT(N'expired on ', CONVERT(NVARCHAR(10), e.expiry_date, 23), N' and the version is still unsupported.')
                                                ELSE CONCAT(N'was due for review on ', CONVERT(NVARCHAR(10), e.review_date, 23), N'.') END) AS NVARCHAR(MAX)) AS msg
                          FROM grac_practice.fn_asset_technology_status(@organization_id, NULL) ts
                          JOIN grac_practice.asset_technology_exception e
                            ON e.organization_id = @organization_id AND e.technology_kind = ts.Kind AND e.status = N'APPROVED'
                           AND ((ts.Kind = N'FIRMWARE' AND e.firmware_release_id = ts.CurrentReleaseId)
                                OR (ts.Kind = N'OS' AND e.os_release_id = ts.CurrentReleaseId))
                           AND (e.asset_id = ts.AssetId OR (e.asset_id IS NULL AND e.model_id = ts.ModelId))
                         WHERE (ts.Classification = N'UNSUPPORTED' AND e.expiry_date < CAST(SYSUTCDATETIME() AS DATE))
                            OR (e.exception_id = ts.ExceptionId AND e.review_date < CAST(SYSUTCDATETIME() AS DATE))
                        UNION ALL
                        -- verification exception past its resolution due date (432 overdue rule)
                        SELECT x.asset_id,
                               CAST(CONCAT(N'Verification exception #', x.exception_id, N' was due for resolution on ',
                                           CONVERT(NVARCHAR(10), x.resolution_due, 23), N'.') AS NVARCHAR(MAX))
                          FROM grac_practice.asset_verification_exception x
                          JOIN grac_practice.entity_status_master s ON s.entity_status_id = x.current_status_id
                         WHERE x.organization_id = @organization_id AND s.is_terminal = 0
                           AND s.status_code NOT IN (N'RESOLVED', N'AWAITING_EVIDENCE')
                           AND x.resolution_due < CAST(SYSUTCDATETIME() AS DATE)
                        UNION ALL
                        -- approved activity exception past its review date (439), not replaced by a later decision
                        SELECT ao.asset_id,
                               CAST(CONCAT(N'Activity exception #', d.disposition_id, N' was due for review on ',
                                           CONVERT(NVARCHAR(10), d.review_date, 23), N'.') AS NVARCHAR(MAX))
                          FROM grac_practice.asset_activity_disposition d
                          JOIN grac_practice.asset_activity_occurrence ao ON ao.occurrence_id = d.occurrence_id
                         WHERE d.organization_id = @organization_id AND d.disposition_type = N'EXCEPTION' AND d.status = N'APPROVED'
                           AND d.review_date < CAST(SYSUTCDATETIME() AS DATE)
                           AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_disposition d2
                                            WHERE d2.occurrence_id = d.occurrence_id AND d2.disposition_id > d.disposition_id
                                              AND d2.status = N'APPROVED')
                        UNION ALL
                        -- consistency acceptance past its review date, or reopened by it and not accepted again (447)
                        SELECT cf.asset_id,
                               CAST(CONCAT(N'Consistency finding #', cf.finding_id,
                                           CASE WHEN cf.status = N'ACCEPTED'
                                                THEN CONCAT(N' acceptance passed its review date ', CONVERT(NVARCHAR(10), cf.review_date, 23), N'.')
                                                ELSE N' was accepted, passed its review date and is open again.' END) AS NVARCHAR(MAX))
                          FROM grac_practice.asset_consistency_finding cf
                         WHERE cf.organization_id = @organization_id
                           AND ((cf.status = N'ACCEPTED' AND cf.review_date < CAST(SYSUTCDATETIME() AS DATE))
                                OR (cf.status = N'OPEN' AND cf.reopened_count > 0))
                        UNION ALL
                        -- privacy exception past its expiry, or expired while the gap is still open (448)
                        SELECT px.asset_id,
                               CAST(CONCAT(N'Privacy exception #', px.exception_id, N' (', rq.requirement_name, N') ',
                                           CASE WHEN px.status = N'APPROVED'
                                                THEN CONCAT(N'passed its expiry date ', CONVERT(NVARCHAR(10), px.expiry_date, 23), N'.')
                                                ELSE N'expired and the gap is still open.' END) AS NVARCHAR(MAX))
                          FROM grac_practice.asset_privacy_exception px
                          JOIN grac_practice.asset_privacy_requirement rq ON rq.requirement_code = px.requirement_code
                         WHERE px.organization_id = @organization_id
                           AND ((px.status = N'APPROVED' AND px.expiry_date < CAST(SYSUTCDATETIME() AS DATE))
                                OR (px.status = N'EXPIRED'
                                    AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_privacy_exception py
                                                     WHERE py.asset_id = px.asset_id AND py.requirement_code = px.requirement_code
                                                       AND py.exception_id > px.exception_id
                                                       AND py.status IN (N'PENDING_APPROVAL', N'APPROVED', N'EXPIRED'))
                                    AND EXISTS (SELECT 1 FROM grac_practice.fn_asset_privacy_gaps(@organization_id, px.asset_id) pg
                                                 WHERE pg.RequirementCode = px.requirement_code AND pg.IsExcepted = 0)))
                        ) f
                  GROUP BY f.asset_id) ex ON ex.asset_id = p.AssetId
     CROSS APPLY (SELECT CASE WHEN p.ExclusionReason IS NOT NULL THEN N'EXCLUDED'
                              WHEN ISNULL(ex.n, 0) = 0 THEN N'PASS' ELSE N'FAIL' END AS outcome) o
     WHERE (@kpi_code IS NULL OR @kpi_code = N'EXCEPTION_HEALTH')

    UNION ALL
    -- 8. Discovery Freshness (442 / 443 freshness rule): assets linked to a source.
    SELECT N'DISCOVERY_FRESHNESS', N'ASSET', p.AssetId, p.AssetName, o.outcome,
           CASE WHEN o.outcome = N'PASS' THEN 1 ELSE 0 END,
           CASE WHEN o.outcome = N'EXCLUDED' THEN 0 ELSE 1 END,
           CAST(CASE WHEN p.ExclusionReason IS NOT NULL THEN p.ExclusionReason
                     WHEN o.outcome = N'FAIL' THEN CONCAT(N'No source observed it within its expected interval x ', st.sm,
                                                          N'; last observed ', CONVERT(NVARCHAR(16), l.last_seen, 120), N' UTC.') END AS NVARCHAR(1000))
      FROM grac_practice.fn_asset_governance_assets(@organization_id) p
     CROSS APPLY (SELECT ISNULL((SELECT MAX(x.stale_multiplier) FROM grac_practice.asset_discovery_setting x
                                  WHERE x.organization_id = @organization_id), 3) AS sm) st
     -- the freshness flag is computed per link first (Msg 8124, as 442 / 443).
     CROSS APPLY (SELECT COUNT(*) AS links, MAX(k.last_seen_dt) AS last_seen, SUM(fr.is_fresh) AS fresh
                    FROM grac_practice.asset_discovery_link k
                    JOIN grac_practice.asset_discovery_source src ON src.source_id = k.source_id
                   CROSS APPLY (SELECT CASE WHEN k.last_seen_dt >= DATEADD(HOUR, -src.expected_interval_hours * st.sm, SYSUTCDATETIME())
                                            THEN 1 ELSE 0 END AS is_fresh) fr
                   WHERE k.asset_id = p.AssetId) l
     CROSS APPLY (SELECT CASE WHEN p.ExclusionReason IS NOT NULL THEN N'EXCLUDED'
                              WHEN ISNULL(l.fresh, 0) > 0 THEN N'PASS' ELSE N'FAIL' END AS outcome) o
     WHERE (@kpi_code IS NULL OR @kpi_code = N'DISCOVERY_FRESHNESS') AND l.links > 0

    UNION ALL
    -- 9. Reconciliation Backlog Rate (442): raised in the period, or still open. Lower is better.
    SELECT N'RECONCILIATION_BACKLOG', N'RECONCILIATION', e.exception_id,
           CAST(CONCAT(CASE e.exception_kind WHEN N'SUGGESTED_MATCH' THEN N'Suggested match' WHEN N'MANUAL_REVIEW' THEN N'Manual review'
                                             WHEN N'NEW_CANDIDATE' THEN N'New candidate' WHEN N'DUPLICATE' THEN N'Potential duplicate'
                                             ELSE N'Conflict' END, N' - ',
                       COALESCE(a.asset_name, e.external_key, CONCAT(N'observation #', e.observation_id)),
                       CASE WHEN e.field_key IS NULL THEN N'' ELSE CONCAT(N' [', e.field_key, N']') END,
                       N' (', src.source_name, N')') AS NVARCHAR(400)),
           CASE WHEN e.status = N'OPEN' THEN N'FAIL' ELSE N'PASS' END,
           CASE WHEN e.status = N'OPEN' THEN 1 ELSE 0 END,
           1,
           CAST(CASE WHEN e.status = N'OPEN'
                     THEN CONCAT(N'Open since ', CONVERT(NVARCHAR(10), e.entered_dt, 23),
                                 CASE WHEN e.raised_count > 1 THEN CONCAT(N'; observed ', e.raised_count, N' times') ELSE N'' END, N'.')
                     ELSE CONCAT(N'Resolved ', CONVERT(NVARCHAR(10), e.resolved_dt, 23),
                                 CASE WHEN e.resolution IS NULL THEN N'' ELSE CONCAT(N' (', LOWER(e.resolution), N')') END, N'.') END AS NVARCHAR(1000))
      FROM grac_practice.asset_reconciliation_exception e
      JOIN grac_practice.asset_discovery_source src ON src.source_id = e.source_id
      LEFT JOIN grac_practice.organization_dependency_asset a ON a.asset_id = e.asset_id
     CROSS APPLY (SELECT ef.PeriodDays AS p FROM grac_practice.fn_asset_governance_effective(@organization_id) ef
                   WHERE ef.KpiCode = N'RECONCILIATION_BACKLOG') pd
     WHERE (@kpi_code IS NULL OR @kpi_code = N'RECONCILIATION_BACKLOG')
       AND e.organization_id = @organization_id
       AND (e.status = N'OPEN' OR e.entered_dt >= DATEADD(DAY, -pd.p, SYSUTCDATETIME()))

    UNION ALL
    -- 10. Connector Availability (442): expected intervals of each active source with a completed batch.
    SELECT N'CONNECTOR_AVAILABILITY', N'SOURCE', s.source_id, CAST(CONCAT(s.source_code, N' - ', s.source_name) AS NVARCHAR(400)),
           o.outcome,
           CASE WHEN o.outcome = N'EXCLUDED' THEN 0 ELSE r.ok END,
           CASE WHEN o.outcome = N'EXCLUDED' THEN 0 ELSE sl.slots END,
           CAST(CASE o.outcome
                WHEN N'EXCLUDED' THEN CASE WHEN s.is_active = 0 THEN N'Inactive source.' ELSE N'Added less than one expected interval ago.' END
                WHEN N'FAIL' THEN CONCAT(sl.slots - r.ok, N' of ', sl.slots, N' expected runs (every ', s.expected_interval_hours,
                                         N' h) had no completed batch',
                                         CASE WHEN s.last_run_dt IS NULL THEN N'; never run'
                                              ELSE CONCAT(N'; last run ', CONVERT(NVARCHAR(16), s.last_run_dt, 120), N' UTC, ',
                                                          LOWER(ISNULL(s.last_run_status, N'unknown'))) END, N'.') END AS NVARCHAR(1000))
      FROM grac_practice.asset_discovery_source s
     CROSS APPLY (SELECT ef.PeriodDays AS p FROM grac_practice.fn_asset_governance_effective(@organization_id) ef
                   WHERE ef.KpiCode = N'CONNECTOR_AVAILABILITY') pd
     CROSS APPLY (SELECT CASE WHEN s.entered_dt > DATEADD(DAY, -pd.p, SYSUTCDATETIME()) THEN s.entered_dt
                              ELSE DATEADD(DAY, -pd.p, SYSUTCDATETIME()) END AS ws) w
     CROSS APPLY (SELECT DATEDIFF(HOUR, w.ws, SYSUTCDATETIME()) / s.expected_interval_hours AS slots) sl
     -- the interval of each batch is computed per row first (Msg 8124).
     CROSS APPLY (SELECT COUNT(DISTINCT bi.slot) AS ok
                    FROM grac_practice.asset_discovery_batch b
                   CROSS APPLY (SELECT DATEDIFF(HOUR, w.ws, b.received_dt) / s.expected_interval_hours AS slot) bi
                   WHERE b.source_id = s.source_id AND b.status = N'COMPLETED' AND b.received_dt >= w.ws AND bi.slot < sl.slots) r
     CROSS APPLY (SELECT CASE WHEN s.is_active = 0 OR sl.slots < 1 THEN N'EXCLUDED'
                              WHEN r.ok >= sl.slots THEN N'PASS' ELSE N'FAIL' END AS outcome) o
     WHERE (@kpi_code IS NULL OR @kpi_code = N'CONNECTOR_AVAILABILITY')
       AND s.organization_id = @organization_id;
GO
PRINT '450: KPI functions created.';
GO

-- =====================================================================
-- 5. Snapshot (D172-D174)
-- =====================================================================
-- Computes every enabled KPI from fn_asset_governance_items, scores it
-- (one decimal, half away from zero), rates it against its thresholds and
-- the overall score (weighted mean of the scored KPIs; a lower-is-better
-- KPI enters as 100 - rate), then:
--   * the same date already has a current snapshot with exactly the same
--     KPI rows and record rows -> nothing is written (UNCHANGED);
--   * otherwise a new snapshot (version n + 1 of the date) becomes the
--     current one and the previous one of the date is kept, superseded.
-- Record rows of snapshots older than the retention are removed (the KPI
-- rows stay); the latest snapshot always keeps its records.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_governance_snapshot_take
    @organization_id BIGINT,
    @source_code     NVARCHAR(10)  = N'MANUAL',
    @actor           NVARCHAR(100) = N'system',
    @suppress_result BIT           = 0,
    @out_snapshot_id BIGINT        = NULL OUTPUT,
    @out_created     BIT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @source_code = CASE WHEN UPPER(ISNULL(@source_code, N'')) = N'SCHEDULER' THEN N'SCHEDULER' ELSE N'MANUAL' END;
    SELECT @out_snapshot_id = NULL, @out_created = 0;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53080, 'Organization not found.', 1;

    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @ot DECIMAL(5, 1), @ow DECIMAL(5, 1), @ret INT, @code NVARCHAR(30), @cur BIGINT, @ver INT, @overall DECIMAL(5, 1),
            @rag NVARCHAR(6), @items INT, @latest BIGINT;
    SELECT @ot = overall_target, @ow = overall_warning, @ret = item_retention_days
      FROM grac_practice.asset_governance_org_setting WHERE organization_id = @organization_id;
    SELECT @ot = ISNULL(@ot, 90.0), @ow = ISNULL(@ow, 75.0), @ret = ISNULL(@ret, 90);

    CREATE TABLE #set (kpi_code NVARCHAR(30) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, is_enabled BIT NOT NULL, weight INT NOT NULL,
                       target_value DECIMAL(5, 1) NOT NULL, warning_value DECIMAL(5, 1) NOT NULL, period_days INT NULL,
                       direction NVARCHAR(6) COLLATE DATABASE_DEFAULT NOT NULL, display_order INT NOT NULL);
    INSERT #set (kpi_code, is_enabled, weight, target_value, warning_value, period_days, direction, display_order)
    SELECT KpiCode, IsEnabled, Weight, TargetValue, WarningValue, PeriodDays, Direction, DisplayOrder
      FROM grac_practice.fn_asset_governance_effective(@organization_id);

    CREATE TABLE #item (kpi_code NVARCHAR(30) COLLATE DATABASE_DEFAULT NOT NULL, record_kind NVARCHAR(16) COLLATE DATABASE_DEFAULT NOT NULL,
                        record_id BIGINT NOT NULL, record_name NVARCHAR(400) COLLATE DATABASE_DEFAULT NULL,
                        outcome NVARCHAR(8) COLLATE DATABASE_DEFAULT NOT NULL, numerator INT NOT NULL, denominator INT NOT NULL,
                        reason NVARCHAR(1000) COLLATE DATABASE_DEFAULT NULL,
                        PRIMARY KEY (kpi_code, record_kind, record_id));
    -- One KPI at a time, enabled ones only (a disabled KPI is recorded, not computed).
    DECLARE kpi_cur CURSOR LOCAL STATIC FOR SELECT kpi_code FROM #set WHERE is_enabled = 1 ORDER BY display_order;
    OPEN kpi_cur;
    FETCH NEXT FROM kpi_cur INTO @code;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        INSERT #item (kpi_code, record_kind, record_id, record_name, outcome, numerator, denominator, reason)
        SELECT KpiCode, RecordKind, RecordId, RecordName, Outcome, ISNULL(Numerator, 0), ISNULL(Denominator, 0), Reason
          FROM grac_practice.fn_asset_governance_items(@organization_id, @code);
        FETCH NEXT FROM kpi_cur INTO @code;
    END
    CLOSE kpi_cur;
    DEALLOCATE kpi_cur;

    CREATE TABLE #kpi (kpi_code NVARCHAR(30) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, is_enabled BIT NOT NULL, numerator INT NOT NULL,
                       denominator INT NOT NULL, excluded_count INT NOT NULL, failing_count INT NOT NULL, score DECIMAL(5, 1) NULL,
                       rag NVARCHAR(6) COLLATE DATABASE_DEFAULT NOT NULL, direction NVARCHAR(6) COLLATE DATABASE_DEFAULT NOT NULL,
                       target_value DECIMAL(5, 1) NOT NULL, warning_value DECIMAL(5, 1) NOT NULL, weight INT NOT NULL, period_days INT NULL);
    INSERT #kpi (kpi_code, is_enabled, numerator, denominator, excluded_count, failing_count, score, rag, direction,
                 target_value, warning_value, weight, period_days)
    SELECT s.kpi_code, s.is_enabled, ISNULL(a.num, 0), ISNULL(a.den, 0), ISNULL(a.exc, 0), ISNULL(a.fail, 0), sc.score,
           CASE WHEN sc.score IS NULL THEN N'NA'
                WHEN s.direction = N'HIGHER' AND sc.score >= s.target_value THEN N'GREEN'
                WHEN s.direction = N'HIGHER' AND sc.score >= s.warning_value THEN N'AMBER'
                WHEN s.direction = N'LOWER' AND sc.score <= s.target_value THEN N'GREEN'
                WHEN s.direction = N'LOWER' AND sc.score <= s.warning_value THEN N'AMBER'
                ELSE N'RED' END,
           s.direction, s.target_value, s.warning_value, s.weight, s.period_days
      FROM #set s
     OUTER APPLY (SELECT SUM(CASE WHEN i.outcome <> N'EXCLUDED' THEN i.numerator ELSE 0 END) AS num,
                         SUM(CASE WHEN i.outcome <> N'EXCLUDED' THEN i.denominator ELSE 0 END) AS den,
                         SUM(CASE WHEN i.outcome = N'EXCLUDED' THEN 1 ELSE 0 END) AS exc,
                         SUM(CASE WHEN i.outcome = N'FAIL' THEN 1 ELSE 0 END) AS fail
                    FROM #item i WHERE i.kpi_code = s.kpi_code) a
     -- Zero denominator: no score, rated NA, left out of the overall score (D171).
     CROSS APPLY (SELECT CAST(CASE WHEN s.is_enabled = 1 AND ISNULL(a.den, 0) > 0
                                   THEN ROUND(100.0 * a.num / a.den, 1) END AS DECIMAL(5, 1)) AS score) sc;

    SET @overall = (SELECT CAST(ROUND(SUM((CASE WHEN k.direction = N'LOWER' THEN 100.0 - k.score ELSE k.score END) * k.weight)
                                      / NULLIF(SUM(k.weight), 0), 1) AS DECIMAL(5, 1))
                      FROM #kpi k WHERE k.is_enabled = 1 AND k.score IS NOT NULL AND k.weight > 0);
    SET @rag = CASE WHEN @overall IS NULL THEN N'NA' WHEN @overall >= @ot THEN N'GREEN' WHEN @overall >= @ow THEN N'AMBER' ELSE N'RED' END;
    SET @items = (SELECT COUNT(*) FROM #item);

    SET @cur = (SELECT snapshot_id FROM grac_practice.asset_governance_snapshot
                 WHERE organization_id = @organization_id AND as_of_date = @today AND is_current = 1);
    IF @cur IS NOT NULL
       AND EXISTS (SELECT 1 FROM grac_practice.asset_governance_snapshot
                    WHERE snapshot_id = @cur AND items_purged = 0 AND overall_target = @ot AND overall_warning = @ow)
       AND NOT EXISTS (SELECT kpi_code, is_enabled, numerator, denominator, excluded_count, failing_count, target_value, warning_value, weight, period_days
                         FROM #kpi
                       EXCEPT
                       SELECT kpi_code, is_enabled, numerator, denominator, excluded_count, failing_count, target_value, warning_value, weight, period_days
                         FROM grac_practice.asset_governance_snapshot_kpi WHERE snapshot_id = @cur)
       AND NOT EXISTS (SELECT kpi_code, is_enabled, numerator, denominator, excluded_count, failing_count, target_value, warning_value, weight, period_days
                         FROM grac_practice.asset_governance_snapshot_kpi WHERE snapshot_id = @cur
                       EXCEPT
                       SELECT kpi_code, is_enabled, numerator, denominator, excluded_count, failing_count, target_value, warning_value, weight, period_days
                         FROM #kpi)
       AND NOT EXISTS (SELECT kpi_code, record_kind, record_id, outcome, numerator, denominator, reason FROM #item
                       EXCEPT
                       SELECT kpi_code, record_kind, record_id, outcome, numerator, denominator, reason
                         FROM grac_practice.asset_governance_snapshot_item WHERE snapshot_id = @cur)
       AND NOT EXISTS (SELECT kpi_code, record_kind, record_id, outcome, numerator, denominator, reason
                         FROM grac_practice.asset_governance_snapshot_item WHERE snapshot_id = @cur
                       EXCEPT
                       SELECT kpi_code, record_kind, record_id, outcome, numerator, denominator, reason FROM #item)
    BEGIN
        SET @out_snapshot_id = @cur;
    END
    ELSE
    BEGIN
        SET @ver = ISNULL((SELECT MAX(version_no) FROM grac_practice.asset_governance_snapshot
                            WHERE organization_id = @organization_id AND as_of_date = @today), 0) + 1;
        BEGIN TRAN;
        UPDATE grac_practice.asset_governance_snapshot
           SET is_current = 0, superseded_dt = SYSUTCDATETIME()
         WHERE snapshot_id = @cur;
        INSERT grac_practice.asset_governance_snapshot
            (organization_id, as_of_date, version_no, is_current, source_code, overall_score, overall_rag, overall_target,
             overall_warning, item_count, taken_by)
        VALUES (@organization_id, @today, @ver, 1, @source_code, @overall, @rag, @ot, @ow, @items, @actor);
        SET @out_snapshot_id = SCOPE_IDENTITY();
        INSERT grac_practice.asset_governance_snapshot_kpi
            (snapshot_id, kpi_code, is_enabled, numerator, denominator, excluded_count, failing_count, score, rag, direction,
             target_value, warning_value, weight, period_days)
        SELECT @out_snapshot_id, kpi_code, is_enabled, numerator, denominator, excluded_count, failing_count, score, rag, direction,
               target_value, warning_value, weight, period_days
          FROM #kpi;
        INSERT grac_practice.asset_governance_snapshot_item
            (snapshot_id, kpi_code, record_kind, record_id, record_name, outcome, numerator, denominator, reason)
        SELECT @out_snapshot_id, kpi_code, record_kind, record_id, record_name, outcome, numerator, denominator, reason
          FROM #item;
        INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        VALUES (N'asset-governance-snapshot', @out_snapshot_id, N'SNAPSHOT',
                CASE WHEN @cur IS NULL THEN NULL ELSE (SELECT @cur AS supersededSnapshotId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END,
                (SELECT @organization_id AS organizationId, @today AS asOfDate, @ver AS versionNo, @source_code AS source,
                        @overall AS overallScore, @rag AS overallRag, @items AS records FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                N'Active', @actor);
        COMMIT;
        SET @out_created = 1;
    END

    -- Record-detail retention (D174): the KPI rows stay; the latest snapshot keeps its records.
    SET @latest = (SELECT TOP (1) snapshot_id FROM grac_practice.asset_governance_snapshot
                    WHERE organization_id = @organization_id ORDER BY as_of_date DESC, version_no DESC);
    DELETE i
      FROM grac_practice.asset_governance_snapshot_item i
      JOIN grac_practice.asset_governance_snapshot s ON s.snapshot_id = i.snapshot_id
     WHERE s.organization_id = @organization_id AND s.snapshot_id <> @latest
       AND s.taken_dt < DATEADD(DAY, -@ret, SYSUTCDATETIME());
    UPDATE grac_practice.asset_governance_snapshot
       SET items_purged = 1
     WHERE organization_id = @organization_id AND snapshot_id <> @latest AND items_purged = 0
       AND taken_dt < DATEADD(DAY, -@ret, SYSUTCDATETIME());

    IF @suppress_result = 0
        SELECT @out_snapshot_id AS SnapshotId, CASE WHEN @out_created = 1 THEN N'CREATED' ELSE N'UNCHANGED' END AS Result;
END
GO
PRINT '450: snapshot procedure created.';
GO

-- =====================================================================
-- 6. Readers
-- =====================================================================
-- Scorecard of a snapshot (default: the current snapshot of the latest
-- date). 1. snapshot header  2. KPI rows with their definitions and the
-- previous date score  3. trend: current snapshot of each date in the
-- window (KpiCode OVERALL = the overall score).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_governance_get
    @organization_id BIGINT,
    @snapshot_id     BIGINT = NULL,
    @trend_days      INT    = 90
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53080, 'Organization not found.', 1;
    SET @trend_days = CASE WHEN ISNULL(@trend_days, 90) < 7 THEN 7 WHEN @trend_days > 366 THEN 366 ELSE @trend_days END;
    IF @snapshot_id IS NULL
    BEGIN
        SET @snapshot_id = (SELECT TOP (1) snapshot_id FROM grac_practice.asset_governance_snapshot
                             WHERE organization_id = @organization_id AND is_current = 1 ORDER BY as_of_date DESC);
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_governance_snapshot
                         WHERE snapshot_id = @snapshot_id AND organization_id = @organization_id)
    BEGIN
        THROW 53083, 'Snapshot not found.', 1;
    END
    DECLARE @as_of DATE = (SELECT as_of_date FROM grac_practice.asset_governance_snapshot WHERE snapshot_id = @snapshot_id);

    -- 1. Header
    SELECT s.snapshot_id AS SnapshotId, s.as_of_date AS AsOfDate, s.version_no AS VersionNo, s.is_current AS IsCurrent,
           s.source_code AS SourceCode, s.overall_score AS OverallScore, s.overall_rag AS OverallRag,
           s.overall_target AS OverallTarget, s.overall_warning AS OverallWarning, s.item_count AS ItemCount,
           s.items_purged AS ItemsPurged, s.taken_by AS TakenBy, s.taken_dt AS TakenDt, s.superseded_dt AS SupersededDt,
           (SELECT COUNT(*) FROM grac_practice.asset_governance_snapshot x
             WHERE x.organization_id = s.organization_id AND x.as_of_date = s.as_of_date) AS VersionsOfDate,
           (SELECT TOP (1) p.overall_score FROM grac_practice.asset_governance_snapshot p
             WHERE p.organization_id = s.organization_id AND p.is_current = 1 AND p.as_of_date < s.as_of_date
             ORDER BY p.as_of_date DESC) AS PreviousOverallScore
      FROM grac_practice.asset_governance_snapshot s
     WHERE s.snapshot_id = @snapshot_id;

    -- 2. KPIs: definition + the snapshot row (+ effective settings when no snapshot yet)
    SELECT k.kpi_code AS KpiCode, k.kpi_name AS KpiName, k.formula_text AS FormulaText, k.numerator_text AS NumeratorText,
           k.denominator_text AS DenominatorText, k.population_text AS PopulationText, k.exclusions_text AS ExclusionsText,
           k.as_of_text AS AsOfText, k.record_label AS RecordLabel, k.brd_reference AS BrdReference, k.display_order AS DisplayOrder,
           ISNULL(sk.is_enabled, e.IsEnabled) AS IsEnabled, sk.numerator AS Numerator, sk.denominator AS Denominator,
           sk.excluded_count AS ExcludedCount, sk.failing_count AS FailingCount, sk.score AS Score, ISNULL(sk.rag, N'NA') AS Rag,
           ISNULL(sk.direction, k.direction) AS Direction, ISNULL(sk.target_value, e.TargetValue) AS TargetValue,
           ISNULL(sk.warning_value, e.WarningValue) AS WarningValue, ISNULL(sk.weight, e.Weight) AS Weight,
           CASE WHEN sk.snapshot_id IS NULL THEN e.PeriodDays ELSE sk.period_days END AS PeriodDays,
           prev.score AS PreviousScore
      FROM grac_practice.asset_governance_kpi k
      JOIN grac_practice.fn_asset_governance_effective(@organization_id) e ON e.KpiCode = k.kpi_code
      LEFT JOIN grac_practice.asset_governance_snapshot_kpi sk ON sk.snapshot_id = @snapshot_id AND sk.kpi_code = k.kpi_code
     OUTER APPLY (SELECT TOP (1) pk.score
                    FROM grac_practice.asset_governance_snapshot ps
                    JOIN grac_practice.asset_governance_snapshot_kpi pk ON pk.snapshot_id = ps.snapshot_id AND pk.kpi_code = k.kpi_code
                   WHERE ps.organization_id = @organization_id AND ps.is_current = 1 AND ps.as_of_date < @as_of
                   ORDER BY ps.as_of_date DESC) prev
     ORDER BY k.display_order;

    -- 3. Trend
    SELECT s.as_of_date AS AsOfDate, CAST(N'OVERALL' AS NVARCHAR(30)) AS KpiCode, s.overall_score AS Score, s.overall_rag AS Rag
      FROM grac_practice.asset_governance_snapshot s
     WHERE s.organization_id = @organization_id AND s.is_current = 1
       AND s.as_of_date BETWEEN DATEADD(DAY, -@trend_days, @as_of) AND @as_of
    UNION ALL
    SELECT s.as_of_date, sk.kpi_code, sk.score, sk.rag
      FROM grac_practice.asset_governance_snapshot s
      JOIN grac_practice.asset_governance_snapshot_kpi sk ON sk.snapshot_id = s.snapshot_id
     WHERE s.organization_id = @organization_id AND s.is_current = 1
       AND s.as_of_date BETWEEN DATEADD(DAY, -@trend_days, @as_of) AND @as_of
     ORDER BY AsOfDate, KpiCode;
END
GO

-- Drill-down: the record rows of one KPI of a snapshot (exact numerator,
-- denominator, excluded and failing records). @outcome PASS | FAIL |
-- EXCLUDED | empty (all). 1. rows (paged)  2. totals per outcome.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_governance_items
    @organization_id BIGINT,
    @snapshot_id     BIGINT,
    @kpi_code        NVARCHAR(30),
    @outcome         NVARCHAR(8)   = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @outcome = NULLIF(UPPER(LTRIM(RTRIM(@outcome))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53080, 'Organization not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_governance_snapshot WHERE snapshot_id = @snapshot_id AND organization_id = @organization_id)
        THROW 53083, 'Snapshot not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_governance_kpi WHERE kpi_code = @kpi_code)
        THROW 53081, 'Unknown KPI.', 1;

    SELECT i.record_kind AS RecordKind, i.record_id AS RecordId, i.record_name AS RecordName, i.outcome AS Outcome,
           i.numerator AS Numerator, i.denominator AS Denominator, i.reason AS Reason, COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_governance_snapshot_item i
     WHERE i.snapshot_id = @snapshot_id AND i.kpi_code = @kpi_code
       AND (@outcome IS NULL OR i.outcome = @outcome)
       AND (@search IS NULL OR i.record_name LIKE N'%' + @search + N'%' OR i.reason LIKE N'%' + @search + N'%'
            OR CAST(i.record_id AS NVARCHAR(20)) = @search)
     ORDER BY CASE i.outcome WHEN N'FAIL' THEN 0 WHEN N'EXCLUDED' THEN 2 ELSE 1 END, i.record_name, i.record_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;

    SELECT o.outcome AS Outcome, COUNT(i.record_id) AS ItemCount, ISNULL(SUM(i.numerator), 0) AS Numerator,
           ISNULL(SUM(i.denominator), 0) AS Denominator
      FROM (VALUES (N'PASS'), (N'FAIL'), (N'EXCLUDED')) o(outcome)
      LEFT JOIN grac_practice.asset_governance_snapshot_item i
             ON i.snapshot_id = @snapshot_id AND i.kpi_code = @kpi_code AND i.outcome = o.outcome
     GROUP BY o.outcome;
END
GO

-- Snapshot history (every version of every date, superseded ones too).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_governance_snapshots
    @organization_id BIGINT,
    @page_number     INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53080, 'Organization not found.', 1;
    SELECT s.snapshot_id AS SnapshotId, s.as_of_date AS AsOfDate, s.version_no AS VersionNo, s.is_current AS IsCurrent,
           s.source_code AS SourceCode, s.overall_score AS OverallScore, s.overall_rag AS OverallRag, s.item_count AS ItemCount,
           s.items_purged AS ItemsPurged, s.taken_by AS TakenBy, s.taken_dt AS TakenDt, s.superseded_dt AS SupersededDt,
           r.green AS GreenCount, r.amber AS AmberCount, r.red AS RedCount, r.na AS NaCount, COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_governance_snapshot s
     CROSS APPLY (SELECT SUM(CASE WHEN k.rag = N'GREEN' THEN 1 ELSE 0 END) AS green, SUM(CASE WHEN k.rag = N'AMBER' THEN 1 ELSE 0 END) AS amber,
                         SUM(CASE WHEN k.rag = N'RED' THEN 1 ELSE 0 END) AS red, SUM(CASE WHEN k.rag = N'NA' THEN 1 ELSE 0 END) AS na
                    FROM grac_practice.asset_governance_snapshot_kpi k WHERE k.snapshot_id = s.snapshot_id) r
     WHERE s.organization_id = @organization_id
     ORDER BY s.as_of_date DESC, s.version_no DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Settings: 1. KPIs with defaults and the organization values  2. overall
-- thresholds and retention  3. relationship requirements  4. asset types
-- 5. relationship types an asset can take part in  6. the 441 minimum
-- supporting relationships of business services.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_governance_settings
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53080, 'Organization not found.', 1;
    SELECT k.kpi_code AS KpiCode, k.kpi_name AS KpiName, k.formula_text AS FormulaText, k.direction AS Direction,
           k.default_target AS DefaultTarget, k.default_warning AS DefaultWarning, k.default_weight AS DefaultWeight,
           k.default_period_days AS DefaultPeriodDays, e.IsEnabled, e.Weight, e.TargetValue, e.WarningValue, e.PeriodDays,
           e.IsCustomised, s.updated_by AS UpdatedBy, ISNULL(s.updated_dt, s.entered_dt) AS UpdatedDt
      FROM grac_practice.asset_governance_kpi k
      JOIN grac_practice.fn_asset_governance_effective(@organization_id) e ON e.KpiCode = k.kpi_code
      LEFT JOIN grac_practice.asset_governance_setting s ON s.organization_id = @organization_id AND s.kpi_code = k.kpi_code
     ORDER BY k.display_order;
    SELECT ISNULL(o.overall_target, 90.0) AS OverallTarget, ISNULL(o.overall_warning, 75.0) AS OverallWarning,
           ISNULL(o.item_retention_days, 90) AS ItemRetentionDays, o.updated_by AS UpdatedBy, ISNULL(o.updated_dt, o.entered_dt) AS UpdatedDt
      FROM (SELECT 1 AS one) x
      LEFT JOIN grac_practice.asset_governance_org_setting o ON o.organization_id = @organization_id;
    SELECT r.rule_id AS RuleId, r.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName,
           r.relationship_type_code AS RelationshipTypeCode, rt.type_name AS TypeName, rt.inverse_label AS InverseLabel,
           r.asset_side AS AssetSide, r.min_count AS MinCount, r.is_active AS IsActive,
           ISNULL(r.updated_by, r.entered_by) AS UpdatedBy, ISNULL(r.updated_dt, r.entered_dt) AS UpdatedDt
      FROM grac_practice.asset_governance_relationship_rule r
      JOIN grac_practice.asset_relationship_type rt ON rt.type_code = r.relationship_type_code
      LEFT JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = r.asset_type_id
     WHERE r.organization_id = @organization_id
     ORDER BY t.asset_type_name, rt.display_order, r.asset_side;
    SELECT t.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName
      FROM grac_practice.dependency_asset_type_master t
     WHERE t.is_active = 1
     ORDER BY t.asset_type_name;
    SELECT rt.type_code AS TypeCode, rt.type_name AS TypeName, rt.inverse_label AS InverseLabel,
           CAST(CASE WHEN N',' + REPLACE(rt.source_kinds, N' ', N'') + N',' LIKE N'%,ASSET,%' THEN 1 ELSE 0 END AS BIT) AS AssetAsSource,
           CAST(CASE WHEN N',' + REPLACE(rt.target_kinds, N' ', N'') + N',' LIKE N'%,ASSET,%' THEN 1 ELSE 0 END AS BIT) AS AssetAsTarget
      FROM grac_practice.asset_relationship_type rt
     WHERE rt.is_active = 1
       AND (N',' + REPLACE(rt.source_kinds, N' ', N'') + N',' LIKE N'%,ASSET,%'
            OR N',' + REPLACE(rt.target_kinds, N' ', N'') + N',' LIKE N'%,ASSET,%')
     ORDER BY rt.display_order;
    SELECT ISNULL((SELECT bs.min_supporting_relationships FROM grac_practice.business_service_setting bs
                    WHERE bs.organization_id = @organization_id), 1) AS MinSupportingRelationships;
END
GO
PRINT '450: readers created.';
GO

-- =====================================================================
-- 7. Writers (asset-governance EDIT)
-- =====================================================================
-- One KPI of the organization. @reset = 1 removes the row (catalogue
-- defaults again). Higher-is-better: warning <= target; lower-is-better:
-- warning >= target. The period applies only to KPIs that have one.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_governance_setting_save
    @organization_id BIGINT,
    @kpi_code        NVARCHAR(30),
    @reset           BIT           = 0,
    @is_enabled      BIT           = 1,
    @weight          INT           = NULL,
    @target_value    DECIMAL(5, 1) = NULL,
    @warning_value   DECIMAL(5, 1) = NULL,
    @period_days     INT           = NULL,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53080, 'Organization not found.', 1;
    DECLARE @direction NVARCHAR(6), @has_period INT;
    SELECT @direction = direction, @has_period = CASE WHEN default_period_days IS NULL THEN 0 ELSE 1 END
      FROM grac_practice.asset_governance_kpi WHERE kpi_code = @kpi_code;
    IF @direction IS NULL THROW 53081, 'Unknown KPI.', 1;
    IF ISNULL(@reset, 0) = 0
    BEGIN
        IF @weight IS NULL OR @weight NOT BETWEEN 0 AND 100
            THROW 53082, 'The weight must be between 0 and 100.', 1;
        IF @target_value IS NULL OR @warning_value IS NULL OR @target_value NOT BETWEEN 0 AND 100 OR @warning_value NOT BETWEEN 0 AND 100
            THROW 53082, 'Target and warning thresholds must be between 0 and 100.', 1;
        IF @direction = N'HIGHER' AND @warning_value > @target_value
            THROW 53082, 'For this KPI higher is better: the warning threshold cannot be above the target.', 1;
        IF @direction = N'LOWER' AND @warning_value < @target_value
            THROW 53082, 'For this KPI lower is better: the warning threshold cannot be below the target.', 1;
        IF @has_period = 1 AND (@period_days IS NULL OR @period_days NOT BETWEEN 1 AND 3650)
            THROW 53082, 'The period must be between 1 and 3650 days.', 1;
        IF @has_period = 0 SET @period_days = NULL;
    END

    DECLARE @before NVARCHAR(MAX) = (SELECT s.is_enabled AS isEnabled, s.weight AS weight, s.target_value AS targetValue,
                                            s.warning_value AS warningValue, s.period_days AS periodDays
                                       FROM grac_practice.asset_governance_setting s
                                      WHERE s.organization_id = @organization_id AND s.kpi_code = @kpi_code
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    IF ISNULL(@reset, 0) = 1
    BEGIN
        DELETE FROM grac_practice.asset_governance_setting WHERE organization_id = @organization_id AND kpi_code = @kpi_code;
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_governance_setting
           SET is_enabled = ISNULL(@is_enabled, 1), weight = @weight, target_value = @target_value, warning_value = @warning_value,
               period_days = @period_days, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE organization_id = @organization_id AND kpi_code = @kpi_code;
        IF @@ROWCOUNT = 0
            INSERT grac_practice.asset_governance_setting
                (organization_id, kpi_code, is_enabled, weight, target_value, warning_value, period_days, entered_by)
            VALUES (@organization_id, @kpi_code, ISNULL(@is_enabled, 1), @weight, @target_value, @warning_value, @period_days, @actor);
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-governance-setting', @organization_id, CASE WHEN ISNULL(@reset, 0) = 1 THEN N'RESET' ELSE N'SAVE' END, @before,
            (SELECT @kpi_code AS kpiCode, CASE WHEN ISNULL(@reset, 0) = 1 THEN NULL ELSE ISNULL(@is_enabled, 1) END AS isEnabled,
                    @weight AS weight, @target_value AS targetValue, @warning_value AS warningValue, @period_days AS periodDays
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @organization_id AS OrganizationId, @kpi_code AS KpiCode, CASE WHEN ISNULL(@reset, 0) = 1 THEN N'RESET' ELSE N'SAVED' END AS Result;
END
GO

-- Overall thresholds and record-detail retention of the organization.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_governance_org_setting_save
    @organization_id     BIGINT,
    @overall_target      DECIMAL(5, 1),
    @overall_warning     DECIMAL(5, 1),
    @item_retention_days INT,
    @actor               NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53080, 'Organization not found.', 1;
    IF @overall_target IS NULL OR @overall_warning IS NULL OR @overall_target NOT BETWEEN 0 AND 100
       OR @overall_warning NOT BETWEEN 0 AND 100 OR @overall_warning > @overall_target
        THROW 53089, 'Overall thresholds must be between 0 and 100, the warning not above the target.', 1;
    IF @item_retention_days IS NULL OR @item_retention_days NOT BETWEEN 7 AND 3650
        THROW 53089, 'Record detail is kept between 7 and 3650 days.', 1;
    DECLARE @before NVARCHAR(MAX) = (SELECT o.overall_target AS overallTarget, o.overall_warning AS overallWarning,
                                            o.item_retention_days AS itemRetentionDays
                                       FROM grac_practice.asset_governance_org_setting o
                                      WHERE o.organization_id = @organization_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    UPDATE grac_practice.asset_governance_org_setting
       SET overall_target = @overall_target, overall_warning = @overall_warning, item_retention_days = @item_retention_days,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE organization_id = @organization_id;
    IF @@ROWCOUNT = 0
        INSERT grac_practice.asset_governance_org_setting (organization_id, overall_target, overall_warning, item_retention_days, entered_by)
        VALUES (@organization_id, @overall_target, @overall_warning, @item_retention_days, @actor);
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-governance-org-setting', @organization_id, N'SAVE', @before,
            (SELECT @overall_target AS overallTarget, @overall_warning AS overallWarning, @item_retention_days AS itemRetentionDays
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @organization_id AS OrganizationId, N'SAVED' AS Result;
END
GO

-- Relationship requirement of an asset type (new when @rule_id is NULL).
-- Type, relationship and side are fixed once saved; deactivate instead of
-- deleting (IsActive = 0).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_governance_relationship_rule_save
    @organization_id        BIGINT,
    @rule_id                BIGINT        = NULL,
    @asset_type_id          INT           = NULL,
    @relationship_type_code NVARCHAR(30)  = NULL,
    @asset_side             NVARCHAR(6)   = NULL,
    @min_count              INT           = 1,
    @is_active              BIT           = 1,
    @actor                  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @asset_side = NULLIF(UPPER(LTRIM(RTRIM(@asset_side))), N'');
    SET @relationship_type_code = NULLIF(UPPER(LTRIM(RTRIM(@relationship_type_code))), N'');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53080, 'Organization not found.', 1;
    IF @min_count IS NULL OR @min_count NOT BETWEEN 1 AND 50
        THROW 53087, 'The minimum is between 1 and 50 relationships.', 1;
    DECLARE @before NVARCHAR(MAX);
    IF @rule_id IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_governance_relationship_rule
                        WHERE rule_id = @rule_id AND organization_id = @organization_id)
            THROW 53086, 'Relationship requirement not found.', 1;
        SET @before = (SELECT r.min_count AS minCount, r.is_active AS isActive
                         FROM grac_practice.asset_governance_relationship_rule r WHERE r.rule_id = @rule_id
                          FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    END
    ELSE
    BEGIN
        IF @asset_type_id IS NULL OR NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_type_master WHERE asset_type_id = @asset_type_id)
            THROW 53084, 'Asset type not found.', 1;
        IF @asset_side IS NULL OR @asset_side NOT IN (N'SOURCE', N'TARGET')
            THROW 53087, 'Choose whether the asset is the source or the target of the relationship.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_relationship_type rt
                        WHERE rt.type_code = @relationship_type_code AND rt.is_active = 1
                          AND N',' + REPLACE(CASE @asset_side WHEN N'SOURCE' THEN rt.source_kinds ELSE rt.target_kinds END, N' ', N'') + N','
                              LIKE N'%,ASSET,%')
            THROW 53085, 'Relationship type not found, inactive, or an asset cannot be on that side of it.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.asset_governance_relationship_rule
                    WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id
                      AND relationship_type_code = @relationship_type_code AND asset_side = @asset_side)
            THROW 53088, 'A requirement for this asset type, relationship and side exists; change it instead.', 1;
    END

    BEGIN TRAN;
    IF @rule_id IS NOT NULL
    BEGIN
        UPDATE grac_practice.asset_governance_relationship_rule
           SET min_count = @min_count, is_active = ISNULL(@is_active, 1), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE rule_id = @rule_id;
    END
    ELSE
    BEGIN
        INSERT grac_practice.asset_governance_relationship_rule
            (organization_id, asset_type_id, relationship_type_code, asset_side, min_count, is_active, entered_by)
        VALUES (@organization_id, @asset_type_id, @relationship_type_code, @asset_side, @min_count, ISNULL(@is_active, 1), @actor);
        SET @rule_id = SCOPE_IDENTITY();
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-governance-relationship-rule', @rule_id, CASE WHEN @before IS NULL THEN N'CREATE' ELSE N'UPDATE' END, @before,
            (SELECT r.organization_id AS organizationId, r.asset_type_id AS assetTypeId, r.relationship_type_code AS relationshipTypeCode,
                    r.asset_side AS assetSide, r.min_count AS minCount, r.is_active AS isActive
               FROM grac_practice.asset_governance_relationship_rule r WHERE r.rule_id = @rule_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @rule_id AS RuleId, CASE WHEN @before IS NULL THEN N'CREATED' ELSE N'SAVED' END AS Result;
END
GO
PRINT '450: writers created.';
GO
-- =====================================================================
-- 8. Re-issued body (450 lines marked; otherwise unchanged)
-- =====================================================================
-- 448 body: one governance snapshot per organization per day.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_scheduler_run
    @organization_id BIGINT        = NULL,
    @trigger_code    NVARCHAR(12)  = N'SCHEDULED',
    @actor           NVARCHAR(100) = N'scheduler'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SET @trigger_code = CASE WHEN UPPER(ISNULL(@trigger_code, N'')) = N'MANUAL' THEN N'MANUAL' ELSE N'SCHEDULED' END;
    IF @organization_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54610, 'Organization not found.', 1;

    DECLARE @lock INT;
    EXEC @lock = sp_getapplock @Resource = N'grac_practice.asset_scheduler', @LockMode = N'Exclusive',
                               @LockOwner = N'Session', @LockTimeout = 0;
    IF @lock < 0
    BEGIN
        SELECT CAST(NULL AS BIGINT) AS RunId, N'SKIPPED' AS Result, 0 AS Organizations, 0 AS RenewalsStarted,
               0 AS AttestationsGenerated, 0 AS OccurrencesOpened, 0 AS OccurrencesClosed, 0 AS NotificationsQueued,
               0 AS ErrorCount, N'Another scheduler run is in progress.' AS ErrorText, 0 AS TasksCreated;
        RETURN;
    END

    DECLARE @run BIGINT, @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    BEGIN TRY
    INSERT grac_practice.asset_scheduler_run (organization_id, trigger_code, entered_by) VALUES (@organization_id, @trigger_code, @actor);
    SET @run = SCOPE_IDENTITY();

    DECLARE @orgs INT = 0, @ren INT = 0, @att INT = 0, @opened INT = 0, @closed INT = 0, @queued INT = 0, @errors INT = 0,
            @err NVARCHAR(MAX) = NULL,
            @o INT, @c INT, @q INT, @e INT, @et NVARCHAR(MAX), @gen INT, @rid BIGINT,
            @tasks INT = 0, @t INT, @ao INT, @ac INT;                                      -- 438
    DECLARE @vu INT;                                                                       -- 446
    DECLARE @co INT, @cr INT, @cx INT;                                                     -- 447
    DECLARE @po INT, @pc INT, @px INT;                                                     -- 448
    DECLARE @gs BIGINT, @gc BIT;                                                           -- 450

    DECLARE @org_list TABLE (organization_id BIGINT NOT NULL PRIMARY KEY);
    INSERT @org_list (organization_id)
    SELECT o.organization_id
      FROM grac_practice.organization o
     WHERE (@organization_id IS NOT NULL AND o.organization_id = @organization_id)
        OR (@organization_id IS NULL
            AND (EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a WHERE a.organization_id = o.organization_id)
                 OR EXISTS (SELECT 1 FROM grac_practice.asset_contract c WHERE c.organization_id = o.organization_id)));

    DECLARE @org BIGINT, @contract BIGINT;
    DECLARE org_cur CURSOR LOCAL STATIC FOR SELECT organization_id FROM @org_list ORDER BY organization_id;
    OPEN org_cur;
    FETCH NEXT FROM org_cur INTO @org;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @orgs = @orgs + 1;

        BEGIN TRY
            EXEC grac_practice.sp_asset_notification_defaults_ensure @organization_id = @org, @actor = @actor;
            EXEC grac_practice.sp_asset_contract_sync @organization_id = @org, @actor = @actor;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (defaults / contract dates): ', ERROR_MESSAGE()), 8000);
        END CATCH

        IF EXISTS (SELECT 1 FROM grac_practice.asset_attestation_profile WHERE organization_id = @org AND is_active = 1)
        BEGIN
        BEGIN TRY
            SET @gen = 0;
            EXEC grac_practice.sp_asset_attestation_generate @organization_id = @org, @campaign_type = N'PERIODIC', @actor = @actor,
                 @scheduled = 1, @suppress_result = 1, @out_generated = @gen OUTPUT;
            SET @att = @att + ISNULL(@gen, 0);
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (periodic attestation): ', ERROR_MESSAGE()), 8000);
        END CATCH
        END

        -- d. Renewal occurrences whose reminder window has opened.
        DECLARE ren_cur CURSOR LOCAL STATIC FOR
            SELECT c.contract_id
              FROM grac_practice.asset_contract c
              JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
             CROSS APPLY (SELECT MIN(v.d) AS d FROM (VALUES (cv.notice_date), (cv.decision_date), (cv.effective_end)) v(d)) t
             OUTER APPLY (SELECT ProfileId FROM grac_practice.fn_asset_ntf_profile_for(
                              c.organization_id, grac_practice.fn_asset_ntf_contract_activity(c.contract_type),
                              grac_practice.fn_asset_ntf_version_severity(cv.version_id), @today)) p
             OUTER APPLY (SELECT MAX(s.offset_days) AS lead_days FROM grac_practice.asset_notification_stage s
                           WHERE s.profile_id = p.ProfileId AND s.is_active = 1 AND s.stage_kind = N'REMINDER') w
             WHERE c.organization_id = @org AND c.contract_status IN (N'ACTIVE', N'APPROVED', N'EXPIRED')
               AND cv.version_type <> N'TERMINATION' AND t.d IS NOT NULL
               AND DATEADD(DAY, -ISNULL(w.lead_days, 0), t.d) <= @today
               AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_renewal r
                                WHERE r.contract_id = c.contract_id
                                  AND (r.is_open = 1 OR (r.prior_version_id = cv.version_id AND ISNULL(r.outcome, N'') <> N'CANCELLED')));
        OPEN ren_cur;
        FETCH NEXT FROM ren_cur INTO @contract;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @rid = NULL;
                EXEC grac_practice.sp_asset_contract_renewal_start @organization_id = @org, @contract_id = @contract,
                     @renewal_type = N'RENEWAL', @notes = N'Started by the scheduler: the renewal reminder window opened.',
                     @actor_employee_id = NULL, @actor = @actor, @suppress_result = 1, @out_renewal_id = @rid OUTPUT;
                IF @rid IS NOT NULL SET @ren = @ren + 1;
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0 ROLLBACK;
                SET @errors = @errors + 1;
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                       N'Contract ', @contract, N' (renewal start): ', ERROR_MESSAGE()), 8000);
            END CATCH
            FETCH NEXT FROM ren_cur INTO @contract;
        END
        CLOSE ren_cur;
        DEALLOCATE ren_cur;

        -- 446: Asset Value for ratings changed outside the asset form (5.1.18.5.7, D137).
        BEGIN TRY                                                                          -- 446
            SELECT @vu = 0, @e = 0, @et = NULL;                                            -- 446
            EXEC grac_practice.sp_asset_valuation_sync @organization_id = @org, @actor = @actor,   -- 446
                 @updated = @vu OUTPUT, @errors = @e OUTPUT, @error_text = @et OUTPUT;     -- 446
            SET @errors = @errors + ISNULL(@e, 0);                                         -- 446
            IF @et IS NOT NULL                                                             -- 446
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, N'Organization ', @org, N': ', @et), 8000);   -- 446
        END TRY                                                                            -- 446
        BEGIN CATCH                                                                        -- 446
            IF XACT_STATE() <> 0 ROLLBACK;                                                 -- 446
            SET @errors = @errors + 1;                                                     -- 446
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,   -- 446
                                   N'Organization ', @org, N' (asset value): ', ERROR_MESSAGE()), 8000);   -- 446
        END CATCH                                                                          -- 446

        -- 447: consistency findings follow ratings, valuations and expired acceptances (19.7).
        BEGIN TRY                                                                          -- 447
            EXEC grac_practice.sp_asset_consistency_evaluate @organization_id = @org, @actor = @actor,   -- 447
                 @out_opened = @co OUTPUT, @out_resolved = @cr OUTPUT, @out_reopened = @cx OUTPUT;   -- 447
        END TRY                                                                            -- 447
        BEGIN CATCH                                                                        -- 447
            IF XACT_STATE() <> 0 ROLLBACK;                                                 -- 447
            SET @errors = @errors + 1;                                                     -- 447
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,   -- 447
                                   N'Organization ', @org, N' (consistency rules): ', ERROR_MESSAGE()), 8000);   -- 447
        END CATCH                                                                          -- 447

        -- 448: privacy and retention reviews, exception expiry (before the sweep, so they notify).
        BEGIN TRY                                                                          -- 448
            EXEC grac_practice.sp_asset_privacy_sync @organization_id = @org, @actor = @actor,   -- 448
                 @out_opened = @po OUTPUT, @out_closed = @pc OUTPUT, @out_expired = @px OUTPUT;   -- 448
        END TRY                                                                            -- 448
        BEGIN CATCH                                                                        -- 448
            IF XACT_STATE() <> 0 ROLLBACK;                                                 -- 448
            SET @errors = @errors + 1;                                                     -- 448
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,   -- 448
                                   N'Organization ', @org, N' (privacy): ', ERROR_MESSAGE()), 8000);   -- 448
        END CATCH                                                                          -- 448

        -- 438: recurring asset activities (before the sweep, so new occurrences notify).
        BEGIN TRY
            SELECT @t = 0, @ao = 0, @ac = 0, @e = 0, @et = NULL;
            EXEC grac_practice.sp_asset_activity_run @organization_id = @org, @actor = @actor,
                 @tasks = @t OUTPUT, @opened = @ao OUTPUT, @completed = @ac OUTPUT, @errors = @e OUTPUT, @error_text = @et OUTPUT;
            SELECT @tasks = @tasks + ISNULL(@t, 0), @errors = @errors + ISNULL(@e, 0);
            IF @et IS NOT NULL
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, N'Organization ', @org, N': ', @et), 8000);
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (activities): ', ERROR_MESSAGE()), 8000);
        END CATCH

        BEGIN TRY
            SELECT @o = 0, @c = 0, @q = 0, @e = 0, @et = NULL;
            EXEC grac_practice.sp_asset_notification_sweep @organization_id = @org, @actor = @actor,
                 @opened = @o OUTPUT, @closed = @c OUTPUT, @queued = @q OUTPUT, @errors = @e OUTPUT, @error_text = @et OUTPUT;
            SELECT @opened = @opened + @o, @closed = @closed + @c, @queued = @queued + @q, @errors = @errors + @e;
            IF @et IS NOT NULL
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, N'Organization ', @org, N': ', @et), 8000);
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (notifications): ', ERROR_MESSAGE()), 8000);
        END CATCH

        -- 450: one governance KPI snapshot per organization per day (19.8), after the sweep.
        IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_governance_snapshot                -- 450
                        WHERE organization_id = @org AND as_of_date = @today)               -- 450
        BEGIN                                                                              -- 450
        BEGIN TRY                                                                          -- 450
            EXEC grac_practice.sp_asset_governance_snapshot_take @organization_id = @org, @source_code = N'SCHEDULER',   -- 450
                 @actor = @actor, @suppress_result = 1, @out_snapshot_id = @gs OUTPUT, @out_created = @gc OUTPUT;   -- 450
        END TRY                                                                            -- 450
        BEGIN CATCH                                                                        -- 450
            IF XACT_STATE() <> 0 ROLLBACK;                                                 -- 450
            SET @errors = @errors + 1;                                                     -- 450
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,   -- 450
                                   N'Organization ', @org, N' (governance snapshot): ', ERROR_MESSAGE()), 8000);   -- 450
        END CATCH                                                                          -- 450
        END                                                                                -- 450

        FETCH NEXT FROM org_cur INTO @org;
    END
    CLOSE org_cur;
    DEALLOCATE org_cur;

    UPDATE grac_practice.asset_scheduler_run
       SET finished_dt = SYSUTCDATETIME(), result = CASE WHEN @errors > 0 THEN N'COMPLETED_WITH_ERRORS' ELSE N'COMPLETED' END,
           organizations = @orgs, renewals_started = @ren, attestations_generated = @att, occurrences_opened = @opened,
           occurrences_closed = @closed, notifications_queued = @queued, error_count = @errors, error_text = @err,
           tasks_created = @tasks                                                          -- 438
     WHERE run_id = @run;
    END TRY
    BEGIN CATCH
        -- Never leave the lock behind on a pooled connection.
        IF XACT_STATE() <> 0 ROLLBACK;
        IF CURSOR_STATUS('local', 'org_cur') >= -1
        BEGIN
            IF CURSOR_STATUS('local', 'org_cur') >= 0 CLOSE org_cur;
            DEALLOCATE org_cur;
        END
        EXEC sp_releaseapplock @Resource = N'grac_practice.asset_scheduler', @LockOwner = N'Session';
        IF @run IS NOT NULL
            UPDATE grac_practice.asset_scheduler_run
               SET finished_dt = SYSUTCDATETIME(), result = N'FAILED', error_count = @errors + 1,
                   error_text = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, ERROR_MESSAGE()), 8000)
             WHERE run_id = @run;
        THROW;
    END CATCH
    EXEC sp_releaseapplock @Resource = N'grac_practice.asset_scheduler', @LockOwner = N'Session';

    SELECT run_id AS RunId, result AS Result, organizations AS Organizations, renewals_started AS RenewalsStarted,
           attestations_generated AS AttestationsGenerated, occurrences_opened AS OccurrencesOpened,
           occurrences_closed AS OccurrencesClosed, notifications_queued AS NotificationsQueued,
           error_count AS ErrorCount, error_text AS ErrorText, tasks_created AS TasksCreated   -- 438
      FROM grac_practice.asset_scheduler_run WHERE run_id = @run;
END
GO
GO
PRINT '450: sp_asset_scheduler_run re-issued.';
GO
-- =====================================================================
-- 9. Menu: Asset & Contract -> Asset Governance (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-governance', N'Asset Governance', N'Practice/Index/asset-governance', 365, N'gauge-high', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-450', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-450');
PRINT CONCAT('450: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-450', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-governance' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 1, N'Active', @active_rs, N'seed-450', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-governance'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('450: Admin grants inserted: ', @@ROWCOUNT);
GO
-- =====================================================================
-- 10. Verification
-- =====================================================================
SELECT '450-a objects' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_governance_kpi','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_governance_setting','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_governance_org_setting','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_governance_relationship_rule','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_governance_snapshot','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_governance_snapshot_kpi','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_governance_snapshot_item','U') IS NOT NULL
             AND (SELECT COUNT(*) FROM grac_practice.asset_governance_kpi) = 10
             AND OBJECT_ID('grac_practice.fn_asset_governance_effective') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_governance_assets') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_governance_items') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_governance_snapshot_take','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_governance_get','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_governance_items','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_governance_snapshots','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_governance_settings','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_governance_setting_save','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_governance_org_setting_save','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_governance_relationship_rule_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT '450-b scheduler re-issue' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_scheduler_run')) LIKE '%sp_asset_governance_snapshot_take%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_scheduler_run')) LIKE '%sp_asset_privacy_sync%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_scheduler_run')) LIKE '%sp_asset_consistency_evaluate%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
-- Every KPI branch runs for every organization; nothing is written. Each
-- record row has a valid outcome and an excluded row contributes nothing.
SELECT '450-c record rows' AS Check_,
       (SELECT COUNT(*) FROM grac_practice.organization o CROSS APPLY grac_practice.fn_asset_governance_items(o.organization_id, NULL) i) AS RecordRows,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.organization o
                              CROSS APPLY grac_practice.fn_asset_governance_items(o.organization_id, NULL) i
                              WHERE i.Outcome NOT IN (N'PASS', N'FAIL', N'EXCLUDED')
                                 OR (i.Outcome = N'EXCLUDED' AND (i.Numerator <> 0 OR i.Denominator <> 0))
                                 OR i.Numerator > i.Denominator OR i.Numerator < 0)
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT '450-d menu' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-governance' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END AS Result;
GO

/* =====================================================================
   UAT (asset-governance VIEW / EDIT; asset data from 428-448)
   ---------------------------------------------------------------------
   1. Asset Governance -> Take snapshot: ten KPI cards with score, rating
      against target / warning, numerator / denominator, failing and
      excluded counts; the overall score. Take snapshot again with no data
      change -> "No change since the current snapshot" (UNCHANGED).
   2. Open a card -> KPI detail: formula, numerator, denominator,
      population, as-of, exclusions, zero-denominator and rounding text;
      the record grid (Failing / Passing / Excluded) adds up exactly to the
      card (numerator = sum of passing contributions, denominator = passing
      + failing contributions).
   3. Clear the owner of an asset in use and take a snapshot -> Ownership
      Completeness drops, the asset is listed as failing ("No asset
      owner."); History shows version 2 of today and version 1 kept as
      superseded and still openable.
   4. Settings: set Attestation Compliance target 99 / warning 90 / period
      30 days -> the next snapshot uses them; disable a KPI -> shown as
      disabled and left out of the overall score; warning above target
      for a higher-is-better KPI refused (53082).
   5. Settings -> Relationship requirements: asset type Virtual Machine
      requires 1 "Is hosted on" (asset as source) -> Relationship
      Completeness lists every VM in use; one with no Active Hosted On
      relationship fails.
   6. A source with expected interval 24 h added 10 days ago and 7
      completed batches on different days -> Connector Availability
      7 / 10 (one decimal: 70.0).
   7. No discovery source -> Discovery Freshness and Connector
      Availability show "Not applicable" and are not in the overall score.
   8. Run the asset scheduler -> one snapshot per organization for today;
      a second run the same day takes none.
   ===================================================================== */
