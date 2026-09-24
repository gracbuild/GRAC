-- =====================================================================
-- 363_menu_rename_source_statements_to_control_statements.sql
--
-- Renames the sidebar menu label "Source Statements" to
-- "Control Statements". DISPLAY LABEL ONLY.
--
--   * Updates grac_practice.menu_master.menu_name for the existing
--     'source-statements' row.
--   * Does NOT change menu_key, menu_url, display_order, permissions,
--     parent, or any other column -- so every route, permission grant
--     and screen mapping stays intact.
--
-- Idempotent and re-runnable. ASCII-only.
-- Rollback: 363_menu_rename_source_statements_to_control_statements_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (363): grac_practice.menu_master is missing.';
    RETURN;
END
GO

UPDATE grac_practice.menu_master
   SET menu_name  = N'Control Statements',
       updated_by = 'seed-363',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'source-statements'
   AND menu_name <> N'Control Statements';
PRINT CONCAT('363: menu rows updated to "Control Statements": ', @@ROWCOUNT);
GO

-- Verification
IF EXISTS (SELECT 1 FROM grac_practice.menu_master
            WHERE menu_key = N'source-statements' AND menu_name = N'Control Statements')
    PRINT '363: PASS -- sidebar menu label is now "Control Statements".';
ELSE
    PRINT '363: NOTE -- no source-statements menu row found (nothing to rename).';
GO
