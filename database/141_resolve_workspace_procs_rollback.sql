-- =====================================================================
-- 141 Resolve workspace procedures -- ROLLBACK
--
-- Drops the six procedures. No data is touched: adoption rows, evidence
-- rows and dependency resolutions are all left exactly as they are, so
-- re-running 141 restores full function.
--
-- Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_resolve_dependency_save','P')   IS NOT NULL DROP PROCEDURE grac_practice.sp_resolve_dependency_save;
GO
IF OBJECT_ID('grac_practice.sp_resolve_dependency_list','P')   IS NOT NULL DROP PROCEDURE grac_practice.sp_resolve_dependency_list;
GO
IF OBJECT_ID('grac_practice.sp_resolve_obligation_adopt','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_resolve_obligation_adopt;
GO
IF OBJECT_ID('grac_practice.sp_resolve_obligation_list','P')   IS NOT NULL DROP PROCEDURE grac_practice.sp_resolve_obligation_list;
GO
IF OBJECT_ID('grac_practice.sp_resolve_instance_detail','P')   IS NOT NULL DROP PROCEDURE grac_practice.sp_resolve_instance_detail;
GO
IF OBJECT_ID('grac_practice.sp_resolve_instance_list','P')     IS NOT NULL DROP PROCEDURE grac_practice.sp_resolve_instance_list;
GO

SELECT 'resolve procedures dropped' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM sys.objects
                WHERE type = 'P' AND SCHEMA_NAME(schema_id) = 'grac_practice'
                  AND name LIKE 'sp_resolve_%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- Untouched by this rollback.
SELECT (SELECT COUNT(*) FROM grac_practice.practice_instance_obligation)   AS AdoptionRows,
       (SELECT COUNT(*) FROM grac_practice.practice_dependency_resolution) AS DependencyResolutions;

PRINT '141 rolled back. Procedures dropped; no data changed.';
GO
