-- =====================================================================
-- 465 ROLLBACK -- drop the role gateway shims
--
-- Removes sp_org_role_repository_manage / _get and the two procedures
-- behind them. ResolveProcedureAsync probes with ShimExistsAsync, so the
-- Api falls straight back to dbo.pm_manage_practice_repository /
-- dbo.pm_get_practice_repository with no code change needed -- which
-- means Role Code stops being saved and shows blank again, the exact
-- state 465 was written to fix.
--
-- Already-stored codes are NOT touched: the column and its rows stay as
-- they are, they simply become invisible to the screen again.
--
-- Note: ShimExistsAsync caches its answer per process, so the Api picks
-- the change up on its next restart rather than immediately.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_org_role_repository_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_role_repository_manage;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_role_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_role_save;
GO

PRINT '=== 465 rollback verification ===';
SELECT '465 rollback: shims gone, Api falls back to the monolith' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_role_repository_manage','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_org_role_repository_get','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_org_role_save','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_org_role_list','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
