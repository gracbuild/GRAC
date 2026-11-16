-- =====================================================================
-- 555 ROLLBACK -- restores materialize (545), engagement start execution
-- (554), execution start (099) and execution get (120); drops the 555
-- procedures; sets the My Audits menu row Inactive. KEPT: the scope_frozen
-- columns and org_assurance_execution_scope_exclusion (unread). Executions
-- created live (no entities) stay as they are -- cancel them. Deploy the
-- pre-555 Api and Web with it. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
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

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_start_execution
    @organization_id  BIGINT,
    @plan_id          BIGINT,
    @plan_item_id     BIGINT,
    @actor            NVARCHAR(100) = 'system',
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
        -- 554: the engagement's Branch (a Location) narrows the audit's
        -- scope. The scope is resolved here (EXECUTION), narrowed, and the
        -- snapshot handed to materialize. No branch: materialize resolves
        -- it itself, as before. An audit with nothing left at the branch
        -- stops the start (nothing is created).
        IF @branch_id IS NOT NULL
        BEGIN
            EXEC grac_practice.sp_org_assurance_scope_resolve
                 @organization_id    = @organization_id,
                 @definition_id      = @def,
                 @version_id         = @ver,
                 @resolution_purpose = N'EXECUTION',
                 @execution_id       = NULL,
                 @actor              = @actor,
                 @resolution_id_out  = @res OUTPUT;
            EXEC grac_practice.sp_org_assurance_scope_resolution_narrow_location
                 @organization_id = @organization_id,
                 @resolution_id   = @res,
                 @location_id     = @branch_id;
            IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_resolution_entity
                            WHERE org_assurance_scope_resolution_id = @res)
            BEGIN
                SELECT @def_code = definition_code FROM grac_practice.org_assurance_definition
                 WHERE org_assurance_definition_id = @def;
                SET @msg = CONCAT(N'Audit ', @def_code, N' has nothing in scope at branch ',
                                  ISNULL(@branch_name, N'#' + CAST(@branch_id AS NVARCHAR(20))),
                                  N'. Remove the branch or this audit from the engagement.');
                THROW 53942, @msg, 1;
            END
        END
        EXEC grac_practice.sp_org_assurance_execution_materialize
             @organization_id     = @organization_id,
             @definition_id       = @def,
             @version_id          = @ver,
             @scope_resolution_id = @res,
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
             @execution_id_out    = @eid OUTPUT;
        -- 554: a snapshot made here points back at its execution
        -- (materialize does this only for one it resolved itself).
        IF @res IS NOT NULL
            UPDATE grac_practice.org_assurance_scope_resolution
               SET execution_id = @eid
             WHERE org_assurance_scope_resolution_id = @res;
        INSERT INTO @started (execution_id) VALUES (@eid);
        IF @execution_id_out IS NULL SET @execution_id_out = @eid;
        SET @n += 1;
    END
    COMMIT;

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

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_start
    @organization_id BIGINT, @execution_id BIGINT, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_execution_transition
        @organization_id = @organization_id, @execution_id = @execution_id,
        @expected_from_codes = N'Planned',
        @to_code = N'InProgress',
        @stamp_start = 1, @stamp_end = 0, @actor = @actor;
END
GO

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

IF OBJECT_ID('grac_practice.sp_org_assurance_my_audit_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_my_audit_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_my_audits_prepare','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_my_audits_prepare;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_execution_live_scope','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_execution_live_scope;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_execution_freeze_scope','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_execution_freeze_scope;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_execution_scope_exclusion_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_execution_scope_exclusion_list;
GO
UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-555', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-my-audits';
GO
PRINT '555 rolled back.';
GO
