-- =====================================================================
-- 582  Audit Intelligence -- Risk-Based Internal Audit (RBIA)
--      (CR2 - AA Part D; Phase 4; docs/audit-intelligence.md)
--
-- REQUEST (2026-11-17, sir: "proceed with next phase"). Internal Audit
--   assesses the audit risk of each Audit Universe subject with its OWN
--   configurable, versioned methodology; enterprise risk intelligence
--   (581) is an input, never the answer (CR2 6.1, 6.5); approved
--   assessments are immutable (6.11). Earlier decision (2026-11-16): RBIA
--   configurable per organization with an RBI preset.
--
-- METHODOLOGY (CR2 6.2, per organization, versioned Draft -> Published ->
-- Superseded; only a Draft is edited; publishing supersedes the previous
-- version; an assessment keeps the version it started on):
--   * rating scale (levels 1..N with names / descriptions, 6.6)
--   * parameters: INHERENT (risk areas, 6.3) and CONTROL (control
--     effectiveness, 6.7), each with a weight (each kind sums to 100)
--   * questions per parameter (6.4): guidance, evidence expectation,
--     weight, answer by the rating scale or by its own options (each option
--     a score 0-100), an optional indicator shown beside it (6.5 -- shown,
--     never applied)
--   * scoring: inherent aggregation (weighted average / highest
--     parameter / weighted sum), residual method (factor: inherent x
--     (1 - CE x max reduction) -- the CR2 6.8 illustration; subtract:
--     inherent - CE x max reduction; inherent only), max reduction %
--   * risk bands 0-100 with audit priority and recommended frequency
--     (months) (6.2, 6.8)
--   * approval: reviewer step on / off; the approver holds HEAD_INTERNAL_AUDIT
--   Starting a draft: copy of the published version, the RBI preset (CR2
--   6.3 parameters, 6.4 questions, 6.6 five-point scale; weights, bands and
--   frequencies are starting values to be set by the Head of Internal
--   Audit), or blank.
--
-- SCORING (every save, server side): an answer = its scale level
--   normalised to 0-100 ((level - 1) / (levels - 1) x 100) or its option
--   score; "not applicable" is left out. Parameter = weighted average of its
--   answers. Inherent = the aggregation of INHERENT parameters; control
--   effectiveness (CE) = weighted average of CONTROL parameters (0 when
--   none); residual = the residual method; band = the band holding the
--   residual (rounded to 2 decimals). Nothing is decided silently: the
--   assessor answers every question (or marks it not applicable) and may
--   propose an override band with a justification (6.9), which the
--   approver approves with the assessment.
--
-- ASSESSMENT (6.10, 6.11): Draft -> Submitted (the assessor; every question
--   answered) -> In Review (reviewer step on: an AUDIT_REVIEWER, not the
--   assessor, REVIEWs -> Pending Approval, or RETURNs) -> Approved (a
--   HEAD_INTERNAL_AUDIT holder, not the assessor; RETURN -> Returned).
--   Approving freezes the enterprise risk snapshot (581's risks, passed by
--   the Api from the same procedure at that moment) and the methodology
--   snapshot, and supersedes the subject's previous approved assessment.
--   An approved assessment never changes; REASSESS makes a new Draft
--   (version + 1, previous linked). CANCEL a Draft / Returned one (reason).
--   Individual and bulk creation; types Initial / Annual / Event-triggered
--   (reason). One open assessment per subject; only Active subjects.
--
-- OBJECTS: tables org_assurance_rbia_methodology, _rbia_level,
--   _rbia_parameter, _rbia_question, _rbia_question_option, _rbia_band,
--   _rbia_assessment, _rbia_response, _rbia_score, _rbia_history;
--   fn_org_assurance_rbia_subject_current; procedures
--   sp_org_assurance_rbia_methodology_list / _get / _draft / _save /
--   _publish / _discard, sp_org_assurance_rbia_assessment_list / _create /
--   _get / _save / _compute / _action. Menus (Audit Intelligence):
--   RBIA Configuration (50), RBIA Assessment (60); 274 updated.
--
-- ERRORS 54130-54145: 54130 not found; 54131 not a draft / not in a state
--   that allows this; 54132 no published methodology; 54133 methodology
--   invalid (message says what); 54134 only the assessor; 54135 only an
--   Audit Reviewer (not the assessor); 54136 only the Head of Internal
--   Audit (not the assessor); 54137 unanswered questions; 54138 reason
--   required; 54139 changed by someone else; 54140 nothing selected;
--   54141 subject not Active / not found; 54142 override needs a
--   justification; 54143 a draft already exists.
-- DEPENDS ON: 553, 566 (fn_org_responsibility_holder), 577, 578.
-- Rollback: 582_audit_rbia_rollback.sql.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_universe_subject','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_responsibility_holder','IF') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-audit-intelligence')
BEGIN
    PRINT 'ABORT (582): run 577 and 578 first. Nothing was changed.';
    RAISERROR('582_audit_rbia: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Methodology tables
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_rbia_methodology','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_rbia_methodology(
        rbia_methodology_id   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rbia_meth PRIMARY KEY,
        organization_id       BIGINT         NOT NULL,
        version_no            INT            NOT NULL,
        methodology_name      NVARCHAR(200)  NOT NULL,
        status                NVARCHAR(20)   NOT NULL,
        preset_code           NVARCHAR(30)   NULL,
        effective_from        DATE           NULL,
        inherent_aggregation  NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_oa_rbia_meth_agg DEFAULT N'WEIGHTED_AVG',
        residual_method       NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_oa_rbia_meth_res DEFAULT N'FACTOR',
        max_reduction_pct     DECIMAL(5,2)   NOT NULL CONSTRAINT df_pm_oa_rbia_meth_red DEFAULT 100,
        require_review        BIT            NOT NULL CONSTRAINT df_pm_oa_rbia_meth_rev DEFAULT 1,
        notes                 NVARCHAR(2000) NULL,
        published_by          NVARCHAR(240)  NULL,
        published_dt          DATETIME2      NULL,
        superseded_dt         DATETIME2      NULL,
        entered_by            NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_oa_rbia_meth_by DEFAULT 'system',
        entered_dt            DATETIME2      NOT NULL CONSTRAINT df_pm_oa_rbia_meth_dt DEFAULT SYSUTCDATETIME(),
        updated_by            NVARCHAR(100)  NULL,
        updated_dt            DATETIME2      NULL,
        CONSTRAINT fk_pm_oa_rbia_meth_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT ck_pm_oa_rbia_meth_status CHECK (status IN (N'Draft', N'Published', N'Superseded')),
        CONSTRAINT ck_pm_oa_rbia_meth_agg CHECK (inherent_aggregation IN (N'WEIGHTED_AVG', N'MAX', N'WEIGHTED_SUM')),
        CONSTRAINT ck_pm_oa_rbia_meth_res CHECK (residual_method IN (N'FACTOR', N'SUBTRACT', N'INHERENT_ONLY')),
        CONSTRAINT ck_pm_oa_rbia_meth_red CHECK (max_reduction_pct BETWEEN 0 AND 100),
        CONSTRAINT uq_pm_oa_rbia_meth_ver UNIQUE(organization_id, version_no)
    );
    CREATE UNIQUE INDEX ux_pm_oa_rbia_meth_draft ON grac_practice.org_assurance_rbia_methodology(organization_id) WHERE status = N'Draft';
    CREATE UNIQUE INDEX ux_pm_oa_rbia_meth_pub ON grac_practice.org_assurance_rbia_methodology(organization_id) WHERE status = N'Published';
    PRINT '582.1: org_assurance_rbia_methodology created.';
END
GO
IF OBJECT_ID('grac_practice.org_assurance_rbia_level','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_rbia_level(
        rbia_level_id       BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rbia_lvl PRIMARY KEY,
        rbia_methodology_id BIGINT         NOT NULL,
        level_value         INT            NOT NULL,
        level_name          NVARCHAR(100)  NOT NULL,
        description         NVARCHAR(500)  NULL,
        CONSTRAINT fk_pm_oa_rbia_lvl_meth FOREIGN KEY(rbia_methodology_id) REFERENCES grac_practice.org_assurance_rbia_methodology(rbia_methodology_id),
        CONSTRAINT uq_pm_oa_rbia_lvl UNIQUE(rbia_methodology_id, level_value)
    );
    PRINT '582.1: org_assurance_rbia_level created.';
END
GO
IF OBJECT_ID('grac_practice.org_assurance_rbia_parameter','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_rbia_parameter(
        rbia_parameter_id   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rbia_par PRIMARY KEY,
        rbia_methodology_id BIGINT         NOT NULL,
        parameter_code      NVARCHAR(40)   NOT NULL,
        parameter_name      NVARCHAR(200)  NOT NULL,
        assessment_focus    NVARCHAR(1000) NULL,
        parameter_kind      NVARCHAR(10)   NOT NULL,
        weight_pct          DECIMAL(6,2)   NOT NULL,
        display_order       INT            NOT NULL CONSTRAINT df_pm_oa_rbia_par_ord DEFAULT 0,
        CONSTRAINT fk_pm_oa_rbia_par_meth FOREIGN KEY(rbia_methodology_id) REFERENCES grac_practice.org_assurance_rbia_methodology(rbia_methodology_id),
        CONSTRAINT ck_pm_oa_rbia_par_kind CHECK (parameter_kind IN (N'INHERENT', N'CONTROL')),
        CONSTRAINT uq_pm_oa_rbia_par UNIQUE(rbia_methodology_id, parameter_code)
    );
    PRINT '582.1: org_assurance_rbia_parameter created.';
END
GO
IF OBJECT_ID('grac_practice.org_assurance_rbia_question','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_rbia_question(
        rbia_question_id     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rbia_q PRIMARY KEY,
        rbia_parameter_id    BIGINT         NOT NULL,
        question_text        NVARCHAR(1000) NOT NULL,
        guidance             NVARCHAR(2000) NULL,
        evidence_expectation NVARCHAR(1000) NULL,
        answer_mode          NVARCHAR(10)   NOT NULL CONSTRAINT df_pm_oa_rbia_q_mode DEFAULT N'SCALE',
        weight               DECIMAL(6,2)   NOT NULL CONSTRAINT df_pm_oa_rbia_q_w DEFAULT 1,
        indicator_code       NVARCHAR(40)   NULL,
        display_order        INT            NOT NULL CONSTRAINT df_pm_oa_rbia_q_ord DEFAULT 0,
        CONSTRAINT fk_pm_oa_rbia_q_par FOREIGN KEY(rbia_parameter_id) REFERENCES grac_practice.org_assurance_rbia_parameter(rbia_parameter_id),
        CONSTRAINT ck_pm_oa_rbia_q_mode CHECK (answer_mode IN (N'SCALE', N'OPTIONS')),
        CONSTRAINT ck_pm_oa_rbia_q_w CHECK (weight > 0)
    );
    PRINT '582.1: org_assurance_rbia_question created.';
END
GO
IF OBJECT_ID('grac_practice.org_assurance_rbia_question_option','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_rbia_question_option(
        rbia_option_id   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rbia_opt PRIMARY KEY,
        rbia_question_id BIGINT         NOT NULL,
        option_label     NVARCHAR(300)  NOT NULL,
        option_score     DECIMAL(6,2)   NOT NULL,
        display_order    INT            NOT NULL CONSTRAINT df_pm_oa_rbia_opt_ord DEFAULT 0,
        CONSTRAINT fk_pm_oa_rbia_opt_q FOREIGN KEY(rbia_question_id) REFERENCES grac_practice.org_assurance_rbia_question(rbia_question_id),
        CONSTRAINT ck_pm_oa_rbia_opt_score CHECK (option_score BETWEEN 0 AND 100)
    );
    PRINT '582.1: org_assurance_rbia_question_option created.';
END
GO
IF OBJECT_ID('grac_practice.org_assurance_rbia_band','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_rbia_band(
        rbia_band_id        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rbia_band PRIMARY KEY,
        rbia_methodology_id BIGINT         NOT NULL,
        band_code           NVARCHAR(30)   NOT NULL,
        band_name           NVARCHAR(100)  NOT NULL,
        min_score           DECIMAL(6,2)   NOT NULL,
        max_score           DECIMAL(6,2)   NOT NULL,
        audit_priority      NVARCHAR(60)   NOT NULL,
        frequency_months    INT            NOT NULL,
        display_order       INT            NOT NULL CONSTRAINT df_pm_oa_rbia_band_ord DEFAULT 0,
        CONSTRAINT fk_pm_oa_rbia_band_meth FOREIGN KEY(rbia_methodology_id) REFERENCES grac_practice.org_assurance_rbia_methodology(rbia_methodology_id),
        CONSTRAINT ck_pm_oa_rbia_band_range CHECK (min_score >= 0 AND max_score <= 100 AND min_score <= max_score),
        CONSTRAINT ck_pm_oa_rbia_band_freq CHECK (frequency_months > 0),
        CONSTRAINT uq_pm_oa_rbia_band UNIQUE(rbia_methodology_id, band_code)
    );
    PRINT '582.1: org_assurance_rbia_band created.';
END
GO

-- =====================================================================
-- 2. Assessment tables
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_rbia_assessment','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_rbia_assessment(
        rbia_assessment_id     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rbia_asm PRIMARY KEY,
        organization_id        BIGINT         NOT NULL,
        ref_no                 INT            NOT NULL,
        assessment_ref         NVARCHAR(30)   NOT NULL,
        universe_subject_id    BIGINT         NOT NULL,
        rbia_methodology_id    BIGINT         NOT NULL,
        assessment_version     INT            NOT NULL CONSTRAINT df_pm_oa_rbia_asm_ver DEFAULT 1,
        previous_assessment_id BIGINT         NULL,
        assessment_period      NVARCHAR(60)   NOT NULL,
        assessment_type        NVARCHAR(20)   NOT NULL,
        trigger_reason         NVARCHAR(2000) NULL,
        status                 NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_oa_rbia_asm_status DEFAULT N'Draft',
        assessor_employee_id   BIGINT         NOT NULL,
        reviewer_employee_id   BIGINT         NULL,
        reviewed_dt            DATETIME2      NULL,
        approver_employee_id   BIGINT         NULL,
        approved_dt            DATETIME2      NULL,
        submitted_dt           DATETIME2      NULL,
        inherent_score         DECIMAL(6,2)   NULL,
        control_score          DECIMAL(6,2)   NULL,
        residual_score         DECIMAL(6,2)   NULL,
        system_band_id         BIGINT         NULL,
        override_band_id       BIGINT         NULL,
        override_justification NVARCHAR(2000) NULL,
        override_evidence      NVARCHAR(2000) NULL,
        final_band_id          BIGINT         NULL,
        final_band_name        NVARCHAR(100)  NULL,
        final_priority         NVARCHAR(60)   NULL,
        frequency_months       INT            NULL,
        next_audit_due         DATE           NULL,
        is_current             BIT            NOT NULL CONSTRAINT df_pm_oa_rbia_asm_cur DEFAULT 0,
        risk_snapshot_json     NVARCHAR(MAX)  NULL,
        methodology_snapshot_json NVARCHAR(MAX) NULL,
        row_version_no         INT            NOT NULL CONSTRAINT df_pm_oa_rbia_asm_rv DEFAULT 1,
        entered_by             NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_oa_rbia_asm_by DEFAULT 'system',
        entered_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_oa_rbia_asm_dt DEFAULT SYSUTCDATETIME(),
        updated_by             NVARCHAR(100)  NULL,
        updated_dt             DATETIME2      NULL,
        CONSTRAINT fk_pm_oa_rbia_asm_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT fk_pm_oa_rbia_asm_subject FOREIGN KEY(universe_subject_id) REFERENCES grac_practice.org_assurance_universe_subject(universe_subject_id),
        CONSTRAINT fk_pm_oa_rbia_asm_meth FOREIGN KEY(rbia_methodology_id) REFERENCES grac_practice.org_assurance_rbia_methodology(rbia_methodology_id),
        CONSTRAINT fk_pm_oa_rbia_asm_prev FOREIGN KEY(previous_assessment_id) REFERENCES grac_practice.org_assurance_rbia_assessment(rbia_assessment_id),
        CONSTRAINT fk_pm_oa_rbia_asm_assessor FOREIGN KEY(assessor_employee_id) REFERENCES grac_practice.organization_employee(employee_id),
        CONSTRAINT fk_pm_oa_rbia_asm_sband FOREIGN KEY(system_band_id) REFERENCES grac_practice.org_assurance_rbia_band(rbia_band_id),
        CONSTRAINT fk_pm_oa_rbia_asm_oband FOREIGN KEY(override_band_id) REFERENCES grac_practice.org_assurance_rbia_band(rbia_band_id),
        CONSTRAINT fk_pm_oa_rbia_asm_fband FOREIGN KEY(final_band_id) REFERENCES grac_practice.org_assurance_rbia_band(rbia_band_id),
        CONSTRAINT ck_pm_oa_rbia_asm_status CHECK (status IN (N'Draft', N'InReview', N'PendingApproval', N'Returned', N'Approved', N'Superseded', N'Cancelled')),
        CONSTRAINT ck_pm_oa_rbia_asm_type CHECK (assessment_type IN (N'INITIAL', N'ANNUAL', N'EVENT')),
        CONSTRAINT uq_pm_oa_rbia_asm_ref UNIQUE(organization_id, ref_no)
    );
    CREATE INDEX ix_pm_oa_rbia_asm_subject ON grac_practice.org_assurance_rbia_assessment(organization_id, universe_subject_id, status);
    PRINT '582.2: org_assurance_rbia_assessment created.';
END
GO
IF OBJECT_ID('grac_practice.org_assurance_rbia_response','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_rbia_response(
        rbia_response_id   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rbia_resp PRIMARY KEY,
        rbia_assessment_id BIGINT         NOT NULL,
        rbia_question_id   BIGINT         NOT NULL,
        level_value        INT            NULL,
        rbia_option_id     BIGINT         NULL,
        is_not_applicable  BIT            NOT NULL CONSTRAINT df_pm_oa_rbia_resp_na DEFAULT 0,
        answer_score       DECIMAL(6,2)   NULL,
        comment            NVARCHAR(2000) NULL,
        evidence_reference NVARCHAR(1000) NULL,
        updated_by         NVARCHAR(100)  NULL,
        updated_dt         DATETIME2      NULL,
        CONSTRAINT fk_pm_oa_rbia_resp_asm FOREIGN KEY(rbia_assessment_id) REFERENCES grac_practice.org_assurance_rbia_assessment(rbia_assessment_id),
        CONSTRAINT fk_pm_oa_rbia_resp_q FOREIGN KEY(rbia_question_id) REFERENCES grac_practice.org_assurance_rbia_question(rbia_question_id),
        CONSTRAINT fk_pm_oa_rbia_resp_opt FOREIGN KEY(rbia_option_id) REFERENCES grac_practice.org_assurance_rbia_question_option(rbia_option_id),
        CONSTRAINT uq_pm_oa_rbia_resp UNIQUE(rbia_assessment_id, rbia_question_id)
    );
    PRINT '582.2: org_assurance_rbia_response created.';
END
GO
IF OBJECT_ID('grac_practice.org_assurance_rbia_score','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_rbia_score(
        rbia_score_id      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rbia_score PRIMARY KEY,
        rbia_assessment_id BIGINT        NOT NULL,
        rbia_parameter_id  BIGINT        NOT NULL,
        parameter_score    DECIMAL(6,2)  NULL,
        weight_pct         DECIMAL(6,2)  NOT NULL,
        answered_count     INT           NOT NULL,
        question_count     INT           NOT NULL,
        CONSTRAINT fk_pm_oa_rbia_score_asm FOREIGN KEY(rbia_assessment_id) REFERENCES grac_practice.org_assurance_rbia_assessment(rbia_assessment_id),
        CONSTRAINT fk_pm_oa_rbia_score_par FOREIGN KEY(rbia_parameter_id) REFERENCES grac_practice.org_assurance_rbia_parameter(rbia_parameter_id),
        CONSTRAINT uq_pm_oa_rbia_score UNIQUE(rbia_assessment_id, rbia_parameter_id)
    );
    PRINT '582.2: org_assurance_rbia_score created.';
END
GO
IF OBJECT_ID('grac_practice.org_assurance_rbia_history','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_rbia_history(
        rbia_history_id     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rbia_hist PRIMARY KEY,
        organization_id     BIGINT         NOT NULL,
        rbia_assessment_id  BIGINT         NULL,
        rbia_methodology_id BIGINT         NULL,
        action_code         NVARCHAR(30)   NOT NULL,
        from_status         NVARCHAR(20)   NULL,
        to_status           NVARCHAR(20)   NULL,
        comment             NVARCHAR(MAX)  NULL,
        employee_id         BIGINT         NULL,
        actor_name          NVARCHAR(240)  NOT NULL,
        action_dt           DATETIME2      NOT NULL CONSTRAINT df_pm_oa_rbia_hist_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT fk_pm_oa_rbia_hist_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id)
    );
    CREATE INDEX ix_pm_oa_rbia_hist ON grac_practice.org_assurance_rbia_history(organization_id, rbia_assessment_id, action_dt);
    PRINT '582.2: org_assurance_rbia_history created.';
