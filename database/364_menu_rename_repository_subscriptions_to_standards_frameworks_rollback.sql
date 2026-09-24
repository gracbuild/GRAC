-- =====================================================================
-- 364_..._rollback.sql
--
-- Reverses 364: restores the sidebar menu labels back to
-- "Repository Subscriptions". Display label only; menu_key etc. untouched.
-- Idempotent. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (364 rollback): grac_practice.menu_master is missing.';
    RETURN;
END
GO

UPDATE grac_practice.menu_master
   SET menu_name  = N'Repository Subscriptions',
       updated_by = 'seed-364-rollback',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_name = N'Standards & Frameworks';
PRINT CONCAT('364 rollback: rows restored to "Repository Subscriptions": ', @@ROWCOUNT);
GO

UPDATE grac_practice.menu_master
   SET menu_name  = N'Repository Subscriptions (Admin)',
       updated_by = 'seed-364-rollback',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_name = N'Standards & Frameworks (Admin)';
PRINT CONCAT('364 rollback: admin rows restored: ', @@ROWCOUNT);
GO
