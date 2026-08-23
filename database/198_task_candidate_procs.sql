-- =====================================================================
-- 198 Task Candidate — lifecycle procedures  (BRD §4, §5, §6, §8, §18)
--
-- CONTENTS
--   1. sp_task_candidate_apply_sla     — proposed priority -> proposed SLA
--   2. sp_task_candidate_create        — raise one (idempotent)
--   3. sp_task_candidate_list          — the Candidates tab
--   4. sp_task_candidate_get           — detail + history
--   5. sp_task_candidate_validate_save — confirm owner + priority
--   6. sp_task_candidate_approve       — convert to an Approved Task
--   7. sp_task_candidate_discard       — will not be executed
--   8. sp_task_candidate_counts        — tab badges
--
-- THE ONE JOB OF THIS STAGE  (BRD §5)
-- -----------------------------------
-- "Task Candidates ... must pass lightweight execution validation before
--  becoming Approved Tasks. The candidate stage must not duplicate
--  analysis, risk assessment, gap assessment or exception decision-making
--  already performed in upstream centres."
--
-- So there are exactly three questions here — who, how urgent, by when —
-- and the third is derived from the second. Nothing in this file touches
-- severity, impact or root cause; those belong to the source.
--
-- RESULT-SET DISCIPLINE
-- ---------------------
-- Procs called by OTHER procs (sp_task_candidate_create,
-- sp_task_candidate_apply_sla) return through OUTPUT parameters and emit
-- NO result set. Procs called only by the API tier return a summary row.
-- Mixing the two is what breaks ADO.NET callers: a nested proc's SELECT
-- arrives first and the caller silently binds the wrong result set.
-- (Same reason sp_task_activity_add was made OUTPUT-only in 193.)
--
-- Rollback: database/198_task_candidate_procs_rollback.sql
-- ERROR CODE RANGE: 55800-55849
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.task_candidate','U') IS NULL
BEGIN PRINT 'ABORT (198): task_candidate missing — run 197_task_candidate_schema.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_owner_resolve','P') IS NULL
BEGIN PRINT 'ABORT (198): sp_task_owner_resolve missing — run 193 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_open','P') IS NULL
BEGIN PRINT 'ABORT (198): sp_task_open missing — run 037/048/196 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('198_task_candidate_procs: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_task_candidate_apply_sla  (BRD §8)
--
-- The candidate mirror of sp_task_apply_sla (193): the proposed SLA is
-- SYSTEM-DERIVED from the proposed priority and is never typed in. It is
-- a *proposal* — the authoritative SLA is derived again at approval time
-- by sp_task_open, because the org policy may have changed in between.
--
-- Calls sp_org_sla_match_for_severity directly rather than the
-- sp_org_sla_match_for_priority seam, for the same reason 193 does:
-- T-SQL forbids nesting INSERT ... EXEC (error 8164).
--
-- OUTPUT-only. No result set.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_candidate_apply_sla
    @task_candidate_id   BIGINT,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_candidate_id IS NULL
        THROW 55800, 'sp_task_candidate_apply_sla: task_candidate_id is required.', 1;

    DECLARE @organization_id BIGINT,
            @priority        NVARCHAR(30),
            @task_type_code  NVARCHAR(60),
            @baseline        DATETIME2,
            @status          NVARCHAR(30);

    SELECT @organization_id = organization_id,
           @priority        = proposed_priority,
           @task_type_code  = task_type_code,
           @baseline        = entered_dt,
           @status          = status_code
      FROM grac_practice.task_candidate
     WHERE task_candidate_id = @task_candidate_id;

    IF @organization_id IS NULL
        THROW 55801, 'sp_task_candidate_apply_sla: candidate not found.', 1;

    -- A converted or abandoned candidate is a historical record; its
    -- proposal must not drift after the fact.
    IF @status IN (N'Approved', N'Discarded') RETURN;

    DECLARE @match TABLE (
        OrgSlaConfigId BIGINT,  SlaMasterId  BIGINT,
        SlaMasterCode  NVARCHAR(120), SlaMasterName NVARCHAR(200),
        TotalSlaDays   INT,
        WarningPct     DECIMAL(5,2), EscalationPct DECIMAL(5,2),
        TimeBasis      NVARCHAR(60));

    IF OBJECT_ID('grac_practice.sp_org_sla_match_for_severity','P') IS NOT NULL
       AND @priority IS NOT NULL
    BEGIN
        INSERT @match
        EXEC grac_practice.sp_org_sla_match_for_severity
             @organization_id = @organization_id,
             @severity_code   = @priority;
    END

    DECLARE @sla_master_id   BIGINT        = NULL,
            @sla_master_name NVARCHAR(200) = NULL,
            @days            INT           = NULL,
            @source          NVARCHAR(30);

    SELECT TOP 1
           @sla_master_id   = SlaMasterId,
           @sla_master_name = SlaMasterName,
           @days            = TotalSlaDays
      FROM @match;

    IF @days IS NOT NULL AND @days >= 0
        SET @source = N'AUTO';
    ELSE
    BEGIN
        DECLARE @default_hours INT;
        SELECT @default_hours = default_sla_hours
          FROM grac_practice.task_type_master
         WHERE type_code = @task_type_code;

        SET @days   = CAST(CEILING(ISNULL(@default_hours, 72) / 24.0) AS INT);
        SET @source = N'TYPE_DEFAULT';
        SET @sla_master_id   = NULL;
        SET @sla_master_name = NULL;
    END

    UPDATE grac_practice.task_candidate
       SET proposed_sla_days = @days,
           proposed_due_at   = DATEADD(DAY, @days, @baseline),
           sla_master_id     = @sla_master_id,
           sla_master_name   = @sla_master_name,
           sla_source_code   = @source,
           updated_by        = @caller_display_name,
           updated_dt        = SYSUTCDATETIME()
     WHERE task_candidate_id = @task_candidate_id;
