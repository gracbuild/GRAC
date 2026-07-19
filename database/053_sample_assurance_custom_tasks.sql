-- =====================================================================
-- 053 Sample Assurance + Custom tasks for demo / UI QA
--
-- Seeds 6 Assurance tasks and 6 Custom tasks for the first active
-- organisation, rotating across the first three active employees of
-- that org. Uses sp_task_open (which enforces the state machine and
-- SLA rules) then sp_task_transition to spread across statuses so the
-- Task Center grid, filters, and 3-dot menu can be QA'd end-to-end.
--
-- Design notes:
--   * task_type_master rows 'Assurance' and 'Custom' were added by
--     migration 048 -- prerequisite guard checks for them.
--   * Sample rows are marked with correlation_id ending in
--     '-SAMPLE-053-' so a rollback can find + delete them cleanly.
--   * If the target org or employee count is insufficient we skip
--     (no error), so the migration is safe to run in any environment.
--   * ASCII-only, no CTE-then-MERGE constructs (see notes on 050).
--
-- Rollback: database/053_sample_assurance_custom_tasks_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisite guard.
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (053): schema grac_practice missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
   OR OBJECT_ID('grac_practice.task_type_master','U') IS NULL
BEGIN
    PRINT 'ABORT (053): practice_task or task_type_master missing (run 037 + 048 first).';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.sp_task_open','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_transition','P') IS NULL
BEGIN
    PRINT 'ABORT (053): sp_task_open / sp_task_transition missing.';
    SET @prereqs_ok = 0;
END

IF NOT EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'Assurance' AND is_active = 1)
   OR NOT EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'Custom' AND is_active = 1)
