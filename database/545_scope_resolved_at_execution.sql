-- =====================================================================
-- 545  Scope is resolved when an execution is created; Scope Resolution
--      is no longer a configuration step
--
-- REQUEST (2026-11-13, sir)
--   Resolving the scope during configuration is too early: planning comes
--   after configuration and the execution after that, by when the data
--   (assets, vendors, practice instances) has changed. Resolve it when the
--   execution is created.
--
-- WHAT THIS DOES
--   1. sp_org_assurance_execution_materialize (536 body):
--      @scope_resolution_id is optional (default NULL). Without it the
--      procedure resolves the version's scope itself, inside its own
--      transaction (sp_org_assurance_scope_resolve, purpose EXECUTION),
--      links that snapshot to the new execution (scope_resolution.
--      execution_id) and snapshots its entities -- the scope as it is at
--      that moment. A snapshot passed in is still checked and used as
--      before (54019 / 54020 / 54021); THROW 54012 (snapshot required)
--      is gone.
--   2. fn_org_assurance_setup_steps (543 body): the Scope Resolution step
--      is removed -- five configuration steps (Scope Builder, Question
--      Sets, Workflow, Scoring, Trigger). The chips, the Audit
--      Configuration list and the 537 review gate follow: Submit for
--      Review no longer needs a resolution, and the 543 "scope changed
--      after the last resolve" rule goes with the step.
--   3. sp_org_assurance_configuration_list (543 body): no
--      ScopeResolutionStatus; ConfigurationSteps = 5.
--
-- NOT CHANGED: sp_org_assurance_scope_resolve (Preview still uses it,
--   purpose PREVIEW), sp_org_assurance_setup_status, the submit gate
--   procedure, tables, old executions and their snapshots.
-- DEPENDS ON: 534 (resolver), 536 (materialize), 543.
-- Rollback: 545_scope_resolved_at_execution_rollback.sql (543 function and
--   list, 536 materialize).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_scope_resolve','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_assurance_execution_materialize','P') IS NULL
   OR OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_org_assurance_setup_steps')) NOT LIKE '%scope_saved_at%'
   OR COL_LENGTH('grac_practice.org_assurance_scope_resolution','execution_id') IS NULL
