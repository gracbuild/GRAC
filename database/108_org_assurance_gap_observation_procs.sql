-- =====================================================================
-- 108 Organization Assurance Gap Center -- Stage 4b stored procedures
--
-- Depends on 107 (junction schema).
--
-- NEW procedures:
--   sp_org_assurance_gap_observation_attach
--   sp_org_assurance_gap_observation_detach
--   sp_org_assurance_gap_observation_list      Observations linked to a gap
--   sp_org_assurance_observation_linked_gaps_list  Gaps linked to an obs
--   sp_org_assurance_gap_merge                 Merge gap A into gap B
--
-- REWRITTEN procedures (CREATE OR ALTER):
--   sp_org_assurance_gap_generate_from_observation  Adds junction write
--   sp_org_assurance_gap_list                       Adds LinkedObservationCount
--   sp_org_assurance_gap_get                        Adds LinkedObservationCount
--   sp_org_assurance_gap_delete                     Cascades junction deactivate
--   sp_org_assurance_observation_delete             Cascades junction deactivate
--
-- THROW reason codes: 54225-54299.
-- Rollback: 108_org_assurance_gap_observation_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_gap_observation','U') IS NULL
BEGIN
    RAISERROR('108: run 107 schema first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_org_assurance_gap_observation_attach
--   Attaches an observation to a gap (many-to-one from the gap side).
--   Idempotent -- if an active junction already exists, returns it.
--   Also updates the observation.gap_id "primary gap" pointer to the
--   newly-attached gap when the observation had none, for backward
--   compat with older consumers.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_observation_attach
    @organization_id BIGINT,
    @gap_id          BIGINT,
    @observation_id  BIGINT,
    @link_source     NVARCHAR(30)  = N'MANUAL',
    @notes           NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100) = 'system',
    @junction_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @gap_id IS NULL OR @observation_id IS NULL
        THROW 54225, 'organization_id, gap_id and observation_id are required.', 1;
    IF @link_source NOT IN (N'AUTO', N'MANUAL', N'MERGE')
        THROW 54226, 'link_source must be AUTO / MANUAL / MERGE.', 1;

    -- Verify both sides belong to this organization + are active.
    DECLARE @gap_org BIGINT;
    SELECT @gap_org = organization_id
    FROM grac_practice.org_assurance_gap
    WHERE org_assurance_gap_id = @gap_id AND is_active = 1;
    IF @gap_org IS NULL       THROW 54227, 'Gap not found.', 1;
    IF @gap_org <> @organization_id
        THROW 54228, 'Gap belongs to a different organization.', 1;

    DECLARE @obs_org BIGINT, @obs_gap_id BIGINT;
    SELECT @obs_org = organization_id, @obs_gap_id = gap_id
    FROM grac_practice.org_assurance_observation
    WHERE org_assurance_observation_id = @observation_id AND is_active = 1;
    IF @obs_org IS NULL       THROW 54229, 'Observation not found.', 1;
    IF @obs_org <> @organization_id
        THROW 54230, 'Observation belongs to a different organization.', 1;

    BEGIN TRAN;

    -- Idempotent guard -- if already actively linked, return that.
    SELECT @junction_id_out = org_assurance_gap_observation_id
    FROM grac_practice.org_assurance_gap_observation
    WHERE org_assurance_gap_id         = @gap_id
      AND org_assurance_observation_id = @observation_id
      AND is_active = 1;

    IF @junction_id_out IS NULL
    BEGIN
        INSERT INTO grac_practice.org_assurance_gap_observation(
            org_assurance_gap_id, org_assurance_observation_id, organization_id,
            link_source, linked_by, linked_dt, notes, is_active)
        VALUES(
            @gap_id, @observation_id, @organization_id,
            @link_source, @actor, SYSUTCDATETIME(), @notes, 1);
        SET @junction_id_out = SCOPE_IDENTITY();
    END

    -- Backward compat: keep observation.gap_id populated with the
    -- observation's primary gap (the first active link -- do not
    -- overwrite an existing pointer).
    IF @obs_gap_id IS NULL
        UPDATE grac_practice.org_assurance_observation
        SET gap_id = @gap_id, updated_by = @actor, updated_dt = SYSUTCDATETIME()
        WHERE org_assurance_observation_id = @observation_id;

    -- History: log on the gap side.
    IF OBJECT_ID('grac_practice.org_assurance_gap_history','U') IS NOT NULL
        INSERT INTO grac_practice.org_assurance_gap_history(
            org_assurance_gap_id, organization_id, action_code, reason_text,
            actor_display_name, entered_by)
        VALUES(
            @gap_id, @organization_id, N'ATTACH_OBSERVATION',
            N'Observation #' + CAST(@observation_id AS NVARCHAR(20)) +
                N' attached (' + @link_source + N').' +
                CASE WHEN @notes IS NULL THEN N'' ELSE N' Note: ' + @notes END,
            @actor, @actor);

    COMMIT;
