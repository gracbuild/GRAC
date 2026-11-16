-- =====================================================================
-- 489_tprm_due_diligence_decision_monitoring.sql
--
-- REQUEST (2026-10-24)
-- --------------------
--   TPRM BRD section 3 steps 3-5 and section 4 (lifecycle):
--     Step 3  Due diligence, safeguards and evidence -- questionnaires
--             generated from service type, scope, inherent risk and
--             applicability rules (conditional follow-ups), third-party
--             and internal responses with assessor ratings and reviewer
--             comments, evidence from the GRAC Evidence Center or an
--             external reference, contractual / operational safeguards
--             whose EFFECTIVENESS is assessed and verified (a policy,
--             certificate or clause alone is not counted), deficiencies,
--             exceptions and remediation with owners and due dates, and
--             a residual risk recalculated from verified safeguards and
--             treatment outcomes whenever they change.
--     Step 4  Risk decision and approval -- a decision pack, configurable
--             outcomes (Approved / with conditions / Rejected / Returned),
--             approval paths from the approval rules with segregation of
--             duties and delegation, time-bound risk acceptance with a
--             mandatory review date, escalation to the GRAC Risk Centre
--             or a link to an existing enterprise risk -- never an
--             automatic copy of every engagement risk.
--     Step 5  Onboarding and operationalisation -- prerequisites that
--             must be met or formally waived, actual exposure compared
--             with the proposed one, deviations that trigger
--             reassessment, activation, review schedule.
--     Lifecycle  periodic reviews, contract / certification / acceptance
--             expiry, incident and material-change triggers, overdue
--             remediation, assurance failures, suspension, renewal, scope
--             change, exit with data return / deletion evidence and
--             dependency deactivation checks; history kept after closure.
--
-- REUSE (BRD 7)
-- -------------
--   Evidence      GRAC Evidence Center items (476 / 477), linked here by
--                 item and PINNED version; visibility through
--                 fn_pm_evidence_item_visible. No second file store.
--   Gaps          a deficiency can be raised to the Gap Register through
--                 sp_custom_gap_save (source_reference_type 'TprmFinding').
--   Risk Centre   escalation creates a risk CANDIDATE through
--                 sp_risk_candidate_create (new source 'ThirdParty'); its
--                 own idempotency stops duplicates; or an existing
--                 enterprise risk is linked.
--
-- ERROR NUMBERS: 57700-57899.
-- DEPENDS ON: 486, 487, 488; 476 / 477 (Evidence Center); 204-207 / 378
--   (Risk Centre); 324 (sp_custom_gap_save).
-- Rollback: 489_tprm_due_diligence_decision_monitoring_rollback.sql
-- SAFE TO RE-RUN. ASCII-only. SQL Server 2017+.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.tprm_risk_assessment','U') IS NULL
BEGIN PRINT 'ABORT (489): run 488 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.evidence_item','U') IS NULL OR OBJECT_ID('grac_practice.fn_pm_evidence_item_visible') IS NULL
BEGIN PRINT 'ABORT (489): the Evidence Center (476 / 477) is required -- TPRM reuses it for evidence.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_source_master','U') IS NULL OR OBJECT_ID('grac_practice.sp_risk_candidate_create','P') IS NULL
BEGIN PRINT 'ABORT (489): Risk Centre procedures missing (204-207, 378).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_custom_gap_save','P') IS NULL
BEGIN PRINT 'ABORT (489): sp_custom_gap_save missing (112 / 324).'; SET @ok = 0; END
-- 521 (Third-Party Management Phase 1) re-issued sp_tprm_monitoring_sweep
-- without the legacy vendor and dropped tprm_third_party.vendor_id.
-- Running 489 again would restore the old body, so it stops.
IF OBJECT_ID('grac_practice.tprm_third_party','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.tprm_third_party','vendor_id') IS NULL
BEGIN PRINT 'ABORT (489): superseded by 521_tpm_vendor_registry_foundation.sql -- do not re-run 489 after 521.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('489_tprm_due_diligence_decision_monitoring: prerequisites missing -- see the messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Due diligence
-- =====================================================================
IF OBJECT_ID('grac_practice.tprm_dd_assessment','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_dd_assessment(
        dd_id                  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_dd_assessment PRIMARY KEY,
        engagement_id          BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_dd_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        organization_id        BIGINT         NOT NULL,
        risk_assessment_id     BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_dd_ra REFERENCES grac_practice.tprm_risk_assessment(assessment_id),
        dd_no                  INT            NOT NULL,
        dd_tier_code           NVARCHAR(60)   NOT NULL,
        status                 NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_dd_status DEFAULT N'IN_PROGRESS'
            CONSTRAINT ck_pm_tprm_dd_status CHECK (status IN (N'IN_PROGRESS', N'COMPLETED', N'SUPERSEDED', N'CANCELLED')),
        due_dt                 DATE           NULL,
        assessor_employee_id   BIGINT         NULL
            CONSTRAINT fk_pm_tprm_dd_assessor REFERENCES grac_practice.organization_employee(employee_id),
        reviewer_employee_id   BIGINT         NULL
            CONSTRAINT fk_pm_tprm_dd_reviewer REFERENCES grac_practice.organization_employee(employee_id),
        copied_from_dd_id      BIGINT         NULL,
        summary                NVARCHAR(2000) NULL,
        started_by             NVARCHAR(100)  NOT NULL,
        started_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_dd_started DEFAULT SYSUTCDATETIME(),
        completed_by           NVARCHAR(100)  NULL,
        completed_dt           DATETIME2      NULL,
        CONSTRAINT uq_pm_tprm_dd_no UNIQUE (engagement_id, dd_no)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_dd_open ON grac_practice.tprm_dd_assessment(engagement_id) WHERE status = N'IN_PROGRESS';
END
GO

IF OBJECT_ID('grac_practice.tprm_dd_questionnaire','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_dd_questionnaire(
        ddq_id               BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_dd_questionnaire PRIMARY KEY,
        dd_id                BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_ddq_dd REFERENCES grac_practice.tprm_dd_assessment(dd_id),
        organization_id      BIGINT         NOT NULL,
        template_id          BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_ddq_t REFERENCES grac_practice.tprm_template(template_id),
        template_version_id  BIGINT         NOT NULL       -- pinned (BRD 11)
            CONSTRAINT fk_pm_tprm_ddq_v REFERENCES grac_practice.tprm_template_version(version_id),
        template_code        NVARCHAR(60)   NOT NULL,
        template_name        NVARCHAR(250)  NOT NULL,
        respondent_contact_id BIGINT        NULL,
        respondent_name      NVARCHAR(200)  NULL,
        sent_dt              DATETIME2      NULL,
        responded_dt         DATETIME2      NULL,
        display_order        INT            NOT NULL CONSTRAINT df_pm_tprm_ddq_order DEFAULT 100
    );
END
GO

IF OBJECT_ID('grac_practice.tprm_dd_response','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_dd_response(
        response_id          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_dd_response PRIMARY KEY,
        ddq_id               BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_ddr_ddq REFERENCES grac_practice.tprm_dd_questionnaire(ddq_id),
        dd_id                BIGINT         NOT NULL,
        organization_id      BIGINT         NOT NULL,
        question_id          BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_ddr_q REFERENCES grac_practice.tprm_q_question(question_id),
        question_code        NVARCHAR(60)   NOT NULL,
        base_applicable      BIT            NOT NULL,    -- tier / category / data / access conditions
        is_applicable        BIT            NOT NULL,    -- base and, for a follow-up, the parent answer
        respondent_type      NVARCHAR(20)   NULL
            CONSTRAINT ck_pm_tprm_ddr_resp CHECK (respondent_type IS NULL OR respondent_type IN (N'THIRD_PARTY', N'INTERNAL')),
        answer_option_codes  NVARCHAR(400)  NULL,
        answer_text          NVARCHAR(MAX)  NULL,
        answer_number        DECIMAL(19,4)  NULL,
        answer_date          DATE           NULL,
        answered_by          NVARCHAR(100)  NULL,
        answered_dt          DATETIME2      NULL,
        rating_code          NVARCHAR(60)   NULL,        -- RESPONSE_RATING
        assessor_comment     NVARCHAR(2000) NULL,
        reviewer_comment     NVARCHAR(2000) NULL,
        rated_by_employee_id BIGINT         NULL,
        rated_dt             DATETIME2      NULL,
        status               NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_ddr_status DEFAULT N'PENDING'
            CONSTRAINT ck_pm_tprm_ddr_status CHECK (status IN (N'PENDING', N'ANSWERED', N'RATED')),
        CONSTRAINT uq_pm_tprm_ddr UNIQUE (ddq_id, question_id)
    );
    CREATE INDEX ix_pm_tprm_ddr_dd ON grac_practice.tprm_dd_response(dd_id);
END
GO

IF OBJECT_ID('grac_practice.tprm_safeguard_assessment','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_safeguard_assessment(
        sg_assessment_id          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_safeguard_assessment PRIMARY KEY,
        dd_id                     BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_sga_dd REFERENCES grac_practice.tprm_dd_assessment(dd_id),
        engagement_id             BIGINT         NOT NULL,
        organization_id           BIGINT         NOT NULL,
        safeguard_code            NVARCHAR(60)   NOT NULL,
        safeguard_name            NVARCHAR(250)  NOT NULL,     -- as in force when generated
        category_code             NVARCHAR(60)   NULL,
        dimension_code            NVARCHAR(60)   NULL,
        is_contract_clause        BIT            NOT NULL CONSTRAINT df_pm_tprm_sga_clause DEFAULT 0,
        evidence_requirement_code NVARCHAR(60)   NULL,
        effectiveness_criteria    NVARCHAR(2000) NULL,
        is_applicable             BIT            NOT NULL CONSTRAINT df_pm_tprm_sga_app DEFAULT 1,
        existence_code            NVARCHAR(20)   NULL
            CONSTRAINT ck_pm_tprm_sga_exist CHECK (existence_code IS NULL OR existence_code IN (N'EXISTS', N'PARTIAL', N'MISSING', N'UNKNOWN')),
        contract_clause_ref       NVARCHAR(300)  NULL,
        effectiveness_code        NVARCHAR(60)   NULL,         -- EFFECTIVENESS value
        verification_method       NVARCHAR(30)   NULL
            CONSTRAINT ck_pm_tprm_sga_method CHECK (verification_method IS NULL OR verification_method IN
                (N'EVIDENCE_REVIEW', N'ASSURANCE_RESULT', N'TESTING', N'CONTRACT_REVIEW', N'ATTESTATION_ONLY')),
        -- Only a VERIFIED effective / partially effective safeguard reduces
        -- residual risk (BRD step 3: not assumed from a document's existence).
        is_verified               BIT            NOT NULL CONSTRAINT df_pm_tprm_sga_verified DEFAULT 0,
        verified_by_employee_id   BIGINT         NULL,
        verified_dt               DATETIME2      NULL,
        verification_note         NVARCHAR(2000) NULL,
        comment                   NVARCHAR(2000) NULL,
        assessed_by               NVARCHAR(100)  NULL,
        assessed_dt               DATETIME2      NULL,
        CONSTRAINT uq_pm_tprm_sga UNIQUE (dd_id, safeguard_code)
    );
END
GO

IF OBJECT_ID('grac_practice.tprm_evidence_link','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_evidence_link(
        tprm_evidence_id          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_evidence_link PRIMARY KEY,
        organization_id           BIGINT         NOT NULL,
        engagement_id             BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_ev_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        dd_id                     BIGINT         NULL,
        target_kind               NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_tprm_ev_kind CHECK (target_kind IN (N'RESPONSE', N'SAFEGUARD', N'FINDING', N'ENGAGEMENT', N'REVIEW', N'ONBOARDING')),
        target_id                 BIGINT         NOT NULL,
        evidence_requirement_code NVARCHAR(60)   NULL,
        source_kind               NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_tprm_ev_source CHECK (source_kind IN (N'EVIDENCE_CENTER', N'EXTERNAL')),
        evidence_item_id          BIGINT         NULL
            CONSTRAINT fk_pm_tprm_ev_item REFERENCES grac_practice.evidence_item(evidence_item_id),
        evidence_file_id          BIGINT         NULL,      -- pinned version (Evidence Center rule)
        external_reference        NVARCHAR(400)  NULL,
        external_location         NVARCHAR(1000) NULL,
        title                     NVARCHAR(300)  NOT NULL,
        valid_from                DATE           NULL,
        valid_to                  DATE           NULL,
        note                      NVARCHAR(1000) NULL,
        review_status             NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_ev_review DEFAULT N'PENDING'
            CONSTRAINT ck_pm_tprm_ev_review CHECK (review_status IN (N'PENDING', N'ACCEPTED', N'REJECTED')),
        reviewed_by_employee_id   BIGINT         NULL,
        reviewed_dt               DATETIME2      NULL,
        review_note               NVARCHAR(1000) NULL,
        added_by_employee_id      BIGINT         NULL,
        status                    NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_ev_status DEFAULT N'Active'
            CONSTRAINT ck_pm_tprm_ev_status CHECK (status IN (N'Active', N'Removed')),
        entered_by                NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_ev_eby DEFAULT N'system',
        entered_dt                DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_ev_edt DEFAULT SYSUTCDATETIME(),
        updated_by                NVARCHAR(100)  NULL,
        updated_dt                DATETIME2      NULL,
        CONSTRAINT ck_pm_tprm_ev_ref CHECK ((source_kind = N'EVIDENCE_CENTER' AND evidence_item_id IS NOT NULL)
                                         OR (source_kind = N'EXTERNAL' AND external_reference IS NOT NULL))
    );
    CREATE INDEX ix_pm_tprm_ev_eng ON grac_practice.tprm_evidence_link(engagement_id, target_kind, target_id);
END
GO

IF OBJECT_ID('grac_practice.tprm_finding','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_finding(
        finding_id                 BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_finding PRIMARY KEY,
        organization_id            BIGINT         NOT NULL,
        engagement_id              BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_f_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        dd_id                      BIGINT         NULL,
        finding_number             NVARCHAR(20)   NOT NULL,      -- TPF-001 per organization
        finding_kind               NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_tprm_f_kind CHECK (finding_kind IN (N'DEFICIENCY', N'CONDITION', N'EXCEPTION')),
        source_kind                NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_tprm_f_source CHECK (source_kind IN (N'QUESTION', N'SAFEGUARD', N'DECISION', N'DEVIATION', N'REVIEW', N'MANUAL')),
        source_id                  BIGINT         NULL,
        is_automatic               BIT            NOT NULL CONSTRAINT df_pm_tprm_f_auto DEFAULT 0,
        title                      NVARCHAR(300)  NOT NULL,
        description                NVARCHAR(2000) NULL,
        severity_code              NVARCHAR(60)   NOT NULL,     -- FINDING_SEVERITY
        dimension_code             NVARCHAR(60)   NULL,
        treatment_action_code      NVARCHAR(60)   NULL,
        owner_employee_id          BIGINT         NULL
            CONSTRAINT fk_pm_tprm_f_owner REFERENCES grac_practice.organization_employee(employee_id),
        due_dt                     DATE           NULL,
        is_mandatory_for_activation BIT           NOT NULL CONSTRAINT df_pm_tprm_f_mand DEFAULT 0,
        exception_until            DATE           NULL,
        status                     NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_f_status DEFAULT N'OPEN'
            CONSTRAINT ck_pm_tprm_f_status CHECK (status IN (N'OPEN', N'IN_PROGRESS', N'CLOSED', N'WAIVED', N'CANCELLED')),
        status_note                NVARCHAR(2000) NULL,
        closed_by_employee_id      BIGINT         NULL,
        closed_dt                  DATETIME2      NULL,
        custom_gap_id              BIGINT         NULL,
        record_version             ROWVERSION     NOT NULL,
        entered_by                 NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_f_eby DEFAULT N'system',
        entered_dt                 DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_f_edt DEFAULT SYSUTCDATETIME(),
        updated_by                 NVARCHAR(100)  NULL,
        updated_dt                 DATETIME2      NULL,
        CONSTRAINT uq_pm_tprm_f_number UNIQUE (organization_id, finding_number)
    );
    CREATE INDEX ix_pm_tprm_f_eng ON grac_practice.tprm_finding(engagement_id, status);
END
GO

-- =====================================================================
-- 2. Decisions and approvals
-- =====================================================================
IF OBJECT_ID('grac_practice.tprm_decision','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_decision(
        decision_id               BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_decision PRIMARY KEY,
        organization_id           BIGINT         NOT NULL,
        engagement_id             BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_d_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        risk_assessment_id        BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_d_ra REFERENCES grac_practice.tprm_risk_assessment(assessment_id),
        dd_id                     BIGINT         NULL,
        decision_no               INT            NOT NULL,
        prior_stage_code          NVARCHAR(30)   NOT NULL,      -- stage to return to (ACTIVE re-approvals)
        status                    NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_d_status DEFAULT N'PENDING'
            CONSTRAINT ck_pm_tprm_d_status CHECK (status IN (N'PENDING', N'DECIDED', N'WITHDRAWN')),
        approval_rule_code        NVARCHAR(60)   NULL,
        rule_snapshot_json        NVARCHAR(MAX)  NULL,          -- the rule as matched (history survives rule changes)
        required_levels           INT            NOT NULL,
        sod_required              BIT            NOT NULL,
        escalation_recommended    BIT            NOT NULL CONSTRAINT df_pm_tprm_d_esc DEFAULT 0,
        inherent_score            DECIMAL(6,2)   NULL,
        inherent_band_code        NVARCHAR(60)   NULL,
        residual_score            DECIMAL(6,2)   NULL,
        residual_band_code        NVARCHAR(60)   NULL,
        open_findings_count       INT            NULL,
        submission_note           NVARCHAR(2000) NULL,
        submitted_by_employee_id  BIGINT         NULL,
        submitted_dt              DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_d_sub DEFAULT SYSUTCDATETIME(),
        outcome_code              NVARCHAR(60)   NULL,          -- DECISION value
        outcome_meaning           NVARCHAR(40)   NULL,
        rationale                 NVARCHAR(2000) NULL,
        risk_accepted             BIT            NOT NULL CONSTRAINT df_pm_tprm_d_acc DEFAULT 0,
        acceptance_until          DATE           NULL,
        mandatory_review_dt       DATE           NULL,
        decided_by_employee_id    BIGINT         NULL,
        decided_dt                DATETIME2      NULL,
        CONSTRAINT uq_pm_tprm_d_no UNIQUE (engagement_id, decision_no)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_d_pending ON grac_practice.tprm_decision(engagement_id) WHERE status = N'PENDING';
END
GO

IF OBJECT_ID('grac_practice.tprm_decision_approval','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_decision_approval(
        approval_id             BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_decision_approval PRIMARY KEY,
        decision_id             BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_da_d REFERENCES grac_practice.tprm_decision(decision_id),
        level_no                INT            NOT NULL,
        required_role_name      NVARCHAR(120)  NULL,
        status                  NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_da_status DEFAULT N'PENDING'
            CONSTRAINT ck_pm_tprm_da_status CHECK (status IN (N'PENDING', N'APPROVED', N'REJECTED', N'RETURNED', N'WITHDRAWN')),
        approver_employee_id    BIGINT         NULL,
        on_behalf_of_employee_id BIGINT        NULL,          -- delegation
        comment                 NVARCHAR(2000) NULL,
        decided_dt              DATETIME2      NULL,
        CONSTRAINT uq_pm_tprm_da UNIQUE (decision_id, level_no)
    );
END
GO

-- =====================================================================
-- 3. Onboarding, exit, deviations, reviews
-- =====================================================================
IF OBJECT_ID('grac_practice.tprm_onboarding_item','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_onboarding_item(
        item_id              BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_onboarding_item PRIMARY KEY,
        engagement_id        BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_oi_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        organization_id      BIGINT         NOT NULL,
        phase                NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_tprm_oi_phase CHECK (phase IN (N'ONBOARDING', N'EXIT')),
        check_code           NVARCHAR(60)   NOT NULL,
        check_label          NVARCHAR(300)  NOT NULL,
        is_mandatory         BIT            NOT NULL,
        status               NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_oi_status DEFAULT N'PENDING'
            CONSTRAINT ck_pm_tprm_oi_status CHECK (status IN (N'PENDING', N'DONE', N'WAIVED', N'NOT_APPLICABLE')),
        note                 NVARCHAR(1000) NULL,
        evidence_reference   NVARCHAR(400)  NULL,
        completed_by_employee_id BIGINT     NULL,
        completed_dt         DATETIME2      NULL,
        entered_by           NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tprm_oi_eby DEFAULT N'system',
        entered_dt           DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_oi_edt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_tprm_oi UNIQUE (engagement_id, phase, check_code)
    );
END
GO

IF OBJECT_ID('grac_practice.tprm_engagement_deviation','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_engagement_deviation(
        deviation_id     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_engagement_deviation PRIMARY KEY,
        engagement_id    BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_dev_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        organization_id  BIGINT         NOT NULL,
        snapshot_id      BIGINT         NULL,
        deviation_kind   NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_tprm_dev_kind CHECK (deviation_kind IN (N'ADDED', N'REMOVED')),
        item_kind        NVARCHAR(30)   NOT NULL,
        item_key         NVARCHAR(200)  NOT NULL,
        item_name        NVARCHAR(300)  NOT NULL,
        is_material      BIT            NOT NULL,
        status           NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_dev_status DEFAULT N'OPEN'
            CONSTRAINT ck_pm_tprm_dev_status CHECK (status IN (N'OPEN', N'ACCEPTED', N'REASSESS', N'SUPERSEDED')),
        decision_note    NVARCHAR(1000) NULL,
        decided_by_employee_id BIGINT   NULL,
        decided_dt       DATETIME2      NULL,
        entered_dt       DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_dev_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_tprm_dev_eng ON grac_practice.tprm_engagement_deviation(engagement_id, status);
END
GO

IF OBJECT_ID('grac_practice.tprm_review','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_review(
        review_id            BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_review PRIMARY KEY,
        organization_id      BIGINT         NOT NULL,
        engagement_id        BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rev_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        review_number        NVARCHAR(20)   NOT NULL,      -- TPR-001 per organization
        review_type          NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_tprm_rev_type CHECK (review_type IN (N'PERIODIC', N'TRIGGERED', N'CONTRACT_EXPIRY', N'CERTIFICATION_EXPIRY', N'ACCEPTANCE_EXPIRY')),
        trigger_code         NVARCHAR(60)   NOT NULL,      -- REVIEW_TRIGGER value
        trigger_detail       NVARCHAR(2000) NULL,
        source_key           NVARCHAR(200)  NULL,          -- de-duplication of scheduler-raised reviews
        due_dt               DATE           NOT NULL,
        owner_employee_id    BIGINT         NULL
            CONSTRAINT fk_pm_tprm_rev_owner REFERENCES grac_practice.organization_employee(employee_id),
        requires_reassessment BIT           NOT NULL CONSTRAINT df_pm_tprm_rev_reassess DEFAULT 0,
        status               NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_rev_status DEFAULT N'OPEN'
            CONSTRAINT ck_pm_tprm_rev_status CHECK (status IN (N'OPEN', N'COMPLETED', N'CANCELLED')),
        outcome_code         NVARCHAR(20)   NULL
            CONSTRAINT ck_pm_tprm_rev_outcome CHECK (outcome_code IS NULL OR outcome_code IN (N'NO_CHANGE', N'REASSESS', N'REMEDIATE', N'SUSPEND', N'EXIT')),
        outcome_note         NVARCHAR(2000) NULL,
        completed_by_employee_id BIGINT     NULL,
        completed_dt         DATETIME2      NULL,
        raised_by            NVARCHAR(100)  NOT NULL,
        raised_dt            DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_rev_raised DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_tprm_rev_number UNIQUE (organization_id, review_number)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_rev_source ON grac_practice.tprm_review(organization_id, source_key) WHERE source_key IS NOT NULL;
    CREATE INDEX ix_pm_tprm_rev_eng ON grac_practice.tprm_review(engagement_id, status);
END
GO
PRINT '489: tables ready.';
GO

-- Risk Centre source for escalated engagement risks (BRD 7). Extending
-- risk_source_master is how 205 says a new Centre joins: no schema change.
MERGE grac_practice.risk_source_master AS t
USING (VALUES (N'ThirdParty', N'Third-party engagement', N'Risk escalated from a third-party engagement (TPRM)', N'TPRM', 75))
      AS s(source_type_code, source_name, description, source_centre_code, display_order)
ON t.source_type_code = s.source_type_code
WHEN MATCHED THEN UPDATE SET source_name = s.source_name, description = s.description,
     source_centre_code = s.source_centre_code, display_order = s.display_order, is_system = 1, status = N'Active',
     updated_by = N'seed-489', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (source_type_code, source_name, description, source_centre_code, is_system, display_order, status, entered_by)
     VALUES (s.source_type_code, s.source_name, s.description, s.source_centre_code, 1, s.display_order, N'Active', N'seed-489');
GO

-- =====================================================================
-- 4. Functions
-- =====================================================================
-- The approval rule for a residual band rank and a criticality rank:
-- lowest priority among the rules whose threshold is met (a rule with
-- both thresholds empty is the catch-all).
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_match_approval_rule (@organization_id BIGINT, @band_rank INT, @criticality_rank INT)
RETURNS TABLE
AS
RETURN
(
SELECT TOP (1) r.*
FROM   grac_practice.fn_tprm_approval_rule_effective(@organization_id) r
WHERE  (r.min_band_rank IS NULL AND r.min_criticality_rank IS NULL)
    OR (r.min_band_rank IS NOT NULL AND ISNULL(@band_rank, 0) >= r.min_band_rank)
    OR (r.min_criticality_rank IS NOT NULL AND ISNULL(@criticality_rank, 0) >= r.min_criticality_rank)
ORDER  BY r.priority, r.rule_code
);
GO

CREATE OR ALTER FUNCTION grac_practice.fn_tprm_match_review_rule (@organization_id BIGINT, @band_rank INT, @criticality_rank INT)
RETURNS TABLE
AS
RETURN
(
SELECT TOP (1) r.*
FROM   grac_practice.fn_tprm_review_rule_effective(@organization_id) r
WHERE  (r.min_band_rank IS NULL AND r.min_criticality_rank IS NULL)
    OR (r.min_band_rank IS NOT NULL AND ISNULL(@band_rank, 0) >= r.min_band_rank)
    OR (r.min_criticality_rank IS NOT NULL AND ISNULL(@criticality_rank, 0) >= r.min_criticality_rank)
ORDER  BY r.priority, r.rule_code
);
GO

-- The ranks an engagement is judged by: residual band (inherent while
-- there is no residual) in its pinned model, and service criticality.
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_engagement_ranks (@engagement_id BIGINT)
RETURNS TABLE
AS
RETURN
(
SELECT e.engagement_id, e.organization_id,
       (SELECT TOP (1) b.rank_no FROM grac_practice.tprm_rm_band b
         WHERE b.version_id = e.risk_model_version_id AND b.band_code = COALESCE(e.residual_band_code, e.inherent_band_code)) AS band_rank,
       (SELECT TOP (1) r.rank_no FROM grac_practice.fn_tprm_reference_effective(e.organization_id) r
         WHERE r.list_code = N'CRITICALITY' AND r.value_code = e.service_criticality_code) AS criticality_rank
FROM grac_practice.tprm_engagement e
WHERE e.engagement_id = @engagement_id
);
GO

-- The due-diligence round that is current for an engagement.
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_current_dd (@engagement_id BIGINT)
RETURNS TABLE
AS
RETURN
(
SELECT TOP (1) d.dd_id, d.status, d.risk_assessment_id, d.dd_tier_code
FROM grac_practice.tprm_dd_assessment d
WHERE d.engagement_id = @engagement_id AND d.status IN (N'IN_PROGRESS', N'COMPLETED')
ORDER BY d.dd_no DESC
);
GO

-- =====================================================================
-- 5. Helpers
-- =====================================================================
-- Next per-organization number with a prefix (TPF-, TPR-).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_next_number
    @organization_id BIGINT,
    @prefix          NVARCHAR(10),
    @number          NVARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @next INT, @len INT = LEN(@prefix) + 1;
    IF @prefix = N'TPF-'
        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(finding_number, @len, 20))), 0) + 1
        FROM grac_practice.tprm_finding WITH (UPDLOCK, HOLDLOCK)
        WHERE organization_id = @organization_id AND finding_number LIKE N'TPF-%';
    ELSE
        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(review_number, @len, 20))), 0) + 1
        FROM grac_practice.tprm_review WITH (UPDLOCK, HOLDLOCK)
        WHERE organization_id = @organization_id AND review_number LIKE N'TPR-%';
    SET @number = @prefix + FORMAT(@next, '000');
