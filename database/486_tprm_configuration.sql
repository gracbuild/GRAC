-- =====================================================================
-- 486_tprm_configuration.sql
--
-- REQUEST (2026-10-24)
-- --------------------
--   BRD "GRAC -- Third-Party Risk Management (TPRM)" v1.0. Section 13
--   asks for the baseline configuration and the tenant customization
--   model BEFORE the operational workflow. This is that layer. The
--   operational records (third parties, engagements, assessments,
--   decisions, reviews) follow in 488 / 489. Design, ERD and integration
--   map: docs/tprm.md.
--
-- THE THREE LAYERS (BRD 6.3)
-- --------------------------
--   Layer 1  GRAC baseline         rows with organization_id IS NULL.
--                                  Maintained by the platform
--                                  administrator (PM_ADMIN) only.
--   Layer 2  Organization config   rows with organization_id = the org.
--                                  Either an ADDITION (baseline_*_id
--                                  NULL) or an OVERRIDE of one baseline
--                                  row (baseline_*_id set: relabel,
--                                  reorder, change values, or hide).
--   Layer 3  Operational records   488 / 489 -- they store CODES and the
--                                  template VERSION they were assessed
--                                  with, never a pointer that a later
--                                  configuration change could move.
--
--   A baseline change therefore never rewrites an organization row: the
--   override row is the organization's and stays as it is. Versioned
--   templates (risk models, questionnaires) go further: an organization
--   ADOPTS a baseline template into its own copy, edits a Draft version,
--   and activates it. When GRAC publishes a newer baseline version the
--   organization sees "update available", can COMPARE the versions and
--   adopts the update into a NEW Draft of its own -- nothing changes
--   until the organization activates it, and every assessment keeps the
--   version it was made with (BRD 6.3, 11, acceptance 7 / 8).
--
-- WHAT THIS FILE CREATES
-- ----------------------
--   Tables
--     tprm_reference_list / tprm_reference_value   classification lists
--         (service categories, provider types, criticality, lifecycle
--         statuses, service models, engagement types, data exposure,
--         access, decisions, review triggers, onboarding / exit checks,
--         ...). Values carry an optional meaning_code the workflow relies
--         on (e.g. a decision label means APPROVE) and a rank.
--     tprm_library_item    safeguards, evidence requirements, treatment
--         actions -- with BRD 5.3 provenance (source authority, document,
--         version, reference, applicability, is_regulatory).
--     tprm_approval_rule   approval paths and escalation thresholds.
--     tprm_review_rule     review frequency, evidence renewal, expiry
--         alert windows, reassessment triggers.
--     tprm_approval_delegation  time-bound delegation of an approver.
--     tprm_custom_field / tprm_custom_field_value   organization-defined
--         fields (text, number, date, Boolean, single / multi select,
--         reference) with mandatory, default, validation, options,
--         conditional visibility, access roles, search / filter / report
--         flags (BRD 6.2).
--     tprm_template / tprm_template_version  versioned RISK_MODEL and
--         QUESTIONNAIRE templates, baseline or organization.
--     tprm_rm_dimension / _factor / _factor_option / _band / _tier_rule
--         the risk model of one version (BRD 3 step 2 dimensions).
--     tprm_q_section / tprm_q_question / tprm_q_option  questionnaire
--         content of one version (sections, response types, mandatory,
--         applicability conditions, conditional follow-ups).
--   Functions (the effective configuration of an organization -- ONE
--   place each, used by every screen and every operational procedure)
--     fn_tprm_reference_effective, fn_tprm_library_effective,
--     fn_tprm_approval_rule_effective, fn_tprm_review_rule_effective,
--     fn_tprm_template_effective, fn_tprm_split_codes
--   Procedures
--     sp_tprm_audit (internal), sp_tprm_config_reference_get,
--     sp_tprm_reference_value_save, sp_tprm_reference_value_override,
--     sp_tprm_library_list, sp_tprm_library_save, sp_tprm_library_override,
--     sp_tprm_rules_get, sp_tprm_approval_rule_save, sp_tprm_review_rule_save,
--     sp_tprm_delegation_save, sp_tprm_custom_field_list,
--     sp_tprm_custom_field_save, sp_tprm_custom_values_save (internal),
--     sp_tprm_template_list, sp_tprm_template_version_get,
--     sp_tprm_template_create, sp_tprm_template_adopt,
--     sp_tprm_template_new_version, sp_tprm_template_version_header_save,
--     sp_tprm_template_version_copy (internal), sp_tprm_rm_item_save,
--     sp_tprm_q_item_save, sp_tprm_template_item_remove,
--     sp_tprm_template_version_activate, sp_tprm_template_retire,
--     sp_tprm_template_compare
--
-- ERROR NUMBERS: 57500-57599 (user-facing sentences).
-- DEPENDS ON: 001/002 (organization, organization_employee,
--   organization_role, practice_audit_trace), 146 (evidence_type_master
--   is optional -- referenced by id only when present).
-- Rollback: 486_tprm_configuration_rollback.sql
-- SAFE TO RE-RUN. ASCII-only. SQL Server 2017+ (STRING_SPLIT, OPENJSON, STRING_AGG).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.organization','U') IS NULL
BEGIN PRINT 'ABORT (486): grac_practice.organization missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
BEGIN PRINT 'ABORT (486): grac_practice.organization_employee missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
BEGIN PRINT 'ABORT (486): grac_practice.organization_role missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_audit_trace','U') IS NULL
BEGIN PRINT 'ABORT (486): grac_practice.practice_audit_trace missing.'; SET @ok = 0; END
IF (SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()) < 130
BEGIN PRINT 'ABORT (486): database compatibility level 130+ is required (STRING_SPLIT / OPENJSON).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('486_tprm_configuration: prerequisites missing -- see the messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Reference lists and values
-- =====================================================================
IF OBJECT_ID('grac_practice.tprm_reference_list','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_reference_list(
        list_code      NVARCHAR(60)   NOT NULL CONSTRAINT pk_pm_tprm_reference_list PRIMARY KEY,
        list_name      NVARCHAR(200)  NOT NULL,
        description    NVARCHAR(1000) NULL,
        -- EXTENSIBLE: an organization may add values, relabel, reorder and
        --             hide baseline values.
        -- MEANING   : the workflow reads meaning_code; an organization may
        --             relabel / reorder / hide and add values, but every
        --             value it adds must name one of the meanings below.
        scope_rule     NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_rl_scope DEFAULT N'EXTENSIBLE'
            CONSTRAINT ck_pm_tprm_rl_scope CHECK (scope_rule IN (N'EXTENSIBLE', N'MEANING')),
        allowed_meanings NVARCHAR(400) NULL,      -- comma separated, MEANING lists only
        display_order  INT            NOT NULL CONSTRAINT df_pm_tprm_rl_order DEFAULT 100,
        entered_by     NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_rl_eby DEFAULT N'system',
        entered_dt     DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_rl_edt DEFAULT SYSUTCDATETIME(),
        updated_by     NVARCHAR(100)  NULL,
        updated_dt     DATETIME2      NULL
    );
    PRINT '486: tprm_reference_list created.';
END
GO

