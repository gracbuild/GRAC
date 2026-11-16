-- =====================================================================
-- 523_tpm_cr2_screening_admission.sql
--
-- REQUEST (2026-11-08)
-- --------------------
--   "Change Document -- GRAC Third-Party Management (TPM) Redesign"
--   (CR 2), ROUND B -- sections 6 and 7: Initial Exposure Screening, the
--   client TPRM applicability decision and formal TPRM admission through
--   the configured approval rules. Design: docs/tpm-lifecycle-redesign.md
--   sections 6, 7 and 15.3. Round C (TP Risk Register) follows.
--
-- WHAT CHANGES
-- ------------
--   1. Screening (CR 2 6). Saving Scope & Exposure generates an Initial
--      Exposure Screening Report automatically (sp_tprm_screening_run,
--      called by the re-issued sp_tprm_engagement_exposure_save); it can
--      also be refreshed. Reports are versioned and never updated
--      (tprm_screening_report) and hold observations
--      (tprm_screening_observation) with section, dimension, origin
--      (PROPOSED = declared by the business / DISCOVERED = GRAC
--      correlation), significance, source, verification status and
--      evidence reference. Classification: FURTHER_INFORMATION_REQUIRED
--      (any information gap), POTENTIAL_TPRM_CASE (any HIGH indicator),
--      NO_SIGNIFICANT_INDICATORS. The indicators and their thresholds are
--      the new list SCREENING_INDICATOR (hide a value to switch the
--      indicator off; its rank is the threshold). The classification is
--      informational: it changes nothing else.
--   2. Discovery (CR 2 6.3). sp_tprm_engagement_discover also follows
--      the engagement's business functions and processes to practice
--      instances, and can hand its results to a caller (#tprm_discovery,
--      @suppress_result) instead of returning them.
--   3. Applicability decision (CR 2 7). tprm_applicability_decision:
--      INCLUDE / EXCLUDE / DEFER with rationale, decision-maker, decision
--      date, evidence references, approval reference, the report it was
--      made on, and (DEFER) the information requested. A revised decision
--      supersedes the previous one; nothing is deleted. The engagement's
--      applicability status: NOT_SCREENED, SCREENED, EXCLUDED, DEFERRED,
--      ADMISSION_PENDING, ADMITTED, ADMISSION_REJECTED.
--   4. Admission (CR 2 7.1, decision Q7). INCLUDE opens an admission
--      (tprm_admission + tprm_admission_approval) under the approval rule
--      matched on the service criticality (tprm_approval_rule: levels,
--      roles, segregation of duties) with delegations
--      (tprm_approval_delegation). Final approval sets ADMITTED -- Round C
--      creates / links the TP Risk Register record. The inherent risk
--      assessment (and so the whole formal TPRM lifecycle) is offered only
--      to an ADMITTED engagement.
--   5. Existing engagements: those past scoping (or with a risk
--      assessment) are treated as ADMITTED; scoping ones with Scope &
--      Exposure saved are screened now. Sample engagements
--      (sp_tprm_sample_load, re-issued) are screened when loaded.
--   6. Decision, approval and withdrawal re-check the engagement and the
--      admission under locks (UPDLOCK) inside their transaction, so a
--      concurrent decision, approval or closure cannot be overwritten.
--
-- RUN ORDER: after 522. Re-running the regenerated 487 (list
-- SCREENING_INDICATOR) is optional -- this file adds the list itself.
-- ERROR NUMBERS: 58100-58149.
-- DEPENDS ON: 486-490, 507, 521, 522.
-- Rollback: 523_tpm_cr2_screening_admission_rollback.sql
-- Refuses to re-run once 524 is applied.
-- SAFE TO RE-RUN. ASCII-only. SQL Server 2017+.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF COL_LENGTH('grac_practice.tprm_engagement', 'exposure_saved_dt') IS NULL
   OR OBJECT_ID('grac_practice.sp_tprm_engagement_exposure_save', 'P') IS NULL
BEGIN PRINT 'ABORT (523): run 522_tpm_cr2_registration_exposure.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.tprm_approval_rule','U') IS NULL OR OBJECT_ID('grac_practice.fn_tprm_match_approval_rule') IS NULL
BEGIN PRINT 'ABORT (523): the TPRM approval rules (486 / 489) are missing.'; SET @ok = 0; END
-- 524 re-issues sp_tprm_admission_act and sp_tprm_engagement_get (register
-- link); running 523 again would take that out.
IF OBJECT_ID('grac_practice.tprm_risk_register', 'U') IS NOT NULL
BEGIN PRINT 'ABORT (523): superseded by 524_tpm_cr2_risk_register.sql, which is already applied. Do not re-run 523.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('523_tpm_cr2_screening_admission: prerequisites missing -- see the messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Configuration: screening indicators (also in the regenerated 487)
-- =====================================================================
MERGE grac_practice.tprm_reference_list AS t
USING (VALUES
    (N'SCREENING_INDICATOR', N'Screening indicators',
     N'Exposure indicators of the Initial Exposure Screening. Each value is an indicator (its meaning); the rank is its threshold where it has one. Hide a value to switch the indicator off -- the observation is still reported, without making the engagement a potential TPRM case.',
     N'MEANING', N'CRITICALITY,DATA,ACCESS,CUSTOMER_IMPACT,SUBSTITUTABILITY,IMPORTANT_PROCESS,FOURTH_PARTY_DATA,DISCOVERED_CRITICAL_INSTANCE,DISCOVERED_OPEN_FINDING', 230)
) AS s(list_code, list_name, description, scope_rule, allowed_meanings, display_order)
ON t.list_code = s.list_code
WHEN MATCHED THEN UPDATE SET list_name = s.list_name, description = s.description, scope_rule = s.scope_rule,
    allowed_meanings = s.allowed_meanings, display_order = s.display_order, updated_by = N'migration-523', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (list_code, list_name, description, scope_rule, allowed_meanings, display_order, entered_by)
    VALUES (s.list_code, s.list_name, s.description, s.scope_rule, s.allowed_meanings, s.display_order, N'migration-523');
GO
MERGE grac_practice.tprm_reference_value AS t
USING (VALUES
    (N'CRITICALITY', N'Business criticality', N'Service criticality at or above the rank (CRITICALITY list).', 3, 10),
    (N'DATA', N'Sensitive data', N'A data category at or above the rank (DATA_EXPOSURE list).', 3, 20),
    (N'ACCESS', N'System or privileged access', N'An access category at or above the rank (ACCESS_CATEGORY list).', 3, 30),
    (N'CUSTOMER_IMPACT', N'Customer impact', N'Customer impact at or above the rank (CUSTOMER_IMPACT list).', 3, 40),
    (N'SUBSTITUTABILITY', N'Hard to substitute', N'Substitutability at or above the rank (SUBSTITUTABILITY list).', 3, 50),
    (N'IMPORTANT_PROCESS', N'Important process with disruption impact', N'The service supports an important business process and its disruption affects operations.', NULL, 60),
    (N'FOURTH_PARTY_DATA', N'Subcontracting with data', N'Subcontractors are used and organization or customer data is in scope.', NULL, 70),
    (N'DISCOVERED_CRITICAL_INSTANCE', N'Critical practice instance discovered', N'GRAC finds a practice instance of high or critical criticality behind the engagement''s applications, processes or business functions.', NULL, 80),
    (N'DISCOVERED_OPEN_FINDING', N'Open high assurance finding discovered', N'GRAC finds an open assurance finding of high or critical severity on a related practice instance.', NULL, 90)
) AS s(value_code, label, description, rank_no, display_order)
ON t.organization_id IS NULL AND t.list_code = N'SCREENING_INDICATOR' AND t.value_code = s.value_code
WHEN MATCHED THEN UPDATE SET label = s.label, description = s.description, meaning_code = s.value_code, rank_no = s.rank_no,
    display_order = s.display_order, status = N'Active', updated_by = N'migration-523', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN INSERT
    (list_code, organization_id, value_code, label, description, meaning_code, rank_no, display_order, status, entered_by)
    VALUES (N'SCREENING_INDICATOR', NULL, s.value_code, s.label, s.description, s.value_code, s.rank_no, s.display_order, N'Active', N'migration-523');
PRINT '523: list SCREENING_INDICATOR ready.';
GO

-- =====================================================================
-- 2. Schema
-- =====================================================================
IF OBJECT_ID('grac_practice.tprm_screening_report', 'U') IS NULL
BEGIN
    -- One row per screening run; never updated (CR 2 10-16).
    CREATE TABLE grac_practice.tprm_screening_report(
        report_id                BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_screening_report PRIMARY KEY,
        organization_id          BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_sr_org REFERENCES grac_practice.organization(organization_id),
        engagement_id            BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_sr_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        version_no               INT            NOT NULL,
        classification           NVARCHAR(40)   NOT NULL
            CONSTRAINT ck_pm_tprm_sr_class CHECK (classification IN (N'POTENTIAL_TPRM_CASE', N'NO_SIGNIFICANT_INDICATORS', N'FURTHER_INFORMATION_REQUIRED')),
        trigger_code             NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_tprm_sr_trigger CHECK (trigger_code IN (N'EXPOSURE_SAVED', N'REFRESH', N'MIGRATION')),
        high_count               INT            NOT NULL,
        gap_count                INT            NOT NULL,
        observation_count        INT            NOT NULL,
        summary_json             NVARCHAR(MAX)  NULL,     -- engagement overview, proposed exposure, discovery counts
        generated_by_employee_id BIGINT         NULL
            CONSTRAINT fk_pm_tprm_sr_by REFERENCES grac_practice.organization_employee(employee_id),
        generated_by             NVARCHAR(100)  NOT NULL,
        generated_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_sr_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_tprm_sr_version UNIQUE (engagement_id, version_no)
    );
    PRINT '523: tprm_screening_report created.';
END
GO
IF OBJECT_ID('grac_practice.tprm_screening_observation', 'U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_screening_observation(
        observation_id      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_screening_observation PRIMARY KEY,
        report_id           BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_so_report REFERENCES grac_practice.tprm_screening_report(report_id),
        sort_no             INT            NOT NULL,
        -- CR 2 6.4 report sections 4-10
        section_code        NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_tprm_so_section CHECK (section_code IN (N'BUSINESS_OPERATIONAL', N'DATA_TECHNOLOGY', N'REGULATORY_OUTSOURCING',
                                                                      N'FOURTH_PARTY', N'RELATED_RECORDS', N'INFORMATION_GAP')),
        -- CR 2 6.2 screening inputs (+ discovered record kinds)
        dimension_code      NVARCHAR(30)   NOT NULL,
        origin              NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_tprm_so_origin CHECK (origin IN (N'PROPOSED', N'DISCOVERED')),
        significance        NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_tprm_so_sig CHECK (significance IN (N'HIGH', N'MEDIUM', N'LOW', N'INFO')),
        indicator_code      NVARCHAR(40)   NULL,     -- SCREENING_INDICATOR meaning that made it HIGH
        source_kind         NVARCHAR(30)   NULL,     -- ENGAGEMENT / SCOPE_ITEM / PRACTICE_INSTANCE / OBLIGATION / FINDING / GAP / RISK / ENGAGEMENT_OF_VENDOR
        source_id           BIGINT         NULL,
        source_label        NVARCHAR(400)  NULL,
        verification_status NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_tprm_so_verif CHECK (verification_status IN (N'DECLARED', N'DISCOVERED_UNVALIDATED', N'VALIDATED')),
        evidence_reference  NVARCHAR(500)  NULL,
        observation_text    NVARCHAR(1000) NOT NULL
    );
    CREATE INDEX ix_pm_tprm_so_report ON grac_practice.tprm_screening_observation(report_id, sort_no);
    PRINT '523: tprm_screening_observation created.';
END
GO
IF OBJECT_ID('grac_practice.tprm_applicability_decision', 'U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_applicability_decision(
        decision_id                 BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_applicability_decision PRIMARY KEY,
        organization_id             BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_apd_org REFERENCES grac_practice.organization(organization_id),
        engagement_id               BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_apd_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        report_id                   BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_apd_report REFERENCES grac_practice.tprm_screening_report(report_id),
        decision                    NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_tprm_apd_decision CHECK (decision IN (N'INCLUDE', N'EXCLUDE', N'DEFER')),
        rationale                   NVARCHAR(2000) NOT NULL,
        decision_dt                 DATE           NOT NULL,
        evidence_references         NVARCHAR(2000) NULL,
        approval_reference          NVARCHAR(200)  NULL,
        information_request         NVARCHAR(2000) NULL,     -- DEFER: what is asked for
        information_from_employee_id BIGINT        NULL
            CONSTRAINT fk_pm_tprm_apd_from REFERENCES grac_practice.organization_employee(employee_id),
        status                      NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_apd_status DEFAULT N'CURRENT'
            CONSTRAINT ck_pm_tprm_apd_status CHECK (status IN (N'CURRENT', N'SUPERSEDED')),
        decided_by_employee_id      BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_apd_by REFERENCES grac_practice.organization_employee(employee_id),
        decided_by                  NVARCHAR(100)  NOT NULL,
        entered_dt                  DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_apd_edt DEFAULT SYSUTCDATETIME(),
        superseded_dt               DATETIME2      NULL
    );
    CREATE UNIQUE INDEX ux_pm_tprm_apd_current ON grac_practice.tprm_applicability_decision(engagement_id) WHERE status = N'CURRENT';
    PRINT '523: tprm_applicability_decision created.';