END;
GO

-- =====================================================================
-- 2. sp_task_candidate_create  (BRD §4A, §6)
--
-- Called by the source integrations in 199 and by the API for a manual
-- "add another action for this gap".
--
-- IDEMPOTENCY: when @source_dedupe_key is supplied and an OPEN candidate
-- already exists for (source_type, source_record, key), the existing id
-- is returned with @created = 0. Passing NULL disables the check, which
-- is how BRD §15's one-source-many-tasks stays possible.
--
-- OUTPUT-only. No result set — 199's callers emit their own.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_candidate_create
    @organization_id            BIGINT,
    @source_type_code           NVARCHAR(40),
    @source_record_id           BIGINT,
    @candidate_title            NVARCHAR(250),
    @candidate_description      NVARCHAR(MAX) = NULL,
    @source_reference           NVARCHAR(200) = NULL,
    @source_dedupe_key          NVARCHAR(200) = NULL,
    @task_type_code             NVARCHAR(60)  = N'Rectification',
    @linked_release_id          BIGINT = NULL,
    @linked_control_id          BIGINT = NULL,
    @linked_practice_id         BIGINT = NULL,
    @linked_instance_id         BIGINT = NULL,
    @explicit_owner_employee_id BIGINT = NULL,
    @proposed_priority          NVARCHAR(30) = NULL,
    @actor_employee_id          BIGINT = NULL,
    @caller_display_name        NVARCHAR(100) = N'system',
    @task_candidate_id          BIGINT OUTPUT,
    @created                    BIT    = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @created = 0;
    SET @task_candidate_id = NULL;

    IF @organization_id IS NULL
        THROW 55805, 'sp_task_candidate_create: organization_id is required.', 1;
    IF @source_type_code IS NULL OR @source_record_id IS NULL
        THROW 55806, 'sp_task_candidate_create: source_type_code and source_record_id are required.', 1;
    IF @candidate_title IS NULL OR LEN(LTRIM(RTRIM(@candidate_title))) = 0
        THROW 55807, 'sp_task_candidate_create: candidate_title is required.', 1;

    -- ---- Idempotency -------------------------------------------------
    IF @source_dedupe_key IS NOT NULL
    BEGIN
        SELECT TOP 1 @task_candidate_id = task_candidate_id
          FROM grac_practice.task_candidate
         WHERE source_type_code  = @source_type_code
           AND source_record_id  = @source_record_id
           AND source_dedupe_key = @source_dedupe_key
           AND status_code IN (N'New', N'Validated')
         ORDER BY task_candidate_id DESC;

        IF @task_candidate_id IS NOT NULL RETURN;   -- @created stays 0
    END

    -- ---- Priority: caller's, else the task type's default ------------
    DECLARE @priority NVARCHAR(30) = @proposed_priority;
    IF @priority IS NULL
        SELECT @priority = default_priority
          FROM grac_practice.task_type_master
         WHERE type_code = @task_type_code;
    IF @priority IS NULL OR @priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @priority = N'Medium';

    -- ---- Owner ladder (BRD §6) ---------------------------------------
    -- The candidate stage PROPOSES an owner; validation confirms it.
    -- Resolution failure is never fatal: an unowned candidate is exactly
    -- what the Candidates tab exists to surface.
    DECLARE @owner_id BIGINT = NULL, @owner_source NVARCHAR(40) = N'MANUAL';

    BEGIN TRY
        DECLARE @resolved TABLE (
            OwnerEmployeeId BIGINT, OwnerEmployeeName NVARCHAR(200),
            OwnerSourceCode NVARCHAR(40), OwnerSourceName NVARCHAR(120));

        INSERT @resolved
        EXEC grac_practice.sp_task_owner_resolve
             @organization_id            = @organization_id,
             @source_type_code           = @source_type_code,
             @source_record_id           = @source_record_id,
             @linked_practice_id         = @linked_practice_id,
             @linked_control_id          = @linked_control_id,
             @linked_instance_id         = @linked_instance_id,
             @explicit_owner_employee_id = @explicit_owner_employee_id;

        SELECT TOP 1 @owner_id = OwnerEmployeeId, @owner_source = OwnerSourceCode FROM @resolved;
    END TRY
    BEGIN CATCH
        DECLARE @owner_warn NVARCHAR(4000) = ERROR_MESSAGE();
        PRINT CONCAT(N'sp_task_candidate_create: owner resolution warning: ', @owner_warn);
        SET @owner_id     = @explicit_owner_employee_id;
        SET @owner_source = CASE WHEN @explicit_owner_employee_id IS NOT NULL
                                 THEN N'EXPLICIT_SOURCE' ELSE N'MANUAL' END;
    END CATCH

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
          FROM grac_practice.record_status_master
         WHERE status_code = 'ACTIVE' OR status_name = 'Active'
         ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    INSERT INTO grac_practice.task_candidate
        (organization_id, source_type_code, source_record_id, source_reference,
         source_dedupe_key, candidate_title, candidate_description, task_type_code,
         linked_release_id, linked_control_id, linked_practice_id, linked_instance_id,
         proposed_owner_employee_id, owner_source_code, proposed_priority,
         status_code, record_status_id, entered_by, entered_dt)
    VALUES
        (@organization_id, @source_type_code, @source_record_id, @source_reference,
         @source_dedupe_key, @candidate_title, @candidate_description, @task_type_code,
         @linked_release_id, @linked_control_id, @linked_practice_id, @linked_instance_id,
         @owner_id, ISNULL(@owner_source, N'MANUAL'), @priority,
         N'New', @active_record_status_id, @caller_display_name, SYSUTCDATETIME());

    SET @task_candidate_id = SCOPE_IDENTITY();
    SET @created = 1;

    INSERT INTO grac_practice.task_candidate_history
        (task_candidate_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@task_candidate_id, N'Create', NULL, N'New',
         CONCAT(N'Raised from ', @source_type_code, N' #', CAST(@source_record_id AS NVARCHAR(20)),
                N'. Proposed owner: ', ISNULL(CAST(@owner_id AS NVARCHAR(20)), N'unresolved'),
                N' (', ISNULL(@owner_source, N'MANUAL'), N'). Proposed priority: ', @priority, N'.'),
         @actor_employee_id, @caller_display_name, @caller_display_name, SYSUTCDATETIME());

    COMMIT;

    -- Outside the transaction: a missing SLA policy must not roll back a
    -- successfully raised candidate. Idempotent, so it can be re-run.
    BEGIN TRY
        EXEC grac_practice.sp_task_candidate_apply_sla
             @task_candidate_id   = @task_candidate_id,
             @caller_display_name = @caller_display_name;
    END TRY
    BEGIN CATCH
        DECLARE @sla_warn NVARCHAR(4000) = ERROR_MESSAGE();
        PRINT CONCAT(N'sp_task_candidate_create: SLA proposal warning: ', @sla_warn);
    END CATCH
