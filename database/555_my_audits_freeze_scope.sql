-- =====================================================================
-- 555  Phase 3 -- My Audits, live scope, Freeze Scope
--
-- REQUEST (2026-11-14, sir) -- docs/audit-flow-redesign.md Phase 3.
-- DECISIONS (sir):
--   * Executions are created AUTOMATICALLY when the auditor opens My Audits
--     on or after the engagement's From date; Start Execution on the plan
--     stays (an admin may start early).
--   * My Audits is a new sidebar menu item under Audit Assurance.
--   * Before freezing, the auditor may EXCLUDE items from the live scope,
--     each with a reason (kept on the execution).
--   * Frozen is FINAL -- to change the scope, cancel and start again.
--
-- MODEL
--   An engagement's execution is created with a LIVE scope: no entity rows
--   and scope_frozen_at NULL. Its live scope is the audit's scope resolved
--   now, narrowed to the engagement's Branch (554). The auditor (the
--   execution's owner = the engagement's Assigned Auditor) reviews it and
--   clicks Freeze Scope: the scope is resolved (EXECUTION), narrowed, the
--   exclusions removed and recorded, the entity rows copied, and the
--   execution moves Planned -> In Progress. Manual / trigger executions are
--   frozen at creation, as before. Executions that exist already are
--   marked frozen (they have their entities).
--
-- WHAT THIS DOES
--   1. org_assurance_execution + scope_frozen_at / scope_frozen_by
--      (backfilled for existing rows); NEW org_assurance_execution_scope_exclusion.
--   2. Menu: org-my-audits "My Audits" under nav-assurance (468, before
--      Executions), granted to every active role (it lists only the
--      caller's own audits).
--   3. sp_org_assurance_execution_materialize (545 body) + @live.
--   4. sp_org_assurance_plan_item_start_execution (554 body): creates the
--      executions LIVE (the 554 narrowing moves to the live view / freeze);
--      + @suppress_result.
--   5. sp_org_assurance_execution_start (099 body): refuses a live scope
--      (54030) -- the auditor starts by freezing.
--   6. sp_org_assurance_execution_get (120 body) + ScopeFrozenAt / By,
--      ScopeExclusionCount.
--   7. NEW sp_org_assurance_my_audits_prepare(@employee_id): starts the
--      due engagements of that auditor (From <= today, plan Approved /
--      Active, audits not started); one engagement failing does not stop
--      the others.
--   8. NEW sp_org_assurance_my_audit_list(@employee_id): one row per audit
--      of the auditor's engagements with its execution and state
--      (Upcoming / Ready / ScopeLive / InProgress / Completed / Cancelled).
--   9. NEW sp_org_assurance_execution_live_scope: the live scope (resolved
--      in a rolled-back transaction, branch-narrowed); nothing saved.
--  10. NEW sp_org_assurance_execution_freeze_scope (auditor only).
--  11. NEW sp_org_assurance_execution_scope_exclusion_list.
--
-- ERRORS: 54030 live scope -- freeze first; 54031 scope already frozen;
--   54032 only the assigned auditor can freeze; 54033 freeze only while
--   Planned; 54034 an exclusion is not in the scope or has no reason;
--   54035 nothing left in scope; 54036 employee required.
-- DEPENDS ON: 545, 552, 554.
-- Rollback: 555_my_audits_freeze_scope_rollback.sql.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_scope_resolution_narrow_location','P') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_engagement_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_assurance_execution_materialize','P') IS NULL
BEGIN
    PRINT 'ABORT (555): run 545, 552 and 554 first. Nothing was changed.';
    RAISERROR('555_my_audits_freeze_scope: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Schema
-- =====================================================================
IF COL_LENGTH('grac_practice.org_assurance_execution','scope_frozen_at') IS NULL
BEGIN
    ALTER TABLE grac_practice.org_assurance_execution ADD
        scope_frozen_at DATETIME2     NULL,
        scope_frozen_by NVARCHAR(100) NULL;
    PRINT '555.1: scope_frozen_at / scope_frozen_by added.';
    -- Every execution that exists already was snapshotted at creation.
    -- Only here, when the columns are new: on a re-run, a NULL is a live
    -- scope and must stay NULL. (Dynamic: the columns are new in this batch.)
    EXEC sp_executesql N'
        UPDATE grac_practice.org_assurance_execution
           SET scope_frozen_at = ISNULL(entered_dt, SYSUTCDATETIME()),
               scope_frozen_by = N''migration-555''
         WHERE scope_frozen_at IS NULL;
        PRINT ''555.1: existing executions marked frozen = '' + CAST(@@ROWCOUNT AS NVARCHAR(20));';
END
GO

IF OBJECT_ID('grac_practice.org_assurance_execution_scope_exclusion','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_execution_scope_exclusion(
        org_assurance_execution_scope_exclusion_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_oa_exec_scope_excl PRIMARY KEY,
        organization_id            BIGINT        NOT NULL,
        org_assurance_execution_id BIGINT        NOT NULL,
        dimension_code             NVARCHAR(60)  NOT NULL,
        dimension_name             NVARCHAR(160) NULL,
        entity_id                  BIGINT        NOT NULL,
        entity_code                NVARCHAR(120) NULL,
        entity_name                NVARCHAR(240) NULL,
        reason                     NVARCHAR(1000) NOT NULL,
        entered_by                 NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_oa_exec_scope_excl_ent_by DEFAULT 'system',
        entered_dt                 DATETIME2     NOT NULL
            CONSTRAINT df_pm_oa_exec_scope_excl_ent_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT fk_pm_oa_exec_scope_excl_exec
            FOREIGN KEY(org_assurance_execution_id)
            REFERENCES grac_practice.org_assurance_execution(org_assurance_execution_id),
        CONSTRAINT fk_pm_oa_exec_scope_excl_org
            FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT uq_pm_oa_exec_scope_excl
            UNIQUE(org_assurance_execution_id, dimension_code, entity_id)
    );
    PRINT '555.1: org_assurance_execution_scope_exclusion created.';
END
GO

-- =====================================================================
-- 2. Menu: Audit Assurance -> My Audits (also in 274's snapshot)
-- =====================================================================
DECLARE @assurance_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'org-my-audits', N'My Audits', N'Practice/org-my-audits', 468, N'user-check')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @assurance_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Audit Assurance',
    status = N'Active', updated_by = 'seed-555', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @assurance_id, src.display_order,
     src.icon_class, N'Audit Assurance', N'Active', 'seed-555');
PRINT '555.2: org-my-audits menu row upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- Every active role (the list shows only the caller's own audits), as 530.
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 0,
       N'Active', @active_rs, N'seed-555', SYSUTCDATETIME()
FROM   grac_practice.organization_role r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_practice.menu_master m ON m.menu_key = N'org-my-audits'
WHERE  o.status = N'Active' AND r.status = N'Active'
  AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission p
        WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);