END
GO
IF OBJECT_ID('grac_practice.tprm_admission', 'U') IS NULL
BEGIN
    -- Formal TPRM admission of one engagement (CR 2 7.1): the approval
    -- path of the matched approval rule, kept with the rule as matched.
    CREATE TABLE grac_practice.tprm_admission(
        admission_id             BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_admission PRIMARY KEY,
        organization_id          BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_adm_org REFERENCES grac_practice.organization(organization_id),
        engagement_id            BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_adm_eng REFERENCES grac_practice.tprm_engagement(engagement_id),
        applicability_decision_id BIGINT        NOT NULL
            CONSTRAINT fk_pm_tprm_adm_dec REFERENCES grac_practice.tprm_applicability_decision(decision_id),
        admission_no             INT            NOT NULL,
        status                   NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_adm_status DEFAULT N'PENDING'
            CONSTRAINT ck_pm_tprm_adm_status CHECK (status IN (N'PENDING', N'APPROVED', N'REJECTED', N'RETURNED', N'WITHDRAWN')),
        approval_rule_code       NVARCHAR(60)   NOT NULL,
        rule_snapshot_json       NVARCHAR(MAX)  NULL,
        required_levels          INT            NOT NULL,
        sod_required             BIT            NOT NULL,
        submitted_by_employee_id BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_adm_sub REFERENCES grac_practice.organization_employee(employee_id),
        submitted_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_adm_sub DEFAULT SYSUTCDATETIME(),
        outcome_rationale        NVARCHAR(2000) NULL,
        decided_by_employee_id   BIGINT         NULL,
        decided_dt               DATETIME2      NULL,
        CONSTRAINT uq_pm_tprm_adm_no UNIQUE (engagement_id, admission_no)
    );
    CREATE UNIQUE INDEX ux_pm_tprm_adm_pending ON grac_practice.tprm_admission(engagement_id) WHERE status = N'PENDING';
    PRINT '523: tprm_admission created.';
END
GO
IF OBJECT_ID('grac_practice.tprm_admission_approval', 'U') IS NULL
BEGIN
    CREATE TABLE grac_practice.tprm_admission_approval(
        approval_id              BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_admission_approval PRIMARY KEY,
        admission_id             BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_ada_adm REFERENCES grac_practice.tprm_admission(admission_id),
        level_no                 INT            NOT NULL,
        required_role_name       NVARCHAR(120)  NULL,
        status                   NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_tprm_ada_status DEFAULT N'PENDING'
            CONSTRAINT ck_pm_tprm_ada_status CHECK (status IN (N'PENDING', N'APPROVED', N'REJECTED', N'RETURNED', N'WITHDRAWN')),
        approver_employee_id     BIGINT         NULL,
        on_behalf_of_employee_id BIGINT         NULL,      -- delegation
        comment                  NVARCHAR(2000) NULL,
        decided_dt               DATETIME2      NULL,
        CONSTRAINT uq_pm_tprm_ada UNIQUE (admission_id, level_no)
    );
    PRINT '523: tprm_admission_approval created.';
END
GO
IF COL_LENGTH('grac_practice.tprm_engagement', 'applicability_status') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD applicability_status NVARCHAR(30) NOT NULL
        CONSTRAINT df_pm_tprm_eng_applic DEFAULT N'NOT_SCREENED'
        CONSTRAINT ck_pm_tprm_eng_applic CHECK (applicability_status IN (N'NOT_SCREENED', N'SCREENED', N'EXCLUDED', N'DEFERRED',
                                                                         N'ADMISSION_PENDING', N'ADMITTED', N'ADMISSION_REJECTED'));
IF COL_LENGTH('grac_practice.tprm_engagement', 'current_screening_report_id') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD current_screening_report_id BIGINT NULL;
IF COL_LENGTH('grac_practice.tprm_engagement', 'admitted_dt') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD admitted_dt DATETIME2 NULL;
GO
PRINT '523: engagement applicability columns ready.';
GO

