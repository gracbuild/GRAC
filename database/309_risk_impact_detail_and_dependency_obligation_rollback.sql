-- =====================================================================
-- 309 Risk Centre -- Impact Details and dependency attribution -- ROLLBACK
--
-- 309 IS WITHDRAWN. Run this ONLY if 309 was applied before the feature
-- was withdrawn -- on a database where it never ran, every DROP below is
-- guarded and this script is a no-op that reports so. The forward script
-- now aborts on purpose; the reasoning is in its banner and in
-- docs/risk-obligation-structure.md. Run it with the default
-- @KeepData = 0 unless somebody genuinely recorded impacts against the
-- withdrawn feature.
--
-- Drops what 309 added, in dependency order:
--   1. the six procedures
--   2. risk_dependency_obligation      (attributions)
--   3. risk_impact_detail              (the records)
--   4. risk_impact_area_master         (the seed)
--   5. the history rows 309's procedures wrote
--
-- WHAT THIS DELETES, SAID PLAINLY
--   Impact Details are the only place those records exist -- nothing
--   else in the schema carries them -- so dropping the table deletes
--   them. That is what rolling back this feature means. @KeepData = 1
--   drops the PROCEDURES and leaves the three tables and their contents
--   in place, which is the safer option if any impact has been recorded
--   in earnest.
--
--   Dependency attributions are safe to lose either way: the
--   dependencies themselves live in risk_dependency_map, which 309 never
--   touched. Removing an attribution cannot remove a dependency from a
--   risk.
--
-- Re-runnable: yes.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @KeepData BIT = 0;   -- 1 = drop only the procedures

-- ---------------------------------------------------------------------
-- What would be lost, before anything is dropped.
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.risk_impact_detail','U') IS NOT NULL
    SELECT 'Impact details that will be deleted (unless @KeepData = 1)' AS Check_,
           COUNT(*) AS Rows_
    FROM   grac_practice.risk_impact_detail;

IF OBJECT_ID('grac_practice.risk_dependency_obligation','U') IS NOT NULL
    SELECT 'Dependency attributions that will be deleted' AS Check_,
           COUNT(*) AS Rows_
    FROM   grac_practice.risk_dependency_obligation;
GO

-- ---------------------------------------------------------------------
-- 1. Procedures
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_risk_dependency_obligation_list','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_risk_dependency_obligation_list;
    PRINT '309 rollback: sp_risk_dependency_obligation_list dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_risk_dependency_obligation_set','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_risk_dependency_obligation_set;
    PRINT '309 rollback: sp_risk_dependency_obligation_set dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_risk_impact_detail_retire','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_risk_impact_detail_retire;
    PRINT '309 rollback: sp_risk_impact_detail_retire dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_risk_impact_detail_save','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_risk_impact_detail_save;
    PRINT '309 rollback: sp_risk_impact_detail_save dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_risk_impact_detail_list','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_risk_impact_detail_list;
    PRINT '309 rollback: sp_risk_impact_detail_list dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_risk_impact_area_list','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_risk_impact_area_list;
    PRINT '309 rollback: sp_risk_impact_area_list dropped.';
END
GO

-- ---------------------------------------------------------------------
-- 2-4. Tables. risk_impact_detail before risk_impact_area_master -- it
--      references it.
-- ---------------------------------------------------------------------
DECLARE @KeepData BIT = 0;   -- keep in step with the value above

IF @KeepData = 1
    PRINT '309 rollback: @KeepData = 1 -- tables and their rows kept.';
ELSE
BEGIN
    IF OBJECT_ID('grac_practice.risk_dependency_obligation','U') IS NOT NULL
    BEGIN
        DROP TABLE grac_practice.risk_dependency_obligation;
        PRINT '309 rollback: risk_dependency_obligation dropped.';
    END

    IF OBJECT_ID('grac_practice.risk_impact_detail','U') IS NOT NULL
    BEGIN
        DROP TABLE grac_practice.risk_impact_detail;
        PRINT '309 rollback: risk_impact_detail dropped.';
    END

    IF OBJECT_ID('grac_practice.risk_impact_area_master','U') IS NOT NULL
    BEGIN
        DROP TABLE grac_practice.risk_impact_area_master;
        PRINT '309 rollback: risk_impact_area_master dropped.';
    END
END
GO

-- ---------------------------------------------------------------------
-- 5. The history rows 309's procedures wrote.
--
--    Keyed on the five action codes 309 introduced, so nothing else in
--    risk_register_history can match. Left alone when @KeepData = 1:
--    the records are still there, so their history should be too.
-- ---------------------------------------------------------------------
DECLARE @KeepData2 BIT = 0;   -- keep in step with the value above

IF @KeepData2 = 0 AND OBJECT_ID('grac_practice.risk_register_history','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.risk_register_history
     WHERE action_code IN (N'ImpactDetailAdded', N'ImpactDetailEdited',
                           N'ImpactDetailRetired', N'DependencyObligationSet',
                           N'DependencyObligationCleared');

    PRINT '309 rollback: history rows deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END
GO

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
DECLARE @KeepData3 BIT = 0;   -- keep in step with the value above

SELECT '309 rollback-a procedures gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_impact_detail_save','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_impact_detail_list','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_impact_detail_retire','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_impact_area_list','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_dependency_obligation_set','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_dependency_obligation_list','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '309 rollback-b tables gone (or kept on purpose)',
       CASE WHEN @KeepData3 = 1 THEN 'SKIPPED (@KeepData)'
            WHEN OBJECT_ID('grac_practice.risk_impact_detail','U') IS NULL
             AND OBJECT_ID('grac_practice.risk_impact_area_master','U') IS NULL
             AND OBJECT_ID('grac_practice.risk_dependency_obligation','U') IS NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- The point of the whole design: 309 never owned the dependencies, so a
-- rollback cannot have cost any.
SELECT '309 rollback-c risk_dependency_map untouched',
       CASE WHEN OBJECT_ID('grac_practice.risk_dependency_map','U') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.key_constraints
                          WHERE name = 'uq_pm_risk_dependency_map')
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '309 rollback complete.';
GO

SET NOEXEC OFF;
GO