END
GO

-- =====================================================================
-- 3. A subject's current (latest approved) RBIA -- for the Universe and
--    the Audit Plan Recommendations (phase 5).
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_org_assurance_rbia_subject_current(@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT a.universe_subject_id, a.rbia_assessment_id, a.assessment_ref, a.assessment_period, a.approved_dt,
           a.inherent_score, a.control_score, a.residual_score, a.final_band_id, a.final_band_name, a.final_priority,
           a.frequency_months, a.next_audit_due, a.override_band_id
      FROM grac_practice.org_assurance_rbia_assessment a
     WHERE a.organization_id = @organization_id AND a.is_current = 1 AND a.status = N'Approved';
GO

-- =====================================================================
-- 4. Methodology procedures
-- =====================================================================

-- 4a. Versions.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_rbia_methodology_list
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.rbia_methodology_id AS RbiaMethodologyId, m.version_no AS VersionNo, m.methodology_name AS MethodologyName,
           m.status AS Status, m.preset_code AS PresetCode, m.effective_from AS EffectiveFrom,
           m.published_by AS PublishedBy, m.published_dt AS PublishedDt, m.superseded_dt AS SupersededDt,
           (SELECT COUNT(*) FROM grac_practice.org_assurance_rbia_assessment a WHERE a.rbia_methodology_id = m.rbia_methodology_id) AS AssessmentCount,
           ISNULL(m.updated_dt, m.entered_dt) AS ChangedDt
      FROM grac_practice.org_assurance_rbia_methodology m
     WHERE m.organization_id = @organization_id
     ORDER BY m.version_no DESC;
END
GO

-- 4b. One version (NULL = the draft, else the published one): settings,
-- scale, parameters, questions, options, bands.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_rbia_methodology_get
    @organization_id     BIGINT,
    @rbia_methodology_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @rbia_methodology_id IS NULL
        SET @rbia_methodology_id = ISNULL(
            (SELECT rbia_methodology_id FROM grac_practice.org_assurance_rbia_methodology WHERE organization_id = @organization_id AND status = N'Draft'),
            (SELECT rbia_methodology_id FROM grac_practice.org_assurance_rbia_methodology WHERE organization_id = @organization_id AND status = N'Published'));
    SELECT m.rbia_methodology_id AS RbiaMethodologyId, m.version_no AS VersionNo, m.methodology_name AS MethodologyName,
           m.status AS Status, m.preset_code AS PresetCode, m.effective_from AS EffectiveFrom,
           m.inherent_aggregation AS InherentAggregation, m.residual_method AS ResidualMethod,
           m.max_reduction_pct AS MaxReductionPct, m.require_review AS RequireReview, m.notes AS Notes,
           m.published_by AS PublishedBy, m.published_dt AS PublishedDt
      FROM grac_practice.org_assurance_rbia_methodology m
     WHERE m.rbia_methodology_id = @rbia_methodology_id AND m.organization_id = @organization_id;
    SELECT level_value AS LevelValue, level_name AS LevelName, description AS Description
      FROM grac_practice.org_assurance_rbia_level WHERE rbia_methodology_id = @rbia_methodology_id ORDER BY level_value;
    SELECT p.rbia_parameter_id AS RbiaParameterId, p.parameter_code AS ParameterCode, p.parameter_name AS ParameterName,
           p.assessment_focus AS AssessmentFocus, p.parameter_kind AS ParameterKind, p.weight_pct AS WeightPct,
           p.display_order AS DisplayOrder
      FROM grac_practice.org_assurance_rbia_parameter p
     WHERE p.rbia_methodology_id = @rbia_methodology_id
     ORDER BY CASE p.parameter_kind WHEN N'INHERENT' THEN 0 ELSE 1 END, p.display_order, p.parameter_code;
    SELECT q.rbia_question_id AS RbiaQuestionId, q.rbia_parameter_id AS RbiaParameterId, q.question_text AS QuestionText,
           q.guidance AS Guidance, q.evidence_expectation AS EvidenceExpectation, q.answer_mode AS AnswerMode,
           q.weight AS Weight, q.indicator_code AS IndicatorCode, q.display_order AS DisplayOrder
      FROM grac_practice.org_assurance_rbia_question q
      JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = q.rbia_parameter_id
     WHERE p.rbia_methodology_id = @rbia_methodology_id
     ORDER BY q.rbia_parameter_id, q.display_order, q.rbia_question_id;
    SELECT o.rbia_option_id AS RbiaOptionId, o.rbia_question_id AS RbiaQuestionId, o.option_label AS OptionLabel,
           o.option_score AS OptionScore, o.display_order AS DisplayOrder
      FROM grac_practice.org_assurance_rbia_question_option o
      JOIN grac_practice.org_assurance_rbia_question q ON q.rbia_question_id = o.rbia_question_id
      JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = q.rbia_parameter_id
     WHERE p.rbia_methodology_id = @rbia_methodology_id
     ORDER BY o.rbia_question_id, o.display_order, o.rbia_option_id;
    SELECT b.rbia_band_id AS RbiaBandId, b.band_code AS BandCode, b.band_name AS BandName, b.min_score AS MinScore,
           b.max_score AS MaxScore, b.audit_priority AS AuditPriority, b.frequency_months AS FrequencyMonths,
           b.display_order AS DisplayOrder
      FROM grac_practice.org_assurance_rbia_band b
     WHERE b.rbia_methodology_id = @rbia_methodology_id
     ORDER BY b.min_score;
END
GO

-- 4c. Replace a draft's content: @content_json =
--   { methodologyName, effectiveFrom, inherentAggregation, residualMethod,
--     maxReductionPct, requireReview, notes,
--     levels: [{ levelValue, levelName, description }],
--     parameters: [{ parameterCode, parameterName, assessmentFocus, parameterKind,
--                    weightPct, displayOrder,
--                    questions: [{ questionText, guidance, evidenceExpectation,
--                                  answerMode, weight, indicatorCode, displayOrder,
--                                  options: [{ optionLabel, optionScore, displayOrder }] }] }],
--     bands: [{ bandCode, bandName, minScore, maxScore, auditPriority, frequencyMonths, displayOrder }] }
-- A draft has no assessments, so its rows are replaced wholesale.
-- Validation happens at publish (a draft may be incomplete).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_rbia_methodology_save
    @organization_id     BIGINT,
    @rbia_methodology_id BIGINT,
    @content_json        NVARCHAR(MAX),
    @employee_id         BIGINT        = NULL,
    @actor               NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_methodology
                    WHERE rbia_methodology_id = @rbia_methodology_id AND organization_id = @organization_id AND status = N'Draft')
        THROW 54131, 'Only the draft methodology can be changed. Start a draft first.', 1;
    IF ISJSON(ISNULL(@content_json, N'')) = 0 THROW 54133, 'The methodology is not valid.', 1;

    DECLARE @name NVARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@content_json, '$.methodologyName'))), N'');
    DECLARE @agg NVARCHAR(20) = ISNULL(JSON_VALUE(@content_json, '$.inherentAggregation'), N'WEIGHTED_AVG');
    DECLARE @res NVARCHAR(20) = ISNULL(JSON_VALUE(@content_json, '$.residualMethod'), N'FACTOR');
    DECLARE @red DECIMAL(5,2) = TRY_CAST(JSON_VALUE(@content_json, '$.maxReductionPct') AS DECIMAL(5,2));
    IF @name IS NULL THROW 54133, 'Give the methodology a name.', 1;
    IF @agg NOT IN (N'WEIGHTED_AVG', N'MAX', N'WEIGHTED_SUM') THROW 54133, 'Unknown inherent aggregation.', 1;
    IF @res NOT IN (N'FACTOR', N'SUBTRACT', N'INHERENT_ONLY') THROW 54133, 'Unknown residual method.', 1;
    IF @red IS NULL OR @red < 0 OR @red > 100 THROW 54133, 'Maximum reduction must be 0 to 100 (%).', 1;

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    DECLARE @par TABLE(seq INT, code NVARCHAR(40), name NVARCHAR(200), focus NVARCHAR(1000), kind NVARCHAR(10),
                       weight DECIMAL(6,2), ord INT, questions NVARCHAR(MAX));
    INSERT INTO @par
    SELECT CAST(j.[key] AS INT), UPPER(LTRIM(RTRIM(p.code))), LTRIM(RTRIM(p.name)), NULLIF(LTRIM(RTRIM(p.focus)), N''),
           UPPER(ISNULL(p.kind, N'INHERENT')), ISNULL(p.weight, 0), ISNULL(p.ord, 0), p.questions
      FROM OPENJSON(@content_json, '$.parameters') j
     CROSS APPLY OPENJSON(j.value) WITH (code NVARCHAR(40) '$.parameterCode', name NVARCHAR(200) '$.parameterName',
                                         focus NVARCHAR(1000) '$.assessmentFocus', kind NVARCHAR(10) '$.parameterKind',
                                         weight DECIMAL(6,2) '$.weightPct', ord INT '$.displayOrder',
                                         questions NVARCHAR(MAX) '$.questions' AS JSON) p;
    IF EXISTS (SELECT 1 FROM @par WHERE NULLIF(code, N'') IS NULL OR NULLIF(name, N'') IS NULL)
        THROW 54133, 'Every parameter needs a code and a name.', 1;
    IF EXISTS (SELECT code FROM @par GROUP BY code HAVING COUNT(*) > 1) THROW 54133, 'Parameter codes must be unique.', 1;
    IF EXISTS (SELECT 1 FROM @par WHERE kind NOT IN (N'INHERENT', N'CONTROL')) THROW 54133, 'A parameter is INHERENT or CONTROL.', 1;

    BEGIN TRAN;
    UPDATE grac_practice.org_assurance_rbia_methodology
       SET methodology_name = @name,
           effective_from = TRY_CAST(JSON_VALUE(@content_json, '$.effectiveFrom') AS DATE),
           inherent_aggregation = @agg, residual_method = @res, max_reduction_pct = @red,
           require_review = CASE WHEN JSON_VALUE(@content_json, '$.requireReview') IN (N'false', N'0') THEN 0 ELSE 1 END,
           notes = NULLIF(LTRIM(RTRIM(JSON_VALUE(@content_json, '$.notes'))), N''),
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE rbia_methodology_id = @rbia_methodology_id;

    DELETE o FROM grac_practice.org_assurance_rbia_question_option o
      JOIN grac_practice.org_assurance_rbia_question q ON q.rbia_question_id = o.rbia_question_id
      JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = q.rbia_parameter_id
     WHERE p.rbia_methodology_id = @rbia_methodology_id;
    DELETE q FROM grac_practice.org_assurance_rbia_question q
      JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = q.rbia_parameter_id
     WHERE p.rbia_methodology_id = @rbia_methodology_id;
    DELETE FROM grac_practice.org_assurance_rbia_parameter WHERE rbia_methodology_id = @rbia_methodology_id;
    DELETE FROM grac_practice.org_assurance_rbia_level WHERE rbia_methodology_id = @rbia_methodology_id;
    DELETE FROM grac_practice.org_assurance_rbia_band WHERE rbia_methodology_id = @rbia_methodology_id;

    INSERT INTO grac_practice.org_assurance_rbia_level (rbia_methodology_id, level_value, level_name, description)
    SELECT @rbia_methodology_id, l.lv, LTRIM(RTRIM(l.nm)), NULLIF(LTRIM(RTRIM(l.ds)), N'')
      FROM OPENJSON(@content_json, '$.levels') WITH (lv INT '$.levelValue', nm NVARCHAR(100) '$.levelName', ds NVARCHAR(500) '$.description') l
     WHERE l.lv IS NOT NULL AND NULLIF(LTRIM(RTRIM(l.nm)), N'') IS NOT NULL;

    INSERT INTO grac_practice.org_assurance_rbia_band
        (rbia_methodology_id, band_code, band_name, min_score, max_score, audit_priority, frequency_months, display_order)
    SELECT @rbia_methodology_id, UPPER(LTRIM(RTRIM(b.cd))), LTRIM(RTRIM(b.nm)), b.mn, b.mx, LTRIM(RTRIM(b.pr)), b.fq, ISNULL(b.ord, 0)
      FROM OPENJSON(@content_json, '$.bands') WITH (cd NVARCHAR(30) '$.bandCode', nm NVARCHAR(100) '$.bandName',
                                                     mn DECIMAL(6,2) '$.minScore', mx DECIMAL(6,2) '$.maxScore',
                                                     pr NVARCHAR(60) '$.auditPriority', fq INT '$.frequencyMonths', ord INT '$.displayOrder') b
     WHERE NULLIF(LTRIM(RTRIM(b.cd)), N'') IS NOT NULL;

    DECLARE @seq INT = (SELECT MIN(seq) FROM @par), @pid BIGINT, @qjson NVARCHAR(MAX);
    WHILE @seq IS NOT NULL
    BEGIN
        INSERT INTO grac_practice.org_assurance_rbia_parameter
            (rbia_methodology_id, parameter_code, parameter_name, assessment_focus, parameter_kind, weight_pct, display_order)
        SELECT @rbia_methodology_id, code, name, focus, kind, weight, ord FROM @par WHERE seq = @seq;
        SET @pid = SCOPE_IDENTITY();
        SET @qjson = (SELECT questions FROM @par WHERE seq = @seq);
        IF ISJSON(ISNULL(@qjson, N'')) = 1
        BEGIN
            DECLARE @qmap TABLE(qid BIGINT, qseq INT);
            DELETE FROM @qmap;
            MERGE grac_practice.org_assurance_rbia_question AS t
            USING (SELECT CAST(j.[key] AS INT) AS qseq, q.txt, q.gd, q.ev, UPPER(ISNULL(q.md, N'SCALE')) AS md,
                          ISNULL(NULLIF(q.wt, 0), 1) AS wt, NULLIF(LTRIM(RTRIM(q.ind)), N'') AS ind, ISNULL(q.ord, 0) AS ord
                     FROM OPENJSON(@qjson) j
                    CROSS APPLY OPENJSON(j.value) WITH (txt NVARCHAR(1000) '$.questionText', gd NVARCHAR(2000) '$.guidance',
                                                        ev NVARCHAR(1000) '$.evidenceExpectation', md NVARCHAR(10) '$.answerMode',
                                                        wt DECIMAL(6,2) '$.weight', ind NVARCHAR(40) '$.indicatorCode', ord INT '$.displayOrder') q
                    WHERE NULLIF(LTRIM(RTRIM(q.txt)), N'') IS NOT NULL) AS s
               ON 1 = 0
            WHEN NOT MATCHED THEN
                INSERT (rbia_parameter_id, question_text, guidance, evidence_expectation, answer_mode, weight, indicator_code, display_order)
                VALUES (@pid, LTRIM(RTRIM(s.txt)), NULLIF(LTRIM(RTRIM(s.gd)), N''), NULLIF(LTRIM(RTRIM(s.ev)), N''),
                        CASE WHEN s.md = N'OPTIONS' THEN N'OPTIONS' ELSE N'SCALE' END, s.wt, s.ind, s.ord)
            OUTPUT inserted.rbia_question_id, s.qseq INTO @qmap (qid, qseq);
            INSERT INTO grac_practice.org_assurance_rbia_question_option (rbia_question_id, option_label, option_score, display_order)
            SELECT m.qid, LTRIM(RTRIM(o.lbl)), o.sc, ISNULL(o.ord, 0)
              FROM @qmap m
              JOIN OPENJSON(@qjson) j ON CAST(j.[key] AS INT) = m.qseq
             CROSS APPLY OPENJSON(j.value, '$.options') WITH (lbl NVARCHAR(300) '$.optionLabel', sc DECIMAL(6,2) '$.optionScore', ord INT '$.displayOrder') o
             WHERE NULLIF(LTRIM(RTRIM(o.lbl)), N'') IS NOT NULL AND o.sc BETWEEN 0 AND 100;
        END
        SET @seq = (SELECT MIN(seq) FROM @par WHERE seq > @seq);
    END
    INSERT INTO grac_practice.org_assurance_rbia_history (organization_id, rbia_methodology_id, action_code, comment, employee_id, actor_name)
    VALUES (@organization_id, @rbia_methodology_id, N'METHOD_SAVE', N'Draft saved', @employee_id, @me);
    COMMIT;