-- =====================================================================
-- 3. Discovery (CR 2 6.3) -- re-issued
-- =====================================================================
-- What GRAC already holds that involves an engagement (BRD step 2; CR 2
-- 6.3). Re-issued by 523: practice instances are found through the
-- engagement's APPLICATIONS (resolved Application dependencies), its
-- PROCESSES (resolved dependencies whose type reads
-- organization_dependency_process, dependency_type_source_config) and its
-- BUSINESS FUNCTIONS (practice_instance.business_function_id); then
--   obligations         of those instances and their practices
--   dependencies        the application resolutions, and the applications
--   assurance findings  on those practice instances
--   gaps                of those instances
--   risks               risk_register rows linked to their practices
--   contracts           the engagement's own contract (434, when present)
-- Read-only unless @persist = 1, which records the results as DISCOVERED
-- links (to validate) and a DISCOVERED exposure snapshot.
-- @suppress_result = 1: no result sets; when the caller has created
-- #tprm_discovery (record_kind, record_id, label, detail, via, criticality,
-- severity, is_open), the records found are written there instead -- the
-- screening reads them (sp_tprm_screening_run). Result sets otherwise
-- unchanged: summary, instances, obligations, dependencies, findings,
-- gaps, risks, contracts.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_discover
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @persist           BIT           = 0,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system',
    @suppress_result   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tp BIGINT, @stage NVARCHAR(30), @contract_id BIGINT;
    SELECT @tp = third_party_id, @stage = stage_code, @contract_id = contract_id FROM grac_practice.tprm_engagement
     WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @tp IS NULL THROW 57630, 'That engagement was not found.', 1;

    DECLARE @app_type INT = (SELECT TOP (1) dependency_type_id FROM grac_practice.dependency_type_master WHERE dependency_type_code = N'Application');

    -- applications in scope (proposed or actual) or linked
    DECLARE @apps TABLE (application_id BIGINT PRIMARY KEY, application_name NVARCHAR(220));
    INSERT @apps
    SELECT a.application_id, a.application_name
    FROM   grac_practice.organization_dependency_application a
    WHERE  a.organization_id = @organization_id AND a.status = N'Active'
      AND  (   EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope s
                        WHERE s.engagement_id = @engagement_id AND s.item_kind = N'APPLICATION'
                          AND s.status = N'Active' AND s.ref_id = a.application_id)
            OR EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l
                        WHERE l.engagement_id = @engagement_id AND l.link_kind = N'APPLICATION'
                          AND l.status = N'Active' AND l.target_id = a.application_id));

    -- instances behind those applications, the engagement's processes and
    -- its business functions (523)
    DECLARE @found TABLE (practice_instance_id BIGINT, via NVARCHAR(20), resolution_id BIGINT, pref INT);
    INSERT @found (practice_instance_id, via, resolution_id, pref)
    SELECT r.practice_instance_id, N'APPLICATION', r.resolution_id, 1
    FROM   grac_practice.practice_dependency_resolution r
    JOIN   @apps a ON a.application_id = r.resolved_dependency_id
    WHERE  r.organization_id = @organization_id AND r.dependency_type_id = @app_type AND r.is_active = 1;
    IF OBJECT_ID('grac_practice.dependency_type_source_config', 'U') IS NOT NULL
        INSERT @found (practice_instance_id, via, resolution_id, pref)
        SELECT r.practice_instance_id, N'PROCESS', r.resolution_id, 2
        FROM   grac_practice.practice_dependency_resolution r
        JOIN   grac_practice.dependency_type_source_config c
               ON c.dependency_type_id = r.dependency_type_id AND c.status = N'Active'
              AND c.source_table_name = N'grac_practice.organization_dependency_process'
        WHERE  r.organization_id = @organization_id AND r.is_active = 1
          AND  EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope s
                        WHERE s.engagement_id = @engagement_id AND s.item_kind = N'PROCESS' AND s.status = N'Active'
                          AND s.ref_id = r.resolved_dependency_id);
    INSERT @found (practice_instance_id, via, resolution_id, pref)
    SELECT pi.practice_instance_id, N'BUSINESS_FUNCTION', NULL, 3
    FROM   grac_practice.practice_instance pi
    WHERE  pi.organization_id = @organization_id AND pi.status = N'Active'
      AND  EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope s
                    WHERE s.engagement_id = @engagement_id AND s.item_kind = N'BUSINESS_FUNCTION' AND s.status = N'Active'
                      AND s.ref_id = pi.business_function_id);
    DECLARE @pi TABLE (practice_instance_id BIGINT PRIMARY KEY, via NVARCHAR(20), resolution_id BIGINT);
    INSERT @pi (practice_instance_id, via, resolution_id)
    SELECT f.practice_instance_id, f.via, f.resolution_id
    FROM  (SELECT practice_instance_id, via, resolution_id,
                  ROW_NUMBER() OVER (PARTITION BY practice_instance_id ORDER BY pref, resolution_id) AS rn
           FROM @found) f
    WHERE f.rn = 1;

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

    -- 4 dependencies: the application resolutions, and the applications
    SELECT N'APPLICATION_RESOLUTION' AS DependencyKind, r.resolution_id AS DependencyId, r.resolved_dependency_name AS DependencyName,
           r.practice_instance_id AS PracticeInstanceId, pi.instance_code AS InstanceCode, r.resolution_status AS ResolutionStatus
    INTO   #deps
    FROM   grac_practice.practice_dependency_resolution r
    JOIN   @apps a ON a.application_id = r.resolved_dependency_id
    JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = r.practice_instance_id
    WHERE  r.organization_id = @organization_id AND r.dependency_type_id = @app_type AND r.is_active = 1
    UNION ALL
    SELECT N'APPLICATION', a.application_id, a.application_name, NULL, NULL, NULL
    FROM   @apps a;
    INSERT @counts SELECT N'Dependencies', COUNT(*) FROM #deps;

    -- 5 assurance findings on the instances
    SELECT o.org_assurance_observation_id AS ObservationId, o.observation_code AS ObservationCode, o.observation_title AS ObservationTitle,
           o.observation_type AS ObservationType, o.severity_code AS SeverityCode, o.severity_name AS SeverityName,
           sm.status_name AS StatusName, sm.is_terminal AS IsClosed, o.observed_dt AS ObservedDt,
           ee.dimension_code AS DimensionCode, ee.entity_name AS EntityName, o.execution_code AS ExecutionCode,
           ee.entity_id AS EntityId
    INTO   #findings
    FROM   grac_practice.org_assurance_observation o
    JOIN   grac_practice.org_assurance_execution_entity ee ON ee.org_assurance_execution_entity_id = o.org_assurance_execution_entity_id
    LEFT   JOIN grac_practice.org_assurance_observation_status_master sm ON sm.org_assurance_observation_status_id = o.observation_status_id
    WHERE  o.organization_id = @organization_id
      AND  ee.dimension_code = N'PRACTICE_INSTANCE'
      AND  ee.entity_id IN (SELECT PracticeInstanceId FROM #instances);
    INSERT @counts SELECT N'AssuranceFindings', COUNT(*) FROM #findings;
    INSERT @counts SELECT N'OpenAssuranceFindings', COUNT(*) FROM #findings WHERE ISNULL(IsClosed, 0) = 0;

    -- 6 gaps of the instances
    SELECT g.practice_gap_id AS PracticeGapId, g.practice_instance_id AS PracticeInstanceId, i.InstanceCode, i.InstanceName,
           g.gap_status AS GapStatus, g.opened_dt AS OpenedDt, g.closed_dt AS ClosedDt
    INTO   #gaps
    FROM   grac_practice.practice_gap g
    JOIN   #instances i ON i.PracticeInstanceId = g.practice_instance_id;
    INSERT @counts SELECT N'OpenGaps', COUNT(*) FROM #gaps WHERE GapStatus = N'Open';

    -- 7 enterprise risks on the practices of those instances
    SELECT rr.risk_register_id AS RiskRegisterId, rr.risk_number AS RiskNumber, rr.risk_title AS RiskTitle,
           rr.status_code AS StatusCode, rr.inherent_rating_name AS InherentRating,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                                    AND l.link_kind = N'ENTERPRISE_RISK' AND l.target_id = rr.risk_register_id AND l.status = N'Active')
                     THEN 1 ELSE 0 END AS BIT) AS IsLinked
    INTO   #risks
    FROM   grac_practice.risk_register rr
    WHERE  rr.organization_id = @organization_id
      AND  rr.linked_practice_id IN (SELECT DISTINCT PracticeId FROM #instances);
    INSERT @counts SELECT N'Risks', COUNT(*) FROM #risks;

    -- 8 the engagement's contract (Asset & Contract, when present)
    CREATE TABLE #contracts (ContractId BIGINT, ContractNumber NVARCHAR(60), ContractName NVARCHAR(250), ContractStatus NVARCHAR(20));
    IF @contract_id IS NOT NULL AND OBJECT_ID('grac_practice.asset_contract','U') IS NOT NULL
        INSERT #contracts
        EXEC sp_executesql N'SELECT c.contract_id, c.contract_number, c.contract_name, c.contract_status
                             FROM grac_practice.asset_contract c
                             WHERE c.organization_id = @o AND c.contract_id = @c;',
             N'@o BIGINT, @c BIGINT', @o = @organization_id, @c = @contract_id;
    INSERT @counts SELECT N'Contracts', COUNT(*) FROM #contracts;
    INSERT @counts SELECT N'Applications', COUNT(*) FROM @apps;

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
        WHERE d.DependencyKind = N'APPLICATION_RESOLUTION'
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

    -- 523: hand the records to the caller (the screening) when it asks.
    IF OBJECT_ID('tempdb..#tprm_discovery') IS NOT NULL
    BEGIN
        INSERT #tprm_discovery (record_kind, record_id, label, detail, via, criticality, severity, is_open)
        SELECT N'PRACTICE_INSTANCE', i.PracticeInstanceId, LEFT(CONCAT(i.InstanceCode, N' - ', i.InstanceName), 400),
               LEFT(CONCAT(i.PracticeCode, N' ', i.PracticeName), 400), i.Via, i.Criticality, NULL,
               CASE WHEN i.Status = N'Active' THEN 1 ELSE 0 END
        FROM #instances i;
        INSERT #tprm_discovery (record_kind, record_id, label, detail, via, criticality, severity, is_open)
        SELECT N'OBLIGATION', o.ObligationRowId, LEFT(o.ObligationName, 400), o.Level, NULL, NULL, NULL, 1
        FROM #obligations o;
        INSERT #tprm_discovery (record_kind, record_id, label, detail, via, criticality, severity, is_open)
        SELECT N'FINDING', f.ObservationId, LEFT(CONCAT(f.ObservationCode, N' - ', f.ObservationTitle), 400), LEFT(f.EntityName, 400),
               NULL, NULL, f.SeverityName, CASE WHEN ISNULL(f.IsClosed, 0) = 1 THEN 0 ELSE 1 END
        FROM #findings f;
        INSERT #tprm_discovery (record_kind, record_id, label, detail, via, criticality, severity, is_open)
        SELECT N'GAP', g.PracticeGapId, LEFT(CONCAT(N'Gap #', g.PracticeGapId, N' on ', g.InstanceCode), 400), g.InstanceName,
               NULL, NULL, NULL, CASE WHEN g.GapStatus = N'Open' THEN 1 ELSE 0 END
        FROM #gaps g;
        INSERT #tprm_discovery (record_kind, record_id, label, detail, via, criticality, severity, is_open)
        SELECT N'RISK', r.RiskRegisterId, LEFT(CONCAT(r.RiskNumber, N' - ', r.RiskTitle), 400), r.StatusCode, NULL, r.InherentRating, NULL, 1
        FROM #risks r;
        INSERT #tprm_discovery (record_kind, record_id, label, detail, via, criticality, severity, is_open)
        SELECT N'CONTRACT', c.ContractId, LEFT(CONCAT(c.ContractNumber, N' - ', c.ContractName), 400), c.ContractStatus, NULL, NULL, NULL, 1
        FROM #contracts c;
    END

    IF ISNULL(@suppress_result, 0) = 1 RETURN;
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
-- 4. Initial Exposure Screening (CR 2 6)
-- =====================================================================
-- Generates a new report version for an engagement from its saved Scope
-- & Exposure (PROPOSED) and GRAC discovery (DISCOVERED). Intelligence
-- only: the engagement's stage, vendor and register are not touched; an
-- engagement not yet screened becomes SCREENED (awaiting the client's
-- decision); any other applicability status stays as it is.
-- Classification (CR 2 6.5): FURTHER_INFORMATION_REQUIRED when the report
-- has an information gap; else POTENTIAL_TPRM_CASE when an observation is
-- HIGH (an indicator of SCREENING_INDICATOR in force is met); else
-- NO_SIGNIFICANT_INDICATORS.
--   @trigger_code    EXPOSURE_SAVED (Scope & Exposure save), REFRESH, MIGRATION
--   @suppress_result 1 = no result set (called from another procedure)
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_screening_run
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @trigger_code      NVARCHAR(20)  = N'REFRESH',
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system',
    @suppress_result   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30), @tp BIGINT, @saved DATETIME2, @status NVARCHAR(30),
            @crit NVARCHAR(60), @cust NVARCHAR(60), @sub NVARCHAR(60), @exit NVARCHAR(2000),
            @a_app NVARCHAR(10), @a_prem NVARCHAR(10), @a_data NVARCHAR(10), @a_sub NVARCHAR(10), @a_proc NVARCHAR(10),
            @a_disr NVARCHAR(10), @a_sla NVARCHAR(10), @a_con NVARCHAR(10),
            @sla NVARCHAR(2000), @rto INT, @rpo INT, @contract_id BIGINT, @contract_ref NVARCHAR(200), @model NVARCHAR(60),
            @locations NVARCHAR(1000);
    SELECT @stage = stage_code, @tp = third_party_id, @saved = exposure_saved_dt, @status = applicability_status,
           @crit = service_criticality_code, @cust = customer_impact_code, @sub = substitutability_code, @exit = exit_dependencies,
           @a_app = app_access_answer, @a_prem = premises_access_answer, @a_data = data_processing_answer,
           @a_sub = subcontracting_answer, @a_proc = important_process_answer, @a_disr = disruption_impact_answer,
           @a_sla = service_commitment_answer, @a_con = contract_answer,
           @sla = sla_summary, @rto = rto_hours, @rpo = rpo_hours, @contract_id = contract_id, @contract_ref = contract_reference,
           @model = service_model_code, @locations = delivery_locations
    FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @stage IS NULL THROW 57630, 'That engagement was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;
    IF @saved IS NULL THROW 58100, 'Save Scope & Exposure first: the screening reads it.', 1;
    SET @trigger_code = CASE WHEN @trigger_code IN (N'EXPOSURE_SAVED', N'REFRESH', N'MIGRATION') THEN @trigger_code ELSE N'REFRESH' END;

    -- the organization's values in force (labels, ranks) and its indicators
    DECLARE @ref TABLE (list_code NVARCHAR(60), value_code NVARCHAR(60), label NVARCHAR(200), rank_no INT);
    INSERT @ref (list_code, value_code, label, rank_no)
    SELECT r.list_code, r.value_code, r.label, r.rank_no
    FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
    WHERE r.list_code IN (N'CRITICALITY', N'DATA_EXPOSURE', N'ACCESS_CATEGORY', N'CUSTOMER_IMPACT', N'SUBSTITUTABILITY',
                          N'SERVICE_MODEL', N'FOURTH_PARTY_CATEGORY');
    DECLARE @ind TABLE (code NVARCHAR(40) PRIMARY KEY, threshold INT);
    INSERT @ind (code, threshold)
    SELECT r.meaning_code, MIN(r.rank_no)
    FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
    WHERE r.list_code = N'SCREENING_INDICATOR' AND r.meaning_code IS NOT NULL
    GROUP BY r.meaning_code;
    DECLARE @t_crit INT = (SELECT threshold FROM @ind WHERE code = N'CRITICALITY'),
            @t_data INT = (SELECT threshold FROM @ind WHERE code = N'DATA'),
            @t_acc INT = (SELECT threshold FROM @ind WHERE code = N'ACCESS'),
            @t_cust INT = (SELECT threshold FROM @ind WHERE code = N'CUSTOMER_IMPACT'),
            @t_sub INT = (SELECT threshold FROM @ind WHERE code = N'SUBSTITUTABILITY');
    DECLARE @on_proc BIT = CASE WHEN EXISTS (SELECT 1 FROM @ind WHERE code = N'IMPORTANT_PROCESS') THEN 1 ELSE 0 END,
            @on_fpd BIT = CASE WHEN EXISTS (SELECT 1 FROM @ind WHERE code = N'FOURTH_PARTY_DATA') THEN 1 ELSE 0 END,
            @on_inst BIT = CASE WHEN EXISTS (SELECT 1 FROM @ind WHERE code = N'DISCOVERED_CRITICAL_INSTANCE') THEN 1 ELSE 0 END,
            @on_find BIT = CASE WHEN EXISTS (SELECT 1 FROM @ind WHERE code = N'DISCOVERED_OPEN_FINDING') THEN 1 ELSE 0 END;
    DECLARE @crit_rank INT = (SELECT rank_no FROM @ref WHERE list_code = N'CRITICALITY' AND value_code = @crit),
            @cust_rank INT = (SELECT rank_no FROM @ref WHERE list_code = N'CUSTOMER_IMPACT' AND value_code = @cust),
            @sub_rank INT = (SELECT rank_no FROM @ref WHERE list_code = N'SUBSTITUTABILITY' AND value_code = @sub);

    -- the proposed scope items, with the rank of their list value
    DECLARE @items TABLE (scope_item_id BIGINT, item_kind NVARCHAR(30), item_code NVARCHAR(60), item_name NVARCHAR(300),
                          country NVARCHAR(120), rank_no INT);
    INSERT @items
    SELECT s.scope_item_id, s.item_kind, s.item_code, s.item_name, s.country, r.rank_no
    FROM grac_practice.tprm_engagement_scope s
    LEFT JOIN @ref r ON r.value_code = s.item_code
                    AND r.list_code = CASE s.item_kind WHEN N'DATA_CATEGORY' THEN N'DATA_EXPOSURE'
                                                       WHEN N'ACCESS' THEN N'ACCESS_CATEGORY' ELSE N'-' END
    WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active';

    -- GRAC discovery, handed over by sp_tprm_engagement_discover
    CREATE TABLE #tprm_discovery (record_kind NVARCHAR(30), record_id BIGINT, label NVARCHAR(400), detail NVARCHAR(400),
                                  via NVARCHAR(30), criticality NVARCHAR(100), severity NVARCHAR(100), is_open BIT);
    EXEC grac_practice.sp_tprm_engagement_discover @organization_id, @engagement_id, 0, @actor_employee_id, @actor, 1;

    DECLARE @obs TABLE (sort_no INT IDENTITY(1,1), section_code NVARCHAR(30), dimension_code NVARCHAR(30), origin NVARCHAR(20),
                        significance NVARCHAR(10), indicator_code NVARCHAR(40), source_kind NVARCHAR(30), source_id BIGINT,
                        source_label NVARCHAR(400), verification_status NVARCHAR(30), evidence_reference NVARCHAR(500),
                        observation_text NVARCHAR(1000));

    -- ---- 4/5 business, operational, data and technology (PROPOSED)
    INSERT @obs (section_code, dimension_code, origin, significance, indicator_code, source_kind, source_label, verification_status, observation_text)
    SELECT N'BUSINESS_OPERATIONAL', N'CRITICALITY', N'PROPOSED',
           CASE WHEN @t_crit IS NOT NULL AND ISNULL(@crit_rank, 0) >= @t_crit THEN N'HIGH' ELSE N'INFO' END,
           CASE WHEN @t_crit IS NOT NULL AND ISNULL(@crit_rank, 0) >= @t_crit THEN N'CRITICALITY' END,
           N'ENGAGEMENT', N'Service criticality', N'DECLARED',
           CONCAT(N'Service criticality: ', ISNULL((SELECT label FROM @ref WHERE list_code = N'CRITICALITY' AND value_code = @crit), @crit), N'.');
    IF @a_proc = N'YES'
        INSERT @obs (section_code, dimension_code, origin, significance, indicator_code, source_kind, source_label, verification_status, observation_text)
        VALUES (N'BUSINESS_OPERATIONAL', N'OPERATIONAL_DEPENDENCY', N'PROPOSED',
                CASE WHEN @a_disr = N'YES' AND @on_proc = 1 THEN N'HIGH' ELSE N'MEDIUM' END,
                CASE WHEN @a_disr = N'YES' AND @on_proc = 1 THEN N'IMPORTANT_PROCESS' END,
                N'ENGAGEMENT', N'Exposure questions', N'DECLARED',
                CASE WHEN @a_disr = N'YES' THEN N'The service supports an important business process or function, and its disruption can affect business operations.'
                     ELSE N'The service supports an important business process or function.' END);
    INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_id, source_label, verification_status, observation_text)
    SELECT N'BUSINESS_OPERATIONAL', N'OPERATIONAL_DEPENDENCY', N'PROPOSED', N'MEDIUM', N'SCOPE_ITEM', i.scope_item_id, i.item_name, N'DECLARED',
           CONCAT(CASE i.item_kind WHEN N'PROCESS' THEN N'Process supported or performed: ' ELSE N'Business function supported: ' END, i.item_name, N'.')
    FROM @items i WHERE i.item_kind IN (N'BUSINESS_FUNCTION', N'PROCESS');
    INSERT @obs (section_code, dimension_code, origin, significance, indicator_code, source_kind, source_label, verification_status, observation_text)
    SELECT N'BUSINESS_OPERATIONAL', N'CONTINUITY', N'PROPOSED',
           CASE WHEN x.thr IS NOT NULL AND ISNULL(x.rnk, 0) >= x.thr THEN N'HIGH' ELSE N'MEDIUM' END,
           CASE WHEN x.thr IS NOT NULL AND ISNULL(x.rnk, 0) >= x.thr THEN x.ind END,
           N'ENGAGEMENT', x.what, N'DECLARED', CONCAT(x.what, N': ', x.lbl, N'.')
    FROM (VALUES (N'Customer impact', N'CUSTOMER_IMPACT', @cust_rank, @t_cust,
                  ISNULL((SELECT label FROM @ref WHERE list_code = N'CUSTOMER_IMPACT' AND value_code = @cust), @cust)),
                 (N'Substitutability', N'SUBSTITUTABILITY', @sub_rank, @t_sub,
                  ISNULL((SELECT label FROM @ref WHERE list_code = N'SUBSTITUTABILITY' AND value_code = @sub), @sub))) x(what, ind, rnk, thr, lbl)
    WHERE x.lbl IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@exit)), N'') IS NOT NULL
        INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_label, verification_status, observation_text)
        VALUES (N'BUSINESS_OPERATIONAL', N'CONTINUITY', N'PROPOSED', N'INFO', N'ENGAGEMENT', N'Exit dependencies', N'DECLARED',
                LEFT(CONCAT(N'Exit dependencies: ', @exit), 1000));
    IF @a_sla = N'YES' AND (NULLIF(LTRIM(RTRIM(@sla)), N'') IS NOT NULL OR @rto IS NOT NULL OR @rpo IS NOT NULL)
        INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_label, verification_status, observation_text)
        VALUES (N'BUSINESS_OPERATIONAL', N'CONTRACT', N'PROPOSED', N'INFO', N'ENGAGEMENT', N'Service commitments', N'DECLARED',
                LEFT(CONCAT(N'Service commitments: RTO ', ISNULL(CAST(@rto AS NVARCHAR(10)), N'--'), N' h, RPO ',
                            ISNULL(CAST(@rpo AS NVARCHAR(10)), N'--'), N' h', CASE WHEN NULLIF(LTRIM(RTRIM(@sla)), N'') IS NOT NULL THEN CONCAT(N'; SLA: ', @sla) ELSE N'' END, N'.'), 1000));

    INSERT @obs (section_code, dimension_code, origin, significance, indicator_code, source_kind, source_id, source_label, verification_status, observation_text)
    SELECT N'DATA_TECHNOLOGY', N'DATA', N'PROPOSED',
           CASE WHEN @t_data IS NOT NULL AND ISNULL(i.rank_no, 0) >= @t_data THEN N'HIGH' WHEN ISNULL(i.rank_no, 0) > 0 THEN N'MEDIUM' ELSE N'INFO' END,
           CASE WHEN @t_data IS NOT NULL AND ISNULL(i.rank_no, 0) >= @t_data THEN N'DATA' END,
           N'SCOPE_ITEM', i.scope_item_id, i.item_name, N'DECLARED', CONCAT(N'Data in scope: ', i.item_name, N'.')
    FROM @items i WHERE i.item_kind = N'DATA_CATEGORY';
    IF @a_data = N'NO'
        INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_label, verification_status, observation_text)
        VALUES (N'DATA_TECHNOLOGY', N'DATA', N'PROPOSED', N'INFO', N'ENGAGEMENT', N'Exposure questions', N'DECLARED',
                N'No organization or customer data is accessed, processed, stored or transmitted.');
    INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_id, source_label, verification_status, observation_text)
    SELECT N'DATA_TECHNOLOGY', N'SYSTEM_ACCESS', N'PROPOSED', N'MEDIUM', N'SCOPE_ITEM', i.scope_item_id, i.item_name, N'DECLARED',
           CONCAT(N'Application or system accessed or supported: ', i.item_name, N'.')
    FROM @items i WHERE i.item_kind = N'APPLICATION';
    INSERT @obs (section_code, dimension_code, origin, significance, indicator_code, source_kind, source_id, source_label, verification_status, observation_text)
    SELECT N'DATA_TECHNOLOGY', CASE WHEN ISNULL(i.rank_no, 0) >= 4 THEN N'PRIVILEGED_ACCESS' ELSE N'SYSTEM_ACCESS' END, N'PROPOSED',
           CASE WHEN @t_acc IS NOT NULL AND ISNULL(i.rank_no, 0) >= @t_acc THEN N'HIGH' WHEN ISNULL(i.rank_no, 0) > 0 THEN N'MEDIUM' ELSE N'INFO' END,
           CASE WHEN @t_acc IS NOT NULL AND ISNULL(i.rank_no, 0) >= @t_acc THEN N'ACCESS' END,
           N'SCOPE_ITEM', i.scope_item_id, i.item_name, N'DECLARED', CONCAT(N'Access: ', i.item_name, N'.')
    FROM @items i WHERE i.item_kind = N'ACCESS';

    -- ---- 6 regulatory and outsourcing (PROPOSED)
    INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_label, verification_status, observation_text)
    SELECT N'REGULATORY_OUTSOURCING', N'OUTSOURCING', N'PROPOSED', N'INFO', N'ENGAGEMENT', N'Service model', N'DECLARED',
           CONCAT(N'Service model: ', ISNULL((SELECT label FROM @ref WHERE list_code = N'SERVICE_MODEL' AND value_code = @model), @model), N'.')
    WHERE @model IS NOT NULL;
    INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_id, source_label, verification_status, observation_text)
    SELECT N'REGULATORY_OUTSOURCING', N'LOCATION', N'PROPOSED', N'INFO', N'SCOPE_ITEM', i.scope_item_id, i.item_name, N'DECLARED',
           CONCAT(N'Delivered or processed at: ', i.item_name, CASE WHEN i.country IS NOT NULL THEN CONCAT(N' (', i.country, N')') ELSE N'' END, N'.')
    FROM @items i WHERE i.item_kind = N'LOCATION';
    IF NOT EXISTS (SELECT 1 FROM @items WHERE item_kind = N'LOCATION') AND NULLIF(LTRIM(RTRIM(@locations)), N'') IS NOT NULL
        INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_label, verification_status, observation_text)
        VALUES (N'REGULATORY_OUTSOURCING', N'LOCATION', N'PROPOSED', N'INFO', N'ENGAGEMENT', N'Delivery location', N'DECLARED',
                LEFT(CONCAT(N'Delivery location: ', @locations, N'.'), 1000));
    IF @a_con = N'YES' AND (@contract_id IS NOT NULL OR NULLIF(LTRIM(RTRIM(@contract_ref)), N'') IS NOT NULL)
        INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_label, verification_status, observation_text)
        VALUES (N'REGULATORY_OUTSOURCING', N'CONTRACT', N'PROPOSED', N'INFO', N'ENGAGEMENT', N'Contract', N'DECLARED',
                LEFT(CONCAT(N'Contract: ', ISNULL(NULLIF(LTRIM(RTRIM(@contract_ref)), N''), CONCAT(N'#', @contract_id)), N'.'), 1000));
    IF @a_con = N'NO' AND @t_crit IS NOT NULL AND ISNULL(@crit_rank, 0) >= @t_crit
        INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_label, verification_status, observation_text)
        VALUES (N'REGULATORY_OUTSOURCING', N'CONTRACT', N'PROPOSED', N'MEDIUM', N'ENGAGEMENT', N'Contract', N'DECLARED',
                N'No contract is recorded for a service of this criticality.');

    -- ---- 7 fourth parties (PROPOSED)
    INSERT @obs (section_code, dimension_code, origin, significance, indicator_code, source_kind, source_id, source_label, verification_status, observation_text)
    SELECT N'FOURTH_PARTY', N'FOURTH_PARTY', N'PROPOSED',
           CASE WHEN @a_data = N'YES' AND @on_fpd = 1 THEN N'HIGH' ELSE N'MEDIUM' END,
           CASE WHEN @a_data = N'YES' AND @on_fpd = 1 THEN N'FOURTH_PARTY_DATA' END,
           N'SCOPE_ITEM', i.scope_item_id, i.item_name, N'DECLARED',
           CONCAT(N'Fourth party: ', i.item_name,
                  CASE WHEN i.item_code IS NOT NULL THEN CONCAT(N' -- ', ISNULL((SELECT label FROM @ref WHERE list_code = N'FOURTH_PARTY_CATEGORY' AND value_code = i.item_code), i.item_code)) ELSE N'' END,
                  CASE WHEN i.country IS NOT NULL THEN CONCAT(N' (', i.country, N')') ELSE N'' END,
                  CASE WHEN @a_data = N'YES' THEN N'; organization or customer data is in scope' ELSE N'' END, N'.')
    FROM @items i WHERE i.item_kind = N'FOURTH_PARTY';

    -- ---- 8 related records (DISCOVERED -- to review, never scope by itself)
    INSERT @obs (section_code, dimension_code, origin, significance, indicator_code, source_kind, source_id, source_label, verification_status, observation_text)
    SELECT N'RELATED_RECORDS', N'OPERATIONAL_DEPENDENCY', N'DISCOVERED',
           CASE WHEN @on_inst = 1 AND UPPER(LTRIM(RTRIM(ISNULL(d.criticality, N'')))) IN (N'HIGH', N'CRITICAL', N'VERY HIGH') THEN N'HIGH' ELSE N'MEDIUM' END,
           CASE WHEN @on_inst = 1 AND UPPER(LTRIM(RTRIM(ISNULL(d.criticality, N'')))) IN (N'HIGH', N'CRITICAL', N'VERY HIGH') THEN N'DISCOVERED_CRITICAL_INSTANCE' END,
           N'PRACTICE_INSTANCE', d.record_id, d.label,
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id AND l.status = N'Active'
                               AND l.link_kind = N'PRACTICE_INSTANCE' AND l.target_id = d.record_id AND l.is_validated = 1)
                THEN N'VALIDATED' ELSE N'DISCOVERED_UNVALIDATED' END,
           LEFT(CONCAT(N'Practice instance ', d.label, N' (', d.detail, N') depends on this engagement''s ',
                       CASE d.via WHEN N'APPLICATION' THEN N'applications' WHEN N'PROCESS' THEN N'processes' ELSE N'business functions' END,
                       CASE WHEN d.criticality IS NOT NULL THEN CONCAT(N'; criticality ', d.criticality) ELSE N'' END, N'.'), 1000)
    FROM #tprm_discovery d WHERE d.record_kind = N'PRACTICE_INSTANCE' AND d.is_open = 1;  -- retired instances are not indicators
    INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_label, verification_status, observation_text)
    SELECT N'REGULATORY_OUTSOURCING', N'REGULATORY', N'DISCOVERED', N'MEDIUM', N'OBLIGATION', N'Obligations', N'DISCOVERED_UNVALIDATED',
           CONCAT(COUNT(*), N' obligation(s) apply to the related practice instances and their practices.')
    FROM #tprm_discovery d WHERE d.record_kind = N'OBLIGATION'
    HAVING COUNT(*) > 0;
    INSERT @obs (section_code, dimension_code, origin, significance, indicator_code, source_kind, source_id, source_label, verification_status, observation_text)
    SELECT N'RELATED_RECORDS', N'ASSURANCE', N'DISCOVERED',
           CASE WHEN @on_find = 1 AND (UPPER(ISNULL(d.severity, N'')) LIKE N'%HIGH%' OR UPPER(ISNULL(d.severity, N'')) LIKE N'%CRITICAL%') THEN N'HIGH' ELSE N'MEDIUM' END,
           CASE WHEN @on_find = 1 AND (UPPER(ISNULL(d.severity, N'')) LIKE N'%HIGH%' OR UPPER(ISNULL(d.severity, N'')) LIKE N'%CRITICAL%') THEN N'DISCOVERED_OPEN_FINDING' END,
           N'FINDING', d.record_id, d.label, N'DISCOVERED_UNVALIDATED',
           LEFT(CONCAT(N'Open assurance finding ', d.label, CASE WHEN d.severity IS NOT NULL THEN CONCAT(N' (', d.severity, N')') ELSE N'' END,
                       N' on ', d.detail, N'.'), 1000)
    FROM #tprm_discovery d WHERE d.record_kind = N'FINDING' AND d.is_open = 1;
    INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_id, source_label, verification_status, observation_text)
    SELECT N'RELATED_RECORDS', N'GAP', N'DISCOVERED', N'MEDIUM', N'GAP', d.record_id, d.label, N'DISCOVERED_UNVALIDATED',
           LEFT(CONCAT(N'Open gap: ', d.label, N'.'), 1000)
    FROM #tprm_discovery d WHERE d.record_kind = N'GAP' AND d.is_open = 1;
    INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_id, source_label, verification_status, observation_text)
    SELECT N'RELATED_RECORDS', N'RISK', N'DISCOVERED', N'MEDIUM', N'RISK', d.record_id, d.label,
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id AND l.status = N'Active'
                               AND l.link_kind = N'ENTERPRISE_RISK' AND l.target_id = d.record_id AND l.is_validated = 1)
                THEN N'VALIDATED' ELSE N'DISCOVERED_UNVALIDATED' END,
           LEFT(CONCAT(N'Enterprise risk ', d.label, CASE WHEN d.criticality IS NOT NULL THEN CONCAT(N' (inherent ', d.criticality, N')') ELSE N'' END, N'.'), 1000)
    FROM #tprm_discovery d WHERE d.record_kind = N'RISK';
    -- the vendor's other engagements (Third-Party Management)
    INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_id, source_label, verification_status, observation_text)
    SELECT N'RELATED_RECORDS', N'THIRD_PARTY', N'DISCOVERED', N'INFO', N'ENGAGEMENT_OF_VENDOR', o.engagement_id,
           LEFT(CONCAT(o.engagement_code, N' - ', o.engagement_title), 400), N'DISCOVERED_UNVALIDATED',
           LEFT(CONCAT(N'The vendor''s engagement ', o.engagement_code, N' - ', o.engagement_title, N': ',
                       CASE o.applicability_status WHEN N'ADMITTED' THEN N'in formal TPRM' WHEN N'EXCLUDED' THEN N'excluded from formal TPRM'
                            WHEN N'ADMISSION_PENDING' THEN N'admission pending' ELSE N'not yet decided' END,
                       CASE WHEN o.residual_band_code IS NOT NULL THEN CONCAT(N', residual risk ', o.residual_band_code)
                            WHEN o.inherent_band_code IS NOT NULL THEN CONCAT(N', inherent risk ', o.inherent_band_code) ELSE N'' END, N'.'), 1000)
    FROM grac_practice.tprm_engagement o
    WHERE o.third_party_id = @tp AND o.engagement_id <> @engagement_id
      AND o.stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED');

    -- ---- 9 information gaps and inconsistencies (CR 2 6.4-9, 6.5)
    INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_label, verification_status, observation_text)
    SELECT N'INFORMATION_GAP', q.dim, N'PROPOSED', N'MEDIUM', N'ENGAGEMENT', N'Exposure questions', N'DECLARED',
           CONCAT(CASE WHEN q.answer IS NULL THEN N'Not answered: ' ELSE N'Not sure: ' END, q.question)
    FROM (VALUES (@a_app,  N'SYSTEM_ACCESS',          N'Will the vendor access or support our applications or systems?'),
                 (@a_prem, N'SYSTEM_ACCESS',          N'Will the vendor have physical access to our premises?'),
                 (@a_data, N'DATA',                   N'Will the vendor access, process, store or transmit organization or customer data?'),
                 (@a_sub,  N'FOURTH_PARTY',           N'Will the vendor use subcontractors or other third parties for this service?'),
                 (@a_proc, N'OPERATIONAL_DEPENDENCY', N'Does the service support an important business process or function?'),
                 (@a_disr, N'CONTINUITY',             N'Could a disruption of the service affect business operations?'),
                 (@a_sla,  N'CONTRACT',               N'Are service commitments (SLA, recovery objectives) part of the service?'),
                 (@a_con,  N'CONTRACT',               N'Is there a contract for this engagement?')) q(answer, dim, question)
    WHERE q.answer IS NULL OR q.answer = N'UNKNOWN';
    INSERT @obs (section_code, dimension_code, origin, significance, source_kind, source_label, verification_status, observation_text)
    SELECT N'INFORMATION_GAP', g.dim, N'PROPOSED', N'MEDIUM', N'ENGAGEMENT', N'Exposure details', N'DECLARED', g.txt
    FROM (VALUES
        (CASE WHEN @a_app = N'YES' AND NOT EXISTS (SELECT 1 FROM @items WHERE item_kind = N'APPLICATION') THEN 1 ELSE 0 END,
         N'SYSTEM_ACCESS', N'Application access is declared, but no application or system is recorded.'),
        (CASE WHEN (@a_app = N'YES' OR @a_prem = N'YES') AND NOT EXISTS (SELECT 1 FROM @items WHERE item_kind = N'ACCESS') THEN 1 ELSE 0 END,
         N'SYSTEM_ACCESS', N'Access is declared, but no access category is recorded.'),
        (CASE WHEN @a_data = N'YES' AND NOT EXISTS (SELECT 1 FROM @items WHERE item_kind = N'DATA_CATEGORY') THEN 1 ELSE 0 END,
         N'DATA', N'Data processing is declared, but no data category is recorded.'),
        (CASE WHEN @a_sub = N'YES' AND NOT EXISTS (SELECT 1 FROM @items WHERE item_kind = N'FOURTH_PARTY') THEN 1 ELSE 0 END,
         N'FOURTH_PARTY', N'Subcontracting is declared, but no fourth party is recorded.'),
        (CASE WHEN @a_proc = N'YES' AND NOT EXISTS (SELECT 1 FROM @items WHERE item_kind IN (N'BUSINESS_FUNCTION', N'PROCESS')) THEN 1 ELSE 0 END,
         N'OPERATIONAL_DEPENDENCY', N'An important business process is declared, but no process or business function is recorded.'),
        (CASE WHEN @a_disr = N'YES' AND @cust IS NULL AND @sub IS NULL AND NULLIF(LTRIM(RTRIM(@exit)), N'') IS NULL THEN 1 ELSE 0 END,
         N'CONTINUITY', N'Disruption impact is declared, but customer impact, substitutability and exit dependencies are not recorded.'),
        (CASE WHEN @a_sla = N'YES' AND NULLIF(LTRIM(RTRIM(@sla)), N'') IS NULL AND @rto IS NULL AND @rpo IS NULL THEN 1 ELSE 0 END,
         N'CONTRACT', N'Service commitments are declared, but no SLA, RTO or RPO is recorded.'),
        (CASE WHEN @a_con = N'YES' AND @contract_id IS NULL AND NULLIF(LTRIM(RTRIM(@contract_ref)), N'') IS NULL THEN 1 ELSE 0 END,
         N'CONTRACT', N'A contract is declared, but no contract record or reference is given.')
    ) g(flag, dim, txt)
    WHERE g.flag = 1;

    DECLARE @high INT = (SELECT COUNT(*) FROM @obs WHERE significance = N'HIGH' AND section_code <> N'INFORMATION_GAP'),
            @gaps INT = (SELECT COUNT(*) FROM @obs WHERE section_code = N'INFORMATION_GAP'),
            @n INT = (SELECT COUNT(*) FROM @obs);
    DECLARE @class NVARCHAR(40) = CASE WHEN @gaps > 0 THEN N'FURTHER_INFORMATION_REQUIRED'
                                       WHEN @high > 0 THEN N'POTENTIAL_TPRM_CASE' ELSE N'NO_SIGNIFICANT_INDICATORS' END;

    -- engagement overview, proposed exposure and discovery counts (CR 2 6.4-1..3)
    DECLARE @summary NVARCHAR(MAX) = (
        SELECT e.engagement_code AS engagementCode, e.engagement_title AS engagementTitle,
               t.third_party_code AS vendorCode, t.legal_name AS vendorName,
               sc.label AS serviceCategory, et.label AS engagementType, sm.label AS serviceModel,
               e.service_recipient AS serviceRecipient, e.delivery_locations AS deliveryLocation,
               e.service_description AS serviceDescription, e.business_purpose AS businessPurpose,
               CONVERT(NVARCHAR(10), e.proposed_start_dt, 23) AS proposedStart, CONVERT(NVARCHAR(10), e.proposed_end_dt, 23) AS proposedEnd,
               ro.employee_name AS relationshipOwner, cr.label AS criticality, de.label AS dataExposure,
               e.app_access_answer AS appAccess, e.premises_access_answer AS premisesAccess, e.data_processing_answer AS dataProcessing,
               e.subcontracting_answer AS subcontracting, e.important_process_answer AS importantProcess,
               e.disruption_impact_answer AS disruptionImpact, e.service_commitment_answer AS serviceCommitments,
               e.contract_answer AS contract,
               (SELECT i.item_kind AS kind, COUNT(*) AS [count] FROM @items i GROUP BY i.item_kind FOR JSON PATH) AS proposedItems,
               (SELECT d.record_kind AS kind, COUNT(*) AS [count] FROM #tprm_discovery d GROUP BY d.record_kind FOR JSON PATH) AS discovered
        FROM grac_practice.tprm_engagement e
        JOIN grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
        LEFT JOIN grac_practice.fn_tprm_reference_effective(@organization_id) sc ON sc.list_code = N'SERVICE_CATEGORY' AND sc.value_code = e.service_category_code
        LEFT JOIN grac_practice.fn_tprm_reference_effective(@organization_id) et ON et.list_code = N'ENGAGEMENT_TYPE' AND et.value_code = e.engagement_type_code
        LEFT JOIN grac_practice.fn_tprm_reference_effective(@organization_id) sm ON sm.list_code = N'SERVICE_MODEL' AND sm.value_code = e.service_model_code
        LEFT JOIN grac_practice.fn_tprm_reference_effective(@organization_id) cr ON cr.list_code = N'CRITICALITY' AND cr.value_code = e.service_criticality_code
        LEFT JOIN grac_practice.fn_tprm_reference_effective(@organization_id) de ON de.list_code = N'DATA_EXPOSURE' AND de.value_code = e.data_exposure_code
        LEFT JOIN grac_practice.organization_employee ro ON ro.employee_id = e.relationship_owner_employee_id
        WHERE e.engagement_id = @engagement_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @report BIGINT, @version INT, @to_status NVARCHAR(30) = CASE WHEN @status = N'NOT_SCREENED' THEN N'SCREENED' ELSE @status END;
    BEGIN TRAN;
        SELECT @version = ISNULL(MAX(version_no), 0) + 1 FROM grac_practice.tprm_screening_report WITH (UPDLOCK, HOLDLOCK)
         WHERE engagement_id = @engagement_id;
        INSERT grac_practice.tprm_screening_report
            (organization_id, engagement_id, version_no, classification, trigger_code, high_count, gap_count, observation_count,
             summary_json, generated_by_employee_id, generated_by)
        VALUES (@organization_id, @engagement_id, @version, @class, @trigger_code, @high, @gaps, @n, @summary, @actor_employee_id, @actor);
        SET @report = SCOPE_IDENTITY();
        INSERT grac_practice.tprm_screening_observation
            (report_id, sort_no, section_code, dimension_code, origin, significance, indicator_code, source_kind, source_id, source_label,
             verification_status, evidence_reference, observation_text)
        SELECT @report, o.sort_no, o.section_code, o.dimension_code, o.origin, o.significance, o.indicator_code, o.source_kind, o.source_id,
               o.source_label, o.verification_status, o.evidence_reference, o.observation_text
        FROM @obs o;
        UPDATE grac_practice.tprm_engagement
           SET current_screening_report_id = @report, applicability_status = @to_status
         WHERE engagement_id = @engagement_id;
        DECLARE @detail NVARCHAR(2000) = CONCAT(N'Initial exposure screening v', @version, N': ',
            CASE @class WHEN N'POTENTIAL_TPRM_CASE' THEN N'potential TPRM case' WHEN N'FURTHER_INFORMATION_REQUIRED' THEN N'further information required'
                        ELSE N'no significant TPRM indicators' END,
            N' (', @high, N' high indicator(s), ', @gaps, N' information gap(s)).');
        EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'SCREENING_GENERATED', @stage, @stage, @detail, @actor_employee_id, @actor;
    COMMIT;
    EXEC grac_practice.sp_tprm_audit N'tprm-screening', @report, N'GENERATE', @detail, @actor;

    IF ISNULL(@suppress_result, 0) = 0
        SELECT @report AS ReportId, @version AS VersionNo, @class AS Classification, N'GENERATED' AS Result;
END
GO

-- =====================================================================
-- 5. Applicability decision and admission (CR 2 7)
-- =====================================================================
-- Result sets: 1 reports (every version)  2 report (@report_id, else the
-- current one)  3 its observations  4 decisions (every one)
-- 5 admissions  6 their approval levels
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_applicability_get
    @organization_id BIGINT,
    @engagement_id   BIGINT,
    @report_id       BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @current BIGINT;
    SELECT @current = current_screening_report_id FROM grac_practice.tprm_engagement
     WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id)
        THROW 57630, 'That engagement was not found.', 1;
    DECLARE @shown BIGINT = COALESCE((SELECT report_id FROM grac_practice.tprm_screening_report
                                       WHERE report_id = @report_id AND engagement_id = @engagement_id), @current);

    SELECT r.report_id AS ReportId, r.version_no AS VersionNo, r.classification AS Classification, r.trigger_code AS TriggerCode,
           r.high_count AS HighCount, r.gap_count AS GapCount, r.observation_count AS ObservationCount,
           ISNULL(ge.employee_name, r.generated_by) AS GeneratedBy, r.generated_dt AS GeneratedDt,
           CAST(CASE WHEN r.report_id = @current THEN 1 ELSE 0 END AS BIT) AS IsCurrent
    FROM grac_practice.tprm_screening_report r
    LEFT JOIN grac_practice.organization_employee ge ON ge.employee_id = r.generated_by_employee_id
    WHERE r.engagement_id = @engagement_id
    ORDER BY r.version_no DESC;

    SELECT r.report_id AS ReportId, r.version_no AS VersionNo, r.classification AS Classification, r.trigger_code AS TriggerCode,
           r.high_count AS HighCount, r.gap_count AS GapCount, r.observation_count AS ObservationCount, r.summary_json AS SummaryJson,
           ISNULL(ge.employee_name, r.generated_by) AS GeneratedBy, r.generated_dt AS GeneratedDt,
           CAST(CASE WHEN r.report_id = @current THEN 1 ELSE 0 END AS BIT) AS IsCurrent
    FROM grac_practice.tprm_screening_report r
    LEFT JOIN grac_practice.organization_employee ge ON ge.employee_id = r.generated_by_employee_id
    WHERE r.report_id = @shown;

    SELECT o.observation_id AS ObservationId, o.sort_no AS SortNo, o.section_code AS SectionCode, o.dimension_code AS DimensionCode,
           o.origin AS Origin, o.significance AS Significance, o.indicator_code AS IndicatorCode, ind.label AS IndicatorLabel,
           o.source_kind AS SourceKind, o.source_id AS SourceId, o.source_label AS SourceLabel,
           o.verification_status AS VerificationStatus, o.evidence_reference AS EvidenceReference, o.observation_text AS ObservationText
    FROM grac_practice.tprm_screening_observation o
    LEFT JOIN (SELECT meaning_code, MIN(label) AS label FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                WHERE list_code = N'SCREENING_INDICATOR' GROUP BY meaning_code) ind ON ind.meaning_code = o.indicator_code
    WHERE o.report_id = @shown
    ORDER BY o.sort_no;

    SELECT d.decision_id AS DecisionId, d.report_id AS ReportId, r.version_no AS ReportVersionNo, r.classification AS ReportClassification,
           d.decision AS Decision, d.rationale AS Rationale, d.decision_dt AS DecisionDt, d.evidence_references AS EvidenceReferences,
           d.approval_reference AS ApprovalReference, d.information_request AS InformationRequest,
           d.information_from_employee_id AS InformationFromEmployeeId, fe.employee_name AS InformationFromName,
           d.status AS Status, d.decided_by_employee_id AS DecidedByEmployeeId, ISNULL(de.employee_name, d.decided_by) AS DecidedBy,
           d.entered_dt AS EnteredDt, d.superseded_dt AS SupersededDt
    FROM grac_practice.tprm_applicability_decision d
    JOIN grac_practice.tprm_screening_report r ON r.report_id = d.report_id
    LEFT JOIN grac_practice.organization_employee de ON de.employee_id = d.decided_by_employee_id
    LEFT JOIN grac_practice.organization_employee fe ON fe.employee_id = d.information_from_employee_id
    WHERE d.engagement_id = @engagement_id
    ORDER BY d.decision_id DESC;

    SELECT a.admission_id AS AdmissionId, a.admission_no AS AdmissionNo, a.applicability_decision_id AS DecisionId, a.status AS Status,
           a.approval_rule_code AS ApprovalRuleCode, JSON_VALUE(a.rule_snapshot_json, '$.rule_name') AS ApprovalRuleName,
           a.required_levels AS RequiredLevels, a.sod_required AS SodRequired,
           a.submitted_by_employee_id AS SubmittedByEmployeeId, se.employee_name AS SubmittedBy, a.submitted_dt AS SubmittedDt,
           a.outcome_rationale AS OutcomeRationale, a.decided_by_employee_id AS DecidedByEmployeeId, xe.employee_name AS DecidedBy,
           a.decided_dt AS DecidedDt
    FROM grac_practice.tprm_admission a
    LEFT JOIN grac_practice.organization_employee se ON se.employee_id = a.submitted_by_employee_id
    LEFT JOIN grac_practice.organization_employee xe ON xe.employee_id = a.decided_by_employee_id
    WHERE a.engagement_id = @engagement_id
    ORDER BY a.admission_no DESC;

    SELECT p.approval_id AS ApprovalId, p.admission_id AS AdmissionId, p.level_no AS LevelNo, p.required_role_name AS RequiredRoleName,
           p.status AS Status, p.approver_employee_id AS ApproverEmployeeId, ae.employee_name AS ApproverName,
           p.on_behalf_of_employee_id AS OnBehalfOfEmployeeId, oe.employee_name AS OnBehalfOfName, p.comment AS Comment, p.decided_dt AS DecidedDt
    FROM grac_practice.tprm_admission_approval p
    JOIN grac_practice.tprm_admission a ON a.admission_id = p.admission_id
    LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = p.approver_employee_id
    LEFT JOIN grac_practice.organization_employee oe ON oe.employee_id = p.on_behalf_of_employee_id
    WHERE a.engagement_id = @engagement_id
    ORDER BY a.admission_no DESC, p.level_no;
END
GO

-- The client's TPRM applicability decision (CR 2 7), made on the CURRENT
-- screening report (@expected_report_id = the report the decider saw).
--   INCLUDE  starts the admission approval (CR 2 7.1): the approval rule
--            matched on the service criticality (fn_tprm_match_approval_rule
--            -- no risk band exists yet) gives the levels, roles and SoD.
--   EXCLUDE  CR 2 7.2: recorded with the report; the engagement stays in
--            Engagement Management, the vendor stays active, nothing goes
--            to the TP Risk Register; the formal TPRM steps are not offered.
--   DEFER    CR 2 7.3: pending; @information_request (and who is asked)
--            records what is needed; the next Scope & Exposure save
--            regenerates the report; a revised decision can be recorded.
-- A new decision supersedes the previous one. Not while an admission is
-- pending or after admission.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_applicability_decide
    @organization_id              BIGINT,
    @engagement_id                BIGINT,
    @decision                     NVARCHAR(20),
    @rationale                    NVARCHAR(2000),
    @decision_dt                  DATE           = NULL,
    @evidence_references          NVARCHAR(2000) = NULL,
    @approval_reference           NVARCHAR(200)  = NULL,
    @information_request          NVARCHAR(2000) = NULL,
    @information_from_employee_id BIGINT         = NULL,
    @expected_report_id           BIGINT         = NULL,
    @actor_employee_id            BIGINT         = NULL,
    @actor                        NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @actor_employee_id IS NULL THROW 58101, 'Recording the decision needs a sign-in linked to an employee (the decision-maker).', 1;
    DECLARE @stage NVARCHAR(30), @status NVARCHAR(30), @report BIGINT;
    SELECT @stage = stage_code, @status = applicability_status, @report = current_screening_report_id
    FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @stage IS NULL THROW 57630, 'That engagement was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;
    IF @report IS NULL THROW 58102, 'Generate the screening report first (save Scope & Exposure).', 1;
    IF @expected_report_id IS NOT NULL AND @expected_report_id <> @report
        THROW 58103, 'The screening report has changed. Review the latest report and decide again.', 1;
    IF @status = N'ADMISSION_PENDING' THROW 58104, 'An admission approval is pending. Withdraw it before recording a new decision.', 1;
    IF @status = N'ADMITTED' THROW 58105, 'The engagement is already admitted to formal TPRM.', 1;
    SET @decision = UPPER(NULLIF(LTRIM(RTRIM(@decision)), N''));
    IF @decision IS NULL OR @decision NOT IN (N'INCLUDE', N'EXCLUDE', N'DEFER') THROW 58106, 'Choose Include, Exclude or Defer.', 1;
    SET @rationale = NULLIF(LTRIM(RTRIM(@rationale)), N'');
    IF @rationale IS NULL THROW 58107, 'Give the rationale for the decision.', 1;
    SET @decision_dt = ISNULL(@decision_dt, CONVERT(DATE, SYSUTCDATETIME()));
    IF @decision_dt > CONVERT(DATE, SYSUTCDATETIME()) THROW 58108, 'The decision date cannot be in the future.', 1;
    IF @decision <> N'DEFER' SELECT @information_request = NULL, @information_from_employee_id = NULL;
    IF @information_from_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                        WHERE employee_id = @information_from_employee_id AND organization_id = @organization_id AND status = N'Active')
        THROW 58109, 'The person asked for information must be an active employee of this organization.', 1;

    DECLARE @rule_code NVARCHAR(60), @levels INT, @l1 NVARCHAR(120), @l2 NVARCHAR(120), @l3 NVARCHAR(120), @sod BIT, @snapshot NVARCHAR(MAX);
    IF @decision = N'INCLUDE'
    BEGIN
        DECLARE @crit_rank INT;
        SELECT @crit_rank = criticality_rank FROM grac_practice.fn_tprm_engagement_ranks(@engagement_id);
        SELECT @rule_code = rule_code, @levels = approval_levels, @l1 = level1_role_name, @l2 = level2_role_name, @l3 = level3_role_name,
               @sod = sod_required,
               @snapshot = (SELECT r2.rule_code, r2.rule_name, r2.approval_levels, r2.level1_role_name, r2.level2_role_name, r2.level3_role_name,
                                   r2.sod_required, r2.origin
                            FROM grac_practice.fn_tprm_match_approval_rule(@organization_id, NULL, @crit_rank) r2
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
        FROM grac_practice.fn_tprm_match_approval_rule(@organization_id, NULL, @crit_rank);
        IF @rule_code IS NULL THROW 58110, 'No approval rule applies. Add a catch-all approval rule in Third-Party Settings.', 1;
    END

    DECLARE @id BIGINT, @admission BIGINT, @no INT,
            @to_status NVARCHAR(30) = CASE @decision WHEN N'INCLUDE' THEN N'ADMISSION_PENDING' WHEN N'EXCLUDE' THEN N'EXCLUDED' ELSE N'DEFERRED' END;
    BEGIN TRAN;
        -- Re-read under a lock: a concurrent decision, admission or
        -- re-screening between the checks above and here must not be
        -- overwritten (it changes this row first).
        SELECT @stage = stage_code, @status = applicability_status
        FROM grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK)
        WHERE engagement_id = @engagement_id AND organization_id = @organization_id
          AND current_screening_report_id = @report;
        IF @@ROWCOUNT = 0 THROW 58103, 'The screening report has changed. Review the latest report and decide again.', 1;
        IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;
        IF @status IN (N'ADMISSION_PENDING', N'ADMITTED')
           OR EXISTS (SELECT 1 FROM grac_practice.tprm_admission WHERE engagement_id = @engagement_id AND status = N'PENDING')
            THROW 58104, 'An admission approval is pending or complete. Refresh the page.', 1;
        UPDATE grac_practice.tprm_applicability_decision SET status = N'SUPERSEDED', superseded_dt = SYSUTCDATETIME()
         WHERE engagement_id = @engagement_id AND status = N'CURRENT';
        INSERT grac_practice.tprm_applicability_decision
            (organization_id, engagement_id, report_id, decision, rationale, decision_dt, evidence_references, approval_reference,
             information_request, information_from_employee_id, status, decided_by_employee_id, decided_by)
        VALUES (@organization_id, @engagement_id, @report, @decision, @rationale, @decision_dt,
                NULLIF(LTRIM(RTRIM(@evidence_references)), N''), NULLIF(LTRIM(RTRIM(@approval_reference)), N''),
                NULLIF(LTRIM(RTRIM(@information_request)), N''), @information_from_employee_id, N'CURRENT', @actor_employee_id, @actor);
        SET @id = SCOPE_IDENTITY();
        IF @decision = N'INCLUDE'
        BEGIN
            SELECT @no = ISNULL(MAX(admission_no), 0) + 1 FROM grac_practice.tprm_admission WITH (UPDLOCK, HOLDLOCK) WHERE engagement_id = @engagement_id;
            INSERT grac_practice.tprm_admission
                (organization_id, engagement_id, applicability_decision_id, admission_no, status, approval_rule_code, rule_snapshot_json,
                 required_levels, sod_required, submitted_by_employee_id)
            VALUES (@organization_id, @engagement_id, @id, @no, N'PENDING', @rule_code, @snapshot, @levels, @sod, @actor_employee_id);
            SET @admission = SCOPE_IDENTITY();
            INSERT grac_practice.tprm_admission_approval (admission_id, level_no, required_role_name, status)
            SELECT @admission, x.n, x.r, N'PENDING' FROM (VALUES (1, @l1), (2, @l2), (3, @l3)) x(n, r) WHERE x.n <= @levels;
        END
        UPDATE grac_practice.tprm_engagement SET applicability_status = @to_status, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @engagement_id;
        DECLARE @detail NVARCHAR(2000) = LEFT(CONCAT(N'TPRM applicability: ', @decision, N'. ', @rationale,
            CASE WHEN @decision = N'INCLUDE' THEN CONCAT(N' Admission ', @no, N' requested under rule ', @rule_code, N' (', @levels, N' level(s)).') ELSE N'' END), 2000);
        EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'APPLICABILITY_DECISION', @stage, @stage, @detail, @actor_employee_id, @actor;
    COMMIT;
    EXEC grac_practice.sp_tprm_audit N'tprm-applicability', @id, @decision, @detail, @actor;
    SELECT @id AS DecisionId, @admission AS AdmissionId, @to_status AS Result;