PRINT '555.2: org-my-audits permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 3. Materialize (545 body + 555 @live)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_materialize
    @organization_id     BIGINT,
    @definition_id       BIGINT,
    @version_id          BIGINT       = NULL,
    @scope_resolution_id BIGINT        = NULL,   -- 545: NULL = resolve the scope now
    @execution_code      NVARCHAR(120) = NULL,
    @execution_name      NVARCHAR(300) = NULL,
    @origin_type         NVARCHAR(20)  = N'MANUAL',
    @plan_id             BIGINT        = NULL,
    @plan_item_id        BIGINT        = NULL,
    @trigger_config_id   BIGINT        = NULL,
    @planned_start_dt    DATE          = NULL,
    @planned_end_dt      DATE          = NULL,
    @owner_role_id       BIGINT        = NULL,   -- 120
    @owner_role_name     NVARCHAR(120) = NULL,   -- 120
    @owner_employee_id   BIGINT        = NULL,
    @owner_display_name  NVARCHAR(240) = NULL,
    @assigned_team_name  NVARCHAR(200) = NULL,
    @notes               NVARCHAR(MAX) = NULL,
    @actor               NVARCHAR(100) = 'system',
    @live                BIT           = 0,      -- 555: 1 = scope live until the auditor freezes it
    @execution_id_out    BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL      THROW 54008, 'organization_id is required.',      1;
    IF @definition_id   IS NULL      THROW 54011, 'definition_id is required.',        1;
    IF @origin_type NOT IN (N'MANUAL', N'PLAN', N'TRIGGER')
        THROW 54013, 'origin_type must be MANUAL / PLAN / TRIGGER.',                    1;

    -- ==========================================================
    -- 120 hybrid ownership resolver -- Owner (single field)
    -- ==========================================================
    IF @owner_role_id IS NOT NULL
       AND (@owner_role_name IS NULL OR LEN(LTRIM(RTRIM(@owner_role_name))) = 0)
        SELECT @owner_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @owner_role_id AND organization_id = @organization_id;

    IF @owner_role_id IS NOT NULL AND @owner_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id   = @organization_id,
             @role_id           = @owner_role_id,
             @employee_id_out   = @owner_employee_id  OUTPUT,
             @employee_name_out = @owner_display_name OUTPUT;

    IF @owner_employee_id IS NOT NULL AND @owner_role_id IS NULL
    BEGIN
        SELECT @owner_role_id   = e.role_id,
               @owner_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @owner_employee_id
          AND e.organization_id = @organization_id;
    END

    IF @owner_employee_id IS NOT NULL
       AND (@owner_display_name IS NULL OR LEN(LTRIM(RTRIM(@owner_display_name))) = 0)
        SELECT @owner_display_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @owner_employee_id;

    -- ---------------------------------------------------------------
    -- Definition + version
    -- ---------------------------------------------------------------
    DECLARE @def_org BIGINT, @def_code NVARCHAR(80), @def_name NVARCHAR(240),
            @def_current_version_id BIGINT;
    SELECT @def_org               = d.organization_id,
           @def_code              = d.definition_code,
           @def_name              = d.definition_name,
           @def_current_version_id = d.current_version_id
    FROM grac_practice.org_assurance_definition d
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL           THROW 54014, 'Assurance definition not found.',      1;
    IF @def_org <> @organization_id
        THROW 54015, 'Definition belongs to a different organization.',                1;

    IF @version_id IS NULL SET @version_id = @def_current_version_id;
    IF @version_id IS NULL
        THROW 54016, 'Definition has no version to materialize.',                       1;

    DECLARE @version_number INT, @version_status NVARCHAR(60);
    SELECT @version_number = v.version_number,
           @version_status = s.status_code
    FROM grac_practice.org_assurance_definition_version v
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = v.status_id
    WHERE v.org_assurance_definition_version_id = @version_id
      AND v.org_assurance_definition_id         = @definition_id
      AND v.is_active = 1;

    IF @version_number IS NULL
        THROW 54017, 'Version not found for this definition.',                          1;
    IF @version_status NOT IN (N'Approved', N'Active')
    BEGIN
        DECLARE @vs NVARCHAR(60) = ISNULL(@version_status, N'(unknown)');
        DECLARE @vs_msg NVARCHAR(400) =
            N'Only Approved or Active versions can be materialized. '
          + N'Current version status is "' + @vs + N'". '
          + N'Submit for Review, then Approve the version, then retry.';
        THROW 54018, @vs_msg, 1;
    END

    -- ---------------------------------------------------------------
    -- Scope resolution
    -- ---------------------------------------------------------------
    -- 545: a snapshot passed in is checked as before; with none, the scope
    -- is resolved below, inside this procedure's transaction, so the
    -- execution covers what the scope matches at the moment it is created.
    DECLARE @scope_res_org BIGINT, @scope_res_def BIGINT, @scope_res_ver BIGINT,
            @scope_res_total BIGINT, @resolved_here BIT = 0;
    IF @scope_resolution_id IS NOT NULL
    BEGIN
    SELECT @scope_res_org   = r.organization_id,
           @scope_res_def   = r.org_assurance_definition_id,
           @scope_res_ver   = r.org_assurance_definition_version_id,
           @scope_res_total = r.total_entity_count
    FROM grac_practice.org_assurance_scope_resolution r
    WHERE r.org_assurance_scope_resolution_id = @scope_resolution_id
      AND r.is_active = 1;

    IF @scope_res_org IS NULL
        THROW 54019, 'Scope resolution snapshot not found.',                            1;
    IF @scope_res_org <> @organization_id
        THROW 54020, 'Scope resolution belongs to a different organization.',           1;
    IF @scope_res_def <> @definition_id OR @scope_res_ver <> @version_id
        THROW 54021, 'Scope resolution does not belong to this definition version.',    1;
    END

    -- ---------------------------------------------------------------
    -- Origin sanity
    -- ---------------------------------------------------------------
    IF @origin_type = N'PLAN' AND (@plan_id IS NULL OR @plan_item_id IS NULL)
        THROW 54022, 'PLAN origin requires plan_id and plan_item_id.',                   1;
    IF @origin_type = N'TRIGGER' AND @trigger_config_id IS NULL
        THROW 54023, 'TRIGGER origin requires trigger_config_id.',                       1;

    -- ---------------------------------------------------------------
    -- Auto execution_code / execution_name
    -- ---------------------------------------------------------------
    IF @execution_code IS NULL OR LEN(LTRIM(RTRIM(@execution_code))) = 0
    BEGIN
        DECLARE @yyyymm NVARCHAR(6) = FORMAT(SYSUTCDATETIME(), 'yyyyMM');
        DECLARE @seq INT = (
            SELECT COUNT(1) + 1
            FROM grac_practice.org_assurance_execution
            WHERE organization_id = @organization_id
              AND org_assurance_definition_id = @definition_id
              AND FORMAT(entered_dt, 'yyyyMM') = @yyyymm);
        SET @execution_code = @def_code + N'-' + @yyyymm + N'-'
                            + RIGHT(N'000' + CAST(@seq AS NVARCHAR(4)), 4);
    END
    IF @execution_name IS NULL OR LEN(LTRIM(RTRIM(@execution_name))) = 0
        SET @execution_name = @def_name + N' (' + @execution_code + N')';

    -- Uniqueness on execution_code per org
    IF EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_execution
        WHERE organization_id = @organization_id
          AND execution_code  = @execution_code
          AND is_active       = 1)
        THROW 54024, 'execution_code already exists for this organization.',             1;

    -- ---------------------------------------------------------------
    -- Snapshot JSON payloads (definition/questions/evidence/workflow/scoring)
    -- Reuses the exact JSON shape from 099. Content of these blocks is
    -- copied wholesale from 099; the 120 diff is only the resolver above
    -- + the INSERT columns below.
    -- ---------------------------------------------------------------
    DECLARE @definition_json NVARCHAR(MAX) = (
        SELECT d.org_assurance_definition_id     AS DefinitionId,
               d.definition_code                  AS DefinitionCode,
               d.definition_name                  AS DefinitionName,
               v.org_assurance_definition_version_id AS VersionId,
               v.version_number                   AS VersionNumber,
               v.version_label                    AS VersionLabel,
               v.description                      AS Description,
               v.objective                        AS Objective,
               v.effective_date                   AS EffectiveDate,
               v.assurance_category_id            AS AssuranceCategoryId,
               v.assurance_category_code          AS AssuranceCategoryCode,
               v.assurance_category_name          AS AssuranceCategoryName
        FROM grac_practice.org_assurance_definition d
        JOIN grac_practice.org_assurance_definition_version v
             ON v.org_assurance_definition_version_id = @version_id
        WHERE d.org_assurance_definition_id = @definition_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- 536: the questions of the question sets adopted by this version
    -- (277), in the order the audit asks them -- set order, then question
    -- order. Only questions still in the set (is_active) with Status
    -- Active. Closes the 099 gap ("question sets do not link to a
    -- definition_version") that 277 made closable.
    DECLARE @questions_json NVARCHAR(MAX) = ISNULL(
        (SELECT dq.display_order                   AS SetOrder,
                qs.org_assurance_question_set_id   AS QuestionSetId,
                qs.set_code                        AS QuestionSetCode,
                qs.set_name                        AS QuestionSetName,
                dq.is_mandatory                    AS QuestionSetIsMandatory,
                q.org_assurance_question_id        AS QuestionId,
                q.question_code                    AS QuestionCode,
                q.question_text                    AS QuestionText,
                q.help_text                        AS HelpText,
                q.question_type_id                 AS QuestionTypeId,
                q.question_type_code               AS QuestionTypeCode,
                q.question_type_name               AS QuestionTypeName,
                q.is_mandatory                     AS IsMandatory,
                q.weight                           AS Weight,
                q.evidence_type_id                 AS EvidenceTypeId,
                q.evidence_type_code               AS EvidenceTypeCode,
                q.evidence_type_name               AS EvidenceTypeName,
                q.expected_evidence                AS ExpectedEvidence,
                q.version_number                   AS QuestionVersion,
                q.display_order                    AS DisplayOrder
         FROM grac_practice.org_assurance_definition_question_set dq
         JOIN grac_practice.org_assurance_question_set qs
              ON qs.org_assurance_question_set_id = dq.org_assurance_question_set_id
         JOIN grac_practice.org_assurance_question q
              ON q.org_assurance_question_set_id = qs.org_assurance_question_set_id
             AND q.is_active = 1
             AND ISNULL(q.status, N'Active') = N'Active'
         WHERE dq.org_assurance_definition_version_id = @version_id
           AND dq.organization_id = @organization_id
           AND dq.is_active = 1
         ORDER BY dq.display_order, qs.set_name, q.display_order, q.org_assurance_question_id
         FOR JSON PATH),
        N'[]');

    -- 536: Evidence Config (079 / 082 / 118) is retired; the evidence an
    -- execution expects is what its questions ask for -- one row per
    -- question that names an Evidence Type, from the same rows as
    -- @questions_json. (The org_assurance_evidence_config tables are kept,
    -- unread, so older executions' snapshots stay as they were.)
    DECLARE @evidence_json NVARCHAR(MAX) = ISNULL(
        (SELECT dq.display_order                   AS SetOrder,
                qs.org_assurance_question_set_id   AS QuestionSetId,
                qs.set_code                        AS QuestionSetCode,
                q.org_assurance_question_id        AS QuestionId,
                q.question_code                    AS QuestionCode,
                q.evidence_type_id                 AS EvidenceTypeId,
                q.evidence_type_code               AS EvidenceTypeCode,
                q.evidence_type_name               AS EvidenceTypeName,
                q.expected_evidence                AS ExpectedEvidence,
                q.is_mandatory                     AS IsMandatory,
                q.display_order                    AS DisplayOrder
         FROM grac_practice.org_assurance_definition_question_set dq
         JOIN grac_practice.org_assurance_question_set qs
              ON qs.org_assurance_question_set_id = dq.org_assurance_question_set_id
         JOIN grac_practice.org_assurance_question q
              ON q.org_assurance_question_set_id = qs.org_assurance_question_set_id
             AND q.is_active = 1
             AND ISNULL(q.status, N'Active') = N'Active'
             AND q.evidence_type_id IS NOT NULL
         WHERE dq.org_assurance_definition_version_id = @version_id
           AND dq.organization_id = @organization_id
           AND dq.is_active = 1
         ORDER BY dq.display_order, qs.set_name, q.display_order, q.org_assurance_question_id
         FOR JSON PATH),
        N'[]');

    -- 555: the workflow and scoring snapshots read the real 083 / 086
    -- tables. Since 120 they named org_assurance_workflow_config_stage and
    -- org_assurance_scoring_config_band, which never existed (and columns
    -- that are not on these tables), so every materialize failed with 208.
    DECLARE @workflow_json NVARCHAR(MAX) = ISNULL(
        (SELECT wc.org_assurance_workflow_config_id AS WorkflowConfigId,
                wc.workflow_name                     AS WorkflowName,
                wc.workflow_template_code            AS TemplateCode,
                wc.workflow_template_name            AS TemplateName,
                wc.description                       AS Description,
                wc.total_sla_days                    AS TotalSlaDays,
                ws.stage_order                       AS StageOrder,
                ws.stage_code                        AS StageCode,
                ws.stage_name                        AS StageName,
                ws.stage_type                        AS StageType,
                ws.assigned_role_id                  AS RoleId,
                ws.assigned_role_name                AS RoleName,
                ws.assigned_employee_id              AS EmployeeId,
                ws.assigned_employee_name            AS EmployeeName,
                ws.sla_days                          AS SlaDays,
                ws.escalation_role_id                AS EscalationRoleId,
                ws.escalation_role_name              AS EscalationRoleName,
                ws.escalation_after_days             AS EscalationAfterDays,
                ws.instructions                      AS Instructions
         FROM grac_practice.org_assurance_workflow_config wc
         LEFT JOIN grac_practice.org_assurance_workflow_stage ws
                ON ws.org_assurance_workflow_config_id = wc.org_assurance_workflow_config_id
               AND ws.is_active = 1
         WHERE wc.org_assurance_definition_version_id = @version_id
           AND wc.is_active = 1
         ORDER BY ws.stage_order
         FOR JSON PATH),
        N'[]');

    DECLARE @scoring_json NVARCHAR(MAX) = ISNULL(
        (SELECT sc.org_assurance_scoring_config_id AS ScoringConfigId,
                sc.scoring_model_id                  AS ScoringModelId,
                sc.scoring_model_code                AS ScoringModelCode,
                sc.scoring_model_name                AS ScoringModelName,
                sc.scoring_model_type                AS ScoringModelType,
                sc.max_score                         AS MaxScore,
                sc.pass_threshold                    AS PassThreshold,
                sc.warning_threshold                 AS WarningThreshold,
                sc.fail_threshold                    AS FailThreshold,
                sc.description                       AS Description,
                sb.band_order                        AS BandOrder,
                sb.band_code                         AS BandCode,
                sb.band_name                         AS BandName,
                sb.min_score                         AS BandMinScore,
                sb.max_score                         AS BandMaxScore,
                sb.outcome_code                      AS BandOutcomeCode,
                sb.color_hex                         AS BandColorHex
         FROM grac_practice.org_assurance_scoring_config sc
         LEFT JOIN grac_practice.org_assurance_scoring_band sb
                ON sb.org_assurance_scoring_config_id = sc.org_assurance_scoring_config_id
               AND sb.is_active = 1
         WHERE sc.org_assurance_definition_version_id = @version_id
           AND sc.is_active = 1
         ORDER BY sb.band_order
         FOR JSON PATH),
        N'[]');

    DECLARE @planned_status_id INT = (
        SELECT TOP 1 org_assurance_execution_status_id
        FROM grac_practice.org_assurance_execution_status_master
        WHERE status_code = N'Planned'
        ORDER BY org_assurance_execution_status_id);
    IF @planned_status_id IS NULL
        THROW 54025, 'Planned status not seeded in org_assurance_execution_status_master.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    -- ---------------------------------------------------------------
    -- Persist
    -- ---------------------------------------------------------------
    BEGIN TRAN;

    -- 545: no snapshot given -- resolve the version's scope now, for this
    -- execution (purpose EXECUTION). The resolver opens its own nested
    -- transaction and never rolls back on its own, so a failure here or
    -- below undoes both.
    IF @scope_resolution_id IS NULL
    BEGIN
        EXEC grac_practice.sp_org_assurance_scope_resolve
             @organization_id    = @organization_id,
             @definition_id      = @definition_id,
             @version_id         = @version_id,
             @resolution_purpose = N'EXECUTION',
             @execution_id       = NULL,
             @actor              = @actor,
             @resolution_id_out  = @scope_resolution_id OUTPUT;
        SET @resolved_here = 1;
        SELECT @scope_res_total = r.total_entity_count
          FROM grac_practice.org_assurance_scope_resolution r
         WHERE r.org_assurance_scope_resolution_id = @scope_resolution_id;
    END

    INSERT INTO grac_practice.org_assurance_execution(
        organization_id,
        org_assurance_definition_id, org_assurance_definition_version_id,
        definition_code, definition_name, version_number,
        execution_code, execution_name, execution_status_id,
        origin_type, org_assurance_plan_id, org_assurance_plan_item_id,
        org_assurance_trigger_config_id,
        org_assurance_scope_resolution_id,
        definition_snapshot_json, questions_snapshot_json,
        evidence_snapshot_json, workflow_snapshot_json, scoring_snapshot_json,
        owner_role_id, owner_role_name,           -- 120
        owner_employee_id, owner_display_name, assigned_team_name,
        planned_start_dt, planned_end_dt,
        total_entity_count, completed_entity_count,
        notes,
        is_active, record_status_id, entered_by, entered_dt)
    VALUES (
        @organization_id,
        @definition_id, @version_id,
        @def_code, @def_name, @version_number,
        @execution_code, @execution_name, @planned_status_id,
        @origin_type, @plan_id, @plan_item_id,
        @trigger_config_id,
        @scope_resolution_id,
        @definition_json, @questions_json,
        @evidence_json, @workflow_json, @scoring_json,
        @owner_role_id, @owner_role_name,          -- 120
        @owner_employee_id, @owner_display_name, @assigned_team_name,
        @planned_start_dt, @planned_end_dt,
        ISNULL(@scope_res_total, 0), 0,
        @notes,
        1, @active_record_status_id, @actor, SYSUTCDATETIME());

    SET @execution_id_out = SCOPE_IDENTITY();

    -- 555: frozen now (manual / trigger: the scope is fixed at creation),
    -- or left live for the auditor to freeze (plan engagements).
    UPDATE grac_practice.org_assurance_execution
       SET scope_frozen_at = CASE WHEN ISNULL(@live, 0) = 1 THEN NULL ELSE SYSUTCDATETIME() END,
           scope_frozen_by = CASE WHEN ISNULL(@live, 0) = 1 THEN NULL ELSE @actor END
     WHERE org_assurance_execution_id = @execution_id_out;

    -- 545: the snapshot made for this execution points back at it.
    IF @resolved_here = 1
        UPDATE grac_practice.org_assurance_scope_resolution
           SET execution_id = @execution_id_out
         WHERE org_assurance_scope_resolution_id = @scope_resolution_id;

    -- Snapshot entities from the scope resolution (auditor left NULL --
    -- assigned per-entity later via sp_org_assurance_execution_entity_auditor_assign).
    -- 555: not for a live scope -- Freeze Scope copies them.
    IF ISNULL(@live, 0) = 0
    INSERT INTO grac_practice.org_assurance_execution_entity(
        org_assurance_execution_id, organization_id,
        dimension_code, dimension_name,
        entity_id, entity_code, entity_name,
        source_group_order, source_condition_order,
        entity_status_code, is_active, entered_by, entered_dt)
    SELECT @execution_id_out, @organization_id,
           r.dimension_code, r.dimension_name,
           r.entity_id, r.entity_code, r.entity_name,
           r.source_group_order, r.source_condition_order,
           N'NotStarted', 1, @actor, SYSUTCDATETIME()
    FROM grac_practice.org_assurance_scope_resolution_entity r
    WHERE r.org_assurance_scope_resolution_id = @scope_resolution_id
      AND r.organization_id = @organization_id;

    DECLARE @actual_total BIGINT = (
        SELECT COUNT_BIG(1)
        FROM grac_practice.org_assurance_execution_entity
        WHERE org_assurance_execution_id = @execution_id_out
          AND is_active = 1);

    UPDATE grac_practice.org_assurance_execution
    SET total_entity_count = @actual_total,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_execution_id = @execution_id_out;

    IF OBJECT_ID('grac_practice.org_assurance_definition_history','U') IS NOT NULL
    BEGIN
        DECLARE @history_note NVARCHAR(1000) =
            N'Materialized execution #' + CAST(@execution_id_out AS NVARCHAR(20))
          + N' from resolution #' + CAST(@scope_resolution_id AS NVARCHAR(20));

        INSERT INTO grac_practice.org_assurance_definition_history
            (org_assurance_definition_id, org_assurance_definition_version_id,
             organization_id, action_code, from_status_id, to_status_id,
             actor_display_name, reason_text, entered_by)
        SELECT @definition_id, @version_id, @organization_id,
               N'EXECUTE', d.current_status_id, d.current_status_id,
               @actor, @history_note, @actor
        FROM grac_practice.org_assurance_definition d
        WHERE d.org_assurance_definition_id = @definition_id;
    END

    COMMIT;
END
GO

-- =====================================================================
-- 4. Engagement Start Execution (554 body + 555: live, @suppress_result)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_start_execution
    @organization_id  BIGINT,
    @plan_id          BIGINT,
    @plan_item_id     BIGINT,
    @actor            NVARCHAR(100) = 'system',
    @suppress_result  BIT           = 0,      -- 555: My Audits prepare calls it
    @execution_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @plan_id IS NULL OR @plan_item_id IS NULL
        THROW 53902, 'organization_id, plan_id and plan_item_id are required.', 1;

    DECLARE @item_plan BIGINT,
            @from DATE, @to DATE,
            @aud_role_id BIGINT, @aud_role_name NVARCHAR(120),
            @aud_emp_id BIGINT, @aud_name NVARCHAR(240),
            @team NVARCHAR(200),
            @branch_id BIGINT, @branch_name NVARCHAR(200);   -- 554
    SELECT @item_plan     = i.org_assurance_plan_id,
           @from          = i.scheduled_from,
           @to            = i.scheduled_to,
           @aud_role_id   = i.assigned_auditor_role_id,
           @aud_role_name = i.assigned_auditor_role_name,
           @aud_emp_id    = i.assigned_auditor_employee_id,
           @aud_name      = i.assigned_auditor_name,
           @team          = i.assigned_team_name,
           @branch_id     = i.assigned_branch_id,     -- 554
           @branch_name   = i.assigned_branch_name
      FROM grac_practice.org_assurance_plan_item i
     WHERE i.org_assurance_plan_item_id = @plan_item_id
       AND i.organization_id = @organization_id
       AND i.is_active = 1;

    IF @item_plan IS NULL      THROW 53915, 'Plan item not found.', 1;
    IF @item_plan <> @plan_id  THROW 53916, 'Plan item does not belong to the specified plan.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan p
          JOIN grac_practice.org_assurance_plan_status_master s
               ON s.org_assurance_plan_status_id = p.status_id
         WHERE p.org_assurance_plan_id = @plan_id
           AND p.organization_id = @organization_id
           AND p.is_active = 1
           AND s.status_code IN (N'Approved', N'Active'))
        THROW 53935, 'An execution can be started only from an Approved or Active plan.', 1;

    -- The audits to start: active on the engagement, an Active version,
    -- not Retired, and no live execution on this engagement.
    DECLARE @todo TABLE (rn INT IDENTITY(1,1) PRIMARY KEY, definition_id BIGINT NOT NULL, version_id BIGINT NOT NULL);
    INSERT INTO @todo (definition_id, version_id)
    SELECT ed.org_assurance_definition_id, d.active_version_id
      FROM grac_practice.org_assurance_engagement_definition ed
      JOIN grac_practice.org_assurance_definition d
           ON d.org_assurance_definition_id = ed.org_assurance_definition_id
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
     WHERE ed.org_assurance_plan_item_id = @plan_item_id
       AND ed.is_active = 1
       AND d.active_version_id IS NOT NULL
       AND s.status_code <> N'Retired'
       AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                         JOIN grac_practice.org_assurance_execution_status_master es
                              ON es.org_assurance_execution_status_id = e.execution_status_id
                        WHERE e.org_assurance_plan_item_id = @plan_item_id
                          AND e.org_assurance_definition_id = ed.org_assurance_definition_id
                          AND e.is_active = 1 AND es.status_code <> N'Cancelled')
     ORDER BY ed.display_order, ed.org_assurance_engagement_definition_id;

    IF NOT EXISTS (SELECT 1 FROM @todo)
        THROW 53936, 'Every audit of this engagement has already been started, or none can be executed (no Active version).', 1;

    DECLARE @started TABLE (execution_id BIGINT NOT NULL);
    DECLARE @n INT = 1, @max INT = (SELECT MAX(rn) FROM @todo),
            @def BIGINT, @ver BIGINT, @eid BIGINT,
            @res BIGINT, @def_code NVARCHAR(80), @msg NVARCHAR(400);   -- 554

    BEGIN TRAN;
    WHILE @n <= @max
    BEGIN
        SELECT @def = definition_id, @ver = version_id FROM @todo WHERE rn = @n;
        SET @eid = NULL;
        SET @res = NULL;
        -- 555: the scope stays LIVE -- the auditor reviews it (narrowed to
        -- the engagement's Branch, 554) and freezes it in My Audits.
        EXEC grac_practice.sp_org_assurance_execution_materialize
             @organization_id     = @organization_id,
             @definition_id       = @def,
             @version_id          = @ver,
             @scope_resolution_id = NULL,
             @execution_code      = NULL,
             @execution_name      = NULL,
             @origin_type         = N'PLAN',
             @plan_id             = @plan_id,
             @plan_item_id        = @plan_item_id,
             @trigger_config_id   = NULL,
             @planned_start_dt    = @from,
             @planned_end_dt      = @to,
             @owner_role_id       = @aud_role_id,
             @owner_role_name     = @aud_role_name,
             @owner_employee_id   = @aud_emp_id,
             @owner_display_name  = @aud_name,
             @assigned_team_name  = @team,
             @notes               = NULL,
             @actor               = @actor,
             @live                = 1,                -- 555
             @execution_id_out    = @eid OUTPUT;
        INSERT INTO @started (execution_id) VALUES (@eid);
        IF @execution_id_out IS NULL SET @execution_id_out = @eid;
        SET @n += 1;
    END
    COMMIT;

    IF ISNULL(@suppress_result, 0) = 1 RETURN;   -- 555

    SELECT e.org_assurance_execution_id AS ExecutionId,
           e.execution_code             AS ExecutionCode,
           e.execution_name             AS ExecutionName,
           e.definition_code            AS DefinitionCode,
           e.total_entity_count         AS TotalEntityCount
      FROM grac_practice.org_assurance_execution e
      JOIN @started s ON s.execution_id = e.org_assurance_execution_id
     ORDER BY e.org_assurance_execution_id;
END
GO

-- =====================================================================
-- 5. Execution Start needs a frozen scope (099 body + 555)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_start
    @organization_id BIGINT, @execution_id BIGINT, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    -- 555: an execution with a live scope starts by Freeze Scope (My Audits).
    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution
                WHERE org_assurance_execution_id = @execution_id
                  AND organization_id = @organization_id
                  AND scope_frozen_at IS NULL)
        THROW 54030, 'The scope of this execution is live. The auditor starts it by freezing the scope in My Audits.', 1;
    EXEC grac_practice.sp_org_assurance_execution_transition
        @organization_id = @organization_id, @execution_id = @execution_id,
        @expected_from_codes = N'Planned',
        @to_code = N'InProgress',
        @stamp_start = 1, @stamp_end = 0, @actor = @actor;
END
GO

-- =====================================================================
-- 6. Execution get + scope state (120 body + 555)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_get
    @organization_id BIGINT,
    @execution_id    BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;

    SELECT e.org_assurance_execution_id           AS ExecutionId,
           e.organization_id                       AS OrganizationId,
           e.org_assurance_definition_id           AS DefinitionId,
           e.org_assurance_definition_version_id   AS DefinitionVersionId,
           e.definition_code                       AS DefinitionCode,
           e.definition_name                       AS DefinitionName,
           e.version_number                        AS VersionNumber,
           e.execution_code                        AS ExecutionCode,
           e.execution_name                        AS ExecutionName,
           s.status_code                           AS StatusCode,
           s.status_name                           AS StatusName,
           s.is_terminal                           AS StatusIsTerminal,
           e.origin_type                           AS OriginType,
           e.org_assurance_plan_id                 AS PlanId,
           e.org_assurance_plan_item_id            AS PlanItemId,
           e.org_assurance_trigger_config_id       AS TriggerConfigId,
           e.org_assurance_scope_resolution_id     AS ScopeResolutionId,
           e.definition_snapshot_json              AS DefinitionSnapshotJson,
           e.questions_snapshot_json               AS QuestionsSnapshotJson,
           e.evidence_snapshot_json                AS EvidenceSnapshotJson,
           e.workflow_snapshot_json                AS WorkflowSnapshotJson,
           e.scoring_snapshot_json                 AS ScoringSnapshotJson,
           e.owner_role_id                         AS OwnerRoleId,        -- 120
           e.owner_role_name                       AS OwnerRoleName,      -- 120
           e.owner_employee_id                     AS OwnerEmployeeId,
           e.owner_display_name                    AS OwnerDisplayName,
           e.assigned_team_name                    AS AssignedTeamName,
           e.planned_start_dt                      AS PlannedStartDt,
           e.planned_end_dt                        AS PlannedEndDt,
           e.actual_start_dt                       AS ActualStartDt,
           e.actual_end_dt                         AS ActualEndDt,
           e.total_entity_count                    AS TotalEntityCount,
           e.completed_entity_count                AS CompletedEntityCount,
           e.notes                                 AS Notes,
           e.scope_frozen_at                       AS ScopeFrozenAt,      -- 555
           e.scope_frozen_by                       AS ScopeFrozenBy,      -- 555
           (SELECT COUNT(*) FROM grac_practice.org_assurance_execution_scope_exclusion x
             WHERE x.org_assurance_execution_id = e.org_assurance_execution_id) AS ScopeExclusionCount,
           e.entered_by                            AS EnteredBy,
           e.entered_dt                            AS EnteredDt,
           e.updated_by                            AS UpdatedBy,
           e.updated_dt                            AS UpdatedDt
    FROM grac_practice.org_assurance_execution e
    JOIN grac_practice.org_assurance_execution_status_master s
         ON s.org_assurance_execution_status_id = e.execution_status_id
    WHERE e.organization_id = @organization_id
      AND e.org_assurance_execution_id = @execution_id
      AND e.is_active = 1;
END
GO

-- =====================================================================
-- 7. sp_org_assurance_my_audits_prepare -- start the auditor's due
--    engagements (From <= today). One engagement failing (e.g. an audit
--    lost its Active version) is reported and the others still start.
--    Result: one row per engagement tried.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_my_audits_prepare
    @employee_id BIGINT,
    @actor       NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @employee_id IS NULL
        THROW 54036, 'employee_id is required.', 1;

    DECLARE @today DATE = CAST(SYSDATETIME() AS DATE);
    DECLARE @due TABLE (rn INT IDENTITY(1,1) PRIMARY KEY, organization_id BIGINT NOT NULL,
                        plan_id BIGINT NOT NULL, plan_item_id BIGINT NOT NULL,
                        engagement_code NVARCHAR(80) NULL);
    INSERT INTO @due (organization_id, plan_id, plan_item_id, engagement_code)
    SELECT i.organization_id, i.org_assurance_plan_id, i.org_assurance_plan_item_id, i.engagement_code
      FROM grac_practice.org_assurance_plan_item i
      JOIN grac_practice.org_assurance_plan p
           ON p.org_assurance_plan_id = i.org_assurance_plan_id
      JOIN grac_practice.org_assurance_plan_status_master ps
           ON ps.org_assurance_plan_status_id = p.status_id
     WHERE i.assigned_auditor_employee_id = @employee_id
       AND i.is_active = 1
       AND p.is_active = 1
       AND ps.status_code IN (N'Approved', N'Active')
       AND i.scheduled_from IS NOT NULL
       AND i.scheduled_from <= @today
       -- an audit of the engagement that can start and has not (the
       -- start procedure's own rule)
       AND EXISTS (
            SELECT 1
              FROM grac_practice.org_assurance_engagement_definition ed
              JOIN grac_practice.org_assurance_definition d
                   ON d.org_assurance_definition_id = ed.org_assurance_definition_id
              JOIN grac_practice.org_assurance_status_master s
                   ON s.org_assurance_status_id = d.current_status_id
             WHERE ed.org_assurance_plan_item_id = i.org_assurance_plan_item_id
               AND ed.is_active = 1
               AND d.active_version_id IS NOT NULL
               AND s.status_code <> N'Retired'
               AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                                 JOIN grac_practice.org_assurance_execution_status_master es
                                      ON es.org_assurance_execution_status_id = e.execution_status_id
                                WHERE e.org_assurance_plan_item_id = i.org_assurance_plan_item_id
                                  AND e.org_assurance_definition_id = ed.org_assurance_definition_id
                                  AND e.is_active = 1 AND es.status_code <> N'Cancelled'))
     ORDER BY i.scheduled_from, i.org_assurance_plan_item_id;

    DECLARE @out TABLE (plan_item_id BIGINT, engagement_code NVARCHAR(80), started BIT, message NVARCHAR(2048));
    DECLARE @n INT = 1, @max INT = ISNULL((SELECT MAX(rn) FROM @due), 0),
            @org BIGINT, @plan BIGINT, @item BIGINT, @code NVARCHAR(80), @eid BIGINT;
    WHILE @n <= @max
    BEGIN
        SELECT @org = organization_id, @plan = plan_id, @item = plan_item_id, @code = engagement_code
          FROM @due WHERE rn = @n;
        BEGIN TRY
            SET @eid = NULL;
            EXEC grac_practice.sp_org_assurance_plan_item_start_execution
                 @organization_id  = @org,
                 @plan_id          = @plan,
                 @plan_item_id     = @item,
                 @actor            = @actor,
                 @suppress_result  = 1,
                 @execution_id_out = @eid OUTPUT;
            INSERT INTO @out VALUES (@item, @code, 1, NULL);
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            INSERT INTO @out VALUES (@item, @code, 0, ERROR_MESSAGE());
        END CATCH
        SET @n += 1;
    END

    SELECT plan_item_id AS PlanItemId, engagement_code AS EngagementCode,
           started AS Started, message AS Message
      FROM @out;
END
GO

-- =====================================================================
-- 8. sp_org_assurance_my_audit_list -- the auditor's audits: one row per
--    audit of each engagement assigned to them (plan Approved / Active /
--    Closed), with its latest execution and state.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_my_audit_list
    @employee_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @employee_id IS NULL
        THROW 54036, 'employee_id is required.', 1;

    DECLARE @today DATE = CAST(SYSDATETIME() AS DATE);

    SELECT i.organization_id               AS OrganizationId,
           o.organization_name             AS OrganizationName,
           p.org_assurance_plan_id         AS PlanId,
           p.plan_code                     AS PlanCode,
           p.plan_name                     AS PlanName,
           i.org_assurance_plan_item_id    AS PlanItemId,
           i.engagement_code               AS EngagementCode,
           i.engagement_name               AS EngagementName,
           i.assigned_branch_id            AS BranchId,
           i.assigned_branch_name          AS BranchName,
           i.scheduled_from                AS ScheduledFrom,
           i.scheduled_to                  AS ScheduledTo,
           d.org_assurance_definition_id   AS DefinitionId,
           d.definition_code               AS DefinitionCode,
           d.definition_name               AS DefinitionName,
           ex.org_assurance_execution_id   AS ExecutionId,
           ex.execution_code               AS ExecutionCode,
           ex.status_code                  AS ExecutionStatusCode,
           ex.status_name                  AS ExecutionStatusName,
           ex.scope_frozen_at              AS ScopeFrozenAt,
           ex.total_entity_count           AS TotalEntityCount,
           ex.completed_entity_count       AS CompletedEntityCount,
           CASE WHEN ex.org_assurance_execution_id IS NULL
                     THEN CASE WHEN i.scheduled_from > @today THEN N'Upcoming' ELSE N'Ready' END
                WHEN ex.status_code = N'Cancelled'    THEN N'Cancelled'
                WHEN ex.scope_frozen_at IS NULL       THEN N'ScopeLive'
                WHEN ex.status_code IN (N'Planned', N'InProgress') THEN N'InProgress'
                ELSE N'Done' END           AS AuditState
      FROM grac_practice.org_assurance_engagement_definition ed
      JOIN grac_practice.org_assurance_plan_item i
           ON i.org_assurance_plan_item_id = ed.org_assurance_plan_item_id
      JOIN grac_practice.org_assurance_plan p
           ON p.org_assurance_plan_id = i.org_assurance_plan_id
      JOIN grac_practice.org_assurance_plan_status_master ps
           ON ps.org_assurance_plan_status_id = p.status_id
      JOIN grac_practice.org_assurance_definition d
           ON d.org_assurance_definition_id = ed.org_assurance_definition_id
      JOIN grac_practice.organization o
           ON o.organization_id = i.organization_id
      OUTER APPLY (
          SELECT TOP 1 e.org_assurance_execution_id, e.execution_code, es.status_code, es.status_name,
                       e.scope_frozen_at, e.total_entity_count, e.completed_entity_count
            FROM grac_practice.org_assurance_execution e
            JOIN grac_practice.org_assurance_execution_status_master es
                 ON es.org_assurance_execution_status_id = e.execution_status_id
           WHERE e.org_assurance_plan_item_id = ed.org_assurance_plan_item_id
             AND e.org_assurance_definition_id = ed.org_assurance_definition_id
             AND e.is_active = 1
           ORDER BY CASE WHEN es.status_code = N'Cancelled' THEN 1 ELSE 0 END,
                    e.org_assurance_execution_id DESC) ex
     WHERE i.assigned_auditor_employee_id = @employee_id
       AND i.is_active  = 1
       AND ed.is_active = 1
       AND p.is_active  = 1
       AND ps.status_code IN (N'Approved', N'Active', N'Closed')
     ORDER BY i.scheduled_from, i.engagement_code, ed.display_order, ed.org_assurance_engagement_definition_id;
END
GO

-- =====================================================================
-- 9. sp_org_assurance_execution_live_scope -- what Freeze would take now:
--    the audit's scope resolved (PREVIEW, inside a transaction that is
--    rolled back -- nothing saved) and narrowed to the engagement's
--    Branch. A frozen execution returns its frozen entities.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_live_scope
    @organization_id BIGINT,
    @execution_id    BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;

    DECLARE @def BIGINT, @ver BIGINT, @item BIGINT, @frozen DATETIME2;
    SELECT @def    = e.org_assurance_definition_id,
           @ver    = e.org_assurance_definition_version_id,
           @item   = e.org_assurance_plan_item_id,
           @frozen = e.scope_frozen_at
      FROM grac_practice.org_assurance_execution e
     WHERE e.org_assurance_execution_id = @execution_id
       AND e.organization_id = @organization_id
       AND e.is_active = 1;
    IF @def IS NULL
        THROW 54010, 'Execution not found or not accessible in this organization.', 1;

    IF @frozen IS NOT NULL
    BEGIN
        SELECT ee.dimension_code AS DimensionCode, ee.dimension_name AS DimensionName,
               ee.entity_id AS EntityId, ee.entity_code AS EntityCode, ee.entity_name AS EntityName
          FROM grac_practice.org_assurance_execution_entity ee
         WHERE ee.org_assurance_execution_id = @execution_id
           AND ee.organization_id = @organization_id
           AND ee.is_active = 1
         ORDER BY ee.dimension_code, ee.entity_name, ee.entity_code;
        RETURN;
    END

    DECLARE @branch BIGINT = (SELECT assigned_branch_id FROM grac_practice.org_assurance_plan_item
                               WHERE org_assurance_plan_item_id = @item);
    DECLARE @ents TABLE (dimension_code NVARCHAR(60) NULL, dimension_name NVARCHAR(160) NULL,
                         entity_id BIGINT NULL, entity_code NVARCHAR(120) NULL, entity_name NVARCHAR(240) NULL);
    DECLARE @res BIGINT;

    BEGIN TRAN;
    EXEC grac_practice.sp_org_assurance_scope_resolve
         @organization_id    = @organization_id,
         @definition_id      = @def,
         @version_id         = @ver,
         @resolution_purpose = N'PREVIEW',
         @execution_id       = NULL,
         @actor              = @actor,
         @resolution_id_out  = @res OUTPUT;
    IF @branch IS NOT NULL
        EXEC grac_practice.sp_org_assurance_scope_resolution_narrow_location
             @organization_id = @organization_id,
             @resolution_id   = @res,
             @location_id     = @branch;
    INSERT INTO @ents (dimension_code, dimension_name, entity_id, entity_code, entity_name)
    SELECT DISTINCT r.dimension_code, r.dimension_name, r.entity_id, r.entity_code, r.entity_name
      FROM grac_practice.org_assurance_scope_resolution_entity r
     WHERE r.org_assurance_scope_resolution_id = @res;
    ROLLBACK;   -- live: nothing the resolver wrote is kept

    SELECT dimension_code AS DimensionCode, dimension_name AS DimensionName,
           entity_id AS EntityId, entity_code AS EntityCode, entity_name AS EntityName
      FROM @ents
     ORDER BY dimension_code, entity_name, entity_code;