END
GO

-- =====================================================================
-- sp_org_assurance_gap_observation_detach
--   Soft-detach a junction row with a reason.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_observation_detach
    @organization_id BIGINT,
    @gap_id          BIGINT,
    @observation_id  BIGINT,
    @reason          NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @gap_id IS NULL OR @observation_id IS NULL
        THROW 54225, 'organization_id, gap_id and observation_id are required.', 1;

    -- Verify org via the junction row itself so we don't accept
    -- cross-org tampering.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_gap_observation
        WHERE org_assurance_gap_id         = @gap_id
          AND org_assurance_observation_id = @observation_id
          AND organization_id              = @organization_id
          AND is_active = 1)
        THROW 54231, 'Active junction row not found.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.org_assurance_gap_observation
    SET is_active     = 0,
        detach_by     = @actor,
        detach_dt     = SYSUTCDATETIME(),
        detach_reason = @reason
    WHERE org_assurance_gap_id         = @gap_id
      AND org_assurance_observation_id = @observation_id
      AND is_active = 1;

    -- If the observation's primary gap pointer was this gap and there
    -- are still OTHER active junctions, retarget to the next one.
    IF EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_observation
        WHERE org_assurance_observation_id = @observation_id
          AND gap_id = @gap_id)
    BEGIN
        DECLARE @next_gap BIGINT = (
            SELECT TOP 1 org_assurance_gap_id
            FROM grac_practice.org_assurance_gap_observation
            WHERE org_assurance_observation_id = @observation_id
              AND is_active = 1
            ORDER BY linked_dt DESC, org_assurance_gap_observation_id DESC);
        UPDATE grac_practice.org_assurance_observation
        SET gap_id = @next_gap,
            updated_by = @actor,
            updated_dt = SYSUTCDATETIME()
        WHERE org_assurance_observation_id = @observation_id;
    END

    IF OBJECT_ID('grac_practice.org_assurance_gap_history','U') IS NOT NULL
        INSERT INTO grac_practice.org_assurance_gap_history(
            org_assurance_gap_id, organization_id, action_code, reason_text,
            actor_display_name, entered_by)
        VALUES(
            @gap_id, @organization_id, N'DETACH_OBSERVATION',
            N'Observation #' + CAST(@observation_id AS NVARCHAR(20)) + N' detached.'
            + CASE WHEN @reason IS NULL THEN N'' ELSE N' Reason: ' + @reason END,
            @actor, @actor);

    COMMIT;
END
GO

-- =====================================================================
-- sp_org_assurance_gap_observation_list
--   Observations attached to a gap (active links only by default).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_observation_list
    @organization_id  BIGINT,
    @gap_id           BIGINT,
    @include_detached BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @gap_id IS NULL
        THROW 54225, 'organization_id and gap_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_gap
        WHERE org_assurance_gap_id = @gap_id
          AND organization_id      = @organization_id)
        THROW 54228, 'Gap belongs to a different organization.', 1;

    SELECT j.org_assurance_gap_observation_id AS JunctionId,
           j.org_assurance_gap_id              AS GapId,
           j.org_assurance_observation_id      AS ObservationId,
           o.observation_code                   AS ObservationCode,
           o.observation_title                  AS ObservationTitle,
           o.severity_code                      AS SeverityCode,
           o.severity_name                      AS SeverityName,
           os.status_code                       AS ObservationStatusCode,
           os.status_name                       AS ObservationStatusName,
           o.execution_code                     AS ExecutionCode,
           o.execution_name                     AS ExecutionName,
           o.entity_name                        AS EntityName,
           j.link_source                        AS LinkSource,
           j.linked_by                          AS LinkedBy,
           j.linked_dt                          AS LinkedDt,
           j.notes                              AS Notes,
           j.is_active                          AS IsActive,
           j.detach_by                          AS DetachBy,
           j.detach_dt                          AS DetachDt,
           j.detach_reason                      AS DetachReason
    FROM grac_practice.org_assurance_gap_observation j
    JOIN grac_practice.org_assurance_observation o
         ON o.org_assurance_observation_id = j.org_assurance_observation_id
    JOIN grac_practice.org_assurance_observation_status_master os
         ON os.org_assurance_observation_status_id = o.observation_status_id
    WHERE j.org_assurance_gap_id = @gap_id
      AND j.organization_id      = @organization_id
      AND (@include_detached = 1 OR j.is_active = 1)
    ORDER BY j.is_active DESC, j.linked_dt DESC, j.org_assurance_gap_observation_id DESC;
