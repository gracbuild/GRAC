-- =====================================================================
-- 056 Governance menu split -- ROLLBACK
--
-- Reverses the key swap. Rename order is inverted so UNIQUE(menu_key)
-- is never violated.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'SKIP (056 rollback): menu_master missing.';
    RETURN;
END
GO

-- Step 1: Drop the inactive stub row so the original 'repository-subscriptions'
--         key is free to rename back.
DELETE FROM grac_practice.menu_master
 WHERE menu_key = N'repository-subscriptions'
   AND status   = N'Inactive'
   AND entered_by = 'seed-056';
GO

-- Step 2: Rename 'organization-controls' (the current Repository Subscriptions row)
--         back to 'repository-subscriptions'.
UPDATE grac_practice.menu_master
   SET menu_key      = N'repository-subscriptions',
       menu_name     = N'Repository Subscriptions',
       menu_url      = N'Practice/Index/repository-subscriptions',
       display_order = 100,
       icon_class    = N'bookmark',
       updated_by    = 'rollback-056',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key = N'organization-controls';
GO

-- Step 3: Rename 'source-statements' back to 'organization-controls'.
UPDATE grac_practice.menu_master
   SET menu_key      = N'organization-controls',
       menu_name     = N'Source Statements',
       menu_url      = N'Practice/Index/organization-controls',
       display_order = 105,
       icon_class    = N'shield',
       updated_by    = 'rollback-056',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key = N'source-statements';
GO

PRINT '056 governance menu split rollback complete.';
GO

SET NOEXEC OFF;
GO
