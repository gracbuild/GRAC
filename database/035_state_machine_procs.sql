-- =====================================================================
-- 035 State-machine framework — procedures  (charter §12.1.1)
--
-- Companion file to 035_state_machine_framework.sql. Kept separate per
-- charter §5 non-negotiable: "new services / procedures go into new
-- files" (never appended to 02_Create_Procedures.sql).
--
-- Contents:
--   * grac_practice.sp_pm_state_transition
--     — validate + log a transition. Callers are expected to update the
--       owning entity's current_status_id INSIDE THE SAME TRANSACTION
--       (procedure returns to_status_id via output).
--   * grac_practice.sp_pm_state_transition_probe
--     — read-only probe used by the UI to decide whether to show a
--       transition action button.
--
-- Audit sink: existing grac_practice.practice_audit_trace (Q004
-- resolution — canonical audit_trail table deferred to migration 062).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- Prerequisite guard using SET NOEXEC ON so that all subsequent GO-
-- separated batches parse-but-do-not-execute when a prerequisite is
-- missing (a bare THROW only terminates its own batch — later batches
-- would otherwise proceed and fail with confusing errors).
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (035-procs): schema grac_practice missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.entity_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (035-procs): entity_status_master missing. Run 035_state_machine_framework.sql before this file.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.practice_audit_trace','U') IS NULL
BEGIN
    PRINT 'ABORT (035-procs): practice_audit_trace missing. Run deployment/01_Create_Schema_Tables.sql before this file.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('035_state_machine_procs: prerequisites missing — see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_pm_state_transition