END
GO

-- Act on the current level of an admission (CR 2 7.1; decision Q7: the
-- TPRM approval rules). APPROVE passes to the next level, or at the last
-- level ADMITS the engagement; REJECT ends it (ADMISSION_REJECTED);
-- RETURN sends it back for a new client decision (SCREENED).
-- Role: when the organization has a role with the level's role name, the
-- approver must hold it (organization_employee.role_id) or act under an
-- active delegation from someone who does (same rule as
-- sp_tprm_decision_act). Segregation of duties (when the rule asks for
-- it): the decision-maker who included the engagement cannot approve its
-- admission, and each level needs a different person.
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

-- Withdraw a pending admission (the decision-maker, or an administrator):
-- the INCLUDE decision is superseded and the engagement awaits a new
-- decision (SCREENED).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_admission_withdraw
    @organization_id   BIGINT,
    @admission_id      BIGINT,
    @note              NVARCHAR(1000) = NULL,
    @caller_is_admin   BIT            = 0,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @eng BIGINT, @status NVARCHAR(20), @submitter BIGINT, @decision_id BIGINT, @no INT;
    SELECT @eng = engagement_id, @status = status, @submitter = submitted_by_employee_id, @decision_id = applicability_decision_id,
           @no = admission_no
    FROM grac_practice.tprm_admission WHERE admission_id = @admission_id AND organization_id = @organization_id;
    IF @eng IS NULL THROW 58116, 'That admission was not found.', 1;
    IF @status <> N'PENDING' THROW 58117, 'That admission is no longer pending.', 1;
    IF ISNULL(@caller_is_admin, 0) = 0 AND ISNULL(@submitter, -1) <> ISNULL(@actor_employee_id, -2)
        THROW 58124, 'Only the decision-maker who included the engagement can withdraw the admission.', 1;
    DECLARE @stage NVARCHAR(30), @applic NVARCHAR(30);
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    BEGIN TRAN;
        SELECT @status = status FROM grac_practice.tprm_admission WITH (UPDLOCK, HOLDLOCK) WHERE admission_id = @admission_id;
        IF @status <> N'PENDING' THROW 58117, 'That admission is no longer pending.', 1;
        SELECT @stage = stage_code, @applic = applicability_status
        FROM grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK) WHERE engagement_id = @eng;
        IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;
        IF @applic <> N'ADMISSION_PENDING' THROW 58126, 'The engagement is no longer awaiting this admission. Refresh the page.', 1;
        UPDATE grac_practice.tprm_admission SET status = N'WITHDRAWN', outcome_rationale = @note,
               decided_by_employee_id = @actor_employee_id, decided_dt = SYSUTCDATETIME()
         WHERE admission_id = @admission_id;
        UPDATE grac_practice.tprm_admission_approval SET status = N'WITHDRAWN' WHERE admission_id = @admission_id AND status = N'PENDING';
        UPDATE grac_practice.tprm_applicability_decision SET status = N'SUPERSEDED', superseded_dt = SYSUTCDATETIME()
         WHERE decision_id = @decision_id AND status = N'CURRENT';
        UPDATE grac_practice.tprm_engagement SET applicability_status = N'SCREENED', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @eng;
        DECLARE @detail NVARCHAR(2000) = LEFT(CONCAT(N'Admission ', @no, N' withdrawn.', CASE WHEN @note IS NOT NULL THEN CONCAT(N' ', @note) ELSE N'' END), 2000);
        EXEC grac_practice.sp_tprm_engagement_event @eng, N'ADMISSION_WITHDRAWN', @stage, @stage, @detail, @actor_employee_id, @actor;
    COMMIT;
    EXEC grac_practice.sp_tprm_audit N'tprm-admission', @admission_id, N'WITHDRAW', @detail, @actor;
    SELECT @admission_id AS AdmissionId, N'WITHDRAWN' AS Result;