END
GO

-- 4d. Start a draft: @source PUBLISHED (copy of the published version),
-- RBI (the preset) or BLANK. One draft at a time (54143) unless @replace.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_rbia_methodology_draft
    @organization_id BIGINT,
    @source          NVARCHAR(20),
    @replace         BIT           = 0,
    @employee_id     BIGINT        = NULL,
    @actor           NVARCHAR(100) = 'system',
    @rbia_methodology_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @source = UPPER(LTRIM(RTRIM(ISNULL(@source, N'PUBLISHED'))));
    IF @source NOT IN (N'PUBLISHED', N'RBI', N'BLANK') THROW 54133, 'Start from the published version, the RBI preset or blank.', 1;
    DECLARE @draft BIGINT = (SELECT rbia_methodology_id FROM grac_practice.org_assurance_rbia_methodology
                              WHERE organization_id = @organization_id AND status = N'Draft');
    IF @draft IS NOT NULL AND ISNULL(@replace, 0) = 0 THROW 54143, 'A draft already exists. Open it, or replace it.', 1;
    DECLARE @pub BIGINT = (SELECT rbia_methodology_id FROM grac_practice.org_assurance_rbia_methodology
                            WHERE organization_id = @organization_id AND status = N'Published');
    IF @source = N'PUBLISHED' AND @pub IS NULL THROW 54132, 'There is no published methodology to copy.', 1;
    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    DECLARE @content NVARCHAR(MAX);

    IF @source = N'PUBLISHED'
        SET @content = (SELECT m.methodology_name AS methodologyName, m.inherent_aggregation AS inherentAggregation,
                               m.residual_method AS residualMethod, m.max_reduction_pct AS maxReductionPct,
                               m.require_review AS requireReview, m.notes AS notes,
                               (SELECT l.level_value AS levelValue, l.level_name AS levelName, l.description
                                  FROM grac_practice.org_assurance_rbia_level l WHERE l.rbia_methodology_id = m.rbia_methodology_id
                                 ORDER BY l.level_value FOR JSON PATH) AS levels,
                               (SELECT p.parameter_code AS parameterCode, p.parameter_name AS parameterName, p.assessment_focus AS assessmentFocus,
                                       p.parameter_kind AS parameterKind, p.weight_pct AS weightPct, p.display_order AS displayOrder,
                                       (SELECT q.question_text AS questionText, q.guidance, q.evidence_expectation AS evidenceExpectation,
                                               q.answer_mode AS answerMode, q.weight, q.indicator_code AS indicatorCode, q.display_order AS displayOrder,
                                               (SELECT o.option_label AS optionLabel, o.option_score AS optionScore, o.display_order AS displayOrder
                                                  FROM grac_practice.org_assurance_rbia_question_option o WHERE o.rbia_question_id = q.rbia_question_id
                                                 ORDER BY o.display_order FOR JSON PATH) AS options
                                          FROM grac_practice.org_assurance_rbia_question q WHERE q.rbia_parameter_id = p.rbia_parameter_id
                                         ORDER BY q.display_order, q.rbia_question_id FOR JSON PATH) AS questions
                                  FROM grac_practice.org_assurance_rbia_parameter p WHERE p.rbia_methodology_id = m.rbia_methodology_id
                                 ORDER BY p.display_order FOR JSON PATH) AS parameters,
                               (SELECT b.band_code AS bandCode, b.band_name AS bandName, b.min_score AS minScore, b.max_score AS maxScore,
                                       b.audit_priority AS auditPriority, b.frequency_months AS frequencyMonths, b.display_order AS displayOrder
                                  FROM grac_practice.org_assurance_rbia_band b WHERE b.rbia_methodology_id = m.rbia_methodology_id
                                 ORDER BY b.min_score FOR JSON PATH) AS bands
                          FROM grac_practice.org_assurance_rbia_methodology m
                         WHERE m.rbia_methodology_id = @pub
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    ELSE IF @source = N'RBI'
        SET @content = N'{
 "methodologyName": "RBIA - RBI preset",
 "inherentAggregation": "WEIGHTED_AVG", "residualMethod": "FACTOR", "maxReductionPct": 100, "requireReview": true,
 "notes": "Starting set from CR2 6.3 / 6.4 / 6.6 and 6.8 (Residual = Inherent x (1 - Control Effectiveness)). Weights, bands, priorities and frequencies are starting values for the Head of Internal Audit to set.",
 "levels": [
  {"levelValue":1,"levelName":"Very Low","description":"Very low exposure / for control parameters: controls very weak"},
  {"levelValue":2,"levelName":"Low","description":"Low exposure / controls weak"},
  {"levelValue":3,"levelName":"Moderate","description":"Moderate exposure / controls partly effective"},
  {"levelValue":4,"levelName":"High","description":"High exposure / controls largely effective"},
  {"levelValue":5,"levelName":"Very High","description":"Very high exposure / controls fully effective"}],
 "parameters": [
  {"parameterCode":"FINANCIAL","parameterName":"Financial Risk","assessmentFocus":"Financial exposure, transaction value and potential loss","parameterKind":"INHERENT","weightPct":15,"displayOrder":10,
   "questions":[{"questionText":"What is the financial exposure associated with the subject?","displayOrder":1},
                {"questionText":"What is the approximate transaction volume or value?","displayOrder":2},
                {"questionText":"Have material financial losses occurred?","displayOrder":3,"indicatorCode":"OPEN_FINDINGS"}]},
  {"parameterCode":"OPERATIONAL","parameterName":"Operational Risk","assessmentFocus":"Operational complexity, process dependency and disruption","parameterKind":"INHERENT","weightPct":15,"displayOrder":20,
   "questions":[{"questionText":"Is the process business-critical?","displayOrder":1,"indicatorCode":"CRITICALITY"},
                {"questionText":"Does it involve high transaction volumes?","displayOrder":2},
                {"questionText":"Does it have significant dependency on other functions?","displayOrder":3}]},
  {"parameterCode":"REGULATORY","parameterName":"Regulatory Risk","assessmentFocus":"Regulatory significance and compliance exposure","parameterKind":"INHERENT","weightPct":15,"displayOrder":30,
   "questions":[{"questionText":"Is the subject directly governed by regulatory requirements?","displayOrder":1,"indicatorCode":"REG_SIGNIFICANCE"},
                {"questionText":"Have regulatory observations or breaches been reported?","displayOrder":2},
                {"questionText":"Are there pending regulatory remediation actions?","displayOrder":3,"indicatorCode":"OPEN_GAPS"}]},
  {"parameterCode":"COMPLIANCE","parameterName":"Compliance Risk","assessmentFocus":"Compliance history and unresolved deviations","parameterKind":"INHERENT","weightPct":10,"displayOrder":40,
   "questions":[{"questionText":"How significant are the unresolved compliance deviations and exceptions?","displayOrder":1,"indicatorCode":"OPEN_GAPS"}]},
  {"parameterCode":"TECHNOLOGY","parameterName":"Technology Risk","assessmentFocus":"Application, infrastructure, cyber and technology dependencies","parameterKind":"INHERENT","weightPct":10,"displayOrder":50,
   "questions":[{"questionText":"Does the subject depend on critical applications or infrastructure?","displayOrder":1},
                {"questionText":"Are there known cybersecurity or technology control weaknesses?","displayOrder":2},
                {"questionText":"Are there significant third-party technology dependencies?","displayOrder":3}]},
  {"parameterCode":"FRAUD","parameterName":"Fraud Risk","assessmentFocus":"Fraud exposure, transaction characteristics and known incidents","parameterKind":"INHERENT","weightPct":10,"displayOrder":60,
   "questions":[{"questionText":"Does the subject involve cash, collateral, customer transactions or sensitive financial operations?","displayOrder":1},
                {"questionText":"Have fraud incidents or suspicious transactions been identified?","displayOrder":2}]},
  {"parameterCode":"REPUTATIONAL","parameterName":"Reputational Risk","assessmentFocus":"Potential customer, public and stakeholder impact","parameterKind":"INHERENT","weightPct":10,"displayOrder":70,
   "questions":[{"questionText":"What would be the customer, public and stakeholder impact of a failure?","displayOrder":1}]},
  {"parameterCode":"STRATEGIC","parameterName":"Strategic Risk","assessmentFocus":"Importance to organizational objectives","parameterKind":"INHERENT","weightPct":5,"displayOrder":80,
   "questions":[{"questionText":"How important is the subject to organizational objectives?","displayOrder":1}]},
  {"parameterCode":"CUSTOMER","parameterName":"Customer Risk","assessmentFocus":"Customer impact, conduct and service exposure","parameterKind":"INHERENT","weightPct":10,"displayOrder":90,
   "questions":[{"questionText":"What is the customer impact, conduct and service exposure?","displayOrder":1}]},
  {"parameterCode":"CONTROL_ENV","parameterName":"Control Environment","assessmentFocus":"Design and operating effectiveness of controls (rate effectiveness: 5 = fully effective)","parameterKind":"CONTROL","weightPct":100,"displayOrder":100,
   "questions":[{"questionText":"Are key controls documented and assigned?","displayOrder":1},
                {"questionText":"Are controls independently tested?","displayOrder":2},
                {"questionText":"Are recurring control failures and audit findings resolved (5 = none outstanding)?","displayOrder":3,"indicatorCode":"OPEN_FINDINGS"},
                {"questionText":"Is remediation of known deficiencies on track (5 = fully on track)?","displayOrder":4,"indicatorCode":"OPEN_TREATMENT"}]}],
 "bands": [
  {"bandCode":"LOW","bandName":"Low","minScore":0,"maxScore":24.99,"auditPriority":"P4 - Low","frequencyMonths":24,"displayOrder":1},
  {"bandCode":"MEDIUM","bandName":"Medium","minScore":25,"maxScore":49.99,"auditPriority":"P3 - Medium","frequencyMonths":18,"displayOrder":2},
  {"bandCode":"HIGH","bandName":"High","minScore":50,"maxScore":74.99,"auditPriority":"P2 - High","frequencyMonths":12,"displayOrder":3},
  {"bandCode":"VERY_HIGH","bandName":"Very High","minScore":75,"maxScore":100,"auditPriority":"P1 - Very High","frequencyMonths":6,"displayOrder":4}]
}';
    ELSE
        SET @content = N'{"methodologyName":"RBIA methodology","inherentAggregation":"WEIGHTED_AVG","residualMethod":"FACTOR","maxReductionPct":100,"requireReview":true,"levels":[],"parameters":[],"bands":[]}';

    DECLARE @ver INT;
    BEGIN TRAN;
    IF @draft IS NOT NULL
    BEGIN
        -- the replaced draft has no assessments (assessments use published versions)
        DELETE o FROM grac_practice.org_assurance_rbia_question_option o
          JOIN grac_practice.org_assurance_rbia_question q ON q.rbia_question_id = o.rbia_question_id
          JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = q.rbia_parameter_id
         WHERE p.rbia_methodology_id = @draft;
        DELETE q FROM grac_practice.org_assurance_rbia_question q
          JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = q.rbia_parameter_id
         WHERE p.rbia_methodology_id = @draft;
        DELETE FROM grac_practice.org_assurance_rbia_parameter WHERE rbia_methodology_id = @draft;
        DELETE FROM grac_practice.org_assurance_rbia_level WHERE rbia_methodology_id = @draft;
        DELETE FROM grac_practice.org_assurance_rbia_band WHERE rbia_methodology_id = @draft;
        UPDATE grac_practice.org_assurance_rbia_history SET rbia_methodology_id = NULL WHERE rbia_methodology_id = @draft;
        DELETE FROM grac_practice.org_assurance_rbia_methodology WHERE rbia_methodology_id = @draft;
    END
    SET @ver = ISNULL((SELECT MAX(version_no) FROM grac_practice.org_assurance_rbia_methodology WITH (UPDLOCK, HOLDLOCK)
                        WHERE organization_id = @organization_id), 0) + 1;
    INSERT INTO grac_practice.org_assurance_rbia_methodology (organization_id, version_no, methodology_name, status, preset_code, entered_by)
    VALUES (@organization_id, @ver, N'RBIA methodology', N'Draft', @source, @actor);
    SET @rbia_methodology_id_out = SCOPE_IDENTITY();
    COMMIT;
    EXEC grac_practice.sp_org_assurance_rbia_methodology_save @organization_id = @organization_id,
         @rbia_methodology_id = @rbia_methodology_id_out, @content_json = @content, @employee_id = @employee_id, @actor = @actor;
    INSERT INTO grac_practice.org_assurance_rbia_history (organization_id, rbia_methodology_id, action_code, comment, employee_id, actor_name)
    VALUES (@organization_id, @rbia_methodology_id_out, N'METHOD_DRAFT',
            N'Draft v' + CAST(@ver AS NVARCHAR(10)) + N' started from ' + CASE @source WHEN N'RBI' THEN N'the RBI preset'
                                                                                 WHEN N'BLANK' THEN N'blank' ELSE N'the published version' END,
            @employee_id, @me);