IF OBJECT_ID('grac_practice.tprm_reference_value','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_reference_value(
        value_id          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_reference_value PRIMARY KEY,
        list_code         NVARCHAR(60)   NOT NULL
            CONSTRAINT fk_pm_tprm_rv_list REFERENCES grac_practice.tprm_reference_list(list_code),
        organization_id   BIGINT         NULL      -- NULL = GRAC baseline (Layer 1)
            CONSTRAINT fk_pm_tprm_rv_org REFERENCES grac_practice.organization(organization_id),
        value_code        NVARCHAR(60)   NOT NULL,
        label             NVARCHAR(200)  NOT NULL,
        description       NVARCHAR(1000) NULL,
        meaning_code      NVARCHAR(40)   NULL,
        rank_no           INT            NULL,      -- ordering / severity used by rules
        color_hex         NVARCHAR(9)    NULL,
        is_mandatory      BIT            NOT NULL CONSTRAINT df_pm_tprm_rv_mand DEFAULT 0,  -- checks lists
        display_order     INT            NOT NULL CONSTRAINT df_pm_tprm_rv_order DEFAULT 100,
        -- Layer 2 override of one baseline value (same value_code).
        baseline_value_id BIGINT         NULL
            CONSTRAINT fk_pm_tprm_rv_baseline REFERENCES grac_practice.tprm_reference_value(value_id),
        is_hidden         BIT            NOT NULL CONSTRAINT df_pm_tprm_rv_hidden DEFAULT 0,
        status            NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_rv_status DEFAULT N'Active'
            CONSTRAINT ck_pm_tprm_rv_status CHECK (status IN (N'Active', N'Retired')),
        record_version    ROWVERSION     NOT NULL,
        entered_by        NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_rv_eby DEFAULT N'system',
        entered_dt        DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_rv_edt DEFAULT SYSUTCDATETIME(),
        updated_by        NVARCHAR(100)  NULL,
        updated_dt        DATETIME2      NULL,
        CONSTRAINT ck_pm_tprm_rv_override CHECK (baseline_value_id IS NULL OR organization_id IS NOT NULL)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_rv_baseline ON grac_practice.tprm_reference_value(list_code, value_code)
        WHERE organization_id IS NULL;
    CREATE UNIQUE INDEX ux_pm_tprm_rv_org ON grac_practice.tprm_reference_value(organization_id, list_code, value_code)
        WHERE organization_id IS NOT NULL;
    PRINT '486: tprm_reference_value created.';
END
GO

-- =====================================================================
-- 2. Library: safeguards, evidence requirements, treatment actions
-- =====================================================================
IF OBJECT_ID('grac_practice.tprm_library_item','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_library_item(
        item_id                   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_library_item PRIMARY KEY,
        library_code              NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_tprm_li_library CHECK (library_code IN (N'SAFEGUARD', N'EVIDENCE_REQUIREMENT', N'TREATMENT_ACTION')),
        organization_id           BIGINT         NULL
            CONSTRAINT fk_pm_tprm_li_org REFERENCES grac_practice.organization(organization_id),
        item_code                 NVARCHAR(60)   NOT NULL,
        item_name                 NVARCHAR(250)  NOT NULL,
        description               NVARCHAR(2000) NULL,
        category_code             NVARCHAR(60)   NULL,   -- SAFEGUARD_CATEGORY value
        dimension_code            NVARCHAR(60)   NULL,   -- risk dimension the safeguard mitigates
        guidance                  NVARCHAR(2000) NULL,
        effectiveness_criteria    NVARCHAR(2000) NULL,
        is_contract_clause        BIT            NOT NULL CONSTRAINT df_pm_tprm_li_clause DEFAULT 0,
        evidence_requirement_code NVARCHAR(60)   NULL,   -- SAFEGUARD: suggested evidence
        evidence_type_id          INT            NULL,   -- EVIDENCE_REQUIREMENT: Evidence Center type
        validity_months           INT            NULL,   -- EVIDENCE_REQUIREMENT
        review_required           BIT            NOT NULL CONSTRAINT df_pm_tprm_li_review DEFAULT 1,
        default_due_days          INT            NULL,   -- TREATMENT_ACTION
        default_owner_hint        NVARCHAR(200)  NULL,   -- TREATMENT_ACTION
        -- BRD 5.3 provenance. is_regulatory = 1 only when the source and
        -- its applicability have been established; GRAC's generic baseline
        -- rows are 0 and cite related standards as "informative".
        source_authority          NVARCHAR(200)  NULL,
        source_document           NVARCHAR(300)  NULL,
        source_version            NVARCHAR(100)  NULL,
        source_reference          NVARCHAR(300)  NULL,
        applicability_note        NVARCHAR(1000) NULL,
        is_regulatory             BIT            NOT NULL CONSTRAINT df_pm_tprm_li_reg DEFAULT 0,
        display_order             INT            NOT NULL CONSTRAINT df_pm_tprm_li_order DEFAULT 100,
        baseline_item_id          BIGINT         NULL
            CONSTRAINT fk_pm_tprm_li_baseline REFERENCES grac_practice.tprm_library_item(item_id),
        is_hidden                 BIT            NOT NULL CONSTRAINT df_pm_tprm_li_hidden DEFAULT 0,
        status                    NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_li_status DEFAULT N'Active'
            CONSTRAINT ck_pm_tprm_li_status CHECK (status IN (N'Active', N'Retired')),
        record_version            ROWVERSION     NOT NULL,
        entered_by                NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_li_eby DEFAULT N'system',
        entered_dt                DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_li_edt DEFAULT SYSUTCDATETIME(),
        updated_by                NVARCHAR(100)  NULL,
        updated_dt                DATETIME2      NULL,
        CONSTRAINT ck_pm_tprm_li_override CHECK (baseline_item_id IS NULL OR organization_id IS NOT NULL)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_li_baseline ON grac_practice.tprm_library_item(library_code, item_code)
        WHERE organization_id IS NULL;
    CREATE UNIQUE INDEX ux_pm_tprm_li_org ON grac_practice.tprm_library_item(organization_id, library_code, item_code)
        WHERE organization_id IS NOT NULL;
    PRINT '486: tprm_library_item created.';
END
GO

-- =====================================================================
-- 3. Approval rules, review rules, delegations
-- =====================================================================
IF OBJECT_ID('grac_practice.tprm_approval_rule','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_approval_rule(
        rule_id                 BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_approval_rule PRIMARY KEY,
        organization_id         BIGINT        NULL
            CONSTRAINT fk_pm_tprm_ar_org REFERENCES grac_practice.organization(organization_id),
        rule_code               NVARCHAR(60)  NOT NULL,
        rule_name               NVARCHAR(200) NOT NULL,
        description             NVARCHAR(1000) NULL,
        priority                INT           NOT NULL CONSTRAINT df_pm_tprm_ar_prio DEFAULT 100,
        -- Matches when the residual band rank >= min_band_rank OR the
        -- service criticality rank >= min_criticality_rank (a NULL test is
        -- ignored; both NULL = catch-all). Lowest priority wins.
        min_band_rank           INT           NULL,
        min_criticality_rank    INT           NULL,
        approval_levels         INT           NOT NULL CONSTRAINT df_pm_tprm_ar_levels DEFAULT 1
            CONSTRAINT ck_pm_tprm_ar_levels CHECK (approval_levels BETWEEN 1 AND 3),
        level1_role_name        NVARCHAR(120) NULL,
        level2_role_name        NVARCHAR(120) NULL,
        level3_role_name        NVARCHAR(120) NULL,
        sod_required            BIT           NOT NULL CONSTRAINT df_pm_tprm_ar_sod DEFAULT 1,
        escalate_to_risk_centre BIT           NOT NULL CONSTRAINT df_pm_tprm_ar_esc DEFAULT 0,
        max_acceptance_months   INT           NULL,
        allowed_decision_codes  NVARCHAR(400) NULL,      -- DECISION value codes; NULL = all
        baseline_rule_id        BIGINT        NULL
            CONSTRAINT fk_pm_tprm_ar_baseline REFERENCES grac_practice.tprm_approval_rule(rule_id),
        is_hidden               BIT           NOT NULL CONSTRAINT df_pm_tprm_ar_hidden DEFAULT 0,
        status                  NVARCHAR(20)  NOT NULL CONSTRAINT df_pm_tprm_ar_status DEFAULT N'Active'
            CONSTRAINT ck_pm_tprm_ar_status CHECK (status IN (N'Active', N'Retired')),
        record_version          ROWVERSION    NOT NULL,
        entered_by              NVARCHAR(100) NOT NULL CONSTRAINT df_pm_tprm_ar_eby DEFAULT N'system',
        entered_dt              DATETIME2     NOT NULL CONSTRAINT df_pm_tprm_ar_edt DEFAULT SYSUTCDATETIME(),
        updated_by              NVARCHAR(100) NULL,
        updated_dt              DATETIME2     NULL,
        CONSTRAINT ck_pm_tprm_ar_override CHECK (baseline_rule_id IS NULL OR organization_id IS NOT NULL)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_ar_baseline ON grac_practice.tprm_approval_rule(rule_code) WHERE organization_id IS NULL;
    CREATE UNIQUE INDEX ux_pm_tprm_ar_org ON grac_practice.tprm_approval_rule(organization_id, rule_code) WHERE organization_id IS NOT NULL;
    PRINT '486: tprm_approval_rule created.';
END
GO

IF OBJECT_ID('grac_practice.tprm_review_rule','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_review_rule(
        rule_id                    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_review_rule PRIMARY KEY,
        organization_id            BIGINT        NULL
            CONSTRAINT fk_pm_tprm_rr_org REFERENCES grac_practice.organization(organization_id),
        rule_code                  NVARCHAR(60)  NOT NULL,
        rule_name                  NVARCHAR(200) NOT NULL,
        description                NVARCHAR(1000) NULL,
        priority                   INT           NOT NULL CONSTRAINT df_pm_tprm_rr_prio DEFAULT 100,
        min_band_rank              INT           NULL,
        min_criticality_rank       INT           NULL,
        review_frequency_months    INT           NOT NULL CONSTRAINT df_pm_tprm_rr_freq DEFAULT 12,
        evidence_renewal_months    INT           NULL,
        contract_expiry_alert_days INT           NULL,
        cert_expiry_alert_days     INT           NULL,
        review_lead_days           INT           NOT NULL CONSTRAINT df_pm_tprm_rr_lead DEFAULT 30,
        reassessment_trigger_codes NVARCHAR(600) NULL,   -- REVIEW_TRIGGER codes that require reassessment
        monitoring_note            NVARCHAR(1000) NULL,
        baseline_rule_id           BIGINT        NULL
            CONSTRAINT fk_pm_tprm_rr_baseline REFERENCES grac_practice.tprm_review_rule(rule_id),
        is_hidden                  BIT           NOT NULL CONSTRAINT df_pm_tprm_rr_hidden DEFAULT 0,
        status                     NVARCHAR(20)  NOT NULL CONSTRAINT df_pm_tprm_rr_status DEFAULT N'Active'
            CONSTRAINT ck_pm_tprm_rr_status CHECK (status IN (N'Active', N'Retired')),
        record_version             ROWVERSION    NOT NULL,
        entered_by                 NVARCHAR(100) NOT NULL CONSTRAINT df_pm_tprm_rr_eby DEFAULT N'system',
        entered_dt                 DATETIME2     NOT NULL CONSTRAINT df_pm_tprm_rr_edt DEFAULT SYSUTCDATETIME(),
        updated_by                 NVARCHAR(100) NULL,
        updated_dt                 DATETIME2     NULL,
        CONSTRAINT ck_pm_tprm_rr_override CHECK (baseline_rule_id IS NULL OR organization_id IS NOT NULL),
        CONSTRAINT ck_pm_tprm_rr_freq CHECK (review_frequency_months BETWEEN 1 AND 120)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_rr_baseline ON grac_practice.tprm_review_rule(rule_code) WHERE organization_id IS NULL;
    CREATE UNIQUE INDEX ux_pm_tprm_rr_org ON grac_practice.tprm_review_rule(organization_id, rule_code) WHERE organization_id IS NOT NULL;
    PRINT '486: tprm_review_rule created.';
END
GO

IF OBJECT_ID('grac_practice.tprm_approval_delegation','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_approval_delegation(
        delegation_id         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_approval_delegation PRIMARY KEY,
        organization_id       BIGINT        NOT NULL
            CONSTRAINT fk_pm_tprm_ad_org REFERENCES grac_practice.organization(organization_id),
        from_employee_id      BIGINT        NOT NULL
            CONSTRAINT fk_pm_tprm_ad_from REFERENCES grac_practice.organization_employee(employee_id),
        to_employee_id        BIGINT        NOT NULL
            CONSTRAINT fk_pm_tprm_ad_to REFERENCES grac_practice.organization_employee(employee_id),
        valid_from            DATE          NOT NULL,
        valid_to              DATE          NOT NULL,
        reason                NVARCHAR(500) NULL,
        status                NVARCHAR(20)  NOT NULL CONSTRAINT df_pm_tprm_ad_status DEFAULT N'Active'
            CONSTRAINT ck_pm_tprm_ad_status CHECK (status IN (N'Active', N'Revoked')),
        entered_by            NVARCHAR(100) NOT NULL CONSTRAINT df_pm_tprm_ad_eby DEFAULT N'system',
        entered_dt            DATETIME2     NOT NULL CONSTRAINT df_pm_tprm_ad_edt DEFAULT SYSUTCDATETIME(),
        updated_by            NVARCHAR(100) NULL,
        updated_dt            DATETIME2     NULL,
        CONSTRAINT ck_pm_tprm_ad_dates CHECK (valid_to >= valid_from),
        CONSTRAINT ck_pm_tprm_ad_self CHECK (to_employee_id <> from_employee_id)
    );
    PRINT '486: tprm_approval_delegation created.';
END
GO

-- =====================================================================
-- 4. Custom fields (BRD 6.2)
-- =====================================================================
IF OBJECT_ID('grac_practice.tprm_custom_field','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_custom_field(
        field_id                 BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_custom_field PRIMARY KEY,
        organization_id          BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_cf_org REFERENCES grac_practice.organization(organization_id),
        entity_code              NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_tprm_cf_entity CHECK (entity_code IN (N'THIRD_PARTY', N'ENGAGEMENT', N'FINDING', N'REVIEW')),
        field_code               NVARCHAR(60)   NOT NULL,
        label                    NVARCHAR(200)  NOT NULL,
        description              NVARCHAR(1000) NULL,
        data_type                NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_tprm_cf_type CHECK (data_type IN (N'TEXT', N'NUMBER', N'DATE', N'BOOLEAN',
                                                               N'SINGLE_SELECT', N'MULTI_SELECT', N'REFERENCE')),
        is_mandatory             BIT            NOT NULL CONSTRAINT df_pm_tprm_cf_mand DEFAULT 0,
        default_value            NVARCHAR(500)  NULL,
        validation_regex         NVARCHAR(300)  NULL,      -- checked by the screen (SQL has no regex)
        min_value                DECIMAL(19,4)  NULL,
        max_value                DECIMAL(19,4)  NULL,
        max_length               INT            NULL,
        options_json             NVARCHAR(MAX)  NULL,      -- [{"code":"A","label":"..."}]
        reference_kind           NVARCHAR(60)   NULL,      -- EMPLOYEE | THIRD_PARTY | VENDOR | BUSINESS_FUNCTION | LIST:<list_code>
        visible_when_field_code  NVARCHAR(60)   NULL,
        visible_when_value       NVARCHAR(200)  NULL,
        access_role_names        NVARCHAR(600)  NULL,      -- NULL = everyone who can open the record
        is_searchable            BIT            NOT NULL CONSTRAINT df_pm_tprm_cf_search DEFAULT 0,
        is_filterable            BIT            NOT NULL CONSTRAINT df_pm_tprm_cf_filter DEFAULT 0,
        is_reportable            BIT            NOT NULL CONSTRAINT df_pm_tprm_cf_report DEFAULT 1,
        display_order            INT            NOT NULL CONSTRAINT df_pm_tprm_cf_order DEFAULT 100,
        status                   NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_cf_status DEFAULT N'Active'
            CONSTRAINT ck_pm_tprm_cf_status CHECK (status IN (N'Active', N'Retired')),
        record_version           ROWVERSION     NOT NULL,
        entered_by               NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_cf_eby DEFAULT N'system',
        entered_dt               DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_cf_edt DEFAULT SYSUTCDATETIME(),
        updated_by               NVARCHAR(100)  NULL,
        updated_dt               DATETIME2      NULL,
        CONSTRAINT uq_pm_tprm_cf_code UNIQUE (organization_id, entity_code, field_code)
    );
    PRINT '486: tprm_custom_field created.';
END
GO

IF OBJECT_ID('grac_practice.tprm_custom_field_value','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_custom_field_value(
        value_id        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_custom_field_value PRIMARY KEY,
        organization_id BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_cfv_org REFERENCES grac_practice.organization(organization_id),
        field_id        BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_cfv_field REFERENCES grac_practice.tprm_custom_field(field_id),
        entity_code     NVARCHAR(30)   NOT NULL,
        record_id       BIGINT         NOT NULL,
        value_text      NVARCHAR(2000) NULL,      -- TEXT, SINGLE_SELECT code, MULTI_SELECT codes (comma separated)
        value_number    DECIMAL(19,4)  NULL,
        value_date      DATE           NULL,
        value_bool      BIT            NULL,
        value_ref_id    BIGINT         NULL,      -- REFERENCE
        updated_by      NVARCHAR(100)  NULL,
        updated_dt      DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_cfv_udt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_tprm_cfv UNIQUE (field_id, record_id)
    );
    CREATE INDEX ix_pm_tprm_cfv_record ON grac_practice.tprm_custom_field_value(organization_id, entity_code, record_id);
    PRINT '486: tprm_custom_field_value created.';
END
GO

-- =====================================================================
-- 5. Versioned templates -- risk models and questionnaires
-- =====================================================================
IF OBJECT_ID('grac_practice.tprm_template','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_template(
        template_id          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_template PRIMARY KEY,
        organization_id      BIGINT         NULL
            CONSTRAINT fk_pm_tprm_t_org REFERENCES grac_practice.organization(organization_id),
        template_kind        NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_tprm_t_kind CHECK (template_kind IN (N'RISK_MODEL', N'QUESTIONNAIRE')),
        template_code        NVARCHAR(60)   NOT NULL,
        template_name        NVARCHAR(250)  NOT NULL,
        description          NVARCHAR(2000) NULL,
        is_default           BIT            NOT NULL CONSTRAINT df_pm_tprm_t_default DEFAULT 0,  -- RISK_MODEL used when none adopted
        baseline_template_id BIGINT         NULL      -- the GRAC template this organization copy was adopted from
            CONSTRAINT fk_pm_tprm_t_baseline REFERENCES grac_practice.tprm_template(template_id),
        current_version_id   BIGINT         NULL,     -- the ACTIVE version (FK added below)
        status               NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_t_status DEFAULT N'Active'
            CONSTRAINT ck_pm_tprm_t_status CHECK (status IN (N'Active', N'Retired')),
        is_sample            BIT            NOT NULL CONSTRAINT df_pm_tprm_t_sample DEFAULT 0,
        entered_by           NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_t_eby DEFAULT N'system',
        entered_dt           DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_t_edt DEFAULT SYSUTCDATETIME(),
        updated_by           NVARCHAR(100)  NULL,
        updated_dt           DATETIME2      NULL,
        CONSTRAINT ck_pm_tprm_t_adopt CHECK (baseline_template_id IS NULL OR organization_id IS NOT NULL)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_t_baseline ON grac_practice.tprm_template(template_kind, template_code) WHERE organization_id IS NULL;
    CREATE UNIQUE INDEX ux_pm_tprm_t_org ON grac_practice.tprm_template(organization_id, template_kind, template_code) WHERE organization_id IS NOT NULL;
    PRINT '486: tprm_template created.';
END
GO

IF OBJECT_ID('grac_practice.tprm_template_version','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_template_version(
        version_id                BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_template_version PRIMARY KEY,
        template_id               BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_tv_template REFERENCES grac_practice.tprm_template(template_id),
        version_no                INT            NOT NULL,
        status                    NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_tv_status DEFAULT N'DRAFT'
            CONSTRAINT ck_pm_tprm_tv_status CHECK (status IN (N'DRAFT', N'ACTIVE', N'SUPERSEDED', N'DISCARDED')),
        based_on_version_id       BIGINT         NULL
            CONSTRAINT fk_pm_tprm_tv_based REFERENCES grac_practice.tprm_template_version(version_id),
        baseline_version_id       BIGINT         NULL     -- the GRAC version this content derives from
            CONSTRAINT fk_pm_tprm_tv_baseline REFERENCES grac_practice.tprm_template_version(version_id),
        change_summary            NVARCHAR(2000) NULL,
        -- QUESTIONNAIRE applicability (when it is generated for an engagement)
        is_core                   BIT            NOT NULL CONSTRAINT df_pm_tprm_tv_core DEFAULT 0,
        applies_service_categories NVARCHAR(1000) NULL,   -- SERVICE_CATEGORY codes; NULL = every category
        applies_min_tier_rank     INT            NULL,    -- DD_TIER rank; NULL = every tier
        applies_engagement_types  NVARCHAR(600)  NULL,    -- ENGAGEMENT_TYPE codes; NULL = every type
        -- RISK_MODEL scoring rules (BRD 2.6: not hard-coded)
        aggregation_method        NVARCHAR(30)   NULL
            CONSTRAINT ck_pm_tprm_tv_agg CHECK (aggregation_method IS NULL OR aggregation_method IN (N'WEIGHTED_AVERAGE', N'HIGHEST_DIMENSION', N'BLENDED')),
        blend_pct                 DECIMAL(5,2)   NULL,    -- BLENDED: share of the highest dimension
        effective_reduction_pct   DECIMAL(5,2)   NULL,    -- reduction of a dimension by a VERIFIED effective safeguard
        partial_reduction_pct     DECIMAL(5,2)   NULL,    -- ... by a VERIFIED partially effective safeguard
        residual_floor_pct        DECIMAL(5,2)   NULL,    -- residual never below this share of inherent
        deficiency_uplift_pct     DECIMAL(5,2)   NULL,    -- per open High / Critical deficiency on the dimension
        created_by                NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_tv_cby DEFAULT N'system',
        created_dt                DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_tv_cdt DEFAULT SYSUTCDATETIME(),
        activated_by              NVARCHAR(100)  NULL,
        activated_dt              DATETIME2      NULL,
        updated_by                NVARCHAR(100)  NULL,
        updated_dt                DATETIME2      NULL,
        CONSTRAINT uq_pm_tprm_tv_no UNIQUE (template_id, version_no)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_tv_one_active ON grac_practice.tprm_template_version(template_id) WHERE status = N'ACTIVE';
    CREATE UNIQUE INDEX ux_pm_tprm_tv_one_draft  ON grac_practice.tprm_template_version(template_id) WHERE status = N'DRAFT';
    PRINT '486: tprm_template_version created.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'fk_pm_tprm_t_current')
    ALTER TABLE grac_practice.tprm_template ADD CONSTRAINT fk_pm_tprm_t_current
        FOREIGN KEY (current_version_id) REFERENCES grac_practice.tprm_template_version(version_id);
GO

-- ---- risk model content ---------------------------------------------
IF OBJECT_ID('grac_practice.tprm_rm_dimension','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_rm_dimension(
        dimension_id   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_rm_dimension PRIMARY KEY,
        version_id     BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rmd_version REFERENCES grac_practice.tprm_template_version(version_id),
        dimension_code NVARCHAR(60)   NOT NULL,
        dimension_name NVARCHAR(200)  NOT NULL,
        description    NVARCHAR(1000) NULL,
        weight         DECIMAL(9,2)   NOT NULL CONSTRAINT df_pm_tprm_rmd_weight DEFAULT 1,
        display_order  INT            NOT NULL CONSTRAINT df_pm_tprm_rmd_order DEFAULT 100,
        CONSTRAINT uq_pm_tprm_rmd UNIQUE (version_id, dimension_code),
        CONSTRAINT ck_pm_tprm_rmd_weight CHECK (weight >= 0)
    );
END
GO
IF OBJECT_ID('grac_practice.tprm_rm_factor','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_rm_factor(
        factor_id      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_rm_factor PRIMARY KEY,
        version_id     BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rmf_version REFERENCES grac_practice.tprm_template_version(version_id),
        dimension_id   BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rmf_dimension REFERENCES grac_practice.tprm_rm_dimension(dimension_id),
        factor_code    NVARCHAR(60)   NOT NULL,
        question_text  NVARCHAR(1000) NOT NULL,
        guidance       NVARCHAR(2000) NULL,
        is_mandatory   BIT            NOT NULL CONSTRAINT df_pm_tprm_rmf_mand DEFAULT 1,
        -- Optional suggestion from the engagement scope (488):
        -- SERVICE_CRITICALITY | DATA_EXPOSURE | ACCESS | FOURTH_PARTY_COUNT | IS_EXISTING
        prefill_source NVARCHAR(40)   NULL,
        display_order  INT            NOT NULL CONSTRAINT df_pm_tprm_rmf_order DEFAULT 100,
        CONSTRAINT uq_pm_tprm_rmf UNIQUE (version_id, factor_code)
    );
END
GO
IF OBJECT_ID('grac_practice.tprm_rm_factor_option','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_rm_factor_option(
        option_id          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_rm_factor_option PRIMARY KEY,
        factor_id          BIGINT        NOT NULL
            CONSTRAINT fk_pm_tprm_rmo_factor REFERENCES grac_practice.tprm_rm_factor(factor_id),
        option_code        NVARCHAR(60)  NOT NULL,
        option_label       NVARCHAR(300) NOT NULL,
        score              DECIMAL(9,2)  NOT NULL,
        prefill_match_code NVARCHAR(200) NULL,      -- scope value codes (comma separated) that suggest this option
        display_order      INT           NOT NULL CONSTRAINT df_pm_tprm_rmo_order DEFAULT 100,
        CONSTRAINT uq_pm_tprm_rmo UNIQUE (factor_id, option_code),
        CONSTRAINT ck_pm_tprm_rmo_score CHECK (score >= 0)
    );
END
GO
IF OBJECT_ID('grac_practice.tprm_rm_band','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_rm_band(
        band_id       BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_rm_band PRIMARY KEY,
        version_id    BIGINT        NOT NULL
            CONSTRAINT fk_pm_tprm_rmb_version REFERENCES grac_practice.tprm_template_version(version_id),
        band_code     NVARCHAR(60)  NOT NULL,
        band_name     NVARCHAR(120) NOT NULL,
        -- A score belongs to the band with the highest min_score <= score.
        -- Only the lower bound is stored, so bands can never overlap or
        -- leave a gap; activation requires one band at 0.
        min_score     DECIMAL(6,2)  NOT NULL,
        rank_no       INT           NOT NULL,
        color_hex     NVARCHAR(9)   NULL,
        dd_tier_code  NVARCHAR(60)  NOT NULL,      -- DD_TIER value
        CONSTRAINT uq_pm_tprm_rmb UNIQUE (version_id, band_code),
        CONSTRAINT uq_pm_tprm_rmb_min UNIQUE (version_id, min_score),
        CONSTRAINT ck_pm_tprm_rmb_min CHECK (min_score BETWEEN 0 AND 100)
    );
END
GO
IF OBJECT_ID('grac_practice.tprm_rm_tier_rule','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_rm_tier_rule(
        tier_rule_id     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_rm_tier_rule PRIMARY KEY,
        version_id       BIGINT       NOT NULL
            CONSTRAINT fk_pm_tprm_rmt_version REFERENCES grac_practice.tprm_template_version(version_id),
        -- The tier is the highest of the band's tier and every matching rule.
        condition_kind   NVARCHAR(30) NOT NULL
            CONSTRAINT ck_pm_tprm_rmt_kind CHECK (condition_kind IN (N'CRITICALITY', N'DATA_EXPOSURE', N'ACCESS')),
        condition_code   NVARCHAR(60) NOT NULL,
        min_dd_tier_code NVARCHAR(60) NOT NULL,
        CONSTRAINT uq_pm_tprm_rmt UNIQUE (version_id, condition_kind, condition_code)
    );
END
GO

-- ---- questionnaire content ------------------------------------------
IF OBJECT_ID('grac_practice.tprm_q_section','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_q_section(
        section_id    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_q_section PRIMARY KEY,
        version_id    BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_qs_version REFERENCES grac_practice.tprm_template_version(version_id),
        section_code  NVARCHAR(60)   NOT NULL,
        title         NVARCHAR(250)  NOT NULL,
        description   NVARCHAR(1000) NULL,
        display_order INT            NOT NULL CONSTRAINT df_pm_tprm_qs_order DEFAULT 100,
        CONSTRAINT uq_pm_tprm_qs UNIQUE (version_id, section_code)
    );
END
GO
IF OBJECT_ID('grac_practice.tprm_q_question','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_q_question(
        question_id                 BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_q_question PRIMARY KEY,
        version_id                  BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_qq_version REFERENCES grac_practice.tprm_template_version(version_id),
        section_id                  BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_qq_section REFERENCES grac_practice.tprm_q_section(section_id),
        question_code               NVARCHAR(60)   NOT NULL,
        question_text               NVARCHAR(2000) NOT NULL,
        guidance                    NVARCHAR(2000) NULL,
        response_type               NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_tprm_qq_type CHECK (response_type IN (N'YES_NO', N'SINGLE', N'MULTI', N'TEXT', N'NUMBER', N'DATE')),
        is_mandatory                BIT            NOT NULL CONSTRAINT df_pm_tprm_qq_mand DEFAULT 1,
        evidence_expected           BIT            NOT NULL CONSTRAINT df_pm_tprm_qq_evid DEFAULT 0,
        evidence_requirement_code   NVARCHAR(60)   NULL,
        safeguard_code              NVARCHAR(60)   NULL,
        dimension_code              NVARCHAR(60)   NULL,
        -- Applicability (all given conditions must hold)
        min_tier_rank               INT            NULL,
        applies_service_categories  NVARCHAR(1000) NULL,
        applies_min_data_rank       INT            NULL,
        applies_access_codes        NVARCHAR(600)  NULL,
        -- Conditional follow-up: shown only when the parent's answer is one of the trigger options.
        parent_question_code        NVARCHAR(60)   NULL,
        trigger_option_codes        NVARCHAR(400)  NULL,
        weight                      DECIMAL(9,2)   NOT NULL CONSTRAINT df_pm_tprm_qq_weight DEFAULT 1,
        display_order               INT            NOT NULL CONSTRAINT df_pm_tprm_qq_order DEFAULT 100,
        source_authority            NVARCHAR(200)  NULL,
        source_document             NVARCHAR(300)  NULL,
        source_version              NVARCHAR(100)  NULL,
        source_reference            NVARCHAR(300)  NULL,
        applicability_note          NVARCHAR(1000) NULL,
        is_regulatory               BIT            NOT NULL CONSTRAINT df_pm_tprm_qq_reg DEFAULT 0,
        CONSTRAINT uq_pm_tprm_qq UNIQUE (version_id, question_code)
    );
END
GO
IF OBJECT_ID('grac_practice.tprm_q_option','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_q_option(
        option_id               BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_q_option PRIMARY KEY,
        question_id             BIGINT        NOT NULL
            CONSTRAINT fk_pm_tprm_qo_question REFERENCES grac_practice.tprm_q_question(question_id),
        option_code             NVARCHAR(60)  NOT NULL,
        option_label            NVARCHAR(300) NOT NULL,
        score                   DECIMAL(9,2)  NULL,
        flags_deficiency        BIT           NOT NULL CONSTRAINT df_pm_tprm_qo_def DEFAULT 0,
        deficiency_severity_code NVARCHAR(60) NULL,      -- FINDING_SEVERITY value
        display_order           INT           NOT NULL CONSTRAINT df_pm_tprm_qo_order DEFAULT 100,
        CONSTRAINT uq_pm_tprm_qo UNIQUE (question_id, option_code)
    );
END
GO
PRINT '486: template content tables ready.';
GO

-- =====================================================================
-- 6. Effective configuration -- one function per layer type
-- =====================================================================

-- Comma separated codes -> rows (trimmed, empty removed).
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_split_codes (@codes NVARCHAR(MAX))
RETURNS TABLE
AS
RETURN
SELECT DISTINCT LTRIM(RTRIM(s.value)) AS code
FROM   STRING_SPLIT(ISNULL(@codes, N''), N',') s
WHERE  LTRIM(RTRIM(s.value)) <> N'';
GO

-- Baseline values the organization did not hide, with its overrides
-- applied, plus the organization's own values.
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_reference_effective (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
(
SELECT b.list_code,
       b.value_code,
       COALESCE(o.label, b.label)                 AS label,
       COALESCE(o.description, b.description)     AS description,
       b.meaning_code,
       COALESCE(o.rank_no, b.rank_no)             AS rank_no,
       COALESCE(o.color_hex, b.color_hex)         AS color_hex,
       CASE WHEN o.value_id IS NOT NULL THEN o.is_mandatory ELSE b.is_mandatory END AS is_mandatory,
       COALESCE(o.display_order, b.display_order) AS display_order,
       CASE WHEN o.value_id IS NULL THEN N'GRAC' ELSE N'GRAC_OVERRIDDEN' END AS origin,
       b.value_id                                 AS baseline_value_id,
       o.value_id                                 AS override_value_id
FROM   grac_practice.tprm_reference_value b
LEFT   JOIN grac_practice.tprm_reference_value o
       ON o.baseline_value_id = b.value_id
      AND o.organization_id   = @organization_id
      AND o.status            = N'Active'
WHERE  b.organization_id IS NULL
  AND  b.status = N'Active'
  AND  ISNULL(o.is_hidden, 0) = 0
UNION ALL
SELECT v.list_code, v.value_code, v.label, v.description, v.meaning_code, v.rank_no, v.color_hex,
       v.is_mandatory, v.display_order, N'ORGANIZATION', NULL, v.value_id
FROM   grac_practice.tprm_reference_value v
WHERE  v.organization_id = @organization_id
  AND  v.baseline_value_id IS NULL
  AND  v.status = N'Active'
  AND  v.is_hidden = 0
);
GO

CREATE OR ALTER FUNCTION grac_practice.fn_tprm_library_effective (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
(
SELECT b.library_code,
       b.item_code,
       COALESCE(o.item_name, b.item_name)                           AS item_name,
       COALESCE(o.description, b.description)                      AS description,
       COALESCE(o.category_code, b.category_code)                  AS category_code,
       COALESCE(o.dimension_code, b.dimension_code)                AS dimension_code,
       COALESCE(o.guidance, b.guidance)                            AS guidance,
       COALESCE(o.effectiveness_criteria, b.effectiveness_criteria) AS effectiveness_criteria,
       CASE WHEN o.item_id IS NOT NULL THEN o.is_contract_clause ELSE b.is_contract_clause END AS is_contract_clause,
       COALESCE(o.evidence_requirement_code, b.evidence_requirement_code) AS evidence_requirement_code,
       COALESCE(o.evidence_type_id, b.evidence_type_id)            AS evidence_type_id,
       COALESCE(o.validity_months, b.validity_months)              AS validity_months,
       CASE WHEN o.item_id IS NOT NULL THEN o.review_required ELSE b.review_required END AS review_required,
       COALESCE(o.default_due_days, b.default_due_days)            AS default_due_days,
       COALESCE(o.default_owner_hint, b.default_owner_hint)        AS default_owner_hint,
       b.source_authority, b.source_document, b.source_version, b.source_reference,
       b.applicability_note, b.is_regulatory,
       COALESCE(o.display_order, b.display_order)                  AS display_order,
       CASE WHEN o.item_id IS NULL THEN N'GRAC' ELSE N'GRAC_OVERRIDDEN' END AS origin,
       b.item_id AS baseline_item_id,
       o.item_id AS override_item_id
FROM   grac_practice.tprm_library_item b
LEFT   JOIN grac_practice.tprm_library_item o
       ON o.baseline_item_id = b.item_id
      AND o.organization_id  = @organization_id
      AND o.status           = N'Active'
WHERE  b.organization_id IS NULL
  AND  b.status = N'Active'
  AND  ISNULL(o.is_hidden, 0) = 0
UNION ALL
SELECT i.library_code, i.item_code, i.item_name, i.description, i.category_code, i.dimension_code,
       i.guidance, i.effectiveness_criteria, i.is_contract_clause, i.evidence_requirement_code,
       i.evidence_type_id, i.validity_months, i.review_required, i.default_due_days, i.default_owner_hint,
       i.source_authority, i.source_document, i.source_version, i.source_reference,
       i.applicability_note, i.is_regulatory, i.display_order, N'ORGANIZATION', NULL, i.item_id
FROM   grac_practice.tprm_library_item i
WHERE  i.organization_id = @organization_id
  AND  i.baseline_item_id IS NULL
  AND  i.status = N'Active'
  AND  i.is_hidden = 0
);
GO

CREATE OR ALTER FUNCTION grac_practice.fn_tprm_approval_rule_effective (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
(
SELECT COALESCE(o.rule_id, b.rule_id) AS rule_id, b.rule_code,
       COALESCE(o.rule_name, b.rule_name) AS rule_name,
       COALESCE(o.description, b.description) AS description,
       COALESCE(o.priority, b.priority) AS priority,
       CASE WHEN o.rule_id IS NOT NULL THEN o.min_band_rank        ELSE b.min_band_rank END        AS min_band_rank,
       CASE WHEN o.rule_id IS NOT NULL THEN o.min_criticality_rank ELSE b.min_criticality_rank END AS min_criticality_rank,
       COALESCE(o.approval_levels, b.approval_levels) AS approval_levels,
       CASE WHEN o.rule_id IS NOT NULL THEN o.level1_role_name ELSE b.level1_role_name END AS level1_role_name,
       CASE WHEN o.rule_id IS NOT NULL THEN o.level2_role_name ELSE b.level2_role_name END AS level2_role_name,
       CASE WHEN o.rule_id IS NOT NULL THEN o.level3_role_name ELSE b.level3_role_name END AS level3_role_name,
       CASE WHEN o.rule_id IS NOT NULL THEN o.sod_required ELSE b.sod_required END AS sod_required,
       CASE WHEN o.rule_id IS NOT NULL THEN o.escalate_to_risk_centre ELSE b.escalate_to_risk_centre END AS escalate_to_risk_centre,
       CASE WHEN o.rule_id IS NOT NULL THEN o.max_acceptance_months ELSE b.max_acceptance_months END AS max_acceptance_months,
       CASE WHEN o.rule_id IS NOT NULL THEN o.allowed_decision_codes ELSE b.allowed_decision_codes END AS allowed_decision_codes,
       CASE WHEN o.rule_id IS NULL THEN N'GRAC' ELSE N'GRAC_OVERRIDDEN' END AS origin,
       b.rule_id AS baseline_rule_id
FROM   grac_practice.tprm_approval_rule b
LEFT   JOIN grac_practice.tprm_approval_rule o
       ON o.baseline_rule_id = b.rule_id AND o.organization_id = @organization_id AND o.status = N'Active'
WHERE  b.organization_id IS NULL AND b.status = N'Active' AND ISNULL(o.is_hidden, 0) = 0
UNION ALL
SELECT r.rule_id, r.rule_code, r.rule_name, r.description, r.priority, r.min_band_rank, r.min_criticality_rank,
       r.approval_levels, r.level1_role_name, r.level2_role_name, r.level3_role_name, r.sod_required,
       r.escalate_to_risk_centre, r.max_acceptance_months, r.allowed_decision_codes, N'ORGANIZATION', NULL
FROM   grac_practice.tprm_approval_rule r
WHERE  r.organization_id = @organization_id AND r.baseline_rule_id IS NULL AND r.status = N'Active' AND r.is_hidden = 0
);
GO

CREATE OR ALTER FUNCTION grac_practice.fn_tprm_review_rule_effective (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
(
SELECT COALESCE(o.rule_id, b.rule_id) AS rule_id, b.rule_code,
       COALESCE(o.rule_name, b.rule_name) AS rule_name,
       COALESCE(o.description, b.description) AS description,
       COALESCE(o.priority, b.priority) AS priority,
       CASE WHEN o.rule_id IS NOT NULL THEN o.min_band_rank        ELSE b.min_band_rank END        AS min_band_rank,
       CASE WHEN o.rule_id IS NOT NULL THEN o.min_criticality_rank ELSE b.min_criticality_rank END AS min_criticality_rank,
       COALESCE(o.review_frequency_months, b.review_frequency_months) AS review_frequency_months,
       CASE WHEN o.rule_id IS NOT NULL THEN o.evidence_renewal_months    ELSE b.evidence_renewal_months END    AS evidence_renewal_months,
       CASE WHEN o.rule_id IS NOT NULL THEN o.contract_expiry_alert_days ELSE b.contract_expiry_alert_days END AS contract_expiry_alert_days,
       CASE WHEN o.rule_id IS NOT NULL THEN o.cert_expiry_alert_days     ELSE b.cert_expiry_alert_days END     AS cert_expiry_alert_days,
       COALESCE(o.review_lead_days, b.review_lead_days) AS review_lead_days,
       CASE WHEN o.rule_id IS NOT NULL THEN o.reassessment_trigger_codes ELSE b.reassessment_trigger_codes END AS reassessment_trigger_codes,
       COALESCE(o.monitoring_note, b.monitoring_note) AS monitoring_note,
       CASE WHEN o.rule_id IS NULL THEN N'GRAC' ELSE N'GRAC_OVERRIDDEN' END AS origin,
       b.rule_id AS baseline_rule_id
FROM   grac_practice.tprm_review_rule b
LEFT   JOIN grac_practice.tprm_review_rule o
       ON o.baseline_rule_id = b.rule_id AND o.organization_id = @organization_id AND o.status = N'Active'
WHERE  b.organization_id IS NULL AND b.status = N'Active' AND ISNULL(o.is_hidden, 0) = 0
UNION ALL
SELECT r.rule_id, r.rule_code, r.rule_name, r.description, r.priority, r.min_band_rank, r.min_criticality_rank,
       r.review_frequency_months, r.evidence_renewal_months, r.contract_expiry_alert_days, r.cert_expiry_alert_days,
       r.review_lead_days, r.reassessment_trigger_codes, r.monitoring_note, N'ORGANIZATION', NULL
FROM   grac_practice.tprm_review_rule r
WHERE  r.organization_id = @organization_id AND r.baseline_rule_id IS NULL AND r.status = N'Active' AND r.is_hidden = 0
);
GO

-- The templates in force for an organization: its own templates with an
-- ACTIVE version, plus every GRAC template it has neither adopted (with
-- an active version of its own) nor retired for itself.
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_template_effective (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
(
SELECT t.template_id, t.template_kind, t.template_code, t.template_name, t.is_default,
       t.current_version_id AS version_id, N'ORGANIZATION' AS origin, t.baseline_template_id
FROM   grac_practice.tprm_template t
WHERE  t.organization_id = @organization_id
  AND  t.status = N'Active'
  AND  t.current_version_id IS NOT NULL
UNION ALL
SELECT b.template_id, b.template_kind, b.template_code, b.template_name, b.is_default,
       b.current_version_id, N'GRAC', NULL
FROM   grac_practice.tprm_template b
WHERE  b.organization_id IS NULL
  AND  b.status = N'Active'
  AND  b.current_version_id IS NOT NULL
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.tprm_template t
                    WHERE t.organization_id = @organization_id
                      AND t.baseline_template_id = b.template_id
                      AND (t.status = N'Retired' OR t.current_version_id IS NOT NULL))
);
GO

-- The risk model version in force: the organization's own first, else
-- the GRAC default.
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_risk_model_version (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
SELECT TOP (1) e.version_id, e.template_id, e.template_name, e.origin
FROM   grac_practice.fn_tprm_template_effective(@organization_id) e
WHERE  e.template_kind = N'RISK_MODEL'
ORDER  BY CASE WHEN e.origin = N'ORGANIZATION' THEN 0 ELSE 1 END, e.is_default DESC, e.template_id;
GO

-- =====================================================================
-- 7. Internal helpers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_audit
    @entity_type NVARCHAR(100),
    @entity_id   BIGINT,
    @action      NVARCHAR(80),
    @after_json  NVARCHAR(MAX) = NULL,
    @actor       NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (@entity_type, ISNULL(@entity_id, 0), @action, NULL, @after_json, N'Active', ISNULL(@actor, N'system'));
END
GO

-- Organization (or the baseline when @organization_id is NULL and the
-- caller is the platform administrator) the configuration call may write.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_config_scope_check
    @organization_id   BIGINT,
    @is_platform_admin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL AND ISNULL(@is_platform_admin, 0) = 0
        THROW 57500, 'The GRAC baseline is maintained by the platform administrator. Select an organization to change its own configuration.', 1;
    IF @organization_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 57501, 'Organization not found.', 1;
END
GO

-- =====================================================================
-- 8. Reference lists
-- =====================================================================
-- Result 1: lists. Result 2: every value of the scope -- for an
-- organization the effective rows plus its hidden / retired overrides
-- (so they can be shown again), for the baseline the baseline rows.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_config_reference_get
    @organization_id   BIGINT = NULL,
    @list_code         NVARCHAR(60) = NULL,
    @is_platform_admin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, @is_platform_admin;

    SELECT l.list_code AS ListCode, l.list_name AS ListName, l.description AS Description,
           l.scope_rule AS ScopeRule, l.allowed_meanings AS AllowedMeanings, l.display_order AS DisplayOrder,
           (SELECT COUNT(*) FROM grac_practice.tprm_reference_value v
             WHERE v.list_code = l.list_code AND v.organization_id IS NULL AND v.status = N'Active') AS BaselineCount,
           (SELECT COUNT(*) FROM grac_practice.tprm_reference_value v
             WHERE v.list_code = l.list_code AND v.organization_id = @organization_id) AS OrganizationCount
    FROM   grac_practice.tprm_reference_list l
    WHERE  @list_code IS NULL OR l.list_code = @list_code
    ORDER  BY l.display_order, l.list_name;

    IF @organization_id IS NULL
        SELECT v.value_id AS ValueId, v.list_code AS ListCode, v.value_code AS ValueCode, v.label AS Label,
               v.description AS Description, v.meaning_code AS MeaningCode, v.rank_no AS RankNo,
               v.color_hex AS ColorHex, v.is_mandatory AS IsMandatory, v.display_order AS DisplayOrder,
               N'GRAC' AS Origin, CAST(0 AS BIT) AS IsHidden, v.status AS Status,
               v.value_id AS BaselineValueId, CAST(NULL AS BIGINT) AS OverrideValueId
        FROM   grac_practice.tprm_reference_value v
        WHERE  v.organization_id IS NULL AND (@list_code IS NULL OR v.list_code = @list_code)
        ORDER  BY v.list_code, v.display_order, v.label;
    ELSE
        SELECT e.override_value_id AS ValueId, e.list_code AS ListCode, e.value_code AS ValueCode, e.label AS Label,
               e.description AS Description, e.meaning_code AS MeaningCode, e.rank_no AS RankNo,
               e.color_hex AS ColorHex, e.is_mandatory AS IsMandatory, e.display_order AS DisplayOrder,
               e.origin AS Origin, CAST(0 AS BIT) AS IsHidden, N'Active' AS Status,
               e.baseline_value_id AS BaselineValueId, e.override_value_id AS OverrideValueId
        FROM   grac_practice.fn_tprm_reference_effective(@organization_id) e
        WHERE  @list_code IS NULL OR e.list_code = @list_code
        UNION ALL
        -- hidden baseline values and retired organization values
        SELECT v.value_id, v.list_code, v.value_code, COALESCE(b.label, v.label), v.description, v.meaning_code,
               v.rank_no, v.color_hex, v.is_mandatory, v.display_order,
               CASE WHEN v.baseline_value_id IS NULL THEN N'ORGANIZATION' ELSE N'GRAC_OVERRIDDEN' END,
               v.is_hidden, v.status, v.baseline_value_id, v.value_id
        FROM   grac_practice.tprm_reference_value v
        LEFT   JOIN grac_practice.tprm_reference_value b ON b.value_id = v.baseline_value_id
        WHERE  v.organization_id = @organization_id
          AND  (v.is_hidden = 1 OR v.status = N'Retired')
          AND  (@list_code IS NULL OR v.list_code = @list_code)
        ORDER  BY ListCode, DisplayOrder, Label;
END
GO

-- Add / edit one value of the scope (an organization's own value, or a
-- baseline value for the platform administrator). Overrides of baseline
-- values go through sp_tprm_reference_value_override.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_reference_value_save
    @organization_id   BIGINT        = NULL,
    @value_id          BIGINT        = NULL,
    @list_code         NVARCHAR(60),
    @value_code        NVARCHAR(60),
    @label             NVARCHAR(200),
    @description       NVARCHAR(1000) = NULL,
    @meaning_code      NVARCHAR(40)  = NULL,
    @rank_no           INT           = NULL,
    @color_hex         NVARCHAR(9)   = NULL,
    @is_mandatory      BIT           = 0,
    @display_order     INT           = 100,
    @status            NVARCHAR(20)  = N'Active',
    @is_platform_admin BIT           = 0,
    @actor             NVARCHAR(100) = N'system',
    @out_value_id      BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, @is_platform_admin;

    DECLARE @scope_rule NVARCHAR(20), @allowed NVARCHAR(400);
    SELECT @scope_rule = scope_rule, @allowed = allowed_meanings
    FROM   grac_practice.tprm_reference_list WHERE list_code = @list_code;
    IF @scope_rule IS NULL THROW 57502, 'That list does not exist.', 1;

    SET @value_code = UPPER(NULLIF(LTRIM(RTRIM(@value_code)), N''));
    SET @label      = NULLIF(LTRIM(RTRIM(@label)), N'');
    SET @meaning_code = NULLIF(LTRIM(RTRIM(@meaning_code)), N'');
    IF @value_code IS NULL OR @label IS NULL THROW 57503, 'Code and label are both required.', 1;
    IF @value_code LIKE N'%[^A-Z0-9_]%' THROW 57504, 'Codes may contain only letters, digits and underscores.', 1;
    IF ISNULL(@status, N'') NOT IN (N'Active', N'Retired') SET @status = N'Active';

    IF @scope_rule = N'MEANING'
       AND (@meaning_code IS NULL
            OR NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(@allowed) WHERE code = @meaning_code))
        THROW 57505, 'Values of this list must be mapped to one of its meanings, so the workflow knows how to treat them.', 1;

    IF @value_id IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_reference_value
                    WHERE list_code = @list_code AND value_code = @value_code
                      AND ((@organization_id IS NULL AND organization_id IS NULL) OR organization_id = @organization_id))
           OR (@organization_id IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.tprm_reference_value
                    WHERE list_code = @list_code AND value_code = @value_code AND organization_id IS NULL))
            THROW 57506, 'A value with that code already exists in this list.', 1;

        INSERT grac_practice.tprm_reference_value
            (list_code, organization_id, value_code, label, description, meaning_code, rank_no, color_hex,
             is_mandatory, display_order, status, entered_by)
        VALUES (@list_code, @organization_id, @value_code, @label, @description, @meaning_code, @rank_no, @color_hex,
                ISNULL(@is_mandatory, 0), ISNULL(@display_order, 100), @status, @actor);
        SET @out_value_id = SCOPE_IDENTITY();
        EXEC grac_practice.sp_tprm_audit N'tprm-reference-value', @out_value_id, N'CREATE', @value_code, @actor;
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_reference_value
                    WHERE value_id = @value_id AND list_code = @list_code AND baseline_value_id IS NULL
                      AND ((@organization_id IS NULL AND organization_id IS NULL) OR organization_id = @organization_id))
        THROW 57507, 'That value was not found in this scope.', 1;

    UPDATE grac_practice.tprm_reference_value
       SET label = @label, description = @description, meaning_code = @meaning_code, rank_no = @rank_no,
           color_hex = @color_hex, is_mandatory = ISNULL(@is_mandatory, 0), display_order = ISNULL(@display_order, 100),
           status = @status, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE value_id = @value_id;
    SET @out_value_id = @value_id;
    EXEC grac_practice.sp_tprm_audit N'tprm-reference-value', @value_id, N'UPDATE', @value_code, @actor;
END
GO

-- Relabel / reorder / rank / hide a GRAC value for one organization, or
-- reset it (@reset = 1 removes the override; history keeps the audit).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_reference_value_override
    @organization_id   BIGINT,
    @baseline_value_id BIGINT,
    @label             NVARCHAR(200)  = NULL,
    @description       NVARCHAR(1000) = NULL,
    @rank_no           INT            = NULL,
    @color_hex         NVARCHAR(9)    = NULL,
    @is_mandatory      BIT            = NULL,
    @display_order     INT            = NULL,
    @is_hidden         BIT            = 0,
    @reset             BIT            = 0,
    @actor             NVARCHAR(100)  = N'system',
    @out_value_id      BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL THROW 57508, 'Select an organization.', 1;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, 0;

    DECLARE @list NVARCHAR(60), @code NVARCHAR(60), @b_label NVARCHAR(200), @b_desc NVARCHAR(1000), @b_meaning NVARCHAR(40),
            @b_rank INT, @b_color NVARCHAR(9), @b_mand BIT, @b_order INT;
    SELECT @list = list_code, @code = value_code, @b_label = label, @b_desc = description, @b_meaning = meaning_code,
           @b_rank = rank_no, @b_color = color_hex, @b_mand = is_mandatory, @b_order = display_order
    FROM   grac_practice.tprm_reference_value
    WHERE  value_id = @baseline_value_id AND organization_id IS NULL;
    IF @list IS NULL THROW 57509, 'That GRAC value was not found.', 1;

    DECLARE @existing BIGINT = (SELECT value_id FROM grac_practice.tprm_reference_value
                                 WHERE organization_id = @organization_id AND baseline_value_id = @baseline_value_id);

    IF ISNULL(@reset, 0) = 1
    BEGIN
        IF @existing IS NOT NULL
        BEGIN
            UPDATE grac_practice.tprm_reference_value
               SET status = N'Retired', is_hidden = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE value_id = @existing;
            EXEC grac_practice.sp_tprm_audit N'tprm-reference-value', @existing, N'RESET', @code, @actor;
        END
        SET @out_value_id = @existing;
        RETURN;
    END

    IF @existing IS NULL
    BEGIN
        INSERT grac_practice.tprm_reference_value
            (list_code, organization_id, value_code, label, description, meaning_code, rank_no, color_hex,
             is_mandatory, display_order, baseline_value_id, is_hidden, status, entered_by)
        VALUES (@list, @organization_id, @code, COALESCE(NULLIF(LTRIM(RTRIM(@label)), N''), @b_label),
                COALESCE(@description, @b_desc), @b_meaning, COALESCE(@rank_no, @b_rank), COALESCE(@color_hex, @b_color),
                COALESCE(@is_mandatory, @b_mand), COALESCE(@display_order, @b_order), @baseline_value_id,
                ISNULL(@is_hidden, 0), N'Active', @actor);
        SET @existing = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE grac_practice.tprm_reference_value
           SET label = COALESCE(NULLIF(LTRIM(RTRIM(@label)), N''), @b_label),
               description = COALESCE(@description, @b_desc), rank_no = COALESCE(@rank_no, @b_rank),
               color_hex = COALESCE(@color_hex, @b_color), is_mandatory = COALESCE(@is_mandatory, @b_mand),
               display_order = COALESCE(@display_order, @b_order), is_hidden = ISNULL(@is_hidden, 0),
               status = N'Active', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE value_id = @existing;

    SET @out_value_id = @existing;
    EXEC grac_practice.sp_tprm_audit N'tprm-reference-value', @existing, N'OVERRIDE', @code, @actor;
END
GO

-- =====================================================================
-- 9. Library (safeguards, evidence requirements, treatment actions)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_library_list
    @organization_id   BIGINT       = NULL,
    @library_code      NVARCHAR(30) = NULL,
    @is_platform_admin BIT          = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, @is_platform_admin;

    IF @organization_id IS NULL
        SELECT i.item_id AS ItemId, i.library_code AS LibraryCode, i.item_code AS ItemCode, i.item_name AS ItemName,
               i.description AS Description, i.category_code AS CategoryCode, i.dimension_code AS DimensionCode,
               i.guidance AS Guidance, i.effectiveness_criteria AS EffectivenessCriteria,
               i.is_contract_clause AS IsContractClause, i.evidence_requirement_code AS EvidenceRequirementCode,
               i.evidence_type_id AS EvidenceTypeId, i.validity_months AS ValidityMonths, i.review_required AS ReviewRequired,
               i.default_due_days AS DefaultDueDays, i.default_owner_hint AS DefaultOwnerHint,
               i.source_authority AS SourceAuthority, i.source_document AS SourceDocument, i.source_version AS SourceVersion,
               i.source_reference AS SourceReference, i.applicability_note AS ApplicabilityNote, i.is_regulatory AS IsRegulatory,
               i.display_order AS DisplayOrder, N'GRAC' AS Origin, CAST(0 AS BIT) AS IsHidden, i.status AS Status,
               i.item_id AS BaselineItemId, CAST(NULL AS BIGINT) AS OverrideItemId
        FROM   grac_practice.tprm_library_item i
        WHERE  i.organization_id IS NULL AND (@library_code IS NULL OR i.library_code = @library_code)
        ORDER  BY i.library_code, i.display_order, i.item_name;
    ELSE
        SELECT e.override_item_id AS ItemId, e.library_code AS LibraryCode, e.item_code AS ItemCode, e.item_name AS ItemName,
               e.description AS Description, e.category_code AS CategoryCode, e.dimension_code AS DimensionCode,
               e.guidance AS Guidance, e.effectiveness_criteria AS EffectivenessCriteria,
               e.is_contract_clause AS IsContractClause, e.evidence_requirement_code AS EvidenceRequirementCode,
               e.evidence_type_id AS EvidenceTypeId, e.validity_months AS ValidityMonths, e.review_required AS ReviewRequired,
               e.default_due_days AS DefaultDueDays, e.default_owner_hint AS DefaultOwnerHint,
               e.source_authority AS SourceAuthority, e.source_document AS SourceDocument, e.source_version AS SourceVersion,
               e.source_reference AS SourceReference, e.applicability_note AS ApplicabilityNote, e.is_regulatory AS IsRegulatory,
               e.display_order AS DisplayOrder, e.origin AS Origin, CAST(0 AS BIT) AS IsHidden, N'Active' AS Status,
               e.baseline_item_id AS BaselineItemId, e.override_item_id AS OverrideItemId
        FROM   grac_practice.fn_tprm_library_effective(@organization_id) e
        WHERE  @library_code IS NULL OR e.library_code = @library_code
        UNION ALL
        SELECT i.item_id, i.library_code, i.item_code, COALESCE(b.item_name, i.item_name), i.description, i.category_code,
               i.dimension_code, i.guidance, i.effectiveness_criteria, i.is_contract_clause, i.evidence_requirement_code,
               i.evidence_type_id, i.validity_months, i.review_required, i.default_due_days, i.default_owner_hint,
               i.source_authority, i.source_document, i.source_version, i.source_reference, i.applicability_note,
               i.is_regulatory, i.display_order,
               CASE WHEN i.baseline_item_id IS NULL THEN N'ORGANIZATION' ELSE N'GRAC_OVERRIDDEN' END,
               i.is_hidden, i.status, i.baseline_item_id, i.item_id
        FROM   grac_practice.tprm_library_item i
        LEFT   JOIN grac_practice.tprm_library_item b ON b.item_id = i.baseline_item_id
        WHERE  i.organization_id = @organization_id AND (i.is_hidden = 1 OR i.status = N'Retired')
          AND  (@library_code IS NULL OR i.library_code = @library_code)
        ORDER  BY LibraryCode, DisplayOrder, ItemName;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_library_save
    @organization_id           BIGINT         = NULL,
    @item_id                   BIGINT         = NULL,
    @library_code              NVARCHAR(30),
    @item_code                 NVARCHAR(60),
    @item_name                 NVARCHAR(250),
    @description               NVARCHAR(2000) = NULL,
    @category_code             NVARCHAR(60)   = NULL,
    @dimension_code            NVARCHAR(60)   = NULL,
    @guidance                  NVARCHAR(2000) = NULL,
    @effectiveness_criteria    NVARCHAR(2000) = NULL,
    @is_contract_clause        BIT            = 0,
    @evidence_requirement_code NVARCHAR(60)   = NULL,
    @evidence_type_id          INT            = NULL,
    @validity_months           INT            = NULL,
    @review_required           BIT            = 1,
    @default_due_days          INT            = NULL,
    @default_owner_hint        NVARCHAR(200)  = NULL,
    @source_authority          NVARCHAR(200)  = NULL,
    @source_document           NVARCHAR(300)  = NULL,
    @source_version            NVARCHAR(100)  = NULL,
    @source_reference          NVARCHAR(300)  = NULL,
    @applicability_note        NVARCHAR(1000) = NULL,
    @is_regulatory             BIT            = 0,
    @display_order             INT            = 100,
    @status                    NVARCHAR(20)   = N'Active',
    @is_platform_admin         BIT            = 0,
    @actor                     NVARCHAR(100)  = N'system',
    @out_item_id               BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, @is_platform_admin;

    IF @library_code NOT IN (N'SAFEGUARD', N'EVIDENCE_REQUIREMENT', N'TREATMENT_ACTION')
        THROW 57510, 'Unknown library.', 1;
    SET @item_code = UPPER(NULLIF(LTRIM(RTRIM(@item_code)), N''));
    SET @item_name = NULLIF(LTRIM(RTRIM(@item_name)), N'');
    IF @item_code IS NULL OR @item_name IS NULL THROW 57511, 'Code and name are both required.', 1;
    IF @item_code LIKE N'%[^A-Z0-9_]%' THROW 57504, 'Codes may contain only letters, digits and underscores.', 1;
    IF ISNULL(@status, N'') NOT IN (N'Active', N'Retired') SET @status = N'Active';
    -- BRD 5.3: a requirement is regulatory only when its source is established.
    IF ISNULL(@is_regulatory, 0) = 1 AND (NULLIF(LTRIM(RTRIM(@source_authority)), N'') IS NULL
                                       OR NULLIF(LTRIM(RTRIM(@source_document)), N'') IS NULL)
        THROW 57512, 'A regulatory requirement needs its source authority and source document.', 1;
    IF @validity_months IS NOT NULL AND (@validity_months < 1 OR @validity_months > 120)
        THROW 57513, 'Validity must be between 1 and 120 months.', 1;
    IF @evidence_type_id IS NOT NULL AND OBJECT_ID('grac_practice.evidence_type_master','U') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_type_master WHERE evidence_type_id = @evidence_type_id)
        THROW 57514, 'That evidence type does not exist.', 1;

    IF @item_id IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_library_item
                    WHERE library_code = @library_code AND item_code = @item_code
                      AND (organization_id IS NULL OR organization_id = @organization_id))
            THROW 57515, 'An item with that code already exists in this library.', 1;
        INSERT grac_practice.tprm_library_item
            (library_code, organization_id, item_code, item_name, description, category_code, dimension_code, guidance,
             effectiveness_criteria, is_contract_clause, evidence_requirement_code, evidence_type_id, validity_months,
             review_required, default_due_days, default_owner_hint, source_authority, source_document, source_version,
             source_reference, applicability_note, is_regulatory, display_order, status, entered_by)
        VALUES (@library_code, @organization_id, @item_code, @item_name, @description, @category_code, @dimension_code, @guidance,
                @effectiveness_criteria, ISNULL(@is_contract_clause, 0), @evidence_requirement_code, @evidence_type_id, @validity_months,
                ISNULL(@review_required, 1), @default_due_days, @default_owner_hint, @source_authority, @source_document, @source_version,
                @source_reference, @applicability_note, ISNULL(@is_regulatory, 0), ISNULL(@display_order, 100), @status, @actor);
        SET @out_item_id = SCOPE_IDENTITY();
        EXEC grac_practice.sp_tprm_audit N'tprm-library-item', @out_item_id, N'CREATE', @item_code, @actor;
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_library_item
                    WHERE item_id = @item_id AND library_code = @library_code AND baseline_item_id IS NULL
                      AND ((@organization_id IS NULL AND organization_id IS NULL) OR organization_id = @organization_id))
        THROW 57516, 'That library item was not found in this scope.', 1;

    UPDATE grac_practice.tprm_library_item
       SET item_name = @item_name, description = @description, category_code = @category_code, dimension_code = @dimension_code,
           guidance = @guidance, effectiveness_criteria = @effectiveness_criteria, is_contract_clause = ISNULL(@is_contract_clause, 0),
           evidence_requirement_code = @evidence_requirement_code, evidence_type_id = @evidence_type_id,
           validity_months = @validity_months, review_required = ISNULL(@review_required, 1),
           default_due_days = @default_due_days, default_owner_hint = @default_owner_hint,
           source_authority = @source_authority, source_document = @source_document, source_version = @source_version,
           source_reference = @source_reference, applicability_note = @applicability_note,
           is_regulatory = ISNULL(@is_regulatory, 0), display_order = ISNULL(@display_order, 100),
           status = @status, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE item_id = @item_id;
    SET @out_item_id = @item_id;
    EXEC grac_practice.sp_tprm_audit N'tprm-library-item', @item_id, N'UPDATE', @item_code, @actor;
END
GO

-- Organization override of a GRAC library item: its own name, guidance,
-- criteria, evidence, validity, due days -- or hidden; @reset removes it.
-- Provenance stays the baseline's: an organization cannot re-attribute a
-- GRAC row to a regulator.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_library_override
    @organization_id           BIGINT,
    @baseline_item_id          BIGINT,
    @item_name                 NVARCHAR(250)  = NULL,
    @description               NVARCHAR(2000) = NULL,
    @category_code             NVARCHAR(60)   = NULL,
    @dimension_code            NVARCHAR(60)   = NULL,
    @guidance                  NVARCHAR(2000) = NULL,
    @effectiveness_criteria    NVARCHAR(2000) = NULL,
    @is_contract_clause        BIT            = NULL,
    @evidence_requirement_code NVARCHAR(60)   = NULL,
    @evidence_type_id          INT            = NULL,
    @validity_months           INT            = NULL,
    @review_required           BIT            = NULL,
    @default_due_days          INT            = NULL,
    @default_owner_hint        NVARCHAR(200)  = NULL,
    @display_order             INT            = NULL,
    @is_hidden                 BIT            = 0,
    @reset                     BIT            = 0,
    @actor                     NVARCHAR(100)  = N'system',
    @out_item_id               BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL THROW 57508, 'Select an organization.', 1;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, 0;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_library_item WHERE item_id = @baseline_item_id AND organization_id IS NULL)
        THROW 57517, 'That GRAC library item was not found.', 1;
    IF @validity_months IS NOT NULL AND (@validity_months < 1 OR @validity_months > 120)
        THROW 57513, 'Validity must be between 1 and 120 months.', 1;

    DECLARE @existing BIGINT = (SELECT item_id FROM grac_practice.tprm_library_item
                                 WHERE organization_id = @organization_id AND baseline_item_id = @baseline_item_id);
    IF ISNULL(@reset, 0) = 1
    BEGIN
        IF @existing IS NOT NULL
        BEGIN
            UPDATE grac_practice.tprm_library_item SET status = N'Retired', is_hidden = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE item_id = @existing;
            EXEC grac_practice.sp_tprm_audit N'tprm-library-item', @existing, N'RESET', NULL, @actor;
        END
        SET @out_item_id = @existing;
        RETURN;
    END

    IF @existing IS NULL
    BEGIN
        INSERT grac_practice.tprm_library_item
            (library_code, organization_id, item_code, item_name, description, category_code, dimension_code, guidance,
             effectiveness_criteria, is_contract_clause, evidence_requirement_code, evidence_type_id, validity_months,
             review_required, default_due_days, default_owner_hint, source_authority, source_document, source_version,
             source_reference, applicability_note, is_regulatory, display_order, baseline_item_id, is_hidden, status, entered_by)
        SELECT b.library_code, @organization_id, b.item_code, COALESCE(NULLIF(LTRIM(RTRIM(@item_name)), N''), b.item_name),
               COALESCE(@description, b.description), COALESCE(@category_code, b.category_code), COALESCE(@dimension_code, b.dimension_code),
               COALESCE(@guidance, b.guidance), COALESCE(@effectiveness_criteria, b.effectiveness_criteria),
               COALESCE(@is_contract_clause, b.is_contract_clause), COALESCE(@evidence_requirement_code, b.evidence_requirement_code),
               COALESCE(@evidence_type_id, b.evidence_type_id), COALESCE(@validity_months, b.validity_months),
               COALESCE(@review_required, b.review_required), COALESCE(@default_due_days, b.default_due_days),
               COALESCE(@default_owner_hint, b.default_owner_hint), b.source_authority, b.source_document, b.source_version,
               b.source_reference, b.applicability_note, b.is_regulatory, COALESCE(@display_order, b.display_order),
               b.item_id, ISNULL(@is_hidden, 0), N'Active', @actor
        FROM   grac_practice.tprm_library_item b WHERE b.item_id = @baseline_item_id;
        SET @existing = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE o
           SET item_name = COALESCE(NULLIF(LTRIM(RTRIM(@item_name)), N''), b.item_name),
               description = COALESCE(@description, b.description), category_code = COALESCE(@category_code, b.category_code),
               dimension_code = COALESCE(@dimension_code, b.dimension_code), guidance = COALESCE(@guidance, b.guidance),
               effectiveness_criteria = COALESCE(@effectiveness_criteria, b.effectiveness_criteria),
               is_contract_clause = COALESCE(@is_contract_clause, b.is_contract_clause),
               evidence_requirement_code = COALESCE(@evidence_requirement_code, b.evidence_requirement_code),
               evidence_type_id = COALESCE(@evidence_type_id, b.evidence_type_id),
               validity_months = COALESCE(@validity_months, b.validity_months),
               review_required = COALESCE(@review_required, b.review_required),
               default_due_days = COALESCE(@default_due_days, b.default_due_days),
               default_owner_hint = COALESCE(@default_owner_hint, b.default_owner_hint),
               display_order = COALESCE(@display_order, b.display_order), is_hidden = ISNULL(@is_hidden, 0),
               status = N'Active', updated_by = @actor, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.tprm_library_item o
          JOIN grac_practice.tprm_library_item b ON b.item_id = o.baseline_item_id
         WHERE o.item_id = @existing;

    SET @out_item_id = @existing;
    EXEC grac_practice.sp_tprm_audit N'tprm-library-item', @existing, N'OVERRIDE', NULL, @actor;
END
GO

-- =====================================================================
-- 10. Approval rules, review rules, delegations
-- =====================================================================
-- Result 1 approval rules, 2 review rules (effective + hidden overrides
-- for an organization; baseline rows for the baseline), 3 delegations,
-- 4 the organization's active roles (for the role pickers).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_rules_get
    @organization_id   BIGINT = NULL,
    @is_platform_admin BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, @is_platform_admin;

    SELECT r.rule_id AS RuleId, r.rule_code AS RuleCode, r.rule_name AS RuleName, r.description AS Description,
           r.priority AS Priority, r.min_band_rank AS MinBandRank, r.min_criticality_rank AS MinCriticalityRank,
           r.approval_levels AS ApprovalLevels, r.level1_role_name AS Level1RoleName, r.level2_role_name AS Level2RoleName,
           r.level3_role_name AS Level3RoleName, r.sod_required AS SodRequired, r.escalate_to_risk_centre AS EscalateToRiskCentre,
           r.max_acceptance_months AS MaxAcceptanceMonths, r.allowed_decision_codes AS AllowedDecisionCodes,
           CASE WHEN r.organization_id IS NULL THEN N'GRAC'
                WHEN r.baseline_rule_id IS NULL THEN N'ORGANIZATION' ELSE N'GRAC_OVERRIDDEN' END AS Origin,
           r.baseline_rule_id AS BaselineRuleId, r.is_hidden AS IsHidden, r.status AS Status,
           CAST(CASE WHEN r.organization_id IS NULL AND @organization_id IS NOT NULL
                      AND EXISTS (SELECT 1 FROM grac_practice.tprm_approval_rule o
                                   WHERE o.baseline_rule_id = r.rule_id AND o.organization_id = @organization_id AND o.status = N'Active')
                     THEN 1 ELSE 0 END AS BIT) AS IsOverridden
    FROM   grac_practice.tprm_approval_rule r
    WHERE  r.organization_id IS NULL OR r.organization_id = @organization_id
    ORDER  BY r.priority, r.rule_code, CASE WHEN r.organization_id IS NULL THEN 0 ELSE 1 END;

    SELECT r.rule_id AS RuleId, r.rule_code AS RuleCode, r.rule_name AS RuleName, r.description AS Description,
           r.priority AS Priority, r.min_band_rank AS MinBandRank, r.min_criticality_rank AS MinCriticalityRank,
           r.review_frequency_months AS ReviewFrequencyMonths, r.evidence_renewal_months AS EvidenceRenewalMonths,
           r.contract_expiry_alert_days AS ContractExpiryAlertDays, r.cert_expiry_alert_days AS CertExpiryAlertDays,
           r.review_lead_days AS ReviewLeadDays, r.reassessment_trigger_codes AS ReassessmentTriggerCodes,
           r.monitoring_note AS MonitoringNote,
           CASE WHEN r.organization_id IS NULL THEN N'GRAC'
                WHEN r.baseline_rule_id IS NULL THEN N'ORGANIZATION' ELSE N'GRAC_OVERRIDDEN' END AS Origin,
           r.baseline_rule_id AS BaselineRuleId, r.is_hidden AS IsHidden, r.status AS Status,
           CAST(CASE WHEN r.organization_id IS NULL AND @organization_id IS NOT NULL
                      AND EXISTS (SELECT 1 FROM grac_practice.tprm_review_rule o
                                   WHERE o.baseline_rule_id = r.rule_id AND o.organization_id = @organization_id AND o.status = N'Active')
                     THEN 1 ELSE 0 END AS BIT) AS IsOverridden
    FROM   grac_practice.tprm_review_rule r
    WHERE  r.organization_id IS NULL OR r.organization_id = @organization_id
    ORDER  BY r.priority, r.rule_code, CASE WHEN r.organization_id IS NULL THEN 0 ELSE 1 END;

    SELECT d.delegation_id AS DelegationId, d.from_employee_id AS FromEmployeeId, f.employee_name AS FromEmployeeName,
           d.to_employee_id AS ToEmployeeId, t.employee_name AS ToEmployeeName, d.valid_from AS ValidFrom,
           d.valid_to AS ValidTo, d.reason AS Reason, d.status AS Status
    FROM   grac_practice.tprm_approval_delegation d
    JOIN   grac_practice.organization_employee f ON f.employee_id = d.from_employee_id
    JOIN   grac_practice.organization_employee t ON t.employee_id = d.to_employee_id
    WHERE  d.organization_id = @organization_id
    ORDER  BY d.valid_from DESC;

    SELECT r.role_id AS RoleId, r.role_name AS RoleName
    FROM   grac_practice.organization_role r
    WHERE  r.organization_id = @organization_id AND r.status = N'Active'
    ORDER  BY r.role_name;
END
GO

-- Save an approval rule. @baseline_rule_id set = this organization's
-- override of that GRAC rule (created on first save); @is_hidden hides it.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_approval_rule_save
    @organization_id         BIGINT        = NULL,
    @rule_id                 BIGINT        = NULL,
    @baseline_rule_id        BIGINT        = NULL,
    @rule_code               NVARCHAR(60)  = NULL,
    @rule_name               NVARCHAR(200),
    @description             NVARCHAR(1000) = NULL,
    @priority                INT           = 100,
    @min_band_rank           INT           = NULL,
    @min_criticality_rank    INT           = NULL,
    @approval_levels         INT           = 1,
    @level1_role_name        NVARCHAR(120) = NULL,
    @level2_role_name        NVARCHAR(120) = NULL,
    @level3_role_name        NVARCHAR(120) = NULL,
    @sod_required            BIT           = 1,
    @escalate_to_risk_centre BIT           = 0,
    @max_acceptance_months   INT           = NULL,
    @allowed_decision_codes  NVARCHAR(400) = NULL,
    @is_hidden               BIT           = 0,
    @status                  NVARCHAR(20)  = N'Active',
    @is_platform_admin       BIT           = 0,
    @actor                   NVARCHAR(100) = N'system',
    @out_rule_id             BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, @is_platform_admin;

    SET @rule_name = NULLIF(LTRIM(RTRIM(@rule_name)), N'');
    IF @rule_name IS NULL THROW 57520, 'Rule name is required.', 1;
    IF ISNULL(@approval_levels, 0) NOT BETWEEN 1 AND 3 THROW 57521, 'Approval needs between one and three levels.', 1;
    IF @max_acceptance_months IS NOT NULL AND (@max_acceptance_months < 1 OR @max_acceptance_months > 60)
        THROW 57522, 'Maximum risk acceptance must be between 1 and 60 months.', 1;
    IF ISNULL(@status, N'') NOT IN (N'Active', N'Retired') SET @status = N'Active';

    IF @baseline_rule_id IS NOT NULL
    BEGIN
        IF @organization_id IS NULL THROW 57508, 'Select an organization.', 1;
        SELECT @rule_code = rule_code FROM grac_practice.tprm_approval_rule
         WHERE rule_id = @baseline_rule_id AND organization_id IS NULL;
        IF @rule_code IS NULL THROW 57523, 'That GRAC rule was not found.', 1;
        SET @rule_id = (SELECT rule_id FROM grac_practice.tprm_approval_rule
                         WHERE organization_id = @organization_id AND baseline_rule_id = @baseline_rule_id);
    END
    ELSE
    BEGIN
        SET @rule_code = UPPER(NULLIF(LTRIM(RTRIM(@rule_code)), N''));
        IF @rule_code IS NULL THROW 57524, 'Rule code is required.', 1;
        IF @rule_code LIKE N'%[^A-Z0-9_]%' THROW 57504, 'Codes may contain only letters, digits and underscores.', 1;
    END

    IF @rule_id IS NULL
    BEGIN
        IF @baseline_rule_id IS NULL AND EXISTS (SELECT 1 FROM grac_practice.tprm_approval_rule
                    WHERE rule_code = @rule_code AND (organization_id IS NULL OR organization_id = @organization_id))
            THROW 57525, 'A rule with that code already exists.', 1;
        INSERT grac_practice.tprm_approval_rule
            (organization_id, rule_code, rule_name, description, priority, min_band_rank, min_criticality_rank, approval_levels,
             level1_role_name, level2_role_name, level3_role_name, sod_required, escalate_to_risk_centre, max_acceptance_months,
             allowed_decision_codes, baseline_rule_id, is_hidden, status, entered_by)
        VALUES (@organization_id, @rule_code, @rule_name, @description, ISNULL(@priority, 100), @min_band_rank, @min_criticality_rank,
                @approval_levels, NULLIF(LTRIM(RTRIM(@level1_role_name)), N''), NULLIF(LTRIM(RTRIM(@level2_role_name)), N''),
                NULLIF(LTRIM(RTRIM(@level3_role_name)), N''), ISNULL(@sod_required, 1), ISNULL(@escalate_to_risk_centre, 0),
                @max_acceptance_months, NULLIF(LTRIM(RTRIM(@allowed_decision_codes)), N''), @baseline_rule_id,
                ISNULL(@is_hidden, 0), @status, @actor);
        SET @out_rule_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_approval_rule WHERE rule_id = @rule_id
                         AND ((@organization_id IS NULL AND organization_id IS NULL) OR organization_id = @organization_id))
            THROW 57526, 'That rule was not found in this scope.', 1;
        UPDATE grac_practice.tprm_approval_rule
           SET rule_name = @rule_name, description = @description, priority = ISNULL(@priority, 100),
               min_band_rank = @min_band_rank, min_criticality_rank = @min_criticality_rank, approval_levels = @approval_levels,
               level1_role_name = NULLIF(LTRIM(RTRIM(@level1_role_name)), N''), level2_role_name = NULLIF(LTRIM(RTRIM(@level2_role_name)), N''),
               level3_role_name = NULLIF(LTRIM(RTRIM(@level3_role_name)), N''), sod_required = ISNULL(@sod_required, 1),
               escalate_to_risk_centre = ISNULL(@escalate_to_risk_centre, 0), max_acceptance_months = @max_acceptance_months,
               allowed_decision_codes = NULLIF(LTRIM(RTRIM(@allowed_decision_codes)), N''), is_hidden = ISNULL(@is_hidden, 0),
               status = @status, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE rule_id = @rule_id;
        SET @out_rule_id = @rule_id;
    END
    EXEC grac_practice.sp_tprm_audit N'tprm-approval-rule', @out_rule_id, N'SAVE', @rule_code, @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_review_rule_save
    @organization_id            BIGINT        = NULL,
    @rule_id                    BIGINT        = NULL,
    @baseline_rule_id           BIGINT        = NULL,
    @rule_code                  NVARCHAR(60)  = NULL,
    @rule_name                  NVARCHAR(200),
    @description                NVARCHAR(1000) = NULL,
    @priority                   INT           = 100,
    @min_band_rank              INT           = NULL,
    @min_criticality_rank       INT           = NULL,
    @review_frequency_months    INT           = 12,
    @evidence_renewal_months    INT           = NULL,
    @contract_expiry_alert_days INT           = NULL,
    @cert_expiry_alert_days     INT           = NULL,
    @review_lead_days           INT           = 30,
    @reassessment_trigger_codes NVARCHAR(600) = NULL,
    @monitoring_note            NVARCHAR(1000) = NULL,
    @is_hidden                  BIT           = 0,
    @status                     NVARCHAR(20)  = N'Active',
    @is_platform_admin          BIT           = 0,
    @actor                      NVARCHAR(100) = N'system',
    @out_rule_id                BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, @is_platform_admin;

    SET @rule_name = NULLIF(LTRIM(RTRIM(@rule_name)), N'');
    IF @rule_name IS NULL THROW 57520, 'Rule name is required.', 1;
    IF ISNULL(@review_frequency_months, 0) NOT BETWEEN 1 AND 120
        THROW 57527, 'Review frequency must be between 1 and 120 months.', 1;
    IF ISNULL(@review_lead_days, 0) NOT BETWEEN 0 AND 365
        THROW 57528, 'Review lead time must be between 0 and 365 days.', 1;
    IF ISNULL(@status, N'') NOT IN (N'Active', N'Retired') SET @status = N'Active';

    IF @baseline_rule_id IS NOT NULL
    BEGIN
        IF @organization_id IS NULL THROW 57508, 'Select an organization.', 1;
        SELECT @rule_code = rule_code FROM grac_practice.tprm_review_rule
         WHERE rule_id = @baseline_rule_id AND organization_id IS NULL;
        IF @rule_code IS NULL THROW 57523, 'That GRAC rule was not found.', 1;
        SET @rule_id = (SELECT rule_id FROM grac_practice.tprm_review_rule
                         WHERE organization_id = @organization_id AND baseline_rule_id = @baseline_rule_id);
    END
    ELSE
    BEGIN
        SET @rule_code = UPPER(NULLIF(LTRIM(RTRIM(@rule_code)), N''));
        IF @rule_code IS NULL THROW 57524, 'Rule code is required.', 1;
        IF @rule_code LIKE N'%[^A-Z0-9_]%' THROW 57504, 'Codes may contain only letters, digits and underscores.', 1;
    END

    IF @rule_id IS NULL
    BEGIN
        IF @baseline_rule_id IS NULL AND EXISTS (SELECT 1 FROM grac_practice.tprm_review_rule
                    WHERE rule_code = @rule_code AND (organization_id IS NULL OR organization_id = @organization_id))
            THROW 57525, 'A rule with that code already exists.', 1;
        INSERT grac_practice.tprm_review_rule
            (organization_id, rule_code, rule_name, description, priority, min_band_rank, min_criticality_rank,
             review_frequency_months, evidence_renewal_months, contract_expiry_alert_days, cert_expiry_alert_days,
             review_lead_days, reassessment_trigger_codes, monitoring_note, baseline_rule_id, is_hidden, status, entered_by)
        VALUES (@organization_id, @rule_code, @rule_name, @description, ISNULL(@priority, 100), @min_band_rank, @min_criticality_rank,
                @review_frequency_months, @evidence_renewal_months, @contract_expiry_alert_days, @cert_expiry_alert_days,
                @review_lead_days, NULLIF(LTRIM(RTRIM(@reassessment_trigger_codes)), N''), @monitoring_note, @baseline_rule_id,
                ISNULL(@is_hidden, 0), @status, @actor);
        SET @out_rule_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_review_rule WHERE rule_id = @rule_id
                         AND ((@organization_id IS NULL AND organization_id IS NULL) OR organization_id = @organization_id))
            THROW 57526, 'That rule was not found in this scope.', 1;
        UPDATE grac_practice.tprm_review_rule
           SET rule_name = @rule_name, description = @description, priority = ISNULL(@priority, 100),
               min_band_rank = @min_band_rank, min_criticality_rank = @min_criticality_rank,
               review_frequency_months = @review_frequency_months, evidence_renewal_months = @evidence_renewal_months,
               contract_expiry_alert_days = @contract_expiry_alert_days, cert_expiry_alert_days = @cert_expiry_alert_days,
               review_lead_days = @review_lead_days, reassessment_trigger_codes = NULLIF(LTRIM(RTRIM(@reassessment_trigger_codes)), N''),
               monitoring_note = @monitoring_note, is_hidden = ISNULL(@is_hidden, 0), status = @status,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE rule_id = @rule_id;
        SET @out_rule_id = @rule_id;
    END
    EXEC grac_practice.sp_tprm_audit N'tprm-review-rule', @out_rule_id, N'SAVE', @rule_code, @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_delegation_save
    @organization_id  BIGINT,
    @delegation_id    BIGINT        = NULL,
    @from_employee_id BIGINT        = NULL,
    @to_employee_id   BIGINT        = NULL,
    @valid_from       DATE          = NULL,
    @valid_to         DATE          = NULL,
    @reason           NVARCHAR(500) = NULL,
    @revoke           BIT           = 0,
    @actor            NVARCHAR(100) = N'system',
    @out_delegation_id BIGINT       = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL THROW 57508, 'Select an organization.', 1;

    IF @delegation_id IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_approval_delegation WHERE delegation_id = @delegation_id AND organization_id = @organization_id)
            THROW 57529, 'That delegation was not found.', 1;
        IF ISNULL(@revoke, 0) = 1
        BEGIN
            UPDATE grac_practice.tprm_approval_delegation SET status = N'Revoked', updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE delegation_id = @delegation_id;
            SET @out_delegation_id = @delegation_id;
            EXEC grac_practice.sp_tprm_audit N'tprm-delegation', @delegation_id, N'REVOKE', NULL, @actor;
            RETURN;
        END
    END

    IF @from_employee_id IS NULL OR @to_employee_id IS NULL OR @valid_from IS NULL OR @valid_to IS NULL
        THROW 57530, 'Approver, delegate and both dates are required.', 1;
    IF @from_employee_id = @to_employee_id THROW 57531, 'An approver cannot delegate to themselves.', 1;
    IF @valid_to < @valid_from THROW 57532, 'The end date is before the start date.', 1;
    IF (SELECT COUNT(*) FROM grac_practice.organization_employee
         WHERE organization_id = @organization_id AND status = N'Active'
           AND employee_id IN (@from_employee_id, @to_employee_id)) <> 2
        THROW 57533, 'Both people must be active employees of this organization.', 1;

    IF @delegation_id IS NULL
    BEGIN
        INSERT grac_practice.tprm_approval_delegation
            (organization_id, from_employee_id, to_employee_id, valid_from, valid_to, reason, status, entered_by)
        VALUES (@organization_id, @from_employee_id, @to_employee_id, @valid_from, @valid_to, @reason, N'Active', @actor);
        SET @out_delegation_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.tprm_approval_delegation
           SET from_employee_id = @from_employee_id, to_employee_id = @to_employee_id, valid_from = @valid_from,
               valid_to = @valid_to, reason = @reason, status = N'Active', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE delegation_id = @delegation_id;
        SET @out_delegation_id = @delegation_id;
    END
    EXEC grac_practice.sp_tprm_audit N'tprm-delegation', @out_delegation_id, N'SAVE', NULL, @actor;
