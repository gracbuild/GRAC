-- =====================================================================
-- 105 Organization Assurance Gap Management -- Stage 4 stored procedures
--
-- Depends on 101 (observation) + 102 (observation procs) + 104 (gap
-- schema).
--
-- Procedures:
--   sp_org_assurance_gap_status_list
--   sp_org_assurance_gap_list
--   sp_org_assurance_gap_get
--   sp_org_assurance_gap_save                        Manual create + update
--   sp_org_assurance_gap_delete                      Soft (Open only)
--   sp_org_assurance_gap_generate_from_observation   Idempotent engine
--   sp_org_assurance_gap_transition                  Shared helper
--   sp_org_assurance_gap_start                       Open      -> InProgress
--   sp_org_assurance_gap_submit_remediation          InProgress -> RemediationSubmitted
--   sp_org_assurance_gap_verify                      RemediationSubmitted -> Verified
--   sp_org_assurance_gap_close                       Verified  -> Closed
--   sp_org_assurance_gap_reopen                      Closed    -> Reopened
--   sp_org_assurance_gap_action_list
--   sp_org_assurance_gap_action_save
--   sp_org_assurance_gap_action_delete
--   sp_org_assurance_gap_action_complete
--   sp_org_assurance_gap_history_list
--
-- Plus: CREATE OR ALTER sp_org_assurance_observation_accept -- re-defined
-- so accepting an observation auto-fires the gap generator (guarded).
--
-- THROW reason codes: 54200-54299.
-- Rollback: 105_org_assurance_gap_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_gap','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_gap_action','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_gap_status_master','U') IS NULL
BEGIN
    RAISERROR('105: run 104 schema first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- Lookup
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_status_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT org_assurance_gap_status_id AS StatusId,
           status_code   AS StatusCode,
           status_name   AS StatusName,
           display_order AS DisplayOrder,
           is_terminal   AS IsTerminal
    FROM grac_practice.org_assurance_gap_status_master
    WHERE is_active = 1
    ORDER BY display_order, org_assurance_gap_status_id;
END
GO

-- =====================================================================
-- sp_org_assurance_gap_list  (paginated + filters)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_list
    @organization_id BIGINT,
    @execution_id    BIGINT       = NULL,
    @observation_id  BIGINT       = NULL,
    @status_code     NVARCHAR(60) = NULL,
    @severity_code   NVARCHAR(30) = NULL,
    @owner_employee_id BIGINT     = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 54200, 'organization_id is required.', 1;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    DECLARE @offset INT = (@page - 1) * @page_size;

    ;WITH base AS (
        SELECT g.org_assurance_gap_id,
               g.organization_id,
               g.org_assurance_observation_id,
               g.org_assurance_execution_id,
               g.org_assurance_execution_entity_id,
               g.execution_code,
               g.execution_name,
               g.entity_dimension_code,
               g.entity_dimension_name,
               g.entity_code,
               g.entity_name,
               g.observation_code,
               g.observation_title,
               g.gap_code,
               g.gap_title,
               g.severity_code,
               g.severity_name,
               st.status_code AS status_code,
               st.status_name AS status_name,
               st.is_terminal AS status_is_terminal,
               g.assigned_owner_employee_id,
               g.assigned_owner_display_name,
               g.assigned_reviewer_display_name,
               g.opened_dt,
               g.target_resolution_date,
               g.closed_dt,
               g.risk_id,
               g.task_id,
               g.entered_dt,
               g.updated_dt,
               (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_gap_action a
                 WHERE a.org_assurance_gap_id = g.org_assurance_gap_id
                   AND a.is_active = 1) AS action_count,
               (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_gap_action a
                 WHERE a.org_assurance_gap_id = g.org_assurance_gap_id
                   AND a.is_active = 1
                   AND a.action_status_code = N'Completed') AS action_completed_count
        FROM grac_practice.org_assurance_gap g
        JOIN grac_practice.org_assurance_gap_status_master st
             ON st.org_assurance_gap_status_id = g.gap_status_id
        WHERE g.organization_id = @organization_id
          AND g.is_active = 1
          AND (@execution_id   IS NULL OR g.org_assurance_execution_id    = @execution_id)
          AND (@observation_id IS NULL OR g.org_assurance_observation_id  = @observation_id)
          AND (@status_code    IS NULL OR st.status_code = @status_code)
          AND (@severity_code  IS NULL OR g.severity_code = @severity_code)
          AND (@owner_employee_id IS NULL OR g.assigned_owner_employee_id = @owner_employee_id)
          AND (@search IS NULL OR @search = ''
               OR g.gap_title      LIKE N'%' + @search + N'%'
               OR g.gap_code       LIKE N'%' + @search + N'%'
               OR g.execution_name LIKE N'%' + @search + N'%'
               OR g.entity_name    LIKE N'%' + @search + N'%'
               OR g.observation_title LIKE N'%' + @search + N'%')
    )
    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM base;

    ;WITH base AS (
        SELECT g.org_assurance_gap_id,
               g.organization_id,
               g.org_assurance_observation_id,
               g.org_assurance_execution_id,
               g.org_assurance_execution_entity_id,
               g.execution_code,
               g.execution_name,
               g.entity_dimension_code,
               g.entity_dimension_name,
               g.entity_code,
               g.entity_name,
               g.observation_code,
               g.observation_title,
               g.gap_code,
               g.gap_title,
               g.severity_code,
               g.severity_name,
               st.status_code AS status_code,
               st.status_name AS status_name,
               st.is_terminal AS status_is_terminal,
               g.assigned_owner_employee_id,
               g.assigned_owner_display_name,
               g.assigned_reviewer_display_name,
               g.opened_dt,
               g.target_resolution_date,
               g.closed_dt,
               g.risk_id,
               g.task_id,
               g.entered_dt,
               g.updated_dt,
               (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_gap_action a
                 WHERE a.org_assurance_gap_id = g.org_assurance_gap_id
                   AND a.is_active = 1) AS action_count,
               (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_gap_action a
                 WHERE a.org_assurance_gap_id = g.org_assurance_gap_id
                   AND a.is_active = 1
                   AND a.action_status_code = N'Completed') AS action_completed_count
        FROM grac_practice.org_assurance_gap g
        JOIN grac_practice.org_assurance_gap_status_master st
             ON st.org_assurance_gap_status_id = g.gap_status_id
        WHERE g.organization_id = @organization_id
          AND g.is_active = 1
          AND (@execution_id   IS NULL OR g.org_assurance_execution_id    = @execution_id)
          AND (@observation_id IS NULL OR g.org_assurance_observation_id  = @observation_id)
          AND (@status_code    IS NULL OR st.status_code = @status_code)
          AND (@severity_code  IS NULL OR g.severity_code = @severity_code)
          AND (@owner_employee_id IS NULL OR g.assigned_owner_employee_id = @owner_employee_id)
          AND (@search IS NULL OR @search = ''
               OR g.gap_title      LIKE N'%' + @search + N'%'
               OR g.gap_code       LIKE N'%' + @search + N'%'
               OR g.execution_name LIKE N'%' + @search + N'%'
               OR g.entity_name    LIKE N'%' + @search + N'%'
               OR g.observation_title LIKE N'%' + @search + N'%')
    )
    SELECT org_assurance_gap_id             AS GapId,
           organization_id                   AS OrganizationId,
           org_assurance_observation_id      AS ObservationId,
           org_assurance_execution_id        AS ExecutionId,
           org_assurance_execution_entity_id AS EntityId,
           execution_code                    AS ExecutionCode,
           execution_name                    AS ExecutionName,
           entity_dimension_code             AS EntityDimensionCode,
           entity_dimension_name             AS EntityDimensionName,
           entity_code                       AS EntityCode,
           entity_name                       AS EntityName,
           observation_code                  AS ObservationCode,
           observation_title                 AS ObservationTitle,
           gap_code                          AS GapCode,
           gap_title                         AS GapTitle,
           severity_code                     AS SeverityCode,
           severity_name                     AS SeverityName,
           status_code                       AS StatusCode,
           status_name                       AS StatusName,
           status_is_terminal                AS StatusIsTerminal,
           assigned_owner_employee_id        AS OwnerEmployeeId,
           assigned_owner_display_name       AS OwnerDisplayName,
           assigned_reviewer_display_name    AS ReviewerDisplayName,
           opened_dt                         AS OpenedDt,
           target_resolution_date            AS TargetResolutionDate,
           closed_dt                         AS ClosedDt,
           risk_id                           AS RiskId,
           task_id                           AS TaskId,
           action_count                      AS ActionCount,
           action_completed_count            AS ActionCompletedCount,
           entered_dt                        AS EnteredDt,
           updated_dt                        AS UpdatedDt
    FROM base
    ORDER BY opened_dt DESC, org_assurance_gap_id DESC
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- sp_org_assurance_gap_get
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_get
    @organization_id BIGINT,
    @gap_id          BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @gap_id IS NULL
        THROW 54201, 'organization_id and gap_id are required.', 1;

    SELECT g.org_assurance_gap_id            AS GapId,
           g.organization_id                  AS OrganizationId,
           g.org_assurance_observation_id     AS ObservationId,
           g.org_assurance_execution_id       AS ExecutionId,
           g.org_assurance_execution_entity_id AS EntityId,
           g.execution_code                   AS ExecutionCode,
           g.execution_name                   AS ExecutionName,
           g.entity_dimension_code            AS EntityDimensionCode,
           g.entity_dimension_name            AS EntityDimensionName,
           g.entity_code                      AS EntityCode,
           g.entity_name                      AS EntityName,
           g.observation_code                 AS ObservationCode,
           g.observation_title                AS ObservationTitle,
           g.gap_code                         AS GapCode,
           g.gap_title                        AS GapTitle,
           g.gap_description                  AS GapDescription,
           g.severity_id                      AS SeverityId,
           g.severity_code                    AS SeverityCode,
           g.severity_name                    AS SeverityName,
           st.status_code                     AS StatusCode,
           st.status_name                     AS StatusName,
           st.is_terminal                     AS StatusIsTerminal,
           g.assigned_owner_employee_id       AS OwnerEmployeeId,
           g.assigned_owner_display_name      AS OwnerDisplayName,
           g.assigned_reviewer_employee_id    AS ReviewerEmployeeId,
           g.assigned_reviewer_display_name   AS ReviewerDisplayName,
           g.opened_dt                        AS OpenedDt,
           g.target_resolution_date           AS TargetResolutionDate,
           g.remediation_submitted_dt         AS RemediationSubmittedDt,
           g.verified_dt                      AS VerifiedDt,
           g.closed_dt                        AS ClosedDt,
           g.reopened_dt                      AS ReopenedDt,
           g.remediation_plan                 AS RemediationPlan,
           g.resolution_notes                 AS ResolutionNotes,
           g.verification_notes               AS VerificationNotes,
           g.closure_notes                    AS ClosureNotes,
           g.risk_id                          AS RiskId,
           g.task_id                          AS TaskId,
           g.entered_by                       AS EnteredBy,
           g.entered_dt                       AS EnteredDt,
           g.updated_by                       AS UpdatedBy,
           g.updated_dt                       AS UpdatedDt
    FROM grac_practice.org_assurance_gap g
    JOIN grac_practice.org_assurance_gap_status_master st
         ON st.org_assurance_gap_status_id = g.gap_status_id
    WHERE g.organization_id = @organization_id
      AND g.org_assurance_gap_id = @gap_id
      AND g.is_active = 1;
END
GO

-- =====================================================================
-- sp_org_assurance_gap_save  (manual create + update; edits only in
--   Open / InProgress / Reopened)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_save
    @organization_id                BIGINT,
    @gap_id                         BIGINT        = NULL,
    @observation_id                 BIGINT        = NULL,
    @execution_id                   BIGINT        = NULL,
    @execution_entity_id            BIGINT        = NULL,
    @gap_code                       NVARCHAR(120) = NULL,
    @gap_title                      NVARCHAR(300),
    @gap_description                NVARCHAR(MAX) = NULL,
    @severity_code                  NVARCHAR(30)  = N'Medium',
    @assigned_owner_employee_id     BIGINT        = NULL,
    @assigned_owner_display_name    NVARCHAR(240) = NULL,
    @assigned_reviewer_employee_id  BIGINT        = NULL,
    @assigned_reviewer_display_name NVARCHAR(240) = NULL,
    @target_resolution_date         DATE          = NULL,
    @remediation_plan               NVARCHAR(MAX) = NULL,
    @actor                          NVARCHAR(100) = 'system',
    @gap_id_out                     BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 54200, 'organization_id is required.', 1;
    IF @gap_title IS NULL OR LEN(LTRIM(RTRIM(@gap_title))) = 0
        THROW 54202, 'gap_title is required.', 1;

    -- Severity lookup (reuse observation severity master).
    DECLARE @sev_id INT, @sev_name NVARCHAR(120);
    SELECT @sev_id   = org_assurance_observation_severity_id,
           @sev_name = severity_name
    FROM grac_practice.org_assurance_observation_severity_master
    WHERE severity_code = @severity_code AND is_active = 1;
    IF @sev_id IS NULL
        THROW 54203, 'Unknown severity_code.', 1;

    -- Optional observation / execution / entity denormalize.
    DECLARE @obs_org BIGINT,
            @obs_exec BIGINT, @obs_entity BIGINT,
            @obs_code NVARCHAR(120), @obs_title NVARCHAR(300),
            @exec_code NVARCHAR(120), @exec_name NVARCHAR(300),
            @dim_code NVARCHAR(60),   @dim_name NVARCHAR(160),
            @ent_code NVARCHAR(120),  @ent_name NVARCHAR(240);

    IF @observation_id IS NOT NULL
    BEGIN
        SELECT @obs_org    = organization_id,
               @obs_exec   = org_assurance_execution_id,
               @obs_entity = org_assurance_execution_entity_id,
               @obs_code   = observation_code,
               @obs_title  = observation_title,
               @exec_code  = execution_code,
               @exec_name  = execution_name,
               @dim_code   = entity_dimension_code,
               @dim_name   = entity_dimension_name,
               @ent_code   = entity_code,
               @ent_name   = entity_name
        FROM grac_practice.org_assurance_observation
        WHERE org_assurance_observation_id = @observation_id AND is_active = 1;
        IF @obs_org IS NULL       THROW 54204, 'Observation not found.', 1;
        IF @obs_org <> @organization_id
            THROW 54205, 'Observation belongs to a different organization.', 1;
        IF @execution_id IS NULL SET @execution_id       = @obs_exec;
        IF @execution_entity_id IS NULL SET @execution_entity_id = @obs_entity;
    END
    ELSE IF @execution_id IS NOT NULL
    BEGIN
        SELECT @obs_org = organization_id,
               @exec_code = execution_code,
               @exec_name = execution_name
        FROM grac_practice.org_assurance_execution
        WHERE org_assurance_execution_id = @execution_id AND is_active = 1;
        IF @obs_org IS NULL       THROW 54206, 'Execution not found.', 1;
        IF @obs_org <> @organization_id
            THROW 54207, 'Execution belongs to a different organization.', 1;
        IF @execution_entity_id IS NOT NULL
        BEGIN
            SELECT @dim_code = dimension_code, @dim_name = dimension_name,
                   @ent_code = entity_code,    @ent_name = entity_name
            FROM grac_practice.org_assurance_execution_entity
            WHERE org_assurance_execution_entity_id = @execution_entity_id
              AND org_assurance_execution_id        = @execution_id
              AND organization_id                    = @organization_id
              AND is_active = 1;
            IF @dim_code IS NULL
                THROW 54208, 'Execution entity not found in this execution.', 1;
        END
    END

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    DECLARE @open_status_id INT = (
        SELECT org_assurance_gap_status_id
        FROM grac_practice.org_assurance_gap_status_master
        WHERE status_code = N'Open');

    BEGIN TRAN;

    IF @gap_id IS NULL
    BEGIN
        IF @gap_code IS NULL OR LEN(LTRIM(RTRIM(@gap_code))) = 0
            SET @gap_code = ISNULL(@obs_code, ISNULL(@exec_code, N'GAP')) + N'-GAP-'
                          + FORMAT(SYSUTCDATETIME(), 'yyyyMMdd-HHmmss');

        IF EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_gap
            WHERE organization_id = @organization_id
              AND gap_code = @gap_code
              AND is_active = 1)
        BEGIN
            ROLLBACK; THROW 54209, 'A gap with this code already exists in the organization.', 1;
        END

        INSERT INTO grac_practice.org_assurance_gap(
            organization_id,
            org_assurance_observation_id,
            org_assurance_execution_id, org_assurance_execution_entity_id,
            execution_code, execution_name,
            entity_dimension_code, entity_dimension_name,
            entity_code, entity_name,
            observation_code, observation_title,
            gap_code, gap_title, gap_description,
            severity_id, severity_code, severity_name,
            gap_status_id,
            assigned_owner_employee_id, assigned_owner_display_name,
            assigned_reviewer_employee_id, assigned_reviewer_display_name,
            target_resolution_date, remediation_plan,
            is_active, record_status_id, entered_by, entered_dt)
        VALUES (
            @organization_id,
            @observation_id,
            @execution_id, @execution_entity_id,
            @exec_code, @exec_name,
            @dim_code, @dim_name,
            @ent_code, @ent_name,
            @obs_code, @obs_title,
            @gap_code, @gap_title, @gap_description,
            @sev_id, @severity_code, @sev_name,
            @open_status_id,
            @assigned_owner_employee_id, @assigned_owner_display_name,
            @assigned_reviewer_employee_id, @assigned_reviewer_display_name,
            @target_resolution_date, @remediation_plan,
            1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @gap_id_out = SCOPE_IDENTITY();

        INSERT INTO grac_practice.org_assurance_gap_history(
            org_assurance_gap_id, organization_id,
            action_code, from_status_id, to_status_id,
            reason_text, actor_display_name, entered_by)
        VALUES(
            @gap_id_out, @organization_id,
            N'CREATE', NULL, @open_status_id,
            N'Gap created.', @actor, @actor);
    END
    ELSE
    BEGIN
        DECLARE @gap_org BIGINT, @current_code NVARCHAR(60), @current_status_id INT;
        SELECT @gap_org           = g.organization_id,
               @current_code      = st.status_code,
               @current_status_id = g.gap_status_id
        FROM grac_practice.org_assurance_gap g
        JOIN grac_practice.org_assurance_gap_status_master st
             ON st.org_assurance_gap_status_id = g.gap_status_id
        WHERE g.org_assurance_gap_id = @gap_id AND g.is_active = 1;

        IF @gap_org IS NULL       BEGIN ROLLBACK; THROW 54210, 'Gap not found.', 1; END
        IF @gap_org <> @organization_id
            BEGIN ROLLBACK; THROW 54211, 'Gap belongs to a different organization.', 1; END
        IF @current_code NOT IN (N'Open', N'InProgress', N'Reopened')
            BEGIN ROLLBACK; THROW 54212, 'Gap cannot be edited in its current status.', 1; END

        UPDATE grac_practice.org_assurance_gap
        SET gap_title                      = @gap_title,
            gap_description                = @gap_description,
            severity_id                    = @sev_id,
            severity_code                  = @severity_code,
            severity_name                  = @sev_name,
            assigned_owner_employee_id     = @assigned_owner_employee_id,
            assigned_owner_display_name    = @assigned_owner_display_name,
            assigned_reviewer_employee_id  = @assigned_reviewer_employee_id,
            assigned_reviewer_display_name = @assigned_reviewer_display_name,
            target_resolution_date         = @target_resolution_date,
            remediation_plan               = @remediation_plan,
            updated_by                     = @actor,
            updated_dt                     = SYSUTCDATETIME()
        WHERE org_assurance_gap_id = @gap_id;

        SET @gap_id_out = @gap_id;

        INSERT INTO grac_practice.org_assurance_gap_history(
            org_assurance_gap_id, organization_id,
            action_code, from_status_id, to_status_id,
            reason_text, actor_display_name, entered_by)
        VALUES(
            @gap_id, @organization_id,
            N'EDIT', @current_status_id, @current_status_id,
            N'Gap edited.', @actor, @actor);
    END

    COMMIT;
END
GO

-- =====================================================================
-- sp_org_assurance_gap_delete  (soft; Open only)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_delete
    @organization_id BIGINT,
    @gap_id          BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @gap_id IS NULL
        THROW 54201, 'organization_id and gap_id are required.', 1;

    DECLARE @gap_org BIGINT, @status_code NVARCHAR(60), @obs_id BIGINT;
    SELECT @gap_org = g.organization_id, @status_code = st.status_code,
           @obs_id  = g.org_assurance_observation_id
    FROM grac_practice.org_assurance_gap g
    JOIN grac_practice.org_assurance_gap_status_master st
         ON st.org_assurance_gap_status_id = g.gap_status_id
    WHERE g.org_assurance_gap_id = @gap_id AND g.is_active = 1;

    IF @gap_org IS NULL       THROW 54210, 'Gap not found.', 1;
    IF @gap_org <> @organization_id
        THROW 54211, 'Gap belongs to a different organization.', 1;
    IF @status_code <> N'Open'
        THROW 54213, 'Only Open gaps can be soft-deleted.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.org_assurance_gap_action
    SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_gap_id = @gap_id AND is_active = 1;

    UPDATE grac_practice.org_assurance_gap
    SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_gap_id = @gap_id;

    -- Break the back-link so the observation shows Regenerate.
    IF @obs_id IS NOT NULL
        UPDATE grac_practice.org_assurance_observation
        SET gap_id = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
        WHERE org_assurance_observation_id = @obs_id
          AND gap_id = @gap_id;

    INSERT INTO grac_practice.org_assurance_gap_history(
        org_assurance_gap_id, organization_id,
        action_code, reason_text, actor_display_name, entered_by)
    VALUES(
        @gap_id, @organization_id,
        N'DELETE', N'Soft-deleted.', @actor, @actor);

    COMMIT;
END
GO

-- =====================================================================
-- sp_org_assurance_gap_generate_from_observation
--   Idempotent -- guarded so re-calls on the same observation do NOT
--   duplicate the gap. If the observation.gap_id is already populated
--   and the gap is still active, the SP returns the existing gap_id.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_generate_from_observation
    @organization_id BIGINT,
    @observation_id  BIGINT,
    @actor           NVARCHAR(100) = 'system',
    @gap_id_out      BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @observation_id IS NULL
        THROW 54214, 'organization_id and observation_id are required.', 1;

    -- Pull observation with its status.
    DECLARE @obs_org BIGINT, @obs_status NVARCHAR(60), @existing_gap_id BIGINT,
            @sev_id INT, @sev_code NVARCHAR(30), @sev_name NVARCHAR(120),
            @exec_id BIGINT, @entity_id BIGINT,
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
           @sev_id          = o.severity_id,
           @sev_code        = o.severity_code,
           @sev_name        = o.severity_name,
           @exec_id         = o.org_assurance_execution_id,
           @entity_id       = o.org_assurance_execution_entity_id,
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

    IF @obs_org IS NULL       THROW 54215, 'Observation not found.', 1;
    IF @obs_org <> @organization_id
        THROW 54216, 'Observation belongs to a different organization.', 1;

    -- Only ACCEPTED observations produce gaps. This is what makes the
    -- accept-hook (see redefinition of sp_org_assurance_observation_accept
    -- at the bottom of this migration) safe to call unconditionally.
    IF @obs_status <> N'Accepted'
        THROW 54217, 'Only Accepted observations can generate a gap.', 1;

    -- Idempotent -- if the observation already carries an active gap,
    -- return it and do nothing else.
    IF @existing_gap_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM grac_practice.org_assurance_gap
                   WHERE org_assurance_gap_id = @existing_gap_id
                     AND organization_id      = @organization_id
                     AND is_active = 1)
    BEGIN
        SET @gap_id_out = @existing_gap_id;
        RETURN;
    END

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    DECLARE @open_status_id INT = (
        SELECT org_assurance_gap_status_id
        FROM grac_practice.org_assurance_gap_status_master
        WHERE status_code = N'Open');

    DECLARE @gap_code NVARCHAR(120) =
        ISNULL(@obs_code, N'GAP') + N'-GAP-'
        + FORMAT(SYSUTCDATETIME(), 'yyyyMMdd-HHmmss');

    -- If somehow the auto-code collides with an existing gap code,
    -- fall back to numeric suffix.
    IF EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_gap
        WHERE organization_id = @organization_id AND gap_code = @gap_code)
        SET @gap_code = @gap_code + N'-' + CAST(ABS(CHECKSUM(NEWID())) % 100000 AS NVARCHAR(10));

    DECLARE @gap_title NVARCHAR(300) =
        N'Gap: ' + ISNULL(@obs_title, N'(observation)');

    BEGIN TRAN;

    INSERT INTO grac_practice.org_assurance_gap(
        organization_id,
        org_assurance_observation_id,
        org_assurance_execution_id, org_assurance_execution_entity_id,
        execution_code, execution_name,
        entity_dimension_code, entity_dimension_name,
        entity_code, entity_name,
        observation_code, observation_title,
        gap_code, gap_title, gap_description,
        severity_id, severity_code, severity_name,
        gap_status_id,
        assigned_owner_employee_id, assigned_owner_display_name,
        assigned_reviewer_employee_id, assigned_reviewer_display_name,
        target_resolution_date,
        is_active, record_status_id, entered_by, entered_dt)
    VALUES (
        @organization_id,
        @observation_id,
        @exec_id, @entity_id,
        @exec_code, @exec_name,
        @dim_code, @dim_name,
        @ent_code, @ent_name,
        @obs_code, @obs_title,
        @gap_code, @gap_title, @obs_desc,
        @sev_id, @sev_code, @sev_name,
        @open_status_id,
        @owner_id, @owner_name,
        @reviewer_id, @reviewer_name,
        @due_dt,
        1, @active_record_status_id, @actor, SYSUTCDATETIME());

    SET @gap_id_out = SCOPE_IDENTITY();

    UPDATE grac_practice.org_assurance_observation
    SET gap_id = @gap_id_out,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_observation_id = @observation_id;

    INSERT INTO grac_practice.org_assurance_gap_history(
        org_assurance_gap_id, organization_id,
        action_code, from_status_id, to_status_id,
        reason_text, actor_display_name, entered_by)
    VALUES(
        @gap_id_out, @organization_id,
        N'AUTO_GENERATED',
        NULL, @open_status_id,
        N'Auto-generated from Observation #' + CAST(@observation_id AS NVARCHAR(20)),
        @actor, @actor);

    COMMIT;
