-- =====================================================================
-- 525_tpm_dashboard_tasks_profile_review.sql
--
-- REQUEST (2026-11-09)
-- --------------------
--   Third-Party Management after CR 2 Rounds A-C, the next phase chosen by
--   the product owner: (1) TPRM dashboard rework to the CR 2 views,
--   (2) remaining links carry record ids encrypted (Web only -- nothing
--   here), (3) a Defer decision creates a Task Board task (open point 3a),
--   (4) a review cycle for the TP Risk Register vendor profile (open
--   point 7). Design: docs/tpm-lifecycle-redesign.md section 15.5.
--
-- WHAT CHANGES
-- ------------
--   1. Task type TprmInformationRequest; task source ThirdParty (the
--      ck_pm_practice_task_source_type list of 449 plus ThirdParty;
--      sp_task_centre_source_counts re-issued from 449 with it).
--      tprm_applicability_decision.information_task_id.
--      sp_tprm_applicability_decide (523) re-issued: a DEFER naming the
--      person asked for information opens a task for that person
--      (sp_task_open) in the same transaction. sp_tprm_applicability_get
--      (523) re-issued: the decisions show the task number and status.
--   2. Vendor profile review: tprm_risk_register.last_profile_review_dt /
--      next_profile_review_dt / profile_review_rule_code;
--      tprm_register_profile_review; sp_tprm_register_profile_review_save
--      (every area rated; next date from the review rule on the overall
--      band rank and the linked engagements' highest criticality).
--      sp_tprm_register_link (524) re-issued: a new record's first review
--      is due within the rule's lead days. sp_tprm_register_list / _get
--      (524) re-issued: review dates, attention PROFILE_REVIEW_DUE, review
--      history. Existing records get their first due date now.
--   3. sp_dashboard_tprm (507) re-issued: CR 2 KPIs (awaiting decision,
--      potential cases, information required, deferred, admissions
--      pending, excluded; register total, high overall risk, impact
--      reviews, profile reviews overdue / due, not fully rated, exiting),
--      distributions (applicability, register by overall risk), ageing of
--      pending admissions and lists (pending admissions, register needs
--      attention). Every 507 row is kept.
--
-- RUN ORDER: after 524. 524 refuses to re-run afterwards.
-- ERROR NUMBERS: 58200-58249 (and 58151, 58157 reused).
-- Note: sp_tprm_register_list accepts attention PROFILE_REVIEW_DUE (due in 30
-- days or overdue) and PROFILE_REVIEW_OVERDUE.
-- DEPENDS ON: 486-490, 521-524; 196 (sp_task_open), 449 (task source list).
-- 507 need not have run: its watchlist is part of the dashboard re-issued
-- here, and 507 refuses to re-run afterwards (it would remove the 525 rows).
-- Rollback: 525_tpm_dashboard_tasks_profile_review_rollback.sql
-- SAFE TO RE-RUN. ASCII-only. SQL Server 2017+.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.tprm_risk_register', 'U') IS NULL OR OBJECT_ID('grac_practice.fn_tprm_register_overall') IS NULL
BEGIN PRINT 'ABORT (525): run 524_tpm_cr2_risk_register.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_open', 'P') IS NULL OR OBJECT_ID('grac_practice.task_type_master', 'U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_source_type' AND definition LIKE '%Schedule''%')
BEGIN PRINT 'ABORT (525): the Task Centre (196) and the scheduled-task source (449) are required.'; SET @ok = 0; END
-- 507 is not required: the dashboard below is the 507 body (which carries
-- 490's whole contract plus the high-risk watchlist) with the 525 rows.
IF OBJECT_ID('grac_practice.sp_dashboard_tprm', 'P') IS NULL
BEGIN PRINT 'ABORT (525): run 490_tprm_menu_dashboard.sql first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('525_tpm_dashboard_tasks_profile_review: prerequisites missing -- see the messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Task Board: the TPRM information-request task (open point 3a)
-- =====================================================================
MERGE grac_practice.task_type_master AS t
USING (VALUES (N'TprmInformationRequest', N'TPRM Information Request',
               N'Provide the information a deferred TPRM applicability decision is waiting for', 120, N'Medium', 1, 96))
   AS s(type_code, type_name, description, default_sla_hours, default_priority, is_system_only, display_order)
ON t.type_code = s.type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (type_code, type_name, description, default_sla_hours, default_priority, is_system_only, display_order, entered_by)
    VALUES (s.type_code, s.type_name, s.description, s.default_sla_hours, s.default_priority, s.is_system_only, s.display_order, N'migration-525');
PRINT CONCAT('525: task type inserted: ', @@ROWCOUNT);
GO
-- Task source "ThirdParty" (additive; 449's list kept verbatim -- a value no
-- row uses yet is harmless, as 449 notes).
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_practice_task_source_type' AND definition LIKE '%ThirdParty''%')
BEGIN
    ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_source_type;
    ALTER TABLE grac_practice.practice_task WITH NOCHECK
        ADD CONSTRAINT ck_pm_practice_task_source_type
            CHECK (source_type_code IS NULL
                OR source_type_code IN (N'Gap', N'Exception', N'Risk',
                                        N'RiskRegister',
                                        N'ContinuousAssurance', N'EventAssurance',
                                        N'Custom',
                                        N'Asset',
                                        N'Schedule',
                                        N'ThirdParty'));                  -- NEW in 525
    PRINT '525: practice_task source vocabulary widened (ThirdParty).';
END
GO
IF COL_LENGTH('grac_practice.tprm_applicability_decision', 'information_task_id') IS NULL
    ALTER TABLE grac_practice.tprm_applicability_decision ADD information_task_id BIGINT NULL;
GO

-- =====================================================================
-- 2. Vendor profile review cycle (open point 7)
-- =====================================================================
IF COL_LENGTH('grac_practice.tprm_risk_register', 'next_profile_review_dt') IS NULL
    ALTER TABLE grac_practice.tprm_risk_register ADD
        last_profile_review_dt   DATETIME2    NULL,
        next_profile_review_dt   DATE         NULL,
        profile_review_rule_code NVARCHAR(60) NULL;
GO
IF OBJECT_ID('grac_practice.tprm_register_profile_review', 'U') IS NULL
BEGIN
    -- One row per periodic review of a register record's vendor profile:
    -- who confirmed it, the overall vendor risk at the time, the review rule
    -- and the next due date it set.
    CREATE TABLE grac_practice.tprm_register_profile_review(
        profile_review_id       BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tprm_register_profile_review PRIMARY KEY,
        register_id             BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rpv_reg REFERENCES grac_practice.tprm_risk_register(register_id),
        reviewed_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_tprm_rpv_dt DEFAULT SYSUTCDATETIME(),
        reviewed_by_employee_id BIGINT         NOT NULL
            CONSTRAINT fk_pm_tprm_rpv_by REFERENCES grac_practice.organization_employee(employee_id),
        reviewed_by             NVARCHAR(100)  NOT NULL,
        rationale               NVARCHAR(2000) NOT NULL,
        overall_band_code       NVARCHAR(60)   NULL,
        overall_band_name       NVARCHAR(120)  NULL,
        rule_code               NVARCHAR(60)   NOT NULL,
        frequency_months        INT            NOT NULL,
        next_review_dt          DATE           NOT NULL
    );
    CREATE INDEX ix_pm_tprm_rpv_reg ON grac_practice.tprm_register_profile_review(register_id, reviewed_dt);
    PRINT '525: tprm_register_profile_review created.';
END
GO

-- Record a periodic review of a register record's vendor profile (open
-- point 7): every area in use must have a current rating (re-rate what
-- changed first); the next review date follows the TPRM review rule
-- matched on the overall vendor risk band rank and the highest service
-- criticality of the linked engagements (fn_tprm_match_review_rule).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_register_profile_review_save
    @organization_id   BIGINT,
    @register_id       BIGINT,
    @rationale         NVARCHAR(2000),
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @actor_employee_id IS NULL THROW 58200, 'Recording the profile review needs a sign-in linked to an employee (the reviewer).', 1;
    SET @rationale = NULLIF(LTRIM(RTRIM(@rationale)), N'');
    IF @rationale IS NULL THROW 58201, 'Record what the review found.', 1;
    DECLARE @status NVARCHAR(20), @missing INT, @band NVARCHAR(60), @bname NVARCHAR(120), @rank INT, @crank INT,
            @rule NVARCHAR(60), @freq INT, @next DATE, @id BIGINT, @today DATE = CONVERT(DATE, SYSUTCDATETIME());
    BEGIN TRAN;
        SELECT @status = status FROM grac_practice.tprm_risk_register WITH (UPDLOCK, HOLDLOCK)
        WHERE register_id = @register_id AND organization_id = @organization_id;
        IF @status IS NULL THROW 58151, 'That register record was not found.', 1;
        IF @status = N'CLOSED' THROW 58157, 'A closed register record cannot be changed.', 1;
        SELECT @missing = COUNT(*) FROM grac_practice.fn_tprm_reference_effective(@organization_id) a
        WHERE a.list_code = N'VENDOR_PROFILE_AREA'
          AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_register_profile_rating p
                           WHERE p.register_id = @register_id AND p.area_code = a.value_code AND p.status = N'CURRENT');
        IF @missing > 0
        BEGIN
            DECLARE @mmsg NVARCHAR(300) = CONCAT(@missing, N' vendor profile area(s) are not rated yet. Rate every area before recording the review.');
            THROW 58202, @mmsg, 1;
        END
        SELECT @band = band_code, @bname = band_name, @rank = rank_no FROM grac_practice.fn_tprm_register_overall(@register_id);
        SELECT @crank = MAX(c.rank_no)
        FROM grac_practice.tprm_register_engagement l
        JOIN grac_practice.tprm_engagement e ON e.engagement_id = l.engagement_id
        JOIN grac_practice.fn_tprm_reference_effective(@organization_id) c ON c.list_code = N'CRITICALITY' AND c.value_code = e.service_criticality_code
        WHERE l.register_id = @register_id AND l.status = N'LINKED';
        SELECT @rule = rule_code, @freq = review_frequency_months FROM grac_practice.fn_tprm_match_review_rule(@organization_id, @rank, @crank);
        IF @rule IS NULL THROW 58203, 'No review rule applies. Add a catch-all review rule in Third-Party Settings.', 1;
        SET @next = DATEADD(MONTH, @freq, @today);
        INSERT grac_practice.tprm_register_profile_review
            (register_id, reviewed_by_employee_id, reviewed_by, rationale, overall_band_code, overall_band_name, rule_code, frequency_months, next_review_dt)
        VALUES (@register_id, @actor_employee_id, ISNULL(@actor, N'system'), @rationale, @band, @bname, @rule, @freq, @next);
        SET @id = SCOPE_IDENTITY();
        UPDATE grac_practice.tprm_risk_register
           SET last_profile_review_dt = SYSUTCDATETIME(), next_profile_review_dt = @next, profile_review_rule_code = @rule,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE register_id = @register_id;
        DECLARE @detail NVARCHAR(2000) = LEFT(CONCAT(N'Vendor profile reviewed (overall ', ISNULL(@bname, N'not rated'), N'); next review ',
                                                     CONVERT(NVARCHAR(10), @next, 23), N' (rule ', @rule, N'). ', @rationale), 2000);
        EXEC grac_practice.sp_tprm_register_event @register_id, N'PROFILE_REVIEWED', NULL, @detail, @actor_employee_id, @actor;
    COMMIT;
    SELECT @id AS ProfileReviewId, @next AS NextProfileReviewDt, N'REVIEWED' AS Result;
