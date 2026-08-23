-- =====================================================================
-- 116a Observation SP rewrites for hybrid role+employee ownership.
--
-- Depends on: 102 (base Observation procs), 115 (role columns),
--             117 (role-holder helpers).
--
-- CREATE OR ALTER for:
--   sp_org_assurance_observation_save   (adds 4 role params + auto-resolve)
--   sp_org_assurance_observation_list   (returns 4 new role columns)
--   sp_org_assurance_observation_get    (returns 4 new role columns)
--
-- Auto-resolve rules (per Q1-A):
--   * If role_id given without employee_id: pick the role's first active
--     holder via sp_org_role_primary_holder_pick (snapshot only).
--   * If employee_id given without role_id: pull the employee's current
--     role from organization_employee.role_id.
--   * If both given: use both as-is (user override wins).
--   * If neither: both stay NULL (unassigned).
--
-- Rollback: 116a_observation_procs_role_extension_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_observation','U') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_observation','assigned_owner_role_id') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_role_primary_holder_pick','P') IS NULL
BEGIN
    RAISERROR('116a: run 102 + 115 + 117 first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_org_assurance_observation_save (extended)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_save
    @organization_id                BIGINT,
    @observation_id                 BIGINT        = NULL,
    @execution_id                   BIGINT,
    @execution_entity_id            BIGINT        = NULL,
    @observation_code               NVARCHAR(120) = NULL,
    @observation_title              NVARCHAR(300),
    @observation_description        NVARCHAR(MAX) = NULL,
    @observation_type               NVARCHAR(30)  = N'Finding',
    @severity_code                  NVARCHAR(30)  = N'Medium',
    @source_question_code           NVARCHAR(120) = NULL,
    @source_question_text           NVARCHAR(MAX) = NULL,
    @assigned_owner_employee_id     BIGINT        = NULL,
    @assigned_owner_display_name    NVARCHAR(240) = NULL,
    @assigned_reviewer_employee_id  BIGINT        = NULL,
    @assigned_reviewer_display_name NVARCHAR(240) = NULL,
    @reported_by_employee_id        BIGINT        = NULL,
    @reported_by_display_name       NVARCHAR(240) = NULL,
    @observed_dt                    DATETIME2     = NULL,
    @due_date                       DATE          = NULL,
    -- 116a: hybrid ownership -- new role params (all nullable)
    @assigned_owner_role_id         BIGINT        = NULL,
    @assigned_owner_role_name       NVARCHAR(120) = NULL,
    @assigned_reviewer_role_id      BIGINT        = NULL,
    @assigned_reviewer_role_name    NVARCHAR(120) = NULL,
    @actor                          NVARCHAR(100) = 'system',
    @observation_id_out             BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 54100, 'organization_id is required.', 1;
    IF @execution_id IS NULL
        THROW 54102, 'execution_id is required.', 1;
    IF @observation_title IS NULL OR LEN(LTRIM(RTRIM(@observation_title))) = 0
        THROW 54103, 'observation_title is required.', 1;
    IF @observation_type NOT IN (N'Finding', N'Improvement', N'BestPractice', N'Risk')
        THROW 54104, 'observation_type must be Finding / Improvement / BestPractice / Risk.', 1;

    -- Verify execution + optional entity belong to the same organization.
    DECLARE @exec_org BIGINT,
            @exec_code NVARCHAR(120), @exec_name NVARCHAR(300);
    SELECT @exec_org  = organization_id,
           @exec_code = execution_code,
           @exec_name = execution_name
    FROM grac_practice.org_assurance_execution
    WHERE org_assurance_execution_id = @execution_id AND is_active = 1;

    IF @exec_org IS NULL      THROW 54105, 'Execution not found.', 1;
    IF @exec_org <> @organization_id
        THROW 54106, 'Execution belongs to a different organization.', 1;

    DECLARE @dim_code NVARCHAR(60), @dim_name NVARCHAR(160),
            @ent_code NVARCHAR(120), @ent_name NVARCHAR(240);
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
            THROW 54107, 'Execution entity not found or does not belong to this execution.', 1;
    END

    -- Severity resolution.
    DECLARE @sev_id INT, @sev_name NVARCHAR(120);
    SELECT @sev_id   = org_assurance_observation_severity_id,
           @sev_name = severity_name
    FROM grac_practice.org_assurance_observation_severity_master
    WHERE severity_code = @severity_code AND is_active = 1;
    IF @sev_id IS NULL
        THROW 54108, 'Unknown severity_code.', 1;

    -- ==========================================================
    -- 116a hybrid ownership resolver -- Owner
    -- ==========================================================
    -- If role_name not supplied but role_id was, look it up.
    IF @assigned_owner_role_id IS NOT NULL
       AND (@assigned_owner_role_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_owner_role_name))) = 0)
        SELECT @assigned_owner_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @assigned_owner_role_id AND organization_id = @organization_id;

    -- If employee not supplied but role was, auto-snapshot the first
    -- active holder (per Q1-A). If none, keep employee NULL.
    IF @assigned_owner_role_id IS NOT NULL AND @assigned_owner_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id      = @organization_id,
             @role_id              = @assigned_owner_role_id,
             @employee_id_out      = @assigned_owner_employee_id   OUTPUT,
             @employee_name_out    = @assigned_owner_display_name  OUTPUT;

    -- If employee supplied but role wasn't, pull the employee's current
    -- role and snapshot its name so history matches the current holder.
    IF @assigned_owner_employee_id IS NOT NULL AND @assigned_owner_role_id IS NULL
    BEGIN
        SELECT @assigned_owner_role_id = e.role_id,
               @assigned_owner_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @assigned_owner_employee_id
          AND e.organization_id = @organization_id;
    END

    -- If display_name not supplied but employee was, snapshot the name.
    IF @assigned_owner_employee_id IS NOT NULL
       AND (@assigned_owner_display_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_owner_display_name))) = 0)
        SELECT @assigned_owner_display_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @assigned_owner_employee_id;

    -- ==========================================================
    -- 116a hybrid ownership resolver -- Reviewer (same pattern)
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

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    DECLARE @open_status_id INT = (
        SELECT org_assurance_observation_status_id
        FROM grac_practice.org_assurance_observation_status_master
        WHERE status_code = N'Open');

    BEGIN TRAN;

    IF @observation_id IS NULL
    BEGIN
        IF @observation_code IS NULL OR LEN(LTRIM(RTRIM(@observation_code))) = 0
            SET @observation_code =
                ISNULL(@exec_code, N'OBS') + N'-OBS-'
                + FORMAT(SYSUTCDATETIME(), 'yyyyMMdd-HHmmss');

        IF EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_observation
            WHERE organization_id  = @organization_id
              AND observation_code = @observation_code
              AND is_active = 1)
        BEGIN
            ROLLBACK; THROW 54109, 'An observation with this code already exists in the organization.', 1;
        END

        INSERT INTO grac_practice.org_assurance_observation(
            organization_id,
            org_assurance_execution_id, org_assurance_execution_entity_id,
            execution_code, execution_name,
            entity_dimension_code, entity_dimension_name,
            entity_code, entity_name,
            observation_code, observation_title, observation_description,
            observation_type, severity_id, severity_code, severity_name,
            observation_status_id,
            source_question_code, source_question_text,
            reported_by_employee_id, reported_by_display_name,
            assigned_owner_employee_id, assigned_owner_display_name,
            assigned_owner_role_id, assigned_owner_role_name,
            assigned_reviewer_employee_id, assigned_reviewer_display_name,
            assigned_reviewer_role_id, assigned_reviewer_role_name,
            observed_dt, due_date,
            is_active, record_status_id, entered_by, entered_dt)
        VALUES (
            @organization_id,
            @execution_id, @execution_entity_id,
            @exec_code, @exec_name,
            @dim_code, @dim_name,
            @ent_code, @ent_name,
            @observation_code, @observation_title, @observation_description,
            @observation_type, @sev_id, @severity_code, @sev_name,
            @open_status_id,
            @source_question_code, @source_question_text,
            @reported_by_employee_id, @reported_by_display_name,
            @assigned_owner_employee_id, @assigned_owner_display_name,
            @assigned_owner_role_id, @assigned_owner_role_name,
            @assigned_reviewer_employee_id, @assigned_reviewer_display_name,
            @assigned_reviewer_role_id, @assigned_reviewer_role_name,
            ISNULL(@observed_dt, SYSUTCDATETIME()), @due_date,
            1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @observation_id_out = SCOPE_IDENTITY();

        INSERT INTO grac_practice.org_assurance_observation_history(
            org_assurance_observation_id, organization_id,
            action_code, from_status_id, to_status_id,
            reason_text, actor_display_name, entered_by)
        VALUES(
            @observation_id_out, @organization_id,
            N'CREATE', NULL, @open_status_id,
            N'Observation created.', @actor, @actor);
    END
    ELSE
    BEGIN
        DECLARE @obs_org BIGINT, @current_code NVARCHAR(60), @current_status_id INT;
        SELECT @obs_org           = o.organization_id,
               @current_code      = st.status_code,
               @current_status_id = o.observation_status_id
        FROM grac_practice.org_assurance_observation o
        JOIN grac_practice.org_assurance_observation_status_master st
             ON st.org_assurance_observation_status_id = o.observation_status_id
        WHERE o.org_assurance_observation_id = @observation_id
          AND o.is_active = 1;

        IF @obs_org IS NULL       BEGIN ROLLBACK; THROW 54110, 'Observation not found.', 1; END
        IF @obs_org <> @organization_id
            BEGIN ROLLBACK; THROW 54111, 'Observation belongs to a different organization.', 1; END
        IF @current_code NOT IN (N'Open', N'InReview')
            BEGIN ROLLBACK; THROW 54112, 'Observation cannot be edited in its current status.', 1; END

        UPDATE grac_practice.org_assurance_observation
        SET observation_title              = @observation_title,
            observation_description        = @observation_description,
            observation_type               = @observation_type,
            severity_id                    = @sev_id,
            severity_code                  = @severity_code,
            severity_name                  = @sev_name,
            source_question_code           = @source_question_code,
            source_question_text           = @source_question_text,
            reported_by_employee_id        = @reported_by_employee_id,
            reported_by_display_name       = @reported_by_display_name,
            assigned_owner_employee_id     = @assigned_owner_employee_id,
            assigned_owner_display_name    = @assigned_owner_display_name,
            assigned_owner_role_id         = @assigned_owner_role_id,
            assigned_owner_role_name       = @assigned_owner_role_name,
            assigned_reviewer_employee_id  = @assigned_reviewer_employee_id,
            assigned_reviewer_display_name = @assigned_reviewer_display_name,
            assigned_reviewer_role_id      = @assigned_reviewer_role_id,
            assigned_reviewer_role_name    = @assigned_reviewer_role_name,
            observed_dt                    = ISNULL(@observed_dt, observed_dt),
            due_date                       = @due_date,
            updated_by                     = @actor,
            updated_dt                     = SYSUTCDATETIME()
        WHERE org_assurance_observation_id = @observation_id;

        SET @observation_id_out = @observation_id;

        INSERT INTO grac_practice.org_assurance_observation_history(
            org_assurance_observation_id, organization_id,
            action_code, from_status_id, to_status_id,
            reason_text, actor_display_name, entered_by)
        VALUES(
            @observation_id, @organization_id,
            N'EDIT', @current_status_id, @current_status_id,
            N'Observation edited.', @actor, @actor);
    END

    COMMIT;
END
GO

-- =====================================================================
-- sp_org_assurance_observation_list  (adds 4 role columns)
-- Signature preserved -- just adds columns to both result sets.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_list
    @organization_id BIGINT,
    @execution_id    BIGINT       = NULL,
    @entity_id       BIGINT       = NULL,
    @status_code     NVARCHAR(60) = NULL,
    @severity_code   NVARCHAR(30) = NULL,
    @observation_type NVARCHAR(30) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 54100, 'organization_id is required.', 1;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    DECLARE @offset INT = (@page - 1) * @page_size;

    ;WITH base AS (
        SELECT o.org_assurance_observation_id,
               o.organization_id,
               o.org_assurance_execution_id,
               o.org_assurance_execution_entity_id,
               o.execution_code,
               o.execution_name,
               o.entity_dimension_code,
               o.entity_dimension_name,
               o.entity_code,
               o.entity_name,
               o.observation_code,
               o.observation_title,
               o.observation_type,
               o.severity_code,
               o.severity_name,
               st.status_code AS status_code,
               st.status_name AS status_name,
               st.is_terminal AS status_is_terminal,
               o.assigned_owner_employee_id,
               o.assigned_owner_display_name,
               o.assigned_owner_role_id,
               o.assigned_owner_role_name,
               o.assigned_reviewer_employee_id,
               o.assigned_reviewer_display_name,
               o.assigned_reviewer_role_id,
               o.assigned_reviewer_role_name,
               o.observed_dt,
               o.due_date,
               o.gap_id,
               o.entered_dt,
               o.updated_dt,
               (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_observation_evidence e
                 WHERE e.org_assurance_observation_id = o.org_assurance_observation_id
                   AND e.is_active = 1) AS evidence_count
        FROM grac_practice.org_assurance_observation o
        JOIN grac_practice.org_assurance_observation_status_master st
             ON st.org_assurance_observation_status_id = o.observation_status_id
        WHERE o.organization_id = @organization_id
          AND o.is_active = 1
          AND (@execution_id  IS NULL OR o.org_assurance_execution_id        = @execution_id)
          AND (@entity_id     IS NULL OR o.org_assurance_execution_entity_id = @entity_id)
          AND (@status_code   IS NULL OR st.status_code   = @status_code)
          AND (@severity_code IS NULL OR o.severity_code  = @severity_code)
          AND (@observation_type IS NULL OR o.observation_type = @observation_type)
          AND (@search IS NULL OR @search = ''
               OR o.observation_title LIKE N'%' + @search + N'%'
               OR o.observation_code  LIKE N'%' + @search + N'%'
               OR o.execution_name    LIKE N'%' + @search + N'%'
               OR o.entity_name       LIKE N'%' + @search + N'%')
    )
    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM base;

    ;WITH base AS (
        SELECT o.org_assurance_observation_id,
               o.organization_id,
               o.org_assurance_execution_id,
               o.org_assurance_execution_entity_id,
               o.execution_code,
               o.execution_name,
               o.entity_dimension_code,
               o.entity_dimension_name,
               o.entity_code,
               o.entity_name,
               o.observation_code,
               o.observation_title,
               o.observation_type,
               o.severity_code,
               o.severity_name,
               st.status_code AS status_code,
               st.status_name AS status_name,
               st.is_terminal AS status_is_terminal,
               o.assigned_owner_employee_id,
               o.assigned_owner_display_name,
               o.assigned_owner_role_id,
               o.assigned_owner_role_name,
               o.assigned_reviewer_employee_id,
               o.assigned_reviewer_display_name,
               o.assigned_reviewer_role_id,
               o.assigned_reviewer_role_name,
               o.observed_dt,
               o.due_date,
               o.gap_id,
               o.entered_dt,
               o.updated_dt,
               (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_observation_evidence e
                 WHERE e.org_assurance_observation_id = o.org_assurance_observation_id
                   AND e.is_active = 1) AS evidence_count
        FROM grac_practice.org_assurance_observation o
        JOIN grac_practice.org_assurance_observation_status_master st
             ON st.org_assurance_observation_status_id = o.observation_status_id
        WHERE o.organization_id = @organization_id
          AND o.is_active = 1
          AND (@execution_id  IS NULL OR o.org_assurance_execution_id        = @execution_id)
          AND (@entity_id     IS NULL OR o.org_assurance_execution_entity_id = @entity_id)
          AND (@status_code   IS NULL OR st.status_code   = @status_code)
          AND (@severity_code IS NULL OR o.severity_code  = @severity_code)
          AND (@observation_type IS NULL OR o.observation_type = @observation_type)
          AND (@search IS NULL OR @search = ''
               OR o.observation_title LIKE N'%' + @search + N'%'
               OR o.observation_code  LIKE N'%' + @search + N'%'
               OR o.execution_name    LIKE N'%' + @search + N'%'
               OR o.entity_name       LIKE N'%' + @search + N'%')
    )
    SELECT org_assurance_observation_id  AS ObservationId,
           organization_id                AS OrganizationId,
           org_assurance_execution_id     AS ExecutionId,
           org_assurance_execution_entity_id AS EntityId,
           execution_code                 AS ExecutionCode,
           execution_name                 AS ExecutionName,
           entity_dimension_code          AS EntityDimensionCode,
           entity_dimension_name          AS EntityDimensionName,
           entity_code                    AS EntityCode,
           entity_name                    AS EntityName,
           observation_code               AS ObservationCode,
           observation_title              AS ObservationTitle,
           observation_type               AS ObservationType,
           severity_code                  AS SeverityCode,
           severity_name                  AS SeverityName,
           status_code                    AS StatusCode,
           status_name                    AS StatusName,
           status_is_terminal             AS StatusIsTerminal,
           assigned_owner_display_name    AS OwnerDisplayName,
           assigned_owner_role_id         AS OwnerRoleId,
           assigned_owner_role_name       AS OwnerRoleName,
           assigned_reviewer_display_name AS ReviewerDisplayName,
           assigned_reviewer_role_id      AS ReviewerRoleId,
           assigned_reviewer_role_name    AS ReviewerRoleName,
           observed_dt                    AS ObservedDt,
           due_date                       AS DueDate,
           gap_id                         AS GapId,
           evidence_count                 AS EvidenceCount,
           entered_dt                     AS EnteredDt,
           updated_dt                     AS UpdatedDt
    FROM base
    ORDER BY observed_dt DESC, org_assurance_observation_id DESC
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- sp_org_assurance_observation_get (adds 4 role columns to detail)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_get
    @organization_id BIGINT,
    @observation_id  BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @observation_id IS NULL
        THROW 54101, 'organization_id and observation_id are required.', 1;

    SELECT o.org_assurance_observation_id  AS ObservationId,
           o.organization_id                AS OrganizationId,
           o.org_assurance_execution_id     AS ExecutionId,
           o.org_assurance_execution_entity_id AS EntityId,
           o.execution_code                 AS ExecutionCode,
           o.execution_name                 AS ExecutionName,
           o.entity_dimension_code          AS EntityDimensionCode,
           o.entity_dimension_name          AS EntityDimensionName,
           o.entity_code                    AS EntityCode,
           o.entity_name                    AS EntityName,
           o.observation_code               AS ObservationCode,
           o.observation_title              AS ObservationTitle,
           o.observation_description        AS ObservationDescription,
           o.observation_type               AS ObservationType,
           o.severity_id                    AS SeverityId,
           o.severity_code                  AS SeverityCode,
           o.severity_name                  AS SeverityName,
           st.status_code                   AS StatusCode,
           st.status_name                   AS StatusName,
           st.is_terminal                   AS StatusIsTerminal,
           o.source_question_code           AS SourceQuestionCode,
           o.source_question_text           AS SourceQuestionText,
           o.source_question_snapshot_json  AS SourceQuestionSnapshotJson,
           o.reported_by_employee_id        AS ReportedByEmployeeId,
           o.reported_by_display_name       AS ReportedByDisplayName,
           o.assigned_owner_employee_id     AS OwnerEmployeeId,
           o.assigned_owner_display_name    AS OwnerDisplayName,
           o.assigned_owner_role_id         AS OwnerRoleId,
           o.assigned_owner_role_name       AS OwnerRoleName,
           o.assigned_reviewer_employee_id  AS ReviewerEmployeeId,
           o.assigned_reviewer_display_name AS ReviewerDisplayName,
           o.assigned_reviewer_role_id      AS ReviewerRoleId,
           o.assigned_reviewer_role_name    AS ReviewerRoleName,
           o.observed_dt                    AS ObservedDt,
           o.due_date                       AS DueDate,
           o.accepted_dt                    AS AcceptedDt,
           o.rejected_dt                    AS RejectedDt,
           o.resolved_dt                    AS ResolvedDt,
           o.closed_dt                      AS ClosedDt,
           o.gap_id                         AS GapId,
           o.resolution_notes               AS ResolutionNotes,
           o.rejection_reason               AS RejectionReason,
           o.entered_by                     AS EnteredBy,
           o.entered_dt                     AS EnteredDt,
           o.updated_by                     AS UpdatedBy,
           o.updated_dt                     AS UpdatedDt
    FROM grac_practice.org_assurance_observation o
    JOIN grac_practice.org_assurance_observation_status_master st
         ON st.org_assurance_observation_status_id = o.observation_status_id
    WHERE o.organization_id = @organization_id
      AND o.org_assurance_observation_id = @observation_id
      AND o.is_active = 1;
END
GO

PRINT '116a Observation SPs extended for role+employee hybrid.';
GO
