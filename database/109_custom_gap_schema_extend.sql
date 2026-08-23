-- =====================================================================
-- 109 Custom Gap schema extensions -- unify Assurance gaps into the
-- existing Gap Center (Practice/Index/gaps -> Assurance Gaps tab).
--
-- Background:
--   The existing grac_practice.custom_gap table (migration 054) was
--   already designed to accept multiple gap sources via gap_type_code,
--   and the existing Gap Center partial has an Assurance Gaps tab
--   that has been placeholder-only. Stage 4 briefly built a parallel
--   org_assurance_gap module -- migrations 109 - 113 reunify: this
--   migration extends custom_gap so it can carry an Assurance-source
--   gap's full context (severity, remediation lifecycle, source
--   observation ref, denormalized execution / entity), 110 renames
--   junction / actions / history to custom_gap_*, 111 data-migrates
--   the org_assurance_gap rows in, 112 rewrites procs, 113 drops the
--   parallel module.
--
-- Design notes:
--   * gap_source_module_code (Implementation / Assurance / Custom /
--     Exception / Risk / Audit) is a discoverable filter distinct
--     from the older free-text gap_type_code, and is what the Gap
--     Center tabs filter on.
--   * severity_code is a soft NVARCHAR (matches the observation
--     severity vocabulary) to keep custom_gap decoupled from the
--     Assurance-specific severity master. Custom rows leave it NULL.
--   * status CHECK is extended to include the remediation lifecycle
--     values (RemediationSubmitted / Verified / Reopened). Existing
--     rows use Open / InProgress / Closed / Cancelled -- unchanged.
--   * Every ADD COLUMN is guarded so migration 109 is idempotent.
--
-- Rollback: 109_custom_gap_schema_extend_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
BEGIN
    RAISERROR('109: prerequisite missing (run 054 first).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Source-module + soft source-reference
-- =====================================================================
IF COL_LENGTH('grac_practice.custom_gap','gap_source_module_code') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD gap_source_module_code NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_custom_gap_source_module DEFAULT N'Custom';
GO

IF COL_LENGTH('grac_practice.custom_gap','source_reference_type') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD source_reference_type NVARCHAR(60) NULL;
GO

IF COL_LENGTH('grac_practice.custom_gap','source_reference_id') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD source_reference_id BIGINT NULL;
GO

-- =====================================================================
-- 2. Severity (soft codes -- no FK to observation severity master)
-- =====================================================================
IF COL_LENGTH('grac_practice.custom_gap','severity_code') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD severity_code NVARCHAR(30) NULL;
GO

IF COL_LENGTH('grac_practice.custom_gap','severity_name') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD severity_name NVARCHAR(120) NULL;
GO

-- =====================================================================
-- 3. Denormalized source context (executed for Assurance rows;
--    all nullable so Custom / Implementation rows leave them empty)
-- =====================================================================
IF COL_LENGTH('grac_practice.custom_gap','execution_code') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD execution_code NVARCHAR(120) NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','execution_name') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD execution_name NVARCHAR(300) NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','entity_dimension_code') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD entity_dimension_code NVARCHAR(60)  NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','entity_dimension_name') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD entity_dimension_name NVARCHAR(160) NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','entity_code') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD entity_code NVARCHAR(120) NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','entity_name') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD entity_name NVARCHAR(240) NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','observation_code') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD observation_code NVARCHAR(120) NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','observation_title') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD observation_title NVARCHAR(300) NULL;
GO

-- =====================================================================
-- 4. Ownership -- reviewer + display names (owner already exists via
--    owner_employee_id; we add reviewer + denormalized name fields
--    for both, so lists render without joins)
-- =====================================================================
IF COL_LENGTH('grac_practice.custom_gap','owner_display_name') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD owner_display_name NVARCHAR(240) NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','assigned_reviewer_employee_id') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD assigned_reviewer_employee_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','assigned_reviewer_display_name') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD assigned_reviewer_display_name NVARCHAR(240) NULL;
GO

