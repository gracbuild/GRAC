-- =====================================================================
-- 524_tpm_cr2_risk_register.sql
--
-- REQUEST (2026-11-08)
-- --------------------
--   "Change Document -- GRAC Third-Party Management (TPM) Redesign"
--   (CR 2), ROUND C -- section 8: the TP Risk Register, one vendor-level
--   record per admitted vendor. Design: docs/tpm-lifecycle-redesign.md
--   sections 8 and 15.4. Decisions (2026-11-08): the vendor-level profile
--   is a rating per area on the bands of the risk model in force; the
--   overall vendor risk status is the highest of those ratings and the
--   linked engagements' bands ("highest wins").
--
-- WHAT CHANGES
-- ------------
--   1. tprm_risk_register: created at a vendor's first formal admission
--      (final admission approval, sp_tprm_admission_act re-issued); one
--      OPEN / EXIT_IN_PROGRESS record per vendor (filtered unique index).
--      tprm_register_engagement links the admitted engagements; each keeps
--      its own assessment, due diligence and decision (CR 2 8.3).
--   2. Vendor-level profile (CR 2 8.2): list VENDOR_PROFILE_AREA (eight
--      baseline areas, extensible); tprm_register_profile_rating -- one
--      CURRENT rating per area (band of the risk model in force, rationale,
--      evidence, assessor), superseded, never overwritten.
--   3. Overall vendor risk status (fn_tprm_register_overall): never an
--      average -- the highest band among the area ratings and the linked
--      engagements' residual (else inherent) bands, with its source.
--   4. Impact review (CR 2 8.4): admitting a further engagement of a
--      vendor already on the register raises one
--      (tprm_register_impact_review); outcome no change / profile updated
--      by someone other than the decision-maker who included it.
--   5. Exit (CR 2 8.5): an engagement that exits, is rejected or is
--      cancelled leaves the record (sp_tprm_engagement_lifecycle and
--      sp_tprm_decision_act re-issued); when none remains the record is
--      EXIT_IN_PROGRESS until it is closed (not by the person whose action
--      started the exit). Closed records stay readable. Cancelling an
--      engagement also withdraws its pending admission.
--   6. Screen "TP Risk Register" (tprm-risk-register, CR 2 menu 3.3)
--      under Third-Party Management; grants copied from Engagement
--      Management. sp_tprm_engagement_get (523) gains the register link.
--   7. Engagements admitted before 524 are linked now (no impact reviews).
--   Also: sp_tprm_decision_act refuses a second approval of the same level
--   acting at the same moment (it no longer overwrites the first).
--
-- RUN ORDER: after 523. Re-running the regenerated 487 (list
-- VENDOR_PROFILE_AREA) is optional -- this file adds the list itself.
-- 523 refuses to re-run after this file; this file refuses to re-run after 525.
-- ERROR NUMBERS: 58150-58199 (and 57767, 57640 reused).
-- DEPENDS ON: 486-490, 507, 521, 522, 523.
-- Rollback: 524_tpm_cr2_risk_register_rollback.sql
-- SAFE TO RE-RUN. ASCII-only. SQL Server 2017+.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF COL_LENGTH('grac_practice.tprm_engagement', 'applicability_status') IS NULL
   OR OBJECT_ID('grac_practice.tprm_admission', 'U') IS NULL
   OR OBJECT_ID('grac_practice.sp_tprm_admission_act', 'P') IS NULL
BEGIN PRINT 'ABORT (524): run 523_tpm_cr2_screening_admission.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.menu_master', 'U') IS NULL OR COL_LENGTH('grac_practice.menu_master', 'show_in_sidebar') IS NULL
BEGIN PRINT 'ABORT (524): menu_master (022 / 390) is missing.'; SET @ok = 0; END
-- 525 re-issues sp_tprm_register_link / _list / _get (and 523's
-- sp_tprm_applicability_decide / _get); running 524 again would take the
-- register changes out.
IF OBJECT_ID('grac_practice.tprm_register_profile_review', 'U') IS NOT NULL
BEGIN PRINT 'ABORT (524): superseded by 525_tpm_dashboard_tasks_profile_review.sql, which is already applied. Do not re-run 524.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('524_tpm_cr2_risk_register: prerequisites missing -- see the messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Configuration: vendor profile areas (also in the regenerated 487)
-- =====================================================================
MERGE grac_practice.tprm_reference_list AS t
USING (VALUES
    (N'VENDOR_PROFILE_AREA', N'Vendor profile areas',
     N'The vendor-level areas of the TP Risk Register profile (CR 2 8.2). Each area is rated on the bands of the risk model in force, with the rationale and evidence. Add areas, relabel or hide them per organization.',
     N'EXTENSIBLE', CAST(NULL AS NVARCHAR(400)), 240)
) AS s(list_code, list_name, description, scope_rule, allowed_meanings, display_order)
ON t.list_code = s.list_code
WHEN MATCHED THEN UPDATE SET list_name = s.list_name, description = s.description, scope_rule = s.scope_rule,
    allowed_meanings = s.allowed_meanings, display_order = s.display_order, updated_by = N'migration-524', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (list_code, list_name, description, scope_rule, allowed_meanings, display_order, entered_by)
    VALUES (s.list_code, s.list_name, s.description, s.scope_rule, s.allowed_meanings, s.display_order, N'migration-524');
GO
MERGE grac_practice.tprm_reference_value AS t
USING (VALUES
    (N'CORPORATE_PROFILE', N'Vendor identity and corporate profile', N'Legal identity, registration, size, years in business, locations.', 10),
    (N'OWNERSHIP_GROUP', N'Ownership and group relationships', N'Ultimate ownership, parent and group companies, related parties.', 20),
    (N'FINANCIAL_STABILITY', N'Financial stability', N'Financial statements, ratings, solvency and concentration.', 30),
    (N'GOVERNANCE', N'Governance and management', N'Board and management structure, policies, oversight of risk.', 40),
    (N'LEGAL_REGULATORY', N'Legal and regulatory standing', N'Licences, regulatory actions, litigation, sanctions screening.', 50),
    (N'INFORMATION_SECURITY', N'Enterprise cybersecurity and information security', N'Security programme, incidents, vulnerability management, privacy.', 60),
    (N'BUSINESS_CONTINUITY', N'Business continuity capability', N'Continuity and recovery plans, tests, resilience of critical services.', 70),
    (N'CERTIFICATIONS', N'Certifications and independent assurance', N'Certifications (ISO 27001, SOC 2 ...), audit reports and their validity.', 80)
) AS s(value_code, label, description, display_order)
ON t.organization_id IS NULL AND t.list_code = N'VENDOR_PROFILE_AREA' AND t.value_code = s.value_code
WHEN MATCHED THEN UPDATE SET label = s.label, description = s.description, display_order = s.display_order,
    status = N'Active', updated_by = N'migration-524', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN INSERT
    (list_code, organization_id, value_code, label, description, meaning_code, rank_no, display_order, status, entered_by)
    VALUES (N'VENDOR_PROFILE_AREA', NULL, s.value_code, s.label, s.description, NULL, NULL, s.display_order, N'Active', N'migration-524');
PRINT '524: list VENDOR_PROFILE_AREA ready.';
GO

