-- =====================================================================
-- 455 rollback: drop ix_pm_org_fw_statement_org_status_scope. ASCII only.
-- =====================================================================
SET NOCOUNT ON;
GO
IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ix_pm_org_fw_statement_org_status_scope'
              AND object_id = OBJECT_ID('grac_practice.organization_framework_statements'))
    DROP INDEX ix_pm_org_fw_statement_org_status_scope
        ON grac_practice.organization_framework_statements;
GO
PRINT '455 rollback complete.';
GO
