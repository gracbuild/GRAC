-- =====================================================================
-- 061 Dissolve the Operations sidebar group
--
-- Before this migration (state after 052 + 060):
--   Operations parent (nav-operations) contains:
--     dependency-applications
--     dependency-tools
--     dependency-vendors
--     dependency-assets
--     dependency-processes
--     resolve
--
-- After this migration:
--   * resolve moves to the Governance parent (nav-governance) --
--     it belongs alongside Practice / Practice Instance flows.
--   * dependency-{applications,tools,vendors,assets,processes} are
--     inactivated as standalone sidebar entries. They remain reachable
--     as tabs inside the Organization Dependencies workspace, so keeping
--     them at the sidebar level is duplicated clutter.
--   * nav-operations (the group parent itself) is inactivated once its
--     only remaining meaningful child (resolve) is moved out. If any
--     future migration reintroduces Operations-scoped screens, the row
--     can be reactivated by that migration.
--
-- Screen keys remain valid in PracticeScreen.All so any bookmark to
-- /Practice/Index/dependency-* still resolves.
--
-- ASCII-only. Idempotent -- safe to re-run.
-- Rollback: database/061_operations_group_dissolve_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    RAISERROR('061: prerequisites missing (schema grac_practice or menu_master).', 16, 1);
    SET NOEXEC ON;
END
GO

DECLARE @gov_parent_id BIGINT = (
    SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-governance'
);
DECLARE @ops_parent_id BIGINT = (
    SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-operations'
);

IF @gov_parent_id IS NULL
BEGIN
    RAISERROR('061: nav-governance parent row is missing. Run 052_menu_parent_hierarchy.sql first.', 16, 1);
    RETURN;
END

BEGIN TRAN;

-- ---------------------------------------------------------------------------
-- Step 1 -- Move resolve to Governance.
--           display_order 120 places it after practice-instances (115)
--           inside the Governance group.
-- ---------------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET parent_menu_id = @gov_parent_id,
       module_type    = N'Governance',
       display_order  = 120,
       status         = N'Active',
       updated_by     = 'seed-061',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'resolve';

-- ---------------------------------------------------------------------------
-- Step 2 -- Inactivate the standalone dependency sidebar entries. They
--           are already reachable as tabs inside Organization Dependencies.
-- ---------------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET status     = N'Inactive',
       updated_by = 'seed-061',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (
        N'dependency-applications',
        N'dependency-tools',
        N'dependency-vendors',
        N'dependency-assets',
        N'dependency-processes'
   );

-- ---------------------------------------------------------------------------
-- Step 3 -- Inactivate the nav-operations parent itself.
--           No Active child remains after Step 1 + Step 2, so the group
--           header would be an empty toggle. If a future migration adds
--           new Operations-scoped screens, it should reactivate this row
--           in the same batch.
-- ---------------------------------------------------------------------------
IF @ops_parent_id IS NOT NULL
BEGIN
    UPDATE grac_practice.menu_master
       SET status     = N'Inactive',
           updated_by = 'seed-061',
           updated_dt = SYSUTCDATETIME()
     WHERE menu_id = @ops_parent_id;
END

COMMIT TRAN;

-- ---------------------------------------------------------------------------
-- Sanity report
-- ---------------------------------------------------------------------------
SELECT p.menu_key AS ParentKey,
       p.menu_name AS Parent,
       c.menu_key AS ChildKey,
       c.menu_name AS ChildName,
       c.display_order,
       c.status
FROM grac_practice.menu_master p
LEFT JOIN grac_practice.menu_master c ON c.parent_menu_id = p.menu_id
WHERE p.menu_key IN (N'nav-governance', N'nav-operations')
ORDER BY p.menu_key, c.status DESC, c.display_order;

SELECT menu_key, menu_name, menu_url, parent_menu_id, display_order, status
FROM grac_practice.menu_master
WHERE menu_key IN (N'resolve',
                   N'dependency-applications', N'dependency-tools',
                   N'dependency-vendors',      N'dependency-assets',
                   N'dependency-processes',    N'nav-operations');

PRINT '061 Operations group dissolve complete.';
PRINT '  resolve -> Governance (Active).';
PRINT '  dependency-{applications,tools,vendors,assets,processes} -> Inactive.';
PRINT '  nav-operations -> Inactive.';
GO

SET NOEXEC OFF;
GO
