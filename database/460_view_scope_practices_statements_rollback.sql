-- =====================================================================
-- 460_view_scope_practices_statements_rollback.sql
-- Drops the two predicates added by 460. Roll back the Api build first
-- (it calls them), or Organization Practices / Control Statements fail.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.fn_pm_view_scope_statement') IS NOT NULL
    DROP FUNCTION grac_practice.fn_pm_view_scope_statement;
GO
IF OBJECT_ID('grac_practice.fn_pm_view_scope_requirement') IS NOT NULL
    DROP FUNCTION grac_practice.fn_pm_view_scope_requirement;
GO
PRINT 'Rollback 460 applied.';
GO