END;
GO

-- =====================================================================
-- 3. sp_task_candidate_list  (the Candidates tab)
--     Two result sets, same shape as sp_task_list: count header, then
--     the page.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_candidate_list
    @organization_id  BIGINT        = NULL,
    @status_code      NVARCHAR(30)  = NULL,   -- 'OpenSet' = New + Validated
    @source_type_code NVARCHAR(40)  = NULL,
    @source_record_id BIGINT        = NULL,
    @owner_employee_id BIGINT       = NULL,
    @priority         NVARCHAR(30)  = NULL,
    @search           NVARCHAR(200) = NULL,
    @page             INT = 1,
    @page_size        INT = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    DECLARE @filtered TABLE (task_candidate_id BIGINT PRIMARY KEY, sort_dt DATETIME2);

    INSERT INTO @filtered (task_candidate_id, sort_dt)
    SELECT c.task_candidate_id, c.entered_dt
      FROM grac_practice.task_candidate c
     WHERE (@organization_id IS NULL   OR c.organization_id = @organization_id)
       AND (
             @status_code IS NULL
          OR (@status_code = N'OpenSet' AND c.status_code IN (N'New', N'Validated'))
          OR c.status_code = @status_code
           )
       AND (@source_type_code IS NULL  OR c.source_type_code = @source_type_code)
       AND (@source_record_id IS NULL  OR c.source_record_id = @source_record_id)
       AND (@owner_employee_id IS NULL OR c.proposed_owner_employee_id = @owner_employee_id)
       AND (@priority IS NULL          OR c.proposed_priority = @priority)
       AND (@search IS NULL
            OR c.candidate_title LIKE N'%' + @search + N'%'
            OR c.candidate_description LIKE N'%' + @search + N'%'
            OR c.candidate_number LIKE N'%' + @search + N'%'
            OR c.source_reference LIKE N'%' + @search + N'%');

    SELECT COUNT_BIG(*) AS TotalCount,
           @page        AS PageNumber,
           @page_size   AS PageSize
      FROM @filtered;

    SELECT c.task_candidate_id          AS TaskCandidateId,
           c.candidate_number           AS CandidateNumber,
           c.organization_id            AS OrganizationId,
           c.source_type_code           AS SourceTypeCode,
           c.source_record_id           AS SourceRecordId,
           c.source_reference           AS SourceReference,
           c.candidate_title            AS CandidateTitle,
           c.candidate_description      AS CandidateDescription,
           c.task_type_code             AS TaskTypeCode,
           c.proposed_owner_employee_id AS ProposedOwnerEmployeeId,
           e.employee_name              AS ProposedOwnerName,
           c.owner_source_code          AS OwnerSourceCode,
           c.proposed_priority          AS ProposedPriority,
           c.proposed_sla_days          AS ProposedSlaDays,
           c.proposed_due_at            AS ProposedDueAt,
           c.sla_master_name            AS SlaMasterName,
           c.sla_source_code            AS SlaSourceCode,
           c.status_code                AS StatusCode,
           c.approved_task_id           AS ApprovedTaskId,
           t.task_number                AS ApprovedTaskNumber,
           -- Drives the Approve button: BRD §5 requires a confirmed
           -- owner before a candidate may become an accountable task.
           CASE WHEN c.status_code IN (N'New', N'Validated')
                 AND c.proposed_owner_employee_id IS NOT NULL
                THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsReadyToApprove,
           c.entered_dt                 AS EnteredDt,
           c.entered_by                 AS EnteredBy
      FROM @filtered f
      JOIN grac_practice.task_candidate c ON c.task_candidate_id = f.task_candidate_id
 LEFT JOIN grac_practice.organization_employee e ON e.employee_id = c.proposed_owner_employee_id
 LEFT JOIN grac_practice.practice_task         t ON t.task_id     = c.approved_task_id
     ORDER BY f.sort_dt DESC, f.task_candidate_id DESC
     OFFSET (@page - 1) * @page_size ROWS
     FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- =====================================================================
