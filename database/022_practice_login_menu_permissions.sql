SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 52200, 'PracticeManagement schema grac_practice is missing. Run base scripts first.', 1;
GO

DECLARE @active_record_status_id INT=(SELECT TOP 1 record_status_id FROM grac_practice.record_status_master WHERE status_code='ACTIVE' OR status_name='Active' ORDER BY record_status_id);
IF @active_record_status_id IS NULL SET @active_record_status_id=1;

IF COL_LENGTH('grac_practice.organization_employee','password_hash') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD password_hash NVARCHAR(500) NULL;

IF COL_LENGTH('grac_practice.organization_employee','role_id') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD role_id BIGINT NULL;

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
CREATE TABLE grac_practice.menu_master(
 menu_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_menu_master PRIMARY KEY,
 menu_key NVARCHAR(120) NOT NULL CONSTRAINT uq_pm_menu_key UNIQUE,
 menu_name NVARCHAR(160) NOT NULL,
 menu_url NVARCHAR(260) NULL,
 parent_menu_id BIGINT NULL,
 display_order INT NOT NULL CONSTRAINT df_pm_menu_order DEFAULT 0,
 icon_class NVARCHAR(120) NULL,
 module_type NVARCHAR(80) NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_menu_status DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_menu_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_menu_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_menu_parent FOREIGN KEY(parent_menu_id) REFERENCES grac_practice.menu_master(menu_id)
);

IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
CREATE TABLE grac_practice.organization_role(
 role_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_organization_role PRIMARY KEY,
 organization_id BIGINT NOT NULL,
 role_name NVARCHAR(120) NOT NULL,
 description NVARCHAR(500) NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_org_role_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_org_role_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_org_role_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_org_role_organization FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_org_role_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_org_role_name UNIQUE(organization_id,role_name)
);

IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
CREATE TABLE grac_practice.organization_role_menu_permission(
 role_menu_permission_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_role_menu_permission PRIMARY KEY,
 role_id BIGINT NOT NULL,
 menu_id BIGINT NOT NULL,
 can_view BIT NOT NULL CONSTRAINT df_pm_role_menu_view DEFAULT 1,
 can_add BIT NOT NULL CONSTRAINT df_pm_role_menu_add DEFAULT 0,
 can_edit BIT NOT NULL CONSTRAINT df_pm_role_menu_edit DEFAULT 0,
 can_delete BIT NOT NULL CONSTRAINT df_pm_role_menu_delete DEFAULT 0,
 can_approve BIT NOT NULL CONSTRAINT df_pm_role_menu_approve DEFAULT 0,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_role_menu_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_role_menu_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_role_menu_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_role_menu_role FOREIGN KEY(role_id) REFERENCES grac_practice.organization_role(role_id),
 CONSTRAINT fk_pm_role_menu_menu FOREIGN KEY(menu_id) REFERENCES grac_practice.menu_master(menu_id),
 CONSTRAINT fk_pm_role_menu_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_role_menu UNIQUE(role_id,menu_id)
);

IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_employee_role')
    ALTER TABLE grac_practice.organization_employee ADD CONSTRAINT fk_pm_employee_role FOREIGN KEY(role_id) REFERENCES grac_practice.organization_role(role_id);

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_pm_employee_email' AND object_id=OBJECT_ID('grac_practice.organization_employee'))
AND NOT EXISTS(
 SELECT 1
 FROM grac_practice.organization_employee
 WHERE NULLIF(LTRIM(RTRIM(email)),'') IS NOT NULL
 GROUP BY LOWER(LTRIM(RTRIM(email)))
 HAVING COUNT_BIG(1)>1
)
    CREATE UNIQUE INDEX ux_pm_employee_email ON grac_practice.organization_employee(email) WHERE email IS NOT NULL AND email<>'';

