-- =====================================================================
-- 454 rollback: drop ix_pm_org_stmt_practice_map_statement. ASCII only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ix_pm_org_stmt_practice_map_statement'
              AND object_id = OBJECT_ID('grac_practice.organization_statement_practice_mapping'))
    DROP INDEX ix_pm_org_stmt_practice_map_statement
        ON grac_practice.organization_statement_practice_mapping;
GO

PRINT '454 rollback complete.';
GO
