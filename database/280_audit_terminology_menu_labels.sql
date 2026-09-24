-- =====================================================================
-- 280 "Assurance" -> "Audit" in Audit Management menu labels
--
-- WHAT THIS DOES
--   Renames the two menu_master rows in the Audit Management group whose
--   DISPLAY NAME still reads "Assurance":
--       org-assurance-definitions   'Assurance Definitions' -> 'Audit Definitions'
--       org-assurance-plans         'Assurance Plans'       -> 'Audit Plans'
--   Every other row in the group (Scope Builder, Question Sets, Evidence
--   Config, Workflow Config, Scoring Config, Triggers, Scope Resolution,
--   Executions, Observations) already reads correctly.
--
-- LABELS ONLY -- NOTHING ELSE MOVES
--   menu_key is untouched. So are menu_url, parent_menu_id,
--   display_order, module_type, status and every
--   organization_role_menu_permission row (which points at menu_id, an
--   IDENTITY this script never writes). Screen keys, routes, API paths,
--   stored procedures, table and column names all keep the word
--   "assurance" -- this is a terminology change in the UI, not a rename
--   of the model.
--
-- OUT OF SCOPE ON PURPOSE
--   The legacy 'Assurance Management' module (assurance-dashboard,
--   assurance-generation, assurance-findings, ...) is a DIFFERENT and
--   unrelated set of screens, all Inactive. Its labels are left exactly
--   as they are.
--
-- Re-runnable: yes. A second run reports 0 changes.
-- Rollback: database/280_audit_terminology_menu_labels_rollback.sql
-- DEPENDS ON: 276 (the Audit Management group).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (280): grac_practice.menu_master missing. Run 022 first.';
    RAISERROR('280_audit_terminology_menu_labels: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

UPDATE m
SET    menu_name  = x.new_name,
       updated_by = N'seed-280',
       updated_dt = SYSUTCDATETIME()
FROM   grac_practice.menu_master m
JOIN  (VALUES
    (N'org-assurance-definitions', N'Audit Definitions'),
    (N'org-assurance-plans'      , N'Audit Plans')
) AS x(menu_key, new_name) ON x.menu_key = m.menu_key
WHERE  m.menu_name <> x.new_name;

PRINT '280: menu labels renamed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'No Audit Management menu still reads "Assurance"' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1
                  FROM grac_practice.menu_master m
                 WHERE m.module_type = N'Audit Management'
                   AND m.menu_name LIKE N'%Assurance%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Legacy Assurance Management labels untouched' AS Check_,
       CAST((SELECT COUNT(*) FROM grac_practice.menu_master
              WHERE module_type = N'Assurance Management') AS NVARCHAR(20))
       + ' legacy row(s) left as they were' AS Result;

SELECT 'Permissions unaffected' AS Check_,
       CAST((SELECT COUNT(*)
               FROM grac_practice.organization_role_menu_permission p
               JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
              WHERE m.menu_key IN (N'org-assurance-definitions', N'org-assurance-plans')) AS NVARCHAR(20))
       + ' grant row(s) still present' AS Result;

SELECT m.menu_key AS MenuKey, m.menu_name AS MenuName,
       m.module_type AS ModuleType, m.status AS Status
  FROM grac_practice.menu_master m
 WHERE m.module_type = N'Audit Management'
 ORDER BY m.display_order;

PRINT '280 Audit terminology (menu labels) complete.';
GO
SET NOEXEC OFF;
GO
