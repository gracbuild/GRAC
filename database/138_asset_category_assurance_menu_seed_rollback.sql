-- =====================================================================
-- 138 Asset Category Assurance menu seed -- ROLLBACK
--
-- Undoes both halves of 138:
--   * removes the asset-category-assurance screen (permissions, menu row,
--     per-org flag rows, flag master row)
--   * restores the workflow-scope-mapping screen (flag reactivated, menu
--     row re-seeded under nav-workflow, Admin permissions re-granted)
--
-- Order matters: permissions reference menu_id.
--
-- NOTE ON WHAT CANNOT BE RESTORED
-- -------------------------------
-- 138 DELETEs the workflow-scope-mapping permission rows rather than
-- deactivating them, so a role that had been granted only partial rights
-- (view but not edit, say) comes back with the full Admin grant below and
-- nothing else. Non-Admin roles that had the screen lose it. If that
-- matters in your environment, capture
--     SELECT r.role_name, p.*
--     FROM   grac_practice.organization_role_menu_permission p
--     JOIN   grac_practice.menu_master m ON m.menu_id = p.menu_id
--     JOIN   grac_practice.organization_role r ON r.role_id = p.role_id
--     WHERE  m.menu_key = N'workflow-scope-mapping';
-- BEFORE running 138.
--
-- No mapping data is involved either way -- 138 touched navigation only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
BEGIN
    RAISERROR('138 rollback: menu / feature-flag tables missing.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Remove the asset-category-assurance screen
-- =====================================================================
DELETE p
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master m ON m.menu_id = p.menu_id
WHERE  m.menu_key = N'asset-category-assurance';
GO

DELETE FROM grac_practice.menu_master
 WHERE menu_key = N'asset-category-assurance';
GO

-- feature_flag's FK column is feature_flag_id (-> feature_flag_master.
-- feature_flag_id), NOT feature_flag_master_id. Same shape as the 125
-- rollback.
DELETE FROM grac_practice.feature_flag
 WHERE feature_flag_id IN (
       SELECT feature_flag_id FROM grac_practice.feature_flag_master
        WHERE feature_code = N'screen.asset-category-assurance');
GO

DELETE FROM grac_practice.feature_flag_master
 WHERE feature_code = N'screen.asset-category-assurance';
GO

-- =====================================================================
-- 2. Restore the workflow-scope-mapping screen
--
--    Values reproduce migration 125 exactly: display_order 459,
--    icon diagram-project, module_type Workflow, parent nav-workflow.
-- =====================================================================
UPDATE grac_practice.feature_flag_master
   SET is_active   = 1,
       description = N'Map checklists to an organisation role or asset category, restricted to subscribed releases (migrations 123/124).',
       updated_by  = 'rollback-138',
       updated_dt  = SYSUTCDATETIME()
 WHERE feature_code = N'screen.workflow-scope-mapping';
GO

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'workflow-scope-mapping', N'Scoped Checklist Mapping',
     N'Practice/Index/workflow-scope-mapping', 459, N'diagram-project', N'Workflow')
) AS source(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name     = source.menu_name,
    menu_url      = source.menu_url,
    display_order = source.display_order,
    icon_class    = source.icon_class,
    module_type   = source.module_type,
    status        = N'Active',
    updated_by    = 'rollback-138',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
VALUES
    (source.menu_key, source.menu_name, source.menu_url, source.display_order,
     source.icon_class, source.module_type, N'Active', 'rollback-138');
GO

DECLARE @wf_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-workflow');
IF @wf_id IS NULL
    PRINT '138 rollback: nav-workflow parent missing -- scope-mapping restored without a parent.';
ELSE
    UPDATE grac_practice.menu_master
       SET parent_menu_id = @wf_id,
           updated_by     = 'rollback-138',
           updated_dt     = SYSUTCDATETIME()
     WHERE menu_key = N'workflow-scope-mapping';
GO

DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id
    FROM grac_practice.record_status_master
    WHERE status_code = 'ACTIVE' OR status_name = 'Active'
    ORDER BY record_status_id
);
IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

MERGE grac_practice.organization_role_menu_permission AS target
USING (
    SELECT r.role_id, m.menu_id,
           CAST(1 AS BIT) AS can_view,
           CAST(1 AS BIT) AS can_add,
           CAST(1 AS BIT) AS can_edit,
           CAST(1 AS BIT) AS can_delete,
           CAST(1 AS BIT) AS can_approve,
           @active_record_status_id AS record_status_id
    FROM grac_practice.organization_role r
    CROSS JOIN grac_practice.menu_master m
    WHERE r.role_name = N'Admin'
      AND r.status    = N'Active'
      AND m.menu_key  = N'workflow-scope-mapping'
) AS source
ON target.role_id = source.role_id AND target.menu_id = source.menu_id
WHEN MATCHED THEN UPDATE SET
    can_view = source.can_view, can_add = source.can_add, can_edit = source.can_edit,
    can_delete = source.can_delete, can_approve = source.can_approve,
    status = N'Active', updated_by = 'rollback-138', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by)
VALUES
    (source.role_id, source.menu_id, source.can_view, source.can_add,
     source.can_edit, source.can_delete, source.can_approve,
     N'Active', source.record_status_id, 'rollback-138');
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'asset-category-assurance menu removed' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE menu_key = N'asset-category-assurance')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'asset-category-assurance flag removed',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.feature_flag_master
                              WHERE feature_code = N'screen.asset-category-assurance')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'scope-mapping menu restored',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'workflow-scope-mapping'
                            AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'scope-mapping flag reactivated',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.feature_flag_master
                          WHERE feature_code = N'screen.workflow-scope-mapping'
                            AND is_active = 1)
            THEN 'PASS' ELSE 'FAIL -- 125 may not have been run' END;

PRINT '138 Asset Category Assurance rolled back; Scoped Checklist Mapping restored.';
PRINT 'Remember to revert PracticeScreen.cs and Manage.cshtml to match.';
GO
