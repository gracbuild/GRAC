-- =====================================================================
-- 192 Task Centre v2 — schema  (Phase 1 of the Task Centre Incremental
--     Enhancement BRD v1.1, 16 Aug 2026)
--
-- WHAT THE BRD ASKS FOR THAT THE EXISTING TASK CENTRE CANNOT EXPRESS
-- -----------------------------------------------------------------
-- The task engine from 037/048 stores a single `sla_due_at` and a free
-- `priority` string. The BRD needs:
--
--   * Standard SLA (system-derived from priority, NEVER user-editable)
--     kept SEPARATE from an Approved Extended Due Date, so an approved
--     extension never destroys the original commitment  (BRD §8).
--   * Governed priority changes — increases are free, reductions need
--     an Exception Centre approval  (BRD §7).
--   * Parent/child decomposition where the parent owns the commitment
--     and children may not weaken it  (BRD §11, §12).
--   * A per-task activity trail and evidence store for the operational
--     detail view  (BRD §16).
--   * A source reference that survives independently of the existing
--     subject_entity_* pair, so one source can raise many tasks and the
--     UI can navigate Task -> Source and Source -> Tasks  (BRD §15).
--   * Task-linked Exception Centre requests, reusing the SAME exception
--     mechanism the gap flow already uses — BRD §19 explicitly forbids a
--     parallel approval mechanism.
--
-- DESIGN NOTES / CONFLICT REGISTER (BRD §19 "document the conflict")
-- -----------------------------------------------------------------
--  1. LIFECYCLE. The BRD's lean lifecycle is APPROVED -> IN PROGRESS ->
--     COMPLETED. GRAC already runs a data-driven state machine (035)
--     with Open/Assigned/InProgress/PendingReview/Closed plus the
--     Implementation two-gate closure (§12.2.3). Per the agreed
--     resolution we MAP rather than replace:
--         Approved   ~= Assigned      (owner + priority + SLA settled)
--         InProgress  = InProgress
--         Completed  ~= Closed        (closed_at set)
--     No entity_status_master rows are added or removed, so the existing
--     transition rules, two-gate closure and sample data keep working.
--     `completed_by_employee_id` / `completed_dt` are recorded ALONGSIDE
--     closed_at so BRD-shaped reporting is possible without a second
--     status model.
--
--  2. `sla_due_at` REMAINS the EFFECTIVE monitoring date. Existing
--     sweeps (sp_task_overdue_sweep) and the existing view's is_overdue
--     keep reading it untouched. 192 adds `standard_due_at` (immutable
--     original) and `approved_extended_due_at` (only after approval);
--     193/194 keep sla_due_at = COALESCE(approved_extended, standard).
--
--  3. exception_request.custom_gap_id becomes NULLABLE so a request can
--     hang off a TASK instead of a GAP. Every existing row keeps its
--     gap id; a new CHECK guarantees at least one of (gap, task) is set.
--
-- CONTENTS
--   1. practice_task — additive columns (parent/child, SLA split,
--      extension + priority-change state, source ref, completion)
--   2. task_activity        — update / comment / governance trail
--   3. task_attachment      — evidence store (same shape as
--                             exception_request_attachment)
--   4. org_task_default_owner — level 6 of the owner-resolution chain
--   5. exception_request    — task_id, nullable custom_gap_id, widened
--                             request_type_code, priority payload
--   6. Indexes
--
-- ADDITIVE ONLY. No column is dropped, no existing row is rewritten.
-- Idempotent — safe to re-run.
--
-- Rollback:  database/192_task_centre_v2_schema_rollback.sql
-- Procs:     193_task_centre_v2_procs.sql,
--            194_task_centre_v2_parent_child.sql,
--            195_task_centre_v2_read.sql
-- Docs:      docs/task-centre-v2.md
-- ERROR CODE RANGE: 55600-55699
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- ---------------------------------------------------------------------
-- Prerequisite guard. SET NOEXEC ON so that ALL later GO-separated
-- batches are parsed-but-not-executed when a prerequisite is missing —
-- a bare THROW would only kill the current batch (same pattern as 037).
-- ---------------------------------------------------------------------
DECLARE @ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (192): schema grac_practice is missing.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
BEGIN PRINT 'ABORT (192): practice_task missing — run 037_task_engine.sql first.'; SET @ok = 0; END