END
GO

-- =====================================================================
-- 3. Re-issued procedures
-- =====================================================================
-- Applicability decision (523) -- re-issued by 525: a DEFER that names the
-- person asked for information opens a Task Board task for that person.
-- Otherwise as in 523.
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
        -- 525: the information-request task of the decision being replaced
        -- is cancelled (Task state machine, when its status allows it), so
        -- a revised decision never leaves a stale task behind.
        DECLARE @old_task BIGINT, @old_task_status NVARCHAR(60);
        SELECT @old_task = d.information_task_id, @old_task_status = s.status_code
        FROM grac_practice.tprm_applicability_decision d
        JOIN grac_practice.practice_task t ON t.task_id = d.information_task_id
        JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
        WHERE d.engagement_id = @engagement_id AND d.status = N'CURRENT';
        IF @old_task IS NOT NULL
           AND EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule
                        WHERE entity_type = N'Task' AND from_status_code = @old_task_status AND to_status_code = N'Cancelled'
                          AND actor_role_code IS NULL AND requires_approval = 0 AND is_active = 1)
            EXEC grac_practice.sp_task_transition
                 @task_id           = @old_task,
                 @to_status_code    = N'Cancelled',
                 @actor_employee_id = @actor_employee_id,
                 @reason_code       = N'TPRM_DECISION_REVISED',
                 @reason_text       = N'The deferred TPRM applicability decision was replaced by a new decision.';
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
        -- 525 (open point 3a): a deferral that names the person asked for
        -- information opens a Task Board task for that person.
        IF @decision = N'DEFER' AND @information_from_employee_id IS NOT NULL
        BEGIN
            DECLARE @task BIGINT, @task_title NVARCHAR(250), @task_desc NVARCHAR(MAX), @task_ref NVARCHAR(200),
                    -- the task type's five days, given explicitly: sp_task_open then skips its
                    -- post-commit SLA step, which could otherwise doom this transaction
                    @task_due DATETIME2 = DATEADD(DAY, 5, SYSUTCDATETIME());
            SELECT @task_title = LEFT(CONCAT(N'TPRM information requested: ', e.engagement_code, N' - ', e.engagement_title), 250),
                   @task_ref = e.engagement_code,
                   @task_desc = CONCAT(N'The TPRM applicability decision on ', e.engagement_code, N' (', t.legal_name, N') is deferred until this information is provided: ',
                                       ISNULL(NULLIF(LTRIM(RTRIM(@information_request)), N''), N'(see the rationale)'),
                                       NCHAR(13), NCHAR(10), N'Rationale: ', @rationale,
                                       NCHAR(13), NCHAR(10), N'Reply in Engagement Management -> Screening & decision, then complete this task.')
            FROM grac_practice.tprm_engagement e
            JOIN grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
            WHERE e.engagement_id = @engagement_id;
            EXEC grac_practice.sp_task_open
                 @organization_id         = @organization_id,
                 @task_type_code          = N'TprmInformationRequest',
                 @subject_entity_type     = N'TprmApplicabilityDecision',
                 @subject_entity_id       = @id,
                 @subject_title           = @task_title,
                 @subject_description     = @task_desc,
                 @priority                = N'Medium',
                 @origin_code             = N'GRAC',
                 @assigned_to_employee_id = @information_from_employee_id,
                 @actor_employee_id       = @actor_employee_id,
                 @source_type_code        = N'ThirdParty',
                 @source_record_id        = @engagement_id,
                 @source_reference        = @task_ref,
                 @resolve_owner           = 0,
                 @target_date             = @task_due,
                 @task_id                 = @task OUTPUT;
            UPDATE grac_practice.tprm_applicability_decision SET information_task_id = @task WHERE decision_id = @id;
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