-- 4. sp_task_candidate_get  — header + history
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_candidate_get
    @task_candidate_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_candidate_id IS NULL
        THROW 55810, 'sp_task_candidate_get: task_candidate_id is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.task_candidate WHERE task_candidate_id = @task_candidate_id)
        THROW 55811, 'sp_task_candidate_get: candidate not found.', 1;

    SELECT c.task_candidate_id          AS TaskCandidateId,
           c.candidate_number           AS CandidateNumber,
           c.organization_id            AS OrganizationId,
           c.source_type_code           AS SourceTypeCode,
           c.source_record_id           AS SourceRecordId,
           c.source_reference           AS SourceReference,
           c.source_dedupe_key          AS SourceDedupeKey,
           c.candidate_title            AS CandidateTitle,
           c.candidate_description      AS CandidateDescription,
           c.task_type_code             AS TaskTypeCode,
           c.linked_release_id          AS LinkedReleaseId,
           c.linked_control_id          AS LinkedControlId,
           c.linked_practice_id         AS LinkedPracticeId,
           c.linked_instance_id         AS LinkedInstanceId,
           c.proposed_owner_employee_id AS ProposedOwnerEmployeeId,
           e.employee_name              AS ProposedOwnerName,
           c.owner_source_code          AS OwnerSourceCode,
           c.proposed_priority          AS ProposedPriority,
           c.proposed_sla_days          AS ProposedSlaDays,
           c.proposed_due_at            AS ProposedDueAt,
           c.sla_master_id              AS SlaMasterId,
           c.sla_master_name            AS SlaMasterName,
           c.sla_source_code            AS SlaSourceCode,
           c.status_code                AS StatusCode,
           c.approved_task_id           AS ApprovedTaskId,
           t.task_number                AS ApprovedTaskNumber,
           c.validated_dt               AS ValidatedDt,
           v.employee_name              AS ValidatedByName,
           c.approved_dt                AS ApprovedDt,
           a.employee_name              AS ApprovedByName,
           c.discarded_dt               AS DiscardedDt,
           d.employee_name              AS DiscardedByName,
           c.discard_reason             AS DiscardReason,
           CASE WHEN c.status_code IN (N'New', N'Validated')
                 AND c.proposed_owner_employee_id IS NOT NULL
                THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsReadyToApprove,
           c.entered_by                 AS EnteredBy,
           c.entered_dt                 AS EnteredDt
      FROM grac_practice.task_candidate c
 LEFT JOIN grac_practice.organization_employee e ON e.employee_id = c.proposed_owner_employee_id
 LEFT JOIN grac_practice.organization_employee v ON v.employee_id = c.validated_by_employee_id
 LEFT JOIN grac_practice.organization_employee a ON a.employee_id = c.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee d ON d.employee_id = c.discarded_by_employee_id
 LEFT JOIN grac_practice.practice_task         t ON t.task_id     = c.approved_task_id
     WHERE c.task_candidate_id = @task_candidate_id;

    SELECT h.task_candidate_history_id AS TaskCandidateHistoryId,
           h.action_code               AS ActionCode,
           h.from_status_code          AS FromStatusCode,
           h.to_status_code            AS ToStatusCode,
           h.remark                    AS Remark,
           h.actor_employee_id         AS ActorEmployeeId,
           h.actor_display_name        AS ActorDisplayName,
           h.entered_dt                AS EnteredDt
      FROM grac_practice.task_candidate_history h
     WHERE h.task_candidate_id = @task_candidate_id
     ORDER BY h.entered_dt DESC, h.task_candidate_history_id DESC;