BEGIN
    PRINT 'ABORT (053): task_type_master needs Assurance + Custom rows (run 048 first).';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('053_sample_assurance_custom_tasks: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- Pick target organization + first three employees.
-- Every insert reuses these ids so we get a stable, meaningful seed.
-- =====================================================================
DECLARE @org_id BIGINT = (
    SELECT TOP 1 organization_id
    FROM grac_practice.organization
    WHERE status = N'Active'
    ORDER BY organization_id
);

IF @org_id IS NULL
BEGIN
    PRINT 'SKIP (053): no active organization -- nothing to seed.';
    RETURN;
END

-- Employees table name is organization_employee (per 002).
IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
BEGIN
    PRINT 'SKIP (053): organization_employee table missing.';
    RETURN;
END

DECLARE @emp_1 BIGINT, @emp_2 BIGINT, @emp_3 BIGINT;

;WITH emps AS (
    SELECT TOP 3 employee_id,
           ROW_NUMBER() OVER (ORDER BY employee_id) AS rn
    FROM grac_practice.organization_employee
    WHERE organization_id = @org_id
      AND (status IS NULL OR status = N'Active')
    ORDER BY employee_id
)
SELECT @emp_1 = MAX(CASE WHEN rn = 1 THEN employee_id END),
       @emp_2 = MAX(CASE WHEN rn = 2 THEN employee_id END),
       @emp_3 = MAX(CASE WHEN rn = 3 THEN employee_id END)
FROM emps;

IF @emp_1 IS NULL
BEGIN
    PRINT 'SKIP (053): no active employees for the chosen organization.';
    RETURN;
END

-- Fall back to emp_1 if fewer than three employees exist.
IF @emp_2 IS NULL SET @emp_2 = @emp_1;
IF @emp_3 IS NULL SET @emp_3 = @emp_1;

-- =====================================================================
-- Idempotence guard: if we've already seeded, don't add duplicates.
-- =====================================================================
IF EXISTS (
    SELECT 1
    FROM grac_practice.practice_task pt
    JOIN grac_practice.task_type_master tt ON tt.task_type_id = pt.task_type_id
    WHERE pt.organization_id = @org_id
      AND tt.type_code IN (N'Assurance', N'Custom')
      AND pt.origin_code = N'SAMPLE-053'
)
BEGIN
    PRINT 'SKIP (053): sample rows already present for this organization.';
    RETURN;
END

DECLARE @tid BIGINT;

-- =====================================================================
-- 12 sample rows, alternating type and priority, rotating assignee.
-- We call sp_task_open once per row (procs handle SLA + audit).
-- =====================================================================

-- ---------- Assurance tasks ----------
EXEC grac_practice.sp_task_open
    @organization_id        = @org_id,
    @task_type_code         = N'Assurance',
    @subject_entity_type    = N'Assurance',
    @subject_entity_id      = 0,
    @subject_title          = N'Q1 access-review evidence collection',
    @subject_description    = N'Collect signed access-review sheets from all department heads.',
    @priority               = N'High',
    @origin_code            = N'SAMPLE-053',
    @assigned_to_employee_id= @emp_1,
    @task_id                = @tid OUTPUT;

EXEC grac_practice.sp_task_open
    @organization_id        = @org_id,
    @task_type_code         = N'Assurance',
    @subject_entity_type    = N'Assurance',
    @subject_entity_id      = 0,
    @subject_title          = N'Backup restoration test walk-through',
    @subject_description    = N'Perform quarterly restore drill for tier-1 databases and attach the runbook output.',
    @priority               = N'Critical',
    @origin_code            = N'SAMPLE-053',
    @assigned_to_employee_id= @emp_2,
    @task_id                = @tid OUTPUT;
-- Move this one into InProgress so the grid shows a non-Open row.
EXEC grac_practice.sp_task_transition
    @task_id                = @tid,
    @to_status_code         = N'InProgress',
    @actor_employee_id      = @emp_2,
    @reason_code            = N'SEED_INIT',
    @reason_text            = N'Sample data: moved to InProgress by seed-053.';

EXEC grac_practice.sp_task_open
    @organization_id        = @org_id,
    @task_type_code         = N'Assurance',
    @subject_entity_type    = N'Assurance',
    @subject_entity_id      = 0,
    @subject_title          = N'Vendor SOC 2 report reconciliation',
    @subject_description    = N'Compare our latest vendor register against SOC 2 reports for FY25.',
    @priority               = N'Medium',
    @origin_code            = N'SAMPLE-053',
    @assigned_to_employee_id= @emp_3,
    @task_id                = @tid OUTPUT;

EXEC grac_practice.sp_task_open
    @organization_id        = @org_id,
    @task_type_code         = N'Assurance',
    @subject_entity_type    = N'Assurance',
    @subject_entity_id      = 0,
    @subject_title          = N'Firewall change ticket sample audit',
    @subject_description    = N'Sample 10 of last quarter''s firewall change tickets for approval evidence.',
    @priority               = N'High',
    @origin_code            = N'SAMPLE-053',
    @assigned_to_employee_id= @emp_1,
    @task_id                = @tid OUTPUT;
-- Pending review
EXEC grac_practice.sp_task_transition
    @task_id                = @tid,
    @to_status_code         = N'InProgress',
    @actor_employee_id      = @emp_1,
    @reason_code            = N'SEED_INIT',
    @reason_text            = N'Sample data: moved to InProgress by seed-053.';
EXEC grac_practice.sp_task_transition
    @task_id                = @tid,
    @to_status_code         = N'PendingReview',
    @actor_employee_id      = @emp_1,
    @reason_code            = N'SEED_INIT',
    @reason_text            = N'Sample data: moved to PendingReview by seed-053.';

EXEC grac_practice.sp_task_open
    @organization_id        = @org_id,
    @task_type_code         = N'Assurance',
    @subject_entity_type    = N'Assurance',
    @subject_entity_id      = 0,
    @subject_title          = N'Employee-onboarding checklist compliance sweep',
    @subject_description    = N'Confirm the last 20 new-hires had all four onboarding steps signed off.',
    @priority               = N'Low',
    @origin_code            = N'SAMPLE-053',
    @assigned_to_employee_id= @emp_2,
    @task_id                = @tid OUTPUT;

EXEC grac_practice.sp_task_open
    @organization_id        = @org_id,
    @task_type_code         = N'Assurance',
    @subject_entity_type    = N'Assurance',
    @subject_entity_id      = 0,
    @subject_title          = N'Data-retention policy attestation',
    @subject_description    = N'Attest that the data-retention policy is being followed by data owners.',
    @priority               = N'Medium',
    @origin_code            = N'SAMPLE-053',
    @assigned_to_employee_id= @emp_3,
    @task_id                = @tid OUTPUT;

-- ---------- Custom tasks ----------
EXEC grac_practice.sp_task_open
    @organization_id        = @org_id,
    @task_type_code         = N'Custom',
    @subject_entity_type    = N'Custom',
    @subject_entity_id      = 0,
    @subject_title          = N'Draft board pack for October risk committee',
    @subject_description    = N'Assemble the risk heat map, top-10 findings, and remediation status.',
    @priority               = N'High',
    @origin_code            = N'SAMPLE-053',
    @assigned_to_employee_id= @emp_1,
    @task_id                = @tid OUTPUT;

EXEC grac_practice.sp_task_open
    @organization_id        = @org_id,
    @task_type_code         = N'Custom',
    @subject_entity_type    = N'Custom',
    @subject_entity_id      = 0,
    @subject_title          = N'Update internal wiki: incident-response contacts',
    @subject_description    = N'Refresh the after-hours escalation numbers for on-call.',
    @priority               = N'Low',
    @origin_code            = N'SAMPLE-053',
    @assigned_to_employee_id= @emp_2,
    @task_id                = @tid OUTPUT;
-- Close this one to show a terminal row.
EXEC grac_practice.sp_task_transition
    @task_id                = @tid,
    @to_status_code         = N'InProgress',
    @actor_employee_id      = @emp_2,
    @reason_code            = N'SEED_INIT',
    @reason_text            = N'Sample data.';
EXEC grac_practice.sp_task_transition
    @task_id                = @tid,
    @to_status_code         = N'Closed',
    @actor_employee_id      = @emp_2,
    @reason_code            = N'SEED_INIT',
    @reason_text            = N'Sample data: moved to Closed by seed-053.';

EXEC grac_practice.sp_task_open
    @organization_id        = @org_id,
    @task_type_code         = N'Custom',
    @subject_entity_type    = N'Custom',
    @subject_entity_id      = 0,
    @subject_title          = N'Prepare comms for revised privacy notice',
    @subject_description    = N'Draft internal + customer-facing messages ahead of the November rollout.',
    @priority               = N'Medium',
    @origin_code            = N'SAMPLE-053',
    @assigned_to_employee_id= @emp_3,
    @task_id                = @tid OUTPUT;

EXEC grac_practice.sp_task_open
    @organization_id        = @org_id,
    @task_type_code         = N'Custom',
    @subject_entity_type    = N'Custom',
    @subject_entity_id      = 0,
    @subject_title          = N'Vendor Zoom seat true-up',
    @subject_description    = N'Reconcile actual Zoom seats against contracted count; flag surplus for cancellation.',
    @priority               = N'Low',
    @origin_code            = N'SAMPLE-053',
    @assigned_to_employee_id= @emp_1,
    @task_id                = @tid OUTPUT;

EXEC grac_practice.sp_task_open
    @organization_id        = @org_id,
    @task_type_code         = N'Custom',
    @subject_entity_type    = N'Custom',
    @subject_entity_id      = 0,
    @subject_title          = N'Coordinate DR site quarterly failover',
    @subject_description    = N'Book the maintenance window, notify stakeholders, capture the post-mortem.',
    @priority               = N'Critical',
    @origin_code            = N'SAMPLE-053',
    @assigned_to_employee_id= @emp_2,
    @task_id                = @tid OUTPUT;
EXEC grac_practice.sp_task_transition
    @task_id                = @tid,
    @to_status_code         = N'InProgress',
    @actor_employee_id      = @emp_2,
    @reason_code            = N'SEED_INIT',
    @reason_text            = N'Sample data: moved to InProgress by seed-053.';

EXEC grac_practice.sp_task_open
    @organization_id        = @org_id,
    @task_type_code         = N'Custom',
    @subject_entity_type    = N'Custom',
    @subject_entity_id      = 0,
    @subject_title          = N'Assign shadow reviewer for December releases',
    @subject_description    = N'Nominate one buddy from each squad for the December release freeze.',
    @priority               = N'Medium',
    @origin_code            = N'SAMPLE-053',
    @assigned_to_employee_id= @emp_3,
    @task_id                = @tid OUTPUT;

PRINT '053 sample Assurance + Custom tasks seeded.';
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT tt.type_code            AS TaskType,
       tsm.status_code         AS StatusCode,
       COUNT(*)                AS RowCount
FROM grac_practice.practice_task pt
JOIN grac_practice.task_type_master tt   ON tt.task_type_id = pt.task_type_id
JOIN grac_practice.task_status_master tsm ON tsm.task_status_id = pt.current_status_id
WHERE pt.origin_code = N'SAMPLE-053'
GROUP BY tt.type_code, tsm.status_code
ORDER BY tt.type_code, tsm.status_code;
GO

SET NOEXEC OFF;
GO