IF COL_LENGTH('grac_practice.practice_task','related_entity_type_id') IS NULL
BEGIN PRINT 'ABORT (192): practice_task not extended — run 048_task_model_extension.sql first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN PRINT 'ABORT (192): exception_request missing — run 161_exception_centre_schema.sql first.'; SET @ok = 0; END

IF COL_LENGTH('grac_practice.exception_request','request_type_code') IS NULL
BEGIN PRINT 'ABORT (192): exception_request.request_type_code missing — run 184_gap_sla_match_and_override.sql first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
BEGIN PRINT 'ABORT (192): organization_employee missing — run 009_practice_employee_master.sql first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('192_task_centre_v2_schema: prerequisites missing — see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. practice_task — additive columns
-- =====================================================================

-- ---- 1a. Parent / child decomposition (BRD §11) ----------------------
-- parent_task_id is a self-reference. Single level only: 194 rejects an
-- attempt to give a child its own children, because the BRD's governance
-- model ("the parent owns the commitment") has exactly one accountable
-- parent per work package.
IF COL_LENGTH('grac_practice.practice_task','parent_task_id') IS NULL
    ALTER TABLE grac_practice.practice_task ADD parent_task_id BIGINT NULL;
GO

-- Mandatory children gate parent completion (BRD §12). Default 1: a
-- child created without an explicit flag is assumed to be required work.
-- NULL for top-level tasks — the column only has meaning on a child.
IF COL_LENGTH('grac_practice.practice_task','is_mandatory_child') IS NULL
    ALTER TABLE grac_practice.practice_task ADD is_mandatory_child BIT NULL;
GO

-- Optional operational target for a child. 194 clamps it so it can never
-- exceed the parent's effective due date (BRD §11: "child operational
-- target dates ... cannot exceed the parent's approved due date").
IF COL_LENGTH('grac_practice.practice_task','child_target_date') IS NULL
    ALTER TABLE grac_practice.practice_task ADD child_target_date DATETIME2 NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = 'fk_pm_practice_task_parent'
      AND parent_object_id = OBJECT_ID('grac_practice.practice_task'))
    ALTER TABLE grac_practice.practice_task
        ADD CONSTRAINT fk_pm_practice_task_parent
            FOREIGN KEY (parent_task_id)
            REFERENCES grac_practice.practice_task(task_id);
GO

-- A task cannot be its own parent. (The single-level rule is enforced
-- procedurally in 194 — a CHECK cannot see another row.)
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_parent_not_self')
    ALTER TABLE grac_practice.practice_task
        ADD CONSTRAINT ck_pm_practice_task_parent_not_self
            CHECK (parent_task_id IS NULL OR parent_task_id <> task_id);
GO

-- ---- 1b. SLA split: standard vs approved extension (BRD §8) ----------
-- standard_sla_days / standard_due_at are the SYSTEM-DERIVED commitment.
-- They are written only by sp_task_apply_sla (193) and are never exposed
-- as editable fields — BRD §18: "Direct SLA editing is not permitted."
IF COL_LENGTH('grac_practice.practice_task','standard_sla_days') IS NULL
    ALTER TABLE grac_practice.practice_task ADD standard_sla_days INT NULL;
GO
IF COL_LENGTH('grac_practice.practice_task','standard_due_at') IS NULL
    ALTER TABLE grac_practice.practice_task ADD standard_due_at DATETIME2 NULL;
GO

