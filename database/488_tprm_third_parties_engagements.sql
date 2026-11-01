-- =====================================================================
-- 488_tprm_third_parties_engagements.sql
--
-- REQUEST (2026-10-24)
-- --------------------
--   TPRM BRD section 3, steps 1 and 2 (Layer 3 -- operational records):
--     Step 1  Third-party registration: one unique record per legal
--             entity, duplicate detection, discovery of existing vendors
--             from GRAC Vendor dependencies, configurable lifecycle
--             statuses, organization-defined fields, many engagements.
--     Step 2  Engagement scope and risk: the service relationship, its
--             scope (business functions, processes, applications, data,
--             access, locations, fourth parties), service levels incl.
--             RTO / RPO, automatic discovery of the Practice Instances,
--             Practices, Obligations, Dependencies, assurance findings,
--             gaps, risks and contracts already in GRAC, intended exposure
--             for proposed engagements, and the configurable inherent
--             risk assessment that sets the due-diligence tier.
--
-- DESIGN DECISIONS (docs/tprm.md section 4)
-- -----------------------------------------
--   * A third party is the legal entity; the GRAC vendor
--     (organization_dependency_vendor) stays the operational dependency
--     record and is LINKED (tprm_third_party.vendor_id, one per third
--     party), never copied. A third party may exist with no vendor
--     (prospective) -- BRD acceptance 5.
--   * An engagement is the service relationship and owns its own scope,
--     risk, due diligence and decision (BRD 2.2, acceptance 2).
--   * GRAC objects found for an engagement are recorded as LINKS
--     (tprm_engagement_link) -- practice instances, dependency
--     resolutions, applications, contracts, enterprise risks -- never as
--     TPRM copies (BRD 7, 8). Discovery is read-only until "Record"
--     (@persist = 1); recorded links are DISCOVERED until validated.
--   * The inherent assessment pins the risk model VERSION in force when
--     it starts; every later read uses that version (BRD 11).
--
-- WHAT THIS FILE CREATES
-- ----------------------
--   Tables  tprm_third_party, tprm_third_party_category,
--           tprm_third_party_contact, tprm_third_party_status_history,
--           tprm_engagement, tprm_engagement_scope, tprm_engagement_link,
--           tprm_exposure_snapshot, tprm_engagement_history,
--           tprm_risk_assessment, tprm_risk_assessment_answer,
--           tprm_risk_assessment_dimension
--   Functions fn_tprm_normalize_name, fn_tprm_third_party_matches,
--           fn_tprm_meaning_code, fn_tprm_engagement_signals
--   Procedures
--     sp_tprm_lookups
--     sp_tprm_third_party_list / _get / _save / _status / _sync_status
--     sp_tprm_vendor_discovery / sp_tprm_vendor_import
--     sp_tprm_sample_load
--     sp_tprm_engagement_list / _get / _save, sp_tprm_engagement_event
--     sp_tprm_scope_item_save / sp_tprm_scope_item_remove
--     sp_tprm_engagement_discover
--     sp_tprm_link_save / sp_tprm_link_action
--     sp_tprm_risk_assessment_start / _get / sp_tprm_risk_answers_save /
--     sp_tprm_risk_score / sp_tprm_risk_assessment_complete
--
-- ERROR NUMBERS: 57600-57699.
-- DEPENDS ON: 486, 487; 002 (vendors, applications, processes,
--   resolutions), 054 / 245 (gaps), 098 / 101 (assurance), 140 / 307
--   (obligations), 205 / 378 (risk register), 434 (asset_contract --
--   optional, read only when present).
-- Rollback: 488_tprm_third_parties_engagements_rollback.sql
-- SAFE TO RE-RUN. ASCII-only. SQL Server 2017+.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.tprm_sample_profile','U') IS NULL
BEGIN PRINT 'ABORT (488): run 486 and 487 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.organization_dependency_vendor','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
   OR OBJECT_ID('grac_practice.dependency_type_master','U') IS NULL
BEGIN PRINT 'ABORT (488): GRAC dependency tables missing (002).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
BEGIN PRINT 'ABORT (488): practice_instance_obligation missing (140).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_obligation','U') IS NULL
BEGIN PRINT 'ABORT (488): practice_obligation missing (307).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_gap','U') IS NULL
BEGIN PRINT 'ABORT (488): practice_gap missing (245).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.org_assurance_observation','U') IS NULL
BEGIN PRINT 'ABORT (488): org_assurance_observation missing (101).'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.risk_register','risk_number') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','linked_vendor_id') IS NULL
BEGIN PRINT 'ABORT (488): risk_register.risk_number / linked_vendor_id missing (205, 378).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('488_tprm_third_parties_engagements: prerequisites missing -- see the messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Third parties
-- =====================================================================
IF OBJECT_ID('grac_practice.tprm_third_party','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_third_party(
        third_party_id               BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_third_party PRIMARY KEY,
        organization_id              BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_tp_org REFERENCES grac_practice.organization(organization_id),
        third_party_code             NVARCHAR(20)   NOT NULL,     -- TP-001 per organization
        legal_name                   NVARCHAR(250)  NOT NULL,
        trading_name                 NVARCHAR(250)  NULL,
        normalized_name              NVARCHAR(250)  NOT NULL,     -- duplicate detection
        registration_number          NVARCHAR(100)  NULL,
        tax_id                       NVARCHAR(100)  NULL,
        lei_code                     NVARCHAR(40)   NULL,
        provider_type_code           NVARCHAR(60)   NULL,
        primary_service_category_code NVARCHAR(60)  NULL,
        reporting_category_code      NVARCHAR(60)   NULL,
        country                      NVARCHAR(120)  NULL,
        state_region                 NVARCHAR(120)  NULL,
        city                         NVARCHAR(120)  NULL,
        address                      NVARCHAR(1000) NULL,
        website                      NVARCHAR(300)  NULL,
        parent_company               NVARCHAR(250)  NULL,
        year_established             INT            NULL,
        employee_count_band          NVARCHAR(60)   NULL,
        annual_revenue_band          NVARCHAR(60)   NULL,
        certifications_text          NVARCHAR(1000) NULL,
        profile_notes                NVARCHAR(MAX)  NULL,
        lifecycle_status_code        NVARCHAR(60)   NOT NULL,     -- TP_STATUS value
        relationship_owner_employee_id BIGINT       NULL
            CONSTRAINT fk_pm_tprm_tp_owner REFERENCES grac_practice.organization_employee(employee_id),
        vendor_id                    BIGINT         NULL          -- the GRAC vendor dependency, linked not copied
            CONSTRAINT fk_pm_tprm_tp_vendor REFERENCES grac_practice.organization_dependency_vendor(vendor_id),
        is_sample                    BIT            NOT NULL CONSTRAINT df_pm_tprm_tp_sample DEFAULT 0,
        status                       NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_tp_status DEFAULT N'Active'
            CONSTRAINT ck_pm_tprm_tp_status CHECK (status IN (N'Active', N'Archived')),
        record_version               ROWVERSION     NOT NULL,
        entered_by                   NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_tp_eby DEFAULT N'system',
        entered_dt                   DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_tp_edt DEFAULT SYSUTCDATETIME(),
        updated_by                   NVARCHAR(100)  NULL,
        updated_dt                   DATETIME2      NULL,
        CONSTRAINT uq_pm_tprm_tp_code UNIQUE (organization_id, third_party_code)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_tp_vendor ON grac_practice.tprm_third_party(vendor_id) WHERE vendor_id IS NOT NULL;
    CREATE INDEX ix_pm_tprm_tp_name ON grac_practice.tprm_third_party(organization_id, normalized_name);
    PRINT '488: tprm_third_party created.';
END
GO

IF OBJECT_ID('grac_practice.tprm_third_party_category','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_third_party_category(
        third_party_id        BIGINT       NOT NULL
            CONSTRAINT fk_pm_tprm_tpc_tp REFERENCES grac_practice.tprm_third_party(third_party_id),
        service_category_code NVARCHAR(60) NOT NULL,
        CONSTRAINT pk_pm_tprm_third_party_category PRIMARY KEY (third_party_id, service_category_code)
    );
END
GO

IF OBJECT_ID('grac_practice.tprm_third_party_contact','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_third_party_contact(
        contact_id      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_third_party_contact PRIMARY KEY,
        third_party_id  BIGINT        NOT NULL
            CONSTRAINT fk_pm_tprm_tpct_tp REFERENCES grac_practice.tprm_third_party(third_party_id),
        organization_id BIGINT        NOT NULL,
        contact_name    NVARCHAR(200) NOT NULL,
        contact_role    NVARCHAR(150) NULL,
        email           NVARCHAR(250) NULL,
        phone           NVARCHAR(60)  NULL,
        is_primary      BIT           NOT NULL CONSTRAINT df_pm_tprm_tpct_primary DEFAULT 0,
        status          NVARCHAR(20)  NOT NULL CONSTRAINT df_pm_tprm_tpct_status DEFAULT N'Active'
            CONSTRAINT ck_pm_tprm_tpct_status CHECK (status IN (N'Active', N'Removed')),
        entered_by      NVARCHAR(100) NOT NULL CONSTRAINT df_pm_tprm_tpct_eby DEFAULT N'system',
        entered_dt      DATETIME2     NOT NULL CONSTRAINT df_pm_tprm_tpct_edt DEFAULT SYSUTCDATETIME(),
        updated_by      NVARCHAR(100) NULL,
        updated_dt      DATETIME2     NULL
    );
END
GO

IF OBJECT_ID('grac_practice.tprm_third_party_status_history','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_third_party_status_history(
        history_id          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_tp_status_history PRIMARY KEY,
        third_party_id      BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_tpsh_tp REFERENCES grac_practice.tprm_third_party(third_party_id),
        from_status_code    NVARCHAR(60)   NULL,
        to_status_code      NVARCHAR(60)   NOT NULL,
        reason              NVARCHAR(1000) NULL,
        is_automatic        BIT            NOT NULL CONSTRAINT df_pm_tprm_tpsh_auto DEFAULT 0,
        actor_employee_id   BIGINT         NULL,
        actor               NVARCHAR(100)  NOT NULL,
        changed_dt          DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_tpsh_dt DEFAULT SYSUTCDATETIME()
    );
END
GO

-- =====================================================================
-- 2. Engagements
-- =====================================================================
IF OBJECT_ID('grac_practice.tprm_engagement','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_engagement(
        engagement_id                 BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_engagement PRIMARY KEY,
        organization_id               BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_eng_org REFERENCES grac_practice.organization(organization_id),
        third_party_id                BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_eng_tp REFERENCES grac_practice.tprm_third_party(third_party_id),
        engagement_code               NVARCHAR(20)   NOT NULL,     -- ENG-001 per organization
        engagement_title              NVARCHAR(250)  NOT NULL,
        service_description           NVARCHAR(2000) NULL,
        scope_description             NVARCHAR(2000) NULL,
        business_purpose              NVARCHAR(1000) NULL,
        service_category_code         NVARCHAR(60)   NULL,
        engagement_type_code          NVARCHAR(60)   NULL,
        service_model_code            NVARCHAR(60)   NULL,
        delivery_locations            NVARCHAR(1000) NULL,
        is_existing                   BIT            NOT NULL CONSTRAINT df_pm_tprm_eng_existing DEFAULT 0,
        contract_id                   BIGINT         NULL,          -- asset_contract (434) when used
        contract_reference            NVARCHAR(200)  NULL,
        contract_value                DECIMAL(19,2)  NULL,
        currency_code                 NVARCHAR(10)   NULL,
        proposed_start_dt             DATE           NULL,
        proposed_end_dt               DATE           NULL,
        actual_start_dt               DATE           NULL,
        actual_end_dt                 DATE           NULL,
        renewal_dt                    DATE           NULL,
        business_owner_employee_id    BIGINT         NULL
            CONSTRAINT fk_pm_tprm_eng_bowner REFERENCES grac_practice.organization_employee(employee_id),
        relationship_owner_employee_id BIGINT        NULL
            CONSTRAINT fk_pm_tprm_eng_rowner REFERENCES grac_practice.organization_employee(employee_id),
        assessor_employee_id          BIGINT         NULL
            CONSTRAINT fk_pm_tprm_eng_assessor REFERENCES grac_practice.organization_employee(employee_id),
        service_criticality_code      NVARCHAR(60)   NULL,
        data_exposure_code            NVARCHAR(60)   NULL,
        rto_hours                     INT            NULL,
        rpo_hours                     INT            NULL,
        sla_summary                   NVARCHAR(2000) NULL,
        stage_code                    NVARCHAR(30)   NOT NULL CONSTRAINT df_pm_tprm_eng_stage DEFAULT N'SCOPING'
            CONSTRAINT ck_pm_tprm_eng_stage CHECK (stage_code IN (N'SCOPING', N'RISK_ASSESSED', N'DUE_DILIGENCE', N'PENDING_DECISION',
                                                                  N'APPROVED', N'ONBOARDING', N'ACTIVE', N'SUSPENDED', N'EXITING',
                                                                  N'EXITED', N'REJECTED', N'CANCELLED')),
        stage_dt                      DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_eng_stage_dt DEFAULT SYSUTCDATETIME(),
        current_risk_assessment_id    BIGINT         NULL,
        risk_model_version_id         BIGINT         NULL
            CONSTRAINT fk_pm_tprm_eng_rmv REFERENCES grac_practice.tprm_template_version(version_id),
        inherent_score                DECIMAL(6,2)   NULL,
        inherent_band_code            NVARCHAR(60)   NULL,
        dd_tier_code                  NVARCHAR(60)   NULL,
        residual_score                DECIMAL(6,2)   NULL,
        residual_band_code            NVARCHAR(60)   NULL,
        acceptance_until              DATE           NULL,
        next_review_dt                DATE           NULL,
        last_review_dt                DATE           NULL,
        reassessment_required         BIT            NOT NULL CONSTRAINT df_pm_tprm_eng_reassess DEFAULT 0,
        reassessment_reason           NVARCHAR(1000) NULL,
        notes                         NVARCHAR(MAX)  NULL,
        is_sample                     BIT            NOT NULL CONSTRAINT df_pm_tprm_eng_sample DEFAULT 0,
        record_version                ROWVERSION     NOT NULL,
        entered_by                    NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_eng_eby DEFAULT N'system',
        entered_dt                    DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_eng_edt DEFAULT SYSUTCDATETIME(),
        updated_by                    NVARCHAR(100)  NULL,
        updated_dt                    DATETIME2      NULL,
        CONSTRAINT uq_pm_tprm_eng_code UNIQUE (organization_id, engagement_code)
    );
    CREATE INDEX ix_pm_tprm_eng_tp ON grac_practice.tprm_engagement(third_party_id);
    CREATE INDEX ix_pm_tprm_eng_stage ON grac_practice.tprm_engagement(organization_id, stage_code);
    PRINT '488: tprm_engagement created.';
END
GO

IF OBJECT_ID('grac_practice.tprm_engagement_scope','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_engagement_scope(
        scope_item_id   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_engagement_scope PRIMARY KEY,
        engagement_id   BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_es_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        organization_id BIGINT         NOT NULL,
        item_kind       NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_tprm_es_kind CHECK (item_kind IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION', N'DATA_CATEGORY',
                                                                N'ACCESS', N'LOCATION', N'FOURTH_PARTY')),
        -- PROPOSED = intended exposure (BRD step 2); ACTUAL = recorded at
        -- onboarding (BRD step 5) and compared with PROPOSED.
        exposure_mode   NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_es_mode DEFAULT N'PROPOSED'
            CONSTRAINT ck_pm_tprm_es_mode CHECK (exposure_mode IN (N'PROPOSED', N'ACTUAL')),
        ref_id          BIGINT         NULL,      -- GRAC object (business function / process / application / third party)
        item_code       NVARCHAR(60)   NULL,      -- DATA_EXPOSURE / ACCESS_CATEGORY / FOURTH_PARTY_CATEGORY value
        item_name       NVARCHAR(300)  NOT NULL,
        criticality_code NVARCHAR(60)  NULL,
        country         NVARCHAR(120)  NULL,
        is_critical     BIT            NOT NULL CONSTRAINT df_pm_tprm_es_critical DEFAULT 0,
        notes           NVARCHAR(1000) NULL,
        status          NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_es_status DEFAULT N'Active'
            CONSTRAINT ck_pm_tprm_es_status CHECK (status IN (N'Active', N'Removed')),
        entered_by      NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_es_eby DEFAULT N'system',
        entered_dt      DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_es_edt DEFAULT SYSUTCDATETIME(),
        updated_by      NVARCHAR(100)  NULL,
        updated_dt      DATETIME2      NULL
    );
    CREATE INDEX ix_pm_tprm_es_eng ON grac_practice.tprm_engagement_scope(engagement_id, exposure_mode, status);
END
GO

IF OBJECT_ID('grac_practice.tprm_engagement_link','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_engagement_link(
        link_id         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_engagement_link PRIMARY KEY,
        engagement_id   BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_el_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        organization_id BIGINT         NOT NULL,
        link_kind       NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_tprm_el_kind CHECK (link_kind IN (N'VENDOR', N'PRACTICE_INSTANCE', N'DEPENDENCY', N'APPLICATION',
                                                                N'CONTRACT', N'ENTERPRISE_RISK', N'RISK_CANDIDATE', N'GAP')),
        target_id       BIGINT         NOT NULL,
        target_label    NVARCHAR(400)  NULL,      -- label at the time it was linked (the target may change)
        link_source     NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_tprm_el_source CHECK (link_source IN (N'DISCOVERED', N'MANUAL', N'ONBOARDING', N'ESCALATION')),
        is_validated    BIT            NOT NULL CONSTRAINT df_pm_tprm_el_valid DEFAULT 0,
        validated_by    NVARCHAR(100)  NULL,
        validated_dt    DATETIME2      NULL,
        note            NVARCHAR(1000) NULL,
        status          NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_el_status DEFAULT N'Active'
            CONSTRAINT ck_pm_tprm_el_status CHECK (status IN (N'Active', N'Removed')),
        entered_by      NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_el_eby DEFAULT N'system',
        entered_dt      DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_el_edt DEFAULT SYSUTCDATETIME(),
        updated_by      NVARCHAR(100)  NULL,
        updated_dt      DATETIME2      NULL
    );
    CREATE UNIQUE INDEX ux_pm_tprm_el_active ON grac_practice.tprm_engagement_link(engagement_id, link_kind, target_id)
        WHERE status = N'Active';
    CREATE INDEX ix_pm_tprm_el_target ON grac_practice.tprm_engagement_link(organization_id, link_kind, target_id);
END
GO

