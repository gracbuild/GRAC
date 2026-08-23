-- =====================================================================
-- 112 Custom Gap procedures -- unified across all sources
-- (Implementation / Assurance / Custom / etc.).
--
-- Depends on 109 (custom_gap column extensions), 110 (custom_gap_*
-- supporting tables), 111 (data migration).
--
-- PROCEDURES (all CREATE OR ALTER):
--   sp_custom_gap_list                            -- extended (was 055)
--   sp_custom_gap_get                             -- new
--   sp_custom_gap_save                            -- new (unified upsert)
--   sp_custom_gap_delete                          -- new (unified soft delete)
--   sp_custom_gap_generate_from_assurance_observation  -- new (auto-gen engine)
--   sp_custom_gap_transition                      -- new (shared helper)
--   sp_custom_gap_start                           -- new
--   sp_custom_gap_submit_remediation              -- new
--   sp_custom_gap_verify                          -- new
--   sp_custom_gap_close_lifecycle                 -- new
--     (distinct from the pre-existing sp_custom_gap_close in 055
--      which uses a different signature -- kept unchanged)
--   sp_custom_gap_reopen                          -- new
--   sp_custom_gap_observation_attach              -- new
--   sp_custom_gap_observation_detach              -- new
--   sp_custom_gap_observation_list                -- new
--   sp_observation_linked_custom_gaps_list        -- new
--   sp_custom_gap_merge                           -- new
--   sp_custom_gap_action_list / save / complete / delete  -- new
--   sp_custom_gap_history_list                    -- new
--
-- Plus: CREATE OR ALTER sp_org_assurance_observation_accept
--   retargeted -- the auto-hook now calls
--   sp_custom_gap_generate_from_assurance_observation.
--
-- THROW reason codes: 55000-55099.
--
-- Rollback: 112_custom_gap_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap','gap_source_module_code') IS NULL
   OR OBJECT_ID('grac_practice.custom_gap_observation','U') IS NULL
BEGIN
    RAISERROR('112: run 109 + 110 first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_custom_gap_list (extended)
--
-- Preserves original param names from migration 055 so existing
-- callers (Practice/Partials/gaps.cshtml Custom tab, CustomGapService)
-- keep working. Adds new filters + returns the new columns.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_list
    @organization_id       BIGINT       = NULL,
    @status_code           NVARCHAR(30) = NULL,
    @priority              NVARCHAR(30) = NULL,
    @owner_employee_id     BIGINT       = NULL,
    @search                NVARCHAR(200) = NULL,
    @page                  INT          = 1,
    @page_size             INT          = 25,
    -- New filters (all optional; existing callers ignore them):
    @gap_source_module_code NVARCHAR(30) = NULL,   -- Implementation / Assurance / Custom / ...
    @severity_code         NVARCHAR(30)  = NULL,
    @observation_id        BIGINT        = NULL,   -- observations attached to gap
    @execution_id          BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    ;WITH filtered AS (
        SELECT g.custom_gap_id,
               g.organization_id,
               g.gap_type_code,
               g.gap_source_module_code,
               g.source_reference_type,
               g.source_reference_id,
               g.title,
               g.description,
               g.priority,
               g.severity_code,
               g.severity_name,
               g.owner_employee_id,
               g.owner_display_name,
               g.assigned_reviewer_employee_id,
               g.assigned_reviewer_display_name,
               g.due_date,
               g.target_resolution_date,
               g.status,
               g.execution_code,
               g.execution_name,
               g.entity_dimension_code,
               g.entity_dimension_name,
               g.entity_code,
               g.entity_name,
               g.observation_code,
               g.observation_title,
               g.opened_dt,
               g.remediation_submitted_dt,
               g.verified_dt,
               g.closed_dt,
               g.reopened_dt,
               g.remarks,
               g.linked_task_id,
               g.risk_id,
               g.entered_by, g.entered_dt, g.updated_by, g.updated_dt,
               (SELECT COUNT_BIG(1) FROM grac_practice.custom_gap_observation j
                 WHERE j.custom_gap_id = g.custom_gap_id AND j.is_active = 1) AS linked_observation_count,
               (SELECT COUNT_BIG(1) FROM grac_practice.custom_gap_action a
                 WHERE a.custom_gap_id = g.custom_gap_id AND a.is_active = 1) AS action_count,
               (SELECT COUNT_BIG(1) FROM grac_practice.custom_gap_action a
                 WHERE a.custom_gap_id = g.custom_gap_id AND a.is_active = 1
                   AND a.action_status_code = N'Completed') AS action_completed_count
        FROM grac_practice.custom_gap g
        WHERE (@organization_id IS NULL OR g.organization_id = @organization_id)
          AND (@status_code     IS NULL OR g.status         = @status_code)
          AND (@priority        IS NULL OR g.priority       = @priority)
          AND (@owner_employee_id IS NULL OR g.owner_employee_id = @owner_employee_id)
          AND (@gap_source_module_code IS NULL OR g.gap_source_module_code = @gap_source_module_code)
          AND (@severity_code   IS NULL OR g.severity_code  = @severity_code)
          AND (@execution_id    IS NULL OR
               (g.gap_source_module_code = N'Assurance' AND
                EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                        WHERE e.execution_code = g.execution_code
                          AND e.org_assurance_execution_id = @execution_id)))
          AND (@observation_id  IS NULL OR EXISTS (
                    SELECT 1 FROM grac_practice.custom_gap_observation j
                    WHERE j.custom_gap_id = g.custom_gap_id
                      AND j.org_assurance_observation_id = @observation_id
                      AND j.is_active = 1))
          AND (@search          IS NULL OR @search = ''
               OR g.title       LIKE N'%' + @search + N'%'
               OR g.description LIKE N'%' + @search + N'%'
               OR g.remarks     LIKE N'%' + @search + N'%'
               OR g.execution_name  LIKE N'%' + @search + N'%'
               OR g.entity_name     LIKE N'%' + @search + N'%'
               OR g.observation_title LIKE N'%' + @search + N'%')
    )
    SELECT CAST(COUNT_BIG(*) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM filtered
    OPTION (RECOMPILE);

    ;WITH filtered AS (
        SELECT g.custom_gap_id,
               g.organization_id,
               g.gap_type_code,
               g.gap_source_module_code,
               g.source_reference_type,
               g.source_reference_id,
               g.title,
               g.description,
               g.priority,
               g.severity_code,
               g.severity_name,
               g.owner_employee_id,
               g.owner_display_name,
               g.assigned_reviewer_employee_id,
               g.assigned_reviewer_display_name,
               g.due_date,
               g.target_resolution_date,
               g.status,
               g.execution_code,
               g.execution_name,
               g.entity_dimension_code,
               g.entity_dimension_name,
               g.entity_code,
               g.entity_name,
               g.observation_code,
               g.observation_title,
               g.opened_dt,
               g.remediation_submitted_dt,
               g.verified_dt,
               g.closed_dt,
               g.reopened_dt,
               g.remarks,
               g.linked_task_id,
               g.risk_id,
               g.entered_by, g.entered_dt, g.updated_by, g.updated_dt,
               (SELECT COUNT_BIG(1) FROM grac_practice.custom_gap_observation j
                 WHERE j.custom_gap_id = g.custom_gap_id AND j.is_active = 1) AS linked_observation_count,
               (SELECT COUNT_BIG(1) FROM grac_practice.custom_gap_action a
                 WHERE a.custom_gap_id = g.custom_gap_id AND a.is_active = 1) AS action_count,
               (SELECT COUNT_BIG(1) FROM grac_practice.custom_gap_action a
                 WHERE a.custom_gap_id = g.custom_gap_id AND a.is_active = 1
                   AND a.action_status_code = N'Completed') AS action_completed_count
        FROM grac_practice.custom_gap g
        WHERE (@organization_id IS NULL OR g.organization_id = @organization_id)
          AND (@status_code     IS NULL OR g.status         = @status_code)
          AND (@priority        IS NULL OR g.priority       = @priority)
          AND (@owner_employee_id IS NULL OR g.owner_employee_id = @owner_employee_id)
          AND (@gap_source_module_code IS NULL OR g.gap_source_module_code = @gap_source_module_code)
          AND (@severity_code   IS NULL OR g.severity_code  = @severity_code)
          AND (@execution_id    IS NULL OR
               (g.gap_source_module_code = N'Assurance' AND
                EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                        WHERE e.execution_code = g.execution_code
                          AND e.org_assurance_execution_id = @execution_id)))
          AND (@observation_id  IS NULL OR EXISTS (
                    SELECT 1 FROM grac_practice.custom_gap_observation j
                    WHERE j.custom_gap_id = g.custom_gap_id
                      AND j.org_assurance_observation_id = @observation_id
                      AND j.is_active = 1))
          AND (@search          IS NULL OR @search = ''
               OR g.title       LIKE N'%' + @search + N'%'
               OR g.description LIKE N'%' + @search + N'%'
               OR g.remarks     LIKE N'%' + @search + N'%'
               OR g.execution_name  LIKE N'%' + @search + N'%'
               OR g.entity_name     LIKE N'%' + @search + N'%'
               OR g.observation_title LIKE N'%' + @search + N'%')
    )
    SELECT *
    FROM filtered
    ORDER BY CASE WHEN due_date IS NULL THEN 1 ELSE 0 END,
             due_date ASC,
             custom_gap_id DESC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY
    OPTION (RECOMPILE);