-- Only ever written by an APPROVED extension (194). Until then it is NULL
-- and monitoring runs against standard_due_at (BRD §13: "monitoring
-- switches to the Approved Extended Due Date only after approval").
IF COL_LENGTH('grac_practice.practice_task','approved_extended_due_at') IS NULL
    ALTER TABLE grac_practice.practice_task ADD approved_extended_due_at DATETIME2 NULL;
GO

-- Provenance of the standard SLA, mirroring custom_gap.sla_source_code
-- from 184 so both centres read the same vocabulary:
--   AUTO         — matched an Active org_sla_config for this priority
--   TYPE_DEFAULT — no org SLA config matched; fell back to
--                  task_type_master.default_sla_hours (legacy behaviour)
--   EXTENDED     — an extension has been approved; effective date is
--                  approved_extended_due_at, standard_* still intact
IF COL_LENGTH('grac_practice.practice_task','sla_source_code') IS NULL
    ALTER TABLE grac_practice.practice_task ADD sla_source_code NVARCHAR(30) NULL;
GO

-- Soft reference to grac_new.sla_master.sla_id — deliberately NOT an FK,
-- exactly like custom_gap.sla_master_id (184): sla_master lives in the
-- grac_new database/schema owned by Control Management.
IF COL_LENGTH('grac_practice.practice_task','sla_master_id') IS NULL
    ALTER TABLE grac_practice.practice_task ADD sla_master_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.practice_task','sla_master_name') IS NULL
    ALTER TABLE grac_practice.practice_task ADD sla_master_name NVARCHAR(200) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_sla_source')
    ALTER TABLE grac_practice.practice_task
        ADD CONSTRAINT ck_pm_practice_task_sla_source
            CHECK (sla_source_code IS NULL
                OR sla_source_code IN (N'AUTO', N'TYPE_DEFAULT', N'EXTENDED'));
GO

-- ---- 1c. In-flight SLA extension request state (BRD §8) --------------
-- Denormalised onto the task so the grid and detail view can show
-- "Extension Pending" without joining exception_request on every row.
-- exception_request remains the system of record for the approval.
IF COL_LENGTH('grac_practice.practice_task','extension_status_code') IS NULL
    ALTER TABLE grac_practice.practice_task ADD extension_status_code NVARCHAR(20) NULL;
GO
IF COL_LENGTH('grac_practice.practice_task','requested_due_at') IS NULL
    ALTER TABLE grac_practice.practice_task ADD requested_due_at DATETIME2 NULL;
GO
IF COL_LENGTH('grac_practice.practice_task','extension_reason') IS NULL
    ALTER TABLE grac_practice.practice_task ADD extension_reason NVARCHAR(MAX) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_extension_status')
    ALTER TABLE grac_practice.practice_task
        ADD CONSTRAINT ck_pm_practice_task_extension_status
            CHECK (extension_status_code IS NULL
                OR extension_status_code IN (N'Pending', N'Approved', N'Rejected'));
GO

-- ---- 1d. In-flight priority REDUCTION state (BRD §7) -----------------
-- A priority INCREASE is applied immediately and leaves these NULL.
-- A priority REDUCTION parks the requested value here and applies it
-- only when the Exception Centre approves (193).
IF COL_LENGTH('grac_practice.practice_task','requested_priority') IS NULL
    ALTER TABLE grac_practice.practice_task ADD requested_priority NVARCHAR(30) NULL;
GO
IF COL_LENGTH('grac_practice.practice_task','priority_change_status_code') IS NULL
    ALTER TABLE grac_practice.practice_task ADD priority_change_status_code NVARCHAR(20) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_priority_change_status')
    ALTER TABLE grac_practice.practice_task
        ADD CONSTRAINT ck_pm_practice_task_priority_change_status
            CHECK (priority_change_status_code IS NULL
                OR priority_change_status_code IN (N'Pending', N'Approved', N'Rejected'));
GO

-- Reuse the SAME vocabulary as ck_pm_task_priority from 037.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_requested_priority')
    ALTER TABLE grac_practice.practice_task
        ADD CONSTRAINT ck_pm_practice_task_requested_priority
            CHECK (requested_priority IS NULL
                OR requested_priority IN (N'Low', N'Medium', N'High', N'Critical'));
GO

-- ---- 1e. Source reference (BRD §15, one source -> many tasks) --------
-- 037's subject_entity_type/id is the *state-machine* subject and is
-- constrained by ux_pm_practice_task_impl_dedup for Implementation
-- tasks (one open Implementation task per subject). The BRD needs a
-- reference that explicitly permits MANY tasks per source, so it gets
-- its own unconstrained pair. sp_task_open callers keep populating
-- subject_entity_*; 193 mirrors it into source_* when not supplied.
IF COL_LENGTH('grac_practice.practice_task','source_type_code') IS NULL
    ALTER TABLE grac_practice.practice_task ADD source_type_code NVARCHAR(40) NULL;
GO
IF COL_LENGTH('grac_practice.practice_task','source_record_id') IS NULL
    ALTER TABLE grac_practice.practice_task ADD source_record_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.practice_task','source_reference') IS NULL
    ALTER TABLE grac_practice.practice_task ADD source_reference NVARCHAR(200) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_source_type')
    ALTER TABLE grac_practice.practice_task
        ADD CONSTRAINT ck_pm_practice_task_source_type
            CHECK (source_type_code IS NULL
                OR source_type_code IN (N'Gap', N'Exception', N'Risk',
                                        N'ContinuousAssurance', N'EventAssurance',
                                        N'Custom'));
GO

-- ---- 1f. Owner provenance (BRD §6) -----------------------------------
-- Which rung of the resolution ladder produced assigned_to_employee_id.
-- Purely informational — the UI shows "Owner (from Practice owner)" and
-- audit can prove the system did not invent an owner.
IF COL_LENGTH('grac_practice.practice_task','owner_source_code') IS NULL
    ALTER TABLE grac_practice.practice_task ADD owner_source_code NVARCHAR(40) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_owner_source')
    ALTER TABLE grac_practice.practice_task
        ADD CONSTRAINT ck_pm_practice_task_owner_source
            CHECK (owner_source_code IS NULL
                OR owner_source_code IN (N'EXPLICIT_SOURCE', N'PRACTICE_OWNER',
                                         N'CONTROL_OWNER', N'PROCESS_OWNER',
                                         N'FUNCTION_OWNER', N'ORG_DEFAULT',
                                         N'MANUAL', N'REASSIGNED'));
GO

-- ---- 1g. Completion (BRD §10, §12) -----------------------------------
-- Recorded alongside closed_at rather than instead of it — see the
-- lifecycle conflict note in the header.
IF COL_LENGTH('grac_practice.practice_task','completed_by_employee_id') IS NULL
    ALTER TABLE grac_practice.practice_task ADD completed_by_employee_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.practice_task','completed_dt') IS NULL
    ALTER TABLE grac_practice.practice_task ADD completed_dt DATETIME2 NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = 'fk_pm_practice_task_completed_by'
      AND parent_object_id = OBJECT_ID('grac_practice.practice_task'))
    ALTER TABLE grac_practice.practice_task
        ADD CONSTRAINT fk_pm_practice_task_completed_by
            FOREIGN KEY (completed_by_employee_id)
            REFERENCES grac_practice.organization_employee(employee_id);