-- =====================================================================
-- 2. Schema
-- =====================================================================
IF OBJECT_ID('grac_practice.tprm_risk_register', 'U') IS NULL
BEGIN
    -- One row per admission lifetime of a vendor (CR 2 8.1): created at
    -- the first formal admission, closed after the exit of its last
    -- engagement. One OPEN / EXIT_IN_PROGRESS row per vendor (CR 2 10-12).
    CREATE TABLE grac_practice.tprm_risk_register(
        register_id                  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_risk_register PRIMARY KEY,
        organization_id              BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_reg_org REFERENCES grac_practice.organization(organization_id),
        third_party_id               BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_reg_tp REFERENCES grac_practice.tprm_third_party(third_party_id),
        register_code                NVARCHAR(20)   NOT NULL,     -- TPRR-001 per organization
        status                       NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_reg_status DEFAULT N'OPEN'
            CONSTRAINT ck_pm_tprm_reg_status CHECK (status IN (N'OPEN', N'EXIT_IN_PROGRESS', N'CLOSED')),
        admitted_dt                  DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_reg_admitted DEFAULT SYSUTCDATETIME(),
        exit_started_dt              DATETIME2      NULL,
        exit_started_by_employee_id  BIGINT         NULL
            CONSTRAINT fk_pm_tprm_reg_exit_by REFERENCES grac_practice.organization_employee(employee_id),
        closed_dt                    DATETIME2      NULL,
        closed_by_employee_id        BIGINT         NULL
            CONSTRAINT fk_pm_tprm_reg_closed_by REFERENCES grac_practice.organization_employee(employee_id),
        closure_rationale            NVARCHAR(2000) NULL,
        entered_by                   NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_reg_eby DEFAULT N'system',
        entered_dt                   DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_reg_edt DEFAULT SYSUTCDATETIME(),
        updated_by                   NVARCHAR(100)  NULL,
        updated_dt                   DATETIME2      NULL,
        CONSTRAINT uq_pm_tprm_reg_code UNIQUE (organization_id, register_code)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_reg_active ON grac_practice.tprm_risk_register(organization_id, third_party_id) WHERE status <> N'CLOSED';
    PRINT '524: tprm_risk_register created.';
END
GO
IF OBJECT_ID('grac_practice.tprm_register_engagement', 'U') IS NULL
BEGIN
    -- The admitted engagements of a register record (CR 2 8.1, 10-13).
    CREATE TABLE grac_practice.tprm_register_engagement(
        link_id        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_register_engagement PRIMARY KEY,
        register_id    BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rle_reg REFERENCES grac_practice.tprm_risk_register(register_id),
        engagement_id  BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rle_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        admission_id   BIGINT         NULL
            CONSTRAINT fk_pm_tprm_rle_adm REFERENCES grac_practice.tprm_admission(admission_id),   -- NULL: linked by migration 524
        status         NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_rle_status DEFAULT N'LINKED'
            CONSTRAINT ck_pm_tprm_rle_status CHECK (status IN (N'LINKED', N'ENDED')),
        linked_dt      DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_rle_linked DEFAULT SYSUTCDATETIME(),
        ended_dt       DATETIME2      NULL,
        end_reason     NVARCHAR(30)   NULL,      -- the engagement stage that ended it: EXITED / REJECTED / CANCELLED
        CONSTRAINT uq_pm_tprm_rle UNIQUE (register_id, engagement_id)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_rle_linked ON grac_practice.tprm_register_engagement(engagement_id) WHERE status = N'LINKED';
    PRINT '524: tprm_register_engagement created.';
END
GO
IF OBJECT_ID('grac_practice.tprm_register_profile_rating', 'U') IS NULL
BEGIN
    -- Vendor-level profile (CR 2 8.2): one CURRENT rating per area; a new
    -- rating supersedes the previous one, nothing is overwritten.
    CREATE TABLE grac_practice.tprm_register_profile_rating(
        rating_id               BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_register_profile_rating PRIMARY KEY,
        register_id             BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rpr_reg REFERENCES grac_practice.tprm_risk_register(register_id),
        area_code               NVARCHAR(60)   NOT NULL,     -- VENDOR_PROFILE_AREA
        risk_model_version_id   BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rpr_rmv REFERENCES grac_practice.tprm_template_version(version_id),
        band_code               NVARCHAR(60)   NOT NULL,     -- tprm_rm_band of that version
        rationale               NVARCHAR(2000) NOT NULL,
        evidence_reference      NVARCHAR(1000) NULL,
        status                  NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_rpr_status DEFAULT N'CURRENT'
            CONSTRAINT ck_pm_tprm_rpr_status CHECK (status IN (N'CURRENT', N'SUPERSEDED')),
        assessed_by_employee_id BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rpr_by REFERENCES grac_practice.organization_employee(employee_id),
        assessed_by             NVARCHAR(100)  NOT NULL,
        assessed_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_rpr_dt DEFAULT SYSUTCDATETIME(),
        superseded_dt           DATETIME2      NULL
    );
    CREATE UNIQUE INDEX ux_pm_tprm_rpr_current ON grac_practice.tprm_register_profile_rating(register_id, area_code) WHERE status = N'CURRENT';
    PRINT '524: tprm_register_profile_rating created.';
END
GO
IF OBJECT_ID('grac_practice.tprm_register_impact_review', 'U') IS NULL
BEGIN
    -- Raised when a further engagement of an admitted vendor is admitted
    -- (CR 2 8.4): does the new engagement change the vendor profile?
    CREATE TABLE grac_practice.tprm_register_impact_review(
        impact_review_id         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_register_impact_review PRIMARY KEY,
        register_id              BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rir_reg REFERENCES grac_practice.tprm_risk_register(register_id),
        engagement_id            BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rir_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        admission_id             BIGINT         NULL
            CONSTRAINT fk_pm_tprm_rir_adm REFERENCES grac_practice.tprm_admission(admission_id),
        status                   NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_rir_status DEFAULT N'OPEN'
            CONSTRAINT ck_pm_tprm_rir_status CHECK (status IN (N'OPEN', N'COMPLETED', N'CANCELLED')),
        profile_at_raise_json    NVARCHAR(MAX)  NULL,     -- overall status and linked engagements when raised
        requested_by_employee_id BIGINT         NULL
            CONSTRAINT fk_pm_tprm_rir_req REFERENCES grac_practice.organization_employee(employee_id),
        raised_dt                DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_rir_raised DEFAULT SYSUTCDATETIME(),
        outcome                  NVARCHAR(20)   NULL
            CONSTRAINT ck_pm_tprm_rir_outcome CHECK (outcome IS NULL OR outcome IN (N'NO_CHANGE', N'PROFILE_UPDATED')),
        rationale                NVARCHAR(2000) NULL,
        reviewed_by_employee_id  BIGINT         NULL
            CONSTRAINT fk_pm_tprm_rir_by REFERENCES grac_practice.organization_employee(employee_id),
        reviewed_dt              DATETIME2      NULL
    );
    CREATE INDEX ix_pm_tprm_rir_reg ON grac_practice.tprm_register_impact_review(register_id, status);
    PRINT '524: tprm_register_impact_review created.';
END
GO
IF OBJECT_ID('grac_practice.tprm_register_history', 'U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_register_history(
        history_id        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_register_history PRIMARY KEY,
        register_id       BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rh_reg REFERENCES grac_practice.tprm_risk_register(register_id),
        event_code        NVARCHAR(40)   NOT NULL,
        engagement_id     BIGINT         NULL,
        detail            NVARCHAR(2000) NULL,
        actor_employee_id BIGINT         NULL,
        actor             NVARCHAR(100)  NOT NULL,
        event_dt          DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_rh_dt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_tprm_rh_reg ON grac_practice.tprm_register_history(register_id, event_dt);
    PRINT '524: tprm_register_history created.';
END
GO

-- =====================================================================
-- 3. Consolidated status and internal procedures
-- =====================================================================
-- Overall vendor risk status (CR 2 8.3; decision 2026-11-08 "highest
-- wins"): never an average -- the highest band (rank_no of the band's own
-- risk model version) among the CURRENT vendor-level area ratings and the
-- LINKED engagements' residual band (inherent while no residual), with
-- the source that set it. No row: nothing rated or assessed yet.
-- Only areas the organization still uses count (a rating of an area that
-- was hidden later cannot be re-rated, so it must not hold the status).
-- Ranks are compared as stored: each band's rank_no in its own risk model
-- version (area ratings use the version in force, engagements the one
-- they were assessed on) -- keep rank_no comparable across versions.
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_register_overall (@register_id BIGINT)
RETURNS TABLE
AS
RETURN
(
SELECT TOP (1) x.source_kind, x.source_id, x.source_code, x.source_label, x.version_id, x.band_code,
       b.band_name, b.color_hex, b.rank_no
FROM (
    SELECT N'VENDOR_AREA' AS source_kind, r.rating_id AS source_id, r.area_code AS source_code,
           CAST(NULL AS NVARCHAR(300)) AS source_label, r.risk_model_version_id AS version_id, r.band_code
    FROM   grac_practice.tprm_register_profile_rating r
    JOIN   grac_practice.tprm_risk_register g ON g.register_id = r.register_id
    CROSS  APPLY (SELECT TOP (1) a.value_code FROM grac_practice.fn_tprm_reference_effective(g.organization_id) a
                  WHERE a.list_code = N'VENDOR_PROFILE_AREA' AND a.value_code = r.area_code) a
    WHERE  r.register_id = @register_id AND r.status = N'CURRENT'
    UNION ALL
    SELECT N'ENGAGEMENT', e.engagement_id, e.engagement_code, e.engagement_title, e.risk_model_version_id,
           COALESCE(e.residual_band_code, e.inherent_band_code)
    FROM   grac_practice.tprm_register_engagement l
    JOIN   grac_practice.tprm_engagement e ON e.engagement_id = l.engagement_id
    WHERE  l.register_id = @register_id AND l.status = N'LINKED'
      AND  COALESCE(e.residual_band_code, e.inherent_band_code) IS NOT NULL
) x
JOIN grac_practice.tprm_rm_band b ON b.version_id = x.version_id AND b.band_code = x.band_code
ORDER BY b.rank_no DESC, CASE x.source_kind WHEN N'VENDOR_AREA' THEN 0 ELSE 1 END, x.source_id
);
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_register_event
    @register_id       BIGINT,
    @event_code        NVARCHAR(40),
    @engagement_id     BIGINT         = NULL,
    @detail            NVARCHAR(2000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    INSERT grac_practice.tprm_register_history (register_id, event_code, engagement_id, detail, actor_employee_id, actor)
    VALUES (@register_id, @event_code, @engagement_id, @detail, @actor_employee_id, ISNULL(@actor, N'system'));
    EXEC grac_practice.sp_tprm_audit N'tprm-register', @register_id, @event_code, @detail, @actor;
END
GO

-- Internal (CR 2 8.1, 8.4): an engagement admitted to formal TPRM joins
-- its vendor's register record -- created at the first admission,
-- reopened when the vendor was exiting -- and, when the record already
-- holds another linked engagement, an impact review of the vendor
-- profile is raised. Runs inside the caller's transaction.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_register_link
    @engagement_id     BIGINT,
    @admission_id        BIGINT         = NULL,
    @actor_employee_id   BIGINT         = NULL,
    @actor               NVARCHAR(100)  = N'system',
    @raise_impact_review BIT            = 1      -- 0: migration 524 linking engagements admitted before it
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @org BIGINT, @tp BIGINT, @code NVARCHAR(20), @title NVARCHAR(250);
    SELECT @org = organization_id, @tp = third_party_id, @code = engagement_code, @title = engagement_title
    FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id;
    IF @org IS NULL RETURN;

    DECLARE @reg BIGINT, @rstatus NVARCHAR(20), @rcode NVARCHAR(20), @next INT, @others INT, @detail NVARCHAR(2000),
            @reopened BIT = 0;
    SELECT @reg = register_id, @rstatus = status, @rcode = register_code
    FROM grac_practice.tprm_risk_register WITH (UPDLOCK, HOLDLOCK)
    WHERE organization_id = @org AND third_party_id = @tp AND status <> N'CLOSED';

    IF @reg IS NULL
    BEGIN
        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(register_code, 6, 20))), 0) + 1
        FROM grac_practice.tprm_risk_register WITH (UPDLOCK, HOLDLOCK)
        WHERE organization_id = @org AND register_code LIKE N'TPRR-%';
        SET @rcode = N'TPRR-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_risk_register (organization_id, third_party_id, register_code, status, entered_by)
        VALUES (@org, @tp, @rcode, N'OPEN', ISNULL(@actor, N'system'));
        SET @reg = SCOPE_IDENTITY();
        SET @detail = CONCAT(N'Register record ', @rcode, N' created: ', @code, N' admitted to formal TPRM.');
        EXEC grac_practice.sp_tprm_register_event @reg, N'CREATED', @engagement_id, @detail, @actor_employee_id, @actor;
    END
    ELSE IF @rstatus = N'EXIT_IN_PROGRESS'
    BEGIN
        UPDATE grac_practice.tprm_risk_register
           SET status = N'OPEN', exit_started_dt = NULL, exit_started_by_employee_id = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE register_id = @reg;
        SET @reopened = 1;
        SET @detail = CONCAT(N'Exit stopped: ', @code, N' admitted to formal TPRM.');
        EXEC grac_practice.sp_tprm_register_event @reg, N'REOPENED', @engagement_id, @detail, @actor_employee_id, @actor;
    END

    SELECT @others = COUNT(*) FROM grac_practice.tprm_register_engagement
    WHERE register_id = @reg AND status = N'LINKED' AND engagement_id <> @engagement_id;

    IF EXISTS (SELECT 1 FROM grac_practice.tprm_register_engagement WHERE register_id = @reg AND engagement_id = @engagement_id)
        UPDATE grac_practice.tprm_register_engagement
           SET status = N'LINKED', admission_id = COALESCE(@admission_id, admission_id), linked_dt = SYSUTCDATETIME(), ended_dt = NULL, end_reason = NULL
         WHERE register_id = @reg AND engagement_id = @engagement_id;
    ELSE
        INSERT grac_practice.tprm_register_engagement (register_id, engagement_id, admission_id, status)
        VALUES (@reg, @engagement_id, @admission_id, N'LINKED');
    SET @detail = CONCAT(@code, N' ', @title, N' linked.');
    EXEC grac_practice.sp_tprm_register_event @reg, N'ENGAGEMENT_LINKED', @engagement_id, @detail, @actor_employee_id, @actor;
    SET @detail = CONCAT(N'Linked to TP Risk Register record ', @rcode, N'.');
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'REGISTER_LINKED', NULL, NULL, @detail, @actor_employee_id, @actor;

    -- an impact review when the record already holds another engagement,
    -- or when it is reopened with a vendor profile rated before
    IF ISNULL(@raise_impact_review, 1) = 1
       AND (@others > 0
            OR (@reopened = 1 AND EXISTS (SELECT 1 FROM grac_practice.tprm_register_profile_rating
                                           WHERE register_id = @reg AND status = N'CURRENT')))
    BEGIN
        DECLARE @snapshot NVARCHAR(MAX) = (
            SELECT (SELECT o.band_code AS bandCode, o.band_name AS bandName, o.source_kind AS sourceKind, o.source_code AS sourceCode
                    FROM grac_practice.fn_tprm_register_overall(@reg) o FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS overall,
                   (SELECT e.engagement_code AS engagementCode, COALESCE(e.residual_band_code, e.inherent_band_code) AS bandCode
                    FROM grac_practice.tprm_register_engagement l
                    JOIN grac_practice.tprm_engagement e ON e.engagement_id = l.engagement_id
                    WHERE l.register_id = @reg AND l.status = N'LINKED' AND l.engagement_id <> @engagement_id
                    FOR JSON PATH) AS engagements
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        INSERT grac_practice.tprm_register_impact_review (register_id, engagement_id, admission_id, status, profile_at_raise_json, requested_by_employee_id)
        SELECT @reg, @engagement_id, @admission_id, N'OPEN', @snapshot, a.submitted_by_employee_id
        FROM (SELECT 1 AS one) x
        LEFT JOIN grac_practice.tprm_admission a ON a.admission_id = @admission_id;
        SET @detail = CASE WHEN @others > 0
            THEN CONCAT(N'Impact review raised: ', @code, N' joins ', @others, N' linked engagement(s) of this vendor.')
            ELSE CONCAT(N'Impact review raised: the record is reopened by ', @code, N'; review the existing vendor profile.') END;
        EXEC grac_practice.sp_tprm_register_event @reg, N'IMPACT_REVIEW_RAISED', @engagement_id, @detail, @actor_employee_id, @actor;
    END
END
GO

-- Internal (CR 2 8.5): an engagement that is closed (EXITED, REJECTED or
-- CANCELLED) leaves its register record; its open impact review is
-- cancelled. When no linked engagement remains, the record moves to
-- EXIT_IN_PROGRESS and waits for closure (sp_tprm_register_close).
-- Ending one engagement never closes the record while others remain.
-- Runs inside the caller's transaction.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_register_sync_engagement
    @engagement_id     BIGINT,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30), @code NVARCHAR(20), @reg BIGINT, @detail NVARCHAR(2000);
    SELECT @stage = stage_code, @code = engagement_code FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id;
    IF @stage IS NULL OR @stage NOT IN (N'EXITED', N'REJECTED', N'CANCELLED') RETURN;
    SELECT @reg = register_id FROM grac_practice.tprm_register_engagement WHERE engagement_id = @engagement_id AND status = N'LINKED';
    IF @reg IS NULL RETURN;

    UPDATE grac_practice.tprm_risk_register SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE register_id = @reg;   -- takes the row lock before the counts below
    UPDATE grac_practice.tprm_register_engagement
       SET status = N'ENDED', ended_dt = SYSUTCDATETIME(), end_reason = @stage
     WHERE register_id = @reg AND engagement_id = @engagement_id AND status = N'LINKED';
    UPDATE grac_practice.tprm_register_impact_review
       SET status = N'CANCELLED', rationale = CONCAT(N'Engagement ', LOWER(@stage), N'.'), reviewed_dt = SYSUTCDATETIME()
     WHERE register_id = @reg AND engagement_id = @engagement_id AND status = N'OPEN';
    SET @detail = CONCAT(@code, N' left the record (', LOWER(@stage), N').');
    EXEC grac_practice.sp_tprm_register_event @reg, N'ENGAGEMENT_ENDED', @engagement_id, @detail, @actor_employee_id, @actor;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_register_engagement WHERE register_id = @reg AND status = N'LINKED')
       AND EXISTS (SELECT 1 FROM grac_practice.tprm_risk_register WHERE register_id = @reg AND status = N'OPEN')
    BEGIN
        UPDATE grac_practice.tprm_risk_register
           SET status = N'EXIT_IN_PROGRESS', exit_started_dt = SYSUTCDATETIME(), exit_started_by_employee_id = @actor_employee_id
         WHERE register_id = @reg;
        UPDATE grac_practice.tprm_register_impact_review
           SET status = N'CANCELLED', rationale = N'No linked engagement remains.', reviewed_dt = SYSUTCDATETIME()
         WHERE register_id = @reg AND status = N'OPEN';
        EXEC grac_practice.sp_tprm_register_event @reg, N'EXIT_STARTED', @engagement_id,
             N'No admitted engagement remains: the vendor exit and closure of the record follow.', @actor_employee_id, @actor;
    END
END
GO

-- =====================================================================
-- 4. TP Risk Register screen procedures
-- =====================================================================
-- The register (CR 2 menu 3.3): admitted vendors only. @status ACTIVE =
-- OPEN and EXIT_IN_PROGRESS. @attention: IMPACT_REVIEW (an open impact
-- review), NOT_RATED (a profile area without a current rating), EXIT
-- (exit in progress).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_register_list
    @organization_id BIGINT,
    @status          NVARCHAR(20)  = N'ACTIVE',
    @band_code       NVARCHAR(60)  = NULL,
    @attention       NVARCHAR(20)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 58150, 'Select an organization.', 1;
    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N''), @areas INT;
    SELECT @areas = COUNT(*) FROM grac_practice.fn_tprm_reference_effective(@organization_id) WHERE list_code = N'VENDOR_PROFILE_AREA';

    SELECT r.register_id AS RegisterId, r.register_code AS RegisterCode, r.status AS Status,
           r.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS ThirdPartyName,
           r.admitted_dt AS AdmittedDt, r.exit_started_dt AS ExitStartedDt, r.closed_dt AS ClosedDt,
           o.band_code AS OverallBandCode, o.band_name AS OverallBand, o.color_hex AS OverallBandColor,
           o.source_kind AS OverallSourceKind, o.source_code AS OverallSourceCode,
           n.linked AS LinkedEngagements, n.open_findings AS OpenFindings, n.open_impact AS OpenImpactReviews,
           n.rated AS RatedAreas, @areas AS ProfileAreas, n.last_rated AS LastRatedDt, n.next_review AS NextReviewDt,
           COUNT(*) OVER () AS TotalRows
    FROM   grac_practice.tprm_risk_register r
    JOIN   grac_practice.tprm_third_party t ON t.third_party_id = r.third_party_id
    OUTER  APPLY grac_practice.fn_tprm_register_overall(r.register_id) o
    OUTER  APPLY (SELECT
             (SELECT COUNT(*) FROM grac_practice.tprm_register_engagement l WHERE l.register_id = r.register_id AND l.status = N'LINKED') AS linked,
             (SELECT COUNT(*) FROM grac_practice.tprm_finding f
               JOIN grac_practice.tprm_register_engagement l ON l.engagement_id = f.engagement_id AND l.register_id = r.register_id AND l.status = N'LINKED'
               WHERE f.status IN (N'OPEN', N'IN_PROGRESS')) AS open_findings,
             (SELECT COUNT(*) FROM grac_practice.tprm_register_impact_review i WHERE i.register_id = r.register_id AND i.status = N'OPEN') AS open_impact,
             (SELECT COUNT(*) FROM grac_practice.tprm_register_profile_rating p
               JOIN grac_practice.fn_tprm_reference_effective(@organization_id) a ON a.list_code = N'VENDOR_PROFILE_AREA' AND a.value_code = p.area_code
               WHERE p.register_id = r.register_id AND p.status = N'CURRENT') AS rated,
             (SELECT MAX(p.assessed_dt) FROM grac_practice.tprm_register_profile_rating p WHERE p.register_id = r.register_id) AS last_rated,
             (SELECT MIN(e.next_review_dt) FROM grac_practice.tprm_engagement e
               JOIN grac_practice.tprm_register_engagement l ON l.engagement_id = e.engagement_id AND l.register_id = r.register_id AND l.status = N'LINKED') AS next_review
           ) n
    WHERE  r.organization_id = @organization_id
      AND  (ISNULL(@status, N'ALL') = N'ALL' OR r.status = @status OR (@status = N'ACTIVE' AND r.status <> N'CLOSED'))
      AND  (@band_code IS NULL OR o.band_code = @band_code)
      AND  (@attention IS NULL
            OR (@attention = N'IMPACT_REVIEW' AND n.open_impact > 0)
            OR (@attention = N'NOT_RATED' AND r.status <> N'CLOSED' AND n.rated < @areas)
            OR (@attention = N'EXIT' AND r.status = N'EXIT_IN_PROGRESS'))
      AND  (@s IS NULL OR r.register_code LIKE N'%' + @s + N'%' OR t.legal_name LIKE N'%' + @s + N'%'
            OR t.third_party_code LIKE N'%' + @s + N'%'
            OR EXISTS (SELECT 1 FROM grac_practice.tprm_register_engagement l JOIN grac_practice.tprm_engagement e ON e.engagement_id = l.engagement_id
                        WHERE l.register_id = r.register_id AND (e.engagement_code LIKE N'%' + @s + N'%' OR e.engagement_title LIKE N'%' + @s + N'%')))
    ORDER  BY CASE r.status WHEN N'EXIT_IN_PROGRESS' THEN 0 WHEN N'OPEN' THEN 1 ELSE 2 END, ISNULL(o.rank_no, -1) DESC, t.legal_name, r.register_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- One register record (CR 2 8.2 / 8.3): header, overall status, the