END
GO

-- =====================================================================
-- sp_custom_gap_get
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_get
    @organization_id BIGINT,
    @custom_gap_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @custom_gap_id IS NULL
        THROW 55000, 'organization_id and custom_gap_id are required.', 1;

    SELECT g.custom_gap_id,
           g.organization_id,
           g.gap_type_code,
           g.gap_source_module_code,
           g.source_reference_type,
           g.source_reference_id,
           g.title,
           g.description,
           g.priority,
           g.severity_code,
           g.severity_name,
           g.owner_employee_id,
           g.owner_display_name,
           g.assigned_reviewer_employee_id,
           g.assigned_reviewer_display_name,
           g.due_date,
           g.target_resolution_date,
           g.status,
           g.execution_code,
           g.execution_name,
           g.entity_dimension_code,
           g.entity_dimension_name,
           g.entity_code,
           g.entity_name,
           g.observation_code,
           g.observation_title,
           g.opened_dt,
           g.remediation_submitted_dt,
           g.verified_dt,
           g.closed_dt,
           g.reopened_dt,
           g.remediation_plan,
           g.resolution_notes,
           g.verification_notes,
           g.closure_notes,
           g.remarks,
           g.linked_task_id,
           g.risk_id,
           g.entered_by, g.entered_dt, g.updated_by, g.updated_dt,
           (SELECT COUNT_BIG(1) FROM grac_practice.custom_gap_observation j
             WHERE j.custom_gap_id = g.custom_gap_id AND j.is_active = 1) AS linked_observation_count
    FROM grac_practice.custom_gap g
    WHERE g.organization_id = @organization_id
      AND g.custom_gap_id   = @custom_gap_id;
END
GO