IF OBJECT_ID('grac_practice.tprm_exposure_snapshot','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_exposure_snapshot(
        snapshot_id     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_exposure_snapshot PRIMARY KEY,
        engagement_id   BIGINT        NOT NULL
            CONSTRAINT fk_pm_tprm_snap_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        organization_id BIGINT        NOT NULL,
        snapshot_kind   NVARCHAR(20)  NOT NULL
            CONSTRAINT ck_pm_tprm_snap_kind CHECK (snapshot_kind IN (N'PROPOSED', N'DISCOVERED', N'ACTUAL')),
        summary_json    NVARCHAR(MAX) NULL,
        items_json      NVARCHAR(MAX) NULL,
        taken_by        NVARCHAR(100) NOT NULL,
        taken_dt        DATETIME2     NOT NULL CONSTRAINT df_pm_tprm_snap_dt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_tprm_snap_eng ON grac_practice.tprm_exposure_snapshot(engagement_id, snapshot_kind, snapshot_id);
END
GO

IF OBJECT_ID('grac_practice.tprm_engagement_history','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_engagement_history(
        history_id        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_engagement_history PRIMARY KEY,
        engagement_id     BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_eh_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        event_code        NVARCHAR(40)   NOT NULL,
        from_stage_code   NVARCHAR(30)   NULL,
        to_stage_code     NVARCHAR(30)   NULL,
        detail            NVARCHAR(2000) NULL,
        actor_employee_id BIGINT         NULL,
        actor             NVARCHAR(100)  NOT NULL,
        event_dt          DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_eh_dt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_tprm_eh_eng ON grac_practice.tprm_engagement_history(engagement_id, history_id);
END
GO

-- =====================================================================
-- 3. Inherent risk assessment (versions)
-- =====================================================================
IF OBJECT_ID('grac_practice.tprm_risk_assessment','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_risk_assessment(
        assessment_id          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_risk_assessment PRIMARY KEY,
        engagement_id          BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_ra_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        organization_id        BIGINT         NOT NULL,
        assessment_no          INT            NOT NULL,
        risk_model_version_id  BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_ra_rmv REFERENCES grac_practice.tprm_template_version(version_id),
        trigger_code           NVARCHAR(60)   NOT NULL,   -- INITIAL / REVIEW_TRIGGER value
        trigger_note           NVARCHAR(1000) NULL,
        status                 NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_ra_status DEFAULT N'DRAFT'
            CONSTRAINT ck_pm_tprm_ra_status CHECK (status IN (N'DRAFT', N'COMPLETED', N'SUPERSEDED', N'DISCARDED')),
        inherent_score         DECIMAL(6,2)   NULL,
        inherent_band_code     NVARCHAR(60)   NULL,
        dd_tier_code           NVARCHAR(60)   NULL,
        dd_tier_reason         NVARCHAR(1000) NULL,
        residual_score         DECIMAL(6,2)   NULL,
        residual_band_code     NVARCHAR(60)   NULL,
        residual_dt            DATETIME2      NULL,
        residual_note          NVARCHAR(1000) NULL,
        notes                  NVARCHAR(2000) NULL,
        assessed_by_employee_id BIGINT        NULL
            CONSTRAINT fk_pm_tprm_ra_by REFERENCES grac_practice.organization_employee(employee_id),
        completed_by           NVARCHAR(100)  NULL,
        completed_dt           DATETIME2      NULL,
        record_version         ROWVERSION     NOT NULL,
        entered_by             NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_ra_eby DEFAULT N'system',
        entered_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_ra_edt DEFAULT SYSUTCDATETIME(),
        updated_by             NVARCHAR(100)  NULL,
        updated_dt             DATETIME2      NULL,
        CONSTRAINT uq_pm_tprm_ra_no UNIQUE (engagement_id, assessment_no)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_ra_draft ON grac_practice.tprm_risk_assessment(engagement_id) WHERE status = N'DRAFT';
END
GO

IF OBJECT_ID('grac_practice.tprm_risk_assessment_answer','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_risk_assessment_answer(
        answer_id     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_risk_assessment_answer PRIMARY KEY,
        assessment_id BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_raa_ra REFERENCES grac_practice.tprm_risk_assessment(assessment_id),
        factor_id     BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_raa_factor REFERENCES grac_practice.tprm_rm_factor(factor_id),
        option_id     BIGINT         NULL
            CONSTRAINT fk_pm_tprm_raa_option REFERENCES grac_practice.tprm_rm_factor_option(option_id),
        score         DECIMAL(9,2)   NULL,
        comment       NVARCHAR(1000) NULL,
        is_prefilled  BIT            NOT NULL CONSTRAINT df_pm_tprm_raa_prefill DEFAULT 0,
        updated_by    NVARCHAR(100)  NULL,
        updated_dt    DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_raa_udt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_tprm_raa UNIQUE (assessment_id, factor_id)
    );
END
GO

IF OBJECT_ID('grac_practice.tprm_risk_assessment_dimension','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_risk_assessment_dimension(
        assessment_id     BIGINT        NOT NULL
            CONSTRAINT fk_pm_tprm_rad_ra REFERENCES grac_practice.tprm_risk_assessment(assessment_id),
        dimension_id      BIGINT        NOT NULL
            CONSTRAINT fk_pm_tprm_rad_dim REFERENCES grac_practice.tprm_rm_dimension(dimension_id),
        dimension_code    NVARCHAR(60)  NOT NULL,
        weight            DECIMAL(9,2)  NOT NULL,
        inherent_score    DECIMAL(6,2)  NULL,
        reduction_pct     DECIMAL(6,2)  NULL,      -- 489: from verified safeguards
        uplift_pct        DECIMAL(6,2)  NULL,      -- 489: open High / Critical deficiencies
        residual_score    DECIMAL(6,2)  NULL,
        safeguard_summary NVARCHAR(1000) NULL,
        CONSTRAINT pk_pm_tprm_risk_assessment_dimension PRIMARY KEY (assessment_id, dimension_id)
    );
END
GO
PRINT '488: tables ready.';
GO

-- =====================================================================
-- 4. Functions
-- =====================================================================
-- Name normalised for duplicate detection: upper case, punctuation and
-- legal-form words removed, spaces collapsed.
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_normalize_name (@name NVARCHAR(250))
RETURNS NVARCHAR(250)
AS
BEGIN
    DECLARE @s NVARCHAR(400) = N' ' + UPPER(LTRIM(RTRIM(ISNULL(@name, N'')))) + N' ';
    DECLARE @i INT = 1, @c NCHAR(1), @r NVARCHAR(400) = N'';
    WHILE @i <= LEN(@s + N'x') - 1
    BEGIN
        SET @c = SUBSTRING(@s, @i, 1);
        SET @r = @r + CASE WHEN @c LIKE N'[A-Z0-9]' THEN @c ELSE N' ' END;
        SET @i = @i + 1;
    END
    SET @r = N' ' + @r + N' ';
    -- legal forms and filler words
    SET @r = REPLACE(@r, N' PRIVATE ', N' ');  SET @r = REPLACE(@r, N' PVT ', N' ');
    SET @r = REPLACE(@r, N' LIMITED ', N' ');  SET @r = REPLACE(@r, N' LTD ', N' ');
    SET @r = REPLACE(@r, N' INCORPORATED ', N' '); SET @r = REPLACE(@r, N' INC ', N' ');
    SET @r = REPLACE(@r, N' CORPORATION ', N' '); SET @r = REPLACE(@r, N' CORP ', N' ');
    SET @r = REPLACE(@r, N' COMPANY ', N' ');  SET @r = REPLACE(@r, N' CO ', N' ');
    SET @r = REPLACE(@r, N' LLP ', N' ');      SET @r = REPLACE(@r, N' LLC ', N' ');
    SET @r = REPLACE(@r, N' PLC ', N' ');      SET @r = REPLACE(@r, N' GMBH ', N' ');
    SET @r = REPLACE(@r, N' THE ', N' ');      SET @r = REPLACE(@r, N' AND ', N' ');
    WHILE CHARINDEX(N'  ', @r) > 0 SET @r = REPLACE(@r, N'  ', N' ');
    RETURN LEFT(LTRIM(RTRIM(@r)), 250);
END
GO

-- Possible duplicates of a third party: other third parties of the
-- organization with the same normalised name, one name containing the
-- other, or the same registration / tax / LEI identifier -- and GRAC
-- vendors (not yet linked) with the same normalised name.
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_third_party_matches
    (@organization_id BIGINT, @legal_name NVARCHAR(250), @trading_name NVARCHAR(250),
     @registration_number NVARCHAR(100), @tax_id NVARCHAR(100), @lei_code NVARCHAR(40), @exclude_id BIGINT)
RETURNS TABLE
AS
RETURN
(
WITH n AS (
    SELECT grac_practice.fn_tprm_normalize_name(@legal_name)   AS legal_n,
           grac_practice.fn_tprm_normalize_name(@trading_name) AS trading_n
)
SELECT N'THIRD_PARTY' AS match_kind, t.third_party_id AS match_id, t.third_party_code AS match_code, t.legal_name AS match_name,
       CASE WHEN NULLIF(LTRIM(RTRIM(@registration_number)), N'') IS NOT NULL AND t.registration_number = LTRIM(RTRIM(@registration_number)) THEN N'Same registration number'
            WHEN NULLIF(LTRIM(RTRIM(@tax_id)), N'') IS NOT NULL AND t.tax_id = LTRIM(RTRIM(@tax_id)) THEN N'Same tax identifier'
            WHEN NULLIF(LTRIM(RTRIM(@lei_code)), N'') IS NOT NULL AND t.lei_code = LTRIM(RTRIM(@lei_code)) THEN N'Same LEI'
            WHEN t.normalized_name = n.legal_n OR (n.trading_n <> N'' AND t.normalized_name = n.trading_n) THEN N'Same name'
            ELSE N'Similar name' END AS match_reason
FROM   grac_practice.tprm_third_party t
CROSS  JOIN n
WHERE  t.organization_id = @organization_id
  AND  t.status = N'Active'
  AND  t.third_party_id <> ISNULL(@exclude_id, -1)
  AND  (   (NULLIF(LTRIM(RTRIM(@registration_number)), N'') IS NOT NULL AND t.registration_number = LTRIM(RTRIM(@registration_number)))
        OR (NULLIF(LTRIM(RTRIM(@tax_id)), N'') IS NOT NULL AND t.tax_id = LTRIM(RTRIM(@tax_id)))
        OR (NULLIF(LTRIM(RTRIM(@lei_code)), N'') IS NOT NULL AND t.lei_code = LTRIM(RTRIM(@lei_code)))
        OR (n.legal_n <> N'' AND t.normalized_name = n.legal_n)
        OR (n.trading_n <> N'' AND t.normalized_name = n.trading_n)
        OR (LEN(n.legal_n) >= 5 AND LEN(t.normalized_name) >= 5
            AND (t.normalized_name LIKE N'%' + n.legal_n + N'%' OR n.legal_n LIKE N'%' + t.normalized_name + N'%')))
UNION ALL
SELECT N'VENDOR', v.vendor_id, CAST(NULL AS NVARCHAR(20)), v.vendor_name, N'GRAC vendor with the same name'
FROM   grac_practice.organization_dependency_vendor v
CROSS  JOIN n
WHERE  v.organization_id = @organization_id
  AND  v.status = N'Active'
  AND  n.legal_n <> N''
  AND  grac_practice.fn_tprm_normalize_name(v.vendor_name) IN (n.legal_n, n.trading_n)
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party t WHERE t.vendor_id = v.vendor_id)
);
GO

-- The first effective value of a list with the given meaning.
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_meaning_code (@organization_id BIGINT, @list_code NVARCHAR(60), @meaning NVARCHAR(40))
RETURNS NVARCHAR(60)
AS
BEGIN
    RETURN (SELECT TOP (1) e.value_code
            FROM grac_practice.fn_tprm_reference_effective(@organization_id) e
            WHERE e.list_code = @list_code AND e.meaning_code = @meaning
            ORDER BY CASE WHEN e.value_code = @meaning THEN 0 ELSE 1 END, e.display_order);
END
GO

-- What the scope says about an engagement, as codes the risk model,
-- tier rules and questionnaire applicability read (PROPOSED exposure
-- until onboarding has recorded the ACTUAL one).
--   data_codes    engagement data exposure + DATA_CATEGORY scope items
--   access_codes  ACCESS scope items (NONE when there are none)
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_engagement_signals (@engagement_id BIGINT)
RETURNS TABLE
AS
RETURN
(
SELECT e.engagement_id,
       e.organization_id,
       e.service_criticality_code,
       e.service_model_code,
       e.service_category_code,
       e.engagement_type_code,
       e.is_existing,
       mode.exposure_mode,
       CONCAT_WS(N',', e.data_exposure_code,
                 (SELECT STRING_AGG(s.item_code, N',') FROM grac_practice.tprm_engagement_scope s
                   WHERE s.engagement_id = e.engagement_id AND s.item_kind = N'DATA_CATEGORY'
                     AND s.status = N'Active' AND s.exposure_mode = mode.exposure_mode AND s.item_code IS NOT NULL)) AS data_codes,
       ISNULL((SELECT STRING_AGG(s.item_code, N',') FROM grac_practice.tprm_engagement_scope s
                WHERE s.engagement_id = e.engagement_id AND s.item_kind = N'ACCESS'
                  AND s.status = N'Active' AND s.exposure_mode = mode.exposure_mode AND s.item_code IS NOT NULL), N'NONE') AS access_codes,
       (SELECT COUNT(*) FROM grac_practice.tprm_engagement_scope s
         WHERE s.engagement_id = e.engagement_id AND s.item_kind = N'FOURTH_PARTY'
           AND s.status = N'Active' AND s.exposure_mode = mode.exposure_mode) AS fourth_party_count,
       (SELECT COUNT(*) FROM grac_practice.tprm_engagement_scope s
         WHERE s.engagement_id = e.engagement_id AND s.item_kind = N'LOCATION'
           AND s.status = N'Active' AND s.exposure_mode = mode.exposure_mode) AS location_count
FROM   grac_practice.tprm_engagement e
CROSS  APPLY (SELECT CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope a
                                        WHERE a.engagement_id = e.engagement_id AND a.exposure_mode = N'ACTUAL' AND a.status = N'Active')
                          THEN N'ACTUAL' ELSE N'PROPOSED' END AS exposure_mode) mode
WHERE  e.engagement_id = @engagement_id
);
GO

-- =====================================================================
-- 5. Helpers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_event
    @engagement_id     BIGINT,
    @event_code        NVARCHAR(40),
    @from_stage_code   NVARCHAR(30)   = NULL,
    @to_stage_code     NVARCHAR(30)   = NULL,
    @detail            NVARCHAR(2000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    INSERT grac_practice.tprm_engagement_history
        (engagement_id, event_code, from_stage_code, to_stage_code, detail, actor_employee_id, actor)
    VALUES (@engagement_id, @event_code, @from_stage_code, @to_stage_code, @detail, @actor_employee_id, ISNULL(@actor, N'system'));
    EXEC grac_practice.sp_tprm_audit N'tprm-engagement', @engagement_id, @event_code, @detail, @actor;
END
GO

-- Moves the third party's lifecycle status to what its engagements say
-- (BRD step 1 statuses), only forward, and never out of a manual
-- suspension:
--   any engagement ACTIVE                       -> ACTIVE
--   any APPROVED / ONBOARDING                   -> APPROVED
--   any in assessment (SCOPING .. DECISION)     -> UNDER_ASSESSMENT
--   all closed and at least one EXITED          -> EXITED
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_third_party_sync_status
    @third_party_id BIGINT,
    @actor          NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @org BIGINT, @current NVARCHAR(60), @current_meaning NVARCHAR(40);
    SELECT @org = t.organization_id, @current = t.lifecycle_status_code
    FROM grac_practice.tprm_third_party t WHERE t.third_party_id = @third_party_id;
    IF @org IS NULL RETURN;
    SELECT TOP (1) @current_meaning = e.meaning_code FROM grac_practice.fn_tprm_reference_effective(@org) e
     WHERE e.list_code = N'TP_STATUS' AND e.value_code = @current;
    IF @current_meaning = N'SUSPENDED' RETURN;

    DECLARE @target NVARCHAR(40) =
        CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id AND stage_code = N'ACTIVE')
                  THEN N'ACTIVE'
             WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id
                            AND stage_code IN (N'APPROVED', N'ONBOARDING', N'SUSPENDED', N'EXITING'))
                  THEN N'APPROVED'
             WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id
                            AND stage_code IN (N'SCOPING', N'RISK_ASSESSED', N'DUE_DILIGENCE', N'PENDING_DECISION'))
                  THEN N'UNDER_ASSESSMENT'
             WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id AND stage_code = N'EXITED')
                  THEN N'EXITED'
        END;
    IF @target IS NULL OR @target = @current_meaning RETURN;
    -- forward only, except a full exit (EXITED) and a reactivation (back to ACTIVE)
    IF @target NOT IN (N'EXITED', N'ACTIVE')
       AND CASE @current_meaning WHEN N'PROSPECTIVE' THEN 1 WHEN N'UNDER_ASSESSMENT' THEN 2 WHEN N'APPROVED' THEN 3
                                 WHEN N'ACTIVE' THEN 4 WHEN N'EXITED' THEN 5 ELSE 0 END
         >= CASE @target WHEN N'UNDER_ASSESSMENT' THEN 2 WHEN N'APPROVED' THEN 3 ELSE 0 END
       AND @current_meaning <> N'EXITED'
        RETURN;

    DECLARE @code NVARCHAR(60) = grac_practice.fn_tprm_meaning_code(@org, N'TP_STATUS', @target);
    IF @code IS NULL OR @code = @current RETURN;
    UPDATE grac_practice.tprm_third_party SET lifecycle_status_code = @code, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE third_party_id = @third_party_id;
    INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor)
    VALUES (@third_party_id, @current, @code, N'Set from the status of its engagements.', 1, ISNULL(@actor, N'system'));
END
GO

-- =====================================================================
-- 6. Lookups for every TPRM screen of one organization
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_lookups
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 57600, 'Select an organization.', 1;

    -- 1 reference values in force
    SELECT e.list_code AS ListCode, e.value_code AS ValueCode, e.label AS Label, e.description AS Description,
           e.meaning_code AS MeaningCode, e.rank_no AS RankNo, e.color_hex AS ColorHex, e.is_mandatory AS IsMandatory,
           e.display_order AS DisplayOrder
    FROM   grac_practice.fn_tprm_reference_effective(@organization_id) e
    ORDER  BY e.list_code, e.display_order, e.label;

    -- 2 employees
    SELECT employee_id AS EmployeeId, employee_name AS EmployeeName, employee_code AS EmployeeCode
    FROM   grac_practice.organization_employee
    WHERE  organization_id = @organization_id AND status = N'Active'
    ORDER  BY employee_name;

    -- 3 business functions  4 processes  5 applications
    SELECT business_function_id AS Id, function_name AS Name, criticality AS Criticality
    FROM   grac_practice.organization_business_function
    WHERE  organization_id = @organization_id AND status = N'Active' ORDER BY function_name;
    SELECT process_id AS Id, process_name AS Name
    FROM   grac_practice.organization_dependency_process
    WHERE  organization_id = @organization_id AND status = N'Active' ORDER BY process_name;
    SELECT application_id AS Id, application_name AS Name, vendor_id AS VendorId
    FROM   grac_practice.organization_dependency_application
    WHERE  organization_id = @organization_id AND status = N'Active' ORDER BY application_name;

    -- 6 vendors (GRAC dependency register) with the third party they are linked to
    SELECT v.vendor_id AS VendorId, v.vendor_name AS VendorName, t.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode
    FROM   grac_practice.organization_dependency_vendor v
    LEFT   JOIN grac_practice.tprm_third_party t ON t.vendor_id = v.vendor_id
    WHERE  v.organization_id = @organization_id AND v.status = N'Active'
    ORDER  BY v.vendor_name;

    -- 7 contracts (Asset & Contract, 434) when installed
    IF OBJECT_ID('grac_practice.asset_contract','U') IS NOT NULL
        EXEC sp_executesql N'SELECT c.contract_id AS ContractId, c.contract_number AS ContractNumber, c.contract_name AS ContractName,
                                    c.vendor_id AS VendorId, c.contract_status AS ContractStatus
                             FROM grac_practice.asset_contract c WHERE c.organization_id = @o ORDER BY c.contract_number;',
                           N'@o BIGINT', @o = @organization_id;
    ELSE
        SELECT CAST(NULL AS BIGINT) AS ContractId, CAST(NULL AS NVARCHAR(60)) AS ContractNumber, CAST(NULL AS NVARCHAR(250)) AS ContractName,
               CAST(NULL AS BIGINT) AS VendorId, CAST(NULL AS NVARCHAR(20)) AS ContractStatus WHERE 1 = 0;

    -- 8 library in force
    SELECT l.library_code AS LibraryCode, l.item_code AS ItemCode, l.item_name AS ItemName, l.description AS Description,
           l.category_code AS CategoryCode, l.dimension_code AS DimensionCode, l.guidance AS Guidance,
           l.effectiveness_criteria AS EffectivenessCriteria, l.is_contract_clause AS IsContractClause,
           l.evidence_requirement_code AS EvidenceRequirementCode, l.evidence_type_id AS EvidenceTypeId,
           l.validity_months AS ValidityMonths, l.default_due_days AS DefaultDueDays, l.default_owner_hint AS DefaultOwnerHint
    FROM   grac_practice.fn_tprm_library_effective(@organization_id) l
    ORDER  BY l.library_code, l.display_order, l.item_name;

    -- 9 custom fields
    SELECT f.field_id AS FieldId, f.entity_code AS EntityCode, f.field_code AS FieldCode, f.label AS Label,
           f.description AS Description, f.data_type AS DataType, f.is_mandatory AS IsMandatory,
           f.default_value AS DefaultValue, f.validation_regex AS ValidationRegex, f.min_value AS MinValue,
           f.max_value AS MaxValue, f.max_length AS MaxLength, f.options_json AS OptionsJson,
           f.reference_kind AS ReferenceKind, f.visible_when_field_code AS VisibleWhenFieldCode,
           f.visible_when_value AS VisibleWhenValue, f.access_role_names AS AccessRoleNames,
           f.is_filterable AS IsFilterable, f.display_order AS DisplayOrder
    FROM   grac_practice.tprm_custom_field f
    WHERE  f.organization_id = @organization_id AND f.status = N'Active'
    ORDER  BY f.entity_code, f.display_order, f.label;

    -- 10 risk model in force + its dimensions
    SELECT m.version_id AS VersionId, m.template_id AS TemplateId, m.template_name AS TemplateName, m.origin AS Origin,
           v.version_no AS VersionNo
    FROM   grac_practice.fn_tprm_risk_model_version(@organization_id) m
    JOIN   grac_practice.tprm_template_version v ON v.version_id = m.version_id;
    SELECT d.dimension_code AS DimensionCode, d.dimension_name AS DimensionName, d.weight AS Weight
    FROM   grac_practice.fn_tprm_risk_model_version(@organization_id) m
    JOIN   grac_practice.tprm_rm_dimension d ON d.version_id = m.version_id
    ORDER  BY d.display_order;
    SELECT b.band_code AS BandCode, b.band_name AS BandName, b.min_score AS MinScore, b.rank_no AS RankNo, b.color_hex AS ColorHex
    FROM   grac_practice.fn_tprm_risk_model_version(@organization_id) m
    JOIN   grac_practice.tprm_rm_band b ON b.version_id = m.version_id
    ORDER  BY b.min_score;

    -- 13 evidence types (Evidence Center) when installed
    IF OBJECT_ID('grac_practice.evidence_type_master','U') IS NOT NULL
        EXEC sp_executesql N'SELECT evidence_type_id AS EvidenceTypeId, evidence_type_name AS EvidenceType
                             FROM grac_practice.evidence_type_master ORDER BY evidence_type_name;';
    ELSE
        SELECT CAST(NULL AS INT) AS EvidenceTypeId, CAST(NULL AS NVARCHAR(200)) AS EvidenceType WHERE 1 = 0;

    -- 14 roles
    SELECT role_id AS RoleId, role_name AS RoleName
    FROM   grac_practice.organization_role
    WHERE  organization_id = @organization_id AND status = N'Active' ORDER BY role_name;