MERGE grac_practice.menu_master AS target
USING (VALUES
 (N'dashboard',N'Dashboard',N'/Practice/Index',5,N'chart-line',N'Dashboard'),
 (N'menu-master',N'Menu Master',N'/Practice/Index/menu-master',6,N'bars',N'System'),
 (N'organization-setup',N'Organization Setup',N'/Practice/Index/organization-setup',10,N'building',N'Organization Setup'),
 (N'organization-administration',N'Organization Administration',N'/Practice/Index/organization-administration',20,N'building-user',N'Organization Administration'),
 (N'organizations',N'Organization Onboarding',N'/Practice/Index/organizations',30,N'building',N'Organization Setup'),
 (N'organization-metadata',N'Organization Metadata',N'/Practice/Index/organization-metadata',40,N'sliders',N'Organization Setup'),
 (N'repository-subscriptions',N'Repository Subscriptions',N'/Practice/Index/repository-subscriptions',50,N'bookmark',N'Organization Setup'),
 (N'locations',N'Location Management',N'/Practice/Index/locations',60,N'location-dot',N'Organization Administration'),
 (N'departments',N'Department Management',N'/Practice/Index/departments',70,N'building-user',N'Organization Administration'),
 (N'business-functions',N'Business Function Management',N'/Practice/Index/business-functions',80,N'briefcase',N'Organization Administration'),
 (N'teams',N'Team Management',N'/Practice/Index/teams',90,N'people-group',N'Organization Administration'),
 (N'committees',N'Committee Management',N'/Practice/Index/committees',100,N'users-gear',N'Organization Administration'),
 (N'roles',N'Role Master',N'/Practice/Index/roles',110,N'user-lock',N'Organization Administration'),
 (N'role-menu-permissions',N'Role Menu Permission',N'/Practice/Index/role-menu-permissions',120,N'list-check',N'Organization Administration'),
 (N'users',N'User Management',N'/Practice/Index/users',130,N'users',N'Organization Administration'),
 (N'organization-dependencies',N'Organization Dependencies',N'/Practice/Index/organization-dependencies',140,N'diagram-project',N'Organization Dependencies'),
 (N'dependency-applications',N'Applications',N'/Practice/Index/dependency-applications',150,N'window-restore',N'Organization Dependencies'),
 (N'dependency-tools',N'Tools',N'/Practice/Index/dependency-tools',160,N'screwdriver-wrench',N'Organization Dependencies'),
 (N'dependency-vendors',N'Vendors',N'/Practice/Index/dependency-vendors',170,N'handshake',N'Organization Dependencies'),
 (N'dependency-assets',N'Assets',N'/Practice/Index/dependency-assets',180,N'server',N'Organization Dependencies'),
 (N'dependency-processes',N'Processes',N'/Practice/Index/dependency-processes',190,N'arrows-spin',N'Organization Dependencies'),
 (N'organization-controls',N'Organization Controls',N'/Practice/Index/organization-controls',200,N'shield',N'Practice Management'),
 (N'organization-requirements',N'Organization Requirements / Practices',N'/Practice/Index/organization-requirements',210,N'list-check',N'Practice Management'),
 (N'practice-instances',N'Practice Instances',N'/Practice/Index/practice-instances',220,N'network-wired',N'Practice Management'),
 (N'resolve',N'Resolve',N'/Practice/Index/resolve',230,N'gears',N'Practice Management'),
 (N'workbench-applications',N'Applications',N'/Practice/Index/workbench-applications',240,N'window-restore',N'Registers'),
 (N'workbench-tools',N'Tools',N'/Practice/Index/workbench-tools',250,N'screwdriver-wrench',N'Registers'),
 (N'workbench-vendors',N'Vendors',N'/Practice/Index/workbench-vendors',260,N'handshake',N'Registers'),
 (N'workbench-assets',N'Assets',N'/Practice/Index/workbench-assets',270,N'server',N'Registers'),
 (N'workbench-teams',N'Teams',N'/Practice/Index/workbench-teams',280,N'people-group',N'Registers'),
 (N'workbench-committees',N'Committees',N'/Practice/Index/workbench-committees',290,N'users-gear',N'Registers'),
 (N'workbench-processes',N'Processes',N'/Practice/Index/workbench-processes',300,N'arrows-spin',N'Registers'),
 (N'workbench-locations',N'Locations',N'/Practice/Index/workbench-locations',310,N'location-dot',N'Registers'),
 (N'audit-trace',N'Audit Traceability',N'/Practice/Index/audit-trace',900,N'timeline',N'Practice Management')
) AS source(menu_key,menu_name,menu_url,display_order,icon_class,module_type)
ON target.menu_key=source.menu_key
WHEN MATCHED THEN UPDATE SET menu_name=source.menu_name,menu_url=source.menu_url,display_order=source.display_order,icon_class=source.icon_class,module_type=source.module_type,status='Active',updated_by='seed',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(menu_key,menu_name,menu_url,display_order,icon_class,module_type,status,entered_by)
VALUES(source.menu_key,source.menu_name,source.menu_url,source.display_order,source.icon_class,source.module_type,'Active','seed');

INSERT grac_practice.organization_role(organization_id,role_name,description,status,record_status_id,entered_by)
SELECT o.organization_id,role_seed.role_name,role_seed.description,'Active',@active_record_status_id,'seed'
FROM grac_practice.organization o
CROSS JOIN (VALUES
 (N'Admin',N'Organization administrator with all Practice Management menu permissions.'),
 (N'Compliance Owner',N'Compliance owner responsible for controls, requirements, practices, and evidence.'),
 (N'Evidence Owner',N'Evidence owner responsible for evidence collection and updates.'),
 (N'Reviewer',N'Reviewer with read and review-oriented access.'),
 (N'Viewer',N'Read-only user.')
) role_seed(role_name,description)
WHERE NOT EXISTS(
 SELECT 1 FROM grac_practice.organization_role r
 WHERE r.organization_id=o.organization_id AND LOWER(r.role_name)=LOWER(role_seed.role_name)
);

INSERT grac_practice.organization_role_menu_permission(role_id,menu_id,can_view,can_add,can_edit,can_delete,can_approve,status,record_status_id,entered_by)
SELECT r.role_id,m.menu_id,1,1,1,1,1,'Active',@active_record_status_id,'seed'
FROM grac_practice.organization_role r
CROSS JOIN grac_practice.menu_master m
WHERE r.role_name='Admin'
  AND NOT EXISTS(
    SELECT 1 FROM grac_practice.organization_role_menu_permission p
    WHERE p.role_id=r.role_id AND p.menu_id=m.menu_id
  );

INSERT grac_practice.organization_role_menu_permission(role_id,menu_id,can_view,can_add,can_edit,can_delete,can_approve,status,record_status_id,entered_by)
SELECT r.role_id,m.menu_id,1,0,0,0,0,'Active',@active_record_status_id,'seed'
FROM grac_practice.organization_role r
CROSS JOIN grac_practice.menu_master m
WHERE r.role_name='Viewer'
  AND NOT EXISTS(
    SELECT 1 FROM grac_practice.organization_role_menu_permission p
    WHERE p.role_id=r.role_id AND p.menu_id=m.menu_id
  );

UPDATE e
SET role_id=r.role_id,updated_by='seed',updated_dt=SYSUTCDATETIME()
FROM grac_practice.organization_employee e
JOIN grac_practice.organization_role r ON r.organization_id=e.organization_id AND r.role_name='Admin'
WHERE e.role_id IS NULL;

SELECT 'Practice login/menu permission migration complete.' Message;
