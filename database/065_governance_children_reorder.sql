-- =====================================================================
-- 065 Governance sidebar reorder + Practices label refresh
--
-- Target Governance children order (top -> bottom):
--     100  Repository Subscriptions    organization-controls
--     105  Source Statements           source-statements
--     110  Organization Practices      organization-requirements  (renamed
--                                                                  from
--                                                                  'Practices')
--     115  Practice Instances          practice-instances
--     120  Resolve                     resolve                    (LAST)
--
-- Migration 061 already parented 'resolve' to nav-governance at
-- display_order 120, but this migration re-asserts the entire Governance
-- group ordering + confirms 'Organization Practices' as the label the
-- user wants for organization-requirements. Safe to re-run in any state.
--
-- Only menu_name (for organization-requirements) and display_order are
-- changed. menu_key, menu_url, parent_menu_id and permissions stay put
-- so no routing / role permission grant is affected.
--
-- ASCII-only. Idempotent.
-- Rollback: database/065_governance_children_reorder_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    RAISERROR('065: prerequisites missing (schema grac_practice or menu_master).', 16, 1);
    SET NOEXEC ON;
END
GO

DECLARE @gov_parent_id BIGINT = (
    SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-governance'
);

IF @gov_parent_id IS NULL
BEGIN
    RAISERROR('065: nav-governance parent row is missing. Run 052_menu_parent_hierarchy.sql first.', 16, 1);
    RETURN;
END

BEGIN TRAN;

-- ---------------------------------------------------------------------------
-- Step 1 -- Re-assert the ordered children of nav-governance.
--           parent_menu_id / status set defensively so any row that some
--           earlier migration accidentally moved snaps back in.
-- ---------------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET display_order  = 100,
       parent_menu_id = @gov_parent_id,
       status         = N'Active',
       updated_by     = 'seed-065',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'organization-controls';

UPDATE grac_practice.menu_master
   SET display_order  = 105,
       parent_menu_id = @gov_parent_id,
       status         = N'Active',
       updated_by     = 'seed-065',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'source-statements';

UPDATE grac_practice.menu_master
   SET menu_name      = N'Organization Practices',
       display_order  = 110,
       parent_menu_id = @gov_parent_id,
       status         = N'Active',
       updated_by     = 'seed-065',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'organization-requirements';

UPDATE grac_practice.menu_master
   SET display_order  = 115,
       parent_menu_id = @gov_parent_id,
       status         = N'Active',
       updated_by     = 'seed-065',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'practice-instances';

UPDATE grac_practice.menu_master
   SET display_order  = 120,
       parent_menu_id = @gov_parent_id,
       module_type    = N'Governance',
       status         = N'Active',
       updated_by     = 'seed-065',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'resolve';

COMMIT TRAN;

-- ---------------------------------------------------------------------------
-- Sanity report
-- ---------------------------------------------------------------------------
SELECT c.display_order  AS Ord,
       c.menu_key       AS Key_,
       c.menu_name      AS Name_,
       c.menu_url       AS Url,
       c.status         AS Status
FROM grac_practice.menu_master c
JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
WHERE p.menu_key = N'nav-governance'
ORDER BY c.display_order;

PRINT '065 Governance sidebar reorder complete.';
PRINT '  Order: Repository Subscriptions -> Source Statements ->';
PRINT '         Organization Practices -> Practice Instances -> Resolve.';
GO

SET NOEXEC OFF;
GO