GO

-- =====================================================================
-- 2. task_activity — update / comment / governance trail  (BRD §16)
--
-- practice_audit_trace stays the immutable compliance log. task_activity
-- is the OPERATIONAL, user-facing feed rendered on the task detail page:
-- comments, progress updates and human-readable records of ownership,
-- priority, SLA and parent/child events.
-- =====================================================================
IF OBJECT_ID('grac_practice.task_activity','U') IS NULL
CREATE TABLE grac_practice.task_activity(
    task_activity_id     BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_task_activity PRIMARY KEY,
    task_id              BIGINT NOT NULL
        CONSTRAINT fk_pm_task_activity_task
            REFERENCES grac_practice.practice_task(task_id),

    -- Update / Comment / Reassign / PriorityChange / PriorityRequest /
    -- SlaExtensionRequest / SlaExtensionApproved / SlaExtensionRejected /
    -- ChildAdded / ChildCompleted / StatusChange / Completed
    activity_type_code   NVARCHAR(40) NOT NULL,

    remark               NVARCHAR(MAX) NULL,
    from_value           NVARCHAR(400) NULL,
    to_value             NVARCHAR(400) NULL,

    actor_employee_id    BIGINT NULL
        CONSTRAINT fk_pm_task_activity_actor
            REFERENCES grac_practice.organization_employee(employee_id),
    actor_display_name   NVARCHAR(240) NULL,

    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_task_activity_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_task_activity_entered_dt DEFAULT SYSUTCDATETIME()
);
GO

