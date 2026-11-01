-- =====================================================================
-- 455 Performance: covering index for the Practices grid's
--     statement-scope EXISTS (organization-requirements/query)
--
-- WHAT AND WHY
-- ------------
-- The Practices grid (organization-requirements/query, inline SQL in
-- QueryOrganizationRequirementFallbackAsync) lists practices for an org.
-- On the LIST view (no control drilled in, @organization_control_id
-- NULL) it evaluates EVERY requirement in the organization, and for each
-- it runs the PracticeStatementScopeSql EXISTS. That EXISTS filters
-- grac_practice.organization_framework_statements by
-- (organization_id, status) and reads org_statement_id, release_id and
-- applicability_status_id.
--
-- The existing index ix_pm_org_framework_statement_org_release is keyed
-- (organization_id, release_id, status) and does NOT carry
-- org_statement_id, so that EXISTS seeks on organization_id, scans the
-- release partitions, and does a clustered key lookup per statement row
-- to fetch org_statement_id -- repeated for every requirement on the
-- page. Measured: ~122,000 logical reads for a 25-row page (~1.2 s).
--
-- This adds a covering index keyed (organization_id, status) that
-- INCLUDEs org_statement_id, release_id and applicability_status_id, so
-- the scope EXISTS becomes an index-only seek with no key lookups.
-- Pure additive index; no behaviour change. Idempotent (guards on table,
-- columns and index name). ASCII only. Rollback drops it.
--
-- NOTE: this reduces the per-row cost of the scope check. On very large
-- organizations the check is still evaluated once per requirement
-- (O(requirements)); a set-based rewrite of that scope test is the
-- deeper fix and is tracked separately.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.organization_framework_statements','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.organization_framework_statements','organization_id')       IS NOT NULL
   AND COL_LENGTH('grac_practice.organization_framework_statements','status')                IS NOT NULL
   AND COL_LENGTH('grac_practice.organization_framework_statements','org_statement_id')       IS NOT NULL
   AND COL_LENGTH('grac_practice.organization_framework_statements','release_id')             IS NOT NULL
   AND COL_LENGTH('grac_practice.organization_framework_statements','applicability_status_id') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ix_pm_org_fw_statement_org_status_scope'
                      AND object_id = OBJECT_ID('grac_practice.organization_framework_statements'))
BEGIN
    EXEC(N'CREATE INDEX ix_pm_org_fw_statement_org_status_scope
            ON grac_practice.organization_framework_statements(organization_id, status)
            INCLUDE (org_statement_id, release_id, applicability_status_id);');
    PRINT '455: ix_pm_org_fw_statement_org_status_scope created.';
END
ELSE
    PRINT '455: index already present or columns missing -- nothing to do.';
GO

PRINT '455 complete.';
GO
