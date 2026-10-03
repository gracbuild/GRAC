-- =====================================================================
-- 409_..._rollback.sql
--
-- Reverses 409: the Asset Category Assurance menu is Active again.
-- Status only; key, url, parent, order and permissions were never
-- touched. Also set the 'asset-category-assurance' row in
-- 274_menu_master_seed.sql back to N'Active', or the next snapshot run
-- will deactivate it again.
-- Idempotent. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (409 rollback): grac_practice.menu_master is missing.';
    RETURN;
END
GO

UPDATE grac_practice.menu_master
   SET status     = N'Active',
       updated_by = 'seed-409-rollback',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'asset-category-assurance'
   AND status  <> N'Active';
PRINT CONCAT('409 rollback: asset-category-assurance menu rows set Active: ', @@ROWCOUNT);
GO