END
GO

-- =====================================================================
-- 11. Custom fields
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_custom_field_list
    @organization_id BIGINT,
    @entity_code     NVARCHAR(30) = NULL,
    @active_only     BIT          = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 57508, 'Select an organization.', 1;
    SELECT f.field_id AS FieldId, f.entity_code AS EntityCode, f.field_code AS FieldCode, f.label AS Label,
           f.description AS Description, f.data_type AS DataType, f.is_mandatory AS IsMandatory,
           f.default_value AS DefaultValue, f.validation_regex AS ValidationRegex, f.min_value AS MinValue,
           f.max_value AS MaxValue, f.max_length AS MaxLength, f.options_json AS OptionsJson,
           f.reference_kind AS ReferenceKind, f.visible_when_field_code AS VisibleWhenFieldCode,
           f.visible_when_value AS VisibleWhenValue, f.access_role_names AS AccessRoleNames,
           f.is_searchable AS IsSearchable, f.is_filterable AS IsFilterable, f.is_reportable AS IsReportable,
           f.display_order AS DisplayOrder, f.status AS Status
    FROM   grac_practice.tprm_custom_field f
    WHERE  f.organization_id = @organization_id
      AND  (@entity_code IS NULL OR f.entity_code = @entity_code)
      AND  (ISNULL(@active_only, 0) = 0 OR f.status = N'Active')
    ORDER  BY f.entity_code, f.display_order, f.label;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_custom_field_save
    @organization_id         BIGINT,
    @field_id                BIGINT         = NULL,
    @entity_code             NVARCHAR(30),
    @field_code              NVARCHAR(60),
    @label                   NVARCHAR(200),
    @description             NVARCHAR(1000) = NULL,
    @data_type               NVARCHAR(20),
    @is_mandatory            BIT            = 0,
    @default_value           NVARCHAR(500)  = NULL,
    @validation_regex        NVARCHAR(300)  = NULL,
    @min_value               DECIMAL(19,4)  = NULL,
    @max_value               DECIMAL(19,4)  = NULL,
    @max_length              INT            = NULL,
    @options_json            NVARCHAR(MAX)  = NULL,
    @reference_kind          NVARCHAR(60)   = NULL,
    @visible_when_field_code NVARCHAR(60)   = NULL,
    @visible_when_value      NVARCHAR(200)  = NULL,
    @access_role_names       NVARCHAR(600)  = NULL,
    @is_searchable           BIT            = 0,
    @is_filterable           BIT            = 0,
    @is_reportable           BIT            = 1,
    @display_order           INT            = 100,
    @status                  NVARCHAR(20)   = N'Active',
    @actor                   NVARCHAR(100)  = N'system',
    @out_field_id            BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL THROW 57508, 'Select an organization.', 1;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, 0;

    SET @field_code = UPPER(NULLIF(LTRIM(RTRIM(@field_code)), N''));
    SET @label = NULLIF(LTRIM(RTRIM(@label)), N'');
    SET @options_json = NULLIF(LTRIM(RTRIM(@options_json)), N'');
    SET @reference_kind = NULLIF(LTRIM(RTRIM(@reference_kind)), N'');
    IF @field_code IS NULL OR @label IS NULL THROW 57540, 'Code and label are both required.', 1;
    IF @field_code LIKE N'%[^A-Z0-9_]%' THROW 57504, 'Codes may contain only letters, digits and underscores.', 1;
    IF @entity_code NOT IN (N'THIRD_PARTY', N'ENGAGEMENT', N'FINDING', N'REVIEW') THROW 57541, 'Unknown record type.', 1;
    IF @data_type NOT IN (N'TEXT', N'NUMBER', N'DATE', N'BOOLEAN', N'SINGLE_SELECT', N'MULTI_SELECT', N'REFERENCE')
        THROW 57542, 'Unknown data type.', 1;
    IF @data_type IN (N'SINGLE_SELECT', N'MULTI_SELECT')
       AND (@options_json IS NULL OR ISJSON(@options_json) <> 1
            OR (SELECT COUNT(*) FROM OPENJSON(@options_json) WITH (code NVARCHAR(60) '$.code', label NVARCHAR(200) '$.label')
                 WHERE NULLIF(code, N'') IS NOT NULL AND NULLIF(label, N'') IS NOT NULL) < 1)
        THROW 57543, 'A select field needs at least one option with a code and a label.', 1;
    IF @data_type = N'REFERENCE'
       AND (@reference_kind IS NULL
            OR (@reference_kind NOT IN (N'EMPLOYEE', N'THIRD_PARTY', N'VENDOR', N'BUSINESS_FUNCTION')
                AND (@reference_kind NOT LIKE N'LIST:%'
                     OR NOT EXISTS (SELECT 1 FROM grac_practice.tprm_reference_list
                                     WHERE list_code = SUBSTRING(@reference_kind, 6, 60)))))
        THROW 57544, 'Choose what a reference field points to.', 1;
    IF @min_value IS NOT NULL AND @max_value IS NOT NULL AND @max_value < @min_value
        THROW 57545, 'The maximum is below the minimum.', 1;
    IF @visible_when_field_code IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_custom_field
                        WHERE organization_id = @organization_id AND entity_code = @entity_code
                          AND field_code = UPPER(@visible_when_field_code) AND ISNULL(field_id, 0) <> ISNULL(@field_id, -1))
        THROW 57546, 'The field this one depends on does not exist on the same record type.', 1;
    IF ISNULL(@status, N'') NOT IN (N'Active', N'Retired') SET @status = N'Active';

    IF @field_id IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_custom_field
                    WHERE organization_id = @organization_id AND entity_code = @entity_code AND field_code = @field_code)
            THROW 57547, 'A field with that code already exists on this record type.', 1;
        INSERT grac_practice.tprm_custom_field
            (organization_id, entity_code, field_code, label, description, data_type, is_mandatory, default_value,
             validation_regex, min_value, max_value, max_length, options_json, reference_kind, visible_when_field_code,
             visible_when_value, access_role_names, is_searchable, is_filterable, is_reportable, display_order, status, entered_by)
        VALUES (@organization_id, @entity_code, @field_code, @label, @description, @data_type, ISNULL(@is_mandatory, 0), @default_value,
                @validation_regex, @min_value, @max_value, @max_length, @options_json, @reference_kind,
                UPPER(NULLIF(LTRIM(RTRIM(@visible_when_field_code)), N'')), @visible_when_value,
                NULLIF(LTRIM(RTRIM(@access_role_names)), N''), ISNULL(@is_searchable, 0), ISNULL(@is_filterable, 0),
                ISNULL(@is_reportable, 1), ISNULL(@display_order, 100), @status, @actor);
        SET @out_field_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @old_type NVARCHAR(20) = (SELECT data_type FROM grac_practice.tprm_custom_field
                                            WHERE field_id = @field_id AND organization_id = @organization_id);
        IF @old_type IS NULL THROW 57548, 'That field was not found.', 1;
        -- Stored values would lose their meaning if the type changed.
        IF @old_type <> @data_type AND EXISTS (SELECT 1 FROM grac_practice.tprm_custom_field_value WHERE field_id = @field_id)
            THROW 57549, 'This field already has values; its data type cannot change. Retire it and add a new field.', 1;
        UPDATE grac_practice.tprm_custom_field
           SET label = @label, description = @description, data_type = @data_type, is_mandatory = ISNULL(@is_mandatory, 0),
               default_value = @default_value, validation_regex = @validation_regex, min_value = @min_value, max_value = @max_value,
               max_length = @max_length, options_json = @options_json, reference_kind = @reference_kind,
               visible_when_field_code = UPPER(NULLIF(LTRIM(RTRIM(@visible_when_field_code)), N'')),
               visible_when_value = @visible_when_value, access_role_names = NULLIF(LTRIM(RTRIM(@access_role_names)), N''),
               is_searchable = ISNULL(@is_searchable, 0), is_filterable = ISNULL(@is_filterable, 0),
               is_reportable = ISNULL(@is_reportable, 1), display_order = ISNULL(@display_order, 100),
               status = @status, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE field_id = @field_id;
        SET @out_field_id = @field_id;
    END
    EXEC grac_practice.sp_tprm_audit N'tprm-custom-field', @out_field_id, N'SAVE', @field_code, @actor;
