-- =====================================================================
-- 515  vw_repo_src_framework_statement: classifications through the 478
--      functions (fixes Msg 8711 in change detection)
--
-- FOUND (2026-11-04, diagnose_change_detect_8711_b.sql on UAT)
--   The live vw_repo_src_framework_statement is an EARLY DRAFT of 478:
--
--       OUTER APPLY (SELECT STRING_AGG(...) WITHIN GROUP (ORDER BY id)      AS classification_ids,
--                           STRING_AGG(...) WITHIN GROUP (ORDER BY display_order, name)
--                                                                         AS classification_names
--                    FROM ...) cls
--
--   Two ordered aggregates with different orderings in ONE scope is
--   exactly what SQL Server refuses with Msg 8711.  The final 478 replaced
--   that APPLY with fn_repo_statement_classification_ids / _names (WITH
--   INLINE = OFF), so each ordering lives in its own function.  On UAT the
--   two functions exist but the view was never rebuilt to call them --
--   which is why every query that reads the view's classification or hash
--   columns (change detection's Statement step) fails, and why 514 could
--   not help.
--
-- FIX
--   Rebuild the view exactly as 478 section 3c does: the same builder, the
--   same @extra_select, classification_id left out.  The view keeps the
--   same columns, names and values -- the ids and names strings are built
--   by the same expressions -- so content_hash is unchanged and nothing has
--   to be re-baselined.  The rebuilt view is then read the ways that
--   failed (every row, a join + GROUP BY, a FOR JSON); if any read fails
--   the previous definition is put back and the script stops.
--
-- SAFE TO RE-RUN (does nothing once the view calls the functions).
-- Requires 478's functions and builder.
-- Rollback: 515_statement_view_classification_functions_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.fn_repo_statement_classification_ids','FN') IS NULL
   OR OBJECT_ID('grac_practice.fn_repo_statement_classification_names','FN') IS NULL
   OR OBJECT_ID('grac_practice.sp_repo_build_source_view','P') IS NULL
   OR OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_repo_build_source_view')) NOT LIKE '%@exclude_columns%'
   OR COL_LENGTH('grac_practice.organization_framework_statements','classification_ids') IS NULL
BEGIN
    PRINT 'ABORT (515): 478 is not fully applied (functions / builder / copy columns missing). Run 478 first. Nothing was changed.';
    SET NOEXEC ON;
END
GO

IF OBJECT_DEFINITION(OBJECT_ID('grac_practice.vw_repo_src_framework_statement')) LIKE '%fn_repo_statement_classification_ids%'
BEGIN
    PRINT '515: vw_repo_src_framework_statement already calls the classification functions. Nothing to do.';
    SET NOEXEC ON;
END
GO

DECLARE @previous NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.vw_repo_src_framework_statement'));

-- Same call as 478 section 3c.
EXEC grac_practice.sp_repo_build_source_view
     @source_table    = N'grac_new.framework_statement',
     @view_name       = N'vw_repo_src_framework_statement',
     @extra_select    = N'grac_practice.fn_repo_statement_classification_ids(src.framework_statement_id) AS classification_ids,
           grac_practice.fn_repo_statement_classification_names(src.framework_statement_id) AS classification_names',
     @exclude_columns = N'classification_id';

-- Read it the ways that failed.  On failure, put the previous view back.
BEGIN TRY
    EXEC sp_executesql N'DECLARE @c INT;
        SELECT @c = CHECKSUM_AGG(CHECKSUM(v.content_hash, v.classification_ids, v.classification_names))
        FROM grac_practice.vw_repo_src_framework_statement v;
        SELECT @c = COUNT(*) FROM (
            SELECT ofs.organization_id, COUNT(*) AS n,
                   SUM(CASE WHEN ofs.source_version_hash <> v.content_hash THEN 1 ELSE 0 END) AS behind
            FROM   grac_practice.organization_framework_statements ofs
            JOIN   grac_practice.vw_repo_src_framework_statement v
                   ON v.framework_statement_id = ofs.framework_statement_id
            GROUP  BY ofs.organization_id) x;
        DECLARE @j NVARCHAR(MAX) = (SELECT TOP (50) v.* FROM grac_practice.vw_repo_src_framework_statement v
                                    FOR JSON PATH);';
END TRY
BEGIN CATCH
    DECLARE @why NVARCHAR(2048) = ERROR_MESSAGE();
    -- The stored text starts with CREATE VIEW; make it re-runnable.
    DECLARE @restore NVARCHAR(MAX) =
        STUFF(@previous, PATINDEX('%CREATE%VIEW%', @previous), LEN('CREATE'), N'CREATE OR ALTER');
    EXEC sp_executesql @restore;
    PRINT '515: the rebuilt view could not be read; the previous definition was put back. ' + @why;
    THROW 53991, 'ABORT (515): see the message above. Nothing else was changed.', 1;
END CATCH;

PRINT '515: vw_repo_src_framework_statement rebuilt on the classification functions.';
GO

-- 515-a  the view calls the functions
SELECT N'515-a view uses functions' AS [Check],
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.vw_repo_src_framework_statement'))
                 LIKE '%fn_repo_statement_classification_names%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.vw_repo_src_framework_statement'))
                 NOT LIKE '%WITHIN GROUP%'
            THEN N'PASS' ELSE N'FAIL' END AS Result;
GO

-- 515-b  copies whose stored hash differs from the source now.  These are
--        real Control Management changes waiting for detection, NOT caused
--        by this rebuild (the hash expression is unchanged).
SELECT N'515-b statement copies behind source' AS [Check], ofs.organization_id AS OrganizationId,
       COUNT(*) AS Copies,
       SUM(CASE WHEN ofs.source_version_hash <> v.content_hash THEN 1 ELSE 0 END) AS Behind
FROM   grac_practice.organization_framework_statements ofs
JOIN   grac_practice.vw_repo_src_framework_statement v
       ON v.framework_statement_id = ofs.framework_statement_id
GROUP  BY ofs.organization_id
ORDER  BY ofs.organization_id;
GO

-- 515-c  a full detection run completes (rolled back -- adds nothing).
SET XACT_ABORT OFF;
DECLARE @ok NVARCHAR(10) = N'PASS', @why NVARCHAR(4000) = NULL, @r INT, @nn INT;
BEGIN TRANSACTION;
BEGIN TRY
    EXEC grac_practice.sp_repository_change_detect
         @actor = N'verify-515', @raised_count = @r OUTPUT, @notified_count = @nn OUTPUT,
         @suppress_result = 1;
END TRY
BEGIN CATCH
    SELECT @ok = N'FAIL', @why = CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE());
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
SELECT N'515-c full detection run (rolled back)' AS [Check], @ok AS Result,
       @r AS WouldRaise, @why AS Error;
GO

PRINT '515 complete. Now run EXEC grac_practice.sp_repository_change_detect (or let the worker run).';
GO
SET NOEXEC OFF;
GO