-- =====================================================================
-- sp_custom_gap_save (unified upsert -- Custom / Assurance / any source)
--   Edits only allowed in Open / InProgress / Reopened. Existing rows
--   from other sources use their existing status vocabulary.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_save
    @organization_id                BIGINT,
    @custom_gap_id                  BIGINT       = NULL,
    @gap_source_module_code         NVARCHAR(30) = N'Custom',
    @source_reference_type          NVARCHAR(60) = NULL,
    @source_reference_id            BIGINT       = NULL,
    @gap_type_code                  NVARCHAR(60) = NULL,
    @title                          NVARCHAR(250),
    @description                    NVARCHAR(MAX) = NULL,
    @priority                       NVARCHAR(30) = N'Medium',
    @severity_code                  NVARCHAR(30) = NULL,
    @severity_name                  NVARCHAR(120) = NULL,
    @owner_employee_id              BIGINT       = NULL,
    @owner_display_name             NVARCHAR(240) = NULL,
    @assigned_reviewer_employee_id  BIGINT       = NULL,
    @assigned_reviewer_display_name NVARCHAR(240) = NULL,
    @due_date                       DATE         = NULL,
    @target_resolution_date         DATE         = NULL,
    @remediation_plan               NVARCHAR(MAX) = NULL,
    @remarks                        NVARCHAR(1000) = NULL,
    @actor                          NVARCHAR(100) = 'system',
    @custom_gap_id_out              BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 55001, 'organization_id is required.', 1;
    IF @title IS NULL OR LEN(LTRIM(RTRIM(@title))) = 0
        THROW 55002, 'title is required.', 1;
    IF @gap_source_module_code NOT IN (
            N'Implementation', N'Assurance', N'Custom',
            N'Exception', N'Risk', N'Audit')
        THROW 55003, 'gap_source_module_code must be a known source.', 1;
    IF @priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @priority = N'Medium';

    BEGIN TRAN;

    IF @custom_gap_id IS NULL
    BEGIN
        INSERT INTO grac_practice.custom_gap(
            organization_id, gap_type_code,
            gap_source_module_code, source_reference_type, source_reference_id,
            title, description, priority, severity_code, severity_name,
            owner_employee_id, owner_display_name,
            assigned_reviewer_employee_id, assigned_reviewer_display_name,
            due_date, target_resolution_date,
            status, opened_dt,
            remediation_plan, remarks,
            entered_by, entered_dt)
        VALUES(
            @organization_id, ISNULL(@gap_type_code, @gap_source_module_code),
            @gap_source_module_code, @source_reference_type, @source_reference_id,
            @title, @description, @priority, @severity_code, @severity_name,
            @owner_employee_id, @owner_display_name,
            @assigned_reviewer_employee_id, @assigned_reviewer_display_name,
            @due_date, @target_resolution_date,
            N'Open', SYSUTCDATETIME(),
            @remediation_plan, @remarks,
            @actor, SYSUTCDATETIME());

        SET @custom_gap_id_out = SCOPE_IDENTITY();

        INSERT INTO grac_practice.custom_gap_history(
            custom_gap_id, organization_id, action_code,
            from_status_code, to_status_code,
            reason_text, actor_display_name, entered_by)
        VALUES(
            @custom_gap_id_out, @organization_id, N'CREATE',
            NULL, N'Open',
            N'Gap created.', @actor, @actor);
    END
    ELSE
    BEGIN
        DECLARE @gap_org BIGINT, @current_status NVARCHAR(60);
        SELECT @gap_org = organization_id, @current_status = status
        FROM grac_practice.custom_gap
        WHERE custom_gap_id = @custom_gap_id;

        IF @gap_org IS NULL       BEGIN ROLLBACK; THROW 55004, 'Gap not found.', 1; END
        IF @gap_org <> @organization_id
            BEGIN ROLLBACK; THROW 55005, 'Gap belongs to a different organization.', 1; END
        IF @current_status NOT IN (N'Open', N'InProgress', N'Reopened')
            BEGIN ROLLBACK; THROW 55006, 'Gap cannot be edited in its current status.', 1; END

        UPDATE grac_practice.custom_gap
        SET title                          = @title,
            description                    = @description,
            priority                       = @priority,
            severity_code                  = @severity_code,
            severity_name                  = @severity_name,
            owner_employee_id              = @owner_employee_id,
            owner_display_name             = @owner_display_name,
            assigned_reviewer_employee_id  = @assigned_reviewer_employee_id,
            assigned_reviewer_display_name = @assigned_reviewer_display_name,
            due_date                       = @due_date,
            target_resolution_date         = @target_resolution_date,
            remediation_plan               = @remediation_plan,
            remarks                        = @remarks,
            updated_by                     = @actor,
            updated_dt                     = SYSUTCDATETIME()
        WHERE custom_gap_id = @custom_gap_id;

        SET @custom_gap_id_out = @custom_gap_id;

        INSERT INTO grac_practice.custom_gap_history(
            custom_gap_id, organization_id, action_code,
            from_status_code, to_status_code,
            reason_text, actor_display_name, entered_by)
        VALUES(
            @custom_gap_id, @organization_id, N'EDIT',
            @current_status, @current_status,
            N'Gap edited.', @actor, @actor);
    END

    COMMIT;
END
GO

-- =====================================================================
-- sp_custom_gap_delete (unified soft-delete; Open only)
--   Cascades junction + actions deactivate; nulls
--   observation.gap_id pointers.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_delete
    @organization_id BIGINT,
    @custom_gap_id   BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @custom_gap_id IS NULL
        THROW 55000, 'organization_id and custom_gap_id are required.', 1;

    DECLARE @gap_org BIGINT, @status NVARCHAR(30);
    SELECT @gap_org = organization_id, @status = status
    FROM grac_practice.custom_gap
    WHERE custom_gap_id = @custom_gap_id;
    IF @gap_org IS NULL       THROW 55004, 'Gap not found.', 1;
    IF @gap_org <> @organization_id
        THROW 55005, 'Gap belongs to a different organization.', 1;
    IF @status <> N'Open'
        THROW 55007, 'Only Open gaps can be soft-deleted.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.custom_gap_observation
    SET is_active     = 0,
        detach_by     = @actor,
        detach_dt     = SYSUTCDATETIME(),
        detach_reason = N'Gap soft-deleted.'
    WHERE custom_gap_id = @custom_gap_id AND is_active = 1;

    IF OBJECT_ID('grac_practice.org_assurance_observation','U') IS NOT NULL
        UPDATE grac_practice.org_assurance_observation
        SET gap_id     = NULL,
            updated_by = @actor,
            updated_dt = SYSUTCDATETIME()
        WHERE gap_id = @custom_gap_id AND organization_id = @organization_id;

    UPDATE grac_practice.custom_gap_action
    SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE custom_gap_id = @custom_gap_id AND is_active = 1;

    -- We use status='Cancelled' as the soft-delete state on custom_gap
    -- because the table has no is_active column (kept schema-compatible
    -- with pre-054 usage).
    UPDATE grac_practice.custom_gap
    SET status     = N'Cancelled',
        closed_dt  = ISNULL(closed_dt, SYSUTCDATETIME()),
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE custom_gap_id = @custom_gap_id;

    INSERT INTO grac_practice.custom_gap_history(
        custom_gap_id, organization_id, action_code,
        from_status_code, to_status_code,
        reason_text, actor_display_name, entered_by)
    VALUES(
        @custom_gap_id, @organization_id, N'DELETE',
        N'Open', N'Cancelled',
        N'Soft-deleted.', @actor, @actor);

    COMMIT;
END
GO