END
GO

-- =====================================================================
-- sp_org_assurance_observation_linked_gaps_list
--   Reverse view -- gaps that reference this observation.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_linked_gaps_list
    @organization_id  BIGINT,
    @observation_id   BIGINT,
    @include_detached BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @observation_id IS NULL
        THROW 54225, 'organization_id and observation_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_observation
        WHERE org_assurance_observation_id = @observation_id
          AND organization_id              = @organization_id)
        THROW 54230, 'Observation belongs to a different organization.', 1;

    SELECT j.org_assurance_gap_observation_id AS JunctionId,
           j.org_assurance_gap_id              AS GapId,
           g.gap_code                           AS GapCode,
           g.gap_title                          AS GapTitle,
           g.severity_code                      AS SeverityCode,
           g.severity_name                      AS SeverityName,
           gs.status_code                       AS GapStatusCode,
           gs.status_name                       AS GapStatusName,
           j.link_source                        AS LinkSource,
           j.linked_by                          AS LinkedBy,
           j.linked_dt                          AS LinkedDt,
           j.notes                              AS Notes,
           j.is_active                          AS IsActive,
           j.detach_by                          AS DetachBy,
           j.detach_dt                          AS DetachDt,
           j.detach_reason                      AS DetachReason
    FROM grac_practice.org_assurance_gap_observation j
    JOIN grac_practice.org_assurance_gap g
         ON g.org_assurance_gap_id = j.org_assurance_gap_id
    JOIN grac_practice.org_assurance_gap_status_master gs
         ON gs.org_assurance_gap_status_id = g.gap_status_id
    WHERE j.org_assurance_observation_id = @observation_id
      AND j.organization_id              = @organization_id
      AND (@include_detached = 1 OR j.is_active = 1)
    ORDER BY j.is_active DESC, j.linked_dt DESC, j.org_assurance_gap_observation_id DESC;
END
GO

