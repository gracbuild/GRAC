-- =====================================================================
-- 536 ROLLBACK  Evidence Config back
--   Restores sp_org_assurance_execution_materialize (120 body) and
--   sp_org_assurance_setup_status (278 body), and makes the
--   'org-assurance-evidence-config' menu Active again. The Evidence Config
--   tables were never touched. Revert the Api / Web files and 274 with it.
--   Executions created while 536 was in place keep their question-based
--   snapshots. ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_materialize
    @organization_id     BIGINT,
    @definition_id       BIGINT,
    @version_id          BIGINT       = NULL,
    @scope_resolution_id BIGINT,
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
    IF @scope_resolution_id IS NULL  THROW 54012, 'scope_resolution_id is required.',  1;
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
    DECLARE @scope_res_org BIGINT, @scope_res_def BIGINT, @scope_res_ver BIGINT,
            @scope_res_total BIGINT;
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

    -- Question sets currently do not link to a definition_version (documented
    -- gap in 099); left as an empty array so the SP shape stays stable.
    DECLARE @questions_json NVARCHAR(MAX) = N'[]';

    DECLARE @evidence_json NVARCHAR(MAX) = ISNULL(
        (SELECT ec.org_assurance_evidence_config_id AS EvidenceConfigId,
                ei.evidence_type_id                  AS EvidenceTypeId,
                ei.evidence_type_code                AS EvidenceTypeCode,
                ei.evidence_type_name                AS EvidenceTypeName,
                ei.collection_method_id              AS CollectionMethodId,
                ei.collection_method_code            AS CollectionMethodCode,
                ei.collection_method_name            AS CollectionMethodName,
                ei.collection_frequency_id           AS CollectionFrequencyId,
                ei.collection_frequency_code         AS CollectionFrequencyCode,
                ei.collection_frequency_name         AS CollectionFrequencyName,
                ei.evidence_owner                    AS EvidenceOwner,
                ei.owner_role_id                     AS OwnerRoleId,
                ei.owner_role_name                   AS OwnerRoleName,
                ei.owner_employee_id                 AS OwnerEmployeeId,
                ei.owner_display_name                AS OwnerDisplayName,
                ei.retention_period                  AS RetentionPeriod,
                ei.evidence_location                 AS EvidenceLocation,
                ei.evidence_locator                  AS EvidenceLocator,
                ei.evidence_label                    AS EvidenceLabel,
                ei.description                       AS Description,
                ei.is_mandatory                      AS IsMandatory,
                ei.validity_days                     AS ValidityDays,
                ei.expiry_warning_days               AS ExpiryWarningDays,
                ei.display_order                     AS DisplayOrder
         FROM grac_practice.org_assurance_evidence_config ec
         LEFT JOIN grac_practice.org_assurance_evidence_config_item ei
                ON ei.org_assurance_evidence_config_id = ec.org_assurance_evidence_config_id
         WHERE ec.org_assurance_definition_version_id = @version_id
           AND ec.is_active = 1
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
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_setup_status
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @version_id      BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);

    SELECT @def_org             = d.organization_id,
           @current_version_id  = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL      THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;

    IF @version_id IS NULL SET @version_id = @current_version_id;

    DECLARE @scope_groups   INT = 0,
            @question_sets  INT = 0,
            @evidence_rows  INT = 0,
            @workflow_cfg   INT = 0,
            @workflow_stage INT = 0,
            @scoring_cfg    INT = 0,
            @scoring_band   INT = 0,
            @trigger_rows   INT = 0,
            @resolutions    INT = 0;

    SELECT @scope_groups = COUNT(*)
      FROM grac_practice.org_assurance_scope_group g
     WHERE g.org_assurance_definition_version_id = @version_id
       AND g.organization_id = @organization_id
       AND g.is_active = 1;

    SELECT @question_sets = COUNT(*)
      FROM grac_practice.org_assurance_definition_question_set q
     WHERE q.org_assurance_definition_version_id = @version_id
       AND q.organization_id = @organization_id
       AND q.is_active = 1;

    SELECT @evidence_rows = COUNT(*)
      FROM grac_practice.org_assurance_evidence_config e
     WHERE e.org_assurance_definition_version_id = @version_id
       AND e.organization_id = @organization_id
       AND e.is_active = 1;

    SELECT @workflow_cfg = COUNT(*)
      FROM grac_practice.org_assurance_workflow_config w
     WHERE w.org_assurance_definition_version_id = @version_id
       AND w.organization_id = @organization_id
       AND w.is_active = 1;

    SELECT @workflow_stage = COUNT(*)
      FROM grac_practice.org_assurance_workflow_stage st
      JOIN grac_practice.org_assurance_workflow_config w
           ON w.org_assurance_workflow_config_id = st.org_assurance_workflow_config_id
     WHERE w.org_assurance_definition_version_id = @version_id
       AND w.organization_id = @organization_id
       AND w.is_active = 1
       AND st.is_active = 1;

    SELECT @scoring_cfg = COUNT(*)
      FROM grac_practice.org_assurance_scoring_config sc
     WHERE sc.org_assurance_definition_version_id = @version_id
       AND sc.organization_id = @organization_id
       AND sc.is_active = 1;

    SELECT @scoring_band = COUNT(*)
      FROM grac_practice.org_assurance_scoring_band b
      JOIN grac_practice.org_assurance_scoring_config sc
           ON sc.org_assurance_scoring_config_id = b.org_assurance_scoring_config_id
     WHERE sc.org_assurance_definition_version_id = @version_id
       AND sc.organization_id = @organization_id
       AND sc.is_active = 1
       AND b.is_active  = 1;

    SELECT @trigger_rows = COUNT(*)
      FROM grac_practice.org_assurance_trigger_config t
     WHERE t.org_assurance_definition_version_id = @version_id
       AND t.organization_id = @organization_id
       AND t.is_active = 1;

    SELECT @resolutions = COUNT(*)
      FROM grac_practice.org_assurance_scope_resolution r
     WHERE r.org_assurance_definition_version_id = @version_id
       AND r.organization_id = @organization_id;

    -- Header, so the caller knows which version was measured.
    SELECT @definition_id       AS DefinitionId,
           @version_id          AS VersionId,
           @current_version_id  AS CurrentVersionId,
           @current_status_code AS CurrentStatusCode,
           CAST(CASE WHEN @current_status_code = N'Draft'
                     AND @version_id = @current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS IsEditable;

    -- One row per step. "details" is Completed by definition: the audit
    -- exists and has a version, or this procedure would have thrown.
    SELECT StepKey, StepName, ItemCount, Status
    FROM (VALUES
        (N'details',          N'Audit Details',      1,
            N'Completed'),
        (N'scope',            N'Scope Builder',      @scope_groups,
            CASE WHEN @scope_groups  > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (N'questions',        N'Question Sets',      @question_sets,
            CASE WHEN @question_sets > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (N'evidence',         N'Evidence',           @evidence_rows,
            CASE WHEN @evidence_rows > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (N'workflow',         N'Workflow',           @workflow_stage,
            CASE WHEN @workflow_stage > 0 THEN N'Completed'
                 WHEN @workflow_cfg   > 0 THEN N'InProgress'
                 ELSE N'NotConfigured' END),
        (N'scoring',          N'Scoring',            @scoring_band,
            CASE WHEN @scoring_cfg  > 0 AND @scoring_band > 0 THEN N'Completed'
                 WHEN @scoring_cfg  > 0 THEN N'InProgress'
                 ELSE N'NotConfigured' END),
        (N'trigger',          N'Trigger',            @trigger_rows,
            CASE WHEN @trigger_rows > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (N'scope-resolution', N'Scope Resolution',   @resolutions,
            CASE WHEN @resolutions  > 0 THEN N'Completed' ELSE N'NotConfigured' END)
    ) AS x(StepKey, StepName, ItemCount, Status);
END
GO
UPDATE grac_practice.menu_master
   SET status = N'Active', updated_by = 'rollback-536', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-assurance-evidence-config';
PRINT 'ROLLBACK 536: Evidence Config menu active again = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO
PRINT 'ROLLBACK 536 complete.';
GO