END
GO

-- 4e. Publish the draft (validated); the previous published version is
-- superseded. Only the Head of Internal Audit.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_rbia_methodology_publish
    @organization_id     BIGINT,
    @rbia_methodology_id BIGINT,
    @employee_id         BIGINT,
    @actor               NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_methodology
                    WHERE rbia_methodology_id = @rbia_methodology_id AND organization_id = @organization_id AND status = N'Draft')
        THROW 54131, 'Only the draft can be published.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h WHERE h.employee_id = @employee_id)
        THROW 54136, 'Only the Head of Internal Audit (or a delegate holding that responsibility) publishes the methodology.', 1;
    DECLARE @m INT = @rbia_methodology_id;
    IF (SELECT COUNT(*) FROM grac_practice.org_assurance_rbia_level WHERE rbia_methodology_id = @m) < 2
        THROW 54133, 'The rating scale needs at least two levels.', 1;
    IF EXISTS (SELECT 1 FROM (SELECT level_value, ROW_NUMBER() OVER (ORDER BY level_value) AS rn
                                FROM grac_practice.org_assurance_rbia_level WHERE rbia_methodology_id = @m) x WHERE x.level_value <> x.rn)
        THROW 54133, 'Rating scale levels must run 1, 2, 3 ... without gaps.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_parameter WHERE rbia_methodology_id = @m AND parameter_kind = N'INHERENT')
        THROW 54133, 'At least one INHERENT parameter is needed.', 1;
    IF (SELECT SUM(weight_pct) FROM grac_practice.org_assurance_rbia_parameter WHERE rbia_methodology_id = @m AND parameter_kind = N'INHERENT') <> 100
        THROW 54133, 'The weights of the INHERENT parameters must add up to 100.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_parameter WHERE rbia_methodology_id = @m AND parameter_kind = N'CONTROL')
       AND (SELECT SUM(weight_pct) FROM grac_practice.org_assurance_rbia_parameter WHERE rbia_methodology_id = @m AND parameter_kind = N'CONTROL') <> 100
        THROW 54133, 'The weights of the CONTROL parameters must add up to 100.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_parameter p WHERE p.rbia_methodology_id = @m
                  AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_question q WHERE q.rbia_parameter_id = p.rbia_parameter_id))
        THROW 54133, 'Every parameter needs at least one question.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_question q
                 JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = q.rbia_parameter_id
                WHERE p.rbia_methodology_id = @m AND q.answer_mode = N'OPTIONS'
                  AND (SELECT COUNT(*) FROM grac_practice.org_assurance_rbia_question_option o WHERE o.rbia_question_id = q.rbia_question_id) < 2)
        THROW 54133, 'A question answered by options needs at least two options.', 1;
    -- bands: start at 0, end at 100, no overlap; a gap of more than 0.01 is refused
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_band WHERE rbia_methodology_id = @m)
       OR (SELECT MIN(min_score) FROM grac_practice.org_assurance_rbia_band WHERE rbia_methodology_id = @m) <> 0
       OR (SELECT MAX(max_score) FROM grac_practice.org_assurance_rbia_band WHERE rbia_methodology_id = @m) <> 100
       OR EXISTS (SELECT 1 FROM (SELECT min_score, LAG(max_score) OVER (ORDER BY min_score) AS prev_max
                                   FROM grac_practice.org_assurance_rbia_band WHERE rbia_methodology_id = @m) x
                   WHERE x.prev_max IS NOT NULL AND (x.min_score <= x.prev_max OR x.min_score - x.prev_max > 0.01))
        THROW 54133, 'The risk bands must cover 0 to 100 without overlaps or gaps (e.g. 0-24.99, 25-49.99, ...).', 1;

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    BEGIN TRAN;
    UPDATE grac_practice.org_assurance_rbia_methodology
       SET status = N'Superseded', superseded_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE organization_id = @organization_id AND status = N'Published';
    UPDATE grac_practice.org_assurance_rbia_methodology
       SET status = N'Published', published_by = @me, published_dt = SYSUTCDATETIME(),
           effective_from = ISNULL(effective_from, CAST(SYSUTCDATETIME() AS DATE)), updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE rbia_methodology_id = @m;
    INSERT INTO grac_practice.org_assurance_rbia_history (organization_id, rbia_methodology_id, action_code, comment, employee_id, actor_name)
    VALUES (@organization_id, @m, N'METHOD_PUBLISH', N'Published', @employee_id, @me);
    COMMIT;