END
GO

-- =====================================================================
-- 10. sp_org_assurance_execution_freeze_scope -- the assigned auditor
--     freezes the live scope: resolve (EXECUTION), narrow to the Branch,
--     drop and record the exclusions (each with a reason), copy the
--     entities, Planned -> In Progress. Final (decision: no unfreeze).
--     @exclusions_json: [{"dimensionCode":"ASSET","entityId":12,"reason":"..."}]
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_freeze_scope
    @organization_id BIGINT,
    @execution_id    BIGINT,
    @employee_id     BIGINT,
    @exclusions_json NVARCHAR(MAX) = NULL,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;
    IF @employee_id IS NULL
        THROW 54036, 'Sign in as the assigned auditor to freeze the scope.', 1;

    DECLARE @def BIGINT, @ver BIGINT, @item BIGINT, @owner BIGINT,
            @frozen DATETIME2, @status NVARCHAR(60);
    SELECT @def    = e.org_assurance_definition_id,
           @ver    = e.org_assurance_definition_version_id,
           @item   = e.org_assurance_plan_item_id,
           @owner  = e.owner_employee_id,
           @frozen = e.scope_frozen_at,
           @status = s.status_code
      FROM grac_practice.org_assurance_execution e
      JOIN grac_practice.org_assurance_execution_status_master s
           ON s.org_assurance_execution_status_id = e.execution_status_id
     WHERE e.org_assurance_execution_id = @execution_id
       AND e.organization_id = @organization_id
       AND e.is_active = 1;
    IF @def IS NULL
        THROW 54010, 'Execution not found or not accessible in this organization.', 1;
    IF @frozen IS NOT NULL
        THROW 54031, 'The scope of this execution is already frozen.', 1;
    IF @owner IS NULL OR @owner <> @employee_id
        THROW 54032, 'Only the assigned auditor can freeze the scope.', 1;
    IF @status <> N'Planned'
        THROW 54033, 'The scope can be frozen only while the execution is Planned.', 1;

    DECLARE @excl TABLE (dimension_code NVARCHAR(60) NULL, entity_id BIGINT NULL, reason NVARCHAR(1000) NULL);
    IF @exclusions_json IS NOT NULL AND ISJSON(@exclusions_json) = 1
        INSERT INTO @excl (dimension_code, entity_id, reason)
        SELECT x.dimension_code, x.entity_id, MAX(x.reason)
          FROM (SELECT NULLIF(LTRIM(RTRIM(JSON_VALUE(j.[value], '$.dimensionCode'))), N'') AS dimension_code,
                       TRY_CAST(JSON_VALUE(j.[value], '$.entityId') AS BIGINT)            AS entity_id,
                       LEFT(NULLIF(LTRIM(RTRIM(JSON_VALUE(j.[value], '$.reason'))), N''), 1000) AS reason
                  FROM OPENJSON(@exclusions_json) j) x
         GROUP BY x.dimension_code, x.entity_id;
    IF EXISTS (SELECT 1 FROM @excl WHERE dimension_code IS NULL OR entity_id IS NULL OR reason IS NULL)
        THROW 54034, 'Every excluded item needs a reason.', 1;

    DECLARE @branch BIGINT = (SELECT assigned_branch_id FROM grac_practice.org_assurance_plan_item
                               WHERE org_assurance_plan_item_id = @item);
    DECLARE @res BIGINT, @total BIGINT, @summary NVARCHAR(MAX);

    BEGIN TRAN;

    EXEC grac_practice.sp_org_assurance_scope_resolve
         @organization_id    = @organization_id,
         @definition_id      = @def,
         @version_id         = @ver,
         @resolution_purpose = N'EXECUTION',
         @execution_id       = @execution_id,
         @actor              = @actor,
         @resolution_id_out  = @res OUTPUT;
    IF @branch IS NOT NULL
        EXEC grac_practice.sp_org_assurance_scope_resolution_narrow_location
             @organization_id = @organization_id,
             @resolution_id   = @res,
             @location_id     = @branch;

    IF EXISTS (SELECT 1 FROM @excl x
                WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_resolution_entity r
                                   WHERE r.org_assurance_scope_resolution_id = @res
                                     AND r.dimension_code = x.dimension_code
                                     AND r.entity_id      = x.entity_id))
        THROW 54034, 'An excluded item is no longer in the scope. Reload the scope and try again.', 1;

    INSERT INTO grac_practice.org_assurance_execution_scope_exclusion
        (organization_id, org_assurance_execution_id, dimension_code, dimension_name,
         entity_id, entity_code, entity_name, reason, entered_by)
    SELECT @organization_id, @execution_id, x.dimension_code, r.dimension_name,
           x.entity_id, r.entity_code, r.entity_name, x.reason, @actor
      FROM @excl x
      CROSS APPLY (SELECT TOP 1 re.dimension_name, re.entity_code, re.entity_name
                     FROM grac_practice.org_assurance_scope_resolution_entity re
                    WHERE re.org_assurance_scope_resolution_id = @res
                      AND re.dimension_code = x.dimension_code
                      AND re.entity_id      = x.entity_id) r;

    DELETE r
      FROM grac_practice.org_assurance_scope_resolution_entity r
      JOIN @excl x ON x.dimension_code = r.dimension_code AND x.entity_id = r.entity_id
     WHERE r.org_assurance_scope_resolution_id = @res;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_resolution_entity
                    WHERE org_assurance_scope_resolution_id = @res)
        THROW 54035, 'Nothing is left in the scope. Keep at least one item, or cancel the execution.', 1;

    SET @summary = (SELECT dimension_code AS dimensionCode, COUNT(*) AS entityCount
                      FROM grac_practice.org_assurance_scope_resolution_entity
                     WHERE org_assurance_scope_resolution_id = @res
                     GROUP BY dimension_code
                     ORDER BY dimension_code
                       FOR JSON PATH);
    SET @total = (SELECT COUNT_BIG(*) FROM grac_practice.org_assurance_scope_resolution_entity
                   WHERE org_assurance_scope_resolution_id = @res);
    UPDATE grac_practice.org_assurance_scope_resolution
       SET total_entity_count = @total, summary_json = @summary, execution_id = @execution_id
     WHERE org_assurance_scope_resolution_id = @res;

    -- The entities, as materialize copies them.
    INSERT INTO grac_practice.org_assurance_execution_entity(
        org_assurance_execution_id, organization_id,
        dimension_code, dimension_name,
        entity_id, entity_code, entity_name,
        source_group_order, source_condition_order,
        entity_status_code, is_active, entered_by, entered_dt)
    SELECT @execution_id, @organization_id,
           r.dimension_code, r.dimension_name,
           r.entity_id, r.entity_code, r.entity_name,
           r.source_group_order, r.source_condition_order,
           N'NotStarted', 1, @actor, SYSUTCDATETIME()
      FROM grac_practice.org_assurance_scope_resolution_entity r
     WHERE r.org_assurance_scope_resolution_id = @res
       AND r.organization_id = @organization_id;

    UPDATE grac_practice.org_assurance_execution
       SET org_assurance_scope_resolution_id = @res,
           total_entity_count = (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_execution_entity
                                  WHERE org_assurance_execution_id = @execution_id AND is_active = 1),
           scope_frozen_at    = SYSUTCDATETIME(),
           scope_frozen_by    = @actor,
           updated_by         = @actor,
           updated_dt         = SYSUTCDATETIME()
     WHERE org_assurance_execution_id = @execution_id;

    -- Freezing starts the audit.
    EXEC grac_practice.sp_org_assurance_execution_transition
         @organization_id     = @organization_id,
         @execution_id        = @execution_id,
         @expected_from_codes = N'Planned',
         @to_code             = N'InProgress',
         @stamp_start         = 1,
         @stamp_end           = 0,
         @actor               = @actor;

    COMMIT;

    SELECT e.org_assurance_execution_id AS ExecutionId,
           e.execution_code             AS ExecutionCode,
           e.total_entity_count         AS TotalEntityCount,
           (SELECT COUNT(*) FROM @excl)  AS ExcludedCount
      FROM grac_practice.org_assurance_execution e
     WHERE e.org_assurance_execution_id = @execution_id;