-- =====================================================================
-- 5. Remediation lifecycle
-- =====================================================================
IF COL_LENGTH('grac_practice.custom_gap','remediation_plan') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD remediation_plan NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','resolution_notes') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD resolution_notes NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','verification_notes') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD verification_notes NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','closure_notes') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD closure_notes NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','target_resolution_date') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD target_resolution_date DATE NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','opened_dt') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD opened_dt DATETIME2 NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','remediation_submitted_dt') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD remediation_submitted_dt DATETIME2 NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','verified_dt') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD verified_dt DATETIME2 NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','closed_dt') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD closed_dt DATETIME2 NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap','reopened_dt') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD reopened_dt DATETIME2 NULL;
GO

-- =====================================================================
-- 6. Stage 4c integration hooks
-- =====================================================================
IF COL_LENGTH('grac_practice.custom_gap','risk_id') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD risk_id BIGINT NULL;
GO
-- The existing linked_task_id already exists (from 054) -- keep it as
-- the canonical PM-task pointer; do not add a duplicate task_id.

-- =====================================================================
-- 7. Extended status CHECK (drop + re-add).
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_custom_gap_status')
    ALTER TABLE grac_practice.custom_gap
        DROP CONSTRAINT ck_pm_custom_gap_status;
GO

ALTER TABLE grac_practice.custom_gap
    ADD CONSTRAINT ck_pm_custom_gap_status CHECK (status IN (
        N'Open', N'InProgress', N'RemediationSubmitted',
        N'Verified', N'Closed', N'Reopened', N'Cancelled'));
GO

-- Source-module vocabulary CHECK.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_custom_gap_source_module')
    ALTER TABLE grac_practice.custom_gap
        ADD CONSTRAINT ck_pm_custom_gap_source_module CHECK (
            gap_source_module_code IN (
                N'Implementation', N'Assurance', N'Custom',
                N'Exception', N'Risk', N'Audit'));
GO

-- =====================================================================
-- 8. Filter-friendly indexes for the new columns
-- =====================================================================
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'ix_pm_custom_gap_source_module'
      AND object_id = OBJECT_ID('grac_practice.custom_gap'))
    CREATE INDEX ix_pm_custom_gap_source_module
        ON grac_practice.custom_gap(organization_id, gap_source_module_code, status)
        INCLUDE (priority, severity_code, due_date);
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'ix_pm_custom_gap_source_ref'
      AND object_id = OBJECT_ID('grac_practice.custom_gap'))
    CREATE INDEX ix_pm_custom_gap_source_ref
        ON grac_practice.custom_gap(source_reference_type, source_reference_id)
        WHERE source_reference_id IS NOT NULL;
GO

-- =====================================================================
-- 9. Backfill -- every existing row was Custom-sourced; set opened_dt
--    from entered_dt so lifecycle timestamps aren't NULL for legacy
--    rows.
-- =====================================================================
UPDATE grac_practice.custom_gap
   SET gap_source_module_code = N'Custom'
 WHERE gap_source_module_code IS NULL
    OR gap_source_module_code = N'';
GO

UPDATE grac_practice.custom_gap
   SET opened_dt = entered_dt
 WHERE opened_dt IS NULL;
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'gap_source_module_code present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.custom_gap','gap_source_module_code') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'severity_code present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.custom_gap','severity_code') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'remediation lifecycle columns present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.custom_gap','remediation_plan') IS NOT NULL
             AND COL_LENGTH('grac_practice.custom_gap','remediation_submitted_dt') IS NOT NULL
             AND COL_LENGTH('grac_practice.custom_gap','verified_dt') IS NOT NULL
             AND COL_LENGTH('grac_practice.custom_gap','closed_dt') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'status CHECK includes RemediationSubmitted' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM sys.check_constraints
           WHERE name = 'ck_pm_custom_gap_status'
             AND OBJECT_DEFINITION(object_id) LIKE '%RemediationSubmitted%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'source-module CHECK present' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM sys.check_constraints
           WHERE name = 'ck_pm_custom_gap_source_module')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '109 Custom Gap schema extensions deployed.';
GO

SET NOEXEC OFF;
GO