END
GO
-- =====================================================================
-- 6. Re-issued procedures
-- =====================================================================
-- Save Scope & Exposure (522; CR 2 5.2, 5.3) -- re-issued by 523: the
-- save generates the Initial Exposure Screening Report in the same
-- transaction (CR 2 6.1: "upon saving the Scope & Exposure information,
-- GRAC shall automatically initiate Initial Exposure Screening").
-- Everything else as in 522 (see there for the parameters).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_exposure_save
    @organization_id           BIGINT,
    @engagement_id             BIGINT,
    @app_access_answer         NVARCHAR(10)   = NULL,
    @premises_access_answer    NVARCHAR(10)   = NULL,
    @data_processing_answer    NVARCHAR(10)   = NULL,
    @subcontracting_answer     NVARCHAR(10)   = NULL,
    @important_process_answer  NVARCHAR(10)   = NULL,
    @disruption_impact_answer  NVARCHAR(10)   = NULL,
    @service_commitment_answer NVARCHAR(10)   = NULL,
    @contract_answer           NVARCHAR(10)   = NULL,
    @service_criticality_code  NVARCHAR(60)   = NULL,
    @data_processing_details   NVARCHAR(2000) = NULL,
    @customer_impact_code      NVARCHAR(60)   = NULL,
    @substitutability_code     NVARCHAR(60)   = NULL,
    @exit_dependencies         NVARCHAR(2000) = NULL,
    @sla_summary               NVARCHAR(2000) = NULL,
    @rto_hours                 INT            = NULL,
    @rpo_hours                 INT            = NULL,
    @contract_id               BIGINT         = NULL,
    @contract_reference        NVARCHAR(200)  = NULL,
    @contract_value            DECIMAL(19,2)  = NULL,
    @currency_code             NVARCHAR(10)   = NULL,
    @contract_start_dt         DATE           = NULL,
    @contract_end_dt           DATE           = NULL,
    @renewal_dt                DATE           = NULL,
    @contract_documents        NVARCHAR(1000) = NULL,
    @scope_json                NVARCHAR(MAX)  = NULL,
    @expected_record_version   BIGINT         = NULL,
    @actor_employee_id         BIGINT         = NULL,
    @actor                     NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @rv BIGINT, @stage NVARCHAR(30), @o_crit NVARCHAR(60), @o_data NVARCHAR(60), @o_sub NVARCHAR(60), @o_cust NVARCHAR(60);
    SELECT @rv = CONVERT(BIGINT, record_version), @stage = stage_code,
           @o_crit = service_criticality_code, @o_data = data_exposure_code, @o_sub = substitutability_code, @o_cust = customer_impact_code
    FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @rv IS NULL THROW 57630, 'That engagement was not found.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 57639, 'Someone else changed this engagement. Reload and try again.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;

    SELECT @app_access_answer         = UPPER(NULLIF(LTRIM(RTRIM(@app_access_answer)), N'')),
           @premises_access_answer    = UPPER(NULLIF(LTRIM(RTRIM(@premises_access_answer)), N'')),
           @data_processing_answer    = UPPER(NULLIF(LTRIM(RTRIM(@data_processing_answer)), N'')),
           @subcontracting_answer     = UPPER(NULLIF(LTRIM(RTRIM(@subcontracting_answer)), N'')),
           @important_process_answer  = UPPER(NULLIF(LTRIM(RTRIM(@important_process_answer)), N'')),
           @disruption_impact_answer  = UPPER(NULLIF(LTRIM(RTRIM(@disruption_impact_answer)), N'')),
           @service_commitment_answer = UPPER(NULLIF(LTRIM(RTRIM(@service_commitment_answer)), N'')),
           @contract_answer           = UPPER(NULLIF(LTRIM(RTRIM(@contract_answer)), N''));
    IF EXISTS (SELECT 1 FROM (VALUES (@app_access_answer), (@premises_access_answer), (@data_processing_answer),
                                     (@subcontracting_answer), (@important_process_answer), (@disruption_impact_answer),
                                     (@service_commitment_answer), (@contract_answer)) x(answer)
                WHERE x.answer IS NOT NULL AND x.answer NOT IN (N'YES', N'NO', N'UNKNOWN'))
        THROW 58063, 'Answer each question Yes, No or Not sure.', 1;
    SET @service_criticality_code = NULLIF(LTRIM(RTRIM(@service_criticality_code)), N'');
    IF @service_criticality_code IS NULL THROW 58070, 'Choose the service criticality.', 1;

    -- Only the dimensions that apply are kept (CR 2 5.2: "the system must
    -- not force users to populate every exposure dimension").
    SELECT @data_processing_details = NULLIF(LTRIM(RTRIM(@data_processing_details)), N''),
           @customer_impact_code = NULLIF(LTRIM(RTRIM(@customer_impact_code)), N''),
           @substitutability_code = NULLIF(LTRIM(RTRIM(@substitutability_code)), N''),
           @exit_dependencies = NULLIF(LTRIM(RTRIM(@exit_dependencies)), N''),
           @sla_summary = NULLIF(LTRIM(RTRIM(@sla_summary)), N''),
           @contract_reference = NULLIF(LTRIM(RTRIM(@contract_reference)), N''),
           @currency_code = NULLIF(LTRIM(RTRIM(@currency_code)), N''),
           @contract_documents = NULLIF(LTRIM(RTRIM(@contract_documents)), N'');
    IF ISNULL(@data_processing_answer, N'') <> N'YES' SET @data_processing_details = NULL;
    IF ISNULL(@disruption_impact_answer, N'') <> N'YES'
        SELECT @customer_impact_code = NULL, @substitutability_code = NULL, @exit_dependencies = NULL;
    IF ISNULL(@service_commitment_answer, N'') <> N'YES'
        SELECT @sla_summary = NULL, @rto_hours = NULL, @rpo_hours = NULL;
    IF ISNULL(@contract_answer, N'') <> N'YES'
        SELECT @contract_id = NULL, @contract_reference = NULL, @contract_value = NULL, @currency_code = NULL,
               @contract_start_dt = NULL, @contract_end_dt = NULL, @renewal_dt = NULL, @contract_documents = NULL;

    DECLARE @bad NVARCHAR(200);
    SELECT TOP (1) @bad = x.what FROM (VALUES
        (N'CRITICALITY',      @service_criticality_code, N'service criticality'),
        (N'CUSTOMER_IMPACT',  @customer_impact_code,     N'customer impact'),
        (N'SUBSTITUTABILITY', @substitutability_code,    N'substitutability')) x(list_code, code, what)
    WHERE x.code IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
                       WHERE r.list_code = x.list_code AND r.value_code = x.code);
    IF @bad IS NOT NULL
    BEGIN
        DECLARE @bad_msg NVARCHAR(300) = CONCAT(N'Choose a ', @bad, N' from the list.');
        THROW 57633, @bad_msg, 1;
    END
    IF (@rto_hours IS NOT NULL AND @rto_hours < 0) OR (@rpo_hours IS NOT NULL AND @rpo_hours < 0)
        THROW 57637, 'RTO and RPO cannot be negative.', 1;
    IF @contract_end_dt IS NOT NULL AND @contract_start_dt IS NOT NULL AND @contract_end_dt < @contract_start_dt
        THROW 58069, 'The contract end date is before its start date.', 1;
    IF @contract_id IS NOT NULL
    BEGIN
        IF OBJECT_ID('grac_practice.asset_contract','U') IS NULL THROW 57638, 'Contracts are not available in this installation.', 1;
        DECLARE @contract_ok INT;
        EXEC sp_executesql N'SELECT @n = COUNT(*) FROM grac_practice.asset_contract WHERE contract_id = @c AND organization_id = @o;',
             N'@n INT OUTPUT, @c BIGINT, @o BIGINT', @n = @contract_ok OUTPUT, @c = @contract_id, @o = @organization_id;
        IF ISNULL(@contract_ok, 0) = 0 THROW 57638, 'That contract was not found in this organization.', 1;
    END

    -- ---- the proposed scope items, as one set
    IF @scope_json IS NOT NULL AND ISJSON(@scope_json) <> 1 THROW 58064, 'The scope items are not valid.', 1;
    DECLARE @in TABLE (row_no INT IDENTITY(1,1) PRIMARY KEY, item_kind NVARCHAR(30), ref_id BIGINT, item_code NVARCHAR(60),
                       item_name NVARCHAR(300), country NVARCHAR(120), item_key NVARCHAR(500));
    INSERT @in (item_kind, ref_id, item_code, item_name, country)
    SELECT UPPER(NULLIF(LTRIM(RTRIM(j.kind)), N'')), j.refId, NULLIF(LTRIM(RTRIM(j.itemCode)), N''),
           NULLIF(LTRIM(RTRIM(j.itemName)), N''), NULLIF(LTRIM(RTRIM(j.country)), N'')
    FROM OPENJSON(ISNULL(@scope_json, N'[]'))
         WITH (kind NVARCHAR(30) '$.kind', refId BIGINT '$.refId', itemCode NVARCHAR(60) '$.itemCode',
               itemName NVARCHAR(300) '$.itemName', country NVARCHAR(120) '$.country') j;
    IF EXISTS (SELECT 1 FROM @in WHERE item_kind IS NULL OR item_kind NOT IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION',
                                                                              N'DATA_CATEGORY', N'ACCESS', N'LOCATION', N'FOURTH_PARTY'))
        THROW 58065, 'Unknown scope item type.', 1;
    -- a dimension that does not apply keeps no items
    DELETE FROM @in
    WHERE (item_kind = N'APPLICATION' AND ISNULL(@app_access_answer, N'') <> N'YES')
       OR (item_kind = N'ACCESS' AND ISNULL(@app_access_answer, N'') <> N'YES' AND ISNULL(@premises_access_answer, N'') <> N'YES')
       OR (item_kind = N'DATA_CATEGORY' AND ISNULL(@data_processing_answer, N'') <> N'YES')
       OR (item_kind = N'FOURTH_PARTY' AND ISNULL(@subcontracting_answer, N'') <> N'YES')
       OR (item_kind IN (N'BUSINESS_FUNCTION', N'PROCESS') AND ISNULL(@important_process_answer, N'') <> N'YES');
    UPDATE @in SET ref_id = NULL WHERE item_kind NOT IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION');
    -- GRAC records are picked, not typed: the name comes from the record.
    IF EXISTS (SELECT 1 FROM @in i WHERE i.ref_id IS NOT NULL
                 AND NOT ((i.item_kind = N'BUSINESS_FUNCTION' AND EXISTS (SELECT 1 FROM grac_practice.organization_business_function f
                                                                           WHERE f.business_function_id = i.ref_id AND f.organization_id = @organization_id))
                       OR (i.item_kind = N'PROCESS' AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process p
                                                                 WHERE p.process_id = i.ref_id AND p.organization_id = @organization_id))
                       OR (i.item_kind = N'APPLICATION' AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_application a
                                                                     WHERE a.application_id = i.ref_id AND a.organization_id = @organization_id))))
        THROW 58066, 'A GRAC record in the scope was not found in this organization.', 1;
    UPDATE i SET item_name = f.function_name FROM @in i
    JOIN grac_practice.organization_business_function f ON f.business_function_id = i.ref_id
    WHERE i.item_kind = N'BUSINESS_FUNCTION';
    UPDATE i SET item_name = p.process_name FROM @in i
    JOIN grac_practice.organization_dependency_process p ON p.process_id = i.ref_id
    WHERE i.item_kind = N'PROCESS';
    UPDATE i SET item_name = a.application_name FROM @in i
    JOIN grac_practice.organization_dependency_application a ON a.application_id = i.ref_id
    WHERE i.item_kind = N'APPLICATION';
    -- list values: the code must be in force; the name is its label
    DECLARE @lv TABLE (list_code NVARCHAR(60), value_code NVARCHAR(60), label NVARCHAR(200), rank_no INT, display_order INT);
    INSERT @lv (list_code, value_code, label, rank_no, display_order)
    SELECT r.list_code, r.value_code, r.label, r.rank_no, r.display_order
    FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
    WHERE r.list_code IN (N'DATA_EXPOSURE', N'ACCESS_CATEGORY', N'FOURTH_PARTY_CATEGORY');
    -- A value no longer in force (retired / hidden) that this engagement
    -- already records stays valid, so a save never drops it silently.
    DECLARE @kept TABLE (item_kind NVARCHAR(30), item_code NVARCHAR(60), item_name NVARCHAR(300));
    INSERT @kept (item_kind, item_code, item_name)
    SELECT s.item_kind, s.item_code, MAX(s.item_name) FROM grac_practice.tprm_engagement_scope s
    WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active' AND s.item_code IS NOT NULL
    GROUP BY s.item_kind, s.item_code;
    IF EXISTS (SELECT 1 FROM @in i
                WHERE (i.item_kind IN (N'DATA_CATEGORY', N'ACCESS')
                       AND (i.item_code IS NULL
                            OR (NOT EXISTS (SELECT 1 FROM @lv l
                                             WHERE l.list_code = CASE i.item_kind WHEN N'DATA_CATEGORY' THEN N'DATA_EXPOSURE' ELSE N'ACCESS_CATEGORY' END
                                               AND l.value_code = i.item_code)
                                AND NOT EXISTS (SELECT 1 FROM @kept k WHERE k.item_kind = i.item_kind AND k.item_code = i.item_code))))
                   OR (i.item_kind = N'FOURTH_PARTY' AND i.item_code IS NOT NULL
                       AND NOT EXISTS (SELECT 1 FROM @lv l WHERE l.list_code = N'FOURTH_PARTY_CATEGORY' AND l.value_code = i.item_code)
                       AND NOT EXISTS (SELECT 1 FROM @kept k WHERE k.item_kind = N'FOURTH_PARTY' AND k.item_code = i.item_code)))
        THROW 58067, 'Choose the scope values from the lists.', 1;
    UPDATE i SET item_name = k.item_name FROM @in i
    JOIN @kept k ON k.item_kind = i.item_kind AND k.item_code = i.item_code
    WHERE i.item_kind IN (N'DATA_CATEGORY', N'ACCESS');
    UPDATE i SET item_name = l.label FROM @in i
    JOIN @lv l ON l.list_code = CASE i.item_kind WHEN N'DATA_CATEGORY' THEN N'DATA_EXPOSURE' ELSE N'ACCESS_CATEGORY' END
              AND l.value_code = i.item_code
    WHERE i.item_kind IN (N'DATA_CATEGORY', N'ACCESS');
    UPDATE @in SET item_code = NULL WHERE item_kind IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION', N'LOCATION');
    UPDATE @in SET country = NULL WHERE item_kind NOT IN (N'LOCATION', N'FOURTH_PARTY');
    IF EXISTS (SELECT 1 FROM @in WHERE item_name IS NULL) THROW 58068, 'Every scope item needs a name.', 1;
    UPDATE @in SET item_key = grac_practice.fn_tprm_scope_item_key(item_kind, ref_id, item_code, item_name, country);
    DELETE i FROM @in i WHERE EXISTS (SELECT 1 FROM @in d WHERE d.item_key = i.item_key AND d.row_no < i.row_no);

    -- the derived data exposure
    DECLARE @data_code NVARCHAR(60) = NULL;
    IF @data_processing_answer = N'YES'
        SELECT TOP (1) @data_code = i.item_code
        FROM @in i LEFT JOIN @lv l ON l.list_code = N'DATA_EXPOSURE' AND l.value_code = i.item_code
        WHERE i.item_kind = N'DATA_CATEGORY'
        ORDER BY ISNULL(l.rank_no, 0) DESC, ISNULL(l.display_order, 9999);
    ELSE IF @data_processing_answer = N'NO'
        SELECT TOP (1) @data_code = l.value_code FROM @lv l
        WHERE l.list_code = N'DATA_EXPOSURE' AND l.rank_no = 0
        ORDER BY l.display_order;

    DECLARE @added INT = 0, @removed INT = 0, @flagged BIT = 0;
    BEGIN TRAN;
    UPDATE grac_practice.tprm_engagement
       SET app_access_answer = @app_access_answer, premises_access_answer = @premises_access_answer,
           data_processing_answer = @data_processing_answer, subcontracting_answer = @subcontracting_answer,
           important_process_answer = @important_process_answer, disruption_impact_answer = @disruption_impact_answer,
           service_commitment_answer = @service_commitment_answer, contract_answer = @contract_answer,
           service_criticality_code = @service_criticality_code, data_exposure_code = @data_code,
           data_processing_details = @data_processing_details,
           customer_impact_code = @customer_impact_code, substitutability_code = @substitutability_code,
           exit_dependencies = @exit_dependencies,
           sla_summary = @sla_summary, rto_hours = @rto_hours, rpo_hours = @rpo_hours,
           contract_id = @contract_id, contract_reference = @contract_reference, contract_value = @contract_value,
           currency_code = @currency_code, contract_start_dt = @contract_start_dt, contract_end_dt = @contract_end_dt,
           renewal_dt = @renewal_dt, contract_documents = @contract_documents,
           exposure_saved_dt = SYSUTCDATETIME(), exposure_saved_by = @actor,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE engagement_id = @engagement_id;

    -- items no longer listed
    UPDATE s SET status = N'Removed', updated_by = @actor, updated_dt = SYSUTCDATETIME()
    FROM grac_practice.tprm_engagement_scope s
    WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active'
      AND NOT EXISTS (SELECT 1 FROM @in i
                       WHERE i.item_key = grac_practice.fn_tprm_scope_item_key(s.item_kind, s.ref_id, s.item_code, s.item_name, s.country));
    SET @removed = @@ROWCOUNT;
    -- items kept: the name and the fourth-party category follow the page
    UPDATE s SET item_name = i.item_name,
                 item_code = CASE WHEN s.item_kind = N'FOURTH_PARTY' THEN i.item_code ELSE s.item_code END,
                 updated_by = @actor, updated_dt = SYSUTCDATETIME()
    FROM grac_practice.tprm_engagement_scope s
    JOIN @in i ON i.item_key = grac_practice.fn_tprm_scope_item_key(s.item_kind, s.ref_id, s.item_code, s.item_name, s.country)
    WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active'
      AND (s.item_name <> i.item_name
           OR (s.item_kind = N'FOURTH_PARTY' AND ISNULL(s.item_code, N'') <> ISNULL(i.item_code, N'')));
    -- new items
    INSERT grac_practice.tprm_engagement_scope
        (engagement_id, organization_id, item_kind, exposure_mode, ref_id, item_code, item_name, country, entered_by)
    SELECT @engagement_id, @organization_id, i.item_kind, N'PROPOSED', i.ref_id, i.item_code, i.item_name, i.country, @actor
    FROM @in i
    WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope s
                       WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active'
                         AND grac_practice.fn_tprm_scope_item_key(s.item_kind, s.ref_id, s.item_code, s.item_name, s.country) = i.item_key);
    SET @added = @@ROWCOUNT;

    DECLARE @material NVARCHAR(1000) = NULLIF(CONCAT_WS(N'; ',
        CASE WHEN ISNULL(@o_crit, N'') <> ISNULL(@service_criticality_code, N'') THEN CONCAT(N'criticality ', @o_crit, N' -> ', @service_criticality_code) END,
        CASE WHEN ISNULL(@o_data, N'') <> ISNULL(@data_code, N'') THEN CONCAT(N'data exposure ', @o_data, N' -> ', @data_code) END,
        CASE WHEN ISNULL(@o_cust, N'') <> ISNULL(@customer_impact_code, N'') THEN CONCAT(N'customer impact ', @o_cust, N' -> ', @customer_impact_code) END,
        CASE WHEN ISNULL(@o_sub, N'') <> ISNULL(@substitutability_code, N'') THEN CONCAT(N'substitutability ', @o_sub, N' -> ', @substitutability_code) END), N'');
    EXEC grac_practice.sp_tprm_engagement_flag_material @engagement_id, @stage, @material, @actor_employee_id, @actor, @flagged OUTPUT;
    DECLARE @detail NVARCHAR(2000) = CONCAT(N'Scope & exposure saved: ', @added, N' proposed item(s) added, ', @removed, N' removed.');
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'EXPOSURE_SAVED', @stage, @stage, @detail, @actor_employee_id, @actor;
    -- 523 (CR 2 6.1): the screening report, generated from what was just saved
    DECLARE @screen_trigger NVARCHAR(20) = N'EXPOSURE_SAVED';
    EXEC grac_practice.sp_tprm_screening_run @organization_id, @engagement_id, @screen_trigger, @actor_employee_id, @actor, 1;
    COMMIT;

    SELECT @engagement_id AS EngagementId, CASE WHEN @flagged = 1 THEN N'MATERIAL_CHANGE' ELSE N'SAVED' END AS Result;
