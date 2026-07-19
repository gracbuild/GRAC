-- =====================================================================
-- 059 Organization group sidebar reshape -- ROLLBACK
--
-- Restores the pre-059 sidebar shape:
--   * organization-administration -> Inactive, parent_menu_id NULL
--     (matches 051's wrapper deactivation).
--   * organizations (Organization Onboarding) -> Active,
--     parented to nav-organization (matches 052's placement).
--
-- ASCII-only. Idempotent.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

-- Re-inactivate organization-administration and clear its parent so it
-- looks like it did after 051.
UPDATE grac_practice.menu_master
   SET status         = N'Inactive',
       parent_menu_id = NULL,
       updated_by     = 'rollback-059',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'organization-administration'
   AND updated_by IN ('seed-059');

-- Reactivate organizations under nav-organization.
DECLARE @org_parent_id BIGINT = (
    SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-organization'
);

UPDATE grac_practice.menu_master
   SET status         = N'Active',
       parent_menu_id = COALESCE(parent_menu_id, @org_parent_id),
       updated_by     = 'rollback-059',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'organizations'
   AND updated_by = 'seed-059';

COMMIT TRAN;

SELECT menu_key, menu_name, menu_url, parent_menu_id, display_order, status
FROM grac_practice.menu_master
WHERE menu_key IN (N'organizations', N'organization-administration');

PRINT '059 rollback complete.';
GO
