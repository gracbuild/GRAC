-- =====================================================================
-- 067 Workflow & Event-Driven Assurance Engine -- procedures
--
-- Follows the CustomGap convention (055): each entity gets list / upsert /
-- (optional) status-transition SPs, all in grac_practice.sp_workflow_* or
-- grac_practice.sp_event_*. Every SP is idempotent w.r.t. schema (CREATE
-- OR ALTER) so re-runs are safe.
--
-- Rollback: database/067_workflow_engine_procs_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.workflow','U') IS NULL
BEGIN
    RAISERROR('067: workflow table missing -- run 066 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- WORKFLOW
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_workflow_list
    @organization_id BIGINT       = NULL,
    @status_code     NVARCHAR(30) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT          = 1,
    @page_size       INT          = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    ;WITH filtered AS (
        SELECT w.*
        FROM grac_practice.workflow w
        WHERE (@organization_id IS NULL OR w.organization_id = @organization_id)
          AND (@status_code     IS NULL OR w.status          = @status_code)
          AND (@search          IS NULL
               OR w.workflow_name LIKE N'%' + @search + N'%'
               OR w.workflow_code LIKE N'%' + @search + N'%'
               OR w.description   LIKE N'%' + @search + N'%')
    )
    SELECT (SELECT COUNT_BIG(*) FROM filtered) AS TotalCount,
           @page AS PageNumber, @page_size AS PageSize
    OPTION (RECOMPILE);

    ;WITH filtered AS (
        SELECT w.*
        FROM grac_practice.workflow w
        WHERE (@organization_id IS NULL OR w.organization_id = @organization_id)
          AND (@status_code     IS NULL OR w.status          = @status_code)
          AND (@search          IS NULL
               OR w.workflow_name LIKE N'%' + @search + N'%'
               OR w.workflow_code LIKE N'%' + @search + N'%'
               OR w.description   LIKE N'%' + @search + N'%')
    )
    SELECT *
    FROM filtered
    ORDER BY workflow_name ASC, workflow_id DESC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_workflow_save
    @workflow_id            BIGINT        = NULL,      -- NULL = insert
    @organization_id        BIGINT,
    @workflow_code          NVARCHAR(60),
    @workflow_name          NVARCHAR(200),
    @description            NVARCHAR(MAX) = NULL,
    @applicable_entity_type NVARCHAR(100) = NULL,
    @version                NVARCHAR(20)  = N'1.0',
    @owner_employee_id      BIGINT        = NULL,
    @status                 NVARCHAR(30)  = N'Active',
    @is_default_template    BIT           = 0,
    @actor_employee_id      BIGINT        = NULL,
    @out_workflow_id        BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @workflow_code IS NULL OR @workflow_name IS NULL
        THROW 67010, 'sp_workflow_save: organization_id, workflow_code and workflow_name are required.', 1;

    IF @status NOT IN (N'Active', N'Inactive', N'Draft', N'Archived')
        SET @status = N'Active';

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    IF @workflow_id IS NULL
    BEGIN
        INSERT INTO grac_practice.workflow
            (organization_id, workflow_code, workflow_name, description,
             applicable_entity_type, version, owner_employee_id, status,
             is_default_template, entered_by, entered_dt)
        VALUES
            (@organization_id, @workflow_code, @workflow_name, @description,
             @applicable_entity_type, @version, @owner_employee_id, @status,
             ISNULL(@is_default_template, 0), @actor, SYSUTCDATETIME());
        SET @out_workflow_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.workflow
           SET workflow_code          = @workflow_code,
               workflow_name          = @workflow_name,
               description            = @description,
               applicable_entity_type = @applicable_entity_type,
               version                = @version,
               owner_employee_id      = @owner_employee_id,
               status                 = @status,
               is_default_template    = ISNULL(@is_default_template, 0),
               updated_by             = @actor,
               updated_dt             = SYSUTCDATETIME()
         WHERE workflow_id = @workflow_id;
        SET @out_workflow_id = @workflow_id;
    END
END;
GO

-- =====================================================================
-- WORKFLOW STAGE
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_workflow_stage_list
    @workflow_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.*
    FROM grac_practice.workflow_stage s
    WHERE s.workflow_id = @workflow_id
    ORDER BY s.stage_sequence ASC, s.workflow_stage_id ASC;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_workflow_stage_save
    @workflow_stage_id   BIGINT       = NULL,
    @workflow_id         BIGINT,
    @stage_code          NVARCHAR(60),
    @stage_name          NVARCHAR(200),
    @description         NVARCHAR(MAX) = NULL,
    @stage_sequence      INT          = 1,
    @previous_stage_id   BIGINT       = NULL,
    @next_stage_id       BIGINT       = NULL,
    @allowed_transitions NVARCHAR(1000) = NULL,
    @status              NVARCHAR(30) = N'Active',
    @actor_employee_id   BIGINT       = NULL,
    @out_workflow_stage_id BIGINT     OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @workflow_id IS NULL OR @stage_code IS NULL OR @stage_name IS NULL
        THROW 67020, 'sp_workflow_stage_save: workflow_id, stage_code and stage_name are required.', 1;

    IF @status NOT IN (N'Active', N'Inactive') SET @status = N'Active';

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    IF @workflow_stage_id IS NULL
    BEGIN
        INSERT INTO grac_practice.workflow_stage
            (workflow_id, stage_code, stage_name, description,
             stage_sequence, previous_stage_id, next_stage_id,
             allowed_transitions, status, entered_by, entered_dt)
        VALUES
            (@workflow_id, @stage_code, @stage_name, @description,
             ISNULL(@stage_sequence, 1), @previous_stage_id, @next_stage_id,
             @allowed_transitions, @status, @actor, SYSUTCDATETIME());
        SET @out_workflow_stage_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.workflow_stage
           SET stage_code          = @stage_code,
               stage_name          = @stage_name,
               description         = @description,
               stage_sequence      = ISNULL(@stage_sequence, 1),
               previous_stage_id   = @previous_stage_id,
               next_stage_id       = @next_stage_id,
               allowed_transitions = @allowed_transitions,
               status              = @status,
               updated_by          = @actor,
               updated_dt          = SYSUTCDATETIME()
         WHERE workflow_stage_id = @workflow_stage_id;
        SET @out_workflow_stage_id = @workflow_stage_id;
    END
END;
GO

-- =====================================================================
-- ENTITY TYPE
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_entity_type_list
    @organization_id BIGINT = NULL,
    @status_code     NVARCHAR(30) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.*
    FROM grac_practice.entity_type_master e
    WHERE (@organization_id IS NULL OR e.organization_id = @organization_id)
      AND (@status_code     IS NULL OR e.status          = @status_code)
    ORDER BY e.entity_category ASC, e.entity_type_name ASC;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_entity_type_save
    @entity_type_id     BIGINT = NULL,
    @organization_id    BIGINT,
    @entity_type_code   NVARCHAR(60),
    @entity_type_name   NVARCHAR(200),
    @description        NVARCHAR(MAX) = NULL,
    @entity_category    NVARCHAR(60)  = NULL,
    @status             NVARCHAR(30)  = N'Active',
    @actor_employee_id  BIGINT        = NULL,
    @out_entity_type_id BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @entity_type_code IS NULL OR @entity_type_name IS NULL
        THROW 67030, 'sp_entity_type_save: organization_id, entity_type_code and entity_type_name are required.', 1;

    IF @status NOT IN (N'Active', N'Inactive') SET @status = N'Active';

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    IF @entity_type_id IS NULL
    BEGIN
        INSERT INTO grac_practice.entity_type_master
            (organization_id, entity_type_code, entity_type_name, description,
             entity_category, status, entered_by, entered_dt)
        VALUES
            (@organization_id, @entity_type_code, @entity_type_name, @description,
             @entity_category, @status, @actor, SYSUTCDATETIME());
        SET @out_entity_type_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.entity_type_master
           SET entity_type_code = @entity_type_code,
               entity_type_name = @entity_type_name,
               description      = @description,
               entity_category  = @entity_category,
               status           = @status,
               updated_by       = @actor,
               updated_dt       = SYSUTCDATETIME()
         WHERE entity_type_id = @entity_type_id;
        SET @out_entity_type_id = @entity_type_id;
    END
END;
GO

-- =====================================================================
-- EVENT DEFINITION
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_definition_list
    @organization_id BIGINT       = NULL,
    @status_code     NVARCHAR(30) = NULL,
    @entity_category NVARCHAR(60) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT          = 1,
    @page_size       INT          = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    ;WITH filtered AS (
        SELECT e.*
        FROM grac_practice.event_definition e
        WHERE (@organization_id IS NULL OR e.organization_id = @organization_id)
          AND (@status_code     IS NULL OR e.status          = @status_code)
          AND (@entity_category IS NULL OR e.entity_category = @entity_category)
          AND (@search          IS NULL
               OR e.event_name LIKE N'%' + @search + N'%'
               OR e.event_code LIKE N'%' + @search + N'%')
    )
    SELECT (SELECT COUNT_BIG(*) FROM filtered) AS TotalCount,
           @page AS PageNumber, @page_size AS PageSize
    OPTION (RECOMPILE);

    ;WITH filtered AS (
        SELECT e.*
        FROM grac_practice.event_definition e
        WHERE (@organization_id IS NULL OR e.organization_id = @organization_id)
          AND (@status_code     IS NULL OR e.status          = @status_code)
          AND (@entity_category IS NULL OR e.entity_category = @entity_category)
          AND (@search          IS NULL
               OR e.event_name LIKE N'%' + @search + N'%'
               OR e.event_code LIKE N'%' + @search + N'%')
    )
    SELECT *
    FROM filtered
    ORDER BY entity_category ASC, event_name ASC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_event_definition_save
    @event_definition_id  BIGINT = NULL,
    @organization_id      BIGINT,
    @event_code           NVARCHAR(60),
    @event_name           NVARCHAR(200),
    @description          NVARCHAR(MAX) = NULL,
    @entity_category      NVARCHAR(60)  = NULL,
    @workflow_id          BIGINT        = NULL,
    @workflow_stage_id    BIGINT        = NULL,
    @trigger_source       NVARCHAR(60)  = NULL,
    @status               NVARCHAR(30)  = N'Active',
    @actor_employee_id    BIGINT        = NULL,
    @out_event_definition_id BIGINT     OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @event_code IS NULL OR @event_name IS NULL
        THROW 67040, 'sp_event_definition_save: organization_id, event_code and event_name are required.', 1;

    IF @status NOT IN (N'Active', N'Inactive', N'Draft') SET @status = N'Active';

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    IF @event_definition_id IS NULL
    BEGIN
        INSERT INTO grac_practice.event_definition
            (organization_id, event_code, event_name, description,
             entity_category, workflow_id, workflow_stage_id,
             trigger_source, status, entered_by, entered_dt)
        VALUES
            (@organization_id, @event_code, @event_name, @description,
             @entity_category, @workflow_id, @workflow_stage_id,
             @trigger_source, @status, @actor, SYSUTCDATETIME());
        SET @out_event_definition_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.event_definition
           SET event_code        = @event_code,
               event_name        = @event_name,
               description       = @description,
               entity_category   = @entity_category,
               workflow_id       = @workflow_id,
               workflow_stage_id = @workflow_stage_id,
               trigger_source    = @trigger_source,
               status            = @status,
               updated_by        = @actor,
               updated_dt        = SYSUTCDATETIME()
         WHERE event_definition_id = @event_definition_id;
        SET @out_event_definition_id = @event_definition_id;
    END
END;
GO

-- =====================================================================
-- CHECKLIST + ITEMS
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_checklist_list
    @organization_id BIGINT       = NULL,
    @status_code     NVARCHAR(30) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT          = 1,
    @page_size       INT          = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    ;WITH filtered AS (
        SELECT c.*,
               (SELECT COUNT(*) FROM grac_practice.checklist_item i
                 WHERE i.checklist_id = c.checklist_id) AS item_count
        FROM grac_practice.checklist c
        WHERE (@organization_id IS NULL OR c.organization_id = @organization_id)
          AND (@status_code     IS NULL OR c.status          = @status_code)
          AND (@search          IS NULL
               OR c.checklist_name LIKE N'%' + @search + N'%'
               OR c.checklist_code LIKE N'%' + @search + N'%')
    )
    SELECT (SELECT COUNT_BIG(*) FROM filtered) AS TotalCount,
           @page AS PageNumber, @page_size AS PageSize
    OPTION (RECOMPILE);

    ;WITH filtered AS (
        SELECT c.*,
               (SELECT COUNT(*) FROM grac_practice.checklist_item i
                 WHERE i.checklist_id = c.checklist_id) AS item_count
        FROM grac_practice.checklist c
        WHERE (@organization_id IS NULL OR c.organization_id = @organization_id)
          AND (@status_code     IS NULL OR c.status          = @status_code)
          AND (@search          IS NULL
               OR c.checklist_name LIKE N'%' + @search + N'%'
               OR c.checklist_code LIKE N'%' + @search + N'%')
    )
    SELECT *
    FROM filtered
    ORDER BY checklist_name ASC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_checklist_save
    @checklist_id      BIGINT = NULL,
    @organization_id   BIGINT,
    @checklist_code    NVARCHAR(60),
    @checklist_name    NVARCHAR(200),
    @description       NVARCHAR(MAX) = NULL,
    @version           NVARCHAR(20)  = N'1.0',
    @status            NVARCHAR(30)  = N'Active',
    @actor_employee_id BIGINT        = NULL,
    @out_checklist_id  BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @checklist_code IS NULL OR @checklist_name IS NULL
        THROW 67050, 'sp_checklist_save: organization_id, checklist_code and checklist_name are required.', 1;

    IF @status NOT IN (N'Active', N'Inactive', N'Draft', N'Archived') SET @status = N'Active';

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    IF @checklist_id IS NULL
    BEGIN
        INSERT INTO grac_practice.checklist
            (organization_id, checklist_code, checklist_name, description,
             version, status, entered_by, entered_dt)
        VALUES
            (@organization_id, @checklist_code, @checklist_name, @description,
             @version, @status, @actor, SYSUTCDATETIME());
        SET @out_checklist_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.checklist
           SET checklist_code = @checklist_code,
               checklist_name = @checklist_name,
               description    = @description,
               version        = @version,
               status         = @status,
               updated_by     = @actor,
               updated_dt     = SYSUTCDATETIME()
         WHERE checklist_id = @checklist_id;
        SET @out_checklist_id = @checklist_id;
    END
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_checklist_item_list
    @checklist_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT i.*
    FROM grac_practice.checklist_item i
    WHERE i.checklist_id = @checklist_id
    ORDER BY i.item_sequence ASC, i.checklist_item_id ASC;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_checklist_item_save
    @checklist_item_id     BIGINT = NULL,
    @checklist_id          BIGINT,
    @item_sequence         INT           = 1,
    @item_text             NVARCHAR(500),
    @item_type             NVARCHAR(60)  = N'Manual',
    @is_mandatory          BIT           = 1,
    @evidence_required     BIT           = 0,
    @attachment_required   BIT           = 0,
    @approval_required     BIT           = 0,
    @responsible_role      NVARCHAR(100) = NULL,
    @due_period_days       INT           = NULL,
    @escalation_rules      NVARCHAR(MAX) = NULL,
    @status                NVARCHAR(30)  = N'Active',
    @actor_employee_id     BIGINT        = NULL,
    @out_checklist_item_id BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @checklist_id IS NULL OR @item_text IS NULL OR LTRIM(RTRIM(@item_text)) = N''
        THROW 67060, 'sp_checklist_item_save: checklist_id and item_text are required.', 1;

    IF @item_type NOT IN (N'Manual', N'Automated', N'API Validation',
                          N'Document Upload', N'Observation',
                          N'Approval', N'Integration Call')
        SET @item_type = N'Manual';

    IF @status NOT IN (N'Active', N'Inactive') SET @status = N'Active';

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    IF @checklist_item_id IS NULL
    BEGIN
        INSERT INTO grac_practice.checklist_item
            (checklist_id, item_sequence, item_text, item_type,
             is_mandatory, evidence_required, attachment_required,
             approval_required, responsible_role, due_period_days,
             escalation_rules, status, entered_by, entered_dt)
        VALUES
            (@checklist_id, ISNULL(@item_sequence,1), @item_text, @item_type,
             ISNULL(@is_mandatory,1), ISNULL(@evidence_required,0), ISNULL(@attachment_required,0),
             ISNULL(@approval_required,0), @responsible_role, @due_period_days,
             @escalation_rules, @status, @actor, SYSUTCDATETIME());
        SET @out_checklist_item_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.checklist_item
           SET item_sequence       = ISNULL(@item_sequence,1),
               item_text           = @item_text,
               item_type           = @item_type,
               is_mandatory        = ISNULL(@is_mandatory,1),
               evidence_required   = ISNULL(@evidence_required,0),
               attachment_required = ISNULL(@attachment_required,0),
               approval_required   = ISNULL(@approval_required,0),
               responsible_role    = @responsible_role,
               due_period_days     = @due_period_days,
               escalation_rules    = @escalation_rules,
               status              = @status
         WHERE checklist_item_id = @checklist_item_id;
        SET @out_checklist_item_id = @checklist_item_id;
    END
END;
GO

-- =====================================================================
-- EVENT-CHECKLIST MAPPING (BRD Sec 10)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_checklist_mapping_list
    @organization_id BIGINT       = NULL,
    @status_code     NVARCHAR(30) = NULL,
    @page            INT          = 1,
    @page_size       INT          = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    ;WITH filtered AS (
        SELECT m.mapping_id,
               m.organization_id,
               m.entity_type_id,
               et.entity_type_name,
               m.event_definition_id,
               ed.event_code,
               ed.event_name,
               m.checklist_id,
               c.checklist_name,
               m.default_owner_role,
               m.default_due_period_days,
               m.status,
               m.entered_by,
               m.entered_dt,
               m.updated_by,
               m.updated_dt
        FROM grac_practice.event_checklist_mapping m
        JOIN grac_practice.entity_type_master  et ON et.entity_type_id      = m.entity_type_id
        JOIN grac_practice.event_definition    ed ON ed.event_definition_id = m.event_definition_id
        JOIN grac_practice.checklist           c  ON c.checklist_id         = m.checklist_id
        WHERE (@organization_id IS NULL OR m.organization_id = @organization_id)
          AND (@status_code     IS NULL OR m.status          = @status_code)
    )
    SELECT (SELECT COUNT_BIG(*) FROM filtered) AS TotalCount,
           @page AS PageNumber, @page_size AS PageSize
    OPTION (RECOMPILE);

    ;WITH filtered AS (
        SELECT m.mapping_id,
               m.organization_id,
               m.entity_type_id,
               et.entity_type_name,
               m.event_definition_id,
               ed.event_code,
               ed.event_name,
               m.checklist_id,
               c.checklist_name,
               m.default_owner_role,
               m.default_due_period_days,
               m.status,
               m.entered_by,
               m.entered_dt,
               m.updated_by,
               m.updated_dt
        FROM grac_practice.event_checklist_mapping m
        JOIN grac_practice.entity_type_master  et ON et.entity_type_id      = m.entity_type_id
        JOIN grac_practice.event_definition    ed ON ed.event_definition_id = m.event_definition_id
        JOIN grac_practice.checklist           c  ON c.checklist_id         = m.checklist_id
        WHERE (@organization_id IS NULL OR m.organization_id = @organization_id)
          AND (@status_code     IS NULL OR m.status          = @status_code)
    )
    SELECT *
    FROM filtered
    ORDER BY entity_type_name, event_name, checklist_name
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_event_checklist_mapping_save
    @mapping_id              BIGINT = NULL,
    @organization_id         BIGINT,
    @entity_type_id          BIGINT,
    @event_definition_id     BIGINT,
    @checklist_id            BIGINT,
    @default_owner_role      NVARCHAR(100) = NULL,
    @default_due_period_days INT           = NULL,
    @status                  NVARCHAR(30)  = N'Active',
    @actor_employee_id       BIGINT        = NULL,
    @out_mapping_id          BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @entity_type_id IS NULL
       OR @event_definition_id IS NULL OR @checklist_id IS NULL
        THROW 67070, 'sp_event_checklist_mapping_save: organization_id, entity_type_id, event_definition_id and checklist_id are required.', 1;

    IF @status NOT IN (N'Active', N'Inactive') SET @status = N'Active';

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    IF @mapping_id IS NULL
    BEGIN
        INSERT INTO grac_practice.event_checklist_mapping
            (organization_id, entity_type_id, event_definition_id, checklist_id,
             default_owner_role, default_due_period_days, status,
             entered_by, entered_dt)
        VALUES
            (@organization_id, @entity_type_id, @event_definition_id, @checklist_id,
             @default_owner_role, @default_due_period_days, @status,
             @actor, SYSUTCDATETIME());
        SET @out_mapping_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.event_checklist_mapping
           SET entity_type_id          = @entity_type_id,
               event_definition_id     = @event_definition_id,
               checklist_id            = @checklist_id,
               default_owner_role      = @default_owner_role,
               default_due_period_days = @default_due_period_days,
               status                  = @status,
               updated_by              = @actor,
               updated_dt              = SYSUTCDATETIME()
         WHERE mapping_id = @mapping_id;
        SET @out_mapping_id = @mapping_id;
    END
END;
GO

-- =====================================================================
-- EVENT INSTANCE (BRD Sec 13 -- trigger engine + Sec 14 assurance)
--   sp_event_instance_trigger implements steps 1..7 of Sec 13:
--     Validate -> Identify Entity -> Identify Event -> Locate Checklist
--     -> Generate Assurance -> Assign Owner -> materialize items.
--   Step 8..10 (Collect Evidence / Complete / Gap+Task) are separate
--   flows so QA can drive each independently.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_instance_list
    @organization_id BIGINT       = NULL,
    @status_code     NVARCHAR(30) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT          = 1,
    @page_size       INT          = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    ;WITH filtered AS (
        SELECT ei.event_instance_id,
               ei.organization_id,
               ei.event_definition_id,
               ed.event_code,
               ed.event_name,
               ei.entity_type_id,
               et.entity_type_name,
               ei.entity_reference,
               ei.entity_display_name,
               ei.checklist_id,
               c.checklist_name,
               ei.trigger_source,
               ei.owner_employee_id,
               ei.due_date,
               ei.status,
               ei.completed_dt,
               ei.entered_by,
               ei.entered_dt
        FROM grac_practice.event_instance     ei
        JOIN grac_practice.event_definition   ed ON ed.event_definition_id = ei.event_definition_id
        LEFT JOIN grac_practice.entity_type_master et ON et.entity_type_id = ei.entity_type_id
        LEFT JOIN grac_practice.checklist          c  ON c.checklist_id    = ei.checklist_id
        WHERE (@organization_id IS NULL OR ei.organization_id = @organization_id)
          AND (@status_code     IS NULL OR ei.status          = @status_code)
          AND (@search          IS NULL
               OR ei.entity_reference   LIKE N'%' + @search + N'%'
               OR ei.entity_display_name LIKE N'%' + @search + N'%'
               OR ed.event_name         LIKE N'%' + @search + N'%')
    )
    SELECT (SELECT COUNT_BIG(*) FROM filtered) AS TotalCount,
           @page AS PageNumber, @page_size AS PageSize
    OPTION (RECOMPILE);

    ;WITH filtered AS (
        SELECT ei.event_instance_id,
               ei.organization_id,
               ei.event_definition_id,
               ed.event_code,
               ed.event_name,
               ei.entity_type_id,
               et.entity_type_name,
               ei.entity_reference,
               ei.entity_display_name,
               ei.checklist_id,
               c.checklist_name,
               ei.trigger_source,
               ei.owner_employee_id,
               ei.due_date,
               ei.status,
               ei.completed_dt,
               ei.entered_by,
               ei.entered_dt
        FROM grac_practice.event_instance     ei
        JOIN grac_practice.event_definition   ed ON ed.event_definition_id = ei.event_definition_id
        LEFT JOIN grac_practice.entity_type_master et ON et.entity_type_id = ei.entity_type_id
        LEFT JOIN grac_practice.checklist          c  ON c.checklist_id    = ei.checklist_id
        WHERE (@organization_id IS NULL OR ei.organization_id = @organization_id)
          AND (@status_code     IS NULL OR ei.status          = @status_code)
          AND (@search          IS NULL
               OR ei.entity_reference    LIKE N'%' + @search + N'%'
               OR ei.entity_display_name LIKE N'%' + @search + N'%'
               OR ed.event_name          LIKE N'%' + @search + N'%')
    )
    SELECT *
    FROM filtered
    ORDER BY CASE WHEN due_date IS NULL THEN 1 ELSE 0 END,
             due_date ASC, event_instance_id DESC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_event_instance_trigger
    @organization_id     BIGINT,
    @event_definition_id BIGINT       = NULL,   -- optional shortcut
    @event_code          NVARCHAR(60) = NULL,   -- alternative lookup
    @entity_type_id      BIGINT       = NULL,
    @entity_reference    NVARCHAR(200) = NULL,
    @entity_display_name NVARCHAR(300) = NULL,
    @trigger_source      NVARCHAR(60)  = N'Manual',
    @payload_json        NVARCHAR(MAX) = NULL,
    @owner_employee_id   BIGINT        = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @out_event_instance_id BIGINT      OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 67080, 'sp_event_instance_trigger: organization_id is required.', 1;

    -- Step 3/4: locate event definition by id or code.
    IF @event_definition_id IS NULL
    BEGIN
        SELECT TOP 1 @event_definition_id = event_definition_id
        FROM grac_practice.event_definition
        WHERE organization_id = @organization_id
          AND event_code      = @event_code
          AND status          = N'Active';
    END

    IF @event_definition_id IS NULL
        THROW 67081, 'sp_event_instance_trigger: event definition not found for organization.', 1;

    -- Step 5: locate configured checklist through mapping.
    DECLARE @checklist_id BIGINT = NULL;
    DECLARE @default_due_period INT = NULL;
    SELECT TOP 1
           @checklist_id       = m.checklist_id,
           @default_due_period = m.default_due_period_days
    FROM grac_practice.event_checklist_mapping m
    WHERE m.organization_id     = @organization_id
      AND m.event_definition_id = @event_definition_id
      AND (@entity_type_id IS NULL OR m.entity_type_id = @entity_type_id)
      AND m.status              = N'Active'
    ORDER BY m.mapping_id DESC;

    DECLARE @due_date DATE = CASE WHEN @default_due_period IS NULL
                                  THEN NULL
                                  ELSE DATEADD(DAY, @default_due_period, CAST(SYSUTCDATETIME() AS DATE))
                             END;

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    -- Step 6: generate assurance record.
    INSERT INTO grac_practice.event_instance
        (organization_id, event_definition_id, entity_type_id, entity_reference,
         entity_display_name, checklist_id, trigger_source, payload_json,
         owner_employee_id, due_date, status, entered_by, entered_dt)
    VALUES
        (@organization_id, @event_definition_id, @entity_type_id, @entity_reference,
         @entity_display_name, @checklist_id, ISNULL(@trigger_source, N'Manual'), @payload_json,
         @owner_employee_id, @due_date,
         CASE WHEN @checklist_id IS NULL THEN N'Received' ELSE N'Pending' END,
         @actor, SYSUTCDATETIME());

    SET @out_event_instance_id = SCOPE_IDENTITY();

    -- Step 7: materialize item rows so the executor can walk them one by one.
    IF @checklist_id IS NOT NULL
    BEGIN
        INSERT INTO grac_practice.event_instance_item
            (event_instance_id, checklist_item_id, item_status, entered_dt)
        SELECT @out_event_instance_id, ci.checklist_item_id, N'Pending', SYSUTCDATETIME()
        FROM grac_practice.checklist_item ci
        WHERE ci.checklist_id = @checklist_id
          AND ci.status       = N'Active';
    END

    -- Audit trail.
    INSERT INTO grac_practice.event_audit
        (organization_id, event_instance_id, entity_type, entity_id,
         action, actor, new_value, entered_dt)
    VALUES
        (@organization_id, @out_event_instance_id, N'EventInstance', @out_event_instance_id,
         N'Trigger', @actor,
         CONCAT(N'event_definition_id=', @event_definition_id,
                N';checklist_id=', ISNULL(CAST(@checklist_id AS NVARCHAR(20)), N'null'),
                N';trigger_source=', ISNULL(@trigger_source, N'Manual')),
         SYSUTCDATETIME());
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_event_instance_complete
    @event_instance_id BIGINT,
    @actor_employee_id BIGINT       = NULL,
    @comments          NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.event_instance WHERE event_instance_id = @event_instance_id)
        THROW 67090, 'sp_event_instance_complete: event_instance_id not found.', 1;

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    -- Any pending mandatory item that is not passed marks the event Failed.
    DECLARE @has_failure BIT =
        CASE WHEN EXISTS (
            SELECT 1
            FROM grac_practice.event_instance_item ei_i
            JOIN grac_practice.checklist_item      ci  ON ci.checklist_item_id = ei_i.checklist_item_id
            WHERE ei_i.event_instance_id = @event_instance_id
              AND ci.is_mandatory = 1
              AND ei_i.item_status <> N'Passed'
        ) THEN 1 ELSE 0 END;

    UPDATE grac_practice.event_instance
       SET status       = CASE WHEN @has_failure = 1 THEN N'Failed' ELSE N'Completed' END,
           completed_dt = SYSUTCDATETIME(),
           comments     = COALESCE(@comments, comments),
           updated_by   = @actor,
           updated_dt   = SYSUTCDATETIME()
     WHERE event_instance_id = @event_instance_id;

    INSERT INTO grac_practice.event_audit
        (organization_id, event_instance_id, entity_type, entity_id,
         action, actor, entered_dt)
    SELECT organization_id, event_instance_id, N'EventInstance', event_instance_id,
           N'Complete', @actor, SYSUTCDATETIME()
    FROM grac_practice.event_instance WHERE event_instance_id = @event_instance_id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_event_instance_item_save
    @event_instance_item_id BIGINT,
    @item_status            NVARCHAR(30),
    @evidence_url           NVARCHAR(1000) = NULL,
    @remarks                NVARCHAR(MAX)  = NULL,
    @actor_employee_id      BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @item_status NOT IN (N'Pending', N'Passed', N'Failed', N'NotApplicable', N'InProgress')
        THROW 67091, 'sp_event_instance_item_save: invalid item_status.', 1;

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    UPDATE grac_practice.event_instance_item
       SET item_status  = @item_status,
           evidence_url = @evidence_url,
           remarks      = @remarks,
           completed_by = CASE WHEN @item_status IN (N'Passed', N'Failed', N'NotApplicable')
                               THEN @actor ELSE completed_by END,
           completed_dt = CASE WHEN @item_status IN (N'Passed', N'Failed', N'NotApplicable')
                               THEN SYSUTCDATETIME() ELSE completed_dt END
     WHERE event_instance_item_id = @event_instance_item_id;
