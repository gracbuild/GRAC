-- =====================================================================
-- 454 Performance: index the statement->practice mapping for the
--     Control Statements (release-statements) drill-down
--
-- WHAT AND WHY
-- ------------
-- The Control Statements screen loads a framework release through
-- QueryReleaseStatementsAsync (inline SQL in PracticeRepositoryService).
-- Two aggregate CTEs there -- statement_practice_counts and
-- statement_implementation -- both start from
-- grac_practice.organization_statement_practice_mapping, filter on
-- (organization_id, status) and GROUP BY framework_statement_id,
-- counting DISTINCT org_practice_id.
--
-- That table (added by the repository-copy phase, 391/392) carries only
-- its PK and UNIQUE(organization_id, org_statement_id, org_practice_id).
-- Neither leads on framework_statement_id, so every Control Statements
-- load scans the organization's whole mapping set and sorts it to do the
-- GROUP BY -- the cost grows with the organization, which is exactly the
-- slowness seen once real UAT data arrived. 029_performance_indexes.sql
-- predates this table, so it never covered it.
--
-- This adds a covering index keyed (organization_id, status,
-- framework_statement_id) with org_practice_id as an included column, so
-- both CTEs become an index seek + ordered stream aggregate with no table
-- touch. Pure additive index; no behaviour change. Idempotent (guards on
-- the table, the columns, and the index name). ASCII only.
-- Rollback drops the index.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.organization_statement_practice_mapping','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.organization_statement_practice_mapping','organization_id')       IS NOT NULL
   AND COL_LENGTH('grac_practice.organization_statement_practice_mapping','status')                IS NOT NULL
   AND COL_LENGTH('grac_practice.organization_statement_practice_mapping','framework_statement_id') IS NOT NULL
   AND COL_LENGTH('grac_practice.organization_statement_practice_mapping','org_practice_id')        IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ix_pm_org_stmt_practice_map_statement'
                      AND object_id = OBJECT_ID('grac_practice.organization_statement_practice_mapping'))
BEGIN
    EXEC(N'CREATE INDEX ix_pm_org_stmt_practice_map_statement
            ON grac_practice.organization_statement_practice_mapping
               (organization_id, status, framework_statement_id)
            INCLUDE (org_practice_id);');
    PRINT '454: ix_pm_org_stmt_practice_map_statement created.';
END
ELSE
    PRINT '454: index already present or columns missing -- nothing to do.';
GO

PRINT '454 complete.';
GO