END
GO

-- 4f. Discard the draft.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_rbia_methodology_discard
    @organization_id     BIGINT,
    @rbia_methodology_id BIGINT,
    @employee_id         BIGINT        = NULL,
    @actor               NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_methodology
                    WHERE rbia_methodology_id = @rbia_methodology_id AND organization_id = @organization_id AND status = N'Draft')
        THROW 54131, 'Only the draft can be discarded.', 1;
    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    BEGIN TRAN;
    DELETE o FROM grac_practice.org_assurance_rbia_question_option o
      JOIN grac_practice.org_assurance_rbia_question q ON q.rbia_question_id = o.rbia_question_id
      JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = q.rbia_parameter_id
     WHERE p.rbia_methodology_id = @rbia_methodology_id;
    DELETE q FROM grac_practice.org_assurance_rbia_question q
      JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = q.rbia_parameter_id
     WHERE p.rbia_methodology_id = @rbia_methodology_id;
    DELETE FROM grac_practice.org_assurance_rbia_parameter WHERE rbia_methodology_id = @rbia_methodology_id;
    DELETE FROM grac_practice.org_assurance_rbia_level WHERE rbia_methodology_id = @rbia_methodology_id;
    DELETE FROM grac_practice.org_assurance_rbia_band WHERE rbia_methodology_id = @rbia_methodology_id;
    UPDATE grac_practice.org_assurance_rbia_history SET rbia_methodology_id = NULL WHERE rbia_methodology_id = @rbia_methodology_id;
    DELETE FROM grac_practice.org_assurance_rbia_methodology WHERE rbia_methodology_id = @rbia_methodology_id;
    INSERT INTO grac_practice.org_assurance_rbia_history (organization_id, action_code, comment, employee_id, actor_name)
    VALUES (@organization_id, N'METHOD_DISCARD', N'Draft discarded', @employee_id, @me);
    COMMIT;
END
GO

-- =====================================================================
-- 5. Assessment procedures
-- =====================================================================

-- 5a. Scores of one assessment (see the header). Internal.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_rbia_assessment_compute
    @rbia_assessment_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @m BIGINT, @agg NVARCHAR(20), @res NVARCHAR(20), @red DECIMAL(5,2), @levels INT;
    SELECT @m = a.rbia_methodology_id, @agg = mt.inherent_aggregation, @res = mt.residual_method, @red = mt.max_reduction_pct
      FROM grac_practice.org_assurance_rbia_assessment a
      JOIN grac_practice.org_assurance_rbia_methodology mt ON mt.rbia_methodology_id = a.rbia_methodology_id
     WHERE a.rbia_assessment_id = @rbia_assessment_id;
    SET @levels = (SELECT MAX(level_value) FROM grac_practice.org_assurance_rbia_level WHERE rbia_methodology_id = @m);

    -- answer scores
    UPDATE r
       SET answer_score = CASE WHEN r.is_not_applicable = 1 THEN NULL
                               WHEN q.answer_mode = N'OPTIONS' THEN o.option_score
                               WHEN r.level_value IS NOT NULL AND @levels > 1
                                    THEN CAST((r.level_value - 1) * 100.0 / (@levels - 1) AS DECIMAL(6,2))
                               ELSE NULL END
      FROM grac_practice.org_assurance_rbia_response r
      JOIN grac_practice.org_assurance_rbia_question q ON q.rbia_question_id = r.rbia_question_id
      LEFT JOIN grac_practice.org_assurance_rbia_question_option o ON o.rbia_option_id = r.rbia_option_id
     WHERE r.rbia_assessment_id = @rbia_assessment_id;

    -- parameter scores
    DELETE FROM grac_practice.org_assurance_rbia_score WHERE rbia_assessment_id = @rbia_assessment_id;
    INSERT INTO grac_practice.org_assurance_rbia_score
        (rbia_assessment_id, rbia_parameter_id, parameter_score, weight_pct, answered_count, question_count)
    SELECT @rbia_assessment_id, p.rbia_parameter_id,
           CAST(SUM(CASE WHEN r.answer_score IS NOT NULL THEN r.answer_score * q.weight END)
                / NULLIF(SUM(CASE WHEN r.answer_score IS NOT NULL THEN q.weight END), 0) AS DECIMAL(6,2)),
           p.weight_pct,
           SUM(CASE WHEN r.answer_score IS NOT NULL OR r.is_not_applicable = 1 THEN 1 ELSE 0 END),
           COUNT(q.rbia_question_id)
      FROM grac_practice.org_assurance_rbia_parameter p
      JOIN grac_practice.org_assurance_rbia_question q ON q.rbia_parameter_id = p.rbia_parameter_id
      LEFT JOIN grac_practice.org_assurance_rbia_response r
             ON r.rbia_question_id = q.rbia_question_id AND r.rbia_assessment_id = @rbia_assessment_id
     WHERE p.rbia_methodology_id = @m
     GROUP BY p.rbia_parameter_id, p.weight_pct;

    DECLARE @inh DECIMAL(9,4), @ce DECIMAL(9,4), @resid DECIMAL(9,4);
    SELECT @inh = CASE @agg
                    WHEN N'MAX' THEN MAX(s.parameter_score)
                    WHEN N'WEIGHTED_SUM' THEN SUM(ISNULL(s.parameter_score, 0) * s.weight_pct) / 100.0
                    ELSE SUM(CASE WHEN s.parameter_score IS NOT NULL THEN s.parameter_score * s.weight_pct END)
                         / NULLIF(SUM(CASE WHEN s.parameter_score IS NOT NULL THEN s.weight_pct END), 0) END
      FROM grac_practice.org_assurance_rbia_score s
      JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = s.rbia_parameter_id AND p.parameter_kind = N'INHERENT'
     WHERE s.rbia_assessment_id = @rbia_assessment_id;
    SELECT @ce = SUM(CASE WHEN s.parameter_score IS NOT NULL THEN s.parameter_score * s.weight_pct END)
                 / NULLIF(SUM(CASE WHEN s.parameter_score IS NOT NULL THEN s.weight_pct END), 0)
      FROM grac_practice.org_assurance_rbia_score s
      JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = s.rbia_parameter_id AND p.parameter_kind = N'CONTROL'
     WHERE s.rbia_assessment_id = @rbia_assessment_id;
    SET @resid = CASE WHEN @inh IS NULL THEN NULL
                      WHEN @res = N'INHERENT_ONLY' THEN @inh
                      WHEN @res = N'SUBTRACT' THEN CASE WHEN @inh - ISNULL(@ce, 0) * @red / 100.0 < 0 THEN 0
                                                        ELSE @inh - ISNULL(@ce, 0) * @red / 100.0 END
                      ELSE @inh * (1 - ISNULL(@ce, 0) / 100.0 * @red / 100.0) END;
    SET @resid = ROUND(@resid, 2);

    DECLARE @band BIGINT = (SELECT TOP (1) b.rbia_band_id FROM grac_practice.org_assurance_rbia_band b
                             WHERE b.rbia_methodology_id = @m AND @resid >= b.min_score AND @resid <= b.max_score
                             ORDER BY b.min_score DESC);
    UPDATE a
       SET inherent_score = ROUND(@inh, 2), control_score = ROUND(@ce, 2), residual_score = @resid,
           system_band_id = @band,
           final_band_id  = ISNULL(a.override_band_id, @band)
      FROM grac_practice.org_assurance_rbia_assessment a
     WHERE a.rbia_assessment_id = @rbia_assessment_id;
    UPDATE a
       SET final_band_name = b.band_name, final_priority = b.audit_priority, frequency_months = b.frequency_months
      FROM grac_practice.org_assurance_rbia_assessment a
      LEFT JOIN grac_practice.org_assurance_rbia_band b ON b.rbia_band_id = a.final_band_id
     WHERE a.rbia_assessment_id = @rbia_assessment_id;
END
GO