-- =====================================================================
-- sp_custom_gap_generate_from_assurance_observation
--   The Assurance auto-hook target. Idempotent -- honours both any
--   active junction row AND legacy observation.gap_id pointer.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_generate_from_assurance_observation
    @organization_id BIGINT,
    @observation_id  BIGINT,
    @actor           NVARCHAR(100) = 'system',
    @custom_gap_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @observation_id IS NULL
        THROW 55010, 'organization_id and observation_id are required.', 1;

    DECLARE @obs_org BIGINT, @obs_status NVARCHAR(60), @existing_gap_id BIGINT,
            @sev_code NVARCHAR(30), @sev_name NVARCHAR(120),
            @exec_code NVARCHAR(120), @exec_name NVARCHAR(300),
            @dim_code NVARCHAR(60),   @dim_name NVARCHAR(160),
            @ent_code NVARCHAR(120),  @ent_name NVARCHAR(240),
            @obs_code NVARCHAR(120),  @obs_title NVARCHAR(300),
            @obs_desc NVARCHAR(MAX),
            @owner_id BIGINT,         @owner_name NVARCHAR(240),
            @reviewer_id BIGINT,      @reviewer_name NVARCHAR(240),
            @due_dt DATE;

    SELECT @obs_org         = o.organization_id,
           @obs_status      = st.status_code,
           @existing_gap_id = o.gap_id,
           @sev_code        = o.severity_code,
           @sev_name        = o.severity_name,
           @exec_code       = o.execution_code,
           @exec_name       = o.execution_name,
           @dim_code        = o.entity_dimension_code,
           @dim_name        = o.entity_dimension_name,
           @ent_code        = o.entity_code,
           @ent_name        = o.entity_name,
           @obs_code        = o.observation_code,
           @obs_title       = o.observation_title,
           @obs_desc        = o.observation_description,
           @owner_id        = o.assigned_owner_employee_id,
           @owner_name      = o.assigned_owner_display_name,
           @reviewer_id     = o.assigned_reviewer_employee_id,
           @reviewer_name   = o.assigned_reviewer_display_name,
           @due_dt          = o.due_date
    FROM grac_practice.org_assurance_observation o
    JOIN grac_practice.org_assurance_observation_status_master st
         ON st.org_assurance_observation_status_id = o.observation_status_id
    WHERE o.org_assurance_observation_id = @observation_id AND o.is_active = 1;

    IF @obs_org IS NULL       THROW 55011, 'Observation not found.', 1;
    IF @obs_org <> @organization_id
        THROW 55012, 'Observation belongs to a different organization.', 1;
    IF @obs_status <> N'Accepted'
        THROW 55013, 'Only Accepted observations can generate a gap.', 1;

    -- Idempotent -- if ANY active junction already exists for this
    -- observation, return the most-recently linked gap.
    DECLARE @junction_gap_id BIGINT = (
        SELECT TOP 1 custom_gap_id
        FROM grac_practice.custom_gap_observation
        WHERE org_assurance_observation_id = @observation_id
          AND organization_id              = @organization_id
          AND is_active = 1
        ORDER BY linked_dt DESC, custom_gap_observation_id DESC);
    IF @junction_gap_id IS NOT NULL
    BEGIN
        SET @custom_gap_id_out = @junction_gap_id;
        RETURN;
    END

    -- Legacy pointer -- if observation.gap_id already points at a
    -- valid active custom_gap, back-fill the junction and return.
    IF @existing_gap_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM grac_practice.custom_gap
                   WHERE custom_gap_id = @existing_gap_id
                     AND organization_id = @organization_id
                     AND status <> N'Cancelled')
    BEGIN
        SET @custom_gap_id_out = @existing_gap_id;
        IF NOT EXISTS (
            SELECT 1 FROM grac_practice.custom_gap_observation
            WHERE custom_gap_id                = @existing_gap_id
              AND org_assurance_observation_id = @observation_id
              AND is_active = 1)
            INSERT INTO grac_practice.custom_gap_observation(
                custom_gap_id, org_assurance_observation_id, organization_id,
                link_source, linked_by, linked_dt, is_active)
            VALUES(
                @existing_gap_id, @observation_id, @organization_id,
                N'AUTO', @actor, SYSUTCDATETIME(), 1);
        RETURN;
    END

    -- Otherwise create a new custom_gap + junction.
    DECLARE @priority NVARCHAR(30) =
        CASE @sev_code
            WHEN N'Critical'      THEN N'Critical'
            WHEN N'High'          THEN N'High'
            WHEN N'Medium'        THEN N'Medium'
            WHEN N'Low'           THEN N'Low'
            WHEN N'Informational' THEN N'Low'
            ELSE N'Medium'
        END;

    DECLARE @gap_title NVARCHAR(250) =
        LEFT(N'Gap: ' + ISNULL(@obs_title, N'(observation)'), 250);

    BEGIN TRAN;

    INSERT INTO grac_practice.custom_gap(
        organization_id, gap_type_code,
        gap_source_module_code, source_reference_type, source_reference_id,
        title, description, priority, severity_code, severity_name,
        owner_employee_id, owner_display_name,
        assigned_reviewer_employee_id, assigned_reviewer_display_name,
        due_date, target_resolution_date, status, opened_dt,
        execution_code, execution_name,
        entity_dimension_code, entity_dimension_name,
        entity_code, entity_name,
        observation_code, observation_title,
        entered_by, entered_dt)
    VALUES(
        @organization_id, N'Assurance',
        N'Assurance', N'AssuranceObservation', @observation_id,
        @gap_title, @obs_desc, @priority, @sev_code, @sev_name,
        @owner_id, @owner_name,
        @reviewer_id, @reviewer_name,
        @due_dt, @due_dt, N'Open', SYSUTCDATETIME(),
        @exec_code, @exec_name,
        @dim_code, @dim_name,
        @ent_code, @ent_name,
        @obs_code, @obs_title,
        @actor, SYSUTCDATETIME());

    SET @custom_gap_id_out = SCOPE_IDENTITY();

    INSERT INTO grac_practice.custom_gap_observation(
        custom_gap_id, org_assurance_observation_id, organization_id,
        link_source, linked_by, linked_dt, is_active)
    VALUES(
        @custom_gap_id_out, @observation_id, @organization_id,
        N'AUTO', @actor, SYSUTCDATETIME(), 1);

    -- Backward-compat pointer.
    UPDATE grac_practice.org_assurance_observation
    SET gap_id     = @custom_gap_id_out,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_observation_id = @observation_id;

    INSERT INTO grac_practice.custom_gap_history(
        custom_gap_id, organization_id, action_code,
        from_status_code, to_status_code,
        reason_text, actor_display_name, entered_by)
    VALUES(
        @custom_gap_id_out, @organization_id, N'AUTO_GENERATED',
        NULL, N'Open',
        N'Auto-generated from Assurance Observation #' + CAST(@observation_id AS NVARCHAR(20)),
        @actor, @actor);

    COMMIT;