END
GO

-- Internal: write the custom values of one record.
--   @values_json : [{"fieldCode":"X","value":"..."}] -- one string per
--   field (MULTI_SELECT: comma separated codes; BOOLEAN: true/false;
--   DATE: yyyy-mm-dd; REFERENCE: the id).
-- Mandatory fields that are visible must have a value; hidden values
-- (visibility condition false) are cleared. Fields the caller's roles may
-- not access are left untouched (@caller_role_names: comma separated).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_custom_values_save
    @organization_id   BIGINT,
    @entity_code       NVARCHAR(30),
    @record_id         BIGINT,
    @values_json       NVARCHAR(MAX) = NULL,
    @caller_role_names NVARCHAR(600) = NULL,
    @caller_is_admin   BIT           = 0,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    -- NULL = the caller did not send the custom section (e.g. an import):
    -- leave the stored values as they are.
    IF @values_json IS NULL RETURN;
    IF ISJSON(@values_json) <> 1
        THROW 57550, 'Custom field values are not valid.', 1;

    DECLARE @v TABLE (field_id BIGINT PRIMARY KEY, field_code NVARCHAR(60), data_type NVARCHAR(20),
                      is_mandatory BIT, raw NVARCHAR(2000), visible BIT, can_access BIT,
                      min_value DECIMAL(19,4), max_value DECIMAL(19,4), max_length INT,
                      options_json NVARCHAR(MAX), label NVARCHAR(200),
                      visible_when_field_code NVARCHAR(60), visible_when_value NVARCHAR(200), supplied BIT);

    INSERT @v (field_id, field_code, data_type, is_mandatory, raw, visible, can_access, min_value, max_value, max_length,
               options_json, label, visible_when_field_code, visible_when_value, supplied)
    SELECT f.field_id, f.field_code, f.data_type, f.is_mandatory,
           NULLIF(LTRIM(RTRIM(j.value)), N''), 1,
           CASE WHEN ISNULL(@caller_is_admin, 0) = 1 OR f.access_role_names IS NULL
                     OR EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(f.access_role_names) a
                                JOIN grac_practice.fn_tprm_split_codes(@caller_role_names) c ON c.code = a.code)
                THEN 1 ELSE 0 END,
           f.min_value, f.max_value, f.max_length, f.options_json, f.label,
           f.visible_when_field_code, f.visible_when_value,
           CASE WHEN j.fieldCode IS NULL THEN 0 ELSE 1 END
    FROM   grac_practice.tprm_custom_field f
    LEFT   JOIN OPENJSON(ISNULL(@values_json, N'[]'))
           WITH (fieldCode NVARCHAR(60) '$.fieldCode', value NVARCHAR(2000) '$.value') j
           ON UPPER(j.fieldCode) = f.field_code
    WHERE  f.organization_id = @organization_id AND f.entity_code = @entity_code AND f.status = N'Active';

    -- Not supplied: keep the stored value (for the visibility test too).
    UPDATE v SET raw = COALESCE(s.value_text,
                                CONVERT(NVARCHAR(40), s.value_number),
                                CONVERT(NVARCHAR(10), s.value_date, 23),
                                CASE WHEN s.value_bool = 1 THEN N'true' WHEN s.value_bool = 0 THEN N'false' END,
                                CONVERT(NVARCHAR(40), s.value_ref_id))
    FROM   @v v
    JOIN   grac_practice.tprm_custom_field_value s ON s.field_id = v.field_id AND s.record_id = @record_id
    WHERE  v.supplied = 0 OR v.can_access = 0;

    -- Conditional visibility (one level, against the controlling field's value).
    UPDATE v SET visible = CASE WHEN p.raw IS NOT NULL
                                 AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(p.raw) x
                                             WHERE x.code = v.visible_when_value)
                                THEN 1 ELSE 0 END
    FROM   @v v
    LEFT   JOIN @v p ON p.field_code = v.visible_when_field_code
    WHERE  v.visible_when_field_code IS NOT NULL;

    DECLARE @msg NVARCHAR(400);
    SELECT TOP (1) @msg = CONCAT(N'"', label, N'" is required.')
    FROM @v WHERE is_mandatory = 1 AND visible = 1 AND can_access = 1 AND raw IS NULL;
    IF @msg IS NOT NULL THROW 57551, @msg, 1;

    SELECT TOP (1) @msg = CONCAT(N'"', label, N'" must be a number.')
    FROM @v WHERE data_type = N'NUMBER' AND raw IS NOT NULL AND TRY_CONVERT(DECIMAL(19,4), raw) IS NULL;
    IF @msg IS NOT NULL THROW 57552, @msg, 1;
    SELECT TOP (1) @msg = CONCAT(N'"', label, N'" is outside the allowed range.')
    FROM @v WHERE data_type = N'NUMBER' AND raw IS NOT NULL
             AND ((min_value IS NOT NULL AND TRY_CONVERT(DECIMAL(19,4), raw) < min_value)
               OR (max_value IS NOT NULL AND TRY_CONVERT(DECIMAL(19,4), raw) > max_value));
    IF @msg IS NOT NULL THROW 57553, @msg, 1;
    SELECT TOP (1) @msg = CONCAT(N'"', label, N'" must be a date.')
    FROM @v WHERE data_type = N'DATE' AND raw IS NOT NULL AND TRY_CONVERT(DATE, raw) IS NULL;
    IF @msg IS NOT NULL THROW 57554, @msg, 1;
    SELECT TOP (1) @msg = CONCAT(N'"', label, N'" is too long.')
    FROM @v WHERE data_type = N'TEXT' AND raw IS NOT NULL AND max_length IS NOT NULL AND LEN(raw) > max_length;
    IF @msg IS NOT NULL THROW 57555, @msg, 1;
    SELECT TOP (1) @msg = CONCAT(N'"', label, N'" has a value that is not one of its options.')
    FROM @v v
    WHERE v.data_type IN (N'SINGLE_SELECT', N'MULTI_SELECT') AND v.raw IS NOT NULL
      AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(v.raw) x
                  WHERE NOT EXISTS (SELECT 1 FROM OPENJSON(ISNULL(v.options_json, N'[]')) WITH (code NVARCHAR(60) '$.code') o
                                     WHERE o.code = x.code));
    IF @msg IS NOT NULL THROW 57556, @msg, 1;
    SELECT TOP (1) @msg = CONCAT(N'"', label, N'" allows one option only.')
    FROM @v v WHERE v.data_type = N'SINGLE_SELECT' AND v.raw IS NOT NULL
             AND (SELECT COUNT(*) FROM grac_practice.fn_tprm_split_codes(v.raw)) > 1;
    IF @msg IS NOT NULL THROW 57556, @msg, 1;
    SELECT TOP (1) @msg = CONCAT(N'"', label, N'" must be true or false.')
    FROM @v WHERE data_type = N'BOOLEAN' AND raw IS NOT NULL AND LOWER(raw) NOT IN (N'true', N'false', N'1', N'0');
    IF @msg IS NOT NULL THROW 57557, @msg, 1;
    SELECT TOP (1) @msg = CONCAT(N'"', label, N'" must point to a record.')
    FROM @v WHERE data_type = N'REFERENCE' AND raw IS NOT NULL AND TRY_CONVERT(BIGINT, raw) IS NULL;
    IF @msg IS NOT NULL THROW 57558, @msg, 1;

    -- Hidden by its condition: no value is kept.
    DELETE s FROM grac_practice.tprm_custom_field_value s
    JOIN @v v ON v.field_id = s.field_id
    WHERE s.record_id = @record_id AND v.can_access = 1 AND (v.visible = 0 OR v.raw IS NULL);

    MERGE grac_practice.tprm_custom_field_value AS t
    USING (SELECT field_id, data_type, raw FROM @v WHERE can_access = 1 AND supplied = 1 AND visible = 1 AND raw IS NOT NULL) AS s
    ON t.field_id = s.field_id AND t.record_id = @record_id
    WHEN MATCHED THEN UPDATE SET
        value_text   = CASE WHEN s.data_type IN (N'TEXT', N'SINGLE_SELECT', N'MULTI_SELECT') THEN s.raw END,
        value_number = CASE WHEN s.data_type = N'NUMBER' THEN TRY_CONVERT(DECIMAL(19,4), s.raw) END,
        value_date   = CASE WHEN s.data_type = N'DATE' THEN TRY_CONVERT(DATE, s.raw) END,
        value_bool   = CASE WHEN s.data_type = N'BOOLEAN' THEN CASE WHEN LOWER(s.raw) IN (N'true', N'1') THEN 1 ELSE 0 END END,
        value_ref_id = CASE WHEN s.data_type = N'REFERENCE' THEN TRY_CONVERT(BIGINT, s.raw) END,
        updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (organization_id, field_id, entity_code, record_id, value_text, value_number, value_date, value_bool, value_ref_id, updated_by)
    VALUES (@organization_id, s.field_id, @entity_code, @record_id,
        CASE WHEN s.data_type IN (N'TEXT', N'SINGLE_SELECT', N'MULTI_SELECT') THEN s.raw END,
        CASE WHEN s.data_type = N'NUMBER' THEN TRY_CONVERT(DECIMAL(19,4), s.raw) END,
        CASE WHEN s.data_type = N'DATE' THEN TRY_CONVERT(DATE, s.raw) END,
        CASE WHEN s.data_type = N'BOOLEAN' THEN CASE WHEN LOWER(s.raw) IN (N'true', N'1') THEN 1 ELSE 0 END END,
        CASE WHEN s.data_type = N'REFERENCE' THEN TRY_CONVERT(BIGINT, s.raw) END,
        @actor);
