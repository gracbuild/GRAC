-- =====================================================================
-- 120 -- Execution Owner + Entity Auditor role+employee hybrid
--         (Q1-A + Q2 staged rollout, Stage 4c continuation)
--
-- Rewrites 4 procs from 099 + adds 1 new SP:
--   * sp_org_assurance_execution_list        -- adds OwnerRoleId + OwnerRoleName
--   * sp_org_assurance_execution_get         -- adds OwnerRoleId + OwnerRoleName
--   * sp_org_assurance_execution_entity_list -- adds AssignedAuditorRoleId + Name
--   * sp_org_assurance_execution_materialize -- 2 new owner-role params + hybrid resolver
--   * sp_org_assurance_execution_entity_auditor_assign  -- NEW; per-entity auditor set
--
-- Resolver semantics (same as 116a Observation / 119 Definition):
--   * role_id given, role_name empty  -> lookup role_name from organization_role
--   * role_id given, employee_id NULL -> auto-snapshot first active holder
--     via sp_org_role_primary_holder_pick (Q1-A auto-fill)
--   * employee_id given, role_id NULL -> pull role from employee.role_id +
--     snapshot role_name from organization_role
--   * employee_id given, display_name empty -> snapshot from employee_name
--
-- Column dependencies (must exist -- provided by 115):
--   grac_practice.org_assurance_execution.owner_role_id      BIGINT NULL
--   grac_practice.org_assurance_execution.owner_role_name    NVARCHAR(120) NULL
--   grac_practice.org_assurance_execution_entity.assigned_auditor_role_id   BIGINT NULL
--   grac_practice.org_assurance_execution_entity.assigned_auditor_role_name NVARCHAR(120) NULL
--
-- THROW reason-code range: 54080-54089 (auditor-assign errors).
-- =====================================================================
SET NOCOUNT ON;
GO

IF COL_LENGTH('grac_practice.org_assurance_execution','owner_role_id') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_execution','owner_role_name') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_execution_entity','assigned_auditor_role_id') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_execution_entity','assigned_auditor_role_name') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_role_primary_holder_pick','P') IS NULL
BEGIN
    RAISERROR('120 preflight failed: apply 115 (schema) + 117 (helper SPs) first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_org_assurance_execution_list -- adds Owner role columns
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
               e.owner_role_id,          -- 120
               e.owner_role_name,        -- 120
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
               e.owner_role_id,          -- 120
               e.owner_role_name,        -- 120
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
           owner_role_id                         AS OwnerRoleId,        -- 120
           owner_role_name                       AS OwnerRoleName,      -- 120
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
-- sp_org_assurance_execution_get -- adds Owner role columns
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
-- sp_org_assurance_execution_entity_list -- adds Auditor role columns
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
               ee.assigned_auditor_role_id,          -- 120
               ee.assigned_auditor_role_name,        -- 120
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
               ee.assigned_auditor_role_id,          -- 120
               ee.assigned_auditor_role_name,        -- 120
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
           assigned_auditor_role_id           AS AssignedAuditorRoleId,      -- 120
           assigned_auditor_role_name         AS AssignedAuditorRoleName,    -- 120
           assigned_auditor_employee_id       AS AssignedAuditorEmployeeId,
           assigned_auditor_name              AS AssignedAuditorName
    FROM base
    ORDER BY dimension_code, entity_name, entity_code, org_assurance_execution_entity_id
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- sp_org_assurance_execution_materialize -- adds 2 owner-role params
--   + hybrid resolver + persists owner_role_id + owner_role_name.
--   Full body preserved from 099; only the resolver + INSERT list changed.
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

-- =====================================================================
-- sp_org_assurance_execution_entity_auditor_assign  (NEW, 120)
--   Assigns a per-entity auditor via role+employee hybrid.
--   Guards: org isolation + entity belongs to execution + execution
--   not in a terminal state (Cancelled / Closed).
--   THROW range 54080-54089.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_entity_auditor_assign
    @organization_id      BIGINT,
    @execution_id         BIGINT,
    @execution_entity_id  BIGINT,
    @auditor_role_id      BIGINT        = NULL,
    @auditor_role_name    NVARCHAR(120) = NULL,
    @auditor_employee_id  BIGINT        = NULL,
    @auditor_display_name NVARCHAR(240) = NULL,
    @actor                NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @execution_id IS NULL OR @execution_entity_id IS NULL
        THROW 54080, 'organization_id, execution_id and execution_entity_id are required.', 1;

    -- Org + relationship isolation.
    IF NOT EXISTS (
        SELECT 1
        FROM grac_practice.org_assurance_execution_entity ee
        JOIN grac_practice.org_assurance_execution e
             ON e.org_assurance_execution_id = ee.org_assurance_execution_id
        WHERE ee.org_assurance_execution_entity_id = @execution_entity_id
          AND ee.org_assurance_execution_id        = @execution_id
          AND ee.organization_id                   = @organization_id
          AND e.organization_id                    = @organization_id
          AND ee.is_active = 1
          AND e.is_active  = 1)
        THROW 54081, 'Execution entity not found in this execution/organization.', 1;

    -- Guard: cannot reassign auditors on a terminal execution.
    IF EXISTS (
        SELECT 1
        FROM grac_practice.org_assurance_execution e
        JOIN grac_practice.org_assurance_execution_status_master s
             ON s.org_assurance_execution_status_id = e.execution_status_id
        WHERE e.org_assurance_execution_id = @execution_id
          AND s.is_terminal = 1)
        THROW 54082, 'Cannot reassign auditor on a terminal execution (Closed / Cancelled).', 1;

    -- ==========================================================
    -- 120 hybrid ownership resolver -- Auditor
    -- ==========================================================
    IF @auditor_role_id IS NOT NULL
       AND (@auditor_role_name IS NULL OR LEN(LTRIM(RTRIM(@auditor_role_name))) = 0)
        SELECT @auditor_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @auditor_role_id AND organization_id = @organization_id;

    IF @auditor_role_id IS NOT NULL AND @auditor_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id   = @organization_id,
             @role_id           = @auditor_role_id,
             @employee_id_out   = @auditor_employee_id  OUTPUT,
             @employee_name_out = @auditor_display_name OUTPUT;

    IF @auditor_employee_id IS NOT NULL AND @auditor_role_id IS NULL
    BEGIN
        SELECT @auditor_role_id   = e.role_id,
               @auditor_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @auditor_employee_id
          AND e.organization_id = @organization_id;
    END

    IF @auditor_employee_id IS NOT NULL
       AND (@auditor_display_name IS NULL OR LEN(LTRIM(RTRIM(@auditor_display_name))) = 0)
        SELECT @auditor_display_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @auditor_employee_id;

    UPDATE grac_practice.org_assurance_execution_entity
    SET assigned_auditor_role_id      = @auditor_role_id,
        assigned_auditor_role_name    = @auditor_role_name,
        assigned_auditor_employee_id  = @auditor_employee_id,
        assigned_auditor_name         = @auditor_display_name,
        updated_by                    = @actor,
        updated_dt                    = SYSUTCDATETIME()
    WHERE org_assurance_execution_entity_id = @execution_entity_id;

    SELECT CAST(1 AS BIT) AS Success,
           @execution_entity_id AS ExecutionEntityId;
END
GO

PRINT '120: Execution Owner + Entity Auditor role+employee hybrid applied.';
GO
