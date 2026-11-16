-- =====================================================================
-- 510_organization_list_spoc_frameworks_rollback.sql
--
-- Drops the two procedures 510 added. Nothing else: 510 creates no
-- table, alters no column and writes no data.
--
-- After this, PracticeRepositoryService.ResolveProcedureAsync's
-- ShimExistsAsync probe finds no shim and 'organizations' reads fall
-- back to dbo.pm_get_practice_repository, exactly as before 510 --
-- without SpocName or FrameworkSummary, so the Organization list's
-- SPOC Name and Selected Standards and Frameworks cells come back
-- empty. Restart the Api: the probe is cached per process.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_organizations_repository_get','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_org_organizations_repository_get;
    PRINT '510 rollback: sp_org_organizations_repository_get dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_org_organization_list','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_org_organization_list;
    PRINT '510 rollback: sp_org_organization_list dropped.';
END
GO

PRINT '--- 510 rollback verification ---';
SELECT CASE WHEN OBJECT_ID('grac_practice.sp_org_organization_list','P') IS NULL
            THEN 'gone' ELSE 'STILL THERE' END AS list_procedure,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_organizations_repository_get','P') IS NULL
            THEN 'gone' ELSE 'STILL THERE' END AS get_shim;
PRINT '510 rollback: done. Restart the Api.';
GO