END
GO

-- =====================================================================
-- 7. Third parties
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_third_party_list
    @organization_id       BIGINT,
    @search                NVARCHAR(200) = NULL,
    @status_code           NVARCHAR(60)  = NULL,
    @service_category_code NVARCHAR(60)  = NULL,
    @include_archived      BIT           = 0,
    @sample                NVARCHAR(10)  = NULL,   -- NULL all / ONLY / EXCLUDE
    @page_number           INT           = 1,
    @page_size             INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 57600, 'Select an organization.', 1;
    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');

    ;WITH ref AS (SELECT list_code, value_code, label, color_hex, rank_no FROM grac_practice.fn_tprm_reference_effective(@organization_id)),
    agg AS (
        SELECT e.third_party_id,
               COUNT(*) AS engagement_count,
               SUM(CASE WHEN e.stage_code = N'ACTIVE' THEN 1 ELSE 0 END) AS active_count,
               SUM(CASE WHEN e.stage_code IN (N'SCOPING', N'RISK_ASSESSED', N'DUE_DILIGENCE', N'PENDING_DECISION') THEN 1 ELSE 0 END) AS in_assessment_count,
               MAX(e.residual_score) AS highest_residual_score,
               MAX(e.inherent_score) AS highest_inherent_score
        FROM   grac_practice.tprm_engagement e
        WHERE  e.organization_id = @organization_id
        GROUP  BY e.third_party_id
    )
    SELECT t.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS LegalName,
           t.trading_name AS TradingName, t.provider_type_code AS ProviderTypeCode, pt.label AS ProviderType,
           t.primary_service_category_code AS ServiceCategoryCode, sc.label AS ServiceCategory,
           t.country AS Country, t.lifecycle_status_code AS StatusCode, st.label AS StatusLabel, st.color_hex AS StatusColor,
           t.relationship_owner_employee_id AS RelationshipOwnerEmployeeId, ro.employee_name AS RelationshipOwnerName,
           t.vendor_id AS VendorId, v.vendor_name AS VendorName, t.is_sample AS IsSample, t.status AS RecordStatus,
           ISNULL(a.engagement_count, 0) AS EngagementCount, ISNULL(a.active_count, 0) AS ActiveEngagementCount,
           ISNULL(a.in_assessment_count, 0) AS InAssessmentCount,
           a.highest_inherent_score AS HighestInherentScore, a.highest_residual_score AS HighestResidualScore,
           COUNT(*) OVER () AS TotalRows
    FROM   grac_practice.tprm_third_party t
    LEFT   JOIN agg a ON a.third_party_id = t.third_party_id
    LEFT   JOIN ref pt ON pt.list_code = N'PROVIDER_TYPE' AND pt.value_code = t.provider_type_code
    LEFT   JOIN ref sc ON sc.list_code = N'SERVICE_CATEGORY' AND sc.value_code = t.primary_service_category_code
    LEFT   JOIN ref st ON st.list_code = N'TP_STATUS' AND st.value_code = t.lifecycle_status_code
    LEFT   JOIN grac_practice.organization_employee ro ON ro.employee_id = t.relationship_owner_employee_id
    LEFT   JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id = t.vendor_id
    WHERE  t.organization_id = @organization_id
      AND  (ISNULL(@include_archived, 0) = 1 OR t.status = N'Active')
      AND  (@status_code IS NULL OR t.lifecycle_status_code = @status_code)
      AND  (@service_category_code IS NULL
            OR t.primary_service_category_code = @service_category_code
            OR EXISTS (SELECT 1 FROM grac_practice.tprm_third_party_category c
                        WHERE c.third_party_id = t.third_party_id AND c.service_category_code = @service_category_code))
      AND  (@sample IS NULL OR (@sample = N'ONLY' AND t.is_sample = 1) OR (@sample = N'EXCLUDE' AND t.is_sample = 0))
      AND  (@s IS NULL OR t.legal_name LIKE N'%' + @s + N'%' OR t.trading_name LIKE N'%' + @s + N'%'
            OR t.third_party_code LIKE N'%' + @s + N'%' OR t.registration_number LIKE N'%' + @s + N'%'
            OR EXISTS (SELECT 1 FROM grac_practice.tprm_custom_field_value cv
                        JOIN grac_practice.tprm_custom_field cf ON cf.field_id = cv.field_id AND cf.is_searchable = 1
                        WHERE cv.entity_code = N'THIRD_PARTY' AND cv.record_id = t.third_party_id
                          AND cv.value_text LIKE N'%' + @s + N'%'))
    ORDER  BY t.legal_name, t.third_party_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_third_party_get
    @organization_id BIGINT,
    @third_party_id  BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party WHERE third_party_id = @third_party_id AND organization_id = @organization_id)
        THROW 57601, 'That third party was not found.', 1;

    ;WITH ref AS (SELECT list_code, value_code, label, color_hex FROM grac_practice.fn_tprm_reference_effective(@organization_id))
    SELECT t.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS LegalName,
           t.trading_name AS TradingName, t.registration_number AS RegistrationNumber, t.tax_id AS TaxId, t.lei_code AS LeiCode,
           t.provider_type_code AS ProviderTypeCode, pt.label AS ProviderType,
           t.primary_service_category_code AS ServiceCategoryCode, sc.label AS ServiceCategory,
           t.reporting_category_code AS ReportingCategoryCode, rc.label AS ReportingCategory,
           t.country AS Country, t.state_region AS StateRegion, t.city AS City, t.address AS Address, t.website AS Website,
           t.parent_company AS ParentCompany, t.year_established AS YearEstablished, t.employee_count_band AS EmployeeCountBand,
           t.annual_revenue_band AS AnnualRevenueBand, t.certifications_text AS CertificationsText, t.profile_notes AS ProfileNotes,
           t.lifecycle_status_code AS StatusCode, st.label AS StatusLabel, st.color_hex AS StatusColor,
           t.relationship_owner_employee_id AS RelationshipOwnerEmployeeId, ro.employee_name AS RelationshipOwnerName,
           t.vendor_id AS VendorId, v.vendor_name AS VendorName, t.is_sample AS IsSample, t.status AS RecordStatus,
           CONVERT(BIGINT, t.record_version) AS RecordVersion, t.entered_by AS EnteredBy, t.entered_dt AS EnteredDt,
           t.updated_by AS UpdatedBy, t.updated_dt AS UpdatedDt
    FROM   grac_practice.tprm_third_party t
    LEFT   JOIN ref pt ON pt.list_code = N'PROVIDER_TYPE' AND pt.value_code = t.provider_type_code
    LEFT   JOIN ref sc ON sc.list_code = N'SERVICE_CATEGORY' AND sc.value_code = t.primary_service_category_code
    LEFT   JOIN ref rc ON rc.list_code = N'REPORTING_CATEGORY' AND rc.value_code = t.reporting_category_code
    LEFT   JOIN ref st ON st.list_code = N'TP_STATUS' AND st.value_code = t.lifecycle_status_code
    LEFT   JOIN grac_practice.organization_employee ro ON ro.employee_id = t.relationship_owner_employee_id
    LEFT   JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id = t.vendor_id
    WHERE  t.third_party_id = @third_party_id;

    SELECT c.service_category_code AS ServiceCategoryCode, r.label AS Label
    FROM   grac_practice.tprm_third_party_category c
    LEFT   JOIN grac_practice.fn_tprm_reference_effective(@organization_id) r
           ON r.list_code = N'SERVICE_CATEGORY' AND r.value_code = c.service_category_code
    WHERE  c.third_party_id = @third_party_id;

    SELECT contact_id AS ContactId, contact_name AS ContactName, contact_role AS ContactRole, email AS Email,
           phone AS Phone, is_primary AS IsPrimary
    FROM   grac_practice.tprm_third_party_contact
    WHERE  third_party_id = @third_party_id AND status = N'Active'
    ORDER  BY is_primary DESC, contact_name;

    SELECT e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode, e.engagement_title AS EngagementTitle,
           e.stage_code AS StageCode, e.service_criticality_code AS CriticalityCode, e.inherent_score AS InherentScore,
           e.inherent_band_code AS InherentBandCode, e.residual_score AS ResidualScore, e.residual_band_code AS ResidualBandCode,
           e.dd_tier_code AS DdTierCode, e.next_review_dt AS NextReviewDt, e.is_existing AS IsExisting,
           bo.employee_name AS BusinessOwnerName
    FROM   grac_practice.tprm_engagement e
    LEFT   JOIN grac_practice.organization_employee bo ON bo.employee_id = e.business_owner_employee_id
    WHERE  e.third_party_id = @third_party_id
    ORDER  BY e.engagement_id DESC;

    SELECT h.history_id AS HistoryId, h.from_status_code AS FromStatusCode, h.to_status_code AS ToStatusCode,
           h.reason AS Reason, h.is_automatic AS IsAutomatic, h.actor AS Actor, ae.employee_name AS ActorName, h.changed_dt AS ChangedDt
    FROM   grac_practice.tprm_third_party_status_history h
    LEFT   JOIN grac_practice.organization_employee ae ON ae.employee_id = h.actor_employee_id
    WHERE  h.third_party_id = @third_party_id
    ORDER  BY h.history_id DESC;

    SELECT cv.field_id AS FieldId, cv.field_code AS FieldCode, cv.label AS Label, cv.data_type AS DataType, cv.value_string AS Value
    FROM   grac_practice.fn_tprm_custom_values(@organization_id, N'THIRD_PARTY', @third_party_id) cv;

    DECLARE @ln NVARCHAR(250), @tn NVARCHAR(250), @rn NVARCHAR(100), @tx NVARCHAR(100), @lei NVARCHAR(40);
    SELECT @ln = legal_name, @tn = trading_name, @rn = registration_number, @tx = tax_id, @lei = lei_code
    FROM grac_practice.tprm_third_party WHERE third_party_id = @third_party_id;
    SELECT m.match_kind AS MatchKind, m.match_id AS MatchId, m.match_code AS MatchCode, m.match_name AS MatchName, m.match_reason AS MatchReason
    FROM   grac_practice.fn_tprm_third_party_matches(@organization_id, @ln, @tn, @rn, @tx, @lei, @third_party_id) m;
END
GO

-- Register / update a third party.
-- Result: one row (ThirdPartyId, Result). Result DUPLICATES = nothing was
-- saved; a second result set lists the possible duplicates. Repeat with
-- @confirm_duplicates = 1 to register anyway.
--   @categories_csv : SERVICE_CATEGORY codes (the primary one is added)
--   @contacts_json  : [{"contactId":null,"name","role","email","phone","isPrimary"}] -- the full list
--   @custom_json    : see sp_tprm_custom_values_save
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_third_party_save
    @organization_id               BIGINT,
    @third_party_id                BIGINT         = NULL,
    @legal_name                    NVARCHAR(250),
    @trading_name                  NVARCHAR(250)  = NULL,
    @registration_number           NVARCHAR(100)  = NULL,
    @tax_id                        NVARCHAR(100)  = NULL,
    @lei_code                      NVARCHAR(40)   = NULL,
    @provider_type_code            NVARCHAR(60)   = NULL,
    @primary_service_category_code NVARCHAR(60)   = NULL,
    @categories_csv                NVARCHAR(1000) = NULL,
    @reporting_category_code       NVARCHAR(60)   = NULL,
    @country                       NVARCHAR(120)  = NULL,
    @state_region                  NVARCHAR(120)  = NULL,
    @city                          NVARCHAR(120)  = NULL,
    @address                       NVARCHAR(1000) = NULL,
    @website                       NVARCHAR(300)  = NULL,
    @parent_company                NVARCHAR(250)  = NULL,
    @year_established              INT            = NULL,
    @employee_count_band           NVARCHAR(60)   = NULL,
    @annual_revenue_band           NVARCHAR(60)   = NULL,
    @certifications_text           NVARCHAR(1000) = NULL,
    @profile_notes                 NVARCHAR(MAX)  = NULL,
    @relationship_owner_employee_id BIGINT        = NULL,
    @contacts_json                 NVARCHAR(MAX)  = NULL,
    @custom_json                   NVARCHAR(MAX)  = NULL,
    @confirm_duplicates            BIT            = 0,
    @expected_record_version       BIGINT         = NULL,
    @caller_role_names             NVARCHAR(600)  = NULL,
    @caller_is_admin               BIT            = 0,
    @actor_employee_id             BIGINT         = NULL,
    @actor                         NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL THROW 57600, 'Select an organization.', 1;
    SET @legal_name = NULLIF(LTRIM(RTRIM(@legal_name)), N'');
    IF @legal_name IS NULL THROW 57602, 'Legal name is required.', 1;
    SET @primary_service_category_code = NULLIF(LTRIM(RTRIM(@primary_service_category_code)), N'');
    SET @provider_type_code = NULLIF(LTRIM(RTRIM(@provider_type_code)), N'');
    SET @reporting_category_code = NULLIF(LTRIM(RTRIM(@reporting_category_code)), N'');

    IF @provider_type_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                                        WHERE list_code = N'PROVIDER_TYPE' AND value_code = @provider_type_code)
        THROW 57603, 'Choose a provider type from the list.', 1;
    IF @primary_service_category_code IS NULL THROW 57604, 'Choose the main service category.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(CONCAT_WS(N',', @primary_service_category_code, @categories_csv)) c
                WHERE NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
                                   WHERE r.list_code = N'SERVICE_CATEGORY' AND r.value_code = c.code))
        THROW 57605, 'A service category is not in the list.', 1;
    IF @reporting_category_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                                             WHERE list_code = N'REPORTING_CATEGORY' AND value_code = @reporting_category_code)
        THROW 57606, 'Choose a reporting category from the list.', 1;
    IF @relationship_owner_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                        WHERE employee_id = @relationship_owner_employee_id AND organization_id = @organization_id AND status = N'Active')
        THROW 57607, 'The relationship owner must be an active employee of this organization.', 1;
    IF @year_established IS NOT NULL AND (@year_established < 1800 OR @year_established > YEAR(SYSUTCDATETIME()))
        THROW 57608, 'Year established is not valid.', 1;
    IF @contacts_json IS NOT NULL AND ISJSON(@contacts_json) <> 1 THROW 57609, 'Contacts are not valid.', 1;
    IF @contacts_json IS NOT NULL AND EXISTS (SELECT 1 FROM OPENJSON(@contacts_json) WITH (name NVARCHAR(200) '$.name') WHERE NULLIF(LTRIM(RTRIM(name)), N'') IS NULL)
        THROW 57610, 'Every contact needs a name.', 1;

    IF @third_party_id IS NOT NULL
    BEGIN
        DECLARE @rv BIGINT;
        SELECT @rv = CONVERT(BIGINT, record_version) FROM grac_practice.tprm_third_party
         WHERE third_party_id = @third_party_id AND organization_id = @organization_id;
        IF @rv IS NULL THROW 57601, 'That third party was not found.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 57611, 'Someone else changed this third party. Reload and try again.', 1;
    END

    -- BRD step 1: identify possible duplicate records before registering.
    IF ISNULL(@confirm_duplicates, 0) = 0
       AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_third_party_matches(@organization_id, @legal_name, @trading_name,
                                   @registration_number, @tax_id, @lei_code, @third_party_id) m
                    WHERE m.match_kind = N'THIRD_PARTY' OR @third_party_id IS NULL)
    BEGIN
        SELECT @third_party_id AS ThirdPartyId, N'DUPLICATES' AS Result;
        SELECT m.match_kind AS MatchKind, m.match_id AS MatchId, m.match_code AS MatchCode, m.match_name AS MatchName, m.match_reason AS MatchReason
        FROM grac_practice.fn_tprm_third_party_matches(@organization_id, @legal_name, @trading_name,
                                   @registration_number, @tax_id, @lei_code, @third_party_id) m;
        RETURN;
    END

    DECLARE @id BIGINT = @third_party_id, @created BIT = 0;
    BEGIN TRAN;
    IF @id IS NULL
    BEGIN
        DECLARE @next INT, @code NVARCHAR(20);
        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(third_party_code, 4, 20))), 0) + 1
        FROM   grac_practice.tprm_third_party WITH (UPDLOCK, HOLDLOCK)
        WHERE  organization_id = @organization_id AND third_party_code LIKE N'TP-%';
        SET @code = N'TP-' + FORMAT(@next, '000');

        INSERT grac_practice.tprm_third_party
            (organization_id, third_party_code, legal_name, trading_name, normalized_name, registration_number, tax_id, lei_code,
             provider_type_code, primary_service_category_code, reporting_category_code, country, state_region, city, address,
             website, parent_company, year_established, employee_count_band, annual_revenue_band, certifications_text, profile_notes,
             lifecycle_status_code, relationship_owner_employee_id, entered_by)
        VALUES (@organization_id, @code, @legal_name, NULLIF(LTRIM(RTRIM(@trading_name)), N''), grac_practice.fn_tprm_normalize_name(@legal_name),
                NULLIF(LTRIM(RTRIM(@registration_number)), N''), NULLIF(LTRIM(RTRIM(@tax_id)), N''), NULLIF(LTRIM(RTRIM(@lei_code)), N''),
                @provider_type_code, @primary_service_category_code, @reporting_category_code, @country, @state_region, @city, @address,
                @website, @parent_company, @year_established, @employee_count_band, @annual_revenue_band, @certifications_text, @profile_notes,
                ISNULL(grac_practice.fn_tprm_meaning_code(@organization_id, N'TP_STATUS', N'PROSPECTIVE'), N'PROSPECTIVE'),
                @relationship_owner_employee_id, @actor);
        SET @id = SCOPE_IDENTITY();
        SET @created = 1;
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        SELECT @id, NULL, lifecycle_status_code, N'Registered.', 0, @actor_employee_id, @actor
        FROM grac_practice.tprm_third_party WHERE third_party_id = @id;
    END
    ELSE
        UPDATE grac_practice.tprm_third_party
           SET legal_name = @legal_name, trading_name = NULLIF(LTRIM(RTRIM(@trading_name)), N''),
               normalized_name = grac_practice.fn_tprm_normalize_name(@legal_name),
               registration_number = NULLIF(LTRIM(RTRIM(@registration_number)), N''), tax_id = NULLIF(LTRIM(RTRIM(@tax_id)), N''),
               lei_code = NULLIF(LTRIM(RTRIM(@lei_code)), N''), provider_type_code = @provider_type_code,
               primary_service_category_code = @primary_service_category_code, reporting_category_code = @reporting_category_code,
               country = @country, state_region = @state_region, city = @city, address = @address, website = @website,
               parent_company = @parent_company, year_established = @year_established, employee_count_band = @employee_count_band,
               annual_revenue_band = @annual_revenue_band, certifications_text = @certifications_text, profile_notes = @profile_notes,
               relationship_owner_employee_id = @relationship_owner_employee_id, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE third_party_id = @id;

    DELETE FROM grac_practice.tprm_third_party_category WHERE third_party_id = @id;
    INSERT grac_practice.tprm_third_party_category (third_party_id, service_category_code)
    SELECT @id, c.code FROM grac_practice.fn_tprm_split_codes(CONCAT_WS(N',', @primary_service_category_code, @categories_csv)) c;

    IF @contacts_json IS NOT NULL
    BEGIN
        UPDATE c SET status = N'Removed', updated_by = @actor, updated_dt = SYSUTCDATETIME()
        FROM grac_practice.tprm_third_party_contact c
        WHERE c.third_party_id = @id AND c.status = N'Active'
          AND NOT EXISTS (SELECT 1 FROM OPENJSON(@contacts_json) WITH (contactId BIGINT '$.contactId') j WHERE j.contactId = c.contact_id);
        UPDATE c SET contact_name = LTRIM(RTRIM(j.name)), contact_role = j.role, email = j.email, phone = j.phone,
                     is_primary = ISNULL(j.isPrimary, 0), updated_by = @actor, updated_dt = SYSUTCDATETIME()
        FROM grac_practice.tprm_third_party_contact c
        JOIN OPENJSON(@contacts_json) WITH (contactId BIGINT '$.contactId', name NVARCHAR(200) '$.name', role NVARCHAR(150) '$.role',
                                            email NVARCHAR(250) '$.email', phone NVARCHAR(60) '$.phone', isPrimary BIT '$.isPrimary') j
             ON j.contactId = c.contact_id
        WHERE c.third_party_id = @id;
        INSERT grac_practice.tprm_third_party_contact (third_party_id, organization_id, contact_name, contact_role, email, phone, is_primary, entered_by)
        SELECT @id, @organization_id, LTRIM(RTRIM(j.name)), j.role, j.email, j.phone, ISNULL(j.isPrimary, 0), @actor
        FROM OPENJSON(@contacts_json) WITH (contactId BIGINT '$.contactId', name NVARCHAR(200) '$.name', role NVARCHAR(150) '$.role',
                                            email NVARCHAR(250) '$.email', phone NVARCHAR(60) '$.phone', isPrimary BIT '$.isPrimary') j
        WHERE j.contactId IS NULL OR NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party_contact c
                                                  WHERE c.contact_id = j.contactId AND c.third_party_id = @id);
    END

    -- custom-field access follows the caller's GRAC role (organization_employee.role_id)
    IF @caller_role_names IS NULL AND @actor_employee_id IS NOT NULL
        SELECT @caller_role_names = r.role_name FROM grac_practice.organization_employee e
        JOIN grac_practice.organization_role r ON r.role_id = e.role_id WHERE e.employee_id = @actor_employee_id;
    EXEC grac_practice.sp_tprm_custom_values_save @organization_id, N'THIRD_PARTY', @id, @custom_json,
         @caller_role_names, @caller_is_admin, @actor;
    COMMIT;

    -- EXEC arguments must be constants or variables (no expressions)
    DECLARE @audit_action NVARCHAR(80) = CASE WHEN @created = 1 THEN N'CREATE' ELSE N'UPDATE' END;
    EXEC grac_practice.sp_tprm_audit N'tprm-third-party', @id, @audit_action, @legal_name, @actor;
    SELECT @id AS ThirdPartyId, CASE WHEN @created = 1 THEN N'CREATED' ELSE N'SAVED' END AS Result;