-- =====================================================================
-- sp_org_assurance_gap_merge
--   Merge SOURCE gap into TARGET gap:
--     * All active observation links on SOURCE are re-attached to
--       TARGET with link_source = MERGE
--     * Original SOURCE junctions are soft-detached with reason
--       "Merged into gap #TARGET"
--     * Any observation with observation.gap_id = SOURCE is retargeted
--       to TARGET
--     * SOURCE gap is soft-closed with a merge note
--     * History logged on both gaps
--   Merging into oneself is rejected.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_merge
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
        THROW 54232, 'organization_id, source_gap_id and target_gap_id are required.', 1;
    IF @source_gap_id = @target_gap_id
        THROW 54233, 'A gap cannot be merged into itself.', 1;

    DECLARE @source_org BIGINT, @source_status NVARCHAR(60), @source_status_id INT;
    SELECT @source_org       = g.organization_id,
           @source_status    = st.status_code,
           @source_status_id = g.gap_status_id
    FROM grac_practice.org_assurance_gap g
    JOIN grac_practice.org_assurance_gap_status_master st
         ON st.org_assurance_gap_status_id = g.gap_status_id
    WHERE g.org_assurance_gap_id = @source_gap_id AND g.is_active = 1;
    IF @source_org IS NULL       THROW 54234, 'Source gap not found.', 1;
    IF @source_org <> @organization_id
        THROW 54235, 'Source gap belongs to a different organization.', 1;
    IF @source_status = N'Closed'
        THROW 54236, 'Closed gaps cannot be merged.', 1;

    DECLARE @target_org BIGINT, @target_status NVARCHAR(60);
    SELECT @target_org    = g.organization_id,
           @target_status = st.status_code
    FROM grac_practice.org_assurance_gap g
    JOIN grac_practice.org_assurance_gap_status_master st
         ON st.org_assurance_gap_status_id = g.gap_status_id
    WHERE g.org_assurance_gap_id = @target_gap_id AND g.is_active = 1;
    IF @target_org IS NULL       THROW 54237, 'Target gap not found.', 1;
    IF @target_org <> @organization_id
        THROW 54238, 'Target gap belongs to a different organization.', 1;
    IF @target_status = N'Closed'
        THROW 54239, 'Target gap is Closed -- cannot receive merged observations.', 1;

    DECLARE @closed_status_id INT = (
        SELECT org_assurance_gap_status_id
        FROM grac_practice.org_assurance_gap_status_master WHERE status_code = N'Closed');

    DECLARE @merge_note NVARCHAR(400) =
        N'Merged into gap #' + CAST(@target_gap_id AS NVARCHAR(20))
        + CASE WHEN @reason IS NULL THEN N'' ELSE N': ' + @reason END;

    BEGIN TRAN;

    -- Snapshot the observations currently attached to SOURCE.
    DECLARE @moved TABLE(observation_id BIGINT PRIMARY KEY);
    INSERT INTO @moved(observation_id)
    SELECT DISTINCT org_assurance_observation_id
    FROM grac_practice.org_assurance_gap_observation
    WHERE org_assurance_gap_id = @source_gap_id
      AND is_active = 1;

    -- Attach each to TARGET (idempotent -- may already be attached).
    INSERT INTO grac_practice.org_assurance_gap_observation(
        org_assurance_gap_id, org_assurance_observation_id, organization_id,
        link_source, linked_by, linked_dt, notes, is_active)
    SELECT @target_gap_id, m.observation_id, @organization_id,
           N'MERGE', @actor, SYSUTCDATETIME(), @merge_note, 1
    FROM @moved m
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_gap_observation j2
        WHERE j2.org_assurance_gap_id         = @target_gap_id
          AND j2.org_assurance_observation_id = m.observation_id
          AND j2.is_active = 1);

    -- Detach the SOURCE junctions.
    UPDATE grac_practice.org_assurance_gap_observation
    SET is_active = 0,
        detach_by = @actor,
        detach_dt = SYSUTCDATETIME(),
        detach_reason = @merge_note
    WHERE org_assurance_gap_id = @source_gap_id
      AND is_active = 1;

    -- Retarget observation.gap_id pointer where it was pointing at
    -- SOURCE.
    UPDATE grac_practice.org_assurance_observation
    SET gap_id     = @target_gap_id,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE gap_id = @source_gap_id
      AND organization_id = @organization_id;

    -- Close SOURCE gap with the merge note.
    UPDATE grac_practice.org_assurance_gap
    SET gap_status_id  = @closed_status_id,
        closed_dt      = ISNULL(closed_dt, SYSUTCDATETIME()),
        closure_notes  = ISNULL(closure_notes, @merge_note),
        updated_by     = @actor,
        updated_dt     = SYSUTCDATETIME()
    WHERE org_assurance_gap_id = @source_gap_id;

    -- History on both sides.
    IF OBJECT_ID('grac_practice.org_assurance_gap_history','U') IS NOT NULL
    BEGIN
        INSERT INTO grac_practice.org_assurance_gap_history(
            org_assurance_gap_id, organization_id, action_code,
            from_status_id, to_status_id, reason_text,
            actor_display_name, entered_by)
        VALUES(
            @source_gap_id, @organization_id, N'MERGED_INTO',
            @source_status_id, @closed_status_id, @merge_note,
            @actor, @actor);

        INSERT INTO grac_practice.org_assurance_gap_history(
            org_assurance_gap_id, organization_id, action_code,
            reason_text, actor_display_name, entered_by)
        VALUES(
            @target_gap_id, @organization_id, N'MERGE_RECEIVED',
            N'Received observations from merged gap #' + CAST(@source_gap_id AS NVARCHAR(20))
            + CASE WHEN @reason IS NULL THEN N'' ELSE N': ' + @reason END,
            @actor, @actor);
    END

    COMMIT;
END
GO