END
GO

-- Result sets: 1 header  2 scope  3 links  4 snapshots  5 history
--              6 custom values  7 dimensions of the current assessment
-- (re-issued by 523: the applicability status and the current screening
-- report in the header)
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

-- Engagement register (488) -- re-issued by 523: the applicability
-- status and screening classification per row, and a filter on the
-- applicability status.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_list
    @organization_id    BIGINT,
    @search             NVARCHAR(200) = NULL,
    @third_party_id     BIGINT        = NULL,
    @stage_code         NVARCHAR(30)  = NULL,   -- a stage, OPEN (not closed) or CLOSED
    @band_code          NVARCHAR(60)  = NULL,   -- residual band, else inherent
    @criticality_code   NVARCHAR(60)  = NULL,
    @owner_employee_id  BIGINT        = NULL,
    @attention          NVARCHAR(30)  = NULL,   -- REASSESS / REVIEW_DUE / MINE
    @applicability_status NVARCHAR(30) = NULL,  -- 523: an applicability status, or UNDECIDED (screened / deferred / not screened)
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
           e.applicability_status AS ApplicabilityStatus, sr.classification AS ScreeningClassification,
           COUNT(*) OVER () AS TotalRows
    FROM   grac_practice.tprm_engagement e
    JOIN   grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
    LEFT   JOIN ref sc ON sc.list_code = N'SERVICE_CATEGORY' AND sc.value_code = e.service_category_code
    LEFT   JOIN ref cr ON cr.list_code = N'CRITICALITY' AND cr.value_code = e.service_criticality_code
    LEFT   JOIN ref dt ON dt.list_code = N'DD_TIER' AND dt.value_code = e.dd_tier_code
    LEFT   JOIN grac_practice.tprm_rm_band ib ON ib.version_id = e.risk_model_version_id AND ib.band_code = e.inherent_band_code
    LEFT   JOIN grac_practice.tprm_rm_band rb ON rb.version_id = e.risk_model_version_id AND rb.band_code = e.residual_band_code
    LEFT   JOIN grac_practice.organization_employee bo ON bo.employee_id = e.business_owner_employee_id
    LEFT   JOIN grac_practice.tprm_screening_report sr ON sr.report_id = e.current_screening_report_id
    WHERE  e.organization_id = @organization_id
      AND  (@applicability_status IS NULL OR e.applicability_status = @applicability_status
            OR (@applicability_status = N'UNDECIDED' AND e.applicability_status IN (N'NOT_SCREENED', N'SCREENED', N'DEFERRED', N'ADMISSION_REJECTED')))
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