END
GO

-- =====================================================================
-- Shared lifecycle transition helper
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_transition
    @organization_id     BIGINT,
    @gap_id              BIGINT,
    @expected_from_codes NVARCHAR(200),
    @to_code             NVARCHAR(60),
    @stamp_field         NVARCHAR(30) = NULL, -- remediation_submitted / verified / closed / reopened
    @notes               NVARCHAR(MAX) = NULL,
    @actor               NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @gap_id IS NULL
        THROW 54201, 'organization_id and gap_id are required.', 1;

    DECLARE @to_id INT, @from_id INT, @gap_org BIGINT, @current_code NVARCHAR(60);

    SELECT @to_id = org_assurance_gap_status_id
    FROM grac_practice.org_assurance_gap_status_master WHERE status_code = @to_code;
    IF @to_id IS NULL
        THROW 54218, 'Unknown target status_code in gap transition.', 1;

    SELECT @gap_org      = g.organization_id,
           @current_code = st.status_code,
           @from_id      = g.gap_status_id
    FROM grac_practice.org_assurance_gap g
    JOIN grac_practice.org_assurance_gap_status_master st
         ON st.org_assurance_gap_status_id = g.gap_status_id
    WHERE g.org_assurance_gap_id = @gap_id AND g.is_active = 1;

    IF @gap_org IS NULL      THROW 54210, 'Gap not found.', 1;
    IF @gap_org <> @organization_id
        THROW 54211, 'Gap belongs to a different organization.', 1;

    DECLARE @allowed TABLE(code NVARCHAR(60));
    INSERT INTO @allowed(code)
    SELECT LTRIM(RTRIM(value))
    FROM STRING_SPLIT(@expected_from_codes, ',')
    WHERE LTRIM(RTRIM(value)) <> '';

    IF NOT EXISTS (SELECT 1 FROM @allowed WHERE code = @current_code)
        THROW 54219, 'Illegal gap lifecycle transition -- current status does not match the expected source.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.org_assurance_gap
    SET gap_status_id = @to_id,
        remediation_submitted_dt =
            CASE WHEN @stamp_field = N'remediation_submitted' AND remediation_submitted_dt IS NULL
                 THEN SYSUTCDATETIME() ELSE remediation_submitted_dt END,
        verified_dt =
            CASE WHEN @stamp_field = N'verified' AND verified_dt IS NULL
                 THEN SYSUTCDATETIME() ELSE verified_dt END,
        closed_dt =
            CASE WHEN @stamp_field = N'closed' AND closed_dt IS NULL
                 THEN SYSUTCDATETIME() ELSE closed_dt END,
        reopened_dt =
            CASE WHEN @stamp_field = N'reopened'
                 THEN SYSUTCDATETIME() ELSE reopened_dt END,
        resolution_notes   = CASE WHEN @stamp_field = N'remediation_submitted' THEN ISNULL(@notes, resolution_notes)   ELSE resolution_notes END,
        verification_notes = CASE WHEN @stamp_field = N'verified'              THEN ISNULL(@notes, verification_notes) ELSE verification_notes END,
        closure_notes      = CASE WHEN @stamp_field = N'closed'                THEN ISNULL(@notes, closure_notes)      ELSE closure_notes END,
        updated_by         = @actor,
        updated_dt         = SYSUTCDATETIME()
    WHERE org_assurance_gap_id = @gap_id;

    INSERT INTO grac_practice.org_assurance_gap_history(
        org_assurance_gap_id, organization_id,
        action_code, from_status_id, to_status_id,
        reason_text, actor_display_name, entered_by)
    VALUES(
        @gap_id, @organization_id,
        UPPER(@to_code), @from_id, @to_id,
        @notes, @actor, @actor);

    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_start
    @organization_id BIGINT, @gap_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_gap_transition
        @organization_id = @organization_id, @gap_id = @gap_id,
        @expected_from_codes = N'Open,Reopened', @to_code = N'InProgress',
        @stamp_field = NULL, @notes = @notes, @actor = @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_submit_remediation
    @organization_id BIGINT, @gap_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_gap_transition
        @organization_id = @organization_id, @gap_id = @gap_id,
        @expected_from_codes = N'InProgress', @to_code = N'RemediationSubmitted',
        @stamp_field = N'remediation_submitted', @notes = @notes, @actor = @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_verify
    @organization_id BIGINT, @gap_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_gap_transition
        @organization_id = @organization_id, @gap_id = @gap_id,
        @expected_from_codes = N'RemediationSubmitted', @to_code = N'Verified',
        @stamp_field = N'verified', @notes = @notes, @actor = @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_close
    @organization_id BIGINT, @gap_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_gap_transition
        @organization_id = @organization_id, @gap_id = @gap_id,
        @expected_from_codes = N'Verified', @to_code = N'Closed',
        @stamp_field = N'closed', @notes = @notes, @actor = @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_reopen
    @organization_id BIGINT, @gap_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_gap_transition
        @organization_id = @organization_id, @gap_id = @gap_id,
        @expected_from_codes = N'Closed,Verified', @to_code = N'Reopened',
        @stamp_field = N'reopened', @notes = @notes, @actor = @actor;
