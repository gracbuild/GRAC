-- =====================================================================
-- 179 Organization SLA Config -- stored procedures
--
-- Depends on 178 (schema) and 117 (sp_org_role_holders_list).
--
-- Procedures:
--   sp_ctrl_sla_master_list
--       Defensive column-name discovery over grac_new.sla_master
--       (Control Management). Same shape used by
--       sp_org_assurance_admin_workflow_template_list (084).
--
--   sp_org_sla_process_type_list
--       Fixed catalog from sla_process_type_master. Extensible via
--       INSERT to master, no proc change needed.
--
--   sp_org_sla_config_list
--       Filtered list of adopted SLA configs for an organization.
--
--   sp_org_sla_config_get
--       3 result sets (header, notify roles, process bindings) for
--       one org_sla_config_id.
--
--   sp_org_sla_config_upsert
--       Adopt a new SLA master into an org OR update an existing
--       adoption's thresholds / notes.
--
--   sp_org_sla_config_notify_role_set
--       Full replacement of notify roles for a config from JSON.
--       Snapshots role_name at save time.
--
--   sp_org_sla_process_binding_set
--       Full replacement of process bindings for a config from JSON.
--
--   sp_org_sla_config_for_process
--       Resolver used by task/gap/exception sweeps: given (org,
--       process_type_code, scope_ref_id), returns the best matching
--       config plus its notify roles (2 result sets). Match priority
--       is scope-specific first, then default (scope_ref IS NULL).
--
-- Rollback: 179_org_sla_config_procs_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_sla_config','U') IS NULL
   OR OBJECT_ID('grac_practice.org_sla_config_notify_role','U') IS NULL
   OR OBJECT_ID('grac_practice.org_sla_process_binding','U') IS NULL
   OR OBJECT_ID('grac_practice.sla_process_type_master','U') IS NULL