END
GO

-- The custom values of one record as rows (for the "get" procedures).
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_custom_values (@organization_id BIGINT, @entity_code NVARCHAR(30), @record_id BIGINT)
RETURNS TABLE
AS
RETURN
SELECT f.field_id, f.field_code, f.label, f.data_type,
       COALESCE(s.value_text, CONVERT(NVARCHAR(40), s.value_number), CONVERT(NVARCHAR(10), s.value_date, 23),
                CASE WHEN s.value_bool = 1 THEN N'true' WHEN s.value_bool = 0 THEN N'false' END,
                CONVERT(NVARCHAR(40), s.value_ref_id)) AS value_string
FROM   grac_practice.tprm_custom_field f
JOIN   grac_practice.tprm_custom_field_value s ON s.field_id = f.field_id AND s.record_id = @record_id
WHERE  f.organization_id = @organization_id AND f.entity_code = @entity_code;
GO

-- =====================================================================
-- 12. Templates -- list, get, create, adopt, versions, items, activate
-- =====================================================================

-- Templates visible in a scope. For an organization: its own templates
-- and every GRAC template, with whether it was adopted, which version is
-- in force and whether GRAC has published a newer version than the one
-- the organization's copy derives from (UpdateAvailable).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_template_list
    @organization_id   BIGINT       = NULL,
    @template_kind     NVARCHAR(20) = NULL,
    @is_platform_admin BIT          = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, @is_platform_admin;

    ;WITH tpl AS (
        SELECT t.*
        FROM   grac_practice.tprm_template t
        WHERE  (t.organization_id IS NULL OR t.organization_id = @organization_id)
          AND  (@template_kind IS NULL OR t.template_kind = @template_kind)
    )
    SELECT t.template_id AS TemplateId, t.template_kind AS TemplateKind, t.template_code AS TemplateCode,
           t.template_name AS TemplateName, t.description AS Description, t.is_default AS IsDefault,
           CASE WHEN t.organization_id IS NULL THEN N'GRAC' ELSE N'ORGANIZATION' END AS Origin,
           t.baseline_template_id AS BaselineTemplateId, bt.template_name AS BaselineTemplateName,
           t.status AS Status, t.current_version_id AS CurrentVersionId, cv.version_no AS CurrentVersionNo,
           cv.activated_dt AS CurrentActivatedDt,
           dv.version_id AS DraftVersionId, dv.version_no AS DraftVersionNo,
           cv.is_core AS IsCore, cv.applies_service_categories AS AppliesServiceCategories,
           cv.applies_min_tier_rank AS AppliesMinTierRank,
           -- organization copy: the GRAC version its content derives from vs GRAC's current one
           obv.version_no AS DerivedFromBaselineVersionNo, bcv.version_no AS BaselineCurrentVersionNo,
           CAST(CASE WHEN t.baseline_template_id IS NOT NULL AND bt.current_version_id IS NOT NULL
                      AND ISNULL(COALESCE(cv.baseline_version_id, dv.baseline_version_id), 0) <> bt.current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS UpdateAvailable,
           -- GRAC template seen from an organization
           at.template_id AS AdoptedTemplateId,
           CAST(CASE WHEN t.organization_id IS NULL AND @organization_id IS NOT NULL
                      AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_template_effective(@organization_id) e
                                   WHERE e.template_id = t.template_id)
                     THEN 1
                     WHEN t.organization_id IS NOT NULL
                      AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_template_effective(@organization_id) e
                                   WHERE e.template_id = t.template_id)
                     THEN 1 ELSE 0 END AS BIT) AS InForce,
           (SELECT COUNT(*) FROM grac_practice.tprm_template_version v WHERE v.template_id = t.template_id) AS VersionCount
    FROM   tpl t
    LEFT   JOIN grac_practice.tprm_template_version cv ON cv.version_id = t.current_version_id
    LEFT   JOIN grac_practice.tprm_template_version dv ON dv.template_id = t.template_id AND dv.status = N'DRAFT'
    LEFT   JOIN grac_practice.tprm_template bt ON bt.template_id = t.baseline_template_id
    LEFT   JOIN grac_practice.tprm_template_version bcv ON bcv.version_id = bt.current_version_id
    LEFT   JOIN grac_practice.tprm_template_version obv ON obv.version_id = COALESCE(cv.baseline_version_id, dv.baseline_version_id)
    OUTER  APPLY (SELECT TOP (1) a.template_id FROM grac_practice.tprm_template a
                   WHERE t.organization_id IS NULL AND a.organization_id = @organization_id
                     AND a.baseline_template_id = t.template_id) at
    ORDER  BY t.template_kind DESC, CASE WHEN t.organization_id IS NULL THEN 1 ELSE 0 END, t.template_name;