END
GO

-- Internal: raise a review (used by the screen, lifecycle actions and
-- the scheduler). @source_key de-duplicates scheduler reviews; a review
-- whose trigger is one of the review rule's reassessment triggers flags
-- the engagement for reassessment. Returns the id through @review_id
-- (NULL when the source key already exists).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_review_create
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @review_type       NVARCHAR(30),
    @trigger_code      NVARCHAR(60),
    @trigger_detail    NVARCHAR(2000) = NULL,
    @due_dt            DATE,
    @owner_employee_id BIGINT         = NULL,
    @source_key        NVARCHAR(200)  = NULL,
    @actor             NVARCHAR(100)  = N'system',
    @review_id         BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @review_id = NULL;
    IF @source_key IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.tprm_review WHERE organization_id = @organization_id AND source_key = @source_key)
        RETURN;
    DECLARE @band_rank INT, @crit_rank INT, @triggers NVARCHAR(600), @owner BIGINT = @owner_employee_id;
    SELECT @band_rank = band_rank, @crit_rank = criticality_rank FROM grac_practice.fn_tprm_engagement_ranks(@engagement_id);
    SELECT @triggers = reassessment_trigger_codes FROM grac_practice.fn_tprm_match_review_rule(@organization_id, @band_rank, @crit_rank);
    IF @owner IS NULL
        SELECT @owner = COALESCE(relationship_owner_employee_id, business_owner_employee_id) FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id;
    DECLARE @reassess BIT = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(@triggers) x WHERE x.code = @trigger_code) THEN 1 ELSE 0 END;

    DECLARE @number NVARCHAR(20);
    EXEC grac_practice.sp_tprm_next_number @organization_id, N'TPR-', @number OUTPUT;
    INSERT grac_practice.tprm_review
        (organization_id, engagement_id, review_number, review_type, trigger_code, trigger_detail, source_key, due_dt,
         owner_employee_id, requires_reassessment, status, raised_by)
    VALUES (@organization_id, @engagement_id, @number, @review_type, @trigger_code, @trigger_detail, @source_key, @due_dt,
            @owner, @reassess, N'OPEN', ISNULL(@actor, N'system'));
    SET @review_id = SCOPE_IDENTITY();
    IF @reassess = 1
        UPDATE grac_practice.tprm_engagement
           SET reassessment_required = 1,
               reassessment_reason = LEFT(COALESCE(reassessment_reason, CONCAT(N'Review ', @number, N': ', @trigger_code)), 1000)
         WHERE engagement_id = @engagement_id;
    DECLARE @detail NVARCHAR(2000) = CONCAT(@number, N' (', @review_type, N' / ', @trigger_code, N') due ', CONVERT(NVARCHAR(10), @due_dt, 23));
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'REVIEW_RAISED', NULL, NULL, @detail, NULL, @actor;
END
GO

-- =====================================================================
-- 6. Residual risk (BRD step 3)
--   For each dimension of the current inherent assessment:
--     reduction = average over the APPLICABLE safeguards of that
--                 dimension in the current due-diligence round of
--                   effective_reduction_pct  (verified, meaning EFFECTIVE)
--                   partial_reduction_pct    (verified, PARTIALLY_EFFECTIVE)
--                   0                        (anything else, incl. unverified)
--     uplift    = deficiency_uplift_pct x open High / Critical
--                 deficiencies and exceptions of that dimension
--     residual  = inherent x (1 - max(0, reduction - uplift) / 100),
--                 never below inherent x residual_floor_pct / 100
--   Overall and band as for inherent. No round yet = no residual.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_residual_calculate
    @organization_id BIGINT,
    @engagement_id   BIGINT,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @assessment BIGINT, @version BIGINT, @dd BIGINT;
    SELECT @assessment = current_risk_assessment_id, @version = risk_model_version_id
    FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @assessment IS NULL RETURN;
    SELECT @dd = dd_id FROM grac_practice.fn_tprm_current_dd(@engagement_id);
    IF @dd IS NULL
    BEGIN
        UPDATE grac_practice.tprm_risk_assessment_dimension SET reduction_pct = NULL, uplift_pct = NULL, residual_score = NULL, safeguard_summary = NULL
         WHERE assessment_id = @assessment;
        UPDATE grac_practice.tprm_risk_assessment SET residual_score = NULL, residual_band_code = NULL, residual_dt = NULL, residual_note = NULL
         WHERE assessment_id = @assessment;
        UPDATE grac_practice.tprm_engagement SET residual_score = NULL, residual_band_code = NULL WHERE engagement_id = @engagement_id;
        RETURN;
    END

    DECLARE @method NVARCHAR(30), @blend DECIMAL(5,2), @eff DECIMAL(5,2), @part DECIMAL(5,2), @floor DECIMAL(5,2), @uplift DECIMAL(5,2);
    SELECT @method = ISNULL(aggregation_method, N'WEIGHTED_AVERAGE'), @blend = ISNULL(blend_pct, 50),
           @eff = ISNULL(effective_reduction_pct, 60), @part = ISNULL(partial_reduction_pct, 30),
           @floor = ISNULL(residual_floor_pct, 20), @uplift = ISNULL(deficiency_uplift_pct, 10)
    FROM grac_practice.tprm_template_version WHERE version_id = @version;

    ;WITH eff AS (
        SELECT s.dimension_code,
               AVG(CASE WHEN s.is_verified = 1 AND m.meaning_code = N'EFFECTIVE' THEN @eff
                        WHEN s.is_verified = 1 AND m.meaning_code = N'PARTIALLY_EFFECTIVE' THEN @part
                        ELSE CAST(0 AS DECIMAL(5,2)) END) AS reduction,
               COUNT(*) AS applicable_count,
               SUM(CASE WHEN s.is_verified = 1 AND m.meaning_code IN (N'EFFECTIVE', N'PARTIALLY_EFFECTIVE') THEN 1 ELSE 0 END) AS verified_count
        FROM grac_practice.tprm_safeguard_assessment s
        LEFT JOIN grac_practice.fn_tprm_reference_effective(@organization_id) m
               ON m.list_code = N'EFFECTIVENESS' AND m.value_code = s.effectiveness_code
        WHERE s.dd_id = @dd AND s.is_applicable = 1 AND s.dimension_code IS NOT NULL
        GROUP BY s.dimension_code
    ),
    def AS (
        SELECT f.dimension_code, COUNT(*) AS open_count
        FROM grac_practice.tprm_finding f
        JOIN grac_practice.fn_tprm_reference_effective(@organization_id) sv
             ON sv.list_code = N'FINDING_SEVERITY' AND sv.value_code = f.severity_code
        WHERE f.engagement_id = @engagement_id AND f.finding_kind IN (N'DEFICIENCY', N'EXCEPTION')
          AND f.status IN (N'OPEN', N'IN_PROGRESS') AND ISNULL(sv.rank_no, 0) >= 3 AND f.dimension_code IS NOT NULL
        GROUP BY f.dimension_code
    )
    UPDATE d
       SET reduction_pct = CAST(ISNULL(e.reduction, 0) AS DECIMAL(6,2)),
           uplift_pct = CAST(ISNULL(df.open_count, 0) * @uplift AS DECIMAL(6,2)),
           residual_score = CASE WHEN d.inherent_score IS NULL THEN NULL ELSE
               CAST(CASE WHEN d.inherent_score * (1 - (CASE WHEN ISNULL(e.reduction, 0) - ISNULL(df.open_count, 0) * @uplift > 0
                                                            THEN ISNULL(e.reduction, 0) - ISNULL(df.open_count, 0) * @uplift ELSE 0 END) / 100.0)
                              < d.inherent_score * @floor / 100.0
                         THEN d.inherent_score * @floor / 100.0
                         ELSE d.inherent_score * (1 - (CASE WHEN ISNULL(e.reduction, 0) - ISNULL(df.open_count, 0) * @uplift > 0
                                                            THEN ISNULL(e.reduction, 0) - ISNULL(df.open_count, 0) * @uplift ELSE 0 END) / 100.0) END
                    AS DECIMAL(6,2)) END,
           safeguard_summary = CONCAT(ISNULL(e.verified_count, 0), N' of ', ISNULL(e.applicable_count, 0), N' safeguards verified effective',
                                      CASE WHEN ISNULL(df.open_count, 0) > 0 THEN CONCAT(N'; ', df.open_count, N' open high deficiencies') ELSE N'' END)
    FROM grac_practice.tprm_risk_assessment_dimension d
    LEFT JOIN eff e ON e.dimension_code = d.dimension_code
    LEFT JOIN def df ON df.dimension_code = d.dimension_code
    WHERE d.assessment_id = @assessment;

    DECLARE @wa DECIMAL(9,4), @hd DECIMAL(9,4), @score DECIMAL(6,2), @band NVARCHAR(60);
    SELECT @wa = SUM(weight * residual_score) / NULLIF(SUM(weight), 0), @hd = MAX(residual_score)
    FROM grac_practice.tprm_risk_assessment_dimension
    WHERE assessment_id = @assessment AND residual_score IS NOT NULL AND weight > 0;
    SET @score = CAST(CASE @method WHEN N'HIGHEST_DIMENSION' THEN @hd
                                   WHEN N'BLENDED' THEN (@blend / 100.0) * @hd + (1 - @blend / 100.0) * @wa
                                   ELSE @wa END AS DECIMAL(6,2));
    SELECT TOP (1) @band = band_code FROM grac_practice.tprm_rm_band
     WHERE version_id = @version AND min_score <= ISNULL(@score, 0) ORDER BY min_score DESC;

    DECLARE @note NVARCHAR(1000) = (SELECT CONCAT(SUM(CASE WHEN is_verified = 1 THEN 1 ELSE 0 END), N' of ', COUNT(*),
                                                  N' applicable safeguards verified')
                                    FROM grac_practice.tprm_safeguard_assessment WHERE dd_id = @dd AND is_applicable = 1);
    UPDATE grac_practice.tprm_risk_assessment
       SET residual_score = @score, residual_band_code = CASE WHEN @score IS NULL THEN NULL ELSE @band END,
           residual_dt = SYSUTCDATETIME(), residual_note = @note
     WHERE assessment_id = @assessment;
    UPDATE grac_practice.tprm_engagement
       SET residual_score = @score, residual_band_code = CASE WHEN @score IS NULL THEN NULL ELSE @band END
     WHERE engagement_id = @engagement_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_residual_recalculate
    @organization_id BIGINT,
    @engagement_id   BIGINT,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id)
        THROW 57700, 'That engagement was not found.', 1;
    EXEC grac_practice.sp_tprm_residual_calculate @organization_id, @engagement_id, @actor;
    SELECT engagement_id AS EngagementId, residual_score AS ResidualScore, residual_band_code AS ResidualBandCode, N'RECALCULATED' AS Result
    FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id;
END
GO

-- =====================================================================
-- 7. Due diligence -- start, read, respond, rate, safeguards, complete
-- =====================================================================
-- Generates the round for the CURRENT inherent assessment:
--   questionnaires  every effective QUESTIONNAIRE template that is core,
--                   or whose version applies to the engagement's service
--                   category, DD tier rank and engagement type
--   responses       every question of those versions; applicability from
--                   the question's tier / category / data / access
--                   conditions; follow-ups start hidden until their
--                   parent's answer triggers them
--   safeguards      the effective safeguard library; applicable when a
--                   generated question references it, when it is a
--                   contractual safeguard, or when its dimension scored
--                   50 or more
--   @copy_previous  answers, ratings and safeguard results of the last
--                   round are carried forward (same question codes) --
--                   reassessment without re-keying (BRD step 3)
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_dd_start
    @organization_id      BIGINT,
    @engagement_id        BIGINT,
    @due_dt               DATE          = NULL,
    @assessor_employee_id BIGINT        = NULL,
    @reviewer_employee_id BIGINT        = NULL,
    @copy_previous        BIT           = 1,
    @actor_employee_id    BIGINT        = NULL,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30), @assessment BIGINT, @tier NVARCHAR(60), @category NVARCHAR(60), @etype NVARCHAR(60);
    SELECT @stage = stage_code, @assessment = current_risk_assessment_id, @tier = dd_tier_code,
           @category = service_category_code, @etype = engagement_type_code
    FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @stage IS NULL THROW 57700, 'That engagement was not found.', 1;
    IF @assessment IS NULL THROW 57701, 'Complete the inherent risk assessment first.', 1;
    IF @stage NOT IN (N'RISK_ASSESSED', N'DUE_DILIGENCE', N'ACTIVE', N'SUSPENDED', N'APPROVED', N'ONBOARDING')
        THROW 57702, 'Due diligence cannot start at this stage.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_dd_assessment WHERE engagement_id = @engagement_id AND status = N'IN_PROGRESS')
        THROW 57703, 'A due-diligence round is already in progress.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_risk_assessment WHERE engagement_id = @engagement_id AND status = N'DRAFT')
        THROW 57704, 'Complete or discard the risk assessment in progress first.', 1;
    IF EXISTS (SELECT 1 FROM (VALUES (@assessor_employee_id), (@reviewer_employee_id)) x(id)
                WHERE x.id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                        WHERE employee_id = x.id AND organization_id = @organization_id AND status = N'Active'))
        THROW 57705, 'Assessor and reviewer must be active employees of this organization.', 1;
    IF @assessor_employee_id IS NOT NULL AND @assessor_employee_id = @reviewer_employee_id
        THROW 57706, 'The evidence reviewer must be a different person from the assessor.', 1;

    DECLARE @tier_rank INT = (SELECT TOP (1) rank_no FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                               WHERE list_code = N'DD_TIER' AND value_code = @tier);
    DECLARE @previous BIGINT = (SELECT TOP (1) dd_id FROM grac_practice.tprm_dd_assessment
                                 WHERE engagement_id = @engagement_id AND status IN (N'COMPLETED', N'SUPERSEDED')
                                 ORDER BY dd_no DESC);

    -- signals for applicability
    DECLARE @data_rank INT, @access NVARCHAR(1000);
    SELECT @access = s.access_codes,
           @data_rank = (SELECT MAX(ISNULL(r.rank_no, 0)) FROM grac_practice.fn_tprm_split_codes(s.data_codes) x
                         JOIN grac_practice.fn_tprm_reference_effective(@organization_id) r ON r.list_code = N'DATA_EXPOSURE' AND r.value_code = x.code)
    FROM grac_practice.fn_tprm_engagement_signals(@engagement_id) s;

    DECLARE @dd BIGINT, @no INT;
    BEGIN TRAN;
        UPDATE grac_practice.tprm_dd_assessment SET status = N'SUPERSEDED' WHERE engagement_id = @engagement_id AND status = N'COMPLETED';
        SELECT @no = ISNULL(MAX(dd_no), 0) + 1 FROM grac_practice.tprm_dd_assessment WITH (UPDLOCK, HOLDLOCK) WHERE engagement_id = @engagement_id;
        INSERT grac_practice.tprm_dd_assessment
            (engagement_id, organization_id, risk_assessment_id, dd_no, dd_tier_code, status, due_dt, assessor_employee_id,
             reviewer_employee_id, copied_from_dd_id, started_by)
        VALUES (@engagement_id, @organization_id, @assessment, @no, ISNULL(@tier, N'BASIC'), N'IN_PROGRESS', @due_dt,
                COALESCE(@assessor_employee_id, @actor_employee_id), @reviewer_employee_id,
                CASE WHEN ISNULL(@copy_previous, 1) = 1 THEN @previous END, @actor);
        SET @dd = SCOPE_IDENTITY();

        INSERT grac_practice.tprm_dd_questionnaire (dd_id, organization_id, template_id, template_version_id, template_code, template_name, display_order)
        SELECT @dd, @organization_id, e.template_id, e.version_id, e.template_code, e.template_name,
               ROW_NUMBER() OVER (ORDER BY v.is_core DESC, ISNULL(v.applies_min_tier_rank, 0), e.template_name) * 10
        FROM grac_practice.fn_tprm_template_effective(@organization_id) e
        JOIN grac_practice.tprm_template_version v ON v.version_id = e.version_id
        WHERE e.template_kind = N'QUESTIONNAIRE'
          AND (v.is_core = 1
               OR (   (v.applies_service_categories IS NULL OR EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(v.applies_service_categories) x WHERE x.code = @category))
                  AND (v.applies_min_tier_rank IS NULL OR ISNULL(@tier_rank, 0) >= v.applies_min_tier_rank)
                  AND (v.applies_engagement_types IS NULL OR EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(v.applies_engagement_types) x WHERE x.code = @etype))));

        INSERT grac_practice.tprm_dd_response (ddq_id, dd_id, organization_id, question_id, question_code, base_applicable, is_applicable, status)
        SELECT q.ddq_id, @dd, @organization_id, qq.question_id, qq.question_code, b.ok,
               CASE WHEN qq.parent_question_code IS NULL THEN b.ok ELSE 0 END, N'PENDING'
        FROM grac_practice.tprm_dd_questionnaire q
        JOIN grac_practice.tprm_q_question qq ON qq.version_id = q.template_version_id
        CROSS APPLY (SELECT CAST(CASE WHEN (qq.min_tier_rank IS NULL OR ISNULL(@tier_rank, 0) >= qq.min_tier_rank)
                                        AND (qq.applies_service_categories IS NULL OR EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(qq.applies_service_categories) x WHERE x.code = @category))
                                        AND (qq.applies_min_data_rank IS NULL OR ISNULL(@data_rank, 0) >= qq.applies_min_data_rank)
                                        AND (qq.applies_access_codes IS NULL OR EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(qq.applies_access_codes) x
                                                                                        JOIN grac_practice.fn_tprm_split_codes(@access) a ON a.code = x.code))
                                      THEN 1 ELSE 0 END AS BIT) AS ok) b
        WHERE q.dd_id = @dd;

        INSERT grac_practice.tprm_safeguard_assessment
            (dd_id, engagement_id, organization_id, safeguard_code, safeguard_name, category_code, dimension_code, is_contract_clause,
             evidence_requirement_code, effectiveness_criteria, is_applicable)
        SELECT @dd, @engagement_id, @organization_id, l.item_code, l.item_name, l.category_code, l.dimension_code, l.is_contract_clause,
               l.evidence_requirement_code, l.effectiveness_criteria,
               CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_dd_response r JOIN grac_practice.tprm_q_question qq ON qq.question_id = r.question_id
                                  WHERE r.dd_id = @dd AND r.base_applicable = 1 AND qq.safeguard_code = l.item_code)
                      OR l.category_code = N'CONTRACTUAL'
                      OR EXISTS (SELECT 1 FROM grac_practice.tprm_risk_assessment_dimension d
                                  WHERE d.assessment_id = @assessment AND d.dimension_code = l.dimension_code AND d.inherent_score >= 50)
                    THEN 1 ELSE 0 END
        FROM grac_practice.fn_tprm_library_effective(@organization_id) l
        WHERE l.library_code = N'SAFEGUARD';

        IF ISNULL(@copy_previous, 1) = 1 AND @previous IS NOT NULL
        BEGIN
            UPDATE r SET respondent_type = p.respondent_type, answer_option_codes = p.answer_option_codes, answer_text = p.answer_text,
                         answer_number = p.answer_number, answer_date = p.answer_date, answered_by = p.answered_by, answered_dt = p.answered_dt,
                         rating_code = p.rating_code, assessor_comment = p.assessor_comment, reviewer_comment = p.reviewer_comment,
                         rated_by_employee_id = p.rated_by_employee_id, rated_dt = p.rated_dt, status = p.status
            FROM grac_practice.tprm_dd_response r
            JOIN grac_practice.tprm_dd_questionnaire q ON q.ddq_id = r.ddq_id
            JOIN grac_practice.tprm_dd_response p ON p.dd_id = @previous AND p.question_code = r.question_code
            JOIN grac_practice.tprm_dd_questionnaire pq ON pq.ddq_id = p.ddq_id AND pq.template_code = q.template_code
            WHERE r.dd_id = @dd AND p.status <> N'PENDING';
            UPDATE s SET is_applicable = p.is_applicable, existence_code = p.existence_code, contract_clause_ref = p.contract_clause_ref,
                         effectiveness_code = p.effectiveness_code, verification_method = p.verification_method,
                         -- evidence links stay on the previous round: a verification that rested on
                         -- evidence is re-done with the new round's evidence
                         is_verified = CASE WHEN p.verification_method = N'EVIDENCE_REVIEW' THEN 0 ELSE p.is_verified END,
                         verified_by_employee_id = CASE WHEN p.verification_method = N'EVIDENCE_REVIEW' THEN NULL ELSE p.verified_by_employee_id END,
                         verified_dt = CASE WHEN p.verification_method = N'EVIDENCE_REVIEW' THEN NULL ELSE p.verified_dt END,
                         verification_note = p.verification_note, comment = p.comment, assessed_by = p.assessed_by, assessed_dt = p.assessed_dt
            FROM grac_practice.tprm_safeguard_assessment s
            JOIN grac_practice.tprm_safeguard_assessment p ON p.dd_id = @previous AND p.safeguard_code = s.safeguard_code
            WHERE s.dd_id = @dd;
        END

        -- follow-ups whose parent's (copied) answer triggers them
        UPDATE c SET is_applicable = CASE WHEN c.base_applicable = 1 AND p.is_applicable = 1
                                           AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(p.answer_option_codes) a
                                                       JOIN grac_practice.fn_tprm_split_codes(cq.trigger_option_codes) t ON t.code = a.code)
                                          THEN 1 ELSE 0 END
        FROM grac_practice.tprm_dd_response c
        JOIN grac_practice.tprm_q_question cq ON cq.question_id = c.question_id AND cq.parent_question_code IS NOT NULL
        JOIN grac_practice.tprm_dd_response p ON p.ddq_id = c.ddq_id AND p.question_code = cq.parent_question_code
        WHERE c.dd_id = @dd;

        IF @stage = N'RISK_ASSESSED'
            UPDATE grac_practice.tprm_engagement SET stage_code = N'DUE_DILIGENCE', stage_dt = SYSUTCDATETIME(),
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE engagement_id = @engagement_id;
    COMMIT;

    EXEC grac_practice.sp_tprm_residual_calculate @organization_id, @engagement_id, @actor;
    DECLARE @detail NVARCHAR(2000);
    SELECT @detail = CONCAT(N'Due diligence round ', @no, N' started: ', COUNT(DISTINCT q.ddq_id), N' questionnaires, ',
                            SUM(CASE WHEN r.is_applicable = 1 THEN 1 ELSE 0 END), N' applicable questions, tier ', @tier, N'.')
    FROM grac_practice.tprm_dd_questionnaire q LEFT JOIN grac_practice.tprm_dd_response r ON r.ddq_id = q.ddq_id
    WHERE q.dd_id = @dd;
    DECLARE @to_stage NVARCHAR(30) = CASE WHEN @stage = N'RISK_ASSESSED' THEN N'DUE_DILIGENCE' ELSE @stage END;
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'DD_STARTED', @stage, @to_stage, @detail, @actor_employee_id, @actor;
    SELECT @dd AS DdId, N'STARTED' AS Result;