END;
GO

-- =====================================================================
-- EVENT GAP (BRD Sec 15)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_gap_list
    @organization_id BIGINT       = NULL,
    @status_code     NVARCHAR(30) = NULL,
    @severity        NVARCHAR(30) = NULL,
    @page            INT          = 1,
    @page_size       INT          = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    ;WITH filtered AS (
        SELECT g.*
        FROM grac_practice.event_gap g
        WHERE (@organization_id IS NULL OR g.organization_id = @organization_id)
          AND (@status_code     IS NULL OR g.status          = @status_code)
          AND (@severity        IS NULL OR g.severity        = @severity)
    )
    SELECT (SELECT COUNT_BIG(*) FROM filtered) AS TotalCount,
           @page AS PageNumber, @page_size AS PageSize
    OPTION (RECOMPILE);

    ;WITH filtered AS (
        SELECT g.*
        FROM grac_practice.event_gap g
        WHERE (@organization_id IS NULL OR g.organization_id = @organization_id)
          AND (@status_code     IS NULL OR g.status          = @status_code)
          AND (@severity        IS NULL OR g.severity        = @severity)
    )
    SELECT *
    FROM filtered
    ORDER BY CASE WHEN due_date IS NULL THEN 1 ELSE 0 END,
             due_date ASC, event_gap_id DESC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_event_gap_open
    @organization_id   BIGINT,
    @event_instance_id BIGINT,
    @checklist_item_id BIGINT        = NULL,
    @entity_reference  NVARCHAR(200) = NULL,
    @title             NVARCHAR(250),
    @description       NVARCHAR(MAX) = NULL,
    @severity          NVARCHAR(30)  = N'Medium',
    @owner_employee_id BIGINT        = NULL,
    @due_date          DATE          = NULL,
    @actor_employee_id BIGINT        = NULL,
    @out_event_gap_id  BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @event_instance_id IS NULL
       OR @title IS NULL OR LTRIM(RTRIM(@title)) = N''
        THROW 67100, 'sp_event_gap_open: organization_id, event_instance_id and title are required.', 1;

    IF @severity NOT IN (N'Low', N'Medium', N'High', N'Critical') SET @severity = N'Medium';

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    INSERT INTO grac_practice.event_gap
        (organization_id, event_instance_id, checklist_item_id, entity_reference,
         title, description, severity, owner_employee_id, due_date, status,
         entered_by, entered_dt)
    VALUES
        (@organization_id, @event_instance_id, @checklist_item_id, @entity_reference,
         @title, @description, @severity, @owner_employee_id, @due_date, N'Open',
         @actor, SYSUTCDATETIME());

    SET @out_event_gap_id = SCOPE_IDENTITY();

    INSERT INTO grac_practice.event_audit
        (organization_id, event_instance_id, entity_type, entity_id,
         action, actor, new_value, entered_dt)
    VALUES
        (@organization_id, @event_instance_id, N'EventGap', @out_event_gap_id,
         N'GapRaised', @actor, CONCAT(N'severity=', @severity, N';title=', @title),
         SYSUTCDATETIME());
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_event_gap_close
    @event_gap_id      BIGINT,
    @actor_employee_id BIGINT = NULL,
    @remarks           NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.event_gap WHERE event_gap_id = @event_gap_id)
        THROW 67101, 'sp_event_gap_close: event_gap_id not found.', 1;

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    UPDATE grac_practice.event_gap
       SET status     = N'Closed',
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
     WHERE event_gap_id = @event_gap_id;
