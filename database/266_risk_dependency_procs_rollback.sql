-- =====================================================================
-- 266 Risk dependency mapping procedures ROLLBACK
--
-- Reverses 266_risk_dependency_procs.sql.
--
-- RUN 265's ROLLBACK AFTER THIS ONE, NOT BEFORE. 266's procedures read
-- risk_dependency_map, which 265's rollback drops.
--
-- RESTORING 262 IS NOT AUTOMATIC. 266 dropped fn_risk_practice_assets,
-- sp_risk_asset_map_direct and sp_risk_asset_unmap, and REWROTE
-- sp_risk_practice_map / _unmap / _mapping_get / _mapping_options /
-- _mapping_sync_primary. Re-running 262 restores all of them -- it is
-- CREATE OR ALTER throughout -- but those bodies reference risk_asset_map,
-- which only exists again once 265's rollback has recreated it.
--
-- So the correct full sequence back to the asset-only world is:
--     1. this file
--     2. 265_risk_dependency_mapping_schema_rollback.sql
--     3. re-run 262_risk_mapping_procs.sql
--     4. re-run 264 (its list/get were rewritten by 265 section 5)
-- Each step's own PRINT repeats the next one.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_risk_mapping_options','P')      IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_mapping_options;
IF OBJECT_ID('grac_practice.sp_risk_mapping_get','P')          IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_mapping_get;
IF OBJECT_ID('grac_practice.sp_risk_dependency_unmap','P')     IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_dependency_unmap;
IF OBJECT_ID('grac_practice.sp_risk_dependency_map_direct','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_dependency_map_direct;
IF OBJECT_ID('grac_practice.sp_risk_practice_unmap','P')       IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_practice_unmap;
IF OBJECT_ID('grac_practice.sp_risk_practice_map','P')         IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_practice_map;
IF OBJECT_ID('grac_practice.sp_risk_mapping_sync_primary','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_mapping_sync_primary;
GO

IF OBJECT_ID('grac_practice.fn_risk_practice_dependencies','IF') IS NOT NULL
    DROP FUNCTION grac_practice.fn_risk_practice_dependencies;
GO

SELECT '266 rollback complete' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_dependency_map_direct','P')   IS NULL
             AND OBJECT_ID('grac_practice.fn_risk_practice_dependencies','IF')  IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_mapping_get','P')             IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '266-rollback done. Mapping DATA is untouched.';
PRINT '     NEXT: 265_risk_dependency_mapping_schema_rollback.sql, then';
PRINT '           re-run 262_risk_mapping_procs.sql and 264_risk_acceptance_review_procs.sql.';
GO

SET NOEXEC OFF;
GO
