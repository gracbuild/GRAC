-- =====================================================================
-- 238 sp_resolve_dependency_category_sync -- ROLLBACK
--
-- Drops the procedure. Nothing else touched.
--
-- The Operationalize dependency UI will fail to save until it is rolled
-- back too (the button posts to /resolve/dependency-category, which the
-- controller no longer accepts if you keep 238's app tier).
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_resolve_dependency_category_sync','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_resolve_dependency_category_sync;
    PRINT '238 rollback: sp_resolve_dependency_category_sync dropped.';
END
ELSE
BEGIN
    PRINT '238 rollback: procedure was already absent.';
END
GO

SELECT 'procedure dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_dependency_category_sync','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '';
PRINT '238 rollback complete.';
GO

SET NOEXEC OFF;
GO