-- vendor-level areas with their current rating, rating history, the
-- highest engagement exposure per risk dimension, the engagements (each
-- keeps its own assessment), open findings, risk decisions and
-- acceptances, admissions, impact reviews, open reviews, history.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_register_get
    @organization_id BIGINT,
    @register_id     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_risk_register WHERE register_id = @register_id AND organization_id = @organization_id)
        THROW 58151, 'That register record was not found.', 1;
    SELECT list_code, value_code, label, description, color_hex, display_order
    INTO   #ref
    FROM   grac_practice.fn_tprm_reference_effective(@organization_id)
    WHERE  list_code IN (N'VENDOR_PROFILE_AREA', N'TP_STATUS', N'CRITICALITY', N'SERVICE_CATEGORY', N'DECISION', N'FINDING_SEVERITY', N'DD_TIER');
    SELECT l.engagement_id, l.status AS link_status, l.linked_dt, l.ended_dt, l.end_reason, l.admission_id
    INTO   #links
    FROM   grac_practice.tprm_register_engagement l WHERE l.register_id = @register_id;

    -- 1 header
    SELECT r.register_id AS RegisterId, r.register_code AS RegisterCode, r.status AS Status, r.admitted_dt AS AdmittedDt,
           r.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS ThirdPartyName,
           t.trading_name AS TradingName, t.country AS Country, ts.label AS ThirdPartyStatus, sc.label AS ServiceCategory,
           t.relationship_owner_employee_id AS RelationshipOwnerEmployeeId, ro.employee_name AS RelationshipOwnerName,
           r.exit_started_dt AS ExitStartedDt, r.exit_started_by_employee_id AS ExitStartedByEmployeeId, xe.employee_name AS ExitStartedBy,
           r.closed_dt AS ClosedDt, ce.employee_name AS ClosedBy, r.closure_rationale AS ClosureRationale,
           o.band_code AS OverallBandCode, o.band_name AS OverallBand, o.color_hex AS OverallBandColor, o.source_kind AS OverallSourceKind,
           o.source_id AS OverallSourceId, o.source_code AS OverallSourceCode,
           COALESCE(o.source_label, (SELECT TOP (1) a.label FROM #ref a WHERE a.list_code = N'VENDOR_PROFILE_AREA' AND a.value_code = o.source_code)) AS OverallSourceLabel,
           (SELECT TOP (1) version_id FROM grac_practice.fn_tprm_risk_model_version(@organization_id)) AS RiskModelVersionId
    FROM   grac_practice.tprm_risk_register r
    JOIN   grac_practice.tprm_third_party t ON t.third_party_id = r.third_party_id
    OUTER  APPLY grac_practice.fn_tprm_register_overall(r.register_id) o
    LEFT   JOIN #ref ts ON ts.list_code = N'TP_STATUS' AND ts.value_code = t.lifecycle_status_code
    LEFT   JOIN #ref sc ON sc.list_code = N'SERVICE_CATEGORY' AND sc.value_code = t.primary_service_category_code
    LEFT   JOIN grac_practice.organization_employee ro ON ro.employee_id = t.relationship_owner_employee_id
    LEFT   JOIN grac_practice.organization_employee xe ON xe.employee_id = r.exit_started_by_employee_id
    LEFT   JOIN grac_practice.organization_employee ce ON ce.employee_id = r.closed_by_employee_id
    WHERE  r.register_id = @register_id;

    -- 2 vendor-level areas (every active area, rated or not; a hidden area that still has a rating is listed too)
    SELECT COALESCE(a.value_code, p.area_code) AS AreaCode, COALESCE(a.label, p.area_code) AS AreaLabel, a.description AS AreaDescription,
           CAST(CASE WHEN a.value_code IS NULL THEN 0 ELSE 1 END AS BIT) AS IsActiveArea,
           p.rating_id AS RatingId, p.band_code AS BandCode, b.band_name AS BandName, b.color_hex AS BandColor, b.rank_no AS BandRank,
           p.risk_model_version_id AS RiskModelVersionId, p.rationale AS Rationale, p.evidence_reference AS EvidenceReference,
           p.assessed_by_employee_id AS AssessedByEmployeeId, ae.employee_name AS AssessedBy, p.assessed_dt AS AssessedDt
    FROM   (SELECT value_code, label, description, display_order FROM #ref WHERE list_code = N'VENDOR_PROFILE_AREA') a
    FULL   OUTER JOIN (SELECT * FROM grac_practice.tprm_register_profile_rating WHERE register_id = @register_id AND status = N'CURRENT') p
           ON p.area_code = a.value_code
    LEFT   JOIN grac_practice.tprm_rm_band b ON b.version_id = p.risk_model_version_id AND b.band_code = p.band_code
    LEFT   JOIN grac_practice.organization_employee ae ON ae.employee_id = p.assessed_by_employee_id
    ORDER  BY ISNULL(a.display_order, 9999), COALESCE(a.label, p.area_code);

    -- 3 rating history (newest first)
    SELECT p.rating_id AS RatingId, p.area_code AS AreaCode, COALESCE(a.label, p.area_code) AS AreaLabel, p.band_code AS BandCode,
           b.band_name AS BandName, b.color_hex AS BandColor, p.rationale AS Rationale, p.evidence_reference AS EvidenceReference,
           p.status AS Status, ae.employee_name AS AssessedBy, p.assessed_dt AS AssessedDt, p.superseded_dt AS SupersededDt
    FROM   grac_practice.tprm_register_profile_rating p
    LEFT   JOIN #ref a ON a.list_code = N'VENDOR_PROFILE_AREA' AND a.value_code = p.area_code
    LEFT   JOIN grac_practice.tprm_rm_band b ON b.version_id = p.risk_model_version_id AND b.band_code = p.band_code
    LEFT   JOIN grac_practice.organization_employee ae ON ae.employee_id = p.assessed_by_employee_id
    WHERE  p.register_id = @register_id
    ORDER  BY p.assessed_dt DESC, p.rating_id DESC;

    -- 4 highest engagement exposure per risk dimension (linked engagements, current assessment; residual else inherent)
    SELECT d.DimensionCode, d.DimensionName, d.Score, d.ScoreKind, d.EngagementId, d.EngagementCode, d.EngagementTitle
    FROM (
        SELECT rd.dimension_code AS DimensionCode, md.dimension_name AS DimensionName,
               COALESCE(rd.residual_score, rd.inherent_score) AS Score,
               CASE WHEN rd.residual_score IS NOT NULL THEN N'RESIDUAL' ELSE N'INHERENT' END AS ScoreKind,
               e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode, e.engagement_title AS EngagementTitle,
               ROW_NUMBER() OVER (PARTITION BY rd.dimension_code
                                  ORDER BY COALESCE(rd.residual_score, rd.inherent_score) DESC, e.engagement_id) AS rn,
               MIN(md.display_order) OVER (PARTITION BY rd.dimension_code) AS ord
        FROM   #links l
        JOIN   grac_practice.tprm_engagement e ON e.engagement_id = l.engagement_id
        JOIN   grac_practice.tprm_risk_assessment_dimension rd ON rd.assessment_id = e.current_risk_assessment_id
        JOIN   grac_practice.tprm_rm_dimension md ON md.dimension_id = rd.dimension_id
        WHERE  l.link_status = N'LINKED' AND COALESCE(rd.residual_score, rd.inherent_score) IS NOT NULL
    ) d
    WHERE d.rn = 1
    ORDER BY d.ord, d.DimensionCode;

    -- 5 engagements (each keeps its own assessment -- CR 2 8.3)
    SELECT e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode, e.engagement_title AS EngagementTitle,
           l.link_status AS LinkStatus, l.linked_dt AS LinkedDt, l.ended_dt AS EndedDt, l.end_reason AS EndReason,
           e.stage_code AS StageCode, e.applicability_status AS ApplicabilityStatus, e.admitted_dt AS AdmittedDt,
           e.service_criticality_code AS CriticalityCode, cr.label AS Criticality, cr.color_hex AS CriticalityColor,
           e.inherent_score AS InherentScore, e.inherent_band_code AS InherentBandCode, ib.band_name AS InherentBand, ib.color_hex AS InherentBandColor,
           e.residual_score AS ResidualScore, e.residual_band_code AS ResidualBandCode, rb.band_name AS ResidualBand, rb.color_hex AS ResidualBandColor,
           dd.status AS DueDiligenceStatus, ddt.label AS DueDiligenceTier,
           e.contract_reference AS ContractReference, e.contract_start_dt AS ContractStartDt, e.contract_end_dt AS ContractEndDt,
           e.acceptance_until AS AcceptanceUntil, e.next_review_dt AS NextReviewDt, e.last_review_dt AS LastReviewDt,
           e.reassessment_required AS ReassessmentRequired,
           (SELECT COUNT(*) FROM grac_practice.tprm_finding f WHERE f.engagement_id = e.engagement_id AND f.status IN (N'OPEN', N'IN_PROGRESS')) AS OpenFindings
    FROM   #links l
    JOIN   grac_practice.tprm_engagement e ON e.engagement_id = l.engagement_id
    OUTER  APPLY grac_practice.fn_tprm_current_dd(e.engagement_id) dd
    LEFT   JOIN #ref cr ON cr.list_code = N'CRITICALITY' AND cr.value_code = e.service_criticality_code
    LEFT   JOIN #ref ddt ON ddt.list_code = N'DD_TIER' AND ddt.value_code = dd.dd_tier_code
    LEFT   JOIN grac_practice.tprm_rm_band ib ON ib.version_id = e.risk_model_version_id AND ib.band_code = e.inherent_band_code
    LEFT   JOIN grac_practice.tprm_rm_band rb ON rb.version_id = e.risk_model_version_id AND rb.band_code = e.residual_band_code
    ORDER  BY CASE l.link_status WHEN N'LINKED' THEN 0 ELSE 1 END, e.engagement_code;

    -- 6 open findings and remediation of the linked engagements
    SELECT f.finding_id AS FindingId, f.finding_number AS FindingNumber, f.title AS Title, f.finding_kind AS FindingKind,
           f.severity_code AS SeverityCode, sv.label AS Severity, sv.color_hex AS SeverityColor, f.status AS Status, f.due_dt AS DueDt,
           oe.employee_name AS OwnerName, e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode
    FROM   #links l
    JOIN   grac_practice.tprm_finding f ON f.engagement_id = l.engagement_id
    JOIN   grac_practice.tprm_engagement e ON e.engagement_id = f.engagement_id
    LEFT   JOIN #ref sv ON sv.list_code = N'FINDING_SEVERITY' AND sv.value_code = f.severity_code
    LEFT   JOIN grac_practice.organization_employee oe ON oe.employee_id = f.owner_employee_id
    WHERE  l.link_status = N'LINKED' AND f.status IN (N'OPEN', N'IN_PROGRESS')
    ORDER  BY f.due_dt, f.finding_id;

    -- 7 risk decisions and acceptances (approval history of the risk)
    SELECT d.decision_id AS DecisionId, d.decision_no AS DecisionNo, d.status AS Status, d.outcome_code AS OutcomeCode,
           dv.label AS Outcome, d.rationale AS Rationale, d.risk_accepted AS RiskAccepted, d.acceptance_until AS AcceptanceUntil,
           d.residual_band_code AS ResidualBandCode, de.employee_name AS DecidedBy, d.decided_dt AS DecidedDt, d.submitted_dt AS SubmittedDt,
           e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode
    FROM   #links l
    JOIN   grac_practice.tprm_decision d ON d.engagement_id = l.engagement_id
    JOIN   grac_practice.tprm_engagement e ON e.engagement_id = d.engagement_id
    LEFT   JOIN #ref dv ON dv.list_code = N'DECISION' AND dv.value_code = d.outcome_code
    LEFT   JOIN grac_practice.organization_employee de ON de.employee_id = d.decided_by_employee_id
    ORDER  BY COALESCE(d.decided_dt, d.submitted_dt) DESC;

    -- 8 admissions (formal TPRM admission approvals)
    SELECT a.admission_id AS AdmissionId, a.admission_no AS AdmissionNo, a.status AS Status, a.approval_rule_code AS ApprovalRuleCode,
           JSON_VALUE(a.rule_snapshot_json, '$.rule_name') AS ApprovalRuleName, a.outcome_rationale AS OutcomeRationale,
           se.employee_name AS SubmittedBy, a.submitted_dt AS SubmittedDt, de.employee_name AS DecidedBy, a.decided_dt AS DecidedDt,
           e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode
    FROM   #links l
    JOIN   grac_practice.tprm_admission a ON a.engagement_id = l.engagement_id
    JOIN   grac_practice.tprm_engagement e ON e.engagement_id = a.engagement_id
    LEFT   JOIN grac_practice.organization_employee se ON se.employee_id = a.submitted_by_employee_id
    LEFT   JOIN grac_practice.organization_employee de ON de.employee_id = a.decided_by_employee_id
    ORDER  BY a.submitted_dt DESC;

    -- 9 impact reviews
    SELECT i.impact_review_id AS ImpactReviewId, i.status AS Status, i.outcome AS Outcome, i.rationale AS Rationale,
           i.raised_dt AS RaisedDt, i.requested_by_employee_id AS RequestedByEmployeeId, qe.employee_name AS RequestedBy,
           i.reviewed_by_employee_id AS ReviewedByEmployeeId, re.employee_name AS ReviewedBy, i.reviewed_dt AS ReviewedDt,
           i.profile_at_raise_json AS ProfileAtRaiseJson,
           e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode, e.engagement_title AS EngagementTitle
    FROM   grac_practice.tprm_register_impact_review i
    JOIN   grac_practice.tprm_engagement e ON e.engagement_id = i.engagement_id
    LEFT   JOIN grac_practice.organization_employee qe ON qe.employee_id = i.requested_by_employee_id
    LEFT   JOIN grac_practice.organization_employee re ON re.employee_id = i.reviewed_by_employee_id
    WHERE  i.register_id = @register_id
    ORDER  BY CASE i.status WHEN N'OPEN' THEN 0 ELSE 1 END, i.raised_dt DESC;

    -- 10 open periodic / triggered reviews of the linked engagements (monitoring status)
    SELECT v.review_id AS ReviewId, v.review_number AS ReviewNumber, v.review_type AS ReviewType, v.trigger_code AS TriggerCode,
           v.due_dt AS DueDt, v.status AS Status,
           CAST(CASE WHEN v.due_dt < CONVERT(DATE, SYSUTCDATETIME()) THEN 1 ELSE 0 END AS BIT) AS IsOverdue,
           e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode
    FROM   #links l
    JOIN   grac_practice.tprm_review v ON v.engagement_id = l.engagement_id
    JOIN   grac_practice.tprm_engagement e ON e.engagement_id = v.engagement_id
    WHERE  l.link_status = N'LINKED' AND v.status = N'OPEN'
    ORDER  BY v.due_dt;

    -- 11 history
    SELECT h.history_id AS HistoryId, h.event_code AS EventCode, h.detail AS Detail, h.event_dt AS EventDt,
           COALESCE(ae.employee_name, h.actor) AS ActorName, e.engagement_code AS EngagementCode
    FROM   grac_practice.tprm_register_history h
    LEFT   JOIN grac_practice.organization_employee ae ON ae.employee_id = h.actor_employee_id
    LEFT   JOIN grac_practice.tprm_engagement e ON e.engagement_id = h.engagement_id
    WHERE  h.register_id = @register_id
    ORDER  BY h.event_dt DESC, h.history_id DESC;
END
GO

-- Rate one vendor-level area (CR 2 8.2; decision 2026-11-08: a rating
-- per area on the bands of the risk model in force, with rationale and
-- evidence). The previous rating of the area is superseded, never
-- overwritten.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_register_rating_save
    @organization_id    BIGINT,
    @register_id        BIGINT,
    @area_code          NVARCHAR(60),
    @band_code          NVARCHAR(60),
    @rationale          NVARCHAR(2000),
    @evidence_reference NVARCHAR(1000) = NULL,
    @actor_employee_id  BIGINT         = NULL,
    @actor              NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @actor_employee_id IS NULL THROW 58152, 'Rating the profile needs a sign-in linked to an employee (the assessor).', 1;
    SET @area_code = NULLIF(LTRIM(RTRIM(@area_code)), N'');
    SET @band_code = NULLIF(LTRIM(RTRIM(@band_code)), N'');
    SET @rationale = NULLIF(LTRIM(RTRIM(@rationale)), N'');
    IF @rationale IS NULL THROW 58153, 'Give the rationale for the rating.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                    WHERE list_code = N'VENDOR_PROFILE_AREA' AND value_code = @area_code)
        THROW 58154, 'Choose a vendor profile area (Third-Party Settings -> Vendor profile areas).', 1;
    DECLARE @version BIGINT = (SELECT version_id FROM grac_practice.fn_tprm_risk_model_version(@organization_id));
    IF @version IS NULL THROW 58155, 'No risk model is in force. Activate one in Third-Party Settings.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_rm_band WHERE version_id = @version AND band_code = @band_code)
        THROW 58156, 'Choose a band of the risk model in force.', 1;

    DECLARE @status NVARCHAR(20), @id BIGINT, @label NVARCHAR(200), @band NVARCHAR(120);
    BEGIN TRAN;
        SELECT @status = status FROM grac_practice.tprm_risk_register WITH (UPDLOCK, HOLDLOCK)
        WHERE register_id = @register_id AND organization_id = @organization_id;
        IF @status IS NULL THROW 58151, 'That register record was not found.', 1;
        IF @status = N'CLOSED' THROW 58157, 'A closed register record cannot be changed.', 1;
        UPDATE grac_practice.tprm_register_profile_rating SET status = N'SUPERSEDED', superseded_dt = SYSUTCDATETIME()
         WHERE register_id = @register_id AND area_code = @area_code AND status = N'CURRENT';
        INSERT grac_practice.tprm_register_profile_rating
            (register_id, area_code, risk_model_version_id, band_code, rationale, evidence_reference, status, assessed_by_employee_id, assessed_by)
        VALUES (@register_id, @area_code, @version, @band_code, @rationale, NULLIF(LTRIM(RTRIM(@evidence_reference)), N''),
                N'CURRENT', @actor_employee_id, ISNULL(@actor, N'system'));
        SET @id = SCOPE_IDENTITY();
        UPDATE grac_practice.tprm_risk_register SET updated_by = @actor, updated_dt = SYSUTCDATETIME() WHERE register_id = @register_id;
        SELECT @label = label FROM grac_practice.fn_tprm_reference_effective(@organization_id) WHERE list_code = N'VENDOR_PROFILE_AREA' AND value_code = @area_code;
        SELECT @band = band_name FROM grac_practice.tprm_rm_band WHERE version_id = @version AND band_code = @band_code;
        DECLARE @detail NVARCHAR(2000) = LEFT(CONCAT(@label, N' rated ', @band, N'. ', @rationale), 2000);
        EXEC grac_practice.sp_tprm_register_event @register_id, N'PROFILE_RATED', NULL, @detail, @actor_employee_id, @actor;
    COMMIT;
    SELECT @id AS RatingId, N'SAVED' AS Result;
END
GO

-- Record the outcome of an impact review (CR 2 8.4). Segregation of
-- duties: the reviewer is not the decision-maker who included the new
-- engagement. PROFILE_UPDATED needs an area rating recorded since the
-- review was raised.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_register_impact_review_decide
    @organization_id   BIGINT,
    @impact_review_id  BIGINT,
    @outcome           NVARCHAR(20),
    @rationale         NVARCHAR(2000),
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @actor_employee_id IS NULL THROW 58158, 'Recording the impact review needs a sign-in linked to an employee.', 1;
    SET @outcome = UPPER(NULLIF(LTRIM(RTRIM(@outcome)), N''));
    IF @outcome IS NULL OR @outcome NOT IN (N'NO_CHANGE', N'PROFILE_UPDATED') THROW 58159, 'Choose no change or profile updated.', 1;
    SET @rationale = NULLIF(LTRIM(RTRIM(@rationale)), N'');
    IF @rationale IS NULL THROW 58160, 'Give the rationale for the outcome.', 1;

    DECLARE @reg BIGINT, @status NVARCHAR(20), @requester BIGINT, @raised DATETIME2, @eng BIGINT;
    BEGIN TRAN;
        SELECT @reg = i.register_id, @status = i.status, @requester = i.requested_by_employee_id, @raised = i.raised_dt, @eng = i.engagement_id
        FROM grac_practice.tprm_register_impact_review i WITH (UPDLOCK, HOLDLOCK)
        JOIN grac_practice.tprm_risk_register r ON r.register_id = i.register_id
        WHERE i.impact_review_id = @impact_review_id AND r.organization_id = @organization_id;
        IF @reg IS NULL THROW 58161, 'That impact review was not found.', 1;
        IF @status <> N'OPEN' THROW 58162, 'That impact review is no longer open.', 1;
        IF @requester IS NOT NULL AND @requester = @actor_employee_id
            THROW 58163, 'Segregation of duties: the decision-maker who included the engagement cannot review its impact.', 1;
        IF @outcome = N'PROFILE_UPDATED'
           AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_register_profile_rating WHERE register_id = @reg AND assessed_dt >= @raised)
            THROW 58164, 'Record the updated area rating(s) first, then complete the review as profile updated.', 1;
        UPDATE grac_practice.tprm_register_impact_review
           SET status = N'COMPLETED', outcome = @outcome, rationale = @rationale, reviewed_by_employee_id = @actor_employee_id,
               reviewed_dt = SYSUTCDATETIME()
         WHERE impact_review_id = @impact_review_id AND status = N'OPEN';
        DECLARE @detail NVARCHAR(2000) = LEFT(CONCAT(N'Impact review: ', CASE @outcome WHEN N'NO_CHANGE' THEN N'no change to the vendor profile' ELSE N'vendor profile updated' END,
                                                     N'. ', @rationale), 2000);
        EXEC grac_practice.sp_tprm_register_event @reg, N'IMPACT_REVIEW_COMPLETED', @eng, @detail, @actor_employee_id, @actor;
    COMMIT;
    SELECT @impact_review_id AS ImpactReviewId, N'COMPLETED' AS Result;
END
GO

-- Close a register record whose last engagement has left (CR 2 8.5).
-- Segregation of duties: not the person whose action started the exit.
-- The closed record stays readable.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_register_close
    @organization_id   BIGINT,
    @register_id       BIGINT,
    @rationale         NVARCHAR(2000),
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @actor_employee_id IS NULL THROW 58165, 'Closing the record needs a sign-in linked to an employee.', 1;
    SET @rationale = NULLIF(LTRIM(RTRIM(@rationale)), N'');
    IF @rationale IS NULL THROW 58166, 'Give the closure rationale.', 1;
    DECLARE @status NVARCHAR(20), @starter BIGINT;
    BEGIN TRAN;
        SELECT @status = status, @starter = exit_started_by_employee_id
        FROM grac_practice.tprm_risk_register WITH (UPDLOCK, HOLDLOCK)
        WHERE register_id = @register_id AND organization_id = @organization_id;
        IF @status IS NULL THROW 58151, 'That register record was not found.', 1;
        IF @status <> N'EXIT_IN_PROGRESS' THROW 58167, 'Only a record whose admitted engagements have all ended can be closed.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_register_engagement WHERE register_id = @register_id AND status = N'LINKED')
            THROW 58167, 'Only a record whose admitted engagements have all ended can be closed.', 1;
        IF @starter IS NOT NULL AND @starter = @actor_employee_id
            THROW 58168, 'Segregation of duties: the person who completed the last exit cannot close the record.', 1;
        UPDATE grac_practice.tprm_risk_register
           SET status = N'CLOSED', closed_dt = SYSUTCDATETIME(), closed_by_employee_id = @actor_employee_id, closure_rationale = @rationale,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE register_id = @register_id;
        DECLARE @detail NVARCHAR(2000) = LEFT(CONCAT(N'Record closed. ', @rationale), 2000);
        EXEC grac_practice.sp_tprm_register_event @register_id, N'CLOSED', NULL, @detail, @actor_employee_id, @actor;
    COMMIT;
    SELECT @register_id AS RegisterId, N'CLOSED' AS Result;
END
GO

-- =====================================================================
-- 5. Re-issued procedures
-- =====================================================================
-- Act on an admission level (523) -- re-issued by 524: the final approval
-- links the engagement to its vendor's TP Risk Register record
-- (sp_tprm_register_link). Otherwise as in 523.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_admission_act
    @organization_id          BIGINT,
    @admission_id             BIGINT,
    @action                   NVARCHAR(20),
    @rationale                NVARCHAR(2000) = NULL,
    @on_behalf_of_employee_id BIGINT         = NULL,
    @actor_employee_id        BIGINT         = NULL,
    @actor                    NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @actor_employee_id IS NULL THROW 58115, 'Approving needs a sign-in linked to an employee.', 1;
    DECLARE @eng BIGINT, @status NVARCHAR(20), @levels INT, @sod BIT, @submitter BIGINT, @decision_id BIGINT, @no INT;
    SELECT @eng = engagement_id, @status = status, @levels = required_levels, @sod = sod_required, @submitter = submitted_by_employee_id,
           @decision_id = applicability_decision_id, @no = admission_no
    FROM grac_practice.tprm_admission WHERE admission_id = @admission_id AND organization_id = @organization_id;
    IF @eng IS NULL THROW 58116, 'That admission was not found.', 1;
    IF @status <> N'PENDING' THROW 58117, 'That admission is no longer pending.', 1;
    SET @action = UPPER(NULLIF(LTRIM(RTRIM(@action)), N''));
    IF @action IS NULL OR @action NOT IN (N'APPROVE', N'REJECT', N'RETURN') THROW 58118, 'Choose approve, reject or return.', 1;
    SET @rationale = NULLIF(LTRIM(RTRIM(@rationale)), N'');
    IF @rationale IS NULL THROW 58119, 'Record the rationale.', 1;

    DECLARE @approval BIGINT, @level INT, @role NVARCHAR(120), @stage NVARCHAR(30), @applic NVARCHAR(30);
    BEGIN TRAN;
    -- Every check below runs under a lock on the admission and its
    -- engagement, so two approvers cannot act on the same level, and an
    -- engagement that was closed or re-decided cannot be admitted.
    SELECT @status = status FROM grac_practice.tprm_admission WITH (UPDLOCK, HOLDLOCK) WHERE admission_id = @admission_id;
    IF @status <> N'PENDING' THROW 58117, 'That admission is no longer pending.', 1;
    SELECT @stage = stage_code, @applic = applicability_status
    FROM grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK) WHERE engagement_id = @eng;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;
    IF @applic <> N'ADMISSION_PENDING'
       OR NOT EXISTS (SELECT 1 FROM grac_practice.tprm_applicability_decision WHERE decision_id = @decision_id AND status = N'CURRENT')
        THROW 58126, 'The engagement is no longer awaiting this admission. Refresh the page.', 1;
    SELECT TOP (1) @approval = approval_id, @level = level_no, @role = required_role_name
    FROM grac_practice.tprm_admission_approval WHERE admission_id = @admission_id AND status = N'PENDING' ORDER BY level_no;

    IF @on_behalf_of_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_approval_delegation
                        WHERE organization_id = @organization_id AND from_employee_id = @on_behalf_of_employee_id
                          AND to_employee_id = @actor_employee_id AND status = N'Active'
                          AND CONVERT(DATE, SYSUTCDATETIME()) BETWEEN valid_from AND valid_to)
        THROW 58120, 'You have no active delegation from that approver.', 1;
    DECLARE @authority BIGINT = COALESCE(@on_behalf_of_employee_id, @actor_employee_id);
    IF @role IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.organization_role WHERE organization_id = @organization_id
                                       AND role_name = @role AND status = N'Active')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                        JOIN grac_practice.organization_role r ON r.role_id = e.role_id
                        WHERE e.employee_id = @authority AND r.role_name = @role)
    BEGIN
        DECLARE @role_msg NVARCHAR(400) = CONCAT(N'Approval level ', @level, N' needs the role "', @role, N'".');
        THROW 58121, @role_msg, 1;
    END
    IF @sod = 1
    BEGIN
        IF @actor_employee_id = @submitter OR @authority = @submitter
            THROW 58122, 'Segregation of duties: the decision-maker who included the engagement cannot approve its admission.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_admission_approval WHERE admission_id = @admission_id AND status = N'APPROVED'
                     AND (approver_employee_id IN (@actor_employee_id, @authority) OR on_behalf_of_employee_id IN (@actor_employee_id, @authority)))
            THROW 58123, 'Segregation of duties: each approval level needs a different person.', 1;
    END

    DECLARE @final BIT = CASE WHEN @action <> N'APPROVE' OR @level >= @levels THEN 1 ELSE 0 END;
    DECLARE @outcome NVARCHAR(20) = CASE @action WHEN N'APPROVE' THEN N'APPROVED' WHEN N'REJECT' THEN N'REJECTED' ELSE N'RETURNED' END;
    DECLARE @to_status NVARCHAR(30) = CASE @action WHEN N'APPROVE' THEN N'ADMITTED' WHEN N'REJECT' THEN N'ADMISSION_REJECTED' ELSE N'SCREENED' END;
        UPDATE grac_practice.tprm_admission_approval
           SET status = @outcome, approver_employee_id = @actor_employee_id, on_behalf_of_employee_id = @on_behalf_of_employee_id,
               comment = @rationale, decided_dt = SYSUTCDATETIME()
         WHERE approval_id = @approval AND status = N'PENDING';
        IF @@ROWCOUNT = 0 THROW 58117, 'That admission is no longer pending.', 1;
        IF @final = 1
        BEGIN
            UPDATE grac_practice.tprm_admission_approval SET status = N'WITHDRAWN' WHERE admission_id = @admission_id AND status = N'PENDING';
            UPDATE grac_practice.tprm_admission
               SET status = @outcome, outcome_rationale = @rationale, decided_by_employee_id = @actor_employee_id, decided_dt = SYSUTCDATETIME()
             WHERE admission_id = @admission_id;
            -- returned: the INCLUDE decision no longer stands; a new decision is needed
            IF @action = N'RETURN'
                UPDATE grac_practice.tprm_applicability_decision SET status = N'SUPERSEDED', superseded_dt = SYSUTCDATETIME()
                 WHERE decision_id = @decision_id AND status = N'CURRENT';
            UPDATE grac_practice.tprm_engagement
               SET applicability_status = @to_status,
                   admitted_dt = CASE WHEN @action = N'APPROVE' THEN SYSUTCDATETIME() ELSE admitted_dt END,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE engagement_id = @eng;
            -- 524 (CR 2 8.1, 8.4): admitted -> the vendor's TP Risk Register
            -- record (created, or reopened, or joined with an impact review)
            IF @action = N'APPROVE'
                EXEC grac_practice.sp_tprm_register_link @eng, @admission_id, @actor_employee_id, @actor;
        END
        DECLARE @detail NVARCHAR(2000) = LEFT(CASE WHEN @final = 1
            THEN CONCAT(N'Admission ', @no, N' ', LOWER(@outcome), N'. ', @rationale,
                        CASE WHEN @action = N'APPROVE' THEN N' The engagement is admitted to formal TPRM.' ELSE N'' END)
            ELSE CONCAT(N'Admission ', @no, N': approval level ', @level, N' approved. ', @rationale) END, 2000);
        EXEC grac_practice.sp_tprm_engagement_event @eng, N'ADMISSION', @stage, @stage, @detail, @actor_employee_id, @actor;
    COMMIT;
    DECLARE @audit_json NVARCHAR(MAX) = (SELECT @action AS action, @level AS levelNo, @rationale AS rationale,
                                                @on_behalf_of_employee_id AS onBehalfOfEmployeeId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC grac_practice.sp_tprm_audit N'tprm-admission', @admission_id, @action, @audit_json, @actor;
    SELECT @admission_id AS AdmissionId, CASE WHEN @final = 1 THEN @to_status ELSE N'LEVEL_APPROVED' END AS Result;
END
GO

-- Engagement lifecycle actions (489) -- re-issued by 524: an exited or
-- cancelled engagement leaves its TP Risk Register record
-- (sp_tprm_register_sync_engagement); cancelling withdraws a pending
-- admission. Otherwise as in 489.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_lifecycle
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @action            NVARCHAR(20),
    @reason            NVARCHAR(1000) = NULL,
    @new_end_dt        DATE           = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30), @tp BIGINT, @end DATE;
    SELECT @stage = stage_code, @tp = third_party_id, @end = COALESCE(actual_end_dt, proposed_end_dt)
    FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @stage IS NULL THROW 57700, 'That engagement was not found.', 1;
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    IF @reason IS NULL THROW 57804, 'Give the reason.', 1;
    DECLARE @to NVARCHAR(30) = @stage, @rid BIGINT, @due DATE = DATEADD(DAY, 30, CONVERT(DATE, SYSUTCDATETIME()));

    BEGIN TRAN;
    IF @action = N'SUSPEND'
    BEGIN
        IF @stage <> N'ACTIVE' BEGIN ROLLBACK; THROW 57805, 'Only an active engagement can be suspended.', 1; END
        SET @to = N'SUSPENDED';
    END
    ELSE IF @action = N'RESUME'
    BEGIN
        IF @stage <> N'SUSPENDED' BEGIN ROLLBACK; THROW 57806, 'Only a suspended engagement can be resumed.', 1; END
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND reassessment_required = 1)
        BEGIN ROLLBACK; THROW 57807, 'The engagement needs reassessment before it can resume.', 1; END
        SET @to = N'ACTIVE';
    END
    ELSE IF @action = N'RENEW'
    BEGIN
        IF @stage NOT IN (N'ACTIVE', N'SUSPENDED') BEGIN ROLLBACK; THROW 57808, 'Only a live engagement can be renewed.', 1; END
        IF @new_end_dt IS NULL OR (@end IS NOT NULL AND @new_end_dt <= @end) BEGIN ROLLBACK; THROW 57809, 'Give a new end date after the current one.', 1; END
        UPDATE grac_practice.tprm_engagement SET actual_end_dt = @new_end_dt, renewal_dt = CONVERT(DATE, SYSUTCDATETIME()) WHERE engagement_id = @engagement_id;
        DECLARE @rkey NVARCHAR(200) = CONCAT(N'RENEWAL:', @engagement_id, N':', CONVERT(NVARCHAR(10), @new_end_dt, 23));
        EXEC grac_practice.sp_tprm_review_create @organization_id, @engagement_id, N'TRIGGERED', N'CONTRACT_RENEWAL', @reason, @due, NULL, @rkey, @actor, @rid OUTPUT;
    END
    ELSE IF @action = N'SCOPE_CHANGE'
    BEGIN
        IF @stage NOT IN (N'ACTIVE', N'SUSPENDED', N'ONBOARDING', N'APPROVED') BEGIN ROLLBACK; THROW 57810, 'Scope changes are recorded for approved or live engagements.', 1; END
        UPDATE grac_practice.tprm_engagement SET reassessment_required = 1, reassessment_reason = LEFT(CONCAT(N'Material scope change: ', @reason), 1000)
         WHERE engagement_id = @engagement_id;
        DECLARE @skey NVARCHAR(200) = CONCAT(N'SCOPE:', @engagement_id, N':', CONVERT(NVARCHAR(36), NEWID()));
        EXEC grac_practice.sp_tprm_review_create @organization_id, @engagement_id, N'TRIGGERED', N'SCOPE_CHANGE', @reason, @due, NULL, @skey, @actor, @rid OUTPUT;
    END
    ELSE IF @action = N'START_EXIT'
    BEGIN
        IF @stage NOT IN (N'ACTIVE', N'SUSPENDED', N'APPROVED', N'ONBOARDING') BEGIN ROLLBACK; THROW 57811, 'Exit starts from an approved or live engagement.', 1; END
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_decision WHERE engagement_id = @engagement_id AND status = N'PENDING')
        BEGIN ROLLBACK; THROW 57812, 'Withdraw the pending decision first.', 1; END
        EXEC grac_practice.sp_tprm_checks_create @organization_id, @engagement_id, N'EXIT', @actor;
        SET @to = N'EXITING';
    END
    ELSE IF @action = N'COMPLETE_EXIT'
    BEGIN
        IF @stage <> N'EXITING' BEGIN ROLLBACK; THROW 57813, 'Start the exit first.', 1; END
        DECLARE @pending INT = (SELECT COUNT(*) FROM grac_practice.tprm_onboarding_item WHERE engagement_id = @engagement_id
                                  AND phase = N'EXIT' AND is_mandatory = 1 AND status = N'PENDING');
        IF @pending > 0
        BEGIN
            ROLLBACK;
            DECLARE @emsg NVARCHAR(300) = CONCAT(@pending, N' mandatory exit check(s) are not done or waived (data return, deletion evidence, access, dependencies).');
            THROW 57814, @emsg, 1;
        END
        UPDATE grac_practice.tprm_engagement SET actual_end_dt = COALESCE(actual_end_dt, CONVERT(DATE, SYSUTCDATETIME())), next_review_dt = NULL
         WHERE engagement_id = @engagement_id;
        UPDATE grac_practice.tprm_review SET status = N'CANCELLED', outcome_note = N'Engagement exited.' WHERE engagement_id = @engagement_id AND status = N'OPEN';
        UPDATE grac_practice.tprm_finding SET status = N'CANCELLED', status_note = N'Engagement exited.', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @engagement_id AND status IN (N'OPEN', N'IN_PROGRESS') AND custom_gap_id IS NULL;
        SET @to = N'EXITED';
    END
    ELSE IF @action = N'CANCEL'
    BEGIN
        IF @stage NOT IN (N'SCOPING', N'RISK_ASSESSED', N'DUE_DILIGENCE', N'APPROVED', N'ONBOARDING')
        BEGIN ROLLBACK; THROW 57815, 'Only an engagement that is not yet active can be cancelled (withdraw a pending decision first).', 1; END
        UPDATE grac_practice.tprm_dd_assessment SET status = N'CANCELLED' WHERE engagement_id = @engagement_id AND status = N'IN_PROGRESS';
        UPDATE grac_practice.tprm_risk_assessment SET status = N'DISCARDED' WHERE engagement_id = @engagement_id AND status = N'DRAFT';
        UPDATE grac_practice.tprm_finding SET status = N'CANCELLED', status_note = N'Engagement cancelled.', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @engagement_id AND status IN (N'OPEN', N'IN_PROGRESS') AND custom_gap_id IS NULL;
        UPDATE grac_practice.tprm_review SET status = N'CANCELLED', outcome_note = N'Engagement cancelled.' WHERE engagement_id = @engagement_id AND status = N'OPEN';
        -- 524: a pending admission ends with the engagement (withdrawn; the
        -- INCLUDE decision no longer stands)
        UPDATE grac_practice.tprm_admission_approval SET status = N'WITHDRAWN'
         WHERE status = N'PENDING'
           AND admission_id IN (SELECT admission_id FROM grac_practice.tprm_admission WHERE engagement_id = @engagement_id AND status = N'PENDING');
        UPDATE grac_practice.tprm_applicability_decision SET status = N'SUPERSEDED', superseded_dt = SYSUTCDATETIME()
         WHERE status = N'CURRENT'
           AND decision_id IN (SELECT applicability_decision_id FROM grac_practice.tprm_admission WHERE engagement_id = @engagement_id AND status = N'PENDING');
        UPDATE grac_practice.tprm_admission
           SET status = N'WITHDRAWN', outcome_rationale = N'Engagement cancelled.', decided_by_employee_id = @actor_employee_id, decided_dt = SYSUTCDATETIME()
         WHERE engagement_id = @engagement_id AND status = N'PENDING';
        UPDATE grac_practice.tprm_engagement SET applicability_status = N'SCREENED'
         WHERE engagement_id = @engagement_id AND applicability_status = N'ADMISSION_PENDING';
        SET @to = N'CANCELLED';
    END
    ELSE BEGIN ROLLBACK; THROW 57816, 'Unknown lifecycle action.', 1; END

    IF @to <> @stage
        UPDATE grac_practice.tprm_engagement SET stage_code = @to, stage_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @engagement_id;
    -- 524 (CR 2 8.5): an exited or cancelled engagement leaves its TP Risk
    -- Register record; the last one starts the record's exit
    IF @to IN (N'EXITED', N'CANCELLED')
        EXEC grac_practice.sp_tprm_register_sync_engagement @engagement_id, @actor_employee_id, @actor;
    COMMIT;

    EXEC grac_practice.sp_tprm_third_party_sync_status @tp, @actor;
    DECLARE @evt NVARCHAR(40) = CONCAT(N'LIFECYCLE_', @action);
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, @evt, @stage, @to, @reason, @actor_employee_id, @actor;
    SELECT @engagement_id AS EngagementId, @to AS Result;