END
GO

-- One version with its content. Result sets:
--   1 header (template + version)   2 versions of the template
--   RISK_MODEL:    3 dimensions  4 factors  5 options  6 bands  7 tier rules
--   QUESTIONNAIRE: 3 sections    4 questions 5 options
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_template_version_get
    @organization_id BIGINT = NULL,
    @version_id      BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @template_id BIGINT, @kind NVARCHAR(20), @owner BIGINT;
    SELECT @template_id = t.template_id, @kind = t.template_kind, @owner = t.organization_id
    FROM   grac_practice.tprm_template_version v
    JOIN   grac_practice.tprm_template t ON t.template_id = v.template_id
    WHERE  v.version_id = @version_id;
    -- GRAC versions are readable by everyone; an organization's only by itself.
    IF @template_id IS NULL OR (@owner IS NOT NULL AND ISNULL(@organization_id, -1) <> @owner)
        THROW 57560, 'That template version was not found.', 1;

    SELECT t.template_id AS TemplateId, t.template_kind AS TemplateKind, t.template_code AS TemplateCode,
           t.template_name AS TemplateName, t.description AS Description, t.is_default AS IsDefault,
           CASE WHEN t.organization_id IS NULL THEN N'GRAC' ELSE N'ORGANIZATION' END AS Origin,
           t.baseline_template_id AS BaselineTemplateId, t.status AS TemplateStatus,
           v.version_id AS VersionId, v.version_no AS VersionNo, v.status AS VersionStatus,
           v.based_on_version_id AS BasedOnVersionId, v.baseline_version_id AS BaselineVersionId,
           bv.version_no AS BaselineVersionNo, v.change_summary AS ChangeSummary,
           v.is_core AS IsCore, v.applies_service_categories AS AppliesServiceCategories,
           v.applies_min_tier_rank AS AppliesMinTierRank, v.applies_engagement_types AS AppliesEngagementTypes,
           v.aggregation_method AS AggregationMethod, v.blend_pct AS BlendPct,
           v.effective_reduction_pct AS EffectiveReductionPct, v.partial_reduction_pct AS PartialReductionPct,
           v.residual_floor_pct AS ResidualFloorPct, v.deficiency_uplift_pct AS DeficiencyUpliftPct,
           v.created_by AS CreatedBy, v.created_dt AS CreatedDt, v.activated_by AS ActivatedBy, v.activated_dt AS ActivatedDt,
           CAST(CASE WHEN v.status = N'DRAFT' THEN 1 ELSE 0 END AS BIT) AS IsEditable
    FROM   grac_practice.tprm_template_version v
    JOIN   grac_practice.tprm_template t ON t.template_id = v.template_id
    LEFT   JOIN grac_practice.tprm_template_version bv ON bv.version_id = v.baseline_version_id
    WHERE  v.version_id = @version_id;

    SELECT v.version_id AS VersionId, v.version_no AS VersionNo, v.status AS Status, v.change_summary AS ChangeSummary,
           v.created_by AS CreatedBy, v.created_dt AS CreatedDt, v.activated_by AS ActivatedBy, v.activated_dt AS ActivatedDt,
           bv.version_no AS BaselineVersionNo
    FROM   grac_practice.tprm_template_version v
    LEFT   JOIN grac_practice.tprm_template_version bv ON bv.version_id = v.baseline_version_id
    WHERE  v.template_id = @template_id
    ORDER  BY v.version_no DESC;

    IF @kind = N'RISK_MODEL'
    BEGIN
        SELECT d.dimension_id AS DimensionId, d.dimension_code AS DimensionCode, d.dimension_name AS DimensionName,
               d.description AS Description, d.weight AS Weight, d.display_order AS DisplayOrder
        FROM   grac_practice.tprm_rm_dimension d WHERE d.version_id = @version_id ORDER BY d.display_order, d.dimension_name;
        SELECT f.factor_id AS FactorId, f.dimension_id AS DimensionId, d.dimension_code AS DimensionCode,
               f.factor_code AS FactorCode, f.question_text AS QuestionText, f.guidance AS Guidance,
               f.is_mandatory AS IsMandatory, f.prefill_source AS PrefillSource, f.display_order AS DisplayOrder
        FROM   grac_practice.tprm_rm_factor f
        JOIN   grac_practice.tprm_rm_dimension d ON d.dimension_id = f.dimension_id
        WHERE  f.version_id = @version_id ORDER BY d.display_order, f.display_order;
        SELECT o.option_id AS OptionId, o.factor_id AS FactorId, o.option_code AS OptionCode, o.option_label AS OptionLabel,
               o.score AS Score, o.prefill_match_code AS PrefillMatchCode, o.display_order AS DisplayOrder
        FROM   grac_practice.tprm_rm_factor_option o
        JOIN   grac_practice.tprm_rm_factor f ON f.factor_id = o.factor_id
        WHERE  f.version_id = @version_id ORDER BY o.factor_id, o.display_order;
        SELECT b.band_id AS BandId, b.band_code AS BandCode, b.band_name AS BandName, b.min_score AS MinScore,
               LEAD(b.min_score) OVER (ORDER BY b.min_score) AS NextMinScore,
               b.rank_no AS RankNo, b.color_hex AS ColorHex, b.dd_tier_code AS DdTierCode
        FROM   grac_practice.tprm_rm_band b WHERE b.version_id = @version_id ORDER BY b.min_score;
        SELECT r.tier_rule_id AS TierRuleId, r.condition_kind AS ConditionKind, r.condition_code AS ConditionCode,
               r.min_dd_tier_code AS MinDdTierCode
        FROM   grac_practice.tprm_rm_tier_rule r WHERE r.version_id = @version_id ORDER BY r.condition_kind, r.condition_code;
    END
    ELSE
    BEGIN
        SELECT s.section_id AS SectionId, s.section_code AS SectionCode, s.title AS Title, s.description AS Description,
               s.display_order AS DisplayOrder
        FROM   grac_practice.tprm_q_section s WHERE s.version_id = @version_id ORDER BY s.display_order, s.title;
        SELECT q.question_id AS QuestionId, q.section_id AS SectionId, q.question_code AS QuestionCode,
               q.question_text AS QuestionText, q.guidance AS Guidance, q.response_type AS ResponseType,
               q.is_mandatory AS IsMandatory, q.evidence_expected AS EvidenceExpected,
               q.evidence_requirement_code AS EvidenceRequirementCode, q.safeguard_code AS SafeguardCode,
               q.dimension_code AS DimensionCode, q.min_tier_rank AS MinTierRank,
               q.applies_service_categories AS AppliesServiceCategories, q.applies_min_data_rank AS AppliesMinDataRank,
               q.applies_access_codes AS AppliesAccessCodes, q.parent_question_code AS ParentQuestionCode,
               q.trigger_option_codes AS TriggerOptionCodes, q.weight AS Weight, q.display_order AS DisplayOrder,
               q.source_authority AS SourceAuthority, q.source_document AS SourceDocument, q.source_version AS SourceVersion,
               q.source_reference AS SourceReference, q.applicability_note AS ApplicabilityNote, q.is_regulatory AS IsRegulatory
        FROM   grac_practice.tprm_q_question q
        JOIN   grac_practice.tprm_q_section s ON s.section_id = q.section_id
        WHERE  q.version_id = @version_id ORDER BY s.display_order, q.display_order;
        SELECT o.option_id AS OptionId, o.question_id AS QuestionId, o.option_code AS OptionCode, o.option_label AS OptionLabel,
               o.score AS Score, o.flags_deficiency AS FlagsDeficiency, o.deficiency_severity_code AS DeficiencySeverityCode,
               o.display_order AS DisplayOrder
        FROM   grac_practice.tprm_q_option o
        JOIN   grac_practice.tprm_q_question q ON q.question_id = o.question_id
        WHERE  q.version_id = @version_id ORDER BY o.question_id, o.display_order;
    END
END
GO

-- Internal: copy the content of one version into another (empty) one.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_template_version_copy
    @from_version_id BIGINT,
    @to_version_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @dim TABLE (old_id BIGINT, new_id BIGINT);
    DECLARE @fac TABLE (old_id BIGINT, new_id BIGINT);
    DECLARE @sec TABLE (old_id BIGINT, new_id BIGINT);
    DECLARE @que TABLE (old_id BIGINT, new_id BIGINT);

    UPDATE t SET is_core = f.is_core, applies_service_categories = f.applies_service_categories,
                 applies_min_tier_rank = f.applies_min_tier_rank, applies_engagement_types = f.applies_engagement_types,
                 aggregation_method = f.aggregation_method, blend_pct = f.blend_pct,
                 effective_reduction_pct = f.effective_reduction_pct, partial_reduction_pct = f.partial_reduction_pct,
                 residual_floor_pct = f.residual_floor_pct, deficiency_uplift_pct = f.deficiency_uplift_pct
    FROM grac_practice.tprm_template_version t
    JOIN grac_practice.tprm_template_version f ON f.version_id = @from_version_id
    WHERE t.version_id = @to_version_id;

    MERGE grac_practice.tprm_rm_dimension AS t
    USING (SELECT * FROM grac_practice.tprm_rm_dimension WHERE version_id = @from_version_id) AS s
    ON 1 = 0
    WHEN NOT MATCHED THEN INSERT (version_id, dimension_code, dimension_name, description, weight, display_order)
         VALUES (@to_version_id, s.dimension_code, s.dimension_name, s.description, s.weight, s.display_order)
    OUTPUT s.dimension_id, inserted.dimension_id INTO @dim(old_id, new_id);

    MERGE grac_practice.tprm_rm_factor AS t
    USING (SELECT f.*, m.new_id AS new_dimension_id FROM grac_practice.tprm_rm_factor f
           JOIN @dim m ON m.old_id = f.dimension_id WHERE f.version_id = @from_version_id) AS s
    ON 1 = 0
    WHEN NOT MATCHED THEN INSERT (version_id, dimension_id, factor_code, question_text, guidance, is_mandatory, prefill_source, display_order)
         VALUES (@to_version_id, s.new_dimension_id, s.factor_code, s.question_text, s.guidance, s.is_mandatory, s.prefill_source, s.display_order)
    OUTPUT s.factor_id, inserted.factor_id INTO @fac(old_id, new_id);

    INSERT grac_practice.tprm_rm_factor_option (factor_id, option_code, option_label, score, prefill_match_code, display_order)
    SELECT m.new_id, o.option_code, o.option_label, o.score, o.prefill_match_code, o.display_order
    FROM   grac_practice.tprm_rm_factor_option o JOIN @fac m ON m.old_id = o.factor_id;

    INSERT grac_practice.tprm_rm_band (version_id, band_code, band_name, min_score, rank_no, color_hex, dd_tier_code)
    SELECT @to_version_id, band_code, band_name, min_score, rank_no, color_hex, dd_tier_code
    FROM   grac_practice.tprm_rm_band WHERE version_id = @from_version_id;

    INSERT grac_practice.tprm_rm_tier_rule (version_id, condition_kind, condition_code, min_dd_tier_code)
    SELECT @to_version_id, condition_kind, condition_code, min_dd_tier_code
    FROM   grac_practice.tprm_rm_tier_rule WHERE version_id = @from_version_id;

    MERGE grac_practice.tprm_q_section AS t
    USING (SELECT * FROM grac_practice.tprm_q_section WHERE version_id = @from_version_id) AS s
    ON 1 = 0
    WHEN NOT MATCHED THEN INSERT (version_id, section_code, title, description, display_order)
         VALUES (@to_version_id, s.section_code, s.title, s.description, s.display_order)
    OUTPUT s.section_id, inserted.section_id INTO @sec(old_id, new_id);

    MERGE grac_practice.tprm_q_question AS t
    USING (SELECT q.*, m.new_id AS new_section_id FROM grac_practice.tprm_q_question q
           JOIN @sec m ON m.old_id = q.section_id WHERE q.version_id = @from_version_id) AS s
    ON 1 = 0
    WHEN NOT MATCHED THEN INSERT
        (version_id, section_id, question_code, question_text, guidance, response_type, is_mandatory, evidence_expected,
         evidence_requirement_code, safeguard_code, dimension_code, min_tier_rank, applies_service_categories,
         applies_min_data_rank, applies_access_codes, parent_question_code, trigger_option_codes, weight, display_order,
         source_authority, source_document, source_version, source_reference, applicability_note, is_regulatory)
    VALUES
        (@to_version_id, s.new_section_id, s.question_code, s.question_text, s.guidance, s.response_type, s.is_mandatory,
         s.evidence_expected, s.evidence_requirement_code, s.safeguard_code, s.dimension_code, s.min_tier_rank,
         s.applies_service_categories, s.applies_min_data_rank, s.applies_access_codes, s.parent_question_code,
         s.trigger_option_codes, s.weight, s.display_order, s.source_authority, s.source_document, s.source_version,
         s.source_reference, s.applicability_note, s.is_regulatory)
    OUTPUT s.question_id, inserted.question_id INTO @que(old_id, new_id);

    INSERT grac_practice.tprm_q_option (question_id, option_code, option_label, score, flags_deficiency, deficiency_severity_code, display_order)
    SELECT m.new_id, o.option_code, o.option_label, o.score, o.flags_deficiency, o.deficiency_severity_code, o.display_order
    FROM   grac_practice.tprm_q_option o JOIN @que m ON m.old_id = o.question_id;
END
GO

-- A new, empty template (DRAFT v1) in the scope. A risk model starts
-- with the scoring defaults; its content is added on the Draft.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_template_create
    @organization_id   BIGINT        = NULL,
    @template_kind     NVARCHAR(20),
    @template_code     NVARCHAR(60),
    @template_name     NVARCHAR(250),
    @description       NVARCHAR(2000) = NULL,
    @copy_from_version_id BIGINT     = NULL,
    @is_platform_admin BIT           = 0,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, @is_platform_admin;

    SET @template_code = UPPER(NULLIF(LTRIM(RTRIM(@template_code)), N''));
    SET @template_name = NULLIF(LTRIM(RTRIM(@template_name)), N'');
    IF @template_kind NOT IN (N'RISK_MODEL', N'QUESTIONNAIRE') THROW 57561, 'Unknown template type.', 1;
    IF @template_code IS NULL OR @template_name IS NULL THROW 57562, 'Code and name are both required.', 1;
    IF @template_code LIKE N'%[^A-Z0-9_]%' THROW 57504, 'Codes may contain only letters, digits and underscores.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_template
                WHERE template_kind = @template_kind AND template_code = @template_code
                  AND ((@organization_id IS NULL AND organization_id IS NULL) OR organization_id = @organization_id))
        THROW 57563, 'A template with that code already exists.', 1;
    IF @copy_from_version_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_template_version v
                        JOIN grac_practice.tprm_template t ON t.template_id = v.template_id
                        WHERE v.version_id = @copy_from_version_id AND t.template_kind = @template_kind
                          AND (t.organization_id IS NULL OR t.organization_id = @organization_id))
        THROW 57564, 'The version to copy was not found.', 1;

    DECLARE @template_id BIGINT, @version_id BIGINT;
    BEGIN TRAN;
        INSERT grac_practice.tprm_template (organization_id, template_kind, template_code, template_name, description, status, entered_by)
        VALUES (@organization_id, @template_kind, @template_code, @template_name, @description, N'Active', @actor);
        SET @template_id = SCOPE_IDENTITY();

        INSERT grac_practice.tprm_template_version
            (template_id, version_no, status, based_on_version_id, change_summary, aggregation_method, blend_pct,
             effective_reduction_pct, partial_reduction_pct, residual_floor_pct, deficiency_uplift_pct, created_by)
        VALUES (@template_id, 1, N'DRAFT', @copy_from_version_id, N'Created',
                CASE WHEN @template_kind = N'RISK_MODEL' THEN N'WEIGHTED_AVERAGE' END,
                CASE WHEN @template_kind = N'RISK_MODEL' THEN 50 END,
                CASE WHEN @template_kind = N'RISK_MODEL' THEN 60 END,
                CASE WHEN @template_kind = N'RISK_MODEL' THEN 30 END,
                CASE WHEN @template_kind = N'RISK_MODEL' THEN 20 END,
                CASE WHEN @template_kind = N'RISK_MODEL' THEN 10 END, @actor);
        SET @version_id = SCOPE_IDENTITY();

        IF @copy_from_version_id IS NOT NULL
            EXEC grac_practice.sp_tprm_template_version_copy @copy_from_version_id, @version_id;
    COMMIT;

    EXEC grac_practice.sp_tprm_audit N'tprm-template', @template_id, N'CREATE', @template_code, @actor;
    SELECT @template_id AS TemplateId, @version_id AS VersionId, N'CREATED' AS Result;
END
GO

-- Adopt a GRAC template into the organization (first adoption creates
-- the organization's copy), or adopt GRAC's newer version as a new Draft
-- of the organization's copy. Nothing is in force until activated.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_template_adopt
    @organization_id      BIGINT,
    @baseline_template_id BIGINT,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL THROW 57508, 'Select an organization.', 1;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, 0;

    DECLARE @kind NVARCHAR(20), @code NVARCHAR(60), @name NVARCHAR(250), @desc NVARCHAR(2000), @baseline_version BIGINT;
    SELECT @kind = template_kind, @code = template_code, @name = template_name, @desc = description,
           @baseline_version = current_version_id
    FROM   grac_practice.tprm_template
    WHERE  template_id = @baseline_template_id AND organization_id IS NULL AND status = N'Active';
    IF @kind IS NULL THROW 57565, 'That GRAC template was not found.', 1;
    IF @baseline_version IS NULL THROW 57566, 'That GRAC template has no published version yet.', 1;

    DECLARE @template_id BIGINT = (SELECT template_id FROM grac_practice.tprm_template
                                    WHERE organization_id = @organization_id AND baseline_template_id = @baseline_template_id);
    IF @template_id IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.tprm_template_version
                                             WHERE template_id = @template_id AND status = N'DRAFT')
        THROW 57567, 'Your copy already has a Draft version. Activate or discard it before adopting again.', 1;

    DECLARE @version_id BIGINT, @next INT;
    BEGIN TRAN;
        IF @template_id IS NULL
        BEGIN
            -- the code is GRAC's; if the organization already used it, suffix it
            DECLARE @org_code NVARCHAR(60) = @code;
            IF EXISTS (SELECT 1 FROM grac_practice.tprm_template WHERE organization_id = @organization_id
                         AND template_kind = @kind AND template_code = @org_code)
                SET @org_code = LEFT(@code, 52) + N'_ORG';
            INSERT grac_practice.tprm_template
                (organization_id, template_kind, template_code, template_name, description, baseline_template_id, status, entered_by)
            VALUES (@organization_id, @kind, @org_code, @name, @desc, @baseline_template_id, N'Active', @actor);
            SET @template_id = SCOPE_IDENTITY();
        END
        ELSE
            UPDATE grac_practice.tprm_template SET status = N'Active', updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE template_id = @template_id;

        SET @next = ISNULL((SELECT MAX(version_no) FROM grac_practice.tprm_template_version WHERE template_id = @template_id), 0) + 1;
        INSERT grac_practice.tprm_template_version
            (template_id, version_no, status, based_on_version_id, baseline_version_id, change_summary, created_by)
        VALUES (@template_id, @next, N'DRAFT', @baseline_version, @baseline_version,
                CONCAT(N'Adopted from GRAC version ', (SELECT version_no FROM grac_practice.tprm_template_version WHERE version_id = @baseline_version)),
                @actor);
        SET @version_id = SCOPE_IDENTITY();
        EXEC grac_practice.sp_tprm_template_version_copy @baseline_version, @version_id;
    COMMIT;

    EXEC grac_practice.sp_tprm_audit N'tprm-template', @template_id, N'ADOPT', @code, @actor;
    SELECT @template_id AS TemplateId, @version_id AS VersionId, N'ADOPTED' AS Result;
END
GO

-- A new Draft of a template from its ACTIVE version (or the latest).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_template_new_version
    @organization_id   BIGINT        = NULL,
    @template_id       BIGINT,
    @is_platform_admin BIT           = 0,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, @is_platform_admin;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_template WHERE template_id = @template_id
                     AND ((@organization_id IS NULL AND organization_id IS NULL) OR organization_id = @organization_id))
        THROW 57568, 'That template was not found in this scope.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_template_version WHERE template_id = @template_id AND status = N'DRAFT')
        THROW 57567, 'This template already has a Draft version. Activate or discard it first.', 1;

    DECLARE @from BIGINT = (SELECT TOP (1) version_id FROM grac_practice.tprm_template_version
                             WHERE template_id = @template_id AND status IN (N'ACTIVE', N'SUPERSEDED')
                             ORDER BY CASE WHEN status = N'ACTIVE' THEN 0 ELSE 1 END, version_no DESC);
    DECLARE @baseline BIGINT = (SELECT baseline_version_id FROM grac_practice.tprm_template_version WHERE version_id = @from);
    DECLARE @next INT = ISNULL((SELECT MAX(version_no) FROM grac_practice.tprm_template_version WHERE template_id = @template_id), 0) + 1;
    DECLARE @version_id BIGINT;

    BEGIN TRAN;
        INSERT grac_practice.tprm_template_version
            (template_id, version_no, status, based_on_version_id, baseline_version_id, change_summary, created_by)
        VALUES (@template_id, @next, N'DRAFT', @from, @baseline, NULL, @actor);
        SET @version_id = SCOPE_IDENTITY();
        IF @from IS NOT NULL EXEC grac_practice.sp_tprm_template_version_copy @from, @version_id;
    COMMIT;
    EXEC grac_practice.sp_tprm_audit N'tprm-template-version', @version_id, N'NEW_VERSION', NULL, @actor;
    SELECT @template_id AS TemplateId, @version_id AS VersionId, N'CREATED' AS Result;
END
GO