-- =====================================================================
-- REWRITE: sp_org_assurance_gap_generate_from_observation
--   Same behaviour as 105 BUT also writes the junction row so the
--   many-to-many model is populated from day one.
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
    IF @obs_status <> N'Accepted'
        THROW 54217, 'Only Accepted observations can generate a gap.', 1;

    -- Idempotency (STRONGER now that junction exists) -- if ANY active
    -- junction already exists for this observation, return the most
    -- recently linked gap.
    DECLARE @junction_gap_id BIGINT = (
        SELECT TOP 1 org_assurance_gap_id
        FROM grac_practice.org_assurance_gap_observation
        WHERE org_assurance_observation_id = @observation_id
          AND organization_id              = @organization_id
          AND is_active = 1
        ORDER BY linked_dt DESC, org_assurance_gap_observation_id DESC);

    IF @junction_gap_id IS NOT NULL
    BEGIN
        SET @gap_id_out = @junction_gap_id;
        RETURN;
    END

    -- Also honour the legacy observation.gap_id pointer (older data).
    IF @existing_gap_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM grac_practice.org_assurance_gap
                   WHERE org_assurance_gap_id = @existing_gap_id
                     AND organization_id      = @organization_id
                     AND is_active = 1)
    BEGIN
        SET @gap_id_out = @existing_gap_id;

        -- Back-fill the missing junction row so future reads use the
        -- junction as source of truth.
        IF NOT EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_gap_observation
            WHERE org_assurance_gap_id         = @existing_gap_id
              AND org_assurance_observation_id = @observation_id
              AND is_active = 1)
            INSERT INTO grac_practice.org_assurance_gap_observation(
                org_assurance_gap_id, org_assurance_observation_id, organization_id,
                link_source, linked_by, linked_dt, is_active)
            VALUES(
                @existing_gap_id, @observation_id, @organization_id,
                N'AUTO', @actor, SYSUTCDATETIME(), 1);
        RETURN;
    END

    -- Otherwise create a new gap + junction.
    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    DECLARE @open_status_id INT = (
        SELECT org_assurance_gap_status_id
        FROM grac_practice.org_assurance_gap_status_master WHERE status_code = N'Open');

    DECLARE @gap_code NVARCHAR(120) =
        ISNULL(@obs_code, N'GAP') + N'-GAP-'
        + FORMAT(SYSUTCDATETIME(), 'yyyyMMdd-HHmmss');

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

    -- Junction row (source of truth going forward).
    INSERT INTO grac_practice.org_assurance_gap_observation(
        org_assurance_gap_id, org_assurance_observation_id, organization_id,
        link_source, linked_by, linked_dt, is_active)
    VALUES(
        @gap_id_out, @observation_id, @organization_id,
        N'AUTO', @actor, SYSUTCDATETIME(), 1);

    -- Backward-compat pointer.
    UPDATE grac_practice.org_assurance_observation
    SET gap_id     = @gap_id_out,
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
-- REWRITE: sp_org_assurance_gap_list
--   Adds LinkedObservationCount from the junction.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_list
    @organization_id BIGINT,
    @execution_id    BIGINT       = NULL,
    @observation_id  BIGINT       = NULL,   -- filters to gaps linked to this obs
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
                   AND a.action_status_code = N'Completed') AS action_completed_count,
               (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_gap_observation j
                 WHERE j.org_assurance_gap_id = g.org_assurance_gap_id
                   AND j.is_active = 1) AS linked_observation_count
        FROM grac_practice.org_assurance_gap g
        JOIN grac_practice.org_assurance_gap_status_master st
             ON st.org_assurance_gap_status_id = g.gap_status_id
        WHERE g.organization_id = @organization_id
          AND g.is_active = 1
          AND (@execution_id   IS NULL OR g.org_assurance_execution_id = @execution_id)
          AND (@observation_id IS NULL OR EXISTS (
                    SELECT 1 FROM grac_practice.org_assurance_gap_observation j
                    WHERE j.org_assurance_gap_id         = g.org_assurance_gap_id
                      AND j.org_assurance_observation_id = @observation_id
                      AND j.is_active = 1))
          AND (@status_code    IS NULL OR st.status_code   = @status_code)
          AND (@severity_code  IS NULL OR g.severity_code  = @severity_code)
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
                   AND a.action_status_code = N'Completed') AS action_completed_count,
               (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_gap_observation j
                 WHERE j.org_assurance_gap_id = g.org_assurance_gap_id
                   AND j.is_active = 1) AS linked_observation_count
        FROM grac_practice.org_assurance_gap g
        JOIN grac_practice.org_assurance_gap_status_master st
             ON st.org_assurance_gap_status_id = g.gap_status_id
        WHERE g.organization_id = @organization_id
          AND g.is_active = 1
          AND (@execution_id   IS NULL OR g.org_assurance_execution_id = @execution_id)
          AND (@observation_id IS NULL OR EXISTS (
                    SELECT 1 FROM grac_practice.org_assurance_gap_observation j
                    WHERE j.org_assurance_gap_id         = g.org_assurance_gap_id
                      AND j.org_assurance_observation_id = @observation_id
                      AND j.is_active = 1))
          AND (@status_code    IS NULL OR st.status_code   = @status_code)
          AND (@severity_code  IS NULL OR g.severity_code  = @severity_code)
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
           linked_observation_count          AS LinkedObservationCount,
           entered_dt                        AS EnteredDt,
           updated_dt                        AS UpdatedDt
    FROM base
    ORDER BY opened_dt DESC, org_assurance_gap_id DESC
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- REWRITE: sp_org_assurance_gap_get -- adds LinkedObservationCount
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
           g.updated_dt                       AS UpdatedDt,
           (SELECT COUNT_BIG(1)
              FROM grac_practice.org_assurance_gap_observation j
             WHERE j.org_assurance_gap_id = g.org_assurance_gap_id
               AND j.is_active = 1) AS LinkedObservationCount
    FROM grac_practice.org_assurance_gap g
    JOIN grac_practice.org_assurance_gap_status_master st
         ON st.org_assurance_gap_status_id = g.gap_status_id
    WHERE g.organization_id = @organization_id
      AND g.org_assurance_gap_id = @gap_id
      AND g.is_active = 1;
