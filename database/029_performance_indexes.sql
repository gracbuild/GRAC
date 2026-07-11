-- 029_performance_indexes.sql
-- Performance indexes for frequently filtered columns across the GRAC schemas
-- used by Practice Management (grac_practice) and the shared repository schema
-- (grac_new). Every index is guarded so the script is idempotent and safe to
-- run on databases where a table does not exist yet.
--
-- Standard: filters applied in queries (OrganizationID, ReleaseID, StatusID/
-- Status, ParentID, FrameworkStatementID, SourceStructureNodeID, RoleID,
-- UserID, AuthorityID, ArtifactID, RequirementID) must be supported by an
-- index here. Extend this script when new filtered columns are introduced.

-- ---------------------------------------------------------------------------
-- grac_practice.repository_subscription: subscription lookups by org+release
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_practice.repository_subscription','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_repo_subscription_org_release_status' AND object_id=OBJECT_ID('grac_practice.repository_subscription'))
 EXEC(N'CREATE INDEX ix_pm_repo_subscription_org_release_status
        ON grac_practice.repository_subscription(organization_id,release_id,status)
        INCLUDE(subscription_status,artifact_id)');
GO

-- ---------------------------------------------------------------------------
-- grac_practice.organization_framework_statements: the core drill-down /
-- summary-count table. Covers org+release+status scans and statement lookups.
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_practice.organization_framework_statements','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_fw_statements_org_release_status' AND object_id=OBJECT_ID('grac_practice.organization_framework_statements'))
 EXEC(N'CREATE INDEX ix_pm_org_fw_statements_org_release_status
        ON grac_practice.organization_framework_statements(organization_id,release_id,status)
        INCLUDE(framework_statement_id,org_statement_id,applicability_status_id,owner_id)');
GO
IF OBJECT_ID('grac_practice.organization_framework_statements','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_fw_statements_statement' AND object_id=OBJECT_ID('grac_practice.organization_framework_statements'))
 EXEC(N'CREATE INDEX ix_pm_org_fw_statements_statement
        ON grac_practice.organization_framework_statements(framework_statement_id)
        INCLUDE(organization_id,release_id,status)');
GO

-- ---------------------------------------------------------------------------
-- grac_practice.organization_requirement: practice counts per statement
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_practice.organization_requirement','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_requirement_org_statement_status' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
 EXEC(N'CREATE INDEX ix_pm_org_requirement_org_statement_status
        ON grac_practice.organization_requirement(organization_id,org_statement_id,status)
        INCLUDE(applicability_status_id,repository_requirement_id)');
GO

-- ---------------------------------------------------------------------------
-- grac_practice.organization_employee: owner lookups scoped to organization
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_employee_org_status' AND object_id=OBJECT_ID('grac_practice.organization_employee'))
 EXEC(N'CREATE INDEX ix_pm_org_employee_org_status
        ON grac_practice.organization_employee(organization_id,status)
        INCLUDE(employee_name)');
GO

-- ---------------------------------------------------------------------------
-- grac_practice role/menu/user access tables
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_role_menu_permission_role_menu' AND object_id=OBJECT_ID('grac_practice.organization_role_menu_permission'))
 EXEC(N'CREATE INDEX ix_pm_org_role_menu_permission_role_menu
        ON grac_practice.organization_role_menu_permission(role_id,menu_id)
        INCLUDE(can_view,can_add,can_edit,can_delete,can_approve,status)');
GO
IF OBJECT_ID('grac_practice.organization_role','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_role_org' AND object_id=OBJECT_ID('grac_practice.organization_role'))
 EXEC(N'CREATE INDEX ix_pm_org_role_org ON grac_practice.organization_role(organization_id)');
GO
IF OBJECT_ID('grac_practice.organization_employee_role','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_employee_role_role' AND object_id=OBJECT_ID('grac_practice.organization_employee_role'))
 EXEC(N'CREATE INDEX ix_pm_org_employee_role_role
        ON grac_practice.organization_employee_role(role_id)
        INCLUDE(employee_id,status)');
GO

-- ---------------------------------------------------------------------------
-- grac_new.framework_statement: release-scoped statement reads + node joins
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_new.framework_statement','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_cm_framework_statement_release_status' AND object_id=OBJECT_ID('grac_new.framework_statement'))
 EXEC(N'CREATE INDEX ix_cm_framework_statement_release_status
        ON grac_new.framework_statement(release_id,status)
        INCLUDE(structure_node_id,statement_reference,statement_title,display_order)');
GO
IF OBJECT_ID('grac_new.framework_statement','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_cm_framework_statement_structure_node' AND object_id=OBJECT_ID('grac_new.framework_statement'))
 EXEC(N'CREATE INDEX ix_cm_framework_statement_structure_node
        ON grac_new.framework_statement(structure_node_id,status)');
GO

-- ---------------------------------------------------------------------------
-- grac_new.source_structure_node: release-scoped tree reads + parent walks
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_new.source_structure_node','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_cm_source_structure_node_release_status' AND object_id=OBJECT_ID('grac_new.source_structure_node'))
 EXEC(N'CREATE INDEX ix_cm_source_structure_node_release_status
        ON grac_new.source_structure_node(release_id,status)
        INCLUDE(parent_node_id,node_level,node_reference,node_title,display_order)');
GO
IF OBJECT_ID('grac_new.source_structure_node','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_cm_source_structure_node_parent' AND object_id=OBJECT_ID('grac_new.source_structure_node'))
 EXEC(N'CREATE INDEX ix_cm_source_structure_node_parent
        ON grac_new.source_structure_node(parent_node_id)');
GO

-- ---------------------------------------------------------------------------
-- grac_new mapping tables: statement -> requirement / control
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_new.framework_statement_requirement_map','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_cm_fs_requirement_map_statement_status' AND object_id=OBJECT_ID('grac_new.framework_statement_requirement_map'))
 EXEC(N'CREATE INDEX ix_cm_fs_requirement_map_statement_status
        ON grac_new.framework_statement_requirement_map(framework_statement_id,status)
        INCLUDE(requirement_id)');
GO
IF OBJECT_ID('grac_new.framework_statement_control_map','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_cm_fs_control_map_statement_status' AND object_id=OBJECT_ID('grac_new.framework_statement_control_map'))
 EXEC(N'CREATE INDEX ix_cm_fs_control_map_statement_status
        ON grac_new.framework_statement_control_map(framework_statement_id,status)
        INCLUDE(control_id)');
GO

-- ---------------------------------------------------------------------------
-- grac_new.release / artifact: authority -> artifact -> release navigation
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_new.release','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_cm_release_artifact' AND object_id=OBJECT_ID('grac_new.release'))
 EXEC(N'CREATE INDEX ix_cm_release_artifact ON grac_new.release(artifact_id)');
GO
IF OBJECT_ID('grac_new.artifact','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_cm_artifact_authority' AND object_id=OBJECT_ID('grac_new.artifact'))
 EXEC(N'CREATE INDEX ix_cm_artifact_authority ON grac_new.artifact(authority_id)');
GO
