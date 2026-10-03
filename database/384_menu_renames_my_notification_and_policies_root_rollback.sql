-- =====================================================================
-- 384 ROLLBACK  Sidebar renames / My Notification parent / Policies &
--               Documents root
--
-- Restores the pre-384 state:
--   * labels: Audit Management, Document Management, Oversight,
--     Gap Center, Task Center, Exception Centre, Dashboard,
--     My Notifications
--   * module_type: 'Issues & Actions' -> 'Oversight',
--     'Audit Assurance' -> 'Audit Management', document rows -> 'Documents'
--     (nav-documents -> 'Governance'), my-notifications -> 'Oversight',
--     my-acknowledgements -> 'Documents'
--   * nav-documents back under nav-governance (display_order 130, 359)
--   * my-notifications back under nav-oversight (display_order 270)
--   * my-acknowledgements back under nav-documents (display_order 30)
--   * removes my-practices / my-approvals and their permission rows
--
-- ALSO revert the 384 edits in 274_menu_master_seed.sql, or its next run
-- re-applies 384. ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ROLLBACK 384: menu_master missing; nothing to do.'; RETURN; END
GO

-- 1. Remove the two placeholder rows (children first: permissions).
DELETE p
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key IN (N'my-practices', N'my-approvals');
PRINT 'ROLLBACK 384: permission rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

DELETE FROM grac_practice.menu_master WHERE menu_key IN (N'my-practices', N'my-approvals');
PRINT 'ROLLBACK 384: placeholder menu rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- 2. Labels.
UPDATE m
   SET menu_name = x.old_name, updated_by = 'rollback-384', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master m
  JOIN (VALUES
        (N'nav-assurance'    , N'Audit Management'),
        (N'nav-documents'    , N'Document Management'),
        (N'nav-oversight'    , N'Oversight'),
        (N'gaps'             , N'Gap Center'),
        (N'tasks'            , N'Task Center'),
        (N'exception-centre' , N'Exception Centre'),
        (N'dashboard'        , N'Dashboard'),
        (N'my-notifications' , N'My Notifications')
  ) AS x(menu_key, old_name) ON x.menu_key = m.menu_key;
PRINT 'ROLLBACK 384: labels restored = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- 3. module_type.
UPDATE grac_practice.menu_master SET module_type = N'Oversight', updated_by = 'rollback-384', updated_dt = SYSUTCDATETIME()
 WHERE module_type = N'Issues & Actions' OR menu_key = N'my-notifications';
UPDATE grac_practice.menu_master SET module_type = N'Audit Management', updated_by = 'rollback-384', updated_dt = SYSUTCDATETIME()
 WHERE module_type = N'Audit Assurance';
UPDATE grac_practice.menu_master SET module_type = N'Documents', updated_by = 'rollback-384', updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'document-uploads', N'document-acknowledgements', N'my-acknowledgements');
UPDATE grac_practice.menu_master SET module_type = N'Governance', updated_by = 'rollback-384', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'nav-documents';
PRINT 'ROLLBACK 384: module_type restored.';
GO

-- 4. Parents and order.
DECLARE @gov  BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-governance');
DECLARE @ovs  BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight');
DECLARE @docs BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-documents');

UPDATE grac_practice.menu_master SET parent_menu_id = @gov,  display_order = 130, updated_by = 'rollback-384', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'nav-documents';
UPDATE grac_practice.menu_master SET parent_menu_id = @ovs,  display_order = 270, updated_by = 'rollback-384', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'my-notifications';
UPDATE grac_practice.menu_master SET parent_menu_id = @docs, display_order = 30,  updated_by = 'rollback-384', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'my-acknowledgements';
PRINT 'ROLLBACK 384: parents restored.';
GO
PRINT 'ROLLBACK 384 complete.';
GO