END
GO

-- The due-diligence workspace. @dd_id NULL = the current round.
-- Result sets: 1 header  2 questionnaires  3 sections  4 questions with
--   responses  5 options  6 safeguards  7 evidence  8 findings
--   9 dimensions (inherent / residual)  10 rounds
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_dd_get
    @organization_id    BIGINT,
    @engagement_id      BIGINT,
    @dd_id              BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id)
        THROW 57700, 'That engagement was not found.', 1;
    IF @dd_id IS NULL SELECT @dd_id = dd_id FROM grac_practice.fn_tprm_current_dd(@engagement_id);
    IF @dd_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_dd_assessment WHERE dd_id = @dd_id AND engagement_id = @engagement_id)
        THROW 57707, 'That due-diligence round was not found.', 1;

    SELECT d.dd_id AS DdId, d.dd_no AS DdNo, d.dd_tier_code AS DdTierCode, d.status AS Status, d.due_dt AS DueDt,
           d.assessor_employee_id AS AssessorEmployeeId, ae.employee_name AS AssessorName,
           d.reviewer_employee_id AS ReviewerEmployeeId, re.employee_name AS ReviewerName,
           d.risk_assessment_id AS RiskAssessmentId, d.summary AS Summary, d.started_by AS StartedBy, d.started_dt AS StartedDt,
           d.completed_by AS CompletedBy, d.completed_dt AS CompletedDt, d.copied_from_dd_id AS CopiedFromDdId,
           (SELECT COUNT(*) FROM grac_practice.tprm_dd_response r WHERE r.dd_id = d.dd_id AND r.is_applicable = 1) AS ApplicableQuestions,
           (SELECT COUNT(*) FROM grac_practice.tprm_dd_response r WHERE r.dd_id = d.dd_id AND r.is_applicable = 1 AND r.status <> N'PENDING') AS AnsweredQuestions,
           (SELECT COUNT(*) FROM grac_practice.tprm_dd_response r WHERE r.dd_id = d.dd_id AND r.is_applicable = 1 AND r.status = N'RATED') AS RatedQuestions,
           (SELECT COUNT(*) FROM grac_practice.tprm_safeguard_assessment s WHERE s.dd_id = d.dd_id AND s.is_applicable = 1) AS ApplicableSafeguards,
           (SELECT COUNT(*) FROM grac_practice.tprm_safeguard_assessment s WHERE s.dd_id = d.dd_id AND s.is_applicable = 1 AND s.effectiveness_code IS NOT NULL) AS AssessedSafeguards,
           (SELECT COUNT(*) FROM grac_practice.tprm_safeguard_assessment s WHERE s.dd_id = d.dd_id AND s.is_applicable = 1 AND s.is_verified = 1) AS VerifiedSafeguards
    FROM grac_practice.tprm_dd_assessment d
    LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = d.assessor_employee_id
    LEFT JOIN grac_practice.organization_employee re ON re.employee_id = d.reviewer_employee_id
    WHERE d.dd_id = @dd_id;

    SELECT q.ddq_id AS DdqId, q.template_id AS TemplateId, q.template_version_id AS TemplateVersionId, q.template_code AS TemplateCode,
           q.template_name AS TemplateName, v.version_no AS VersionNo, q.respondent_contact_id AS RespondentContactId,
           q.respondent_name AS RespondentName, q.sent_dt AS SentDt, q.responded_dt AS RespondedDt, q.display_order AS DisplayOrder
    FROM grac_practice.tprm_dd_questionnaire q
    JOIN grac_practice.tprm_template_version v ON v.version_id = q.template_version_id
    WHERE q.dd_id = @dd_id ORDER BY q.display_order;

    SELECT s.section_id AS SectionId, q.ddq_id AS DdqId, s.section_code AS SectionCode, s.title AS Title, s.display_order AS DisplayOrder
    FROM grac_practice.tprm_dd_questionnaire q
    JOIN grac_practice.tprm_q_section s ON s.version_id = q.template_version_id
    WHERE q.dd_id = @dd_id ORDER BY q.display_order, s.display_order;

    SELECT r.response_id AS ResponseId, r.ddq_id AS DdqId, qq.question_id AS QuestionId, qq.section_id AS SectionId,
           qq.question_code AS QuestionCode, qq.question_text AS QuestionText, qq.guidance AS Guidance, qq.response_type AS ResponseType,
           qq.is_mandatory AS IsMandatory, qq.evidence_expected AS EvidenceExpected, qq.evidence_requirement_code AS EvidenceRequirementCode,
           qq.safeguard_code AS SafeguardCode, qq.dimension_code AS DimensionCode, qq.parent_question_code AS ParentQuestionCode,
           qq.trigger_option_codes AS TriggerOptionCodes, qq.source_authority AS SourceAuthority, qq.source_reference AS SourceReference,
           qq.is_regulatory AS IsRegulatory, r.base_applicable AS BaseApplicable, r.is_applicable AS IsApplicable,
           r.respondent_type AS RespondentType, r.answer_option_codes AS AnswerOptionCodes, r.answer_text AS AnswerText,
           r.answer_number AS AnswerNumber, r.answer_date AS AnswerDate, r.answered_by AS AnsweredBy, r.answered_dt AS AnsweredDt,
           r.rating_code AS RatingCode, r.assessor_comment AS AssessorComment, r.reviewer_comment AS ReviewerComment,
           rb.employee_name AS RatedByName, r.rated_dt AS RatedDt, r.status AS Status,
           (SELECT COUNT(*) FROM grac_practice.tprm_evidence_link l WHERE l.target_kind = N'RESPONSE' AND l.target_id = r.response_id AND l.status = N'Active') AS EvidenceCount,
           (SELECT COUNT(*) FROM grac_practice.tprm_finding f WHERE f.source_kind = N'QUESTION' AND f.source_id = r.response_id AND f.status NOT IN (N'CANCELLED')) AS FindingCount
    FROM grac_practice.tprm_dd_response r
    JOIN grac_practice.tprm_q_question qq ON qq.question_id = r.question_id
    JOIN grac_practice.tprm_q_section s ON s.section_id = qq.section_id
    JOIN grac_practice.tprm_dd_questionnaire q ON q.ddq_id = r.ddq_id
    LEFT JOIN grac_practice.organization_employee rb ON rb.employee_id = r.rated_by_employee_id
    WHERE r.dd_id = @dd_id
    ORDER BY q.display_order, s.display_order, qq.display_order;

    SELECT o.option_id AS OptionId, o.question_id AS QuestionId, o.option_code AS OptionCode, o.option_label AS OptionLabel,
           o.flags_deficiency AS FlagsDeficiency, o.deficiency_severity_code AS DeficiencySeverityCode
    FROM grac_practice.tprm_q_option o
    WHERE o.question_id IN (SELECT r.question_id FROM grac_practice.tprm_dd_response r WHERE r.dd_id = @dd_id)
    ORDER BY o.question_id, o.display_order;

    SELECT s.sg_assessment_id AS SgAssessmentId, s.safeguard_code AS SafeguardCode, s.safeguard_name AS SafeguardName,
           s.category_code AS CategoryCode, s.dimension_code AS DimensionCode, s.is_contract_clause AS IsContractClause,
           s.evidence_requirement_code AS EvidenceRequirementCode, s.effectiveness_criteria AS EffectivenessCriteria,
           s.is_applicable AS IsApplicable, s.existence_code AS ExistenceCode, s.contract_clause_ref AS ContractClauseRef,
           s.effectiveness_code AS EffectivenessCode, s.verification_method AS VerificationMethod, s.is_verified AS IsVerified,
           ve.employee_name AS VerifiedByName, s.verified_dt AS VerifiedDt, s.verification_note AS VerificationNote,
           s.comment AS Comment, s.assessed_by AS AssessedBy, s.assessed_dt AS AssessedDt,
           (SELECT COUNT(*) FROM grac_practice.tprm_evidence_link l WHERE l.target_kind = N'SAFEGUARD' AND l.target_id = s.sg_assessment_id
              AND l.status = N'Active' AND l.review_status = N'ACCEPTED') AS AcceptedEvidenceCount
    FROM grac_practice.tprm_safeguard_assessment s
    LEFT JOIN grac_practice.organization_employee ve ON ve.employee_id = s.verified_by_employee_id
    WHERE s.dd_id = @dd_id
    ORDER BY s.is_applicable DESC, s.category_code, s.safeguard_name;

    SELECT l.tprm_evidence_id AS TprmEvidenceId, l.target_kind AS TargetKind, l.target_id AS TargetId,
           l.evidence_requirement_code AS EvidenceRequirementCode, l.source_kind AS SourceKind, l.evidence_item_id AS EvidenceItemId,
           l.evidence_file_id AS EvidenceFileId, f.version_no AS VersionNo, i.evidence_title AS EvidenceTitle,
           l.external_reference AS ExternalReference, l.external_location AS ExternalLocation, l.title AS Title,
           l.valid_from AS ValidFrom, l.valid_to AS ValidTo, l.note AS Note, l.review_status AS ReviewStatus,
           rv.employee_name AS ReviewedByName, l.reviewed_dt AS ReviewedDt, l.review_note AS ReviewNote,
           l.added_by_employee_id AS AddedByEmployeeId, ad.employee_name AS AddedByName, l.entered_dt AS AddedDt
    FROM grac_practice.tprm_evidence_link l
    LEFT JOIN grac_practice.evidence_item i ON i.evidence_item_id = l.evidence_item_id
    LEFT JOIN grac_practice.evidence_item_file f ON f.evidence_file_id = l.evidence_file_id
    LEFT JOIN grac_practice.organization_employee rv ON rv.employee_id = l.reviewed_by_employee_id
    LEFT JOIN grac_practice.organization_employee ad ON ad.employee_id = l.added_by_employee_id
    WHERE l.engagement_id = @engagement_id AND l.status = N'Active'
      AND (l.dd_id IS NULL OR l.dd_id = @dd_id)
    ORDER BY l.entered_dt DESC;

    SELECT f.finding_id AS FindingId, f.finding_number AS FindingNumber, f.finding_kind AS FindingKind, f.source_kind AS SourceKind,
           f.source_id AS SourceId, f.is_automatic AS IsAutomatic, f.title AS Title, f.description AS Description,
           f.severity_code AS SeverityCode, f.dimension_code AS DimensionCode, f.treatment_action_code AS TreatmentActionCode,
           f.owner_employee_id AS OwnerEmployeeId, oe.employee_name AS OwnerName, f.due_dt AS DueDt,
           f.is_mandatory_for_activation AS IsMandatoryForActivation, f.exception_until AS ExceptionUntil, f.status AS Status,
           f.status_note AS StatusNote, f.custom_gap_id AS CustomGapId, f.dd_id AS DdId,
           CAST(CASE WHEN f.status IN (N'OPEN', N'IN_PROGRESS') AND f.due_dt < CONVERT(DATE, SYSUTCDATETIME()) THEN 1 ELSE 0 END AS BIT) AS IsOverdue,
           CONVERT(BIGINT, f.record_version) AS RecordVersion, f.entered_dt AS EnteredDt
    FROM grac_practice.tprm_finding f
    LEFT JOIN grac_practice.organization_employee oe ON oe.employee_id = f.owner_employee_id
    WHERE f.engagement_id = @engagement_id
    ORDER BY CASE WHEN f.status IN (N'OPEN', N'IN_PROGRESS') THEN 0 ELSE 1 END, f.finding_id DESC;

    SELECT d.dimension_code AS DimensionCode, md.dimension_name AS DimensionName, d.weight AS Weight,
           d.inherent_score AS InherentScore, d.reduction_pct AS ReductionPct, d.uplift_pct AS UpliftPct,
           d.residual_score AS ResidualScore, d.safeguard_summary AS SafeguardSummary
    FROM grac_practice.tprm_engagement e
    JOIN grac_practice.tprm_risk_assessment_dimension d ON d.assessment_id = e.current_risk_assessment_id
    JOIN grac_practice.tprm_rm_dimension md ON md.dimension_id = d.dimension_id
    WHERE e.engagement_id = @engagement_id ORDER BY md.display_order;

    SELECT d.dd_id AS DdId, d.dd_no AS DdNo, d.status AS Status, d.dd_tier_code AS DdTierCode, d.started_dt AS StartedDt,
           d.completed_dt AS CompletedDt
    FROM grac_practice.tprm_dd_assessment d WHERE d.engagement_id = @engagement_id ORDER BY d.dd_no DESC;
END
GO

-- Internal: open / cancel the automatic deficiency of one source.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_auto_finding
    @organization_id BIGINT,
    @engagement_id   BIGINT,
    @dd_id           BIGINT,
    @source_kind     NVARCHAR(20),
    @source_id       BIGINT,
    @raise           BIT,
    @title           NVARCHAR(300)  = NULL,
    @description     NVARCHAR(2000) = NULL,
    @severity_code   NVARCHAR(60)   = NULL,
    @dimension_code  NVARCHAR(60)   = NULL,
    @owner_employee_id BIGINT       = NULL,
    @actor           NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @existing BIGINT = (SELECT TOP (1) finding_id FROM grac_practice.tprm_finding
                                 WHERE engagement_id = @engagement_id AND source_kind = @source_kind AND source_id = @source_id
                                   AND is_automatic = 1 AND status IN (N'OPEN', N'IN_PROGRESS')
                                 ORDER BY finding_id DESC);
    IF ISNULL(@raise, 0) = 1
    BEGIN
        IF @existing IS NOT NULL
        BEGIN
            UPDATE grac_practice.tprm_finding SET severity_code = COALESCE(@severity_code, severity_code), updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE finding_id = @existing;
            RETURN;
        END
        DECLARE @number NVARCHAR(20), @due_days INT, @treatment NVARCHAR(60);
        EXEC grac_practice.sp_tprm_next_number @organization_id, N'TPF-', @number OUTPUT;
        SELECT TOP (1) @treatment = item_code, @due_days = default_due_days FROM grac_practice.fn_tprm_library_effective(@organization_id)
         WHERE library_code = N'TREATMENT_ACTION' AND item_code = N'TA_REMEDIATE';
        INSERT grac_practice.tprm_finding
            (organization_id, engagement_id, dd_id, finding_number, finding_kind, source_kind, source_id, is_automatic, title, description,
             severity_code, dimension_code, treatment_action_code, owner_employee_id, due_dt, status, entered_by)
        VALUES (@organization_id, @engagement_id, @dd_id, @number, N'DEFICIENCY', @source_kind, @source_id, 1, LEFT(@title, 300), @description,
                ISNULL(@severity_code, N'MEDIUM'), @dimension_code, @treatment, @owner_employee_id,
                CASE WHEN @due_days > 0 THEN DATEADD(DAY, @due_days, CONVERT(DATE, SYSUTCDATETIME())) END, N'OPEN', @actor);
    END
    ELSE IF @existing IS NOT NULL
        UPDATE grac_practice.tprm_finding
           SET status = N'CANCELLED', status_note = N'No longer indicated by the response / assessment.', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE finding_id = @existing AND custom_gap_id IS NULL;
END
GO

-- Internal: the round an edit is allowed on (IN_PROGRESS, same organization).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_dd_open_check
    @organization_id BIGINT,
    @dd_id           BIGINT,
    @engagement_id   BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @status NVARCHAR(20);
    SELECT @engagement_id = engagement_id, @status = status FROM grac_practice.tprm_dd_assessment
     WHERE dd_id = @dd_id AND organization_id = @organization_id;
    IF @engagement_id IS NULL THROW 57707, 'That due-diligence round was not found.', 1;
    IF @status <> N'IN_PROGRESS' THROW 57708, 'This due-diligence round is closed. Start a new round to change it.', 1;
END
GO