-- Start an inherent assessment (488; 522) -- re-issued by 523: only for
-- an engagement admitted to formal TPRM (CR 2 7.1-5). Everything else as
-- in 522.
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
    -- 523 (CR 2 7.1-5): the formal TPRM lifecycle starts after admission.
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND applicability_status <> N'ADMITTED')
        THROW 58125, 'The inherent risk assessment starts after the engagement is admitted to formal TPRM (screening, decision, admission approval).', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id
                 AND (exposure_saved_dt IS NULL OR service_criticality_code IS NULL))
        THROW 58071, 'Save Scope & Exposure (with the service criticality) before assessing risk.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope WHERE engagement_id = @engagement_id AND status = N'Active')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND data_exposure_code IS NOT NULL)
        THROW 57662, 'Record the scope (at least the data exposure) before assessing risk.', 1;

    DECLARE @version BIGINT = (SELECT version_id FROM grac_practice.fn_tprm_risk_model_version(@organization_id));
    IF @version IS NULL THROW 57663, 'No risk model is in force. Activate one in Third-Party Settings.', 1;
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

-- BRD 5.2 sample records (522) -- re-issued by 523: each sample
-- engagement's Scope & Exposure counts as saved, so it gets its Initial
-- Exposure Screening Report in the same transaction. Otherwise as in 522.
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
    DECLARE @active NVARCHAR(60) = ISNULL(grac_practice.fn_tprm_meaning_code(@organization_id, N'TP_STATUS', N'ACTIVE'), N'ACTIVE');
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
             country, lifecycle_status_code, first_activated_dt, relationship_owner_employee_id, profile_notes, is_sample, entered_by)
        SELECT @organization_id, @tcode, p.legal_name, grac_practice.fn_tprm_normalize_name(p.legal_name), p.provider_type_code,
               p.service_category_code, p.country, @active, SYSUTCDATETIME(), @actor_employee_id,
               CONCAT(N'Illustrative sample record - not a real provider and not a completed assessment. ', p.notes),
               1, @actor
        FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        SET @tp = SCOPE_IDENTITY();
        INSERT grac_practice.tprm_third_party_category (third_party_id, service_category_code)
        SELECT @tp, p.service_category_code FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        VALUES (@tp, NULL, @active, N'Sample record loaded (registered and activated).', 0, @actor_employee_id, @actor);

        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(engagement_code, 5, 20))), 0) + 1
        FROM grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK)
        WHERE organization_id = @organization_id AND engagement_code LIKE N'ENG-%';
        SET @ecode = N'ENG-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_engagement
            (organization_id, third_party_id, engagement_code, engagement_title, service_description, scope_description, business_purpose,
             service_category_code, engagement_type_code, service_model_code, delivery_locations, is_existing, service_criticality_code,
             data_exposure_code, rto_hours, rpo_hours, notes, is_sample, stage_code, exposure_saved_dt, exposure_saved_by, entered_by)
        SELECT @organization_id, @tp, @ecode, p.engagement_title, p.service_description, p.scope_description, p.business_purpose,
               p.service_category_code, p.engagement_type_code, p.service_model_code, p.country, 0, p.criticality_code,
               p.data_exposure_code, p.rto_hours, p.rpo_hours,
               CONCAT(N'Sample guidance -- key safeguards: ', p.key_safeguards, N'. Evidence expected: ', p.evidence_expectations,
                      N'. Review triggers: ', p.review_triggers, N'.'),
               1, N'SCOPING', SYSUTCDATETIME(), @actor, @actor
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

        -- the gating questions, answered from what the sample records
        EXEC grac_practice.sp_tprm_engagement_answers_derive @eng, @actor;
        EXEC grac_practice.sp_tprm_engagement_event @eng, N'CREATED', NULL, N'SCOPING', N'Sample engagement loaded.', @actor_employee_id, @actor;
        -- 523: its Scope & Exposure counts as saved, so it is screened too
        EXEC grac_practice.sp_tprm_screening_run @organization_id, @eng, N'EXPOSURE_SAVED', @actor_employee_id, @actor, 1;
        COMMIT;
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
-- 7. Existing engagements
-- =====================================================================
-- Engagements already in the formal lifecycle (past scoping, or with an
-- inherent assessment) are treated as admitted -- their risk work stands
-- (design doc, open point 2). Scoping engagements with Scope & Exposure
-- saved are screened now and await the client's decision.
UPDATE e
   SET applicability_status = N'ADMITTED', admitted_dt = COALESCE(e.admitted_dt, e.updated_dt, e.entered_dt)