END
GO

-- =====================================================================
-- Gap actions (corrective steps)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_action_list
    @organization_id BIGINT,
    @gap_id          BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @gap_id IS NULL
        THROW 54201, 'organization_id and gap_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_gap
        WHERE org_assurance_gap_id = @gap_id
          AND organization_id      = @organization_id)
        THROW 54211, 'Gap belongs to a different organization.', 1;

    SELECT a.org_assurance_gap_action_id AS ActionId,
           a.org_assurance_gap_id         AS GapId,
           a.action_order                 AS ActionOrder,
           a.action_title                 AS ActionTitle,
           a.action_description           AS ActionDescription,
           a.assigned_employee_id         AS AssignedEmployeeId,
           a.assigned_display_name        AS AssignedDisplayName,
           a.due_date                     AS DueDate,
           a.completed_dt                 AS CompletedDt,
           a.action_status_code           AS ActionStatusCode,
           a.task_id                      AS TaskId,
           a.notes                        AS Notes,
           a.entered_by                   AS EnteredBy,
           a.entered_dt                   AS EnteredDt,
           a.updated_by                   AS UpdatedBy,
           a.updated_dt                   AS UpdatedDt
    FROM grac_practice.org_assurance_gap_action a
    WHERE a.org_assurance_gap_id = @gap_id
      AND a.organization_id      = @organization_id
      AND a.is_active = 1
    ORDER BY a.action_order, a.org_assurance_gap_action_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_action_save
    @organization_id       BIGINT,
    @gap_id                BIGINT,
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

    IF @organization_id IS NULL OR @gap_id IS NULL
        THROW 54201, 'organization_id and gap_id are required.', 1;
    IF @action_title IS NULL OR LEN(LTRIM(RTRIM(@action_title))) = 0
        THROW 54220, 'action_title is required.', 1;
    IF @action_status_code NOT IN (N'Pending', N'InProgress', N'Completed', N'Cancelled')
        THROW 54221, 'action_status_code must be Pending / InProgress / Completed / Cancelled.', 1;

    -- Verify gap ownership + editable status.
    DECLARE @gap_org BIGINT, @status_code NVARCHAR(60);
    SELECT @gap_org = g.organization_id, @status_code = st.status_code
    FROM grac_practice.org_assurance_gap g
    JOIN grac_practice.org_assurance_gap_status_master st
         ON st.org_assurance_gap_status_id = g.gap_status_id
    WHERE g.org_assurance_gap_id = @gap_id AND g.is_active = 1;

    IF @gap_org IS NULL       THROW 54210, 'Gap not found.', 1;
    IF @gap_org <> @organization_id
        THROW 54211, 'Gap belongs to a different organization.', 1;
    IF @status_code = N'Closed'
        THROW 54222, 'Actions cannot be modified on Closed gaps.', 1;

    BEGIN TRAN;

    IF @action_id IS NULL
    BEGIN
        INSERT INTO grac_practice.org_assurance_gap_action(
            org_assurance_gap_id, organization_id,
            action_order, action_title, action_description,
            assigned_employee_id, assigned_display_name,
            due_date, action_status_code, notes,
            is_active, entered_by, entered_dt)
        VALUES(
            @gap_id, @organization_id,
            @action_order, @action_title, @action_description,
            @assigned_employee_id, @assigned_display_name,
            @due_date, @action_status_code, @notes,
            1, @actor, SYSUTCDATETIME());
        SET @action_id_out = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @act_gap BIGINT;
        SELECT @act_gap = org_assurance_gap_id
        FROM grac_practice.org_assurance_gap_action
        WHERE org_assurance_gap_action_id = @action_id AND is_active = 1;
        IF @act_gap IS NULL       BEGIN ROLLBACK; THROW 54223, 'Gap action not found.', 1; END
        IF @act_gap <> @gap_id
            BEGIN ROLLBACK; THROW 54224, 'Gap action does not belong to this gap.', 1; END

        UPDATE grac_practice.org_assurance_gap_action
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
        WHERE org_assurance_gap_action_id = @action_id;
        SET @action_id_out = @action_id;
    END

    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_action_complete
    @organization_id BIGINT,
    @gap_id          BIGINT,
    @action_id       BIGINT,
    @notes           NVARCHAR(MAX) = NULL,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @gap_id IS NULL OR @action_id IS NULL
        THROW 54201, 'organization_id, gap_id and action_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM grac_practice.org_assurance_gap_action a
        JOIN grac_practice.org_assurance_gap g
             ON g.org_assurance_gap_id = a.org_assurance_gap_id
        WHERE a.org_assurance_gap_action_id = @action_id
          AND a.org_assurance_gap_id        = @gap_id
          AND g.organization_id             = @organization_id
          AND a.is_active = 1)
        THROW 54223, 'Gap action not found.', 1;

    UPDATE grac_practice.org_assurance_gap_action
    SET action_status_code = N'Completed',
        completed_dt = ISNULL(completed_dt, SYSUTCDATETIME()),
        notes        = COALESCE(@notes, notes),
        updated_by   = @actor,
        updated_dt   = SYSUTCDATETIME()
    WHERE org_assurance_gap_action_id = @action_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_action_delete
    @organization_id BIGINT,
    @gap_id          BIGINT,
    @action_id       BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @gap_id IS NULL OR @action_id IS NULL
        THROW 54201, 'organization_id, gap_id and action_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM grac_practice.org_assurance_gap_action a
        JOIN grac_practice.org_assurance_gap g
             ON g.org_assurance_gap_id = a.org_assurance_gap_id
        WHERE a.org_assurance_gap_action_id = @action_id
          AND a.org_assurance_gap_id        = @gap_id
          AND g.organization_id             = @organization_id
          AND a.is_active = 1)
        THROW 54223, 'Gap action not found.', 1;

    UPDATE grac_practice.org_assurance_gap_action
    SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_gap_action_id = @action_id;
