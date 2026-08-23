-- =====================================================================
-- 197 Task Candidate — schema  (Phase 2 of the Task Centre Incremental
--     Enhancement BRD v1.1; BRD §4, §5, §15, §18)
--
-- WHAT A TASK CANDIDATE IS
-- ------------------------
-- BRD §2: "Task Candidate means: an identified action awaiting execution
-- validation. Approved Task means: an executable, accountable task with a
-- confirmed owner, priority and SLA."
--
-- So a candidate is NOT a lightweight task. It is the record of an
-- action that upstream analysis has already identified, sitting in the
-- one gate Task Centre owns: does this work have an owner, an urgency
-- and a time expectation? Nothing else. BRD §5 is emphatic that the
-- candidate stage "must not duplicate analysis, risk assessment, gap
-- assessment or exception decision-making already performed in upstream
-- centres" — which is why this table carries no severity, no impact, no
-- root cause. Those live in the source and stay there.
--
-- ENTRY PATHS (BRD §4)
--   A. System-generated: Source -> Candidate -> owner/priority/SLA
--      validation -> Approved Task
--   B. Custom task: straight to Approved Task. A candidate stage would
--      be redundant — "the creator is explicitly creating the work."
--      Nothing in this file applies to Custom tasks.
--
-- THE ONE-SOURCE-MANY-TASKS PROBLEM  (BRD §15)
-- --------------------------------------------
-- BRD §15 insists one source item may generate MANY tasks
-- (GAP-101 -> update policy, configure system, conduct awareness). That
-- rules out a unique index on (source_type_code, source_record_id).
--
-- But auto-generators must still be idempotent: re-saving a gap analysis
-- must not spawn a second identical candidate. Those two requirements
-- are reconciled by `source_dedupe_key`:
--
--   * An automatic trigger passes a stable key ('GAP_REMEDIATION',
--     'RISK_TREATMENT', ...). A filtered unique index then permits at
--     most ONE open candidate per (source, key).
--   * A human adding a second, different action passes NULL, and NULLs
--     are excluded from the index — so 1 -> N stays possible.
--
-- CONTENTS
--   1. task_candidate
--   2. task_candidate_history
--   3. practice_task.task_candidate_id  (Task -> Candidate navigation)
--   4. Indexes
--
-- ADDITIVE ONLY. Idempotent. Depends on 192-196.
--
-- Rollback:  database/197_task_candidate_schema_rollback.sql
-- Procs:     198_task_candidate_procs.sql
-- Sources:   199_task_candidate_sources.sql
-- Docs:      docs/task-centre-v2.md
-- ERROR CODE RANGE: 55800-55899
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (197): schema grac_practice is missing.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
BEGIN PRINT 'ABORT (197): practice_task missing — run 037 first.'; SET @ok = 0; END