IF OBJECT_ID('grac_practice.task_activity','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ix_pm_task_activity_task'
                      AND object_id = OBJECT_ID('grac_practice.task_activity'))
    CREATE INDEX ix_pm_task_activity_task
        ON grac_practice.task_activity(task_id, entered_dt DESC)
        INCLUDE (activity_type_code, actor_display_name);
GO

-- =====================================================================
-- 3. task_attachment — evidence store  (BRD §16)
--
-- Deliberately the SAME shape as exception_request_attachment (161) and
-- document_upload_file: the fat VARBINARY column lives in its own table
-- so list queries never touch it.
-- =====================================================================
IF OBJECT_ID('grac_practice.task_attachment','U') IS NULL
CREATE TABLE grac_practice.task_attachment(
    task_attachment_id      BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_task_attachment PRIMARY KEY,
    task_id                 BIGINT NOT NULL
        CONSTRAINT fk_pm_task_attachment_task
            REFERENCES grac_practice.practice_task(task_id),
    file_name               NVARCHAR(500) NOT NULL,
    content_type            NVARCHAR(200) NULL,
    file_size_bytes         BIGINT NOT NULL
        CONSTRAINT df_pm_task_attachment_size DEFAULT 0,
    file_data               VARBINARY(MAX) NOT NULL,
    evidence_description    NVARCHAR(1000) NULL,
    uploaded_by_employee_id BIGINT NULL
        CONSTRAINT fk_pm_task_attachment_uploader
            REFERENCES grac_practice.organization_employee(employee_id),
    uploaded_dt             DATETIME2 NOT NULL
        CONSTRAINT df_pm_task_attachment_dt DEFAULT SYSUTCDATETIME()
);
GO

IF OBJECT_ID('grac_practice.task_attachment','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ix_pm_task_attachment_task'
                      AND object_id = OBJECT_ID('grac_practice.task_attachment'))
    CREATE INDEX ix_pm_task_attachment_task
        ON grac_practice.task_attachment(task_id, uploaded_dt DESC)
        INCLUDE (file_name, file_size_bytes);
GO

-- =====================================================================
-- 4. org_task_default_owner — rung 6 of the owner ladder  (BRD §6)
--
-- "Organisation default owner" is the last automatic fallback before
-- manual assignment. BRD §6 insists we REUSE existing ownership data
-- rather than build duplicate master data — rungs 1-5 all read existing
-- tables (custom_gap, practice, organization_control, practice_instance,
-- organization_business_function). Only this final rung has nowhere to
-- live today, so it gets one narrow row per organisation.
-- =====================================================================
IF OBJECT_ID('grac_practice.org_task_default_owner','U') IS NULL
CREATE TABLE grac_practice.org_task_default_owner(
    organization_id          BIGINT NOT NULL
        CONSTRAINT pk_pm_org_task_default_owner PRIMARY KEY
        CONSTRAINT fk_pm_org_task_default_owner_org
            REFERENCES grac_practice.organization(organization_id),
    default_owner_employee_id BIGINT NOT NULL
        CONSTRAINT fk_pm_org_task_default_owner_employee
            REFERENCES grac_practice.organization_employee(employee_id),
    notes                    NVARCHAR(400) NULL,
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_org_task_default_owner_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_org_task_default_owner_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL
);
GO

