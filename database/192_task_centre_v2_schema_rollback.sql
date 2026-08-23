-- =====================================================================
-- 192 Task Centre v2 — schema ROLLBACK
--
-- Reverses 192_task_centre_v2_schema.sql. Idempotent: every step is
-- guarded, so a partial forward run rolls back cleanly.
--
-- ORDER MATTERS
--   1. Drop the procs that read the v2 surface (193/194/195) — their own
--      rollbacks do this, but we guard here too so 192's rollback can be
--      run standalone without leaving procs bound to dropped columns.
--   2. Drop indexes / constraints that reference the new columns.
--   3. Drop the new columns.
--   4. Drop the new tables (children before parents).
--   5. Restore exception_request.custom_gap_id to NOT NULL — ONLY if no
--      task-linked rows exist, otherwise we would destroy data. When
--      task-linked rows are present the script PRINTs and leaves the
--      column nullable; delete those rows first if you truly need the
--      pre-192 shape back.
--
-- DATA LOSS WARNING: task_activity and task_attachment are DROPPED.
-- Everything else is additive metadata; the underlying practice_task
-- rows, their sla_due_at and their lifecycle state are untouched.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '192-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Drop v2 procedures (defensive — 193/194/195 rollbacks own these)
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_task_source_tasks','P')             IS NOT NULL DROP PROCEDURE grac_practice.sp_task_source_tasks;
IF OBJECT_ID('grac_practice.sp_task_get','P')                      IS NOT NULL DROP PROCEDURE grac_practice.sp_task_get;
IF OBJECT_ID('grac_practice.sp_task_complete','P')                 IS NOT NULL DROP PROCEDURE grac_practice.sp_task_complete;
IF OBJECT_ID('grac_practice.sp_task_completion_eligibility','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_task_completion_eligibility;
IF OBJECT_ID('grac_practice.sp_task_child_create','P')             IS NOT NULL DROP PROCEDURE grac_practice.sp_task_child_create;
IF OBJECT_ID('grac_practice.sp_task_sla_extension_approve','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_task_sla_extension_approve;
IF OBJECT_ID('grac_practice.sp_task_sla_extension_request_create','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_task_sla_extension_request_create;
IF OBJECT_ID('grac_practice.sp_task_priority_reduction_approve','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_task_priority_reduction_approve;
IF OBJECT_ID('grac_practice.sp_task_priority_change','P')          IS NOT NULL DROP PROCEDURE grac_practice.sp_task_priority_change;
IF OBJECT_ID('grac_practice.sp_task_attachment_get','P')           IS NOT NULL DROP PROCEDURE grac_practice.sp_task_attachment_get;
IF OBJECT_ID('grac_practice.sp_task_attachment_add','P')           IS NOT NULL DROP PROCEDURE grac_practice.sp_task_attachment_add;
IF OBJECT_ID('grac_practice.sp_task_activity_add','P')             IS NOT NULL DROP PROCEDURE grac_practice.sp_task_activity_add;
IF OBJECT_ID('grac_practice.sp_task_apply_sla','P')                IS NOT NULL DROP PROCEDURE grac_practice.sp_task_apply_sla;
IF OBJECT_ID('grac_practice.sp_org_sla_match_for_priority','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_org_sla_match_for_priority;
IF OBJECT_ID('grac_practice.sp_task_owner_resolve','P')            IS NOT NULL DROP PROCEDURE grac_practice.sp_task_owner_resolve;
IF OBJECT_ID('grac_practice.fn_task_employee_by_name','FN')        IS NOT NULL DROP FUNCTION  grac_practice.fn_task_employee_by_name;
GO

-- The read layer rebuilt this view over v2 columns; drop it so the
-- column drops below cannot fail on a schema-bound-ish dependency and
-- so 048_task_model_procs.sql can rebuild the pre-192 shape.
IF OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NOT NULL
    DROP VIEW grac_practice.vw_pm_practice_task;
GO

-- ---------------------------------------------------------------------
-- 2. exception_request — indexes, constraints, columns
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ux_pm_exception_request_task_sla_pending'
              AND object_id = OBJECT_ID('grac_practice.exception_request'))
    DROP INDEX ux_pm_exception_request_task_sla_pending ON grac_practice.exception_request;

IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ux_pm_exception_request_task_prio_pending'
              AND object_id = OBJECT_ID('grac_practice.exception_request'))
    DROP INDEX ux_pm_exception_request_task_prio_pending ON grac_practice.exception_request;

IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ix_pm_exception_request_task'
              AND object_id = OBJECT_ID('grac_practice.exception_request'))
    DROP INDEX ix_pm_exception_request_task ON grac_practice.exception_request;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_exception_request_subject')
    ALTER TABLE grac_practice.exception_request DROP CONSTRAINT ck_pm_exception_request_subject;
GO

-- Restore the 184 request-type vocabulary.
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_exception_request_type')
    ALTER TABLE grac_practice.exception_request DROP CONSTRAINT ck_pm_exception_request_type;
GO

-- Task-typed rows would violate the restored CHECK; remove them first.
IF OBJECT_ID('grac_practice.exception_request','U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM grac_practice.exception_request
                WHERE request_type_code IN (N'TASK_SLA_EXTENSION', N'TASK_PRIORITY_REDUCTION'))
BEGIN
    PRINT '192-rollback: deleting task-linked exception requests (history first).';

    DELETE h
      FROM grac_practice.exception_request_history h
      JOIN grac_practice.exception_request r
        ON r.exception_request_id = h.exception_request_id
     WHERE r.request_type_code IN (N'TASK_SLA_EXTENSION', N'TASK_PRIORITY_REDUCTION');

    DELETE a
      FROM grac_practice.exception_request_attachment a
      JOIN grac_practice.exception_request r
        ON r.exception_request_id = a.exception_request_id
     WHERE r.request_type_code IN (N'TASK_SLA_EXTENSION', N'TASK_PRIORITY_REDUCTION');

    DELETE FROM grac_practice.exception_request
     WHERE request_type_code IN (N'TASK_SLA_EXTENSION', N'TASK_PRIORITY_REDUCTION');
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_exception_request_type')
    ALTER TABLE grac_practice.exception_request
        ADD CONSTRAINT ck_pm_exception_request_type
            CHECK (request_type_code IN (N'GAP_CANDIDATE', N'SLA_CANDIDATE'));
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys
            WHERE name = 'fk_pm_exception_request_task'
              AND parent_object_id = OBJECT_ID('grac_practice.exception_request'))
    ALTER TABLE grac_practice.exception_request DROP CONSTRAINT fk_pm_exception_request_task;
GO

IF COL_LENGTH('grac_practice.exception_request','task_id')            IS NOT NULL ALTER TABLE grac_practice.exception_request DROP COLUMN task_id;
IF COL_LENGTH('grac_practice.exception_request','due_at_original')    IS NOT NULL ALTER TABLE grac_practice.exception_request DROP COLUMN due_at_original;
IF COL_LENGTH('grac_practice.exception_request','due_at_requested')   IS NOT NULL ALTER TABLE grac_practice.exception_request DROP COLUMN due_at_requested;
IF COL_LENGTH('grac_practice.exception_request','priority_original')  IS NOT NULL ALTER TABLE grac_practice.exception_request DROP COLUMN priority_original;
IF COL_LENGTH('grac_practice.exception_request','priority_requested') IS NOT NULL ALTER TABLE grac_practice.exception_request DROP COLUMN priority_requested;
GO

-- Restore NOT NULL only when it is safe.
--
-- Same index dependency as the forward script: ALTER COLUMN cannot touch
-- a column that participates in an index (error 5074), so the three
-- indexes on custom_gap_id come off and go back on around the alter.
IF EXISTS (SELECT 1 FROM grac_practice.exception_request WHERE custom_gap_id IS NULL)
    PRINT '192-rollback: exception_request rows with NULL custom_gap_id exist; leaving the column NULLABLE. Remove those rows and re-run to fully restore the pre-192 shape.';
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_exception_request_gap')
        ALTER TABLE grac_practice.exception_request DROP CONSTRAINT fk_pm_exception_request_gap;

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
        ALTER COLUMN custom_gap_id BIGINT NOT NULL;

    CREATE INDEX ix_pm_exception_request_org_status
        ON grac_practice.exception_request(organization_id, status_code, requested_dt DESC)
        INCLUDE(custom_gap_id, request_title);

    CREATE INDEX ix_pm_exception_request_gap
        ON grac_practice.exception_request(custom_gap_id, status_code);

    CREATE UNIQUE INDEX ux_pm_exception_request_sla_pending
        ON grac_practice.exception_request(custom_gap_id)
        WHERE status_code = N'Pending' AND request_type_code = N'SLA_CANDIDATE';

    ALTER TABLE grac_practice.exception_request
        ADD CONSTRAINT fk_pm_exception_request_gap
            FOREIGN KEY (custom_gap_id)
            REFERENCES grac_practice.custom_gap(custom_gap_id);
END
GO

-- ---------------------------------------------------------------------
-- 3. Drop the new tables (task_attachment / task_activity reference
--    practice_task, so they go before the practice_task column drops)
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.task_attachment','U')        IS NOT NULL DROP TABLE grac_practice.task_attachment;
IF OBJECT_ID('grac_practice.task_activity','U')          IS NOT NULL DROP TABLE grac_practice.task_activity;
IF OBJECT_ID('grac_practice.org_task_default_owner','U') IS NOT NULL DROP TABLE grac_practice.org_task_default_owner;
GO

-- ---------------------------------------------------------------------
-- 4. practice_task — indexes, constraints, columns
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_parent'      AND object_id = OBJECT_ID('grac_practice.practice_task'))
    DROP INDEX ix_pm_practice_task_parent ON grac_practice.practice_task;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_source'      AND object_id = OBJECT_ID('grac_practice.practice_task'))
    DROP INDEX ix_pm_practice_task_source ON grac_practice.practice_task;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_sla_monitor' AND object_id = OBJECT_ID('grac_practice.practice_task'))
    DROP INDEX ix_pm_practice_task_sla_monitor ON grac_practice.practice_task;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_parent_not_self')        ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_parent_not_self;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_sla_source')             ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_sla_source;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_extension_status')       ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_extension_status;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_priority_change_status') ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_priority_change_status;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_requested_priority')     ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_requested_priority;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_source_type')            ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_source_type;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_owner_source')           ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_owner_source;
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_practice_task_parent'       AND parent_object_id = OBJECT_ID('grac_practice.practice_task'))
    ALTER TABLE grac_practice.practice_task DROP CONSTRAINT fk_pm_practice_task_parent;
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_practice_task_completed_by' AND parent_object_id = OBJECT_ID('grac_practice.practice_task'))
    ALTER TABLE grac_practice.practice_task DROP CONSTRAINT fk_pm_practice_task_completed_by;
