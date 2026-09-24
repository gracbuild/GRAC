-- =====================================================================
-- 313 Risk Type schema -- ROLLBACK
--
-- Drops what 313 added, children first:
--   1. risk_analysis_risk_type   (the versioned audit sets)
--   2. risk_register_risk_type   (the current sets)
--   3. risk_type_master          (the master and its three seeded rows)
--
-- WHAT THIS DELETES, SAID PLAINLY
--   The link tables ARE the risk-type record -- nothing else stores it --
--   so dropping them discards every selection any analyst has made.
--   Unlike 285's rollback there is no legacy column holding a copy,
--   because Risk Type never had one.
--
--   @KeepData = 1 (set it in section 1 below) drops NOTHING and only
--   reports. Use that first if any analysis has been saved since 313
--   went in.
--
-- ORDER MATTERS. The two link tables have foreign keys to
-- risk_type_master, so the master cannot go first -- SQL Server will
-- refuse. Children, then parent.
--
-- RUN 314's ROLLBACK FIRST. Its procedures read these tables; dropping
-- the tables while the procedures exist leaves procedures that fail at
-- run time instead of objects that are cleanly absent.
--
-- Re-runnable: yes.
-- ASCII-only on purpose.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

-- =====================================================================
-- 1. THE ONE KNOB, in the batch that reads it.
--
-- A variable cannot cross a GO, so it is declared here rather than in a
-- header batch where setting it would silently do nothing.
--
--   0 = drop everything 313 created (the default)
--   1 = drop nothing, just report what would go
-- =====================================================================
DECLARE @KeepData BIT = 0;

IF OBJECT_ID('grac_practice.sp_risk_type_selection_set','P') IS NOT NULL
   OR OBJECT_ID('grac_practice.sp_risk_type_selection_get','P') IS NOT NULL
   OR OBJECT_ID('grac_practice.sp_risk_type_list','P') IS NOT NULL
BEGIN
    PRINT 'WARNING (313 rollback): 314s procedures are still present.';
    PRINT '        Run 314_risk_type_procs_rollback.sql first, or they will';
    PRINT '        remain as procedures referring to tables that are gone.';
END

IF @KeepData = 1
BEGIN
    PRINT '313 rollback: @KeepData = 1 -- nothing dropped. What exists now:';

    -- sp_executesql, NOT a static SELECT.
    --
    -- A SELECT has no deferred name resolution: naming a table that does
    -- not exist fails at COMPILE time and takes the whole batch with it,
    -- including the guarded DROPs below -- even under SET NOEXEC ON. So
    -- running this rollback on a database where 313 was never applied
    -- would report "Invalid object name" instead of "nothing to undo".
    -- 264 uses the same device around CREATE VIEW, for the same reason.
    IF OBJECT_ID('grac_practice.risk_type_master','U') IS NOT NULL
        EXEC sp_executesql N'
            SELECT ''risk_type_master rows'' AS Object_,
                   COUNT(*)                  AS Rows_
              FROM grac_practice.risk_type_master;';
    ELSE
        PRINT '        risk_type_master: absent';

    IF OBJECT_ID('grac_practice.risk_analysis_risk_type','U') IS NOT NULL
        EXEC sp_executesql N'
            SELECT ''risk_analysis_risk_type rows'' AS Object_,
                   COUNT(*)                         AS Rows_
              FROM grac_practice.risk_analysis_risk_type;';
    ELSE
        PRINT '        risk_analysis_risk_type: absent';

    IF OBJECT_ID('grac_practice.risk_register_risk_type','U') IS NOT NULL
        EXEC sp_executesql N'
            SELECT ''risk_register_risk_type rows'' AS Object_,
                   COUNT(*)                         AS Rows_
              FROM grac_practice.risk_register_risk_type;';
    ELSE
        PRINT '        risk_register_risk_type: absent';
END
ELSE
BEGIN
    IF OBJECT_ID('grac_practice.risk_analysis_risk_type','U') IS NOT NULL
    BEGIN
        DROP TABLE grac_practice.risk_analysis_risk_type;
        PRINT '313 rollback: risk_analysis_risk_type dropped.';
    END

    IF OBJECT_ID('grac_practice.risk_register_risk_type','U') IS NOT NULL
    BEGIN
        DROP TABLE grac_practice.risk_register_risk_type;
        PRINT '313 rollback: risk_register_risk_type dropped.';
    END

    -- Parent last: both children reference it.
    IF OBJECT_ID('grac_practice.risk_type_master','U') IS NOT NULL
    BEGIN
        DROP TABLE grac_practice.risk_type_master;
        PRINT '313 rollback: risk_type_master dropped.';
    END
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '313r-a risk_analysis_risk_type gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_analysis_risk_type','U') IS NULL
            THEN 'PASS' ELSE 'CHECK -- still present (@KeepData = 1?)' END AS Result
UNION ALL
SELECT '313r-b risk_register_risk_type gone',
       CASE WHEN OBJECT_ID('grac_practice.risk_register_risk_type','U') IS NULL
            THEN 'PASS' ELSE 'CHECK -- still present (@KeepData = 1?)' END
UNION ALL
SELECT '313r-c risk_type_master gone',
       CASE WHEN OBJECT_ID('grac_practice.risk_type_master','U') IS NULL
            THEN 'PASS' ELSE 'CHECK -- still present (@KeepData = 1?)' END
UNION ALL
-- 313 touched nothing else. If either of these ever fails, something
-- outside this migration is wrong.
SELECT '313r-d risk_analysis untouched',
       CASE WHEN OBJECT_ID('grac_practice.risk_analysis','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '313r-e risk_register untouched',
       CASE WHEN OBJECT_ID('grac_practice.risk_register','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '313 rollback complete. Re-running 313 recreates the master and its';
PRINT 'three seeded rows, but NOT the selections analysts had made --';
PRINT 'those existed only in the link tables.';
GO

SET NOEXEC OFF;
GO