IF COL_LENGTH('grac_practice.practice_task','source_type_code') IS NULL
BEGIN PRINT 'ABORT (197): Task Centre v2 schema missing — run 192_task_centre_v2_schema.sql first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_task_owner_resolve','P') IS NULL
BEGIN PRINT 'ABORT (197): sp_task_owner_resolve missing — run 193_task_centre_v2_procs.sql first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
BEGIN PRINT 'ABORT (197): organization_employee missing — run 009 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN PRINT 'ABORT (197): record_status_master missing — run 008 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('197_task_candidate_schema: prerequisites missing — see PRINT messages above. Run database/_diag_task_centre_v2_prereqs.sql for a full report.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. task_candidate
-- =====================================================================
IF OBJECT_ID('grac_practice.task_candidate','U') IS NULL
CREATE TABLE grac_practice.task_candidate(
    task_candidate_id        BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_task_candidate PRIMARY KEY,
    organization_id          BIGINT NOT NULL
        CONSTRAINT fk_pm_task_candidate_organization
            REFERENCES grac_practice.organization(organization_id),

    -- ---- Origin (BRD §15) ------------------------------------------
    -- Same vocabulary as practice_task.source_type_code so a candidate
    -- and the task it becomes describe their origin identically.
    source_type_code         NVARCHAR(40)  NOT NULL,
    source_record_id         BIGINT        NOT NULL,
    source_reference         NVARCHAR(200) NULL,      -- display label, e.g. 'GAP-101'

    -- Idempotency key for automatic generators; NULL for manual adds.
    -- See the header note on one-source-many-tasks.
    source_dedupe_key        NVARCHAR(200) NULL,

    -- ---- What needs doing ------------------------------------------
    candidate_title          NVARCHAR(250) NOT NULL,
    candidate_description    NVARCHAR(MAX) NULL,

    -- Which task type the approved task should be opened as. Defaults to
    -- Rectification because that is what every current source produces;
    -- validated against task_type_master at approval time, not here, so
    -- a deactivated type cannot orphan an existing candidate.
    task_type_code           NVARCHAR(60)  NOT NULL
        CONSTRAINT df_pm_task_candidate_type DEFAULT N'Rectification',

    -- Carried straight through to the task so the owner ladder and the
    -- source panels have the same context the source had.
    linked_release_id        BIGINT NULL,
    linked_control_id        BIGINT NULL,
    linked_practice_id       BIGINT NULL,
    linked_instance_id       BIGINT NULL,

    -- ---- The three things validation confirms (BRD §5) -------------
    proposed_owner_employee_id BIGINT NULL
        CONSTRAINT fk_pm_task_candidate_owner
            REFERENCES grac_practice.organization_employee(employee_id),
    owner_source_code        NVARCHAR(40)  NULL,      -- which rung of the ladder answered

    proposed_priority        NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_task_candidate_priority DEFAULT N'Medium',

    -- Derived from priority, never typed in — same rule as the task
    -- (BRD §8: "Users must not directly edit or overwrite the standard
    -- SLA"). Recomputed whenever the proposed priority changes.
    proposed_sla_days        INT NULL,
    proposed_due_at          DATETIME2 NULL,
    sla_master_id            BIGINT NULL,             -- soft ref grac_new.sla_master
    sla_master_name          NVARCHAR(200) NULL,
    sla_source_code          NVARCHAR(30)  NULL,      -- AUTO | TYPE_DEFAULT

    -- ---- Lifecycle (BRD §5) -----------------------------------------
    --   New       — raised by a source, not yet looked at
    --   Validated — owner + priority confirmed, ready to approve
    --   Approved  — converted; approved_task_id points at the task
    --   Discarded — the action will not be executed as a task
    --
    -- Deliberately NOT a state-machine entity: the candidate stage is a
    -- gate, not a workflow, and adding it to entity_status_master would
    -- imply a richness the BRD explicitly does not want.
    status_code              NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_task_candidate_status DEFAULT N'New',

    approved_task_id         BIGINT NULL
        CONSTRAINT fk_pm_task_candidate_task
            REFERENCES grac_practice.practice_task(task_id),

    validated_by_employee_id BIGINT NULL
        CONSTRAINT fk_pm_task_candidate_validator
            REFERENCES grac_practice.organization_employee(employee_id),
    validated_dt             DATETIME2 NULL,

    approved_by_employee_id  BIGINT NULL
        CONSTRAINT fk_pm_task_candidate_approver
            REFERENCES grac_practice.organization_employee(employee_id),
    approved_dt              DATETIME2 NULL,

    discarded_by_employee_id BIGINT NULL
        CONSTRAINT fk_pm_task_candidate_discarder
            REFERENCES grac_practice.organization_employee(employee_id),
    discarded_dt             DATETIME2 NULL,
    discard_reason           NVARCHAR(MAX) NULL,

    record_status_id         INT NOT NULL
        CONSTRAINT fk_pm_task_candidate_record_status
            REFERENCES grac_practice.record_status_master(record_status_id),
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_task_candidate_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_task_candidate_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    -- Mirrors practice_task.task_number so the two read alike on screen.
    candidate_number AS
        (CONCAT('TC-', CAST(organization_id AS NVARCHAR(20)), '-', CAST(task_candidate_id AS NVARCHAR(20))))
        PERSISTED,

    CONSTRAINT ck_pm_task_candidate_source_type
        CHECK (source_type_code IN (N'Gap', N'Exception', N'Risk',
                                    N'ContinuousAssurance', N'EventAssurance',
                                    N'Custom')),
    CONSTRAINT ck_pm_task_candidate_status
        CHECK (status_code IN (N'New', N'Validated', N'Approved', N'Discarded')),
    CONSTRAINT ck_pm_task_candidate_priority
        CHECK (proposed_priority IN (N'Low', N'Medium', N'High', N'Critical')),
    CONSTRAINT ck_pm_task_candidate_sla_source
        CHECK (sla_source_code IS NULL OR sla_source_code IN (N'AUTO', N'TYPE_DEFAULT')),
    CONSTRAINT ck_pm_task_candidate_owner_source
        CHECK (owner_source_code IS NULL
            OR owner_source_code IN (N'EXPLICIT_SOURCE', N'PRACTICE_OWNER',
                                     N'CONTROL_OWNER', N'PROCESS_OWNER',
                                     N'FUNCTION_OWNER', N'ORG_DEFAULT',
                                     N'MANUAL', N'REASSIGNED')),
    -- An Approved candidate must point at the task it became; nothing
    -- else may. This is what makes "one candidate, one task" provable.
    CONSTRAINT ck_pm_task_candidate_approved_task
        CHECK ((status_code = N'Approved' AND approved_task_id IS NOT NULL)
            OR (status_code <> N'Approved' AND approved_task_id IS NULL)),
    CONSTRAINT ck_pm_task_candidate_discard_reason
        CHECK (status_code <> N'Discarded' OR discard_reason IS NOT NULL)
);
GO

-- =====================================================================
-- 2. task_candidate_history
--     Same shape as risk_candidate_history (169) and
--     exception_request_history (161) — every centre's audit log reads
--     the same way.
-- =====================================================================
IF OBJECT_ID('grac_practice.task_candidate_history','U') IS NULL
CREATE TABLE grac_practice.task_candidate_history(
    task_candidate_history_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_task_candidate_history PRIMARY KEY,
    task_candidate_id        BIGINT NOT NULL
        CONSTRAINT fk_pm_task_candidate_history_candidate
            REFERENCES grac_practice.task_candidate(task_candidate_id),
    action_code              NVARCHAR(40) NOT NULL,   -- Create / Validate / Approve / Discard / OwnerChange / PriorityChange
    from_status_code         NVARCHAR(30) NULL,
    to_status_code           NVARCHAR(30) NULL,
    remark                   NVARCHAR(MAX) NULL,
    actor_employee_id        BIGINT NULL,
    actor_display_name       NVARCHAR(240) NULL,
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_task_candidate_history_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_task_candidate_history_entered_dt DEFAULT SYSUTCDATETIME()
);
GO

IF OBJECT_ID('grac_practice.task_candidate_history','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ix_pm_task_candidate_history_candidate'
                      AND object_id = OBJECT_ID('grac_practice.task_candidate_history'))
    CREATE INDEX ix_pm_task_candidate_history_candidate
        ON grac_practice.task_candidate_history(task_candidate_id, entered_dt DESC)
        INCLUDE (action_code, actor_display_name);
GO

-- =====================================================================
-- 3. practice_task.task_candidate_id — Task -> Candidate navigation
--
-- The reverse direction (Candidate -> Task) is task_candidate
-- .approved_task_id. Both are stored rather than one being derived,
-- because the task detail page and the candidate grid each need their
-- own direction on a hot path.
-- =====================================================================
IF COL_LENGTH('grac_practice.practice_task','task_candidate_id') IS NULL
    ALTER TABLE grac_practice.practice_task ADD task_candidate_id BIGINT NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = 'fk_pm_practice_task_candidate'
      AND parent_object_id = OBJECT_ID('grac_practice.practice_task'))
    ALTER TABLE grac_practice.practice_task
        ADD CONSTRAINT fk_pm_practice_task_candidate
            FOREIGN KEY (task_candidate_id)
            REFERENCES grac_practice.task_candidate(task_candidate_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_practice_task_candidate'
                  AND object_id = OBJECT_ID('grac_practice.practice_task'))
    CREATE INDEX ix_pm_practice_task_candidate
        ON grac_practice.practice_task(task_candidate_id)
        WHERE task_candidate_id IS NOT NULL;
GO

-- =====================================================================
-- 4. task_candidate indexes
-- =====================================================================

-- Idempotency for automatic generators. Filtered to OPEN statuses only,
-- so once a candidate is Approved or Discarded the same source+key may
-- legitimately raise another (e.g. a gap re-opens and needs new work).
-- NULL dedupe keys are excluded entirely — that is what preserves the
-- BRD §15 one-source-many-tasks rule for manual additions.
--
-- IN() is used rather than OR: filtered index predicates support IN but
-- SQL Server rejects OR in some versions.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_task_candidate_source_dedupe'
                  AND object_id = OBJECT_ID('grac_practice.task_candidate'))
    CREATE UNIQUE INDEX ux_pm_task_candidate_source_dedupe
        ON grac_practice.task_candidate(source_type_code, source_record_id, source_dedupe_key)
        WHERE source_dedupe_key IS NOT NULL
          AND status_code IN (N'New', N'Validated');
