-- =====================================================================
-- 193 Task Centre v2 — owner resolution, SLA derivation, priority
--     governance, activity + evidence  (BRD §6, §7, §8, §16)
--
-- CONTENTS
--   1. fn_task_employee_by_name            — name -> employee_id helper
--   2. sp_task_owner_resolve               — the 7-rung owner ladder (§6)
--   3. sp_org_sla_match_for_priority       — priority -> org SLA policy (§8)
--   4. sp_task_apply_sla                   — derive standard SLA, keep the
--                                            effective due date coherent,
--                                            cascade to children (§8, §11)
--   5. sp_task_activity_add                — operational trail (§16)
--   6. sp_task_attachment_add / _get       — evidence (§16)
--   7. sp_task_priority_change             — increase free / reduce via
--                                            Exception Centre (§7)
--   8. sp_task_priority_reduction_approve  — apply an approved reduction
--   9. sp_exception_request_reject         — REWRITE, task-aware
--  10. sp_exception_request_list           — REWRITE, task-aware
--
-- GOVERNANCE PRINCIPLE ENCODED HERE (BRD §21)
--   "GRAC should never obstruct faster execution." Owner changes and
--   priority INCREASES are unapproved operational freedoms. Any REDUCTION
--   in urgency, or an extension beyond the standard SLA, routes through
--   Exception Centre. That asymmetry is why sp_task_priority_change has
--   two completely different code paths for what looks like one action.
--
-- The gap-side procs from 184/188/189/190 are NOT touched, except that
-- sp_exception_request_reject and sp_exception_request_list are rewritten
-- as supersets — every existing column, parameter and side effect
-- (including GAP_CANDIDATE risk auto-creation) is preserved verbatim.
--
-- Rollback: database/193_task_centre_v2_procs_rollback.sql
-- ERROR CODE RANGE: 55600-55649
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
BEGIN PRINT 'ABORT (193): practice_task missing.'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.practice_task','standard_due_at') IS NULL
BEGIN PRINT 'ABORT (193): run 192_task_centre_v2_schema.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.task_activity','U') IS NULL
BEGIN PRINT 'ABORT (193): task_activity missing — run 192 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN PRINT 'ABORT (193): exception_request missing — run 161 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('193_task_centre_v2_procs: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. fn_task_employee_by_name
--
-- Most ownership in GRAC predates organization_employee and is stored as
-- a display NAME (practice.practice_owner, organization_control
-- .primary_owner, practice_instance.primary_owner, business function
-- .owner_name). 009_practice_employee_master.sql seeded the employee
-- master FROM those very names, so a case-insensitive, trimmed name match
-- inside the same organisation is the correct bridge — and BRD §6 demands
-- we reuse existing ownership data rather than duplicate it.
--
-- Returns NULL when there is no unambiguous active match; the caller
-- simply falls to the next rung.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_task_employee_by_name
(
    @organization_id BIGINT,
    @employee_name   NVARCHAR(200)
)
RETURNS BIGINT
AS
BEGIN
    IF @organization_id IS NULL
       OR @employee_name IS NULL
       OR LEN(LTRIM(RTRIM(@employee_name))) = 0
        RETURN NULL;

    DECLARE @employee_id BIGINT;

    SELECT TOP 1 @employee_id = e.employee_id
      FROM grac_practice.organization_employee e
     WHERE e.organization_id = @organization_id
       AND UPPER(LTRIM(RTRIM(e.employee_name))) = UPPER(LTRIM(RTRIM(@employee_name)))
       AND ISNULL(e.status, N'Active') = N'Active'
     ORDER BY e.employee_id;

    RETURN @employee_id;
END;
GO

-- =====================================================================
-- 2. sp_task_owner_resolve  (BRD §6)
--
-- Walks the ownership ladder and returns the FIRST rung that yields an
-- active employee in the requesting organisation:
--
--   1 EXPLICIT_SOURCE — owner supplied by the caller, or carried on the
--                       originating source record
--   2 PRACTICE_OWNER  — practice.practice_owner_id / practice_owner
--   3 CONTROL_OWNER   — organization_control.primary_owner
--   4 PROCESS_OWNER   — practice_instance.primary_owner_id / primary_owner
--   5 FUNCTION_OWNER  — organization_business_function.owner_name
--   6 ORG_DEFAULT     — org_task_default_owner (192)
--   7 MANUAL          — nothing resolved; the UI must ask a human
--
-- Read-only. It never assigns; callers decide what to do with the answer.
-- Always returns exactly one row (OwnerEmployeeId may be NULL).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_owner_resolve
    @organization_id            BIGINT,
    @source_type_code           NVARCHAR(40)  = NULL,
    @source_record_id           BIGINT        = NULL,
    @linked_practice_id         BIGINT        = NULL,
    @linked_control_id          BIGINT        = NULL,
    @linked_instance_id         BIGINT        = NULL,
    @explicit_owner_employee_id BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 55600, 'sp_task_owner_resolve: organization_id is required.', 1;

    DECLARE @owner_id    BIGINT       = NULL,
            @source_code NVARCHAR(40) = NULL;

    -- ---- Rung 1: explicit -------------------------------------------
    IF @explicit_owner_employee_id IS NOT NULL
    BEGIN
        SET @owner_id    = @explicit_owner_employee_id;
        SET @source_code = N'EXPLICIT_SOURCE';
    END

    -- ---- Rung 1b: owner carried on the originating source record ----
    -- Only Gap has an owner column today (custom_gap.owner_employee_id).
    -- Risk / Continuous Assurance / Event Assurance sources join in
    -- Phase 2 alongside their candidate integrations; until then they
    -- fall straight through to rung 2.
    IF @owner_id IS NULL
       AND @source_type_code = N'Gap'
       AND @source_record_id IS NOT NULL
       AND OBJECT_ID('grac_practice.custom_gap','U') IS NOT NULL
    BEGIN
        SELECT @owner_id = g.owner_employee_id
          FROM grac_practice.custom_gap g
         WHERE g.custom_gap_id = @source_record_id;

        IF @owner_id IS NOT NULL SET @source_code = N'EXPLICIT_SOURCE';
    END

    -- ---- Rung 2: practice owner -------------------------------------
    IF @owner_id IS NULL AND @linked_practice_id IS NOT NULL
    BEGIN
        SELECT @owner_id = COALESCE(
                   p.practice_owner_id,
                   grac_practice.fn_task_employee_by_name(@organization_id, p.practice_owner))
          FROM grac_practice.practice p
         WHERE p.practice_id = @linked_practice_id;

        IF @owner_id IS NOT NULL SET @source_code = N'PRACTICE_OWNER';
    END

    -- ---- Rung 3: control / requirement owner ------------------------
    IF @owner_id IS NULL AND @linked_control_id IS NOT NULL
    BEGIN
        SELECT @owner_id = grac_practice.fn_task_employee_by_name(
                               @organization_id,
                               COALESCE(c.primary_owner, c.secondary_owner))
          FROM grac_practice.organization_control c
         WHERE c.organization_control_id = @linked_control_id;

        IF @owner_id IS NOT NULL SET @source_code = N'CONTROL_OWNER';
    END

    -- ---- Rung 4: process owner (practice instance) ------------------
    IF @owner_id IS NULL AND @linked_instance_id IS NOT NULL
    BEGIN
        SELECT @owner_id = COALESCE(
                   pi.primary_owner_id,
                   grac_practice.fn_task_employee_by_name(@organization_id, pi.primary_owner),
                   grac_practice.fn_task_employee_by_name(@organization_id, pi.secondary_owner))
          FROM grac_practice.practice_instance pi
         WHERE pi.practice_instance_id = @linked_instance_id;

        IF @owner_id IS NOT NULL SET @source_code = N'PROCESS_OWNER';
    END

    -- ---- Rung 5: department / business function owner ---------------
    IF @owner_id IS NULL AND @linked_instance_id IS NOT NULL
    BEGIN
        SELECT @owner_id = grac_practice.fn_task_employee_by_name(@organization_id, bf.owner_name)
          FROM grac_practice.practice_instance pi
          JOIN grac_practice.organization_business_function bf
            ON bf.business_function_id = pi.business_function_id
         WHERE pi.practice_instance_id = @linked_instance_id;

        IF @owner_id IS NOT NULL SET @source_code = N'FUNCTION_OWNER';
    END

    -- ---- Rung 6: organisation default -------------------------------
    IF @owner_id IS NULL AND OBJECT_ID('grac_practice.org_task_default_owner','U') IS NOT NULL
    BEGIN
        SELECT @owner_id = d.default_owner_employee_id
          FROM grac_practice.org_task_default_owner d
         WHERE d.organization_id = @organization_id;

        IF @owner_id IS NOT NULL SET @source_code = N'ORG_DEFAULT';
    END

    -- ---- Cross-org / inactive safety net ----------------------------
    -- Legacy owner_id columns are plain BIGINTs with no org guard, so a
    -- stale value could point at another tenant's employee. Discard
    -- anything that does not resolve to an active employee of THIS org
    -- and fall back to manual rather than leak an assignment across the
    -- tenant boundary.
    IF @owner_id IS NOT NULL
       AND NOT EXISTS (SELECT 1
                         FROM grac_practice.organization_employee e
                        WHERE e.employee_id      = @owner_id
                          AND e.organization_id  = @organization_id
                          AND ISNULL(e.status, N'Active') = N'Active')
    BEGIN
        SET @owner_id    = NULL;
        SET @source_code = NULL;
    END

    -- ---- Rung 7: manual ---------------------------------------------
    IF @owner_id IS NULL SET @source_code = N'MANUAL';

    SELECT @owner_id    AS OwnerEmployeeId,
           (SELECT TOP 1 e.employee_name
              FROM grac_practice.organization_employee e
             WHERE e.employee_id = @owner_id) AS OwnerEmployeeName,
           @source_code AS OwnerSourceCode,
           CASE @source_code
                WHEN N'EXPLICIT_SOURCE' THEN N'Explicit owner from source'
                WHEN N'PRACTICE_OWNER'  THEN N'Practice owner'
                WHEN N'CONTROL_OWNER'   THEN N'Control / requirement owner'
                WHEN N'PROCESS_OWNER'   THEN N'Process owner'
                WHEN N'FUNCTION_OWNER'  THEN N'Department / function owner'
                WHEN N'ORG_DEFAULT'     THEN N'Organisation default owner'
                ELSE                         N'Manual assignment required'
           END          AS OwnerSourceName;
END;
GO

-- =====================================================================
-- 3. sp_org_sla_match_for_priority  (BRD §8)
--
-- "The standard SLA is automatically mapped from priority using the
--  organisation's configured SLA policy."
--
-- 184 already built exactly this lookup for gaps, keyed on
-- sla_master.classification. Task priority (Low/Medium/High/Critical)
-- uses the SAME classification vocabulary, so this proc is a thin,
-- named seam over sp_org_sla_match_for_severity rather than a second
-- copy of the join. If a future release needs priority-specific masters,
-- only this proc changes.
--
-- NOTE on 186: org_sla_process_binding and sp_org_sla_config_for_process
-- were dropped as dead surface, with the explicit note "If a future
-- feature (Task SLA, ...) needs the resolver back, we re-introduce it
-- alongside the caller." We deliberately do NOT resurrect bindings —
-- the classification match is the pattern the gap flow settled on and
-- Task Centre now follows it, keeping one lookup style across GRAC.
--
-- Returns 0 or 1 row.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_match_for_priority
    @organization_id BIGINT,
    @priority        NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 55601, 'sp_org_sla_match_for_priority: organization_id is required.', 1;

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

    SELECT OrgSlaConfigId, SlaMasterId, SlaMasterCode, SlaMasterName,
           TotalSlaDays, WarningPct, EscalationPct, TimeBasis
      FROM @match;
END;
GO

-- =====================================================================
-- 4. sp_task_apply_sla  (BRD §8, §11)
--
-- The ONLY writer of standard_sla_days / standard_due_at. Nothing in the
-- API or UI exposes those as editable fields — BRD §18: "Direct SLA
-- editing is not permitted."
--
-- Effective due date rule:
--     sla_due_at = approved_extended_due_at   when an extension has been
--                                             APPROVED and pushes the date
--                                             out;
--                  standard_due_at            otherwise.
--
-- An approved extension therefore never destroys the original
-- commitment: standard_sla_days / standard_due_at survive untouched and
-- remain available for reporting and audit (BRD §13).
--
-- Idempotent — safe to call after open, after a priority change, and
-- after an extension approval.
--
-- Children are NOT resolved independently: they inherit the parent's
-- priority and SLA and cannot alter them (BRD §11). Calling this proc on
-- a child is a no-op; calling it on a parent cascades.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_apply_sla
    @task_id             BIGINT,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL
        THROW 55602, 'sp_task_apply_sla: task_id is required.', 1;

    DECLARE @organization_id  BIGINT,
            @priority         NVARCHAR(30),
            @task_type_id     INT,
            @parent_task_id   BIGINT,
            @baseline         DATETIME2,
            @ext_status       NVARCHAR(20),
            @ext_due          DATETIME2,
            @closed_at        DATETIME2;

    SELECT @organization_id = t.organization_id,
           @priority        = t.priority,
           @task_type_id    = t.task_type_id,
           @parent_task_id  = t.parent_task_id,
           @baseline        = COALESCE(t.start_date, t.entered_dt),
           @ext_status      = t.extension_status_code,
           @ext_due         = t.approved_extended_due_at,
           @closed_at       = t.closed_at
      FROM grac_practice.practice_task t
     WHERE t.task_id = @task_id;

    IF @organization_id IS NULL
        THROW 55603, 'sp_task_apply_sla: task not found.', 1;

    -- A child never derives its own SLA (BRD §11).
    IF @parent_task_id IS NOT NULL RETURN;

    -- ---- Resolve the org SLA policy for this priority ---------------
    --
    -- NOTE: this calls sp_org_sla_match_for_SEVERITY directly, not the
    -- sp_org_sla_match_for_PRIORITY seam defined above, even though the
    -- latter reads better here. T-SQL forbids nesting INSERT ... EXEC:
    -- sp_org_sla_match_for_priority is itself implemented as an
    -- INSERT ... EXEC over the severity proc, so wrapping it in a second
    -- one fails at runtime with error 8164 ("An INSERT EXEC statement
    -- cannot be nested"). Going straight to the underlying proc keeps
    -- exactly one level. sp_org_sla_match_for_priority remains the
    -- public, self-documenting entry point for the API and any caller
    -- that is not already inside an INSERT ... EXEC.
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

    DECLARE @sla_master_id   BIGINT       = NULL,
            @sla_master_name NVARCHAR(200) = NULL,
            @days            INT          = NULL,
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
        -- ---- Fallback: the legacy task-type default (037) ------------
        -- No Active org SLA config matches this priority. Rather than
        -- leave the task without a commitment we keep the pre-192
        -- behaviour and flag the provenance so the UI can prompt the
        -- operator to configure an SLA for that classification.
        DECLARE @default_hours INT;
        SELECT @default_hours = default_sla_hours
          FROM grac_practice.task_type_master
         WHERE task_type_id = @task_type_id;

        SET @days   = CAST(CEILING(ISNULL(@default_hours, 72) / 24.0) AS INT);
        SET @source = N'TYPE_DEFAULT';
        SET @sla_master_id   = NULL;
        SET @sla_master_name = NULL;
    END

    DECLARE @standard_due DATETIME2 = DATEADD(DAY, @days, @baseline);

    -- Approved extension wins ONLY when it actually pushes the date out.
    DECLARE @use_extension BIT =
        CASE WHEN @ext_status = N'Approved'
              AND @ext_due IS NOT NULL
              AND @ext_due > @standard_due THEN 1 ELSE 0 END;

    DECLARE @effective_due DATETIME2 = CASE WHEN @use_extension = 1 THEN @ext_due ELSE @standard_due END;

    UPDATE grac_practice.practice_task
       SET standard_sla_days = @days,
           standard_due_at   = @standard_due,
           sla_master_id     = @sla_master_id,
           sla_master_name   = @sla_master_name,
           sla_due_at        = @effective_due,
           sla_source_code   = CASE WHEN @use_extension = 1 THEN N'EXTENDED' ELSE @source END,
           updated_by        = @caller_display_name,
           updated_dt        = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    -- ---- Cascade to children (BRD §11) ------------------------------
    -- Children inherit priority + SLA and cannot alter them. Their own
    -- operational target date is clamped so it can never exceed the
    -- parent's effective due date. Closed children are left alone.
    UPDATE c
       SET c.priority                 = @priority,
           c.standard_sla_days        = @days,
           c.standard_due_at          = @standard_due,
           c.approved_extended_due_at = CASE WHEN @use_extension = 1 THEN @ext_due ELSE NULL END,
           c.sla_due_at               = @effective_due,
           c.sla_source_code          = CASE WHEN @use_extension = 1 THEN N'EXTENDED' ELSE @source END,
           c.child_target_date        = CASE
                                            WHEN c.child_target_date IS NULL THEN NULL
                                            WHEN c.child_target_date > @effective_due THEN @effective_due
                                            ELSE c.child_target_date
                                        END,
           c.updated_by               = @caller_display_name,
           c.updated_dt               = SYSUTCDATETIME()
      FROM grac_practice.practice_task c
     WHERE c.parent_task_id = @task_id
       AND c.closed_at IS NULL;
END;
GO

-- =====================================================================
-- 5. sp_task_activity_add  (BRD §16)
--
-- The operational, user-visible feed. practice_audit_trace remains the
-- immutable compliance log written by sp_pm_state_transition — this is
-- the human-readable companion rendered on the task detail page.
--
-- RETURNS NOTHING. The new id comes back through an OUTPUT parameter,
-- deliberately: almost every caller of this proc (priority change, SLA
-- extension, child create, complete, attachment upload, exception
-- reject) emits its OWN summary result set afterwards. If this proc
-- SELECTed, that row would arrive FIRST and every ADO.NET caller doing
-- ExecuteReader + first Read() would silently bind the wrong result set.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_activity_add
    @task_id             BIGINT,
    @activity_type_code  NVARCHAR(40),
    @remark              NVARCHAR(MAX)  = NULL,
    @from_value          NVARCHAR(400)  = NULL,
    @to_value            NVARCHAR(400)  = NULL,
    @actor_employee_id   BIGINT         = NULL,
    @caller_display_name NVARCHAR(100)  = N'system',
    @task_activity_id    BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_id IS NULL
        THROW 55604, 'sp_task_activity_add: task_id is required.', 1;
    IF @activity_type_code IS NULL OR LEN(LTRIM(RTRIM(@activity_type_code))) = 0
        THROW 55605, 'sp_task_activity_add: activity_type_code is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_task WHERE task_id = @task_id)
        THROW 55606, 'sp_task_activity_add: task not found.', 1;

    -- A free-text Comment or Update with no body is noise, not a record.
    IF @activity_type_code IN (N'Comment', N'Update')
       AND (@remark IS NULL OR LEN(LTRIM(RTRIM(@remark))) = 0)
        THROW 55607, 'sp_task_activity_add: remark is required for Comment and Update activities.', 1;

    DECLARE @actor_name NVARCHAR(240) =
        (SELECT TOP 1 e.employee_name
           FROM grac_practice.organization_employee e
          WHERE e.employee_id = @actor_employee_id);

    INSERT INTO grac_practice.task_activity
        (task_id, activity_type_code, remark, from_value, to_value,
         actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@task_id, @activity_type_code, @remark, @from_value, @to_value,
         @actor_employee_id, COALESCE(@actor_name, @caller_display_name),
         @caller_display_name, SYSUTCDATETIME());

    SET @task_activity_id = SCOPE_IDENTITY();
END;
GO

-- =====================================================================
-- 6. sp_task_attachment_add / sp_task_attachment_get  (BRD §16)
--     Same contract shape as the Exception Centre attachment procs.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_attachment_add
    @task_id                 BIGINT,
    @file_name               NVARCHAR(500),
    @content_type            NVARCHAR(200)  = NULL,
    @file_data               VARBINARY(MAX),
    @evidence_description    NVARCHAR(1000) = NULL,
    @uploaded_by_employee_id BIGINT         = NULL,
    @caller_display_name     NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL
        THROW 55608, 'sp_task_attachment_add: task_id is required.', 1;
    IF @file_name IS NULL OR LEN(LTRIM(RTRIM(@file_name))) = 0
        THROW 55609, 'sp_task_attachment_add: file_name is required.', 1;
    IF @file_data IS NULL
        THROW 55610, 'sp_task_attachment_add: file_data is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_task WHERE task_id = @task_id)
        THROW 55611, 'sp_task_attachment_add: task not found.', 1;

    DECLARE @size BIGINT = DATALENGTH(@file_data);

    BEGIN TRAN;

    INSERT INTO grac_practice.task_attachment
        (task_id, file_name, content_type, file_size_bytes, file_data,
         evidence_description, uploaded_by_employee_id, uploaded_dt)
    VALUES
        (@task_id, @file_name, @content_type, @size, @file_data,
         @evidence_description, @uploaded_by_employee_id, SYSUTCDATETIME());

    DECLARE @attachment_id BIGINT = SCOPE_IDENTITY();

    EXEC grac_practice.sp_task_activity_add
         @task_id             = @task_id,
         @activity_type_code  = N'EvidenceAdded',
         @remark              = @evidence_description,
         @to_value            = @file_name,
         @actor_employee_id   = @uploaded_by_employee_id,
         @caller_display_name = @caller_display_name;

    COMMIT;

    SELECT @attachment_id AS TaskAttachmentId, @size AS FileSizeBytes;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_task_attachment_get
    @task_attachment_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_attachment_id IS NULL
        THROW 55612, 'sp_task_attachment_get: task_attachment_id is required.', 1;

    SELECT a.task_attachment_id AS TaskAttachmentId,
           a.task_id            AS TaskId,
           a.file_name          AS FileName,
           a.content_type       AS ContentType,
           a.file_size_bytes    AS FileSizeBytes,
           a.file_data          AS FileData
      FROM grac_practice.task_attachment a
     WHERE a.task_attachment_id = @task_attachment_id;
END;
GO

-- =====================================================================
-- 7. sp_task_priority_change  (BRD §7)
--
--   Low -> Medium / High / Critical   : applied immediately, no approval
--   High -> Medium, Medium -> Low, .. : parked, routed to Exception Centre
--
-- "An increase in priority is never blocked because it makes the
--  organisation more urgent/faster. A reduction is governed because it
--  weakens the original expectation."  (BRD §7)
--
-- On an applied increase the standard SLA is RE-DERIVED from the new
-- priority (BRD §20: "Priority can be increased without approval and SLA
-- recalculates") and cascaded to children.
--
-- Result set: TaskId, Applied (bit), NewPriority, ExceptionRequestId,
--             StatusCode ('Applied' | 'PendingApproval' | 'NoChange')
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_priority_change
    @task_id             BIGINT,
    @new_priority        NVARCHAR(30),
    @reason              NVARCHAR(MAX)  = NULL,
    @actor_employee_id   BIGINT         = NULL,
    @caller_display_name NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL
        THROW 55615, 'sp_task_priority_change: task_id is required.', 1;
    IF @new_priority IS NULL OR @new_priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        THROW 55616, 'sp_task_priority_change: new_priority must be Low, Medium, High or Critical.', 1;

    DECLARE @organization_id BIGINT,
            @current         NVARCHAR(30),
            @parent_task_id  BIGINT,
            @closed_at       DATETIME2,
            @title           NVARCHAR(250),
            @pending         NVARCHAR(20);

    SELECT @organization_id = t.organization_id,
           @current         = t.priority,
           @parent_task_id  = t.parent_task_id,
           @closed_at       = t.closed_at,
           @title           = t.subject_title,
           @pending         = t.priority_change_status_code
      FROM grac_practice.practice_task t
     WHERE t.task_id = @task_id;

    IF @organization_id IS NULL
        THROW 55617, 'sp_task_priority_change: task not found.', 1;
    IF @closed_at IS NOT NULL
        THROW 55618, 'sp_task_priority_change: the task is already completed.', 1;

    -- BRD §11: "Child Tasks inherit the parent's priority and cannot
    -- independently change priority."
    IF @parent_task_id IS NOT NULL
        THROW 55619, 'sp_task_priority_change: child tasks inherit the parent priority. Change it on the parent task instead.', 1;

    DECLARE @rank_new INT = CASE @new_priority WHEN N'Low' THEN 1 WHEN N'Medium' THEN 2 WHEN N'High' THEN 3 ELSE 4 END,
            @rank_cur INT = CASE @current      WHEN N'Low' THEN 1 WHEN N'Medium' THEN 2 WHEN N'High' THEN 3 WHEN N'Critical' THEN 4 ELSE 2 END;

    IF @rank_new = @rank_cur
    BEGIN
        SELECT @task_id AS TaskId, CAST(0 AS BIT) AS Applied, @new_priority AS NewPriority,
               CAST(NULL AS BIGINT) AS ExceptionRequestId, N'NoChange' AS StatusCode;
        RETURN;
    END

    -- =================================================================
    -- INCREASE — operational freedom, applied immediately.
    -- =================================================================
    IF @rank_new > @rank_cur
    BEGIN
        BEGIN TRAN;

        UPDATE grac_practice.practice_task
           SET priority   = @new_priority,
               updated_by = @caller_display_name,
               updated_dt = SYSUTCDATETIME()
         WHERE task_id = @task_id;

        -- Re-derive the standard SLA from the new priority and cascade.
        EXEC grac_practice.sp_task_apply_sla
             @task_id             = @task_id,
             @caller_display_name = @caller_display_name;

        EXEC grac_practice.sp_task_activity_add
             @task_id             = @task_id,
             @activity_type_code  = N'PriorityChange',
             @remark              = @reason,
             @from_value          = @current,
             @to_value            = @new_priority,
             @actor_employee_id   = @actor_employee_id,
             @caller_display_name = @caller_display_name;

        -- Compliance log (BRD §18: "All material changes are auditable").
        INSERT INTO grac_practice.practice_audit_trace
            (entity_type, entity_id, action_type, before_json, after_json,
             status, entered_by, entered_dt)
        VALUES
            (N'Task', @task_id, N'PRIORITY_INCREASE',
             (SELECT @current AS priority FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
             (SELECT @new_priority AS priority, @reason AS reason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
             N'Active', @caller_display_name, SYSUTCDATETIME());

        COMMIT;

        SELECT @task_id AS TaskId, CAST(1 AS BIT) AS Applied, @new_priority AS NewPriority,
               CAST(NULL AS BIGINT) AS ExceptionRequestId, N'Applied' AS StatusCode;
        RETURN;
    END

    -- =================================================================
    -- REDUCTION — governed. Nothing on the task changes until approval.
    -- =================================================================
    IF @reason IS NULL OR LEN(LTRIM(RTRIM(@reason))) = 0
        THROW 55620, 'sp_task_priority_change: a reason is required when reducing priority.', 1;
    IF @actor_employee_id IS NULL
        THROW 55621, 'sp_task_priority_change: actor_employee_id is required when reducing priority (the requester is recorded on the exception).', 1;
    IF @pending = N'Pending'
        THROW 55622, 'sp_task_priority_change: a priority reduction is already awaiting approval for this task. Approve, reject or withdraw it first.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
          FROM grac_practice.record_status_master
         WHERE status_code = 'ACTIVE' OR status_name = 'Active'
         ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    DECLARE @request_title NVARCHAR(300) =
        CONCAT(N'Priority reduction: ', LEFT(ISNULL(@title, N''), 180),
               N' (', @current, N' -> ', @new_priority, N')');

    BEGIN TRAN;

    INSERT INTO grac_practice.exception_request
        (organization_id, custom_gap_id, task_id, request_title, request_reason,
         status_code, request_type_code,
         priority_original, priority_requested,
         requested_by_employee_id, requested_dt,
         record_status_id, entered_by, entered_dt)
    VALUES
        (@organization_id, NULL, @task_id, @request_title, @reason,
         N'Pending', N'TASK_PRIORITY_REDUCTION',
         @current, @new_priority,
         @actor_employee_id, SYSUTCDATETIME(),
         @active_record_status_id, @caller_display_name, SYSUTCDATETIME());

    DECLARE @request_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO grac_practice.exception_request_history
        (exception_request_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@request_id, N'Create', NULL, N'Pending',
         CONCAT(N'Priority reduction requested: ', @current, N' -> ', @new_priority,
                N'. Reason: ', @reason),
         @actor_employee_id, @caller_display_name, @caller_display_name, SYSUTCDATETIME());

    UPDATE grac_practice.practice_task
       SET requested_priority          = @new_priority,
           priority_change_status_code = N'Pending',
           updated_by                  = @caller_display_name,
           updated_dt                  = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    EXEC grac_practice.sp_task_activity_add
         @task_id             = @task_id,
         @activity_type_code  = N'PriorityRequest',
         @remark              = @reason,
         @from_value          = @current,
         @to_value            = @new_priority,
         @actor_employee_id   = @actor_employee_id,
         @caller_display_name = @caller_display_name;

    COMMIT;

    SELECT @task_id AS TaskId, CAST(0 AS BIT) AS Applied, @new_priority AS NewPriority,
           @request_id AS ExceptionRequestId, N'PendingApproval' AS StatusCode;
END;
GO

-- =====================================================================
-- 8. sp_task_priority_reduction_approve  (BRD §7)
--
-- Applies a reduction that Exception Centre has approved, then re-derives
-- the standard SLA from the now-lower priority and cascades to children.
-- Rejection is handled by sp_exception_request_reject below.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_priority_reduction_approve
    @exception_request_id    BIGINT,
    @approved_by_employee_id BIGINT,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @exception_request_id IS NULL
        THROW 55625, 'sp_task_priority_reduction_approve: exception_request_id is required.', 1;
    IF @approved_by_employee_id IS NULL
        THROW 55626, 'sp_task_priority_reduction_approve: approved_by_employee_id is required.', 1;

    DECLARE @task_id  BIGINT, @type NVARCHAR(30), @status NVARCHAR(30),
            @from_pri NVARCHAR(30), @to_pri NVARCHAR(30);

    SELECT @task_id  = task_id,
           @type     = request_type_code,
           @status   = status_code,
           @from_pri = priority_original,
           @to_pri   = priority_requested
      FROM grac_practice.exception_request
     WHERE exception_request_id = @exception_request_id;

    IF @task_id IS NULL
        THROW 55627, 'sp_task_priority_reduction_approve: request not found or not linked to a task.', 1;
    IF @type <> N'TASK_PRIORITY_REDUCTION'
        THROW 55628, 'sp_task_priority_reduction_approve: not a priority reduction request.', 1;
    IF @status <> N'Pending'
        THROW 55629, 'sp_task_priority_reduction_approve: only Pending requests can be approved.', 1;
    IF @to_pri IS NULL
        THROW 55630, 'sp_task_priority_reduction_approve: request is missing priority_requested; cannot apply.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.exception_request
       SET status_code             = N'Approved',
           approved_by_employee_id = @approved_by_employee_id,
           approved_dt             = SYSUTCDATETIME(),
           updated_by              = @caller_display_name,
           updated_dt              = SYSUTCDATETIME()
     WHERE exception_request_id = @exception_request_id;

    INSERT INTO grac_practice.exception_request_history
        (exception_request_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@exception_request_id, N'Approve', N'Pending', N'Approved',
         CONCAT(N'Priority reduction approved: ', @from_pri, N' -> ', @to_pri, N'.'),
         @approved_by_employee_id, @caller_display_name, @caller_display_name, SYSUTCDATETIME());

    UPDATE grac_practice.practice_task
       SET priority                    = @to_pri,
           priority_change_status_code = N'Approved',
           updated_by                  = @caller_display_name,
           updated_dt                  = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    -- Lower priority => (usually) a longer standard SLA. Re-derive it and
    -- cascade to children so the whole work package stays consistent.
    EXEC grac_practice.sp_task_apply_sla
         @task_id             = @task_id,
         @caller_display_name = @caller_display_name;

    EXEC grac_practice.sp_task_activity_add
         @task_id             = @task_id,
         @activity_type_code  = N'PriorityChange',
         @remark              = N'Priority reduction approved via Exception Centre.',
         @from_value          = @from_pri,
         @to_value            = @to_pri,
         @actor_employee_id   = @approved_by_employee_id,
         @caller_display_name = @caller_display_name;

    INSERT INTO grac_practice.practice_audit_trace
        (entity_type, entity_id, action_type, before_json, after_json,
         status, entered_by, entered_dt)
    VALUES
        (N'Task', @task_id, N'PRIORITY_REDUCTION_APPROVED',
         (SELECT @from_pri AS priority FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
         (SELECT @to_pri AS priority, @exception_request_id AS exception_request_id
          FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
         N'Active', @caller_display_name, SYSUTCDATETIME());

    COMMIT;

    SELECT @exception_request_id AS ExceptionRequestId,
           N'Approved'           AS StatusCode,
           @task_id              AS TaskId,
           @to_pri               AS PriorityApplied;
END;
GO

-- =====================================================================
-- 9. sp_exception_request_reject  (REWRITE — superset of 184)
--
-- UNCHANGED for GAP_CANDIDATE: risk auto-creation still fires exactly as
-- 176/184 specified. UNCHANGED for SLA_CANDIDATE: still governance-
-- neutral, no risk raised.
--
-- ADDED: the two task types must release the in-flight state parked on
-- practice_task, otherwise a rejected request would leave the task
-- showing "Pending" forever and the filtered unique index would block
-- any retry.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_reject
    @exception_request_id    BIGINT,
    @rejection_reason        NVARCHAR(MAX),
    @rejected_by_employee_id BIGINT,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55240, 'sp_exception_request_reject: exception_request_id is required.', 1;
    IF @rejection_reason IS NULL OR LEN(LTRIM(RTRIM(@rejection_reason))) = 0
        THROW 55241, 'sp_exception_request_reject: rejection_reason is required.', 1;
    IF @rejected_by_employee_id IS NULL
        THROW 55242, 'sp_exception_request_reject: rejected_by_employee_id is required.', 1;

    DECLARE @current NVARCHAR(30), @type NVARCHAR(30), @task_id BIGINT;
    SELECT @current = status_code,
           @type    = request_type_code,
           @task_id = task_id
      FROM grac_practice.exception_request WHERE exception_request_id = @exception_request_id;
    IF @current IS NULL
        THROW 55243, 'sp_exception_request_reject: request not found.', 1;
    IF @current <> N'Pending'
        THROW 55244, 'sp_exception_request_reject: only Pending requests can be rejected.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.exception_request
           SET status_code             = N'Rejected',
               rejected_by_employee_id = @rejected_by_employee_id,
               rejected_dt             = SYSUTCDATETIME(),
               rejection_reason        = @rejection_reason,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE exception_request_id = @exception_request_id;

        INSERT INTO grac_practice.exception_request_history
            (exception_request_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@exception_request_id, N'Reject', N'Pending', N'Rejected',
             @rejection_reason, @rejected_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        -- ---- Release the task-side in-flight state (192/193) ---------
        -- BRD §8: "If rejected, retain original due date/SLA." Nothing
        -- about the task's dates or priority moves — we only clear the
        -- request marker so the operator can raise another attempt.
        IF @type = N'TASK_PRIORITY_REDUCTION' AND @task_id IS NOT NULL
        BEGIN
            UPDATE grac_practice.practice_task
               SET priority_change_status_code = N'Rejected',
                   updated_by                  = @caller_display_name,
                   updated_dt                  = SYSUTCDATETIME()
             WHERE task_id = @task_id;
        END

        IF @type = N'TASK_SLA_EXTENSION' AND @task_id IS NOT NULL
        BEGIN
            UPDATE grac_practice.practice_task
               SET extension_status_code = N'Rejected',
                   updated_by            = @caller_display_name,
                   updated_dt            = SYSUTCDATETIME()
             WHERE task_id = @task_id;
        END

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    -- Task-side activity is written outside the transaction, mirroring
    -- how 184 keeps the risk auto-create out of the main TRAN: a logging
    -- failure must never roll back a completed governance decision.
    IF @type IN (N'TASK_PRIORITY_REDUCTION', N'TASK_SLA_EXTENSION') AND @task_id IS NOT NULL
    BEGIN
        BEGIN TRY
            DECLARE @activity NVARCHAR(40) =
                CASE WHEN @type = N'TASK_SLA_EXTENSION'
                     THEN N'SlaExtensionRejected' ELSE N'PriorityRequestRejected' END;

            EXEC grac_practice.sp_task_activity_add
                 @task_id             = @task_id,
                 @activity_type_code  = @activity,
                 @remark              = @rejection_reason,
                 @actor_employee_id   = @rejected_by_employee_id,
                 @caller_display_name = @caller_display_name;
        END TRY
        BEGIN CATCH
            DECLARE @amsg NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_exception_request_reject: task activity warning: ', @amsg);
        END CATCH
    END

    -- Risk auto-create ONLY for Gap Candidate (176/184 behaviour, kept
    -- verbatim). SLA Candidate and the two task types are governance-
    -- neutral: the underlying item still carries its original commitment.
    IF @type = N'GAP_CANDIDATE'
    BEGIN
        BEGIN TRY
            DECLARE @gap_id BIGINT;
            SELECT @gap_id = custom_gap_id
              FROM grac_practice.exception_request
             WHERE exception_request_id = @exception_request_id;

            DECLARE @risk_summary NVARCHAR(MAX) =
                CONCAT(N'Auto-raised because exception request #',
                       CAST(@exception_request_id AS NVARCHAR(20)),
                       N' was rejected. Rejection reason: ',
                       @rejection_reason);

            EXEC grac_practice.sp_risk_candidate_create
                @custom_gap_id            = @gap_id,
                @candidate_title          = NULL,
                @candidate_summary        = @risk_summary,
                @requested_by_employee_id = @rejected_by_employee_id,
                @caller_display_name      = @caller_display_name;
        END TRY
        BEGIN CATCH
            DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_exception_request_reject: risk auto-create warning: ', @msg);
        END CATCH
    END

    SELECT @exception_request_id AS ExceptionRequestId,
           N'Rejected' AS StatusCode,
           @type AS RequestTypeCode;
END;
GO

-- =====================================================================
-- 10. sp_exception_request_list  (REWRITE — superset of 184)
--
-- CRITICAL FIX: 184's version INNER JOINed custom_gap. Task-linked
-- requests have custom_gap_id NULL and would silently vanish from the
-- Exception Centre grid. The join becomes a LEFT JOIN and the task
-- columns are exposed so the UI can render "SLA Extension" and
-- "Priority Reduction" tabs alongside the two gap tabs.
--
-- Every column and parameter from 184/166 is preserved, so
-- ExceptionCentreService keeps binding without change.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_list
    @organization_id   BIGINT,
    @status_code       NVARCHAR(30) = NULL,
    @request_type_code NVARCHAR(30) = NULL,
    @page_number       INT = 1,
    @page_size         INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 55210, 'sp_exception_request_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        r.exception_request_id  AS ExceptionRequestId,
        r.organization_id       AS OrganizationId,
        r.custom_gap_id         AS CustomGapId,
        g.title                 AS GapTitle,
        r.task_id               AS TaskId,
        t.task_number           AS TaskNumber,
        t.subject_title         AS TaskTitle,
        r.request_title         AS RequestTitle,
        et.exception_type_name  AS ExceptionTypeName,
        r.status_code           AS StatusCode,
        r.request_type_code     AS RequestTypeCode,
        r.sla_days_original     AS SlaDaysOriginal,
        r.sla_days_requested    AS SlaDaysRequested,
        r.due_at_original       AS DueAtOriginal,
        r.due_at_requested      AS DueAtRequested,
        r.priority_original     AS PriorityOriginal,
        r.priority_requested    AS PriorityRequested,
        r.requested_dt          AS RequestedOn,
        rq.employee_name        AS RequestedByName,
        r.approved_dt           AS ApprovedOn,
        ap.employee_name        AS ApprovedByName,
        r.effective_from        AS EffectiveFrom,
        r.effective_until       AS EffectiveUntil,
        r.rejected_dt           AS RejectedOn,
        rj.employee_name        AS RejectedByName,
        (SELECT COUNT(*) FROM grac_practice.exception_request_attachment a
          WHERE a.exception_request_id = r.exception_request_id) AS AttachmentCount,
        COUNT(*) OVER () AS TotalRows
      FROM grac_practice.exception_request r
 LEFT JOIN grac_practice.custom_gap                g  ON g.custom_gap_id     = r.custom_gap_id
 LEFT JOIN grac_practice.practice_task             t  ON t.task_id           = r.task_id
 LEFT JOIN grac_practice.exception_type_master     et ON et.exception_type_id = r.exception_type_id
 LEFT JOIN grac_practice.organization_employee     rq ON rq.employee_id       = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee     ap ON ap.employee_id       = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee     rj ON rj.employee_id       = r.rejected_by_employee_id
     WHERE r.organization_id = @organization_id
       AND (@status_code IS NULL OR r.status_code = @status_code)
       AND (@request_type_code IS NULL OR r.request_type_code = @request_type_code)
     ORDER BY r.requested_dt DESC, r.exception_request_id DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '193 procedures present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.fn_task_employee_by_name','FN')          IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_owner_resolve','P')               IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_sla_match_for_priority','P')       IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_apply_sla','P')                   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_activity_add','P')                IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_attachment_add','P')              IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_priority_change','P')             IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_priority_reduction_approve','P')  IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '193 Task Centre v2 governance procedures installed. Next: 194_task_centre_v2_parent_child.sql';
GO

SET NOEXEC OFF;
GO