FROM grac_practice.tprm_engagement e
WHERE e.applicability_status = N'NOT_SCREENED'
  AND (e.stage_code NOT IN (N'SCOPING', N'CANCELLED')
       OR EXISTS (SELECT 1 FROM grac_practice.tprm_risk_assessment a WHERE a.engagement_id = e.engagement_id));
PRINT CONCAT('523: engagements treated as admitted: ', @@ROWCOUNT);
GO
DECLARE @org BIGINT, @eng BIGINT, @screened INT = 0;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT e.organization_id, e.engagement_id FROM grac_practice.tprm_engagement e
    WHERE e.applicability_status = N'NOT_SCREENED' AND e.stage_code = N'SCOPING' AND e.exposure_saved_dt IS NOT NULL
      AND e.current_screening_report_id IS NULL;
OPEN c;
FETCH NEXT FROM c INTO @org, @eng;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC grac_practice.sp_tprm_screening_run @org, @eng, N'MIGRATION', NULL, N'migration-523', 1;
    SET @screened = @screened + 1;
    FETCH NEXT FROM c INTO @org, @eng;
END
CLOSE c;
DEALLOCATE c;
PRINT CONCAT('523: engagements screened: ', @screened);
GO

-- =====================================================================
-- 8. Verification
-- =====================================================================
SELECT '523-a screening objects' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.tprm_screening_report', 'U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_screening_observation', 'U') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_screening_run', 'P') IS NOT NULL
             AND (SELECT COUNT(*) FROM grac_practice.tprm_reference_value
                   WHERE organization_id IS NULL AND list_code = N'SCREENING_INDICATOR' AND status = N'Active') = 9
             AND EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('grac_practice.sp_tprm_engagement_discover')
                           AND name = N'@suppress_result')
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '523-b decision and admission objects',
       CASE WHEN OBJECT_ID('grac_practice.tprm_applicability_decision', 'U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_admission', 'U') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_admission_approval', 'U') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_applicability_decide', 'P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_admission_act', 'P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_admission_withdraw', 'P') IS NOT NULL
             AND COL_LENGTH('grac_practice.tprm_engagement', 'applicability_status') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '523-c exposure save screens; risk assessment needs admission',
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules m WHERE m.object_id = OBJECT_ID('grac_practice.sp_tprm_engagement_exposure_save')
                           AND CHARINDEX(N'sp_tprm_screening_run', m.[definition]) > 0)
             AND EXISTS (SELECT 1 FROM sys.sql_modules m WHERE m.object_id = OBJECT_ID('grac_practice.sp_tprm_risk_assessment_start')
                           AND CHARINDEX(N'58125', m.[definition]) > 0)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '523-d every saved scoping engagement is screened or decided',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement
                              WHERE stage_code = N'SCOPING' AND exposure_saved_dt IS NOT NULL AND current_screening_report_id IS NULL
                                AND applicability_status <> N'ADMITTED')
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '523 complete. Deploy the API and Web builds of this change.';
GO