END
GO

-- =====================================================================
-- Shared lifecycle transition helper
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_transition
    @organization_id     BIGINT,
    @custom_gap_id       BIGINT,
    @expected_from_codes NVARCHAR(200),
    @to_code             NVARCHAR(30),
    @stamp_field         NVARCHAR(30) = NULL,
    @notes               NVARCHAR(MAX) = NULL,
    @actor               NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @custom_gap_id IS NULL
        THROW 55000, 'organization_id and custom_gap_id are required.', 1;

    DECLARE @gap_org BIGINT, @current NVARCHAR(30);
    SELECT @gap_org = organization_id, @current = status
    FROM grac_practice.custom_gap
    WHERE custom_gap_id = @custom_gap_id;
    IF @gap_org IS NULL       THROW 55004, 'Gap not found.', 1;
    IF @gap_org <> @organization_id
        THROW 55005, 'Gap belongs to a different organization.', 1;

    DECLARE @allowed TABLE(code NVARCHAR(60));
    INSERT INTO @allowed(code)
    SELECT LTRIM(RTRIM(value))
    FROM STRING_SPLIT(@expected_from_codes, ',')
    WHERE LTRIM(RTRIM(value)) <> '';
    IF NOT EXISTS (SELECT 1 FROM @allowed WHERE code = @current)
        THROW 55008, 'Illegal gap lifecycle transition -- current status does not match the expected source.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.custom_gap
    SET status = @to_code,
        remediation_submitted_dt = CASE WHEN @stamp_field = N'remediation_submitted' AND remediation_submitted_dt IS NULL THEN SYSUTCDATETIME() ELSE remediation_submitted_dt END,
        verified_dt              = CASE WHEN @stamp_field = N'verified' AND verified_dt IS NULL THEN SYSUTCDATETIME() ELSE verified_dt END,
        closed_dt                = CASE WHEN @stamp_field = N'closed'   AND closed_dt   IS NULL THEN SYSUTCDATETIME() ELSE closed_dt   END,
        reopened_dt              = CASE WHEN @stamp_field = N'reopened' THEN SYSUTCDATETIME() ELSE reopened_dt END,
        resolution_notes   = CASE WHEN @stamp_field = N'remediation_submitted' THEN ISNULL(@notes, resolution_notes)   ELSE resolution_notes END,
        verification_notes = CASE WHEN @stamp_field = N'verified'              THEN ISNULL(@notes, verification_notes) ELSE verification_notes END,
        closure_notes      = CASE WHEN @stamp_field = N'closed'                THEN ISNULL(@notes, closure_notes)      ELSE closure_notes END,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE custom_gap_id = @custom_gap_id;

    INSERT INTO grac_practice.custom_gap_history(
        custom_gap_id, organization_id, action_code,
        from_status_code, to_status_code,
        reason_text, actor_display_name, entered_by)
    VALUES(
        @custom_gap_id, @organization_id, UPPER(@to_code),
        @current, @to_code,
        @notes, @actor, @actor);

    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_start
    @organization_id BIGINT, @custom_gap_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_custom_gap_transition
        @organization_id, @custom_gap_id,
        N'Open,Reopened', N'InProgress',
        NULL, @notes, @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_submit_remediation
    @organization_id BIGINT, @custom_gap_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_custom_gap_transition
        @organization_id, @custom_gap_id,
        N'InProgress', N'RemediationSubmitted',
        N'remediation_submitted', @notes, @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_verify
    @organization_id BIGINT, @custom_gap_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_custom_gap_transition
        @organization_id, @custom_gap_id,
        N'RemediationSubmitted', N'Verified',
        N'verified', @notes, @actor;
END
GO

-- Named _close_lifecycle to avoid conflict with legacy sp_custom_gap_close
-- (055) which has a different signature.
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_close_lifecycle
    @organization_id BIGINT, @custom_gap_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_custom_gap_transition
        @organization_id, @custom_gap_id,
        N'Verified', N'Closed',
        N'closed', @notes, @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_reopen
    @organization_id BIGINT, @custom_gap_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_custom_gap_transition
        @organization_id, @custom_gap_id,
        N'Closed,Verified', N'Reopened',
        N'reopened', @notes, @actor;
END
GO