BEGIN
    PRINT 'ABORT (545): run 543 first (and 534 / 536). Nothing was changed.';
    RAISERROR('545_scope_resolved_at_execution: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_org_assurance_execution_materialize (536 body + 545)
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

    DECLARE @workflow_json NVARCHAR(MAX) = ISNULL(
        (SELECT wc.org_assurance_workflow_config_id AS WorkflowConfigId,
                wc.config_code                       AS ConfigCode,
                wc.config_name                       AS ConfigName,
                wc.notes                             AS Notes,
                ws.stage_order                       AS StageOrder,
                ws.stage_code                        AS StageCode,
                ws.stage_name                        AS StageName,
                ws.stage_type_id                     AS StageTypeId,
                ws.stage_type_code                   AS StageTypeCode,
                ws.stage_type_name                   AS StageTypeName,
                ws.role_id                           AS RoleId,
                ws.role_name                         AS RoleName,
                ws.due_days_offset                   AS DueDaysOffset,
                ws.is_optional                       AS IsOptional
         FROM grac_practice.org_assurance_workflow_config wc
         LEFT JOIN grac_practice.org_assurance_workflow_config_stage ws
                ON ws.org_assurance_workflow_config_id = wc.org_assurance_workflow_config_id
         WHERE wc.org_assurance_definition_version_id = @version_id
           AND wc.is_active = 1
         ORDER BY ws.stage_order
         FOR JSON PATH),
        N'{}');

    DECLARE @scoring_json NVARCHAR(MAX) = ISNULL(
        (SELECT sc.org_assurance_scoring_config_id AS ScoringConfigId,
                sc.scoring_model_id                  AS ScoringModelId,
                sc.scoring_model_code                AS ScoringModelCode,
                sc.scoring_model_name                AS ScoringModelName,
                sc.model_type_id                     AS ModelTypeId,
                sc.model_type_code                   AS ModelTypeCode,
                sc.model_type_name                   AS ModelTypeName,
                sc.notes                             AS Notes,
                sb.band_order                        AS BandOrder,
                sb.band_code                         AS BandCode,
                sb.band_name                         AS BandName,
                sb.score_from                        AS ScoreFrom,
                sb.score_to                          AS ScoreTo,
                sb.band_color                        AS BandColor
         FROM grac_practice.org_assurance_scoring_config sc
         LEFT JOIN grac_practice.org_assurance_scoring_config_band sb
                ON sb.org_assurance_scoring_config_id = sc.org_assurance_scoring_config_id
         WHERE sc.org_assurance_definition_version_id = @version_id
           AND sc.is_active = 1
         ORDER BY sb.band_order
         FOR JSON PATH),
        N'{}');

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

    -- 545: the snapshot made for this execution points back at it.
    IF @resolved_here = 1
        UPDATE grac_practice.org_assurance_scope_resolution
           SET execution_id = @execution_id_out
         WHERE org_assurance_scope_resolution_id = @scope_resolution_id;

    -- Snapshot entities from the scope resolution (auditor left NULL --
    -- assigned per-entity later via sp_org_assurance_execution_entity_auditor_assign).
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
-- 2. fn_org_assurance_setup_steps (543 body, no Scope Resolution step)
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_org_assurance_setup_steps
(
    @organization_id BIGINT,
    @version_id      BIGINT
)
RETURNS TABLE
AS
RETURN
    WITH c AS (
        SELECT
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_scope_group g
              WHERE g.org_assurance_definition_version_id = @version_id
                AND g.organization_id = @organization_id
                AND g.is_active = 1)                                  AS scope_groups,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_definition_question_set q
              WHERE q.org_assurance_definition_version_id = @version_id
                AND q.organization_id = @organization_id
                AND q.is_active = 1)                                  AS question_sets,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_workflow_config w
              WHERE w.org_assurance_definition_version_id = @version_id
                AND w.organization_id = @organization_id
                AND w.is_active = 1)                                  AS workflow_cfg,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_workflow_stage st
               JOIN grac_practice.org_assurance_workflow_config w
                    ON w.org_assurance_workflow_config_id = st.org_assurance_workflow_config_id
              WHERE w.org_assurance_definition_version_id = @version_id
                AND w.organization_id = @organization_id
                AND w.is_active = 1
                AND st.is_active = 1)                                 AS workflow_stage,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_scoring_config sc
              WHERE sc.org_assurance_definition_version_id = @version_id
                AND sc.organization_id = @organization_id
                AND sc.is_active = 1)                                 AS scoring_cfg,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_scoring_band b
               JOIN grac_practice.org_assurance_scoring_config sc
                    ON sc.org_assurance_scoring_config_id = b.org_assurance_scoring_config_id
              WHERE sc.org_assurance_definition_version_id = @version_id
                AND sc.organization_id = @organization_id
                AND sc.is_active = 1
                AND b.is_active  = 1)                                 AS scoring_band,
            -- 541: a scoring config is complete when it has what its model
            -- type uses (087 sp_org_assurance_scoring_model_type_list):
            --   thresholds (SupportsThreshold): PASS_FAIL, WEIGHTED,
            --     PERCENTAGE, CUSTOM -> a Pass Threshold;
            --   bands (SupportsBands): RISK_BASED, MATURITY_BASED,
            --     PERCENTAGE, CUSTOM -> at least one active band.
            -- Before 541 every type needed bands, so a Weighted or Pass /
            -- Fail scoring (thresholds only) never left "In progress".
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_scoring_config sc
              WHERE sc.org_assurance_definition_version_id = @version_id
                AND sc.organization_id = @organization_id
                AND sc.is_active = 1
                AND (   (sc.scoring_model_type IN (N'PASS_FAIL', N'WEIGHTED', N'PERCENTAGE', N'CUSTOM')
                         AND sc.pass_threshold IS NOT NULL)
                     OR (sc.scoring_model_type IN (N'RISK_BASED', N'MATURITY_BASED', N'PERCENTAGE', N'CUSTOM')
                         AND EXISTS (SELECT 1
                                       FROM grac_practice.org_assurance_scoring_band b
                                      WHERE b.org_assurance_scoring_config_id = sc.org_assurance_scoring_config_id
                                        AND b.is_active = 1))))         AS scoring_ready,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_trigger_config t
              WHERE t.org_assurance_definition_version_id = @version_id
                AND t.organization_id = @organization_id
                AND t.is_active = 1)                                  AS trigger_rows
            -- 545: no Scope Resolution step -- the scope is resolved when
            -- an execution is created (sp_org_assurance_execution_materialize).
    )
    SELECT x.StepOrder, x.StepKey, x.StepName, x.IsConfiguration, x.ItemCount, x.Status
    FROM c
    CROSS APPLY (VALUES
        (1, N'details',          N'Audit Details',    CAST(0 AS BIT), 1,
            N'Completed'),
        (2, N'scope',            N'Scope Builder',    CAST(1 AS BIT), c.scope_groups,
            CASE WHEN c.scope_groups  > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (3, N'questions',        N'Question Sets',    CAST(1 AS BIT), c.question_sets,
            CASE WHEN c.question_sets > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (4, N'workflow',         N'Workflow',         CAST(1 AS BIT), c.workflow_stage,
            CASE WHEN c.workflow_stage > 0 THEN N'Completed'
                 WHEN c.workflow_cfg   > 0 THEN N'InProgress'
                 ELSE N'NotConfigured' END),
        (5, N'scoring',          N'Scoring',          CAST(1 AS BIT),
            CASE WHEN c.scoring_band > 0 THEN c.scoring_band ELSE c.scoring_ready END,
            CASE WHEN c.scoring_ready > 0 THEN N'Completed'
                 WHEN c.scoring_cfg  > 0 THEN N'InProgress'
                 ELSE N'NotConfigured' END),
        (6, N'trigger',          N'Trigger',          CAST(1 AS BIT), c.trigger_rows,
            CASE WHEN c.trigger_rows > 0 THEN N'Completed' ELSE N'NotConfigured' END)
    ) AS x(StepOrder, StepKey, StepName, IsConfiguration, ItemCount, Status);
GO

-- =====================================================================
-- 3. sp_org_assurance_configuration_list (543 body, five steps)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_configuration_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 53601, 'organization_id is required.', 1;
    IF @page IS NULL OR @page < 1           SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200                     SET @page_size = 200;

    DECLARE @offset INT = (@page - 1) * @page_size;

    -- 543: every Draft audit (Scope and Question Sets are configured on
    -- this page now, so a Draft with neither must be listed) and every
    -- audit Under Review (approved from this page). Steps come from the
    -- same function as the chips; all six count (IsConfiguration = 1).
    SELECT d.org_assurance_definition_id AS definition_id,
           d.organization_id,
           d.definition_code,
           d.definition_name,
           d.owner_role_name,
           d.owner_display_name,
           d.current_version_id,
           s.status_code               AS current_status_code,
           s.status_name               AS current_status_name,
           v.version_number            AS current_version_number,
           v.version_label             AS current_version_label,
           v.effective_date            AS current_effective_date,
           v.assurance_category_name   AS current_category_name,
           st.scope_status,
           st.questions_status,
           st.workflow_status,
           st.scoring_status,
           st.trigger_status,
           st.configured_steps,
           d.updated_dt
    INTO #cfg
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    LEFT JOIN grac_practice.org_assurance_definition_version v
         ON v.org_assurance_definition_version_id = d.current_version_id
    CROSS APPLY (
        SELECT MAX(CASE WHEN f.StepKey = N'scope'            THEN f.Status END) AS scope_status,
               MAX(CASE WHEN f.StepKey = N'questions'        THEN f.Status END) AS questions_status,
               MAX(CASE WHEN f.StepKey = N'workflow'         THEN f.Status END) AS workflow_status,
               MAX(CASE WHEN f.StepKey = N'scoring'          THEN f.Status END) AS scoring_status,
               MAX(CASE WHEN f.StepKey = N'trigger'          THEN f.Status END) AS trigger_status,
               SUM(CASE WHEN f.IsConfiguration = 1 AND f.Status = N'Completed' THEN 1 ELSE 0 END) AS configured_steps
        FROM grac_practice.fn_org_assurance_setup_steps(d.organization_id, d.current_version_id) f
    ) st
    WHERE d.organization_id = @organization_id
      AND d.is_active = 1
      AND d.current_version_id IS NOT NULL
      AND s.status_code IN (N'Draft', N'UnderReview')
      AND (@search IS NULL OR @search = N''
           OR d.definition_name LIKE N'%' + @search + N'%'
           OR d.definition_code LIKE N'%' + @search + N'%');

    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM #cfg;

    SELECT definition_id            AS DefinitionId,
           organization_id          AS OrganizationId,
           definition_code          AS DefinitionCode,
           definition_name          AS DefinitionName,
           owner_role_name          AS OwnerRoleName,
           owner_display_name       AS OwnerDisplayName,
           current_version_id       AS CurrentVersionId,
           current_status_code      AS CurrentStatusCode,
           current_status_name      AS CurrentStatusName,
           current_version_number   AS CurrentVersionNumber,
           current_version_label    AS CurrentVersionLabel,
           current_effective_date   AS CurrentEffectiveDate,
           current_category_name    AS CurrentCategoryName,
           scope_status             AS ScopeStatus,
           questions_status         AS QuestionsStatus,
           workflow_status          AS WorkflowStatus,
           scoring_status           AS ScoringStatus,
           trigger_status           AS TriggerStatus,
           CAST(configured_steps AS INT) AS ConfiguredSteps,
           CAST(5 AS INT)           AS ConfigurationSteps,   -- 545: no Scope Resolution step
           CAST(CASE WHEN configured_steps = 5 THEN 1 ELSE 0 END AS BIT) AS IsConfigured
    FROM #cfg
    -- Under Review first: they wait on an approver.
    ORDER BY CASE WHEN current_status_code = N'UnderReview' THEN 0 ELSE 1 END,
             definition_name, definition_id
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '545 materialize resolves the scope itself' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_execution_materialize')) LIKE '%sp_org_assurance_scope_resolve%' THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '545 no Scope Resolution step',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_org_assurance_setup_steps')) NOT LIKE '%scope-resolution%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '545 configuration list counts five steps',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_configuration_list')) NOT LIKE '%ScopeResolutionStatus%' THEN 'PASS' ELSE 'FAIL' END;
PRINT '545 complete. Restart the Api and publish Web.';
GO
SET NOEXEC OFF;
GO