-- Screening & decision data (523) -- re-issued by 525: the decisions carry
-- their information-request task. Otherwise as in 523.
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
           d.entered_dt AS EnteredDt, d.superseded_dt AS SupersededDt,
           d.information_task_id AS InformationTaskId, it.task_number AS InformationTaskNumber,
           its.status_code AS InformationTaskStatus                                   -- 525
    FROM grac_practice.tprm_applicability_decision d
    JOIN grac_practice.tprm_screening_report r ON r.report_id = d.report_id
    LEFT JOIN grac_practice.practice_task it ON it.task_id = d.information_task_id
    LEFT JOIN grac_practice.entity_status_master its ON its.entity_status_id = it.current_status_id
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

-- Task Centre source counts (449) -- re-issued by 525: + ThirdParty.
CREATE OR ALTER PROCEDURE grac_practice.sp_task_centre_source_counts
    @organization_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Result set 1 -- the filterable vocabulary, in dropdown order.
    ;WITH vocab(SourceTypeCode, DisplayOrder) AS (
        SELECT N'Gap',                 1 UNION ALL
        SELECT N'Exception',           2 UNION ALL
        SELECT N'Risk',                3 UNION ALL
        SELECT N'RiskRegister',        4 UNION ALL
        SELECT N'ContinuousAssurance', 5 UNION ALL
        SELECT N'EventAssurance',      6 UNION ALL
        SELECT N'Custom',              7 UNION ALL
        SELECT N'Asset',               8 UNION ALL                                     -- 438
        SELECT N'Schedule',            9 UNION ALL                                     -- 449
        SELECT N'ThirdParty',         10                                               -- 525
    )
    SELECT v.SourceTypeCode,
           v.DisplayOrder,
           (SELECT COUNT_BIG(*)
              FROM grac_practice.practice_task t
             WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
               AND t.parent_task_id IS NULL
               AND t.source_type_code = v.SourceTypeCode) AS TaskCount
    FROM   vocab v
    ORDER  BY v.DisplayOrder;

    -- Result set 2 -- totals, so the dropdown can label "All sources"
    -- and the caller can see how many rows carry no source at all.
    SELECT
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND t.parent_task_id IS NULL) AS TotalCount,
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND t.parent_task_id IS NULL
            AND t.source_type_code IS NULL) AS UnsourcedCount;
END
GO

-- Register link (524) -- re-issued by 525: a new record's first vendor
-- profile review is due within the review rule's lead days.
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
        -- 525: the first vendor profile review is due within the review
        -- rule's lead days (rule matched on the engagement's criticality)
        DECLARE @crank INT = (SELECT criticality_rank FROM grac_practice.fn_tprm_engagement_ranks(@engagement_id));
        DECLARE @lead INT, @prule NVARCHAR(60);
        SELECT @lead = review_lead_days, @prule = rule_code FROM grac_practice.fn_tprm_match_review_rule(@org, NULL, @crank);
        UPDATE grac_practice.tprm_risk_register
           SET next_profile_review_dt = DATEADD(DAY, ISNULL(@lead, 30), CONVERT(DATE, SYSUTCDATETIME())), profile_review_rule_code = @prule
         WHERE register_id = @reg;
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

-- Register list (524) -- re-issued by 525: profile review dates and the
-- PROFILE_REVIEW_DUE attention filter.
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
    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N''), @areas INT, @today DATE = CONVERT(DATE, SYSUTCDATETIME());
    SELECT @areas = COUNT(*) FROM grac_practice.fn_tprm_reference_effective(@organization_id) WHERE list_code = N'VENDOR_PROFILE_AREA';

    SELECT r.register_id AS RegisterId, r.register_code AS RegisterCode, r.status AS Status,
           r.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS ThirdPartyName,
           r.admitted_dt AS AdmittedDt, r.exit_started_dt AS ExitStartedDt, r.closed_dt AS ClosedDt,
           o.band_code AS OverallBandCode, o.band_name AS OverallBand, o.color_hex AS OverallBandColor,
           o.source_kind AS OverallSourceKind, o.source_code AS OverallSourceCode,
           n.linked AS LinkedEngagements, n.open_findings AS OpenFindings, n.open_impact AS OpenImpactReviews,
           n.rated AS RatedAreas, @areas AS ProfileAreas, n.last_rated AS LastRatedDt, n.next_review AS NextReviewDt,
           r.last_profile_review_dt AS LastProfileReviewDt, r.next_profile_review_dt AS NextProfileReviewDt,
           CAST(CASE WHEN r.status <> N'CLOSED' AND r.next_profile_review_dt < @today THEN 1 ELSE 0 END AS BIT) AS ProfileReviewOverdue,
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
            OR (@attention = N'EXIT' AND r.status = N'EXIT_IN_PROGRESS')
            OR (@attention = N'PROFILE_REVIEW_DUE' AND r.status <> N'CLOSED' AND r.next_profile_review_dt <= DATEADD(DAY, 30, @today))
            OR (@attention = N'PROFILE_REVIEW_OVERDUE' AND r.status <> N'CLOSED' AND r.next_profile_review_dt < @today))
      AND  (@s IS NULL OR r.register_code LIKE N'%' + @s + N'%' OR t.legal_name LIKE N'%' + @s + N'%'
            OR t.third_party_code LIKE N'%' + @s + N'%'
            OR EXISTS (SELECT 1 FROM grac_practice.tprm_register_engagement l JOIN grac_practice.tprm_engagement e ON e.engagement_id = l.engagement_id
                        WHERE l.register_id = r.register_id AND (e.engagement_code LIKE N'%' + @s + N'%' OR e.engagement_title LIKE N'%' + @s + N'%')))
    ORDER  BY CASE r.status WHEN N'EXIT_IN_PROGRESS' THEN 0 WHEN N'OPEN' THEN 1 ELSE 2 END, ISNULL(o.rank_no, -1) DESC, t.legal_name, r.register_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Register record (524) -- re-issued by 525: profile review dates in the
