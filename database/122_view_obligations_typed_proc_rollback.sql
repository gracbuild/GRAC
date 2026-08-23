-- =====================================================================
-- 122 sp_pm_view_obligations_typed -- ROLLBACK
--
-- Drops the standalone typed-projection sub-proc.  pm_get_practice_repository
-- is unchanged so its existing 'evidence-obligations' branch continues to
-- work.  Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.sp_pm_view_obligations_typed','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_pm_view_obligations_typed;
GO

PRINT '122 sp_pm_view_obligations_typed rollback complete.';
GO
