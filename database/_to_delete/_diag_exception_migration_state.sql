-- =====================================================================
-- _diag_exception_migration_state.sql
--
-- READ-ONLY. Changes nothing. Run it on any database (production, UAT,
-- demo) to see whether that database is far enough along for migration
-- 498, and whether 498's four procedures are actually the 498 bodies.
--
-- Why it exists: a re-issued procedure body is validated against the
-- live columns at CREATE time, so one missing column fails that single
-- CREATE with Msg 207 and leaves the OLD body deployed, while the rest
-- of the migration carries on and prints its success. The run reads as
-- complete and is not. This script tells you before and after.
--
-- ASCII only.
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT '=== 1. exception_request columns that 498 reads ===';

SELECT x.mig              AS owning_migration,
       x.col              AS column_name,
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns c
                          WHERE c.object_id = OBJECT_ID('grac_practice.exception_request')
                            AND c.name = x.col)
            THEN 'present' ELSE 'MISSING -- run migration ' + x.mig END AS state
FROM (VALUES
    (N'exception_type_id',        N'166'), (N'owner_employee_id',        N'166'),
    (N'review_frequency_id',      N'166'), (N'justification',            N'166'),
    (N'risk_impact',              N'166'), (N'compensating_control',      N'166'),
    (N'effective_from',           N'166'), (N'linked_practice_id',        N'166'),
    (N'linked_requirement_ref',   N'166'),
    (N'request_type_code',        N'184'), (N'sla_days_original',         N'184'),
    (N'sla_days_requested',       N'184'),
    (N'task_id',                  N'192'), (N'due_at_original',           N'192'),
    (N'due_at_requested',         N'192'), (N'priority_original',         N'192'),
    (N'priority_requested',       N'192'),
    (N'proposed_effective_from',  N'260'), (N'proposed_effective_until',  N'260'),
    (N'exception_number',         N'470'),
    (N'designated_approver_employee_id', N'498')
) AS x(col, mig)
ORDER BY x.mig, x.col;

PRINT '=== 2. the four procedures 498 owns, and whether the 498 body is deployed ===';

SELECT p.name AS procedure_name,
       CASE WHEN OBJECT_ID('grac_practice.' + p.name, 'P') IS NULL THEN 'MISSING'
            WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.' + p.name)) LIKE '%designated_approver_employee_id%'
                 THEN 'has the 498 body'
            ELSE 'OLD BODY -- 498 did not take on this one' END AS state
FROM (VALUES (N'sp_exception_approver_candidates'),
             (N'sp_exception_request_submit_for_approval'),
             (N'sp_exception_request_list'),
             (N'sp_exception_request_get')) AS p(name);

PRINT '=== 3. does the list procedure project ExceptionNumber (470/472)? ===';

SELECT CASE WHEN OBJECT_ID('grac_practice.sp_exception_request_list','P') IS NULL THEN 'procedure MISSING'
            WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_exception_request_list')) LIKE '%ExceptionNumber%'
                 THEN 'yes'
            ELSE 'no -- 472 and/or 498 did not take' END AS exception_number_projected,
       CASE WHEN OBJECT_ID('grac_practice.sp_exception_request_list','P') IS NULL THEN NULL
            WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_exception_request_list')) LIKE '%DesignatedApproverName%'
                 THEN 'yes'
            ELSE 'no -- the Approve option cannot be scoped to the designated approver' END AS designated_approver_projected;

PRINT '=== 4. the FK 498 adds ===';

SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.foreign_keys
                          WHERE name = 'fk_pm_exception_request_designated_approver')
            THEN 'present' ELSE 'missing' END AS fk_designated_approver;

PRINT '=== 5. informational: the same trap on the gap side ===';
-- 469 adds custom_gap.gap_number and 471 projects it. Not used by 498;
-- listed because a database behind on 470 is often behind on 469 too,
-- and the failure looks identical.
SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.custom_gap') AND name = 'gap_number')
            THEN 'present' ELSE 'MISSING -- run migration 469' END AS custom_gap_gap_number,
       CASE WHEN OBJECT_ID('grac_practice.sp_gap_centre_list','P') IS NULL THEN 'procedure missing'
            WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_gap_centre_list')) LIKE '%GapNumber%'
                 THEN 'yes' ELSE 'no -- run 471' END AS gap_number_projected;

PRINT '=== 6. verdict ===';

DECLARE @missing INT;
SELECT @missing = COUNT(*)
FROM (VALUES (N'exception_type_id'),(N'owner_employee_id'),(N'review_frequency_id'),
             (N'justification'),(N'risk_impact'),(N'compensating_control'),
             (N'effective_from'),(N'linked_practice_id'),(N'linked_requirement_ref'),
             (N'request_type_code'),(N'sla_days_original'),(N'sla_days_requested'),
             (N'task_id'),(N'due_at_original'),(N'due_at_requested'),
             (N'priority_original'),(N'priority_requested'),
             (N'proposed_effective_from'),(N'proposed_effective_until'),
             (N'exception_number')) AS x(col)
WHERE NOT EXISTS (SELECT 1 FROM sys.columns c
                   WHERE c.object_id = OBJECT_ID('grac_practice.exception_request')
                     AND c.name = x.col);

IF @missing = 0
    PRINT 'OK: every column 498 reads is present. 498 can run (or re-run) safely.';
ELSE
    PRINT CONCAT('NOT READY: ', @missing,
                 ' column(s) missing -- see section 1 for which migration owns each. Run those first, then 498.');
GO