END
GO

-- Manual lifecycle status change (with a reason) and archive / restore.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_third_party_status
    @organization_id   BIGINT,
    @third_party_id    BIGINT,
    @status_code       NVARCHAR(60)  = NULL,
    @archive           BIT           = NULL,     -- 1 archive, 0 restore, NULL leave
    @reason            NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @current NVARCHAR(60);
    SELECT @current = lifecycle_status_code FROM grac_practice.tprm_third_party
     WHERE third_party_id = @third_party_id AND organization_id = @organization_id;
    IF @current IS NULL THROW 57601, 'That third party was not found.', 1;
    IF NULLIF(LTRIM(RTRIM(@reason)), N'') IS NULL THROW 57612, 'Give a reason for the change.', 1;

    IF @status_code IS NOT NULL AND @status_code <> @current
    BEGIN
        DECLARE @meaning NVARCHAR(40) = (SELECT TOP (1) meaning_code FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                          WHERE list_code = N'TP_STATUS' AND value_code = @status_code);
        IF @meaning IS NULL THROW 57613, 'Choose a status from the list.', 1;
        IF @meaning = N'EXITED' AND EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id
                                             AND stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED'))
            THROW 57614, 'Close, exit or cancel every engagement before marking the third party as exited.', 1;
        IF @meaning = N'ACTIVE' AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id
                                                 AND stage_code = N'ACTIVE')
            THROW 57615, 'A third party is active only when one of its engagements is active.', 1;
        UPDATE grac_practice.tprm_third_party SET lifecycle_status_code = @status_code, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE third_party_id = @third_party_id;
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        VALUES (@third_party_id, @current, @status_code, @reason, 0, @actor_employee_id, @actor);
    END

    IF @archive IS NOT NULL
    BEGIN
        IF @archive = 1 AND EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id
                                     AND stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED'))
            THROW 57616, 'A third party with open engagements cannot be archived.', 1;
        UPDATE grac_practice.tprm_third_party SET status = CASE WHEN @archive = 1 THEN N'Archived' ELSE N'Active' END,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE third_party_id = @third_party_id;
    END

    EXEC grac_practice.sp_tprm_audit N'tprm-third-party', @third_party_id, N'STATUS', @reason, @actor;
    SELECT @third_party_id AS ThirdPartyId, N'SAVED' AS Result;
END
GO

-- =====================================================================
-- 8. Vendor discovery and import (BRD step 1, acceptance 3)
-- =====================================================================
-- GRAC vendors with what already depends on them, and the third party
-- they are (or could be) linked to.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_vendor_discovery
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @only_unlinked   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 57600, 'Select an organization.', 1;
    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');
    DECLARE @vendor_type INT = (SELECT TOP (1) dependency_type_id FROM grac_practice.dependency_type_master
                                 WHERE dependency_type_code = N'Vendor');

    SELECT v.vendor_id AS VendorId, v.vendor_name AS VendorName, sc.service_category_name AS ServiceCategory,
           cm.criticality_name AS Criticality, v.contract_start_dt AS ContractStartDt, v.contract_end_dt AS ContractEndDt,
           ro.employee_name AS RelationshipOwnerName,
           (SELECT COUNT(DISTINCT r.practice_instance_id) FROM grac_practice.practice_dependency_resolution r
             WHERE r.organization_id = @organization_id AND r.dependency_type_id = @vendor_type
               AND r.resolved_dependency_id = v.vendor_id AND r.is_active = 1) AS PracticeInstanceCount,
           (SELECT COUNT(*) FROM grac_practice.organization_dependency_application a
             WHERE a.vendor_id = v.vendor_id AND a.status = N'Active') AS ApplicationCount,
           (SELECT COUNT(*) FROM grac_practice.risk_register rr
             WHERE rr.organization_id = @organization_id AND rr.linked_vendor_id = v.vendor_id
               AND rr.status_code NOT IN (N'Closed', N'Retired')) AS OpenRiskCount,
           t.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS ThirdPartyName,
           sug.third_party_id AS SuggestedThirdPartyId, sug.third_party_code AS SuggestedThirdPartyCode, sug.legal_name AS SuggestedThirdPartyName
    FROM   grac_practice.organization_dependency_vendor v
    LEFT   JOIN grac_practice.dependency_service_category_master sc ON sc.service_category_id = v.service_category_id
    LEFT   JOIN grac_practice.criticality_master cm ON cm.criticality_id = v.criticality_id
    LEFT   JOIN grac_practice.organization_employee ro ON ro.employee_id = v.relationship_owner_id
    LEFT   JOIN grac_practice.tprm_third_party t ON t.vendor_id = v.vendor_id
    OUTER  APPLY (SELECT TOP (1) x.third_party_id, x.third_party_code, x.legal_name
                  FROM grac_practice.tprm_third_party x
                  WHERE t.third_party_id IS NULL AND x.organization_id = @organization_id AND x.vendor_id IS NULL
                    AND x.status = N'Active' AND x.normalized_name = grac_practice.fn_tprm_normalize_name(v.vendor_name)) sug
    WHERE  v.organization_id = @organization_id
      AND  v.status = N'Active'
      AND  (ISNULL(@only_unlinked, 0) = 0 OR t.third_party_id IS NULL)
      AND  (@s IS NULL OR v.vendor_name LIKE N'%' + @s + N'%')
    ORDER  BY CASE WHEN t.third_party_id IS NULL THEN 0 ELSE 1 END, v.vendor_name;
END
GO

-- Bring a GRAC vendor into TPRM without re-entering it: create a third
-- party from it (or link it to an existing one) and, optionally, an
-- "existing relationship" engagement whose exposure is discovered at once.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_vendor_import
    @organization_id    BIGINT,
    @vendor_id          BIGINT,
    @third_party_id     BIGINT        = NULL,     -- link to this third party instead of creating one
    @create_engagement  BIT           = 1,
    @confirm_duplicates BIT           = 0,
    @actor_employee_id  BIGINT        = NULL,
    @actor              NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @vname NVARCHAR(220), @owner BIGINT, @cstart DATE, @cend DATE, @renew DATE, @crit NVARCHAR(40), @cat NVARCHAR(160);
    SELECT @vname = v.vendor_name, @owner = v.relationship_owner_id, @cstart = v.contract_start_dt, @cend = v.contract_end_dt,
           @renew = v.renewal_dt, @crit = UPPER(cm.criticality_code), @cat = sc.service_category_name
    FROM   grac_practice.organization_dependency_vendor v
    LEFT   JOIN grac_practice.criticality_master cm ON cm.criticality_id = v.criticality_id
    LEFT   JOIN grac_practice.dependency_service_category_master sc ON sc.service_category_id = v.service_category_id
    WHERE  v.vendor_id = @vendor_id AND v.organization_id = @organization_id AND v.status = N'Active';
    IF @vname IS NULL THROW 57620, 'That vendor was not found in this organization.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_third_party WHERE vendor_id = @vendor_id)
        THROW 57621, 'That vendor is already linked to a third party.', 1;
    IF @owner IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                          WHERE employee_id = @owner AND organization_id = @organization_id AND status = N'Active')
        SET @owner = NULL;

    -- Category: a SERVICE_CATEGORY value whose label matches the vendor's
    -- category, else OTHER.
    DECLARE @cat_code NVARCHAR(60) = (SELECT TOP (1) value_code FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                       WHERE list_code = N'SERVICE_CATEGORY' AND label = @cat);
    IF @cat_code IS NULL SET @cat_code = (SELECT TOP (1) value_code FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                          WHERE list_code = N'SERVICE_CATEGORY' ORDER BY CASE WHEN value_code = N'OTHER' THEN 0 ELSE 1 END, display_order DESC);
    DECLARE @crit_code NVARCHAR(60) = (SELECT TOP (1) value_code FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                        WHERE list_code = N'CRITICALITY' AND value_code = @crit);

    IF @third_party_id IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party WHERE third_party_id = @third_party_id
                         AND organization_id = @organization_id AND status = N'Active')
            THROW 57601, 'That third party was not found.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_third_party WHERE third_party_id = @third_party_id AND vendor_id IS NOT NULL)
            THROW 57622, 'That third party is already linked to another vendor.', 1;
    END
    ELSE IF ISNULL(@confirm_duplicates, 0) = 0
       AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_third_party_matches(@organization_id, @vname, NULL, NULL, NULL, NULL, NULL) m
                    WHERE m.match_kind = N'THIRD_PARTY')
    BEGIN
        SELECT CAST(NULL AS BIGINT) AS ThirdPartyId, CAST(NULL AS BIGINT) AS EngagementId, N'DUPLICATES' AS Result;
        SELECT m.match_kind AS MatchKind, m.match_id AS MatchId, m.match_code AS MatchCode, m.match_name AS MatchName, m.match_reason AS MatchReason
        FROM grac_practice.fn_tprm_third_party_matches(@organization_id, @vname, NULL, NULL, NULL, NULL, NULL) m
        WHERE m.match_kind = N'THIRD_PARTY';
        RETURN;
    END

    DECLARE @tp BIGINT = @third_party_id, @eng BIGINT;
    BEGIN TRAN;
    IF @tp IS NULL
    BEGIN
        DECLARE @next INT, @code NVARCHAR(20);
        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(third_party_code, 4, 20))), 0) + 1
        FROM   grac_practice.tprm_third_party WITH (UPDLOCK, HOLDLOCK)
        WHERE  organization_id = @organization_id AND third_party_code LIKE N'TP-%';
        SET @code = N'TP-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_third_party
            (organization_id, third_party_code, legal_name, normalized_name, primary_service_category_code, lifecycle_status_code,
             relationship_owner_employee_id, vendor_id, profile_notes, entered_by)
        VALUES (@organization_id, @code, @vname, grac_practice.fn_tprm_normalize_name(@vname), @cat_code,
                ISNULL(grac_practice.fn_tprm_meaning_code(@organization_id, N'TP_STATUS', N'PROSPECTIVE'), N'PROSPECTIVE'),
                @owner, @vendor_id, N'Created from the GRAC vendor register.', @actor);
        SET @tp = SCOPE_IDENTITY();
        INSERT grac_practice.tprm_third_party_category (third_party_id, service_category_code) VALUES (@tp, @cat_code);
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        SELECT @tp, NULL, lifecycle_status_code, N'Created from the GRAC vendor register.', 0, @actor_employee_id, @actor
        FROM grac_practice.tprm_third_party WHERE third_party_id = @tp;
    END
    ELSE
        UPDATE grac_practice.tprm_third_party SET vendor_id = @vendor_id, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE third_party_id = @tp;

    IF ISNULL(@create_engagement, 0) = 1
    BEGIN
        DECLARE @enext INT, @ecode NVARCHAR(20);
        SELECT @enext = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(engagement_code, 5, 20))), 0) + 1
        FROM   grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK)
        WHERE  organization_id = @organization_id AND engagement_code LIKE N'ENG-%';
        SET @ecode = N'ENG-' + FORMAT(@enext, '000');
        INSERT grac_practice.tprm_engagement
            (organization_id, third_party_id, engagement_code, engagement_title, service_description, service_category_code,
             engagement_type_code, is_existing, proposed_start_dt, proposed_end_dt, actual_start_dt, renewal_dt,
             relationship_owner_employee_id, service_criticality_code, stage_code, entered_by)
        VALUES (@organization_id, @tp, @ecode, LEFT(CONCAT(N'Existing relationship - ', @vname), 250),
                N'Existing service relationship brought in from the GRAC vendor register. Complete the scope before assessing.',
                @cat_code, (SELECT TOP (1) value_code FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                             WHERE list_code = N'ENGAGEMENT_TYPE' AND value_code = N'ONGOING'),
                1, @cstart, @cend, @cstart, @renew, @owner, @crit_code, N'SCOPING', @actor);
        SET @eng = SCOPE_IDENTITY();
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source,
                                                   is_validated, validated_by, validated_dt, entered_by)
        VALUES (@eng, @organization_id, N'VENDOR', @vendor_id, @vname, N'DISCOVERED', 1, @actor, SYSUTCDATETIME(), @actor);
        EXEC grac_practice.sp_tprm_engagement_event @eng, N'CREATED', NULL, N'SCOPING', N'Existing relationship imported from the vendor register.', @actor_employee_id, @actor;
    END
    COMMIT;

    EXEC grac_practice.sp_tprm_third_party_sync_status @tp, @actor;
    EXEC grac_practice.sp_tprm_audit N'tprm-third-party', @tp, N'VENDOR_IMPORT', @vname, @actor;
    SELECT @tp AS ThirdPartyId, @eng AS EngagementId, N'IMPORTED' AS Result;
END
GO