-- Internal: the Draft version the caller may edit (raises otherwise).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_template_draft_check
    @organization_id   BIGINT,
    @version_id        BIGINT,
    @is_platform_admin BIT = 0,
    @kind              NVARCHAR(20) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @owner BIGINT, @status NVARCHAR(20), @found BIT = 0;
    SELECT @owner = t.organization_id, @status = v.status, @kind = t.template_kind, @found = 1
    FROM   grac_practice.tprm_template_version v
    JOIN   grac_practice.tprm_template t ON t.template_id = v.template_id
    WHERE  v.version_id = @version_id;
    IF @found = 0 THROW 57560, 'That template version was not found.', 1;
    IF @owner IS NULL AND ISNULL(@is_platform_admin, 0) = 0
        THROW 57500, 'The GRAC baseline is maintained by the platform administrator. Adopt the template to change your own copy.', 1;
    IF @owner IS NOT NULL AND ISNULL(@organization_id, -1) <> @owner
        THROW 57560, 'That template version was not found.', 1;
    IF @status <> N'DRAFT'
        THROW 57569, 'Only a Draft version can be changed. Create a new version first.', 1;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_template_version_header_save
    @organization_id            BIGINT         = NULL,
    @version_id                 BIGINT,
    @template_name              NVARCHAR(250)  = NULL,
    @description                NVARCHAR(2000) = NULL,
    @change_summary             NVARCHAR(2000) = NULL,
    @is_core                    BIT            = NULL,
    @applies_service_categories NVARCHAR(1000) = NULL,
    @applies_min_tier_rank      INT            = NULL,
    @applies_engagement_types   NVARCHAR(600)  = NULL,
    @aggregation_method         NVARCHAR(30)   = NULL,
    @blend_pct                  DECIMAL(5,2)   = NULL,
    @effective_reduction_pct    DECIMAL(5,2)   = NULL,
    @partial_reduction_pct      DECIMAL(5,2)   = NULL,
    @residual_floor_pct         DECIMAL(5,2)   = NULL,
    @deficiency_uplift_pct      DECIMAL(5,2)   = NULL,
    @is_default                 BIT            = NULL,
    @is_platform_admin          BIT            = 0,
    @actor                      NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @kind NVARCHAR(20);
    EXEC grac_practice.sp_tprm_template_draft_check @organization_id, @version_id, @is_platform_admin, @kind OUTPUT;

    IF @kind = N'RISK_MODEL'
    BEGIN
        IF ISNULL(@aggregation_method, N'') NOT IN (N'WEIGHTED_AVERAGE', N'HIGHEST_DIMENSION', N'BLENDED')
            THROW 57570, 'Choose how dimension scores combine into the overall score.', 1;
        IF EXISTS (SELECT 1 FROM (VALUES (@blend_pct), (@effective_reduction_pct), (@partial_reduction_pct),
                                         (@residual_floor_pct), (@deficiency_uplift_pct)) x(p)
                    WHERE p IS NULL OR p < 0 OR p > 100)
            THROW 57571, 'Every percentage must be between 0 and 100.', 1;
        IF @partial_reduction_pct > @effective_reduction_pct
            THROW 57572, 'A partially effective safeguard cannot reduce risk more than an effective one.', 1;
    END

    UPDATE grac_practice.tprm_template_version
       SET change_summary = @change_summary,
           is_core = CASE WHEN @kind = N'QUESTIONNAIRE' THEN ISNULL(@is_core, 0) ELSE 0 END,
           applies_service_categories = CASE WHEN @kind = N'QUESTIONNAIRE' THEN NULLIF(LTRIM(RTRIM(@applies_service_categories)), N'') END,
           applies_min_tier_rank = CASE WHEN @kind = N'QUESTIONNAIRE' THEN @applies_min_tier_rank END,
           applies_engagement_types = CASE WHEN @kind = N'QUESTIONNAIRE' THEN NULLIF(LTRIM(RTRIM(@applies_engagement_types)), N'') END,
           aggregation_method = CASE WHEN @kind = N'RISK_MODEL' THEN @aggregation_method END,
           blend_pct = CASE WHEN @kind = N'RISK_MODEL' THEN @blend_pct END,
           effective_reduction_pct = CASE WHEN @kind = N'RISK_MODEL' THEN @effective_reduction_pct END,
           partial_reduction_pct = CASE WHEN @kind = N'RISK_MODEL' THEN @partial_reduction_pct END,
           residual_floor_pct = CASE WHEN @kind = N'RISK_MODEL' THEN @residual_floor_pct END,
           deficiency_uplift_pct = CASE WHEN @kind = N'RISK_MODEL' THEN @deficiency_uplift_pct END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE version_id = @version_id;

    -- name / description / default flag live on the template
    UPDATE t SET template_name = COALESCE(NULLIF(LTRIM(RTRIM(@template_name)), N''), t.template_name),
                 description = COALESCE(@description, t.description),
                 is_default = CASE WHEN @kind = N'RISK_MODEL' AND t.organization_id IS NULL AND @is_default IS NOT NULL
                                   THEN @is_default ELSE t.is_default END,
                 updated_by = @actor, updated_dt = SYSUTCDATETIME()
    FROM grac_practice.tprm_template t
    JOIN grac_practice.tprm_template_version v ON v.template_id = t.template_id
    WHERE v.version_id = @version_id;

    EXEC grac_practice.sp_tprm_audit N'tprm-template-version', @version_id, N'HEADER', NULL, @actor;
    SELECT @version_id AS VersionId, N'SAVED' AS Result;
END
GO

-- Add / edit one risk model item on a Draft.
--   @item_type DIMENSION | FACTOR | BAND | TIER_RULE
--   FACTOR: @options_json = [{"code","label","score","prefillMatch"}] replaces the factor's options
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_rm_item_save
    @organization_id   BIGINT        = NULL,
    @version_id        BIGINT,
    @item_type         NVARCHAR(20),
    @item_id           BIGINT        = NULL,
    @code              NVARCHAR(60)  = NULL,
    @name              NVARCHAR(1000) = NULL,     -- dimension / band name, factor question
    @description       NVARCHAR(2000) = NULL,     -- dimension description, factor guidance
    @weight            DECIMAL(9,2)  = NULL,
    @dimension_code    NVARCHAR(60)  = NULL,      -- FACTOR
    @is_mandatory      BIT           = 1,
    @prefill_source    NVARCHAR(40)  = NULL,
    @options_json      NVARCHAR(MAX) = NULL,
    @min_score         DECIMAL(6,2)  = NULL,      -- BAND
    @rank_no           INT           = NULL,
    @color_hex         NVARCHAR(9)   = NULL,
    @dd_tier_code      NVARCHAR(60)  = NULL,      -- BAND / TIER_RULE
    @condition_kind    NVARCHAR(30)  = NULL,      -- TIER_RULE
    @display_order     INT           = 100,
    @is_platform_admin BIT           = 0,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @kind NVARCHAR(20);
    EXEC grac_practice.sp_tprm_template_draft_check @organization_id, @version_id, @is_platform_admin, @kind OUTPUT;
    IF @kind <> N'RISK_MODEL' THROW 57573, 'That version is not a risk model.', 1;

    SET @code = UPPER(NULLIF(LTRIM(RTRIM(@code)), N''));
    SET @name = NULLIF(LTRIM(RTRIM(@name)), N'');
    IF @item_type IN (N'DIMENSION', N'FACTOR', N'BAND') AND (@code IS NULL OR @name IS NULL)
        THROW 57574, 'Code and name are both required.', 1;
    IF @code LIKE N'%[^A-Z0-9_]%' THROW 57504, 'Codes may contain only letters, digits and underscores.', 1;
    DECLARE @new_id BIGINT = @item_id;

    IF @item_type = N'DIMENSION'
    BEGIN
        IF ISNULL(@weight, -1) < 0 THROW 57575, 'Weight cannot be negative.', 1;
        IF @item_id IS NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM grac_practice.tprm_rm_dimension WHERE version_id = @version_id AND dimension_code = @code)
                THROW 57576, 'That code is already used in this version.', 1;
            INSERT grac_practice.tprm_rm_dimension (version_id, dimension_code, dimension_name, description, weight, display_order)
            VALUES (@version_id, @code, LEFT(@name, 200), @description, @weight, ISNULL(@display_order, 100));
            SET @new_id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_rm_dimension WHERE dimension_id = @item_id AND version_id = @version_id)
                THROW 57577, 'That item was not found on this version.', 1;
            UPDATE grac_practice.tprm_rm_dimension
               SET dimension_name = LEFT(@name, 200), description = @description, weight = @weight, display_order = ISNULL(@display_order, 100)
             WHERE dimension_id = @item_id;
        END
    END
    ELSE IF @item_type = N'FACTOR'
    BEGIN
        DECLARE @dimension_id BIGINT = (SELECT dimension_id FROM grac_practice.tprm_rm_dimension
                                         WHERE version_id = @version_id AND dimension_code = UPPER(@dimension_code));
        IF @dimension_id IS NULL THROW 57578, 'Choose the dimension the factor belongs to.', 1;
        IF @prefill_source IS NOT NULL AND @prefill_source NOT IN (N'SERVICE_CRITICALITY', N'DATA_EXPOSURE', N'ACCESS', N'FOURTH_PARTY_COUNT', N'IS_EXISTING', N'SERVICE_MODEL', N'LOCATION_COUNT')
            THROW 57579, 'Unknown prefill source.', 1;
        IF @options_json IS NULL OR ISJSON(@options_json) <> 1
           OR (SELECT COUNT(*) FROM OPENJSON(@options_json) WITH (code NVARCHAR(60) '$.code', label NVARCHAR(300) '$.label', score DECIMAL(9,2) '$.score')
                WHERE NULLIF(code, N'') IS NOT NULL AND NULLIF(label, N'') IS NOT NULL AND score IS NOT NULL AND score >= 0) < 2
            THROW 57580, 'A factor needs at least two options, each with a code, a label and a score of 0 or more.', 1;
        IF EXISTS (SELECT UPPER(code) FROM OPENJSON(@options_json) WITH (code NVARCHAR(60) '$.code') GROUP BY UPPER(code) HAVING COUNT(*) > 1)
            THROW 57581, 'Option codes must be unique within the factor.', 1;

        BEGIN TRAN;
        IF @item_id IS NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM grac_practice.tprm_rm_factor WHERE version_id = @version_id AND factor_code = @code)
            BEGIN ROLLBACK; THROW 57576, 'That code is already used in this version.', 1; END
            INSERT grac_practice.tprm_rm_factor (version_id, dimension_id, factor_code, question_text, guidance, is_mandatory, prefill_source, display_order)
            VALUES (@version_id, @dimension_id, @code, @name, @description, ISNULL(@is_mandatory, 1), @prefill_source, ISNULL(@display_order, 100));
            SET @new_id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_rm_factor WHERE factor_id = @item_id AND version_id = @version_id)
            BEGIN ROLLBACK; THROW 57577, 'That item was not found on this version.', 1; END
            UPDATE grac_practice.tprm_rm_factor
               SET dimension_id = @dimension_id, question_text = @name, guidance = @description, is_mandatory = ISNULL(@is_mandatory, 1),
                   prefill_source = @prefill_source, display_order = ISNULL(@display_order, 100)
             WHERE factor_id = @item_id;
            DELETE FROM grac_practice.tprm_rm_factor_option WHERE factor_id = @item_id;
        END
        INSERT grac_practice.tprm_rm_factor_option (factor_id, option_code, option_label, score, prefill_match_code, display_order)
        SELECT @new_id, UPPER(o.code), o.label, o.score, NULLIF(o.prefillMatch, N''), (CAST(j.[key] AS INT) + 1) * 10
        FROM   OPENJSON(@options_json) j
        CROSS  APPLY OPENJSON(j.value) WITH (code NVARCHAR(60) '$.code', label NVARCHAR(300) '$.label',
                                             score DECIMAL(9,2) '$.score', prefillMatch NVARCHAR(200) '$.prefillMatch') o
        WHERE  NULLIF(o.code, N'') IS NOT NULL;
        COMMIT;
    END
    ELSE IF @item_type = N'BAND'
    BEGIN
        IF @min_score IS NULL OR @min_score < 0 OR @min_score > 100 THROW 57582, 'A band starts at a score between 0 and 100.', 1;
        IF @rank_no IS NULL THROW 57583, 'A band needs a rank (1 = lowest risk).', 1;
        IF @dd_tier_code IS NULL THROW 57584, 'Choose the due-diligence tier of the band.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_rm_band WHERE version_id = @version_id
                     AND (band_code = @code OR min_score = @min_score) AND band_id <> ISNULL(@item_id, -1))
            THROW 57585, 'Another band already uses that code or starting score.', 1;
        IF @item_id IS NULL
        BEGIN
            INSERT grac_practice.tprm_rm_band (version_id, band_code, band_name, min_score, rank_no, color_hex, dd_tier_code)
            VALUES (@version_id, @code, LEFT(@name, 120), @min_score, @rank_no, @color_hex, UPPER(@dd_tier_code));
            SET @new_id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_rm_band WHERE band_id = @item_id AND version_id = @version_id)
                THROW 57577, 'That item was not found on this version.', 1;
            UPDATE grac_practice.tprm_rm_band
               SET band_name = LEFT(@name, 120), min_score = @min_score, rank_no = @rank_no, color_hex = @color_hex,
                   dd_tier_code = UPPER(@dd_tier_code)
             WHERE band_id = @item_id;
        END
    END
    ELSE IF @item_type = N'TIER_RULE'
    BEGIN
        IF @condition_kind NOT IN (N'CRITICALITY', N'DATA_EXPOSURE', N'ACCESS') OR @code IS NULL OR @dd_tier_code IS NULL
            THROW 57586, 'A tier rule needs a condition, a value and a minimum tier.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_rm_tier_rule WHERE version_id = @version_id
                     AND condition_kind = @condition_kind AND condition_code = @code AND tier_rule_id <> ISNULL(@item_id, -1))
            THROW 57587, 'A rule for that value already exists.', 1;
        IF @item_id IS NULL
        BEGIN
            INSERT grac_practice.tprm_rm_tier_rule (version_id, condition_kind, condition_code, min_dd_tier_code)
            VALUES (@version_id, @condition_kind, @code, UPPER(@dd_tier_code));
            SET @new_id = SCOPE_IDENTITY();
        END
        ELSE
            UPDATE grac_practice.tprm_rm_tier_rule SET condition_kind = @condition_kind, condition_code = @code,
                   min_dd_tier_code = UPPER(@dd_tier_code)
             WHERE tier_rule_id = @item_id AND version_id = @version_id;
    END
    ELSE THROW 57588, 'Unknown item type.', 1;

    EXEC grac_practice.sp_tprm_audit N'tprm-template-version', @version_id, N'ITEM_SAVE', @item_type, @actor;
    SELECT @new_id AS ItemId, N'SAVED' AS Result;
END
GO

-- Add / edit one questionnaire item on a Draft.
--   @item_type SECTION | QUESTION
--   QUESTION: @options_json = [{"code","label","score","flagsDeficiency","severity"}]
--             replaces the options (YES_NO gets YES / NO / NA when none are given).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_q_item_save
    @organization_id            BIGINT         = NULL,
    @version_id                 BIGINT,
    @item_type                  NVARCHAR(20),
    @item_id                    BIGINT         = NULL,
    @code                       NVARCHAR(60)   = NULL,
    @text                       NVARCHAR(2000) = NULL,     -- section title / question text
    @description                NVARCHAR(2000) = NULL,     -- section description / question guidance
    @section_code               NVARCHAR(60)   = NULL,
    @response_type              NVARCHAR(20)   = NULL,
    @is_mandatory               BIT            = 1,
    @evidence_expected          BIT            = 0,
    @evidence_requirement_code  NVARCHAR(60)   = NULL,
    @safeguard_code             NVARCHAR(60)   = NULL,
    @dimension_code             NVARCHAR(60)   = NULL,
    @min_tier_rank              INT            = NULL,
    @applies_service_categories NVARCHAR(1000) = NULL,
    @applies_min_data_rank      INT            = NULL,
    @applies_access_codes       NVARCHAR(600)  = NULL,
    @parent_question_code       NVARCHAR(60)   = NULL,
    @trigger_option_codes       NVARCHAR(400)  = NULL,
    @weight                     DECIMAL(9,2)   = 1,
    @source_authority           NVARCHAR(200)  = NULL,
    @source_document            NVARCHAR(300)  = NULL,
    @source_version             NVARCHAR(100)  = NULL,
    @source_reference           NVARCHAR(300)  = NULL,
    @applicability_note         NVARCHAR(1000) = NULL,
    @is_regulatory              BIT            = 0,
    @options_json               NVARCHAR(MAX)  = NULL,
    @display_order              INT            = 100,
    @is_platform_admin          BIT            = 0,
    @actor                      NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @kind NVARCHAR(20);
    EXEC grac_practice.sp_tprm_template_draft_check @organization_id, @version_id, @is_platform_admin, @kind OUTPUT;
    IF @kind <> N'QUESTIONNAIRE' THROW 57589, 'That version is not a questionnaire.', 1;

    SET @code = UPPER(NULLIF(LTRIM(RTRIM(@code)), N''));
    SET @text = NULLIF(LTRIM(RTRIM(@text)), N'');
    IF @code IS NULL OR @text IS NULL THROW 57574, 'Code and text are both required.', 1;
    IF @code LIKE N'%[^A-Z0-9_]%' THROW 57504, 'Codes may contain only letters, digits and underscores.', 1;
    DECLARE @new_id BIGINT = @item_id;

    IF @item_type = N'SECTION'
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_q_section WHERE version_id = @version_id AND section_code = @code
                     AND section_id <> ISNULL(@item_id, -1))
            THROW 57576, 'That code is already used in this version.', 1;
        IF @item_id IS NULL
        BEGIN
            INSERT grac_practice.tprm_q_section (version_id, section_code, title, description, display_order)
            VALUES (@version_id, @code, LEFT(@text, 250), LEFT(@description, 1000), ISNULL(@display_order, 100));
            SET @new_id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_q_section WHERE section_id = @item_id AND version_id = @version_id)
                THROW 57577, 'That item was not found on this version.', 1;
            UPDATE grac_practice.tprm_q_section SET title = LEFT(@text, 250), description = LEFT(@description, 1000),
                   display_order = ISNULL(@display_order, 100)
             WHERE section_id = @item_id;
        END
    END
    ELSE IF @item_type = N'QUESTION'
    BEGIN
        DECLARE @section_id BIGINT = (SELECT section_id FROM grac_practice.tprm_q_section
                                       WHERE version_id = @version_id AND section_code = UPPER(@section_code));
        IF @section_id IS NULL THROW 57590, 'Choose the section of the question.', 1;
        IF @response_type NOT IN (N'YES_NO', N'SINGLE', N'MULTI', N'TEXT', N'NUMBER', N'DATE')
            THROW 57591, 'Unknown response type.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_q_question WHERE version_id = @version_id AND question_code = @code
                     AND question_id <> ISNULL(@item_id, -1))
            THROW 57576, 'That code is already used in this version.', 1;
        SET @parent_question_code = UPPER(NULLIF(LTRIM(RTRIM(@parent_question_code)), N''));
        IF @parent_question_code IS NOT NULL
        BEGIN
            IF @parent_question_code = @code THROW 57592, 'A question cannot depend on itself.', 1;
            IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_q_question q
                            WHERE q.version_id = @version_id AND q.question_code = @parent_question_code
                              AND q.response_type IN (N'YES_NO', N'SINGLE', N'MULTI'))
                THROW 57593, 'A follow-up question must depend on a Yes/No or choice question of the same version.', 1;
            IF NULLIF(LTRIM(RTRIM(@trigger_option_codes)), N'') IS NULL
                THROW 57594, 'Choose the answers of the parent question that show this follow-up.', 1;
        END
        IF ISNULL(@is_regulatory, 0) = 1 AND (NULLIF(LTRIM(RTRIM(@source_authority)), N'') IS NULL
                                           OR NULLIF(LTRIM(RTRIM(@source_document)), N'') IS NULL)
            THROW 57512, 'A regulatory requirement needs its source authority and source document.', 1;
        IF @response_type IN (N'SINGLE', N'MULTI')
           AND (@options_json IS NULL OR ISJSON(@options_json) <> 1
                OR (SELECT COUNT(*) FROM OPENJSON(@options_json) WITH (code NVARCHAR(60) '$.code', label NVARCHAR(300) '$.label')
                     WHERE NULLIF(code, N'') IS NOT NULL AND NULLIF(label, N'') IS NOT NULL) < 2)
            THROW 57595, 'A choice question needs at least two options.', 1;
        IF @options_json IS NOT NULL AND ISJSON(@options_json) = 1
           AND EXISTS (SELECT UPPER(code) FROM OPENJSON(@options_json) WITH (code NVARCHAR(60) '$.code') GROUP BY UPPER(code) HAVING COUNT(*) > 1)
            THROW 57581, 'Option codes must be unique within the question.', 1;

        BEGIN TRAN;
        IF @item_id IS NULL
        BEGIN
            INSERT grac_practice.tprm_q_question
                (version_id, section_id, question_code, question_text, guidance, response_type, is_mandatory, evidence_expected,
                 evidence_requirement_code, safeguard_code, dimension_code, min_tier_rank, applies_service_categories,
                 applies_min_data_rank, applies_access_codes, parent_question_code, trigger_option_codes, weight, display_order,
                 source_authority, source_document, source_version, source_reference, applicability_note, is_regulatory)
            VALUES (@version_id, @section_id, @code, @text, @description, @response_type, ISNULL(@is_mandatory, 1),
                    ISNULL(@evidence_expected, 0), UPPER(NULLIF(@evidence_requirement_code, N'')), UPPER(NULLIF(@safeguard_code, N'')),
                    UPPER(NULLIF(@dimension_code, N'')), @min_tier_rank, NULLIF(@applies_service_categories, N''),
                    @applies_min_data_rank, NULLIF(@applies_access_codes, N''), @parent_question_code,
                    UPPER(NULLIF(@trigger_option_codes, N'')), ISNULL(@weight, 1), ISNULL(@display_order, 100),
                    @source_authority, @source_document, @source_version, @source_reference, @applicability_note, ISNULL(@is_regulatory, 0));
            SET @new_id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_q_question WHERE question_id = @item_id AND version_id = @version_id)
            BEGIN ROLLBACK; THROW 57577, 'That item was not found on this version.', 1; END
            UPDATE grac_practice.tprm_q_question
               SET section_id = @section_id, question_text = @text, guidance = @description, response_type = @response_type,
                   is_mandatory = ISNULL(@is_mandatory, 1), evidence_expected = ISNULL(@evidence_expected, 0),
                   evidence_requirement_code = UPPER(NULLIF(@evidence_requirement_code, N'')),
                   safeguard_code = UPPER(NULLIF(@safeguard_code, N'')), dimension_code = UPPER(NULLIF(@dimension_code, N'')),
                   min_tier_rank = @min_tier_rank, applies_service_categories = NULLIF(@applies_service_categories, N''),
                   applies_min_data_rank = @applies_min_data_rank, applies_access_codes = NULLIF(@applies_access_codes, N''),
                   parent_question_code = @parent_question_code, trigger_option_codes = UPPER(NULLIF(@trigger_option_codes, N'')),
                   weight = ISNULL(@weight, 1), display_order = ISNULL(@display_order, 100),
                   source_authority = @source_authority, source_document = @source_document, source_version = @source_version,
                   source_reference = @source_reference, applicability_note = @applicability_note,
                   is_regulatory = ISNULL(@is_regulatory, 0)
             WHERE question_id = @item_id;
            DELETE FROM grac_practice.tprm_q_option WHERE question_id = @item_id;
        END

        IF @response_type IN (N'YES_NO', N'SINGLE', N'MULTI') AND @options_json IS NOT NULL AND ISJSON(@options_json) = 1
           AND EXISTS (SELECT 1 FROM OPENJSON(@options_json))
            INSERT grac_practice.tprm_q_option (question_id, option_code, option_label, score, flags_deficiency, deficiency_severity_code, display_order)
            SELECT @new_id, UPPER(o.code), o.label, o.score, ISNULL(o.flagsDeficiency, 0), UPPER(NULLIF(o.severity, N'')),
                   (CAST(j.[key] AS INT) + 1) * 10
            FROM   OPENJSON(@options_json) j
            CROSS  APPLY OPENJSON(j.value) WITH (code NVARCHAR(60) '$.code', label NVARCHAR(300) '$.label', score DECIMAL(9,2) '$.score',
                                                 flagsDeficiency BIT '$.flagsDeficiency', severity NVARCHAR(60) '$.severity') o
            WHERE  NULLIF(o.code, N'') IS NOT NULL AND NULLIF(o.label, N'') IS NOT NULL;
        ELSE IF @response_type = N'YES_NO'
            INSERT grac_practice.tprm_q_option (question_id, option_code, option_label, score, flags_deficiency, deficiency_severity_code, display_order)
            VALUES (@new_id, N'YES', N'Yes', 0, 0, NULL, 10),
                   (@new_id, N'NO', N'No', 5, 1, N'MEDIUM', 20),
                   (@new_id, N'NA', N'Not applicable', NULL, 0, NULL, 30);
        COMMIT;
    END
    ELSE THROW 57588, 'Unknown item type.', 1;

    EXEC grac_practice.sp_tprm_audit N'tprm-template-version', @version_id, N'ITEM_SAVE', @item_type, @actor;
    SELECT @new_id AS ItemId, N'SAVED' AS Result;
