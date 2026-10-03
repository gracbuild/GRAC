-- =====================================================================
-- 403 rollback: restore the Home menu icon to chart-line. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

UPDATE grac_practice.menu_master
   SET icon_class = N'chart-line',
       updated_by = N'migration-403-rollback',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'dashboard';
GO

PRINT '403 rollback complete.';
GO
