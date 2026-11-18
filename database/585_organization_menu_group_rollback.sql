-- 585 rollback: the Organization parent opens the Organization
-- Administration page again (575's page-parent).
SET NOCOUNT ON;
GO
UPDATE grac_practice.menu_master
   SET menu_url = N'Practice/Index/organization-administration', updated_by = N'rollback-585', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'organization-administration' AND menu_url IS NULL;
PRINT '585 rolled back: organization-administration url restored, rows = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO
