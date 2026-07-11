/*
GRAC PracticeManagement - Assurance Management deployment
Run after the latest PracticeManagement base scripts. This script adds the
Assurance Management schema objects and menu seed data. The generic repository
procedures are updated in 002_practice_management_procedures.sql.
*/

IF SCHEMA_ID('grac_practice') IS NULL
 EXEC('CREATE SCHEMA grac_practice');
GO

IF OBJECT_ID('grac_practice.assurance_activity_status_master','U') IS NULL
CREATE TABLE grac_practice.assurance_activity_status_master(
 assurance_activity_status_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_assurance_activity_status PRIMARY KEY,
 status_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_assurance_activity_status_code UNIQUE,
 status_name NVARCHAR(100) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.assurance_result_status_master','U') IS NULL
CREATE TABLE grac_practice.assurance_result_status_master(
 assurance_result_status_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_assurance_result_status PRIMARY KEY,
 status_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_assurance_result_status_code UNIQUE,
 status_name NVARCHAR(100) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('dbo.pm_assurance_activity_seq','SO') IS NULL
 CREATE SEQUENCE dbo.pm_assurance_activity_seq AS BIGINT START WITH 1 INCREMENT BY 1;
GO

IF OBJECT_ID('dbo.pm_assurance_finding_seq','SO') IS NULL
 CREATE SEQUENCE dbo.pm_assurance_finding_seq AS BIGINT START WITH 1 INCREMENT BY 1;
GO

MERGE grac_practice.assurance_activity_status_master AS target
USING (VALUES
 (N'Pending',N'Pending',1),(N'In Progress',N'In Progress',2),(N'Completed',N'Completed',3),(N'Unable To Verify',N'Unable To Verify',4)
) AS source(status_code,status_name,display_order)
ON target.status_code=source.status_code
WHEN MATCHED THEN UPDATE SET status_name=source.status_name,display_order=source.display_order,is_active=1,updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(status_code,status_name,display_order,is_active,entered_by) VALUES(source.status_code,source.status_name,source.display_order,1,N'system');
GO

MERGE grac_practice.assurance_result_status_master AS target
USING (VALUES
 (N'Pending',N'Pending',1),(N'Pass',N'Pass',2),(N'Pass With Observation',N'Pass With Observation',3),(N'Fail',N'Fail',4),(N'Unable To Verify',N'Unable To Verify',5)
) AS source(status_code,status_name,display_order)
ON target.status_code=source.status_code
WHEN MATCHED THEN UPDATE SET status_name=source.status_name,display_order=source.display_order,is_active=1,updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(status_code,status_name,display_order,is_active,entered_by) VALUES(source.status_code,source.status_name,source.display_order,1,N'system');
GO

IF OBJECT_ID('grac_practice.assurance_activity','U') IS NULL
CREATE TABLE grac_practice.assurance_activity(
 assurance_activity_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_assurance_activity PRIMARY KEY,
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 practice_instance_id BIGINT NOT NULL REFERENCES grac_practice.practice_instance(practice_instance_id),
 activity_number NVARCHAR(60) NOT NULL,
 period_from DATE NOT NULL,
 period_to DATE NOT NULL,
 assurance_type_id INT NULL REFERENCES grac_practice.assurance_type_master(assurance_type_id),
 assurance_type NVARCHAR(80) NOT NULL DEFAULT N'Manual',
 activity_owner_id BIGINT NULL REFERENCES grac_practice.organization_employee(employee_id),
 activity_owner NVARCHAR(200) NULL,
 status_id INT NULL REFERENCES grac_practice.assurance_activity_status_master(assurance_activity_status_id),
 status NVARCHAR(80) NOT NULL DEFAULT N'Pending',
 created_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 due_dt DATE NULL,
 remarks NVARCHAR(MAX) NULL,
 record_status_id INT NULL REFERENCES grac_practice.record_status_master(record_status_id),
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_pm_assurance_activity_number UNIQUE(activity_number),
 CONSTRAINT uq_pm_assurance_activity_period UNIQUE(organization_id,practice_instance_id,period_from,period_to)
);
GO

IF OBJECT_ID('grac_practice.assurance_execution','U') IS NULL
CREATE TABLE grac_practice.assurance_execution(
 assurance_execution_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_assurance_execution PRIMARY KEY,
 assurance_activity_id BIGINT NOT NULL REFERENCES grac_practice.assurance_activity(assurance_activity_id),
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 practice_instance_id BIGINT NOT NULL REFERENCES grac_practice.practice_instance(practice_instance_id),
 execution_dt DATE NOT NULL,
 executor_id BIGINT NULL REFERENCES grac_practice.organization_employee(employee_id),
 executor_name NVARCHAR(200) NULL,
 evidence_status NVARCHAR(80) NOT NULL DEFAULT N'Pending',
 dependency_status NVARCHAR(80) NOT NULL DEFAULT N'Pending',
 result_status_id INT NULL REFERENCES grac_practice.assurance_result_status_master(assurance_result_status_id),
 result_status NVARCHAR(80) NOT NULL DEFAULT N'Pending',
 execution_notes NVARCHAR(MAX) NULL,
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.assurance_evidence_check','U') IS NULL
CREATE TABLE grac_practice.assurance_evidence_check(
 evidence_check_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_assurance_evidence_check PRIMARY KEY,
 assurance_activity_id BIGINT NOT NULL REFERENCES grac_practice.assurance_activity(assurance_activity_id),
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 practice_instance_id BIGINT NOT NULL REFERENCES grac_practice.practice_instance(practice_instance_id),
 evidence_type_id INT NULL,
 evidence_type_name NVARCHAR(200) NULL,
 evidence_exists BIT NOT NULL DEFAULT 0,
 evidence_accessible BIT NOT NULL DEFAULT 0,
 matches_expected_type BIT NOT NULL DEFAULT 0,
 relates_to_assurance BIT NOT NULL DEFAULT 0,
 evidence_location NVARCHAR(500) NULL,
 evidence_locator NVARCHAR(500) NULL,
 result_status NVARCHAR(80) NOT NULL DEFAULT N'Pending',
 remarks NVARCHAR(MAX) NULL,
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.assurance_dependency_check','U') IS NULL
CREATE TABLE grac_practice.assurance_dependency_check(
 dependency_check_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_assurance_dependency_check PRIMARY KEY,
 assurance_activity_id BIGINT NOT NULL REFERENCES grac_practice.assurance_activity(assurance_activity_id),
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 practice_instance_id BIGINT NOT NULL REFERENCES grac_practice.practice_instance(practice_instance_id),
 dependency_type_id INT NULL REFERENCES grac_practice.dependency_type_master(dependency_type_id),
 dependency_type_name NVARCHAR(120) NULL,
 resolved_dependency_id BIGINT NULL,
 resolved_dependency_name NVARCHAR(300) NULL,
 dependency_available BIT NOT NULL DEFAULT 0,
 dependency_current BIT NOT NULL DEFAULT 0,
 result_status NVARCHAR(80) NOT NULL DEFAULT N'Pending',
 remarks NVARCHAR(MAX) NULL,
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.assurance_result','U') IS NULL
CREATE TABLE grac_practice.assurance_result(
 assurance_result_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_assurance_result PRIMARY KEY,
 assurance_activity_id BIGINT NOT NULL REFERENCES grac_practice.assurance_activity(assurance_activity_id),
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 practice_instance_id BIGINT NOT NULL REFERENCES grac_practice.practice_instance(practice_instance_id),
 result_status_id INT NULL REFERENCES grac_practice.assurance_result_status_master(assurance_result_status_id),
 result_status NVARCHAR(80) NOT NULL DEFAULT N'Pending',
 operating_effectiveness NVARCHAR(80) NOT NULL DEFAULT N'Not Assessed',
 completed_dt DATE NULL,
 completed_by_id BIGINT NULL REFERENCES grac_practice.organization_employee(employee_id),
 completed_by NVARCHAR(200) NULL,
 result_summary NVARCHAR(MAX) NULL,
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.assurance_finding','U') IS NULL
CREATE TABLE grac_practice.assurance_finding(
 finding_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_assurance_finding PRIMARY KEY,
 assurance_activity_id BIGINT NOT NULL REFERENCES grac_practice.assurance_activity(assurance_activity_id),
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 practice_instance_id BIGINT NOT NULL REFERENCES grac_practice.practice_instance(practice_instance_id),
 finding_number NVARCHAR(60) NOT NULL,
 title NVARCHAR(300) NOT NULL,
 description NVARCHAR(MAX) NULL,
 severity NVARCHAR(40) NOT NULL DEFAULT N'Medium',
 owner_id BIGINT NULL REFERENCES grac_practice.organization_employee(employee_id),
 owner_name NVARCHAR(200) NULL,
 due_dt DATE NULL,
 finding_status NVARCHAR(80) NOT NULL DEFAULT N'Open',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_pm_assurance_finding_number UNIQUE(finding_number)
);
GO

IF OBJECT_ID('grac_practice.assurance_signal','U') IS NULL
CREATE TABLE grac_practice.assurance_signal(
 signal_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_assurance_signal PRIMARY KEY,
 assurance_activity_id BIGINT NULL REFERENCES grac_practice.assurance_activity(assurance_activity_id),
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 practice_instance_id BIGINT NULL REFERENCES grac_practice.practice_instance(practice_instance_id),
 signal_type NVARCHAR(120) NOT NULL,
 severity NVARCHAR(40) NOT NULL DEFAULT N'Medium',
 signal_status NVARCHAR(80) NOT NULL DEFAULT N'Open',
 detected_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 message NVARCHAR(MAX) NOT NULL,
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.assurance_activity','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_assurance_activity_org_instance_status' AND object_id=OBJECT_ID('grac_practice.assurance_activity'))
 CREATE INDEX ix_pm_assurance_activity_org_instance_status ON grac_practice.assurance_activity(organization_id,practice_instance_id,status,due_dt);
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
 MERGE grac_practice.menu_master AS target
 USING (VALUES
  (N'assurance-dashboard',N'Assurance Dashboard',N'Practice/Index/assurance-dashboard',600,N'chart-line',N'Assurance Management'),
  (N'assurance-generation',N'Assurance Activity Generation',N'Practice/Index/assurance-generation',610,N'calendar-plus',N'Assurance Management'),
  (N'assurance-activities',N'Assurance Activity List',N'Practice/Index/assurance-activities',620,N'clipboard-list',N'Assurance Management'),
  (N'assurance-execution',N'Assurance Execution',N'Practice/Index/assurance-execution',630,N'person-circle-check',N'Assurance Management'),
  (N'evidence-assurance',N'Evidence Assurance',N'Practice/Index/evidence-assurance',640,N'file-circle-check',N'Assurance Management'),
  (N'dependency-assurance',N'Dependency Assurance',N'Practice/Index/dependency-assurance',650,N'network-wired',N'Assurance Management'),
  (N'assurance-results',N'Assurance Result',N'Practice/Index/assurance-results',660,N'square-poll-vertical',N'Assurance Management'),
  (N'assurance-findings',N'Findings',N'Practice/Index/assurance-findings',670,N'triangle-exclamation',N'Assurance Management'),
  (N'assurance-signals',N'Assurance Signals',N'Practice/Index/assurance-signals',680,N'wave-square',N'Assurance Management'),
  (N'assurance-trends',N'Trend Engine',N'Practice/Index/assurance-trends',690,N'chart-column',N'Assurance Management'),
  (N'practice-health',N'Practice Health Engine',N'Practice/Index/practice-health',700,N'heart-pulse',N'Assurance Management'),
  (N'audit-intelligence',N'Audit Intelligence View',N'Practice/Index/audit-intelligence',710,N'magnifying-glass-chart',N'Assurance Management'),
  (N'risk-intelligence',N'Risk Intelligence View',N'Practice/Index/risk-intelligence',720,N'shield-halved',N'Assurance Management')
 ) AS source(menu_key,menu_name,menu_url,display_order,icon_class,module_type)
 ON target.menu_key=source.menu_key
 WHEN MATCHED THEN UPDATE SET menu_name=source.menu_name,menu_url=source.menu_url,display_order=source.display_order,icon_class=source.icon_class,module_type=source.module_type,status='Active',updated_by='seed',updated_dt=SYSUTCDATETIME()
 WHEN NOT MATCHED THEN INSERT(menu_key,menu_name,menu_url,display_order,icon_class,module_type,status,entered_by)
 VALUES(source.menu_key,source.menu_name,source.menu_url,source.display_order,source.icon_class,source.module_type,'Active','seed');
END
GO

IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
BEGIN
 INSERT grac_practice.organization_role_menu_permission(role_id,menu_id,can_view,can_add,can_edit,can_delete,can_approve,status,record_status_id,entered_by)
 SELECT r.role_id,m.menu_id,1,1,1,0,0,'Active',
        (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master WHERE status_code='Active'),
        'seed'
 FROM grac_practice.organization_role r
 JOIN grac_practice.menu_master m ON m.module_type=N'Assurance Management' AND m.status='Active'
 WHERE r.status='Active'
   AND NOT EXISTS(
     SELECT 1
     FROM grac_practice.organization_role_menu_permission existing
     WHERE existing.role_id=r.role_id
       AND existing.menu_id=m.menu_id
   );
END
GO