-- BRD 5.2: load the six illustrative records into an organization. They
-- are named "SAMPLE - ... Example", flagged is_sample, and stop at
-- SCOPING with their proposed exposure -- never presented as completed
-- assessments of real providers. Re-running skips samples already loaded.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_sample_load
    @organization_id   BIGINT,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 57600, 'Select an organization.', 1;

    DECLARE @loaded INT = 0, @code NVARCHAR(60), @tp BIGINT, @eng BIGINT, @next INT, @tcode NVARCHAR(20), @ecode NVARCHAR(20);
    DECLARE @prospective NVARCHAR(60) = ISNULL(grac_practice.fn_tprm_meaning_code(@organization_id, N'TP_STATUS', N'PROSPECTIVE'), N'PROSPECTIVE');
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT p.sample_code FROM grac_practice.tprm_sample_profile p
        WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party t
                           WHERE t.organization_id = @organization_id AND t.is_sample = 1 AND t.legal_name = p.legal_name)
        ORDER BY p.display_order;
    OPEN c;
    FETCH NEXT FROM c INTO @code;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRAN;
        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(third_party_code, 4, 20))), 0) + 1
        FROM grac_practice.tprm_third_party WITH (UPDLOCK, HOLDLOCK)
        WHERE organization_id = @organization_id AND third_party_code LIKE N'TP-%';
        SET @tcode = N'TP-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_third_party
            (organization_id, third_party_code, legal_name, normalized_name, provider_type_code, primary_service_category_code,
             country, lifecycle_status_code, profile_notes, is_sample, entered_by)
        SELECT @organization_id, @tcode, p.legal_name, grac_practice.fn_tprm_normalize_name(p.legal_name), p.provider_type_code,
               p.service_category_code, p.country, @prospective,
               CONCAT(N'Illustrative sample record - not a real provider and not a completed assessment. ', p.notes),
               1, @actor
        FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        SET @tp = SCOPE_IDENTITY();
        INSERT grac_practice.tprm_third_party_category (third_party_id, service_category_code)
        SELECT @tp, p.service_category_code FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        VALUES (@tp, NULL, @prospective, N'Sample record loaded.', 0, @actor_employee_id, @actor);

        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(engagement_code, 5, 20))), 0) + 1
        FROM grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK)
        WHERE organization_id = @organization_id AND engagement_code LIKE N'ENG-%';
        SET @ecode = N'ENG-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_engagement
            (organization_id, third_party_id, engagement_code, engagement_title, service_description, scope_description, business_purpose,
             service_category_code, engagement_type_code, service_model_code, delivery_locations, is_existing, service_criticality_code,
             data_exposure_code, rto_hours, rpo_hours, notes, is_sample, stage_code, entered_by)
        SELECT @organization_id, @tp, @ecode, p.engagement_title, p.service_description, p.scope_description, p.business_purpose,
               p.service_category_code, p.engagement_type_code, p.service_model_code, p.country, 0, p.criticality_code,
               p.data_exposure_code, p.rto_hours, p.rpo_hours,
               CONCAT(N'Sample guidance -- key safeguards: ', p.key_safeguards, N'. Evidence expected: ', p.evidence_expectations,
                      N'. Review triggers: ', p.review_triggers, N'.'),
               1, N'SCOPING', @actor
        FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        SET @eng = SCOPE_IDENTITY();

        INSERT grac_practice.tprm_engagement_scope (engagement_id, organization_id, item_kind, exposure_mode, item_code, item_name, entered_by)
        SELECT @eng, @organization_id, N'DATA_CATEGORY', N'PROPOSED', p.data_exposure_code,
               ISNULL((SELECT TOP (1) label FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                        WHERE list_code = N'DATA_EXPOSURE' AND value_code = p.data_exposure_code), p.data_exposure_code), @actor
        FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code AND p.data_exposure_code IS NOT NULL;
        INSERT grac_practice.tprm_engagement_scope (engagement_id, organization_id, item_kind, exposure_mode, item_code, item_name, entered_by)
        SELECT @eng, @organization_id, N'ACCESS', N'PROPOSED', a.code,
               ISNULL((SELECT TOP (1) label FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                        WHERE list_code = N'ACCESS_CATEGORY' AND value_code = a.code), a.code), @actor
        FROM grac_practice.tprm_sample_profile p
        CROSS APPLY grac_practice.fn_tprm_split_codes(p.access_codes) a
        WHERE p.sample_code = @code;
        -- fourth parties: name|category|country;...
        INSERT grac_practice.tprm_engagement_scope (engagement_id, organization_id, item_kind, exposure_mode, item_code, item_name, country, entered_by)
        SELECT @eng, @organization_id, N'FOURTH_PARTY', N'PROPOSED',
               NULLIF(PARSENAME(REPLACE(REPLACE(f.value, N'.', N' '), N'|', N'.'), 2), N''),
               LEFT(PARSENAME(REPLACE(REPLACE(f.value, N'.', N' '), N'|', N'.'), 3), 300),
               NULLIF(PARSENAME(REPLACE(REPLACE(f.value, N'.', N' '), N'|', N'.'), 1), N''), @actor
        FROM grac_practice.tprm_sample_profile p
        CROSS APPLY STRING_SPLIT(ISNULL(p.fourth_parties, N''), N';') f
        WHERE p.sample_code = @code AND LTRIM(RTRIM(f.value)) <> N''
          AND PARSENAME(REPLACE(REPLACE(f.value, N'.', N' '), N'|', N'.'), 3) IS NOT NULL;

        EXEC grac_practice.sp_tprm_engagement_event @eng, N'CREATED', NULL, N'SCOPING', N'Sample engagement loaded.', @actor_employee_id, @actor;
        COMMIT;
        EXEC grac_practice.sp_tprm_third_party_sync_status @tp, @actor;
        SET @loaded = @loaded + 1;
        FETCH NEXT FROM c INTO @code;
    END
    CLOSE c;
    DEALLOCATE c;

    EXEC grac_practice.sp_tprm_audit N'tprm-sample', @organization_id, N'LOAD', NULL, @actor;
    SELECT @loaded AS LoadedCount, N'LOADED' AS Result;
END
GO

-- =====================================================================
-- 9. Engagements
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_list
    @organization_id    BIGINT,
    @search             NVARCHAR(200) = NULL,
    @third_party_id     BIGINT        = NULL,
    @stage_code         NVARCHAR(30)  = NULL,   -- a stage, OPEN (not closed) or CLOSED
    @band_code          NVARCHAR(60)  = NULL,   -- residual band, else inherent
    @criticality_code   NVARCHAR(60)  = NULL,
    @owner_employee_id  BIGINT        = NULL,
    @attention          NVARCHAR(30)  = NULL,   -- REASSESS / REVIEW_DUE / MINE
    @caller_employee_id BIGINT        = NULL,
    @page_number        INT           = 1,
    @page_size          INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 57600, 'Select an organization.', 1;
    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');
    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());

    ;WITH ref AS (SELECT list_code, value_code, label, color_hex FROM grac_practice.fn_tprm_reference_effective(@organization_id))
    SELECT e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode, e.engagement_title AS EngagementTitle,
           e.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS ThirdPartyName,
           e.stage_code AS StageCode, e.stage_dt AS StageDt, e.is_existing AS IsExisting, e.is_sample AS IsSample,
           e.service_category_code AS ServiceCategoryCode, sc.label AS ServiceCategory,
           e.service_criticality_code AS CriticalityCode, cr.label AS Criticality, cr.color_hex AS CriticalityColor,
           e.inherent_score AS InherentScore, e.inherent_band_code AS InherentBandCode, ib.band_name AS InherentBand, ib.color_hex AS InherentBandColor,
           e.residual_score AS ResidualScore, e.residual_band_code AS ResidualBandCode, rb.band_name AS ResidualBand, rb.color_hex AS ResidualBandColor,
           e.dd_tier_code AS DdTierCode, dt.label AS DdTier,
           e.business_owner_employee_id AS BusinessOwnerEmployeeId, bo.employee_name AS BusinessOwnerName,
           e.next_review_dt AS NextReviewDt, e.reassessment_required AS ReassessmentRequired,
           e.proposed_end_dt AS ProposedEndDt, e.actual_end_dt AS ActualEndDt,
           COUNT(*) OVER () AS TotalRows
    FROM   grac_practice.tprm_engagement e
    JOIN   grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
    LEFT   JOIN ref sc ON sc.list_code = N'SERVICE_CATEGORY' AND sc.value_code = e.service_category_code
    LEFT   JOIN ref cr ON cr.list_code = N'CRITICALITY' AND cr.value_code = e.service_criticality_code
    LEFT   JOIN ref dt ON dt.list_code = N'DD_TIER' AND dt.value_code = e.dd_tier_code
    LEFT   JOIN grac_practice.tprm_rm_band ib ON ib.version_id = e.risk_model_version_id AND ib.band_code = e.inherent_band_code
    LEFT   JOIN grac_practice.tprm_rm_band rb ON rb.version_id = e.risk_model_version_id AND rb.band_code = e.residual_band_code
    LEFT   JOIN grac_practice.organization_employee bo ON bo.employee_id = e.business_owner_employee_id
    WHERE  e.organization_id = @organization_id
      AND  (@third_party_id IS NULL OR e.third_party_id = @third_party_id)
      AND  (@stage_code IS NULL
            OR e.stage_code = @stage_code
            OR (@stage_code = N'OPEN' AND e.stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED'))
            OR (@stage_code = N'CLOSED' AND e.stage_code IN (N'EXITED', N'REJECTED', N'CANCELLED'))
            OR (@stage_code = N'IN_ASSESSMENT' AND e.stage_code IN (N'SCOPING', N'RISK_ASSESSED', N'DUE_DILIGENCE', N'PENDING_DECISION')))
      AND  (@band_code IS NULL OR COALESCE(e.residual_band_code, e.inherent_band_code) = @band_code)
      AND  (@criticality_code IS NULL OR e.service_criticality_code = @criticality_code)
      AND  (@owner_employee_id IS NULL OR @owner_employee_id IN (e.business_owner_employee_id, e.relationship_owner_employee_id, e.assessor_employee_id))
      AND  (@attention IS NULL
            OR (@attention = N'REASSESS' AND e.reassessment_required = 1)
            OR (@attention = N'REVIEW_DUE' AND e.next_review_dt IS NOT NULL AND e.next_review_dt <= DATEADD(DAY, 30, @today))
            OR (@attention = N'MINE' AND @caller_employee_id IN (e.business_owner_employee_id, e.relationship_owner_employee_id, e.assessor_employee_id)))
      AND  (@s IS NULL OR e.engagement_title LIKE N'%' + @s + N'%' OR e.engagement_code LIKE N'%' + @s + N'%'
            OR t.legal_name LIKE N'%' + @s + N'%'
            OR EXISTS (SELECT 1 FROM grac_practice.tprm_custom_field_value cv
                        JOIN grac_practice.tprm_custom_field cf ON cf.field_id = cv.field_id AND cf.is_searchable = 1
                        WHERE cv.entity_code = N'ENGAGEMENT' AND cv.record_id = e.engagement_id
                          AND cv.value_text LIKE N'%' + @s + N'%'))
    ORDER  BY CASE WHEN e.stage_code IN (N'EXITED', N'REJECTED', N'CANCELLED') THEN 1 ELSE 0 END,
              e.engagement_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Result sets: 1 header  2 scope  3 links  4 snapshots  5 history
--              6 custom values  7 dimensions of the current assessment
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_get
    @organization_id BIGINT,
    @engagement_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id)
        THROW 57630, 'That engagement was not found.', 1;

    ;WITH ref AS (SELECT list_code, value_code, label, color_hex FROM grac_practice.fn_tprm_reference_effective(@organization_id))
    SELECT e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode, e.engagement_title AS EngagementTitle,
           e.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS ThirdPartyName,
           t.vendor_id AS ThirdPartyVendorId, t.lifecycle_status_code AS ThirdPartyStatusCode, ts.label AS ThirdPartyStatus,
           e.service_description AS ServiceDescription, e.scope_description AS ScopeDescription, e.business_purpose AS BusinessPurpose,
           e.service_category_code AS ServiceCategoryCode, sc.label AS ServiceCategory,
           e.engagement_type_code AS EngagementTypeCode, et.label AS EngagementType,
           e.service_model_code AS ServiceModelCode, sm.label AS ServiceModel,
           e.delivery_locations AS DeliveryLocations, e.is_existing AS IsExisting,
           e.contract_id AS ContractId, e.contract_reference AS ContractReference, e.contract_value AS ContractValue,
           e.currency_code AS CurrencyCode, e.proposed_start_dt AS ProposedStartDt, e.proposed_end_dt AS ProposedEndDt,
           e.actual_start_dt AS ActualStartDt, e.actual_end_dt AS ActualEndDt, e.renewal_dt AS RenewalDt,
           e.business_owner_employee_id AS BusinessOwnerEmployeeId, bo.employee_name AS BusinessOwnerName,
           e.relationship_owner_employee_id AS RelationshipOwnerEmployeeId, ro.employee_name AS RelationshipOwnerName,
           e.assessor_employee_id AS AssessorEmployeeId, ae.employee_name AS AssessorName,
           e.service_criticality_code AS CriticalityCode, cr.label AS Criticality, cr.color_hex AS CriticalityColor,
           e.data_exposure_code AS DataExposureCode, de.label AS DataExposure,
           e.rto_hours AS RtoHours, e.rpo_hours AS RpoHours, e.sla_summary AS SlaSummary,
           e.stage_code AS StageCode, e.stage_dt AS StageDt,
           e.current_risk_assessment_id AS CurrentRiskAssessmentId, e.risk_model_version_id AS RiskModelVersionId,
           e.inherent_score AS InherentScore, e.inherent_band_code AS InherentBandCode, ib.band_name AS InherentBand, ib.color_hex AS InherentBandColor,
           e.dd_tier_code AS DdTierCode, dt.label AS DdTier,
           e.residual_score AS ResidualScore, e.residual_band_code AS ResidualBandCode, rb.band_name AS ResidualBand, rb.color_hex AS ResidualBandColor,
           e.acceptance_until AS AcceptanceUntil, e.next_review_dt AS NextReviewDt, e.last_review_dt AS LastReviewDt,
           e.reassessment_required AS ReassessmentRequired, e.reassessment_reason AS ReassessmentReason,
           e.notes AS Notes, e.is_sample AS IsSample, CONVERT(BIGINT, e.record_version) AS RecordVersion,
           (SELECT TOP (1) a.assessment_id FROM grac_practice.tprm_risk_assessment a
             WHERE a.engagement_id = e.engagement_id AND a.status = N'DRAFT') AS DraftRiskAssessmentId,
           e.entered_by AS EnteredBy, e.entered_dt AS EnteredDt, e.updated_by AS UpdatedBy, e.updated_dt AS UpdatedDt
    FROM   grac_practice.tprm_engagement e
    JOIN   grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
    LEFT   JOIN ref ts ON ts.list_code = N'TP_STATUS' AND ts.value_code = t.lifecycle_status_code
    LEFT   JOIN ref sc ON sc.list_code = N'SERVICE_CATEGORY' AND sc.value_code = e.service_category_code
    LEFT   JOIN ref et ON et.list_code = N'ENGAGEMENT_TYPE' AND et.value_code = e.engagement_type_code
    LEFT   JOIN ref sm ON sm.list_code = N'SERVICE_MODEL' AND sm.value_code = e.service_model_code
    LEFT   JOIN ref cr ON cr.list_code = N'CRITICALITY' AND cr.value_code = e.service_criticality_code
    LEFT   JOIN ref de ON de.list_code = N'DATA_EXPOSURE' AND de.value_code = e.data_exposure_code
    LEFT   JOIN ref dt ON dt.list_code = N'DD_TIER' AND dt.value_code = e.dd_tier_code
    LEFT   JOIN grac_practice.tprm_rm_band ib ON ib.version_id = e.risk_model_version_id AND ib.band_code = e.inherent_band_code
    LEFT   JOIN grac_practice.tprm_rm_band rb ON rb.version_id = e.risk_model_version_id AND rb.band_code = e.residual_band_code
    LEFT   JOIN grac_practice.organization_employee bo ON bo.employee_id = e.business_owner_employee_id
    LEFT   JOIN grac_practice.organization_employee ro ON ro.employee_id = e.relationship_owner_employee_id
    LEFT   JOIN grac_practice.organization_employee ae ON ae.employee_id = e.assessor_employee_id
    WHERE  e.engagement_id = @engagement_id;

    SELECT s.scope_item_id AS ScopeItemId, s.item_kind AS ItemKind, s.exposure_mode AS ExposureMode, s.ref_id AS RefId,
           s.item_code AS ItemCode, s.item_name AS ItemName, s.criticality_code AS CriticalityCode, s.country AS Country,
           s.is_critical AS IsCritical, s.notes AS Notes, s.entered_by AS EnteredBy, s.entered_dt AS EnteredDt
    FROM   grac_practice.tprm_engagement_scope s
    WHERE  s.engagement_id = @engagement_id AND s.status = N'Active'
    ORDER  BY s.exposure_mode, s.item_kind, s.item_name;

    SELECT l.link_id AS LinkId, l.link_kind AS LinkKind, l.target_id AS TargetId, l.target_label AS TargetLabel,
           l.link_source AS LinkSource, l.is_validated AS IsValidated, l.validated_by AS ValidatedBy, l.validated_dt AS ValidatedDt,
           l.note AS Note, l.status AS Status, l.entered_by AS EnteredBy, l.entered_dt AS EnteredDt
    FROM   grac_practice.tprm_engagement_link l
    WHERE  l.engagement_id = @engagement_id AND l.status = N'Active'
    ORDER  BY l.link_kind, l.target_label;

    SELECT s.snapshot_id AS SnapshotId, s.snapshot_kind AS SnapshotKind, s.summary_json AS SummaryJson,
           s.taken_by AS TakenBy, s.taken_dt AS TakenDt
    FROM   grac_practice.tprm_exposure_snapshot s
    WHERE  s.engagement_id = @engagement_id
    ORDER  BY s.snapshot_id DESC;

    SELECT h.history_id AS HistoryId, h.event_code AS EventCode, h.from_stage_code AS FromStageCode, h.to_stage_code AS ToStageCode,
           h.detail AS Detail, h.actor AS Actor, ae.employee_name AS ActorName, h.event_dt AS EventDt
    FROM   grac_practice.tprm_engagement_history h
    LEFT   JOIN grac_practice.organization_employee ae ON ae.employee_id = h.actor_employee_id
    WHERE  h.engagement_id = @engagement_id
    ORDER  BY h.history_id DESC;

    SELECT cv.field_id AS FieldId, cv.field_code AS FieldCode, cv.label AS Label, cv.data_type AS DataType, cv.value_string AS Value
    FROM   grac_practice.fn_tprm_custom_values(@organization_id, N'ENGAGEMENT', @engagement_id) cv;

    SELECT d.dimension_code AS DimensionCode, md.dimension_name AS DimensionName, d.weight AS Weight,
           d.inherent_score AS InherentScore, d.reduction_pct AS ReductionPct, d.uplift_pct AS UpliftPct,
           d.residual_score AS ResidualScore, d.safeguard_summary AS SafeguardSummary
    FROM   grac_practice.tprm_engagement e
    JOIN   grac_practice.tprm_risk_assessment_dimension d ON d.assessment_id = e.current_risk_assessment_id
    JOIN   grac_practice.tprm_rm_dimension md ON md.dimension_id = d.dimension_id
    WHERE  e.engagement_id = @engagement_id
    ORDER  BY md.display_order;
END
GO

