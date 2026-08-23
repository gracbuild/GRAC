-- =====================================================================
-- 191 Rename Governance sidebar entry: "Resolve" -> "Operationalize"
--
-- Sir's ask (2026-08-14): the menu label under Governance should read
-- "Operationalize" instead of "Resolve". The URL slug / menu_key stays
-- 'resolve' -- rewriting the key would break every hard-coded route
-- (`/Practice/Index/resolve`, PracticeScreen.All, WorkflowController
-- fetches, etc.). Only the human-facing label changes.
--
-- Rollback: 191_rename_resolve_to_operationalize_rollback.sql restores
-- the "Resolve" label.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

UPDATE grac_practice.menu_master
   SET menu_name = N'Operationalize',
       updated_by = 'seed-191',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'resolve';

COMMIT TRAN;
GO

-- Sanity: confirm the row is present + renamed.
SELECT menu_key, menu_name, module_type, display_order, status
FROM grac_practice.menu_master
WHERE menu_key = N'resolve';

PRINT '191 renamed Governance/resolve label to Operationalize.';
GO
