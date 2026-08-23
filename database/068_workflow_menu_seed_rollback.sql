-- =====================================================================
-- 068 Workflow Engine menu + feature flag -- ROLLBACK
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- 1. Remove role grants for all workflow menu rows.
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    DELETE p
    FROM grac_practice.organization_role_menu_permission p
    JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
    WHERE m.menu_key IN (N'nav-workflow', N'workflows', N'workflow-stages',
                         N'workflow-entity-types', N'workflow-events',
                         N'workflow-checklists', N'workflow-event-mappings',
                         N'event-assurance', N'workflow-dashboard');
END
GO

-- 2. Remove all workflow menu rows (children first, then parent).
IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.menu_master
     WHERE menu_key IN (N'workflows', N'workflow-stages',
                        N'workflow-entity-types', N'workflow-events',
                        N'workflow-checklists', N'workflow-event-mappings',
                        N'event-assurance', N'workflow-dashboard');

    DELETE FROM grac_practice.menu_master WHERE menu_key = N'nav-workflow';
END
GO

-- 3. Remove per-org feature_flag rows then the feature_flag_master rows.
IF OBJECT_ID('grac_practice.feature_flag','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.feature_flag_master','U') IS NOT NULL
BEGIN
    DELETE ff
    FROM grac_practice.feature_flag ff
    JOIN grac_practice.feature_flag_master m ON m.feature_flag_id = ff.feature_flag_id
    WHERE m.feature_code IN (N'screen.workflows', N'screen.workflow-stages',
                             N'screen.workflow-entity-types',
                             N'screen.workflow-events',
                             N'screen.workflow-checklists',
                             N'screen.workflow-event-mappings',
                             N'screen.event-assurance',
                             N'screen.workflow-dashboard');

    DELETE FROM grac_practice.feature_flag_master
     WHERE feature_code IN (N'screen.workflows', N'screen.workflow-stages',
                            N'screen.workflow-entity-types',
                            N'screen.workflow-events',
                            N'screen.workflow-checklists',
                            N'screen.workflow-event-mappings',
                            N'screen.event-assurance',
                            N'screen.workflow-dashboard');
END
GO

PRINT '068 workflow menu seed rollback complete.';
GO

SET NOEXEC OFF;
GO
