-- =====================================================================
-- 084 Organization Assurance Workflow -- Stage 2 stored procedures
--
-- Depends on 083 (schema).
--
-- Procedures:
--   sp_org_assurance_admin_workflow_template_list
--       Defensive discovery of grac_new.assurance_workflow_template.
--       Same runtime column-name discovery as
--       sp_org_assurance_admin_category_list (072) and
--       sp_org_assurance_admin_question_type_list (077).
--
--   sp_org_assurance_workflow_stage_type_list
--       Fixed set: AUDITOR / REVIEWER / APPROVER / CUSTOM.
--
--   sp_org_assurance_organization_role_list
--       Pass-through of grac_practice.organization_role scoped to org.
--
--   sp_org_assurance_workflow_get
--       Header + stages for a definition version (3 result sets).
--
--   sp_org_assurance_workflow_save
--       Full replacement (header + stages) driven by JSON.
--       Draft-only enforcement.
--
-- Rollback: 084_org_assurance_workflow_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_workflow_config','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_workflow_stage','U')  IS NULL
BEGIN
    RAISERROR('084: run 083 schema first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_org_assurance_admin_workflow_template_list
--   Same defensive pattern used elsewhere in this module.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_admin_workflow_template_list
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('grac_new.assurance_workflow_template','U') IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)       AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @tbl_id INT = OBJECT_ID('grac_new.assurance_workflow_template');
    DECLARE @id_col NVARCHAR(128), @code_col NVARCHAR(128),
            @name_col NVARCHAR(128), @desc_col NVARCHAR(128),
            @status_col NVARCHAR(128);

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @id_col = name FROM candidates
    WHERE name IN (N'assurance_workflow_template_id', N'workflow_template_id', N'template_id', N'id')
    ORDER BY CASE name
        WHEN N'assurance_workflow_template_id' THEN 1
        WHEN N'workflow_template_id'           THEN 2
        WHEN N'template_id'                    THEN 3
        WHEN N'id'                             THEN 4
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @code_col = name FROM candidates
    WHERE name IN (N'assurance_workflow_template_code', N'workflow_template_code',
                   N'template_code', N'code')
    ORDER BY CASE name
        WHEN N'assurance_workflow_template_code' THEN 1
        WHEN N'workflow_template_code'           THEN 2
        WHEN N'template_code'                    THEN 3
        WHEN N'code'                             THEN 4
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @name_col = name FROM candidates
    WHERE name IN (N'assurance_workflow_template_name', N'workflow_template_name',
                   N'template_name', N'name', N'label', N'display_name')
    ORDER BY CASE name
        WHEN N'assurance_workflow_template_name' THEN 1
        WHEN N'workflow_template_name'           THEN 2
        WHEN N'template_name'                    THEN 3
        WHEN N'name'                             THEN 4
        WHEN N'label'                            THEN 5
        WHEN N'display_name'                     THEN 6
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @desc_col = name FROM candidates
    WHERE name IN (N'description', N'notes', N'remarks');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @status_col = name FROM candidates
    WHERE name IN (N'status', N'is_active', N'active_flag');

    IF @id_col IS NULL OR @name_col IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)       AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT ' + QUOTENAME(@id_col) + N' AS Id,
               ' + COALESCE(QUOTENAME(@code_col), N'CAST(NULL AS NVARCHAR(120))') + N' AS Code,
               ' + QUOTENAME(@name_col) + N' AS Name,
               ' + COALESCE(QUOTENAME(@desc_col), N'CAST(NULL AS NVARCHAR(1000))') + N' AS Description
        FROM grac_new.assurance_workflow_template';

    IF @status_col = N'status'
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = N''Active''';
    ELSE IF @status_col IN (N'is_active', N'active_flag')
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = 1';

    SET @sql = @sql + N' ORDER BY ' + QUOTENAME(@name_col) + N';';

    EXEC sp_executesql @sql;
END
GO

-- =====================================================================
-- sp_org_assurance_workflow_stage_type_list  (fixed vocabulary)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_workflow_stage_type_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT StageTypeCode, StageTypeName, DisplayOrder
    FROM (VALUES
        (N'AUDITOR',  N'Auditor',  1),
        (N'REVIEWER', N'Reviewer', 2),
        (N'APPROVER', N'Approver', 3),
        (N'CUSTOM',   N'Custom',   4)
    ) t(StageTypeCode, StageTypeName, DisplayOrder)
    ORDER BY DisplayOrder;
END
GO

-- =====================================================================
-- sp_org_assurance_organization_role_list  (pass-through of PM master)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_organization_role_list
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 53601, 'organization_id is required.', 1;

    IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)         AS RoleId,
               CAST(NULL AS NVARCHAR(120))  AS RoleName
        WHERE 1 = 0;
        RETURN;
    END

    SELECT r.role_id   AS RoleId,
           r.role_name AS RoleName
    FROM grac_practice.organization_role r
    WHERE r.organization_id = @organization_id
      AND r.status = N'Active'
    ORDER BY r.role_name;
END
GO

-- =====================================================================
-- sp_org_assurance_workflow_get
--   Returns 3 result sets: header context, workflow config, stages.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_workflow_get
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

    -- 1) Header (mirrors scope / evidence header shape).
    SELECT @definition_id       AS DefinitionId,
           @version_id          AS VersionId,
           @current_version_id  AS CurrentVersionId,
           @current_status_code AS CurrentStatusCode,
           CAST(CASE WHEN @current_status_code = N'Draft'
                     AND @version_id = @current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS IsEditable;

    -- 2) Workflow config row (0 or 1).
    SELECT wc.org_assurance_workflow_config_id AS WorkflowConfigId,
           wc.workflow_template_id              AS WorkflowTemplateId,
           wc.workflow_template_code            AS WorkflowTemplateCode,
           wc.workflow_template_name            AS WorkflowTemplateName,
           wc.workflow_name                     AS WorkflowName,
           wc.description                       AS Description,
           wc.total_sla_days                    AS TotalSlaDays
    FROM grac_practice.org_assurance_workflow_config wc
    WHERE wc.organization_id = @organization_id
      AND wc.org_assurance_definition_version_id = @version_id
      AND wc.is_active = 1;

    -- 3) Stages.
    SELECT ws.org_assurance_workflow_stage_id AS StageId,
           ws.stage_order                     AS StageOrder,
           ws.stage_code                      AS StageCode,
           ws.stage_name                      AS StageName,
           ws.stage_type                      AS StageType,
           ws.assigned_role_id                AS AssignedRoleId,
           ws.assigned_role_name              AS AssignedRoleName,
           ws.assigned_employee_id            AS AssignedEmployeeId,
           ws.assigned_employee_name          AS AssignedEmployeeName,
           ws.sla_days                        AS SlaDays,
           ws.escalation_role_id              AS EscalationRoleId,
           ws.escalation_role_name            AS EscalationRoleName,
           ws.escalation_after_days           AS EscalationAfterDays,
           ws.instructions                    AS Instructions
    FROM grac_practice.org_assurance_workflow_stage ws
    JOIN grac_practice.org_assurance_workflow_config wc
         ON wc.org_assurance_workflow_config_id = ws.org_assurance_workflow_config_id
    WHERE wc.organization_id = @organization_id
      AND wc.org_assurance_definition_version_id = @version_id
      AND ws.is_active = 1
    ORDER BY ws.stage_order, ws.org_assurance_workflow_stage_id;
END
GO

-- =====================================================================
-- sp_org_assurance_workflow_save
--   Full-replacement save. Draft-only. Wipes existing header+stages
--   for this version and reinserts from @header_json + @stages_json.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_workflow_save
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @header_json     NVARCHAR(MAX),
    @stages_json     NVARCHAR(MAX),
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;
    IF @header_json IS NULL SET @header_json = N'{}';
    IF @stages_json IS NULL SET @stages_json = N'[]';
    IF ISJSON(@header_json) = 0 THROW 53703, 'header_json is not a valid JSON document.', 1;
    IF ISJSON(@stages_json) = 0 THROW 53703, 'stages_json is not a valid JSON document.', 1;

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
    IF @current_version_id IS NULL
        THROW 53611, 'Definition has no current version.', 1;
    IF @current_status_code <> N'Draft'
        THROW 53608, 'Workflow config can only be edited when the current version is Draft.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    -- Header payload.
    DECLARE @workflow_template_id      BIGINT,
            @workflow_template_code    NVARCHAR(120),
            @workflow_template_name    NVARCHAR(200),
            @workflow_name             NVARCHAR(200),
            @description               NVARCHAR(MAX),
            @total_sla_days            INT;

    SELECT @workflow_template_id   = TRY_CAST(JSON_VALUE(@header_json, '$.workflowTemplateId') AS BIGINT),
           @workflow_template_code = JSON_VALUE(@header_json, '$.workflowTemplateCode'),
           @workflow_template_name = JSON_VALUE(@header_json, '$.workflowTemplateName'),
           @workflow_name          = JSON_VALUE(@header_json, '$.workflowName'),
           @description            = JSON_VALUE(@header_json, '$.description'),
           @total_sla_days         = TRY_CAST(JSON_VALUE(@header_json, '$.totalSlaDays') AS INT);

    BEGIN TRAN;

    -- Wipe existing config for this version (stages first).
    DELETE ws
      FROM grac_practice.org_assurance_workflow_stage ws
      JOIN grac_practice.org_assurance_workflow_config wc
           ON wc.org_assurance_workflow_config_id = ws.org_assurance_workflow_config_id
     WHERE wc.org_assurance_definition_version_id = @current_version_id
       AND wc.organization_id = @organization_id;

    DELETE FROM grac_practice.org_assurance_workflow_config
     WHERE org_assurance_definition_version_id = @current_version_id
       AND organization_id = @organization_id;

    -- Insert new header.
    INSERT INTO grac_practice.org_assurance_workflow_config
        (org_assurance_definition_id, org_assurance_definition_version_id, organization_id,
         workflow_template_id, workflow_template_code, workflow_template_name,
         workflow_name, description, total_sla_days,
         is_active, record_status_id, entered_by, entered_dt)
    VALUES
        (@definition_id, @current_version_id, @organization_id,
         @workflow_template_id, @workflow_template_code, @workflow_template_name,
         @workflow_name, @description, @total_sla_days,
         1, @active_record_status_id, @actor, SYSUTCDATETIME());

    DECLARE @config_id BIGINT = SCOPE_IDENTITY();

    -- Insert stages.
    INSERT INTO grac_practice.org_assurance_workflow_stage
        (org_assurance_workflow_config_id, org_assurance_definition_version_id, organization_id,
         stage_order, stage_code, stage_name, stage_type,
         assigned_role_id, assigned_role_name,
         assigned_employee_id, assigned_employee_name,
         sla_days,
         escalation_role_id, escalation_role_name, escalation_after_days,
         instructions,
         is_active, entered_by, entered_dt)
    SELECT @config_id, @current_version_id, @organization_id,
           x.stageOrder,
           x.stageCode,
           x.stageName,
           CASE WHEN x.stageType IN (N'AUDITOR', N'REVIEWER', N'APPROVER', N'CUSTOM')
                THEN x.stageType ELSE N'CUSTOM' END,
           x.assignedRoleId,     x.assignedRoleName,
           x.assignedEmployeeId, x.assignedEmployeeName,
           x.slaDays,
           x.escalationRoleId,   x.escalationRoleName, x.escalationAfterDays,
           x.instructions,
           1, @actor, SYSUTCDATETIME()
    FROM OPENJSON(@stages_json)
    WITH (
        stageOrder            INT           '$.stageOrder',
        stageCode             NVARCHAR(60)  '$.stageCode',
        stageName             NVARCHAR(200) '$.stageName',
        stageType             NVARCHAR(30)  '$.stageType',
        assignedRoleId        BIGINT        '$.assignedRoleId',
        assignedRoleName      NVARCHAR(200) '$.assignedRoleName',
        assignedEmployeeId    BIGINT        '$.assignedEmployeeId',
        assignedEmployeeName  NVARCHAR(240) '$.assignedEmployeeName',
        slaDays               INT           '$.slaDays',
        escalationRoleId      BIGINT        '$.escalationRoleId',
        escalationRoleName    NVARCHAR(200) '$.escalationRoleName',
        escalationAfterDays   INT           '$.escalationAfterDays',
        instructions          NVARCHAR(MAX) '$.instructions'
    ) x
    WHERE x.stageName IS NOT NULL AND LEN(LTRIM(RTRIM(x.stageName))) > 0;

    -- History log.
    DECLARE @current_status_id INT = (
        SELECT current_status_id FROM grac_practice.org_assurance_definition
        WHERE org_assurance_definition_id = @definition_id);

    INSERT INTO grac_practice.org_assurance_definition_history
        (org_assurance_definition_id, org_assurance_definition_version_id,
         organization_id, action_code, from_status_id, to_status_id,
         reason_text, actor_display_name, entered_by)
    VALUES
        (@definition_id, @current_version_id, @organization_id,
         N'WORKFLOW_EDIT', @current_status_id, @current_status_id,
         N'Workflow config saved', @actor, @actor);

    UPDATE grac_practice.org_assurance_definition
    SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_definition_id = @definition_id;

    COMMIT;
END
GO

PRINT '084 Organization Assurance Workflow procedures deployed.';
GO