-- 5b. The assessments (filters) with the caller's roles.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_rbia_assessment_list
    @organization_id BIGINT,
    @status          NVARCHAR(20)  = NULL,
    @period          NVARCHAR(60)  = NULL,
    @band_code       NVARCHAR(30)  = NULL,
    @current_only    BIT           = 0,
    @search          NVARCHAR(200) = NULL,
    @employee_id     BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @hia BIT = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h
                                          WHERE h.employee_id = @employee_id) THEN 1 ELSE 0 END;
    DECLARE @rev BIT = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'AUDIT_REVIEWER') h
                                          WHERE h.employee_id = @employee_id) THEN 1 ELSE 0 END;
    SELECT a.rbia_assessment_id AS RbiaAssessmentId, a.assessment_ref AS AssessmentRef, a.universe_subject_id AS UniverseSubjectId,
           s.universe_ref AS UniverseRef, s.subject_name AS SubjectName, a.assessment_period AS AssessmentPeriod,
           a.assessment_type AS AssessmentType, a.assessment_version AS AssessmentVersion, m.version_no AS MethodologyVersion,
           a.status AS Status, a.inherent_score AS InherentScore, a.control_score AS ControlScore, a.residual_score AS ResidualScore,
           sb.band_name AS SystemBandName, a.final_band_name AS FinalBandName, fb.band_code AS FinalBandCode,
           a.final_priority AS FinalPriority, a.frequency_months AS FrequencyMonths, a.next_audit_due AS NextAuditDue,
           CAST(CASE WHEN a.override_band_id IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsOverridden,
           a.assessor_employee_id AS AssessorEmployeeId, ae.employee_name AS AssessorName, a.approved_dt AS ApprovedDt,
           a.is_current AS IsCurrent, a.row_version_no AS RowVersionNo, m.require_review AS RequireReview,
           CAST(CASE WHEN a.assessor_employee_id = @employee_id THEN 1 ELSE 0 END AS BIT) AS IsAssessor,
           CAST(CASE WHEN @rev = 1 AND a.assessor_employee_id <> ISNULL(@employee_id, -1) THEN 1 ELSE 0 END AS BIT) AS CanReview,
           CAST(CASE WHEN @hia = 1 AND a.assessor_employee_id <> ISNULL(@employee_id, -1) THEN 1 ELSE 0 END AS BIT) AS CanApprove,
           @hia AS IsHeadOfInternalAudit
      FROM grac_practice.org_assurance_rbia_assessment a
      JOIN grac_practice.org_assurance_universe_subject s ON s.universe_subject_id = a.universe_subject_id
      JOIN grac_practice.org_assurance_rbia_methodology m ON m.rbia_methodology_id = a.rbia_methodology_id
      LEFT JOIN grac_practice.org_assurance_rbia_band sb ON sb.rbia_band_id = a.system_band_id
      LEFT JOIN grac_practice.org_assurance_rbia_band fb ON fb.rbia_band_id = a.final_band_id
      LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = a.assessor_employee_id
     WHERE a.organization_id = @organization_id
       AND (NULLIF(@status, N'') IS NULL OR a.status = @status)
       AND (NULLIF(@period, N'') IS NULL OR a.assessment_period = @period)
       AND (NULLIF(@band_code, N'') IS NULL OR fb.band_code = @band_code)
       AND (ISNULL(@current_only, 0) = 0 OR a.is_current = 1 OR a.status NOT IN (N'Approved', N'Superseded', N'Cancelled'))
       AND (NULLIF(@search, N'') IS NULL OR a.assessment_ref LIKE N'%' + @search + N'%' OR s.universe_ref LIKE N'%' + @search + N'%'
            OR s.subject_name LIKE N'%' + @search + N'%')
     ORDER BY CASE a.status WHEN N'PendingApproval' THEN 0 WHEN N'InReview' THEN 1 WHEN N'Returned' THEN 2 WHEN N'Draft' THEN 3
                            WHEN N'Approved' THEN 4 ELSE 5 END,
              a.residual_score DESC, a.ref_no DESC;
END
GO

-- 5c. Create assessments (one or many): Active subjects, the published
-- methodology, one open assessment per subject (others skipped).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_rbia_assessment_create
    @organization_id      BIGINT,
    @subject_ids_json     NVARCHAR(MAX),
    @assessment_period    NVARCHAR(60),
    @assessment_type      NVARCHAR(20),
    @trigger_reason       NVARCHAR(2000) = NULL,
    @assessor_employee_id BIGINT,
    @employee_id          BIGINT         = NULL,
    @actor                NVARCHAR(100)  = 'system',
    @created_count        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @created_count = 0;
    SET @assessment_type   = UPPER(LTRIM(RTRIM(ISNULL(@assessment_type, N'ANNUAL'))));
    SET @assessment_period = NULLIF(LTRIM(RTRIM(@assessment_period)), N'');
    SET @trigger_reason    = NULLIF(LTRIM(RTRIM(@trigger_reason)), N'');
    IF @assessment_type NOT IN (N'INITIAL', N'ANNUAL', N'EVENT') THROW 54131, 'The type is Initial, Annual or Event-triggered.', 1;
    IF @assessment_period IS NULL THROW 54138, 'Give the assessment period (e.g. FY 2026-27).', 1;
    IF @assessment_type = N'EVENT' AND @trigger_reason IS NULL THROW 54138, 'Give the event that triggers the reassessment.', 1;
    IF ISJSON(ISNULL(@subject_ids_json, N'')) = 0 THROW 54140, 'Select at least one subject.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @assessor_employee_id AND organization_id = @organization_id)
        THROW 54141, 'The assessor is not a person of this organization.', 1;
    DECLARE @m BIGINT = (SELECT rbia_methodology_id FROM grac_practice.org_assurance_rbia_methodology
                          WHERE organization_id = @organization_id AND status = N'Published');
    IF @m IS NULL THROW 54132, 'Publish an RBIA methodology first (RBIA Configuration).', 1;

    DECLARE @ids TABLE(seq INT IDENTITY(1,1), sid BIGINT);
    INSERT INTO @ids (sid)
    SELECT DISTINCT TRY_CAST(j.value AS BIGINT) FROM OPENJSON(@subject_ids_json) j WHERE TRY_CAST(j.value AS BIGINT) IS NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM @ids) THROW 54140, 'Select at least one subject.', 1;
    IF EXISTS (SELECT 1 FROM @ids i WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_subject s
                                                      WHERE s.universe_subject_id = i.sid AND s.organization_id = @organization_id
                                                        AND s.status_code = N'ACTIVE'))
        THROW 54141, 'Only Active Audit Universe subjects of this organization are assessed.', 1;

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    DECLARE @seq INT = 1, @max INT = (SELECT MAX(seq) FROM @ids), @sid BIGINT, @ref INT, @prev BIGINT, @ver INT, @aid BIGINT;
    BEGIN TRAN;
    WHILE @seq <= @max
    BEGIN
        SET @sid = (SELECT sid FROM @ids WHERE seq = @seq);
        IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_assessment
                        WHERE universe_subject_id = @sid AND status IN (N'Draft', N'InReview', N'PendingApproval', N'Returned'))
        BEGIN
            SET @prev = (SELECT TOP (1) rbia_assessment_id FROM grac_practice.org_assurance_rbia_assessment
                          WHERE universe_subject_id = @sid AND status = N'Approved' AND is_current = 1);
            SET @ver = ISNULL((SELECT MAX(assessment_version) FROM grac_practice.org_assurance_rbia_assessment WHERE universe_subject_id = @sid), 0) + 1;
            SET @ref = ISNULL((SELECT MAX(ref_no) FROM grac_practice.org_assurance_rbia_assessment WITH (UPDLOCK, HOLDLOCK)
                                WHERE organization_id = @organization_id), 0) + 1;
            INSERT INTO grac_practice.org_assurance_rbia_assessment
                (organization_id, ref_no, assessment_ref, universe_subject_id, rbia_methodology_id, assessment_version, previous_assessment_id,
                 assessment_period, assessment_type, trigger_reason, assessor_employee_id, entered_by)
            VALUES (@organization_id, @ref, N'RBIA-' + RIGHT(N'00000' + CAST(@ref AS NVARCHAR(10)), 5), @sid, @m, @ver, @prev,
                    @assessment_period, CASE WHEN @prev IS NULL AND @assessment_type = N'ANNUAL' AND @ver = 1 THEN N'INITIAL' ELSE @assessment_type END,
                    @trigger_reason, @assessor_employee_id, @actor);
            SET @aid = SCOPE_IDENTITY();
            INSERT INTO grac_practice.org_assurance_rbia_history
                (organization_id, rbia_assessment_id, action_code, to_status, comment, employee_id, actor_name)
            VALUES (@organization_id, @aid, N'CREATE', N'Draft', @assessment_period + ISNULL(N' -- ' + @trigger_reason, N''), @employee_id, @me);
            SET @created_count = @created_count + 1;
        END
        SET @seq = @seq + 1;
    END
    COMMIT;
END
GO

-- 5d. One assessment: header (+ roles), its methodology, questions with the
-- answers, options, parameter scores, bands, scale, history, previous one.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_rbia_assessment_get
    @organization_id    BIGINT,
    @rbia_assessment_id BIGINT,
    @employee_id        BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @m BIGINT = (SELECT rbia_methodology_id FROM grac_practice.org_assurance_rbia_assessment
                          WHERE rbia_assessment_id = @rbia_assessment_id AND organization_id = @organization_id);
    IF @m IS NULL THROW 54130, 'The assessment was not found in this organization.', 1;
    DECLARE @hia BIT = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h
                                          WHERE h.employee_id = @employee_id) THEN 1 ELSE 0 END;
    DECLARE @rev BIT = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'AUDIT_REVIEWER') h
                                          WHERE h.employee_id = @employee_id) THEN 1 ELSE 0 END;
    SELECT a.rbia_assessment_id AS RbiaAssessmentId, a.assessment_ref AS AssessmentRef, a.universe_subject_id AS UniverseSubjectId,
           s.universe_ref AS UniverseRef, s.subject_name AS SubjectName, a.assessment_period AS AssessmentPeriod,
           a.assessment_type AS AssessmentType, a.trigger_reason AS TriggerReason, a.assessment_version AS AssessmentVersion,
           a.status AS Status, m.version_no AS MethodologyVersion, m.methodology_name AS MethodologyName,
           m.residual_method AS ResidualMethod, m.inherent_aggregation AS InherentAggregation, m.max_reduction_pct AS MaxReductionPct,
           m.require_review AS RequireReview,
           a.inherent_score AS InherentScore, a.control_score AS ControlScore, a.residual_score AS ResidualScore,
           a.system_band_id AS SystemBandId, sb.band_name AS SystemBandName, a.override_band_id AS OverrideBandId,
           a.override_justification AS OverrideJustification, a.override_evidence AS OverrideEvidence,
           a.final_band_name AS FinalBandName, a.final_priority AS FinalPriority, a.frequency_months AS FrequencyMonths,
           a.next_audit_due AS NextAuditDue, a.is_current AS IsCurrent,
           a.assessor_employee_id AS AssessorEmployeeId, ae.employee_name AS AssessorName,
           re.employee_name AS ReviewerName, a.reviewed_dt AS ReviewedDt, pe.employee_name AS ApproverName, a.approved_dt AS ApprovedDt,
           a.submitted_dt AS SubmittedDt, a.risk_snapshot_json AS RiskSnapshotJson, a.row_version_no AS RowVersionNo,
           a.previous_assessment_id AS PreviousAssessmentId, pa.assessment_ref AS PreviousRef, pa.final_band_name AS PreviousBandName,
           pa.residual_score AS PreviousResidualScore, pa.approved_dt AS PreviousApprovedDt,
           CAST(CASE WHEN a.assessor_employee_id = @employee_id THEN 1 ELSE 0 END AS BIT) AS IsAssessor,
           CAST(CASE WHEN @rev = 1 AND a.assessor_employee_id <> ISNULL(@employee_id, -1) THEN 1 ELSE 0 END AS BIT) AS CanReview,
           CAST(CASE WHEN @hia = 1 AND a.assessor_employee_id <> ISNULL(@employee_id, -1) THEN 1 ELSE 0 END AS BIT) AS CanApprove,
           @hia AS IsHeadOfInternalAudit
      FROM grac_practice.org_assurance_rbia_assessment a
      JOIN grac_practice.org_assurance_universe_subject s ON s.universe_subject_id = a.universe_subject_id
      JOIN grac_practice.org_assurance_rbia_methodology m ON m.rbia_methodology_id = a.rbia_methodology_id
      LEFT JOIN grac_practice.org_assurance_rbia_band sb ON sb.rbia_band_id = a.system_band_id
      LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = a.assessor_employee_id
      LEFT JOIN grac_practice.organization_employee re ON re.employee_id = a.reviewer_employee_id
      LEFT JOIN grac_practice.organization_employee pe ON pe.employee_id = a.approver_employee_id
      LEFT JOIN grac_practice.org_assurance_rbia_assessment pa ON pa.rbia_assessment_id = a.previous_assessment_id
     WHERE a.rbia_assessment_id = @rbia_assessment_id;

    SELECT p.rbia_parameter_id AS RbiaParameterId, p.parameter_code AS ParameterCode, p.parameter_name AS ParameterName,
           p.assessment_focus AS AssessmentFocus, p.parameter_kind AS ParameterKind, p.weight_pct AS WeightPct,
           sc.parameter_score AS ParameterScore, sc.answered_count AS AnsweredCount, sc.question_count AS QuestionCount
      FROM grac_practice.org_assurance_rbia_parameter p
      LEFT JOIN grac_practice.org_assurance_rbia_score sc ON sc.rbia_parameter_id = p.rbia_parameter_id AND sc.rbia_assessment_id = @rbia_assessment_id
     WHERE p.rbia_methodology_id = @m
     ORDER BY CASE p.parameter_kind WHEN N'INHERENT' THEN 0 ELSE 1 END, p.display_order;

    SELECT q.rbia_question_id AS RbiaQuestionId, q.rbia_parameter_id AS RbiaParameterId, q.question_text AS QuestionText,
           q.guidance AS Guidance, q.evidence_expectation AS EvidenceExpectation, q.answer_mode AS AnswerMode, q.weight AS Weight,
           q.indicator_code AS IndicatorCode, r.level_value AS LevelValue, r.rbia_option_id AS RbiaOptionId,
           ISNULL(r.is_not_applicable, 0) AS IsNotApplicable, r.answer_score AS AnswerScore, r.comment AS Comment,
           r.evidence_reference AS EvidenceReference
      FROM grac_practice.org_assurance_rbia_question q
      JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = q.rbia_parameter_id
      LEFT JOIN grac_practice.org_assurance_rbia_response r ON r.rbia_question_id = q.rbia_question_id AND r.rbia_assessment_id = @rbia_assessment_id
     WHERE p.rbia_methodology_id = @m
     ORDER BY q.rbia_parameter_id, q.display_order, q.rbia_question_id;

    SELECT o.rbia_option_id AS RbiaOptionId, o.rbia_question_id AS RbiaQuestionId, o.option_label AS OptionLabel, o.option_score AS OptionScore
      FROM grac_practice.org_assurance_rbia_question_option o
      JOIN grac_practice.org_assurance_rbia_question q ON q.rbia_question_id = o.rbia_question_id
      JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = q.rbia_parameter_id
     WHERE p.rbia_methodology_id = @m
     ORDER BY o.rbia_question_id, o.display_order;

    SELECT level_value AS LevelValue, level_name AS LevelName, description AS Description
      FROM grac_practice.org_assurance_rbia_level WHERE rbia_methodology_id = @m ORDER BY level_value;
    SELECT rbia_band_id AS RbiaBandId, band_code AS BandCode, band_name AS BandName, min_score AS MinScore, max_score AS MaxScore,
           audit_priority AS AuditPriority, frequency_months AS FrequencyMonths
      FROM grac_practice.org_assurance_rbia_band WHERE rbia_methodology_id = @m ORDER BY min_score;
    SELECT action_code AS ActionCode, from_status AS FromStatus, to_status AS ToStatus, comment AS Comment,
           actor_name AS ActorName, action_dt AS ActionDt
      FROM grac_practice.org_assurance_rbia_history WHERE rbia_assessment_id = @rbia_assessment_id
     ORDER BY action_dt DESC, rbia_history_id DESC;