END;
GO

-- =====================================================================
-- 5. sp_task_candidate_validate_save  (BRD §5)
--
-- "Resolve/propose owner. Resolve/propose priority. Automatically derive
--  standard SLA from priority."
--
-- Priority here is NOT governed the way it is on an Approved Task. BRD §7
-- governs changes to a COMMITMENT, and a candidate has not made one yet —
-- it has a proposal. So a validator may freely set it up or down, and the
-- asymmetric approval rules start the moment the task is approved.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_candidate_validate_save
    @task_candidate_id          BIGINT,
    @proposed_owner_employee_id BIGINT        = NULL,
    @proposed_priority          NVARCHAR(30)  = NULL,
    @remark                     NVARCHAR(MAX) = NULL,
    @actor_employee_id          BIGINT        = NULL,
    @caller_display_name        NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_candidate_id IS NULL
        THROW 55815, 'sp_task_candidate_validate_save: task_candidate_id is required.', 1;
    IF @proposed_priority IS NOT NULL
       AND @proposed_priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        THROW 55816, 'sp_task_candidate_validate_save: proposed_priority must be Low, Medium, High or Critical.', 1;

    DECLARE @organization_id BIGINT, @status NVARCHAR(30),
            @old_owner BIGINT, @old_priority NVARCHAR(30);

    SELECT @organization_id = organization_id,
           @status          = status_code,
           @old_owner       = proposed_owner_employee_id,
           @old_priority    = proposed_priority
      FROM grac_practice.task_candidate
     WHERE task_candidate_id = @task_candidate_id;

    IF @organization_id IS NULL
        THROW 55817, 'sp_task_candidate_validate_save: candidate not found.', 1;
    IF @status NOT IN (N'New', N'Validated')
        THROW 55818, 'sp_task_candidate_validate_save: only New or Validated candidates can be edited.', 1;

    -- Cross-tenant guard, same rule as the owner ladder: an owner must be
    -- an active employee of the candidate's own organisation.
    IF @proposed_owner_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                        WHERE e.employee_id     = @proposed_owner_employee_id
                          AND e.organization_id = @organization_id
                          AND ISNULL(e.status, N'Active') = N'Active')
        THROW 55819, 'sp_task_candidate_validate_save: the owner must be an active employee of this organisation.', 1;

    DECLARE @new_owner    BIGINT       = COALESCE(@proposed_owner_employee_id, @old_owner);
    DECLARE @new_priority NVARCHAR(30) = COALESCE(@proposed_priority, @old_priority);

    BEGIN TRAN;

    UPDATE grac_practice.task_candidate
       SET proposed_owner_employee_id = @new_owner,
           -- An explicit pick supersedes whatever the ladder proposed.
           owner_source_code = CASE
                                   WHEN @proposed_owner_employee_id IS NOT NULL
                                    AND (@old_owner IS NULL OR @old_owner <> @proposed_owner_employee_id)
                                   THEN N'MANUAL'
                                   ELSE owner_source_code
                               END,
           proposed_priority          = @new_priority,
           status_code                = N'Validated',
           validated_by_employee_id   = @actor_employee_id,
           validated_dt               = SYSUTCDATETIME(),
           updated_by                 = @caller_display_name,
           updated_dt                 = SYSUTCDATETIME()
     WHERE task_candidate_id = @task_candidate_id;

    INSERT INTO grac_practice.task_candidate_history
        (task_candidate_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@task_candidate_id, N'Validate', @status, N'Validated',
         CONCAT(N'Owner: ', ISNULL(CAST(@old_owner AS NVARCHAR(20)), N'unresolved'),
                N' -> ', ISNULL(CAST(@new_owner AS NVARCHAR(20)), N'unresolved'),
                N'. Priority: ', @old_priority, N' -> ', @new_priority, N'.',
                CASE WHEN @remark IS NULL THEN N'' ELSE CONCAT(N' ', @remark) END),
         @actor_employee_id, @caller_display_name, @caller_display_name, SYSUTCDATETIME());

    COMMIT;

    -- Priority may have moved, so the derived SLA has to follow it.
    IF @new_priority <> @old_priority
        EXEC grac_practice.sp_task_candidate_apply_sla
             @task_candidate_id   = @task_candidate_id,
             @caller_display_name = @caller_display_name;

    SELECT @task_candidate_id AS TaskCandidateId,
           N'Validated'       AS StatusCode,
           @new_owner         AS ProposedOwnerEmployeeId,
           @new_priority      AS ProposedPriority;
