/*
  GRAC Part 2 - Practice Intelligence Layer
  RBAC seed.
*/
IF OBJECT_ID('grac_practice.security_role','U') IS NULL
CREATE TABLE grac_practice.security_role(
 security_role_id BIGINT IDENTITY PRIMARY KEY,
 role_code NVARCHAR(80) NOT NULL UNIQUE,
 role_name NVARCHAR(200) NOT NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

IF OBJECT_ID('grac_practice.security_permission','U') IS NULL
CREATE TABLE grac_practice.security_permission(
 security_permission_id BIGINT IDENTITY PRIMARY KEY,
 area_key NVARCHAR(120) NOT NULL,
 action_key NVARCHAR(40) NOT NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 CONSTRAINT uq_pm_security_permission UNIQUE(area_key,action_key)
);
GO

IF OBJECT_ID('grac_practice.security_role_permission','U') IS NULL
CREATE TABLE grac_practice.security_role_permission(
 security_role_permission_id BIGINT IDENTITY PRIMARY KEY,
 security_role_id BIGINT NOT NULL REFERENCES grac_practice.security_role(security_role_id),
 security_permission_id BIGINT NOT NULL REFERENCES grac_practice.security_permission(security_permission_id),
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 CONSTRAINT uq_pm_role_permission UNIQUE(security_role_id,security_permission_id)
);
GO

MERGE grac_practice.security_role AS target
USING (VALUES
 (N'PM_ADMIN',N'Practice Management Administrator'),
 (N'PM_REVIEWER',N'Practice Management Reviewer'),
 (N'PM_OWNER',N'Practice Owner')
) AS source(role_code,role_name)
ON target.role_code=source.role_code
WHEN NOT MATCHED THEN INSERT(role_code,role_name,status,entered_by) VALUES(source.role_code,source.role_name,N'Active',N'system');
GO

DECLARE @areas TABLE(area_key NVARCHAR(120));
INSERT @areas VALUES
(N'organizations'),(N'organization-metadata'),(N'applicability-discovery'),(N'applicability-results'),
(N'repository-subscriptions'),(N'applicability-recommendations'),(N'repository-import'),(N'organization-controls'),(N'organization-requirements'),
(N'control-applicability'),(N'requirement-applicability'),(N'practices'),(N'practice-instances'),
(N'dependencies'),(N'evidence-configurations'),(N'assurance-attributes'),(N'vendor-attributes'),
(N'risk-attributes'),(N'audit-attributes'),(N'task-attributes'),(N'resilience-attributes'),(N'future-triggers'),(N'audit-trace');

MERGE grac_practice.security_permission AS target
USING (SELECT area_key,action_key FROM @areas CROSS JOIN (VALUES(N'VIEW'),(N'ADD'),(N'EDIT'),(N'DELETE'),(N'APPROVE')) a(action_key)) AS source
ON target.area_key=source.area_key AND target.action_key=source.action_key
WHEN NOT MATCHED THEN INSERT(area_key,action_key,status,entered_by) VALUES(source.area_key,source.action_key,N'Active',N'system');
GO
