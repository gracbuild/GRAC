-- =====================================================================
-- 115 Hybrid role+employee ownership across the Assurance module.
--
-- Motivation:
--   In GRC systems, ownership must survive employee turnover. Storing
--   only employee_id creates orphaned records the moment an employee
--   leaves or changes role. Enterprise GRC tools (ServiceNow GRC,
--   Archer, MetricStream) all use a HYBRID pattern:
--
--     * Role  = permanent position ("CISO", "IT Security Manager")
--     * Employee = current holder at time of assignment (snapshot)
--
--   Notifications resolve via `role -> current holders` at notify
--   time. Historical audit rows keep the snapshot so 5 years later
--   we still know "the CISO role, held by Priya on 2026-06-14".
--
-- This migration ADDS role columns alongside every existing owner /
-- reviewer / auditor employee field in the Assurance module. It does
-- NOT drop employee columns -- they remain the current-holder snapshot.
--
-- Reporter fields (observation.reported_by_*, entered_by, updated_by,
-- accepted_dt actor, etc.) intentionally stay employee-only because
-- they are historical facts, not ownership assignments.
--
-- Backfill: for every row where employee_id is populated and the
-- employee's organization_employee.role_id is known, populate the
-- new role_id + role_name from the employee's role assignment.
--
-- Affected tables:
--   * grac_practice.org_assurance_definition           (owner)
--   * grac_practice.org_assurance_observation          (owner, reviewer)
--   * grac_practice.custom_gap                         (owner, reviewer)
--   * grac_practice.custom_gap_action                  (assignee)
--   * grac_practice.org_assurance_execution            (owner)
--   * grac_practice.org_assurance_execution_entity     (assigned auditor)
--   * grac_practice.org_assurance_plan                 (owner)
--   * grac_practice.org_assurance_plan_item            (assigned auditor)
--
-- All ADD COLUMN + backfill statements are idempotent.
-- Rollback: 115_assurance_role_ownership_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','role_id') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
BEGIN
    RAISERROR('115: prerequisites missing (organization_employee.role_id / organization_role).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- Helper: add owner_role_id + owner_role_name pair on a table
-- (implemented as inline ALTERs -- one macro per column pair is
--  simplest, most auditable, and works with idempotent COL_LENGTH guards)
-- =====================================================================

-- ---------- org_assurance_definition (owner) ----------
IF OBJECT_ID('grac_practice.org_assurance_definition','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('grac_practice.org_assurance_definition','owner_role_id') IS NULL
        ALTER TABLE grac_practice.org_assurance_definition ADD owner_role_id BIGINT NULL;
    IF COL_LENGTH('grac_practice.org_assurance_definition','owner_role_name') IS NULL
        ALTER TABLE grac_practice.org_assurance_definition ADD owner_role_name NVARCHAR(120) NULL;
END
GO

-- ---------- org_assurance_observation (owner, reviewer) ----------
IF OBJECT_ID('grac_practice.org_assurance_observation','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('grac_practice.org_assurance_observation','assigned_owner_role_id') IS NULL
        ALTER TABLE grac_practice.org_assurance_observation ADD assigned_owner_role_id BIGINT NULL;
    IF COL_LENGTH('grac_practice.org_assurance_observation','assigned_owner_role_name') IS NULL
        ALTER TABLE grac_practice.org_assurance_observation ADD assigned_owner_role_name NVARCHAR(120) NULL;
    IF COL_LENGTH('grac_practice.org_assurance_observation','assigned_reviewer_role_id') IS NULL
        ALTER TABLE grac_practice.org_assurance_observation ADD assigned_reviewer_role_id BIGINT NULL;
    IF COL_LENGTH('grac_practice.org_assurance_observation','assigned_reviewer_role_name') IS NULL
        ALTER TABLE grac_practice.org_assurance_observation ADD assigned_reviewer_role_name NVARCHAR(120) NULL;
END
GO

-- ---------- custom_gap (owner, reviewer -- for Assurance-source rows;
--                       Custom-source rows can also use them going forward) ----------
IF OBJECT_ID('grac_practice.custom_gap','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('grac_practice.custom_gap','owner_role_id') IS NULL
        ALTER TABLE grac_practice.custom_gap ADD owner_role_id BIGINT NULL;
    IF COL_LENGTH('grac_practice.custom_gap','owner_role_name') IS NULL
        ALTER TABLE grac_practice.custom_gap ADD owner_role_name NVARCHAR(120) NULL;
    IF COL_LENGTH('grac_practice.custom_gap','assigned_reviewer_role_id') IS NULL
        ALTER TABLE grac_practice.custom_gap ADD assigned_reviewer_role_id BIGINT NULL;
    IF COL_LENGTH('grac_practice.custom_gap','assigned_reviewer_role_name') IS NULL
        ALTER TABLE grac_practice.custom_gap ADD assigned_reviewer_role_name NVARCHAR(120) NULL;
END
GO

-- ---------- custom_gap_action (assignee) ----------
IF OBJECT_ID('grac_practice.custom_gap_action','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('grac_practice.custom_gap_action','assigned_role_id') IS NULL
        ALTER TABLE grac_practice.custom_gap_action ADD assigned_role_id BIGINT NULL;
    IF COL_LENGTH('grac_practice.custom_gap_action','assigned_role_name') IS NULL
        ALTER TABLE grac_practice.custom_gap_action ADD assigned_role_name NVARCHAR(120) NULL;
END
GO

-- ---------- org_assurance_execution (owner) ----------
IF OBJECT_ID('grac_practice.org_assurance_execution','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('grac_practice.org_assurance_execution','owner_role_id') IS NULL
        ALTER TABLE grac_practice.org_assurance_execution ADD owner_role_id BIGINT NULL;
    IF COL_LENGTH('grac_practice.org_assurance_execution','owner_role_name') IS NULL
        ALTER TABLE grac_practice.org_assurance_execution ADD owner_role_name NVARCHAR(120) NULL;
END
GO

-- ---------- org_assurance_execution_entity (assigned auditor) ----------
IF OBJECT_ID('grac_practice.org_assurance_execution_entity','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('grac_practice.org_assurance_execution_entity','assigned_auditor_role_id') IS NULL
        ALTER TABLE grac_practice.org_assurance_execution_entity ADD assigned_auditor_role_id BIGINT NULL;
    IF COL_LENGTH('grac_practice.org_assurance_execution_entity','assigned_auditor_role_name') IS NULL
        ALTER TABLE grac_practice.org_assurance_execution_entity ADD assigned_auditor_role_name NVARCHAR(120) NULL;
END
GO

-- ---------- org_assurance_plan (owner) ----------
IF OBJECT_ID('grac_practice.org_assurance_plan','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('grac_practice.org_assurance_plan','owner_role_id') IS NULL
        ALTER TABLE grac_practice.org_assurance_plan ADD owner_role_id BIGINT NULL;
    IF COL_LENGTH('grac_practice.org_assurance_plan','owner_role_name') IS NULL
        ALTER TABLE grac_practice.org_assurance_plan ADD owner_role_name NVARCHAR(120) NULL;
END
GO

-- ---------- org_assurance_plan_item (assigned auditor) ----------
IF OBJECT_ID('grac_practice.org_assurance_plan_item','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('grac_practice.org_assurance_plan_item','assigned_auditor_role_id') IS NULL
        ALTER TABLE grac_practice.org_assurance_plan_item ADD assigned_auditor_role_id BIGINT NULL;
    IF COL_LENGTH('grac_practice.org_assurance_plan_item','assigned_auditor_role_name') IS NULL
        ALTER TABLE grac_practice.org_assurance_plan_item ADD assigned_auditor_role_name NVARCHAR(120) NULL;
END
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Backfill: for each *_employee_id, pull the employee's current role
-- and snapshot the role_id + role_name into the paired columns.
--
-- All updates are guarded by "IS NULL" on the target so a re-run does
-- not overwrite manually-set values.
-- =====================================================================
BEGIN TRAN;

-- Reusable pattern: for each (table, employee_col, role_id_col, role_name_col)
UPDATE d
SET d.owner_role_id   = e.role_id,
    d.owner_role_name = r.role_name
FROM grac_practice.org_assurance_definition d
JOIN grac_practice.organization_employee e ON e.employee_id = d.owner_employee_id
JOIN grac_practice.organization_role     r ON r.role_id     = e.role_id
WHERE d.owner_employee_id IS NOT NULL
  AND d.owner_role_id IS NULL
  AND e.role_id IS NOT NULL;
PRINT '115 backfill definition.owner_role: ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE o
SET o.assigned_owner_role_id   = e.role_id,
    o.assigned_owner_role_name = r.role_name
FROM grac_practice.org_assurance_observation o
JOIN grac_practice.organization_employee e ON e.employee_id = o.assigned_owner_employee_id
JOIN grac_practice.organization_role     r ON r.role_id     = e.role_id
WHERE o.assigned_owner_employee_id IS NOT NULL
  AND o.assigned_owner_role_id IS NULL
  AND e.role_id IS NOT NULL;
PRINT '115 backfill observation.assigned_owner_role: ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE o
SET o.assigned_reviewer_role_id   = e.role_id,
    o.assigned_reviewer_role_name = r.role_name
FROM grac_practice.org_assurance_observation o
JOIN grac_practice.organization_employee e ON e.employee_id = o.assigned_reviewer_employee_id
JOIN grac_practice.organization_role     r ON r.role_id     = e.role_id
WHERE o.assigned_reviewer_employee_id IS NOT NULL
  AND o.assigned_reviewer_role_id IS NULL
  AND e.role_id IS NOT NULL;
PRINT '115 backfill observation.assigned_reviewer_role: ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE g
SET g.owner_role_id   = e.role_id,
    g.owner_role_name = r.role_name
FROM grac_practice.custom_gap g
JOIN grac_practice.organization_employee e ON e.employee_id = g.owner_employee_id
JOIN grac_practice.organization_role     r ON r.role_id     = e.role_id
WHERE g.owner_employee_id IS NOT NULL
  AND g.owner_role_id IS NULL
  AND e.role_id IS NOT NULL;
PRINT '115 backfill custom_gap.owner_role: ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE g
SET g.assigned_reviewer_role_id   = e.role_id,
    g.assigned_reviewer_role_name = r.role_name
FROM grac_practice.custom_gap g
JOIN grac_practice.organization_employee e ON e.employee_id = g.assigned_reviewer_employee_id
JOIN grac_practice.organization_role     r ON r.role_id     = e.role_id
WHERE g.assigned_reviewer_employee_id IS NOT NULL
  AND g.assigned_reviewer_role_id IS NULL
  AND e.role_id IS NOT NULL;
PRINT '115 backfill custom_gap.assigned_reviewer_role: ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE a
SET a.assigned_role_id   = e.role_id,
    a.assigned_role_name = r.role_name
FROM grac_practice.custom_gap_action a
JOIN grac_practice.organization_employee e ON e.employee_id = a.assigned_employee_id
JOIN grac_practice.organization_role     r ON r.role_id     = e.role_id
WHERE a.assigned_employee_id IS NOT NULL
  AND a.assigned_role_id IS NULL
  AND e.role_id IS NOT NULL;
PRINT '115 backfill custom_gap_action.assigned_role: ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE x
SET x.owner_role_id   = e.role_id,
    x.owner_role_name = r.role_name
FROM grac_practice.org_assurance_execution x
JOIN grac_practice.organization_employee e ON e.employee_id = x.owner_employee_id
JOIN grac_practice.organization_role     r ON r.role_id     = e.role_id
WHERE x.owner_employee_id IS NOT NULL
  AND x.owner_role_id IS NULL
  AND e.role_id IS NOT NULL;
PRINT '115 backfill execution.owner_role: ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE ent
SET ent.assigned_auditor_role_id   = e.role_id,
    ent.assigned_auditor_role_name = r.role_name
FROM grac_practice.org_assurance_execution_entity ent
JOIN grac_practice.organization_employee e ON e.employee_id = ent.assigned_auditor_employee_id
JOIN grac_practice.organization_role     r ON r.role_id     = e.role_id
WHERE ent.assigned_auditor_employee_id IS NOT NULL
  AND ent.assigned_auditor_role_id IS NULL
  AND e.role_id IS NOT NULL;
PRINT '115 backfill execution_entity.assigned_auditor_role: ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE p
SET p.owner_role_id   = e.role_id,
    p.owner_role_name = r.role_name
FROM grac_practice.org_assurance_plan p
JOIN grac_practice.organization_employee e ON e.employee_id = p.owner_employee_id
JOIN grac_practice.organization_role     r ON r.role_id     = e.role_id
WHERE p.owner_employee_id IS NOT NULL
  AND p.owner_role_id IS NULL
  AND e.role_id IS NOT NULL;
PRINT '115 backfill plan.owner_role: ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE pi
SET pi.assigned_auditor_role_id   = e.role_id,
    pi.assigned_auditor_role_name = r.role_name
FROM grac_practice.org_assurance_plan_item pi
JOIN grac_practice.organization_employee e ON e.employee_id = pi.assigned_auditor_employee_id
JOIN grac_practice.organization_role     r ON r.role_id     = e.role_id
WHERE pi.assigned_auditor_employee_id IS NOT NULL
  AND pi.assigned_auditor_role_id IS NULL
  AND e.role_id IS NOT NULL;
PRINT '115 backfill plan_item.assigned_auditor_role: ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'definition.owner_role_id column present'      AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.org_assurance_definition','owner_role_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'custom_gap.owner_role_id column present'      AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.custom_gap','owner_role_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'custom_gap_action.assigned_role_id present'   AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.custom_gap_action','assigned_role_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'execution.owner_role_id present'              AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.org_assurance_execution','owner_role_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '115 Assurance role+employee ownership schema deployed.';
GO

SET NOEXEC OFF;
GO