END
GO

-- =====================================================================
-- REWRITE: sp_org_assurance_gap_delete
--   Cascades junction row deactivation so no orphaned active links.
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

    DECLARE @gap_org BIGINT, @status_code NVARCHAR(60);
    SELECT @gap_org = g.organization_id, @status_code = st.status_code
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

    -- Detach all active junctions.
    UPDATE grac_practice.org_assurance_gap_observation
    SET is_active     = 0,
        detach_by     = @actor,
        detach_dt     = SYSUTCDATETIME(),
        detach_reason = N'Gap soft-deleted.'
    WHERE org_assurance_gap_id = @gap_id
      AND is_active = 1;

    -- Retarget any observation.gap_id pointers previously pointing here.
    UPDATE grac_practice.org_assurance_observation
    SET gap_id     = NULL,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE gap_id = @gap_id
      AND organization_id = @organization_id;

    -- Soft-delete gap actions.
    UPDATE grac_practice.org_assurance_gap_action
    SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_gap_id = @gap_id AND is_active = 1;

    -- Soft-delete the gap.
    UPDATE grac_practice.org_assurance_gap
    SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_gap_id = @gap_id;

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
-- REWRITE: sp_org_assurance_observation_delete
--   Cascades junction deactivate for this observation.
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

    -- Detach junction rows for this observation.
    UPDATE grac_practice.org_assurance_gap_observation
    SET is_active     = 0,
        detach_by     = @actor,
        detach_dt     = SYSUTCDATETIME(),
        detach_reason = N'Observation soft-deleted.'
    WHERE org_assurance_observation_id = @observation_id
      AND is_active = 1;

    UPDATE grac_practice.org_assurance_observation_evidence
    SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_observation_id = @observation_id AND is_active = 1;

    UPDATE grac_practice.org_assurance_observation
    SET is_active = 0, gap_id = NULL,
        updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_observation_id = @observation_id;

    INSERT INTO grac_practice.org_assurance_observation_history(
        org_assurance_observation_id, organization_id,
        action_code, reason_text, actor_display_name, entered_by)
    VALUES(
        @observation_id, @organization_id,
        N'DELETE', N'Soft-deleted (junction detached).', @actor, @actor);

    COMMIT;
END
GO

PRINT '108 Organization Assurance Gap Center junction procedures deployed.';
GO
