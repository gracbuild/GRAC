-- =====================================================================
-- 419 rollback -- restores 241's sp_org_dependency_assets_repository_manage
-- body and drops sp_org_dependency_assets_repository_get.
--
-- Deploy the previous API build (PracticeRepositoryService.cs without the
-- dependency-assets query shim) together with this rollback: the 419 API
-- build falls back to the monolith on its own when the get shim is
-- missing (ResolveProcedureAsync checks OBJECT_ID), so the order is not
-- critical.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_org_dependency_assets_repository_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_dependency_assets_repository_get;
GO
PRINT '419 rollback: list shim dropped. Re-run 241_asset_taxonomy_procs.sql to restore the 241 save shim body.';
GO