-- Create / update an engagement (BRD step 2). On an ACTIVE engagement a
-- change of criticality, data exposure, service model or delivery
-- locations is a MATERIAL CHANGE: it is logged and the engagement is
-- flagged for reassessment (BRD step 5 / section 4); 489's monitoring
-- sweep opens the triggered review.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_save
    @organization_id               BIGINT,
    @engagement_id                 BIGINT         = NULL,
    @third_party_id                BIGINT         = NULL,
    @engagement_title              NVARCHAR(250),
    @service_description           NVARCHAR(2000) = NULL,
    @scope_description             NVARCHAR(2000) = NULL,
    @business_purpose              NVARCHAR(1000) = NULL,
    @service_category_code         NVARCHAR(60)   = NULL,
    @engagement_type_code          NVARCHAR(60)   = NULL,
    @service_model_code            NVARCHAR(60)   = NULL,
    @delivery_locations            NVARCHAR(1000) = NULL,
    @is_existing                   BIT            = 0,
    @contract_id                   BIGINT         = NULL,
    @contract_reference            NVARCHAR(200)  = NULL,
    @contract_value                DECIMAL(19,2)  = NULL,
    @currency_code                 NVARCHAR(10)   = NULL,
    @proposed_start_dt             DATE           = NULL,
    @proposed_end_dt               DATE           = NULL,
    @actual_start_dt               DATE           = NULL,
    @actual_end_dt                 DATE           = NULL,
    @renewal_dt                    DATE           = NULL,
    @business_owner_employee_id    BIGINT         = NULL,
    @relationship_owner_employee_id BIGINT        = NULL,
    @assessor_employee_id          BIGINT         = NULL,
    @service_criticality_code      NVARCHAR(60)   = NULL,
    @data_exposure_code            NVARCHAR(60)   = NULL,
    @rto_hours                     INT            = NULL,
    @rpo_hours                     INT            = NULL,
    @sla_summary                   NVARCHAR(2000) = NULL,
    @notes                         NVARCHAR(MAX)  = NULL,
    @custom_json                   NVARCHAR(MAX)  = NULL,
    @expected_record_version       BIGINT         = NULL,
    @caller_role_names             NVARCHAR(600)  = NULL,
    @caller_is_admin               BIT            = 0,
    @actor_employee_id             BIGINT         = NULL,
    @actor                         NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL THROW 57600, 'Select an organization.', 1;
    SET @engagement_title = NULLIF(LTRIM(RTRIM(@engagement_title)), N'');
    IF @engagement_title IS NULL THROW 57631, 'Engagement title is required.', 1;
    IF @service_criticality_code IS NULL THROW 57632, 'Choose the service criticality.', 1;

    DECLARE @bad NVARCHAR(200);
    SELECT TOP (1) @bad = x.what FROM (VALUES
        (N'SERVICE_CATEGORY', @service_category_code, N'service category'),
        (N'ENGAGEMENT_TYPE',  @engagement_type_code,  N'engagement type'),
        (N'SERVICE_MODEL',    @service_model_code,    N'service model'),
        (N'CRITICALITY',      @service_criticality_code, N'criticality'),
        (N'DATA_EXPOSURE',    @data_exposure_code,    N'data exposure')) x(list_code, code, what)
    WHERE x.code IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
                       WHERE r.list_code = x.list_code AND r.value_code = x.code);
    IF @bad IS NOT NULL
    BEGIN
        DECLARE @bad_msg NVARCHAR(300) = CONCAT(N'Choose a ', @bad, N' from the list.');
        THROW 57633, @bad_msg, 1;
    END
    IF EXISTS (SELECT 1 FROM (VALUES (@business_owner_employee_id), (@relationship_owner_employee_id), (@assessor_employee_id)) x(id)
                WHERE x.id IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                   WHERE employee_id = x.id AND organization_id = @organization_id AND status = N'Active'))
        THROW 57634, 'Owners and assessor must be active employees of this organization.', 1;
    IF @proposed_end_dt IS NOT NULL AND @proposed_start_dt IS NOT NULL AND @proposed_end_dt < @proposed_start_dt
        THROW 57635, 'The proposed end date is before the start date.', 1;
    IF @actual_end_dt IS NOT NULL AND @actual_start_dt IS NOT NULL AND @actual_end_dt < @actual_start_dt
        THROW 57636, 'The actual end date is before the start date.', 1;
    IF (@rto_hours IS NOT NULL AND @rto_hours < 0) OR (@rpo_hours IS NOT NULL AND @rpo_hours < 0)
        THROW 57637, 'RTO and RPO cannot be negative.', 1;
    IF @contract_id IS NOT NULL
    BEGIN
        IF OBJECT_ID('grac_practice.asset_contract','U') IS NULL THROW 57638, 'Contracts are not available in this installation.', 1;
        DECLARE @contract_ok INT;
        EXEC sp_executesql N'SELECT @n = COUNT(*) FROM grac_practice.asset_contract WHERE contract_id = @c AND organization_id = @o;',
             N'@n INT OUTPUT, @c BIGINT, @o BIGINT', @n = @contract_ok OUTPUT, @c = @contract_id, @o = @organization_id;
        IF ISNULL(@contract_ok, 0) = 0 THROW 57638, 'That contract was not found in this organization.', 1;
    END

    DECLARE @id BIGINT = @engagement_id, @created BIT = 0, @stage NVARCHAR(30), @tp BIGINT;
    DECLARE @o_crit NVARCHAR(60), @o_data NVARCHAR(60), @o_model NVARCHAR(60), @o_loc NVARCHAR(1000);
    IF @id IS NOT NULL
    BEGIN
        DECLARE @rv BIGINT;
        SELECT @rv = CONVERT(BIGINT, record_version), @stage = stage_code, @tp = third_party_id,
               @o_crit = service_criticality_code, @o_data = data_exposure_code, @o_model = service_model_code, @o_loc = delivery_locations
        FROM grac_practice.tprm_engagement WHERE engagement_id = @id AND organization_id = @organization_id;
        IF @rv IS NULL THROW 57630, 'That engagement was not found.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 57639, 'Someone else changed this engagement. Reload and try again.', 1;
        IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED')
            THROW 57640, 'A closed engagement cannot be changed.', 1;
    END
    ELSE
    BEGIN
        SET @tp = @third_party_id;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party WHERE third_party_id = @tp
                         AND organization_id = @organization_id AND status = N'Active')
            THROW 57641, 'Choose a registered third party for the engagement.', 1;
    END

    BEGIN TRAN;
    IF @id IS NULL
    BEGIN
        DECLARE @next INT, @code NVARCHAR(20);
        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(engagement_code, 5, 20))), 0) + 1
        FROM   grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK)
        WHERE  organization_id = @organization_id AND engagement_code LIKE N'ENG-%';
        SET @code = N'ENG-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_engagement
            (organization_id, third_party_id, engagement_code, engagement_title, service_description, scope_description, business_purpose,
             service_category_code, engagement_type_code, service_model_code, delivery_locations, is_existing, contract_id,
             contract_reference, contract_value, currency_code, proposed_start_dt, proposed_end_dt, actual_start_dt, actual_end_dt,
             renewal_dt, business_owner_employee_id, relationship_owner_employee_id, assessor_employee_id, service_criticality_code,
             data_exposure_code, rto_hours, rpo_hours, sla_summary, notes, stage_code, entered_by)
        VALUES (@organization_id, @tp, @code, @engagement_title, @service_description, @scope_description, @business_purpose,
                @service_category_code, @engagement_type_code, @service_model_code, @delivery_locations, ISNULL(@is_existing, 0), @contract_id,
                @contract_reference, @contract_value, @currency_code, @proposed_start_dt, @proposed_end_dt, @actual_start_dt, @actual_end_dt,
                @renewal_dt, @business_owner_employee_id, @relationship_owner_employee_id, @assessor_employee_id, @service_criticality_code,
                @data_exposure_code, @rto_hours, @rpo_hours, @sla_summary, @notes, N'SCOPING', @actor);
        SET @id = SCOPE_IDENTITY();
        SET @created = 1;
        -- the third party's vendor (when there is one) is this engagement's vendor until told otherwise
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @id, @organization_id, N'VENDOR', t.vendor_id, v.vendor_name, N'DISCOVERED', @actor
        FROM grac_practice.tprm_third_party t
        JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id = t.vendor_id
        WHERE t.third_party_id = @tp;
    END
    ELSE
        UPDATE grac_practice.tprm_engagement
           SET engagement_title = @engagement_title, service_description = @service_description, scope_description = @scope_description,
               business_purpose = @business_purpose, service_category_code = @service_category_code,
               engagement_type_code = @engagement_type_code, service_model_code = @service_model_code,
               delivery_locations = @delivery_locations, is_existing = ISNULL(@is_existing, 0), contract_id = @contract_id,
               contract_reference = @contract_reference, contract_value = @contract_value, currency_code = @currency_code,
               proposed_start_dt = @proposed_start_dt, proposed_end_dt = @proposed_end_dt, actual_start_dt = @actual_start_dt,
               actual_end_dt = @actual_end_dt, renewal_dt = @renewal_dt, business_owner_employee_id = @business_owner_employee_id,
               relationship_owner_employee_id = @relationship_owner_employee_id, assessor_employee_id = @assessor_employee_id,
               service_criticality_code = @service_criticality_code, data_exposure_code = @data_exposure_code,
               rto_hours = @rto_hours, rpo_hours = @rpo_hours, sla_summary = @sla_summary, notes = @notes,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @id;

    -- custom-field access follows the caller's GRAC role (organization_employee.role_id)
    IF @caller_role_names IS NULL AND @actor_employee_id IS NOT NULL
        SELECT @caller_role_names = r.role_name FROM grac_practice.organization_employee e
        JOIN grac_practice.organization_role r ON r.role_id = e.role_id WHERE e.employee_id = @actor_employee_id;
    EXEC grac_practice.sp_tprm_custom_values_save @organization_id, N'ENGAGEMENT', @id, @custom_json,
         @caller_role_names, @caller_is_admin, @actor;

    DECLARE @material NVARCHAR(1000) = NULL;
    IF @created = 0 AND @stage IN (N'ACTIVE', N'SUSPENDED', N'ONBOARDING', N'APPROVED')
    BEGIN
        SET @material = CONCAT_WS(N'; ',
            CASE WHEN ISNULL(@o_crit, N'') <> ISNULL(@service_criticality_code, N'') THEN CONCAT(N'criticality ', @o_crit, N' -> ', @service_criticality_code) END,
            CASE WHEN ISNULL(@o_data, N'') <> ISNULL(@data_exposure_code, N'') THEN CONCAT(N'data exposure ', @o_data, N' -> ', @data_exposure_code) END,
            CASE WHEN ISNULL(@o_model, N'') <> ISNULL(@service_model_code, N'') THEN CONCAT(N'service model ', @o_model, N' -> ', @service_model_code) END,
            CASE WHEN ISNULL(@o_loc, N'') <> ISNULL(@delivery_locations, N'') THEN N'delivery locations changed' END);
        IF @material = N'' SET @material = NULL;
        IF @material IS NOT NULL
            UPDATE grac_practice.tprm_engagement
               SET reassessment_required = 1,
                   reassessment_reason = LEFT(CONCAT(N'Material change: ', @material), 1000)
             WHERE engagement_id = @id;
    END
    COMMIT;

    IF @created = 1
    BEGIN
        EXEC grac_practice.sp_tprm_engagement_event @id, N'CREATED', NULL, N'SCOPING', @engagement_title, @actor_employee_id, @actor;
        EXEC grac_practice.sp_tprm_third_party_sync_status @tp, @actor;
    END
    ELSE IF @material IS NOT NULL
    BEGIN
        DECLARE @mdetail NVARCHAR(2000) = CONCAT(N'Material change: ', @material);
        EXEC grac_practice.sp_tprm_engagement_event @id, N'MATERIAL_CHANGE', @stage, @stage, @mdetail, @actor_employee_id, @actor;
    END
    ELSE
        EXEC grac_practice.sp_tprm_engagement_event @id, N'UPDATED', @stage, @stage, NULL, @actor_employee_id, @actor;

    SELECT @id AS EngagementId, CASE WHEN @created = 1 THEN N'CREATED' WHEN @material IS NOT NULL THEN N'MATERIAL_CHANGE' ELSE N'SAVED' END AS Result;
END
GO

-- =====================================================================
-- 10. Scope items
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_scope_item_save
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @scope_item_id     BIGINT         = NULL,
    @item_kind         NVARCHAR(30),
    @exposure_mode     NVARCHAR(20)   = N'PROPOSED',
    @ref_id            BIGINT         = NULL,
    @item_code         NVARCHAR(60)   = NULL,
    @item_name         NVARCHAR(300)  = NULL,
    @criticality_code  NVARCHAR(60)   = NULL,
    @country           NVARCHAR(120)  = NULL,
    @is_critical       BIT            = 0,
    @notes             NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30) = (SELECT stage_code FROM grac_practice.tprm_engagement
                                    WHERE engagement_id = @engagement_id AND organization_id = @organization_id);
    IF @stage IS NULL THROW 57630, 'That engagement was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;
    IF @item_kind NOT IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION', N'DATA_CATEGORY', N'ACCESS', N'LOCATION', N'FOURTH_PARTY')
        THROW 57642, 'Unknown scope item type.', 1;
    IF ISNULL(@exposure_mode, N'') NOT IN (N'PROPOSED', N'ACTUAL') THROW 57643, 'Exposure must be proposed or actual.', 1;
    SET @item_code = NULLIF(LTRIM(RTRIM(@item_code)), N'');
    SET @item_name = NULLIF(LTRIM(RTRIM(@item_name)), N'');

    -- GRAC objects are picked, not typed: resolve the name from the record.
    IF @item_kind = N'BUSINESS_FUNCTION' AND @ref_id IS NOT NULL
        SELECT @item_name = function_name FROM grac_practice.organization_business_function
         WHERE business_function_id = @ref_id AND organization_id = @organization_id;
    ELSE IF @item_kind = N'PROCESS' AND @ref_id IS NOT NULL
        SELECT @item_name = process_name FROM grac_practice.organization_dependency_process
         WHERE process_id = @ref_id AND organization_id = @organization_id;
    ELSE IF @item_kind = N'APPLICATION' AND @ref_id IS NOT NULL
        SELECT @item_name = application_name FROM grac_practice.organization_dependency_application
         WHERE application_id = @ref_id AND organization_id = @organization_id;
    ELSE IF @item_kind = N'FOURTH_PARTY' AND @ref_id IS NOT NULL
        SELECT @item_name = COALESCE(@item_name, legal_name) FROM grac_practice.tprm_third_party
         WHERE third_party_id = @ref_id AND organization_id = @organization_id;

    IF @item_kind IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION') AND @ref_id IS NULL AND @item_name IS NULL
        THROW 57644, 'Pick the GRAC record or name the item.', 1;
    IF @item_kind IN (N'DATA_CATEGORY', N'ACCESS')
    BEGIN
        DECLARE @list NVARCHAR(60) = CASE @item_kind WHEN N'DATA_CATEGORY' THEN N'DATA_EXPOSURE' ELSE N'ACCESS_CATEGORY' END;
        SELECT @item_name = COALESCE(@item_name, label) FROM grac_practice.fn_tprm_reference_effective(@organization_id)
         WHERE list_code = @list AND value_code = @item_code;
        IF @item_code IS NULL OR @item_name IS NULL THROW 57645, 'Choose a value from the list.', 1;
    END
    IF @item_kind = N'FOURTH_PARTY' AND @item_code IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                        WHERE list_code = N'FOURTH_PARTY_CATEGORY' AND value_code = @item_code)
        THROW 57645, 'Choose a value from the list.', 1;
    IF @item_name IS NULL THROW 57646, 'The item needs a name.', 1;

    IF @scope_item_id IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope
                    WHERE engagement_id = @engagement_id AND item_kind = @item_kind AND exposure_mode = @exposure_mode
                      AND status = N'Active'
                      AND ((@ref_id IS NOT NULL AND ref_id = @ref_id) OR (@item_code IS NOT NULL AND item_code = @item_code AND @item_kind IN (N'DATA_CATEGORY', N'ACCESS'))
                           OR (@ref_id IS NULL AND @item_kind NOT IN (N'DATA_CATEGORY', N'ACCESS') AND item_name = @item_name)))
            THROW 57647, 'That item is already in the scope.', 1;
        INSERT grac_practice.tprm_engagement_scope
            (engagement_id, organization_id, item_kind, exposure_mode, ref_id, item_code, item_name, criticality_code, country,
             is_critical, notes, entered_by)
        VALUES (@engagement_id, @organization_id, @item_kind, @exposure_mode, @ref_id, @item_code, @item_name, @criticality_code,
                @country, ISNULL(@is_critical, 0), @notes, @actor);
        SET @scope_item_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope WHERE scope_item_id = @scope_item_id AND engagement_id = @engagement_id)
            THROW 57648, 'That scope item was not found.', 1;
        UPDATE grac_practice.tprm_engagement_scope
           SET item_kind = @item_kind, exposure_mode = @exposure_mode, ref_id = @ref_id, item_code = @item_code, item_name = @item_name,
               criticality_code = @criticality_code, country = @country, is_critical = ISNULL(@is_critical, 0), notes = @notes,
               status = N'Active', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE scope_item_id = @scope_item_id;
    END

    -- On a live engagement a change of data / access / location / fourth
    -- party in the ACTUAL exposure is a reassessment trigger (BRD 4).
    IF @stage IN (N'ACTIVE', N'SUSPENDED') AND @exposure_mode = N'ACTUAL'
       AND @item_kind IN (N'DATA_CATEGORY', N'ACCESS', N'LOCATION', N'FOURTH_PARTY')
    BEGIN
        UPDATE grac_practice.tprm_engagement
           SET reassessment_required = 1,
               reassessment_reason = LEFT(CONCAT(N'Scope change: ', @item_kind, N' ', @item_name), 1000)
         WHERE engagement_id = @engagement_id;
        DECLARE @sdetail NVARCHAR(2000) = CONCAT(N'Scope change: ', @item_kind, N' ', @item_name);
        EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'SCOPE_CHANGE', @stage, @stage, @sdetail, @actor_employee_id, @actor;
    END
    ELSE
    BEGIN
        DECLARE @adetail NVARCHAR(2000) = CONCAT(@exposure_mode, N' ', @item_kind, N': ', @item_name);
        EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'SCOPE_SAVED', @stage, @stage, @adetail, @actor_employee_id, @actor;
    END
    SELECT @scope_item_id AS ScopeItemId, N'SAVED' AS Result;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_scope_item_remove
    @organization_id   BIGINT,
    @scope_item_id     BIGINT,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @eng BIGINT, @stage NVARCHAR(30), @kind NVARCHAR(30), @name NVARCHAR(300), @mode NVARCHAR(20);
    SELECT @eng = s.engagement_id, @stage = e.stage_code, @kind = s.item_kind, @name = s.item_name, @mode = s.exposure_mode
    FROM grac_practice.tprm_engagement_scope s
    JOIN grac_practice.tprm_engagement e ON e.engagement_id = s.engagement_id
    WHERE s.scope_item_id = @scope_item_id AND s.organization_id = @organization_id AND s.status = N'Active';
    IF @eng IS NULL THROW 57648, 'That scope item was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;

    UPDATE grac_practice.tprm_engagement_scope SET status = N'Removed', updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE scope_item_id = @scope_item_id;
    IF @stage IN (N'ACTIVE', N'SUSPENDED') AND @mode = N'ACTUAL' AND @kind IN (N'DATA_CATEGORY', N'ACCESS', N'LOCATION', N'FOURTH_PARTY')
        UPDATE grac_practice.tprm_engagement
           SET reassessment_required = 1, reassessment_reason = LEFT(CONCAT(N'Scope change: ', @kind, N' ', @name, N' removed'), 1000)
         WHERE engagement_id = @eng;
    DECLARE @detail NVARCHAR(2000) = CONCAT(@mode, N' ', @kind, N' removed: ', @name);
    EXEC grac_practice.sp_tprm_engagement_event @eng, N'SCOPE_REMOVED', @stage, @stage, @detail, @actor_employee_id, @actor;
    SELECT @scope_item_id AS ScopeItemId, N'REMOVED' AS Result;
END
GO