END
GO

-- Risk decision approval (489) -- re-issued by 524: a rejected engagement
-- leaves its TP Risk Register record; the level update requires the level
-- to be still pending. Otherwise as in 489.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_decision_act
    @organization_id          BIGINT,
    @decision_id              BIGINT,
    @action                   NVARCHAR(20),
    @outcome_code             NVARCHAR(60)   = NULL,
    @rationale                NVARCHAR(2000) = NULL,
    @risk_accepted            BIT            = 0,
    @acceptance_until         DATE           = NULL,
    @mandatory_review_dt      DATE           = NULL,
    @conditions_json          NVARCHAR(MAX)  = NULL,   -- [{"title","description","severity","ownerEmployeeId","dueDt"}]
    @on_behalf_of_employee_id BIGINT         = NULL,
    @actor_employee_id        BIGINT         = NULL,
    @actor                    NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @actor_employee_id IS NULL THROW 57765, 'Approving needs a sign-in linked to an employee.', 1;
    DECLARE @eng BIGINT, @status NVARCHAR(20), @levels INT, @sod BIT, @submitter BIGINT, @prior NVARCHAR(30), @rule_json NVARCHAR(MAX), @dd BIGINT;
    SELECT @eng = engagement_id, @status = status, @levels = required_levels, @sod = sod_required, @submitter = submitted_by_employee_id,
           @prior = prior_stage_code, @rule_json = rule_snapshot_json, @dd = dd_id
    FROM grac_practice.tprm_decision WHERE decision_id = @decision_id AND organization_id = @organization_id;
    IF @eng IS NULL THROW 57766, 'That decision was not found.', 1;
    IF @status <> N'PENDING' THROW 57767, 'That decision is no longer pending.', 1;
    IF @action NOT IN (N'APPROVE', N'REJECT', N'RETURN') THROW 57768, 'Unknown decision action.', 1;
    SET @rationale = NULLIF(LTRIM(RTRIM(@rationale)), N'');
    IF @rationale IS NULL THROW 57769, 'Record the rationale for the decision.', 1;

    DECLARE @approval BIGINT, @level INT, @role NVARCHAR(120);
    SELECT TOP (1) @approval = approval_id, @level = level_no, @role = required_role_name
    FROM grac_practice.tprm_decision_approval WHERE decision_id = @decision_id AND status = N'PENDING' ORDER BY level_no;

    -- delegation
    IF @on_behalf_of_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_approval_delegation
                        WHERE organization_id = @organization_id AND from_employee_id = @on_behalf_of_employee_id
                          AND to_employee_id = @actor_employee_id AND status = N'Active'
                          AND CONVERT(DATE, SYSUTCDATETIME()) BETWEEN valid_from AND valid_to)
        THROW 57770, 'You have no active delegation from that approver.', 1;
    DECLARE @authority BIGINT = COALESCE(@on_behalf_of_employee_id, @actor_employee_id);

    -- role
    IF @role IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.organization_role WHERE organization_id = @organization_id
                                       AND role_name = @role AND status = N'Active')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                        JOIN grac_practice.organization_role r ON r.role_id = e.role_id
                        WHERE e.employee_id = @authority AND r.role_name = @role)
    BEGIN
        DECLARE @role_msg NVARCHAR(400) = CONCAT(N'Approval level ', @level, N' needs the role "', @role, N'".');
        THROW 57771, @role_msg, 1;
    END

    -- segregation of duties
    IF @sod = 1
    BEGIN
        IF @actor_employee_id = @submitter OR @authority = @submitter
            THROW 57772, 'Segregation of duties: the person who requested the decision cannot approve it.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @eng AND assessor_employee_id IN (@actor_employee_id, @authority))
           OR EXISTS (SELECT 1 FROM grac_practice.tprm_dd_assessment WHERE dd_id = @dd AND assessor_employee_id IN (@actor_employee_id, @authority))
            THROW 57773, 'Segregation of duties: the assessor of this engagement cannot approve it.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_decision_approval WHERE decision_id = @decision_id AND status = N'APPROVED'
                     AND (approver_employee_id IN (@actor_employee_id, @authority) OR on_behalf_of_employee_id IN (@actor_employee_id, @authority)))
            THROW 57774, 'Segregation of duties: each approval level needs a different person.', 1;
    END

    DECLARE @final BIT = CASE WHEN @action <> N'APPROVE' OR @level >= @levels THEN 1 ELSE 0 END;
    DECLARE @meaning NVARCHAR(40), @max_months INT = TRY_CONVERT(INT, JSON_VALUE(@rule_json, '$.max_acceptance_months')),
            @allowed NVARCHAR(400) = JSON_VALUE(@rule_json, '$.allowed_decision_codes');
    IF @final = 1
    BEGIN
        IF @action = N'APPROVE'
        BEGIN
            SELECT TOP (1) @meaning = meaning_code FROM grac_practice.fn_tprm_reference_effective(@organization_id)
             WHERE list_code = N'DECISION' AND value_code = @outcome_code;
            IF @meaning NOT IN (N'APPROVE', N'APPROVE_WITH_CONDITIONS') OR @meaning IS NULL
                THROW 57775, 'Choose an approval outcome.', 1;
            IF @allowed IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(@allowed) x WHERE x.code = @outcome_code)
                THROW 57776, 'That outcome is not allowed by the approval rule.', 1;
        END
        ELSE
        BEGIN
            SET @meaning = @action;
            IF @outcome_code IS NULL OR NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                                     WHERE list_code = N'DECISION' AND value_code = @outcome_code AND meaning_code = @meaning)
                SET @outcome_code = grac_practice.fn_tprm_meaning_code(@organization_id, N'DECISION', @meaning);
        END
        IF @conditions_json IS NOT NULL AND ISJSON(@conditions_json) <> 1 THROW 57777, 'Conditions are not valid.', 1;
        IF @meaning = N'APPROVE_WITH_CONDITIONS'
           AND NOT EXISTS (SELECT 1 FROM OPENJSON(ISNULL(@conditions_json, N'[]')) WITH (title NVARCHAR(300) '$.title') WHERE NULLIF(LTRIM(RTRIM(title)), N'') IS NOT NULL)
           AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_finding WHERE engagement_id = @eng AND finding_kind = N'CONDITION' AND status IN (N'OPEN', N'IN_PROGRESS'))
            THROW 57778, 'Approval with conditions needs at least one condition.', 1;
        IF ISNULL(@risk_accepted, 0) = 1
        BEGIN
            IF @meaning NOT IN (N'APPROVE', N'APPROVE_WITH_CONDITIONS') THROW 57779, 'Risk is accepted only with an approval.', 1;
            IF @acceptance_until IS NULL OR @acceptance_until <= CONVERT(DATE, SYSUTCDATETIME())
                THROW 57780, 'Risk acceptance is time-bound: give a future end date.', 1;
            IF @max_months IS NOT NULL AND @acceptance_until > DATEADD(MONTH, @max_months, CONVERT(DATE, SYSUTCDATETIME()))
            BEGIN
                DECLARE @acc_msg NVARCHAR(300) = CONCAT(N'The approval rule allows risk acceptance for at most ', @max_months, N' months.');
                THROW 57781, @acc_msg, 1;
            END
            SET @mandatory_review_dt = COALESCE(@mandatory_review_dt, @acceptance_until);
        END
        IF @mandatory_review_dt IS NOT NULL AND @mandatory_review_dt <= CONVERT(DATE, SYSUTCDATETIME())
            THROW 57782, 'The mandatory review date must be in the future.', 1;
    END

    DECLARE @new_stage NVARCHAR(30);
    BEGIN TRAN;
        UPDATE grac_practice.tprm_decision_approval
           SET status = CASE @action WHEN N'APPROVE' THEN N'APPROVED' WHEN N'REJECT' THEN N'REJECTED' ELSE N'RETURNED' END,
               approver_employee_id = @actor_employee_id, on_behalf_of_employee_id = @on_behalf_of_employee_id,
               comment = @rationale, decided_dt = SYSUTCDATETIME()
         WHERE approval_id = @approval AND status = N'PENDING';
        -- 524: two approvers acting on the same level at once -- the second fails
        IF @@ROWCOUNT = 0 THROW 57767, 'That decision is no longer pending.', 1;

        IF @final = 1
        BEGIN
            UPDATE grac_practice.tprm_decision_approval SET status = N'WITHDRAWN' WHERE decision_id = @decision_id AND status = N'PENDING';
            UPDATE grac_practice.tprm_decision
               SET status = N'DECIDED', outcome_code = @outcome_code, outcome_meaning = @meaning, rationale = @rationale,
                   risk_accepted = ISNULL(@risk_accepted, 0), acceptance_until = CASE WHEN @risk_accepted = 1 THEN @acceptance_until END,
                   mandatory_review_dt = @mandatory_review_dt, decided_by_employee_id = @actor_employee_id, decided_dt = SYSUTCDATETIME()
             WHERE decision_id = @decision_id;

            -- conditions become CONDITION findings that must be met before activation
            IF @conditions_json IS NOT NULL
            BEGIN
                DECLARE @c_title NVARCHAR(300), @c_desc NVARCHAR(2000), @c_sev NVARCHAR(60), @c_owner BIGINT, @c_due DATE, @c_no NVARCHAR(20);
                DECLARE cc CURSOR LOCAL FAST_FORWARD FOR
                    SELECT LEFT(LTRIM(RTRIM(title)), 300), description, UPPER(ISNULL(NULLIF(severity, N''), N'MEDIUM')), ownerEmployeeId, dueDt
                    FROM OPENJSON(@conditions_json) WITH (title NVARCHAR(300) '$.title', description NVARCHAR(2000) '$.description',
                                                          severity NVARCHAR(60) '$.severity', ownerEmployeeId BIGINT '$.ownerEmployeeId', dueDt DATE '$.dueDt')
                    WHERE NULLIF(LTRIM(RTRIM(title)), N'') IS NOT NULL;
                OPEN cc;
                FETCH NEXT FROM cc INTO @c_title, @c_desc, @c_sev, @c_owner, @c_due;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    EXEC grac_practice.sp_tprm_next_number @organization_id, N'TPF-', @c_no OUTPUT;
                    INSERT grac_practice.tprm_finding
                        (organization_id, engagement_id, dd_id, finding_number, finding_kind, source_kind, source_id, is_automatic, title,
                         description, severity_code, owner_employee_id, due_dt, is_mandatory_for_activation, status, entered_by)
                    VALUES (@organization_id, @eng, @dd, @c_no, N'CONDITION', N'DECISION', @decision_id, 0, @c_title, @c_desc,
                            CASE WHEN EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                               WHERE list_code = N'FINDING_SEVERITY' AND value_code = @c_sev) THEN @c_sev ELSE N'MEDIUM' END,
                            CASE WHEN EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @c_owner AND organization_id = @organization_id)
                                 THEN @c_owner END,
                            @c_due, 1, N'OPEN', @actor);
                    FETCH NEXT FROM cc INTO @c_title, @c_desc, @c_sev, @c_owner, @c_due;
                END
                CLOSE cc;
                DEALLOCATE cc;
            END

            SET @new_stage = CASE
                WHEN @meaning IN (N'APPROVE', N'APPROVE_WITH_CONDITIONS') THEN CASE WHEN @prior IN (N'ACTIVE', N'SUSPENDED', N'ONBOARDING') THEN @prior ELSE N'APPROVED' END
                WHEN @meaning = N'REJECT' THEN CASE WHEN @prior IN (N'ACTIVE', N'SUSPENDED') THEN N'SUSPENDED' ELSE N'REJECTED' END
                ELSE CASE WHEN @prior IN (N'ACTIVE', N'SUSPENDED') THEN @prior ELSE N'DUE_DILIGENCE' END END;
            UPDATE grac_practice.tprm_engagement
               SET stage_code = @new_stage, stage_dt = SYSUTCDATETIME(),
                   acceptance_until = CASE WHEN @meaning IN (N'APPROVE', N'APPROVE_WITH_CONDITIONS') AND @risk_accepted = 1 THEN @acceptance_until
                                           WHEN @meaning IN (N'APPROVE', N'APPROVE_WITH_CONDITIONS') THEN NULL ELSE acceptance_until END,
                   next_review_dt = CASE WHEN @mandatory_review_dt IS NOT NULL THEN @mandatory_review_dt ELSE next_review_dt END,
                   reassessment_required = CASE WHEN @meaning IN (N'RETURN', N'REJECT') AND @prior IN (N'ACTIVE', N'SUSPENDED') THEN 1 ELSE reassessment_required END,
                   reassessment_reason = CASE WHEN @meaning IN (N'RETURN', N'REJECT') AND @prior IN (N'ACTIVE', N'SUSPENDED')
                                              THEN LEFT(CONCAT(CASE WHEN @meaning = N'REJECT' THEN N'Decision rejected: ' ELSE N'Decision returned: ' END, @rationale), 1000)
                                              ELSE reassessment_reason END,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE engagement_id = @eng;
            -- 524 (CR 2 8.5): a rejected engagement leaves its TP Risk Register record
            IF @new_stage = N'REJECTED'
                EXEC grac_practice.sp_tprm_register_sync_engagement @eng, @actor_employee_id, @actor;
            -- returned: due diligence reopens for more information
            IF @meaning = N'RETURN' AND @dd IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_dd_assessment WHERE engagement_id = @eng AND status = N'IN_PROGRESS')
                UPDATE grac_practice.tprm_dd_assessment SET status = N'IN_PROGRESS', completed_by = NULL, completed_dt = NULL WHERE dd_id = @dd;
        END
    COMMIT;

    DECLARE @tp BIGINT = (SELECT third_party_id FROM grac_practice.tprm_engagement WHERE engagement_id = @eng);
    IF @final = 1 EXEC grac_practice.sp_tprm_third_party_sync_status @tp, @actor;
    DECLARE @audit_json NVARCHAR(MAX) = (SELECT @action AS action, @level AS levelNo, @outcome_code AS outcomeCode, @rationale AS rationale,
                                                @risk_accepted AS riskAccepted, @acceptance_until AS acceptanceUntil,
                                                @on_behalf_of_employee_id AS onBehalfOfEmployeeId
                                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC grac_practice.sp_tprm_audit N'tprm-decision', @decision_id, @action, @audit_json, @actor;
    DECLARE @detail NVARCHAR(2000) = CASE WHEN @final = 1
        THEN CONCAT(N'Decision: ', @outcome_code, CASE WHEN @risk_accepted = 1 THEN CONCAT(N'; risk accepted until ', CONVERT(NVARCHAR(10), @acceptance_until, 23)) ELSE N'' END,
                    N'. ', @rationale)
        ELSE CONCAT(N'Approval level ', @level, N' approved. ', @rationale) END;
    DECLARE @from_stage NVARCHAR(30) = CASE WHEN @final = 1 THEN N'PENDING_DECISION' END;
    EXEC grac_practice.sp_tprm_engagement_event @eng, N'DECISION', @from_stage, @new_stage, @detail, @actor_employee_id, @actor;
    SELECT @decision_id AS DecisionId, CASE WHEN @final = 1 THEN N'DECIDED' ELSE N'LEVEL_APPROVED' END AS Result;
END
GO

-- One engagement (523) -- re-issued by 524: + RegisterId, RegisterCode,
-- RegisterStatus. Otherwise as in 523.
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
           t.lifecycle_status_code AS ThirdPartyStatusCode, ts.label AS ThirdPartyStatus,
           grac_practice.fn_tprm_vendor_status_meaning(t.organization_id, t.lifecycle_status_code) AS ThirdPartyStatusMeaning,
           e.service_description AS ServiceDescription, e.scope_description AS ScopeDescription, e.business_purpose AS BusinessPurpose,
           e.service_category_code AS ServiceCategoryCode, sc.label AS ServiceCategory,
           e.engagement_type_code AS EngagementTypeCode, et.label AS EngagementType,
           e.service_model_code AS ServiceModelCode, sm.label AS ServiceModel,
           e.delivery_locations AS DeliveryLocations, e.is_existing AS IsExisting,
           e.contract_id AS ContractId, e.contract_reference AS ContractReference, e.contract_value AS ContractValue,
           e.currency_code AS CurrencyCode, e.contract_start_dt AS ContractStartDt, e.contract_end_dt AS ContractEndDt,
           e.contract_documents AS ContractDocuments,
           e.proposed_start_dt AS ProposedStartDt, e.proposed_end_dt AS ProposedEndDt,
           e.actual_start_dt AS ActualStartDt, e.actual_end_dt AS ActualEndDt, e.renewal_dt AS RenewalDt,
           e.business_owner_employee_id AS BusinessOwnerEmployeeId, bo.employee_name AS BusinessOwnerName,
           e.relationship_owner_employee_id AS RelationshipOwnerEmployeeId, ro.employee_name AS RelationshipOwnerName,
           e.assessor_employee_id AS AssessorEmployeeId, ae.employee_name AS AssessorName,
           e.service_criticality_code AS CriticalityCode, cr.label AS Criticality, cr.color_hex AS CriticalityColor,
           e.data_exposure_code AS DataExposureCode, de.label AS DataExposure, e.data_processing_details AS DataProcessingDetails,
           e.rto_hours AS RtoHours, e.rpo_hours AS RpoHours, e.sla_summary AS SlaSummary,
           e.service_recipient AS ServiceRecipient, e.substitutability_code AS SubstitutabilityCode, sb.label AS Substitutability,
           e.customer_impact_code AS CustomerImpactCode, ci.label AS CustomerImpact, e.exit_dependencies AS ExitDependencies,
           e.app_access_answer AS AppAccessAnswer, e.premises_access_answer AS PremisesAccessAnswer,
           e.data_processing_answer AS DataProcessingAnswer, e.subcontracting_answer AS SubcontractingAnswer,
           e.important_process_answer AS ImportantProcessAnswer, e.disruption_impact_answer AS DisruptionImpactAnswer,
           e.service_commitment_answer AS ServiceCommitmentAnswer, e.contract_answer AS ContractAnswer,
           e.exposure_saved_dt AS ExposureSavedDt, e.exposure_saved_by AS ExposureSavedBy,
           e.applicability_status AS ApplicabilityStatus, e.current_screening_report_id AS CurrentScreeningReportId,
           sr.version_no AS ScreeningVersionNo, sr.classification AS ScreeningClassification, sr.generated_dt AS ScreeningDt,
           e.admitted_dt AS AdmittedDt,
           rg.register_id AS RegisterId, rg.register_code AS RegisterCode, rg.status AS RegisterStatus,
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
    -- 524: the TP Risk Register record the engagement is (or was last) linked to
    OUTER  APPLY (SELECT TOP (1) r.register_id, r.register_code, r.status
                  FROM grac_practice.tprm_register_engagement l
                  JOIN grac_practice.tprm_risk_register r ON r.register_id = l.register_id
                  WHERE l.engagement_id = e.engagement_id
                  ORDER BY CASE l.status WHEN N'LINKED' THEN 0 ELSE 1 END, l.linked_dt DESC) rg
    LEFT   JOIN ref sc ON sc.list_code = N'SERVICE_CATEGORY' AND sc.value_code = e.service_category_code
    LEFT   JOIN ref et ON et.list_code = N'ENGAGEMENT_TYPE' AND et.value_code = e.engagement_type_code
    LEFT   JOIN ref sm ON sm.list_code = N'SERVICE_MODEL' AND sm.value_code = e.service_model_code
    LEFT   JOIN ref cr ON cr.list_code = N'CRITICALITY' AND cr.value_code = e.service_criticality_code
    LEFT   JOIN ref de ON de.list_code = N'DATA_EXPOSURE' AND de.value_code = e.data_exposure_code
    LEFT   JOIN ref dt ON dt.list_code = N'DD_TIER' AND dt.value_code = e.dd_tier_code
    LEFT   JOIN ref sb ON sb.list_code = N'SUBSTITUTABILITY' AND sb.value_code = e.substitutability_code
    LEFT   JOIN ref ci ON ci.list_code = N'CUSTOMER_IMPACT' AND ci.value_code = e.customer_impact_code
    LEFT   JOIN grac_practice.tprm_rm_band ib ON ib.version_id = e.risk_model_version_id AND ib.band_code = e.inherent_band_code
    LEFT   JOIN grac_practice.tprm_rm_band rb ON rb.version_id = e.risk_model_version_id AND rb.band_code = e.residual_band_code
    LEFT   JOIN grac_practice.organization_employee bo ON bo.employee_id = e.business_owner_employee_id
    LEFT   JOIN grac_practice.organization_employee ro ON ro.employee_id = e.relationship_owner_employee_id
    LEFT   JOIN grac_practice.organization_employee ae ON ae.employee_id = e.assessor_employee_id
    LEFT   JOIN grac_practice.tprm_screening_report sr ON sr.report_id = e.current_screening_report_id
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

-- =====================================================================
-- 6. Menu: TP Risk Register (CR 2 menu 3.3; also in 274 and 490)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'tprm-risk-register', N'TP Risk Register', N'Practice/Index/tprm-risk-register', 374, N'shield-halved', N'Third-Party Management')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'migration-524', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'migration-524');
UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'migration-524', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-tprm'
 WHERE c.menu_key = N'tprm-risk-register' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