--   Guard + log a state transition for any entity.
--
--   Parameters:
--     @entity_type       e.g. 'Task', 'Assignment', 'Waiver'
--     @entity_id         PK of the owning row
--     @from_status_code  NULL for initial-creation transitions
--     @to_status_code    target status_code
--     @actor_employee_id NULL when actor is GRAC_SYSTEM (§12.1.2)
--     @actor_role_code   the actor's role at time of transition
--                        (drives fn_is_transition_allowed)
--     @reason_code       optional; required when the matching rule
--                        has requires_reason = 1
--     @reason_text       optional
--     @correlation_id    optional; propagate from caller for tracing
--
--   Outputs:
--     @to_status_id      surrogate id of the resolved to_status
--     @transition_log_id log row id
--
--   Behaviour:
--     * Illegal transition -> THROW 53520 (409 Conflict at API layer)
--     * Missing reason when required -> THROW 53521
--     * Success -> INSERT into entity_state_transition_log
--                  + INSERT into practice_audit_trace (before/after JSON)
--
--   Never mutates the owning entity — the caller is responsible for
--   updating {entity}.current_status_id inside the same transaction
--   (keeps this procedure entity-agnostic).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_pm_state_transition
    @entity_type       NVARCHAR(60),
    @entity_id         BIGINT,
    @from_status_code  NVARCHAR(60)     = NULL,
    @to_status_code    NVARCHAR(60),
    @actor_employee_id BIGINT           = NULL,
    @actor_role_code   NVARCHAR(60)     = NULL,
    @reason_code       NVARCHAR(60)     = NULL,
    @reason_text       NVARCHAR(1000)   = NULL,
    @correlation_id    UNIQUEIDENTIFIER = NULL,
    @to_status_id      INT              OUTPUT,
    @transition_log_id BIGINT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @entity_type IS NULL
        THROW 53522, 'sp_pm_state_transition: @entity_type is required.', 1;
    IF @to_status_code IS NULL
        THROW 53523, 'sp_pm_state_transition: @to_status_code is required.', 1;

    DECLARE @from_status_id INT = NULL;
    IF @from_status_code IS NOT NULL
    BEGIN
        SET @from_status_id = grac_practice.fn_get_entity_status_id(@entity_type, @from_status_code);
        IF @from_status_id IS NULL
        BEGIN
            DECLARE @msg_from NVARCHAR(200) =
                CONCAT('Unknown from_status_code ''', @from_status_code,
                       ''' for entity_type ''', @entity_type, '''.');
            THROW 53524, @msg_from, 1;
        END
    END

    SET @to_status_id = grac_practice.fn_get_entity_status_id(@entity_type, @to_status_code);
    IF @to_status_id IS NULL
    BEGIN
        DECLARE @msg_to NVARCHAR(200) =
            CONCAT('Unknown to_status_code ''', @to_status_code,
                   ''' for entity_type ''', @entity_type, '''.');
        THROW 53525, @msg_to, 1;
    END

    -- Guard: illegal transition?
    IF grac_practice.fn_is_transition_allowed(
            @entity_type, @from_status_code, @to_status_code, @actor_role_code) = 0
    BEGIN
        DECLARE @msg_illegal NVARCHAR(400) =
            CONCAT('Illegal transition for ', @entity_type, ' #', CAST(@entity_id AS NVARCHAR(30)),
                   ': ', ISNULL(@from_status_code, N'<initial>'), ' -> ', @to_status_code,
                   ' as ', ISNULL(@actor_role_code, N'<no-role>'), '.');
        THROW 53520, @msg_illegal, 1;
    END

    -- Reason required?
    DECLARE @requires_reason BIT = 0;
    SELECT TOP 1 @requires_reason = r.requires_reason
    FROM grac_practice.entity_state_transition_rule r
    WHERE r.entity_type = @entity_type
      AND r.is_active = 1
      AND ISNULL(r.from_status_code, N'__NULL__') = ISNULL(@from_status_code, N'__NULL__')
      AND r.to_status_code = @to_status_code
      AND (r.actor_role_code IS NULL
           OR (@actor_role_code IS NOT NULL AND r.actor_role_code = @actor_role_code))
    ORDER BY CASE WHEN r.actor_role_code IS NULL THEN 1 ELSE 0 END;   -- prefer role-specific rule

    IF @requires_reason = 1
       AND (@reason_code IS NULL OR LTRIM(RTRIM(@reason_code)) = N'')
    BEGIN
        DECLARE @msg_reason NVARCHAR(400) =
            CONCAT('Transition ', @entity_type, ' ',
                   ISNULL(@from_status_code, N'<initial>'), ' -> ', @to_status_code,
                   ' requires a reason_code.');
        THROW 53521, @msg_reason, 1;
    END

    DECLARE @actor_label NVARCHAR(100) =
        CASE
            WHEN @actor_employee_id IS NOT NULL THEN CONCAT('emp:', CAST(@actor_employee_id AS NVARCHAR(30)))
            WHEN @actor_role_code   = N'GRAC_SYSTEM' THEN N'GRAC_SYSTEM'
            ELSE N'system'
        END;

    DECLARE @now DATETIME2 = SYSUTCDATETIME();

    BEGIN TRAN;

    INSERT INTO grac_practice.entity_state_transition_log
        (entity_type, entity_id, from_status_id, to_status_id,
         actor_employee_id, actor_role_code,
         reason_code, reason_text, correlation_id, transitioned_at)
    VALUES
        (@entity_type, @entity_id, @from_status_id, @to_status_id,
         @actor_employee_id, @actor_role_code,
         @reason_code, @reason_text, @correlation_id, @now);

    SET @transition_log_id = SCOPE_IDENTITY();

    -- Charter §9 cross-cutting: audit trail on every mutating procedure.
    DECLARE @before_json NVARCHAR(MAX) = (
        SELECT @from_status_code AS from_status_code,
               @from_status_id   AS from_status_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );
    DECLARE @after_json NVARCHAR(MAX) = (
        SELECT @to_status_code       AS to_status_code,
               @to_status_id         AS to_status_id,
               @actor_employee_id    AS actor_employee_id,
               @actor_role_code      AS actor_role_code,
               @reason_code          AS reason_code,
               @reason_text          AS reason_text,
               @correlation_id       AS correlation_id,
               @transition_log_id    AS transition_log_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    INSERT INTO grac_practice.practice_audit_trace
        (entity_type, entity_id, action_type, before_json, after_json,
         status, entered_by, entered_dt)
    VALUES
        (@entity_type, @entity_id, N'STATE_TRANSITION',
         @before_json, @after_json,
         N'Active', @actor_label, @now);

    COMMIT TRAN;
END;
GO

-- =====================================================================
-- sp_pm_state_transition_probe
--   Read-only. Answers "would this transition succeed if I ran it?".
--   Returns a single row: (Allowed BIT, ReasonRequired BIT, Reason).
--   The UI calls this to decide whether to render / grey-out an action.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_pm_state_transition_probe
    @entity_type       NVARCHAR(60),
    @from_status_code  NVARCHAR(60) = NULL,
    @to_status_code    NVARCHAR(60),
    @actor_role_code   NVARCHAR(60) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @allowed BIT =
        grac_practice.fn_is_transition_allowed(
            @entity_type, @from_status_code, @to_status_code, @actor_role_code);

    DECLARE @requires_reason BIT = 0;
    DECLARE @requires_approval BIT = 0;

    IF @allowed = 1
    BEGIN
        SELECT TOP 1
               @requires_reason   = r.requires_reason,
               @requires_approval = r.requires_approval
        FROM grac_practice.entity_state_transition_rule r
        WHERE r.entity_type = @entity_type
          AND r.is_active = 1
          AND ISNULL(r.from_status_code, N'__NULL__') = ISNULL(@from_status_code, N'__NULL__')
          AND r.to_status_code = @to_status_code
          AND (r.actor_role_code IS NULL
               OR (@actor_role_code IS NOT NULL AND r.actor_role_code = @actor_role_code))
        ORDER BY CASE WHEN r.actor_role_code IS NULL THEN 1 ELSE 0 END;
    END

    SELECT @allowed          AS Allowed,
           @requires_reason  AS ReasonRequired,
           @requires_approval AS ApprovalRequired,
           CASE
             WHEN @allowed = 1 THEN N'OK'
             ELSE CONCAT(N'Illegal transition: ',
                        ISNULL(@from_status_code, N'<initial>'), N' -> ', @to_status_code,
                        N' as ', ISNULL(@actor_role_code, N'<no-role>'))
           END AS Reason;
END;
GO

PRINT '035 state-machine procedures installed.';
GO

SELECT '035 state-machine procedures migration complete.' AS Message;
GO

SET NOEXEC OFF;
GO
