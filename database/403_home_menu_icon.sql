-- =====================================================================
-- 403 Home menu icon: chart-line -> house
--
-- The Home menu (menu_key 'dashboard', displayed as "Home") carried a
-- chart-line icon; a house reads as Home. Menu-only change to
-- grac_practice.menu_master.icon_class. 274 snapshot amended to match.
-- Idempotent. ASCII-only. Rollback restores chart-line.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

UPDATE grac_practice.menu_master
   SET icon_class = N'house',
       updated_by = N'migration-403',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'dashboard';
GO

PRINT '403 complete.';
GO
