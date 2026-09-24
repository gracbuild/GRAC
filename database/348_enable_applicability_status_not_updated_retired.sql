-- =====================================================================
-- 348 Enable "Not Updated" and "Retired" in the Applicability Status lookup
--
-- WHY
--   The applicability-status lookup (002_practice_management_procedures.sql,
--   the "UNION ALL SELECT 'applicability-status',status_code,status_name,..."
--   line inside the generic lookups query) only returns rows where
--   is_active=1. In this database, applicability_status_master's
--   'Not Updated' and 'Retired' rows currently have is_active=0, so every
--   Applicability Status dropdown across the app -- Organization Practices
--   and Organization Controls, single-record and bulk alike -- has been
--   missing those two choices, showing only Applicable / Not Applicable
--   (plus, for screens like Organization Controls, Deferred / Accepted
--   Risk / Not Implemented).
--
--   Reported 2026-09-16 on the Organization Practices "Mark Applicability"
--   bulk dialog, right after that screen's dropdown was restricted
--   (practice.js, PRACTICE_APPLICABILITY_STATUSES) to exactly Not Updated,
--   Applicable, Not Applicable, Retired -- which is when the missing two
--   became visible as a gap rather than just fewer choices among many.
--
--   is_active defaults to 1 on this table (CREATE TABLE, 002 line ~37) and
--   every INSERT that seeds these rows (002 lines ~82-91) omits is_active,
--   so it takes the default. Nothing in this repository's migration
--   history sets it to 0 for these two codes -- whatever disabled them did
--   so directly against the database, not through a script here.
--
-- SCOPE
--   Only 'Not Updated' and 'Retired'. Deferred / Accepted Risk / Not
--   Implemented are untouched by this script -- Organization Practices
--   already excludes those three at the UI layer (practice.js's
--   PRACTICE_APPLICABILITY_STATUSES), and Organization Controls still
--   offers them, unaffected either way since this only flips is_active,
--   not adds or removes rows.
--
-- Re-runnable: yes. A second run makes no changes.
-- Rollback: database/348_enable_applicability_status_not_updated_retired_rollback.sql
-- DEPENDS ON: 002 (applicability_status_master).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.applicability_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (348): grac_practice.applicability_status_master missing. Run 002 first.';
    SET NOEXEC ON;
END
GO

UPDATE grac_practice.applicability_status_master
   SET is_active = 1,
       updated_by = N'seed-348',
       updated_dt = SYSUTCDATETIME()
 WHERE status_code IN (N'Not Updated', N'Retired')
   AND is_active <> 1;

PRINT '348: applicability_status_master rows enabled = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT '348 Not Updated is active' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.applicability_status_master WHERE status_code = N'Not Updated' AND is_active = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '348 Retired is active' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.applicability_status_master WHERE status_code = N'Retired' AND is_active = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT status_code AS StatusCode_, status_name AS StatusName_, is_active AS IsActive_, display_order AS DisplayOrder_
FROM grac_practice.applicability_status_master
ORDER BY display_order;

PRINT '348 complete.';
GO
SET NOEXEC OFF;
GO