END
GO

-- =====================================================================
-- History read
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_history_list
    @organization_id BIGINT,
    @gap_id          BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @gap_id IS NULL
        THROW 54201, 'organization_id and gap_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_gap
        WHERE org_assurance_gap_id = @gap_id
          AND organization_id      = @organization_id)
        THROW 54211, 'Gap belongs to a different organization.', 1;

    SELECT h.org_assurance_gap_history_id AS HistoryId,
           h.action_code                   AS ActionCode,
           h.from_status_id                AS FromStatusId,
           fs.status_code                  AS FromStatusCode,
           fs.status_name                  AS FromStatusName,
           h.to_status_id                  AS ToStatusId,
           ts.status_code                  AS ToStatusCode,
           ts.status_name                  AS ToStatusName,
           h.reason_text                   AS ReasonText,
           h.actor_display_name            AS ActorDisplayName,
           h.entered_by                    AS EnteredBy,
           h.entered_dt                    AS EnteredDt
    FROM grac_practice.org_assurance_gap_history h
    LEFT JOIN grac_practice.org_assurance_gap_status_master fs
         ON fs.org_assurance_gap_status_id = h.from_status_id
    LEFT JOIN grac_practice.org_assurance_gap_status_master ts
         ON ts.org_assurance_gap_status_id = h.to_status_id
    WHERE h.org_assurance_gap_id = @gap_id
    ORDER BY h.entered_dt DESC, h.org_assurance_gap_history_id DESC;
