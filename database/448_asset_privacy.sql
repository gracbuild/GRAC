-- =====================================================================
-- 448  Asset privacy -- requirement settings, privacy status and gaps,
--      privacy exceptions, privacy and retention reviews, privacy
--      notifications, lifecycle gates, Asset Privacy screen
--      (Asset & Contract Management, Phase 8 increment 3)
--
-- REQUEST
-- -------
--   BRD v1.7 5.1.10 (privacy and personal data fields), 5.1.15 / 5.2.7
--   ("personal data processed = Yes or Unknown requires categories,
--   subjects, purpose, assessment, masking, encryption, retention and
--   third-party fields"), 5.1.16 ("Privacy Compliant blocked when required
--   masking, encryption, retention or assessment is incomplete";
--   "Disposed / Archived blocked until required sanitization, certificate
--   and approval exist"), 5.1.17 (personal-data-bearing asset matrix),
--   5.2.15 (privacy requirement mapping: personal data, special / health
--   data, DPIA / PIA, masking / encryption with blocking behaviour,
--   retention and disposal), 5.2.16 / 9.1.7 (privacy review, retention
--   expiry decision -- deletion, archival, legal-hold verification or
--   approved extension -- and privacy-exception expiry reminders).
--   Plan: docs/asset-contract-management.md (Phase 8.3, D154-D166).
--
-- WHAT THIS DOES
-- --------------
--   1. asset_privacy_requirement (global catalogue, 12 requirements from
--      5.1.10 / 5.1.16 / 5.1.17 / 5.2.15) and asset_privacy_setting
--      (organization and asset-type enforcement OFF / WARN / BLOCK,
--      whether an exception may be requested, longest exception).
--   2. fn_asset_privacy_values / _retention_calc / _gaps / _status: the
--      privacy facts of each asset (its 5.1.10 field values), the computed
--      retention end, the gaps per requirement (missing, partial, failed;
--      excepted when an approved exception covers it) and the privacy
--      status: Not applicable, Undetermined, Non-compliant, Incomplete,
--      Conditional, Compliant -- never Compliant while a required control
--      is incomplete (5.1.16).
--   3. asset_privacy_exception: requested with reason, compensating
--      controls, owner and expiry; approved by another person (asset-
--      privacy APPROVE); withdrawn, rejected, revoked; expires.
--   4. asset_privacy_review: one open Privacy review (due = privacy review
--      date) and one open Retention review (due = retention end, or the
--      latest extension) per asset, kept by sp_asset_privacy_sync;
--      completed with Reviewed (next review date written to the asset),
--      Delete, Archive, Legal-hold verified or Extend (approver).
--   5. Notifications (437 framework): PRIVACY_REVIEW from open privacy
--      reviews and approved exceptions, RETENTION_REVIEW from open
--      retention reviews -- sp_asset_notification_sweep and
--      sp_asset_notification_parties (439) re-issued.
--   6. Re-issued (447): sp_asset_register_save (privacy gaps as warnings,
--      reviews refreshed), sp_asset_lifecycle_transition (BLOCK gaps stop
--      a move to Active; a blocking sanitization gap stops Disposed /
--      Archived), sp_asset_scheduler_run (privacy sync per organization
--      before the notification sweep).
--   7. Menu Asset & Contract -> Asset Privacy (364; also carried in 274).
--
-- NOT DONE HERE: masking of field values on screens or exports (the
--   5.1.10 masking fields describe the asset controls); processor-contract
--   reviews (contract expiry already notifies the contract owner);
--   retention start for Employment end / Last activity (no source data);
--   privacy dashboards and reports (8.4 / 8.5).
--
-- ERROR NUMBERS: 53050-53079
--   53050 organization not found        53051 asset not found
--   53052 unknown requirement           53053 enforcement invalid
--   53054 asset type invalid            53056 exception not found
--   53057 the requirement allows no exception
--   53058 reason / controls / owner / expiry required
--   53059 expiry out of range           53060 an active exception exists
--   53061 approver is the requester     53062 action not allowed now
--   53063 exception changed by someone else
--   53064 review not found              53065 review not open
--   53066 outcome invalid or incomplete 53067 next date invalid
--   53069 review changed by someone else
--   53070 privacy gaps block a move to Active
--   53071 sanitization blocks a move to Disposed / Archived
--   53072 invalid action
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web
--   proxy (asset-privacy area), PracticeScreen + Manage.cshtml +
--   appsettings (new screen), new asset-privacy.cshtml / .js,
--   asset-register.cshtml / .js (Privacy tab), 274 (menu), docs.
-- DEPENDS ON: 420, 421, 431, 437, 439, 447.
-- Rollback: 448_asset_privacy_rollback.sql (restores the 439 and 447
--   bodies, drops the 448 objects and the menu row).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_consistency_finding','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_consistency_evaluate','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_valuation_sync','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_field_value_set','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_notification_occurrence','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_notification_activity','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_evidence_field','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_activity_settings') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_ntf_asset_severity') IS NULL
   OR OBJECT_ID('grac_practice.asset_lifecycle_change','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_contract_version','U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_ntf_occ_obj' AND definition LIKE '%ASSET_EVIDENCE%')
   OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_activity WHERE activity_code = N'PRIVACY_REVIEW')
   OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_activity WHERE activity_code = N'RETENTION_REVIEW')
   OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition WHERE field_key = N'personal_data_processed')
   OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition WHERE field_key = N'privacy_review_date')
BEGIN
    RAISERROR('ABORT (448): run 420, 421, 431, 437, 439 and 447 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Requirement catalogue (global) and settings (organization / type)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_privacy_requirement','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_privacy_requirement (
        requirement_code    NVARCHAR(30)   NOT NULL CONSTRAINT pk_pm_aprv_req PRIMARY KEY,
        requirement_name    NVARCHAR(160)  NOT NULL,
        description         NVARCHAR(600)  NOT NULL,
        brd_reference       NVARCHAR(60)   NOT NULL,
        default_enforcement NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_aprv_req_enf CHECK (default_enforcement IN (N'OFF', N'WARN', N'BLOCK')),
        block_target        NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_aprv_req_block CHECK (block_target IN (N'ACTIVE', N'DISPOSAL')),
        display_order       INT            NOT NULL,
        entered_by          NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_aprv_req_eby DEFAULT N'system',
        entered_dt          DATETIME2      NOT NULL CONSTRAINT df_pm_aprv_req_edt DEFAULT SYSUTCDATETIME()
    );
    PRINT '448: asset_privacy_requirement created.';
END
GO

MERGE grac_practice.asset_privacy_requirement AS t
USING (VALUES
    (N'LAW_APPLICABILITY',  N'DPDP / GDPR applicability', N'DPDP and GDPR applicability recorded; Under Assessment is partial.', N'5.1.10', N'WARN', N'ACTIVE', 10),
    (N'ASSESSMENT',         N'Privacy owner and assessment', N'Privacy owner and privacy assessment status recorded; Pending / Conditional partial, Non-Compliant failed.', N'5.1.10, 5.1.17', N'WARN', N'ACTIVE', 20),
    (N'PROCESSING_DETAILS', N'Categories, subjects, operations, activity and purpose', N'Personal data categories, data subjects, processing operations, processing activity and purpose recorded.', N'5.1.10, 5.1.15, 5.1.17', N'WARN', N'ACTIVE', 30),
    (N'SPECIAL_DATA',       N'Special-category, health and children data', N'Special-category / health and children data recorded; Yes requires a DPIA / PIA (enhanced requirements).', N'5.1.5, 5.2.15', N'WARN', N'ACTIVE', 40),
    (N'DPIA',               N'DPIA / PIA', N'High-risk processing and DPIA / PIA required recorded; a required DPIA / PIA Approved (not started / in progress partial, rejected / expired failed).', N'5.1.10, 5.2.15', N'WARN', N'ACTIVE', 50),
    (N'MASKING',            N'Masking', N'Masking applicability recorded; when applicable, implemented with method and coverage (partially implemented partial, not implemented failed).', N'5.1.10, 5.1.16, 5.2.15', N'WARN', N'ACTIVE', 60),
    (N'ENCRYPTION',         N'Encryption', N'Encryption requirement recorded; when required, implemented (partially partial, not implemented failed).', N'5.1.10, 5.1.16, 5.2.15', N'WARN', N'ACTIVE', 70),
    (N'RETENTION',          N'Retention and legal hold', N'Retention policy, period, trigger and legal hold recorded; a valid period; a decision recorded once retention ends.', N'5.1.10, 5.1.16, 5.2.15, 9.1.7', N'WARN', N'ACTIVE', 80),
    (N'THIRD_PARTY',        N'Third-party access and cross-border transfer', N'Third-party access recorded; processor named and cross-border transfer recorded when Yes; transfer countries when transfer is Yes.', N'5.1.10', N'WARN', N'ACTIVE', 90),
    (N'REVIEW',             N'Privacy review', N'Privacy review date recorded and not passed.', N'5.1.10, 5.2.16, 9.1.7', N'WARN', N'ACTIVE', 100),
    (N'RESIDUAL_RISK',      N'Residual privacy risk', N'Residual privacy risk recorded after an approved or conditional assessment.', N'5.1.10', N'WARN', N'ACTIVE', 110),
    (N'SANITIZATION',       N'Deletion / sanitization before disposal', N'Deletion / sanitization required recorded; when required, method, date and evidence recorded before the asset is Disposed or Archived.', N'5.1.10, 5.1.16', N'BLOCK', N'DISPOSAL', 120)
) AS s(requirement_code, requirement_name, description, brd_reference, default_enforcement, block_target, display_order)
ON t.requirement_code = s.requirement_code
WHEN MATCHED AND (t.requirement_name <> s.requirement_name OR t.description <> s.description OR t.brd_reference <> s.brd_reference
               OR t.default_enforcement <> s.default_enforcement OR t.block_target <> s.block_target OR t.display_order <> s.display_order) THEN
    UPDATE SET requirement_name = s.requirement_name, description = s.description, brd_reference = s.brd_reference,
               default_enforcement = s.default_enforcement, block_target = s.block_target, display_order = s.display_order
WHEN NOT MATCHED BY TARGET THEN
    INSERT (requirement_code, requirement_name, description, brd_reference, default_enforcement, block_target, display_order, entered_by)
    VALUES (s.requirement_code, s.requirement_name, s.description, s.brd_reference, s.default_enforcement, s.block_target, s.display_order, N'seed-448');
PRINT CONCAT('448: privacy requirements upserted: ', @@ROWCOUNT);
GO

IF OBJECT_ID('grac_practice.asset_privacy_setting','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_privacy_setting (
        setting_id         BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_aprv_set PRIMARY KEY,
        organization_id    BIGINT        NOT NULL
            CONSTRAINT fk_pm_aprv_set_org REFERENCES grac_practice.organization(organization_id),
        asset_type_id      INT           NULL,
        requirement_code   NVARCHAR(30)  NOT NULL
            CONSTRAINT fk_pm_aprv_set_req REFERENCES grac_practice.asset_privacy_requirement(requirement_code),
        enforcement        NVARCHAR(10)  NOT NULL
            CONSTRAINT ck_pm_aprv_set_enf CHECK (enforcement IN (N'OFF', N'WARN', N'BLOCK')),
        exception_allowed  BIT           NOT NULL CONSTRAINT df_pm_aprv_set_exc DEFAULT 1,
        max_exception_days INT           NULL
            CONSTRAINT ck_pm_aprv_set_days CHECK (max_exception_days IS NULL OR max_exception_days BETWEEN 1 AND 1095),
        entered_by         NVARCHAR(100) NOT NULL,
        entered_dt         DATETIME2     NOT NULL CONSTRAINT df_pm_aprv_set_edt DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100) NULL,
        updated_dt         DATETIME2     NULL
    );
    CREATE UNIQUE INDEX ux_pm_aprv_set_org ON grac_practice.asset_privacy_setting(organization_id, requirement_code) WHERE asset_type_id IS NULL;
    CREATE UNIQUE INDEX ux_pm_aprv_set_type ON grac_practice.asset_privacy_setting(organization_id, asset_type_id, requirement_code) WHERE asset_type_id IS NOT NULL;
    PRINT '448: asset_privacy_setting created.';
END
GO

-- =====================================================================
-- 2. Exceptions and reviews
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_privacy_exception','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_privacy_exception (
        exception_id          BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_aprv_exc PRIMARY KEY,
        organization_id       BIGINT         NOT NULL,
        asset_id              BIGINT         NOT NULL
            CONSTRAINT fk_pm_aprv_exc_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        requirement_code      NVARCHAR(30)   NOT NULL
            CONSTRAINT fk_pm_aprv_exc_req REFERENCES grac_practice.asset_privacy_requirement(requirement_code),
        status                NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_aprv_exc_status CHECK (status IN (N'PENDING_APPROVAL', N'APPROVED', N'REJECTED', N'WITHDRAWN', N'REVOKED', N'EXPIRED')),
        reason                NVARCHAR(1000) NOT NULL,
        compensating_controls NVARCHAR(1000) NOT NULL,
        owner_employee_id     BIGINT         NOT NULL,
        expiry_date           DATE           NOT NULL,
        gap_snapshot          NVARCHAR(MAX)  NULL,
        requested_by          NVARCHAR(100)  NOT NULL,
        requested_employee_id BIGINT         NULL,
        requested_dt          DATETIME2      NOT NULL CONSTRAINT df_pm_aprv_exc_rdt DEFAULT SYSUTCDATETIME(),
        decided_by            NVARCHAR(100)  NULL,
        decided_employee_id   BIGINT         NULL,
        decided_dt            DATETIME2      NULL,
        decision_note         NVARCHAR(1000) NULL,
        closed_dt             DATETIME2      NULL,
        record_version        ROWVERSION     NOT NULL
    );
    CREATE UNIQUE INDEX ux_pm_aprv_exc_live ON grac_practice.asset_privacy_exception(asset_id, requirement_code)
        WHERE status IN (N'PENDING_APPROVAL', N'APPROVED');
    CREATE INDEX ix_pm_aprv_exc_org ON grac_practice.asset_privacy_exception(organization_id, status);
    PRINT '448: asset_privacy_exception created.';
END
GO

IF OBJECT_ID('grac_practice.asset_privacy_review','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_privacy_review (
        review_id             BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_aprv_rev PRIMARY KEY,
        organization_id       BIGINT         NOT NULL,
        asset_id              BIGINT         NOT NULL
            CONSTRAINT fk_pm_aprv_rev_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        review_kind           NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_aprv_rev_kind CHECK (review_kind IN (N'PRIVACY', N'RETENTION')),
        due_date              DATE           NOT NULL,
        status                NVARCHAR(10)   NOT NULL CONSTRAINT df_pm_aprv_rev_status DEFAULT N'OPEN'
            CONSTRAINT ck_pm_aprv_rev_status CHECK (status IN (N'OPEN', N'COMPLETED', N'CANCELLED')),
        outcome               NVARCHAR(12)   NULL
            CONSTRAINT ck_pm_aprv_rev_outcome CHECK (outcome IS NULL OR outcome IN (N'REVIEWED', N'DELETE', N'ARCHIVE', N'LEGAL_HOLD', N'EXTEND')),
        note                  NVARCHAR(1000) NULL,
        evidence              NVARCHAR(1000) NULL,
        next_date             DATE           NULL,
        extended_until        DATE           NULL,
        completed_by          NVARCHAR(100)  NULL,
        completed_employee_id BIGINT         NULL,
        completed_dt          DATETIME2      NULL,
        cancel_reason         NVARCHAR(400)  NULL,
        entered_by            NVARCHAR(100)  NOT NULL,
        entered_dt            DATETIME2      NOT NULL CONSTRAINT df_pm_aprv_rev_edt DEFAULT SYSUTCDATETIME(),
        updated_by            NVARCHAR(100)  NULL,
        updated_dt            DATETIME2      NULL,
        record_version        ROWVERSION     NOT NULL
    );
    CREATE UNIQUE INDEX ux_pm_aprv_rev_open ON grac_practice.asset_privacy_review(asset_id, review_kind) WHERE status = N'OPEN';
    CREATE INDEX ix_pm_aprv_rev_org ON grac_practice.asset_privacy_review(organization_id, status, due_date);
    PRINT '448: asset_privacy_review created.';
END
GO

-- =====================================================================
-- 3. Notification objects (437 framework): privacy reviews and exceptions
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_asset_ntf_occ_obj' AND definition LIKE '%PRIVACY_REVIEW%')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_ntf_occ_obj')
        ALTER TABLE grac_practice.asset_notification_occurrence DROP CONSTRAINT ck_pm_asset_ntf_occ_obj;
    ALTER TABLE grac_practice.asset_notification_occurrence WITH NOCHECK
        ADD CONSTRAINT ck_pm_asset_ntf_occ_obj
            CHECK (object_type IN (N'CONTRACT_VERSION', N'ASSET_MODEL', N'ASSET_OS', N'ASSET_FIRMWARE',
                                   N'TECH_EXCEPTION', N'ATTESTATION', N'ACTIVITY', N'ASSET_EVIDENCE',
                                   N'PRIVACY_REVIEW', N'PRIVACY_EXCEPTION'));                -- 448
    PRINT '448: notification object types widened (PRIVACY_REVIEW, PRIVACY_EXCEPTION).';
END
GO

UPDATE grac_practice.asset_notification_activity
   SET source_available = 1,
       source_note = CASE activity_code
           WHEN N'PRIVACY_REVIEW' THEN N'Raised from open privacy reviews (privacy review date) and approved privacy exceptions (expiry) -- 448.'
           ELSE N'Raised from open retention reviews (retention end or extension) -- 448.' END
 WHERE activity_code IN (N'PRIVACY_REVIEW', N'RETENTION_REVIEW') AND source_available = 0;