GO

-- The Candidates tab: open work for an organisation, newest first.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_task_candidate_org_status'
                  AND object_id = OBJECT_ID('grac_practice.task_candidate'))
    CREATE INDEX ix_pm_task_candidate_org_status
        ON grac_practice.task_candidate(organization_id, status_code, entered_dt DESC)
        INCLUDE (source_type_code, source_record_id, candidate_title,
                 proposed_owner_employee_id, proposed_priority, proposed_due_at);
GO

-- Source -> Candidates, for the "Related Tasks" panel on a gap / risk /
-- observation screen: it must show work that is identified but not yet
-- approved, not only work that already became a task.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_task_candidate_source'
                  AND object_id = OBJECT_ID('grac_practice.task_candidate'))
    CREATE INDEX ix_pm_task_candidate_source
        ON grac_practice.task_candidate(source_type_code, source_record_id)
        INCLUDE (organization_id, status_code, candidate_title, approved_task_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_task_candidate_number'
                  AND object_id = OBJECT_ID('grac_practice.task_candidate'))
    CREATE INDEX ix_pm_task_candidate_number
        ON grac_practice.task_candidate(candidate_number);
GO

-- =====================================================================
-- 5. Sanity
-- =====================================================================
SELECT 'task_candidate + history present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.task_candidate','U')         IS NOT NULL
             AND OBJECT_ID('grac_practice.task_candidate_history','U')  IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'practice_task.task_candidate_id present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_task','task_candidate_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'dedupe index present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE name = 'ux_pm_task_candidate_source_dedupe')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '197 Task Candidate schema installed. Next: 198_task_candidate_procs.sql';
GO

SET NOEXEC OFF;
GO