-- =====================================================================
-- 5. exception_request — carry TASK-linked requests  (BRD §8, §19)
--
-- BRD §19: "Reuse Exception Centre for priority reduction approvals and
-- SLA extension approvals; do not create a parallel exception mechanism."
-- So instead of a task_exception_request table we widen the existing one.
-- =====================================================================

-- ---- 5a. custom_gap_id NOT NULL -> NULL -----------------------------
--
-- ALTER COLUMN refuses to touch a column that participates in an index
-- (SQL Server error 5074, "The index 'X' is dependent on column 'Y'"),
-- and THREE indexes reference custom_gap_id today:
--
--   ix_pm_exception_request_org_status     (161)  INCLUDE(custom_gap_id, ...)
--   ix_pm_exception_request_gap            (161)  KEY(custom_gap_id, status_code)
--   ux_pm_exception_request_sla_pending    (184)  filtered UNIQUE KEY(custom_gap_id)
--
-- plus the FK. So: drop all four, alter, recreate all four — byte-for-byte
-- the definitions from 161 and 184, so nothing about the gap flow changes.
-- Guarded end to end, so a re-run after a partial failure still converges.
IF COL_LENGTH('grac_practice.exception_request','custom_gap_id') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('grac_practice.exception_request')
                  AND name = 'custom_gap_id'
                  AND is_nullable = 0)
BEGIN
    PRINT '192: making exception_request.custom_gap_id nullable (dropping dependent indexes + FK first).';

    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_exception_request_gap')
        ALTER TABLE grac_practice.exception_request
            DROP CONSTRAINT fk_pm_exception_request_gap;

    IF EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_exception_request_sla_pending'
                  AND object_id = OBJECT_ID('grac_practice.exception_request'))
        DROP INDEX ux_pm_exception_request_sla_pending ON grac_practice.exception_request;

    IF EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_exception_request_gap'
                  AND object_id = OBJECT_ID('grac_practice.exception_request'))
        DROP INDEX ix_pm_exception_request_gap ON grac_practice.exception_request;

    IF EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_exception_request_org_status'
                  AND object_id = OBJECT_ID('grac_practice.exception_request'))
        DROP INDEX ix_pm_exception_request_org_status ON grac_practice.exception_request;

    ALTER TABLE grac_practice.exception_request
        ALTER COLUMN custom_gap_id BIGINT NULL;
END
GO

-- Recreate exactly what 161 and 184 created. These IF NOT EXISTS guards
-- also mean this block is a no-op when custom_gap_id was already nullable.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_exception_request_org_status'
                  AND object_id = OBJECT_ID('grac_practice.exception_request'))
    CREATE INDEX ix_pm_exception_request_org_status
        ON grac_practice.exception_request(organization_id, status_code, requested_dt DESC)
        INCLUDE(custom_gap_id, request_title);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_exception_request_gap'
                  AND object_id = OBJECT_ID('grac_practice.exception_request'))
    CREATE INDEX ix_pm_exception_request_gap
        ON grac_practice.exception_request(custom_gap_id, status_code);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_exception_request_sla_pending'
                  AND object_id = OBJECT_ID('grac_practice.exception_request'))
    CREATE UNIQUE INDEX ux_pm_exception_request_sla_pending
        ON grac_practice.exception_request(custom_gap_id)
        WHERE status_code = N'Pending' AND request_type_code = N'SLA_CANDIDATE';
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_exception_request_gap')
    ALTER TABLE grac_practice.exception_request
        ADD CONSTRAINT fk_pm_exception_request_gap
            FOREIGN KEY (custom_gap_id)
            REFERENCES grac_practice.custom_gap(custom_gap_id);
GO

