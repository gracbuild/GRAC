-- =====================================================================
-- 468 Add missing foreign keys found while diagnosing 192's ORG_RETAIN
--     Msg 51007 block
--
-- WHY
-- ---
-- 192_practice_data_reset.sql's ORG_RETAIN scope resolves organization_id
-- for every row-filtered table generically, off sys.foreign_keys -- a
-- direct column, or an unambiguous FK hop to an already-resolved table.
-- Two tables came back BLOCKED with no FK at all, even though each one's
-- own columns clearly identify which row(s) it is about:
--
--   asset_duplicate_decision(asset_id_low, asset_id_high)
--     -- a decision that two specific assets are NOT duplicates of each
--     -- other (442_asset_discovery.sql). Both columns are plain BIGINT,
--     -- never declared against organization_dependency_asset.
--
--   requirement_control_correction_log(organization_requirement_id)
--     -- the audit log 350_correct_ambiguous_requirement_control_links.sql
--     -- writes to before any UPDATE, so a rollback restores the exact
--     -- prior value. The column is plain BIGINT, never declared against
--     -- organization_requirement.
--
-- Both are genuine schema gaps, not tables that need special-casing in
-- 192 itself -- once the FK exists, 192's existing generic resolver (and,
-- for the second one, the existing @CatalogueRoots FK-closure, since
-- organization_requirement is already a named root) picks both up with
-- zero changes to 192.
--
-- WHAT
-- ----
--   1. fk_pm_asset_dup_dec_low  : asset_duplicate_decision.asset_id_low  -> organization_dependency_asset(asset_id)
--      fk_pm_asset_dup_dec_high : asset_duplicate_decision.asset_id_high -> organization_dependency_asset(asset_id)
--   2. fk_pm_req_ctrl_correction_req : requirement_control_correction_log.organization_requirement_id -> organization_requirement(organization_requirement_id)
--
-- Both checks run WITH CHECK (the default) -- if either table already
-- holds an orphaned id (pointing at a row that no longer exists), the
-- ALTER TABLE fails loudly with the offending id, rather than silently
-- adding the constraint NOCHECK and hiding a real data problem.
--
-- Re-runnable. ASCII-only. Error codes 57468.
-- Rollback: 468_add_missing_catalogue_fks_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.asset_duplicate_decision','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_dependency_asset','U') IS NULL
   OR OBJECT_ID('grac_practice.requirement_control_correction_log','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_requirement','U') IS NULL
BEGIN
    RAISERROR('468: prerequisites missing (442, 002, 350, 001).', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. asset_duplicate_decision -> organization_dependency_asset
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_asset_dup_dec_low')
BEGIN
    ALTER TABLE grac_practice.asset_duplicate_decision
        ADD CONSTRAINT fk_pm_asset_dup_dec_low
            FOREIGN KEY (asset_id_low) REFERENCES grac_practice.organization_dependency_asset(asset_id);
    PRINT '468: fk_pm_asset_dup_dec_low added.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_asset_dup_dec_high')
BEGIN
    ALTER TABLE grac_practice.asset_duplicate_decision
        ADD CONSTRAINT fk_pm_asset_dup_dec_high
            FOREIGN KEY (asset_id_high) REFERENCES grac_practice.organization_dependency_asset(asset_id);
    PRINT '468: fk_pm_asset_dup_dec_high added.';
END
GO

-- =====================================================================
-- 2. requirement_control_correction_log -> organization_requirement
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_req_ctrl_correction_req')
BEGIN
    ALTER TABLE grac_practice.requirement_control_correction_log
        ADD CONSTRAINT fk_pm_req_ctrl_correction_req
            FOREIGN KEY (organization_requirement_id) REFERENCES grac_practice.organization_requirement(organization_requirement_id);
    PRINT '468: fk_pm_req_ctrl_correction_req added.';
END
GO

PRINT '468: done.';
GO