UPDATE grac_practice.menu_master SET show_in_sidebar = 1
 WHERE menu_key = N'tprm-risk-register' AND show_in_sidebar = 0;
GO
-- Grants: every role that holds Engagement Management gets the same
-- rights on the register (VIEW / ADD / EDIT / APPROVE; never DELETE).
-- Missing rows only.
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT p.role_id, m.menu_id, p.can_view, p.can_add, p.can_edit, 0, p.can_approve, N'Active', @active_rs, N'migration-524', SYSUTCDATETIME()
  FROM grac_practice.menu_master src
  JOIN grac_practice.organization_role_menu_permission p ON p.menu_id = src.menu_id AND p.status = N'Active' AND p.can_view = 1
  JOIN grac_practice.menu_master m ON m.menu_key = N'tprm-risk-register'
 WHERE src.menu_key = N'tprm-engagements'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e WHERE e.role_id = p.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('524: TP Risk Register grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 7. Existing data: engagements admitted before 524 join their vendor's
--    record (no impact review -- they were admitted before the register
--    existed). Re-run: only engagements not yet linked.
-- =====================================================================
DECLARE @eng BIGINT, @n INT = 0;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT e.engagement_id FROM grac_practice.tprm_engagement e
    WHERE e.applicability_status = N'ADMITTED' AND e.stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED')
      AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_register_engagement l WHERE l.engagement_id = e.engagement_id)
    ORDER BY e.organization_id, e.third_party_id, COALESCE(e.admitted_dt, e.entered_dt), e.engagement_id;