-- =====================================================================
-- 11. Discovery of existing exposure (BRD step 2, acceptance 3 / 4)
--     Vendors = the third party's vendor + the engagement's VENDOR links.
--     Everything else is found through GRAC's own relationships:
--       practice instances  resolved Vendor dependency (142)
--       applications        organization_dependency_application.vendor_id,
--                           and the instances that depend on them
--       practices / obligations of those instances (140 / 307)
--       assurance findings  observations on the vendor or the instances
--       gaps                practice_gap of the instances (245)
--       risks               risk_register.linked_vendor_id
--       contracts           asset_contract.vendor_id (434, when present)
--     @persist = 1 records the instances, dependency resolutions,
--     applications, contracts and risks as DISCOVERED links (not
--     validated) and a DISCOVERED snapshot. Nothing in GRAC is changed.
-- Result sets: 1 summary  2 practice instances  3 obligations
--   4 dependencies (applications + resolutions)  5 assurance findings
--   6 gaps  7 risks  8 contracts
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_discover
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @persist           BIT           = 0,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tp BIGINT, @stage NVARCHAR(30);
    SELECT @tp = third_party_id, @stage = stage_code FROM grac_practice.tprm_engagement
     WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @tp IS NULL THROW 57630, 'That engagement was not found.', 1;

    DECLARE @vendor_type INT = (SELECT TOP (1) dependency_type_id FROM grac_practice.dependency_type_master WHERE dependency_type_code = N'Vendor');
    DECLARE @app_type    INT = (SELECT TOP (1) dependency_type_id FROM grac_practice.dependency_type_master WHERE dependency_type_code = N'Application');

    -- temp table (not a table variable): the optional contract read below
    -- is dynamic SQL and must see it.
    CREATE TABLE #v (vendor_id BIGINT PRIMARY KEY);
    INSERT #v SELECT vendor_id FROM grac_practice.tprm_third_party WHERE third_party_id = @tp AND vendor_id IS NOT NULL;
    INSERT #v SELECT DISTINCT l.target_id FROM grac_practice.tprm_engagement_link l
     WHERE l.engagement_id = @engagement_id AND l.link_kind = N'VENDOR' AND l.status = N'Active'
       AND NOT EXISTS (SELECT 1 FROM #v x WHERE x.vendor_id = l.target_id);

    DECLARE @apps TABLE (application_id BIGINT PRIMARY KEY, application_name NVARCHAR(220));
    INSERT @apps SELECT a.application_id, a.application_name FROM grac_practice.organization_dependency_application a
     JOIN #v v ON v.vendor_id = a.vendor_id
     WHERE a.organization_id = @organization_id AND a.status = N'Active';

    -- instances: directly on the vendor, or through an application of the vendor
    DECLARE @pi TABLE (practice_instance_id BIGINT PRIMARY KEY, via NVARCHAR(20), resolution_id BIGINT);
    INSERT @pi (practice_instance_id, via, resolution_id)
    SELECT r.practice_instance_id, N'VENDOR', MIN(r.resolution_id)
    FROM   grac_practice.practice_dependency_resolution r
    JOIN   #v v ON v.vendor_id = r.resolved_dependency_id
    WHERE  r.organization_id = @organization_id AND r.dependency_type_id = @vendor_type AND r.is_active = 1
    GROUP  BY r.practice_instance_id;
    INSERT @pi (practice_instance_id, via, resolution_id)
    SELECT r.practice_instance_id, N'APPLICATION', MIN(r.resolution_id)
    FROM   grac_practice.practice_dependency_resolution r
    JOIN   @apps a ON a.application_id = r.resolved_dependency_id
    WHERE  r.organization_id = @organization_id AND r.dependency_type_id = @app_type AND r.is_active = 1
      AND  NOT EXISTS (SELECT 1 FROM @pi x WHERE x.practice_instance_id = r.practice_instance_id)
    GROUP  BY r.practice_instance_id;

    DECLARE @counts TABLE (k NVARCHAR(40), n INT);

    -- 2 practice instances
    SELECT pi.practice_instance_id AS PracticeInstanceId, pi.instance_code AS InstanceCode, pi.instance_name AS InstanceName,
           p.practice_id AS PracticeId, p.practice_code AS PracticeCode, p.practice_name AS PracticeName,
           pi.criticality AS Criticality, pi.implementation_status AS ImplementationStatus, pi.status AS Status,
           x.via AS Via, x.resolution_id AS ResolutionId,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                                    AND l.link_kind = N'PRACTICE_INSTANCE' AND l.target_id = pi.practice_instance_id AND l.status = N'Active')
                     THEN 1 ELSE 0 END AS BIT) AS IsLinked
    INTO   #instances
    FROM   @pi x
    JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = x.practice_instance_id
    JOIN   grac_practice.practice p ON p.practice_id = pi.practice_id;
    INSERT @counts SELECT N'PracticeInstances', COUNT(*) FROM #instances;
    INSERT @counts SELECT N'Practices', COUNT(DISTINCT PracticeId) FROM #instances;

    -- 3 obligations (instance obligations + practice-level obligations)
    SELECT N'INSTANCE' AS Level, pio.practice_instance_obligation_id AS ObligationRowId, pio.practice_instance_id AS PracticeInstanceId,
           i.InstanceCode, pio.obligation_name AS ObligationName, pio.obligation_type_code AS ObligationTypeCode,
           pio.execution_frequency AS ExecutionFrequency, pio.responsibility AS Responsibility
    INTO   #obligations
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   #instances i ON i.PracticeInstanceId = pio.practice_instance_id
    WHERE  pio.status = N'Active'
    UNION ALL
    SELECT N'PRACTICE', po.practice_obligation_id, NULL, NULL, po.obligation_name, po.obligation_type_code,
           po.execution_frequency, po.responsibility
    FROM   grac_practice.practice_obligation po
    WHERE  po.organization_id = @organization_id AND po.status = N'Active'
      AND  po.practice_id IN (SELECT DISTINCT PracticeId FROM #instances);
    INSERT @counts SELECT N'Obligations', COUNT(*) FROM #obligations;

    -- 4 dependencies: the vendor resolutions themselves, and the vendor's applications
    SELECT N'VENDOR_RESOLUTION' AS DependencyKind, r.resolution_id AS DependencyId, r.resolved_dependency_name AS DependencyName,
           r.practice_instance_id AS PracticeInstanceId, pi.instance_code AS InstanceCode, r.resolution_status AS ResolutionStatus
    INTO   #deps
    FROM   grac_practice.practice_dependency_resolution r
    JOIN   #v v ON v.vendor_id = r.resolved_dependency_id
    JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = r.practice_instance_id
    WHERE  r.organization_id = @organization_id AND r.dependency_type_id = @vendor_type AND r.is_active = 1
    UNION ALL
    SELECT N'APPLICATION', a.application_id, a.application_name, NULL, NULL, NULL
    FROM   @apps a;
    INSERT @counts SELECT N'Dependencies', COUNT(*) FROM #deps;

    -- 5 assurance findings on the vendor or the instances
    SELECT o.org_assurance_observation_id AS ObservationId, o.observation_code AS ObservationCode, o.observation_title AS ObservationTitle,
           o.observation_type AS ObservationType, o.severity_code AS SeverityCode, o.severity_name AS SeverityName,
           sm.status_name AS StatusName, sm.is_terminal AS IsClosed, o.observed_dt AS ObservedDt,
           ee.dimension_code AS DimensionCode, ee.entity_name AS EntityName, o.execution_code AS ExecutionCode
    INTO   #findings
    FROM   grac_practice.org_assurance_observation o
    JOIN   grac_practice.org_assurance_execution_entity ee ON ee.org_assurance_execution_entity_id = o.org_assurance_execution_entity_id
    LEFT   JOIN grac_practice.org_assurance_observation_status_master sm ON sm.org_assurance_observation_status_id = o.observation_status_id
    WHERE  o.organization_id = @organization_id
      AND  ((ee.dimension_code = N'VENDOR' AND ee.entity_id IN (SELECT vendor_id FROM #v))
         OR (ee.dimension_code = N'PRACTICE_INSTANCE' AND ee.entity_id IN (SELECT PracticeInstanceId FROM #instances)));
    INSERT @counts SELECT N'AssuranceFindings', COUNT(*) FROM #findings;
    INSERT @counts SELECT N'OpenAssuranceFindings', COUNT(*) FROM #findings WHERE ISNULL(IsClosed, 0) = 0;

    -- 6 gaps of the instances
    SELECT g.practice_gap_id AS PracticeGapId, g.practice_instance_id AS PracticeInstanceId, i.InstanceCode, i.InstanceName,
           g.gap_status AS GapStatus, g.opened_dt AS OpenedDt, g.closed_dt AS ClosedDt
    INTO   #gaps
    FROM   grac_practice.practice_gap g
    JOIN   #instances i ON i.PracticeInstanceId = g.practice_instance_id;
    INSERT @counts SELECT N'OpenGaps', COUNT(*) FROM #gaps WHERE GapStatus = N'Open';

    -- 7 enterprise risks on the vendor
    SELECT rr.risk_register_id AS RiskRegisterId, rr.risk_number AS RiskNumber, rr.risk_title AS RiskTitle,
           rr.status_code AS StatusCode, rr.inherent_rating_name AS InherentRating,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                                    AND l.link_kind = N'ENTERPRISE_RISK' AND l.target_id = rr.risk_register_id AND l.status = N'Active')
                     THEN 1 ELSE 0 END AS BIT) AS IsLinked
    INTO   #risks
    FROM   grac_practice.risk_register rr
    WHERE  rr.organization_id = @organization_id AND rr.linked_vendor_id IN (SELECT vendor_id FROM #v);
    INSERT @counts SELECT N'Risks', COUNT(*) FROM #risks;

    -- 8 contracts of the vendor
    CREATE TABLE #contracts (ContractId BIGINT, ContractNumber NVARCHAR(60), ContractName NVARCHAR(250), ContractStatus NVARCHAR(20));
    IF OBJECT_ID('grac_practice.asset_contract','U') IS NOT NULL
        INSERT #contracts
        EXEC sp_executesql N'SELECT c.contract_id, c.contract_number, c.contract_name, c.contract_status
                             FROM grac_practice.asset_contract c
                             WHERE c.organization_id = @o AND c.vendor_id IN (SELECT vendor_id FROM #v);',
             N'@o BIGINT', @o = @organization_id;
    INSERT @counts SELECT N'Contracts', COUNT(*) FROM #contracts;
    INSERT @counts SELECT N'Vendors', COUNT(*) FROM #v;

    IF ISNULL(@persist, 0) = 1
    BEGIN
        IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;
        BEGIN TRAN;
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'PRACTICE_INSTANCE', i.PracticeInstanceId,
               LEFT(CONCAT(i.InstanceCode, N' - ', i.InstanceName, N' (', i.PracticeName, N')'), 400), N'DISCOVERED', @actor
        FROM #instances i
        WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'PRACTICE_INSTANCE' AND l.target_id = i.PracticeInstanceId AND l.status = N'Active');
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'DEPENDENCY', d.DependencyId,
               LEFT(CONCAT(d.InstanceCode, N' depends on ', d.DependencyName), 400), N'DISCOVERED', @actor
        FROM #deps d
        WHERE d.DependencyKind = N'VENDOR_RESOLUTION'
          AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'DEPENDENCY' AND l.target_id = d.DependencyId AND l.status = N'Active');
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'APPLICATION', d.DependencyId, LEFT(d.DependencyName, 400), N'DISCOVERED', @actor
        FROM #deps d
        WHERE d.DependencyKind = N'APPLICATION'
          AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'APPLICATION' AND l.target_id = d.DependencyId AND l.status = N'Active');
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'CONTRACT', c.ContractId, LEFT(CONCAT(c.ContractNumber, N' - ', c.ContractName), 400), N'DISCOVERED', @actor
        FROM #contracts c
        WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'CONTRACT' AND l.target_id = c.ContractId AND l.status = N'Active');
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'ENTERPRISE_RISK', r.RiskRegisterId, LEFT(CONCAT(r.RiskNumber, N' - ', r.RiskTitle), 400), N'DISCOVERED', @actor
        FROM #risks r
        WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'ENTERPRISE_RISK' AND l.target_id = r.RiskRegisterId AND l.status = N'Active');

        INSERT grac_practice.tprm_exposure_snapshot (engagement_id, organization_id, snapshot_kind, summary_json, items_json, taken_by)
        VALUES (@engagement_id, @organization_id, N'DISCOVERED',
                (SELECT k AS [key], n AS [count] FROM @counts FOR JSON PATH),
                (SELECT (SELECT PracticeInstanceId AS id, InstanceCode AS code, InstanceName AS name, PracticeName AS practice FROM #instances FOR JSON PATH) AS instances,
                        (SELECT DependencyKind AS kind, DependencyId AS id, DependencyName AS name FROM #deps FOR JSON PATH) AS dependencies,
                        (SELECT ContractId AS id, ContractNumber AS code FROM #contracts FOR JSON PATH) AS contracts,
                        (SELECT RiskRegisterId AS id, RiskNumber AS code FROM #risks FOR JSON PATH) AS risks
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                @actor);
        COMMIT;
        DECLARE @ddetail NVARCHAR(2000) = (SELECT STRING_AGG(CONCAT(k, N' ', n), N', ') FROM @counts);
        EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'DISCOVERY_RECORDED', @stage, @stage, @ddetail, @actor_employee_id, @actor;
    END

    SELECT k AS CountKey, n AS CountValue FROM @counts;
    SELECT * FROM #instances ORDER BY InstanceCode;
    SELECT * FROM #obligations ORDER BY Level, ObligationName;
    SELECT * FROM #deps ORDER BY DependencyKind, DependencyName;
    SELECT * FROM #findings ORDER BY ISNULL(IsClosed, 0), ObservedDt DESC;
    SELECT * FROM #gaps ORDER BY GapStatus DESC, OpenedDt DESC;
    SELECT * FROM #risks ORDER BY RiskNumber;
    SELECT * FROM #contracts ORDER BY ContractNumber;
END
GO

-- =====================================================================
-- 12. Links to GRAC records (manual / validate / remove)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_link_save
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @link_kind         NVARCHAR(30),
    @target_id         BIGINT,
    @note              NVARCHAR(1000) = NULL,
    @link_source       NVARCHAR(20)   = N'MANUAL',
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30) = (SELECT stage_code FROM grac_practice.tprm_engagement
                                    WHERE engagement_id = @engagement_id AND organization_id = @organization_id);
    IF @stage IS NULL THROW 57630, 'That engagement was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;
    IF ISNULL(@link_source, N'') NOT IN (N'MANUAL', N'ONBOARDING') SET @link_source = N'MANUAL';

    -- The target must be a record of the same organization.
    DECLARE @label NVARCHAR(400);
    IF @link_kind = N'VENDOR'
        SELECT @label = vendor_name FROM grac_practice.organization_dependency_vendor
         WHERE vendor_id = @target_id AND organization_id = @organization_id AND status = N'Active';
    ELSE IF @link_kind = N'PRACTICE_INSTANCE'
        SELECT @label = LEFT(CONCAT(pi.instance_code, N' - ', pi.instance_name, N' (', p.practice_name, N')'), 400)
        FROM grac_practice.practice_instance pi JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
        WHERE pi.practice_instance_id = @target_id AND pi.organization_id = @organization_id;
    ELSE IF @link_kind = N'DEPENDENCY'
        SELECT @label = LEFT(CONCAT(pi.instance_code, N' depends on ', r.resolved_dependency_name), 400)
        FROM grac_practice.practice_dependency_resolution r
        JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = r.practice_instance_id
        WHERE r.resolution_id = @target_id AND r.organization_id = @organization_id AND r.is_active = 1;
    ELSE IF @link_kind = N'APPLICATION'
        SELECT @label = application_name FROM grac_practice.organization_dependency_application
         WHERE application_id = @target_id AND organization_id = @organization_id;
    ELSE IF @link_kind = N'ENTERPRISE_RISK'
        SELECT @label = LEFT(CONCAT(risk_number, N' - ', risk_title), 400) FROM grac_practice.risk_register
         WHERE risk_register_id = @target_id AND organization_id = @organization_id;
    ELSE IF @link_kind = N'GAP'
        SELECT @label = LEFT(title, 400) FROM grac_practice.custom_gap
         WHERE custom_gap_id = @target_id AND organization_id = @organization_id;
    ELSE IF @link_kind = N'CONTRACT' AND OBJECT_ID('grac_practice.asset_contract','U') IS NOT NULL
        EXEC sp_executesql N'SELECT @l = LEFT(CONCAT(contract_number, N'' - '', contract_name), 400)
                             FROM grac_practice.asset_contract WHERE contract_id = @t AND organization_id = @o;',
             N'@l NVARCHAR(400) OUTPUT, @t BIGINT, @o BIGINT', @l = @label OUTPUT, @t = @target_id, @o = @organization_id;
    ELSE
        THROW 57650, 'That kind of record cannot be linked here.', 1;
    IF @label IS NULL THROW 57651, 'That record was not found in this organization.', 1;

    DECLARE @link_id BIGINT = (SELECT link_id FROM grac_practice.tprm_engagement_link
                                WHERE engagement_id = @engagement_id AND link_kind = @link_kind AND target_id = @target_id AND status = N'Active');
    IF @link_id IS NOT NULL
        UPDATE grac_practice.tprm_engagement_link
           SET is_validated = 1, validated_by = @actor, validated_dt = SYSUTCDATETIME(), note = COALESCE(@note, note),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE link_id = @link_id;
    ELSE
    BEGIN
        INSERT grac_practice.tprm_engagement_link
            (engagement_id, organization_id, link_kind, target_id, target_label, link_source, is_validated, validated_by, validated_dt, note, entered_by)
        VALUES (@engagement_id, @organization_id, @link_kind, @target_id, @label, @link_source, 1, @actor, SYSUTCDATETIME(), @note, @actor);
        SET @link_id = SCOPE_IDENTITY();
    END
    DECLARE @ldetail NVARCHAR(2000) = CONCAT(@link_kind, N': ', @label);
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'LINKED', @stage, @stage, @ldetail, @actor_employee_id, @actor;
    SELECT @link_id AS LinkId, N'LINKED' AS Result;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_link_action
    @organization_id   BIGINT,
    @link_id           BIGINT,
    @action            NVARCHAR(20),     -- VALIDATE | REMOVE
    @note              NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @eng BIGINT, @stage NVARCHAR(30), @label NVARCHAR(400), @kind NVARCHAR(30);
    SELECT @eng = l.engagement_id, @stage = e.stage_code, @label = l.target_label, @kind = l.link_kind
    FROM grac_practice.tprm_engagement_link l JOIN grac_practice.tprm_engagement e ON e.engagement_id = l.engagement_id
    WHERE l.link_id = @link_id AND l.organization_id = @organization_id AND l.status = N'Active';
    IF @eng IS NULL THROW 57652, 'That link was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;

    IF @action = N'VALIDATE'
        UPDATE grac_practice.tprm_engagement_link SET is_validated = 1, validated_by = @actor, validated_dt = SYSUTCDATETIME(),
               note = COALESCE(@note, note), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE link_id = @link_id;
    ELSE IF @action = N'REMOVE'
        UPDATE grac_practice.tprm_engagement_link SET status = N'Removed', note = COALESCE(@note, note),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE link_id = @link_id;
    ELSE THROW 57653, 'Unknown link action.', 1;

    DECLARE @adetail NVARCHAR(2000) = CONCAT(@kind, N': ', @label);
    DECLARE @evt NVARCHAR(40) = CONCAT(N'LINK_', @action);
    EXEC grac_practice.sp_tprm_engagement_event @eng, @evt, @stage, @stage, @adetail, @actor_employee_id, @actor;
    SELECT @link_id AS LinkId, @action AS Result;
END
GO

-- =====================================================================
-- 13. Inherent risk assessment
-- =====================================================================
-- Internal: score a DRAFT (or COMPLETED, for re-reads) assessment.
--   factor  = score / highest option score of the factor x 100
--   dimension = average of its answered factors
--   overall   = WEIGHTED_AVERAGE | HIGHEST_DIMENSION | BLENDED (version)
--   band      = highest band with min_score <= overall
--   tier      = highest of the band's tier and every matching tier rule
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_risk_score
    @assessment_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @version BIGINT, @eng BIGINT, @org BIGINT, @method NVARCHAR(30), @blend DECIMAL(5,2);
    SELECT @version = a.risk_model_version_id, @eng = a.engagement_id, @org = a.organization_id
    FROM grac_practice.tprm_risk_assessment a WHERE a.assessment_id = @assessment_id;
    IF @version IS NULL RETURN;
    SELECT @method = ISNULL(aggregation_method, N'WEIGHTED_AVERAGE'), @blend = ISNULL(blend_pct, 50)
    FROM grac_practice.tprm_template_version WHERE version_id = @version;

    DELETE FROM grac_practice.tprm_risk_assessment_dimension WHERE assessment_id = @assessment_id;
    INSERT grac_practice.tprm_risk_assessment_dimension (assessment_id, dimension_id, dimension_code, weight, inherent_score)
    SELECT @assessment_id, d.dimension_id, d.dimension_code, d.weight,
           CAST(AVG(CASE WHEN fx.max_score > 0 AND ans.score IS NOT NULL THEN ans.score * 100.0 / fx.max_score END) AS DECIMAL(6,2))
    FROM   grac_practice.tprm_rm_dimension d
    LEFT   JOIN grac_practice.tprm_rm_factor f ON f.dimension_id = d.dimension_id
    LEFT   JOIN (SELECT o.factor_id, MAX(o.score) AS max_score FROM grac_practice.tprm_rm_factor_option o GROUP BY o.factor_id) fx
           ON fx.factor_id = f.factor_id
    LEFT   JOIN grac_practice.tprm_risk_assessment_answer ans ON ans.assessment_id = @assessment_id AND ans.factor_id = f.factor_id
    WHERE  d.version_id = @version
    GROUP  BY d.dimension_id, d.dimension_code, d.weight;

    DECLARE @wa DECIMAL(9,4), @hd DECIMAL(9,4), @score DECIMAL(6,2);
    SELECT @wa = SUM(weight * inherent_score) / NULLIF(SUM(weight), 0), @hd = MAX(inherent_score)
    FROM grac_practice.tprm_risk_assessment_dimension
    WHERE assessment_id = @assessment_id AND inherent_score IS NOT NULL AND weight > 0;
    SET @score = CAST(CASE @method WHEN N'HIGHEST_DIMENSION' THEN @hd
                                   WHEN N'BLENDED' THEN (@blend / 100.0) * @hd + (1 - @blend / 100.0) * @wa
                                   ELSE @wa END AS DECIMAL(6,2));

    DECLARE @band NVARCHAR(60), @band_tier NVARCHAR(60);
    SELECT TOP (1) @band = band_code, @band_tier = dd_tier_code FROM grac_practice.tprm_rm_band
     WHERE version_id = @version AND min_score <= ISNULL(@score, 0) ORDER BY min_score DESC;

    -- tier: band tier and matching tier rules, highest rank wins
    DECLARE @tiers TABLE (tier_code NVARCHAR(60), reason NVARCHAR(200));
    IF @score IS NOT NULL INSERT @tiers VALUES (@band_tier, CONCAT(N'band ', @band));
    INSERT @tiers
    SELECT r.min_dd_tier_code, CONCAT(LOWER(REPLACE(r.condition_kind, N'_', N' ')), N' ', r.condition_code)
    FROM   grac_practice.tprm_rm_tier_rule r
    CROSS  APPLY grac_practice.fn_tprm_engagement_signals(@eng) s
    WHERE  r.version_id = @version
      AND  (   (r.condition_kind = N'CRITICALITY' AND r.condition_code = s.service_criticality_code)
            OR (r.condition_kind = N'DATA_EXPOSURE' AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(s.data_codes) x WHERE x.code = r.condition_code))
            OR (r.condition_kind = N'ACCESS' AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(s.access_codes) x WHERE x.code = r.condition_code)));

    DECLARE @tier NVARCHAR(60), @tier_rank INT;
    SELECT TOP (1) @tier = t.tier_code, @tier_rank = ISNULL(r.rank_no, 0)
    FROM @tiers t
    LEFT JOIN grac_practice.fn_tprm_reference_effective(@org) r ON r.list_code = N'DD_TIER' AND r.value_code = t.tier_code
    ORDER BY ISNULL(r.rank_no, 0) DESC;
    DECLARE @reason NVARCHAR(1000) = (SELECT STRING_AGG(t.reason, N'; ') FROM @tiers t WHERE t.tier_code = @tier);

    UPDATE grac_practice.tprm_risk_assessment
       SET inherent_score = @score, inherent_band_code = CASE WHEN @score IS NULL THEN NULL ELSE @band END,
           dd_tier_code = @tier, dd_tier_reason = LEFT(@reason, 1000), updated_dt = SYSUTCDATETIME()
     WHERE assessment_id = @assessment_id;
END
GO

-- Start an inherent assessment: pins the risk model in force, and
-- prefills the factors whose option matches the scope (the assessor
-- confirms or changes every answer).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_risk_assessment_start
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @trigger_code      NVARCHAR(60)  = N'INITIAL',
    @trigger_note      NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30) = (SELECT stage_code FROM grac_practice.tprm_engagement
                                    WHERE engagement_id = @engagement_id AND organization_id = @organization_id);
    IF @stage IS NULL THROW 57630, 'That engagement was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED', N'EXITING') THROW 57640, 'A closed engagement cannot be reassessed.', 1;
    IF @stage = N'PENDING_DECISION' THROW 57660, 'A decision is pending. Withdraw it before reassessing.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_risk_assessment WHERE engagement_id = @engagement_id AND status = N'DRAFT')
        THROW 57661, 'An assessment is already in progress.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope WHERE engagement_id = @engagement_id AND status = N'Active')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND data_exposure_code IS NOT NULL)
        THROW 57662, 'Record the scope (at least the data exposure) before assessing risk.', 1;

    DECLARE @version BIGINT = (SELECT version_id FROM grac_practice.fn_tprm_risk_model_version(@organization_id));
    IF @version IS NULL THROW 57663, 'No risk model is in force. Activate one in TPRM Configuration.', 1;
    SET @trigger_code = ISNULL(NULLIF(LTRIM(RTRIM(@trigger_code)), N''), N'INITIAL');

    DECLARE @id BIGINT, @no INT;
    BEGIN TRAN;
        SELECT @no = ISNULL(MAX(assessment_no), 0) + 1 FROM grac_practice.tprm_risk_assessment WITH (UPDLOCK, HOLDLOCK)
         WHERE engagement_id = @engagement_id;
        INSERT grac_practice.tprm_risk_assessment
            (engagement_id, organization_id, assessment_no, risk_model_version_id, trigger_code, trigger_note, status,
             assessed_by_employee_id, entered_by)
        VALUES (@engagement_id, @organization_id, @no, @version, @trigger_code, @trigger_note, N'DRAFT', @actor_employee_id, @actor);
        SET @id = SCOPE_IDENTITY();

        -- prefill from the scope
        ;WITH sig AS (SELECT * FROM grac_practice.fn_tprm_engagement_signals(@engagement_id)),
        ranked AS (
            SELECT f.factor_id, o.option_id, o.score,
                   ROW_NUMBER() OVER (PARTITION BY f.factor_id
                                      ORDER BY ISNULL(rv.rank_no, 0) DESC, o.score DESC) AS rn
            FROM   grac_practice.tprm_rm_factor f
            JOIN   grac_practice.tprm_rm_factor_option o ON o.factor_id = f.factor_id
            CROSS  JOIN sig
            CROSS  APPLY grac_practice.fn_tprm_split_codes(o.prefill_match_code) m
            OUTER  APPLY (SELECT TOP (1) r.rank_no FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
                          WHERE r.value_code = m.code
                            AND r.list_code = CASE f.prefill_source WHEN N'DATA_EXPOSURE' THEN N'DATA_EXPOSURE'
                                                                    WHEN N'ACCESS' THEN N'ACCESS_CATEGORY'
                                                                    WHEN N'SERVICE_CRITICALITY' THEN N'CRITICALITY' ELSE N'-' END) rv
            WHERE  f.version_id = @version
              AND  f.prefill_source IS NOT NULL
              AND  (   (f.prefill_source = N'SERVICE_CRITICALITY' AND m.code = sig.service_criticality_code)
                    OR (f.prefill_source = N'SERVICE_MODEL' AND m.code = sig.service_model_code)
                    OR (f.prefill_source = N'IS_EXISTING' AND m.code = CASE WHEN sig.is_existing = 1 THEN N'YES' ELSE N'NO' END)
                    OR (f.prefill_source = N'DATA_EXPOSURE' AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(sig.data_codes) x WHERE x.code = m.code))
                    OR (f.prefill_source = N'ACCESS' AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(sig.access_codes) x WHERE x.code = m.code))
                    OR (f.prefill_source = N'FOURTH_PARTY_COUNT'
                        AND m.code = CASE WHEN sig.fourth_party_count >= 3 THEN N'3+' ELSE CAST(sig.fourth_party_count AS NVARCHAR(5)) END)
                    OR (f.prefill_source = N'LOCATION_COUNT'
                        AND m.code = CASE WHEN sig.location_count >= 3 THEN N'3+' ELSE CAST(sig.location_count AS NVARCHAR(5)) END))
        )
        INSERT grac_practice.tprm_risk_assessment_answer (assessment_id, factor_id, option_id, score, is_prefilled, updated_by)
        SELECT @id, factor_id, option_id, score, 1, @actor FROM ranked WHERE rn = 1;

        EXEC grac_practice.sp_tprm_risk_score @id;
    COMMIT;

    DECLARE @sdetail NVARCHAR(2000) = CONCAT(N'Inherent assessment ', @no, N' started (', @trigger_code, N').');
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'RISK_ASSESSMENT_STARTED', @stage, @stage, @sdetail, @actor_employee_id, @actor;
    SELECT @id AS AssessmentId, N'STARTED' AS Result;