GO

IF COL_LENGTH('grac_practice.practice_task','parent_task_id')              IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN parent_task_id;
IF COL_LENGTH('grac_practice.practice_task','is_mandatory_child')          IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN is_mandatory_child;
IF COL_LENGTH('grac_practice.practice_task','child_target_date')           IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN child_target_date;
IF COL_LENGTH('grac_practice.practice_task','standard_sla_days')           IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN standard_sla_days;
IF COL_LENGTH('grac_practice.practice_task','standard_due_at')             IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN standard_due_at;
IF COL_LENGTH('grac_practice.practice_task','approved_extended_due_at')    IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN approved_extended_due_at;
IF COL_LENGTH('grac_practice.practice_task','sla_source_code')             IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN sla_source_code;
IF COL_LENGTH('grac_practice.practice_task','sla_master_id')               IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN sla_master_id;
IF COL_LENGTH('grac_practice.practice_task','sla_master_name')             IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN sla_master_name;
IF COL_LENGTH('grac_practice.practice_task','extension_status_code')       IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN extension_status_code;
IF COL_LENGTH('grac_practice.practice_task','requested_due_at')            IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN requested_due_at;
IF COL_LENGTH('grac_practice.practice_task','extension_reason')            IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN extension_reason;
IF COL_LENGTH('grac_practice.practice_task','requested_priority')          IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN requested_priority;
IF COL_LENGTH('grac_practice.practice_task','priority_change_status_code') IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN priority_change_status_code;
IF COL_LENGTH('grac_practice.practice_task','source_type_code')            IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN source_type_code;
IF COL_LENGTH('grac_practice.practice_task','source_record_id')            IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN source_record_id;
IF COL_LENGTH('grac_practice.practice_task','source_reference')            IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN source_reference;
IF COL_LENGTH('grac_practice.practice_task','owner_source_code')           IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN owner_source_code;
IF COL_LENGTH('grac_practice.practice_task','completed_by_employee_id')    IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN completed_by_employee_id;
IF COL_LENGTH('grac_practice.practice_task','completed_dt')                IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN completed_dt;
GO

PRINT '192 Task Centre v2 schema rolled back.';
PRINT 'IMPORTANT: re-run 048_task_model_procs.sql to restore the pre-192 vw_pm_practice_task,';
PRINT '           and 184_gap_sla_match_and_override.sql to restore sp_exception_request_reject / _list.';
GO

SET NOEXEC OFF;
GO