END
GO

-- Remove one item from a Draft (with what depends on it).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_template_item_remove
    @organization_id   BIGINT        = NULL,
    @version_id        BIGINT,
    @item_type         NVARCHAR(20),
    @item_id           BIGINT,
    @is_platform_admin BIT           = 0,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @kind NVARCHAR(20);
    EXEC grac_practice.sp_tprm_template_draft_check @organization_id, @version_id, @is_platform_admin, @kind OUTPUT;

    BEGIN TRAN;
    IF @item_type = N'DIMENSION'
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_rm_factor WHERE dimension_id = @item_id)
        BEGIN ROLLBACK; THROW 57596, 'Remove the factors of this dimension first.', 1; END
        DELETE FROM grac_practice.tprm_rm_dimension WHERE dimension_id = @item_id AND version_id = @version_id;
    END
    ELSE IF @item_type = N'FACTOR'
    BEGIN
        DELETE o FROM grac_practice.tprm_rm_factor_option o
        JOIN grac_practice.tprm_rm_factor f ON f.factor_id = o.factor_id
        WHERE f.factor_id = @item_id AND f.version_id = @version_id;
        DELETE FROM grac_practice.tprm_rm_factor WHERE factor_id = @item_id AND version_id = @version_id;
    END
    ELSE IF @item_type = N'BAND'
        DELETE FROM grac_practice.tprm_rm_band WHERE band_id = @item_id AND version_id = @version_id;
    ELSE IF @item_type = N'TIER_RULE'
        DELETE FROM grac_practice.tprm_rm_tier_rule WHERE tier_rule_id = @item_id AND version_id = @version_id;
    ELSE IF @item_type = N'SECTION'
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_q_question WHERE section_id = @item_id)
        BEGIN ROLLBACK; THROW 57596, 'Remove or move the questions of this section first.', 1; END
        DELETE FROM grac_practice.tprm_q_section WHERE section_id = @item_id AND version_id = @version_id;
    END
    ELSE IF @item_type = N'QUESTION'
    BEGIN
        DECLARE @qcode NVARCHAR(60) = (SELECT question_code FROM grac_practice.tprm_q_question
                                        WHERE question_id = @item_id AND version_id = @version_id);
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_q_question WHERE version_id = @version_id AND parent_question_code = @qcode)
        BEGIN ROLLBACK; THROW 57597, 'Other questions follow up on this one. Change them first.', 1; END
        DELETE FROM grac_practice.tprm_q_option WHERE question_id = @item_id;
        DELETE FROM grac_practice.tprm_q_question WHERE question_id = @item_id AND version_id = @version_id;
    END
    ELSE
    BEGIN ROLLBACK; THROW 57588, 'Unknown item type.', 1; END
    COMMIT;

    EXEC grac_practice.sp_tprm_audit N'tprm-template-version', @version_id, N'ITEM_REMOVE', @item_type, @actor;
    SELECT @item_id AS ItemId, N'REMOVED' AS Result;
END
GO

-- Activate a Draft (it replaces the ACTIVE version, which becomes
-- SUPERSEDED and stays readable -- assessments keep pointing at it), or
-- discard it (@discard = 1). Validation:
--   RISK_MODEL     dimensions with weight > 0, every dimension has a
--                  factor, every factor >= 2 options, a band starting at
--                  0, band tiers and tier-rule tiers are DD_TIER values.
--   QUESTIONNAIRE  >= 1 question; choice questions have options;
--                  follow-ups point at an existing parent.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_template_version_activate
    @organization_id   BIGINT        = NULL,
    @version_id        BIGINT,
    @discard           BIT           = 0,
    @change_summary    NVARCHAR(2000) = NULL,
    @is_platform_admin BIT           = 0,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @kind NVARCHAR(20);
    EXEC grac_practice.sp_tprm_template_draft_check @organization_id, @version_id, @is_platform_admin, @kind OUTPUT;
    DECLARE @template_id BIGINT = (SELECT template_id FROM grac_practice.tprm_template_version WHERE version_id = @version_id);
    -- DD tiers are checked against the owner's effective list (baseline
    -- for a GRAC template, baseline + organization values otherwise).
    DECLARE @owner_org BIGINT = (SELECT organization_id FROM grac_practice.tprm_template WHERE template_id = @template_id);

    IF ISNULL(@discard, 0) = 1
    BEGIN
        UPDATE grac_practice.tprm_template_version SET status = N'DISCARDED', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE version_id = @version_id;
        EXEC grac_practice.sp_tprm_audit N'tprm-template-version', @version_id, N'DISCARD', NULL, @actor;
        SELECT @template_id AS TemplateId, @version_id AS VersionId, N'DISCARDED' AS Result;
        RETURN;
    END

    DECLARE @msg NVARCHAR(400);
    IF @kind = N'RISK_MODEL'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_rm_dimension WHERE version_id = @version_id AND weight > 0)
            SET @msg = N'The risk model needs at least one dimension with a weight above zero.';
        ELSE IF EXISTS (SELECT 1 FROM grac_practice.tprm_rm_dimension d WHERE d.version_id = @version_id
                          AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_rm_factor f WHERE f.dimension_id = d.dimension_id))
            SELECT TOP (1) @msg = CONCAT(N'Dimension "', d.dimension_name, N'" has no factors.')
            FROM grac_practice.tprm_rm_dimension d WHERE d.version_id = @version_id
              AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_rm_factor f WHERE f.dimension_id = d.dimension_id);
        ELSE IF EXISTS (SELECT 1 FROM grac_practice.tprm_rm_factor f WHERE f.version_id = @version_id
                          AND (SELECT COUNT(*) FROM grac_practice.tprm_rm_factor_option o WHERE o.factor_id = f.factor_id) < 2)
            SELECT TOP (1) @msg = CONCAT(N'Factor ', f.factor_code, N' needs at least two options.')
            FROM grac_practice.tprm_rm_factor f WHERE f.version_id = @version_id
              AND (SELECT COUNT(*) FROM grac_practice.tprm_rm_factor_option o WHERE o.factor_id = f.factor_id) < 2;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_rm_band WHERE version_id = @version_id AND min_score = 0)
            SET @msg = N'The first risk band must start at score 0.';
        ELSE IF EXISTS (SELECT 1 FROM grac_practice.tprm_rm_band b WHERE b.version_id = @version_id
                          AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_reference_value v
                                           WHERE v.list_code = N'DD_TIER' AND v.value_code = b.dd_tier_code AND v.status = N'Active'
                                             AND (v.organization_id IS NULL OR v.organization_id = @owner_org)))
            SET @msg = N'Every band needs a due-diligence tier from the DD tier list.';
        ELSE IF EXISTS (SELECT 1 FROM grac_practice.tprm_rm_tier_rule r WHERE r.version_id = @version_id
                          AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_reference_value v
                                           WHERE v.list_code = N'DD_TIER' AND v.value_code = r.min_dd_tier_code AND v.status = N'Active'
                                             AND (v.organization_id IS NULL OR v.organization_id = @owner_org)))
            SET @msg = N'Every tier rule needs a due-diligence tier from the DD tier list.';
        ELSE IF EXISTS (SELECT 1 FROM grac_practice.tprm_template_version WHERE version_id = @version_id AND aggregation_method IS NULL)
            SET @msg = N'Choose how dimension scores combine into the overall score.';
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_q_question WHERE version_id = @version_id)
            SET @msg = N'The questionnaire has no questions.';
        ELSE IF EXISTS (SELECT 1 FROM grac_practice.tprm_q_question q WHERE q.version_id = @version_id
                          AND q.response_type IN (N'YES_NO', N'SINGLE', N'MULTI')
                          AND (SELECT COUNT(*) FROM grac_practice.tprm_q_option o WHERE o.question_id = q.question_id) < 2)
            SELECT TOP (1) @msg = CONCAT(N'Question ', q.question_code, N' needs at least two options.')
            FROM grac_practice.tprm_q_question q WHERE q.version_id = @version_id
              AND q.response_type IN (N'YES_NO', N'SINGLE', N'MULTI')
              AND (SELECT COUNT(*) FROM grac_practice.tprm_q_option o WHERE o.question_id = q.question_id) < 2;
        ELSE IF EXISTS (SELECT 1 FROM grac_practice.tprm_q_question q WHERE q.version_id = @version_id
                          AND q.parent_question_code IS NOT NULL
                          AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_q_question p
                                           WHERE p.version_id = @version_id AND p.question_code = q.parent_question_code))
            SET @msg = N'A follow-up question points at a question that is not in this version.';
    END
    IF @msg IS NOT NULL THROW 57598, @msg, 1;

    BEGIN TRAN;
        UPDATE grac_practice.tprm_template_version SET status = N'SUPERSEDED', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE template_id = @template_id AND status = N'ACTIVE';
        UPDATE grac_practice.tprm_template_version
           SET status = N'ACTIVE', activated_by = @actor, activated_dt = SYSUTCDATETIME(),
               change_summary = COALESCE(NULLIF(LTRIM(RTRIM(@change_summary)), N''), change_summary),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE version_id = @version_id;
        UPDATE grac_practice.tprm_template SET current_version_id = @version_id, status = N'Active',
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE template_id = @template_id;
    COMMIT;

    EXEC grac_practice.sp_tprm_audit N'tprm-template-version', @version_id, N'ACTIVATE', NULL, @actor;
    SELECT @template_id AS TemplateId, @version_id AS VersionId, N'ACTIVATED' AS Result;
END
GO

-- Retire / restore a template for the scope. Retiring the organization's
-- copy of a GRAC template (or a GRAC template it never adopted, which
-- creates a retired copy) stops it being generated for this organization.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_template_retire
    @organization_id   BIGINT        = NULL,
    @template_id       BIGINT,
    @restore           BIT           = 0,
    @is_platform_admin BIT           = 0,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, @is_platform_admin;

    DECLARE @owner BIGINT, @kind NVARCHAR(20), @code NVARCHAR(60), @name NVARCHAR(250), @found BIT = 0;
    SELECT @owner = organization_id, @kind = template_kind, @code = template_code, @name = template_name, @found = 1
    FROM grac_practice.tprm_template WHERE template_id = @template_id;
    IF @found = 0 THROW 57568, 'That template was not found in this scope.', 1;

    DECLARE @target BIGINT = @template_id;
    IF @owner IS NULL AND @organization_id IS NOT NULL
    BEGIN
        -- a GRAC template seen from an organization: act on its copy
        SET @target = (SELECT template_id FROM grac_practice.tprm_template
                        WHERE organization_id = @organization_id AND baseline_template_id = @template_id);
        IF @target IS NULL
        BEGIN
            IF ISNULL(@restore, 0) = 1 BEGIN SELECT @template_id AS TemplateId, N'UNCHANGED' AS Result; RETURN; END
            INSERT grac_practice.tprm_template (organization_id, template_kind, template_code, template_name, baseline_template_id, status, entered_by)
            VALUES (@organization_id, @kind,
                    CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_template WHERE organization_id = @organization_id
                                        AND template_kind = @kind AND template_code = @code)
                         THEN LEFT(@code, 52) + N'_ORG' ELSE @code END,
                    @name, @template_id, N'Retired', @actor);
            SET @target = SCOPE_IDENTITY();
        END
    END
    ELSE IF NOT ((@organization_id IS NULL AND @owner IS NULL) OR @owner = @organization_id)
        THROW 57568, 'That template was not found in this scope.', 1;

    IF ISNULL(@restore, 0) = 0 AND @kind = N'RISK_MODEL' AND @organization_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_template_effective(@organization_id) e
                        WHERE e.template_kind = N'RISK_MODEL' AND e.template_id NOT IN (@template_id, @target))
        THROW 57599, 'This is the only risk model in force. Activate another risk model first.', 1;

    UPDATE grac_practice.tprm_template
       SET status = CASE WHEN ISNULL(@restore, 0) = 1 THEN N'Active' ELSE N'Retired' END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE template_id = @target;
    EXEC grac_practice.sp_tprm_audit N'tprm-template', @target, N'RETIRE', NULL, @actor;
    SELECT @target AS TemplateId, CASE WHEN ISNULL(@restore, 0) = 1 THEN N'RESTORED' ELSE N'RETIRED' END AS Result;
END
GO

-- Differences between two versions of the same kind (BRD 6.3 change
-- comparison) -- matched by codes, so a GRAC version and an organization
-- copy compare item by item.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_template_compare
    @organization_id BIGINT = NULL,
    @version_a       BIGINT,
    @version_b       BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ka NVARCHAR(20), @kb NVARCHAR(20), @oa BIGINT, @ob BIGINT, @fa BIT = 0, @fb BIT = 0;
    SELECT @ka = t.template_kind, @oa = t.organization_id, @fa = 1 FROM grac_practice.tprm_template_version v
      JOIN grac_practice.tprm_template t ON t.template_id = v.template_id WHERE v.version_id = @version_a;
    SELECT @kb = t.template_kind, @ob = t.organization_id, @fb = 1 FROM grac_practice.tprm_template_version v
      JOIN grac_practice.tprm_template t ON t.template_id = v.template_id WHERE v.version_id = @version_b;
    IF @fa = 0 OR @fb = 0 OR (@oa IS NOT NULL AND @oa <> ISNULL(@organization_id, -1))
                          OR (@ob IS NOT NULL AND @ob <> ISNULL(@organization_id, -1))
        THROW 57560, 'That template version was not found.', 1;
    IF @ka <> @kb THROW 57573, 'Only versions of the same kind can be compared.', 1;

    DECLARE @d TABLE (item_type NVARCHAR(20), item_code NVARCHAR(130), item_name NVARCHAR(2000), sig NVARCHAR(MAX));
    DECLARE @e TABLE (item_type NVARCHAR(20), item_code NVARCHAR(130), item_name NVARCHAR(2000), sig NVARCHAR(MAX));

    IF @ka = N'RISK_MODEL'
    BEGIN
        INSERT @d SELECT N'SETTINGS', N'SCORING', N'Scoring rules',
               CONCAT(aggregation_method, N' | blend ', blend_pct, N' | effective -', effective_reduction_pct, N'% | partial -',
                      partial_reduction_pct, N'% | floor ', residual_floor_pct, N'% | deficiency +', deficiency_uplift_pct, N'%')
               FROM grac_practice.tprm_template_version WHERE version_id = @version_a;
        INSERT @e SELECT N'SETTINGS', N'SCORING', N'Scoring rules',
               CONCAT(aggregation_method, N' | blend ', blend_pct, N' | effective -', effective_reduction_pct, N'% | partial -',
                      partial_reduction_pct, N'% | floor ', residual_floor_pct, N'% | deficiency +', deficiency_uplift_pct, N'%')
               FROM grac_practice.tprm_template_version WHERE version_id = @version_b;
        INSERT @d SELECT N'DIMENSION', dimension_code, dimension_name, CONCAT(dimension_name, N' | weight ', weight)
               FROM grac_practice.tprm_rm_dimension WHERE version_id = @version_a;
        INSERT @e SELECT N'DIMENSION', dimension_code, dimension_name, CONCAT(dimension_name, N' | weight ', weight)
               FROM grac_practice.tprm_rm_dimension WHERE version_id = @version_b;
        INSERT @d SELECT N'FACTOR', f.factor_code, f.question_text,
               CONCAT(d.dimension_code, N' | ', f.question_text, N' | ', f.is_mandatory, N' | ',
                      (SELECT STRING_AGG(CONCAT(o.option_code, N'=', o.score), N', ') WITHIN GROUP (ORDER BY o.display_order)
                         FROM grac_practice.tprm_rm_factor_option o WHERE o.factor_id = f.factor_id))
               FROM grac_practice.tprm_rm_factor f JOIN grac_practice.tprm_rm_dimension d ON d.dimension_id = f.dimension_id
               WHERE f.version_id = @version_a;
        INSERT @e SELECT N'FACTOR', f.factor_code, f.question_text,
               CONCAT(d.dimension_code, N' | ', f.question_text, N' | ', f.is_mandatory, N' | ',
                      (SELECT STRING_AGG(CONCAT(o.option_code, N'=', o.score), N', ') WITHIN GROUP (ORDER BY o.display_order)
                         FROM grac_practice.tprm_rm_factor_option o WHERE o.factor_id = f.factor_id))
               FROM grac_practice.tprm_rm_factor f JOIN grac_practice.tprm_rm_dimension d ON d.dimension_id = f.dimension_id
               WHERE f.version_id = @version_b;
        INSERT @d SELECT N'BAND', band_code, band_name, CONCAT(band_name, N' | from ', min_score, N' | rank ', rank_no, N' | tier ', dd_tier_code)
               FROM grac_practice.tprm_rm_band WHERE version_id = @version_a;
        INSERT @e SELECT N'BAND', band_code, band_name, CONCAT(band_name, N' | from ', min_score, N' | rank ', rank_no, N' | tier ', dd_tier_code)
               FROM grac_practice.tprm_rm_band WHERE version_id = @version_b;
        INSERT @d SELECT N'TIER_RULE', CONCAT(condition_kind, N':', condition_code), CONCAT(condition_kind, N' ', condition_code), min_dd_tier_code
               FROM grac_practice.tprm_rm_tier_rule WHERE version_id = @version_a;
        INSERT @e SELECT N'TIER_RULE', CONCAT(condition_kind, N':', condition_code), CONCAT(condition_kind, N' ', condition_code), min_dd_tier_code
               FROM grac_practice.tprm_rm_tier_rule WHERE version_id = @version_b;
    END
    ELSE
    BEGIN
        INSERT @d SELECT N'SETTINGS', N'APPLICABILITY', N'Applicability',
               CONCAT(N'core ', is_core, N' | categories ', applies_service_categories, N' | min tier ', applies_min_tier_rank,
                      N' | types ', applies_engagement_types)
               FROM grac_practice.tprm_template_version WHERE version_id = @version_a;
        INSERT @e SELECT N'SETTINGS', N'APPLICABILITY', N'Applicability',
               CONCAT(N'core ', is_core, N' | categories ', applies_service_categories, N' | min tier ', applies_min_tier_rank,
                      N' | types ', applies_engagement_types)
               FROM grac_practice.tprm_template_version WHERE version_id = @version_b;
        INSERT @d SELECT N'SECTION', section_code, title, title FROM grac_practice.tprm_q_section WHERE version_id = @version_a;
        INSERT @e SELECT N'SECTION', section_code, title, title FROM grac_practice.tprm_q_section WHERE version_id = @version_b;
        INSERT @d SELECT N'QUESTION', q.question_code, q.question_text,
               CONCAT(s.section_code, N' | ', q.question_text, N' | ', q.response_type, N' | mandatory ', q.is_mandatory,
                      N' | evidence ', q.evidence_requirement_code, N' | safeguard ', q.safeguard_code, N' | tier ', q.min_tier_rank,
                      N' | categories ', q.applies_service_categories, N' | follows ', q.parent_question_code, N'=', q.trigger_option_codes,
                      N' | ', (SELECT STRING_AGG(CONCAT(o.option_code, N'=', o.score, CASE WHEN o.flags_deficiency = 1 THEN N'!' ELSE N'' END), N', ')
                                 WITHIN GROUP (ORDER BY o.display_order)
                               FROM grac_practice.tprm_q_option o WHERE o.question_id = q.question_id))
               FROM grac_practice.tprm_q_question q JOIN grac_practice.tprm_q_section s ON s.section_id = q.section_id
               WHERE q.version_id = @version_a;
        INSERT @e SELECT N'QUESTION', q.question_code, q.question_text,
               CONCAT(s.section_code, N' | ', q.question_text, N' | ', q.response_type, N' | mandatory ', q.is_mandatory,
                      N' | evidence ', q.evidence_requirement_code, N' | safeguard ', q.safeguard_code, N' | tier ', q.min_tier_rank,
                      N' | categories ', q.applies_service_categories, N' | follows ', q.parent_question_code, N'=', q.trigger_option_codes,
                      N' | ', (SELECT STRING_AGG(CONCAT(o.option_code, N'=', o.score, CASE WHEN o.flags_deficiency = 1 THEN N'!' ELSE N'' END), N', ')
                                 WITHIN GROUP (ORDER BY o.display_order)
                               FROM grac_practice.tprm_q_option o WHERE o.question_id = q.question_id))
               FROM grac_practice.tprm_q_question q JOIN grac_practice.tprm_q_section s ON s.section_id = q.section_id
               WHERE q.version_id = @version_b;
    END

    SELECT COALESCE(a.item_type, b.item_type) AS ItemType,
           COALESCE(a.item_code, b.item_code) AS ItemCode,
           COALESCE(b.item_name, a.item_name) AS ItemName,
           CASE WHEN a.item_code IS NULL THEN N'ADDED'
                WHEN b.item_code IS NULL THEN N'REMOVED'
                ELSE N'CHANGED' END AS ChangeKind,
           a.sig AS ValueA, b.sig AS ValueB
    FROM   @d a
    FULL   OUTER JOIN @e b ON b.item_type = a.item_type AND b.item_code = a.item_code
    WHERE  a.item_code IS NULL OR b.item_code IS NULL OR ISNULL(a.sig, N'') <> ISNULL(b.sig, N'')
    ORDER  BY CASE COALESCE(a.item_type, b.item_type)
                WHEN N'SETTINGS' THEN 0 WHEN N'DIMENSION' THEN 1 WHEN N'SECTION' THEN 1 WHEN N'FACTOR' THEN 2
                WHEN N'QUESTION' THEN 2 WHEN N'BAND' THEN 3 ELSE 4 END,
              COALESCE(a.item_code, b.item_code);
END
GO

-- =====================================================================
-- 13. Verification
-- =====================================================================
SELECT '486 tables' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.tprm_reference_value','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_library_item','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_approval_rule','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_review_rule','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_custom_field_value','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_template_version','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_rm_tier_rule','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_q_option','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '486 effective-configuration functions',
       CASE WHEN OBJECT_ID('grac_practice.fn_tprm_reference_effective') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_tprm_library_effective') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_tprm_approval_rule_effective') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_tprm_review_rule_effective') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_tprm_template_effective') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_tprm_risk_model_version') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '486 procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_tprm_template_adopt','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_template_version_activate','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_template_compare','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_custom_values_save','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_q_item_save','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_rm_item_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '486 complete. Run 487_tprm_baseline_seed.sql next.';
GO