END
GO

-- One assessment with its (pinned) model. Result sets:
--   1 header  2 dimensions (scores)  3 factors  4 options  5 answers  6 bands
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_risk_assessment_get
    @organization_id BIGINT,
    @assessment_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @version BIGINT;
    SELECT @version = risk_model_version_id FROM grac_practice.tprm_risk_assessment
     WHERE assessment_id = @assessment_id AND organization_id = @organization_id;
    IF @version IS NULL THROW 57664, 'That risk assessment was not found.', 1;

    SELECT a.assessment_id AS AssessmentId, a.engagement_id AS EngagementId, a.assessment_no AS AssessmentNo,
           a.risk_model_version_id AS RiskModelVersionId, t.template_name AS RiskModelName, v.version_no AS RiskModelVersionNo,
           v.aggregation_method AS AggregationMethod, v.blend_pct AS BlendPct,
           a.trigger_code AS TriggerCode, a.trigger_note AS TriggerNote, a.status AS Status,
           a.inherent_score AS InherentScore, a.inherent_band_code AS InherentBandCode, ib.band_name AS InherentBand, ib.color_hex AS InherentBandColor,
           a.dd_tier_code AS DdTierCode, a.dd_tier_reason AS DdTierReason,
           a.residual_score AS ResidualScore, a.residual_band_code AS ResidualBandCode, rb.band_name AS ResidualBand, rb.color_hex AS ResidualBandColor,
           a.residual_dt AS ResidualDt, a.residual_note AS ResidualNote, a.notes AS Notes,
           a.assessed_by_employee_id AS AssessedByEmployeeId, ae.employee_name AS AssessedByName,
           a.completed_by AS CompletedBy, a.completed_dt AS CompletedDt, a.entered_dt AS StartedDt,
           CONVERT(BIGINT, a.record_version) AS RecordVersion
    FROM   grac_practice.tprm_risk_assessment a
    JOIN   grac_practice.tprm_template_version v ON v.version_id = a.risk_model_version_id
    JOIN   grac_practice.tprm_template t ON t.template_id = v.template_id
    LEFT   JOIN grac_practice.tprm_rm_band ib ON ib.version_id = a.risk_model_version_id AND ib.band_code = a.inherent_band_code
    LEFT   JOIN grac_practice.tprm_rm_band rb ON rb.version_id = a.risk_model_version_id AND rb.band_code = a.residual_band_code
    LEFT   JOIN grac_practice.organization_employee ae ON ae.employee_id = a.assessed_by_employee_id
    WHERE  a.assessment_id = @assessment_id;

    SELECT d.dimension_id AS DimensionId, d.dimension_code AS DimensionCode, d.dimension_name AS DimensionName,
           d.description AS Description, d.weight AS Weight, s.inherent_score AS InherentScore, s.reduction_pct AS ReductionPct,
           s.uplift_pct AS UpliftPct, s.residual_score AS ResidualScore, s.safeguard_summary AS SafeguardSummary
    FROM   grac_practice.tprm_rm_dimension d
    LEFT   JOIN grac_practice.tprm_risk_assessment_dimension s ON s.assessment_id = @assessment_id AND s.dimension_id = d.dimension_id
    WHERE  d.version_id = @version
    ORDER  BY d.display_order;

    SELECT f.factor_id AS FactorId, f.dimension_id AS DimensionId, f.factor_code AS FactorCode, f.question_text AS QuestionText,
           f.guidance AS Guidance, f.is_mandatory AS IsMandatory, f.prefill_source AS PrefillSource
    FROM   grac_practice.tprm_rm_factor f
    JOIN   grac_practice.tprm_rm_dimension d ON d.dimension_id = f.dimension_id
    WHERE  f.version_id = @version
    ORDER  BY d.display_order, f.display_order;

    SELECT o.option_id AS OptionId, o.factor_id AS FactorId, o.option_code AS OptionCode, o.option_label AS OptionLabel, o.score AS Score
    FROM   grac_practice.tprm_rm_factor_option o
    JOIN   grac_practice.tprm_rm_factor f ON f.factor_id = o.factor_id
    WHERE  f.version_id = @version
    ORDER  BY o.factor_id, o.display_order;

    SELECT ans.factor_id AS FactorId, ans.option_id AS OptionId, ans.score AS Score, ans.comment AS Comment,
           ans.is_prefilled AS IsPrefilled, ans.updated_by AS UpdatedBy, ans.updated_dt AS UpdatedDt
    FROM   grac_practice.tprm_risk_assessment_answer ans
    WHERE  ans.assessment_id = @assessment_id;

    SELECT b.band_code AS BandCode, b.band_name AS BandName, b.min_score AS MinScore, b.rank_no AS RankNo,
           b.color_hex AS ColorHex, b.dd_tier_code AS DdTierCode
    FROM   grac_practice.tprm_rm_band b WHERE b.version_id = @version ORDER BY b.min_score;
END
GO

-- Save answers of a DRAFT: @answers_json = [{"factorId":1,"optionId":2,"comment":"..."}]
-- (optionId null clears the answer). Returns the recalculated header row.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_risk_answers_save
    @organization_id BIGINT,
    @assessment_id   BIGINT,
    @answers_json    NVARCHAR(MAX),
    @notes           NVARCHAR(2000) = NULL,
    @actor           NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @status NVARCHAR(20), @version BIGINT;
    SELECT @status = status, @version = risk_model_version_id FROM grac_practice.tprm_risk_assessment
     WHERE assessment_id = @assessment_id AND organization_id = @organization_id;
    IF @status IS NULL THROW 57664, 'That risk assessment was not found.', 1;
    IF @status <> N'DRAFT' THROW 57665, 'Only an assessment in progress can be changed.', 1;
    IF @answers_json IS NULL OR ISJSON(@answers_json) <> 1 THROW 57666, 'Answers are not valid.', 1;

    DECLARE @a TABLE (factor_id BIGINT PRIMARY KEY, option_id BIGINT, comment NVARCHAR(1000));
    INSERT @a SELECT factorId, MAX(optionId), MAX(comment)
    FROM OPENJSON(@answers_json) WITH (factorId BIGINT '$.factorId', optionId BIGINT '$.optionId', comment NVARCHAR(1000) '$.comment')
    WHERE factorId IS NOT NULL GROUP BY factorId;
    IF EXISTS (SELECT 1 FROM @a a WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_rm_factor f WHERE f.factor_id = a.factor_id AND f.version_id = @version))
        THROW 57667, 'An answer refers to a factor that is not in this risk model.', 1;
    IF EXISTS (SELECT 1 FROM @a a WHERE a.option_id IS NOT NULL
                 AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_rm_factor_option o WHERE o.option_id = a.option_id AND o.factor_id = a.factor_id))
        THROW 57668, 'An answer is not one of the factor options.', 1;

    BEGIN TRAN;
        MERGE grac_practice.tprm_risk_assessment_answer AS t
        USING (SELECT a.factor_id, a.option_id, o.score, a.comment FROM @a a
               LEFT JOIN grac_practice.tprm_rm_factor_option o ON o.option_id = a.option_id) AS s
        ON t.assessment_id = @assessment_id AND t.factor_id = s.factor_id
        WHEN MATCHED THEN UPDATE SET option_id = s.option_id, score = s.score, comment = s.comment, is_prefilled = 0,
                                     updated_by = @actor, updated_dt = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT (assessment_id, factor_id, option_id, score, comment, is_prefilled, updated_by)
             VALUES (@assessment_id, s.factor_id, s.option_id, s.score, s.comment, 0, @actor);
        IF @notes IS NOT NULL
            UPDATE grac_practice.tprm_risk_assessment SET notes = @notes, updated_by = @actor WHERE assessment_id = @assessment_id;
        EXEC grac_practice.sp_tprm_risk_score @assessment_id;
    COMMIT;

    SELECT a.assessment_id AS AssessmentId, a.inherent_score AS InherentScore, a.inherent_band_code AS InherentBandCode,
           a.dd_tier_code AS DdTierCode, a.dd_tier_reason AS DdTierReason, N'SAVED' AS Result
    FROM grac_practice.tprm_risk_assessment a WHERE a.assessment_id = @assessment_id;
END
GO

-- Complete (or discard) a DRAFT. Completing: mandatory factors answered;
-- the previous completed assessment is SUPERSEDED (kept); the engagement
-- takes the new inherent score, band, tier and the pinned model version;
-- SCOPING -> RISK_ASSESSED. When residual scoring exists (489) the
-- residual is recalculated against the new inherent dimensions.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_risk_assessment_complete
    @organization_id   BIGINT,
    @assessment_id     BIGINT,
    @discard           BIT           = 0,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @status NVARCHAR(20), @version BIGINT, @eng BIGINT, @no INT;
    SELECT @status = status, @version = risk_model_version_id, @eng = engagement_id, @no = assessment_no
    FROM grac_practice.tprm_risk_assessment WHERE assessment_id = @assessment_id AND organization_id = @organization_id;
    IF @status IS NULL THROW 57664, 'That risk assessment was not found.', 1;
    IF @status <> N'DRAFT' THROW 57665, 'Only an assessment in progress can be completed.', 1;
    DECLARE @stage NVARCHAR(30) = (SELECT stage_code FROM grac_practice.tprm_engagement WHERE engagement_id = @eng);

    IF ISNULL(@discard, 0) = 1
    BEGIN
        UPDATE grac_practice.tprm_risk_assessment SET status = N'DISCARDED', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE assessment_id = @assessment_id;
        DECLARE @ddetail NVARCHAR(2000) = CONCAT(N'Inherent assessment ', @no, N' discarded.');
        EXEC grac_practice.sp_tprm_engagement_event @eng, N'RISK_ASSESSMENT_DISCARDED', @stage, @stage, @ddetail, @actor_employee_id, @actor;
        SELECT @assessment_id AS AssessmentId, N'DISCARDED' AS Result;
        RETURN;
    END

    DECLARE @missing NVARCHAR(400);
    SELECT TOP (1) @missing = CONCAT(N'Answer "', f.question_text, N'".')
    FROM grac_practice.tprm_rm_factor f
    JOIN grac_practice.tprm_rm_dimension d ON d.dimension_id = f.dimension_id
    WHERE f.version_id = @version AND f.is_mandatory = 1
      AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_risk_assessment_answer a
                       WHERE a.assessment_id = @assessment_id AND a.factor_id = f.factor_id AND a.option_id IS NOT NULL)
    ORDER BY d.display_order, f.display_order;
    IF @missing IS NOT NULL THROW 57669, @missing, 1;

    DECLARE @new_stage NVARCHAR(30) = CASE WHEN @stage = N'SCOPING' THEN N'RISK_ASSESSED' ELSE @stage END;
    BEGIN TRAN;
        EXEC grac_practice.sp_tprm_risk_score @assessment_id;
        UPDATE grac_practice.tprm_risk_assessment SET status = N'SUPERSEDED', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @eng AND status = N'COMPLETED';
        UPDATE grac_practice.tprm_risk_assessment
           SET status = N'COMPLETED', completed_by = @actor, completed_dt = SYSUTCDATETIME(),
               assessed_by_employee_id = COALESCE(assessed_by_employee_id, @actor_employee_id), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE assessment_id = @assessment_id;
        UPDATE e
           SET current_risk_assessment_id = a.assessment_id, risk_model_version_id = a.risk_model_version_id,
               inherent_score = a.inherent_score, inherent_band_code = a.inherent_band_code, dd_tier_code = a.dd_tier_code,
               residual_score = NULL, residual_band_code = NULL,
               reassessment_required = 0, reassessment_reason = NULL,
               stage_code = @new_stage, stage_dt = CASE WHEN @new_stage <> @stage THEN SYSUTCDATETIME() ELSE e.stage_dt END,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.tprm_engagement e
          JOIN grac_practice.tprm_risk_assessment a ON a.assessment_id = @assessment_id
         WHERE e.engagement_id = @eng;
    COMMIT;

    IF OBJECT_ID('grac_practice.sp_tprm_residual_calculate','P') IS NOT NULL
        EXEC grac_practice.sp_tprm_residual_calculate @organization_id, @eng, @actor;

    DECLARE @cdetail NVARCHAR(2000);
    SELECT @cdetail = CONCAT(N'Inherent assessment ', @no, N' completed: score ', inherent_score, N', band ', inherent_band_code,
                             N', due-diligence tier ', dd_tier_code, N'.')
    FROM grac_practice.tprm_risk_assessment WHERE assessment_id = @assessment_id;
    EXEC grac_practice.sp_tprm_engagement_event @eng, N'RISK_ASSESSED', @stage, @new_stage, @cdetail, @actor_employee_id, @actor;
    SELECT @assessment_id AS AssessmentId, N'COMPLETED' AS Result;
END
GO

-- =====================================================================
-- 14. Verification
-- =====================================================================
SELECT '488 tables' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.tprm_third_party','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_engagement','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_engagement_scope','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_engagement_link','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_risk_assessment_dimension','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '488 procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_tprm_third_party_save','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_vendor_import','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_engagement_discover','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_risk_assessment_complete','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_sample_load','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '488 name normalisation',
       CASE WHEN grac_practice.fn_tprm_normalize_name(N'The Acme Pvt. Ltd.') = N'ACME'
             AND grac_practice.fn_tprm_normalize_name(N'ACME private limited') = N'ACME'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '488 a Vendor dependency type exists',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.dependency_type_master WHERE dependency_type_code = N'Vendor')
            THEN 'PASS' ELSE 'CHECK -- vendor discovery finds no practice instances without it' END;
GO

PRINT '488 complete. Run 489_tprm_due_diligence_decision_monitoring.sql next.';
GO