-- =====================================================================
-- Junction: attach / detach / list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_observation_attach
    @organization_id BIGINT,
    @custom_gap_id   BIGINT,
    @observation_id  BIGINT,
    @link_source     NVARCHAR(30)  = N'MANUAL',
    @notes           NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100) = 'system',
    @junction_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @custom_gap_id IS NULL OR @observation_id IS NULL
        THROW 55020, 'organization_id, custom_gap_id and observation_id are required.', 1;
    IF @link_source NOT IN (N'AUTO', N'MANUAL', N'MERGE')
        THROW 55021, 'link_source must be AUTO / MANUAL / MERGE.', 1;

    DECLARE @gap_org BIGINT;
    SELECT @gap_org = organization_id
    FROM grac_practice.custom_gap
    WHERE custom_gap_id = @custom_gap_id;
    IF @gap_org IS NULL       THROW 55004, 'Gap not found.', 1;
    IF @gap_org <> @organization_id
        THROW 55005, 'Gap belongs to a different organization.', 1;

    DECLARE @obs_org BIGINT, @obs_gap_id BIGINT;
    SELECT @obs_org = organization_id, @obs_gap_id = gap_id
    FROM grac_practice.org_assurance_observation
    WHERE org_assurance_observation_id = @observation_id AND is_active = 1;
    IF @obs_org IS NULL       THROW 55022, 'Observation not found.', 1;
    IF @obs_org <> @organization_id
        THROW 55023, 'Observation belongs to a different organization.', 1;

    BEGIN TRAN;

    SELECT @junction_id_out = custom_gap_observation_id
    FROM grac_practice.custom_gap_observation
    WHERE custom_gap_id                = @custom_gap_id
      AND org_assurance_observation_id = @observation_id
      AND is_active = 1;

    IF @junction_id_out IS NULL
    BEGIN
        INSERT INTO grac_practice.custom_gap_observation(
            custom_gap_id, org_assurance_observation_id, organization_id,
            link_source, linked_by, linked_dt, notes, is_active)
        VALUES(
            @custom_gap_id, @observation_id, @organization_id,
            @link_source, @actor, SYSUTCDATETIME(), @notes, 1);
        SET @junction_id_out = SCOPE_IDENTITY();
    END

    IF @obs_gap_id IS NULL
        UPDATE grac_practice.org_assurance_observation
        SET gap_id = @custom_gap_id, updated_by = @actor, updated_dt = SYSUTCDATETIME()
        WHERE org_assurance_observation_id = @observation_id;

    INSERT INTO grac_practice.custom_gap_history(
        custom_gap_id, organization_id, action_code, reason_text,
        actor_display_name, entered_by)
    VALUES(
        @custom_gap_id, @organization_id, N'ATTACH_OBSERVATION',
        N'Observation #' + CAST(@observation_id AS NVARCHAR(20)) +
            N' attached (' + @link_source + N').' +
            CASE WHEN @notes IS NULL THEN N'' ELSE N' Note: ' + @notes END,
        @actor, @actor);

    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_observation_detach
    @organization_id BIGINT,
    @custom_gap_id   BIGINT,
    @observation_id  BIGINT,
    @reason          NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @custom_gap_id IS NULL OR @observation_id IS NULL
        THROW 55020, 'organization_id, custom_gap_id and observation_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.custom_gap_observation
        WHERE custom_gap_id                = @custom_gap_id
          AND org_assurance_observation_id = @observation_id
          AND organization_id              = @organization_id
          AND is_active = 1)
        THROW 55024, 'Active junction row not found.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.custom_gap_observation
    SET is_active     = 0,
        detach_by     = @actor,
        detach_dt     = SYSUTCDATETIME(),
        detach_reason = @reason
    WHERE custom_gap_id                = @custom_gap_id
      AND org_assurance_observation_id = @observation_id
      AND is_active = 1;

    IF EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_observation
        WHERE org_assurance_observation_id = @observation_id
          AND gap_id = @custom_gap_id)
    BEGIN
        DECLARE @next_gap BIGINT = (
            SELECT TOP 1 custom_gap_id
            FROM grac_practice.custom_gap_observation
            WHERE org_assurance_observation_id = @observation_id
              AND is_active = 1
            ORDER BY linked_dt DESC, custom_gap_observation_id DESC);
        UPDATE grac_practice.org_assurance_observation
        SET gap_id = @next_gap, updated_by = @actor, updated_dt = SYSUTCDATETIME()
        WHERE org_assurance_observation_id = @observation_id;
    END

    INSERT INTO grac_practice.custom_gap_history(
        custom_gap_id, organization_id, action_code, reason_text,
        actor_display_name, entered_by)
    VALUES(
        @custom_gap_id, @organization_id, N'DETACH_OBSERVATION',
        N'Observation #' + CAST(@observation_id AS NVARCHAR(20)) + N' detached.'
        + CASE WHEN @reason IS NULL THEN N'' ELSE N' Reason: ' + @reason END,
        @actor, @actor);

    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_observation_list
    @organization_id  BIGINT,
    @custom_gap_id    BIGINT,
    @include_detached BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @custom_gap_id IS NULL
        THROW 55020, 'organization_id and custom_gap_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.custom_gap
        WHERE custom_gap_id = @custom_gap_id
          AND organization_id = @organization_id)
        THROW 55005, 'Gap belongs to a different organization.', 1;

    SELECT j.custom_gap_observation_id  AS JunctionId,
           j.custom_gap_id               AS GapId,
           j.org_assurance_observation_id AS ObservationId,
           o.observation_code            AS ObservationCode,
           o.observation_title           AS ObservationTitle,
           o.severity_code               AS SeverityCode,
           o.severity_name               AS SeverityName,
           os.status_code                AS ObservationStatusCode,
           os.status_name                AS ObservationStatusName,
           o.execution_code              AS ExecutionCode,
           o.execution_name              AS ExecutionName,
           o.entity_name                 AS EntityName,
           j.link_source                 AS LinkSource,
           j.linked_by                   AS LinkedBy,
           j.linked_dt                   AS LinkedDt,
           j.notes                       AS Notes,
           j.is_active                   AS IsActive,
           j.detach_by                   AS DetachBy,
           j.detach_dt                   AS DetachDt,
           j.detach_reason               AS DetachReason
    FROM grac_practice.custom_gap_observation j
    JOIN grac_practice.org_assurance_observation o
         ON o.org_assurance_observation_id = j.org_assurance_observation_id
    JOIN grac_practice.org_assurance_observation_status_master os
         ON os.org_assurance_observation_status_id = o.observation_status_id
    WHERE j.custom_gap_id   = @custom_gap_id
      AND j.organization_id = @organization_id
      AND (@include_detached = 1 OR j.is_active = 1)
    ORDER BY j.is_active DESC, j.linked_dt DESC, j.custom_gap_observation_id DESC;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_observation_linked_custom_gaps_list
    @organization_id  BIGINT,
    @observation_id   BIGINT,
    @include_detached BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @observation_id IS NULL
        THROW 55020, 'organization_id and observation_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_observation
        WHERE org_assurance_observation_id = @observation_id
          AND organization_id              = @organization_id)
        THROW 55023, 'Observation belongs to a different organization.', 1;

    SELECT j.custom_gap_observation_id AS JunctionId,
           j.custom_gap_id              AS GapId,
           g.title                       AS GapTitle,
           g.gap_source_module_code      AS SourceModule,
           g.severity_code               AS SeverityCode,
           g.severity_name               AS SeverityName,
           g.status                      AS GapStatusCode,
           j.link_source                 AS LinkSource,
           j.linked_by                   AS LinkedBy,
           j.linked_dt                   AS LinkedDt,
           j.notes                       AS Notes,
           j.is_active                   AS IsActive,
           j.detach_by                   AS DetachBy,
           j.detach_dt                   AS DetachDt,
           j.detach_reason               AS DetachReason
    FROM grac_practice.custom_gap_observation j
    JOIN grac_practice.custom_gap g
         ON g.custom_gap_id = j.custom_gap_id
    WHERE j.org_assurance_observation_id = @observation_id
      AND j.organization_id              = @organization_id
      AND (@include_detached = 1 OR j.is_active = 1)
    ORDER BY j.is_active DESC, j.linked_dt DESC, j.custom_gap_observation_id DESC;
END
GO