BEGIN
    RAISERROR('179: run 178 schema first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_ctrl_sla_master_list
--   Defensive discovery of grac_new.sla_master. Same pattern used by
--   sp_org_assurance_admin_workflow_template_list (084) -- we don't
--   assume column names in the Control Management schema because it
--   ships and evolves separately.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_ctrl_sla_master_list
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('grac_new.sla_master','U') IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)        AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description,
               CAST(NULL AS INT)           AS TotalSlaDays
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @tbl_id INT = OBJECT_ID('grac_new.sla_master');
    DECLARE @id_col NVARCHAR(128), @code_col NVARCHAR(128),
            @name_col NVARCHAR(128), @desc_col NVARCHAR(128),
            @days_col NVARCHAR(128), @status_col NVARCHAR(128);

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @id_col = name FROM candidates
    WHERE name IN (N'sla_master_id', N'sla_id', N'id')
    ORDER BY CASE name
        WHEN N'sla_master_id' THEN 1
        WHEN N'sla_id'        THEN 2
        WHEN N'id'            THEN 3
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @code_col = name FROM candidates
    WHERE name IN (N'sla_master_code', N'sla_code', N'code')
    ORDER BY CASE name
        WHEN N'sla_master_code' THEN 1
        WHEN N'sla_code'        THEN 2
        WHEN N'code'            THEN 3
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @name_col = name FROM candidates
    WHERE name IN (N'sla_master_name', N'sla_name', N'name', N'label', N'display_name')
    ORDER BY CASE name
        WHEN N'sla_master_name' THEN 1
        WHEN N'sla_name'        THEN 2
        WHEN N'name'            THEN 3
        WHEN N'label'           THEN 4
        WHEN N'display_name'    THEN 5
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @desc_col = name FROM candidates
    WHERE name IN (N'description', N'notes', N'remarks');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @days_col = name FROM candidates
    WHERE name IN (N'total_sla_days', N'sla_days', N'target_days', N'duration_days');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @status_col = name FROM candidates
    WHERE name IN (N'status', N'is_active', N'active_flag');

    IF @id_col IS NULL OR @name_col IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)        AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description,
               CAST(NULL AS INT)           AS TotalSlaDays
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT ' + QUOTENAME(@id_col) + N' AS Id,
               ' + COALESCE(QUOTENAME(@code_col), N'CAST(NULL AS NVARCHAR(120))') + N' AS Code,
               ' + QUOTENAME(@name_col) + N' AS Name,
               ' + COALESCE(QUOTENAME(@desc_col), N'CAST(NULL AS NVARCHAR(1000))') + N' AS Description,
               ' + COALESCE(QUOTENAME(@days_col), N'CAST(NULL AS INT)') + N' AS TotalSlaDays
        FROM grac_new.sla_master';

    IF @status_col = N'status'
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = N''Active''';
    ELSE IF @status_col IN (N'is_active', N'active_flag')
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = 1';

    SET @sql = @sql + N' ORDER BY ' + QUOTENAME(@name_col) + N';';

    EXEC sp_executesql @sql;
END
GO

-- =====================================================================
-- sp_org_sla_process_type_list  (catalog for UI dropdown)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_process_type_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT sla_process_type_id AS ProcessTypeId,
           process_type_code   AS ProcessTypeCode,
           process_type_name   AS ProcessTypeName,
           description         AS Description,
           scope_ref_hint      AS ScopeRefHint,
           display_order       AS DisplayOrder
    FROM grac_practice.sla_process_type_master
    WHERE is_active = 1
    ORDER BY display_order, process_type_name;
END
GO

-- =====================================================================
-- sp_org_sla_config_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_config_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @page            INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 53780, 'organization_id is required.', 1;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    ;WITH filtered AS (
        SELECT c.org_sla_config_id,
               c.organization_id,
               c.sla_master_id,
               c.sla_master_code,
               c.sla_master_name,
               c.total_sla_days,
               c.warning_before_due_days,
               c.escalation_after_due_days,
               c.notes,
               c.is_active,
               c.entered_by, c.entered_dt, c.updated_by, c.updated_dt,
               (SELECT COUNT(*)
                  FROM grac_practice.org_sla_config_notify_role n
                 WHERE n.org_sla_config_id = c.org_sla_config_id
                   AND n.is_active = 1) AS notify_role_count,
               (SELECT COUNT(*)
                  FROM grac_practice.org_sla_process_binding b
                 WHERE b.org_sla_config_id = c.org_sla_config_id
                   AND b.is_active = 1) AS process_binding_count
        FROM grac_practice.org_sla_config c
        WHERE c.organization_id = @organization_id
          AND c.is_active       = 1
          AND (@search IS NULL
               OR c.sla_master_name LIKE '%' + @search + '%'
               OR c.sla_master_code LIKE '%' + @search + '%')
    )
    SELECT
        org_sla_config_id         AS OrgSlaConfigId,
        organization_id           AS OrganizationId,
        sla_master_id             AS SlaMasterId,
        sla_master_code           AS SlaMasterCode,
        sla_master_name           AS SlaMasterName,
        total_sla_days            AS TotalSlaDays,
        warning_before_due_days   AS WarningBeforeDueDays,
        escalation_after_due_days AS EscalationAfterDueDays,
        notes                     AS Notes,
        notify_role_count         AS NotifyRoleCount,
        process_binding_count     AS ProcessBindingCount,
        entered_by                AS EnteredBy,
        entered_dt                AS EnteredDt,
        updated_by                AS UpdatedBy,
        updated_dt                AS UpdatedDt,
        (SELECT COUNT(*) FROM filtered) AS TotalCount
    FROM filtered
    ORDER BY sla_master_name, org_sla_config_id
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- sp_org_sla_config_get
--   Returns 3 result sets:
--     1) Header
--     2) Notify roles (all events)
--     3) Process bindings
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_config_get
    @organization_id   BIGINT,
    @org_sla_config_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @org_sla_config_id IS NULL
        THROW 53781, 'organization_id and org_sla_config_id are required.', 1;

    -- Isolation guard: config must belong to the calling org.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_sla_config
        WHERE org_sla_config_id = @org_sla_config_id
          AND organization_id   = @organization_id)
        THROW 53782, 'SLA config not found for this organization.', 1;

    -- 1. Header
    SELECT
        c.org_sla_config_id         AS OrgSlaConfigId,
        c.organization_id           AS OrganizationId,
        c.sla_master_id             AS SlaMasterId,
        c.sla_master_code           AS SlaMasterCode,
        c.sla_master_name           AS SlaMasterName,
        c.total_sla_days            AS TotalSlaDays,
        c.warning_before_due_days   AS WarningBeforeDueDays,
        c.escalation_after_due_days AS EscalationAfterDueDays,
        c.notes                     AS Notes,
        c.entered_by                AS EnteredBy,
        c.entered_dt                AS EnteredDt,
        c.updated_by                AS UpdatedBy,
        c.updated_dt                AS UpdatedDt
    FROM grac_practice.org_sla_config c
    WHERE c.org_sla_config_id = @org_sla_config_id;

    -- 2. Notify roles
    SELECT
        n.org_sla_config_notify_role_id AS NotifyRoleId,
        n.notify_event_code             AS NotifyEventCode,
        n.role_id                       AS RoleId,
        n.role_name                     AS RoleName
    FROM grac_practice.org_sla_config_notify_role n
    WHERE n.org_sla_config_id = @org_sla_config_id
      AND n.is_active         = 1
    ORDER BY n.notify_event_code, n.role_name, n.role_id;

    -- 3. Process bindings
    SELECT
        b.org_sla_process_binding_id AS BindingId,
        b.process_type_code          AS ProcessTypeCode,
        pt.process_type_name         AS ProcessTypeName,
        b.process_scope_ref_id       AS ProcessScopeRefId,
        b.process_scope_label        AS ProcessScopeLabel
    FROM grac_practice.org_sla_process_binding b
    JOIN grac_practice.sla_process_type_master pt
         ON pt.process_type_code = b.process_type_code
    WHERE b.org_sla_config_id = @org_sla_config_id
      AND b.is_active         = 1
    ORDER BY pt.display_order, b.process_scope_ref_id;
END
GO

-- =====================================================================
-- sp_org_sla_config_upsert
--   Adopts a new SLA master into an org, or updates the thresholds /
--   notes of an existing adoption.
--
--   INSERT path: caller supplies @org_sla_config_id = NULL.
--   UPDATE path: caller supplies a non-null @org_sla_config_id that
--   belongs to the calling org.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_config_upsert
    @organization_id            BIGINT,
    @org_sla_config_id          BIGINT        = NULL,
    @sla_master_id              BIGINT,
    @sla_master_code            NVARCHAR(120) = NULL,
    @sla_master_name            NVARCHAR(200) = NULL,
    @total_sla_days             INT           = NULL,
    @warning_before_due_days    INT,
    @escalation_after_due_days  INT,
    @notes                      NVARCHAR(1000) = NULL,
    @actor                      NVARCHAR(100) = 'system',
    @out_org_sla_config_id      BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @sla_master_id IS NULL
        THROW 53783, 'organization_id and sla_master_id are required.', 1;
    IF @warning_before_due_days IS NULL OR @warning_before_due_days < 0
        THROW 53784, 'warning_before_due_days must be >= 0.', 1;
    IF @escalation_after_due_days IS NULL OR @escalation_after_due_days < 0
        THROW 53785, 'escalation_after_due_days must be >= 0.', 1;
    IF @total_sla_days IS NOT NULL AND @warning_before_due_days > @total_sla_days
        THROW 53786, 'warning_before_due_days cannot exceed total_sla_days.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    IF @org_sla_config_id IS NULL
    BEGIN
        -- Adoption path. Guard against duplicate active adoption for
        -- the same (org, sla_master).
        IF EXISTS (
            SELECT 1 FROM grac_practice.org_sla_config
            WHERE organization_id = @organization_id
              AND sla_master_id   = @sla_master_id
              AND is_active       = 1)
            THROW 53787,
                'This SLA master is already adopted for the organization. Update the existing configuration instead.', 1;

        INSERT INTO grac_practice.org_sla_config
            (organization_id, sla_master_id, sla_master_code, sla_master_name,
             total_sla_days, warning_before_due_days, escalation_after_due_days,
             notes, is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @sla_master_id, @sla_master_code, @sla_master_name,
             @total_sla_days, @warning_before_due_days, @escalation_after_due_days,
             @notes, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @out_org_sla_config_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        -- Update path. Isolation guard.
        IF NOT EXISTS (
            SELECT 1 FROM grac_practice.org_sla_config
            WHERE org_sla_config_id = @org_sla_config_id
              AND organization_id   = @organization_id
              AND is_active         = 1)
            THROW 53788, 'SLA config not found or not editable for this organization.', 1;

        UPDATE grac_practice.org_sla_config
        SET sla_master_code           = COALESCE(@sla_master_code, sla_master_code),
            sla_master_name           = COALESCE(@sla_master_name, sla_master_name),
            total_sla_days            = @total_sla_days,
            warning_before_due_days   = @warning_before_due_days,
            escalation_after_due_days = @escalation_after_due_days,
            notes                     = @notes,
            updated_by                = @actor,
            updated_dt                = SYSUTCDATETIME()
        WHERE org_sla_config_id = @org_sla_config_id;

        SET @out_org_sla_config_id = @org_sla_config_id;
    END

    COMMIT;
END
GO

-- =====================================================================
-- sp_org_sla_config_notify_role_set
--   Full replacement. @roles_json:
--     [ { "notifyEventCode": "WARNING",    "roleId": 12 },
--       { "notifyEventCode": "ESCALATION", "roleId": 15 }, ... ]
--   Role name is snapshotted from grac_practice.organization_role at
--   save time so the config screen stays readable even if the role is
--   later renamed.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_config_notify_role_set
    @organization_id   BIGINT,
    @org_sla_config_id BIGINT,
    @roles_json        NVARCHAR(MAX),
    @actor             NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @org_sla_config_id IS NULL
        THROW 53790, 'organization_id and org_sla_config_id are required.', 1;
    IF @roles_json IS NULL SET @roles_json = N'[]';
    IF ISJSON(@roles_json) = 0
        THROW 53791, 'roles_json is not a valid JSON document.', 1;

    -- Isolation guard.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_sla_config
        WHERE org_sla_config_id = @org_sla_config_id
          AND organization_id   = @organization_id
          AND is_active         = 1)
        THROW 53792, 'SLA config not found for this organization.', 1;

    BEGIN TRAN;

    -- Wipe existing rows (hard delete -- history lives in audit trail
    -- when we wire it; matches the assurance workflow full-replacement
    -- pattern in sp_org_assurance_workflow_save).
    DELETE FROM grac_practice.org_sla_config_notify_role
    WHERE org_sla_config_id = @org_sla_config_id;

    -- Insert new set. Reject invalid event codes at CHECK constraint;
    -- filter empty rows.
    ;WITH src AS (
        SELECT x.notifyEventCode AS notify_event_code,
               x.roleId          AS role_id
        FROM OPENJSON(@roles_json)
        WITH (
            notifyEventCode NVARCHAR(30) '$.notifyEventCode',
            roleId          BIGINT       '$.roleId'
        ) x
        WHERE x.notifyEventCode IS NOT NULL
          AND x.roleId IS NOT NULL
    ),
    dedup AS (
        -- Drop duplicate (event, role) tuples in the payload.
        SELECT DISTINCT notify_event_code, role_id FROM src
    )
    INSERT INTO grac_practice.org_sla_config_notify_role
        (org_sla_config_id, organization_id, notify_event_code,
         role_id, role_name, is_active, entered_by, entered_dt)
    SELECT
        @org_sla_config_id,
        @organization_id,
        UPPER(d.notify_event_code),
        d.role_id,
        r.role_name,
        1,
        @actor,
        SYSUTCDATETIME()
    FROM dedup d
    LEFT JOIN grac_practice.organization_role r
           ON r.role_id = d.role_id
          AND r.organization_id = @organization_id
    WHERE UPPER(d.notify_event_code) IN (N'WARNING', N'ESCALATION');

    -- Touch header updated_by / _dt so grid shows freshness.
    UPDATE grac_practice.org_sla_config
    SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_sla_config_id = @org_sla_config_id;

    COMMIT;
END
GO

-- =====================================================================
-- sp_org_sla_process_binding_set
--   Full replacement. @bindings_json:
--     [ { "processTypeCode": "GAP",  "processScopeRefId": null, "processScopeLabel": null },
--       { "processTypeCode": "TASK", "processScopeRefId": 2,    "processScopeLabel": "Rectification" } ]
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_process_binding_set
    @organization_id   BIGINT,
    @org_sla_config_id BIGINT,
    @bindings_json     NVARCHAR(MAX),
    @actor             NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @org_sla_config_id IS NULL
        THROW 53793, 'organization_id and org_sla_config_id are required.', 1;
    IF @bindings_json IS NULL SET @bindings_json = N'[]';
    IF ISJSON(@bindings_json) = 0
        THROW 53794, 'bindings_json is not a valid JSON document.', 1;

    -- Isolation guard.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_sla_config
        WHERE org_sla_config_id = @org_sla_config_id
          AND organization_id   = @organization_id
          AND is_active         = 1)
        THROW 53795, 'SLA config not found for this organization.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    -- Guard: cannot bind to a (process_type, scope_ref) already bound
    -- by a DIFFERENT active org_sla_config in the same org. Detects
    -- collisions BEFORE we wipe the current rows so the caller sees a
    -- meaningful error rather than a partial replace.
    IF EXISTS (
        SELECT 1
        FROM OPENJSON(@bindings_json)
        WITH (
            processTypeCode   NVARCHAR(60) '$.processTypeCode',
            processScopeRefId BIGINT       '$.processScopeRefId'
        ) x
        JOIN grac_practice.org_sla_process_binding b
             ON b.organization_id = @organization_id
            AND b.is_active       = 1
            AND b.process_type_code = x.processTypeCode
            AND ((b.process_scope_ref_id IS NULL AND x.processScopeRefId IS NULL)
                 OR b.process_scope_ref_id = x.processScopeRefId)
        WHERE b.org_sla_config_id <> @org_sla_config_id)
        THROW 53796,
            'One or more selected processes are already bound to a different SLA config. Remove the existing binding first.', 1;

    -- Wipe existing rows for this config.
    DELETE FROM grac_practice.org_sla_process_binding
    WHERE org_sla_config_id = @org_sla_config_id;

    ;WITH src AS (
        SELECT x.processTypeCode   AS process_type_code,
               x.processScopeRefId AS process_scope_ref_id,
               x.processScopeLabel AS process_scope_label
        FROM OPENJSON(@bindings_json)
        WITH (
            processTypeCode   NVARCHAR(60)  '$.processTypeCode',
            processScopeRefId BIGINT        '$.processScopeRefId',
            processScopeLabel NVARCHAR(200) '$.processScopeLabel'
        ) x
        WHERE x.processTypeCode IS NOT NULL
    ),
    dedup AS (
        SELECT DISTINCT process_type_code, process_scope_ref_id, process_scope_label
        FROM src
    )
    INSERT INTO grac_practice.org_sla_process_binding
        (organization_id, org_sla_config_id, process_type_code,
         process_scope_ref_id, process_scope_label,
         is_active, record_status_id, entered_by, entered_dt)
    SELECT
        @organization_id,
        @org_sla_config_id,
        d.process_type_code,
        d.process_scope_ref_id,
        d.process_scope_label,
        1,
        @active_record_status_id,
        @actor,
        SYSUTCDATETIME()
    FROM dedup d
    JOIN grac_practice.sla_process_type_master pt
         ON pt.process_type_code = d.process_type_code
        AND pt.is_active = 1;

    UPDATE grac_practice.org_sla_config
    SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_sla_config_id = @org_sla_config_id;

    COMMIT;
END
GO

-- =====================================================================
-- sp_org_sla_config_for_process
--   Resolver used by sweeps. Returns the applicable SLA config for
--   (organization, process_type_code, process_scope_ref_id).
--
--   Match priority:
--     1. Exact scope match (scope_ref_id equal)
--     2. Default (scope_ref_id IS NULL)
--     3. No match -> empty result sets (caller falls back to global default)
--
--   Result sets:
--     1) Header (0 or 1 row)
--     2) Notify roles (0..N rows)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_config_for_process
    @organization_id      BIGINT,
    @process_type_code    NVARCHAR(60),
    @process_scope_ref_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @process_type_code IS NULL
        THROW 53797, 'organization_id and process_type_code are required.', 1;

    DECLARE @config_id BIGINT;

    -- Priority 1: exact scope match.
    IF @process_scope_ref_id IS NOT NULL
    BEGIN
        SELECT TOP 1 @config_id = b.org_sla_config_id
        FROM grac_practice.org_sla_process_binding b
        WHERE b.organization_id     = @organization_id
          AND b.process_type_code   = @process_type_code
          AND b.process_scope_ref_id = @process_scope_ref_id
          AND b.is_active           = 1;
    END

    -- Priority 2: default (scope_ref IS NULL).
    IF @config_id IS NULL
    BEGIN
        SELECT TOP 1 @config_id = b.org_sla_config_id
        FROM grac_practice.org_sla_process_binding b
        WHERE b.organization_id     = @organization_id
          AND b.process_type_code   = @process_type_code
          AND b.process_scope_ref_id IS NULL
          AND b.is_active           = 1;
    END

    -- Header (0 or 1 row). Empty result set when no match.
    SELECT
        c.org_sla_config_id         AS OrgSlaConfigId,
        c.organization_id           AS OrganizationId,
        c.sla_master_id             AS SlaMasterId,
        c.sla_master_code           AS SlaMasterCode,
        c.sla_master_name           AS SlaMasterName,
        c.total_sla_days            AS TotalSlaDays,
        c.warning_before_due_days   AS WarningBeforeDueDays,
        c.escalation_after_due_days AS EscalationAfterDueDays
    FROM grac_practice.org_sla_config c
    WHERE @config_id IS NOT NULL
      AND c.org_sla_config_id = @config_id
      AND c.is_active         = 1;

    -- Notify roles for the resolved config.
    SELECT
        n.notify_event_code AS NotifyEventCode,
        n.role_id           AS RoleId,
        n.role_name         AS RoleName
    FROM grac_practice.org_sla_config_notify_role n
    WHERE @config_id IS NOT NULL
      AND n.org_sla_config_id = @config_id
      AND n.is_active         = 1
    ORDER BY n.notify_event_code, n.role_name;
END
GO

PRINT '179 Organization SLA Config procedures deployed.';
GO
