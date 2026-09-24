-- =====================================================================
-- 262 Risk practice/asset mapping procedures ROLLBACK
--
-- Reverses 262_risk_mapping_procs.sql.
--
-- 262 created only NEW objects -- it rewrote nothing that existed before
-- it. So this rollback is a straight set of drops with no "re-run the
-- earlier migration" step, which is the part 258's and 264's rollbacks
-- both need and this one does not.
--
-- ORDER: procedures before the function. Dropping an inline TVF that a
-- compiled procedure still references succeeds silently in SQL Server
-- and leaves the procedure failing at run time instead of at drop time
-- -- so the procedures go first and the failure cannot be deferred.
--
-- NO DATA IS TOUCHED. risk_practice_map, risk_asset_map and
-- risk_asset_map_source keep every row. They are 261's tables, and
-- 261's rollback is what removes them. Running this file leaves the
-- mappings intact and unreachable, which is the correct state for
-- "the code is rolled back, the data is not".
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_risk_mapping_options','P')     IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_mapping_options;
IF OBJECT_ID('grac_practice.sp_risk_mapping_get','P')         IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_mapping_get;
IF OBJECT_ID('grac_practice.sp_risk_asset_unmap','P')         IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_asset_unmap;
IF OBJECT_ID('grac_practice.sp_risk_asset_map_direct','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_asset_map_direct;
IF OBJECT_ID('grac_practice.sp_risk_practice_unmap','P')      IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_practice_unmap;
IF OBJECT_ID('grac_practice.sp_risk_practice_map','P')        IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_practice_map;
IF OBJECT_ID('grac_practice.sp_risk_mapping_sync_primary','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_mapping_sync_primary;
GO

-- 263 and 264 both call fn_risk_practice_assets. Warn rather than
-- refuse: dropping the function while they are installed is a valid
-- thing to do mid-rollback, as long as the operator knows the next two
-- files are now compiled against something that has gone.
IF OBJECT_ID('grac_practice.sp_risk_treatment_option_set','P') IS NOT NULL
   OR OBJECT_ID('grac_practice.sp_risk_review_due_list','P')   IS NOT NULL
BEGIN
    PRINT '262-rollback WARNING: 263/264 procedures are still installed and some';
    PRINT '     of them reference fn_risk_practice_assets. Roll those back too,';
    PRINT '     or they will fail at run time rather than at drop time.';
END
GO

IF OBJECT_ID('grac_practice.fn_risk_practice_assets','IF') IS NOT NULL
    DROP FUNCTION grac_practice.fn_risk_practice_assets;
GO

SELECT '262 rollback complete' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_practice_map','P')     IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_asset_map_direct','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_mapping_get','P')      IS NULL
             AND OBJECT_ID('grac_practice.fn_risk_practice_assets','IF') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '262-rollback done. Mapping DATA is untouched -- run 261-rollback to drop it.';
GO

SET NOEXEC OFF;
GO