-- =====================================================================
-- Merge -- copies source gap's observations to target, closes source
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_merge
    @organization_id BIGINT,
    @source_gap_id   BIGINT,
    @target_gap_id   BIGINT,
    @reason          NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @source_gap_id IS NULL OR @target_gap_id IS NULL
        THROW 55030, 'organization_id, source_gap_id and target_gap_id are required.', 1;
    IF @source_gap_id = @target_gap_id
        THROW 55031, 'A gap cannot be merged into itself.', 1;

    DECLARE @source_org BIGINT, @source_status NVARCHAR(30);
    SELECT @source_org = organization_id, @source_status = status
    FROM grac_practice.custom_gap WHERE custom_gap_id = @source_gap_id;
    IF @source_org IS NULL       THROW 55032, 'Source gap not found.', 1;
    IF @source_org <> @organization_id
        THROW 55033, 'Source gap belongs to a different organization.', 1;
    IF @source_status = N'Closed' OR @source_status = N'Cancelled'
        THROW 55034, 'Closed or Cancelled gaps cannot be merged.', 1;

    DECLARE @target_org BIGINT, @target_status NVARCHAR(30);
    SELECT @target_org = organization_id, @target_status = status
    FROM grac_practice.custom_gap WHERE custom_gap_id = @target_gap_id;
    IF @target_org IS NULL       THROW 55035, 'Target gap not found.', 1;
    IF @target_org <> @organization_id
        THROW 55036, 'Target gap belongs to a different organization.', 1;
    IF @target_status = N'Closed' OR @target_status = N'Cancelled'
        THROW 55037, 'Target gap is Closed / Cancelled -- cannot receive merged observations.', 1;

    DECLARE @merge_note NVARCHAR(400) =
        N'Merged into gap #' + CAST(@target_gap_id AS NVARCHAR(20))
        + CASE WHEN @reason IS NULL THEN N'' ELSE N': ' + @reason END;

    BEGIN TRAN;

    DECLARE @moved TABLE(observation_id BIGINT PRIMARY KEY);
    INSERT INTO @moved(observation_id)
    SELECT DISTINCT org_assurance_observation_id
    FROM grac_practice.custom_gap_observation
    WHERE custom_gap_id = @source_gap_id AND is_active = 1;

    INSERT INTO grac_practice.custom_gap_observation(
        custom_gap_id, org_assurance_observation_id, organization_id,
        link_source, linked_by, linked_dt, notes, is_active)
    SELECT @target_gap_id, m.observation_id, @organization_id,
           N'MERGE', @actor, SYSUTCDATETIME(), @merge_note, 1
    FROM @moved m
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.custom_gap_observation j
        WHERE j.custom_gap_id                = @target_gap_id
          AND j.org_assurance_observation_id = m.observation_id
          AND j.is_active = 1);

    UPDATE grac_practice.custom_gap_observation
    SET is_active = 0,
        detach_by = @actor,
        detach_dt = SYSUTCDATETIME(),
        detach_reason = @merge_note
    WHERE custom_gap_id = @source_gap_id AND is_active = 1;

    UPDATE grac_practice.org_assurance_observation
    SET gap_id = @target_gap_id, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE gap_id = @source_gap_id AND organization_id = @organization_id;

    UPDATE grac_practice.custom_gap
    SET status = N'Closed',
        closed_dt = ISNULL(closed_dt, SYSUTCDATETIME()),
        closure_notes = ISNULL(closure_notes, @merge_note),
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE custom_gap_id = @source_gap_id;

    INSERT INTO grac_practice.custom_gap_history(
        custom_gap_id, organization_id, action_code,
        from_status_code, to_status_code,
        reason_text, actor_display_name, entered_by)
    VALUES(
        @source_gap_id, @organization_id, N'MERGED_INTO',
        @source_status, N'Closed', @merge_note, @actor, @actor);

    INSERT INTO grac_practice.custom_gap_history(
        custom_gap_id, organization_id, action_code,
        reason_text, actor_display_name, entered_by)
    VALUES(
        @target_gap_id, @organization_id, N'MERGE_RECEIVED',
        N'Received observations from merged gap #' + CAST(@source_gap_id AS NVARCHAR(20))
        + CASE WHEN @reason IS NULL THEN N'' ELSE N': ' + @reason END,
        @actor, @actor);

    COMMIT;
END
GO