END
GO

-- 5e. Save answers and the proposed override (the assessor; Draft /
-- Returned): @responses_json [{ questionId, levelValue, optionId,
-- notApplicable, comment, evidenceReference }];
-- @override_json { bandId (null = none), justification, evidence }.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_rbia_assessment_save
    @organization_id    BIGINT,
    @rbia_assessment_id BIGINT,
    @row_version_no     INT,
    @responses_json     NVARCHAR(MAX) = NULL,
    @override_json      NVARCHAR(MAX) = NULL,
    @employee_id        BIGINT,
    @actor              NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @status NVARCHAR(20), @assessor BIGINT, @rv INT, @m BIGINT, @levels INT;
    SELECT @status = status, @assessor = assessor_employee_id, @rv = row_version_no, @m = rbia_methodology_id
      FROM grac_practice.org_assurance_rbia_assessment
     WHERE rbia_assessment_id = @rbia_assessment_id AND organization_id = @organization_id;
    IF @status IS NULL THROW 54130, 'The assessment was not found in this organization.', 1;
    IF @status NOT IN (N'Draft', N'Returned') THROW 54131, 'The assessment can be changed only while Draft or Returned.', 1;
    IF @assessor <> @employee_id THROW 54134, 'Only the assessor answers the assessment.', 1;
    IF @row_version_no IS NULL OR @row_version_no <> @rv THROW 54139, 'The assessment was changed by someone else. Reload it.', 1;
    SET @levels = (SELECT MAX(level_value) FROM grac_practice.org_assurance_rbia_level WHERE rbia_methodology_id = @m);

    DECLARE @r TABLE(qid BIGINT PRIMARY KEY, lv INT, oid BIGINT, na BIT, cm NVARCHAR(2000), ev NVARCHAR(1000));
    IF ISJSON(ISNULL(@responses_json, N'')) = 1
        INSERT INTO @r (qid, lv, oid, na, cm, ev)
        SELECT j.qid, MAX(j.lv), MAX(j.oid), MAX(CAST(ISNULL(j.na, 0) AS INT)), MAX(NULLIF(LTRIM(RTRIM(j.cm)), N'')), MAX(NULLIF(LTRIM(RTRIM(j.ev)), N''))
          FROM OPENJSON(@responses_json) WITH (qid BIGINT '$.questionId', lv INT '$.levelValue', oid BIGINT '$.optionId',
                                                na BIT '$.notApplicable', cm NVARCHAR(2000) '$.comment', ev NVARCHAR(1000) '$.evidenceReference') j
         WHERE j.qid IS NOT NULL
         GROUP BY j.qid;
    IF EXISTS (SELECT 1 FROM @r r WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_question q
                                                      JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = q.rbia_parameter_id
                                                     WHERE q.rbia_question_id = r.qid AND p.rbia_methodology_id = @m))
        THROW 54133, 'An answer is for a question of another methodology.', 1;
    IF EXISTS (SELECT 1 FROM @r r JOIN grac_practice.org_assurance_rbia_question q ON q.rbia_question_id = r.qid
                WHERE r.na = 0 AND ((q.answer_mode = N'SCALE' AND r.lv IS NOT NULL AND (r.lv < 1 OR r.lv > @levels))
                                 OR (q.answer_mode = N'OPTIONS' AND r.oid IS NOT NULL
                                     AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_question_option o
                                                      WHERE o.rbia_option_id = r.oid AND o.rbia_question_id = q.rbia_question_id))))
        THROW 54133, 'An answer is not one of the question''s choices.', 1;

    DECLARE @ob BIGINT = NULL, @oj NVARCHAR(2000) = NULL, @oe NVARCHAR(2000) = NULL, @set_override BIT = 0;
    IF ISJSON(ISNULL(@override_json, N'')) = 1
    BEGIN
        SET @set_override = 1;
        SET @ob = TRY_CAST(JSON_VALUE(@override_json, '$.bandId') AS BIGINT);
        SET @oj = NULLIF(LTRIM(RTRIM(JSON_VALUE(@override_json, '$.justification'))), N'');
        SET @oe = NULLIF(LTRIM(RTRIM(JSON_VALUE(@override_json, '$.evidence'))), N'');
        IF @ob IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_band WHERE rbia_band_id = @ob AND rbia_methodology_id = @m)
            THROW 54133, 'The override band is not one of the methodology''s bands.', 1;
        IF @ob IS NOT NULL AND @oj IS NULL THROW 54142, 'An override needs a justification.', 1;
    END

    BEGIN TRAN;
    MERGE grac_practice.org_assurance_rbia_response AS t
    USING @r AS s ON t.rbia_assessment_id = @rbia_assessment_id AND t.rbia_question_id = s.qid
    WHEN MATCHED THEN UPDATE SET level_value = CASE WHEN s.na = 1 THEN NULL ELSE s.lv END,
                                 rbia_option_id = CASE WHEN s.na = 1 THEN NULL ELSE s.oid END,
                                 is_not_applicable = s.na, comment = s.cm, evidence_reference = s.ev,
                                 updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (rbia_assessment_id, rbia_question_id, level_value, rbia_option_id, is_not_applicable, comment, evidence_reference, updated_by, updated_dt)
         VALUES (@rbia_assessment_id, s.qid, CASE WHEN s.na = 1 THEN NULL ELSE s.lv END, CASE WHEN s.na = 1 THEN NULL ELSE s.oid END,
                 s.na, s.cm, s.ev, @actor, SYSUTCDATETIME());
    UPDATE grac_practice.org_assurance_rbia_assessment
       SET override_band_id       = CASE WHEN @set_override = 1 THEN @ob ELSE override_band_id END,
           override_justification = CASE WHEN @set_override = 1 THEN CASE WHEN @ob IS NULL THEN NULL ELSE @oj END ELSE override_justification END,
           override_evidence      = CASE WHEN @set_override = 1 THEN CASE WHEN @ob IS NULL THEN NULL ELSE @oe END ELSE override_evidence END,
           row_version_no = row_version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE rbia_assessment_id = @rbia_assessment_id;
    EXEC grac_practice.sp_org_assurance_rbia_assessment_compute @rbia_assessment_id = @rbia_assessment_id;
    COMMIT;
END
GO

