-- =====================================================================
-- 027 Organization Access Administration
-- Adds the "Organization Access Administration" menu group with:
--   1. Organization Role Management      (menu key: roles)
--   2. Organization Role Menu Permission (menu key: role-menu-permissions)
--   3. Organization User Role Assignment (menu key: user-role-assignments)
-- Adds organization_role.role_code and the multi-role assignment map
-- grac_practice.organization_employee_role.
-- Re-run database/deployment/02_Create_Procedures.sql AFTER this script
-- so the stored procedures pick up the new entity branches.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 52700, 'PracticeManagement schema grac_practice is missing. Run base scripts first.', 1;
GO

DECLARE @active_record_status_id INT=(SELECT TOP 1 record_status_id FROM grac_practice.record_status_master WHERE status_code='ACTIVE' OR status_name='Active' ORDER BY record_status_id);
IF @active_record_status_id IS NULL SET @active_record_status_id=1;

-- 1. Role Code on organization roles ---------------------------------
IF COL_LENGTH('grac_practice.organization_role','role_code') IS NULL
    ALTER TABLE grac_practice.organization_role ADD role_code NVARCHAR(60) NULL;

-- Unique role code per organization (ignores blanks).
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_pm_org_role_code' AND object_id=OBJECT_ID('grac_practice.organization_role'))
    EXEC('CREATE UNIQUE INDEX ux_pm_org_role_code ON grac_practice.organization_role(organization_id,role_code) WHERE role_code IS NOT NULL AND role_code<>''''');

-- 2. Multi-role assignment map ---------------------------------------
IF OBJECT_ID('grac_practice.organization_employee_role','U') IS NULL
CREATE TABLE grac_practice.organization_employee_role(
 employee_role_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_employee_role PRIMARY KEY,
 employee_id BIGINT NOT NULL,
 role_id BIGINT NOT NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_employee_role_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_employee_role_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_employee_role_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_employee_role_employee FOREIGN KEY(employee_id) REFERENCES grac_practice.organization_employee(employee_id),
 CONSTRAINT fk_pm_employee_role_role FOREIGN KEY(role_id) REFERENCES grac_practice.organization_role(role_id),
 CONSTRAINT uq_pm_employee_role UNIQUE(employee_id,role_id)
);

-- Backfill: every employee's current single role becomes a map row.
INSERT grac_practice.organization_employee_role(employee_id,role_id,status,record_status_id,entered_by)
SELECT e.employee_id,e.role_id,'Active',@active_record_status_id,'seed'
FROM grac_practice.organization_employee e
WHERE e.role_id IS NOT NULL
  AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee_role er WHERE er.employee_id=e.employee_id AND er.role_id=e.role_id);

-- 3. Menu group: Organization Access Administration -------------------
MERGE grac_practice.menu_master AS target
USING (VALUES
 (N'roles',N'Organization Role Management',N'/Practice/Index/roles',111,N'user-lock',N'Organization Access Administration'),
 (N'role-menu-permissions',N'Organization Role Menu Permission',N'/Practice/Index/role-menu-permissions',112,N'list-check',N'Organization Access Administration'),
 (N'user-role-assignments',N'Organization User Role Assignment',N'/Practice/Index/user-role-assignments',113,N'user-gear',N'Organization Access Administration')
) AS source(menu_key,menu_name,menu_url,display_order,icon_class,module_type)
ON target.menu_key=source.menu_key
WHEN MATCHED THEN UPDATE SET menu_name=source.menu_name,menu_url=source.menu_url,display_order=source.display_order,icon_class=source.icon_class,module_type=source.module_type,status='Active',updated_by='seed-027',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(menu_key,menu_name,menu_url,display_order,icon_class,module_type,status,entered_by)
VALUES(source.menu_key,source.menu_name,source.menu_url,source.display_order,source.icon_class,source.module_type,'Active','seed-027');

-- 4. Grant permissions on the new/updated menus -----------------------
-- Admin: full access. Viewer: view only.
INSERT grac_practice.organization_role_menu_permission(role_id,menu_id,can_view,can_add,can_edit,can_delete,can_approve,status,record_status_id,entered_by)
SELECT r.role_id,m.menu_id,1,1,1,1,1,'Active',@active_record_status_id,'seed-027'
FROM grac_practice.organization_role r
JOIN grac_practice.menu_master m ON m.menu_key IN (N'roles',N'role-menu-permissions',N'user-role-assignments')
WHERE r.role_name='Admin'
  AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_role_menu_permission p WHERE p.role_id=r.role_id AND p.menu_id=m.menu_id);

INSERT grac_practice.organization_role_menu_permission(role_id,menu_id,can_view,can_add,can_edit,can_delete,can_approve,status,record_status_id,entered_by)
SELECT r.role_id,m.menu_id,1,0,0,0,0,'Active',@active_record_status_id,'seed-027'
FROM grac_practice.organization_role r
JOIN grac_practice.menu_master m ON m.menu_key IN (N'roles',N'role-menu-permissions',N'user-role-assignments')
WHERE r.role_name='Viewer'
  AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_role_menu_permission p WHERE p.role_id=r.role_id AND p.menu_id=m.menu_id);

SELECT 'Organization Access Administration migration complete. Now re-run database/deployment/02_Create_Procedures.sql.' Message;
