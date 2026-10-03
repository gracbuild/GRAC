-- =====================================================================
-- 405 rollback: restore the Organization menu's display_order to 195
-- (its position before migration 405 moved it above Settings).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

UPDATE grac_practice.menu_master
   SET display_order = 195,
       updated_by    = N'migration-405-rollback',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key = N'organization-administration';
GO

PRINT '405 rollback complete.';
GO