-- Record a response (third party's or internal). Validates the answer
-- against the response type and options; opens / cancels the automatic
-- deficiency for options that flag one; shows / hides follow-ups.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_dd_response_save
    @organization_id     BIGINT,
    @response_id         BIGINT,
    @respondent_type     NVARCHAR(20)   = N'THIRD_PARTY',
    @answer_option_codes NVARCHAR(400)  = NULL,
    @answer_text         NVARCHAR(MAX)  = NULL,
    @answer_number       DECIMAL(19,4)  = NULL,
    @answer_date         DATE           = NULL,
    @actor_employee_id   BIGINT         = NULL,
    @actor               NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @dd BIGINT, @eng BIGINT, @ddq BIGINT, @qid BIGINT, @applicable BIT;
    SELECT @dd = dd_id, @ddq = ddq_id, @qid = question_id, @applicable = is_applicable
    FROM grac_practice.tprm_dd_response WHERE response_id = @response_id AND organization_id = @organization_id;
    IF @dd IS NULL THROW 57709, 'That question was not found.', 1;
    EXEC grac_practice.sp_tprm_dd_open_check @organization_id, @dd, @eng OUTPUT;
    IF @applicable = 0 THROW 57710, 'That question does not apply to this engagement.', 1;
    IF ISNULL(@respondent_type, N'') NOT IN (N'THIRD_PARTY', N'INTERNAL') SET @respondent_type = N'THIRD_PARTY';

    DECLARE @type NVARCHAR(20), @qcode NVARCHAR(60), @qtext NVARCHAR(2000), @dim NVARCHAR(60);
    SELECT @type = response_type, @qcode = question_code, @qtext = question_text, @dim = dimension_code
    FROM grac_practice.tprm_q_question WHERE question_id = @qid;

    SET @answer_option_codes = NULLIF(UPPER(LTRIM(RTRIM(@answer_option_codes))), N'');
    SET @answer_text = NULLIF(LTRIM(RTRIM(@answer_text)), N'');
    IF @type IN (N'YES_NO', N'SINGLE', N'MULTI') AND @answer_option_codes IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(@answer_option_codes) a
                    WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_q_option o WHERE o.question_id = @qid AND o.option_code = a.code))
            THROW 57711, 'That answer is not one of the options.', 1;
        IF @type <> N'MULTI' AND (SELECT COUNT(*) FROM grac_practice.fn_tprm_split_codes(@answer_option_codes)) > 1
            THROW 57712, 'Choose one option.', 1;
    END
    IF @type = N'NUMBER' AND @answer_number IS NULL AND @answer_text IS NOT NULL
    BEGIN
        SET @answer_number = TRY_CONVERT(DECIMAL(19,4), @answer_text);
        IF @answer_number IS NULL THROW 57713, 'The answer must be a number.', 1;
    END
    DECLARE @has_answer BIT = CASE WHEN (@type IN (N'YES_NO', N'SINGLE', N'MULTI') AND @answer_option_codes IS NOT NULL)
                                     OR (@type = N'TEXT' AND @answer_text IS NOT NULL)
                                     OR (@type = N'NUMBER' AND @answer_number IS NOT NULL)
                                     OR (@type = N'DATE' AND @answer_date IS NOT NULL) THEN 1 ELSE 0 END;

    DECLARE @owner BIGINT = (SELECT COALESCE(relationship_owner_employee_id, business_owner_employee_id)
                             FROM grac_practice.tprm_engagement WHERE engagement_id = @eng);
    DECLARE @def_sev NVARCHAR(60), @def_opt NVARCHAR(300), @def_code NVARCHAR(60);
    SELECT TOP (1) @def_sev = o.deficiency_severity_code, @def_opt = o.option_label, @def_code = o.option_code
    FROM grac_practice.fn_tprm_split_codes(@answer_option_codes) a
    JOIN grac_practice.tprm_q_option o ON o.question_id = @qid AND o.option_code = a.code AND o.flags_deficiency = 1
    LEFT JOIN grac_practice.fn_tprm_reference_effective(@organization_id) sv ON sv.list_code = N'FINDING_SEVERITY' AND sv.value_code = o.deficiency_severity_code
    ORDER BY ISNULL(sv.rank_no, 0) DESC;

    BEGIN TRAN;
        UPDATE grac_practice.tprm_dd_response
           SET respondent_type = @respondent_type,
               answer_option_codes = CASE WHEN @type IN (N'YES_NO', N'SINGLE', N'MULTI') THEN @answer_option_codes END,
               answer_text = CASE WHEN @type IN (N'TEXT', N'YES_NO', N'SINGLE', N'MULTI') THEN @answer_text END,
               answer_number = CASE WHEN @type = N'NUMBER' THEN @answer_number END,
               answer_date = CASE WHEN @type = N'DATE' THEN @answer_date END,
               answered_by = @actor, answered_dt = SYSUTCDATETIME(),
               -- a changed answer needs a new rating
               rating_code = NULL, rated_by_employee_id = NULL, rated_dt = NULL,
               status = CASE WHEN @has_answer = 1 THEN N'ANSWERED' ELSE N'PENDING' END
         WHERE response_id = @response_id;

        -- follow-ups of this question
        UPDATE c SET is_applicable = CASE WHEN c.base_applicable = 1
                                           AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(@answer_option_codes) a
                                                       JOIN grac_practice.fn_tprm_split_codes(cq.trigger_option_codes) t ON t.code = a.code)
                                          THEN 1 ELSE 0 END
        FROM grac_practice.tprm_dd_response c
        JOIN grac_practice.tprm_q_question cq ON cq.question_id = c.question_id AND cq.parent_question_code = @qcode
        WHERE c.ddq_id = @ddq;
        UPDATE f SET status = N'CANCELLED', status_note = N'The question no longer applies.', updated_by = @actor, updated_dt = SYSUTCDATETIME()
        FROM grac_practice.tprm_finding f
        JOIN grac_practice.tprm_dd_response c ON c.response_id = f.source_id AND c.ddq_id = @ddq AND c.is_applicable = 0
        WHERE f.source_kind = N'QUESTION' AND f.is_automatic = 1 AND f.status IN (N'OPEN', N'IN_PROGRESS') AND f.custom_gap_id IS NULL;

        DECLARE @raise BIT = CASE WHEN @def_code IS NOT NULL THEN 1 ELSE 0 END;
        DECLARE @ftitle NVARCHAR(300) = LEFT(CONCAT(@qcode, N': ', @qtext), 300);
        DECLARE @fdesc NVARCHAR(2000) = CONCAT(N'Response "', @def_opt, N'" indicates a deficiency.');
        EXEC grac_practice.sp_tprm_auto_finding @organization_id, @eng, @dd, N'QUESTION', @response_id, @raise,
             @ftitle, @fdesc, @def_sev, @dim, @owner, @actor;
    COMMIT;

    EXEC grac_practice.sp_tprm_residual_calculate @organization_id, @eng, @actor;
    SELECT @response_id AS ResponseId, CASE WHEN @raise = 1 THEN N'SAVED_DEFICIENCY' ELSE N'SAVED' END AS Result;
END
GO

-- Assessor rating + reviewer comment of a response.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_dd_response_rate
    @organization_id   BIGINT,
    @response_id       BIGINT,
    @rating_code       NVARCHAR(60),
    @assessor_comment  NVARCHAR(2000) = NULL,
    @reviewer_comment  NVARCHAR(2000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @dd BIGINT, @eng BIGINT, @status NVARCHAR(20), @applicable BIT;
    SELECT @dd = dd_id, @status = status, @applicable = is_applicable FROM grac_practice.tprm_dd_response
     WHERE response_id = @response_id AND organization_id = @organization_id;
    IF @dd IS NULL THROW 57709, 'That question was not found.', 1;
    EXEC grac_practice.sp_tprm_dd_open_check @organization_id, @dd, @eng OUTPUT;
    IF @applicable = 0 THROW 57710, 'That question does not apply to this engagement.', 1;
    IF @status = N'PENDING' THROW 57714, 'The question has no answer to rate yet.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                    WHERE list_code = N'RESPONSE_RATING' AND value_code = @rating_code)
        THROW 57715, 'Choose a rating from the list.', 1;

    UPDATE grac_practice.tprm_dd_response
       SET rating_code = @rating_code, assessor_comment = @assessor_comment, reviewer_comment = @reviewer_comment,
           rated_by_employee_id = @actor_employee_id, rated_dt = SYSUTCDATETIME(), status = N'RATED'
     WHERE response_id = @response_id;
    SELECT @response_id AS ResponseId, N'RATED' AS Result;
END
GO

-- Safeguard assessment. Effectiveness EFFECTIVE / PARTIALLY_EFFECTIVE
-- counts only once VERIFIED; verification needs a method other than
-- attestation, and for EVIDENCE_REVIEW at least one accepted evidence
-- (on the safeguard, or on a response of a question mapped to it); for
-- the other methods a note saying what was checked. A missing applicable
-- safeguard or an ineffective one opens a deficiency.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_safeguard_save
    @organization_id     BIGINT,
    @sg_assessment_id    BIGINT,
    @is_applicable       BIT            = 1,
    @existence_code      NVARCHAR(20)   = NULL,
    @contract_clause_ref NVARCHAR(300)  = NULL,
    @effectiveness_code  NVARCHAR(60)   = NULL,
    @verification_method NVARCHAR(30)   = NULL,
    @verify              BIT            = 0,
    @verification_note   NVARCHAR(2000) = NULL,
    @comment             NVARCHAR(2000) = NULL,
    @actor_employee_id   BIGINT         = NULL,
    @actor               NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @dd BIGINT, @eng BIGINT, @code NVARCHAR(60), @name NVARCHAR(250), @dim NVARCHAR(60), @clause BIT;
    SELECT @dd = dd_id, @code = safeguard_code, @name = safeguard_name, @dim = dimension_code, @clause = is_contract_clause
    FROM grac_practice.tprm_safeguard_assessment WHERE sg_assessment_id = @sg_assessment_id AND organization_id = @organization_id;
    IF @dd IS NULL THROW 57716, 'That safeguard was not found.', 1;
    EXEC grac_practice.sp_tprm_dd_open_check @organization_id, @dd, @eng OUTPUT;

    SET @effectiveness_code = NULLIF(LTRIM(RTRIM(@effectiveness_code)), N'');
    DECLARE @meaning NVARCHAR(40);
    IF @effectiveness_code IS NOT NULL
    BEGIN
        SELECT TOP (1) @meaning = meaning_code FROM grac_practice.fn_tprm_reference_effective(@organization_id)
         WHERE list_code = N'EFFECTIVENESS' AND value_code = @effectiveness_code;
        IF @meaning IS NULL THROW 57717, 'Choose an effectiveness value from the list.', 1;
    END
    IF @existence_code IS NOT NULL AND @existence_code NOT IN (N'EXISTS', N'PARTIAL', N'MISSING', N'UNKNOWN')
        THROW 57718, 'Unknown existence value.', 1;
    IF @verification_method IS NOT NULL AND @verification_method NOT IN (N'EVIDENCE_REVIEW', N'ASSURANCE_RESULT', N'TESTING', N'CONTRACT_REVIEW', N'ATTESTATION_ONLY')
        THROW 57719, 'Unknown verification method.', 1;
    IF ISNULL(@is_applicable, 1) = 1 AND @existence_code = N'MISSING' AND @meaning IN (N'EFFECTIVE', N'PARTIALLY_EFFECTIVE')
        THROW 57720, 'A missing safeguard cannot be effective.', 1;
    IF @clause = 1 AND @existence_code IN (N'EXISTS', N'PARTIAL') AND NULLIF(LTRIM(RTRIM(@contract_clause_ref)), N'') IS NULL
        THROW 57721, 'Give the contract clause reference for a contractual safeguard.', 1;

    DECLARE @verified BIT = 0;
    IF ISNULL(@verify, 0) = 1 AND ISNULL(@is_applicable, 1) = 1
    BEGIN
        IF @meaning IS NULL OR @meaning NOT IN (N'EFFECTIVE', N'PARTIALLY_EFFECTIVE')
            THROW 57722, 'Only an effective or partially effective safeguard is verified.', 1;
        IF @verification_method IS NULL OR @verification_method = N'ATTESTATION_ONLY'
            THROW 57723, 'An attestation alone does not verify a safeguard. Review evidence, an assurance result, a test or the contract.', 1;
        IF @verification_method = N'EVIDENCE_REVIEW'
           AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_evidence_link l
                            WHERE l.engagement_id = @eng AND l.status = N'Active' AND l.review_status = N'ACCEPTED'
                              AND ((l.target_kind = N'SAFEGUARD' AND l.target_id = @sg_assessment_id)
                                OR (l.target_kind = N'RESPONSE' AND l.target_id IN
                                       (SELECT r.response_id FROM grac_practice.tprm_dd_response r
                                        JOIN grac_practice.tprm_q_question q ON q.question_id = r.question_id
                                        WHERE r.dd_id = @dd AND q.safeguard_code = @code))))
            THROW 57724, 'Verification by evidence review needs at least one accepted evidence for this safeguard.', 1;
        IF @verification_method <> N'EVIDENCE_REVIEW' AND NULLIF(LTRIM(RTRIM(@verification_note)), N'') IS NULL
            THROW 57725, 'Say what was checked to verify the safeguard.', 1;
        SET @verified = 1;
    END

    DECLARE @owner BIGINT = (SELECT COALESCE(relationship_owner_employee_id, business_owner_employee_id)
                             FROM grac_practice.tprm_engagement WHERE engagement_id = @eng);
    BEGIN TRAN;
        UPDATE grac_practice.tprm_safeguard_assessment
           SET is_applicable = ISNULL(@is_applicable, 1), existence_code = @existence_code, contract_clause_ref = @contract_clause_ref,
               effectiveness_code = @effectiveness_code, verification_method = @verification_method,
               -- a change of the assessment drops an earlier verification unless re-verified now
               is_verified = @verified,
               verified_by_employee_id = CASE WHEN @verified = 1 THEN @actor_employee_id END,
               verified_dt = CASE WHEN @verified = 1 THEN SYSUTCDATETIME() END,
               verification_note = @verification_note, comment = @comment, assessed_by = @actor, assessed_dt = SYSUTCDATETIME()
         WHERE sg_assessment_id = @sg_assessment_id;

        DECLARE @raise BIT = CASE WHEN ISNULL(@is_applicable, 1) = 1 AND (@existence_code = N'MISSING' OR @meaning = N'INEFFECTIVE') THEN 1 ELSE 0 END;
        DECLARE @sev NVARCHAR(60) = CASE WHEN @meaning = N'INEFFECTIVE' OR @clause = 1 THEN N'HIGH' ELSE N'MEDIUM' END;
        DECLARE @ftitle NVARCHAR(300) = LEFT(CONCAT(N'Safeguard ', CASE WHEN @existence_code = N'MISSING' THEN N'missing' ELSE N'ineffective' END, N': ', @name), 300);
        DECLARE @fdesc NVARCHAR(2000) = COALESCE(@comment, @verification_note);
        EXEC grac_practice.sp_tprm_auto_finding @organization_id, @eng, @dd, N'SAFEGUARD', @sg_assessment_id, @raise,
             @ftitle, @fdesc, @sev, @dim, @owner, @actor;
    COMMIT;

    EXEC grac_practice.sp_tprm_residual_calculate @organization_id, @eng, @actor;
    SELECT @sg_assessment_id AS SgAssessmentId, CASE WHEN @verified = 1 THEN N'VERIFIED' ELSE N'SAVED' END AS Result;
END
GO

-- Complete a round: every applicable mandatory question answered, every
-- answered applicable question rated, every applicable safeguard
-- assessed, and evidence-expected questions either evidenced or covered
-- by a finding. Then the residual is recalculated.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_dd_complete
    @organization_id   BIGINT,
    @dd_id             BIGINT,
    @summary           NVARCHAR(2000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @eng BIGINT;
    EXEC grac_practice.sp_tprm_dd_open_check @organization_id, @dd_id, @eng OUTPUT;

    DECLARE @msg NVARCHAR(400), @n INT;
    SELECT @n = COUNT(*) FROM grac_practice.tprm_dd_response r JOIN grac_practice.tprm_q_question q ON q.question_id = r.question_id
     WHERE r.dd_id = @dd_id AND r.is_applicable = 1 AND q.is_mandatory = 1 AND r.status = N'PENDING';
    IF @n > 0 BEGIN SET @msg = CONCAT(@n, N' mandatory question(s) have no answer.'); THROW 57726, @msg, 1; END
    SELECT @n = COUNT(*) FROM grac_practice.tprm_dd_response WHERE dd_id = @dd_id AND is_applicable = 1 AND status = N'ANSWERED';
    IF @n > 0 BEGIN SET @msg = CONCAT(@n, N' answered question(s) are not rated by the assessor yet.'); THROW 57727, @msg, 1; END
    SELECT @n = COUNT(*) FROM grac_practice.tprm_safeguard_assessment WHERE dd_id = @dd_id AND is_applicable = 1 AND effectiveness_code IS NULL;
    IF @n > 0 BEGIN SET @msg = CONCAT(@n, N' applicable safeguard(s) are not assessed yet.'); THROW 57728, @msg, 1; END
    SELECT @n = COUNT(*) FROM grac_practice.tprm_dd_response r JOIN grac_practice.tprm_q_question q ON q.question_id = r.question_id
     WHERE r.dd_id = @dd_id AND r.is_applicable = 1 AND q.evidence_expected = 1
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_evidence_link l WHERE l.target_kind = N'RESPONSE' AND l.target_id = r.response_id
                         AND l.status = N'Active' AND l.review_status <> N'REJECTED')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_finding f WHERE f.source_kind = N'QUESTION' AND f.source_id = r.response_id
                         AND f.status <> N'CANCELLED');
    IF @n > 0 BEGIN SET @msg = CONCAT(@n, N' question(s) expect evidence: link it, or record a deficiency for the missing evidence.'); THROW 57729, @msg, 1; END
    -- once the round is closed its evidence can no longer be reviewed
    SELECT @n = COUNT(*) FROM grac_practice.tprm_evidence_link WHERE dd_id = @dd_id AND status = N'Active' AND review_status = N'PENDING';
    IF @n > 0 BEGIN SET @msg = CONCAT(@n, N' evidence item(s) are awaiting review (accept or reject them first).'); THROW 57824, @msg, 1; END

    UPDATE grac_practice.tprm_dd_assessment
       SET status = N'COMPLETED', summary = @summary, completed_by = @actor, completed_dt = SYSUTCDATETIME()
     WHERE dd_id = @dd_id;
    EXEC grac_practice.sp_tprm_residual_calculate @organization_id, @eng, @actor;

    DECLARE @stage NVARCHAR(30), @detail NVARCHAR(2000);
    SELECT @stage = stage_code, @detail = CONCAT(N'Due diligence completed. Residual score ', residual_score, N', band ', residual_band_code, N'.')
    FROM grac_practice.tprm_engagement WHERE engagement_id = @eng;
    EXEC grac_practice.sp_tprm_engagement_event @eng, N'DD_COMPLETED', @stage, @stage, @detail, @actor_employee_id, @actor;
    SELECT @dd_id AS DdId, N'COMPLETED' AS Result;
END
GO

-- =====================================================================
-- 8. Evidence (Evidence Center reuse + external references)
-- =====================================================================
-- Evidence Center items the caller can see, for the shared Evidence
-- Center picker (Shared/evidence-picker.js): the columns it renders
-- (ValidityState, UsedInCount, Linkable) and its paging. Expiring = valid
-- to within 30 days (the Evidence Center rule). Retired items are not
-- offered (they cannot be newly linked, 476).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_evidence_candidates
    @organization_id    BIGINT,
    @search             NVARCHAR(200) = NULL,
    @evidence_type_id   INT           = NULL,
    @page_number        INT           = 1,
    @page_size          INT           = 10,
    @caller_employee_id BIGINT        = NULL,
    @caller_is_admin    BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');
    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());
    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 10 WHEN @page_size > 100 THEN 100 ELSE @page_size END;
    SELECT i.evidence_item_id AS EvidenceItemId, i.evidence_title AS EvidenceTitle, i.evidence_type_id AS EvidenceTypeId,
           et.evidence_type_name AS EvidenceType, f.evidence_file_id AS CurrentFileId, f.version_no AS CurrentVersionNo,
           f.file_name AS FileName, i.valid_from AS ValidFrom, i.valid_to AS ValidTo,
           CASE WHEN i.valid_to IS NULL THEN N'NoExpiry' WHEN i.valid_to < @today THEN N'Expired'
                WHEN i.valid_to <= DATEADD(DAY, 30, @today) THEN N'Expiring' ELSE N'Valid' END AS ValidityState,
           (SELECT COUNT(*) FROM grac_practice.evidence_link l WHERE l.evidence_item_id = i.evidence_item_id AND l.status = N'Active')
         + (SELECT COUNT(*) FROM grac_practice.tprm_evidence_link t WHERE t.evidence_item_id = i.evidence_item_id AND t.status = N'Active') AS UsedInCount,
           CAST(CASE WHEN f.evidence_file_id IS NULL THEN 0 ELSE 1 END AS BIT) AS Linkable,
           CAST(CASE WHEN f.evidence_file_id IS NULL THEN N'No file uploaded' END AS NVARCHAR(100)) AS NotLinkableReason,
           ow.employee_name AS OwnerName, i.classification AS Classification,
           COUNT(*) OVER () AS TotalRows
    FROM grac_practice.evidence_item i
    CROSS APPLY grac_practice.fn_pm_evidence_item_visible(i.evidence_item_id, i.owner_employee_id, i.created_by_employee_id,
                                                          i.classification, @caller_employee_id, @caller_is_admin) v
    LEFT JOIN grac_practice.evidence_item_file f ON f.evidence_item_id = i.evidence_item_id AND f.is_current = 1
    LEFT JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = i.evidence_type_id
    LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = i.owner_employee_id
    WHERE i.organization_id = @organization_id AND i.status = N'Active'
      AND (@evidence_type_id IS NULL OR i.evidence_type_id = @evidence_type_id)
      AND (@s IS NULL OR i.evidence_title LIKE N'%' + @s + N'%' OR i.tags LIKE N'%' + @s + N'%' OR f.file_name LIKE N'%' + @s + N'%')
    ORDER BY i.evidence_title, i.evidence_item_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_evidence_link_add
    @organization_id           BIGINT,
    @engagement_id             BIGINT,
    @target_kind               NVARCHAR(30),
    @target_id                 BIGINT,
    @source_kind               NVARCHAR(20),
    @evidence_item_id          BIGINT         = NULL,
    @external_reference        NVARCHAR(400)  = NULL,
    @external_location         NVARCHAR(1000) = NULL,
    @title                     NVARCHAR(300)  = NULL,
    @evidence_requirement_code NVARCHAR(60)   = NULL,
    @valid_from                DATE           = NULL,
    @valid_to                  DATE           = NULL,
    @note                      NVARCHAR(1000) = NULL,
    @caller_is_admin           BIT            = 0,
    @actor_employee_id         BIGINT         = NULL,
    @actor                     NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30) = (SELECT stage_code FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id);
    IF @stage IS NULL THROW 57700, 'That engagement was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57730, 'A closed engagement cannot be changed.', 1;

    DECLARE @dd BIGINT = NULL;
    IF @target_kind = N'RESPONSE'
        SELECT @dd = r.dd_id FROM grac_practice.tprm_dd_response r JOIN grac_practice.tprm_dd_assessment d ON d.dd_id = r.dd_id
         WHERE r.response_id = @target_id AND d.engagement_id = @engagement_id;
    ELSE IF @target_kind = N'SAFEGUARD'
        SELECT @dd = dd_id FROM grac_practice.tprm_safeguard_assessment WHERE sg_assessment_id = @target_id AND engagement_id = @engagement_id;
    ELSE IF @target_kind = N'FINDING'
        -- remediation evidence: a finding outlives its due-diligence round
        SELECT @dd = 0 FROM grac_practice.tprm_finding WHERE finding_id = @target_id AND engagement_id = @engagement_id;
    ELSE IF @target_kind = N'REVIEW'
        SELECT @dd = 0 FROM grac_practice.tprm_review WHERE review_id = @target_id AND engagement_id = @engagement_id;
    ELSE IF @target_kind = N'ONBOARDING'
        SELECT @dd = 0 FROM grac_practice.tprm_onboarding_item WHERE item_id = @target_id AND engagement_id = @engagement_id;
    ELSE IF @target_kind = N'ENGAGEMENT' AND @target_id = @engagement_id
        SET @dd = 0;
    ELSE THROW 57731, 'Evidence cannot be attached to that.', 1;
    IF @dd IS NULL THROW 57732, 'The record the evidence is for was not found on this engagement.', 1;
    IF @dd = 0 SET @dd = NULL;
    IF @dd IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.tprm_dd_assessment WHERE dd_id = @dd AND status <> N'IN_PROGRESS')
        THROW 57708, 'This due-diligence round is closed. Start a new round to change it.', 1;

    DECLARE @file BIGINT, @item_title NVARCHAR(300), @item_from DATE, @item_to DATE;
    IF @source_kind = N'EVIDENCE_CENTER'
    BEGIN
        SELECT @file = f.evidence_file_id, @item_title = i.evidence_title, @item_from = i.valid_from, @item_to = i.valid_to
        FROM grac_practice.evidence_item i
        CROSS APPLY grac_practice.fn_pm_evidence_item_visible(i.evidence_item_id, i.owner_employee_id, i.created_by_employee_id,
                                                              i.classification, @actor_employee_id, @caller_is_admin) v
        LEFT JOIN grac_practice.evidence_item_file f ON f.evidence_item_id = i.evidence_item_id AND f.is_current = 1
        WHERE i.evidence_item_id = @evidence_item_id AND i.organization_id = @organization_id AND i.status = N'Active';
        IF @item_title IS NULL THROW 57733, 'That Evidence Center item was not found, is not active, or you cannot see it.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_evidence_link WHERE engagement_id = @engagement_id AND target_kind = @target_kind
                     AND target_id = @target_id AND evidence_item_id = @evidence_item_id AND status = N'Active')
            THROW 57734, 'That evidence is already linked here.', 1;
    END
    ELSE IF @source_kind = N'EXTERNAL'
    BEGIN
        SET @external_reference = NULLIF(LTRIM(RTRIM(@external_reference)), N'');
        IF @external_reference IS NULL THROW 57735, 'An external evidence reference needs the reference (document number, report or link).', 1;
    END
    ELSE THROW 57736, 'Choose where the evidence comes from.', 1;

    SET @title = COALESCE(NULLIF(LTRIM(RTRIM(@title)), N''), @item_title, @external_reference);
    SET @valid_from = COALESCE(@valid_from, @item_from);
    SET @valid_to = COALESCE(@valid_to, @item_to);
    IF @valid_to IS NULL AND @evidence_requirement_code IS NOT NULL
        SELECT @valid_to = CASE WHEN validity_months IS NOT NULL THEN DATEADD(MONTH, validity_months, ISNULL(@valid_from, CONVERT(DATE, SYSUTCDATETIME()))) END
        FROM grac_practice.fn_tprm_library_effective(@organization_id)
        WHERE library_code = N'EVIDENCE_REQUIREMENT' AND item_code = @evidence_requirement_code;

    DECLARE @id BIGINT;
    INSERT grac_practice.tprm_evidence_link
        (organization_id, engagement_id, dd_id, target_kind, target_id, evidence_requirement_code, source_kind, evidence_item_id,
         evidence_file_id, external_reference, external_location, title, valid_from, valid_to, note, review_status,
         added_by_employee_id, entered_by)
    VALUES (@organization_id, @engagement_id, @dd, @target_kind, @target_id, NULLIF(@evidence_requirement_code, N''), @source_kind,
            CASE WHEN @source_kind = N'EVIDENCE_CENTER' THEN @evidence_item_id END, @file, @external_reference, @external_location,
            LEFT(@title, 300), @valid_from, @valid_to, @note, N'PENDING', @actor_employee_id, @actor);
    SET @id = SCOPE_IDENTITY();
    DECLARE @detail NVARCHAR(2000) = CONCAT(N'Evidence "', @title, N'" linked to ', @target_kind, N'.');
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'EVIDENCE_LINKED', @stage, @stage, @detail, @actor_employee_id, @actor;
    SELECT @id AS TprmEvidenceId, N'LINKED' AS Result;
