-- =====================================================================
-- 401 rollback: return the standalone Role Menu Permission screen to the
-- sidebar. ASCII-only. Idempotent.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('grac_practice.menu_master','show_in_sidebar') IS NOT NULL
    UPDATE grac_practice.menu_master
       SET show_in_sidebar = 1,
           updated_by = N'migration-401-rollback',
           updated_dt = SYSUTCDATETIME()
     WHERE menu_key = N'role-menu-permissions'
       AND show_in_sidebar = 0;
GO

PRINT '401 rollback complete.';
GO