-- =====================================================================
-- Corrective actions
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_action_list
    @organization_id BIGINT, @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @custom_gap_id IS NULL
        THROW 55040, 'organization_id and custom_gap_id are required.', 1;
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.custom_gap
        WHERE custom_gap_id = @custom_gap_id
          AND organization_id = @organization_id)
        THROW 55005, 'Gap belongs to a different organization.', 1;

    SELECT a.custom_gap_action_id AS ActionId,
           a.custom_gap_id         AS GapId,
           a.action_order          AS ActionOrder,
           a.action_title          AS ActionTitle,
           a.action_description    AS ActionDescription,
           a.assigned_employee_id  AS AssignedEmployeeId,
           a.assigned_display_name AS AssignedDisplayName,
           a.due_date              AS DueDate,
           a.completed_dt          AS CompletedDt,
           a.action_status_code    AS ActionStatusCode,
           a.task_id               AS TaskId,
           a.notes                 AS Notes,
           a.entered_by, a.entered_dt, a.updated_by, a.updated_dt
    FROM grac_practice.custom_gap_action a
    WHERE a.custom_gap_id = @custom_gap_id
      AND a.organization_id = @organization_id
      AND a.is_active = 1
    ORDER BY a.action_order, a.custom_gap_action_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_action_save
    @organization_id       BIGINT,
    @custom_gap_id         BIGINT,
    @action_id             BIGINT        = NULL,
    @action_order          INT           = 0,
    @action_title          NVARCHAR(300),
    @action_description    NVARCHAR(MAX) = NULL,
    @assigned_employee_id  BIGINT        = NULL,
    @assigned_display_name NVARCHAR(240) = NULL,
    @due_date              DATE          = NULL,
    @action_status_code    NVARCHAR(30)  = N'Pending',
    @notes                 NVARCHAR(MAX) = NULL,
    @actor                 NVARCHAR(100) = 'system',
    @action_id_out         BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @custom_gap_id IS NULL
        THROW 55040, 'organization_id and custom_gap_id are required.', 1;
    IF @action_title IS NULL OR LEN(LTRIM(RTRIM(@action_title))) = 0
        THROW 55041, 'action_title is required.', 1;
    IF @action_status_code NOT IN (N'Pending', N'InProgress', N'Completed', N'Cancelled')
        THROW 55042, 'action_status_code must be Pending / InProgress / Completed / Cancelled.', 1;

    DECLARE @gap_org BIGINT, @gap_status NVARCHAR(30);
    SELECT @gap_org = organization_id, @gap_status = status
    FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;
    IF @gap_org IS NULL       THROW 55004, 'Gap not found.', 1;
    IF @gap_org <> @organization_id
        THROW 55005, 'Gap belongs to a different organization.', 1;
    IF @gap_status IN (N'Closed', N'Cancelled')
        THROW 55043, 'Actions cannot be modified on Closed / Cancelled gaps.', 1;

    BEGIN TRAN;

    IF @action_id IS NULL
    BEGIN
        INSERT INTO grac_practice.custom_gap_action(
            custom_gap_id, organization_id,
            action_order, action_title, action_description,
            assigned_employee_id, assigned_display_name,
            due_date, action_status_code, notes,
            is_active, entered_by, entered_dt)
        VALUES(
            @custom_gap_id, @organization_id,
            @action_order, @action_title, @action_description,
            @assigned_employee_id, @assigned_display_name,
            @due_date, @action_status_code, @notes,
            1, @actor, SYSUTCDATETIME());
        SET @action_id_out = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @act_gap BIGINT;
        SELECT @act_gap = custom_gap_id
        FROM grac_practice.custom_gap_action
        WHERE custom_gap_action_id = @action_id AND is_active = 1;
        IF @act_gap IS NULL       BEGIN ROLLBACK; THROW 55044, 'Gap action not found.', 1; END
        IF @act_gap <> @custom_gap_id
            BEGIN ROLLBACK; THROW 55045, 'Gap action does not belong to this gap.', 1; END

        UPDATE grac_practice.custom_gap_action
        SET action_order          = @action_order,
            action_title          = @action_title,
            action_description    = @action_description,
            assigned_employee_id  = @assigned_employee_id,
            assigned_display_name = @assigned_display_name,
            due_date              = @due_date,
            action_status_code    = @action_status_code,
            completed_dt          =
                CASE WHEN @action_status_code = N'Completed' AND completed_dt IS NULL
                     THEN SYSUTCDATETIME() ELSE completed_dt END,
            notes                 = @notes,
            updated_by            = @actor,
            updated_dt            = SYSUTCDATETIME()
        WHERE custom_gap_action_id = @action_id;
        SET @action_id_out = @action_id;
    END

    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_action_complete
    @organization_id BIGINT, @custom_gap_id BIGINT, @action_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @custom_gap_id IS NULL OR @action_id IS NULL
        THROW 55040, 'organization_id, custom_gap_id and action_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.custom_gap_action a
        JOIN grac_practice.custom_gap g ON g.custom_gap_id = a.custom_gap_id
        WHERE a.custom_gap_action_id = @action_id
          AND a.custom_gap_id        = @custom_gap_id
          AND g.organization_id      = @organization_id
          AND a.is_active = 1)
        THROW 55044, 'Gap action not found.', 1;

    UPDATE grac_practice.custom_gap_action
    SET action_status_code = N'Completed',
        completed_dt = ISNULL(completed_dt, SYSUTCDATETIME()),
        notes        = COALESCE(@notes, notes),
        updated_by   = @actor,
        updated_dt   = SYSUTCDATETIME()
    WHERE custom_gap_action_id = @action_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_action_delete
    @organization_id BIGINT, @custom_gap_id BIGINT, @action_id BIGINT,
    @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @custom_gap_id IS NULL OR @action_id IS NULL
        THROW 55040, 'organization_id, custom_gap_id and action_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.custom_gap_action a
        JOIN grac_practice.custom_gap g ON g.custom_gap_id = a.custom_gap_id
        WHERE a.custom_gap_action_id = @action_id
          AND a.custom_gap_id        = @custom_gap_id
          AND g.organization_id      = @organization_id
          AND a.is_active = 1)
        THROW 55044, 'Gap action not found.', 1;

    UPDATE grac_practice.custom_gap_action
    SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE custom_gap_action_id = @action_id;
END
GO

-- =====================================================================
-- History
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_history_list
    @organization_id BIGINT, @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @custom_gap_id IS NULL
        THROW 55050, 'organization_id and custom_gap_id are required.', 1;
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.custom_gap
        WHERE custom_gap_id = @custom_gap_id
          AND organization_id = @organization_id)
        THROW 55005, 'Gap belongs to a different organization.', 1;

    SELECT h.custom_gap_history_id AS HistoryId,
           h.action_code            AS ActionCode,
           h.from_status_code       AS FromStatusCode,
           h.to_status_code         AS ToStatusCode,
           h.reason_text            AS ReasonText,
           h.actor_display_name     AS ActorDisplayName,
           h.entered_by             AS EnteredBy,
           h.entered_dt             AS EnteredDt
    FROM grac_practice.custom_gap_history h
    WHERE h.custom_gap_id = @custom_gap_id
    ORDER BY h.entered_dt DESC, h.custom_gap_history_id DESC;
END
GO

-- =====================================================================
-- Retarget the Assurance accept auto-hook to the unified generator.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_accept
    @organization_id BIGINT, @observation_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;

    EXEC grac_practice.sp_org_assurance_observation_transition
        @organization_id = @organization_id, @observation_id = @observation_id,
        @expected_from_codes = N'InReview', @to_code = N'Accepted',
        @stamp_field = N'accepted', @notes = @notes, @actor = @actor;

    -- Auto-generate a gap in the unified custom_gap Gap Center.
    IF OBJECT_ID('grac_practice.sp_custom_gap_generate_from_assurance_observation','P') IS NOT NULL
    BEGIN
        DECLARE @new_gap_id BIGINT;
        BEGIN TRY
            EXEC grac_practice.sp_custom_gap_generate_from_assurance_observation
                @organization_id = @organization_id,
                @observation_id  = @observation_id,
                @actor           = @actor,
                @custom_gap_id_out = @new_gap_id OUTPUT;
        END TRY
        BEGIN CATCH
            PRINT N'sp_org_assurance_observation_accept: custom_gap generation failed -- ' + ERROR_MESSAGE();
        END CATCH
    END
END
GO

PRINT '112 Custom Gap unified procedures deployed.';
GO
