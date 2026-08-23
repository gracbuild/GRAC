-- =====================================================================
-- 155 Document module menu regroup -- ROLLBACK
--
-- Puts the three document menus back under nav-oversight with the
-- display_order values from 149/152/154 and drops nav-documents.
-- =====================================================================
SET NOCOUNT ON;
GO

DECLARE @oversight_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight');
IF @oversight_id IS NULL
BEGIN
    PRINT '155 rollback: nav-oversight missing; leaving children re-parented as-is.';
END
ELSE
BEGIN
    UPDATE grac_practice.menu_master
       SET parent_menu_id = @oversight_id,
           module_type    = N'Oversight',
           display_order  = CASE menu_key
                              WHEN N'document-uploads'          THEN 240
                              WHEN N'document-acknowledgements' THEN 250
                              WHEN N'my-acknowledgements'       THEN 260
                              ELSE display_order
                            END,
           updated_by     = 'rollback-155',
           updated_dt     = SYSUTCDATETIME()
     WHERE menu_key IN (N'document-uploads', N'document-acknowledgements', N'my-acknowledgements');
END
GO

-- Drop the new parent + its role grants
DECLARE @docs_parent_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-documents');
IF @docs_parent_id IS NOT NULL
BEGIN
    DELETE FROM grac_practice.organization_role_menu_permission WHERE menu_id = @docs_parent_id;
    DELETE FROM grac_practice.menu_master WHERE menu_id = @docs_parent_id;
END
GO

PRINT '155 rollback complete.';
GO
