/*
  =====================================================================
  Task Centre v2 (192-196) — PREFLIGHT

  Run this BEFORE 192. It answers one question: which script do I have
  to run next?

  WHY THIS EXISTS
  ---------------
  Each migration opens with a prerequisite guard that PRINTs, RAISERRORs
  and sets NOEXEC ON. That correctly prevents anything from being
  created — but it CANNOT silence the errors that follow.

  `SET NOEXEC ON` stops execution, not compilation. SQL Server defers
  name resolution for missing TABLES, which is why the pattern works in
  037/048 — but it does NOT defer resolution for a missing COLUMN on a
  table that already exists. So running 195 before 192 produces a wall of
  "Msg 207 ... Invalid column name 'parent_task_id'" as the batch parser
  binds each CREATE OR ALTER PROCEDURE against the un-migrated
  practice_task.

  Those errors are noise, not damage: NOEXEC means nothing was created
  and nothing was altered. But a wall of red is a bad way to learn you
  ran the wrong file, hence this script.

  Read-only. Safe anywhere, any number of times.

  Docs: docs/task-centre-v2.md
  =====================================================================
*/
SET NOCOUNT ON;

PRINT '=== Task Centre v2 preflight ===';
PRINT '';

-- ---------------------------------------------------------------------
-- 1. Upstream prerequisites — what 192 itself demands
-- ---------------------------------------------------------------------
DECLARE @prereq TABLE (
    Ord         INT,
    Requirement NVARCHAR(80),
    Detail      NVARCHAR(200),
    Present     BIT,
    FixByRunning NVARCHAR(120)
);

INSERT INTO @prereq (Ord, Requirement, Detail, Present, FixByRunning) VALUES
 (1, N'schema grac_practice',
     N'SCHEMA_ID(''grac_practice'')',
     CASE WHEN SCHEMA_ID('grac_practice') IS NOT NULL THEN 1 ELSE 0 END,
     N'001_practice_management_schema.sql'),

 (2, N'organization_employee',
     N'employee master for the owner ladder',
     CASE WHEN OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL THEN 1 ELSE 0 END,
     N'009_practice_employee_master.sql'),

 (3, N'state machine framework',
     N'entity_status_master + fn_get_entity_status_id',
     CASE WHEN OBJECT_ID('grac_practice.entity_status_master','U') IS NOT NULL
           AND OBJECT_ID('grac_practice.fn_get_entity_status_id','FN') IS NOT NULL THEN 1 ELSE 0 END,
     N'035_state_machine_framework.sql'),

 (4, N'task engine',
     N'practice_task + task_type_master + sp_task_open',
     CASE WHEN OBJECT_ID('grac_practice.practice_task','U')   IS NOT NULL
           AND OBJECT_ID('grac_practice.task_type_master','U') IS NOT NULL
           AND OBJECT_ID('grac_practice.sp_task_open','P')     IS NOT NULL THEN 1 ELSE 0 END,
     N'037_task_engine.sql + 037_task_engine_procs.sql'),

 (5, N'task model extension',
     N'practice_task.related_entity_type_id (048)',
     CASE WHEN COL_LENGTH('grac_practice.practice_task','related_entity_type_id') IS NOT NULL THEN 1 ELSE 0 END,
     N'048_task_model_extension.sql + 048_task_model_procs.sql'),

 (6, N'custom gap',
     N'custom_gap — the FK target for exception_request',
     CASE WHEN OBJECT_ID('grac_practice.custom_gap','U') IS NOT NULL THEN 1 ELSE 0 END,
     N'054_custom_gap_schema.sql'),

 (7, N'Exception Centre',
     N'exception_request + _history',
     CASE WHEN OBJECT_ID('grac_practice.exception_request','U')         IS NOT NULL
           AND OBJECT_ID('grac_practice.exception_request_history','U')  IS NOT NULL THEN 1 ELSE 0 END,
     N'161_exception_centre_schema.sql + 162_exception_centre_procs.sql'),

 (8, N'Exception request typing',
     N'exception_request.request_type_code (184)',
     CASE WHEN COL_LENGTH('grac_practice.exception_request','request_type_code') IS NOT NULL THEN 1 ELSE 0 END,
     N'184_gap_sla_match_and_override.sql'),

 (9, N'Org SLA configuration',
     N'org_sla_config + sp_org_sla_match_for_severity',
     CASE WHEN OBJECT_ID('grac_practice.org_sla_config','U')                 IS NOT NULL
           AND OBJECT_ID('grac_practice.sp_org_sla_match_for_severity','P')  IS NOT NULL THEN 1 ELSE 0 END,
     N'178/179 + 184 (SLA policy — see note below)'),

 (10, N'record_status_master',
      N'used when raising exception requests',
      CASE WHEN OBJECT_ID('grac_practice.record_status_master','U') IS NOT NULL THEN 1 ELSE 0 END,
      N'008_normalize_practice_status_master.sql');