END
GO

-- ACCEPT / REJECT by the evidence reviewer (never the person who added
-- it -- BRD 9 separation of duties); REMOVE unlinks (the Evidence Center
-- item stays).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_evidence_review
    @organization_id   BIGINT,
    @tprm_evidence_id  BIGINT,
    @action            NVARCHAR(20),
    @note              NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @eng BIGINT, @added_by BIGINT, @dd BIGINT, @title NVARCHAR(300), @target_kind NVARCHAR(30), @target_id BIGINT;
    SELECT @eng = engagement_id, @added_by = added_by_employee_id, @dd = dd_id, @title = title,
           @target_kind = target_kind, @target_id = target_id
    FROM grac_practice.tprm_evidence_link WHERE tprm_evidence_id = @tprm_evidence_id AND organization_id = @organization_id AND status = N'Active';
    IF @eng IS NULL THROW 57737, 'That evidence link was not found.', 1;
    IF @dd IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.tprm_dd_assessment WHERE dd_id = @dd AND status <> N'IN_PROGRESS')
        THROW 57708, 'This due-diligence round is closed. Start a new round to change it.', 1;

    IF @action IN (N'ACCEPT', N'REJECT')
    BEGIN
        IF @actor_employee_id IS NULL THROW 57738, 'Reviewing evidence needs a sign-in linked to an employee.', 1;
        IF @added_by = @actor_employee_id THROW 57739, 'Evidence must be reviewed by someone other than the person who added it.', 1;
        IF @action = N'REJECT' AND NULLIF(LTRIM(RTRIM(@note)), N'') IS NULL THROW 57740, 'Say why the evidence is rejected.', 1;
        UPDATE grac_practice.tprm_evidence_link
           SET review_status = CASE WHEN @action = N'ACCEPT' THEN N'ACCEPTED' ELSE N'REJECTED' END,
               reviewed_by_employee_id = @actor_employee_id, reviewed_dt = SYSUTCDATETIME(), review_note = @note,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE tprm_evidence_id = @tprm_evidence_id;
    END
    ELSE IF @action = N'REMOVE'
    BEGIN
        UPDATE grac_practice.tprm_evidence_link SET status = N'Removed', review_note = COALESCE(@note, review_note),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE tprm_evidence_id = @tprm_evidence_id;
    END
    ELSE THROW 57741, 'Unknown evidence action.', 1;

    -- A safeguard verified by evidence review stays verified only while
    -- accepted evidence supports it -- on the safeguard, or on a response of
    -- a question mapped to it (the rule sp_tprm_safeguard_save verifies by).
    IF @action IN (N'REJECT', N'REMOVE') AND @dd IS NOT NULL AND @target_kind IN (N'SAFEGUARD', N'RESPONSE')
        UPDATE s SET is_verified = 0, verified_by_employee_id = NULL, verified_dt = NULL
        FROM grac_practice.tprm_safeguard_assessment s
        WHERE s.dd_id = @dd AND s.is_verified = 1 AND s.verification_method = N'EVIDENCE_REVIEW'
          AND ((@target_kind = N'SAFEGUARD' AND s.sg_assessment_id = @target_id)
            OR (@target_kind = N'RESPONSE' AND s.safeguard_code IN (SELECT q.safeguard_code FROM grac_practice.tprm_dd_response r
                                                                    JOIN grac_practice.tprm_q_question q ON q.question_id = r.question_id
                                                                    WHERE r.response_id = @target_id)))
          AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_evidence_link l
                           WHERE l.engagement_id = @eng AND l.status = N'Active' AND l.review_status = N'ACCEPTED'
                             AND ((l.target_kind = N'SAFEGUARD' AND l.target_id = s.sg_assessment_id)
                               OR (l.target_kind = N'RESPONSE' AND l.target_id IN
                                      (SELECT r.response_id FROM grac_practice.tprm_dd_response r
                                       JOIN grac_practice.tprm_q_question q ON q.question_id = r.question_id
                                       WHERE r.dd_id = @dd AND q.safeguard_code = s.safeguard_code))));

    EXEC grac_practice.sp_tprm_residual_calculate @organization_id, @eng, @actor;
    DECLARE @detail NVARCHAR(2000) = CONCAT(N'Evidence "', @title, N'": ', @action, CASE WHEN @note IS NULL THEN N'' ELSE CONCAT(N' - ', @note) END);
    EXEC grac_practice.sp_tprm_engagement_event @eng, N'EVIDENCE_REVIEWED', NULL, NULL, @detail, @actor_employee_id, @actor;
    SELECT @tprm_evidence_id AS TprmEvidenceId, @action AS Result;
END
GO

-- =====================================================================
-- 9. Findings (deficiencies, conditions, exceptions) and remediation
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_finding_save
    @organization_id             BIGINT,
    @finding_id                  BIGINT         = NULL,
    @engagement_id               BIGINT         = NULL,
    @finding_kind                NVARCHAR(20)   = N'DEFICIENCY',
    @title                       NVARCHAR(300),
    @description                 NVARCHAR(2000) = NULL,
    @severity_code               NVARCHAR(60),
    @dimension_code              NVARCHAR(60)   = NULL,
    @treatment_action_code       NVARCHAR(60)   = NULL,
    @owner_employee_id           BIGINT         = NULL,
    @due_dt                      DATE           = NULL,
    @is_mandatory_for_activation BIT            = NULL,   -- NULL: conditions block activation, other findings do not
    @exception_until             DATE           = NULL,
    @custom_json                 NVARCHAR(MAX)  = NULL,
    @expected_record_version     BIGINT         = NULL,
    @actor_employee_id           BIGINT         = NULL,
    @actor                       NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @title = NULLIF(LTRIM(RTRIM(@title)), N'');
    IF @title IS NULL THROW 57742, 'Give the finding a title.', 1;
    IF @finding_kind NOT IN (N'DEFICIENCY', N'CONDITION', N'EXCEPTION') THROW 57743, 'Unknown finding type.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                    WHERE list_code = N'FINDING_SEVERITY' AND value_code = @severity_code)
        THROW 57744, 'Choose a severity from the list.', 1;
    IF @treatment_action_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_library_effective(@organization_id)
                    WHERE library_code = N'TREATMENT_ACTION' AND item_code = @treatment_action_code)
        THROW 57745, 'Choose a treatment action from the library.', 1;
    IF @owner_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                    WHERE employee_id = @owner_employee_id AND organization_id = @organization_id AND status = N'Active')
        THROW 57746, 'The owner must be an active employee of this organization.', 1;
    IF @finding_kind = N'EXCEPTION' AND @exception_until IS NULL
        THROW 57747, 'An exception is time-bound: give the date it ends.', 1;

    DECLARE @id BIGINT = @finding_id, @stage NVARCHAR(30), @created BIT = 0;
    IF @id IS NOT NULL
    BEGIN
        DECLARE @rv BIGINT, @status NVARCHAR(20);
        SELECT @rv = CONVERT(BIGINT, record_version), @engagement_id = engagement_id, @status = status
        FROM grac_practice.tprm_finding WHERE finding_id = @id AND organization_id = @organization_id;
        IF @rv IS NULL THROW 57748, 'That finding was not found.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 57749, 'Someone else changed this finding. Reload and try again.', 1;
        IF @status IN (N'CLOSED', N'WAIVED', N'CANCELLED') THROW 57750, 'A closed finding cannot be changed. Reopen it first.', 1;
    END
    SELECT @stage = stage_code FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @stage IS NULL THROW 57700, 'That engagement was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57730, 'A closed engagement cannot be changed.', 1;

    IF @due_dt IS NULL AND @treatment_action_code IS NOT NULL
        SELECT @due_dt = CASE WHEN default_due_days > 0 THEN DATEADD(DAY, default_due_days, CONVERT(DATE, SYSUTCDATETIME())) END
        FROM grac_practice.fn_tprm_library_effective(@organization_id)
        WHERE library_code = N'TREATMENT_ACTION' AND item_code = @treatment_action_code;

    BEGIN TRAN;
    IF @id IS NULL
    BEGIN
        DECLARE @number NVARCHAR(20), @dd BIGINT;
        SELECT @dd = dd_id FROM grac_practice.fn_tprm_current_dd(@engagement_id);
        EXEC grac_practice.sp_tprm_next_number @organization_id, N'TPF-', @number OUTPUT;
        INSERT grac_practice.tprm_finding
            (organization_id, engagement_id, dd_id, finding_number, finding_kind, source_kind, is_automatic, title, description,
             severity_code, dimension_code, treatment_action_code, owner_employee_id, due_dt, is_mandatory_for_activation,
             exception_until, status, entered_by)
        VALUES (@organization_id, @engagement_id, @dd, @number, @finding_kind, N'MANUAL', 0, @title, @description, @severity_code,
                @dimension_code, @treatment_action_code, @owner_employee_id, @due_dt,
                CASE WHEN @finding_kind = N'CONDITION' THEN ISNULL(@is_mandatory_for_activation, 1) ELSE ISNULL(@is_mandatory_for_activation, 0) END,
                @exception_until, N'OPEN', @actor);
        SET @id = SCOPE_IDENTITY();
        SET @created = 1;
    END
    ELSE
        UPDATE grac_practice.tprm_finding
           SET finding_kind = @finding_kind, title = @title, description = @description, severity_code = @severity_code,
               dimension_code = @dimension_code, treatment_action_code = @treatment_action_code, owner_employee_id = @owner_employee_id,
               due_dt = @due_dt, is_mandatory_for_activation = ISNULL(@is_mandatory_for_activation, 0), exception_until = @exception_until,
               is_automatic = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE finding_id = @id;
    DECLARE @roles NVARCHAR(600) = (SELECT r.role_name FROM grac_practice.organization_employee e
                                     JOIN grac_practice.organization_role r ON r.role_id = e.role_id WHERE e.employee_id = @actor_employee_id);
    EXEC grac_practice.sp_tprm_custom_values_save @organization_id, N'FINDING', @id, @custom_json, @roles, 0, @actor;
    COMMIT;

    EXEC grac_practice.sp_tprm_residual_calculate @organization_id, @engagement_id, @actor;
    DECLARE @detail NVARCHAR(2000) = CONCAT(@finding_kind, N' ', CASE WHEN @created = 1 THEN N'recorded' ELSE N'updated' END, N': ', @title);
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'FINDING_SAVED', @stage, @stage, @detail, @actor_employee_id, @actor;
    SELECT @id AS FindingId, CASE WHEN @created = 1 THEN N'CREATED' ELSE N'SAVED' END AS Result;
END
GO

-- START (in progress) | CLOSE (remediated, note) | WAIVE (accepted by an
-- approver, note -- an EXCEPTION is approved until exception_until) |
-- REOPEN | CANCEL | RAISE_GAP (to the GRAC Gap Register, once).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_finding_action
    @organization_id   BIGINT,
    @finding_id        BIGINT,
    @action            NVARCHAR(20),
    @note              NVARCHAR(2000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @eng BIGINT, @status NVARCHAR(20), @kind NVARCHAR(20), @title NVARCHAR(300), @gap BIGINT, @number NVARCHAR(20),
            @sev NVARCHAR(60), @owner BIGINT, @due DATE, @desc NVARCHAR(2000), @until DATE;
    SELECT @eng = engagement_id, @status = status, @kind = finding_kind, @title = title, @gap = custom_gap_id, @number = finding_number,
           @sev = severity_code, @owner = owner_employee_id, @due = due_dt, @desc = description, @until = exception_until
    FROM grac_practice.tprm_finding WHERE finding_id = @finding_id AND organization_id = @organization_id;
    IF @eng IS NULL THROW 57748, 'That finding was not found.', 1;
    DECLARE @stage NVARCHAR(30) = (SELECT stage_code FROM grac_practice.tprm_engagement WHERE engagement_id = @eng);
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');

    IF @action = N'START'
    BEGIN
        IF @status <> N'OPEN' THROW 57751, 'Only an open finding can be started.', 1;
        UPDATE grac_practice.tprm_finding SET status = N'IN_PROGRESS', status_note = COALESCE(@note, status_note), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE finding_id = @finding_id;
    END
    ELSE IF @action IN (N'CLOSE', N'WAIVE', N'CANCEL')
    BEGIN
        IF @status NOT IN (N'OPEN', N'IN_PROGRESS') THROW 57752, 'The finding is already closed.', 1;
        IF @note IS NULL THROW 57753, 'Give a note for the record.', 1;
        IF @action = N'WAIVE' AND @kind = N'EXCEPTION' AND (@until IS NULL OR @until < CONVERT(DATE, SYSUTCDATETIME()))
            THROW 57754, 'An exception needs an end date in the future before it can be approved.', 1;
        UPDATE grac_practice.tprm_finding
           SET status = CASE @action WHEN N'CLOSE' THEN N'CLOSED' WHEN N'WAIVE' THEN N'WAIVED' ELSE N'CANCELLED' END,
               status_note = @note, closed_by_employee_id = @actor_employee_id, closed_dt = SYSUTCDATETIME(),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE finding_id = @finding_id;
    END
    ELSE IF @action = N'REOPEN'
    BEGIN
        IF @status NOT IN (N'CLOSED', N'WAIVED', N'CANCELLED') THROW 57755, 'Only a closed finding can be reopened.', 1;
        IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57730, 'A closed engagement cannot be changed.', 1;
        UPDATE grac_practice.tprm_finding SET status = N'OPEN', status_note = @note, closed_by_employee_id = NULL, closed_dt = NULL,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE finding_id = @finding_id;
    END
    ELSE IF @action = N'RAISE_GAP'
    BEGIN
        IF @gap IS NOT NULL THROW 57756, 'This finding is already in the Gap Register.', 1;
        IF @status NOT IN (N'OPEN', N'IN_PROGRESS') THROW 57752, 'The finding is already closed.', 1;
        DECLARE @org BIGINT = @organization_id, @gtitle NVARCHAR(250) = LEFT(CONCAT(N'[TPRM ', @number, N'] ', @title), 250);
        DECLARE @priority NVARCHAR(30) = CASE WHEN @sev IN (N'LOW', N'MEDIUM', N'HIGH', N'CRITICAL')
                                              THEN UPPER(LEFT(@sev, 1)) + LOWER(SUBSTRING(@sev, 2, 20)) ELSE N'Medium' END;
        DECLARE @gdesc NVARCHAR(MAX) = CONCAT(N'Raised from third-party engagement finding ', @number, N'. ', @desc);
        DECLARE @src_type NVARCHAR(60) = N'TprmFinding', @module NVARCHAR(30) = N'Custom';
        DECLARE @new_gap BIGINT;
        -- sp_custom_gap_save manages its own transaction; it is called
        -- outside ours and the finding is updated after it succeeds.
        EXEC grac_practice.sp_custom_gap_save
             @organization_id = @org, @gap_source_module_code = @module, @source_reference_type = @src_type,
             @source_reference_id = @finding_id, @title = @gtitle, @description = @gdesc, @priority = @priority,
             @owner_employee_id = @owner, @due_date = @due, @actor = @actor, @custom_gap_id_out = @new_gap OUTPUT;
        UPDATE grac_practice.tprm_finding SET custom_gap_id = @new_gap, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE finding_id = @finding_id;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link WHERE engagement_id = @eng AND link_kind = N'GAP' AND target_id = @new_gap AND status = N'Active')
            INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source,
                                                       is_validated, validated_by, validated_dt, entered_by)
            VALUES (@eng, @organization_id, N'GAP', @new_gap, @gtitle, N'ESCALATION', 1, @actor, SYSUTCDATETIME(), @actor);
    END
    ELSE THROW 57757, 'Unknown finding action.', 1;

    EXEC grac_practice.sp_tprm_residual_calculate @organization_id, @eng, @actor;
    DECLARE @detail NVARCHAR(2000) = CONCAT(@number, N' ', @action, CASE WHEN @note IS NULL THEN N'' ELSE CONCAT(N': ', @note) END);
    EXEC grac_practice.sp_tprm_engagement_event @eng, N'FINDING_ACTION', @stage, @stage, @detail, @actor_employee_id, @actor;
    SELECT @finding_id AS FindingId, @action AS Result;
END
GO