-- header and the profile review history (set 12).
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
           (SELECT TOP (1) version_id FROM grac_practice.fn_tprm_risk_model_version(@organization_id)) AS RiskModelVersionId,
           r.last_profile_review_dt AS LastProfileReviewDt, r.next_profile_review_dt AS NextProfileReviewDt,
           r.profile_review_rule_code AS ProfileReviewRuleCode                         -- 525
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

    -- 12 vendor profile reviews (525)
    SELECT v.profile_review_id AS ProfileReviewId, v.reviewed_dt AS ReviewedDt, ISNULL(ve.employee_name, v.reviewed_by) AS ReviewedBy,
           v.rationale AS Rationale, v.overall_band_code AS OverallBandCode, v.overall_band_name AS OverallBandName,
           v.rule_code AS RuleCode, v.frequency_months AS FrequencyMonths, v.next_review_dt AS NextReviewDt
    FROM   grac_practice.tprm_register_profile_review v
    LEFT   JOIN grac_practice.organization_employee ve ON ve.employee_id = v.reviewed_by_employee_id
    WHERE  v.register_id = @register_id
    ORDER  BY v.reviewed_dt DESC, v.profile_review_id DESC;
END
GO

-- Third-Party Management dashboard (507) -- re-issued by 525 with the CR 2
-- views (see the header). Every 507 row is kept.
CREATE OR ALTER PROCEDURE grac_practice.sp_dashboard_tprm
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 57900, 'sp_dashboard_tprm: organization_id is required.', 1;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- Engagements with the band / criticality the engagement list shows.
    SELECT e.engagement_id, e.engagement_code, e.engagement_title, e.stage_code, e.stage_dt, t.legal_name AS third_party_name,
           COALESCE(e.residual_band_code, e.inherent_band_code) AS band_code, b.band_name, b.color_hex, b.rank_no AS band_rank,
           e.service_criticality_code, e.reassessment_required, e.next_review_dt, e.acceptance_until,
           COALESCE(e.actual_end_dt, e.proposed_end_dt) AS end_dt,
           ow.employee_name AS owner_name,
           e.applicability_status, sr.classification AS screening_classification            -- 525 (CR 2 6-7)
      INTO #eng
      FROM grac_practice.tprm_engagement e
      JOIN grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
      LEFT JOIN grac_practice.tprm_rm_band b ON b.version_id = e.risk_model_version_id
                                            AND b.band_code = COALESCE(e.residual_band_code, e.inherent_band_code)
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = COALESCE(e.relationship_owner_employee_id, e.business_owner_employee_id)
      LEFT JOIN grac_practice.tprm_screening_report sr ON sr.report_id = e.current_screening_report_id
     WHERE e.organization_id = @organization_id;

    -- 525 (CR 2 8): TP Risk Register records with their overall vendor
    -- risk and open items.
    SELECT r.register_id, r.register_code, r.status, r.next_profile_review_dt, t.legal_name AS third_party_name,
           o.band_code, o.band_name, o.color_hex, o.rank_no AS band_rank, ow.employee_name AS owner_name,
           (SELECT COUNT(*) FROM grac_practice.tprm_register_impact_review i WHERE i.register_id = r.register_id AND i.status = N'OPEN') AS open_impact,
           (SELECT COUNT(*) FROM grac_practice.fn_tprm_reference_effective(@organization_id) a
             WHERE a.list_code = N'VENDOR_PROFILE_AREA'
               AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_register_profile_rating p
                                WHERE p.register_id = r.register_id AND p.area_code = a.value_code AND p.status = N'CURRENT')) AS unrated
      INTO #reg
      FROM grac_practice.tprm_risk_register r
      JOIN grac_practice.tprm_third_party t ON t.third_party_id = r.third_party_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = t.relationship_owner_employee_id
      OUTER APPLY grac_practice.fn_tprm_register_overall(r.register_id) o
     WHERE r.organization_id = @organization_id AND r.status <> N'CLOSED';
    SELECT a.admission_id, a.engagement_id, a.submitted_dt
      INTO #adm
      FROM grac_practice.tprm_admission a
     WHERE a.organization_id = @organization_id AND a.status = N'PENDING';

    SELECT f.finding_id, f.finding_number, f.finding_kind, f.title, f.severity_code, f.status, f.due_dt, f.entered_dt,
           f.engagement_id, ow.employee_name AS owner_name, sv.rank_no AS severity_rank, sv.label AS severity_label, sv.color_hex
      INTO #fnd
      FROM grac_practice.tprm_finding f
      JOIN #eng x ON x.engagement_id = f.engagement_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = f.owner_employee_id
      LEFT JOIN grac_practice.fn_tprm_reference_effective(@organization_id) sv ON sv.list_code = N'FINDING_SEVERITY' AND sv.value_code = f.severity_code
     WHERE f.status IN (N'OPEN', N'IN_PROGRESS')
       AND x.stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED');   -- findings of closed engagements are history

    SELECT r.review_id, r.review_number, r.review_type, r.trigger_code, r.due_dt, r.raised_dt, r.engagement_id,
           ow.employee_name AS owner_name
      INTO #rev
      FROM grac_practice.tprm_review r
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.owner_employee_id
     WHERE r.organization_id = @organization_id AND r.status = N'OPEN';

    SELECT d.dd_id, d.engagement_id, d.due_dt, d.started_dt
      INTO #dd
      FROM grac_practice.tprm_dd_assessment d
     WHERE d.organization_id = @organization_id AND d.status = N'IN_PROGRESS';

    SELECT d.decision_id, d.engagement_id, d.submitted_dt
      INTO #dec
      FROM grac_practice.tprm_decision d
     WHERE d.organization_id = @organization_id AND d.status = N'PENDING';

    DECLARE @open_stages TABLE (stage_code NVARCHAR(30));
    INSERT @open_stages VALUES (N'SCOPING'), (N'RISK_ASSESSED'), (N'DUE_DILIGENCE'), (N'PENDING_DECISION'), (N'APPROVED'),
                               (N'ONBOARDING'), (N'ACTIVE'), (N'SUSPENDED'), (N'EXITING');

    -- ---- 0. KPIs --------------------------------------------------------
    SELECT k.SectionKey, k.SectionTitle, k.KpiKey, k.Label, k.Value, k.IsAlert, k.SortOrder
      FROM (
        SELECT N'tprmthirdparties' AS SectionKey, N'Third parties' AS SectionTitle, N'total' AS KpiKey, N'Registered (active records)' AS Label,
               (SELECT COUNT(*) FROM grac_practice.tprm_third_party WHERE organization_id = @organization_id AND status = N'Active') AS Value,
               CAST(0 AS BIT) AS IsAlert, 1 AS SortOrder
        UNION ALL SELECT N'tprmthirdparties', N'Third parties', N'withactive', N'With an active engagement',
                         (SELECT COUNT(DISTINCT e.third_party_id) FROM grac_practice.tprm_engagement e
                           WHERE e.organization_id = @organization_id AND e.stage_code = N'ACTIVE'), 0, 2
        UNION ALL SELECT N'tprmthirdparties', N'Third parties', N'samples', N'Sample records',
                         (SELECT COUNT(*) FROM grac_practice.tprm_third_party WHERE organization_id = @organization_id AND is_sample = 1 AND status = N'Active'), 0, 3

        UNION ALL SELECT N'tprmengagements', N'Engagements', N'open', N'Open engagements',
                         (SELECT COUNT(*) FROM #eng x WHERE x.stage_code IN (SELECT stage_code FROM @open_stages)), 0, 1
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'inassessment', N'In assessment',
                         (SELECT COUNT(*) FROM #eng x WHERE x.stage_code IN (N'SCOPING', N'RISK_ASSESSED', N'DUE_DILIGENCE')), 0, 2
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'pendingdecision', N'Pending decision',
                         (SELECT COUNT(*) FROM #eng x WHERE x.stage_code = N'PENDING_DECISION'), 1, 3
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'active', N'Active',
                         (SELECT COUNT(*) FROM #eng x WHERE x.stage_code = N'ACTIVE'), 0, 4
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'highrisk', N'Active, high or critical band',
                         (SELECT COUNT(*) FROM #eng x WHERE x.stage_code IN (N'ACTIVE', N'SUSPENDED') AND x.band_rank >= 3), 1, 5
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'reassess', N'Reassessment required',
                         (SELECT COUNT(*) FROM #eng x WHERE x.reassessment_required = 1 AND x.stage_code IN (SELECT stage_code FROM @open_stages)), 1, 6
        -- 525 (CR 2 6-7): screening, applicability decision, admission
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'undecided', N'Awaiting the applicability decision',
                         (SELECT COUNT(*) FROM #eng x WHERE x.applicability_status IN (N'NOT_SCREENED', N'SCREENED', N'DEFERRED', N'ADMISSION_REJECTED')
                             AND x.stage_code IN (SELECT stage_code FROM @open_stages)), 1, 7
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'potentialcase', N'Potential TPRM cases awaiting a decision',
                         (SELECT COUNT(*) FROM #eng x WHERE x.applicability_status = N'SCREENED' AND x.screening_classification = N'POTENTIAL_TPRM_CASE'
                             AND x.stage_code IN (SELECT stage_code FROM @open_stages)), 1, 8
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'inforequired', N'Further information required',
                         (SELECT COUNT(*) FROM #eng x WHERE x.applicability_status IN (N'SCREENED', N'DEFERRED')
                             AND x.screening_classification = N'FURTHER_INFORMATION_REQUIRED'
                             AND x.stage_code IN (SELECT stage_code FROM @open_stages)), 0, 9
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'deferred', N'Decisions deferred',
                         (SELECT COUNT(*) FROM #eng x WHERE x.applicability_status = N'DEFERRED' AND x.stage_code IN (SELECT stage_code FROM @open_stages)), 0, 10
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'admissionpending', N'Admission approvals pending', (SELECT COUNT(*) FROM #adm), 1, 11
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'excluded', N'Excluded from formal TPRM',
                         (SELECT COUNT(*) FROM #eng x WHERE x.applicability_status = N'EXCLUDED' AND x.stage_code IN (SELECT stage_code FROM @open_stages)), 0, 12

        -- 525 (CR 2 8): TP Risk Register
        UNION ALL SELECT N'tprmregister', N'TP Risk Register', N'total', N'Vendors on the register', (SELECT COUNT(*) FROM #reg), 0, 1
        UNION ALL SELECT N'tprmregister', N'TP Risk Register', N'high', N'Overall vendor risk high or critical',
                         (SELECT COUNT(*) FROM #reg WHERE band_rank >= 3), 1, 2
        UNION ALL SELECT N'tprmregister', N'TP Risk Register', N'impactopen', N'Impact reviews open',
                         (SELECT COUNT(*) FROM grac_practice.tprm_register_impact_review i JOIN #reg g ON g.register_id = i.register_id WHERE i.status = N'OPEN'), 1, 3
        UNION ALL SELECT N'tprmregister', N'TP Risk Register', N'reviewoverdue', N'Vendor profile reviews overdue',
                         (SELECT COUNT(*) FROM #reg WHERE next_profile_review_dt < @today), 1, 4
        UNION ALL SELECT N'tprmregister', N'TP Risk Register', N'reviewdue30', N'Vendor profile reviews due in 30 days',
                         (SELECT COUNT(*) FROM #reg WHERE next_profile_review_dt BETWEEN @today AND DATEADD(DAY, 30, @today)), 0, 5
        UNION ALL SELECT N'tprmregister', N'TP Risk Register', N'notrated', N'Vendor profile not fully rated',
                         (SELECT COUNT(*) FROM #reg WHERE unrated > 0), 0, 6
        UNION ALL SELECT N'tprmregister', N'TP Risk Register', N'exiting', N'Exit in progress',
                         (SELECT COUNT(*) FROM #reg WHERE status = N'EXIT_IN_PROGRESS'), 1, 7
        UNION ALL SELECT N'tprmregister', N'TP Risk Register', N'attention', N'Needing attention (impact review or profile review due)',
                         (SELECT COUNT(*) FROM #reg WHERE open_impact > 0 OR next_profile_review_dt <= DATEADD(DAY, 30, @today)), 0, 8

        UNION ALL SELECT N'tprmdiligence', N'Due diligence', N'inprogress', N'Rounds in progress', (SELECT COUNT(*) FROM #dd), 0, 1
        UNION ALL SELECT N'tprmdiligence', N'Due diligence', N'overdue', N'Overdue rounds',
                         (SELECT COUNT(*) FROM #dd WHERE due_dt < @today), 1, 2
        UNION ALL SELECT N'tprmdiligence', N'Due diligence', N'evidencepending', N'Evidence awaiting review',
                         (SELECT COUNT(*) FROM grac_practice.tprm_evidence_link l JOIN #eng x ON x.engagement_id = l.engagement_id
                           WHERE l.status = N'Active' AND l.review_status = N'PENDING'), 1, 3

        UNION ALL SELECT N'tprmfindings', N'Findings and remediation', N'open', N'Open findings', (SELECT COUNT(*) FROM #fnd), 0, 1
        UNION ALL SELECT N'tprmfindings', N'Findings and remediation', N'high', N'Open high or critical',
                         (SELECT COUNT(*) FROM #fnd WHERE severity_rank >= 3), 1, 2
        UNION ALL SELECT N'tprmfindings', N'Findings and remediation', N'overdue', N'Overdue remediation',
                         (SELECT COUNT(*) FROM #fnd WHERE due_dt < @today), 1, 3
        UNION ALL SELECT N'tprmfindings', N'Findings and remediation', N'conditions', N'Open approval conditions',
                         (SELECT COUNT(*) FROM #fnd WHERE finding_kind = N'CONDITION'), 0, 4

        UNION ALL SELECT N'tprmreviews', N'Reviews and monitoring', N'open', N'Open reviews', (SELECT COUNT(*) FROM #rev), 0, 1
        UNION ALL SELECT N'tprmreviews', N'Reviews and monitoring', N'overdue', N'Overdue reviews',
                         (SELECT COUNT(*) FROM #rev WHERE due_dt < @today), 1, 2
        UNION ALL SELECT N'tprmreviews', N'Reviews and monitoring', N'due30', N'Due in 30 days',
                         (SELECT COUNT(*) FROM #rev WHERE due_dt BETWEEN @today AND DATEADD(DAY, 30, @today)), 0, 3
        UNION ALL SELECT N'tprmreviews', N'Reviews and monitoring', N'triggered', N'Open triggered reviews',
                         (SELECT COUNT(*) FROM #rev WHERE review_type = N'TRIGGERED'), 0, 4

        UNION ALL SELECT N'tprmacceptance', N'Acceptance and expiry', N'accepted', N'Live engagements with accepted risk',
                         (SELECT COUNT(*) FROM #eng x WHERE x.acceptance_until IS NOT NULL AND x.stage_code IN (N'APPROVED', N'ONBOARDING', N'ACTIVE', N'SUSPENDED')), 0, 1
        UNION ALL SELECT N'tprmacceptance', N'Acceptance and expiry', N'acceptexpiring', N'Acceptance ending in 60 days',
                         (SELECT COUNT(*) FROM #eng x WHERE x.acceptance_until BETWEEN @today AND DATEADD(DAY, 60, @today)
                             AND x.stage_code IN (N'APPROVED', N'ONBOARDING', N'ACTIVE', N'SUSPENDED')), 1, 2
        UNION ALL SELECT N'tprmacceptance', N'Acceptance and expiry', N'contractexpiring', N'Engagements ending in 90 days',
                         (SELECT COUNT(*) FROM #eng x WHERE x.end_dt BETWEEN @today AND DATEADD(DAY, 90, @today) AND x.stage_code IN (N'ACTIVE', N'SUSPENDED')), 1, 3
        UNION ALL SELECT N'tprmacceptance', N'Acceptance and expiry', N'certexpiring', N'Accepted evidence expiring in 60 days',
                         (SELECT COUNT(*) FROM grac_practice.tprm_evidence_link l JOIN #eng x ON x.engagement_id = l.engagement_id
                           WHERE l.status = N'Active' AND l.review_status = N'ACCEPTED' AND x.stage_code IN (N'ACTIVE', N'SUSPENDED')
                             AND l.valid_to BETWEEN @today AND DATEADD(DAY, 60, @today)), 1, 4
      ) k
     ORDER BY CASE k.SectionKey WHEN N'tprmthirdparties' THEN 1 WHEN N'tprmengagements' THEN 2 WHEN N'tprmregister' THEN 3
                                WHEN N'tprmdiligence' THEN 4 WHEN N'tprmfindings' THEN 5 WHEN N'tprmreviews' THEN 6 ELSE 7 END, k.SortOrder;

    -- ---- 1. Ageing: open findings (days since recorded), pending
    --         decisions (days since requested) -----------------------------
    SELECT N'tprmfindings' AS GroupKey, N'Open findings' AS GroupTitle,
           b.BandCode, b.BandName, b.SortOrder, b.MinDays, b.MaxDays,
           (SELECT COUNT(*) FROM #fnd x WHERE DATEDIFF(DAY, x.entered_dt, SYSUTCDATETIME()) BETWEEN b.MinDays AND b.MaxDays) AS ItemCount
      FROM grac_practice.fn_pm_ageing_band() b
    UNION ALL
    SELECT N'tprmengagements', N'Pending decisions',
           b.BandCode, b.BandName, b.SortOrder, b.MinDays, b.MaxDays,
           (SELECT COUNT(*) FROM #dec x WHERE DATEDIFF(DAY, x.submitted_dt, SYSUTCDATETIME()) BETWEEN b.MinDays AND b.MaxDays)
      FROM grac_practice.fn_pm_ageing_band() b
    UNION ALL
    SELECT N'tprmadmissions', N'Pending admissions',                                 -- 525
           b.BandCode, b.BandName, b.SortOrder, b.MinDays, b.MaxDays,
           (SELECT COUNT(*) FROM #adm x WHERE DATEDIFF(DAY, x.submitted_dt, SYSUTCDATETIME()) BETWEEN b.MinDays AND b.MaxDays)
      FROM grac_practice.fn_pm_ageing_band() b
     ORDER BY 1, 5;

    -- ---- 2. Distributions ----------------------------------------------
    -- ItemKey is the value the Engagements / Reviews filter takes.
    SELECT d.GroupKey, d.GroupTitle, d.ItemKey, d.ItemLabel, d.ItemCount, d.ColourHex, d.SortOrder
      FROM (
        SELECT N'tprmengagements_stage' AS GroupKey, N'Engagements by stage' AS GroupTitle,
               x.stage_code AS ItemKey,
               CAST(CASE x.stage_code WHEN N'SCOPING' THEN N'Scoping' WHEN N'RISK_ASSESSED' THEN N'Risk assessed'
                    WHEN N'DUE_DILIGENCE' THEN N'Due diligence' WHEN N'PENDING_DECISION' THEN N'Pending decision'
                    WHEN N'APPROVED' THEN N'Approved' WHEN N'ONBOARDING' THEN N'Onboarding' WHEN N'ACTIVE' THEN N'Active'
                    WHEN N'SUSPENDED' THEN N'Suspended' WHEN N'EXITING' THEN N'Exiting' ELSE x.stage_code END AS NVARCHAR(200)) AS ItemLabel,
               COUNT(*) AS ItemCount, CAST(NULL AS NVARCHAR(20)) AS ColourHex,
               MIN(CASE x.stage_code WHEN N'SCOPING' THEN 1 WHEN N'RISK_ASSESSED' THEN 2 WHEN N'DUE_DILIGENCE' THEN 3
                    WHEN N'PENDING_DECISION' THEN 4 WHEN N'APPROVED' THEN 5 WHEN N'ONBOARDING' THEN 6 WHEN N'ACTIVE' THEN 7
                    WHEN N'SUSPENDED' THEN 8 ELSE 9 END) AS SortOrder
          FROM #eng x WHERE x.stage_code IN (SELECT stage_code FROM @open_stages)
         GROUP BY x.stage_code
        UNION ALL
        SELECT N'tprmengagements_band', N'Open engagements by risk band (residual, else inherent)',
               x.band_code, CAST(ISNULL(MAX(x.band_name), N'Not assessed') AS NVARCHAR(200)), COUNT(*), MAX(x.color_hex), ISNULL(MAX(x.band_rank), 0)
          FROM #eng x WHERE x.stage_code IN (SELECT stage_code FROM @open_stages)
         GROUP BY x.band_code
        UNION ALL
        SELECT N'tprmengagements_criticality', N'Open engagements by service criticality',
               x.service_criticality_code, CAST(ISNULL(MAX(c.label), N'Not set') AS NVARCHAR(200)), COUNT(*), MAX(c.color_hex), ISNULL(MAX(c.rank_no), 0)
          FROM #eng x
          LEFT JOIN grac_practice.fn_tprm_reference_effective(@organization_id) c ON c.list_code = N'CRITICALITY' AND c.value_code = x.service_criticality_code
         WHERE x.stage_code IN (SELECT stage_code FROM @open_stages)
         GROUP BY x.service_criticality_code
        UNION ALL
        -- 525: applicability of the open engagements; ItemKey is the
        -- Engagement Management applicability filter value
        SELECT N'tprmengagements_applicability', N'Open engagements by TPRM applicability',
               g.k, CAST(MAX(g.lbl) AS NVARCHAR(200)), COUNT(*), CAST(NULL AS NVARCHAR(20)), MIN(g.ord)
          -- "Awaiting decision" = the Engagement Management UNDECIDED filter
          -- (not screened, screened, deferred, admission rejected)
          FROM (SELECT CASE WHEN x.applicability_status IN (N'NOT_SCREENED', N'SCREENED', N'DEFERRED', N'ADMISSION_REJECTED') THEN N'UNDECIDED'
                            ELSE x.applicability_status END AS k,
                       CASE WHEN x.applicability_status IN (N'NOT_SCREENED', N'SCREENED', N'DEFERRED', N'ADMISSION_REJECTED') THEN N'Awaiting decision'
                            WHEN x.applicability_status = N'ADMISSION_PENDING' THEN N'Admission pending'
                            WHEN x.applicability_status = N'ADMITTED' THEN N'Admitted to formal TPRM'
                            ELSE N'Excluded from formal TPRM' END AS lbl,
                       CASE WHEN x.applicability_status IN (N'NOT_SCREENED', N'SCREENED', N'DEFERRED', N'ADMISSION_REJECTED') THEN 1
                            WHEN x.applicability_status = N'ADMISSION_PENDING' THEN 3
                            WHEN x.applicability_status = N'ADMITTED' THEN 4 ELSE 5 END AS ord
                  FROM #eng x WHERE x.stage_code IN (SELECT stage_code FROM @open_stages)) g
         GROUP BY g.k
        UNION ALL
        -- 525: register records by overall vendor risk; ItemKey is the
        -- TP Risk Register overall-risk filter value
        SELECT N'tprmregister_overall', N'Register records by overall vendor risk',
               g.band_code, CAST(ISNULL(MAX(g.band_name), N'Not rated or assessed') AS NVARCHAR(200)), COUNT(*), MAX(g.color_hex), ISNULL(MAX(g.band_rank), 0)
          FROM #reg g GROUP BY g.band_code
        UNION ALL
        SELECT N'tprmfindings_severity', N'Open findings by severity',
               CAST(NULL AS NVARCHAR(60)), CAST(ISNULL(MAX(f.severity_label), f.severity_code) AS NVARCHAR(200)), COUNT(*), MAX(f.color_hex), ISNULL(MAX(f.severity_rank), 0) * -1
          FROM #fnd f GROUP BY f.severity_code
        UNION ALL
        SELECT N'tprmreviews_type', N'Open reviews by type',
               x.review_type,
               CAST(CASE x.review_type WHEN N'PERIODIC' THEN N'Periodic' WHEN N'TRIGGERED' THEN N'Triggered'
                    WHEN N'CONTRACT_EXPIRY' THEN N'Contract expiry' WHEN N'CERTIFICATION_EXPIRY' THEN N'Certification expiry'
                    ELSE N'Acceptance expiry' END AS NVARCHAR(200)),
               COUNT(*), CAST(NULL AS NVARCHAR(20)),
               MIN(CASE x.review_type WHEN N'PERIODIC' THEN 1 WHEN N'TRIGGERED' THEN 2 WHEN N'CONTRACT_EXPIRY' THEN 3
                    WHEN N'CERTIFICATION_EXPIRY' THEN 4 ELSE 5 END)
          FROM #rev x GROUP BY x.review_type
      ) d
     ORDER BY d.GroupKey, d.SortOrder, d.ItemLabel;

    -- ---- 3. Lists ---------------------------------------------------------
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'tprmreviews_overdue' AS ListKey, N'Overdue reviews' AS ListTitle,
               r.engagement_id AS RecordId, CAST(r.review_number AS NVARCHAR(60)) AS RefText,
               CAST(CONCAT(x.third_party_name, N' - ', x.engagement_title) AS NVARCHAR(400)) AS Title,
               r.owner_name AS OwnerName, CAST(r.trigger_code AS NVARCHAR(400)) AS StatusText, r.due_dt AS DateValue,
               ROW_NUMBER() OVER (ORDER BY r.due_dt, r.review_id) AS SortOrder
          FROM #rev r JOIN #eng x ON x.engagement_id = r.engagement_id
         WHERE r.due_dt < @today
         ORDER BY r.due_dt, r.review_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'tprmfindings_overdue' AS ListKey, N'Overdue remediation' AS ListTitle,
               f.engagement_id AS RecordId, CAST(f.finding_number AS NVARCHAR(60)) AS RefText,
               CAST(CONCAT(x.engagement_code, N' - ', f.title) AS NVARCHAR(400)) AS Title,
               f.owner_name AS OwnerName, CAST(ISNULL(f.severity_label, f.severity_code) AS NVARCHAR(400)) AS StatusText, f.due_dt AS DateValue,
               ROW_NUMBER() OVER (ORDER BY f.due_dt, f.finding_id) AS SortOrder
          FROM #fnd f JOIN #eng x ON x.engagement_id = f.engagement_id
         WHERE f.due_dt < @today
         ORDER BY f.due_dt, f.finding_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'tprmengagements_decisions' AS ListKey, N'Pending decisions' AS ListTitle,
               x.engagement_id AS RecordId, CAST(x.engagement_code AS NVARCHAR(60)) AS RefText,
               CAST(CONCAT(x.third_party_name, N' - ', x.engagement_title) AS NVARCHAR(400)) AS Title,
               x.owner_name AS OwnerName, CAST(ISNULL(x.band_name, N'Not assessed') AS NVARCHAR(400)) AS StatusText,
               CAST(d.submitted_dt AS DATE) AS DateValue,
               ROW_NUMBER() OVER (ORDER BY d.submitted_dt, d.decision_id) AS SortOrder
          FROM #dec d JOIN #eng x ON x.engagement_id = d.engagement_id
         ORDER BY d.submitted_dt, d.decision_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'tprmacceptance_expiring' AS ListKey, N'Risk acceptance ending in 60 days' AS ListTitle,
               x.engagement_id AS RecordId, CAST(x.engagement_code AS NVARCHAR(60)) AS RefText,
               CAST(CONCAT(x.third_party_name, N' - ', x.engagement_title) AS NVARCHAR(400)) AS Title,
               x.owner_name AS OwnerName, CAST(ISNULL(x.band_name, N'') AS NVARCHAR(400)) AS StatusText, x.acceptance_until AS DateValue,
               ROW_NUMBER() OVER (ORDER BY x.acceptance_until, x.engagement_id) AS SortOrder
          FROM #eng x
         WHERE x.acceptance_until BETWEEN @today AND DATEADD(DAY, 60, @today)
           AND x.stage_code IN (N'APPROVED', N'ONBOARDING', N'ACTIVE', N'SUSPENDED')
         ORDER BY x.acceptance_until, x.engagement_id
      ) l
    UNION ALL
    -- 507: high-risk watchlist (spec 10.4) -- exactly the engagements KPI
    -- tprmengagements.highrisk counts (ACTIVE / SUSPENDED, band rank >= 3),
    -- highest band first, then the nearest next review. StatusText = band;
    -- DateValue = next review date.
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (15) N'tprmengagements_highrisk' AS ListKey, N'High-risk engagements' AS ListTitle,
               x.engagement_id AS RecordId, CAST(x.engagement_code AS NVARCHAR(60)) AS RefText,
               CAST(CONCAT(x.third_party_name, N' - ', x.engagement_title) AS NVARCHAR(400)) AS Title,
               x.owner_name AS OwnerName, CAST(ISNULL(x.band_name, x.band_code) AS NVARCHAR(400)) AS StatusText,
               CAST(x.next_review_dt AS DATE) AS DateValue,
               ROW_NUMBER() OVER (ORDER BY x.band_rank DESC, CASE WHEN x.next_review_dt IS NULL THEN 1 ELSE 0 END,
                                           x.next_review_dt, x.engagement_id) AS SortOrder
          FROM #eng x
         WHERE x.stage_code IN (N'ACTIVE', N'SUSPENDED') AND x.band_rank >= 3
         ORDER BY x.band_rank DESC, CASE WHEN x.next_review_dt IS NULL THEN 1 ELSE 0 END, x.next_review_dt, x.engagement_id
      ) l
    UNION ALL
    -- 525: pending admissions (RecordId = engagement), oldest first
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'tprmengagements_admissions' AS ListKey, N'Admission approvals pending' AS ListTitle,
               x.engagement_id AS RecordId, CAST(x.engagement_code AS NVARCHAR(60)) AS RefText,
               CAST(CONCAT(x.third_party_name, N' - ', x.engagement_title) AS NVARCHAR(400)) AS Title,
               x.owner_name AS OwnerName,
               CAST(CASE x.screening_classification WHEN N'POTENTIAL_TPRM_CASE' THEN N'Potential TPRM case'
                    WHEN N'FURTHER_INFORMATION_REQUIRED' THEN N'Further information required'
                    WHEN N'NO_SIGNIFICANT_INDICATORS' THEN N'No significant indicators' ELSE N'' END AS NVARCHAR(400)) AS StatusText,
               CAST(a.submitted_dt AS DATE) AS DateValue,
               ROW_NUMBER() OVER (ORDER BY a.submitted_dt, a.admission_id) AS SortOrder
          FROM #adm a JOIN #eng x ON x.engagement_id = a.engagement_id
         ORDER BY a.submitted_dt, a.admission_id
      ) l
    UNION ALL
    -- 525: register records needing attention (RecordId = register record):
    -- open impact review, or vendor profile review due in 30 days / overdue
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'tprmregister_attention' AS ListKey, N'TP Risk Register: needs attention' AS ListTitle,
               g.register_id AS RecordId, CAST(g.register_code AS NVARCHAR(60)) AS RefText,
               CAST(g.third_party_name AS NVARCHAR(400)) AS Title, g.owner_name AS OwnerName,
               CAST(CONCAT(CASE WHEN g.open_impact > 0 THEN N'Impact review open' END,
                           CASE WHEN g.open_impact > 0 AND g.next_profile_review_dt <= DATEADD(DAY, 30, @today) THEN N'; ' END,
                           CASE WHEN g.next_profile_review_dt < @today THEN N'Profile review overdue'
                                WHEN g.next_profile_review_dt <= DATEADD(DAY, 30, @today) THEN N'Profile review due' END) AS NVARCHAR(400)) AS StatusText,
               g.next_profile_review_dt AS DateValue,
               ROW_NUMBER() OVER (ORDER BY CASE WHEN g.open_impact > 0 THEN 0 ELSE 1 END, g.next_profile_review_dt, g.register_id) AS SortOrder
          FROM #reg g
         WHERE g.open_impact > 0 OR g.next_profile_review_dt <= DATEADD(DAY, 30, @today)
         ORDER BY CASE WHEN g.open_impact > 0 THEN 0 ELSE 1 END, g.next_profile_review_dt, g.register_id
      ) l
     ORDER BY 1, 9;
END
GO

-- =====================================================================
-- 4. Existing data: register records without a profile review date are
--    due within the lead days of the rule matched on their linked
--    engagements' highest criticality, counted from today.
-- =====================================================================
UPDATE r
   SET next_profile_review_dt = DATEADD(DAY, ISNULL(m.review_lead_days, 30), CONVERT(DATE, SYSUTCDATETIME())),
       profile_review_rule_code = m.rule_code
  FROM grac_practice.tprm_risk_register r
  OUTER APPLY (SELECT MAX(c.rank_no) AS crank
                 FROM grac_practice.tprm_register_engagement l
                 JOIN grac_practice.tprm_engagement e ON e.engagement_id = l.engagement_id
                 CROSS APPLY (SELECT TOP (1) v.rank_no FROM grac_practice.fn_tprm_reference_effective(r.organization_id) v
                               WHERE v.list_code = N'CRITICALITY' AND v.value_code = e.service_criticality_code) c
                WHERE l.register_id = r.register_id AND l.status = N'LINKED') x
  OUTER APPLY grac_practice.fn_tprm_match_review_rule(r.organization_id, NULL, x.crank) m
 WHERE r.status <> N'CLOSED' AND r.next_profile_review_dt IS NULL;
PRINT CONCAT('525: register records given a first profile review date: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 5. Verification
-- =====================================================================
SELECT '525-a task type and source' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'TprmInformationRequest')
             AND EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_source_type' AND definition LIKE '%ThirdParty''%')
             AND COL_LENGTH('grac_practice.tprm_applicability_decision', 'information_task_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '525-b profile review cycle',
       CASE WHEN OBJECT_ID('grac_practice.tprm_register_profile_review', 'U') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_register_profile_review_save', 'P') IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_risk_register WHERE status <> N'CLOSED' AND next_profile_review_dt IS NULL)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '525-c dashboard',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_dashboard_tprm')) LIKE '%tprmregister_attention%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_dashboard_tprm')) LIKE '%tprmengagements_highrisk%'
            THEN 'PASS' ELSE 'FAIL' END;
GO
SET NOEXEC OFF;
GO
