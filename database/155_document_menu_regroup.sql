-- =====================================================================
-- 155 Document module menu regroup
--
-- Moves the three document-module menus (document-uploads,
-- document-acknowledgements, my-acknowledgements) out of nav-oversight
-- and under their OWN top-level parent nav-documents ("Document
-- Management"). Keeps the acknowledgement flow visually together and
-- keeps Oversight focused on Task Center / Gap Center.
--
-- Also grants every organization's Admin role can_view on the new
-- parent so it renders in the sidebar without needing a separate grant
-- pass. Non-admin roles can already see the children they were granted
-- by 149/152/154.
--
-- Idempotent. Rollback puts the children back under nav-oversight and
-- drops the new parent.
--
-- Rollback: 155_document_menu_regroup_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;
IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (155): menu_master missing.'; SET @prereqs_ok = 0; END
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN PRINT 'ABORT (155): organization_role_menu_permission missing.'; SET @prereqs_ok = 0; END
IF NOT EXISTS(SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight')
BEGIN PRINT 'ABORT (155): nav-oversight is missing. Run 052 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 0
BEGIN
    RAISERROR('155_document_menu_regroup: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Insert (or update) the new parent menu row
--    menu_url = NULL so it renders as a collapsible group like the
--    other nav-* parents. display_order 450 places it after Oversight
--    (400 in migration 052) and before Administration.
-- =====================================================================
MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'nav-documents', N'Document Management', 450, N'folder-open', N'Documents')
) AS source(menu_key, menu_name, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name      = source.menu_name,
    menu_url       = NULL,
    parent_menu_id = NULL,
    display_order  = source.display_order,
    icon_class     = source.icon_class,
    module_type    = source.module_type,
    status         = N'Active',
    updated_by     = 'seed-155',
    updated_dt     = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id,
     display_order, icon_class, module_type, status, entered_by)
VALUES
    (source.menu_key, source.menu_name, NULL, NULL,
     source.display_order, source.icon_class, source.module_type, N'Active', 'seed-155');
GO

-- =====================================================================
-- 2. Re-parent the three children under nav-documents
-- =====================================================================
DECLARE @docs_parent_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-documents');
IF @docs_parent_id IS NULL
BEGIN
    RAISERROR('155: nav-documents did not get created.', 16, 1);
    SET NOEXEC ON;
END

UPDATE grac_practice.menu_master
   SET parent_menu_id = @docs_parent_id,
       module_type    = N'Documents',
       display_order  = CASE menu_key
                          WHEN N'document-uploads'          THEN 10
                          WHEN N'document-acknowledgements' THEN 20
                          WHEN N'my-acknowledgements'       THEN 30
                          ELSE display_order
                        END,
       updated_by     = 'seed-155',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key IN (N'document-uploads', N'document-acknowledgements', N'my-acknowledgements');
GO

-- =====================================================================
-- 3. Grant every organization's Admin role can_view on the new parent
--    so the group is visible in the sidebar. Children keep their own
--    grants added by 149/152/154 (Admin for uploads + admin ack;
--    every role for my-acknowledgements).
-- =====================================================================
DECLARE @docs_parent_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-documents');
DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

IF @docs_parent_id IS NOT NULL
BEGIN
    MERGE grac_practice.organization_role_menu_permission AS target
    USING (
        SELECT r.role_id, @docs_parent_id AS menu_id,
               CAST(1 AS BIT) AS can_view, CAST(0 AS BIT) AS can_add,
               CAST(0 AS BIT) AS can_edit, CAST(0 AS BIT) AS can_delete,
               CAST(0 AS BIT) AS can_approve, @active_record_status_id AS record_status_id
          FROM grac_practice.organization_role r
         WHERE r.status = N'Active'
    ) AS source
    ON target.role_id = source.role_id AND target.menu_id = source.menu_id
    WHEN MATCHED THEN UPDATE SET
        can_view = 1, status = N'Active',
        updated_by = 'seed-155', updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
         status, record_status_id, entered_by)
    VALUES (source.role_id, source.menu_id, source.can_view, source.can_add,
            source.can_edit, source.can_delete, source.can_approve,
            N'Active', source.record_status_id, 'seed-155');
END
GO

-- Sanity report ----------------------------------------------------
SELECT 'nav-documents present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-documents') THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT m.menu_key AS ChildMenu, p.menu_key AS Parent
  FROM grac_practice.menu_master m
  JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
 WHERE m.menu_key IN (N'document-uploads', N'document-acknowledgements', N'my-acknowledgements')
 ORDER BY m.menu_key;

PRINT '155 Document module menu regroup complete.';
GO
SET NOEXEC OFF;
GO
