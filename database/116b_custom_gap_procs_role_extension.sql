-- =====================================================================
-- 116b Custom Gap SP rewrites for hybrid role+employee ownership.
--
-- Depends on: 109 + 110 + 112 (base custom_gap procs), 115 (role
--             columns on custom_gap + custom_gap_action), 117
--             (role-holder helpers).
--
-- Rewrites:
--   sp_custom_gap_save                         (owner + reviewer role params)
--   sp_custom_gap_generate_from_assurance_observation
--                                              (carry role snapshot from
--                                               observation onto the gap)
--   sp_custom_gap_action_save                  (assignee role params)
--   sp_custom_gap_list / _get / _action_list   (return role columns)
--
-- Same auto-resolve rules as 116a (per Q1-A).
--
-- Rollback: 116b_custom_gap_procs_role_extension_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap','owner_role_id') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_role_primary_holder_pick','P') IS NULL
BEGIN
    RAISERROR('116b: run 109 + 112 + 115 + 117 first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_custom_gap_save  (extended with 4 role params)
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
    -- 116b hybrid ownership -- new nullable role params
    @owner_role_id                  BIGINT       = NULL,
    @owner_role_name                NVARCHAR(120) = NULL,
    @assigned_reviewer_role_id      BIGINT       = NULL,
    @assigned_reviewer_role_name    NVARCHAR(120) = NULL,
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

    -- ==========================================================
    -- Owner hybrid resolver
    -- ==========================================================
    IF @owner_role_id IS NOT NULL
       AND (@owner_role_name IS NULL OR LEN(LTRIM(RTRIM(@owner_role_name))) = 0)
        SELECT @owner_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @owner_role_id AND organization_id = @organization_id;

    IF @owner_role_id IS NOT NULL AND @owner_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id      = @organization_id,
             @role_id              = @owner_role_id,
             @employee_id_out      = @owner_employee_id     OUTPUT,
             @employee_name_out    = @owner_display_name    OUTPUT;

    IF @owner_employee_id IS NOT NULL AND @owner_role_id IS NULL
    BEGIN
        SELECT @owner_role_id = e.role_id,
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

    -- ==========================================================
    -- Reviewer hybrid resolver (same shape)
    -- ==========================================================
    IF @assigned_reviewer_role_id IS NOT NULL
       AND (@assigned_reviewer_role_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_reviewer_role_name))) = 0)
        SELECT @assigned_reviewer_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @assigned_reviewer_role_id AND organization_id = @organization_id;

    IF @assigned_reviewer_role_id IS NOT NULL AND @assigned_reviewer_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id      = @organization_id,
             @role_id              = @assigned_reviewer_role_id,
             @employee_id_out      = @assigned_reviewer_employee_id   OUTPUT,
             @employee_name_out    = @assigned_reviewer_display_name  OUTPUT;

    IF @assigned_reviewer_employee_id IS NOT NULL AND @assigned_reviewer_role_id IS NULL
    BEGIN
        SELECT @assigned_reviewer_role_id = e.role_id,
               @assigned_reviewer_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @assigned_reviewer_employee_id
          AND e.organization_id = @organization_id;
    END

    IF @assigned_reviewer_employee_id IS NOT NULL
       AND (@assigned_reviewer_display_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_reviewer_display_name))) = 0)
        SELECT @assigned_reviewer_display_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @assigned_reviewer_employee_id;

    BEGIN TRAN;

    IF @custom_gap_id IS NULL
    BEGIN
        INSERT INTO grac_practice.custom_gap(
            organization_id, gap_type_code,
            gap_source_module_code, source_reference_type, source_reference_id,
            title, description, priority, severity_code, severity_name,
            owner_employee_id, owner_display_name,
            owner_role_id, owner_role_name,
            assigned_reviewer_employee_id, assigned_reviewer_display_name,
            assigned_reviewer_role_id, assigned_reviewer_role_name,
            due_date, target_resolution_date,
            status, opened_dt,
            remediation_plan, remarks,
            entered_by, entered_dt)
        VALUES(
            @organization_id, ISNULL(@gap_type_code, @gap_source_module_code),
            @gap_source_module_code, @source_reference_type, @source_reference_id,
            @title, @description, @priority, @severity_code, @severity_name,
            @owner_employee_id, @owner_display_name,
            @owner_role_id, @owner_role_name,
            @assigned_reviewer_employee_id, @assigned_reviewer_display_name,
            @assigned_reviewer_role_id, @assigned_reviewer_role_name,
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
            NULL, N'Open', N'Gap created.', @actor, @actor);
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
            owner_role_id                  = @owner_role_id,
            owner_role_name                = @owner_role_name,
            assigned_reviewer_employee_id  = @assigned_reviewer_employee_id,
            assigned_reviewer_display_name = @assigned_reviewer_display_name,
            assigned_reviewer_role_id      = @assigned_reviewer_role_id,
            assigned_reviewer_role_name    = @assigned_reviewer_role_name,
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
            @current_status, @current_status, N'Gap edited.', @actor, @actor);
    END

    COMMIT;