-- =====================================================================
-- 10. Decision and approval (BRD step 4)
-- =====================================================================
-- Result sets: 1 decision pack  2 approval rule that applies now
--   3 decisions  4 approvals  5 open findings  6 Risk Centre links
--   7 decision outcomes allowed  8 active delegations to the caller
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_decision_get
    @organization_id    BIGINT,
    @engagement_id      BIGINT,
    @caller_employee_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id)
        THROW 57700, 'That engagement was not found.', 1;
    DECLARE @band_rank INT, @crit_rank INT, @dd BIGINT, @dd_status NVARCHAR(20);
    SELECT @band_rank = band_rank, @crit_rank = criticality_rank FROM grac_practice.fn_tprm_engagement_ranks(@engagement_id);
    SELECT @dd = dd_id, @dd_status = status FROM grac_practice.fn_tprm_current_dd(@engagement_id);

    SELECT e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode, e.engagement_title AS EngagementTitle,
           t.legal_name AS ThirdPartyName, e.stage_code AS StageCode, e.scope_description AS ScopeDescription,
           e.service_description AS ServiceDescription, e.service_criticality_code AS CriticalityCode,
           e.inherent_score AS InherentScore, e.inherent_band_code AS InherentBandCode, ib.band_name AS InherentBand, ib.color_hex AS InherentBandColor,
           e.residual_score AS ResidualScore, e.residual_band_code AS ResidualBandCode, rb.band_name AS ResidualBand, rb.color_hex AS ResidualBandColor,
           e.dd_tier_code AS DdTierCode, @dd AS DdId, @dd_status AS DdStatus, @band_rank AS BandRank, @crit_rank AS CriticalityRank,
           (SELECT COUNT(*) FROM grac_practice.tprm_finding f WHERE f.engagement_id = e.engagement_id AND f.status IN (N'OPEN', N'IN_PROGRESS')) AS OpenFindings,
           (SELECT COUNT(*) FROM grac_practice.tprm_finding f
             JOIN grac_practice.fn_tprm_reference_effective(@organization_id) sv ON sv.list_code = N'FINDING_SEVERITY' AND sv.value_code = f.severity_code
             WHERE f.engagement_id = e.engagement_id AND f.status IN (N'OPEN', N'IN_PROGRESS') AND sv.rank_no >= 3) AS OpenHighFindings,
           (SELECT COUNT(*) FROM grac_practice.tprm_safeguard_assessment s WHERE s.dd_id = @dd AND s.is_applicable = 1) AS ApplicableSafeguards,
           (SELECT COUNT(*) FROM grac_practice.tprm_safeguard_assessment s WHERE s.dd_id = @dd AND s.is_applicable = 1 AND s.is_verified = 1) AS VerifiedSafeguards,
           (SELECT COUNT(*) FROM grac_practice.tprm_evidence_link l WHERE l.engagement_id = e.engagement_id AND l.status = N'Active' AND l.review_status = N'PENDING') AS PendingEvidence,
           e.acceptance_until AS AcceptanceUntil, e.next_review_dt AS NextReviewDt,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_decision d WHERE d.engagement_id = e.engagement_id AND d.status = N'PENDING') THEN 1 ELSE 0 END AS BIT) AS HasPendingDecision,
           CAST(CASE WHEN @dd_status = N'COMPLETED' AND e.stage_code IN (N'DUE_DILIGENCE', N'APPROVED', N'ONBOARDING', N'ACTIVE', N'SUSPENDED')
                      AND EXISTS (SELECT 1 FROM grac_practice.tprm_dd_assessment x WHERE x.dd_id = @dd AND x.risk_assessment_id = e.current_risk_assessment_id)
                      AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_decision d WHERE d.engagement_id = e.engagement_id AND d.status = N'PENDING')
                      AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_decision d WHERE d.engagement_id = e.engagement_id AND d.status = N'DECIDED'
                                        AND d.risk_assessment_id = e.current_risk_assessment_id AND d.dd_id = @dd)
                     THEN 1 ELSE 0 END AS BIT) AS CanSubmit
    FROM grac_practice.tprm_engagement e
    JOIN grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
    LEFT JOIN grac_practice.tprm_rm_band ib ON ib.version_id = e.risk_model_version_id AND ib.band_code = e.inherent_band_code
    LEFT JOIN grac_practice.tprm_rm_band rb ON rb.version_id = e.risk_model_version_id AND rb.band_code = e.residual_band_code
    WHERE e.engagement_id = @engagement_id;

    SELECT r.rule_code AS RuleCode, r.rule_name AS RuleName, r.approval_levels AS ApprovalLevels,
           r.level1_role_name AS Level1RoleName, r.level2_role_name AS Level2RoleName, r.level3_role_name AS Level3RoleName,
           r.sod_required AS SodRequired, r.escalate_to_risk_centre AS EscalateToRiskCentre,
           r.max_acceptance_months AS MaxAcceptanceMonths, r.allowed_decision_codes AS AllowedDecisionCodes, r.origin AS Origin
    FROM grac_practice.fn_tprm_match_approval_rule(@organization_id, @band_rank, @crit_rank) r;

    SELECT d.decision_id AS DecisionId, d.decision_no AS DecisionNo, d.status AS Status, d.prior_stage_code AS PriorStageCode,
           d.approval_rule_code AS ApprovalRuleCode, d.required_levels AS RequiredLevels, d.sod_required AS SodRequired,
           d.escalation_recommended AS EscalationRecommended, d.inherent_score AS InherentScore, d.inherent_band_code AS InherentBandCode,
           d.residual_score AS ResidualScore, d.residual_band_code AS ResidualBandCode, d.open_findings_count AS OpenFindingsCount,
           d.submission_note AS SubmissionNote, se.employee_name AS SubmittedByName, d.submitted_by_employee_id AS SubmittedByEmployeeId,
           d.submitted_dt AS SubmittedDt, d.outcome_code AS OutcomeCode, d.outcome_meaning AS OutcomeMeaning, ov.label AS OutcomeLabel,
           d.rationale AS Rationale, d.risk_accepted AS RiskAccepted, d.acceptance_until AS AcceptanceUntil,
           d.mandatory_review_dt AS MandatoryReviewDt, de.employee_name AS DecidedByName, d.decided_dt AS DecidedDt
    FROM grac_practice.tprm_decision d
    LEFT JOIN grac_practice.organization_employee se ON se.employee_id = d.submitted_by_employee_id
    LEFT JOIN grac_practice.organization_employee de ON de.employee_id = d.decided_by_employee_id
    LEFT JOIN grac_practice.fn_tprm_reference_effective(@organization_id) ov ON ov.list_code = N'DECISION' AND ov.value_code = d.outcome_code
    WHERE d.engagement_id = @engagement_id
    ORDER BY d.decision_no DESC;

    SELECT a.approval_id AS ApprovalId, a.decision_id AS DecisionId, a.level_no AS LevelNo, a.required_role_name AS RequiredRoleName,
           a.status AS Status, ae.employee_name AS ApproverName, a.approver_employee_id AS ApproverEmployeeId,
           be.employee_name AS OnBehalfOfName, a.comment AS Comment, a.decided_dt AS DecidedDt,
           CAST(CASE WHEN a.status = N'PENDING' AND a.level_no = (SELECT MIN(x.level_no) FROM grac_practice.tprm_decision_approval x
                                                                WHERE x.decision_id = a.decision_id AND x.status = N'PENDING')
                     THEN 1 ELSE 0 END AS BIT) AS IsCurrent
    FROM grac_practice.tprm_decision_approval a
    JOIN grac_practice.tprm_decision d ON d.decision_id = a.decision_id
    LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = a.approver_employee_id
    LEFT JOIN grac_practice.organization_employee be ON be.employee_id = a.on_behalf_of_employee_id
    WHERE d.engagement_id = @engagement_id
    ORDER BY a.decision_id DESC, a.level_no;

    SELECT f.finding_id AS FindingId, f.finding_number AS FindingNumber, f.finding_kind AS FindingKind, f.title AS Title,
           f.severity_code AS SeverityCode, f.status AS Status, f.due_dt AS DueDt, f.is_mandatory_for_activation AS IsMandatoryForActivation,
           f.exception_until AS ExceptionUntil
    FROM grac_practice.tprm_finding f
    WHERE f.engagement_id = @engagement_id AND f.status IN (N'OPEN', N'IN_PROGRESS')
    ORDER BY f.finding_id;

    SELECT l.link_id AS LinkId, l.link_kind AS LinkKind, l.target_id AS TargetId, l.target_label AS TargetLabel,
           l.link_source AS LinkSource, l.entered_dt AS LinkedDt,
           CASE WHEN l.link_kind = N'RISK_CANDIDATE' THEN rc.status_code ELSE rr.status_code END AS TargetStatus
    FROM grac_practice.tprm_engagement_link l
    LEFT JOIN grac_practice.risk_candidate rc ON l.link_kind = N'RISK_CANDIDATE' AND rc.risk_candidate_id = l.target_id
    LEFT JOIN grac_practice.risk_register rr ON l.link_kind = N'ENTERPRISE_RISK' AND rr.risk_register_id = l.target_id
    WHERE l.engagement_id = @engagement_id AND l.status = N'Active' AND l.link_kind IN (N'RISK_CANDIDATE', N'ENTERPRISE_RISK');

    SELECT v.value_code AS ValueCode, v.label AS Label, v.meaning_code AS MeaningCode
    FROM grac_practice.fn_tprm_reference_effective(@organization_id) v
    OUTER APPLY (SELECT TOP (1) r.allowed_decision_codes FROM grac_practice.fn_tprm_match_approval_rule(@organization_id, @band_rank, @crit_rank) r) ar
    WHERE v.list_code = N'DECISION'
      AND (ar.allowed_decision_codes IS NULL OR v.meaning_code = N'RETURN'
           OR EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(ar.allowed_decision_codes) x WHERE x.code = v.value_code))
    ORDER BY v.display_order;

    SELECT g.delegation_id AS DelegationId, g.from_employee_id AS FromEmployeeId, f.employee_name AS FromEmployeeName,
           g.valid_from AS ValidFrom, g.valid_to AS ValidTo
    FROM grac_practice.tprm_approval_delegation g
    JOIN grac_practice.organization_employee f ON f.employee_id = g.from_employee_id
    WHERE g.organization_id = @organization_id AND g.to_employee_id = @caller_employee_id AND g.status = N'Active'
      AND CONVERT(DATE, SYSUTCDATETIME()) BETWEEN g.valid_from AND g.valid_to;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_decision_submit
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @submission_note   NVARCHAR(2000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30), @assessment BIGINT, @tp BIGINT;
    SELECT @stage = stage_code, @assessment = current_risk_assessment_id, @tp = third_party_id
    FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @stage IS NULL THROW 57700, 'That engagement was not found.', 1;
    IF @stage NOT IN (N'DUE_DILIGENCE', N'APPROVED', N'ONBOARDING', N'ACTIVE', N'SUSPENDED')
        THROW 57760, 'A decision can be requested after due diligence (or again after a reassessment).', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_decision WHERE engagement_id = @engagement_id AND status = N'PENDING')
        THROW 57761, 'A decision is already pending.', 1;
    DECLARE @dd BIGINT, @dd_status NVARCHAR(20);
    SELECT @dd = dd_id, @dd_status = status FROM grac_practice.fn_tprm_current_dd(@engagement_id);
    IF @dd IS NULL OR @dd_status <> N'COMPLETED' THROW 57762, 'Complete the due diligence first.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_dd_assessment WHERE dd_id = @dd AND risk_assessment_id = @assessment)
        THROW 57825, 'The due diligence was done for an earlier risk assessment. Start a new due-diligence round for the current one.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_decision WHERE engagement_id = @engagement_id AND status = N'DECIDED'
                 AND risk_assessment_id = @assessment AND dd_id = @dd AND outcome_meaning <> N'RETURN')
        THROW 57763, 'This assessment has already been decided. Reassess or run a new due-diligence round first.', 1;

    DECLARE @band_rank INT, @crit_rank INT;
    SELECT @band_rank = band_rank, @crit_rank = criticality_rank FROM grac_practice.fn_tprm_engagement_ranks(@engagement_id);
    DECLARE @rule_code NVARCHAR(60), @levels INT, @l1 NVARCHAR(120), @l2 NVARCHAR(120), @l3 NVARCHAR(120), @sod BIT, @esc BIT, @snapshot NVARCHAR(MAX);
    SELECT @rule_code = rule_code, @levels = approval_levels, @l1 = level1_role_name, @l2 = level2_role_name, @l3 = level3_role_name,
           @sod = sod_required, @esc = escalate_to_risk_centre,
           @snapshot = (SELECT r2.rule_code, r2.rule_name, r2.approval_levels, r2.level1_role_name, r2.level2_role_name, r2.level3_role_name,
                               r2.sod_required, r2.escalate_to_risk_centre, r2.max_acceptance_months, r2.allowed_decision_codes, r2.origin
                        FROM grac_practice.fn_tprm_match_approval_rule(@organization_id, @band_rank, @crit_rank) r2
                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM grac_practice.fn_tprm_match_approval_rule(@organization_id, @band_rank, @crit_rank);
    IF @rule_code IS NULL THROW 57764, 'No approval rule applies. Add a catch-all approval rule in TPRM Configuration.', 1;

    DECLARE @id BIGINT, @no INT;
    BEGIN TRAN;
        SELECT @no = ISNULL(MAX(decision_no), 0) + 1 FROM grac_practice.tprm_decision WITH (UPDLOCK, HOLDLOCK) WHERE engagement_id = @engagement_id;
        INSERT grac_practice.tprm_decision
            (organization_id, engagement_id, risk_assessment_id, dd_id, decision_no, prior_stage_code, status, approval_rule_code,
             rule_snapshot_json, required_levels, sod_required, escalation_recommended, inherent_score, inherent_band_code,
             residual_score, residual_band_code, open_findings_count, submission_note, submitted_by_employee_id)
        SELECT @organization_id, @engagement_id, @assessment, @dd, @no, @stage, N'PENDING', @rule_code, @snapshot, @levels, @sod, @esc,
               e.inherent_score, e.inherent_band_code, e.residual_score, e.residual_band_code,
               (SELECT COUNT(*) FROM grac_practice.tprm_finding f WHERE f.engagement_id = @engagement_id AND f.status IN (N'OPEN', N'IN_PROGRESS')),
               @submission_note, @actor_employee_id
        FROM grac_practice.tprm_engagement e WHERE e.engagement_id = @engagement_id;
        SET @id = SCOPE_IDENTITY();
        INSERT grac_practice.tprm_decision_approval (decision_id, level_no, required_role_name, status)
        SELECT @id, x.n, x.r, N'PENDING' FROM (VALUES (1, @l1), (2, @l2), (3, @l3)) x(n, r) WHERE x.n <= @levels;
        UPDATE grac_practice.tprm_engagement SET stage_code = N'PENDING_DECISION', stage_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @engagement_id;
    COMMIT;

    DECLARE @detail NVARCHAR(2000) = CONCAT(N'Decision ', @no, N' requested under rule ', @rule_code, N' (', @levels, N' approval level',
                                            CASE WHEN @levels > 1 THEN N's' ELSE N'' END, N').');
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'DECISION_SUBMITTED', @stage, N'PENDING_DECISION', @detail, @actor_employee_id, @actor;
    SELECT @id AS DecisionId, N'SUBMITTED' AS Result;
END
GO

-- Act on the current approval level.
--   APPROVE  intermediate level: passes to the next level.
--            final level: @outcome_code with meaning APPROVE or
--            APPROVE_WITH_CONDITIONS (conditions given or already open),
--            optional time-bound risk acceptance (<= the rule's maximum)
--            and the mandatory review date.
--   REJECT   ends the decision (outcome meaning REJECT).
--   RETURN   ends the decision (meaning RETURN); due diligence reopens.
-- Segregation of duties (rule): the approver is not the submitter, the
-- assessor, the due-diligence assessor, nor an approver of an earlier
-- level. Role: when the organization has a role with the level's role
-- name, the approver must hold it (organization_employee.role_id) or act
-- under an active delegation from someone who does.
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
         WHERE approval_id = @approval;

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

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_decision_withdraw
    @organization_id   BIGINT,
    @decision_id       BIGINT,
    @note              NVARCHAR(1000) = NULL,
    @caller_is_admin   BIT            = 0,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @eng BIGINT, @status NVARCHAR(20), @submitter BIGINT, @prior NVARCHAR(30);
    SELECT @eng = engagement_id, @status = status, @submitter = submitted_by_employee_id, @prior = prior_stage_code
    FROM grac_practice.tprm_decision WHERE decision_id = @decision_id AND organization_id = @organization_id;
    IF @eng IS NULL THROW 57766, 'That decision was not found.', 1;
    IF @status <> N'PENDING' THROW 57767, 'That decision is no longer pending.', 1;
    IF ISNULL(@caller_is_admin, 0) = 0 AND ISNULL(@submitter, -1) <> ISNULL(@actor_employee_id, -2)
        THROW 57783, 'Only the person who requested the decision can withdraw it.', 1;
    BEGIN TRAN;
        UPDATE grac_practice.tprm_decision SET status = N'WITHDRAWN', rationale = @note WHERE decision_id = @decision_id;
        UPDATE grac_practice.tprm_decision_approval SET status = N'WITHDRAWN' WHERE decision_id = @decision_id AND status = N'PENDING';
        UPDATE grac_practice.tprm_engagement SET stage_code = @prior, stage_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @eng;
    COMMIT;
    EXEC grac_practice.sp_tprm_engagement_event @eng, N'DECISION_WITHDRAWN', N'PENDING_DECISION', @prior, @note, @actor_employee_id, @actor;
    SELECT @decision_id AS DecisionId, N'WITHDRAWN' AS Result;
END
GO

-- Risk Centre (BRD 4 / 7, acceptance 12): ESCALATE raises ONE risk
-- candidate for the engagement through sp_risk_candidate_create (its own
-- idempotency returns the open one instead of a duplicate); LINK records
-- an existing enterprise risk. Nothing is copied automatically.
-- sp_risk_candidate_create returns its own row first; this procedure's
-- result is the LAST result set.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_risk_escalate
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @mode              NVARCHAR(20),          -- ESCALATE | LINK
    @risk_register_id  BIGINT         = NULL,
    @candidate_title   NVARCHAR(300)  = NULL,
    @summary           NVARCHAR(MAX)  = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30), @code NVARCHAR(20), @title NVARCHAR(250), @tp_name NVARCHAR(250), @band NVARCHAR(60), @score DECIMAL(6,2);
    SELECT @stage = e.stage_code, @code = e.engagement_code, @title = e.engagement_title, @tp_name = t.legal_name,
           @band = COALESCE(e.residual_band_code, e.inherent_band_code), @score = COALESCE(e.residual_score, e.inherent_score)
    FROM grac_practice.tprm_engagement e JOIN grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
    WHERE e.engagement_id = @engagement_id AND e.organization_id = @organization_id;
    IF @stage IS NULL THROW 57700, 'That engagement was not found.', 1;

    IF @mode = N'LINK'
    BEGIN
        IF @risk_register_id IS NULL THROW 57784, 'Choose the enterprise risk to link.', 1;
        DECLARE @org BIGINT = @organization_id, @eid BIGINT = @engagement_id, @kind NVARCHAR(30) = N'ENTERPRISE_RISK', @src NVARCHAR(20) = N'MANUAL';
        DECLARE @link_note NVARCHAR(1000) = LEFT(@summary, 1000);
        EXEC grac_practice.sp_tprm_link_save @org, @eid, @kind, @risk_register_id, @link_note, @src, @actor_employee_id, @actor;
        RETURN;   -- sp_tprm_link_save returned the row
    END
    IF @mode <> N'ESCALATE' THROW 57785, 'Unknown escalation mode.', 1;

    DECLARE @ctitle NVARCHAR(300) = COALESCE(NULLIF(LTRIM(RTRIM(@candidate_title)), N''), LEFT(CONCAT(N'Third-party risk: ', @tp_name, N' - ', @title), 300));
    DECLARE @csummary NVARCHAR(MAX) = COALESCE(@summary, CONCAT(N'Escalated from TPRM engagement ', @code, N' (', @tp_name, N'). Current risk band ',
                                                                @band, N', score ', @score, N'.'));
    DECLARE @src_type NVARCHAR(40) = N'ThirdParty', @org2 BIGINT = @organization_id, @ref NVARCHAR(200) = @code,
            @caller NVARCHAR(100) = @actor, @eid2 BIGINT = @engagement_id, @requester BIGINT = @actor_employee_id;
    EXEC grac_practice.sp_risk_candidate_create
         @candidate_title = @ctitle, @candidate_summary = @csummary, @requested_by_employee_id = @requester,
         @caller_display_name = @caller, @organization_id = @org2, @source_type_code = @src_type,
         @source_record_id = @eid2, @source_reference = @ref, @source_description = @csummary;

    DECLARE @candidate BIGINT, @cnumber NVARCHAR(20);
    SELECT TOP (1) @candidate = risk_candidate_id, @cnumber = candidate_number FROM grac_practice.risk_candidate
     WHERE source_type_code = N'ThirdParty' AND source_record_id = @engagement_id ORDER BY risk_candidate_id DESC;
    IF @candidate IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link WHERE engagement_id = @engagement_id
                         AND link_kind = N'RISK_CANDIDATE' AND target_id = @candidate AND status = N'Active')
    BEGIN
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source,
                                                   is_validated, validated_by, validated_dt, entered_by)
        VALUES (@engagement_id, @organization_id, N'RISK_CANDIDATE', @candidate, LEFT(CONCAT(@cnumber, N' - ', @ctitle), 400), N'ESCALATION',
                1, @actor, SYSUTCDATETIME(), @actor);
        DECLARE @detail NVARCHAR(2000) = CONCAT(N'Escalated to the Risk Centre as candidate ', @cnumber, N'.');
        EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'RISK_ESCALATED', @stage, @stage, @detail, @actor_employee_id, @actor;
    END
    SELECT @candidate AS RiskCandidateId, @cnumber AS CandidateNumber, N'ESCALATED' AS Result;
END
GO

-- =====================================================================
-- 11. Onboarding and operationalisation (BRD step 5)
-- =====================================================================
-- Internal: build the check items of a phase from the effective list.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_checks_create
    @organization_id BIGINT,
    @engagement_id   BIGINT,
    @phase           NVARCHAR(20),
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    INSERT grac_practice.tprm_onboarding_item (engagement_id, organization_id, phase, check_code, check_label, is_mandatory, status, entered_by)
    SELECT @engagement_id, @organization_id, @phase, v.value_code, v.label, v.is_mandatory, N'PENDING', @actor
    FROM grac_practice.fn_tprm_reference_effective(@organization_id) v
    WHERE v.list_code = CASE @phase WHEN N'EXIT' THEN N'EXIT_CHECK' ELSE N'ONBOARDING_CHECK' END
      AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_onboarding_item i
                       WHERE i.engagement_id = @engagement_id AND i.phase = @phase AND i.check_code = v.value_code);
END
GO

-- Internal: snapshot the PROPOSED exposure once (what was assessed).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_snapshot_proposed
    @organization_id BIGINT,
    @engagement_id   BIGINT,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_exposure_snapshot WHERE engagement_id = @engagement_id AND snapshot_kind = N'PROPOSED') RETURN;
    INSERT grac_practice.tprm_exposure_snapshot (engagement_id, organization_id, snapshot_kind, summary_json, items_json, taken_by)
    VALUES (@engagement_id, @organization_id, N'PROPOSED',
            (SELECT s.item_kind AS [key], COUNT(*) AS [count] FROM grac_practice.tprm_engagement_scope s
              WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active'
              GROUP BY s.item_kind FOR JSON PATH),
            (SELECT s.item_kind AS kind, s.ref_id AS refId, s.item_code AS code, s.item_name AS name FROM grac_practice.tprm_engagement_scope s
              WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active' FOR JSON PATH),
            @actor);
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_onboarding_start
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30) = (SELECT stage_code FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id);
    IF @stage IS NULL THROW 57700, 'That engagement was not found.', 1;
    IF @stage <> N'APPROVED' THROW 57786, 'Onboarding starts once the engagement is approved.', 1;
    BEGIN TRAN;
        EXEC grac_practice.sp_tprm_checks_create @organization_id, @engagement_id, N'ONBOARDING', @actor;
        EXEC grac_practice.sp_tprm_snapshot_proposed @organization_id, @engagement_id, @actor;
        UPDATE grac_practice.tprm_engagement SET stage_code = N'ONBOARDING', stage_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @engagement_id;
    COMMIT;
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'ONBOARDING_STARTED', @stage, N'ONBOARDING', NULL, @actor_employee_id, @actor;
    SELECT @engagement_id AS EngagementId, N'ONBOARDING' AS Result;
END
GO