END;
GO

-- =====================================================================
-- DASHBOARD counts (BRD Sec 16)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_workflow_dashboard_counts
    @organization_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        (SELECT COUNT(*) FROM grac_practice.event_instance
          WHERE (@organization_id IS NULL OR organization_id = @organization_id))          AS EventsReceived,
        (SELECT COUNT(*) FROM grac_practice.event_instance
          WHERE (@organization_id IS NULL OR organization_id = @organization_id)
            AND checklist_id IS NOT NULL)                                                  AS AssuranceGenerated,
        (SELECT COUNT(*) FROM grac_practice.event_instance
          WHERE (@organization_id IS NULL OR organization_id = @organization_id)
            AND status = N'Pending')                                                       AS PendingAssurance,
        (SELECT COUNT(*) FROM grac_practice.event_instance
          WHERE (@organization_id IS NULL OR organization_id = @organization_id)
            AND status = N'Pending' AND due_date IS NOT NULL AND due_date < CAST(SYSUTCDATETIME() AS DATE)) AS OverdueAssurance,
        (SELECT COUNT(*) FROM grac_practice.event_instance
          WHERE (@organization_id IS NULL OR organization_id = @organization_id)
            AND status = N'Failed')                                                        AS FailedAssurance,
        (SELECT COUNT(*) FROM grac_practice.event_gap
          WHERE (@organization_id IS NULL OR organization_id = @organization_id)
            AND status IN (N'Open', N'InProgress'))                                        AS OpenGaps,
        (SELECT COUNT(*) FROM grac_practice.workflow
          WHERE (@organization_id IS NULL OR organization_id = @organization_id)
            AND status = N'Active')                                                        AS ActiveWorkflows,
        (SELECT COUNT(*) FROM grac_practice.event_definition
          WHERE (@organization_id IS NULL OR organization_id = @organization_id)
            AND status = N'Active')                                                        AS ActiveEvents,
        (SELECT COUNT(*) FROM grac_practice.checklist
          WHERE (@organization_id IS NULL OR organization_id = @organization_id)
            AND status = N'Active')                                                        AS ActiveChecklists;
END;
GO

PRINT '067 workflow engine procedures installed.';
GO

SET NOEXEC OFF;
GO