OPEN c;
FETCH NEXT FROM c INTO @eng;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRAN;
        EXEC grac_practice.sp_tprm_register_link @eng, NULL, NULL, N'migration-524', 0;
    COMMIT;
    SET @n = @n + 1;
    FETCH NEXT FROM c INTO @eng;
END
CLOSE c;
DEALLOCATE c;
PRINT CONCAT('524: admitted engagements linked to the TP Risk Register: ', @n);
GO

-- =====================================================================
-- 8. Verification
-- =====================================================================
SELECT '524-a register objects' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.tprm_risk_register', 'U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_register_engagement', 'U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_register_profile_rating', 'U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_register_impact_review', 'U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_register_history', 'U') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_tprm_register_overall') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_register_get', 'P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_register_close', 'P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '524-b list VENDOR_PROFILE_AREA',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.tprm_reference_value
                   WHERE organization_id IS NULL AND list_code = N'VENDOR_PROFILE_AREA' AND status = N'Active') >= 8
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '524-c menu under Third-Party Management',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
                          WHERE c.menu_key = N'tprm-risk-register' AND p.menu_key = N'nav-tprm' AND c.status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '524-d every admitted open engagement linked',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement e
                              WHERE e.applicability_status = N'ADMITTED' AND e.stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED')
                                AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_register_engagement l
                                                 WHERE l.engagement_id = e.engagement_id AND l.status = N'LINKED'))
            THEN 'PASS' ELSE 'FAIL' END;
GO
SET NOEXEC OFF;
GO
