-- =====================================================================
-- 062 Rename Organization group children to drop the redundant prefix
--
-- Before this migration:
--   Organization
--     Organization Administration
--     Organization Dependencies
--
-- After this migration:
--   Organization
--     Administration
--     Dependencies
--
-- Only menu_name is updated. menu_key, menu_url, parent_menu_id,
-- display_order, module_type, status and permissions all stay put so no
-- downstream code / routing / role permission grant is affected.
--
-- ASCII-only. Idempotent -- safe to re-run.
-- Rollback: database/062_organization_children_rename_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    RAISERROR('062: prerequisites missing (schema grac_practice or menu_master).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

UPDATE grac_practice.menu_master
   SET menu_name  = N'Administration',
       updated_by = 'seed-062',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'organization-administration';

UPDATE grac_practice.menu_master
   SET menu_name  = N'Dependencies',
       updated_by = 'seed-062',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'organization-dependencies';

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
WHERE p.menu_key = N'nav-organization'
ORDER BY c.status DESC, c.display_order;

PRINT '062 Organization children rename complete.';
PRINT '  Organization Administration -> Administration.';
PRINT '  Organization Dependencies   -> Dependencies.';
GO

SET NOEXEC OFF;
GO