END;
GO

-- =====================================================================
-- 6. sp_task_candidate_approve  (BRD §4A, §5)
--
-- "Convert to Approved Task once required validation is complete."
--
-- The gate is a confirmed OWNER. Priority always has a value (defaulted
-- at creation) and the SLA is derived, so the owner is the only thing a
-- human must actually settle — which is exactly BRD §2's definition of an
-- Approved Task: "a confirmed owner, priority and SLA".
--
-- The task is opened through sp_task_open so the state machine, audit
-- trail, source stamping and SLA derivation all behave identically to
-- every other task. The SLA is derived AGAIN here rather than copied from
-- the proposal, because the org policy may have changed since the
-- candidate was raised — the commitment must reflect policy at the moment
-- it is made.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_candidate_approve
    @task_candidate_id       BIGINT,
    @approved_by_employee_id BIGINT        = NULL,
    @remark                  NVARCHAR(MAX) = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_candidate_id IS NULL
        THROW 55820, 'sp_task_candidate_approve: task_candidate_id is required.', 1;

    DECLARE @organization_id   BIGINT, @status NVARCHAR(30),
            @source_type       NVARCHAR(40),  @source_record_id BIGINT,
            @source_reference  NVARCHAR(200),
            @title             NVARCHAR(250), @description NVARCHAR(MAX),
            @task_type_code    NVARCHAR(60),
            @owner_id          BIGINT,        @owner_source NVARCHAR(40),
            @priority          NVARCHAR(30),
            @linked_release_id BIGINT, @linked_control_id BIGINT,
            @linked_practice_id BIGINT, @linked_instance_id BIGINT;

    SELECT @organization_id    = organization_id,
           @status             = status_code,
           @source_type        = source_type_code,
           @source_record_id   = source_record_id,
           @source_reference   = source_reference,
           @title              = candidate_title,
           @description        = candidate_description,
           @task_type_code     = task_type_code,
           @owner_id           = proposed_owner_employee_id,
           @owner_source       = owner_source_code,
           @priority           = proposed_priority,
           @linked_release_id  = linked_release_id,
           @linked_control_id  = linked_control_id,
           @linked_practice_id = linked_practice_id,
           @linked_instance_id = linked_instance_id
      FROM grac_practice.task_candidate
     WHERE task_candidate_id = @task_candidate_id;

    IF @organization_id IS NULL
        THROW 55821, 'sp_task_candidate_approve: candidate not found.', 1;
    IF @status = N'Approved'
        THROW 55822, 'sp_task_candidate_approve: this candidate has already been approved.', 1;
    IF @status = N'Discarded'
        THROW 55823, 'sp_task_candidate_approve: a discarded candidate cannot be approved.', 1;
    IF @owner_id IS NULL
        THROW 55824, 'sp_task_candidate_approve: a confirmed owner is required. An Approved Task must be accountable to someone — validate the candidate first.', 1;

    -- The state-machine subject vocabulary each source already uses. Gap
    -- keeps 'CustomGap' so tasks raised before Phase 2 and after it are
    -- indistinguishable to every existing query.
    DECLARE @subject_entity_type NVARCHAR(60) =
        CASE @source_type
             WHEN N'Gap'                 THEN N'CustomGap'
             WHEN N'Risk'                THEN N'RiskCandidate'
             WHEN N'ContinuousAssurance' THEN N'AssuranceObservation'
             WHEN N'Exception'           THEN N'ExceptionRequest'
             WHEN N'EventAssurance'      THEN N'EventInstance'
             ELSE N'Custom'
        END;

    DECLARE @task_id BIGINT;

    BEGIN TRAN;

    EXEC grac_practice.sp_task_open
         @organization_id         = @organization_id,
         @task_type_code          = @task_type_code,
         @subject_entity_type     = @subject_entity_type,
         @subject_entity_id       = @source_record_id,
         @subject_title           = @title,
         @subject_description     = @description,
         @linked_release_id       = @linked_release_id,
         @linked_control_id       = @linked_control_id,
         @linked_practice_id      = @linked_practice_id,
         @linked_instance_id      = @linked_instance_id,
         @priority                = @priority,
         @origin_code             = N'GRAC',
         @assigned_to_employee_id = @owner_id,
         @actor_employee_id       = @approved_by_employee_id,
         @source_type_code        = @source_type,
         @source_record_id        = @source_record_id,
         @source_reference        = @source_reference,
         @resolve_owner           = 0,
         @task_id                 = @task_id OUTPUT;

    IF @task_id IS NULL
        THROW 55825, 'sp_task_candidate_approve: task creation failed.', 1;

    -- Preserve WHICH rung produced the owner. sp_task_open stamps
    -- EXPLICIT_SOURCE because we handed it an owner; the candidate knows
    -- the real provenance and it is worth keeping for audit.
    UPDATE grac_practice.practice_task
       SET task_candidate_id = @task_candidate_id,
           owner_source_code = ISNULL(@owner_source, owner_source_code),
           updated_by        = @caller_display_name,
           updated_dt        = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    UPDATE grac_practice.task_candidate
       SET status_code             = N'Approved',
           approved_task_id        = @task_id,
           approved_by_employee_id = @approved_by_employee_id,
           approved_dt             = SYSUTCDATETIME(),
           updated_by              = @caller_display_name,
           updated_dt              = SYSUTCDATETIME()
     WHERE task_candidate_id = @task_candidate_id;

    INSERT INTO grac_practice.task_candidate_history
        (task_candidate_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@task_candidate_id, N'Approve', @status, N'Approved',
         CONCAT(N'Converted to task #', CAST(@task_id AS NVARCHAR(20)),
                N'. Owner ', CAST(@owner_id AS NVARCHAR(20)), N', priority ', @priority, N'.',
                CASE WHEN @remark IS NULL THEN N'' ELSE CONCAT(N' ', @remark) END),
         @approved_by_employee_id, @caller_display_name, @caller_display_name, SYSUTCDATETIME());

    COMMIT;

    -- The task's own operational feed should show where it came from.
    BEGIN TRY
        DECLARE @origin_note NVARCHAR(400) =
            CONCAT(N'Approved from candidate ',
                   (SELECT candidate_number FROM grac_practice.task_candidate
                     WHERE task_candidate_id = @task_candidate_id),
                   N' (', @source_type, N' #', CAST(@source_record_id AS NVARCHAR(20)), N').');

        EXEC grac_practice.sp_task_activity_add
             @task_id             = @task_id,
             @activity_type_code  = N'CandidateApproved',
             @remark              = @origin_note,
             @actor_employee_id   = @approved_by_employee_id,
             @caller_display_name = @caller_display_name;
    END TRY
    BEGIN CATCH
        DECLARE @act_warn NVARCHAR(4000) = ERROR_MESSAGE();
        PRINT CONCAT(N'sp_task_candidate_approve: activity log warning: ', @act_warn);
    END CATCH

    SELECT @task_candidate_id AS TaskCandidateId,
           N'Approved'        AS StatusCode,
           @task_id           AS ApprovedTaskId;
