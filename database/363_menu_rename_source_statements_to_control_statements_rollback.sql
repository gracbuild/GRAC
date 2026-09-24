-- =====================================================================
-- 363_menu_rename_source_statements_to_control_statements_rollback.sql
--
-- Reverses 363: restores the sidebar menu label back to
-- "Source Statements". Display label only; menu_key etc. untouched.
-- Idempotent. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (363 rollback): grac_practice.menu_master is missing.';
    RETURN;
END
GO

UPDATE grac_practice.menu_master
   SET menu_name  = N'Source Statements',
       updated_by = 'seed-363-rollback',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'source-statements'
   AND menu_name <> N'Source Statements';
PRINT CONCAT('363 rollback: menu rows restored to "Source Statements": ', @@ROWCOUNT);
GO