END
GO

-- =====================================================================
-- sp_custom_gap_generate_from_assurance_observation
--   Extended to carry the observation's role snapshots onto the gap.
--   Same idempotency rules as 112.
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
            @owner_role_id BIGINT,    @owner_role_name NVARCHAR(120),
            @reviewer_id BIGINT,      @reviewer_name NVARCHAR(240),
            @reviewer_role_id BIGINT, @reviewer_role_name NVARCHAR(120),
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
           @owner_role_id   = o.assigned_owner_role_id,
           @owner_role_name = o.assigned_owner_role_name,
           @reviewer_id     = o.assigned_reviewer_employee_id,
           @reviewer_name   = o.assigned_reviewer_display_name,
           @reviewer_role_id   = o.assigned_reviewer_role_id,
           @reviewer_role_name = o.assigned_reviewer_role_name,
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

    -- Idempotent junction check.
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

    -- Legacy pointer -- back-fill missing junction if pointer valid.
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
        owner_role_id, owner_role_name,
        assigned_reviewer_employee_id, assigned_reviewer_display_name,
        assigned_reviewer_role_id, assigned_reviewer_role_name,
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
        @owner_role_id, @owner_role_name,
        @reviewer_id, @reviewer_name,
        @reviewer_role_id, @reviewer_role_name,
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
-- sp_custom_gap_action_save (extended -- assignee role)
-- =====================================================================
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
    -- 116b hybrid
    @assigned_role_id      BIGINT        = NULL,
    @assigned_role_name    NVARCHAR(120) = NULL,
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

    -- Hybrid resolver -- assignee
    IF @assigned_role_id IS NOT NULL
       AND (@assigned_role_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_role_name))) = 0)
        SELECT @assigned_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @assigned_role_id AND organization_id = @organization_id;

    IF @assigned_role_id IS NOT NULL AND @assigned_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id      = @organization_id,
             @role_id              = @assigned_role_id,
             @employee_id_out      = @assigned_employee_id   OUTPUT,
             @employee_name_out    = @assigned_display_name  OUTPUT;

    IF @assigned_employee_id IS NOT NULL AND @assigned_role_id IS NULL
    BEGIN
        SELECT @assigned_role_id = e.role_id,
               @assigned_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @assigned_employee_id
          AND e.organization_id = @organization_id;
    END

    IF @assigned_employee_id IS NOT NULL
       AND (@assigned_display_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_display_name))) = 0)
        SELECT @assigned_display_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @assigned_employee_id;

    BEGIN TRAN;

    IF @action_id IS NULL
    BEGIN
        INSERT INTO grac_practice.custom_gap_action(
            custom_gap_id, organization_id,
            action_order, action_title, action_description,
            assigned_employee_id, assigned_display_name,
            assigned_role_id, assigned_role_name,
            due_date, action_status_code, notes,
            is_active, entered_by, entered_dt)
        VALUES(
            @custom_gap_id, @organization_id,
            @action_order, @action_title, @action_description,
            @assigned_employee_id, @assigned_display_name,
            @assigned_role_id, @assigned_role_name,
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
            assigned_role_id      = @assigned_role_id,
            assigned_role_name    = @assigned_role_name,
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

-- =====================================================================
-- sp_custom_gap_action_list  (adds role columns to output)
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
           a.assigned_role_id      AS AssignedRoleId,
           a.assigned_role_name    AS AssignedRoleName,
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

-- =====================================================================
-- sp_custom_gap_list  (adds role columns to output; signature preserved)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_list
    @organization_id       BIGINT       = NULL,
    @status_code           NVARCHAR(30) = NULL,
    @priority              NVARCHAR(30) = NULL,
    @owner_employee_id     BIGINT       = NULL,
    @search                NVARCHAR(200) = NULL,
    @page                  INT          = 1,
    @page_size             INT          = 25,
    @gap_source_module_code NVARCHAR(30) = NULL,
    @severity_code         NVARCHAR(30)  = NULL,
    @observation_id        BIGINT        = NULL,
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
               g.owner_role_id,
               g.owner_role_name,
               g.assigned_reviewer_employee_id,
               g.assigned_reviewer_display_name,
               g.assigned_reviewer_role_id,
               g.assigned_reviewer_role_name,
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
               g.owner_role_id,
               g.owner_role_name,
               g.assigned_reviewer_employee_id,
               g.assigned_reviewer_display_name,
               g.assigned_reviewer_role_id,
               g.assigned_reviewer_role_name,
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
-- sp_custom_gap_get (adds 4 role columns to detail)
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
           g.owner_role_id,
           g.owner_role_name,
           g.assigned_reviewer_employee_id,
           g.assigned_reviewer_display_name,
           g.assigned_reviewer_role_id,
           g.assigned_reviewer_role_name,
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

PRINT '116b Custom Gap SPs extended for role+employee hybrid.';
GO