SELECT Ord                                          AS [#],
       Requirement,
       Detail,
       CASE WHEN Present = 1 THEN 'PRESENT' ELSE '** MISSING **' END AS Status,
       CASE WHEN Present = 1 THEN '' ELSE FixByRunning END           AS RunThisFirst
  FROM @prereq
 ORDER BY Ord;

-- Requirement 9 is the only soft one: without an SLA policy the task
-- engine still works, it just falls back to task_type_master
-- .default_sla_hours and stamps sla_source_code = 'TYPE_DEFAULT'.
IF EXISTS (SELECT 1 FROM @prereq WHERE Ord = 9 AND Present = 0)
    PRINT 'NOTE: Org SLA configuration is missing. 192-196 will still install and run; every task will simply fall back to the task-type default SLA (sla_source_code = ''TYPE_DEFAULT'') until an SLA master is configured.';

-- ---------------------------------------------------------------------
-- 2. Which Task Centre v2 migrations have already landed?
-- ---------------------------------------------------------------------
PRINT '';
PRINT '=== Task Centre v2 migration state ===';

SELECT 192 AS Migration, N'schema (columns, task_activity, task_attachment, exception_request)' AS Contents,
       CASE WHEN COL_LENGTH('grac_practice.practice_task','standard_due_at') IS NOT NULL
                 AND OBJECT_ID('grac_practice.task_activity','U')            IS NOT NULL
                 AND OBJECT_ID('grac_practice.task_attachment','U')          IS NOT NULL
                 AND COL_LENGTH('grac_practice.exception_request','task_id') IS NOT NULL
            THEN 'APPLIED'
            WHEN COL_LENGTH('grac_practice.practice_task','standard_due_at') IS NOT NULL
              OR OBJECT_ID('grac_practice.task_activity','U')                IS NOT NULL
            THEN '** PARTIAL — re-run 192, it is idempotent **'
            ELSE 'not applied' END AS State
UNION ALL
SELECT 193, N'owner ladder, SLA derivation, priority governance',
       CASE WHEN OBJECT_ID('grac_practice.sp_task_owner_resolve','P')   IS NOT NULL
                 AND OBJECT_ID('grac_practice.sp_task_apply_sla','P')    IS NOT NULL
                 AND OBJECT_ID('grac_practice.sp_task_priority_change','P') IS NOT NULL
            THEN 'APPLIED' ELSE 'not applied' END
UNION ALL
SELECT 194, N'SLA extension, parent/child, completion',
       CASE WHEN OBJECT_ID('grac_practice.sp_task_child_create','P') IS NOT NULL
                 AND OBJECT_ID('grac_practice.sp_task_complete','P')  IS NOT NULL
            THEN 'APPLIED' ELSE 'not applied' END
UNION ALL
SELECT 195, N'view refresh, sp_task_list v2, sp_task_get, source tasks',
       CASE WHEN OBJECT_ID('grac_practice.sp_task_get','P') IS NOT NULL
                 AND EXISTS (SELECT 1 FROM sys.columns
                              WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task')
                                AND name = 'sla_status_code')
            THEN 'APPLIED' ELSE 'not applied' END
UNION ALL
SELECT 196, N'sp_task_open v3 (owner + SLA at creation)',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_task_open')
                            AND name = '@resolve_owner')
            THEN 'APPLIED' ELSE 'not applied' END
ORDER BY Migration;

-- ---------------------------------------------------------------------
-- 3. Verdict
-- ---------------------------------------------------------------------
PRINT '';
DECLARE @missing INT = (SELECT COUNT(*) FROM @prereq WHERE Present = 0 AND Ord <> 9);

IF @missing > 0
BEGIN
    PRINT '*** DO NOT RUN 192-196 YET. ***';
    PRINT 'Run the scripts listed in the RunThisFirst column above, then re-run this preflight.';
END
ELSE
BEGIN
    PRINT 'Prerequisites satisfied. Apply in this order:';
    PRINT '    192_task_centre_v2_schema.sql';
    PRINT '    193_task_centre_v2_procs.sql';
    PRINT '    194_task_centre_v2_parent_child.sql';
    PRINT '    195_task_centre_v2_read.sql';
    PRINT '    196_task_centre_v2_open.sql';
    PRINT '';
    PRINT 'Then verify with deployment/12_UAT_Diagnostics_TaskCentreV2.sql.';
    PRINT 'Roll back in reverse, starting with 195 (its rollback restores the pre-192 view';
    PRINT 'and list proc, which is what lets 192''s column drops succeed).';
END
GO