-- 5f. The workflow (see the header). @risk_snapshot_json: APPROVE only --
-- the Api passes 581's risk intelligence of the subject at that moment.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_rbia_assessment_action
    @organization_id    BIGINT,
    @rbia_assessment_id BIGINT,
    @action             NVARCHAR(20),
    @comment            NVARCHAR(MAX) = NULL,
    @row_version_no     INT           = NULL,
    @risk_snapshot_json NVARCHAR(MAX) = NULL,
    @employee_id        BIGINT,
    @actor              NVARCHAR(100) = 'system',
    @new_assessment_id  BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @new_assessment_id = NULL;
    SET @action  = UPPER(LTRIM(RTRIM(@action)));
    SET @comment = NULLIF(LTRIM(RTRIM(@comment)), N'');
    IF @action NOT IN (N'SUBMIT', N'REVIEW', N'APPROVE', N'RETURN', N'CANCEL', N'REASSESS') THROW 54131, 'Unknown action.', 1;
    DECLARE @status NVARCHAR(20), @assessor BIGINT, @rv INT, @m BIGINT, @sid BIGINT, @review BIT, @cur BIT;
    SELECT @status = a.status, @assessor = a.assessor_employee_id, @rv = a.row_version_no, @m = a.rbia_methodology_id,
           @sid = a.universe_subject_id, @review = mt.require_review, @cur = a.is_current
      FROM grac_practice.org_assurance_rbia_assessment a
      JOIN grac_practice.org_assurance_rbia_methodology mt ON mt.rbia_methodology_id = a.rbia_methodology_id
     WHERE a.rbia_assessment_id = @rbia_assessment_id AND a.organization_id = @organization_id;
    IF @status IS NULL THROW 54130, 'The assessment was not found in this organization.', 1;
    IF @row_version_no IS NOT NULL AND @row_version_no <> @rv THROW 54139, 'The assessment was changed by someone else. Reload it.', 1;
    DECLARE @hia BIT = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h
                                          WHERE h.employee_id = @employee_id) THEN 1 ELSE 0 END;
    DECLARE @rev BIT = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'AUDIT_REVIEWER') h
                                          WHERE h.employee_id = @employee_id) THEN 1 ELSE 0 END;
    DECLARE @to NVARCHAR(20) = CASE @action WHEN N'SUBMIT' THEN CASE WHEN @review = 1 THEN N'InReview' ELSE N'PendingApproval' END
                                            WHEN N'REVIEW' THEN N'PendingApproval' WHEN N'APPROVE' THEN N'Approved'
                                            WHEN N'RETURN' THEN N'Returned' WHEN N'CANCEL' THEN N'Cancelled' ELSE @status END;

    IF (@action = N'SUBMIT' AND @status NOT IN (N'Draft', N'Returned'))
       OR (@action = N'REVIEW' AND @status <> N'InReview')
       OR (@action = N'APPROVE' AND @status <> N'PendingApproval')
       OR (@action = N'RETURN' AND @status NOT IN (N'InReview', N'PendingApproval'))
       OR (@action = N'CANCEL' AND @status NOT IN (N'Draft', N'Returned'))
       OR (@action = N'REASSESS' AND NOT (@status = N'Approved' AND @cur = 1))
        THROW 54131, 'The assessment is not in a state that allows this.', 1;
    IF @action IN (N'SUBMIT', N'CANCEL') AND @assessor <> @employee_id AND @hia = 0
        THROW 54134, 'Only the assessor (or the Head of Internal Audit) does this.', 1;
    IF (@action = N'REVIEW' OR (@action = N'RETURN' AND @status = N'InReview')) AND (@rev = 0 OR @assessor = @employee_id)
        THROW 54135, 'Only an Audit Reviewer who is not the assessor reviews the assessment.', 1;
    IF (@action = N'APPROVE' OR (@action = N'RETURN' AND @status = N'PendingApproval')) AND (@hia = 0 OR @assessor = @employee_id)
        THROW 54136, 'Only the Head of Internal Audit (or a delegate), not the assessor, approves the assessment.', 1;
    IF @action = N'REASSESS' AND @hia = 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'AUDITOR') h
                                                           WHERE h.employee_id = @employee_id)
        THROW 54134, 'Only an auditor or the Head of Internal Audit starts a reassessment.', 1;
    IF @action IN (N'RETURN', N'CANCEL', N'REASSESS') AND @comment IS NULL THROW 54138, 'Give the reason.', 1;
    IF @action = N'SUBMIT'
       AND EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_question q
                     JOIN grac_practice.org_assurance_rbia_parameter p ON p.rbia_parameter_id = q.rbia_parameter_id
                     LEFT JOIN grac_practice.org_assurance_rbia_response r
                            ON r.rbia_question_id = q.rbia_question_id AND r.rbia_assessment_id = @rbia_assessment_id
                    WHERE p.rbia_methodology_id = @m
                      AND (r.rbia_response_id IS NULL OR (r.is_not_applicable = 0 AND r.answer_score IS NULL)))
        THROW 54137, 'Answer every question (or mark it not applicable) before submitting.', 1;
    IF @action = N'SUBMIT'
       AND (SELECT residual_score FROM grac_practice.org_assurance_rbia_assessment WHERE rbia_assessment_id = @rbia_assessment_id) IS NULL
        THROW 54137, 'The inherent risk could not be scored: answer at least one inherent question.', 1;

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    DECLARE @msnap NVARCHAR(MAX);
    IF @action = N'APPROVE'
        SET @msnap = (SELECT mt.version_no AS versionNo, mt.methodology_name AS methodologyName, mt.inherent_aggregation AS inherentAggregation,
                             mt.residual_method AS residualMethod, mt.max_reduction_pct AS maxReductionPct,
                             (SELECT l.level_value AS levelValue, l.level_name AS levelName FROM grac_practice.org_assurance_rbia_level l
                               WHERE l.rbia_methodology_id = mt.rbia_methodology_id ORDER BY l.level_value FOR JSON PATH) AS levels,
                             (SELECT p.parameter_code AS parameterCode, p.parameter_name AS parameterName, p.parameter_kind AS parameterKind,
                                     p.weight_pct AS weightPct, sc.parameter_score AS parameterScore
                                FROM grac_practice.org_assurance_rbia_parameter p
                                LEFT JOIN grac_practice.org_assurance_rbia_score sc
                                       ON sc.rbia_parameter_id = p.rbia_parameter_id AND sc.rbia_assessment_id = @rbia_assessment_id
                               WHERE p.rbia_methodology_id = mt.rbia_methodology_id ORDER BY p.display_order FOR JSON PATH) AS parameters,
                             (SELECT b.band_code AS bandCode, b.band_name AS bandName, b.min_score AS minScore, b.max_score AS maxScore,
                                     b.audit_priority AS auditPriority, b.frequency_months AS frequencyMonths
                                FROM grac_practice.org_assurance_rbia_band b WHERE b.rbia_methodology_id = mt.rbia_methodology_id
                               ORDER BY b.min_score FOR JSON PATH) AS bands
                        FROM grac_practice.org_assurance_rbia_methodology mt WHERE mt.rbia_methodology_id = @m
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;
    IF @action = N'REASSESS'
    BEGIN
        DECLARE @pub BIGINT = (SELECT rbia_methodology_id FROM grac_practice.org_assurance_rbia_methodology
                                WHERE organization_id = @organization_id AND status = N'Published');
        IF @pub IS NULL THROW 54132, 'There is no published methodology.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_assessment
                    WHERE universe_subject_id = @sid AND status IN (N'Draft', N'InReview', N'PendingApproval', N'Returned'))
            THROW 54131, 'The subject already has an open assessment.', 1;
        DECLARE @ref INT = ISNULL((SELECT MAX(ref_no) FROM grac_practice.org_assurance_rbia_assessment WITH (UPDLOCK, HOLDLOCK)
                                    WHERE organization_id = @organization_id), 0) + 1;
        INSERT INTO grac_practice.org_assurance_rbia_assessment
            (organization_id, ref_no, assessment_ref, universe_subject_id, rbia_methodology_id, assessment_version, previous_assessment_id,
             assessment_period, assessment_type, trigger_reason, assessor_employee_id, entered_by)
        SELECT @organization_id, @ref, N'RBIA-' + RIGHT(N'00000' + CAST(@ref AS NVARCHAR(10)), 5), a.universe_subject_id, @pub,
               (SELECT MAX(x.assessment_version) FROM grac_practice.org_assurance_rbia_assessment x WHERE x.universe_subject_id = a.universe_subject_id) + 1,
               a.rbia_assessment_id, a.assessment_period, N'EVENT', @comment, @employee_id, @actor
          FROM grac_practice.org_assurance_rbia_assessment a WHERE a.rbia_assessment_id = @rbia_assessment_id;
        SET @new_assessment_id = SCOPE_IDENTITY();
        -- the previous answers carry over when the methodology is the same version
        IF @pub = @m
            INSERT INTO grac_practice.org_assurance_rbia_response
                (rbia_assessment_id, rbia_question_id, level_value, rbia_option_id, is_not_applicable, comment, evidence_reference, updated_by, updated_dt)
            SELECT @new_assessment_id, r.rbia_question_id, r.level_value, r.rbia_option_id, r.is_not_applicable, r.comment, r.evidence_reference,
                   @actor, SYSUTCDATETIME()
              FROM grac_practice.org_assurance_rbia_response r WHERE r.rbia_assessment_id = @rbia_assessment_id;
        EXEC grac_practice.sp_org_assurance_rbia_assessment_compute @rbia_assessment_id = @new_assessment_id;
        INSERT INTO grac_practice.org_assurance_rbia_history (organization_id, rbia_assessment_id, action_code, to_status, comment, employee_id, actor_name)
        VALUES (@organization_id, @new_assessment_id, N'CREATE', N'Draft', N'Reassessment of the approved assessment -- ' + @comment, @employee_id, @me),
               (@organization_id, @rbia_assessment_id, N'REASSESS', @status, @comment, @employee_id, @me);
        COMMIT;
        RETURN;
    END

    IF @action = N'APPROVE'
    BEGIN
        UPDATE grac_practice.org_assurance_rbia_assessment
           SET status = N'Superseded', is_current = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE universe_subject_id = @sid AND is_current = 1 AND rbia_assessment_id <> @rbia_assessment_id;
    END
    UPDATE grac_practice.org_assurance_rbia_assessment
       SET status               = @to,
           submitted_dt         = CASE WHEN @action = N'SUBMIT' THEN SYSUTCDATETIME() ELSE submitted_dt END,
           reviewer_employee_id = CASE WHEN @action = N'REVIEW' THEN @employee_id ELSE reviewer_employee_id END,
           reviewed_dt          = CASE WHEN @action = N'REVIEW' THEN SYSUTCDATETIME() ELSE reviewed_dt END,
           approver_employee_id = CASE WHEN @action = N'APPROVE' THEN @employee_id ELSE approver_employee_id END,
           approved_dt          = CASE WHEN @action = N'APPROVE' THEN SYSUTCDATETIME() ELSE approved_dt END,
           next_audit_due       = CASE WHEN @action = N'APPROVE' AND frequency_months IS NOT NULL
                                       THEN DATEADD(MONTH, frequency_months, CAST(SYSUTCDATETIME() AS DATE)) ELSE next_audit_due END,
           is_current           = CASE WHEN @action = N'APPROVE' THEN 1 ELSE is_current END,
           risk_snapshot_json   = CASE WHEN @action = N'APPROVE' THEN ISNULL(@risk_snapshot_json, N'{}') ELSE risk_snapshot_json END,
           methodology_snapshot_json = CASE WHEN @action = N'APPROVE' THEN @msnap ELSE methodology_snapshot_json END,
           row_version_no       = row_version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE rbia_assessment_id = @rbia_assessment_id;
    INSERT INTO grac_practice.org_assurance_rbia_history
        (organization_id, rbia_assessment_id, action_code, from_status, to_status, comment, employee_id, actor_name)
    VALUES (@organization_id, @rbia_assessment_id, @action, @status, @to,
            CASE WHEN @action = N'APPROVE' AND EXISTS (SELECT 1 FROM grac_practice.org_assurance_rbia_assessment
                                                        WHERE rbia_assessment_id = @rbia_assessment_id AND override_band_id IS NOT NULL)
                 THEN N'Approved with the override to ' + ISNULL((SELECT final_band_name FROM grac_practice.org_assurance_rbia_assessment
                                                                   WHERE rbia_assessment_id = @rbia_assessment_id), N'') + ISNULL(N'. ' + @comment, N'')
                 ELSE @comment END,
            @employee_id, @me);
    COMMIT;
END
GO

-- =====================================================================
-- 6. Menus: Audit Intelligence -> RBIA Configuration (50), RBIA
--    Assessment (60); the Audit Plans permissions copied; also in 274.
-- =====================================================================
DECLARE @intel_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-audit-intelligence');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'org-audit-rbia-config',     N'RBIA Configuration', N'Practice/org-audit-rbia-config',     50, N'sliders'),
    (N'org-audit-rbia-assessment', N'RBIA Assessment',    N'Practice/org-audit-rbia-assessment', 60, N'gauge-high')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @intel_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Audit Assurance',
    status = N'Active', updated_by = 'seed-582', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @intel_id, src.display_order,
     src.icon_class, N'Audit Assurance', N'Active', 'seed-582');
PRINT '582.6: RBIA menu rows upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT p.role_id, m.menu_id, p.can_view, p.can_add, p.can_edit, p.can_delete, p.can_approve,
       p.status, p.record_status_id, N'seed-582', SYSUTCDATETIME()
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master pm ON pm.menu_id = p.menu_id AND pm.menu_key = N'org-assurance-plans'
JOIN   grac_practice.menu_master m  ON m.menu_key IN (N'org-audit-rbia-config', N'org-audit-rbia-assessment')
WHERE  NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission x
        WHERE x.role_id = p.role_id AND x.menu_id = m.menu_id);
PRINT '582.6: RBIA permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 7. Verification
-- =====================================================================
DECLARE @missing NVARCHAR(MAX) = N'';
SELECT @missing = @missing + n.name + N' '
  FROM (VALUES (N'fn_org_assurance_rbia_subject_current'), (N'sp_org_assurance_rbia_methodology_list'),
               (N'sp_org_assurance_rbia_methodology_get'), (N'sp_org_assurance_rbia_methodology_save'),
               (N'sp_org_assurance_rbia_methodology_draft'), (N'sp_org_assurance_rbia_methodology_publish'),
               (N'sp_org_assurance_rbia_methodology_discard'), (N'sp_org_assurance_rbia_assessment_compute'),
               (N'sp_org_assurance_rbia_assessment_list'), (N'sp_org_assurance_rbia_assessment_create'),
               (N'sp_org_assurance_rbia_assessment_get'), (N'sp_org_assurance_rbia_assessment_save'),
               (N'sp_org_assurance_rbia_assessment_action')) n(name)
 WHERE OBJECT_ID(N'grac_practice.' + n.name) IS NULL;
IF @missing <> N'' RAISERROR('582 verification: missing objects: %s', 16, 1, @missing);
SELECT (SELECT COUNT(*) FROM grac_practice.menu_master
         WHERE menu_key IN (N'org-audit-rbia-config', N'org-audit-rbia-assessment') AND status = N'Active') AS menu_rows;
PRINT '582 done: Audit Intelligence -- RBIA methodology (versioned, RBI preset) and assessments (review, approval, overrides, snapshots).';
GO