PRINT CONCAT('448: privacy notification activities have a source now: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 4. Privacy facts, retention, gaps and status (one evaluation for the
--    form save, lifecycle gates, scheduler, screens and reports)
-- =====================================================================
-- The 5.1.10 / 5.1.5 / 5.1.12 field values of each asset (empty and []
-- read as not recorded). Option values compare without case (YES = Yes).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_privacy_values (@organization_id BIGINT, @asset_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT a.asset_id AS AssetId, a.asset_name AS AssetName, a.asset_type_id AS AssetTypeId, s.status_code AS StatusCode,
           a.owner_id AS OwnerId, CAST(a.entered_dt AS DATE) AS RegisteredDate,
           NULLIF(NULLIF(p.pd, N''), N'[]') AS pd,     NULLIF(NULLIF(p.spc, N''), N'[]') AS spc,   NULLIF(NULLIF(p.chd, N''), N'[]') AS chd,
           NULLIF(NULLIF(p.dpdp, N''), N'[]') AS dpdp, NULLIF(NULLIF(p.gdpr, N''), N'[]') AS gdpr,
           NULLIF(NULLIF(p.powner, N''), N'[]') AS powner, NULLIF(NULLIF(p.pas, N''), N'[]') AS pas,
           NULLIF(NULLIF(p.pdc, N''), N'[]') AS pdc,   NULLIF(NULLIF(p.dsc, N''), N'[]') AS dsc,   NULLIF(NULLIF(p.pops, N''), N'[]') AS pops,
           NULLIF(NULLIF(p.pact, N''), N'[]') AS pact, NULLIF(NULLIF(p.ppur, N''), N'[]') AS ppur, NULLIF(NULLIF(p.hrp, N''), N'[]') AS hrp,
           NULLIF(NULLIF(p.dreq, N''), N'[]') AS dreq, NULLIF(NULLIF(p.dst, N''), N'[]') AS dst,
           NULLIF(NULLIF(p.mapp, N''), N'[]') AS mapp, NULLIF(NULLIF(p.mimp, N''), N'[]') AS mimp,
           NULLIF(NULLIF(p.mmeth, N''), N'[]') AS mmeth, NULLIF(NULLIF(p.mcov, N''), N'[]') AS mcov,
           NULLIF(NULLIF(p.ereq, N''), N'[]') AS ereq, NULLIF(NULLIF(p.eimp, N''), N'[]') AS eimp,
           NULLIF(NULLIF(p.rpol, N''), N'[]') AS rpol, NULLIF(NULLIF(p.rper, N''), N'[]') AS rper, NULLIF(NULLIF(p.rtrg, N''), N'[]') AS rtrg,
           NULLIF(NULLIF(p.lhold, N''), N'[]') AS lhold,
           NULLIF(NULLIF(p.tpa, N''), N'[]') AS tpa, NULLIF(NULLIF(p.proc_tp, N''), N'[]') AS proc_tp,
           NULLIF(NULLIF(p.cbt, N''), N'[]') AS cbt, NULLIF(NULLIF(p.tcty, N''), N'[]') AS tcty,
           NULLIF(NULLIF(p.dsreq, N''), N'[]') AS dsreq, p.rdate, NULLIF(NULLIF(p.rrisk, N''), N'[]') AS rrisk,
           NULLIF(NULLIF(p.sreq, N''), N'[]') AS sreq, NULLIF(NULLIF(p.smeth, N''), N'[]') AS smeth, p.sdate,
           NULLIF(NULLIF(p.sev, N''), N'[]') AS sev, NULLIF(NULLIF(p.psc, N''), N'[]') AS psc
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
     OUTER APPLY (SELECT
            CAST(MAX(CASE WHEN d.field_key = N'personal_data_processed' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS pd,
            CAST(MAX(CASE WHEN d.field_key = N'special_category_or_health_data_processed' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS spc,
            CAST(MAX(CASE WHEN d.field_key = N'children_data_processed' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS chd,
            CAST(MAX(CASE WHEN d.field_key = N'dpdp_applicable' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS dpdp,
            CAST(MAX(CASE WHEN d.field_key = N'gdpr_applicable' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS gdpr,
            CAST(MAX(CASE WHEN d.field_key = N'privacy_owner' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS powner,
            CAST(MAX(CASE WHEN d.field_key = N'privacy_assessment_status' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS pas,
            CAST(MAX(CASE WHEN d.field_key = N'personal_data_categories' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS pdc,
            CAST(MAX(CASE WHEN d.field_key = N'data_subject_categories' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS dsc,
            CAST(MAX(CASE WHEN d.field_key = N'processing_operations' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS pops,
            CAST(MAX(CASE WHEN d.field_key = N'processing_activity' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS pact,
            CAST(MAX(CASE WHEN d.field_key = N'processing_purpose' THEN LEFT(LTRIM(RTRIM(v.value_text)), 400) END) AS NVARCHAR(400)) AS ppur,
            CAST(MAX(CASE WHEN d.field_key = N'high_risk_processing' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS hrp,
            CAST(MAX(CASE WHEN d.field_key = N'dpia_pia_required' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS dreq,
            CAST(MAX(CASE WHEN d.field_key = N'dpia_pia_status' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS dst,
            CAST(MAX(CASE WHEN d.field_key = N'masking_applicable' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS mapp,
            CAST(MAX(CASE WHEN d.field_key = N'masking_implemented' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS mimp,
            CAST(MAX(CASE WHEN d.field_key = N'masking_method' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS mmeth,
            CAST(MAX(CASE WHEN d.field_key = N'masking_coverage' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS mcov,
            CAST(MAX(CASE WHEN d.field_key = N'encryption_required' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS ereq,
            CAST(MAX(CASE WHEN d.field_key = N'encryption_implemented' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS eimp,
            CAST(MAX(CASE WHEN d.field_key = N'retention_policy' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS rpol,
            CAST(MAX(CASE WHEN d.field_key = N'retention_period' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS rper,
            CAST(MAX(CASE WHEN d.field_key = N'retention_trigger' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS rtrg,
            CAST(MAX(CASE WHEN d.field_key = N'legal_hold_status' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS lhold,
            CAST(MAX(CASE WHEN d.field_key = N'third_party_access' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS tpa,
            CAST(MAX(CASE WHEN d.field_key = N'processor_third_party' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS proc_tp,
            CAST(MAX(CASE WHEN d.field_key = N'cross_border_transfer' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS cbt,
            CAST(MAX(CASE WHEN d.field_key = N'transfer_countries' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS tcty,
            CAST(MAX(CASE WHEN d.field_key = N'deletion_sanitization_required' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS dsreq,
            MAX(CASE WHEN d.field_key = N'privacy_review_date' THEN v.value_date END) AS rdate,
            CAST(MAX(CASE WHEN d.field_key = N'residual_privacy_risk' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS rrisk,
            CAST(MAX(CASE WHEN d.field_key = N'sanitization_required' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS sreq,
            CAST(MAX(CASE WHEN d.field_key = N'sanitization_method' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS smeth,
            MAX(CASE WHEN d.field_key = N'sanitization_date' THEN v.value_date END) AS sdate,
            CAST(MAX(CASE WHEN d.field_key = N'sanitization_evidence' THEN LEFT(LTRIM(RTRIM(v.value_text)), 400) END) AS NVARCHAR(400)) AS sev,
            CAST(MAX(CASE WHEN d.field_key = N'primary_support_contract' THEN LTRIM(RTRIM(v.value_text)) END) AS NVARCHAR(400)) AS psc
           FROM grac_practice.asset_field_value v
           JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id
          WHERE v.asset_id = a.asset_id
            AND d.field_key IN (N'personal_data_processed', N'special_category_or_health_data_processed', N'children_data_processed',
                                N'dpdp_applicable', N'gdpr_applicable', N'privacy_owner', N'privacy_assessment_status',
                                N'personal_data_categories', N'data_subject_categories', N'processing_operations', N'processing_activity',
                                N'processing_purpose', N'high_risk_processing', N'dpia_pia_required', N'dpia_pia_status',
                                N'masking_applicable', N'masking_implemented', N'masking_method', N'masking_coverage',
                                N'encryption_required', N'encryption_implemented', N'retention_policy', N'retention_period',
                                N'retention_trigger', N'legal_hold_status', N'third_party_access', N'processor_third_party',
                                N'cross_border_transfer', N'transfer_countries', N'deletion_sanitization_required',
                                N'privacy_review_date', N'residual_privacy_risk', N'sanitization_required', N'sanitization_method',
                                N'sanitization_date', N'sanitization_evidence', N'primary_support_contract')) p
     WHERE a.organization_id = @organization_id AND a.merged_into_asset_id IS NULL
       AND (@asset_id IS NULL OR a.asset_id = @asset_id);
GO

-- Retention end (D158): "<n> day(s) | week(s) | month(s) | year(s)" from
-- the trigger date, at most 100 years -- Creation (registration date), Closure (first
-- completed move to Disposed / Archived), Contract end (end of the version
-- in force of the primary support contract). Employment end and Last
-- activity have no source date. A later extension (completed Extend /
-- Legal-hold review) moves the end.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_privacy_retention_calc
(
    @organization_id BIGINT,
    @asset_id        BIGINT,
    @period          NVARCHAR(400),
    @trigger         NVARCHAR(400),
    @registered      DATE,
    @contract        NVARCHAR(400)
)
RETURNS TABLE
AS
RETURN
    SELECT x.n AS RetentionNumber, u.unit AS RetentionUnit, b.basis_date AS RetentionBasisDate, f.formula_date AS FormulaDueDate,
           e.extended_until AS ExtendedUntil,
           CASE WHEN e.extended_until IS NOT NULL AND (f.formula_date IS NULL OR e.extended_until > f.formula_date) THEN e.extended_until
                ELSE f.formula_date END AS RetentionDueDate,
           CASE WHEN @period IS NOT NULL AND (x.n IS NULL OR x.n <= 0 OR u.unit IS NULL) THEN 1 ELSE 0 END AS PeriodInvalid
      FROM (SELECT TRY_CONVERT(INT, LEFT(@period, CHARINDEX(N' ', @period + N' ') - 1)) AS n,
                   LOWER(LTRIM(SUBSTRING(@period, CHARINDEX(N' ', @period + N' ') + 1, 50))) AS unit_text) x
     -- Units within 100 years only (DATEADD must not overflow).
     CROSS APPLY (SELECT CASE WHEN x.unit_text LIKE N'day%'   AND x.n BETWEEN 1 AND 36500 THEN N'DAY'
                              WHEN x.unit_text LIKE N'week%'  AND x.n BETWEEN 1 AND 5200  THEN N'WEEK'
                              WHEN x.unit_text LIKE N'month%' AND x.n BETWEEN 1 AND 1200  THEN N'MONTH'
                              WHEN x.unit_text LIKE N'year%'  AND x.n BETWEEN 1 AND 100   THEN N'YEAR' END AS unit) u
     CROSS APPLY (SELECT CASE UPPER(ISNULL(@trigger, N''))
                    WHEN N'CREATION' THEN @registered
                    WHEN N'CLOSURE' THEN (SELECT MIN(CAST(COALESCE(c.decided_dt, c.requested_dt) AS DATE))
                                            FROM grac_practice.asset_lifecycle_change c
                                           WHERE c.asset_id = @asset_id AND c.change_status = N'COMPLETED'
                                             AND c.to_status_code IN (N'DISPOSED', N'ARCHIVED'))
                    WHEN N'CONTRACT_END' THEN (SELECT TOP (1) cv.effective_end
                                                 FROM grac_practice.asset_contract k
                                                 JOIN grac_practice.asset_contract_version cv ON cv.version_id = k.current_version_id
                                                WHERE k.contract_id = TRY_CONVERT(BIGINT, @contract) AND k.organization_id = @organization_id)
                  END AS basis_date) b
     CROSS APPLY (SELECT CASE u.unit WHEN N'DAY' THEN DATEADD(DAY, x.n, b.basis_date) WHEN N'WEEK' THEN DATEADD(WEEK, x.n, b.basis_date)
                                     WHEN N'MONTH' THEN DATEADD(MONTH, x.n, b.basis_date) WHEN N'YEAR' THEN DATEADD(YEAR, x.n, b.basis_date) END AS formula_date) f
     OUTER APPLY (SELECT MAX(r.extended_until) AS extended_until
                    FROM grac_practice.asset_privacy_review r
                   WHERE r.asset_id = @asset_id AND r.review_kind = N'RETENTION' AND r.status = N'COMPLETED') e;
GO

-- Gaps per requirement. Applicable = personal data processed Yes or
-- Unknown; sanitization also applies to any asset with sanitization
-- required. Requirements set to OFF raise nothing; an approved, unexpired
-- exception marks the gap excepted.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_privacy_gaps (@organization_id BIGINT, @asset_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT v.AssetId, c.requirement_code AS RequirementCode, c.requirement_name AS RequirementName, g.kind AS GapKind,
           CAST(g.msg AS NVARCHAR(400)) AS Message, ISNULL(st.enforcement, c.default_enforcement) AS Enforcement,
           c.block_target AS BlockTarget, ISNULL(st.exception_allowed, 1) AS ExceptionAllowed, st.max_exception_days AS MaxExceptionDays,
           ex.exception_id AS ExceptionId, ex.expiry_date AS ExceptionExpiry,
           CASE WHEN ex.exception_id IS NULL THEN 0 ELSE 1 END AS IsExcepted, c.display_order AS DisplayOrder
      FROM grac_practice.fn_asset_privacy_values(@organization_id, @asset_id) v
     CROSS APPLY (SELECT CASE WHEN v.pd IN (N'YES', N'UNKNOWN') THEN 1 ELSE 0 END AS app,
                         CASE WHEN v.sreq = N'YES' OR v.dsreq = N'YES' THEN 1 ELSE 0 END AS san,
                         CASE WHEN v.spc = N'YES' OR v.chd = N'YES' OR v.hrp = N'YES' THEN 1 ELSE 0 END AS dpia_needed,
                         CAST(SYSUTCDATETIME() AS DATE) AS today) f
     OUTER APPLY grac_practice.fn_asset_privacy_retention_calc(@organization_id, v.AssetId, v.rper, v.rtrg, v.RegisteredDate, v.psc) rt
     CROSS APPLY (VALUES
        (N'LAW_APPLICABILITY', N'MISSING', CAST(N'DPDP / GDPR applicability is not recorded.' AS NVARCHAR(400)),
            CASE WHEN f.app = 1 AND (v.dpdp IS NULL OR v.gdpr IS NULL) THEN 1 ELSE 0 END),
        (N'LAW_APPLICABILITY', N'PARTIAL', N'DPDP / GDPR applicability is under assessment.',
            CASE WHEN f.app = 1 AND (v.dpdp = N'UNDER_ASSESSMENT' OR v.gdpr = N'UNDER_ASSESSMENT') THEN 1 ELSE 0 END),
        (N'ASSESSMENT', N'MISSING', N'The privacy owner or the privacy assessment is not recorded (or Not Assessed).',
            CASE WHEN f.app = 1 AND (v.powner IS NULL OR v.pas IS NULL OR v.pas = N'NOT_ASSESSED') THEN 1 ELSE 0 END),
        (N'ASSESSMENT', N'PARTIAL', N'The privacy assessment is pending or conditional.',
            CASE WHEN f.app = 1 AND v.pas IN (N'PENDING', N'CONDITIONAL') THEN 1 ELSE 0 END),
        (N'ASSESSMENT', N'FAILED', N'The privacy assessment found the asset non-compliant.',
            CASE WHEN f.app = 1 AND v.pas = N'NON_COMPLIANT' THEN 1 ELSE 0 END),
        (N'PROCESSING_DETAILS', N'MISSING',
            CONCAT(N'Not recorded: ', CONCAT_WS(N', ', CASE WHEN v.pdc IS NULL THEN N'personal data categories' END,
                                               CASE WHEN v.dsc IS NULL THEN N'data subject categories' END,
                                               CASE WHEN v.pops IS NULL THEN N'processing operations' END,
                                               CASE WHEN v.pact IS NULL THEN N'processing activity' END,
                                               CASE WHEN v.ppur IS NULL THEN N'processing purpose' END), N'.'),
            CASE WHEN f.app = 1 AND (v.pdc IS NULL OR v.dsc IS NULL OR v.pops IS NULL OR v.pact IS NULL OR v.ppur IS NULL) THEN 1 ELSE 0 END),
        (N'SPECIAL_DATA', N'MISSING', N'Special-category / health data or children data is not recorded.',
            CASE WHEN f.app = 1 AND (v.spc IS NULL OR v.chd IS NULL) THEN 1 ELSE 0 END),
        (N'SPECIAL_DATA', N'PARTIAL', N'Special-category / health data or children data is Unknown.',
            CASE WHEN f.app = 1 AND (v.spc = N'UNKNOWN' OR v.chd = N'UNKNOWN') THEN 1 ELSE 0 END),
        (N'SPECIAL_DATA', N'FAILED', N'Special-category, health or children data is processed but DPIA / PIA required is No.',
            CASE WHEN f.app = 1 AND (v.spc = N'YES' OR v.chd = N'YES') AND v.dreq = N'NO' THEN 1 ELSE 0 END),
        (N'DPIA', N'MISSING', N'High-risk processing or DPIA / PIA required is not recorded.',
            CASE WHEN f.app = 1 AND (v.hrp IS NULL OR v.dreq IS NULL) THEN 1 ELSE 0 END),
        (N'DPIA', N'FAILED', N'High-risk processing needs a DPIA / PIA but DPIA / PIA required is No.',
            CASE WHEN f.app = 1 AND v.hrp = N'YES' AND v.dreq = N'NO' THEN 1 ELSE 0 END),
        (N'DPIA', N'MISSING', N'The DPIA / PIA status is not recorded.',
            CASE WHEN f.app = 1 AND (v.dreq = N'YES' OR (f.dpia_needed = 1 AND v.dreq IS NULL)) AND v.dst IS NULL THEN 1 ELSE 0 END),
        (N'DPIA', N'PARTIAL', N'The DPIA / PIA is not started or in progress.',
            CASE WHEN f.app = 1 AND v.dreq = N'YES' AND v.dst IN (N'NOT_STARTED', N'IN_PROGRESS') THEN 1 ELSE 0 END),
        (N'DPIA', N'FAILED', N'The DPIA / PIA was rejected or has expired.',
            CASE WHEN f.app = 1 AND v.dreq = N'YES' AND v.dst IN (N'REJECTED', N'EXPIRED') THEN 1 ELSE 0 END),
        (N'MASKING', N'MISSING', N'Masking applicability is not recorded.',
            CASE WHEN f.app = 1 AND v.mapp IS NULL THEN 1 ELSE 0 END),
        (N'MASKING', N'PARTIAL', N'Masking applicability is under assessment.',
            CASE WHEN f.app = 1 AND v.mapp = N'UNDER_ASSESSMENT' THEN 1 ELSE 0 END),
        (N'MASKING', N'MISSING', N'Masking implementation, method or coverage is not recorded.',
            CASE WHEN f.app = 1 AND v.mapp = N'YES'
                      AND (v.mimp IS NULL OR (v.mimp IN (N'YES', N'PARTIALLY') AND (v.mmeth IS NULL OR v.mcov IS NULL))) THEN 1 ELSE 0 END),
        (N'MASKING', N'PARTIAL', N'Masking is partially implemented.',
            CASE WHEN f.app = 1 AND v.mapp = N'YES' AND v.mimp = N'PARTIALLY' THEN 1 ELSE 0 END),
        (N'MASKING', N'FAILED', N'Masking is applicable but not implemented.',
            CASE WHEN f.app = 1 AND v.mapp = N'YES' AND v.mimp = N'NO' THEN 1 ELSE 0 END),
        (N'ENCRYPTION', N'MISSING', N'The encryption requirement or its implementation is not recorded.',
            CASE WHEN f.app = 1 AND (v.ereq IS NULL OR (v.ereq = N'YES' AND v.eimp IS NULL)) THEN 1 ELSE 0 END),
        (N'ENCRYPTION', N'PARTIAL', N'Encryption is partially implemented.',
            CASE WHEN f.app = 1 AND v.ereq = N'YES' AND v.eimp = N'PARTIALLY' THEN 1 ELSE 0 END),
        (N'ENCRYPTION', N'FAILED', N'Encryption is required but not implemented.',
            CASE WHEN f.app = 1 AND v.ereq = N'YES' AND v.eimp = N'NO' THEN 1 ELSE 0 END),
        (N'RETENTION', N'MISSING',
            CONCAT(N'Not recorded: ', CONCAT_WS(N', ', CASE WHEN v.rpol IS NULL THEN N'retention policy' END,
                                               CASE WHEN v.rper IS NULL THEN N'retention period' END,
                                               CASE WHEN v.rtrg IS NULL THEN N'retention trigger' END,
                                               CASE WHEN v.lhold IS NULL THEN N'legal hold status' END), N'.'),
            CASE WHEN f.app = 1 AND (v.rpol IS NULL OR v.rper IS NULL OR v.rtrg IS NULL OR v.lhold IS NULL) THEN 1 ELSE 0 END),
        (N'RETENTION', N'FAILED', N'The retention period must be a positive number of days, weeks, months or years up to 100 years (for example 7 years).',
            CASE WHEN f.app = 1 AND rt.PeriodInvalid = 1 THEN 1 ELSE 0 END),
        (N'RETENTION', N'FAILED',
            CONCAT(N'Retention ended on ', CONVERT(NVARCHAR(10), rt.RetentionDueDate, 23),
                   N'; record the deletion, archival, legal-hold or extension decision (Asset Privacy, Reviews).'),
            CASE WHEN f.app = 1 AND rt.RetentionDueDate < f.today
                      AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_privacy_review r
                                       WHERE r.asset_id = v.AssetId AND r.review_kind = N'RETENTION' AND r.status = N'COMPLETED'
                                         AND r.due_date >= rt.RetentionDueDate) THEN 1 ELSE 0 END),
        (N'THIRD_PARTY', N'MISSING',
            CONCAT(N'Not recorded: ', CONCAT_WS(N', ', CASE WHEN v.tpa IS NULL THEN N'third-party access' END,
                                               CASE WHEN v.tpa = N'YES' AND v.proc_tp IS NULL THEN N'processor / third party' END,
                                               CASE WHEN v.tpa = N'YES' AND v.cbt IS NULL THEN N'cross-border transfer' END,
                                               CASE WHEN v.cbt = N'YES' AND v.tcty IS NULL THEN N'transfer countries' END), N'.'),
            CASE WHEN f.app = 1 AND (v.tpa IS NULL OR (v.tpa = N'YES' AND (v.proc_tp IS NULL OR v.cbt IS NULL))
                                      OR (v.cbt = N'YES' AND v.tcty IS NULL)) THEN 1 ELSE 0 END),
        (N'THIRD_PARTY', N'PARTIAL', N'Cross-border transfer is under assessment.',
            CASE WHEN f.app = 1 AND v.cbt = N'UNDER_ASSESSMENT' THEN 1 ELSE 0 END),
        (N'REVIEW', N'MISSING', N'The privacy review date is not recorded.',
            CASE WHEN f.app = 1 AND v.rdate IS NULL THEN 1 ELSE 0 END),
        (N'REVIEW', N'FAILED', CONCAT(N'The privacy review was due on ', CONVERT(NVARCHAR(10), v.rdate, 23), N'.'),
            CASE WHEN f.app = 1 AND v.rdate < f.today THEN 1 ELSE 0 END),
        (N'RESIDUAL_RISK', N'MISSING', N'Residual privacy risk is not recorded after the assessment.',
            CASE WHEN f.app = 1 AND v.pas IN (N'APPROVED', N'CONDITIONAL') AND v.rrisk IS NULL THEN 1 ELSE 0 END),
        (N'SANITIZATION', N'MISSING', N'Deletion / sanitization required is not recorded.',
            CASE WHEN f.app = 1 AND v.dsreq IS NULL THEN 1 ELSE 0 END),
        (N'SANITIZATION', N'MISSING',
            CONCAT(N'Sanitization is required; not recorded: ', CONCAT_WS(N', ', CASE WHEN v.smeth IS NULL THEN N'sanitization method' END,
                                                                         CASE WHEN v.sdate IS NULL THEN N'sanitization date' END,
                                                                         CASE WHEN v.sev IS NULL THEN N'sanitization evidence' END), N'.'),
            CASE WHEN f.san = 1 AND (v.smeth IS NULL OR v.sdate IS NULL OR v.sev IS NULL)
                      AND ISNULL(v.StatusCode, N'') IN (N'PENDING_DECOMMISSION', N'SANITIZATION_PENDING', N'DISPOSAL_APPROVAL',
                                                        N'DISPOSED', N'ARCHIVED') THEN 1 ELSE 0 END)
     ) g(code, kind, msg, hit)
      JOIN grac_practice.asset_privacy_requirement c ON c.requirement_code = g.code
     OUTER APPLY (SELECT TOP (1) s.enforcement, s.exception_allowed, s.max_exception_days
                    FROM grac_practice.asset_privacy_setting s
                   WHERE s.organization_id = @organization_id AND s.requirement_code = g.code
                     AND (s.asset_type_id = v.AssetTypeId OR s.asset_type_id IS NULL)
                   ORDER BY CASE WHEN s.asset_type_id IS NULL THEN 1 ELSE 0 END) st
     OUTER APPLY (SELECT TOP (1) x.exception_id, x.expiry_date
                    FROM grac_practice.asset_privacy_exception x
                   WHERE x.asset_id = v.AssetId AND x.requirement_code = g.code AND x.status = N'APPROVED'
                     AND x.expiry_date >= f.today) ex
     WHERE g.hit = 1 AND ISNULL(st.enforcement, c.default_enforcement) <> N'OFF';
GO

-- Privacy status per asset (5.1.16: never Compliant while a required
-- control is incomplete).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_privacy_status (@organization_id BIGINT, @asset_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT v.AssetId, v.AssetName, v.AssetTypeId, v.StatusCode, v.OwnerId,
           CASE WHEN v.pd IN (N'YES', N'UNKNOWN') THEN N'APPLICABLE' WHEN v.pd = N'NO' THEN N'NOT_APPLICABLE' ELSE N'UNDETERMINED' END AS Applicability,
           v.pd AS PersonalDataProcessed, TRY_CONVERT(BIGINT, v.powner) AS PrivacyOwnerId, v.pas AS AssessmentStatus,
           v.rdate AS PrivacyReviewDate, rt.RetentionDueDate, v.lhold AS LegalHold,
           ISNULL(g.Failed, 0) AS Failed, ISNULL(g.Missing, 0) AS Missing, ISNULL(g.Partial, 0) AS Partial,
           ISNULL(g.Excepted, 0) AS Excepted, ISNULL(g.Blocking, 0) AS Blocking,
           CASE WHEN v.pd = N'NO' THEN N'NOT_APPLICABLE'
                WHEN v.pd IS NULL THEN N'UNDETERMINED'
                WHEN ISNULL(g.Failed, 0) > 0 THEN N'NON_COMPLIANT'
                WHEN ISNULL(g.Missing, 0) > 0 THEN N'INCOMPLETE'
                WHEN ISNULL(g.Partial, 0) > 0 OR ISNULL(g.Excepted, 0) > 0 THEN N'CONDITIONAL'
                ELSE N'COMPLIANT' END AS PrivacyStatus
      FROM grac_practice.fn_asset_privacy_values(@organization_id, @asset_id) v
     OUTER APPLY grac_practice.fn_asset_privacy_retention_calc(@organization_id, v.AssetId, v.rper, v.rtrg, v.RegisteredDate, v.psc) rt
     OUTER APPLY (SELECT SUM(CASE WHEN x.IsExcepted = 0 AND x.GapKind = N'FAILED' THEN 1 ELSE 0 END) AS Failed,
                         SUM(CASE WHEN x.IsExcepted = 0 AND x.GapKind = N'MISSING' THEN 1 ELSE 0 END) AS Missing,
                         SUM(CASE WHEN x.IsExcepted = 0 AND x.GapKind = N'PARTIAL' THEN 1 ELSE 0 END) AS Partial,
                         SUM(CASE WHEN x.IsExcepted = 1 THEN 1 ELSE 0 END) AS Excepted,
                         SUM(CASE WHEN x.IsExcepted = 0 AND x.Enforcement = N'BLOCK' THEN 1 ELSE 0 END) AS Blocking
                    FROM grac_practice.fn_asset_privacy_gaps(@organization_id, v.AssetId) x) g;
GO
PRINT '448: privacy values, retention, gaps and status functions created.';
GO

-- =====================================================================
-- 5. Sync: reviews and exception expiry (scheduler, form save, run now)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_privacy_sync
    @organization_id BIGINT,
    @asset_id        BIGINT        = NULL,
    @actor           NVARCHAR(100) = N'system',
    @out_opened      INT           = NULL OUTPUT,
    @out_closed      INT           = NULL OUTPUT,
    @out_expired     INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SELECT @out_opened = 0, @out_closed = 0, @out_expired = 0;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- Which reviews should be open: privacy review date (assets in use) and
    -- retention end (any status), unless a completed review already covers it.
    DECLARE @want TABLE (asset_id BIGINT NOT NULL, review_kind NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL, due_date DATE NOT NULL,
                         PRIMARY KEY (asset_id, review_kind));
    INSERT @want (asset_id, review_kind, due_date)
    SELECT v.AssetId, N'PRIVACY', v.rdate
      FROM grac_practice.fn_asset_privacy_values(@organization_id, @asset_id) v
     WHERE v.pd IN (N'YES', N'UNKNOWN') AND v.rdate IS NOT NULL
       AND ISNULL(v.StatusCode, N'') NOT IN (N'DISPOSED', N'ARCHIVED')
    UNION ALL
    SELECT v.AssetId, N'RETENTION', rt.RetentionDueDate
      FROM grac_practice.fn_asset_privacy_values(@organization_id, @asset_id) v
     CROSS APPLY grac_practice.fn_asset_privacy_retention_calc(@organization_id, v.AssetId, v.rper, v.rtrg, v.RegisteredDate, v.psc) rt
     WHERE v.pd IN (N'YES', N'UNKNOWN') AND rt.RetentionDueDate IS NOT NULL;
    DELETE w
      FROM @want w
     WHERE EXISTS (SELECT 1 FROM grac_practice.asset_privacy_review r
                    WHERE r.asset_id = w.asset_id AND r.review_kind = w.review_kind AND r.status = N'COMPLETED'
                      AND r.due_date >= w.due_date);

    BEGIN TRAN;
    UPDATE grac_practice.asset_privacy_exception
       SET status = N'EXPIRED', closed_dt = SYSUTCDATETIME()
     WHERE organization_id = @organization_id AND (@asset_id IS NULL OR asset_id = @asset_id)
       AND status = N'APPROVED' AND expiry_date < @today;
    SET @out_expired = @@ROWCOUNT;

    UPDATE r
       SET status = N'CANCELLED', cancel_reason = N'No longer due: the privacy review date, retention fields or applicability changed.',
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_privacy_review r
     WHERE r.organization_id = @organization_id AND (@asset_id IS NULL OR r.asset_id = @asset_id) AND r.status = N'OPEN'
       AND NOT EXISTS (SELECT 1 FROM @want w WHERE w.asset_id = r.asset_id AND w.review_kind = r.review_kind);
    SET @out_closed = @@ROWCOUNT;

    UPDATE r
       SET due_date = w.due_date, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_privacy_review r
      JOIN @want w ON w.asset_id = r.asset_id AND w.review_kind = r.review_kind
     WHERE r.status = N'OPEN' AND r.due_date <> w.due_date;

    INSERT grac_practice.asset_privacy_review (organization_id, asset_id, review_kind, due_date, status, entered_by)
    SELECT @organization_id, w.asset_id, w.review_kind, w.due_date, N'OPEN', @actor
      FROM @want w
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_privacy_review r
                        WHERE r.asset_id = w.asset_id AND r.review_kind = w.review_kind AND r.status = N'OPEN');
    SET @out_opened = @@ROWCOUNT;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_privacy_run
    @organization_id BIGINT,
    @asset_id        BIGINT        = NULL,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53050, 'Organization not found.', 1;
    DECLARE @o INT, @c INT, @x INT;
    EXEC grac_practice.sp_asset_privacy_sync @organization_id = @organization_id, @asset_id = @asset_id, @actor = @actor,
         @out_opened = @o OUTPUT, @out_closed = @c OUTPUT, @out_expired = @x OUTPUT;
    SELECT @organization_id AS OrganizationId,
           CONCAT(@o, N' review(s) opened, ', @c, N' closed, ', @x, N' exception(s) expired') AS Result;
END
GO
PRINT '448: privacy sync created.';
GO

-- =====================================================================
-- 6. Requirement settings (5.2.15)
-- =====================================================================
-- Requirements with settings, overrides, asset types and employees (the
-- configuration of the Asset Privacy screen).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_privacy_requirements
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    -- 1. Catalogue with the organization setting
    SELECT q.requirement_code AS RequirementCode, q.requirement_name AS RequirementName, q.description AS Description,
           q.brd_reference AS BrdReference, q.default_enforcement AS DefaultEnforcement, q.block_target AS BlockTarget,
           s.enforcement AS OrgEnforcement, ISNULL(s.enforcement, q.default_enforcement) AS EffectiveEnforcement,
           ISNULL(s.exception_allowed, 1) AS ExceptionAllowed, s.max_exception_days AS MaxExceptionDays,
           s.updated_by AS UpdatedBy, COALESCE(s.updated_dt, s.entered_dt) AS UpdatedDt
      FROM grac_practice.asset_privacy_requirement q
      LEFT JOIN grac_practice.asset_privacy_setting s
             ON s.organization_id = @organization_id AND s.asset_type_id IS NULL AND s.requirement_code = q.requirement_code
     ORDER BY q.display_order;
    -- 2. Asset-type overrides
    SELECT s.setting_id AS SettingId, s.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName,
           s.requirement_code AS RequirementCode, q.requirement_name AS RequirementName, s.enforcement AS Enforcement,
           s.exception_allowed AS ExceptionAllowed, s.max_exception_days AS MaxExceptionDays
      FROM grac_practice.asset_privacy_setting s
      JOIN grac_practice.asset_privacy_requirement q ON q.requirement_code = s.requirement_code
      LEFT JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = s.asset_type_id
     WHERE s.organization_id = @organization_id AND s.asset_type_id IS NOT NULL
     ORDER BY t.asset_type_name, q.display_order;
    -- 3. Asset types for an override
    SELECT t.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName
      FROM grac_practice.dependency_asset_type_master t
     WHERE t.is_active = 1
     ORDER BY t.asset_type_name;
    -- 4. Active employees (exception owners)
    SELECT e.employee_id AS EmployeeId, e.employee_name AS EmployeeName
      FROM grac_practice.organization_employee e
     WHERE e.organization_id = @organization_id AND e.status = N'Active'
     ORDER BY e.employee_name;
END
GO

-- Organization row (asset type NULL) or asset-type override; enforcement
-- NULL removes the row (back to the organization / catalogue default).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_privacy_setting_save
    @organization_id    BIGINT,
    @asset_type_id      INT           = NULL,
    @requirement_code   NVARCHAR(30),
    @enforcement        NVARCHAR(10)  = NULL,
    @exception_allowed  BIT           = 1,
    @max_exception_days INT           = NULL,
    @actor              NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @requirement_code = UPPER(LTRIM(RTRIM(ISNULL(@requirement_code, N''))));
    SET @enforcement = NULLIF(UPPER(LTRIM(RTRIM(@enforcement))), N'');
    SET @exception_allowed = ISNULL(@exception_allowed, 1);
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53050, 'Organization not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_privacy_requirement WHERE requirement_code = @requirement_code)
        THROW 53052, 'Unknown privacy requirement.', 1;
    IF @enforcement IS NOT NULL AND @enforcement NOT IN (N'OFF', N'WARN', N'BLOCK')
        THROW 53053, 'Choose Off, Warn or Block.', 1;
    IF @max_exception_days IS NOT NULL AND @max_exception_days NOT BETWEEN 1 AND 1095
        THROW 53053, 'The longest exception must be between 1 and 1095 days.', 1;
    IF @asset_type_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_type_master WHERE asset_type_id = @asset_type_id)
        THROW 53054, 'Asset type not found.', 1;

    DECLARE @before NVARCHAR(MAX) = (SELECT s.enforcement AS enforcement, s.exception_allowed AS exceptionAllowed, s.max_exception_days AS maxExceptionDays
                                       FROM grac_practice.asset_privacy_setting s
                                      WHERE s.organization_id = @organization_id AND s.requirement_code = @requirement_code
                                        AND ISNULL(s.asset_type_id, -1) = ISNULL(@asset_type_id, -1)
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @id BIGINT;
    BEGIN TRAN;
    IF @enforcement IS NULL
    BEGIN
        DELETE FROM grac_practice.asset_privacy_setting
         WHERE organization_id = @organization_id AND requirement_code = @requirement_code
           AND ISNULL(asset_type_id, -1) = ISNULL(@asset_type_id, -1);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_privacy_setting
           SET enforcement = @enforcement, exception_allowed = @exception_allowed, max_exception_days = @max_exception_days,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE organization_id = @organization_id AND requirement_code = @requirement_code
           AND ISNULL(asset_type_id, -1) = ISNULL(@asset_type_id, -1);
        IF @@ROWCOUNT = 0
            INSERT grac_practice.asset_privacy_setting
                (organization_id, asset_type_id, requirement_code, enforcement, exception_allowed, max_exception_days, entered_by)
            VALUES (@organization_id, @asset_type_id, @requirement_code, @enforcement, @exception_allowed, @max_exception_days, @actor);
        SET @id = (SELECT setting_id FROM grac_practice.asset_privacy_setting
                    WHERE organization_id = @organization_id AND requirement_code = @requirement_code
                      AND ISNULL(asset_type_id, -1) = ISNULL(@asset_type_id, -1));
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-privacy-setting', @organization_id, CASE WHEN @enforcement IS NULL THEN N'RESET' ELSE N'SAVE' END, @before,
            (SELECT @requirement_code AS requirementCode, @asset_type_id AS assetTypeId, @enforcement AS enforcement,
                    @exception_allowed AS exceptionAllowed, @max_exception_days AS maxExceptionDays FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @id AS SettingId, CASE WHEN @enforcement IS NULL THEN N'RESET' ELSE N'SAVED' END AS Result;
END
GO
PRINT '448: requirement settings created.';
GO

-- =====================================================================
-- 7. Exceptions (19.7-style override for a privacy requirement; 9.1.7 expiry)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_privacy_exception_request
    @organization_id       BIGINT,
    @asset_id              BIGINT,
    @requirement_code      NVARCHAR(30),
    @reason                NVARCHAR(1000) = NULL,
    @compensating_controls NVARCHAR(1000) = NULL,
    @owner_employee_id     BIGINT         = NULL,
    @expiry_date           DATE           = NULL,
    @actor_employee_id     BIGINT         = NULL,
    @actor                 NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @requirement_code = UPPER(LTRIM(RTRIM(ISNULL(@requirement_code, N''))));
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    SET @compensating_controls = NULLIF(LTRIM(RTRIM(@compensating_controls)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE), @msg NVARCHAR(400);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset
                    WHERE asset_id = @asset_id AND organization_id = @organization_id AND merged_into_asset_id IS NULL)
        THROW 53051, 'Asset not found for this organization.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_privacy_requirement WHERE requirement_code = @requirement_code)
        THROW 53052, 'Unknown privacy requirement.', 1;
    DECLARE @gaps INT = 0, @allowed BIT, @maxd INT, @snapshot NVARCHAR(MAX);
    SELECT @gaps = COUNT(*), @allowed = MIN(CAST(g.ExceptionAllowed AS INT)), @maxd = MIN(g.MaxExceptionDays)
      FROM grac_practice.fn_asset_privacy_gaps(@organization_id, @asset_id) g
     WHERE g.RequirementCode = @requirement_code AND g.IsExcepted = 0;
    IF @gaps = 0 THROW 53062, 'This requirement has no open gap on the asset.', 1;
    IF @allowed = 0 THROW 53057, 'This requirement allows no exception; correct the asset instead.', 1;
    IF @reason IS NULL OR @compensating_controls IS NULL OR @owner_employee_id IS NULL OR @expiry_date IS NULL
        THROW 53058, 'Reason, compensating controls, owner and expiry date are required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @owner_employee_id AND organization_id = @organization_id)
        THROW 53058, 'The owner must be an employee of this organization.', 1;
    IF @expiry_date <= @today OR (@maxd IS NOT NULL AND @expiry_date > DATEADD(DAY, @maxd, @today))
    BEGIN
        SET @msg = CONCAT(N'The expiry date must be after today', CASE WHEN @maxd IS NULL THEN N'' ELSE CONCAT(N' and within ', @maxd, N' days') END, N'.');
        THROW 53059, @msg, 1;
    END
    IF EXISTS (SELECT 1 FROM grac_practice.asset_privacy_exception
                WHERE asset_id = @asset_id AND requirement_code = @requirement_code AND status IN (N'PENDING_APPROVAL', N'APPROVED'))
        THROW 53060, 'An exception for this requirement is already pending or approved.', 1;
    SET @snapshot = (SELECT g.GapKind AS gapKind, g.Message AS message
                       FROM grac_practice.fn_asset_privacy_gaps(@organization_id, @asset_id) g
                      WHERE g.RequirementCode = @requirement_code FOR JSON PATH);

    DECLARE @id BIGINT;
    BEGIN TRAN;
    INSERT grac_practice.asset_privacy_exception
        (organization_id, asset_id, requirement_code, status, reason, compensating_controls, owner_employee_id, expiry_date,
         gap_snapshot, requested_by, requested_employee_id)
    VALUES (@organization_id, @asset_id, @requirement_code, N'PENDING_APPROVAL', @reason, @compensating_controls, @owner_employee_id,
            @expiry_date, @snapshot, @actor, @actor_employee_id);
    SET @id = SCOPE_IDENTITY();
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-privacy-exception', @id, N'REQUEST', NULL,
            (SELECT @asset_id AS assetId, @requirement_code AS requirementCode, @reason AS reason, @compensating_controls AS compensatingControls,
                    @owner_employee_id AS ownerEmployeeId, @expiry_date AS expiryDate FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @id AS ExceptionId, N'PENDING_APPROVAL' AS Result;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_privacy_exception_action
    @organization_id         BIGINT,
    @exception_id            BIGINT,
    @action                  NVARCHAR(12),
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
    DECLARE @found BIT = 0, @status NVARCHAR(20), @rv BIGINT, @req_by NVARCHAR(100), @req_emp BIGINT, @expiry DATE;
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @req_by = requested_by,
           @req_emp = requested_employee_id, @expiry = expiry_date
      FROM grac_practice.asset_privacy_exception WHERE exception_id = @exception_id AND organization_id = @organization_id;
    IF @found = 0 THROW 53056, 'Privacy exception not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 53063, 'This exception was changed by someone else. Reload it and try again.', 1;
    IF @action NOT IN (N'APPROVE', N'REJECT', N'WITHDRAW', N'REVOKE')
        THROW 53072, 'Choose Approve, Reject, Withdraw or Revoke.', 1;
    IF @action IN (N'APPROVE', N'REJECT', N'WITHDRAW') AND @status <> N'PENDING_APPROVAL'
        THROW 53062, 'Only a request awaiting approval can be approved, rejected or withdrawn.', 1;
    IF @action = N'REVOKE' AND @status <> N'APPROVED'
        THROW 53062, 'Only an approved exception can be revoked.', 1;
    IF @action IN (N'APPROVE', N'REJECT')
       AND ((@actor_employee_id IS NOT NULL AND @actor_employee_id = @req_emp) OR @actor = @req_by)
        THROW 53061, 'Segregation of duties: the person who requested the exception cannot decide it.', 1;
    IF @action IN (N'REJECT', N'REVOKE') AND @note IS NULL
        THROW 53058, 'A reason is required.', 1;
    IF @action = N'APPROVE' AND @expiry <= @today
        THROW 53059, 'The expiry date has passed; withdraw and request again.', 1;

    DECLARE @to NVARCHAR(20) = CASE @action WHEN N'APPROVE' THEN N'APPROVED' WHEN N'REJECT' THEN N'REJECTED'
                                            WHEN N'WITHDRAW' THEN N'WITHDRAWN' ELSE N'REVOKED' END;
    BEGIN TRAN;
    UPDATE grac_practice.asset_privacy_exception
       SET status = @to, decision_note = ISNULL(@note, decision_note),
           decided_by = CASE WHEN @action = N'WITHDRAW' THEN decided_by ELSE @actor END,
           decided_employee_id = CASE WHEN @action = N'WITHDRAW' THEN decided_employee_id ELSE @actor_employee_id END,
           decided_dt = CASE WHEN @action = N'WITHDRAW' THEN decided_dt ELSE SYSUTCDATETIME() END,
           closed_dt = CASE WHEN @to = N'APPROVED' THEN NULL ELSE SYSUTCDATETIME() END
     WHERE exception_id = @exception_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-privacy-exception', @exception_id, @action,
            (SELECT @status AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @to AS status, @note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @exception_id AS ExceptionId, @to AS Result;
END
GO
PRINT '448: exception procedures created.';
GO

-- =====================================================================
-- 8. Reviews (9.1.7): privacy review and retention decision
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_privacy_review_complete
    @organization_id         BIGINT,
    @review_id               BIGINT,
    @outcome                 NVARCHAR(12),
    @note                    NVARCHAR(1000) = NULL,
    @evidence                NVARCHAR(1000) = NULL,
    @next_date               DATE           = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @outcome = UPPER(LTRIM(RTRIM(ISNULL(@outcome, N''))));
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    SET @evidence = NULLIF(LTRIM(RTRIM(@evidence)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @found BIT = 0, @status NVARCHAR(10), @rv BIGINT, @kind NVARCHAR(10), @asset BIGINT, @due DATE;
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @kind = review_kind, @asset = asset_id, @due = due_date
      FROM grac_practice.asset_privacy_review WHERE review_id = @review_id AND organization_id = @organization_id;
    IF @found = 0 THROW 53064, 'Privacy review not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 53069, 'This review was changed by someone else. Reload it and try again.', 1;
    IF @status <> N'OPEN' THROW 53065, 'This review is no longer open.', 1;

    IF @kind = N'PRIVACY'
    BEGIN
        IF @outcome <> N'REVIEWED' THROW 53066, 'A privacy review is completed as Reviewed.', 1;
        IF @next_date IS NULL OR @next_date <= @today
            THROW 53067, 'Enter the next privacy review date (after today).', 1;
    END
    ELSE
    BEGIN
        IF @outcome NOT IN (N'DELETE', N'ARCHIVE', N'LEGAL_HOLD', N'EXTEND')
            THROW 53066, 'Choose Delete, Archive, Legal hold verified or Extend.', 1;
        IF @outcome IN (N'DELETE', N'ARCHIVE') AND @evidence IS NULL
            THROW 53066, 'Evidence of the deletion or archival is required.', 1;
        IF @outcome = N'LEGAL_HOLD'
           AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_privacy_values(@organization_id, @asset) v WHERE v.lhold = N'YES')
            THROW 53066, 'Legal hold status of the asset is not Yes; record the legal hold on the asset first.', 1;
        IF @outcome = N'EXTEND' AND @note IS NULL
            THROW 53066, 'A reason is required for an extension.', 1;
        IF @outcome IN (N'LEGAL_HOLD', N'EXTEND') AND (@next_date IS NULL OR @next_date <= @today OR @next_date <= @due)
            THROW 53067, 'Enter the date until which the data is kept (after today and after the current retention end).', 1;
    END

    DECLARE @o INT, @c INT, @x INT, @date_text NVARCHAR(400) = CONVERT(NVARCHAR(10), @next_date, 23);
    BEGIN TRAN;
    UPDATE grac_practice.asset_privacy_review
       SET status = N'COMPLETED', outcome = @outcome, note = @note, evidence = @evidence, next_date = @next_date,
           extended_until = CASE WHEN @outcome IN (N'LEGAL_HOLD', N'EXTEND') THEN @next_date END,
           completed_by = @actor, completed_employee_id = @actor_employee_id, completed_dt = SYSUTCDATETIME(),
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE review_id = @review_id;
    IF @kind = N'PRIVACY'
        EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset, @field_key = N'privacy_review_date', @value = @date_text, @actor = @actor;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-privacy-review', @review_id, @outcome,
            (SELECT @kind AS reviewKind, @due AS dueDate, @asset AS assetId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @outcome AS outcome, @note AS note, @evidence AS evidence, @next_date AS nextDate FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    EXEC grac_practice.sp_asset_privacy_sync @organization_id = @organization_id, @asset_id = @asset, @actor = @actor,
         @out_opened = @o OUTPUT, @out_closed = @c OUTPUT, @out_expired = @x OUTPUT;
    COMMIT;
    SELECT @review_id AS ReviewId, @outcome AS Result;
END
GO
PRINT '448: review completion created.';
GO

-- =====================================================================
-- 9. Readers
-- =====================================================================
-- Privacy register. @status NULL = every asset except Not applicable;
-- ALL; or one privacy status.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_privacy_assets
    @organization_id BIGINT,
    @status          NVARCHAR(20)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SELECT s.AssetId, s.AssetName, s.StatusCode, s.Applicability, s.PrivacyStatus, s.Failed, s.Missing, s.Partial, s.Excepted,
           s.Blocking, s.PrivacyOwnerId, pe.employee_name AS PrivacyOwnerName, s.AssessmentStatus, s.PrivacyReviewDate,
           s.RetentionDueDate, s.LegalHold
      INTO #ps
      FROM grac_practice.fn_asset_privacy_status(@organization_id, NULL) s
      LEFT JOIN grac_practice.organization_employee pe ON pe.employee_id = s.PrivacyOwnerId;
    SELECT p.AssetId, p.AssetName, p.StatusCode, p.Applicability, p.PrivacyStatus, p.Failed, p.Missing, p.Partial, p.Excepted, p.Blocking,
           p.PrivacyOwnerId, p.PrivacyOwnerName, p.AssessmentStatus, p.PrivacyReviewDate, p.RetentionDueDate, p.LegalHold,
           (SELECT COUNT(*) FROM grac_practice.asset_privacy_review r WHERE r.asset_id = p.AssetId AND r.status = N'OPEN') AS OpenReviews,
           (SELECT COUNT(*) FROM grac_practice.asset_privacy_exception x WHERE x.asset_id = p.AssetId AND x.status = N'PENDING_APPROVAL') AS PendingExceptions,
           COUNT(*) OVER () AS TotalRows
      FROM #ps p
     WHERE ((@status IS NULL AND p.PrivacyStatus <> N'NOT_APPLICABLE') OR @status = N'ALL' OR p.PrivacyStatus = @status)
       AND (@search IS NULL OR p.AssetName LIKE N'%' + @search + N'%')
     ORDER BY CASE p.PrivacyStatus WHEN N'NON_COMPLIANT' THEN 0 WHEN N'INCOMPLETE' THEN 1 WHEN N'UNDETERMINED' THEN 2
                                   WHEN N'CONDITIONAL' THEN 3 WHEN N'COMPLIANT' THEN 4 ELSE 5 END, p.AssetName
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    SELECT PrivacyStatus, COUNT(*) AS AssetCount FROM #ps GROUP BY PrivacyStatus;
END
GO

-- One asset: status, gaps, exceptions, reviews.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_privacy_asset_get
    @organization_id BIGINT,
    @asset_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset
                    WHERE asset_id = @asset_id AND organization_id = @organization_id AND merged_into_asset_id IS NULL)
        THROW 53051, 'Asset not found for this organization.', 1;
    -- 1. Status
    SELECT s.AssetId, s.AssetName, s.StatusCode, s.Applicability, s.PersonalDataProcessed, s.PrivacyStatus, s.Failed, s.Missing,
           s.Partial, s.Excepted, s.Blocking, s.PrivacyOwnerId, pe.employee_name AS PrivacyOwnerName, s.AssessmentStatus,
           s.PrivacyReviewDate, s.RetentionDueDate, s.LegalHold
      FROM grac_practice.fn_asset_privacy_status(@organization_id, @asset_id) s
      LEFT JOIN grac_practice.organization_employee pe ON pe.employee_id = s.PrivacyOwnerId;
    -- 2. Gaps
    SELECT g.RequirementCode, g.RequirementName, g.GapKind, g.Message, g.Enforcement, g.BlockTarget, g.ExceptionAllowed,
           g.MaxExceptionDays, g.ExceptionId, g.ExceptionExpiry, g.IsExcepted
      FROM grac_practice.fn_asset_privacy_gaps(@organization_id, @asset_id) g
     ORDER BY g.DisplayOrder, CASE g.GapKind WHEN N'FAILED' THEN 0 WHEN N'MISSING' THEN 1 ELSE 2 END;
    -- 3. Exceptions
    SELECT x.exception_id AS ExceptionId, x.requirement_code AS RequirementCode, q.requirement_name AS RequirementName,
           x.status AS Status, x.reason AS Reason, x.compensating_controls AS CompensatingControls,
           x.owner_employee_id AS OwnerEmployeeId, oe.employee_name AS OwnerName, x.expiry_date AS ExpiryDate,
           x.requested_by AS RequestedBy, x.requested_dt AS RequestedDt, x.decided_by AS DecidedBy, x.decided_dt AS DecidedDt,
           x.decision_note AS DecisionNote, CONVERT(BIGINT, x.record_version) AS RecordVersion
      FROM grac_practice.asset_privacy_exception x
      JOIN grac_practice.asset_privacy_requirement q ON q.requirement_code = x.requirement_code
      LEFT JOIN grac_practice.organization_employee oe ON oe.employee_id = x.owner_employee_id
     WHERE x.asset_id = @asset_id AND x.organization_id = @organization_id
     ORDER BY CASE WHEN x.status IN (N'PENDING_APPROVAL', N'APPROVED') THEN 0 ELSE 1 END, x.exception_id DESC;
    -- 4. Reviews
    SELECT TOP (50) r.review_id AS ReviewId, r.review_kind AS ReviewKind, r.due_date AS DueDate, r.status AS Status,
           r.outcome AS Outcome, r.note AS Note, r.evidence AS Evidence, r.next_date AS NextDate, r.extended_until AS ExtendedUntil,
           r.completed_by AS CompletedBy, r.completed_dt AS CompletedDt, r.cancel_reason AS CancelReason,
           CONVERT(BIGINT, r.record_version) AS RecordVersion
      FROM grac_practice.asset_privacy_review r
     WHERE r.asset_id = @asset_id AND r.organization_id = @organization_id
     ORDER BY CASE WHEN r.status = N'OPEN' THEN 0 ELSE 1 END, r.due_date DESC, r.review_id DESC;
END
GO

-- Exceptions worklist. @status NULL = pending and approved; ALL; or one status.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_privacy_exceptions
    @organization_id BIGINT,
    @status          NVARCHAR(20) = NULL,
    @page_number     INT          = 1,
    @page_size       INT          = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SELECT x.exception_id AS ExceptionId, x.asset_id AS AssetId, a.asset_name AS AssetName, x.requirement_code AS RequirementCode,
           q.requirement_name AS RequirementName, x.status AS Status, x.reason AS Reason, x.compensating_controls AS CompensatingControls,
           x.owner_employee_id AS OwnerEmployeeId, oe.employee_name AS OwnerName, x.expiry_date AS ExpiryDate,
           x.requested_by AS RequestedBy, x.requested_dt AS RequestedDt, x.decided_by AS DecidedBy, x.decided_dt AS DecidedDt,
           x.decision_note AS DecisionNote, CONVERT(BIGINT, x.record_version) AS RecordVersion, COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_privacy_exception x
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = x.asset_id
      JOIN grac_practice.asset_privacy_requirement q ON q.requirement_code = x.requirement_code
      LEFT JOIN grac_practice.organization_employee oe ON oe.employee_id = x.owner_employee_id
     WHERE x.organization_id = @organization_id
       AND ((@status IS NULL AND x.status IN (N'PENDING_APPROVAL', N'APPROVED')) OR @status = N'ALL' OR x.status = @status)
     ORDER BY CASE x.status WHEN N'PENDING_APPROVAL' THEN 0 WHEN N'APPROVED' THEN 1 ELSE 2 END, x.expiry_date, x.exception_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Reviews worklist. @status NULL = open; ALL; or one status.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_privacy_reviews
    @organization_id BIGINT,
    @status          NVARCHAR(10) = NULL,
    @kind            NVARCHAR(10) = NULL,
    @page_number     INT          = 1,
    @page_size       INT          = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @kind = NULLIF(UPPER(LTRIM(RTRIM(@kind))), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SELECT r.review_id AS ReviewId, r.asset_id AS AssetId, a.asset_name AS AssetName, r.review_kind AS ReviewKind,
           r.due_date AS DueDate, CASE WHEN r.status = N'OPEN' AND r.due_date < @today THEN 1 ELSE 0 END AS IsOverdue,
           r.status AS Status, r.outcome AS Outcome, r.note AS Note, r.evidence AS Evidence, r.next_date AS NextDate,
           r.completed_by AS CompletedBy, r.completed_dt AS CompletedDt, v.lhold AS LegalHold,
           TRY_CONVERT(BIGINT, v.powner) AS PrivacyOwnerId, pe.employee_name AS PrivacyOwnerName,
           CONVERT(BIGINT, r.record_version) AS RecordVersion, COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_privacy_review r
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = r.asset_id
      OUTER APPLY (SELECT TOP (1) pv.lhold, pv.powner FROM grac_practice.fn_asset_privacy_values(@organization_id, r.asset_id) pv) v
      LEFT JOIN grac_practice.organization_employee pe ON pe.employee_id = TRY_CONVERT(BIGINT, v.powner)
     WHERE r.organization_id = @organization_id
       AND ((@status IS NULL AND r.status = N'OPEN') OR @status = N'ALL' OR r.status = @status)
       AND (@kind IS NULL OR r.review_kind = @kind)
     ORDER BY CASE WHEN r.status = N'OPEN' THEN 0 ELSE 1 END, r.due_date, r.review_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '448: readers created.';
GO

-- =====================================================================
-- 10. Re-issued bodies (448 lines marked; otherwise unchanged)
-- =====================================================================
-- 447 body: privacy reviews refreshed after the save; privacy gaps as warnings.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_register_save
    @organization_id         BIGINT,
    @asset_id                BIGINT         = NULL,
    @asset_type_id           INT            = NULL,
    @values_json             NVARCHAR(MAX)  = N'{}',
    @hidden_decisions_json   NVARCHAR(MAX)  = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_asset_id            BIGINT         = NULL OUTPUT,
    @out_result              NVARCHAR(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF ISJSON(ISNULL(@values_json, N'')) <> 1 SET @values_json = N'{}';
    IF ISJSON(ISNULL(@hidden_decisions_json, N'')) <> 1 SET @hidden_decisions_json = N'{}';
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54950, 'Organization not found.', 1;

    -- ---------------------------------------------------------- the record
    DECLARE @found BIT = 0, @rv BIGINT, @old_type INT, @template_id BIGINT;
    IF @asset_id IS NOT NULL
    BEGIN
        SELECT @found = 1, @rv = CONVERT(BIGINT, record_version), @old_type = asset_type_id, @template_id = template_id
          FROM grac_practice.organization_dependency_asset
         WHERE asset_id = @asset_id AND organization_id = @organization_id;
        IF @found = 0 THROW 54951, 'Asset not found for this organization.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54952, 'This asset was changed by someone else. Reload it and try again.', 1;
        IF @old_type IS NOT NULL AND @asset_type_id IS NOT NULL AND @asset_type_id <> @old_type
            THROW 54953, 'The asset type of a registered asset cannot change.', 1;
        SET @asset_type_id = ISNULL(@old_type, @asset_type_id);
    END
    IF @asset_type_id IS NULL
       OR (ISNULL(@old_type, -1) <> @asset_type_id
           AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_taxonomy_selectable() WHERE NodeKind = N'TYPE' AND NodeId = @asset_type_id))
        THROW 54954, 'Select an asset type that is active and in effect.', 1;

    -- Template: the version the asset was registered with, else the Active one (5.2.1).
    IF @template_id IS NULL
        SELECT @template_id = template_id FROM grac_practice.asset_form_template
         WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id AND is_active_version = 1;
    IF @template_id IS NULL
        THROW 54955, 'This asset type has no Active form template. Activate one on Asset Form Templates first.', 1;

    DECLARE @sub_id INT, @cat_id INT;
    SELECT @sub_id = t.subcategory_id, @cat_id = s.asset_category_id
      FROM grac_practice.dependency_asset_type_master t
      JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = t.subcategory_id
     WHERE t.asset_type_id = @asset_type_id;

    -- ---------------------------------------------------------- template fields
    DECLARE @tf TABLE (
        field_definition_id INT PRIMARY KEY, field_key NVARCHAR(100) NOT NULL UNIQUE, label NVARCHAR(200) NOT NULL,
        data_type NVARCHAR(30) NOT NULL, lookup_source NVARCHAR(100) NULL, storage_kind NVARCHAR(10) NOT NULL,
        column_name NVARCHAR(128) NULL, editable BIT NOT NULL, default_value NVARCHAR(400) NULL,
        hidden_behavior NVARCHAR(10) NOT NULL, is_multi BIT NOT NULL);
    INSERT @tf
    SELECT d.field_definition_id, d.field_key, d.display_label, d.data_type_code, d.lookup_source, d.storage_kind, d.column_name,
           CASE WHEN dt.is_user_entered = 1 AND f.is_read_only = 0 AND d.storage_kind <> N'SYSTEM' AND d.is_system_field = 0
                 AND ISNULL(d.column_name, N'') NOT IN (N'organization_id', N'asset_type_id', N'asset_subcategory_id', N'asset_category_id')
                THEN 1 ELSE 0 END,
           f.default_value, f.hidden_value_behavior,
           CASE WHEN d.data_type_code IN (N'MULTI_SELECT', N'MULTI_USER') THEN 1 ELSE 0 END
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = d.data_type_code
     WHERE f.template_id = @template_id;

    -- ---------------------------------------------------------- stored, submitted, effective
    DECLARE @stored TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    IF @asset_id IS NOT NULL
        INSERT @stored (field_key, val) SELECT FieldKey, Value FROM grac_practice.fn_asset_stored_values(@asset_id);

    DECLARE @sub TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    INSERT @sub (field_key, val)
    SELECT j.[key],
           CASE WHEN j.[type] = 4 THEN CASE WHEN EXISTS (SELECT 1 FROM OPENJSON(j.[value])) THEN j.[value] END
                WHEN j.[type] = 0 THEN NULL
                ELSE NULLIF(LTRIM(RTRIM(j.[value])), N'') END
      FROM OPENJSON(@values_json) j
      -- OPENJSON's [key] is Latin1_General_BIN2; compare in the database collation (Msg 468).
      JOIN @tf t ON t.field_key = j.[key] COLLATE DATABASE_DEFAULT AND t.editable = 1;
    -- New asset: template defaults for fields not supplied.
    IF @asset_id IS NULL
        INSERT @sub (field_key, val)
        SELECT t.field_key, t.default_value FROM @tf t
         WHERE t.editable = 1 AND t.default_value IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @sub s WHERE s.field_key = t.field_key);
    -- 446: the valuation method comes from the valuation configuration, not a template default (D134).
    IF @asset_id IS NULL                                                                       -- 446
        DELETE s FROM @sub s                                                                   -- 446
         WHERE s.field_key = N'asset_valuation_method'                                         -- 446
           AND NOT EXISTS (SELECT 1 FROM OPENJSON(@values_json) j                              -- 446
                            WHERE j.[key] COLLATE DATABASE_DEFAULT = N'asset_valuation_method'); -- 446

    DECLARE @eff TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL, submitted BIT NOT NULL);
    INSERT @eff (field_key, val, submitted)
    SELECT t.field_key,
           CASE WHEN s.field_key IS NOT NULL THEN s.val ELSE st.val END,
           CASE WHEN s.field_key IS NOT NULL AND ISNULL(s.val, N'') <> ISNULL(st.val, N'') THEN 1 ELSE 0 END
      FROM @tf t
      LEFT JOIN @sub s ON s.field_key = t.field_key
      LEFT JOIN @stored st ON st.field_key = t.field_key;
    -- Taxonomy and legal entity follow the asset type and the organization.
    UPDATE e SET val = CASE t.column_name WHEN N'asset_type_id' THEN CAST(@asset_type_id AS NVARCHAR(40))
                                          WHEN N'asset_subcategory_id' THEN CAST(@sub_id AS NVARCHAR(40))
                                          WHEN N'asset_category_id' THEN CAST(@cat_id AS NVARCHAR(40))
                                          ELSE CAST(@organization_id AS NVARCHAR(40)) END
      FROM @eff e JOIN @tf t ON t.field_key = e.field_key
     WHERE t.column_name IN (N'asset_type_id', N'asset_subcategory_id', N'asset_category_id', N'organization_id');

    -- ---------------------------------------------------------- rules (5.1.14)
    DECLARE @eval_json NVARCHAR(MAX) = N'{' + ISNULL((
        SELECT STRING_AGG(CAST(CONCAT(N'"', STRING_ESCAPE(e.field_key, 'json'), N'":',
                    CASE WHEN t.is_multi = 1 AND ISJSON(e.val) = 1 THEN e.val
                         ELSE N'"' + STRING_ESCAPE(e.val, 'json') + N'"' END) AS NVARCHAR(MAX)), N',')
          FROM @eff e JOIN @tf t ON t.field_key = e.field_key
         WHERE e.val IS NOT NULL), N'') + N'}';
    DECLARE @ev TABLE (field_key NVARCHAR(100) PRIMARY KEY, is_visible INT NOT NULL, is_mandatory INT NOT NULL);
    INSERT @ev (field_key, is_visible, is_mandatory)
    SELECT FieldKey, IsVisible, IsMandatory FROM grac_practice.fn_asset_form_evaluate(@template_id, @eval_json);

    DECLARE @issues TABLE (severity NVARCHAR(10) NOT NULL, field_key NVARCHAR(100) NULL, message NVARCHAR(500) NOT NULL);

    -- Hidden fields holding a value (5.1.14): RETAIN keeps it; CLEAR / MIGRATE need a decision.
    DECLARE @decisions TABLE (field_key NVARCHAR(100) PRIMARY KEY, decision NVARCHAR(10) NOT NULL);
    INSERT @decisions (field_key, decision)
    SELECT j.[key], UPPER(j.[value]) FROM OPENJSON(@hidden_decisions_json) j WHERE UPPER(j.[value]) IN (N'RETAIN', N'CLEAR');
    INSERT @issues (severity, field_key, message)
    SELECT N'DECISION', t.field_key,
           CONCAT(N'"', t.label, N'" is hidden by the form rules but holds a value. Choose whether to keep it or clear it.')
      FROM @tf t
      JOIN @ev v ON v.field_key = t.field_key AND v.is_visible = 0
      JOIN @stored st ON st.field_key = t.field_key AND st.val IS NOT NULL
     WHERE t.editable = 1 AND t.hidden_behavior IN (N'CLEAR', N'MIGRATE')
       AND NOT EXISTS (SELECT 1 FROM @decisions d WHERE d.field_key = t.field_key);
    -- Hidden fields: never take a newly typed value; keep or clear the stored one.
    UPDATE e
       SET val = CASE WHEN ISNULL(d.decision, CASE WHEN t.hidden_behavior = N'RETAIN' THEN N'RETAIN' END) = N'CLEAR' THEN NULL ELSE st.val END,
           submitted = CASE WHEN ISNULL(d.decision, N'') = N'CLEAR' AND st.val IS NOT NULL THEN 1 ELSE 0 END
      FROM @eff e
      JOIN @tf t ON t.field_key = e.field_key AND t.editable = 1
      JOIN @ev v ON v.field_key = e.field_key AND v.is_visible = 0
      LEFT JOIN @stored st ON st.field_key = e.field_key
      LEFT JOIN @decisions d ON d.field_key = e.field_key;

    -- ---------------------------------------------------------- mandatory
    INSERT @issues (severity, field_key, message)
    SELECT N'ERROR', t.field_key, CONCAT(N'"', t.label, N'" is required.')
      FROM @tf t
      JOIN @ev v ON v.field_key = t.field_key AND v.is_visible = 1 AND v.is_mandatory = 1
      JOIN @eff e ON e.field_key = t.field_key
     WHERE t.editable = 1 AND e.val IS NULL;

    -- ---------------------------------------------------------- data types (changed values)
    INSERT @issues (severity, field_key, message)
    SELECT N'ERROR', t.field_key,
           CONCAT(N'"', t.label, N'" ', CASE
               WHEN t.data_type IN (N'DECIMAL', N'CURRENCY') THEN N'must be a number.'
               WHEN t.data_type = N'PERCENT' THEN N'must be a number from 0 to 100.'
               WHEN t.data_type = N'QUANTITY_UNIT' THEN N'must start with a number (for example "12 months").'
               WHEN t.data_type = N'DATE' THEN N'must be a date (yyyy-mm-dd).'
               WHEN t.data_type = N'YES_NO' THEN N'must be Yes or No.'
               ELSE N'is not valid.' END)
      FROM @tf t JOIN @eff e ON e.field_key = t.field_key
     WHERE t.editable = 1 AND e.submitted = 1 AND e.val IS NOT NULL
       AND (   (t.data_type IN (N'DECIMAL', N'CURRENCY') AND TRY_CONVERT(DECIMAL(38, 6), e.val) IS NULL)
            OR (t.data_type = N'PERCENT' AND ISNULL(TRY_CONVERT(DECIMAL(38, 6), e.val), -1) NOT BETWEEN 0 AND 100)
            OR (t.data_type = N'QUANTITY_UNIT' AND TRY_CONVERT(DECIMAL(38, 6), LEFT(e.val, CHARINDEX(N' ', e.val + N' ') - 1)) IS NULL)
            OR (t.data_type = N'DATE' AND TRY_CONVERT(DATE, e.val, 23) IS NULL)
            OR (t.data_type = N'YES_NO' AND e.val NOT IN (N'Yes', N'No')));

    -- ---------------------------------------------------------- lookup values (changed values)
    DECLARE @elems TABLE (field_key NVARCHAR(100) NOT NULL, elem NVARCHAR(400) NOT NULL);
    INSERT @elems (field_key, elem)
    SELECT e.field_key, LEFT(LTRIM(RTRIM(a.[value])), 400)
      FROM @eff e JOIN @tf t ON t.field_key = e.field_key
     CROSS APPLY OPENJSON(CASE WHEN t.is_multi = 1 AND ISJSON(e.val) = 1 THEN e.val
                               ELSE N'["' + STRING_ESCAPE(e.val, 'json') + N'"]' END) a
     WHERE t.editable = 1 AND e.submitted = 1 AND e.val IS NOT NULL AND t.lookup_source IS NOT NULL
       AND a.[value] IS NOT NULL AND LTRIM(RTRIM(a.[value])) <> N'';

    INSERT @issues (severity, field_key, message)
    SELECT DISTINCT N'ERROR', t.field_key,
           CONCAT(N'"', t.label, N'" has a value that is not in its list: ', x.elem, N'.')   -- 435: MASTER:CONTRACT is a list now
      FROM @elems x JOIN @tf t ON t.field_key = x.field_key
     WHERE t.lookup_source NOT IN (N'MASTER:COUNTRY', N'MASTER:CURRENCY')
       AND t.lookup_source NOT LIKE N'STATE:%'
       AND NOT (t.lookup_source LIKE N'OPTION:%' AND EXISTS (
                SELECT 1 FROM grac_practice.fn_asset_field_options(@organization_id) o
                 WHERE o.OptionGroup = N'asset_field.' + SUBSTRING(t.lookup_source, 8, 100) AND o.OptionValue = x.elem))
       AND NOT (t.lookup_source LIKE N'MASTER:%' AND EXISTS (
                SELECT 1 FROM grac_practice.fn_asset_master_lookup(@organization_id) m
                 WHERE m.Source = t.lookup_source AND m.Value = x.elem))
       -- CIA ratings: the levels of the Active valuation configuration (same mapping as 422 / 423 template get).
       AND NOT (t.lookup_source = N'CONFIG:CIA_SCALE' AND EXISTS (
                SELECT 1 FROM grac_practice.asset_valuation_config c
                  JOIN grac_practice.asset_cia_scale_level l ON l.config_id = c.config_id
                 WHERE c.organization_id = @organization_id AND c.is_active_version = 1
                   AND CAST(l.score AS NVARCHAR(160)) = x.elem
                   AND l.dimension_code = CASE t.field_key WHEN N'confidentiality_rating' THEN N'C'
                                                           WHEN N'integrity_rating' THEN N'I'
                                                           WHEN N'availability_rating' THEN N'A' END));

    -- ---------------------------------------------------------- cross-field rules (5.1 / 5.1.16)
    DECLARE @num TABLE (field_key NVARCHAR(100) PRIMARY KEY, n DECIMAL(38, 6) NULL, d DATE NULL);
    INSERT @num (field_key, n, d)
    SELECT e.field_key,
           TRY_CONVERT(DECIMAL(38, 6), CASE WHEN t.data_type = N'QUANTITY_UNIT' THEN LEFT(e.val, CHARINDEX(N' ', e.val + N' ') - 1) ELSE e.val END),
           CASE WHEN t.data_type = N'DATE' THEN TRY_CONVERT(DATE, e.val, 23) END
      FROM @eff e JOIN @tf t ON t.field_key = e.field_key WHERE e.val IS NOT NULL;

    INSERT @issues (severity, field_key, message)
    SELECT r.severity, r.field_key, r.message
      FROM grac_practice.asset_field_validation_rule r
      JOIN @eff e ON e.field_key = r.field_key
      JOIN @num a ON a.field_key = r.field_key
      LEFT JOIN @eff eo ON eo.field_key = r.other_field_key
      LEFT JOIN @num b ON b.field_key = r.other_field_key
      LEFT JOIN @stored st ON st.field_key = r.field_key
     WHERE r.is_active = 1
       AND (e.submitted = 1 OR ISNULL(eo.submitted, 0) = 1)
       AND (   (r.rule_code = N'NOT_FUTURE'       AND a.d > @today)
            OR (r.rule_code = N'ON_OR_AFTER'      AND a.d < b.d)
            OR (r.rule_code = N'AFTER'            AND a.d <= b.d)
            OR (r.rule_code = N'NON_NEGATIVE'     AND a.n < 0)
            OR (r.rule_code = N'POSITIVE'         AND a.n <= 0)
            OR (r.rule_code = N'NOT_GREATER_THAN' AND a.n > b.n)
            OR (r.rule_code = N'NOT_BELOW_STORED' AND a.n < TRY_CONVERT(DECIMAL(38, 6), st.val)));

    -- Model must belong to the selected make and asset type (5.1.16).
    DECLARE @model_val NVARCHAR(MAX) = (SELECT val FROM @eff WHERE field_key = N'model'),
            @make_val  NVARCHAR(MAX) = (SELECT val FROM @eff WHERE field_key = N'manufacturer_make');
    DECLARE @model_id BIGINT = TRY_CONVERT(BIGINT, @model_val), @m_make INT, @m_type INT;
    IF @model_id IS NOT NULL
    BEGIN
        SELECT @m_make = make_id, @m_type = asset_type_id FROM grac_practice.asset_model WHERE model_id = @model_id;
        IF @m_type IS NOT NULL AND @m_type <> @asset_type_id
            INSERT @issues (severity, field_key, message) VALUES (N'ERROR', N'model', N'The selected model belongs to a different asset type.');
        IF @m_make IS NOT NULL AND (@make_val IS NULL OR TRY_CONVERT(INT, @make_val) <> @m_make)
            INSERT @issues (severity, field_key, message) VALUES (N'ERROR', N'model', N'The selected model does not belong to the selected make.');
    END

    -- Serial uniqueness within make / model: warning (no blocking policy configured).
    DECLARE @serial NVARCHAR(MAX) = (SELECT val FROM @eff WHERE field_key = N'serial_number' AND submitted = 1);
    IF @serial IS NOT NULL AND EXISTS (
        SELECT 1 FROM grac_practice.asset_field_value sv
          JOIN grac_practice.asset_field_definition sd ON sd.field_definition_id = sv.field_definition_id AND sd.field_key = N'serial_number'
          JOIN grac_practice.organization_dependency_asset a2 ON a2.asset_id = sv.asset_id AND a2.organization_id = @organization_id
          LEFT JOIN grac_practice.asset_field_value mv ON mv.asset_id = sv.asset_id
               AND mv.field_definition_id = (SELECT field_definition_id FROM grac_practice.asset_field_definition WHERE field_key = N'model')
          LEFT JOIN grac_practice.asset_field_value kv ON kv.asset_id = sv.asset_id
               AND kv.field_definition_id = (SELECT field_definition_id FROM grac_practice.asset_field_definition WHERE field_key = N'manufacturer_make')
         WHERE sv.value_text = @serial AND sv.asset_id <> ISNULL(@asset_id, -1)
           AND ISNULL(mv.value_text, N'') = ISNULL(@model_val, N'') AND ISNULL(kv.value_text, N'') = ISNULL(@make_val, N''))
        INSERT @issues (severity, field_key, message)
        VALUES (N'WARNING', N'serial_number', N'Another asset of this make and model already has this serial number.');

    -- 430: installed firmware / OS (5.1.16 "approved mapping or explicit exception", 4.8)
    -- An ERROR unless an active technology exception covers the asset (or its
    -- model) and the version; it was a warning in 428 until exceptions existed (D14, D19).
    DECLARE @fw BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'firmware_version' AND submitted = 1)),
            @os BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'operating_system' AND submitted = 1));
    DECLARE @hw_rev NVARCHAR(400) = LEFT((SELECT val FROM @eff WHERE field_key = N'hardware_revision'), 400);
    IF @fw IS NOT NULL AND @model_id IS NOT NULL
       AND grac_practice.fn_asset_tech_compatible(@organization_id, N'FIRMWARE', @fw, @asset_type_id, @model_id, @hw_rev) = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_tech_exception_active(@organization_id, @asset_id, @model_id, N'FIRMWARE', @fw))
        INSERT @issues (severity, field_key, message)
        VALUES (N'ERROR', N'firmware_version', N'This firmware has no approved compatibility record for the model. Choose a compatible release, or save without it and request a technology exception on the Technology tab.');
    IF @os IS NOT NULL AND @model_id IS NOT NULL
       AND grac_practice.fn_asset_tech_compatible(@organization_id, N'OS', @os, @asset_type_id, @model_id, NULL) = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_tech_exception_active(@organization_id, @asset_id, @model_id, N'OS', @os))
        INSERT @issues (severity, field_key, message)
        VALUES (N'ERROR', N'operating_system', N'This operating system has no approved compatibility record for the model. Choose a compatible release, or save without it and request a technology exception on the Technology tab.');

    -- 435: coverage (5.1.11 / 5.2.14) -- warnings; a Lifecycle tab move to Active can be blocked (D42).
    DECLARE @psc BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'primary_support_contract'));
    IF @psc IS NOT NULL AND @asset_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_coverage cv
                         JOIN grac_practice.asset_contract_version v ON v.version_id = cv.version_id
                         JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
                        WHERE cv.contract_id = @psc AND cv.asset_id = @asset_id
                          AND s.status_code IN (N'DRAFT', N'IN_REVIEW', N'PENDING_APPROVAL', N'APPROVED', N'ACTIVE'))
        INSERT @issues (severity, field_key, message)
        VALUES (N'WARNING', N'primary_support_contract', N'The selected contract does not list this asset in its coverage; add it on the contract (Contracts -> version -> Asset coverage).');
    IF @asset_id IS NOT NULL
    BEGIN
        INSERT @issues (severity, field_key, message)
        SELECT N'WARNING', NULL, g.Message FROM grac_practice.fn_asset_coverage_gaps(@organization_id) g WHERE g.AssetId = @asset_id;
    END
    ELSE
        INSERT @issues (severity, field_key, message)
        SELECT N'WARNING', NULL, CONCAT(N'Required ', ISNULL(o.OptionLabel, r.coverage_type),
                                        N' coverage is not mapped yet; map the asset on a contract after saving.')
          FROM grac_practice.asset_coverage_requirement r
         OUTER APPLY (SELECT TOP 1 f.OptionLabel FROM grac_practice.fn_asset_field_options(@organization_id) f
                       WHERE f.OptionGroup = N'asset_field.coverage_type' AND f.OptionValue = r.coverage_type) o
         WHERE r.organization_id = @organization_id AND r.asset_type_id = @asset_type_id AND r.requirement_level = N'REQUIRED';

    -- Asset name is unique in the organization (existing constraint uq_pm_org_asset_name).
    DECLARE @name NVARCHAR(220) = LEFT((SELECT val FROM @eff WHERE field_key = N'asset_name'), 220);
    IF @name IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset
                                      WHERE organization_id = @organization_id AND asset_name = @name AND asset_id <> ISNULL(@asset_id, -1))
        INSERT @issues (severity, field_key, message) VALUES (N'ERROR', N'asset_name', N'Another asset in this organization already has this name.');

    -- 446: Asset Valuation Method differing from the configured method is an
    -- 446: asset-level override -- set on the Valuation section, never by the form (D133).
    DECLARE @cfg_method NVARCHAR(30), @cfg_override BIT, @cfg_version INT;                       -- 446
    SELECT TOP (1) @cfg_method = valuation_method, @cfg_override = override_allowed, @cfg_version = version_no   -- 446
      FROM grac_practice.asset_valuation_config                                                 -- 446
     WHERE organization_id = @organization_id AND is_active_version = 1 ORDER BY config_id DESC; -- 446
    INSERT @issues (severity, field_key, message)                                               -- 446
    SELECT N'ERROR', e.field_key,                                                               -- 446
           CASE WHEN @cfg_method IS NULL                                                        -- 446
                THEN N'There is no Active valuation configuration; leave Asset Valuation Method empty.'   -- 446
                WHEN @cfg_override = 0                                                          -- 446
                THEN CONCAT(N'Valuation configuration version ', @cfg_version, N' uses ', @cfg_method,   -- 446
                            N' and does not permit an asset-level method override; leave the field empty.')   -- 446
                ELSE N'An asset-level method override needs an approver and a reason: use Override method in the Valuation section.' END   -- 446
      FROM @eff e                                                                               -- 446
     WHERE e.field_key = N'asset_valuation_method' AND e.submitted = 1 AND e.val IS NOT NULL    -- 446
       AND e.val <> ISNULL(@cfg_method, N'');                                                   -- 446

    -- ---------------------------------------------------------- stop or write
    IF EXISTS (SELECT 1 FROM @issues WHERE severity IN (N'ERROR', N'DECISION'))
    BEGIN
        SET @out_result = CASE WHEN EXISTS (SELECT 1 FROM @issues WHERE severity = N'ERROR') THEN N'INVALID' ELSE N'NEEDS_DECISION' END;
        SET @out_asset_id = @asset_id;
        SELECT severity AS Severity, field_key AS FieldKey, message AS Message FROM @issues
         ORDER BY CASE severity WHEN N'ERROR' THEN 0 WHEN N'DECISION' THEN 1 ELSE 2 END, field_key;
        RETURN;
    END

    DECLARE @col TABLE (column_name NVARCHAR(128) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    INSERT @col (column_name, val)
    SELECT t.column_name, e.val FROM @tf t JOIN @eff e ON e.field_key = t.field_key
     WHERE t.storage_kind = N'COLUMN' AND t.editable = 1;
    DECLARE @in_tpl TABLE (column_name NVARCHAR(128) PRIMARY KEY);
    INSERT @in_tpl (column_name) SELECT column_name FROM @col;

    DECLARE @active_rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                               WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
    DECLARE @draft_id INT = grac_practice.fn_get_entity_status_id(N'Asset', N'DRAFT');
    DECLARE @before NVARCHAR(MAX) = (SELECT field_key AS fieldKey, val AS value FROM @stored FOR JSON PATH);
    DECLARE @to_status_id INT, @log_id BIGINT;

    BEGIN TRAN;
    IF @asset_id IS NULL
    BEGIN
        INSERT grac_practice.organization_dependency_asset
            (organization_id, asset_name, asset_category_id, asset_subcategory_id, asset_type_id, owner_id, location_id,
             purchase_dt, warranty_expiry_dt, amc_expiry_dt, criticality_id, remarks, status, record_status_id,
             lifecycle_status, template_id, current_status_id, entered_by)
        SELECT @organization_id, @name, @cat_id, @sub_id, @asset_type_id,
               TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'owner_id')),
               TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'location_id')),
               TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'purchase_dt'), 23),
               TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'warranty_expiry_dt'), 23),
               TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'amc_expiry_dt'), 23),
               TRY_CONVERT(INT, (SELECT val FROM @col WHERE column_name = N'criticality_id')),
               (SELECT val FROM @col WHERE column_name = N'remarks'),
               N'Active', ISNULL(@active_rs, 1), p.legacy_lifecycle_status, @template_id, @draft_id, @actor
          FROM grac_practice.asset_lifecycle_status_phase p WHERE p.status_code = N'DRAFT';
        SET @out_asset_id = SCOPE_IDENTITY();
        EXEC grac_practice.sp_pm_state_transition
             @entity_type = N'Asset', @entity_id = @out_asset_id,
             @from_status_code = NULL, @to_status_code = N'DRAFT',
             @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
             @reason_code = N'REGISTERED', @reason_text = NULL,
             @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;
    END
    ELSE
    BEGIN
        -- Only columns whose field is on the template change.
        UPDATE a
           SET asset_name = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'asset_name') THEN @name ELSE a.asset_name END,
               asset_category_id = @cat_id, asset_subcategory_id = @sub_id, asset_type_id = @asset_type_id,
               owner_id = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'owner_id')
                               THEN TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'owner_id')) ELSE a.owner_id END,
               location_id = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'location_id')
                                  THEN TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'location_id')) ELSE a.location_id END,
               purchase_dt = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'purchase_dt')
                                  THEN TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'purchase_dt'), 23) ELSE a.purchase_dt END,
               warranty_expiry_dt = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'warranty_expiry_dt')
                                         THEN TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'warranty_expiry_dt'), 23) ELSE a.warranty_expiry_dt END,
               amc_expiry_dt = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'amc_expiry_dt')
                                    THEN TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'amc_expiry_dt'), 23) ELSE a.amc_expiry_dt END,
               criticality_id = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'criticality_id')
                                     THEN TRY_CONVERT(INT, (SELECT val FROM @col WHERE column_name = N'criticality_id')) ELSE a.criticality_id END,
               remarks = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'remarks')
                              THEN (SELECT val FROM @col WHERE column_name = N'remarks') ELSE a.remarks END,
               template_id = @template_id,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.organization_dependency_asset a
         WHERE a.asset_id = @asset_id;
        SET @out_asset_id = @asset_id;
    END

    -- VALUE fields on the template: clear the empty ones, upsert the rest.
    DELETE v
      FROM grac_practice.asset_field_value v
      JOIN @tf t ON t.field_definition_id = v.field_definition_id AND t.storage_kind = N'VALUE' AND t.editable = 1
      JOIN @eff e ON e.field_key = t.field_key
     WHERE v.asset_id = @out_asset_id AND e.val IS NULL;
    MERGE grac_practice.asset_field_value AS tgt
    USING (
        SELECT t.field_definition_id, e.val,
               TRY_CONVERT(DECIMAL(38, 6), CASE WHEN t.data_type = N'QUANTITY_UNIT' THEN LEFT(e.val, CHARINDEX(N' ', e.val + N' ') - 1) ELSE e.val END) AS n,
               CASE WHEN t.data_type = N'DATE' THEN TRY_CONVERT(DATE, e.val, 23) END AS d,
               CASE WHEN t.lookup_source LIKE N'MASTER:%' AND t.is_multi = 0 THEN TRY_CONVERT(BIGINT, e.val) END AS r
          FROM @tf t JOIN @eff e ON e.field_key = t.field_key
         WHERE t.storage_kind = N'VALUE' AND t.editable = 1 AND e.val IS NOT NULL
    ) AS src
    ON tgt.asset_id = @out_asset_id AND tgt.field_definition_id = src.field_definition_id
    WHEN MATCHED AND tgt.value_text <> src.val THEN
        UPDATE SET value_text = src.val, value_number = src.n, value_date = src.d, value_ref = src.r,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (asset_id, field_definition_id, value_text, value_number, value_date, value_ref, entered_by)
        VALUES (@out_asset_id, src.field_definition_id, src.val, src.n, src.d, src.r, @actor);

    -- 430: installed firmware / OS history (BRD 4.6) when the form changes them.
    DECLARE @fw_old BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @stored WHERE field_key = N'firmware_version')),
            @fw_new BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'firmware_version')),
            @os_old BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @stored WHERE field_key = N'operating_system')),
            @os_new BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'operating_system'));
    DECLARE @patch_old NVARCHAR(100) = LEFT((SELECT val FROM @stored WHERE field_key = N'os_build_patch_level'), 100),
            @patch_new NVARCHAR(100) = LEFT((SELECT val FROM @eff WHERE field_key = N'os_build_patch_level'), 100);
    DECLARE @fw_on_tpl BIT = CASE WHEN EXISTS (SELECT 1 FROM @tf WHERE field_key = N'firmware_version' AND editable = 1) THEN 1 ELSE 0 END,
            @os_on_tpl BIT = CASE WHEN EXISTS (SELECT 1 FROM @tf WHERE field_key = N'operating_system' AND editable = 1) THEN 1 ELSE 0 END;
    DECLARE @inst_id BIGINT, @form_source NVARCHAR(100) = N'Asset form';
    IF @fw_on_tpl = 1 AND @fw_new IS NOT NULL AND ISNULL(@fw_old, -1) <> @fw_new
    BEGIN
        EXEC grac_practice.sp_asset_tech_install_apply
             @organization_id = @organization_id, @asset_id = @out_asset_id, @kind = N'FIRMWARE', @release_id = @fw_new,
             @installed_date = @today, @source = @form_source, @update_value = 0, @actor = @actor,
             @out_installation_id = @inst_id OUTPUT;
    END
    ELSE IF @fw_on_tpl = 1 AND @fw_new IS NULL AND @fw_old IS NOT NULL
        UPDATE grac_practice.asset_firmware_installation SET is_current = 0 WHERE asset_id = @out_asset_id AND is_current = 1;
    IF @os_on_tpl = 1 AND @os_new IS NOT NULL AND (ISNULL(@os_old, -1) <> @os_new OR ISNULL(@patch_old, N'') <> ISNULL(@patch_new, N''))
    BEGIN
        EXEC grac_practice.sp_asset_tech_install_apply
             @organization_id = @organization_id, @asset_id = @out_asset_id, @kind = N'OS', @release_id = @os_new,
             @build_patch_level = @patch_new, @installed_date = @today, @source = @form_source, @update_value = 0,
             @actor = @actor, @out_installation_id = @inst_id OUTPUT;
    END
    ELSE IF @os_on_tpl = 1 AND @os_new IS NULL AND @os_old IS NOT NULL
        UPDATE grac_practice.asset_os_installation SET is_current = 0 WHERE asset_id = @out_asset_id AND is_current = 1;

    -- 431: ownership / custody / location history and the acknowledgement it raises (5.3.2).
    DECLARE @assign_source NVARCHAR(100) = N'Asset form';
    EXEC grac_practice.sp_asset_assignment_snapshot
         @organization_id = @organization_id, @asset_id = @out_asset_id, @source = @assign_source,
         @raise_acknowledgement = 1, @actor = @actor;

    -- 446: Asset Value (5.1.18.5.7) -- recalculated when the ratings or method changed.
    DECLARE @val_status NVARCHAR(20), @val_message NVARCHAR(500), @val_changed BIT;          -- 446
    EXEC grac_practice.sp_asset_valuation_apply                                                -- 446
         @organization_id = @organization_id, @asset_id = @out_asset_id, @mode = N'AUTO', @source = N'FORM',   -- 446
         @actor_employee_id = @actor_employee_id, @actor = @actor,                             -- 446
         @out_status = @val_status OUTPUT, @out_message = @val_message OUTPUT, @out_changed = @val_changed OUTPUT;   -- 446
    -- 447: CIA / criticality consistency of the saved asset (19.7).
    DECLARE @cons_o INT, @cons_r INT, @cons_x INT;                                             -- 447
    EXEC grac_practice.sp_asset_consistency_evaluate                                           -- 447
         @organization_id = @organization_id, @asset_id = @out_asset_id, @actor = @actor,      -- 447
         @out_opened = @cons_o OUTPUT, @out_resolved = @cons_r OUTPUT, @out_reopened = @cons_x OUTPUT;   -- 447
    -- 448: privacy reviews of the saved asset (9.1.7).
    DECLARE @prv_o INT, @prv_c INT, @prv_x INT;                                                -- 448
    EXEC grac_practice.sp_asset_privacy_sync                                                   -- 448
         @organization_id = @organization_id, @asset_id = @out_asset_id, @actor = @actor,      -- 448
         @out_opened = @prv_o OUTPUT, @out_closed = @prv_c OUTPUT, @out_expired = @prv_x OUTPUT;   -- 448

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-register', @out_asset_id, CASE WHEN @asset_id IS NULL THEN N'ADD' ELSE N'SAVE' END,
            CASE WHEN @asset_id IS NULL THEN NULL ELSE @before END,
            (SELECT @template_id AS templateId,
                    (SELECT e.field_key AS fieldKey, e.val AS value FROM @eff e WHERE e.submitted = 1 FOR JSON PATH) AS changedValues
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    IF @val_status IN (N'INCOMPLETE', N'INVALID', N'OUT_OF_DATE')                             -- 446
        INSERT @issues (severity, field_key, message)                                          -- 446
        VALUES (N'WARNING', NULL, LEFT(CONCAT(N'Asset Value: ', @val_message), 500));          -- 446
    INSERT @issues (severity, field_key, message)                                              -- 447
    SELECT N'WARNING', NULL,                                                                   -- 447
           LEFT(CONCAT(N'Consistency (', CASE f.severity WHEN N'INFO' THEN N'information' WHEN N'WARNING' THEN N'warning'   -- 447
                                                         WHEN N'ERROR' THEN N'error' ELSE N'approval required' END, N'): ', f.message,   -- 447
                       CASE WHEN f.status = N'PENDING_APPROVAL' THEN N' -- acceptance awaiting approval.'          -- 447
                            WHEN f.action_code = N'BLOCK_TRANSITION' THEN N' -- blocks a move to Active until corrected or accepted.'   -- 447
                            WHEN f.action_code = N'REQUIRE_RATIONALE' THEN N' -- record a rationale on the Valuation tab.'   -- 447
                            WHEN f.action_code = N'CREATE_TASK' THEN N' -- a task was opened.' ELSE N'.' END), 500)   -- 447
      FROM grac_practice.asset_consistency_finding f                                           -- 447
     WHERE f.asset_id = @out_asset_id AND f.status IN (N'OPEN', N'PENDING_APPROVAL');          -- 447
    -- 448: privacy gaps (5.1.10 / 5.1.16 / 5.2.15) -- one summary, plus each blocking gap.
    INSERT @issues (severity, field_key, message)                                              -- 448
    SELECT N'WARNING', NULL, CONCAT(N'Privacy: ', COUNT(*), N' gap(s) to resolve or except (Privacy tab).')   -- 448
      FROM grac_practice.fn_asset_privacy_gaps(@organization_id, @out_asset_id) g              -- 448
     WHERE g.IsExcepted = 0                                                                    -- 448
    HAVING COUNT(*) > 0;                                                                       -- 448
    INSERT @issues (severity, field_key, message)                                              -- 448
    SELECT N'WARNING', NULL, LEFT(CONCAT(N'Privacy (', g.RequirementName, N'): ', g.Message,   -- 448
                                   CASE g.BlockTarget WHEN N'ACTIVE' THEN N' -- blocks a move to Active.'   -- 448
                                        ELSE N' -- blocks Disposed / Archived.' END), 500)    -- 448
      FROM grac_practice.fn_asset_privacy_gaps(@organization_id, @out_asset_id) g              -- 448
     WHERE g.IsExcepted = 0 AND g.Enforcement = N'BLOCK';                                      -- 448
    SET @out_result = N'SAVED';
    SELECT severity AS Severity, field_key AS FieldKey, message AS Message FROM @issues ORDER BY field_key;
END
GO
PRINT '448: sp_asset_register_save re-issued.';
GO

-- 447 body: privacy sync per organization.
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
PRINT '448: sp_asset_scheduler_run re-issued.';
GO

-- 447 body: blocking privacy gaps stop Active; blocking sanitization stops Disposed / Archived.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_lifecycle_transition
    @organization_id         BIGINT,
    @asset_id                BIGINT,
    @to_status_code          NVARCHAR(60),
    @reason_text             NVARCHAR(1000) = NULL,
    @reference_text          NVARCHAR(400)  = NULL,
    @evidence_text           NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_change_id           BIGINT         = NULL OUTPUT,
    @out_result              NVARCHAR(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @to_status_code = UPPER(LTRIM(RTRIM(ISNULL(@to_status_code, N''))));
    SET @reason_text = NULLIF(LTRIM(RTRIM(@reason_text)), N'');
    SET @reference_text = NULLIF(LTRIM(RTRIM(@reference_text)), N'');
    SET @evidence_text = NULLIF(LTRIM(RTRIM(@evidence_text)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54970, 'Organization not found.', 1;

    DECLARE @found BIT = 0, @rv BIGINT, @from NVARCHAR(60), @template_id BIGINT, @owner_id BIGINT;
    SELECT @found = 1, @rv = CONVERT(BIGINT, a.record_version), @from = COALESCE(cs.status_code, ls.status_code),
           @template_id = a.template_id, @owner_id = a.owner_id
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
     WHERE a.asset_id = @asset_id AND a.organization_id = @organization_id;
    IF @found = 0 THROW 54971, 'Asset not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54972, 'This asset was changed by someone else. Reload it and try again.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_change WHERE asset_id = @asset_id AND change_status = N'PENDING_APPROVAL')
        THROW 54973, 'A lifecycle change for this asset is awaiting approval. Approve, reject or cancel it first.', 1;
    IF @from IN (N'DISPOSED', N'ARCHIVED') AND @to_status_code = N'ACTIVE'
        THROW 54975, 'A disposed or archived asset cannot return to Active (BRD 5.4.3 / 19.9). Register a replacement asset instead.', 1;

    DECLARE @rule_id INT, @req_reason BIT, @req_approval BIT, @ref_label NVARCHAR(200), @req_evidence BIT,
            @req_form BIT, @req_owner BIT;
    SELECT TOP 1 @rule_id = r.transition_rule_id, @req_reason = r.requires_reason, @req_approval = r.requires_approval,
           @ref_label = g.reference_label, @req_evidence = g.requires_evidence, @req_form = g.requires_registered_form,
           @req_owner = g.requires_owner
      FROM grac_practice.entity_state_transition_rule r
      JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = r.transition_rule_id
     WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL
       AND r.from_status_code = @from AND r.to_status_code = @to_status_code;
    IF @rule_id IS NULL
    BEGIN
        DECLARE @allowed NVARCHAR(1000) = (
            SELECT STRING_AGG(s.status_name, N', ') WITHIN GROUP (ORDER BY s.display_order)
              FROM grac_practice.entity_state_transition_rule r
              JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = r.transition_rule_id
              JOIN grac_practice.entity_status_master s ON s.entity_type = N'Asset' AND s.status_code = r.to_status_code
             WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL AND r.from_status_code = @from);
        DECLARE @from_name NVARCHAR(120) = (SELECT status_name FROM grac_practice.entity_status_master
                                             WHERE entity_type = N'Asset' AND status_code = @from);
        DECLARE @target_name NVARCHAR(120) = (SELECT status_name FROM grac_practice.entity_status_master
                                               WHERE entity_type = N'Asset' AND status_code = @to_status_code);
        DECLARE @msg NVARCHAR(2048) = CONCAT(N'This asset cannot move from ', ISNULL(@from_name, @from), N' to ',
            ISNULL(@target_name, @to_status_code), N'. Configured moves: ', ISNULL(@allowed, N'none'), N'.');
        THROW 54974, @msg, 1;
    END

    IF @req_form = 1 AND @template_id IS NULL
        THROW 54979, 'Open the asset and save it on its form template first, so its required fields are validated.', 1;
    IF @req_owner = 1 AND @owner_id IS NULL
        THROW 54980, 'Set the asset owner first (identity, owner and source validation).', 1;
    IF @req_reason = 1 AND @reason_text IS NULL
        THROW 54976, 'A reason is required for this change.', 1;
    IF @ref_label IS NOT NULL AND @reference_text IS NULL
    BEGIN
        DECLARE @ref_msg NVARCHAR(400) = CONCAT(N'Enter the ', LOWER(@ref_label), N'.');
        THROW 54977, @ref_msg, 1;
    END
    IF @req_evidence = 1 AND @evidence_text IS NULL
        THROW 54978, 'Evidence is required for this change (document number, report or link).', 1;
    -- 435: required coverage configured to block activation (5.2.14, D42).
    IF @to_status_code = N'ACTIVE'
    BEGIN
        DECLARE @gaps NVARCHAR(1000) = (SELECT STRING_AGG(g.CoverageTypeLabel, N', ')
                                          FROM grac_practice.fn_asset_coverage_gaps(@organization_id) g
                                         WHERE g.AssetId = @asset_id AND g.MissingAction = N'BLOCK_ACTIVATION');
        IF @gaps IS NOT NULL
        BEGIN
            DECLARE @gap_msg NVARCHAR(1200) = CONCAT(N'The asset cannot become Active without its required coverage: ', @gaps,
                                                     N'. Map it on an active contract (Contracts) first.');
            THROW 54560, @gap_msg, 1;
        END
    END
    -- 447: open consistency findings with action Block transition (19.7, D148).
    IF @to_status_code = N'ACTIVE'                                                             -- 447
    BEGIN                                                                                      -- 447
        DECLARE @cons_o INT, @cons_r INT, @cons_x INT;                                         -- 447
        EXEC grac_practice.sp_asset_consistency_evaluate                                       -- 447
             @organization_id = @organization_id, @asset_id = @asset_id, @actor = @actor,      -- 447
             @out_opened = @cons_o OUTPUT, @out_resolved = @cons_r OUTPUT, @out_reopened = @cons_x OUTPUT;   -- 447
        DECLARE @cons NVARCHAR(1000) = (SELECT LEFT(STRING_AGG(CAST(f.message AS NVARCHAR(MAX)), N'; '), 900)   -- 447
                                          FROM grac_practice.asset_consistency_finding f       -- 447
                                         WHERE f.asset_id = @asset_id AND f.action_code = N'BLOCK_TRANSITION'   -- 447
                                           AND f.status IN (N'OPEN', N'PENDING_APPROVAL'));    -- 447
        IF @cons IS NOT NULL                                                                   -- 447
        BEGIN                                                                                  -- 447
            DECLARE @cons_msg NVARCHAR(1400) = CONCAT(N'The asset cannot become Active while consistency findings are open: ', @cons,   -- 447
                N'. Correct the asset or get the inconsistency accepted (Asset Register, Valuation tab) first.');   -- 447
            THROW 53037, @cons_msg, 1;                                                         -- 447
        END                                                                                    -- 447
    END                                                                                        -- 447
    -- 448: privacy requirements set to Block (5.1.16, 5.2.15, D162).
    IF @to_status_code IN (N'ACTIVE', N'DISPOSED', N'ARCHIVED')                                 -- 448
    BEGIN                                                                                      -- 448
        DECLARE @prv_target NVARCHAR(10) = CASE WHEN @to_status_code = N'ACTIVE' THEN N'ACTIVE' ELSE N'DISPOSAL' END;   -- 448
        DECLARE @prv NVARCHAR(1000) = (SELECT LEFT(STRING_AGG(CAST(CONCAT(g.RequirementName, N': ', g.Message) AS NVARCHAR(MAX)), N' '), 900)   -- 448
                                         FROM grac_practice.fn_asset_privacy_gaps(@organization_id, @asset_id) g   -- 448
                                        WHERE g.IsExcepted = 0 AND g.Enforcement = N'BLOCK' AND g.BlockTarget = @prv_target);   -- 448
        IF @prv IS NOT NULL AND @prv_target = N'ACTIVE'                                        -- 448
        BEGIN                                                                                  -- 448
            DECLARE @prv_msg NVARCHAR(1400) = CONCAT(N'The asset cannot become Active while privacy requirements are not met: ', @prv,   -- 448
                N' Complete the privacy fields or get an exception approved (Asset Privacy).');   -- 448
            THROW 53070, @prv_msg, 1;                                                          -- 448
        END                                                                                    -- 448
        IF @prv IS NOT NULL                                                                    -- 448
        BEGIN                                                                                  -- 448
            DECLARE @san_msg NVARCHAR(1400) = CONCAT(N'The asset cannot be disposed or archived yet: ', @prv,   -- 448
                N' Record the sanitization method, date and evidence first.');                 -- 448
            THROW 53071, @san_msg, 1;                                                          -- 448
        END                                                                                    -- 448
    END                                                                                        -- 448
    -- 440: retiring the asset is blocked while active critical relationships
    -- rely on it and were not accepted for its retirement (5.4.2, D86).
    IF @to_status_code IN (N'SANITIZATION_PENDING', N'DISPOSAL_APPROVAL', N'DISPOSED', N'ARCHIVED')
    BEGIN
        DECLARE @blockers NVARCHAR(1000) = (
            SELECT LEFT(STRING_AGG(CONCAT(c.CiName, N' (', t.type_name, N')'), N', '), 900)
              FROM grac_practice.fn_asset_relationship_blockers(@organization_id, N'ASSET', @asset_id) b
              JOIN grac_practice.asset_relationship_type t ON t.type_code = b.TypeCode
              LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) c ON c.CiKind = b.DependentKind AND c.CiId = b.DependentId);
        IF @blockers IS NOT NULL
        BEGIN
            DECLARE @blk_msg NVARCHAR(1400) = CONCAT(N'Active critical dependencies still rely on this asset: ', @blockers,
                N'. Reassign or retire them, or accept them for retirement (Asset Relationships), first.');
            THROW 54719, @blk_msg, 1;
        END
    END

    DECLARE @log_id BIGINT;
    BEGIN TRAN;
    IF @req_approval = 1
    BEGIN
        INSERT grac_practice.asset_lifecycle_change
            (organization_id, asset_id, transition_rule_id, from_status_code, to_status_code, change_status,
             reason_text, reference_text, evidence_text, requested_by, requested_by_employee_id)
        VALUES (@organization_id, @asset_id, @rule_id, @from, @to_status_code, N'PENDING_APPROVAL',
                @reason_text, @reference_text, @evidence_text, @actor, @actor_employee_id);
        SET @out_change_id = SCOPE_IDENTITY();
        SET @out_result = N'PENDING_APPROVAL';
    END
    ELSE
    BEGIN
        EXEC grac_practice.sp_asset_lifecycle_apply
             @organization_id = @organization_id, @asset_id = @asset_id,
             @from_status_code = @from, @to_status_code = @to_status_code,
             @reason_code = N'LIFECYCLE', @reason_text = @reason_text,
             @actor_employee_id = @actor_employee_id, @actor = @actor, @out_log_id = @log_id OUTPUT;
        INSERT grac_practice.asset_lifecycle_change
            (organization_id, asset_id, transition_rule_id, from_status_code, to_status_code, change_status,
             reason_text, reference_text, evidence_text, requested_by, requested_by_employee_id, transition_log_id)
        VALUES (@organization_id, @asset_id, @rule_id, @from, @to_status_code, N'COMPLETED',
                @reason_text, @reference_text, @evidence_text, @actor, @actor_employee_id, @log_id);
        SET @out_change_id = SCOPE_IDENTITY();
        SET @out_result = N'COMPLETED';
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-lifecycle', @asset_id, CASE WHEN @req_approval = 1 THEN N'REQUEST' ELSE N'TRANSITION' END,
            (SELECT @from AS statusCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @out_change_id AS changeId, @to_status_code AS toStatusCode, @out_result AS result,
                    @reason_text AS reason, @reference_text AS reference, @evidence_text AS evidence, @log_id AS transitionLogId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @out_change_id AS ChangeId, @out_result AS Result,
           CASE WHEN @out_result = N'COMPLETED' THEN @to_status_code ELSE @from END AS StatusCode;
END
GO
PRINT '448: sp_asset_lifecycle_transition re-issued.';
GO

-- 439 body: privacy and retention review sources.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_sweep
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @opened          INT           = NULL OUTPUT,
    @closed          INT           = NULL OUTPUT,
    @queued          INT           = NULL OUTPUT,
    @errors          INT           = NULL OUTPUT,
    @error_text      NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SELECT @opened = 0, @closed = 0, @queued = 0, @errors = 0, @error_text = NULL;
    DECLARE @org BIGINT = @organization_id;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    CREATE TABLE #due (
        occurrence_key NVARCHAR(200) NOT NULL PRIMARY KEY,
        activity_code  NVARCHAR(40)  NOT NULL,
        object_type    NVARCHAR(30)  NOT NULL,
        object_id      BIGINT        NOT NULL,
        ref_id         BIGINT        NULL,
        asset_id       BIGINT        NULL,
        contract_id    BIGINT        NULL,
        trigger_date   DATE          NOT NULL,
        object_ref     NVARCHAR(200) NULL,
        object_title   NVARCHAR(400) NULL,
        severity_code  NVARCHAR(10)  NOT NULL
    );

    -- Contract renewal (9.1.5): earliest of notice, decision and end date of
    -- the version in force; stops once a renewal of that version completes.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(x.act, N':CV:', cv.version_id, N':', CONVERT(NVARCHAR(8), t.d, 112)), x.act, N'CONTRACT_VERSION', cv.version_id,
           NULL, NULL, c.contract_id, t.d, c.contract_number, CONCAT(c.contract_name, N' (version ', cv.version_no, N')'),
           grac_practice.fn_asset_ntf_version_severity(cv.version_id)
      FROM grac_practice.asset_contract c
      JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
     CROSS APPLY (SELECT MIN(v.d) AS d FROM (VALUES (cv.notice_date), (cv.decision_date), (cv.effective_end)) v(d)) t
     CROSS APPLY (SELECT grac_practice.fn_asset_ntf_contract_activity(c.contract_type) AS act) x
     WHERE c.organization_id = @org AND c.contract_status IN (N'ACTIVE', N'APPROVED', N'EXPIRED')
       AND cv.version_type <> N'TERMINATION' AND t.d IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_renewal r
                         JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
                        WHERE r.prior_version_id = cv.version_id AND s.status_code = N'COMPLETED');

    -- Contract expiry (9.1.5): the version in force expired without a successor.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'CONTRACT_EXPIRY:CV:', cv.version_id, N':', CONVERT(NVARCHAR(8), DATEADD(DAY, 1, cv.effective_end), 112)),
           N'CONTRACT_EXPIRY', N'CONTRACT_VERSION', cv.version_id, NULL, NULL, c.contract_id, DATEADD(DAY, 1, cv.effective_end),
           c.contract_number, CONCAT(c.contract_name, N' (version ', cv.version_no, N') expired'),
           grac_practice.fn_asset_ntf_version_severity(cv.version_id)
      FROM grac_practice.asset_contract c
      JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = cv.current_status_id
     WHERE c.organization_id = @org AND s.status_code = N'EXPIRED' AND cv.effective_end IS NOT NULL;

    -- Assets that are in use for the technology sources (as 431 D24: not in
    -- acquisition, not lost / stolen, not disposed / archived).
    DECLARE @in_use TABLE (asset_id BIGINT NOT NULL PRIMARY KEY, asset_name NVARCHAR(400) NULL, severity_code NVARCHAR(10) NOT NULL);
    INSERT @in_use (asset_id, asset_name, severity_code)
    SELECT a.asset_id, a.asset_name, grac_practice.fn_asset_ntf_asset_severity(a.asset_id)
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
     WHERE a.organization_id = @org
       AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DRAFT', N'REQUESTED', N'APPROVED', N'ORDERED', N'LOST', N'STOLEN',
                                                     N'DISPOSED', N'ARCHIVED');

    -- Model support end (9.1.3 "Model or OS support end"; D50).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT DISTINCT CONCAT(N'TECH_SUPPORT_END:MODEL:', u.asset_id, N':', m.model_id, N':', CONVERT(NVARCHAR(8), x.d, 112)),
           N'TECH_SUPPORT_END', N'ASSET_MODEL', u.asset_id, m.model_id, u.asset_id, NULL, x.d,
           u.asset_name, CONCAT(N'Model ', m.model_name, N' support ends'), u.severity_code
      FROM @in_use u
      JOIN grac_practice.asset_field_value v ON v.asset_id = u.asset_id
      JOIN grac_practice.asset_field_definition fd ON fd.field_definition_id = v.field_definition_id AND fd.field_key = N'model'
      JOIN grac_practice.asset_model m ON m.model_id = v.value_ref
     CROSS APPLY (SELECT COALESCE(m.end_extended_support_date, m.end_security_support_date, m.end_standard_support_date) AS d) x
     WHERE x.d IS NOT NULL;

    -- Installed OS / firmware release support end (the 430 technology status).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(x.act, N':', t.Kind, N':', u.asset_id, N':', t.CurrentReleaseId, N':', CONVERT(NVARCHAR(8), t.SupportEndDate, 112)),
           x.act, CASE t.Kind WHEN N'OS' THEN N'ASSET_OS' ELSE N'ASSET_FIRMWARE' END, u.asset_id, t.CurrentReleaseId, u.asset_id, NULL,
           t.SupportEndDate, u.asset_name, CONCAT(t.CurrentLabel, N' support ends'), u.severity_code
      FROM grac_practice.fn_asset_technology_status(@org, NULL) t
      JOIN @in_use u ON u.asset_id = t.AssetId
     CROSS APPLY (SELECT CASE t.Kind WHEN N'OS' THEN N'TECH_SUPPORT_END' ELSE N'FIRMWARE_SUPPORT_END' END AS act) x
     WHERE t.CurrentReleaseId IS NOT NULL AND t.SupportEndDate IS NOT NULL;

    -- Technology exception expiry (430).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'EXCEPTION_EXPIRY:EXC:', x.exception_id, N':', CONVERT(NVARCHAR(8), x.expiry_date, 112)),
           N'EXCEPTION_EXPIRY', N'TECH_EXCEPTION', x.exception_id, NULL, x.asset_id, NULL, x.expiry_date,
           CONCAT(N'Exception #', x.exception_id),
           CONCAT(CASE x.technology_kind WHEN N'OS' THEN N'OS' ELSE N'Firmware' END, N' exception for ',
                  COALESCE(a.asset_name, N'model ' + m.model_name, N'-')),
           CASE WHEN x.asset_id IS NULL THEN N'MEDIUM' ELSE grac_practice.fn_asset_ntf_asset_severity(x.asset_id) END
      FROM grac_practice.asset_technology_exception x
      LEFT JOIN grac_practice.organization_dependency_asset a ON a.asset_id = x.asset_id
      LEFT JOIN grac_practice.asset_model m ON m.model_id = x.model_id
     WHERE x.organization_id = @org AND x.status = N'APPROVED';

    -- Custodian attestation (431): open attestations by due date.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'CUSTODIAN_ATTESTATION:ATT:', t.attestation_id, N':', CONVERT(NVARCHAR(8), t.due_date, 112)),
           N'CUSTODIAN_ATTESTATION', N'ATTESTATION', t.attestation_id, NULL, t.asset_id, NULL, t.due_date,
           a.asset_name, CONCAT(N'Attestation of ', a.asset_name, N' (', LOWER(t.assignee_role), N')'),
           grac_practice.fn_asset_ntf_asset_severity(t.asset_id)
      FROM grac_practice.asset_attestation t
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = t.asset_id
     WHERE t.organization_id = @org AND t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS', N'OVERDUE', N'ESCALATED');

    -- 438: recurring asset activities -- open asset-task occurrences by due date.
    -- 439: by the approved revised due date when rescheduled (the old
    -- occurrence is superseded, not deleted); a re-test after a failed
    -- result with the fail policy on is Critical (9.1.4).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(tp.notification_activity_code, N':ACT:', ao.occurrence_id, N':',
                  CONVERT(NVARCHAR(8), ISNULL(ao.revised_due_date, ao.due_date), 112)),                -- 439
           tp.notification_activity_code, N'ACTIVITY', ao.occurrence_id, NULL, ao.asset_id, cv.contract_id,
           ISNULL(ao.revised_due_date, ao.due_date),                                                   -- 439
           a.asset_name, CONCAT(tp.template_name, CASE WHEN ao.is_retest = 1 THEN N' re-test' ELSE N'' END, N' of ', a.asset_name),
           CASE WHEN ao.is_retest = 1 AND st.RestrictOnFail = 1 THEN N'CRITICAL'                        -- 439
                ELSE grac_practice.fn_asset_ntf_asset_severity(ao.asset_id) END
      FROM grac_practice.asset_activity_occurrence ao
      JOIN grac_practice.asset_activity_template tp ON tp.template_code = ao.template_code
      JOIN grac_practice.fn_asset_activity_settings(@org) st ON st.TemplateCode = ao.template_code      -- 439
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = ao.asset_id
      LEFT JOIN grac_practice.asset_contract_version cv ON cv.version_id = ao.contract_version_id
     WHERE ao.organization_id = @org AND ao.status = N'OPEN' AND ao.decision = N'ASSET_TASK';

    -- 439: evidence / certificate expiry (9.1.7) -- the evidence date fields of
    -- assets in use.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'EVIDENCE_EXPIRY:EV:', u.asset_id, N':', fd.field_definition_id, N':', CONVERT(NVARCHAR(8), v.value_date, 112)),
           N'EVIDENCE_EXPIRY', N'ASSET_EVIDENCE', u.asset_id, fd.field_definition_id, u.asset_id, NULL, v.value_date,
           u.asset_name, CONCAT(ef.evidence_name, N' of ', u.asset_name, N' expires'), u.severity_code
      FROM @in_use u
      JOIN grac_practice.asset_field_value v ON v.asset_id = u.asset_id AND v.value_date IS NOT NULL
      JOIN grac_practice.asset_field_definition fd ON fd.field_definition_id = v.field_definition_id
      JOIN grac_practice.asset_evidence_field ef ON ef.field_key = fd.field_key AND ef.is_active = 1;

    -- 448: privacy reviews and retention ends from open reviews; approved
    -- privacy exceptions expiring (9.1.7, 448).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,   -- 448
                 object_ref, object_title, severity_code)                                     -- 448
    SELECT CONCAT(x.act, N':PR:', r.review_id, N':', CONVERT(NVARCHAR(8), r.due_date, 112)),   -- 448
           x.act, N'PRIVACY_REVIEW', r.review_id, NULL, r.asset_id, NULL, r.due_date, a.asset_name,   -- 448
           CONCAT(CASE r.review_kind WHEN N'PRIVACY' THEN N'Privacy / DPIA review of ' ELSE N'Retention end of personal data on ' END,   -- 448
                  a.asset_name),                                                               -- 448
           grac_practice.fn_asset_ntf_asset_severity(r.asset_id)                               -- 448
      FROM grac_practice.asset_privacy_review r                                                -- 448
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = r.asset_id            -- 448
     CROSS APPLY (SELECT CASE r.review_kind WHEN N'PRIVACY' THEN N'PRIVACY_REVIEW' ELSE N'RETENTION_REVIEW' END AS act) x   -- 448
     WHERE r.organization_id = @org AND r.status = N'OPEN';                                    -- 448
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,   -- 448
                 object_ref, object_title, severity_code)                                     -- 448
    SELECT CONCAT(N'PRIVACY_REVIEW:PX:', e.exception_id, N':', CONVERT(NVARCHAR(8), e.expiry_date, 112)),   -- 448
           N'PRIVACY_REVIEW', N'PRIVACY_EXCEPTION', e.exception_id, NULL, e.asset_id, NULL, e.expiry_date, a.asset_name,   -- 448
           CONCAT(N'Privacy exception (', q.requirement_name, N') of ', a.asset_name, N' expires'),   -- 448
           grac_practice.fn_asset_ntf_asset_severity(e.asset_id)                               -- 448
      FROM grac_practice.asset_privacy_exception e                                             -- 448
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = e.asset_id            -- 448
      JOIN grac_practice.asset_privacy_requirement q ON q.requirement_code = e.requirement_code   -- 448
     WHERE e.organization_id = @org AND e.status = N'APPROVED';                                -- 448

    -- 2. Close / reopen.
    UPDATE o
       SET status = CASE WHEN EXISTS (SELECT 1 FROM #due d WHERE d.activity_code = o.activity_code AND d.object_type = o.object_type
                                                                AND d.object_id = o.object_id)
                         THEN N'SUPERSEDED' ELSE N'COMPLETED' END,
           close_reason = CASE WHEN EXISTS (SELECT 1 FROM #due d WHERE d.activity_code = o.activity_code AND d.object_type = o.object_type
                                                                      AND d.object_id = o.object_id)
                               THEN N'The trigger date or reference changed; a new occurrence replaces it.'
                               ELSE N'No longer due (completed, renewed, changed or withdrawn).' END,
           closed_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_notification_occurrence o
     WHERE o.organization_id = @org AND o.status = N'OPEN'
       AND NOT EXISTS (SELECT 1 FROM #due d WHERE d.occurrence_key = o.occurrence_key);
    SET @closed = @@ROWCOUNT;

    UPDATE o
       SET status = N'OPEN', closed_dt = NULL, close_reason = NULL, object_ref = d.object_ref, object_title = d.object_title,
           severity_code = d.severity_code, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_notification_occurrence o
      JOIN #due d ON d.occurrence_key = o.occurrence_key
     WHERE o.organization_id = @org
       AND (o.status <> N'OPEN' OR ISNULL(o.object_title, N'') <> ISNULL(d.object_title, N'') OR o.severity_code <> d.severity_code
            OR ISNULL(o.object_ref, N'') <> ISNULL(d.object_ref, N''));

    -- 3. Open.
    INSERT grac_practice.asset_notification_occurrence
        (organization_id, occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
         object_ref, object_title, severity_code, status, entered_by)
    SELECT @org, d.occurrence_key, d.activity_code, d.object_type, d.object_id, d.ref_id, d.asset_id, d.contract_id, d.trigger_date,
           d.object_ref, d.object_title, d.severity_code, N'OPEN', @actor
      FROM #due d
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_occurrence o
                        WHERE o.organization_id = @org AND o.occurrence_key = d.occurrence_key);
    SET @opened = @@ROWCOUNT;

    -- 4. Fire.
    CREATE TABLE #np (party_code NVARCHAR(30) NOT NULL, employee_id BIGINT NOT NULL);
    CREATE TABLE #rcp (employee_id BIGINT NULL, role_id BIGINT NULL, role_name NVARCHAR(200) NULL, reason_code NVARCHAR(30) NOT NULL);
    CREATE TABLE #holders (
        EmployeeId BIGINT, EmployeeCode NVARCHAR(100), EmployeeName NVARCHAR(240),
        Email NVARCHAR(250), Designation NVARCHAR(200), Department NVARCHAR(200),
        RoleId BIGINT, RoleName NVARCHAR(200)
    );

    DECLARE @occ BIGINT, @act NVARCHAR(40), @otype NVARCHAR(30), @oid BIGINT, @asset BIGINT, @contract BIGINT, @trigger DATE,
            @ref NVARCHAR(200), @title NVARCHAR(400), @sev NVARCHAR(10), @last_date DATE,
            @p BIGINT, @pver INT, @ack NVARCHAR(10), @wdays BIT, @channels NVARCHAR(60),
            @stage BIGINT, @sdate DATE, @kind NVARCHAR(12), @offset INT, @level TINYINT, @class NVARCHAR(20),
            @act_name NVARCHAR(160), @basis NVARCHAR(30), @subject NVARCHAR(400), @body NVARCHAR(MAX), @n INT,
            @role BIGINT, @role_name NVARCHAR(200);

    DECLARE occ_cur CURSOR LOCAL STATIC FOR
        SELECT o.occurrence_id, o.activity_code, o.object_type, o.object_id, o.asset_id, o.contract_id, o.trigger_date,
               o.object_ref, o.object_title, o.severity_code, o.last_stage_date
          FROM grac_practice.asset_notification_occurrence o
         WHERE o.organization_id = @org AND o.status = N'OPEN'
           AND (o.snoozed_until IS NULL OR o.snoozed_until <= @today)
         ORDER BY o.trigger_date, o.occurrence_id;
    OPEN occ_cur;
    FETCH NEXT FROM occ_cur INTO @occ, @act, @otype, @oid, @asset, @contract, @trigger, @ref, @title, @sev, @last_date;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SELECT @p = NULL, @pver = NULL, @ack = NULL, @wdays = NULL, @channels = NULL,
                   @stage = NULL, @sdate = NULL, @kind = NULL, @offset = NULL, @level = NULL, @class = NULL;
            SELECT @p = ProfileId, @pver = VersionNo, @ack = AckMode, @wdays = WorkingDaysOnly, @channels = Channels
              FROM grac_practice.fn_asset_ntf_profile_for(@org, @act, @sev, @today);

            IF @p IS NOT NULL
                SELECT TOP 1 @stage = s.stage_id, @sdate = x.d, @kind = s.stage_kind, @offset = s.offset_days,
                       @level = s.escalation_level, @class = s.notification_class
                  FROM grac_practice.asset_notification_stage s
                 CROSS APPLY (SELECT grac_practice.fn_asset_ntf_stage_date(@trigger, s.stage_kind, s.offset_days, @wdays) AS d) x
                 WHERE s.profile_id = @p AND s.is_active = 1 AND x.d <= @today
                 ORDER BY x.d DESC, s.escalation_level DESC, s.stage_id DESC;

            IF @stage IS NOT NULL AND @sdate > ISNULL(@last_date, CONVERT(DATE, '19000101', 112))
            BEGIN
                -- 9.1.2: an escalation on a critical object is a Critical notification (D53).
                IF @sev = N'CRITICAL' AND @kind = N'ESCALATION' SET @class = N'CRITICAL';

                DELETE FROM #np;
                DELETE FROM #rcp;
                EXEC grac_practice.sp_asset_notification_parties @occurrence_id = @occ;

                INSERT #rcp (employee_id, role_id, role_name, reason_code)
                SELECT np.employee_id, NULL, NULL, sr.recipient_code
                  FROM grac_practice.asset_notification_stage_recipient sr
                  JOIN #np np ON np.party_code = sr.recipient_code
                 WHERE sr.stage_id = @stage AND sr.recipient_code <> N'ROLE';
                INSERT #rcp (employee_id, role_id, role_name, reason_code)
                SELECT np.employee_id, NULL, NULL, m.recipient_code
                  FROM grac_practice.asset_escalation_matrix m
                  JOIN #np np ON np.party_code = m.recipient_code
                 WHERE m.organization_id = @org AND m.severity_code = @sev AND m.escalation_level = @level
                   AND m.recipient_code <> N'ROLE';

                DECLARE role_cur CURSOR LOCAL STATIC FOR
                    SELECT DISTINCT r.role_id, r.role_name
                      FROM (SELECT sr.role_id FROM grac_practice.asset_notification_stage_recipient sr
                             WHERE sr.stage_id = @stage AND sr.recipient_code = N'ROLE'
                            UNION
                            SELECT m.role_id FROM grac_practice.asset_escalation_matrix m
                             WHERE m.organization_id = @org AND m.severity_code = @sev AND m.escalation_level = @level
                               AND m.recipient_code = N'ROLE') x
                      JOIN grac_practice.organization_role r ON r.role_id = x.role_id;
                OPEN role_cur;
                FETCH NEXT FROM role_cur INTO @role, @role_name;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    DELETE FROM #holders;
                    INSERT INTO #holders
                        EXEC grac_practice.sp_org_role_holders_list @organization_id = @org, @role_id = @role;
                    IF EXISTS (SELECT 1 FROM #holders)
                    BEGIN
                        INSERT #rcp (employee_id, role_id, role_name, reason_code)
                        SELECT EmployeeId, RoleId, RoleName, N'ROLE' FROM #holders;
                    END
                    ELSE
                    BEGIN
                        -- An empty role still records the obligation (213 precedent).
                        INSERT #rcp (employee_id, role_id, role_name, reason_code) VALUES (NULL, @role, @role_name, N'ROLE');
                    END
                    FETCH NEXT FROM role_cur INTO @role, @role_name;
                END
                CLOSE role_cur;
                DEALLOCATE role_cur;

                IF NOT EXISTS (SELECT 1 FROM #rcp)
                    INSERT #rcp (employee_id, role_id, role_name, reason_code) VALUES (NULL, NULL, NULL, N'UNRESOLVED');

                SELECT @act_name = activity_name, @basis = trigger_basis
                  FROM grac_practice.asset_notification_activity WHERE activity_code = @act;
                SET @subject = LEFT(CONCAT(N'[GRAC] ',
                    CASE @class WHEN N'INFORMATIONAL' THEN N'Information' WHEN N'REMINDER' THEN N'Reminder'
                                WHEN N'ESCALATION' THEN N'Escalation' ELSE N'Critical' END,
                    N': ', @act_name, N' - ', ISNULL(@ref, N'-'),
                    CASE @kind WHEN N'REMINDER' THEN CONCAT(N' due in ', @offset, N' day(s)')
                               WHEN N'DUE' THEN N' due today'
                               ELSE CASE WHEN @offset = 0 THEN N' reached its date' ELSE CONCAT(N' ', @offset, N' day(s) overdue') END END), 400);
                SET @body = CONCAT(
                    @act_name, CHAR(13), CHAR(10), CHAR(13), CHAR(10),
                    N'Reference: ', ISNULL(@ref, N'-'), CHAR(13), CHAR(10),
                    N'Subject:   ', ISNULL(@title, N'-'), CHAR(13), CHAR(10),
                    N'Date:      ', CONVERT(NVARCHAR(10), @trigger, 23), N' (', LOWER(REPLACE(@basis, N'_', N' ')), N')', CHAR(13), CHAR(10),
                    N'Stage:     ', CASE @kind WHEN N'REMINDER' THEN CONCAT(@offset, N' day(s) before')
                                               WHEN N'DUE' THEN N'due date'
                                               ELSE CONCAT(N'escalation level ', @level, N', ', @offset, N' day(s) after') END, CHAR(13), CHAR(10),
                    N'Severity:  ', @sev, CHAR(13), CHAR(10),
                    CASE @ack WHEN N'ACTION' THEN N'Acknowledge with the action taken.'
                              WHEN N'MANAGER' THEN N'Acknowledge with the action taken; your manager confirms the acknowledgement.'
                              WHEN N'READ' THEN N'Mark as read once seen.' ELSE N'' END);

                BEGIN TRAN;
                INSERT grac_practice.asset_notification_outbox
                    (organization_id, occurrence_id, profile_id, profile_version, stage_id, stage_kind, stage_offset_days, stage_date,
                     escalation_level, notification_class, activity_code, object_type, object_id, asset_id, contract_id, object_ref,
                     object_title, trigger_date, severity_code, recipient_employee_id, recipient_name, recipient_email,
                     recipient_manager_id, role_id, role_name, recipient_reason_code, channels, ack_mode, subject, body_text,
                     status_code, failure_reason, entered_by)
                SELECT @org, @occ, @p, @pver, @stage, @kind, @offset, @sdate, @level, @class, @act, @otype, @oid, @asset, @contract, @ref,
                       @title, @trigger, @sev, r.employee_id, e.employee_name, e.email, e.reporting_officer_id, r.role_id, r.role_name,
                       r.reason_code, @channels, @ack, @subject, @body,
                       CASE WHEN r.employee_id IS NULL THEN N'Suppressed' ELSE N'Pending' END,
                       CASE WHEN r.employee_id IS NULL AND r.reason_code = N'ROLE' THEN N'The role has no active holder.'
                            WHEN r.employee_id IS NULL THEN N'No recipient could be resolved for this stage.' END,
                       @actor
                  FROM (SELECT employee_id, role_id, role_name, reason_code,
                               ROW_NUMBER() OVER (PARTITION BY ISNULL(employee_id, -1)
                                                  ORDER BY CASE WHEN role_id IS NULL THEN 0 ELSE 1 END, reason_code) AS rn
                          FROM #rcp) r
                  LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.employee_id
                 WHERE r.rn = 1
                   AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_outbox x
                                    WHERE x.occurrence_id = @occ AND x.stage_id = @stage
                                      AND ((x.recipient_employee_id IS NULL AND r.employee_id IS NULL)
                                           OR x.recipient_employee_id = r.employee_id));
                SET @n = @@ROWCOUNT;
                UPDATE grac_practice.asset_notification_occurrence
                   SET last_stage_id = @stage, last_stage_date = @sdate,
                       escalation_level = CASE WHEN @level > escalation_level THEN @level ELSE escalation_level END,
                       last_notified_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE occurrence_id = @occ;
                COMMIT;
                SET @queued = @queued + @n;
            END
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            IF CURSOR_STATUS('local', 'role_cur') >= -1
            BEGIN
                IF CURSOR_STATUS('local', 'role_cur') >= 0 CLOSE role_cur;
                DEALLOCATE role_cur;
            END
            SET @errors = @errors + 1;
            SET @error_text = LEFT(CONCAT(@error_text, CASE WHEN @error_text IS NULL THEN N'' ELSE CHAR(10) END,
                                          N'Occurrence ', @occ, N': ', ERROR_MESSAGE()), 4000);
        END CATCH
        FETCH NEXT FROM occ_cur INTO @occ, @act, @otype, @oid, @asset, @contract, @trigger, @ref, @title, @sev, @last_date;
    END
    CLOSE occ_cur;
    DEALLOCATE occ_cur;
END
GO
PRINT '448: sp_asset_notification_sweep re-issued.';
GO

-- 439 body: privacy review and privacy exception parties.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_parties
    @occurrence_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @org BIGINT, @otype NVARCHAR(30), @oid BIGINT, @asset BIGINT, @ref BIGINT;              -- 439: @ref
    SELECT @org = organization_id, @otype = object_type, @oid = object_id, @asset = asset_id, @ref = ref_id
      FROM grac_practice.asset_notification_occurrence WHERE occurrence_id = @occurrence_id;
    IF @org IS NULL RETURN;

    DECLARE @raw TABLE (party_code NVARCHAR(30) NOT NULL, val NVARCHAR(100) NOT NULL);

    IF @asset IS NOT NULL
    BEGIN
        INSERT @raw (party_code, val)
        SELECT N'ASSET_OWNER', CAST(a.owner_id AS NVARCHAR(30))
          FROM grac_practice.organization_dependency_asset a
         WHERE a.asset_id = @asset AND a.owner_id IS NOT NULL;
        INSERT @raw (party_code, val)
        SELECT CASE v.FieldKey WHEN N'business_owner' THEN N'BUSINESS_OWNER' WHEN N'technical_owner' THEN N'TECHNICAL_OWNER'
                               WHEN N'custodian' THEN N'CUSTODIAN' WHEN N'maintenance_owner' THEN N'MAINTENANCE_OWNER'
                               WHEN N'compliance_owner' THEN N'COMPLIANCE_OWNER' WHEN N'privacy_owner' THEN N'PRIVACY_OWNER'
                               ELSE N'SECURITY_OWNER' END,
               LEFT(LTRIM(RTRIM(v.Value)), 100)
          FROM grac_practice.fn_asset_stored_values(@asset) v
         WHERE v.FieldKey IN (N'business_owner', N'technical_owner', N'custodian', N'maintenance_owner', N'compliance_owner',
                              N'privacy_owner', N'information_security_owner')
           AND NULLIF(LTRIM(RTRIM(v.Value)), N'') IS NOT NULL;
    END

    IF @otype = N'CONTRACT_VERSION'
    BEGIN
        INSERT @raw (party_code, val)
        SELECT x.code, CAST(x.emp AS NVARCHAR(30))
          FROM grac_practice.asset_contract_version cv
         CROSS APPLY (VALUES (N'CONTRACT_OWNER', cv.contract_owner_id), (N'PROCUREMENT_OWNER', cv.procurement_owner_id),
                             (N'ACTIVITY_OWNER', COALESCE(cv.contract_owner_id, cv.procurement_owner_id))) x(code, emp)
         WHERE cv.version_id = @oid AND x.emp IS NOT NULL;
        INSERT @raw (party_code, val)
        SELECT DISTINCT N'AFFECTED_ASSET_OWNERS', CAST(a.owner_id AS NVARCHAR(30))
          FROM grac_practice.asset_contract_coverage cc
          JOIN grac_practice.organization_dependency_asset a ON a.asset_id = cc.asset_id
         WHERE cc.version_id = @oid AND cc.coverage_state <> N'EXCLUDED' AND a.owner_id IS NOT NULL;
    END
    ELSE IF @otype = N'TECH_EXCEPTION'
    BEGIN
        INSERT @raw (party_code, val)
        SELECT x.code, CAST(x.emp AS NVARCHAR(30))
          FROM grac_practice.asset_technology_exception t
         CROSS APPLY (VALUES (N'ACTIVITY_OWNER', t.owner_employee_id), (N'EXCEPTION_APPROVER', t.decided_by_employee_id)) x(code, emp)
         WHERE t.exception_id = @oid AND x.emp IS NOT NULL;
    END
    ELSE IF @otype = N'ATTESTATION'
    BEGIN
        INSERT @raw (party_code, val)
        SELECT N'ACTIVITY_OWNER', CASE WHEN t.assignee_employee_id IS NOT NULL THEN CAST(t.assignee_employee_id AS NVARCHAR(30))
                                       ELSE N'T:' + CAST(t.assignee_team_id AS NVARCHAR(30)) END
          FROM grac_practice.asset_attestation t
         WHERE t.attestation_id = @oid AND (t.assignee_employee_id IS NOT NULL OR t.assignee_team_id IS NOT NULL);
    END
    ELSE IF @otype = N'ACTIVITY'                                                       -- 438
    BEGIN
        -- Activity owner: the task owner, else the template owner field, else
        -- the asset owner; the owner of the linked contract version too (9.1.4).
        INSERT @raw (party_code, val)
        SELECT TOP 1 N'ACTIVITY_OWNER', x.val
          FROM (SELECT 0 AS rk, CAST(t.assigned_to_employee_id AS NVARCHAR(100)) AS val
                  FROM grac_practice.asset_activity_occurrence ao
                  JOIN grac_practice.practice_task t ON t.task_id = ao.task_id
                 WHERE ao.occurrence_id = @oid AND t.assigned_to_employee_id IS NOT NULL
                UNION ALL
                SELECT 1, LEFT(v.value_text, 100)
                  FROM grac_practice.asset_activity_occurrence ao
                  JOIN grac_practice.asset_activity_template tp ON tp.template_code = ao.template_code
                  JOIN grac_practice.asset_field_value v ON v.asset_id = ao.asset_id
                  JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id
                                                             AND f.field_key = tp.owner_field_key
                 WHERE ao.occurrence_id = @oid
                UNION ALL
                SELECT 2, r.val FROM @raw r WHERE r.party_code = N'ASSET_OWNER') x
         ORDER BY x.rk;
        INSERT @raw (party_code, val)
        SELECT N'CONTRACT_OWNER', CAST(cv.contract_owner_id AS NVARCHAR(30))
          FROM grac_practice.asset_activity_occurrence ao
          JOIN grac_practice.asset_contract_version cv ON cv.version_id = ao.contract_version_id
         WHERE ao.occurrence_id = @oid AND cv.contract_owner_id IS NOT NULL;
    END
    ELSE IF @otype = N'ASSET_EVIDENCE'                                                 -- 439
    BEGIN
        -- Evidence owner: the owner field named by the evidence catalogue
        -- (a person), else the asset owner (9.1 evidence / certificate expiry).
        INSERT @raw (party_code, val)
        SELECT TOP 1 N'ACTIVITY_OWNER', x.val
          FROM (SELECT 0 AS rk, LEFT(v.value_text, 100) AS val
                  FROM grac_practice.asset_field_definition fd
                  JOIN grac_practice.asset_evidence_field ef ON ef.field_key = fd.field_key
                  JOIN grac_practice.asset_field_definition f ON f.field_key = ef.owner_field_key
                  JOIN grac_practice.asset_field_value v ON v.asset_id = @asset AND v.field_definition_id = f.field_definition_id
                 WHERE fd.field_definition_id = @ref
                UNION ALL
                SELECT 1, r.val FROM @raw r WHERE r.party_code = N'ASSET_OWNER') x
         ORDER BY x.rk;
    END
    ELSE IF @otype = N'PRIVACY_REVIEW'                                                 -- 448
    BEGIN                                                                              -- 448
        -- 448: activity owner -- the privacy owner of the asset, else the asset owner.
        INSERT @raw (party_code, val)                                                  -- 448
        SELECT TOP 1 N'ACTIVITY_OWNER', r.val FROM @raw r                              -- 448
         WHERE r.party_code IN (N'PRIVACY_OWNER', N'ASSET_OWNER')                       -- 448
         ORDER BY CASE r.party_code WHEN N'PRIVACY_OWNER' THEN 0 ELSE 1 END;          -- 448
    END                                                                                -- 448
    ELSE IF @otype = N'PRIVACY_EXCEPTION'                                              -- 448
    BEGIN                                                                              -- 448
        INSERT @raw (party_code, val)                                                  -- 448
        SELECT x.code, CAST(x.emp AS NVARCHAR(30))                                     -- 448
          FROM grac_practice.asset_privacy_exception e                                 -- 448
         CROSS APPLY (VALUES (N'ACTIVITY_OWNER', e.owner_employee_id), (N'EXCEPTION_APPROVER', e.decided_employee_id)) x(code, emp)   -- 448
         WHERE e.exception_id = @oid AND x.emp IS NOT NULL;                            -- 448
    END                                                                                -- 448
    ELSE IF @otype IN (N'ASSET_MODEL', N'ASSET_OS', N'ASSET_FIRMWARE')
    BEGIN
        INSERT @raw (party_code, val)
        SELECT TOP 1 N'ACTIVITY_OWNER', val
          FROM @raw WHERE party_code IN (N'TECHNICAL_OWNER', N'ASSET_OWNER')
         ORDER BY CASE party_code WHEN N'TECHNICAL_OWNER' THEN 0 ELSE 1 END;
    END

    INSERT #np (party_code, employee_id)
    SELECT DISTINCT r.party_code, e.employee_id
      FROM @raw r
     CROSS APPLY (SELECT CASE WHEN r.val LIKE N'T:%' THEN NULL
                              WHEN r.val LIKE N'E:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(r.val, 3, 40))
                              ELSE TRY_CONVERT(BIGINT, r.val) END AS emp,
                         CASE WHEN r.val LIKE N'T:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(r.val, 3, 40)) END AS team) x
      JOIN grac_practice.organization_employee e
        ON e.organization_id = @org AND e.status = N'Active'
       AND (e.employee_id = x.emp
            OR EXISTS (SELECT 1 FROM grac_practice.organization_team_member m
                        WHERE m.team_id = x.team AND m.employee_id = e.employee_id AND m.status = N'Active'));

    INSERT #np (party_code, employee_id)
    SELECT DISTINCT N'MANAGER', m.employee_id
      FROM #np o
      JOIN grac_practice.organization_employee e ON e.employee_id = o.employee_id
      JOIN grac_practice.organization_employee m ON m.employee_id = e.reporting_officer_id AND m.status = N'Active'
     WHERE o.party_code = N'ACTIVITY_OWNER';

    INSERT #np (party_code, employee_id)
    SELECT DISTINCT N'DEPARTMENT_HEAD', h.employee_id
      FROM #np o
      JOIN grac_practice.organization_employee e ON e.employee_id = o.employee_id
      JOIN grac_practice.organization_department d ON d.department_id = e.department_id
      JOIN grac_practice.organization_employee h ON h.employee_id = d.head_employee_id AND h.status = N'Active'
     WHERE o.party_code = N'ACTIVITY_OWNER';
END
GO
PRINT '448: sp_asset_notification_parties re-issued.';
GO

-- =====================================================================
-- 11. Menu: Asset & Contract -> Asset Privacy (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-privacy', N'Asset Privacy', N'Practice/Index/asset-privacy', 364, N'user-shield', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-448', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-448');
PRINT CONCAT('448: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-448', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-privacy' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 1, N'Active', @active_rs, N'seed-448', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-privacy'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('448: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 12. Verification
-- =====================================================================
SELECT '448-a objects' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_privacy_requirement','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_privacy_setting','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_privacy_exception','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_privacy_review','U') IS NOT NULL
             AND (SELECT COUNT(*) FROM grac_practice.asset_privacy_requirement) = 12
             AND OBJECT_ID('grac_practice.fn_asset_privacy_values') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_privacy_retention_calc') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_privacy_gaps') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_privacy_status') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_privacy_sync','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_privacy_run','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_privacy_requirements','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_privacy_setting_save','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_privacy_exception_request','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_privacy_exception_action','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_privacy_review_complete','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_privacy_assets','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_privacy_asset_get','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_privacy_exceptions','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_privacy_reviews','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT '448-b re-issued bodies and notification wiring' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_register_save')) LIKE '%sp_asset_privacy_sync%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_register_save')) LIKE '%sp_asset_consistency_evaluate%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_scheduler_run')) LIKE '%sp_asset_privacy_sync%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_scheduler_run')) LIKE '%sp_asset_consistency_evaluate%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_lifecycle_transition')) LIKE '%53070%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_lifecycle_transition')) LIKE '%53037%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_notification_sweep')) LIKE '%PRIVACY_REVIEW:PX:%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_notification_sweep')) LIKE '%EVIDENCE_EXPIRY:EV:%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_notification_parties')) LIKE '%PRIVACY_EXCEPTION%'
             AND EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_ntf_occ_obj' AND definition LIKE '%PRIVACY_REVIEW%')
             AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_activity
                              WHERE activity_code IN (N'PRIVACY_REVIEW', N'RETENTION_REVIEW') AND source_available = 0)
            THEN 'PASS' ELSE 'FAIL' END AS Result;
-- Retention arithmetic: 7 years from 2026-01-15 -> 2033-01-15; 18 months -> 2027-07-15; bad text -> invalid.
SELECT '448-c retention arithmetic' AS Check_,
       CASE WHEN (SELECT FormulaDueDate FROM grac_practice.fn_asset_privacy_retention_calc(0, 0, N'7 years', N'CREATION', '2026-01-15', NULL)) = '2033-01-15'
             AND (SELECT FormulaDueDate FROM grac_practice.fn_asset_privacy_retention_calc(0, 0, N'18 Months', N'CREATION', '2026-01-15', NULL)) = '2027-07-15'
             AND (SELECT PeriodInvalid FROM grac_practice.fn_asset_privacy_retention_calc(0, 0, N'forever', N'CREATION', '2026-01-15', NULL)) = 1
             AND (SELECT PeriodInvalid FROM grac_practice.fn_asset_privacy_retention_calc(0, 0, N'500 years', N'CREATION', '2026-01-15', NULL)) = 1
            THEN 'PASS' ELSE 'FAIL' END AS Result;
-- The status function runs for every organization; menu row in place.
SELECT '448-d status readable and menu' AS Check_,
       (SELECT COUNT(*) FROM grac_practice.organization o CROSS APPLY grac_practice.fn_asset_privacy_status(o.organization_id, NULL) s) AS AssetsEvaluated,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-privacy' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END AS Result;
GO

/* =====================================================================
   UAT (asset-privacy VIEW / EDIT / APPROVE held by two people;
   asset-register EDIT)
   ---------------------------------------------------------------------
   1. Asset Register: an asset whose template has the privacy fields; set
      Personal data processed = Yes and save -> warning "Privacy: n gap(s)";
      the Privacy tab shows status Incomplete and the gaps.
   2. Complete every 5.1.10 field (assessment Approved, DPIA not required,
      masking / encryption Yes and implemented, retention 7 years from
      Creation, review date next month, residual risk) -> Compliant;
      masking implemented = Partially -> Conditional; encryption
      implemented = No -> Non-compliant (5.1.16: never Compliant while
      incomplete).
   3. Asset Privacy -> Requirements: Encryption = Block; the move to
      Active is refused (53070) while encryption is not implemented.
   4. Request an exception for Encryption (reason, controls, owner,
      expiry) -> approve as the requester refused (53061), as another
      person approved -> status Conditional, the move to Active allowed.
   5. Reviews tab: an open Privacy review due on the review date; complete
      it with a next date -> the asset privacy review date changes and a
      new review opens. Set a retention period ending in the past ->
      Retention review overdue and a Retention gap; complete with Extend
      (approver, reason, date) or Delete (evidence).
   6. Asset with Sanitization required = Yes in Disposal Approval and no
      sanitization date / evidence -> move to Disposed refused (53071).
   7. Run the scheduler -> notifications PRIVACY_REVIEW / RETENTION_REVIEW
      for the open reviews (Asset Notifications).
   ===================================================================== */