-- ---- 5b. task_id + priority payload ---------------------------------
IF COL_LENGTH('grac_practice.exception_request','task_id') IS NULL
    ALTER TABLE grac_practice.exception_request ADD task_id BIGINT NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = 'fk_pm_exception_request_task'
      AND parent_object_id = OBJECT_ID('grac_practice.exception_request'))
    ALTER TABLE grac_practice.exception_request
        ADD CONSTRAINT fk_pm_exception_request_task
            FOREIGN KEY (task_id)
            REFERENCES grac_practice.practice_task(task_id);
GO

-- The gap SLA flow (184) stores its payload in sla_days_original /
-- sla_days_requested. Task SLA extensions reuse those two columns AND
-- add absolute dates, because the BRD captures a "Requested Due Date"
-- rather than a day count (§8, §17).
IF COL_LENGTH('grac_practice.exception_request','due_at_original') IS NULL
    ALTER TABLE grac_practice.exception_request ADD due_at_original DATETIME2 NULL;
GO
IF COL_LENGTH('grac_practice.exception_request','due_at_requested') IS NULL
    ALTER TABLE grac_practice.exception_request ADD due_at_requested DATETIME2 NULL;
GO
IF COL_LENGTH('grac_practice.exception_request','priority_original') IS NULL
    ALTER TABLE grac_practice.exception_request ADD priority_original NVARCHAR(30) NULL;
GO
IF COL_LENGTH('grac_practice.exception_request','priority_requested') IS NULL
    ALTER TABLE grac_practice.exception_request ADD priority_requested NVARCHAR(30) NULL;
GO

-- ---- 5c. Widen request_type_code ------------------------------------
-- 184 seeded GAP_CANDIDATE / SLA_CANDIDATE. Two task-side types join:
--   TASK_SLA_EXTENSION      — BRD §8
--   TASK_PRIORITY_REDUCTION — BRD §7
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_exception_request_type')
    ALTER TABLE grac_practice.exception_request
        DROP CONSTRAINT ck_pm_exception_request_type;
GO

ALTER TABLE grac_practice.exception_request
    ADD CONSTRAINT ck_pm_exception_request_type
        CHECK (request_type_code IN (N'GAP_CANDIDATE', N'SLA_CANDIDATE',
                                     N'TASK_SLA_EXTENSION', N'TASK_PRIORITY_REDUCTION'));
GO

-- ---- 5d. A request must hang off something --------------------------
-- WITH NOCHECK would hide bad legacy rows; every pre-192 row has a gap
-- id by construction so a checked constraint is safe.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_exception_request_subject')
    ALTER TABLE grac_practice.exception_request
        ADD CONSTRAINT ck_pm_exception_request_subject
            CHECK (custom_gap_id IS NOT NULL OR task_id IS NOT NULL);
GO

-- ---- 5e. One Pending request of each task type, per task ------------
-- Mirrors ux_pm_exception_request_sla_pending from 184.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_exception_request_task_sla_pending'
                  AND object_id = OBJECT_ID('grac_practice.exception_request'))
    CREATE UNIQUE INDEX ux_pm_exception_request_task_sla_pending
        ON grac_practice.exception_request(task_id)
        WHERE status_code = N'Pending'
          AND request_type_code = N'TASK_SLA_EXTENSION'
          AND task_id IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_exception_request_task_prio_pending'
                  AND object_id = OBJECT_ID('grac_practice.exception_request'))
    CREATE UNIQUE INDEX ux_pm_exception_request_task_prio_pending
        ON grac_practice.exception_request(task_id)
        WHERE status_code = N'Pending'
          AND request_type_code = N'TASK_PRIORITY_REDUCTION'
          AND task_id IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_exception_request_task'
                  AND object_id = OBJECT_ID('grac_practice.exception_request'))
    CREATE INDEX ix_pm_exception_request_task
        ON grac_practice.exception_request(task_id, status_code)
        WHERE task_id IS NOT NULL;
GO

-- =====================================================================
-- 6. practice_task indexes for the new access paths
-- =====================================================================