END
GO

-- =====================================================================
-- REDEFINE sp_org_assurance_observation_accept (originally in 102).
--
-- Change vs 102: after the observation transitions to Accepted, we
-- fire the gap generator so a gap is created automatically. The call
-- is guarded (defensive), and errors are swallowed so accept is never
-- rolled back by a downstream gap-side issue -- accept is the
-- audit-critical action; gap is derivative.
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

    -- Stage 4b auto-hook -- transient failures here must not undo the
    -- accept commit above.
    IF OBJECT_ID('grac_practice.sp_org_assurance_gap_generate_from_observation','P') IS NOT NULL
    BEGIN
        DECLARE @new_gap_id BIGINT;
        BEGIN TRY
            EXEC grac_practice.sp_org_assurance_gap_generate_from_observation
                @organization_id = @organization_id,
                @observation_id  = @observation_id,
                @actor           = @actor,
                @gap_id_out      = @new_gap_id OUTPUT;
        END TRY
        BEGIN CATCH
            -- Advisory only. The observation stays Accepted; a user
            -- can retry via the "Regenerate Gap" action on the
            -- Observations screen.
            PRINT N'sp_org_assurance_observation_accept: gap generation failed -- ' + ERROR_MESSAGE();
        END CATCH
    END
END
GO

PRINT '105 Organization Assurance Gap procedures deployed.';
GO