END;
GO

-- =====================================================================
-- 7. sp_task_candidate_discard
--
-- The action will not be executed as a task. This does NOT touch the
-- source: BRD §14's principle — Task Centre never decides whether the
-- underlying gap / risk / observation is resolved — applies just as much
-- to refusing work as to completing it.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_candidate_discard
    @task_candidate_id        BIGINT,
    @discard_reason           NVARCHAR(MAX),
    @discarded_by_employee_id BIGINT        = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_candidate_id IS NULL
        THROW 55830, 'sp_task_candidate_discard: task_candidate_id is required.', 1;
    IF @discard_reason IS NULL OR LEN(LTRIM(RTRIM(@discard_reason))) = 0
        THROW 55831, 'sp_task_candidate_discard: discard_reason is required.', 1;

    DECLARE @status NVARCHAR(30);
    SELECT @status = status_code
      FROM grac_practice.task_candidate WHERE task_candidate_id = @task_candidate_id;

    IF @status IS NULL
        THROW 55832, 'sp_task_candidate_discard: candidate not found.', 1;
    IF @status = N'Approved'
        THROW 55833, 'sp_task_candidate_discard: this candidate already became a task. Complete or cancel the task instead.', 1;
    IF @status = N'Discarded'
        THROW 55834, 'sp_task_candidate_discard: the candidate is already discarded.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.task_candidate
       SET status_code              = N'Discarded',
           discard_reason           = @discard_reason,
           discarded_by_employee_id = @discarded_by_employee_id,
           discarded_dt             = SYSUTCDATETIME(),
           updated_by               = @caller_display_name,
           updated_dt               = SYSUTCDATETIME()
     WHERE task_candidate_id = @task_candidate_id;

    INSERT INTO grac_practice.task_candidate_history
        (task_candidate_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@task_candidate_id, N'Discard', @status, N'Discarded',
         @discard_reason, @discarded_by_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());

    COMMIT;

    SELECT @task_candidate_id AS TaskCandidateId, N'Discarded' AS StatusCode;
