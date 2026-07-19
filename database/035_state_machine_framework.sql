-- =====================================================================
-- 035 State-machine framework  (charter §12.1.1)
--
-- Adds a generic, reusable state-machine substrate that every stateful
-- entity in Waves 1–5 will hook into. Locked infra decision §4.1.
--
-- Contents:
--   1. entity_status_master           — the universe of statuses per entity_type
--   2. entity_state_transition_rule   — legal (from_state -> to_state) pairs
--                                        gated by actor_role_code
--   3. entity_state_transition_log    — append-only per-transition record
--   4. fn_is_transition_allowed(...)  — inline TVF used by procs / UI
--
-- Follows conventions from charter §7:
--   * schema grac_practice.*
--   * snake_case
--   * no code enums — masters + FK
--   * every mutating proc writes to audit trail (procs live in the
--     companion file 035_state_machine_procs.sql — do NOT append here)
--
-- Idempotent:
--   * safe to re-run: every DDL guarded with IF NOT EXISTS / COL_LENGTH
--   * seeds use MERGE-style upserts on natural keys
--
-- Rollback: database/035_state_machine_framework_rollback.sql
-- Smoke test appended to database/deployment/05_UAT_Setup_Diagnostics.sql
-- Docs: docs/state-machine-framework.md
-- Procs: database/035_state_machine_procs.sql
--
-- Charter §5 non-negotiables honoured:
--   - Does NOT touch database/deployment/* base files
--   - Does NOT rename or drop any existing object
--   - Does NOT extend 02_Create_Procedures.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 53500, 'PracticeManagement schema grac_practice is missing. Run base scripts first.', 1;
GO

-- =====================================================================
-- 1. entity_status_master
--    One row per (entity_type, status_code). status_code is unique within
--    an entity_type. Referenced by every {entity}.current_status_id later.
-- =====================================================================
IF OBJECT_ID('grac_practice.entity_status_master','U') IS NULL
CREATE TABLE grac_practice.entity_status_master(
    entity_status_id   INT           IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_entity_status_master PRIMARY KEY,
    entity_type        NVARCHAR(60)  NOT NULL,
    status_code        NVARCHAR(60)  NOT NULL,
    status_name        NVARCHAR(120) NOT NULL,
    display_order      INT           NOT NULL DEFAULT 0,
    is_terminal        BIT           NOT NULL DEFAULT 0,
    is_initial         BIT           NOT NULL DEFAULT 0,
    description        NVARCHAR(400) NULL,
    is_active          BIT           NOT NULL DEFAULT 1,
    entered_by         NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt         DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by         NVARCHAR(100) NULL,
    updated_dt         DATETIME2     NULL,
    CONSTRAINT uq_pm_entity_status_master_type_code
        UNIQUE (entity_type, status_code)
);
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'ix_pm_entity_status_master_type_active'
      AND object_id = OBJECT_ID('grac_practice.entity_status_master'))
    CREATE INDEX ix_pm_entity_status_master_type_active
        ON grac_practice.entity_status_master(entity_type, is_active)
        INCLUDE (status_code, is_initial, is_terminal);
GO

-- =====================================================================
-- 2. entity_state_transition_rule
--    (entity_type, from_status_code, to_status_code, actor_role_code)
--    NULL from_status_code = initial transition (creation).
--    NULL actor_role_code  = allowed for any role (rare — use sparingly).
-- =====================================================================
IF OBJECT_ID('grac_practice.entity_state_transition_rule','U') IS NULL
CREATE TABLE grac_practice.entity_state_transition_rule(
    transition_rule_id INT           IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_entity_transition_rule PRIMARY KEY,
    entity_type        NVARCHAR(60)  NOT NULL,
    from_status_code   NVARCHAR(60)  NULL,
    to_status_code     NVARCHAR(60)  NOT NULL,
    actor_role_code    NVARCHAR(60)  NULL,
    requires_reason    BIT           NOT NULL DEFAULT 0,
    requires_approval  BIT           NOT NULL DEFAULT 0,
    description        NVARCHAR(400) NULL,
    is_active          BIT           NOT NULL DEFAULT 1,
    entered_by         NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt         DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by         NVARCHAR(100) NULL,
    updated_dt         DATETIME2     NULL,
    CONSTRAINT uq_pm_entity_transition_rule
        UNIQUE (entity_type, from_status_code, to_status_code, actor_role_code)
);
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'ix_pm_entity_transition_rule_lookup'
      AND object_id = OBJECT_ID('grac_practice.entity_state_transition_rule'))
    CREATE INDEX ix_pm_entity_transition_rule_lookup
        ON grac_practice.entity_state_transition_rule
           (entity_type, from_status_code, to_status_code, is_active)
        INCLUDE (actor_role_code, requires_reason, requires_approval);
GO

-- =====================================================================
-- 3. entity_state_transition_log
--    Append-only log of every transition executed. Made immutable via a
--    reject-trigger (mirrors practice_audit_trace convention).
--    reason_code / reason_text captured for downstream analytics; the
--    log row does NOT double as the audit_trail write — procedures MUST
--    write to practice_audit_trace independently (charter §9).
-- =====================================================================
IF OBJECT_ID('grac_practice.entity_state_transition_log','U') IS NULL
CREATE TABLE grac_practice.entity_state_transition_log(
    transition_log_id  BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_entity_transition_log PRIMARY KEY,
    entity_type        NVARCHAR(60)  NOT NULL,
    entity_id          BIGINT        NOT NULL,
    from_status_id     INT           NULL
        CONSTRAINT fk_pm_transition_log_from
            REFERENCES grac_practice.entity_status_master(entity_status_id),
    to_status_id       INT           NOT NULL
        CONSTRAINT fk_pm_transition_log_to
            REFERENCES grac_practice.entity_status_master(entity_status_id),
    actor_employee_id  BIGINT        NULL,   -- NULL when actor is GRAC_SYSTEM synthetic (§12.1.2)
    actor_role_code    NVARCHAR(60)  NULL,
    reason_code        NVARCHAR(60)  NULL,
    reason_text        NVARCHAR(1000) NULL,
    correlation_id     UNIQUEIDENTIFIER NULL,
    transitioned_at    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'ix_pm_entity_transition_log_entity'
      AND object_id = OBJECT_ID('grac_practice.entity_state_transition_log'))
    CREATE INDEX ix_pm_entity_transition_log_entity
        ON grac_practice.entity_state_transition_log(entity_type, entity_id, transitioned_at DESC)
        INCLUDE (from_status_id, to_status_id, actor_employee_id);
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'ix_pm_entity_transition_log_actor'
      AND object_id = OBJECT_ID('grac_practice.entity_state_transition_log'))
    CREATE INDEX ix_pm_entity_transition_log_actor
        ON grac_practice.entity_state_transition_log(actor_employee_id, transitioned_at DESC)
        WHERE actor_employee_id IS NOT NULL;
GO

-- Immutability trigger — matches practice_audit_trace pattern
CREATE OR ALTER TRIGGER grac_practice.tr_pm_entity_transition_log_immutable
ON grac_practice.entity_state_transition_log
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    THROW 53501, 'entity_state_transition_log is append-only and immutable.', 1;
END;
GO

-- =====================================================================
-- 4. fn_is_transition_allowed
--    Returns 1 when a rule exists for the tuple, else 0. NULL actor_role
--    is treated as a wildcard match.
--
--    Charter §12.1.1 acceptance: "fn_is_transition_allowed(entity_type,
--    from_state, to_state, actor_role) -> bit".
--
--    Kept as a scalar UDF (not TVF) so it can be used inside CHECK
--    constraints, procs, and WHERE clauses interchangeably. Marked
--    SCHEMABINDING to allow the query optimiser to inline it on SQL
--    Server 2019+ (safe no-op on older versions).
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_is_transition_allowed
(
    @entity_type      NVARCHAR(60),
    @from_status_code NVARCHAR(60),   -- NULL for initial creation
    @to_status_code   NVARCHAR(60),
    @actor_role_code  NVARCHAR(60)    -- NULL when caller has no role context
)
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    IF @entity_type IS NULL OR @to_status_code IS NULL RETURN 0;

    IF EXISTS (
        SELECT 1
        FROM grac_practice.entity_state_transition_rule r
        WHERE r.entity_type = @entity_type
          AND r.is_active = 1
          AND (
                (r.from_status_code IS NULL AND @from_status_code IS NULL)
             OR  r.from_status_code = @from_status_code
              )
          AND r.to_status_code = @to_status_code
          AND (
                r.actor_role_code IS NULL
             OR (@actor_role_code IS NOT NULL AND r.actor_role_code = @actor_role_code)
              )
    ) RETURN 1;

    RETURN 0;
END;
GO

-- Convenience helper: resolve a (entity_type, status_code) to its surrogate id.
-- Returns NULL on miss. Used by callers who receive user-friendly status codes
-- from the API layer and need to persist the surrogate id.
CREATE OR ALTER FUNCTION grac_practice.fn_get_entity_status_id
(
    @entity_type NVARCHAR(60),
    @status_code NVARCHAR(60)
)
RETURNS INT
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @id INT;
    SELECT @id = entity_status_id
    FROM grac_practice.entity_status_master
    WHERE entity_type = @entity_type
      AND status_code = @status_code
      AND is_active = 1;
    RETURN @id;
END;
GO

-- =====================================================================
-- 5. Bootstrap seed — Task and Assignment status universes.
--    Data owned by later work items (§12.1.3, §12.1.4) but seeded here
--    so the framework has content on day one for smoke testing.
--    Extension seeds live alongside their owning migrations.
--
--    Idempotent via MERGE on (entity_type, status_code).
-- =====================================================================
;WITH src AS (
    SELECT * FROM (VALUES
        -- entity_type,       status_code,               status_name,             display_order, is_initial, is_terminal
        (N'Task',              N'Open',                   N'Open',                 10, 1, 0),
        (N'Task',              N'Assigned',               N'Assigned',             20, 0, 0),
        (N'Task',              N'InProgress',             N'In Progress',          30, 0, 0),
        (N'Task',              N'PendingReview',          N'Pending Review',       40, 0, 0),
        (N'Task',              N'Closed',                 N'Closed',               50, 0, 1),
        (N'Task',              N'Cancelled',              N'Cancelled',            60, 0, 1),
        (N'Task',              N'Escalated',              N'Escalated',            70, 0, 0),
        -- Implementation-Task-specific intermediate gates (§12.2.3)
        (N'Task',              N'ConfigGatePassed',       N'Config Gate Passed',   35, 0, 0),
        (N'Task',              N'AwaitingFirstExecution', N'Awaiting Execution',   36, 0, 0),
        (N'Task',              N'OperationalGatePassed',  N'Operational Gate Passed',37,0,0),
        -- Assignment lifecycle (§12.1.4)
        (N'Assignment',        N'Nominated',              N'Nominated',            10, 1, 0),
        (N'Assignment',        N'Notified',               N'Notified',             20, 0, 0),
        (N'Assignment',        N'Accepted',               N'Accepted',             30, 0, 0),
        (N'Assignment',        N'Active',                 N'Active',               40, 0, 0),
        (N'Assignment',        N'Declined',               N'Declined',             50, 0, 1),
        (N'Assignment',        N'Delegated',              N'Delegated',            60, 0, 1),
        (N'Assignment',        N'Reassigned',             N'Reassigned',           70, 0, 1),
        (N'Assignment',        N'Vacated',                N'Vacated',              80, 0, 1),
        -- Waiver lifecycle (§12.1.5)
        (N'Waiver',            N'Draft',                  N'Draft',                10, 1, 0),
        (N'Waiver',            N'Requested',              N'Requested',            20, 0, 0),
        (N'Waiver',            N'Approved',               N'Approved',             30, 0, 0),
        (N'Waiver',            N'Active',                 N'Active',               40, 0, 0),
        (N'Waiver',            N'Expired',                N'Expired',              50, 0, 1),
        (N'Waiver',            N'Withdrawn',              N'Withdrawn',            60, 0, 1)
    ) v(entity_type, status_code, status_name, display_order, is_initial, is_terminal)
)
MERGE grac_practice.entity_status_master AS t
USING src
   ON t.entity_type = src.entity_type AND t.status_code = src.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, status_code, status_name, display_order, is_initial, is_terminal, entered_by)
    VALUES (src.entity_type, src.status_code, src.status_name, src.display_order, src.is_initial, src.is_terminal, 'seed-035')
WHEN MATCHED AND (
       t.status_name    <> src.status_name
    OR t.display_order  <> src.display_order
    OR t.is_initial     <> src.is_initial
    OR t.is_terminal    <> src.is_terminal
) THEN
    UPDATE SET
        status_name   = src.status_name,
        display_order = src.display_order,
        is_initial    = src.is_initial,
        is_terminal   = src.is_terminal,
        updated_by    = 'seed-035',
        updated_dt    = SYSUTCDATETIME();
GO

-- Bootstrap transition rules — Task lifecycle only. Assignment and Waiver
-- rules are seeded in their owning migrations (§12.1.4 / §12.1.5).
;WITH rules AS (
    SELECT * FROM (VALUES
        -- entity_type, from,           to,                     actor_role_code, requires_reason
        (N'Task', CAST(NULL AS NVARCHAR(60)), N'Open',                   NULL, 0),
        (N'Task', N'Open',                    N'Assigned',               NULL, 0),
        (N'Task', N'Assigned',                N'InProgress',             NULL, 0),
        (N'Task', N'InProgress',              N'PendingReview',          NULL, 0),
        (N'Task', N'PendingReview',           N'Closed',                 NULL, 0),
        (N'Task', N'InProgress',              N'ConfigGatePassed',       NULL, 0),
        (N'Task', N'ConfigGatePassed',        N'AwaitingFirstExecution', NULL, 0),
        (N'Task', N'AwaitingFirstExecution',  N'OperationalGatePassed',  NULL, 0),
        (N'Task', N'OperationalGatePassed',   N'Closed',                 NULL, 0),
        (N'Task', N'Open',                    N'Cancelled',              NULL, 1),
        (N'Task', N'Assigned',                N'Cancelled',              NULL, 1),
        (N'Task', N'InProgress',              N'Cancelled',              NULL, 1),
        (N'Task', N'Assigned',                N'Escalated',              NULL, 1),
        (N'Task', N'InProgress',              N'Escalated',              NULL, 1),
        (N'Task', N'PendingReview',           N'Escalated',              NULL, 1),
        (N'Task', N'Closed',                  N'Open',                   N'Admin', 1)
    ) v(entity_type, from_status_code, to_status_code, actor_role_code, requires_reason)
)
MERGE grac_practice.entity_state_transition_rule AS t
USING rules
   ON t.entity_type      = rules.entity_type
  AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(rules.from_status_code, N'__NULL__')
  AND t.to_status_code   = rules.to_status_code
  AND ISNULL(t.actor_role_code, N'__NULL__') = ISNULL(rules.actor_role_code, N'__NULL__')
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, entered_by)
    VALUES (rules.entity_type, rules.from_status_code, rules.to_status_code, rules.actor_role_code, rules.requires_reason, 'seed-035');
GO

-- Post-migration sanity — every seeded status_code should be resolvable.
IF NOT EXISTS (SELECT 1 FROM grac_practice.entity_status_master WHERE entity_type = N'Task' AND status_code = N'Open')
    THROW 53502, 'Task lifecycle seed failed to insert Open status.', 1;
GO

PRINT '035 state-machine framework installed. Next: run 035_state_machine_procs.sql';
GO

SELECT '035 state-machine framework migration complete.' AS Message,
       (SELECT COUNT(*) FROM grac_practice.entity_status_master)          AS StatusRowCount,
       (SELECT COUNT(*) FROM grac_practice.entity_state_transition_rule)  AS RuleRowCount;
