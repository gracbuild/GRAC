-- =====================================================================
-- 102 Organization Assurance Observations -- Stage 4 stored procedures
--
-- Depends on 098 (execution) + 101 (observation schema).
--
-- Procedures:
--   sp_org_assurance_observation_severity_list
--   sp_org_assurance_observation_status_list
--   sp_org_assurance_observation_type_list      Fixed vocabulary
--   sp_org_assurance_observation_list           Paginated per org (+ filters)
--   sp_org_assurance_observation_get            Header + counts
--   sp_org_assurance_observation_save           Insert or update
--                                               (Open / InReview only)
--   sp_org_assurance_observation_delete         Soft (Open / Rejected only)
--   sp_org_assurance_observation_transition     Shared helper
--   sp_org_assurance_observation_submit_review  Open -> InReview
--   sp_org_assurance_observation_accept         InReview -> Accepted
--   sp_org_assurance_observation_reject         InReview -> Rejected
--   sp_org_assurance_observation_resolve        Accepted -> Resolved
--   sp_org_assurance_observation_close          Resolved -> Closed
--   sp_org_assurance_observation_evidence_list  Attachments per observation
--   sp_org_assurance_observation_evidence_save  Insert or update
--   sp_org_assurance_observation_evidence_delete Soft delete
--   sp_org_assurance_observation_history_list   Audit log
--
-- THROW reason codes: 54100-54199.
-- Rollback: 102_org_assurance_observation_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_observation','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_observation_evidence','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_observation_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_observation_severity_master','U') IS NULL
BEGIN
    RAISERROR('102: run 101 schema first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- Lookup: severity list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_severity_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT org_assurance_observation_severity_id AS SeverityId,
           severity_code AS SeverityCode,
           severity_name AS SeverityName,
           display_order AS DisplayOrder,
           color_hex     AS ColorHex
    FROM grac_practice.org_assurance_observation_severity_master
    WHERE is_active = 1
    ORDER BY display_order, org_assurance_observation_severity_id;
END
GO

-- =====================================================================
-- Lookup: status list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_status_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT org_assurance_observation_status_id AS StatusId,
           status_code   AS StatusCode,
           status_name   AS StatusName,
           display_order AS DisplayOrder,
           is_terminal   AS IsTerminal
    FROM grac_practice.org_assurance_observation_status_master
    WHERE is_active = 1
    ORDER BY display_order, org_assurance_observation_status_id;
END
GO

-- =====================================================================
-- Lookup: type list (fixed vocabulary from CHECK constraint)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_type_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TypeCode, TypeName, DisplayOrder
    FROM (VALUES
        (N'Finding',      N'Finding',       1),
        (N'Improvement',  N'Improvement',   2),
        (N'BestPractice', N'Best Practice', 3),
        (N'Risk',         N'Risk',          4)
    ) t(TypeCode, TypeName, DisplayOrder)
    ORDER BY DisplayOrder;
END
GO

-- =====================================================================
-- sp_org_assurance_observation_list (paginated + filters)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_list
    @organization_id BIGINT,
    @execution_id    BIGINT       = NULL,
    @entity_id       BIGINT       = NULL,   -- execution_entity_id
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
               o.assigned_owner_display_name,
               o.assigned_reviewer_display_name,
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
               o.assigned_owner_display_name,
               o.assigned_reviewer_display_name,
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
           assigned_reviewer_display_name AS ReviewerDisplayName,
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
-- sp_org_assurance_observation_get (header)
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
           o.assigned_reviewer_employee_id  AS ReviewerEmployeeId,
           o.assigned_reviewer_display_name AS ReviewerDisplayName,
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

-- =====================================================================
-- sp_org_assurance_observation_save  (create + update)
--
-- Edits only allowed while Open / InReview. Executions must belong to
-- the same organization.
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
        -- Auto-code if not provided
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
            assigned_reviewer_employee_id, assigned_reviewer_display_name,
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
            @assigned_reviewer_employee_id, @assigned_reviewer_display_name,
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
            assigned_reviewer_employee_id  = @assigned_reviewer_employee_id,
            assigned_reviewer_display_name = @assigned_reviewer_display_name,
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
-- sp_org_assurance_observation_delete  (soft)
--   Only Open / Rejected observations can be soft-deleted -- others
--   are audit evidence.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_delete
    @organization_id BIGINT,
    @observation_id  BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @observation_id IS NULL
        THROW 54101, 'organization_id and observation_id are required.', 1;

    DECLARE @obs_org BIGINT, @status_code NVARCHAR(60);
    SELECT @obs_org = o.organization_id, @status_code = st.status_code
    FROM grac_practice.org_assurance_observation o
    JOIN grac_practice.org_assurance_observation_status_master st
         ON st.org_assurance_observation_status_id = o.observation_status_id
    WHERE o.org_assurance_observation_id = @observation_id AND o.is_active = 1;

    IF @obs_org IS NULL       THROW 54110, 'Observation not found.', 1;
    IF @obs_org <> @organization_id
        THROW 54111, 'Observation belongs to a different organization.', 1;
    IF @status_code NOT IN (N'Open', N'Rejected')
        THROW 54113, 'Only Open or Rejected observations can be soft-deleted.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.org_assurance_observation_evidence
    SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_observation_id = @observation_id AND is_active = 1;

    UPDATE grac_practice.org_assurance_observation
    SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_observation_id = @observation_id;

    INSERT INTO grac_practice.org_assurance_observation_history(
        org_assurance_observation_id, organization_id,
        action_code, reason_text, actor_display_name, entered_by)
    VALUES(
        @observation_id, @organization_id,
        N'DELETE', N'Soft-deleted.', @actor, @actor);

    COMMIT;
END
GO

-- =====================================================================
-- Shared lifecycle transition helper
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_transition
    @organization_id     BIGINT,
    @observation_id      BIGINT,
    @expected_from_codes NVARCHAR(200),  -- comma-separated allowed source codes
    @to_code             NVARCHAR(60),
    @stamp_field         NVARCHAR(30) = NULL, -- accepted / rejected / resolved / closed
    @notes               NVARCHAR(MAX) = NULL,
    @actor               NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @observation_id IS NULL
        THROW 54101, 'organization_id and observation_id are required.', 1;

    DECLARE @to_id INT, @from_id INT, @obs_org BIGINT, @current_code NVARCHAR(60);

    SELECT @to_id = org_assurance_observation_status_id
    FROM grac_practice.org_assurance_observation_status_master
    WHERE status_code = @to_code;
    IF @to_id IS NULL
        THROW 54114, 'Unknown target status_code in observation transition.', 1;

    SELECT @obs_org      = o.organization_id,
           @current_code = st.status_code,
           @from_id      = o.observation_status_id
    FROM grac_practice.org_assurance_observation o
    JOIN grac_practice.org_assurance_observation_status_master st
         ON st.org_assurance_observation_status_id = o.observation_status_id
    WHERE o.org_assurance_observation_id = @observation_id AND o.is_active = 1;

    IF @obs_org IS NULL      THROW 54110, 'Observation not found.', 1;
    IF @obs_org <> @organization_id
        THROW 54111, 'Observation belongs to a different organization.', 1;

    DECLARE @allowed TABLE(code NVARCHAR(60));
    INSERT INTO @allowed(code)
    SELECT LTRIM(RTRIM(value))
    FROM STRING_SPLIT(@expected_from_codes, ',')
    WHERE LTRIM(RTRIM(value)) <> '';

    IF NOT EXISTS (SELECT 1 FROM @allowed WHERE code = @current_code)
        THROW 54115, 'Illegal observation lifecycle transition -- current status does not match the expected source.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.org_assurance_observation
    SET observation_status_id = @to_id,
        accepted_dt = CASE WHEN @stamp_field = N'accepted' AND accepted_dt IS NULL THEN SYSUTCDATETIME() ELSE accepted_dt END,
        rejected_dt = CASE WHEN @stamp_field = N'rejected' AND rejected_dt IS NULL THEN SYSUTCDATETIME() ELSE rejected_dt END,
        resolved_dt = CASE WHEN @stamp_field = N'resolved' AND resolved_dt IS NULL THEN SYSUTCDATETIME() ELSE resolved_dt END,
        closed_dt   = CASE WHEN @stamp_field = N'closed'   AND closed_dt   IS NULL THEN SYSUTCDATETIME() ELSE closed_dt   END,
        resolution_notes = CASE WHEN @stamp_field = N'resolved' THEN ISNULL(@notes, resolution_notes) ELSE resolution_notes END,
        rejection_reason = CASE WHEN @stamp_field = N'rejected' THEN ISNULL(@notes, rejection_reason) ELSE rejection_reason END,
        updated_by  = @actor,
        updated_dt  = SYSUTCDATETIME()
    WHERE org_assurance_observation_id = @observation_id;

    INSERT INTO grac_practice.org_assurance_observation_history(
        org_assurance_observation_id, organization_id,
        action_code, from_status_id, to_status_id,
        reason_text, actor_display_name, entered_by)
    VALUES(
        @observation_id, @organization_id,
        UPPER(@to_code), @from_id, @to_id,
        @notes, @actor, @actor);

    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_submit_review
    @organization_id BIGINT, @observation_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_observation_transition
        @organization_id = @organization_id, @observation_id = @observation_id,
        @expected_from_codes = N'Open', @to_code = N'InReview',
        @stamp_field = NULL, @notes = @notes, @actor = @actor;
END
GO

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
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_reject
    @organization_id BIGINT, @observation_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_observation_transition
        @organization_id = @organization_id, @observation_id = @observation_id,
        @expected_from_codes = N'InReview', @to_code = N'Rejected',
        @stamp_field = N'rejected', @notes = @notes, @actor = @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_resolve
    @organization_id BIGINT, @observation_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_observation_transition
        @organization_id = @organization_id, @observation_id = @observation_id,
        @expected_from_codes = N'Accepted', @to_code = N'Resolved',
        @stamp_field = N'resolved', @notes = @notes, @actor = @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_close
    @organization_id BIGINT, @observation_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_observation_transition
        @organization_id = @organization_id, @observation_id = @observation_id,
        @expected_from_codes = N'Resolved', @to_code = N'Closed',
        @stamp_field = N'closed', @notes = @notes, @actor = @actor;
END
GO

-- =====================================================================
-- Evidence attachments
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_evidence_list
    @organization_id BIGINT,
    @observation_id  BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @observation_id IS NULL
        THROW 54101, 'organization_id and observation_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_observation
        WHERE org_assurance_observation_id = @observation_id
          AND organization_id              = @organization_id)
        THROW 54111, 'Observation belongs to a different organization.', 1;

    SELECT e.org_assurance_observation_evidence_id AS EvidenceId,
           e.org_assurance_observation_id           AS ObservationId,
           e.evidence_config_id                     AS EvidenceConfigId,
           e.evidence_type_code                     AS EvidenceTypeCode,
           e.evidence_type_name                     AS EvidenceTypeName,
           e.evidence_label                         AS EvidenceLabel,
           e.file_id                                AS FileId,
           e.storage_location                       AS StorageLocation,
           e.storage_locator                        AS StorageLocator,
           e.original_file_name                     AS OriginalFileName,
           e.file_size_bytes                        AS FileSizeBytes,
           e.mime_type                              AS MimeType,
           e.collected_by_employee_id               AS CollectedByEmployeeId,
           e.collected_by_display_name              AS CollectedByDisplayName,
           e.collected_dt                           AS CollectedDt,
           e.notes                                  AS Notes,
           e.entered_by                             AS EnteredBy,
           e.entered_dt                             AS EnteredDt,
           e.updated_by                             AS UpdatedBy,
           e.updated_dt                             AS UpdatedDt
    FROM grac_practice.org_assurance_observation_evidence e
    WHERE e.org_assurance_observation_id = @observation_id
      AND e.organization_id              = @organization_id
      AND e.is_active = 1
    ORDER BY e.collected_dt DESC, e.org_assurance_observation_evidence_id DESC;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_evidence_save
    @organization_id           BIGINT,
    @observation_id            BIGINT,
    @evidence_id               BIGINT        = NULL,
    @evidence_config_id        BIGINT        = NULL,
    @evidence_type_code        NVARCHAR(60)  = NULL,
    @evidence_type_name        NVARCHAR(200) = NULL,
    @evidence_label            NVARCHAR(240) = NULL,
    @file_id                   BIGINT        = NULL,
    @storage_location          NVARCHAR(120) = NULL,
    @storage_locator           NVARCHAR(1000)= NULL,
    @original_file_name        NVARCHAR(400) = NULL,
    @file_size_bytes           BIGINT        = NULL,
    @mime_type                 NVARCHAR(200) = NULL,
    @collected_by_employee_id  BIGINT        = NULL,
    @collected_by_display_name NVARCHAR(240) = NULL,
    @collected_dt              DATETIME2     = NULL,
    @notes                     NVARCHAR(MAX) = NULL,
    @actor                     NVARCHAR(100) = 'system',
    @evidence_id_out           BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @observation_id IS NULL
        THROW 54101, 'organization_id and observation_id are required.', 1;

    -- Verify observation ownership + editable status.
    DECLARE @obs_org BIGINT, @status_code NVARCHAR(60);
    SELECT @obs_org = o.organization_id, @status_code = st.status_code
    FROM grac_practice.org_assurance_observation o
    JOIN grac_practice.org_assurance_observation_status_master st
         ON st.org_assurance_observation_status_id = o.observation_status_id
    WHERE o.org_assurance_observation_id = @observation_id AND o.is_active = 1;

    IF @obs_org IS NULL       THROW 54110, 'Observation not found.', 1;
    IF @obs_org <> @organization_id
        THROW 54111, 'Observation belongs to a different organization.', 1;
    IF @status_code IN (N'Closed', N'Rejected')
        THROW 54116, 'Evidence cannot be added to Closed or Rejected observations.', 1;

    BEGIN TRAN;

    IF @evidence_id IS NULL
    BEGIN
        INSERT INTO grac_practice.org_assurance_observation_evidence(
            org_assurance_observation_id, organization_id,
            evidence_config_id, evidence_type_code, evidence_type_name, evidence_label,
            file_id, storage_location, storage_locator,
            original_file_name, file_size_bytes, mime_type,
            collected_by_employee_id, collected_by_display_name, collected_dt,
            notes, is_active, entered_by, entered_dt)
        VALUES(
            @observation_id, @organization_id,
            @evidence_config_id, @evidence_type_code, @evidence_type_name, @evidence_label,
            @file_id, @storage_location, @storage_locator,
            @original_file_name, @file_size_bytes, @mime_type,
            @collected_by_employee_id, @collected_by_display_name,
            ISNULL(@collected_dt, SYSUTCDATETIME()),
            @notes, 1, @actor, SYSUTCDATETIME());
        SET @evidence_id_out = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @ev_obs BIGINT;
        SELECT @ev_obs = org_assurance_observation_id
        FROM grac_practice.org_assurance_observation_evidence
        WHERE org_assurance_observation_evidence_id = @evidence_id
          AND is_active = 1;

        IF @ev_obs IS NULL       BEGIN ROLLBACK; THROW 54117, 'Evidence item not found.', 1; END
        IF @ev_obs <> @observation_id
            BEGIN ROLLBACK; THROW 54118, 'Evidence item does not belong to the specified observation.', 1; END

        UPDATE grac_practice.org_assurance_observation_evidence
        SET evidence_config_id      = @evidence_config_id,
            evidence_type_code      = @evidence_type_code,
            evidence_type_name      = @evidence_type_name,
            evidence_label          = @evidence_label,
            file_id                 = @file_id,
            storage_location        = @storage_location,
            storage_locator         = @storage_locator,
            original_file_name      = @original_file_name,
            file_size_bytes         = @file_size_bytes,
            mime_type               = @mime_type,
            collected_by_employee_id  = @collected_by_employee_id,
            collected_by_display_name = @collected_by_display_name,
            collected_dt            = ISNULL(@collected_dt, collected_dt),
            notes                   = @notes,
            updated_by              = @actor,
            updated_dt              = SYSUTCDATETIME()
        WHERE org_assurance_observation_evidence_id = @evidence_id;
        SET @evidence_id_out = @evidence_id;
    END

    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_evidence_delete
    @organization_id BIGINT,
    @observation_id  BIGINT,
    @evidence_id     BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @observation_id IS NULL OR @evidence_id IS NULL
        THROW 54101, 'organization_id, observation_id and evidence_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM grac_practice.org_assurance_observation_evidence e
        JOIN grac_practice.org_assurance_observation o
             ON o.org_assurance_observation_id = e.org_assurance_observation_id
        WHERE e.org_assurance_observation_evidence_id = @evidence_id
          AND e.org_assurance_observation_id          = @observation_id
          AND o.organization_id                       = @organization_id
          AND e.is_active = 1)
        THROW 54117, 'Evidence item not found.', 1;

    UPDATE grac_practice.org_assurance_observation_evidence
    SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_observation_evidence_id = @evidence_id;