-- Children of a parent (task detail child list, parent completion check).
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_practice_task_parent'
                  AND object_id = OBJECT_ID('grac_practice.practice_task'))
    CREATE INDEX ix_pm_practice_task_parent
        ON grac_practice.practice_task(parent_task_id)
        INCLUDE (current_status_id, is_mandatory_child, assigned_to_employee_id,
                 subject_title, closed_at)
        WHERE parent_task_id IS NOT NULL;
GO

-- Source -> Tasks navigation (BRD §15).
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_practice_task_source'
                  AND object_id = OBJECT_ID('grac_practice.practice_task'))
    CREATE INDEX ix_pm_practice_task_source
        ON grac_practice.practice_task(source_type_code, source_record_id)
        INCLUDE (organization_id, current_status_id, subject_title, task_number)
        WHERE source_type_code IS NOT NULL;
GO

-- SLA monitoring sweep over the EFFECTIVE due date, restricted to open
-- work. 037 already indexes sla_due_at; this one carries the extension
-- columns so the sweep never has to look up the base table.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_practice_task_sla_monitor'
                  AND object_id = OBJECT_ID('grac_practice.practice_task'))
    CREATE INDEX ix_pm_practice_task_sla_monitor
        ON grac_practice.practice_task(organization_id, sla_due_at)
        INCLUDE (task_id, standard_due_at, approved_extended_due_at,
                 extension_status_code, priority, assigned_to_employee_id,
                 current_status_id)
        WHERE closed_at IS NULL;
GO

-- =====================================================================
-- 7. Backfill — existing tasks must remain usable  (BRD §19)
--
-- Every pre-192 task keeps its sla_due_at. We simply MIRROR it into
-- standard_due_at so the new read layer, SLA status derivation and the
-- extension flow have a baseline to work from. Nothing is recomputed:
-- re-deriving historical SLAs from today's org config would silently
-- move existing due dates, which BRD §19 forbids.
-- =====================================================================
UPDATE grac_practice.practice_task
   SET standard_due_at  = sla_due_at,
       sla_source_code  = N'TYPE_DEFAULT'
 WHERE standard_due_at IS NULL
   AND sla_due_at IS NOT NULL;
GO

-- Source reference mirrors the state-machine subject for existing rows,
-- translating the internal subject_entity_type vocabulary into the BRD's.
UPDATE t
   SET t.source_type_code = CASE t.subject_entity_type
                                WHEN N'CustomGap' THEN N'Gap'
                                ELSE N'Custom'
                            END,
       t.source_record_id = t.subject_entity_id
  FROM grac_practice.practice_task t
 WHERE t.source_type_code IS NULL;
GO

-- Closed tasks predate completed_dt; align it with closed_at so
-- completion reporting is not full of holes.
UPDATE grac_practice.practice_task
   SET completed_dt = closed_at
 WHERE completed_dt IS NULL
   AND closed_at IS NOT NULL;
GO

-- =====================================================================
-- 8. Sanity
-- =====================================================================
SELECT 'practice_task v2 columns' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_task','parent_task_id')           IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','is_mandatory_child')        IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','standard_sla_days')         IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','standard_due_at')           IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','approved_extended_due_at')  IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','extension_status_code')     IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','requested_priority')        IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','source_type_code')          IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','owner_source_code')         IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','completed_dt')              IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'task_activity / task_attachment / org_task_default_owner' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.task_activity','U')          IS NOT NULL
             AND OBJECT_ID('grac_practice.task_attachment','U')         IS NOT NULL
             AND OBJECT_ID('grac_practice.org_task_default_owner','U')  IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'exception_request task-aware' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.exception_request','task_id') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.exception_request')
                            AND name = 'custom_gap_id' AND is_nullable = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'backfill: tasks with a standard_due_at' AS Check_,
       COUNT(*) AS Rows_
  FROM grac_practice.practice_task
 WHERE standard_due_at IS NOT NULL;

PRINT '192 Task Centre v2 schema installed. Next: 193_task_centre_v2_procs.sql';
GO

SET NOEXEC OFF;
GO
