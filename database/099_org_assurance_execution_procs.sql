-- =====================================================================
-- 099 Organization Assurance Execution -- Stage 3 stored procedures
--
-- Depends on 098 (execution schema), 069 (definition), 073/075 (scope),
-- 076/078 (questions), 079/081 (evidence config),
-- 083/084 (workflow config), 086/087 (scoring config),
-- 095/096 (scope resolution).
--
-- Procedures:
--   sp_org_assurance_execution_status_list
--   sp_org_assurance_execution_list
--   sp_org_assurance_execution_get
--   sp_org_assurance_execution_entity_list
--   sp_org_assurance_execution_materialize
--   sp_org_assurance_execution_transition
--   sp_org_assurance_execution_start
--   sp_org_assurance_execution_submit
--   sp_org_assurance_execution_review
--   sp_org_assurance_execution_approve
--   sp_org_assurance_execution_close
--   sp_org_assurance_execution_cancel
--   sp_org_assurance_execution_delete       (soft, non-terminal only)
--
-- THROW reason codes: 54008-54099 (module-specific range).
-- Rollback: 099_org_assurance_execution_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_execution','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_execution_entity','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_execution_status_master','U') IS NULL
BEGIN
    RAISERROR('099: run 098 schema first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_org_assurance_execution_status_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_status_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT org_assurance_execution_status_id AS StatusId,
           status_code                        AS StatusCode,
           status_name                        AS StatusName,
           display_order                      AS DisplayOrder,
           is_terminal                        AS IsTerminal
    FROM grac_practice.org_assurance_execution_status_master
    WHERE is_active = 1
    ORDER BY display_order, org_assurance_execution_status_id;
END
GO

-- =====================================================================
-- sp_org_assurance_execution_list  (paginated, org-scoped)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_list
    @organization_id BIGINT,
    @definition_id   BIGINT       = NULL,
    @status_code     NVARCHAR(60) = NULL,
    @origin_type     NVARCHAR(20) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 54008, 'organization_id is required.', 1;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    DECLARE @offset INT = (@page - 1) * @page_size;

    ;WITH base AS (
        SELECT e.org_assurance_execution_id,
               e.organization_id,
               e.org_assurance_definition_id,
               e.org_assurance_definition_version_id,
               e.definition_code,
               e.definition_name,
               e.version_number,
               e.execution_code,
               e.execution_name,
               s.status_code AS status_code,
               s.status_name AS status_name,
               s.is_terminal AS status_is_terminal,
               e.origin_type,
               e.org_assurance_plan_id,
               e.org_assurance_plan_item_id,
               e.org_assurance_trigger_config_id,
               e.org_assurance_scope_resolution_id,
               e.owner_employee_id,
               e.owner_display_name,
               e.planned_start_dt,
               e.planned_end_dt,
               e.actual_start_dt,
               e.actual_end_dt,
               e.total_entity_count,
               e.completed_entity_count,
               e.entered_dt,
               e.updated_dt
        FROM grac_practice.org_assurance_execution e
        JOIN grac_practice.org_assurance_execution_status_master s
             ON s.org_assurance_execution_status_id = e.execution_status_id
        WHERE e.organization_id = @organization_id
          AND e.is_active = 1
          AND (@definition_id IS NULL OR e.org_assurance_definition_id = @definition_id)
          AND (@status_code   IS NULL OR s.status_code = @status_code)
          AND (@origin_type   IS NULL OR e.origin_type = @origin_type)
          AND (@search IS NULL OR @search = ''
               OR e.execution_code LIKE N'%' + @search + N'%'
               OR e.execution_name LIKE N'%' + @search + N'%'
               OR e.definition_code LIKE N'%' + @search + N'%'
               OR e.definition_name LIKE N'%' + @search + N'%')
    )
    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM base;

    ;WITH base AS (
        SELECT e.org_assurance_execution_id,
               e.organization_id,
               e.org_assurance_definition_id,
               e.org_assurance_definition_version_id,
               e.definition_code,
               e.definition_name,
               e.version_number,
               e.execution_code,
               e.execution_name,
               s.status_code AS status_code,
               s.status_name AS status_name,
               s.is_terminal AS status_is_terminal,
               e.origin_type,
               e.org_assurance_plan_id,
               e.org_assurance_plan_item_id,
               e.org_assurance_trigger_config_id,
               e.org_assurance_scope_resolution_id,
               e.owner_employee_id,
               e.owner_display_name,
               e.planned_start_dt,
               e.planned_end_dt,
               e.actual_start_dt,
               e.actual_end_dt,
               e.total_entity_count,
               e.completed_entity_count,
               e.entered_dt,
               e.updated_dt
        FROM grac_practice.org_assurance_execution e
        JOIN grac_practice.org_assurance_execution_status_master s
             ON s.org_assurance_execution_status_id = e.execution_status_id
        WHERE e.organization_id = @organization_id
          AND e.is_active = 1
          AND (@definition_id IS NULL OR e.org_assurance_definition_id = @definition_id)
          AND (@status_code   IS NULL OR s.status_code = @status_code)
          AND (@origin_type   IS NULL OR e.origin_type = @origin_type)
          AND (@search IS NULL OR @search = ''
               OR e.execution_code LIKE N'%' + @search + N'%'
               OR e.execution_name LIKE N'%' + @search + N'%'
               OR e.definition_code LIKE N'%' + @search + N'%'
               OR e.definition_name LIKE N'%' + @search + N'%')
    )
    SELECT org_assurance_execution_id           AS ExecutionId,
           organization_id                       AS OrganizationId,
           org_assurance_definition_id           AS DefinitionId,
           org_assurance_definition_version_id   AS DefinitionVersionId,
           definition_code                       AS DefinitionCode,
           definition_name                       AS DefinitionName,
           version_number                        AS VersionNumber,
           execution_code                        AS ExecutionCode,
           execution_name                        AS ExecutionName,
           status_code                           AS StatusCode,
           status_name                           AS StatusName,
           status_is_terminal                    AS StatusIsTerminal,
           origin_type                           AS OriginType,
           org_assurance_plan_id                 AS PlanId,
           org_assurance_plan_item_id            AS PlanItemId,
           org_assurance_trigger_config_id       AS TriggerConfigId,
           org_assurance_scope_resolution_id     AS ScopeResolutionId,
           owner_employee_id                     AS OwnerEmployeeId,
           owner_display_name                    AS OwnerDisplayName,
           planned_start_dt                      AS PlannedStartDt,
           planned_end_dt                        AS PlannedEndDt,
           actual_start_dt                       AS ActualStartDt,
           actual_end_dt                         AS ActualEndDt,
           total_entity_count                    AS TotalEntityCount,
           completed_entity_count                AS CompletedEntityCount,
           entered_dt                            AS EnteredDt,
           updated_dt                            AS UpdatedDt
    FROM base
    ORDER BY entered_dt DESC, org_assurance_execution_id DESC
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- sp_org_assurance_execution_get  (header + snapshots)
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

-- =====================================================================
-- sp_org_assurance_execution_entity_list  (paginated)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_entity_list
    @organization_id BIGINT,
    @execution_id    BIGINT,
    @dimension_code  NVARCHAR(60) = NULL,
    @status_code     NVARCHAR(30) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 100;
    IF @page_size > 500 SET @page_size = 500;

    -- Guard org isolation.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_execution
        WHERE org_assurance_execution_id = @execution_id
          AND organization_id = @organization_id
          AND is_active = 1)
        THROW 54010, 'Execution not found or not accessible in this organization.', 1;

    DECLARE @offset INT = (@page - 1) * @page_size;

    ;WITH base AS (
        SELECT ee.org_assurance_execution_entity_id,
               ee.dimension_code,
               ee.dimension_name,
               ee.entity_id,
               ee.entity_code,
               ee.entity_name,
               ee.source_group_order,
               ee.source_condition_order,
               ee.entity_status_code,
               ee.started_dt,
               ee.completed_dt,
               ee.assigned_auditor_employee_id,
               ee.assigned_auditor_name
        FROM grac_practice.org_assurance_execution_entity ee
        WHERE ee.org_assurance_execution_id = @execution_id
          AND ee.organization_id = @organization_id
          AND ee.is_active = 1
          AND (@dimension_code IS NULL OR ee.dimension_code = @dimension_code)
          AND (@status_code    IS NULL OR ee.entity_status_code = @status_code)
          AND (@search IS NULL OR @search = ''
               OR ee.entity_name LIKE N'%' + @search + N'%'
               OR ee.entity_code LIKE N'%' + @search + N'%')
    )
    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM base;

    ;WITH base AS (
        SELECT ee.org_assurance_execution_entity_id,
               ee.dimension_code,
               ee.dimension_name,
               ee.entity_id,
               ee.entity_code,
               ee.entity_name,
               ee.source_group_order,
               ee.source_condition_order,
               ee.entity_status_code,
               ee.started_dt,
               ee.completed_dt,
               ee.assigned_auditor_employee_id,
               ee.assigned_auditor_name
        FROM grac_practice.org_assurance_execution_entity ee
        WHERE ee.org_assurance_execution_id = @execution_id
          AND ee.organization_id = @organization_id
          AND ee.is_active = 1
          AND (@dimension_code IS NULL OR ee.dimension_code = @dimension_code)
          AND (@status_code    IS NULL OR ee.entity_status_code = @status_code)
          AND (@search IS NULL OR @search = ''
               OR ee.entity_name LIKE N'%' + @search + N'%'
               OR ee.entity_code LIKE N'%' + @search + N'%')
    )
    SELECT org_assurance_execution_entity_id AS ExecutionEntityId,
           dimension_code                     AS DimensionCode,
           dimension_name                     AS DimensionName,
           entity_id                          AS EntityId,
           entity_code                        AS EntityCode,
           entity_name                        AS EntityName,
           source_group_order                 AS SourceGroupOrder,
           source_condition_order             AS SourceConditionOrder,
           entity_status_code                 AS EntityStatusCode,
           started_dt                         AS StartedDt,
           completed_dt                       AS CompletedDt,
           assigned_auditor_employee_id       AS AssignedAuditorEmployeeId,
           assigned_auditor_name              AS AssignedAuditorName
    FROM base
    ORDER BY dimension_code, entity_name, entity_code, org_assurance_execution_entity_id
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- sp_org_assurance_execution_materialize
--
-- Turns a definition + scope resolution into a live execution.
--
--   1. Validates org isolation + definition/version exists.
--   2. Validates scope resolution belongs to the same version.
--   3. Auto-generates execution_code if not supplied.
--   4. Captures IMMUTABLE JSON snapshots of the current version's
--      Questions / Evidence Config / Workflow Config / Scoring Config
--      as they stood at materialize time. Downstream Stage 4 must
--      read these snapshots, never the (mutable) config tables.
--   5. Copies the resolution entity snapshot into
--      org_assurance_execution_entity (per-entity execution status
--      starts NotStarted).
--   6. Fires a history entry on the definition (SCOPE_RESOLVE_EXECUTION
--      convention already logged by 096).
-- =====================================================================
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
        -- Dynamic status text so the API/UI can render a helpful message
        -- ("current status = Draft") rather than a bare rejection.
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
    -- Auto-generate code + name
    -- ---------------------------------------------------------------
    IF @execution_code IS NULL OR LEN(LTRIM(RTRIM(@execution_code))) = 0
        SET @execution_code = @def_code + N'-EXEC-' + FORMAT(SYSUTCDATETIME(), 'yyyyMMdd-HHmmss');

    IF @execution_name IS NULL OR LEN(LTRIM(RTRIM(@execution_name))) = 0
        SET @execution_name = @def_name + N' -- ' + FORMAT(SYSUTCDATETIME(), 'yyyy-MM-dd');

    -- Ensure code is unique in org.
    IF EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_execution
        WHERE organization_id = @organization_id
          AND execution_code  = @execution_code
          AND is_active = 1)
        THROW 54024, 'An execution with this code already exists in the organization.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    DECLARE @planned_status_id INT = (
        SELECT org_assurance_execution_status_id
        FROM grac_practice.org_assurance_execution_status_master WHERE status_code = N'Planned');

    -- ---------------------------------------------------------------
    -- IMMUTABLE definition snapshot (JSON)
    -- ---------------------------------------------------------------
    -- Master definition summary. Note: business attributes (category,
    -- description, objective, effective_date) live on the VERSION row,
    -- not the definition row (see 069 schema).
    DECLARE @definition_json NVARCHAR(MAX);
    SELECT @definition_json = (
        SELECT d.org_assurance_definition_id        AS definitionId,
               d.definition_code                     AS definitionCode,
               d.definition_name                     AS definitionName,
               v.org_assurance_definition_version_id AS versionId,
               v.version_number                      AS versionNumber,
               v.version_label                       AS versionLabel,
               v.description                         AS description,
               v.objective                           AS objective,
               v.effective_date                      AS effectiveDate,
               v.assurance_category_code             AS categoryCode,
               v.assurance_category_name             AS categoryName,
               s.status_code                         AS versionStatus
        FROM grac_practice.org_assurance_definition d
        JOIN grac_practice.org_assurance_definition_version v
             ON v.org_assurance_definition_version_id = @version_id
        JOIN grac_practice.org_assurance_status_master s
             ON s.org_assurance_status_id = v.status_id
        WHERE d.org_assurance_definition_id = @definition_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    -- Questions snapshot.
    --
    -- The current schema (076) links questions to PM entities
    -- (Practice / Requirement / Obligation / Asset / Risk /
    -- EvidenceType) via question_link, but does NOT wire question
    -- sets to definition versions -- question sets are org-level
    -- reusable artifacts. Until a Definition <-> QuestionSet link
    -- table is added (deferred to Stage 4 planning per BRD Part 2
    -- Sec 5), we leave the questions snapshot as an empty JSON array.
    -- Downstream execution code can safely treat NULL / empty as
    -- 'no questions bound at this time'.
    DECLARE @questions_json NVARCHAR(MAX) = N'[]';

    -- Evidence config snapshot
    DECLARE @evidence_json NVARCHAR(MAX);
    SELECT @evidence_json = (
        SELECT ec.org_assurance_evidence_config_id AS evidenceConfigId,
               ec.evidence_label                    AS label,
               ec.description                       AS description,
               ec.evidence_type_code                AS typeCode,
               ec.evidence_type_name                AS typeName,
               ec.collection_method_code            AS collectionMethodCode,
               ec.collection_method_name            AS collectionMethodName,
               ec.is_mandatory                      AS isMandatory,
               ec.validity_days                     AS validityDays,
               ec.expiry_warning_days               AS expiryWarningDays,
               ec.display_order                     AS displayOrder
        FROM grac_practice.org_assurance_evidence_config ec
        WHERE ec.org_assurance_definition_version_id = @version_id
          AND ec.organization_id = @organization_id
          AND ec.is_active = 1
        ORDER BY ec.display_order, ec.org_assurance_evidence_config_id
        FOR JSON PATH
    );

    -- Workflow config snapshot
    DECLARE @workflow_json NVARCHAR(MAX);
    SELECT @workflow_json = (
        SELECT w.org_assurance_workflow_config_id AS workflowConfigId,
               w.workflow_template_code            AS templateCode,
               w.workflow_template_name            AS templateName,
               w.workflow_name                     AS workflowName,
               w.description                       AS description,
               w.total_sla_days                    AS totalSlaDays,
               (SELECT st.org_assurance_workflow_stage_id AS stageId,
                       st.stage_order                       AS [order],
                       st.stage_code                        AS code,
                       st.stage_name                        AS name,
                       st.stage_type                        AS type,
                       st.assigned_role_id                  AS roleId,
                       st.assigned_role_name                AS roleName,
                       st.assigned_employee_id              AS employeeId,
                       st.assigned_employee_name            AS employeeName,
                       st.sla_days                          AS slaDays,
                       st.escalation_role_id                AS escalationRoleId,
                       st.escalation_role_name              AS escalationRoleName,
                       st.escalation_after_days             AS escalationAfterDays,
                       st.instructions                      AS instructions
                FROM grac_practice.org_assurance_workflow_stage st
                WHERE st.org_assurance_workflow_config_id = w.org_assurance_workflow_config_id
                  AND st.is_active = 1
                ORDER BY st.stage_order, st.org_assurance_workflow_stage_id
                FOR JSON PATH) AS stages
        FROM grac_practice.org_assurance_workflow_config w
        WHERE w.org_assurance_definition_version_id = @version_id
          AND w.organization_id = @organization_id
          AND w.is_active = 1
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    -- Scoring config snapshot
    DECLARE @scoring_json NVARCHAR(MAX);
    SELECT @scoring_json = (
        SELECT sc.org_assurance_scoring_config_id AS scoringConfigId,
               sc.scoring_model_code               AS modelCode,
               sc.scoring_model_name               AS modelName,
               sc.scoring_model_type               AS modelType,
               sc.max_score                        AS maxScore,
               sc.pass_threshold                   AS passThreshold,
               sc.warning_threshold                AS warningThreshold,
               sc.fail_threshold                   AS failThreshold,
               sc.description                      AS description,
               (SELECT b.org_assurance_scoring_band_id AS bandId,
                       b.band_order                     AS [order],
                       b.band_code                      AS code,
                       b.band_name                      AS name,
                       b.min_score                      AS minScore,
                       b.max_score                      AS maxScore,
                       b.outcome_code                   AS outcomeCode,
                       b.color_hex                      AS colorHex,
                       b.description                    AS description
                FROM grac_practice.org_assurance_scoring_band b
                WHERE b.org_assurance_scoring_config_id = sc.org_assurance_scoring_config_id
                  AND b.is_active = 1
                ORDER BY b.band_order, b.org_assurance_scoring_band_id
                FOR JSON PATH) AS bands
        FROM grac_practice.org_assurance_scoring_config sc
        WHERE sc.org_assurance_definition_version_id = @version_id
          AND sc.organization_id = @organization_id
          AND sc.is_active = 1
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

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
        @owner_employee_id, @owner_display_name, @assigned_team_name,
        @planned_start_dt, @planned_end_dt,
        ISNULL(@scope_res_total, 0), 0,
        @notes,
        1, @active_record_status_id, @actor, SYSUTCDATETIME());

    SET @execution_id_out = SCOPE_IDENTITY();

    -- Snapshot entities from the scope resolution.
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

    -- Refresh total from what actually landed (defensive -- the header
    -- was seeded from the resolution's precomputed total).
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

    -- Advisory history log directly into the definition history
    -- table (from 069). action_code stays under 40 chars.
    IF OBJECT_ID('grac_practice.org_assurance_definition_history','U') IS NOT NULL
    BEGIN
        DECLARE @history_note NVARCHAR(1000) =
            N'Materialized execution #' + CAST(@execution_id_out AS NVARCHAR(20))
            + N' (' + @execution_code + N') from scope resolution #'
            + CAST(@scope_resolution_id AS NVARCHAR(20))
            + N' -- ' + CAST(@actual_total AS NVARCHAR(20)) + N' entities.';
        BEGIN TRY
            INSERT INTO grac_practice.org_assurance_definition_history(
                org_assurance_definition_id, org_assurance_definition_version_id,
                organization_id, action_code, reason_text,
                actor_display_name, entered_by)
            VALUES(
                @definition_id, @version_id,
                @organization_id, N'EXEC_MATERIALIZED', @history_note,
                @actor, @actor);
        END TRY
        BEGIN CATCH
            -- history is advisory; never let it fail the transaction
        END CATCH
    END

    COMMIT;

    -- Return the new execution row (for API convenience).
    SELECT org_assurance_execution_id AS ExecutionId,
           execution_code             AS ExecutionCode,
           execution_name             AS ExecutionName,
           total_entity_count         AS TotalEntityCount
    FROM grac_practice.org_assurance_execution
    WHERE org_assurance_execution_id = @execution_id_out;
END
GO

-- =====================================================================
-- Shared lifecycle transition helper
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_transition
    @organization_id     BIGINT,
    @execution_id        BIGINT,
    @expected_from_codes NVARCHAR(200),  -- comma-separated allowed source codes
    @to_code             NVARCHAR(60),
    @stamp_start         BIT           = 0,
    @stamp_end           BIT           = 0,
    @actor               NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;

    DECLARE @to_id INT, @current_code NVARCHAR(60), @exec_org BIGINT;

    SELECT @to_id = org_assurance_execution_status_id
    FROM grac_practice.org_assurance_execution_status_master
    WHERE status_code = @to_code;
    IF @to_id IS NULL
        THROW 54025, 'Unknown target status_code in execution transition.', 1;

    SELECT @exec_org      = e.organization_id,
           @current_code  = s.status_code
    FROM grac_practice.org_assurance_execution e
    JOIN grac_practice.org_assurance_execution_status_master s
         ON s.org_assurance_execution_status_id = e.execution_status_id
    WHERE e.org_assurance_execution_id = @execution_id
      AND e.is_active = 1;

    IF @exec_org IS NULL      THROW 54010, 'Execution not found or not accessible in this organization.', 1;
    IF @exec_org <> @organization_id
        THROW 54010, 'Execution not found or not accessible in this organization.', 1;

    -- Split expected_from into rows.
    DECLARE @allowed TABLE(code NVARCHAR(60));
    INSERT INTO @allowed(code)
    SELECT LTRIM(RTRIM(value))
    FROM STRING_SPLIT(@expected_from_codes, ',')
    WHERE LTRIM(RTRIM(value)) <> '';

    IF NOT EXISTS (SELECT 1 FROM @allowed WHERE code = @current_code)
        THROW 54026, 'Illegal execution lifecycle transition -- current status does not match the expected source.', 1;

    UPDATE grac_practice.org_assurance_execution
    SET execution_status_id = @to_id,
        actual_start_dt     = CASE
            WHEN @stamp_start = 1 AND actual_start_dt IS NULL
            THEN SYSUTCDATETIME() ELSE actual_start_dt END,
        actual_end_dt       = CASE
            WHEN @stamp_end = 1 AND actual_end_dt IS NULL
            THEN SYSUTCDATETIME() ELSE actual_end_dt END,
        updated_by          = @actor,
        updated_dt          = SYSUTCDATETIME()
    WHERE org_assurance_execution_id = @execution_id;
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

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_submit
    @organization_id BIGINT, @execution_id BIGINT, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_execution_transition
        @organization_id = @organization_id, @execution_id = @execution_id,
        @expected_from_codes = N'InProgress',
        @to_code = N'Submitted',
        @stamp_start = 0, @stamp_end = 0, @actor = @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_review
    @organization_id BIGINT, @execution_id BIGINT, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_execution_transition
        @organization_id = @organization_id, @execution_id = @execution_id,
        @expected_from_codes = N'Submitted',
        @to_code = N'Reviewed',
        @stamp_start = 0, @stamp_end = 0, @actor = @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_approve
    @organization_id BIGINT, @execution_id BIGINT, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_execution_transition
        @organization_id = @organization_id, @execution_id = @execution_id,
        @expected_from_codes = N'Reviewed,Submitted',
        @to_code = N'Approved',
        @stamp_start = 0, @stamp_end = 0, @actor = @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_close
    @organization_id BIGINT, @execution_id BIGINT, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_execution_transition
        @organization_id = @organization_id, @execution_id = @execution_id,
        @expected_from_codes = N'Approved',
        @to_code = N'Closed',
        @stamp_start = 0, @stamp_end = 1, @actor = @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_cancel
    @organization_id BIGINT, @execution_id BIGINT, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_execution_transition
        @organization_id = @organization_id, @execution_id = @execution_id,
        @expected_from_codes = N'Planned,InProgress,Submitted,Reviewed',
        @to_code = N'Cancelled',
        @stamp_start = 0, @stamp_end = 1, @actor = @actor;
END
GO

-- =====================================================================
-- sp_org_assurance_execution_delete  (soft; non-terminal + non-in-progress)
--   Terminal executions (Approved/Closed) are auditable evidence and
--   cannot be deleted -- only Cancelled can be soft-removed.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_delete
    @organization_id BIGINT,
    @execution_id    BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;

    DECLARE @exec_org BIGINT, @status_code NVARCHAR(60);
    SELECT @exec_org    = e.organization_id,
           @status_code = s.status_code
    FROM grac_practice.org_assurance_execution e
    JOIN grac_practice.org_assurance_execution_status_master s
         ON s.org_assurance_execution_status_id = e.execution_status_id
    WHERE e.org_assurance_execution_id = @execution_id
      AND e.is_active = 1;

    IF @exec_org IS NULL      THROW 54010, 'Execution not found or not accessible in this organization.', 1;
    IF @exec_org <> @organization_id
        THROW 54010, 'Execution not found or not accessible in this organization.', 1;
    IF @status_code NOT IN (N'Planned', N'Cancelled')
        THROW 54027, 'Only Planned or Cancelled executions can be soft-deleted.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.org_assurance_execution_entity
    SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_execution_id = @execution_id AND is_active = 1;

    UPDATE grac_practice.org_assurance_execution
    SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_execution_id = @execution_id;

    COMMIT;
END
GO

PRINT '099 Organization Assurance Execution procedures deployed.';
GO