END;
GO

-- =====================================================================
-- 8. sp_task_candidate_counts  — Candidates tab badges
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_candidate_counts
    @organization_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        SUM(CASE WHEN status_code = N'New'       THEN 1 ELSE 0 END) AS NewCount,
        SUM(CASE WHEN status_code = N'Validated' THEN 1 ELSE 0 END) AS ValidatedCount,
        SUM(CASE WHEN status_code IN (N'New', N'Validated') THEN 1 ELSE 0 END) AS OpenCount,
        SUM(CASE WHEN status_code = N'Approved'  THEN 1 ELSE 0 END) AS ApprovedCount,
        SUM(CASE WHEN status_code = N'Discarded' THEN 1 ELSE 0 END) AS DiscardedCount,
        -- Waiting on a human to name an owner (BRD §6 rung 7).
        SUM(CASE WHEN status_code IN (N'New', N'Validated')
                  AND proposed_owner_employee_id IS NULL THEN 1 ELSE 0 END) AS UnownedCount
      FROM grac_practice.task_candidate
     WHERE (@organization_id IS NULL OR organization_id = @organization_id);
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '198 procedures present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_task_candidate_apply_sla','P')     IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_candidate_create','P')         IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_candidate_list','P')           IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_candidate_get','P')            IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_candidate_validate_save','P')  IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_candidate_approve','P')        IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_candidate_discard','P')        IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_candidate_counts','P')         IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'sp_task_candidate_create is OUTPUT-only' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_task_candidate_create')
                            AND name = '@task_candidate_id' AND is_output = 1)
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_task_candidate_create')
                            AND name = '@created' AND is_output = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '198 Task Candidate lifecycle procedures installed. Next: 199_task_candidate_sources.sql';
GO

SET NOEXEC OFF;
GO
