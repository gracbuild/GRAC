-- =====================================================================
-- 125 Scoped event assurance menu seed -- ROLLBACK
--
-- Removes permissions, menu rows, per-org flag rows and flag master rows
-- for the two screens. Order matters: permissions reference menu_id.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

DELETE p
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master m ON m.menu_id = p.menu_id
WHERE  m.menu_key IN (N'workflow-scope-mapping', N'workflow-event-inbox');
GO

DELETE FROM grac_practice.menu_master
 WHERE menu_key IN (N'workflow-scope-mapping', N'workflow-event-inbox');
GO

-- NB: feature_flag's FK column is feature_flag_id (pointing at
-- feature_flag_master.feature_flag_id), NOT feature_flag_master_id.
-- Same shape the 100/103 rollbacks use.
DELETE FROM grac_practice.feature_flag
 WHERE feature_flag_id IN (
       SELECT feature_flag_id FROM grac_practice.feature_flag_master
        WHERE feature_code IN (N'screen.workflow-scope-mapping', N'screen.workflow-event-inbox'));
GO

DELETE FROM grac_practice.feature_flag_master
 WHERE feature_code IN (N'screen.workflow-scope-mapping', N'screen.workflow-event-inbox');
GO

COMMIT TRAN;
GO

SELECT 'menu rows removed' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE menu_key IN (N'workflow-scope-mapping', N'workflow-event-inbox'))
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'feature flags removed' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.feature_flag_master
                              WHERE feature_code IN (N'screen.workflow-scope-mapping',
                                                     N'screen.workflow-event-inbox'))
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '125 Scoped event assurance menu seed rolled back.';
GO
