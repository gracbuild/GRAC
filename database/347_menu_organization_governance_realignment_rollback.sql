-- =====================================================================
-- 347 Organization branch realignment -- ROLLBACK
--
-- Puts 'role-menu-permissions' and 'ownership-management' back under
-- 'nav-administration' at their pre-347 display_order (120 and 135, the
-- values 274 and 345 seed), and restores 'nav-oversight' /
-- 'nav-assurance' to their pre-347 display_order (300 and 200).
--
-- Re-runnable: yes. A second run makes no changes.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (347 rollback): schema or menu_master missing -- nothing to do.';
    SET NOEXEC ON;
END
GO

BEGIN TRANSACTION;

UPDATE m
   SET parent_menu_id = a.menu_id,
       display_order  = 120,
       updated_by     = N'rollback-347',
       updated_dt     = SYSUTCDATETIME()
FROM   grac_practice.menu_master m
JOIN   grac_practice.menu_master a ON a.menu_key = N'nav-administration'
WHERE  m.menu_key = N'role-menu-permissions';

PRINT '347 rollback: Role Permission restored under Administration = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE m
   SET parent_menu_id = a.menu_id,
       display_order  = 135,
       updated_by     = N'rollback-347',
       updated_dt     = SYSUTCDATETIME()
FROM   grac_practice.menu_master m
JOIN   grac_practice.menu_master a ON a.menu_key = N'nav-administration'
WHERE  m.menu_key = N'ownership-management';

PRINT '347 rollback: Ownership Management restored under Administration = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE grac_practice.menu_master
   SET display_order = 300, updated_by = N'rollback-347', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'nav-oversight';

UPDATE grac_practice.menu_master
   SET display_order = 200, updated_by = N'rollback-347', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'nav-assurance';

PRINT '347 rollback: Oversight/Audit Management root order restored.';

COMMIT TRANSACTION;
GO

SELECT '347 rollback complete' AS Check_, 'see PRINT messages above for row counts' AS Result;

PRINT '347 rollback complete.';
GO
SET NOEXEC OFF;
GO