END
GO

-- =====================================================================
-- 11. sp_org_assurance_execution_scope_exclusion_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_scope_exclusion_list
    @organization_id BIGINT,
    @execution_id    BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;

    SELECT x.dimension_code AS DimensionCode, x.dimension_name AS DimensionName,
           x.entity_id AS EntityId, x.entity_code AS EntityCode, x.entity_name AS EntityName,
           x.reason AS Reason, x.entered_by AS EnteredBy, x.entered_dt AS EnteredDt
      FROM grac_practice.org_assurance_execution_scope_exclusion x
     WHERE x.org_assurance_execution_id = @execution_id
       AND x.organization_id = @organization_id
     ORDER BY x.dimension_code, x.entity_name;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '555 schema' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.org_assurance_execution','scope_frozen_at') IS NOT NULL
             AND OBJECT_ID('grac_practice.org_assurance_execution_scope_exclusion','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '555 menu',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-my-audits' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '555 live materialize / start',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_execution_materialize')) LIKE '%@live%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_plan_item_start_execution')) LIKE '%@suppress_result%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_execution_start')) LIKE '%54030%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '555 new procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_my_audits_prepare','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_my_audit_list','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_execution_live_scope','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_execution_freeze_scope','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_execution_scope_exclusion_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '555 complete. Restart the Api and publish Web; users sign out and back in to see My Audits.';
GO
SET NOEXEC OFF;
GO