-- Result sets: 1 readiness  2 onboarding checks  3 exit checks
--   4 conditions  5 deviations  6 snapshots  7 reviews  8 review rule
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_onboarding_get
    @organization_id BIGINT,
    @engagement_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id)
        THROW 57700, 'That engagement was not found.', 1;
    DECLARE @band_rank INT, @crit_rank INT;
    SELECT @band_rank = band_rank, @crit_rank = criticality_rank FROM grac_practice.fn_tprm_engagement_ranks(@engagement_id);

    SELECT e.engagement_id AS EngagementId, e.stage_code AS StageCode, e.contract_id AS ContractId, e.contract_reference AS ContractReference,
           (SELECT COUNT(*) FROM grac_practice.tprm_onboarding_item i WHERE i.engagement_id = e.engagement_id AND i.phase = N'ONBOARDING'
              AND i.is_mandatory = 1 AND i.status = N'PENDING') AS PendingMandatoryChecks,
           (SELECT COUNT(*) FROM grac_practice.tprm_finding f WHERE f.engagement_id = e.engagement_id AND f.finding_kind = N'CONDITION'
              AND f.is_mandatory_for_activation = 1 AND f.status IN (N'OPEN', N'IN_PROGRESS')) AS OpenMandatoryConditions,
           (SELECT COUNT(*) FROM grac_practice.tprm_engagement_deviation d WHERE d.engagement_id = e.engagement_id
              AND d.is_material = 1 AND d.status = N'OPEN') AS OpenMaterialDeviations,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_exposure_snapshot s WHERE s.engagement_id = e.engagement_id AND s.snapshot_kind = N'ACTUAL')
                     THEN 1 ELSE 0 END AS BIT) AS ExposureCompared,
           (SELECT COUNT(*) FROM grac_practice.tprm_engagement_scope s WHERE s.engagement_id = e.engagement_id AND s.exposure_mode = N'ACTUAL' AND s.status = N'Active') AS ActualScopeItems,
           (SELECT COUNT(*) FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = e.engagement_id AND l.status = N'Active'
              AND l.link_kind IN (N'PRACTICE_INSTANCE', N'DEPENDENCY', N'APPLICATION') AND l.is_validated = 0) AS UnvalidatedDependencyLinks,
           (SELECT COUNT(*) FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = e.engagement_id AND l.status = N'Active'
              AND l.link_kind IN (N'PRACTICE_INSTANCE', N'DEPENDENCY', N'APPLICATION') AND l.is_validated = 1) AS ValidatedDependencyLinks,
           e.next_review_dt AS NextReviewDt, e.last_review_dt AS LastReviewDt, e.acceptance_until AS AcceptanceUntil,
           e.actual_start_dt AS ActualStartDt, e.actual_end_dt AS ActualEndDt, e.proposed_end_dt AS ProposedEndDt, e.renewal_dt AS RenewalDt,
           e.reassessment_required AS ReassessmentRequired, e.reassessment_reason AS ReassessmentReason
    FROM grac_practice.tprm_engagement e WHERE e.engagement_id = @engagement_id;

    SELECT i.item_id AS ItemId, i.phase AS Phase, i.check_code AS CheckCode, i.check_label AS CheckLabel, i.is_mandatory AS IsMandatory,
           i.status AS Status, i.note AS Note, i.evidence_reference AS EvidenceReference, ce.employee_name AS CompletedByName,
           i.completed_dt AS CompletedDt
    FROM grac_practice.tprm_onboarding_item i
    LEFT JOIN grac_practice.organization_employee ce ON ce.employee_id = i.completed_by_employee_id
    WHERE i.engagement_id = @engagement_id AND i.phase = N'ONBOARDING' ORDER BY i.is_mandatory DESC, i.item_id;

    SELECT i.item_id AS ItemId, i.phase AS Phase, i.check_code AS CheckCode, i.check_label AS CheckLabel, i.is_mandatory AS IsMandatory,
           i.status AS Status, i.note AS Note, i.evidence_reference AS EvidenceReference, ce.employee_name AS CompletedByName,
           i.completed_dt AS CompletedDt
    FROM grac_practice.tprm_onboarding_item i
    LEFT JOIN grac_practice.organization_employee ce ON ce.employee_id = i.completed_by_employee_id
    WHERE i.engagement_id = @engagement_id AND i.phase = N'EXIT' ORDER BY i.is_mandatory DESC, i.item_id;

    SELECT f.finding_id AS FindingId, f.finding_number AS FindingNumber, f.title AS Title, f.severity_code AS SeverityCode,
           f.status AS Status, f.due_dt AS DueDt, f.is_mandatory_for_activation AS IsMandatoryForActivation, oe.employee_name AS OwnerName
    FROM grac_practice.tprm_finding f
    LEFT JOIN grac_practice.organization_employee oe ON oe.employee_id = f.owner_employee_id
    WHERE f.engagement_id = @engagement_id AND f.finding_kind = N'CONDITION' ORDER BY f.finding_id;

    SELECT d.deviation_id AS DeviationId, d.deviation_kind AS DeviationKind, d.item_kind AS ItemKind, d.item_name AS ItemName,
           d.is_material AS IsMaterial, d.status AS Status, d.decision_note AS DecisionNote, de.employee_name AS DecidedByName,
           d.decided_dt AS DecidedDt, d.entered_dt AS FoundDt
    FROM grac_practice.tprm_engagement_deviation d
    LEFT JOIN grac_practice.organization_employee de ON de.employee_id = d.decided_by_employee_id
    WHERE d.engagement_id = @engagement_id AND d.status <> N'SUPERSEDED' ORDER BY d.is_material DESC, d.deviation_id;

    SELECT s.snapshot_id AS SnapshotId, s.snapshot_kind AS SnapshotKind, s.summary_json AS SummaryJson, s.taken_by AS TakenBy, s.taken_dt AS TakenDt
    FROM grac_practice.tprm_exposure_snapshot s WHERE s.engagement_id = @engagement_id ORDER BY s.snapshot_id DESC;

    SELECT r.review_id AS ReviewId, r.review_number AS ReviewNumber, r.review_type AS ReviewType, r.trigger_code AS TriggerCode,
           r.trigger_detail AS TriggerDetail, r.due_dt AS DueDt, r.status AS Status, r.outcome_code AS OutcomeCode,
           r.outcome_note AS OutcomeNote, r.requires_reassessment AS RequiresReassessment, oe.employee_name AS OwnerName,
           r.completed_dt AS CompletedDt, r.raised_dt AS RaisedDt
    FROM grac_practice.tprm_review r
    LEFT JOIN grac_practice.organization_employee oe ON oe.employee_id = r.owner_employee_id
    WHERE r.engagement_id = @engagement_id ORDER BY CASE WHEN r.status = N'OPEN' THEN 0 ELSE 1 END, r.due_dt;

    SELECT r.rule_code AS RuleCode, r.rule_name AS RuleName, r.review_frequency_months AS ReviewFrequencyMonths,
           r.evidence_renewal_months AS EvidenceRenewalMonths, r.contract_expiry_alert_days AS ContractExpiryAlertDays,
           r.cert_expiry_alert_days AS CertExpiryAlertDays, r.review_lead_days AS ReviewLeadDays,
           r.reassessment_trigger_codes AS ReassessmentTriggerCodes, r.monitoring_note AS MonitoringNote
    FROM grac_practice.fn_tprm_match_review_rule(@organization_id, @band_rank, @crit_rank) r;
END
GO

-- DONE / NA (non-mandatory only) / REOPEN by the team; WAIVE (formal,
-- with a reason) by an authorized role -- the Web tier requires APPROVE.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_onboarding_item_action
    @organization_id    BIGINT,
    @item_id            BIGINT,
    @action             NVARCHAR(20),
    @note               NVARCHAR(1000) = NULL,
    @evidence_reference NVARCHAR(400)  = NULL,
    @actor_employee_id  BIGINT         = NULL,
    @actor              NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @eng BIGINT, @phase NVARCHAR(20), @mand BIT, @label NVARCHAR(300), @stage NVARCHAR(30);
    SELECT @eng = i.engagement_id, @phase = i.phase, @mand = i.is_mandatory, @label = i.check_label, @stage = e.stage_code
    FROM grac_practice.tprm_onboarding_item i JOIN grac_practice.tprm_engagement e ON e.engagement_id = i.engagement_id
    WHERE i.item_id = @item_id AND i.organization_id = @organization_id;
    IF @eng IS NULL THROW 57787, 'That check was not found.', 1;
    IF (@phase = N'ONBOARDING' AND @stage <> N'ONBOARDING') OR (@phase = N'EXIT' AND @stage <> N'EXITING')
        THROW 57788, 'These checks are closed for the engagement''s current stage.', 1;
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    IF @action = N'WAIVE' AND @note IS NULL THROW 57789, 'A waiver needs the reason.', 1;
    IF @action = N'NA' AND @mand = 1 THROW 57790, 'A mandatory check cannot be marked not applicable. Waive it formally instead.', 1;
    IF @action NOT IN (N'DONE', N'WAIVE', N'NA', N'REOPEN') THROW 57791, 'Unknown check action.', 1;

    UPDATE grac_practice.tprm_onboarding_item
       SET status = CASE @action WHEN N'DONE' THEN N'DONE' WHEN N'WAIVE' THEN N'WAIVED' WHEN N'NA' THEN N'NOT_APPLICABLE' ELSE N'PENDING' END,
           note = COALESCE(@note, note), evidence_reference = COALESCE(NULLIF(LTRIM(RTRIM(@evidence_reference)), N''), evidence_reference),
           completed_by_employee_id = CASE WHEN @action = N'REOPEN' THEN NULL ELSE @actor_employee_id END,
           completed_dt = CASE WHEN @action = N'REOPEN' THEN NULL ELSE SYSUTCDATETIME() END
     WHERE item_id = @item_id;
    DECLARE @detail NVARCHAR(2000) = CONCAT(@phase, N' check "', @label, N'": ', @action, CASE WHEN @note IS NULL THEN N'' ELSE CONCAT(N' - ', @note) END);
    EXEC grac_practice.sp_tprm_engagement_event @eng, N'CHECK', @stage, @stage, @detail, @actor_employee_id, @actor;
    SELECT @item_id AS ItemId, @action AS Result;
END
GO

-- Compare the ACTUAL exposure with the PROPOSED one (BRD step 5,
-- acceptance 10). ACTUAL = ACTUAL scope items + validated dependency
-- links (applications, and the instances' resolved dependencies).
-- @confirm_proposed = 1 first records the proposed items as actual (when
-- nothing changed). Earlier open deviations are superseded.
--   material: added data, access, fourth party or location; any
--   increase of the highest data / access rank.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_exposure_compare
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @confirm_proposed  BIT           = 0,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30) = (SELECT stage_code FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id);
    IF @stage IS NULL THROW 57700, 'That engagement was not found.', 1;
    IF @stage NOT IN (N'ONBOARDING', N'ACTIVE', N'SUSPENDED') THROW 57792, 'Actual exposure is compared during onboarding or for a live engagement.', 1;

    BEGIN TRAN;
    EXEC grac_practice.sp_tprm_snapshot_proposed @organization_id, @engagement_id, @actor;
    IF ISNULL(@confirm_proposed, 0) = 1
        INSERT grac_practice.tprm_engagement_scope
            (engagement_id, organization_id, item_kind, exposure_mode, ref_id, item_code, item_name, criticality_code, country, is_critical, notes, entered_by)
        SELECT p.engagement_id, p.organization_id, p.item_kind, N'ACTUAL', p.ref_id, p.item_code, p.item_name, p.criticality_code, p.country,
               p.is_critical, N'Confirmed from the proposed scope.', @actor
        FROM grac_practice.tprm_engagement_scope p
        WHERE p.engagement_id = @engagement_id AND p.exposure_mode = N'PROPOSED' AND p.status = N'Active'
          AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope a
                           WHERE a.engagement_id = @engagement_id AND a.exposure_mode = N'ACTUAL' AND a.status = N'Active'
                             AND a.item_kind = p.item_kind AND COALESCE(CAST(a.ref_id AS NVARCHAR(40)), a.item_code, a.item_name)
                                                             = COALESCE(CAST(p.ref_id AS NVARCHAR(40)), p.item_code, p.item_name));

    DECLARE @p TABLE (item_kind NVARCHAR(30), item_key NVARCHAR(200), item_name NVARCHAR(300), item_code NVARCHAR(60));
    DECLARE @a TABLE (item_kind NVARCHAR(30), item_key NVARCHAR(200), item_name NVARCHAR(300), item_code NVARCHAR(60));
    INSERT @p SELECT DISTINCT item_kind, COALESCE(CAST(ref_id AS NVARCHAR(40)), item_code, item_name), item_name, item_code
              FROM grac_practice.tprm_engagement_scope WHERE engagement_id = @engagement_id AND exposure_mode = N'PROPOSED' AND status = N'Active';
    INSERT @a SELECT DISTINCT item_kind, COALESCE(CAST(ref_id AS NVARCHAR(40)), item_code, item_name), item_name, item_code
              FROM grac_practice.tprm_engagement_scope WHERE engagement_id = @engagement_id AND exposure_mode = N'ACTUAL' AND status = N'Active';
    INSERT @a SELECT N'APPLICATION', CAST(l.target_id AS NVARCHAR(40)), l.target_label, NULL
              FROM grac_practice.tprm_engagement_link l
              WHERE l.engagement_id = @engagement_id AND l.status = N'Active' AND l.is_validated = 1 AND l.link_kind = N'APPLICATION'
                AND NOT EXISTS (SELECT 1 FROM @a x WHERE x.item_kind = N'APPLICATION' AND x.item_key = CAST(l.target_id AS NVARCHAR(40)));

    DECLARE @snapshot BIGINT;
    INSERT grac_practice.tprm_exposure_snapshot (engagement_id, organization_id, snapshot_kind, summary_json, items_json, taken_by)
    VALUES (@engagement_id, @organization_id, N'ACTUAL',
            (SELECT item_kind AS [key], COUNT(*) AS [count] FROM @a GROUP BY item_kind FOR JSON PATH),
            (SELECT item_kind AS kind, item_key AS [key], item_name AS name FROM @a FOR JSON PATH),
            @actor);
    SET @snapshot = SCOPE_IDENTITY();

    UPDATE grac_practice.tprm_engagement_deviation SET status = N'SUPERSEDED' WHERE engagement_id = @engagement_id AND status = N'OPEN';

    -- rank increases of data / access are material even when the item is "the same kind"
    DECLARE @p_data INT, @a_data INT, @p_acc INT, @a_acc INT;
    SELECT @p_data = MAX(r.rank_no) FROM @p x JOIN grac_practice.fn_tprm_reference_effective(@organization_id) r ON r.list_code = N'DATA_EXPOSURE' AND r.value_code = x.item_code WHERE x.item_kind = N'DATA_CATEGORY';
    SELECT @a_data = MAX(r.rank_no) FROM @a x JOIN grac_practice.fn_tprm_reference_effective(@organization_id) r ON r.list_code = N'DATA_EXPOSURE' AND r.value_code = x.item_code WHERE x.item_kind = N'DATA_CATEGORY';
    SELECT @p_acc = MAX(r.rank_no) FROM @p x JOIN grac_practice.fn_tprm_reference_effective(@organization_id) r ON r.list_code = N'ACCESS_CATEGORY' AND r.value_code = x.item_code WHERE x.item_kind = N'ACCESS';
    SELECT @a_acc = MAX(r.rank_no) FROM @a x JOIN grac_practice.fn_tprm_reference_effective(@organization_id) r ON r.list_code = N'ACCESS_CATEGORY' AND r.value_code = x.item_code WHERE x.item_kind = N'ACCESS';

    INSERT grac_practice.tprm_engagement_deviation (engagement_id, organization_id, snapshot_id, deviation_kind, item_kind, item_key, item_name, is_material, status)
    SELECT @engagement_id, @organization_id, @snapshot, N'ADDED', a.item_kind, LEFT(a.item_key, 200), LEFT(a.item_name, 300),
           CASE WHEN a.item_kind IN (N'FOURTH_PARTY', N'LOCATION', N'DATA_CATEGORY', N'ACCESS') THEN 1
                WHEN a.item_kind = N'DATA_CATEGORY' AND ISNULL(@a_data, 0) > ISNULL(@p_data, 0) THEN 1
                WHEN a.item_kind = N'ACCESS' AND ISNULL(@a_acc, 0) > ISNULL(@p_acc, 0) THEN 1
                ELSE 0 END, N'OPEN'
    FROM @a a WHERE NOT EXISTS (SELECT 1 FROM @p p WHERE p.item_kind = a.item_kind AND p.item_key = a.item_key);
    INSERT grac_practice.tprm_engagement_deviation (engagement_id, organization_id, snapshot_id, deviation_kind, item_kind, item_key, item_name, is_material, status)
    SELECT @engagement_id, @organization_id, @snapshot, N'REMOVED', p.item_kind, LEFT(p.item_key, 200), LEFT(p.item_name, 300), 0, N'OPEN'
    FROM @p p WHERE NOT EXISTS (SELECT 1 FROM @a a WHERE a.item_kind = p.item_kind AND a.item_key = p.item_key);
    COMMIT;

    DECLARE @n INT, @m INT;
    SELECT @n = COUNT(*), @m = SUM(CASE WHEN is_material = 1 THEN 1 ELSE 0 END)
    FROM grac_practice.tprm_engagement_deviation WHERE snapshot_id = @snapshot;
    DECLARE @detail NVARCHAR(2000) = CONCAT(N'Actual exposure compared: ', @n, N' deviation(s), ', ISNULL(@m, 0), N' material.');
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'EXPOSURE_COMPARED', @stage, @stage, @detail, @actor_employee_id, @actor;
    SELECT @snapshot AS SnapshotId, @n AS DeviationCount, ISNULL(@m, 0) AS MaterialCount, N'COMPARED' AS Result;
END
GO

-- ACCEPT (the deviation does not change the risk -- APPROVE in Web) or
-- REASSESS (flags reassessment and raises a triggered review).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_deviation_action
    @organization_id   BIGINT,
    @deviation_id      BIGINT,
    @action            NVARCHAR(20),
    @note              NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @eng BIGINT, @status NVARCHAR(20), @name NVARCHAR(300), @kind NVARCHAR(30);
    SELECT @eng = engagement_id, @status = status, @name = item_name, @kind = item_kind
    FROM grac_practice.tprm_engagement_deviation WHERE deviation_id = @deviation_id AND organization_id = @organization_id;
    IF @eng IS NULL THROW 57793, 'That deviation was not found.', 1;
    IF @status <> N'OPEN' THROW 57794, 'That deviation was already decided.', 1;
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    IF @note IS NULL THROW 57795, 'Give a note for the record.', 1;
    IF @action NOT IN (N'ACCEPT', N'REASSESS') THROW 57796, 'Unknown deviation action.', 1;

    BEGIN TRAN;
        UPDATE grac_practice.tprm_engagement_deviation
           SET status = CASE WHEN @action = N'ACCEPT' THEN N'ACCEPTED' ELSE N'REASSESS' END, decision_note = @note,
               decided_by_employee_id = @actor_employee_id, decided_dt = SYSUTCDATETIME()
         WHERE deviation_id = @deviation_id;
        IF @action = N'REASSESS'
        BEGIN
            UPDATE grac_practice.tprm_engagement
               SET reassessment_required = 1, reassessment_reason = LEFT(CONCAT(N'Deviation from proposed exposure: ', @kind, N' ', @name), 1000)
             WHERE engagement_id = @eng;
            DECLARE @rid BIGINT, @due DATE = DATEADD(DAY, 30, CONVERT(DATE, SYSUTCDATETIME())),
                    @rdetail NVARCHAR(2000) = CONCAT(N'Deviation from proposed exposure: ', @kind, N' ', @name, N'. ', @note),
                    @key NVARCHAR(200) = CONCAT(N'DEVIATION:', @deviation_id);
            EXEC grac_practice.sp_tprm_review_create @organization_id, @eng, N'TRIGGERED', N'SCOPE_CHANGE', @rdetail, @due, NULL, @key, @actor, @rid OUTPUT;
        END
    COMMIT;
    DECLARE @detail NVARCHAR(2000) = CONCAT(N'Deviation ', @kind, N' ', @name, N': ', @action, N' - ', @note);
    EXEC grac_practice.sp_tprm_engagement_event @eng, N'DEVIATION_DECIDED', NULL, NULL, @detail, @actor_employee_id, @actor;
    SELECT @deviation_id AS DeviationId, @action AS Result;
END
GO

-- Activate (BRD step 5): only when every configured mandatory condition
-- is met or formally waived. The first blocker found is reported.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_activate
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @actual_start_dt   DATE          = NULL,
    @note              NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30), @tp BIGINT;
    SELECT @stage = stage_code, @tp = third_party_id FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @stage IS NULL THROW 57700, 'That engagement was not found.', 1;
    IF @stage <> N'ONBOARDING' THROW 57797, 'Only an engagement in onboarding can be activated.', 1;

    DECLARE @msg NVARCHAR(400), @n INT;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_decision WHERE engagement_id = @engagement_id AND status = N'DECIDED'
                     AND outcome_meaning IN (N'APPROVE', N'APPROVE_WITH_CONDITIONS')
                     AND decision_no = (SELECT MAX(decision_no) FROM grac_practice.tprm_decision WHERE engagement_id = @engagement_id AND status = N'DECIDED'))
        THROW 57798, 'The latest decision is not an approval.', 1;
    SELECT @n = COUNT(*) FROM grac_practice.tprm_onboarding_item WHERE engagement_id = @engagement_id AND phase = N'ONBOARDING' AND is_mandatory = 1 AND status = N'PENDING';
    IF @n > 0 BEGIN SET @msg = CONCAT(@n, N' mandatory onboarding check(s) are not done or waived.'); THROW 57799, @msg, 1; END
    SELECT @n = COUNT(*) FROM grac_practice.tprm_finding WHERE engagement_id = @engagement_id AND is_mandatory_for_activation = 1 AND status IN (N'OPEN', N'IN_PROGRESS');
    IF @n > 0 BEGIN SET @msg = CONCAT(@n, N' mandatory condition(s) are still open.'); THROW 57800, @msg, 1; END
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_exposure_snapshot WHERE engagement_id = @engagement_id AND snapshot_kind = N'ACTUAL')
        THROW 57801, 'Compare the actual exposure with the proposed one first.', 1;
    SELECT @n = COUNT(*) FROM grac_practice.tprm_engagement_deviation WHERE engagement_id = @engagement_id AND is_material = 1 AND status = N'OPEN';
    IF @n > 0 BEGIN SET @msg = CONCAT(@n, N' material deviation(s) from the proposed exposure need a decision.'); THROW 57802, @msg, 1; END
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND reassessment_required = 1)
        THROW 57803, 'The engagement needs reassessment (scope change or deviation). Reassess it and obtain a new decision before activating it.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement e
                    JOIN grac_practice.tprm_decision d ON d.engagement_id = e.engagement_id AND d.status = N'DECIDED'
                         AND d.decision_no = (SELECT MAX(x.decision_no) FROM grac_practice.tprm_decision x WHERE x.engagement_id = e.engagement_id AND x.status = N'DECIDED')
                    WHERE e.engagement_id = @engagement_id AND d.risk_assessment_id = e.current_risk_assessment_id)
        THROW 57826, 'The approval was given for an earlier risk assessment. Request a new decision for the current one.', 1;

    DECLARE @band_rank INT, @crit_rank INT, @freq INT;
    SELECT @band_rank = band_rank, @crit_rank = criticality_rank FROM grac_practice.fn_tprm_engagement_ranks(@engagement_id);
    SELECT @freq = review_frequency_months FROM grac_practice.fn_tprm_match_review_rule(@organization_id, @band_rank, @crit_rank);
    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());

    BEGIN TRAN;
        UPDATE grac_practice.tprm_engagement
           SET stage_code = N'ACTIVE', stage_dt = SYSUTCDATETIME(), actual_start_dt = COALESCE(@actual_start_dt, actual_start_dt, @today),
               last_review_dt = @today,
               next_review_dt = CASE WHEN next_review_dt IS NOT NULL AND next_review_dt < DATEADD(MONTH, ISNULL(@freq, 12), @today)
                                     THEN next_review_dt ELSE DATEADD(MONTH, ISNULL(@freq, 12), @today) END,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @engagement_id;
    COMMIT;
    EXEC grac_practice.sp_tprm_third_party_sync_status @tp, @actor;
    DECLARE @detail NVARCHAR(2000) = CONCAT(N'Engagement activated. Next review every ', ISNULL(@freq, 12), N' months.',
                                            CASE WHEN @note IS NULL THEN N'' ELSE CONCAT(N' ', @note) END);
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'ACTIVATED', @stage, N'ACTIVE', @detail, @actor_employee_id, @actor;
    SELECT @engagement_id AS EngagementId, N'ACTIVATED' AS Result;