END
GO

-- =====================================================================
-- History read
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_history_list
    @organization_id BIGINT,
    @observation_id  BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @observation_id IS NULL
        THROW 54101, 'organization_id and observation_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_observation
        WHERE org_assurance_observation_id = @observation_id
          AND organization_id              = @organization_id)
        THROW 54111, 'Observation belongs to a different organization.', 1;

    SELECT h.org_assurance_observation_history_id AS HistoryId,
           h.action_code                           AS ActionCode,
           h.from_status_id                        AS FromStatusId,
           fs.status_code                          AS FromStatusCode,
           fs.status_name                          AS FromStatusName,
           h.to_status_id                          AS ToStatusId,
           ts.status_code                          AS ToStatusCode,
           ts.status_name                          AS ToStatusName,
           h.reason_text                           AS ReasonText,
           h.actor_display_name                    AS ActorDisplayName,
           h.entered_by                            AS EnteredBy,
           h.entered_dt                            AS EnteredDt
    FROM grac_practice.org_assurance_observation_history h
    LEFT JOIN grac_practice.org_assurance_observation_status_master fs
         ON fs.org_assurance_observation_status_id = h.from_status_id
    LEFT JOIN grac_practice.org_assurance_observation_status_master ts
         ON ts.org_assurance_observation_status_id = h.to_status_id
    WHERE h.org_assurance_observation_id = @observation_id
    ORDER BY h.entered_dt DESC, h.org_assurance_observation_history_id DESC;
END
GO

PRINT '102 Organization Assurance Observation procedures deployed.';
GO