END
GO

-- =====================================================================
-- 12. Lifecycle (BRD section 4)
--   SUSPEND (ACTIVE)  RESUME (SUSPENDED)  RENEW (ACTIVE / SUSPENDED,
--   new end date; renewal review)  SCOPE_CHANGE (flags reassessment,
--   triggered review)  START_EXIT (exit checks)  COMPLETE_EXIT (all
--   mandatory exit checks done / waived)  CANCEL (before activation)
-- =====================================================================
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
        SET @to = N'CANCELLED';
    END
    ELSE BEGIN ROLLBACK; THROW 57816, 'Unknown lifecycle action.', 1; END

    IF @to <> @stage
        UPDATE grac_practice.tprm_engagement SET stage_code = @to, stage_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @engagement_id;
    COMMIT;

    EXEC grac_practice.sp_tprm_third_party_sync_status @tp, @actor;
    DECLARE @evt NVARCHAR(40) = CONCAT(N'LIFECYCLE_', @action);
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, @evt, @stage, @to, @reason, @actor_employee_id, @actor;
    SELECT @engagement_id AS EngagementId, @to AS Result;
END
GO

-- =====================================================================
-- 13. Reviews and monitoring (BRD section 4)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_review_list
    @organization_id BIGINT,
    @status          NVARCHAR(20)  = N'OPEN',      -- OPEN / COMPLETED / CANCELLED / ALL / OVERDUE
    @review_type     NVARCHAR(30)  = NULL,
    @engagement_id   BIGINT        = NULL,
    @due_within_days INT           = NULL,
    @owner_employee_id BIGINT      = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 57817, 'Select an organization.', 1;
    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME()), @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');

    SELECT r.review_id AS ReviewId, r.review_number AS ReviewNumber, r.review_type AS ReviewType, r.trigger_code AS TriggerCode,
           tv.label AS TriggerLabel, r.trigger_detail AS TriggerDetail, r.due_dt AS DueDt, r.status AS Status,
           r.outcome_code AS OutcomeCode, r.outcome_note AS OutcomeNote, r.requires_reassessment AS RequiresReassessment,
           r.owner_employee_id AS OwnerEmployeeId, oe.employee_name AS OwnerName, r.raised_by AS RaisedBy, r.raised_dt AS RaisedDt,
           r.completed_dt AS CompletedDt, r.engagement_id AS EngagementId, e.engagement_code AS EngagementCode,
           e.engagement_title AS EngagementTitle, t.legal_name AS ThirdPartyName, e.stage_code AS StageCode,
           COALESCE(e.residual_band_code, e.inherent_band_code) AS BandCode,
           CAST(CASE WHEN r.status = N'OPEN' AND r.due_dt < @today THEN 1 ELSE 0 END AS BIT) AS IsOverdue,
           COUNT(*) OVER () AS TotalRows
    FROM grac_practice.tprm_review r
    JOIN grac_practice.tprm_engagement e ON e.engagement_id = r.engagement_id
    JOIN grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
    LEFT JOIN grac_practice.organization_employee oe ON oe.employee_id = r.owner_employee_id
    LEFT JOIN grac_practice.fn_tprm_reference_effective(@organization_id) tv ON tv.list_code = N'REVIEW_TRIGGER' AND tv.value_code = r.trigger_code
    WHERE r.organization_id = @organization_id
      AND (ISNULL(@status, N'ALL') = N'ALL' OR r.status = @status OR (@status = N'OVERDUE' AND r.status = N'OPEN' AND r.due_dt < @today))
      AND (@review_type IS NULL OR r.review_type = @review_type)
      AND (@engagement_id IS NULL OR r.engagement_id = @engagement_id)
      AND (@owner_employee_id IS NULL OR r.owner_employee_id = @owner_employee_id)
      AND (@due_within_days IS NULL OR r.due_dt <= DATEADD(DAY, @due_within_days, @today))
      AND (@s IS NULL OR r.review_number LIKE N'%' + @s + N'%' OR e.engagement_title LIKE N'%' + @s + N'%'
           OR e.engagement_code LIKE N'%' + @s + N'%' OR t.legal_name LIKE N'%' + @s + N'%')
    ORDER BY CASE WHEN r.status = N'OPEN' THEN 0 ELSE 1 END, r.due_dt, r.review_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- A review raised by a person (incident, SLA breach, material change ...).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_review_raise
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @trigger_code      NVARCHAR(60),
    @trigger_detail    NVARCHAR(2000) = NULL,
    @due_dt            DATE           = NULL,
    @owner_employee_id BIGINT         = NULL,
    @custom_json       NVARCHAR(MAX)  = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30) = (SELECT stage_code FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id);
    IF @stage IS NULL THROW 57700, 'That engagement was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57730, 'A closed engagement cannot be changed.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id) WHERE list_code = N'REVIEW_TRIGGER' AND value_code = @trigger_code)
        THROW 57818, 'Choose a trigger from the list.', 1;
    IF @owner_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                    WHERE employee_id = @owner_employee_id AND organization_id = @organization_id AND status = N'Active')
        THROW 57819, 'The owner must be an active employee of this organization.', 1;
    SET @due_dt = COALESCE(@due_dt, DATEADD(DAY, 30, CONVERT(DATE, SYSUTCDATETIME())));
    DECLARE @type NVARCHAR(30) = CASE WHEN @trigger_code = N'SCHEDULED' THEN N'PERIODIC' ELSE N'TRIGGERED' END;
    DECLARE @rid BIGINT;
    BEGIN TRAN;
        EXEC grac_practice.sp_tprm_review_create @organization_id, @engagement_id, @type, @trigger_code, @trigger_detail, @due_dt,
             @owner_employee_id, NULL, @actor, @rid OUTPUT;
        DECLARE @roles NVARCHAR(600) = (SELECT r.role_name FROM grac_practice.organization_employee e
                                         JOIN grac_practice.organization_role r ON r.role_id = e.role_id WHERE e.employee_id = @actor_employee_id);
        EXEC grac_practice.sp_tprm_custom_values_save @organization_id, N'REVIEW', @rid, @custom_json, @roles, 0, @actor;
    COMMIT;
    SELECT @rid AS ReviewId, N'RAISED' AS Result;
END
GO

-- Complete (outcome + note) or cancel (@cancel = 1, note) a review.
--   NO_CHANGE / REMEDIATE  periodic reviews move the review dates
--   REASSESS               flags reassessment (start it on the engagement)
--   SUSPEND / EXIT         performs the lifecycle action
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_review_complete
    @organization_id   BIGINT,
    @review_id         BIGINT,
    @outcome_code      NVARCHAR(20)   = NULL,
    @outcome_note      NVARCHAR(2000) = NULL,
    @cancel            BIT            = 0,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @eng BIGINT, @status NVARCHAR(20), @type NVARCHAR(30), @number NVARCHAR(20), @trigger NVARCHAR(60);
    SELECT @eng = engagement_id, @status = status, @type = review_type, @number = review_number, @trigger = trigger_code
    FROM grac_practice.tprm_review WHERE review_id = @review_id AND organization_id = @organization_id;
    IF @eng IS NULL THROW 57820, 'That review was not found.', 1;
    IF @status <> N'OPEN' THROW 57821, 'That review is already closed.', 1;
    SET @outcome_note = NULLIF(LTRIM(RTRIM(@outcome_note)), N'');
    IF @outcome_note IS NULL THROW 57822, 'Record what the review found.', 1;

    IF ISNULL(@cancel, 0) = 1
    BEGIN
        UPDATE grac_practice.tprm_review SET status = N'CANCELLED', outcome_note = @outcome_note, completed_by_employee_id = @actor_employee_id,
               completed_dt = SYSUTCDATETIME() WHERE review_id = @review_id;
        DECLARE @cdetail NVARCHAR(2000) = CONCAT(@number, N' cancelled: ', @outcome_note);
        EXEC grac_practice.sp_tprm_engagement_event @eng, N'REVIEW_CANCELLED', NULL, NULL, @cdetail, @actor_employee_id, @actor;
        SELECT @review_id AS ReviewId, N'CANCELLED' AS Result;
        RETURN;
    END
    IF ISNULL(@outcome_code, N'') NOT IN (N'NO_CHANGE', N'REASSESS', N'REMEDIATE', N'SUSPEND', N'EXIT')
        THROW 57823, 'Choose the outcome of the review.', 1;

    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME()), @band_rank INT, @crit_rank INT, @freq INT;
    SELECT @band_rank = band_rank, @crit_rank = criticality_rank FROM grac_practice.fn_tprm_engagement_ranks(@eng);
    SELECT @freq = review_frequency_months FROM grac_practice.fn_tprm_match_review_rule(@organization_id, @band_rank, @crit_rank);

    BEGIN TRAN;
        UPDATE grac_practice.tprm_review SET status = N'COMPLETED', outcome_code = @outcome_code, outcome_note = @outcome_note,
               completed_by_employee_id = @actor_employee_id, completed_dt = SYSUTCDATETIME()
         WHERE review_id = @review_id;
        IF @type = N'PERIODIC' OR @trigger = N'SCHEDULED'
            UPDATE grac_practice.tprm_engagement SET last_review_dt = @today, next_review_dt = DATEADD(MONTH, ISNULL(@freq, 12), @today)
             WHERE engagement_id = @eng;
        IF @type = N'ACCEPTANCE_EXPIRY' AND @outcome_code = N'NO_CHANGE'
            UPDATE grac_practice.tprm_engagement SET reassessment_required = 1,
                   reassessment_reason = N'Risk acceptance expired: a new decision is needed.'
             WHERE engagement_id = @eng;
        IF @outcome_code = N'REASSESS'
            UPDATE grac_practice.tprm_engagement SET reassessment_required = 1,
                   reassessment_reason = LEFT(CONCAT(N'Review ', @number, N': ', @outcome_note), 1000)
             WHERE engagement_id = @eng;
    COMMIT;

    DECLARE @detail NVARCHAR(2000) = CONCAT(@number, N' completed: ', @outcome_code, N' - ', @outcome_note);
    EXEC grac_practice.sp_tprm_engagement_event @eng, N'REVIEW_COMPLETED', NULL, NULL, @detail, @actor_employee_id, @actor;

    -- SUSPEND / EXIT perform the lifecycle step (its own result set comes
    -- first; this procedure's result is the LAST set, as for every TPRM
    -- command that calls another procedure).
    DECLARE @stage NVARCHAR(30) = (SELECT stage_code FROM grac_practice.tprm_engagement WHERE engagement_id = @eng);
    IF @outcome_code = N'SUSPEND' AND @stage = N'ACTIVE'
        EXEC grac_practice.sp_tprm_engagement_lifecycle @organization_id, @eng, N'SUSPEND', @outcome_note, NULL, @actor_employee_id, @actor;
    ELSE IF @outcome_code = N'EXIT' AND @stage IN (N'ACTIVE', N'SUSPENDED')
        EXEC grac_practice.sp_tprm_engagement_lifecycle @organization_id, @eng, N'START_EXIT', @outcome_note, NULL, @actor_employee_id, @actor;
    SELECT @review_id AS ReviewId, N'COMPLETED' AS Result;
END
GO

-- The scheduler pass (TaskNotificationWorker, or "Run now"; NULL
-- organization = every organization). Each kind of review is raised once
-- per source key, so the pass can run any number of times:
--   PERIODIC             next review date within the rule's lead days
--   CONTRACT_EXPIRY      end date within the contract alert window
--   CERTIFICATION_EXPIRY accepted evidence expiring within the cert window
--   ACCEPTANCE_EXPIRY    risk acceptance ending within 30 days
--   TRIGGERED            engagement flagged for reassessment with no open
--                        triggered review; overdue remediation (monthly);
--                        new open assurance findings on its vendor or
--                        linked practice instances since activation
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_monitoring_sweep
    @organization_id BIGINT        = NULL,
    @actor           NVARCHAR(100) = N'tprm-scheduler'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME()), @raised INT = 0;
    DECLARE @q TABLE (organization_id BIGINT, engagement_id BIGINT, review_type NVARCHAR(30), trigger_code NVARCHAR(60),
                      detail NVARCHAR(2000), due_dt DATE, source_key NVARCHAR(200));

    ;WITH live AS (
        SELECT e.engagement_id, e.organization_id, e.next_review_dt, COALESCE(e.actual_end_dt, e.proposed_end_dt) AS end_dt,
               e.acceptance_until, e.reassessment_required, e.reassessment_reason, e.actual_start_dt, e.third_party_id,
               rr.review_lead_days, rr.contract_expiry_alert_days, rr.cert_expiry_alert_days
        FROM grac_practice.tprm_engagement e
        CROSS APPLY grac_practice.fn_tprm_engagement_ranks(e.engagement_id) k
        OUTER APPLY grac_practice.fn_tprm_match_review_rule(e.organization_id, k.band_rank, k.criticality_rank) rr
        WHERE e.stage_code IN (N'ACTIVE', N'SUSPENDED')
          AND (@organization_id IS NULL OR e.organization_id = @organization_id)
    )
    INSERT @q
    SELECT organization_id, engagement_id, N'PERIODIC', N'SCHEDULED', N'Periodic engagement risk review.', next_review_dt,
           CONCAT(N'PERIODIC:', engagement_id, N':', CONVERT(NVARCHAR(10), next_review_dt, 23))
    FROM live WHERE next_review_dt IS NOT NULL AND next_review_dt <= DATEADD(DAY, ISNULL(review_lead_days, 30), @today)
    UNION ALL
    SELECT organization_id, engagement_id, N'CONTRACT_EXPIRY', N'CONTRACT_EXPIRY',
           CONCAT(N'The engagement ends on ', CONVERT(NVARCHAR(10), end_dt, 23), N': renew, re-tender or plan the exit.'),
           CASE WHEN end_dt < @today THEN @today ELSE end_dt END,
           CONCAT(N'CONTRACT:', engagement_id, N':', CONVERT(NVARCHAR(10), end_dt, 23))
    FROM live WHERE end_dt IS NOT NULL AND contract_expiry_alert_days IS NOT NULL AND end_dt <= DATEADD(DAY, contract_expiry_alert_days, @today)
    UNION ALL
    SELECT organization_id, engagement_id, N'ACCEPTANCE_EXPIRY', N'ACCEPTANCE_EXPIRY',
           CONCAT(N'Risk acceptance ends on ', CONVERT(NVARCHAR(10), acceptance_until, 23), N'.'),
           CASE WHEN acceptance_until < @today THEN @today ELSE acceptance_until END,
           CONCAT(N'ACCEPTANCE:', engagement_id, N':', CONVERT(NVARCHAR(10), acceptance_until, 23))
    FROM live WHERE acceptance_until IS NOT NULL AND acceptance_until <= DATEADD(DAY, 30, @today)
    UNION ALL
    SELECT organization_id, engagement_id, N'TRIGGERED', N'MATERIAL_CHANGE', ISNULL(reassessment_reason, N'Reassessment required.'),
           DATEADD(DAY, 30, @today), CONCAT(N'REASSESS:', engagement_id, N':', FORMAT(@today, 'yyyyMM'))
    FROM live WHERE reassessment_required = 1
      AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_review r WHERE r.engagement_id = live.engagement_id AND r.status = N'OPEN'
                        AND r.review_type = N'TRIGGERED')
    UNION ALL
    SELECT l.organization_id, l.engagement_id, N'TRIGGERED', N'OVERDUE_REMEDIATION',
           CONCAT(COUNT(*), N' remediation action(s) are overdue.'), DATEADD(DAY, 14, @today),
           CONCAT(N'OVERDUE:', l.engagement_id, N':', FORMAT(@today, 'yyyyMM'))
    FROM live l
    JOIN grac_practice.tprm_finding f ON f.engagement_id = l.engagement_id AND f.status IN (N'OPEN', N'IN_PROGRESS') AND f.due_dt < @today
    GROUP BY l.organization_id, l.engagement_id;

    INSERT @q
    SELECT l.organization_id, l.engagement_id, N'CERTIFICATION_EXPIRY', N'CERTIFICATION_EXPIRY',
           CONCAT(N'Evidence "', v.title, N'" expires on ', CONVERT(NVARCHAR(10), v.valid_to, 23), N'.'),
           CASE WHEN v.valid_to < @today THEN @today ELSE v.valid_to END,
           CONCAT(N'EVIDENCE:', v.tprm_evidence_id, N':', CONVERT(NVARCHAR(10), v.valid_to, 23))
    FROM grac_practice.tprm_evidence_link v
    JOIN grac_practice.tprm_engagement l ON l.engagement_id = v.engagement_id AND l.stage_code IN (N'ACTIVE', N'SUSPENDED')
    CROSS APPLY grac_practice.fn_tprm_engagement_ranks(l.engagement_id) k
    OUTER APPLY grac_practice.fn_tprm_match_review_rule(l.organization_id, k.band_rank, k.criticality_rank) rr
    WHERE v.status = N'Active' AND v.review_status = N'ACCEPTED' AND v.valid_to IS NOT NULL
      AND v.valid_to <= DATEADD(DAY, ISNULL(rr.cert_expiry_alert_days, 30), @today)
      AND (@organization_id IS NULL OR v.organization_id = @organization_id)
      -- only the latest evidence for the same requirement and target counts
      AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_evidence_link n WHERE n.engagement_id = v.engagement_id AND n.status = N'Active'
                        AND n.review_status = N'ACCEPTED' AND n.target_kind = v.target_kind AND n.target_id = v.target_id
                        AND ISNULL(n.evidence_requirement_code, N'') = ISNULL(v.evidence_requirement_code, N'')
                        AND n.valid_to > v.valid_to);

    -- new open assurance findings on the vendor or on linked practice instances, since activation
    INSERT @q
    SELECT e.organization_id, e.engagement_id, N'TRIGGERED', N'ASSURANCE_FAILURE',
           LEFT(CONCAT(N'Assurance finding ', o.observation_code, N': ', o.observation_title, N' (', o.severity_name, N').'), 2000),
           DATEADD(DAY, 30, @today), CONCAT(N'ASSURANCE:', e.engagement_id, N':', o.org_assurance_observation_id)
    FROM grac_practice.tprm_engagement e
    JOIN grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
    JOIN grac_practice.org_assurance_observation o ON o.organization_id = e.organization_id
    JOIN grac_practice.org_assurance_execution_entity ee ON ee.org_assurance_execution_entity_id = o.org_assurance_execution_entity_id
    LEFT JOIN grac_practice.org_assurance_observation_status_master sm ON sm.org_assurance_observation_status_id = o.observation_status_id
    WHERE e.stage_code IN (N'ACTIVE', N'SUSPENDED')
      AND (@organization_id IS NULL OR e.organization_id = @organization_id)
      AND ISNULL(sm.is_terminal, 0) = 0
      AND o.observed_dt >= ISNULL(CAST(e.actual_start_dt AS DATETIME2), e.stage_dt)
      AND (   (ee.dimension_code = N'VENDOR' AND (ee.entity_id = t.vendor_id
                  OR EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = e.engagement_id
                               AND l.link_kind = N'VENDOR' AND l.target_id = ee.entity_id AND l.status = N'Active')))
           OR (ee.dimension_code = N'PRACTICE_INSTANCE' AND EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l
                               WHERE l.engagement_id = e.engagement_id AND l.link_kind = N'PRACTICE_INSTANCE'
                                 AND l.target_id = ee.entity_id AND l.status = N'Active')));

    DECLARE @o BIGINT, @e BIGINT, @t NVARCHAR(30), @tc NVARCHAR(60), @d NVARCHAR(2000), @due DATE, @k NVARCHAR(200), @rid BIGINT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT organization_id, engagement_id, review_type, trigger_code, detail, due_dt, source_key FROM @q;
    OPEN c;
    FETCH NEXT FROM c INTO @o, @e, @t, @tc, @d, @due, @k;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @rid = NULL;
            BEGIN TRAN;   -- holds the review-number lock until the review exists
            EXEC grac_practice.sp_tprm_review_create @o, @e, @t, @tc, @d, @due, NULL, @k, @actor, @rid OUTPUT;
            COMMIT;
            IF @rid IS NOT NULL SET @raised = @raised + 1;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            -- one engagement must not stop the pass; the next run retries it
            PRINT CONCAT('sp_tprm_monitoring_sweep: engagement ', @e, ' skipped - ', ERROR_MESSAGE());
        END CATCH
        FETCH NEXT FROM c INTO @o, @e, @t, @tc, @d, @due, @k;
    END
    CLOSE c;
    DEALLOCATE c;

    SELECT @raised AS ReviewsRaised, (SELECT COUNT(*) FROM @q) AS Candidates, SYSUTCDATETIME() AS RunDt;
END
GO

-- =====================================================================
-- 14. Verification
-- =====================================================================
SELECT '489 tables' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.tprm_dd_response','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_safeguard_assessment','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_evidence_link','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_finding','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_decision_approval','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_onboarding_item','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_engagement_deviation','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_review','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '489 procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_tprm_dd_start','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_residual_calculate','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_decision_act','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_risk_escalate','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_engagement_activate','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_monitoring_sweep','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '489 Risk Centre source ThirdParty',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_source_master WHERE source_type_code = N'ThirdParty' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '489 complete. Run 490_tprm_menu_dashboard.sql next.';
GO
