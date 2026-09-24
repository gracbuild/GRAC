/*
  GRAC Part 2 - Practice Intelligence Layer
  Foundation procedure facade consumed by PracticeManagement.Api.
*/
IF SCHEMA_ID('grac_practice') IS NULL
 THROW 51000, 'Schema grac_practice is missing. Run 001_practice_management_schema.sql first in the current target database.', 1;
GO

/*
  Safety normalization block
  --------------------------
  This procedure script is frequently rerun during development. Keep the
  prerequisite lookup tables and normalized StatusID columns in place before
  the stored procedures are compiled, otherwise SQL Server rejects procedure
  creation with invalid-column errors on older databases.
*/
IF OBJECT_ID('grac_practice.record_status_master','U') IS NULL
CREATE TABLE grac_practice.record_status_master(
 record_status_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_record_status_master PRIMARY KEY,
 status_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_record_status_code UNIQUE,
 status_name NVARCHAR(100) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.applicability_status_master','U') IS NULL
CREATE TABLE grac_practice.applicability_status_master(
 applicability_status_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_applicability_status_master PRIMARY KEY,
 status_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_applicability_status_code UNIQUE,
 status_name NVARCHAR(100) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.subscription_status_master','U') IS NULL
CREATE TABLE grac_practice.subscription_status_master(
 subscription_status_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_subscription_status_master PRIMARY KEY,
 status_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_subscription_status_code UNIQUE,
 status_name NVARCHAR(100) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.implementation_status_master','U') IS NULL
CREATE TABLE grac_practice.implementation_status_master(
 implementation_status_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_implementation_status_master PRIMARY KEY,
 status_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_implementation_status_code UNIQUE,
 status_name NVARCHAR(100) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE status_code='Active')
INSERT grac_practice.record_status_master(status_code,status_name,display_order)
VALUES('Active','Active',1),('Inactive','Inactive',2),('Retired','Retired',3),('Draft','Draft',4);
GO
IF NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE status_code='Disposed')
INSERT grac_practice.record_status_master(status_code,status_name,display_order)
VALUES('Disposed','Disposed',5);
GO

IF NOT EXISTS(SELECT 1 FROM grac_practice.applicability_status_master WHERE status_code='Not Updated')
INSERT grac_practice.applicability_status_master(status_code,status_name,display_order)
VALUES('Not Updated','Not Updated',1),('Applicable','Applicable',2),('Not Applicable','Not Applicable',3),('Deferred','Deferred',4),('Accepted Risk','Accepted Risk',5);
GO
IF NOT EXISTS(SELECT 1 FROM grac_practice.applicability_status_master WHERE status_code='Not Implemented')
INSERT grac_practice.applicability_status_master(status_code,status_name,display_order)
VALUES('Not Implemented','Not Implemented',6);
GO
IF NOT EXISTS(SELECT 1 FROM grac_practice.applicability_status_master WHERE status_code='Retired')
INSERT grac_practice.applicability_status_master(status_code,status_name,display_order)
VALUES('Retired','Retired',7);
GO

IF NOT EXISTS(SELECT 1 FROM grac_practice.subscription_status_master WHERE status_code='Active')
INSERT grac_practice.subscription_status_master(status_code,status_name,display_order)
VALUES('Active','Active',1),('Disabled','Disabled',2),('Superseded','Superseded',3),('Pending Review','Pending Review',4);
GO

IF NOT EXISTS(SELECT 1 FROM grac_practice.implementation_status_master WHERE status_code='Not Started')
INSERT grac_practice.implementation_status_master(status_code,status_name,display_order)
VALUES('Not Started','Not Started',1),('In Progress','In Progress',2),('Implemented','Implemented',3),('Active','Active',4),('Inactive','Inactive',5);
GO

IF OBJECT_ID('grac_practice.repository_subscription','U') IS NOT NULL AND COL_LENGTH('grac_practice.repository_subscription','record_status_id') IS NULL
 ALTER TABLE grac_practice.repository_subscription ADD record_status_id INT NULL;
GO
IF OBJECT_ID('grac_practice.repository_subscription','U') IS NOT NULL AND COL_LENGTH('grac_practice.repository_subscription','subscription_status_id') IS NULL
 ALTER TABLE grac_practice.repository_subscription ADD subscription_status_id INT NULL;
GO
IF OBJECT_ID('grac_practice.organization','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization','record_status_id') IS NULL
 ALTER TABLE grac_practice.organization ADD record_status_id INT NULL;
GO
IF OBJECT_ID('grac_practice.organization_metadata_value','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_metadata_value','record_status_id') IS NULL
 ALTER TABLE grac_practice.organization_metadata_value ADD record_status_id INT NULL;
GO
IF OBJECT_ID('grac_practice.organization_control','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_control','record_status_id') IS NULL
 ALTER TABLE grac_practice.organization_control ADD record_status_id INT NULL;
GO
IF OBJECT_ID('grac_practice.organization_control','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_control','applicability_status') IS NULL
 ALTER TABLE grac_practice.organization_control ADD applicability_status NVARCHAR(40) NOT NULL CONSTRAINT df_pm_org_control_applicability_status DEFAULT 'Not Updated';
GO
IF OBJECT_ID('grac_practice.organization_control','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_control','applicability_status_id') IS NULL
 ALTER TABLE grac_practice.organization_control ADD applicability_status_id INT NULL;
GO
IF OBJECT_ID('grac_practice.organization_control','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_control','release_id') IS NULL
 ALTER TABLE grac_practice.organization_control ADD release_id BIGINT NULL;
GO
IF OBJECT_ID('grac_practice.organization_control','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_control','artifact_id') IS NULL
 ALTER TABLE grac_practice.organization_control ADD artifact_id BIGINT NULL;
GO
IF OBJECT_ID('grac_practice.organization_requirement','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_requirement','record_status_id') IS NULL
 ALTER TABLE grac_practice.organization_requirement ADD record_status_id INT NULL;
GO
IF OBJECT_ID('grac_practice.organization_requirement','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_requirement','applicability_status') IS NULL
 ALTER TABLE grac_practice.organization_requirement ADD applicability_status NVARCHAR(40) NOT NULL CONSTRAINT df_pm_org_requirement_applicability_status DEFAULT 'Not Updated';
GO
IF OBJECT_ID('grac_practice.organization_requirement','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_requirement','applicability_status_id') IS NULL
 ALTER TABLE grac_practice.organization_requirement ADD applicability_status_id INT NULL;
GO
IF OBJECT_ID('grac_practice.organization_requirement','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_requirement','implementation_status') IS NULL
 ALTER TABLE grac_practice.organization_requirement ADD implementation_status NVARCHAR(40) NOT NULL CONSTRAINT df_pm_org_requirement_implementation_status DEFAULT 'Not Started';
GO
IF OBJECT_ID('grac_practice.organization_requirement','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_requirement','implementation_status_id') IS NULL
 ALTER TABLE grac_practice.organization_requirement ADD implementation_status_id INT NULL;
GO
IF OBJECT_ID('grac_practice.practice','U') IS NOT NULL AND COL_LENGTH('grac_practice.practice','record_status_id') IS NULL
 ALTER TABLE grac_practice.practice ADD record_status_id INT NULL;
GO
IF OBJECT_ID('grac_practice.practice','U') IS NOT NULL AND COL_LENGTH('grac_practice.practice','applicability_status') IS NULL
 ALTER TABLE grac_practice.practice ADD applicability_status NVARCHAR(40) NOT NULL CONSTRAINT df_pm_practice_applicability_status DEFAULT 'Not Updated';
GO
IF OBJECT_ID('grac_practice.practice','U') IS NOT NULL AND COL_LENGTH('grac_practice.practice','applicability_status_id') IS NULL
 ALTER TABLE grac_practice.practice ADD applicability_status_id INT NULL;
GO
IF OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL AND COL_LENGTH('grac_practice.practice_instance','record_status_id') IS NULL
 ALTER TABLE grac_practice.practice_instance ADD record_status_id INT NULL;
GO
IF OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL AND COL_LENGTH('grac_practice.practice_instance','implementation_status_id') IS NULL
 ALTER TABLE grac_practice.practice_instance ADD implementation_status_id INT NULL;
GO
IF OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NOT NULL AND COL_LENGTH('grac_practice.practice_instance_dependency','record_status_id') IS NULL
 ALTER TABLE grac_practice.practice_instance_dependency ADD record_status_id INT NULL;
GO

DECLARE @pm_active_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code='Active');
DECLARE @pm_not_updated_applicability_status_id INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Not Updated');
DECLARE @pm_active_subscription_status_id INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code='Active');
DECLARE @pm_not_started_implementation_status_id INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code='Not Started');

IF OBJECT_ID('grac_practice.organization','U') IS NOT NULL
 UPDATE grac_practice.organization SET record_status_id=@pm_active_record_status_id WHERE record_status_id IS NULL;
IF OBJECT_ID('grac_practice.repository_subscription','U') IS NOT NULL
 UPDATE grac_practice.repository_subscription SET record_status_id=@pm_active_record_status_id WHERE record_status_id IS NULL;
IF OBJECT_ID('grac_practice.repository_subscription','U') IS NOT NULL
 UPDATE grac_practice.repository_subscription SET subscription_status_id=@pm_active_subscription_status_id WHERE subscription_status_id IS NULL;
IF OBJECT_ID('grac_practice.organization_control','U') IS NOT NULL
 UPDATE grac_practice.organization_control SET record_status_id=@pm_active_record_status_id WHERE record_status_id IS NULL;
IF OBJECT_ID('grac_practice.organization_control','U') IS NOT NULL
 UPDATE grac_practice.organization_control SET applicability_status_id=@pm_not_updated_applicability_status_id WHERE applicability_status_id IS NULL;
IF OBJECT_ID('grac_practice.organization_requirement','U') IS NOT NULL
 UPDATE grac_practice.organization_requirement SET record_status_id=@pm_active_record_status_id WHERE record_status_id IS NULL;
IF OBJECT_ID('grac_practice.organization_requirement','U') IS NOT NULL
 UPDATE grac_practice.organization_requirement SET applicability_status_id=@pm_not_updated_applicability_status_id WHERE applicability_status_id IS NULL;
IF OBJECT_ID('grac_practice.organization_requirement','U') IS NOT NULL
 UPDATE grac_practice.organization_requirement SET implementation_status_id=@pm_not_started_implementation_status_id WHERE implementation_status_id IS NULL;
IF OBJECT_ID('grac_practice.practice','U') IS NOT NULL
 UPDATE grac_practice.practice SET record_status_id=@pm_active_record_status_id WHERE record_status_id IS NULL;
IF OBJECT_ID('grac_practice.practice','U') IS NOT NULL
 UPDATE grac_practice.practice SET applicability_status_id=@pm_not_updated_applicability_status_id WHERE applicability_status_id IS NULL;
IF OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
 UPDATE grac_practice.practice_instance SET record_status_id=@pm_active_record_status_id WHERE record_status_id IS NULL;
IF OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
 UPDATE grac_practice.practice_instance SET implementation_status_id=@pm_not_started_implementation_status_id WHERE implementation_status_id IS NULL;
IF OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NOT NULL
 UPDATE grac_practice.practice_instance_dependency SET record_status_id=@pm_active_record_status_id WHERE record_status_id IS NULL;
GO

IF OBJECT_ID('grac_practice.organization_division','U') IS NULL
CREATE TABLE grac_practice.organization_division(
 division_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_organization_division PRIMARY KEY,
 organization_id BIGINT NOT NULL,
 division_code NVARCHAR(80) NOT NULL,
 division_name NVARCHAR(200) NOT NULL,
 head_employee_id BIGINT NULL,
 description NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_division_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_division_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_division_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_division_organization FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_division_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_division_org_code UNIQUE(organization_id,division_code)
);
GO

IF OBJECT_ID('grac_practice.location_type_master','U') IS NULL
CREATE TABLE grac_practice.location_type_master(
 location_type_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_location_type_master PRIMARY KEY,
 location_type_code NVARCHAR(40) NOT NULL CONSTRAINT uq_pm_location_type_code UNIQUE,
 location_type_name NVARCHAR(120) NOT NULL,
 display_order INT NOT NULL CONSTRAINT df_pm_location_type_display DEFAULT 100,
 is_active BIT NOT NULL CONSTRAINT df_pm_location_type_active DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_location_type_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_location_type_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

MERGE grac_practice.location_type_master AS target
USING (VALUES
 ('HO','HO',10),
 ('BRANCH','Branch',20),
 ('DC','DC',30),
 ('DR','DR',40),
 ('OFFICE','Office',50),
 ('OTHER','Other',60)
) AS source(location_type_code,location_type_name,display_order)
ON target.location_type_code=source.location_type_code
WHEN MATCHED THEN UPDATE SET location_type_name=source.location_type_name,display_order=source.display_order,is_active=1,updated_by='system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(location_type_code,location_type_name,display_order,is_active,entered_by)
 VALUES(source.location_type_code,source.location_type_name,source.display_order,1,'system');
GO

IF OBJECT_ID('grac_practice.organization_location','U') IS NULL
CREATE TABLE grac_practice.organization_location(
 location_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_organization_location PRIMARY KEY,
 organization_id BIGINT NOT NULL,
 location_name NVARCHAR(200) NOT NULL,
 location_type_id INT NOT NULL,
 location_head_id BIGINT NULL,
 region NVARCHAR(160) NULL,
 remarks NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_location_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_location_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_location_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_location_organization FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_location_type FOREIGN KEY(location_type_id) REFERENCES grac_practice.location_type_master(location_type_id),
 CONSTRAINT fk_pm_location_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_location_org_name UNIQUE(organization_id,location_name)
);
GO

IF OBJECT_ID('grac_practice.organization_department','U') IS NULL
CREATE TABLE grac_practice.organization_department(
 department_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_organization_department PRIMARY KEY,
 organization_id BIGINT NOT NULL,
 department_code NVARCHAR(80) NOT NULL,
 department_name NVARCHAR(200) NOT NULL,
 head_employee_id BIGINT NULL,
 description NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_department_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_department_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_department_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_department_organization FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_department_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_department_org_code UNIQUE(organization_id,department_code)
);
GO

IF OBJECT_ID('grac_practice.organization_team','U') IS NULL
CREATE TABLE grac_practice.organization_team(
 team_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_organization_team PRIMARY KEY,
 organization_id BIGINT NOT NULL,
 team_name NVARCHAR(200) NOT NULL,
 team_manager_id BIGINT NULL,
 parent_department_id BIGINT NULL,
 remarks NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_team_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_team_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_team_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_team_organization FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_team_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_team_org_name UNIQUE(organization_id,team_name)
);
GO

IF OBJECT_ID('grac_practice.organization_committee','U') IS NULL
CREATE TABLE grac_practice.organization_committee(
 committee_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_organization_committee PRIMARY KEY,
 organization_id BIGINT NOT NULL,
 committee_name NVARCHAR(200) NOT NULL,
 chairperson_id BIGINT NULL,
 secretary_id BIGINT NULL,
 review_frequency_id INT NULL,
 remarks NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_committee_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_committee_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_committee_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_committee_organization FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_committee_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_committee_org_name UNIQUE(organization_id,committee_name)
);
GO

IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
CREATE TABLE grac_practice.organization_employee(
 employee_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_organization_employee PRIMARY KEY,
 organization_id BIGINT NOT NULL,
 employee_code NVARCHAR(80) NOT NULL,
 employee_name NVARCHAR(200) NOT NULL,
 email NVARCHAR(250) NULL,
 designation NVARCHAR(150) NULL,
 department NVARCHAR(150) NULL,
 location_id BIGINT NULL,
 division_id BIGINT NULL,
 department_id BIGINT NULL,
 business_function_id BIGINT NULL,
 reporting_officer_id BIGINT NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_employee_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_employee_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_employee_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_employee_organization FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_employee_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_employee_org_code UNIQUE(organization_id,employee_code)
);
GO

IF OBJECT_ID('grac_practice.user_organization_map','U') IS NULL
CREATE TABLE grac_practice.user_organization_map(
 user_organization_map_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_user_organization_map PRIMARY KEY,
 user_email NVARCHAR(250) NOT NULL,
 organization_id BIGINT NOT NULL,
 access_role NVARCHAR(80) NULL,
 is_default BIT NOT NULL CONSTRAINT df_pm_user_org_default DEFAULT 0,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_user_org_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_user_org_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_user_org_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_user_org_organization FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_user_org_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_user_org_email_org UNIQUE(user_email,organization_id)
);
GO

IF OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_employee','department_id') IS NULL
 ALTER TABLE grac_practice.organization_employee ADD department_id BIGINT NULL;
GO
IF OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_employee','location_id') IS NULL
 ALTER TABLE grac_practice.organization_employee ADD location_id BIGINT NULL;
GO
IF OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_employee','division_id') IS NULL
 ALTER TABLE grac_practice.organization_employee ADD division_id BIGINT NULL;
GO
IF OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_employee','business_function_id') IS NULL
 ALTER TABLE grac_practice.organization_employee ADD business_function_id BIGINT NULL;
GO
IF OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_employee','reporting_officer_id') IS NULL
 ALTER TABLE grac_practice.organization_employee ADD reporting_officer_id BIGINT NULL;
GO

IF OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_employee','password_hash') IS NULL
 ALTER TABLE grac_practice.organization_employee ADD password_hash NVARCHAR(500) NULL;
GO

IF OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL AND COL_LENGTH('grac_practice.organization_employee','role_id') IS NULL
 ALTER TABLE grac_practice.organization_employee ADD role_id BIGINT NULL;
GO

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
GO

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
GO

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
GO

IF OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL
AND OBJECT_ID('grac_practice.organization_role','U') IS NOT NULL
AND NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_employee_role')
 ALTER TABLE grac_practice.organization_employee ADD CONSTRAINT fk_pm_employee_role FOREIGN KEY(role_id) REFERENCES grac_practice.organization_role(role_id);
GO

IF OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL
AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_pm_employee_email' AND object_id=OBJECT_ID('grac_practice.organization_employee'))
AND NOT EXISTS(
 SELECT 1
 FROM grac_practice.organization_employee
 WHERE NULLIF(LTRIM(RTRIM(email)),'') IS NOT NULL
 GROUP BY LOWER(LTRIM(RTRIM(email)))
 HAVING COUNT_BIG(1)>1
)
 CREATE UNIQUE INDEX ux_pm_employee_email ON grac_practice.organization_employee(email) WHERE email IS NOT NULL AND email<>'';
GO

-- Values below were synced 2026-09-16 from a live export of grac_practice.menu_master
-- (name/url/display_order/icon_class/module_type only -- status and parent_menu_id
-- are not sourced here; parent linkage is 274's job, and status is deliberately left
-- off the WHEN MATCHED SET below). Before this sync several of these had drifted from
-- 274/347's later renames/reparents (e.g. organization-controls was still seeded here
-- as "Organization Controls" under Practice Management, while 274/347 had already
-- renamed it to "Repository Subscriptions" under Governance) -- harmless on its own,
-- but WHEN MATCHED was overwriting those fields back to the stale values on every run.
IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
 MERGE grac_practice.menu_master AS target
 USING (VALUES
  (N'dashboard',N'Dashboard',N'Practice/Index',0,N'chart-line',N'Dashboard'),
  (N'menu-master',N'Menu Master',N'Practice/Index/menu-master',6,N'bars',N'System'),
  (N'organization-setup',N'Organization Setup',N'Practice/Index/organization-setup',10,N'building',N'Organization Setup'),
  (N'organization-administration',N'Administration',N'Practice/Index/organization-administration',195,N'building-user',N'Organization'),
  (N'organizations',N'Organization Onboarding',N'Practice/Index/organizations',30,N'building',N'Organization Setup'),
  (N'organization-metadata',N'Organization Metadata',N'Practice/Index/organization-metadata',40,N'sliders',N'Organization Setup'),
  (N'repository-subscriptions',N'Repository Subscriptions (Admin)',N'Practice/Index/repository-subscriptions',50,N'bookmark',N'Organization Setup'),
  (N'locations',N'Location Management',N'Practice/Index/locations',60,N'location-dot',N'Organization Administration'),
  (N'departments',N'Department Management',N'Practice/Index/departments',70,N'building-user',N'Organization Administration'),
  (N'business-functions',N'Business Function Management',N'Practice/Index/business-functions',80,N'briefcase',N'Organization Administration'),
  (N'teams',N'Team Management',N'Practice/Index/teams',90,N'people-group',N'Organization Administration'),
  (N'committees',N'Committee Management',N'Practice/Index/committees',100,N'users-gear',N'Organization Administration'),
  (N'roles',N'Role Master',N'Practice/Index/roles',110,N'user-lock',N'Organization Administration'),
  (N'role-menu-permissions',N'Role Menu Permission',N'Practice/Index/role-menu-permissions',120,N'list-check',N'Organization Administration'),
  (N'users',N'User Management',N'Practice/Index/users',130,N'users',N'Organization Administration'),
  (N'organization-dependencies',N'Dependencies',N'Practice/Index/organization-dependencies',197,N'diagram-project',N'Organization'),
  (N'dependency-applications',N'Applications',N'Practice/Index/dependency-applications',150,N'window-restore',N'Organization Dependencies'),
  (N'dependency-tools',N'Tools',N'Practice/Index/dependency-tools',160,N'screwdriver-wrench',N'Organization Dependencies'),
  (N'dependency-vendors',N'Vendors',N'Practice/Index/dependency-vendors',170,N'handshake',N'Organization Dependencies'),
  (N'dependency-assets',N'Assets',N'Practice/Index/dependency-assets',180,N'server',N'Organization Dependencies'),
  (N'dependency-processes',N'Processes',N'Practice/Index/dependency-processes',190,N'arrows-spin',N'Organization Dependencies'),
  (N'organization-controls',N'Repository Subscriptions',N'Practice/Index/organization-controls',100,N'bookmark',N'Governance'),
  (N'organization-requirements',N'Organization Practices',N'Practice/Index/organization-requirements',110,N'list-check',N'Practice Management'),
  (N'practice-instances',N'Practice Instances',N'Practice/Index/practice-instances',115,N'network-wired',N'Practice Management'),
  (N'resolve',N'Operationalize',N'Practice/Index/resolve',120,N'gears',N'Governance'),
  (N'workbench-applications',N'Applications',N'Practice/Index/workbench-applications',240,N'window-restore',N'Registers'),
  (N'workbench-tools',N'Tools',N'Practice/Index/workbench-tools',250,N'screwdriver-wrench',N'Registers'),
  (N'workbench-vendors',N'Vendors',N'Practice/Index/workbench-vendors',260,N'handshake',N'Registers'),
  (N'workbench-assets',N'Assets',N'Practice/Index/workbench-assets',270,N'server',N'Registers'),
  (N'workbench-teams',N'Teams',N'Practice/Index/workbench-teams',280,N'people-group',N'Registers'),
  (N'workbench-committees',N'Committees',N'Practice/Index/workbench-committees',290,N'users-gear',N'Registers'),
  (N'workbench-processes',N'Processes',N'Practice/Index/workbench-processes',300,N'arrows-spin',N'Registers'),
  (N'workbench-locations',N'Locations',N'Practice/Index/workbench-locations',310,N'location-dot',N'Registers'),
  (N'audit-trace',N'Audit Traceability',N'Practice/Index/audit-trace',900,N'timeline',N'Governance')
 ) AS source(menu_key,menu_name,menu_url,display_order,icon_class,module_type)
 ON target.menu_key=source.menu_key
 -- status intentionally left out of this SET list -- on a MATCH, only cosmetic/
 -- navigation fields are kept in sync; whatever Active/Inactive an admin, 274, or
 -- 347 set for an existing menu is left untouched no matter how many times this
 -- file runs. A brand-new row (WHEN NOT MATCHED) still starts Active by default.
 WHEN MATCHED THEN UPDATE SET menu_name=source.menu_name,menu_url=source.menu_url,display_order=source.display_order,icon_class=source.icon_class,module_type=source.module_type,updated_by='seed',updated_dt=SYSUTCDATETIME()
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

IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
 UPDATE grac_practice.menu_master
 SET status='Inactive',updated_by='seed',updated_dt=SYSUTCDATETIME()
 WHERE menu_key='practice-operationalization';
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
 -- Same reasoning as the menu_master MERGE above -- status left off the MATCHED
 -- SET so a re-run can't reactivate a menu that was deliberately set Inactive.
 WHEN MATCHED THEN UPDATE SET menu_name=source.menu_name,menu_url=source.menu_url,display_order=source.display_order,icon_class=source.icon_class,module_type=source.module_type,updated_by='seed',updated_dt=SYSUTCDATETIME()
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

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_department_org_status' AND object_id=OBJECT_ID('grac_practice.organization_department'))
 CREATE INDEX ix_pm_department_org_status ON grac_practice.organization_department(organization_id,record_status_id,department_name);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_location_org_status' AND object_id=OBJECT_ID('grac_practice.organization_location'))
 CREATE INDEX ix_pm_location_org_status ON grac_practice.organization_location(organization_id,record_status_id,location_name);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_division_org_status' AND object_id=OBJECT_ID('grac_practice.organization_division'))
 CREATE INDEX ix_pm_division_org_status ON grac_practice.organization_division(organization_id,record_status_id,division_name);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_team_org_status' AND object_id=OBJECT_ID('grac_practice.organization_team'))
 CREATE INDEX ix_pm_team_org_status ON grac_practice.organization_team(organization_id,record_status_id,team_name);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_committee_org_status' AND object_id=OBJECT_ID('grac_practice.organization_committee'))
 CREATE INDEX ix_pm_committee_org_status ON grac_practice.organization_committee(organization_id,record_status_id,committee_name);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_employee_org_status' AND object_id=OBJECT_ID('grac_practice.organization_employee'))
 CREATE INDEX ix_pm_employee_org_status ON grac_practice.organization_employee(organization_id,record_status_id,employee_name);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_user_org_email_status' AND object_id=OBJECT_ID('grac_practice.user_organization_map'))
 CREATE INDEX ix_pm_user_org_email_status ON grac_practice.user_organization_map(user_email,record_status_id,organization_id);
GO

IF SCHEMA_ID('grac_practice') IS NOT NULL
   AND OBJECT_ID('grac_practice.criticality_master','U') IS NULL
BEGIN
 CREATE TABLE grac_practice.criticality_master(
  criticality_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_criticality_master PRIMARY KEY,
  criticality_code NVARCHAR(40) NOT NULL CONSTRAINT uq_pm_criticality_code UNIQUE,
  criticality_name NVARCHAR(80) NOT NULL,
  display_order INT NOT NULL DEFAULT 0,
  is_active BIT NOT NULL DEFAULT 1,
  entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL
 );
END
GO

IF OBJECT_ID('grac_practice.criticality_master','U') IS NOT NULL
BEGIN
 ;WITH seed(criticality_code,criticality_name,display_order) AS (
  SELECT N'Critical',N'Critical',1 UNION ALL
  SELECT N'High',N'High',2 UNION ALL
  SELECT N'Medium',N'Medium',3 UNION ALL
  SELECT N'Low',N'Low',4
 )
 INSERT grac_practice.criticality_master(criticality_code,criticality_name,display_order,entered_by)
 SELECT s.criticality_code,s.criticality_name,s.display_order,N'system'
 FROM seed s
 WHERE NOT EXISTS(
  SELECT 1 FROM grac_practice.criticality_master existing
  WHERE existing.criticality_code=s.criticality_code
     OR existing.criticality_name=s.criticality_name
 );
END
GO

IF OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.practice_instance_dependency','criticality_id') IS NULL
 ALTER TABLE grac_practice.practice_instance_dependency ADD criticality_id INT NULL;
GO

IF OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.criticality_master','U') IS NOT NULL
BEGIN
 UPDATE d
 SET criticality_id=cm.criticality_id
 FROM grac_practice.practice_instance_dependency d
 JOIN grac_practice.criticality_master cm
   ON cm.criticality_code=d.criticality OR cm.criticality_name=d.criticality
 WHERE d.criticality_id IS NULL;

 UPDATE d
 SET criticality_id=cm.criticality_id,
     criticality=cm.criticality_code
 FROM grac_practice.practice_instance_dependency d
 CROSS JOIN grac_practice.criticality_master cm
 WHERE d.criticality_id IS NULL
   AND cm.criticality_code=N'Medium';
END
GO

IF SCHEMA_ID('grac_practice') IS NOT NULL
   AND OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.frequency_master','U') IS NULL
BEGIN
 CREATE TABLE grac_practice.frequency_master(
  frequency_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_frequency_master PRIMARY KEY,
  frequency_code NVARCHAR(40) NOT NULL CONSTRAINT uq_pm_frequency_code UNIQUE,
  frequency_name NVARCHAR(80) NOT NULL,
  frequency_value INT NULL,
  frequency_unit NVARCHAR(40) NULL,
  is_custom BIT NOT NULL DEFAULT 0,
  display_order INT NOT NULL DEFAULT 0,
  is_active BIT NOT NULL DEFAULT 1,
  entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL
 );
END
GO

IF OBJECT_ID('grac_practice.organization_committee','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.frequency_master','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_committee_frequency')
BEGIN
 ALTER TABLE grac_practice.organization_committee
 ADD CONSTRAINT fk_pm_committee_frequency FOREIGN KEY(review_frequency_id) REFERENCES grac_practice.frequency_master(frequency_id);
END
GO

IF OBJECT_ID('grac_practice.frequency_master','U') IS NOT NULL
BEGIN
 ;WITH seed(frequency_code,frequency_name,frequency_value,frequency_unit,is_custom,display_order) AS (
  SELECT N'Daily',N'Daily',1,N'Day',0,1 UNION ALL
  SELECT N'Weekly',N'Weekly',1,N'Week',0,2 UNION ALL
  SELECT N'Monthly',N'Monthly',1,N'Month',0,3 UNION ALL
  SELECT N'Quarterly',N'Quarterly',3,N'Month',0,4 UNION ALL
  SELECT N'Half-Yearly',N'Half-Yearly',6,N'Month',0,5 UNION ALL
  SELECT N'Annual',N'Annual',12,N'Month',0,6 UNION ALL
  SELECT N'Event Driven',N'Event Driven',NULL,NULL,0,7 UNION ALL
  SELECT N'Continuous',N'Continuous',NULL,NULL,0,8 UNION ALL
  SELECT N'Custom',N'Custom',NULL,NULL,1,9
 )
 INSERT grac_practice.frequency_master(frequency_code,frequency_name,frequency_value,frequency_unit,is_custom,display_order,entered_by)
 SELECT s.frequency_code,s.frequency_name,s.frequency_value,s.frequency_unit,s.is_custom,s.display_order,N'system'
 FROM seed s
 WHERE NOT EXISTS(
  SELECT 1 FROM grac_practice.frequency_master existing
  WHERE existing.frequency_code=s.frequency_code OR existing.frequency_name=s.frequency_name
 );
END
GO

IF OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.practice_instance','frequency_id') IS NULL
 ALTER TABLE grac_practice.practice_instance ADD frequency_id INT NULL;

IF OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.practice_instance','primary_owner_id') IS NULL
 ALTER TABLE grac_practice.practice_instance ADD primary_owner_id BIGINT NULL;

IF OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.practice_instance','department_id') IS NULL
 ALTER TABLE grac_practice.practice_instance ADD department_id BIGINT NULL;

IF OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.practice_instance','execution_frequency_id') IS NULL
 ALTER TABLE grac_practice.practice_instance ADD execution_frequency_id INT NULL;

IF OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.practice_instance','assurance_frequency_id') IS NULL
 ALTER TABLE grac_practice.practice_instance ADD assurance_frequency_id INT NULL;
GO

IF OBJECT_ID('grac_practice.dependency_hosting_type_master','U') IS NULL
CREATE TABLE grac_practice.dependency_hosting_type_master(
 hosting_type_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_dependency_hosting_type PRIMARY KEY,
 hosting_type_code NVARCHAR(40) NOT NULL CONSTRAINT uq_pm_dependency_hosting_type_code UNIQUE,
 hosting_type_name NVARCHAR(120) NOT NULL,
 display_order INT NOT NULL CONSTRAINT df_pm_dependency_hosting_display DEFAULT 100,
 is_active BIT NOT NULL CONSTRAINT df_pm_dependency_hosting_active DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_dependency_hosting_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_dependency_hosting_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.dependency_license_type_master','U') IS NULL
CREATE TABLE grac_practice.dependency_license_type_master(
 license_type_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_dependency_license_type PRIMARY KEY,
 license_type_code NVARCHAR(40) NOT NULL CONSTRAINT uq_pm_dependency_license_type_code UNIQUE,
 license_type_name NVARCHAR(120) NOT NULL,
 display_order INT NOT NULL CONSTRAINT df_pm_dependency_license_display DEFAULT 100,
 is_active BIT NOT NULL CONSTRAINT df_pm_dependency_license_active DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_dependency_license_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_dependency_license_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.dependency_service_category_master','U') IS NULL
CREATE TABLE grac_practice.dependency_service_category_master(
 service_category_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_dependency_service_category PRIMARY KEY,
 service_category_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_dependency_service_category_code UNIQUE,
 service_category_name NVARCHAR(160) NOT NULL,
 display_order INT NOT NULL CONSTRAINT df_pm_dependency_service_category_display DEFAULT 100,
 is_active BIT NOT NULL CONSTRAINT df_pm_dependency_service_category_active DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_dependency_service_category_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_dependency_service_category_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.dependency_asset_category_master','U') IS NULL
CREATE TABLE grac_practice.dependency_asset_category_master(
 asset_category_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_dependency_asset_category PRIMARY KEY,
 asset_category_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_dependency_asset_category_code UNIQUE,
 asset_category_name NVARCHAR(160) NOT NULL,
 display_order INT NOT NULL CONSTRAINT df_pm_dependency_asset_category_display DEFAULT 100,
 is_active BIT NOT NULL CONSTRAINT df_pm_dependency_asset_category_active DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_dependency_asset_category_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_dependency_asset_category_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

MERGE grac_practice.dependency_hosting_type_master AS target
USING (VALUES ('ON_PREM','On-Prem',10),('CLOUD','Cloud',20),('SAAS','SaaS',30)) AS source(hosting_type_code,hosting_type_name,display_order)
ON target.hosting_type_code=source.hosting_type_code
WHEN MATCHED THEN UPDATE SET hosting_type_name=source.hosting_type_name,display_order=source.display_order,is_active=1,updated_by='system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(hosting_type_code,hosting_type_name,display_order,is_active,entered_by) VALUES(source.hosting_type_code,source.hosting_type_name,source.display_order,1,'system');
GO

MERGE grac_practice.dependency_license_type_master AS target
USING (VALUES ('SUBSCRIPTION','Subscription',10),('PERPETUAL','Perpetual',20)) AS source(license_type_code,license_type_name,display_order)
ON target.license_type_code=source.license_type_code
WHEN MATCHED THEN UPDATE SET license_type_name=source.license_type_name,display_order=source.display_order,is_active=1,updated_by='system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(license_type_code,license_type_name,display_order,is_active,entered_by) VALUES(source.license_type_code,source.license_type_name,source.display_order,1,'system');
GO

MERGE grac_practice.dependency_service_category_master AS target
USING (VALUES
 ('IT_SERVICES','IT Services',10),('CLOUD_SERVICES','Cloud Services',20),('CYBER_SECURITY','Cyber Security',30),
 ('PAYMENT_SERVICES','Payment Services',40),('FACILITY_SERVICES','Facility Services',50),('CONSULTING','Consulting',60),('OTHER','Other',100)
) AS source(service_category_code,service_category_name,display_order)
ON target.service_category_code=source.service_category_code
WHEN MATCHED THEN UPDATE SET service_category_name=source.service_category_name,display_order=source.display_order,is_active=1,updated_by='system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(service_category_code,service_category_name,display_order,is_active,entered_by) VALUES(source.service_category_code,source.service_category_name,source.display_order,1,'system');
GO

MERGE grac_practice.dependency_asset_category_master AS target
USING (VALUES
 ('SERVER','Server',10),('NETWORK_DEVICE','Network Device',20),('DATABASE','Database',30),('ENDPOINT','Endpoint',40),
 ('STORAGE','Storage',50),('FACILITY','Facility',60),('DOCUMENT','Document',70),('OTHER','Other',100)
) AS source(asset_category_code,asset_category_name,display_order)
ON target.asset_category_code=source.asset_category_code
WHEN MATCHED THEN UPDATE SET asset_category_name=source.asset_category_name,display_order=source.display_order,is_active=1,updated_by='system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(asset_category_code,asset_category_name,display_order,is_active,entered_by) VALUES(source.asset_category_code,source.asset_category_name,source.display_order,1,'system');
GO

IF OBJECT_ID('grac_practice.organization_dependency_vendor','U') IS NULL
CREATE TABLE grac_practice.organization_dependency_vendor(
 vendor_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_org_dependency_vendor PRIMARY KEY,
 organization_id BIGINT NOT NULL,
 vendor_name NVARCHAR(220) NOT NULL,
 service_category_id INT NOT NULL,
 relationship_owner_id BIGINT NULL,
 contract_start_dt DATE NULL,
 contract_end_dt DATE NULL,
 renewal_dt DATE NULL,
 sla_applicable BIT NOT NULL CONSTRAINT df_pm_org_vendor_sla DEFAULT 0,
 criticality_id INT NULL,
 remarks NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_org_vendor_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_org_vendor_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_org_vendor_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_org_vendor_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_org_vendor_category FOREIGN KEY(service_category_id) REFERENCES grac_practice.dependency_service_category_master(service_category_id),
 CONSTRAINT fk_pm_org_vendor_criticality FOREIGN KEY(criticality_id) REFERENCES grac_practice.criticality_master(criticality_id),
 CONSTRAINT fk_pm_org_vendor_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_org_vendor_name UNIQUE(organization_id,vendor_name)
);
GO

IF OBJECT_ID('grac_practice.organization_dependency_application','U') IS NULL
CREATE TABLE grac_practice.organization_dependency_application(
 application_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_org_dependency_application PRIMARY KEY,
 organization_id BIGINT NOT NULL,
 application_name NVARCHAR(220) NOT NULL,
 description NVARCHAR(MAX) NULL,
 business_owner_id BIGINT NULL,
 technical_owner_id BIGINT NULL,
 vendor_id BIGINT NULL,
 version_no NVARCHAR(80) NULL,
 hosting_type_id INT NULL,
 support_expiry_dt DATE NULL,
 end_of_life_dt DATE NULL,
 criticality_id INT NULL,
 remarks NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_org_app_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_org_app_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_org_app_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_org_app_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_org_app_vendor FOREIGN KEY(vendor_id) REFERENCES grac_practice.organization_dependency_vendor(vendor_id),
 CONSTRAINT fk_pm_org_app_hosting FOREIGN KEY(hosting_type_id) REFERENCES grac_practice.dependency_hosting_type_master(hosting_type_id),
 CONSTRAINT fk_pm_org_app_criticality FOREIGN KEY(criticality_id) REFERENCES grac_practice.criticality_master(criticality_id),
 CONSTRAINT fk_pm_org_app_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_org_app_name UNIQUE(organization_id,application_name)
);
GO

IF OBJECT_ID('grac_practice.organization_dependency_tool','U') IS NULL
CREATE TABLE grac_practice.organization_dependency_tool(
 tool_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_org_dependency_tool PRIMARY KEY,
 organization_id BIGINT NOT NULL,
 tool_name NVARCHAR(220) NOT NULL,
 description NVARCHAR(MAX) NULL,
 business_owner_id BIGINT NULL,
 vendor_id BIGINT NULL,
 license_type_id INT NULL,
 license_expiry_dt DATE NULL,
 support_expiry_dt DATE NULL,
 criticality_id INT NULL,
 remarks NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_org_tool_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_org_tool_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_org_tool_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_org_tool_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_org_tool_vendor FOREIGN KEY(vendor_id) REFERENCES grac_practice.organization_dependency_vendor(vendor_id),
 CONSTRAINT fk_pm_org_tool_license FOREIGN KEY(license_type_id) REFERENCES grac_practice.dependency_license_type_master(license_type_id),
 CONSTRAINT fk_pm_org_tool_criticality FOREIGN KEY(criticality_id) REFERENCES grac_practice.criticality_master(criticality_id),
 CONSTRAINT fk_pm_org_tool_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_org_tool_name UNIQUE(organization_id,tool_name)
);
GO

IF OBJECT_ID('grac_practice.organization_dependency_asset','U') IS NULL
CREATE TABLE grac_practice.organization_dependency_asset(
 asset_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_org_dependency_asset PRIMARY KEY,
 organization_id BIGINT NOT NULL,
 asset_name NVARCHAR(220) NOT NULL,
 asset_category_id INT NOT NULL,
 owner_id BIGINT NULL,
 location_id BIGINT NULL,
 purchase_dt DATE NULL,
 warranty_expiry_dt DATE NULL,
 amc_expiry_dt DATE NULL,
 criticality_id INT NULL,
 remarks NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_org_asset_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_org_asset_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_org_asset_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_org_asset_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_org_asset_category FOREIGN KEY(asset_category_id) REFERENCES grac_practice.dependency_asset_category_master(asset_category_id),
 CONSTRAINT fk_pm_org_asset_location FOREIGN KEY(location_id) REFERENCES grac_practice.organization_location(location_id),
 CONSTRAINT fk_pm_org_asset_criticality FOREIGN KEY(criticality_id) REFERENCES grac_practice.criticality_master(criticality_id),
 CONSTRAINT fk_pm_org_asset_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_org_asset_name UNIQUE(organization_id,asset_name)
);
GO

IF OBJECT_ID('grac_practice.organization_dependency_process','U') IS NULL
CREATE TABLE grac_practice.organization_dependency_process(
 process_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_org_dependency_process PRIMARY KEY,
 organization_id BIGINT NOT NULL,
 process_name NVARCHAR(220) NOT NULL,
 process_owner_id BIGINT NULL,
 version_no NVARCHAR(80) NULL,
 effective_dt DATE NULL,
 last_review_dt DATE NULL,
 next_review_dt DATE NULL,
 remarks NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_org_process_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_org_process_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_org_process_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_org_process_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_org_process_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 CONSTRAINT uq_pm_org_process_name UNIQUE(organization_id,process_name)
);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_dep_vendor_org_status' AND object_id=OBJECT_ID('grac_practice.organization_dependency_vendor'))
 CREATE INDEX ix_pm_dep_vendor_org_status ON grac_practice.organization_dependency_vendor(organization_id,record_status_id,vendor_name);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_dep_app_org_status' AND object_id=OBJECT_ID('grac_practice.organization_dependency_application'))
 CREATE INDEX ix_pm_dep_app_org_status ON grac_practice.organization_dependency_application(organization_id,record_status_id,application_name);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_dep_tool_org_status' AND object_id=OBJECT_ID('grac_practice.organization_dependency_tool'))
 CREATE INDEX ix_pm_dep_tool_org_status ON grac_practice.organization_dependency_tool(organization_id,record_status_id,tool_name);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_dep_asset_org_status' AND object_id=OBJECT_ID('grac_practice.organization_dependency_asset'))
 CREATE INDEX ix_pm_dep_asset_org_status ON grac_practice.organization_dependency_asset(organization_id,record_status_id,asset_name);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_dep_process_org_status' AND object_id=OBJECT_ID('grac_practice.organization_dependency_process'))
 CREATE INDEX ix_pm_dep_process_org_status ON grac_practice.organization_dependency_process(organization_id,record_status_id,process_name);
GO

IF OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.practice_instance_dependency','dependency_reference_id') IS NULL
 ALTER TABLE grac_practice.practice_instance_dependency ADD dependency_reference_id BIGINT NULL;
GO

IF OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.practice_instance_dependency','dependency_source_type') IS NULL
 ALTER TABLE grac_practice.practice_instance_dependency ADD dependency_source_type NVARCHAR(80) NULL;
GO

IF OBJECT_ID('grac_practice.dependency_type_source_config','U') IS NULL
CREATE TABLE grac_practice.dependency_type_source_config(
 dependency_type_source_config_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_dependency_type_source_config PRIMARY KEY,
 dependency_type_id INT NOT NULL,
 dependency_type_name NVARCHAR(120) NOT NULL,
 source_type NVARCHAR(80) NOT NULL,
 source_table_name NVARCHAR(256) NOT NULL,
 id_column_name SYSNAME NOT NULL,
 display_column_name SYSNAME NOT NULL,
 organization_filter_column SYSNAME NULL,
 status_filter_column SYSNAME NULL,
 status_active_value NVARCHAR(80) NULL,
 sort_column SYSNAME NULL,
 is_multi_select_allowed BIT NOT NULL CONSTRAINT df_pm_dep_src_multi DEFAULT 1,
 status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_dep_src_status DEFAULT 'Active',
 record_status_id INT NULL,
 entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_dep_src_entered_by DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_dep_src_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_dep_src_type FOREIGN KEY(dependency_type_id) REFERENCES grac_practice.dependency_type_master(dependency_type_id)
);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='uq_pm_dependency_type_source_config_type' AND object_id=OBJECT_ID('grac_practice.dependency_type_source_config'))
 CREATE UNIQUE INDEX uq_pm_dependency_type_source_config_type ON grac_practice.dependency_type_source_config(dependency_type_id);
GO

DECLARE @pm_dep_src_active_status_id INT=(SELECT TOP 1 record_status_id FROM grac_practice.record_status_master WHERE status_code='Active' OR status_name='Active' ORDER BY record_status_id);
WITH dependency_type_seed AS (
 SELECT N'Application' dependency_type_code,N'Application' dependency_type_name,1 display_order UNION ALL
 SELECT N'Tool',N'Tool',2 UNION ALL
 SELECT N'Vendor',N'Vendor',3 UNION ALL
 SELECT N'Asset',N'Asset',4 UNION ALL
 SELECT N'Process',N'Process',5 UNION ALL
 SELECT N'Location',N'Location',6 UNION ALL
 SELECT N'Person',N'Person',7 UNION ALL
 SELECT N'Team',N'Team',8 UNION ALL
 SELECT N'Committee',N'Committee',9
)
MERGE grac_practice.dependency_type_master AS target
USING dependency_type_seed AS source
ON target.dependency_type_code=source.dependency_type_code
WHEN MATCHED THEN UPDATE SET dependency_type_name=source.dependency_type_name,display_order=source.display_order,is_active=1,updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(dependency_type_code,dependency_type_name,display_order,is_active,entered_by)
VALUES(source.dependency_type_code,source.dependency_type_name,source.display_order,1,N'system');

WITH dependency_source_seed AS (
 SELECT dt.dependency_type_id,dt.dependency_type_name,dt.dependency_type_name source_type,N'grac_practice.organization_dependency_tool' source_table_name,N'tool_id' id_column_name,N'tool_name' display_column_name,N'organization_id' organization_filter_column,N'status' status_filter_column,N'Active' status_active_value,N'tool_name' sort_column
 FROM grac_practice.dependency_type_master dt WHERE dt.dependency_type_name='Tool' OR dt.dependency_type_code='TOOL'
 UNION ALL
 SELECT dt.dependency_type_id,dt.dependency_type_name,dt.dependency_type_name,N'grac_practice.organization_dependency_vendor',N'vendor_id',N'vendor_name',N'organization_id',N'status',N'Active',N'vendor_name'
 FROM grac_practice.dependency_type_master dt WHERE dt.dependency_type_name='Vendor' OR dt.dependency_type_code='VENDOR'
 UNION ALL
 SELECT dt.dependency_type_id,dt.dependency_type_name,dt.dependency_type_name,N'grac_practice.organization_dependency_application',N'application_id',N'application_name',N'organization_id',N'status',N'Active',N'application_name'
 FROM grac_practice.dependency_type_master dt WHERE dt.dependency_type_name='Application' OR dt.dependency_type_code='APPLICATION'
 UNION ALL
 SELECT dt.dependency_type_id,dt.dependency_type_name,dt.dependency_type_name,N'grac_practice.organization_dependency_asset',N'asset_id',N'asset_name',N'organization_id',N'status',N'Active',N'asset_name'
 FROM grac_practice.dependency_type_master dt WHERE dt.dependency_type_name='Asset' OR dt.dependency_type_code='ASSET'
 UNION ALL
 SELECT dt.dependency_type_id,dt.dependency_type_name,dt.dependency_type_name,N'grac_practice.organization_dependency_process',N'process_id',N'process_name',N'organization_id',N'status',N'Active',N'process_name'
 FROM grac_practice.dependency_type_master dt WHERE dt.dependency_type_name='Process' OR dt.dependency_type_code='PROCESS'
 UNION ALL
 SELECT dt.dependency_type_id,dt.dependency_type_name,dt.dependency_type_name,N'grac_practice.organization_location',N'location_id',N'location_name',N'organization_id',N'status',N'Active',N'location_name'
 FROM grac_practice.dependency_type_master dt WHERE dt.dependency_type_name='Location' OR dt.dependency_type_code='LOCATION'
 UNION ALL
 SELECT dt.dependency_type_id,dt.dependency_type_name,dt.dependency_type_name,N'grac_practice.organization_employee',N'employee_id',N'employee_name',N'organization_id',N'status',N'Active',N'employee_name'
 FROM grac_practice.dependency_type_master dt WHERE dt.dependency_type_name='Person' OR dt.dependency_type_code='PERSON'
 UNION ALL
 SELECT dt.dependency_type_id,dt.dependency_type_name,dt.dependency_type_name,N'grac_practice.organization_team',N'team_id',N'team_name',N'organization_id',N'status',N'Active',N'team_name'
 FROM grac_practice.dependency_type_master dt WHERE dt.dependency_type_name='Team' OR dt.dependency_type_code='TEAM'
 UNION ALL
 SELECT dt.dependency_type_id,dt.dependency_type_name,dt.dependency_type_name,N'grac_practice.organization_committee',N'committee_id',N'committee_name',N'organization_id',N'status',N'Active',N'committee_name'
 FROM grac_practice.dependency_type_master dt WHERE dt.dependency_type_name='Committee' OR dt.dependency_type_code='COMMITTEE'
)
MERGE grac_practice.dependency_type_source_config AS target
USING dependency_source_seed AS source
ON target.dependency_type_id=source.dependency_type_id
WHEN MATCHED THEN UPDATE SET
 dependency_type_name=source.dependency_type_name,
 source_type=source.source_type,
 source_table_name=source.source_table_name,
 id_column_name=source.id_column_name,
 display_column_name=source.display_column_name,
 organization_filter_column=source.organization_filter_column,
 status_filter_column=source.status_filter_column,
 status_active_value=source.status_active_value,
 sort_column=source.sort_column,
 is_multi_select_allowed=1,
 status='Active',
 record_status_id=@pm_dep_src_active_status_id,
 updated_by='system',
 updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(dependency_type_id,dependency_type_name,source_type,source_table_name,id_column_name,display_column_name,organization_filter_column,status_filter_column,status_active_value,sort_column,is_multi_select_allowed,status,record_status_id,entered_by)
 VALUES(source.dependency_type_id,source.dependency_type_name,source.source_type,source.source_table_name,source.id_column_name,source.display_column_name,source.organization_filter_column,source.status_filter_column,source.status_active_value,source.sort_column,1,'Active',@pm_dep_src_active_status_id,'system');
GO

IF OBJECT_ID('grac_practice.operationalization_status_master','U') IS NULL
CREATE TABLE grac_practice.operationalization_status_master(
 operationalization_status_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_operationalization_status_master PRIMARY KEY,
 status_code NVARCHAR(80) NOT NULL CONSTRAINT uq_pm_operationalization_status_code UNIQUE,
 status_name NVARCHAR(160) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.operationalization_status_master','U') IS NOT NULL
BEGIN
 ;WITH seed(status_code,status_name,display_order) AS (
  SELECT N'Configured',N'Configured',1 UNION ALL
  SELECT N'Partially Operationalized',N'Partially Operationalized',2 UNION ALL
  SELECT N'Operationalized',N'Operationalized',3 UNION ALL
  SELECT N'Retired',N'Retired',4
 )
 MERGE grac_practice.operationalization_status_master AS target
 USING seed AS source
 ON target.status_code=source.status_code
 WHEN MATCHED THEN UPDATE SET status_name=source.status_name,display_order=source.display_order,is_active=1,updated_by=N'system',updated_dt=SYSUTCDATETIME()
 WHEN NOT MATCHED THEN INSERT(status_code,status_name,display_order,is_active,entered_by)
 VALUES(source.status_code,source.status_name,source.display_order,1,N'system');
END
GO

IF OBJECT_ID('grac_practice.dependency_resolution_status_master','U') IS NULL
CREATE TABLE grac_practice.dependency_resolution_status_master(
 resolution_status_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_dependency_resolution_status_master PRIMARY KEY,
 status_code NVARCHAR(80) NOT NULL CONSTRAINT uq_pm_dependency_resolution_status_code UNIQUE,
 status_name NVARCHAR(160) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.dependency_resolution_status_master','U') IS NOT NULL
BEGIN
 ;WITH seed(status_code,status_name,display_order) AS (
  SELECT N'Pending',N'Pending',1 UNION ALL
  SELECT N'Resolved',N'Resolved',2
 )
 MERGE grac_practice.dependency_resolution_status_master AS target
 USING seed AS source
 ON target.status_code=source.status_code
 WHEN MATCHED THEN UPDATE SET status_name=source.status_name,display_order=source.display_order,is_active=1,updated_by=N'system',updated_dt=SYSUTCDATETIME()
 WHEN NOT MATCHED THEN INSERT(status_code,status_name,display_order,is_active,entered_by)
 VALUES(source.status_code,source.status_name,source.display_order,1,N'system');
END
GO

IF OBJECT_ID('grac_practice.practice_operationalization','U') IS NULL
   AND OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.operationalization_status_master','U') IS NOT NULL
BEGIN
 CREATE TABLE grac_practice.practice_operationalization(
  operationalization_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_practice_operationalization PRIMARY KEY,
  organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
  practice_instance_id BIGINT NOT NULL REFERENCES grac_practice.practice_instance(practice_instance_id),
  status_id INT NOT NULL REFERENCES grac_practice.operationalization_status_master(operationalization_status_id),
  status NVARCHAR(80) NOT NULL DEFAULT N'Configured',
  record_status_id INT NULL REFERENCES grac_practice.record_status_master(record_status_id),
  entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL,
  CONSTRAINT uq_pm_practice_operationalization_instance UNIQUE(organization_id,practice_instance_id)
 );
END
GO

IF OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
   AND OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.dependency_type_master','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.dependency_resolution_status_master','U') IS NOT NULL
BEGIN
 CREATE TABLE grac_practice.practice_dependency_resolution(
  resolution_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_practice_dependency_resolution PRIMARY KEY,
  organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
  practice_instance_id BIGINT NOT NULL REFERENCES grac_practice.practice_instance(practice_instance_id),
  dependency_type_id INT NOT NULL REFERENCES grac_practice.dependency_type_master(dependency_type_id),
  dependency_category NVARCHAR(120) NOT NULL,
  resolved_dependency_id BIGINT NOT NULL,
  resolved_dependency_name NVARCHAR(300) NOT NULL,
  resolution_status_id INT NOT NULL REFERENCES grac_practice.dependency_resolution_status_master(resolution_status_id),
  resolution_status NVARCHAR(80) NOT NULL DEFAULT N'Resolved',
  resolution_owner_id BIGINT NULL REFERENCES grac_practice.organization_employee(employee_id),
  resolution_dt DATETIME2 NULL,
  remarks NVARCHAR(MAX) NULL,
  is_active BIT NOT NULL DEFAULT 1,
  record_status_id INT NULL REFERENCES grac_practice.record_status_master(record_status_id),
  entered_by NVARCHAR(100) NOT NULL,
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL,
  CONSTRAINT uq_pm_practice_dependency_resolution UNIQUE(organization_id,practice_instance_id,dependency_type_id,resolved_dependency_id)
 );
END
GO

IF OBJECT_ID('grac_practice.dependency_custodian_mapping','U') IS NULL
   AND OBJECT_ID('grac_practice.dependency_type_master','U') IS NOT NULL
BEGIN
 CREATE TABLE grac_practice.dependency_custodian_mapping(
  mapping_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_dependency_custodian_mapping PRIMARY KEY,
  organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
  dependency_type_id INT NOT NULL REFERENCES grac_practice.dependency_type_master(dependency_type_id),
  custodian_user_id BIGINT NOT NULL REFERENCES grac_practice.organization_employee(employee_id),
  is_active BIT NOT NULL DEFAULT 1,
  record_status_id INT NULL REFERENCES grac_practice.record_status_master(record_status_id),
  entered_by NVARCHAR(100) NOT NULL,
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL,
  CONSTRAINT uq_pm_dependency_custodian_mapping UNIQUE(organization_id,dependency_type_id,custodian_user_id)
 );
END
GO

IF OBJECT_ID('grac_practice.practice_operationalization','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_operationalization_org_instance' AND object_id=OBJECT_ID('grac_practice.practice_operationalization'))
 CREATE INDEX ix_pm_operationalization_org_instance ON grac_practice.practice_operationalization(organization_id,practice_instance_id,status_id);
GO

IF OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_dependency_resolution_instance' AND object_id=OBJECT_ID('grac_practice.practice_dependency_resolution'))
 CREATE INDEX ix_pm_dependency_resolution_instance ON grac_practice.practice_dependency_resolution(organization_id,practice_instance_id,dependency_type_id,is_active);
GO

IF SCHEMA_ID('GRAC_New') IS NOT NULL
   AND OBJECT_ID('GRAC_New.evidence_type_master','U') IS NULL
BEGIN
 CREATE TABLE GRAC_New.evidence_type_master(
  evidence_type_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_evidence_type_master PRIMARY KEY,
  evidence_type_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_evidence_type_code UNIQUE,
  evidence_type_name NVARCHAR(160) NOT NULL,
  display_order INT NOT NULL DEFAULT 0,
  is_active BIT NOT NULL DEFAULT 1,
  entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL
 );
END
GO

IF OBJECT_ID('GRAC_New.evidence_type_master','U') IS NOT NULL
BEGIN
 ;WITH seed(evidence_type_code,evidence_type_name,display_order) AS (
  SELECT N'Policy Document',N'Policy Document',1 UNION ALL
  SELECT N'Procedure Document',N'Procedure Document',2 UNION ALL
  SELECT N'System Screenshot',N'System Screenshot',3 UNION ALL
  SELECT N'System Report',N'System Report',4 UNION ALL
  SELECT N'Audit Log',N'Audit Log',5 UNION ALL
  SELECT N'Approval Record',N'Approval Record',6 UNION ALL
  SELECT N'Review Register',N'Review Register',7 UNION ALL
  SELECT N'Meeting Minutes',N'Meeting Minutes',8 UNION ALL
  SELECT N'Configuration Export',N'Configuration Export',9 UNION ALL
  SELECT N'Incident Report',N'Incident Report',10
 )
 INSERT GRAC_New.evidence_type_master(evidence_type_code,evidence_type_name,display_order,entered_by)
 SELECT s.evidence_type_code,s.evidence_type_name,s.display_order,N'system'
 FROM seed s
 WHERE NOT EXISTS(
  SELECT 1 FROM GRAC_New.evidence_type_master existing
  WHERE existing.evidence_type_code=s.evidence_type_code OR existing.evidence_type_name=s.evidence_type_name
 );
END
GO

IF SCHEMA_ID('grac_practice') IS NOT NULL
   AND OBJECT_ID('grac_practice.collection_method_master','U') IS NULL
BEGIN
 CREATE TABLE grac_practice.collection_method_master(
  collection_method_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_collection_method_master PRIMARY KEY,
  collection_method_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_collection_method_code UNIQUE,
  collection_method_name NVARCHAR(120) NOT NULL,
  display_order INT NOT NULL DEFAULT 0,
  is_active BIT NOT NULL DEFAULT 1,
  entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL
 );
END
GO

IF OBJECT_ID('grac_practice.collection_method_master','U') IS NOT NULL
BEGIN
 ;WITH seed(collection_method_code,collection_method_name,display_order) AS (
  SELECT N'Manual',N'Manual',1 UNION ALL
  SELECT N'Automated',N'Automated',2
 )
 INSERT grac_practice.collection_method_master(collection_method_code,collection_method_name,display_order,entered_by)
 SELECT s.collection_method_code,s.collection_method_name,s.display_order,N'system'
 FROM seed s
 WHERE NOT EXISTS(
  SELECT 1 FROM grac_practice.collection_method_master existing
  WHERE existing.collection_method_code=s.collection_method_code OR existing.collection_method_name=s.collection_method_name
 );
END
GO

IF SCHEMA_ID('grac_practice') IS NOT NULL
   AND OBJECT_ID('grac_practice.assurance_type_master','U') IS NULL
BEGIN
 CREATE TABLE grac_practice.assurance_type_master(
  assurance_type_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_assurance_type_master PRIMARY KEY,
  assurance_type_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_assurance_type_code UNIQUE,
  assurance_type_name NVARCHAR(120) NOT NULL,
  display_order INT NOT NULL DEFAULT 0,
  is_active BIT NOT NULL DEFAULT 1,
  entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL
 );
END
GO

IF OBJECT_ID('grac_practice.assurance_type_master','U') IS NOT NULL
BEGIN
 ;WITH seed(assurance_type_code,assurance_type_name,display_order) AS (
  SELECT N'Manual',N'Manual',1 UNION ALL
  SELECT N'Automated',N'Automated',2
 )
 INSERT grac_practice.assurance_type_master(assurance_type_code,assurance_type_name,display_order,entered_by)
 SELECT s.assurance_type_code,s.assurance_type_name,s.display_order,N'system'
 FROM seed s
 WHERE NOT EXISTS(
  SELECT 1 FROM grac_practice.assurance_type_master existing
  WHERE existing.assurance_type_code=s.assurance_type_code OR existing.assurance_type_name=s.assurance_type_name
 );
 UPDATE grac_practice.assurance_type_master
 SET is_active=CASE WHEN assurance_type_code IN (N'Manual',N'Automated') THEN 1 ELSE 0 END,
     updated_by=N'system',
     updated_dt=SYSUTCDATETIME()
 WHERE assurance_type_code IN (N'Manual',N'Automated',N'Semi-Automated',N'Semi Automated',N'Hybrid')
    OR assurance_type_name IN (N'Manual',N'Automated',N'Semi-Automated',N'Semi Automated',N'Hybrid');
END
GO

IF SCHEMA_ID('grac_practice') IS NOT NULL
   AND OBJECT_ID('grac_practice.evidence_alignment_status_master','U') IS NULL
BEGIN
 CREATE TABLE grac_practice.evidence_alignment_status_master(
  alignment_status_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_evidence_alignment_status_master PRIMARY KEY,
  alignment_status_code NVARCHAR(80) NOT NULL CONSTRAINT uq_pm_evidence_alignment_status_code UNIQUE,
  alignment_status_name NVARCHAR(160) NOT NULL,
  display_order INT NOT NULL DEFAULT 0,
  is_active BIT NOT NULL DEFAULT 1,
  entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL
 );
END
GO

IF OBJECT_ID('grac_practice.evidence_alignment_status_master','U') IS NOT NULL
BEGIN
 UPDATE grac_practice.evidence_alignment_status_master
 SET is_active=0,updated_by=N'system',updated_dt=SYSUTCDATETIME()
 WHERE alignment_status_code NOT IN (N'Inherited',N'Enhanced',N'Partially Aligned',N'Organization Defined');

 ;WITH seed(alignment_status_code,alignment_status_name,display_order) AS (
  SELECT N'Inherited',N'Inherited',1 UNION ALL
  SELECT N'Enhanced',N'Enhanced',2 UNION ALL
  SELECT N'Partially Aligned',N'Partially Aligned',3 UNION ALL
  SELECT N'Organization Defined',N'Organization Defined',4 UNION ALL
  SELECT N'Aligned',N'Aligned',5 UNION ALL
  SELECT N'Not Aligned',N'Not Aligned',6
 )
 MERGE grac_practice.evidence_alignment_status_master AS target
 USING seed AS source
 ON target.alignment_status_code=source.alignment_status_code
 WHEN MATCHED THEN UPDATE SET alignment_status_name=source.alignment_status_name,display_order=source.display_order,is_active=1,updated_by=N'system',updated_dt=SYSUTCDATETIME()
 WHEN NOT MATCHED THEN INSERT(alignment_status_code,alignment_status_name,display_order,is_active,entered_by)
 VALUES(source.alignment_status_code,source.alignment_status_name,source.display_order,1,N'system');
END
GO

IF OBJECT_ID('grac_practice.practice_instance_evidence_alignment','U') IS NULL
   AND OBJECT_ID('grac_practice.evidence_alignment_status_master','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
BEGIN
 CREATE TABLE grac_practice.practice_instance_evidence_alignment(
  evidence_alignment_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_practice_instance_evidence_alignment PRIMARY KEY,
  practice_instance_id BIGINT NOT NULL REFERENCES grac_practice.practice_instance(practice_instance_id),
  framework_release_id BIGINT NOT NULL,
  alignment_status_id INT NOT NULL REFERENCES grac_practice.evidence_alignment_status_master(alignment_status_id),
  alignment_reason NVARCHAR(MAX) NULL,
  calculated_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  status NVARCHAR(30) NOT NULL DEFAULT 'Active',
  entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL,
  CONSTRAINT uq_pm_evidence_alignment_instance_release UNIQUE(practice_instance_id,framework_release_id)
 );
END
GO

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NULL
   AND OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.collection_method_master','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.frequency_master','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.evidence_alignment_status_master','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.record_status_master','U') IS NOT NULL
BEGIN
 CREATE TABLE grac_practice.practice_instance_evidence(
  evidence_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_practice_instance_evidence PRIMARY KEY,
  organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
  practice_instance_id BIGINT NOT NULL REFERENCES grac_practice.practice_instance(practice_instance_id),
  evidence_type_id INT NOT NULL,
  inherited_from_repository BIT NOT NULL DEFAULT 0,
  organization_modified BIT NOT NULL DEFAULT 0,
  is_mandatory BIT NOT NULL DEFAULT 1,
  collection_method_id INT NOT NULL REFERENCES grac_practice.collection_method_master(collection_method_id),
  collection_frequency_id INT NULL REFERENCES grac_practice.frequency_master(frequency_id),
  evidence_owner NVARCHAR(200) NULL,
  assurance_type_id INT NULL REFERENCES grac_practice.assurance_type_master(assurance_type_id),
  retention_period NVARCHAR(120) NULL,
  alignment_status_id INT NOT NULL REFERENCES grac_practice.evidence_alignment_status_master(alignment_status_id),
  status NVARCHAR(30) NOT NULL DEFAULT 'Active',
  record_status_id INT NULL REFERENCES grac_practice.record_status_master(record_status_id),
  entered_by NVARCHAR(100) NOT NULL,
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL
 );
END
GO

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NOT NULL AND COL_LENGTH('grac_practice.practice_instance_evidence','evidence_description') IS NULL
 ALTER TABLE grac_practice.practice_instance_evidence ADD evidence_description NVARCHAR(MAX) NULL;
GO
IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NOT NULL AND COL_LENGTH('grac_practice.practice_instance_evidence','assurance_type_id') IS NULL
 ALTER TABLE grac_practice.practice_instance_evidence ADD assurance_type_id INT NULL;
GO
IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NOT NULL AND COL_LENGTH('grac_practice.practice_instance_evidence','retention_period') IS NULL
 ALTER TABLE grac_practice.practice_instance_evidence ADD retention_period NVARCHAR(120) NULL;
GO
IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NOT NULL AND COL_LENGTH('grac_practice.practice_instance_evidence','evidence_location') IS NULL
 ALTER TABLE grac_practice.practice_instance_evidence ADD evidence_location NVARCHAR(500) NULL;
GO
IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NOT NULL AND COL_LENGTH('grac_practice.practice_instance_evidence','evidence_locator') IS NULL
 ALTER TABLE grac_practice.practice_instance_evidence ADD evidence_locator NVARCHAR(500) NULL;
GO

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.evidence_type_master','U') IS NOT NULL
BEGIN
 DECLARE @old_evidence_fk SYSNAME;
 SELECT @old_evidence_fk=fk.name
 FROM sys.foreign_keys fk
 WHERE fk.parent_object_id=OBJECT_ID('grac_practice.practice_instance_evidence')
   AND fk.referenced_object_id=OBJECT_ID('grac_practice.evidence_type_master');
 IF @old_evidence_fk IS NOT NULL
 BEGIN
   DECLARE @drop_old_evidence_fk_sql NVARCHAR(MAX)=N'ALTER TABLE grac_practice.practice_instance_evidence DROP CONSTRAINT '+QUOTENAME(@old_evidence_fk);
   EXEC sys.sp_executesql @drop_old_evidence_fk_sql;
 END
END
GO

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NOT NULL
   AND OBJECT_ID('GRAC_New.evidence_type_master','U') IS NOT NULL
   AND NOT EXISTS(
     SELECT 1 FROM sys.foreign_keys fk
     WHERE fk.parent_object_id=OBJECT_ID('grac_practice.practice_instance_evidence')
       AND fk.referenced_object_id=OBJECT_ID('GRAC_New.evidence_type_master')
   )
   AND NOT EXISTS(
     SELECT 1
     FROM grac_practice.practice_instance_evidence e
     LEFT JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=e.evidence_type_id
     WHERE et.evidence_type_id IS NULL
   )
BEGIN
 ALTER TABLE grac_practice.practice_instance_evidence
 ADD CONSTRAINT fk_pm_evidence_shared_type FOREIGN KEY(evidence_type_id) REFERENCES GRAC_New.evidence_type_master(evidence_type_id);
END
GO

IF OBJECT_ID('grac_practice.practice','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.practice','practice_owner_id') IS NULL
BEGIN
 ALTER TABLE grac_practice.practice ADD practice_owner_id BIGINT NULL;
END
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

-- SUPERSEDED BY 300_generic_grid_total_rows.sql.
-- 300 re-emits this procedure whole with COUNT(*) OVER () AS TotalRows on
-- each of its 37 paged branches, because CREATE OR ALTER cannot patch a
-- projection in place. The copy below is the baseline and is left as the
-- historical record; it is NOT what a deployed database ends up running.
-- Change a branch in 300, not here -- an edit made here is reverted the
-- next time 300 runs, the same way menu_master edits are reverted by 274.
CREATE OR ALTER PROCEDURE dbo.pm_get_practice_repository
 @p_entity_type NVARCHAR(100), @p_action NVARCHAR(30)='', @p_id BIGINT=0, @p_search NVARCHAR(250)='', @p_status NVARCHAR(30)='',
 @p_payload NVARCHAR(MAX)='{}', @p_usr_id NVARCHAR(100)=''
AS
BEGIN
 SET NOCOUNT ON;
 SET @p_entity_type=ISNULL(@p_entity_type,'');
 SET @p_action=ISNULL(@p_action,'');
 SET @p_search=ISNULL(@p_search,'');
 SET @p_status=ISNULL(@p_status,'');
 SET @p_payload=ISNULL(NULLIF(@p_payload,''),'{}');
 SET @p_usr_id=ISNULL(@p_usr_id,'');
 DECLARE @organization_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.organizationId'));
 DECLARE @organization_control_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.organizationControlId'));
 DECLARE @organization_requirement_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.organizationRequirementId'));
 DECLARE @practice_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.practiceId'));
 DECLARE @practice_instance_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.practiceInstanceId'));
 DECLARE @assurance_activity_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.assuranceActivityId'));
 DECLARE @page_number INT=ISNULL(NULLIF(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.pageNumber')),0),1);
 DECLARE @page_size INT=ISNULL(NULLIF(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.pageSize')),0),25);
 DECLARE @owner NVARCHAR(200)=NULLIF(JSON_VALUE(@p_payload,'$.owner'),'');
 DECLARE @criticality NVARCHAR(30)=NULLIF(JSON_VALUE(@p_payload,'$.criticality'),'');
 DECLARE @origin_type NVARCHAR(30)=NULLIF(JSON_VALUE(@p_payload,'$.originType'),'');
 DECLARE @date_from DATETIME2=TRY_CONVERT(DATETIME2,JSON_VALUE(@p_payload,'$.dateFrom'));
 DECLARE @date_to DATETIME2=TRY_CONVERT(DATETIME2,JSON_VALUE(@p_payload,'$.dateTo'));
 IF @page_number<1 SET @page_number=1;
 IF @page_size<1 SET @page_size=25;
 IF @page_size>200 SET @page_size=200;
 DECLARE @offset INT=(@page_number-1)*@page_size;
 DECLARE @active_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code='Active');
 DECLARE @inactive_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code='Inactive');
 DECLARE @filter_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code=@p_status OR status_name=@p_status);
 DECLARE @active_subscription_status_id INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code='Active');
 DECLARE @filter_subscription_status_id INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code=@p_status OR status_name=@p_status);
 DECLARE @is_system_admin BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$._security.isSystemAdmin'),'false')) IN ('true','1','yes') THEN 1 ELSE 0 END;
 DECLARE @allowed_organizations TABLE(organization_id BIGINT PRIMARY KEY);
 INSERT @allowed_organizations(organization_id)
 SELECT DISTINCT organization_id
 FROM grac_practice.user_organization_map
 WHERE user_email=@p_usr_id
   AND status='Active'
   AND record_status_id=@active_record_status_id;
 INSERT @allowed_organizations(organization_id)
 SELECT DISTINCT e.organization_id
 FROM grac_practice.organization_employee e
 WHERE e.status='Active'
   AND (e.email=@p_usr_id OR e.employee_code=@p_usr_id)
   AND NOT EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=e.organization_id);
 IF @organization_id IS NOT NULL
    AND @is_system_admin=0
    AND NOT EXISTS(SELECT 1 FROM @allowed_organizations WHERE organization_id=@organization_id)
   THROW 51052,'You do not have access to the selected organization.',1;
 IF @organization_id IS NULL
    AND @is_system_admin=0
    AND @p_entity_type='dashboard-summary'
   SELECT TOP (1) @organization_id=organization_id FROM @allowed_organizations ORDER BY organization_id;
 IF @organization_id IS NULL
    AND @is_system_admin=0
    AND @p_entity_type NOT IN ('lookups','audit-trace')
   SET @organization_id=-1;
 DECLARE @not_updated_applicability_status_id INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Not Updated');
 DECLARE @not_started_implementation_status_id INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code='Not Started');
 DECLARE @payload_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.status') OR status_name=JSON_VALUE(@p_payload,'$.status'));
 DECLARE @payload_record_status_id_from_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.statusId'),''));
 SET @payload_record_status_id=COALESCE(@payload_record_status_id_from_id,@payload_record_status_id);
 DECLARE @payload_subscription_status_id INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.subscriptionStatus') OR status_name=JSON_VALUE(@p_payload,'$.subscriptionStatus'));
 DECLARE @payload_applicability_status_id INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.applicabilityStatus') OR status_name=JSON_VALUE(@p_payload,'$.applicabilityStatus'));
 DECLARE @payload_implementation_status_id INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.implementationStatus') OR status_name=JSON_VALUE(@p_payload,'$.implementationStatus'));

 IF @p_entity_type IN ('organization-controls','control-applicability')
 BEGIN
   ;WITH active_subscriptions AS (
     SELECT s.subscription_id,s.organization_id,s.release_id,COALESCE(s.artifact_id,r.artifact_id) artifact_id
     FROM grac_practice.repository_subscription s
     JOIN grac_new.release r ON r.release_id=s.release_id
     WHERE s.record_status_id=@active_record_status_id
       AND s.subscription_status_id=@active_subscription_status_id
       AND s.release_id IS NOT NULL
       AND (@organization_id IS NULL OR s.organization_id=@organization_id)
   ),
   repository_controls AS (
     SELECT DISTINCT
       s.organization_id,
       s.subscription_id,
       scm.control_id,
       c.control_code,
       c.control_name,
       c.description,
       c.objective,
       c.control_domain_id,
       c.control_sub_domain_id,
       COALESCE(scm.release_id,n.release_id,s.release_id) release_id,
       COALESCE(scm.artifact_id,s.artifact_id) artifact_id
     FROM active_subscriptions s
     JOIN grac_new.source_control_map scm ON COALESCE(scm.release_id,s.release_id)=s.release_id OR scm.release_id IS NULL
     JOIN grac_new.source_structure_node n ON n.structure_node_id=scm.structure_node_id AND n.release_id=s.release_id
     JOIN grac_new.control c ON c.control_id=scm.control_id AND c.status='Active'
     WHERE scm.status='Active' AND n.status='Active'
   )
   UPDATE oc SET
     control_code=rc.control_code,
     control_name=rc.control_name,
     description=rc.description,
     objective=rc.objective,
     control_domain_id=rc.control_domain_id,
     control_sub_domain_id=rc.control_sub_domain_id,
     subscription_id=rc.subscription_id,
     artifact_id=rc.artifact_id,
     status='Active',
     record_status_id=@active_record_status_id,
     origin_type=CASE WHEN oc.origin_type='Hybrid' THEN 'Hybrid' ELSE 'Repository' END,
     is_manually_added=0,
     updated_by=COALESCE(NULLIF(@p_usr_id,''),'system'),
     updated_dt=SYSUTCDATETIME()
   FROM grac_practice.organization_control oc
   JOIN repository_controls rc ON rc.organization_id=oc.organization_id AND rc.control_id=oc.repository_control_id AND rc.release_id=oc.release_id;

   ;WITH active_subscriptions AS (
     SELECT s.subscription_id,s.organization_id,s.release_id,COALESCE(s.artifact_id,r.artifact_id) artifact_id
     FROM grac_practice.repository_subscription s
     JOIN grac_new.release r ON r.release_id=s.release_id
     WHERE s.record_status_id=@active_record_status_id
       AND s.subscription_status_id=@active_subscription_status_id
       AND s.release_id IS NOT NULL
       AND (@organization_id IS NULL OR s.organization_id=@organization_id)
   ),
   repository_controls AS (
     SELECT DISTINCT
       s.organization_id,
       s.subscription_id,
       scm.control_id,
       c.control_code,
       c.control_name,
       c.description,
       c.objective,
       c.control_domain_id,
       c.control_sub_domain_id,
       COALESCE(scm.release_id,n.release_id,s.release_id) release_id,
       COALESCE(scm.artifact_id,s.artifact_id) artifact_id
     FROM active_subscriptions s
     JOIN grac_new.source_control_map scm ON COALESCE(scm.release_id,s.release_id)=s.release_id OR scm.release_id IS NULL
     JOIN grac_new.source_structure_node n ON n.structure_node_id=scm.structure_node_id AND n.release_id=s.release_id
     JOIN grac_new.control c ON c.control_id=scm.control_id AND c.status='Active'
     WHERE scm.status='Active' AND n.status='Active'
   )
   INSERT grac_practice.organization_control(
     organization_id,origin_type,repository_control_id,control_code,control_name,description,objective,control_domain_id,control_sub_domain_id,
     is_manually_added,subscription_id,release_id,artifact_id,applicability_status,applicability_status_id,criticality,status,record_status_id,entered_by)
   SELECT rc.organization_id,'Repository',rc.control_id,rc.control_code,rc.control_name,rc.description,rc.objective,rc.control_domain_id,rc.control_sub_domain_id,
     0,rc.subscription_id,rc.release_id,rc.artifact_id,'Not Updated',@not_updated_applicability_status_id,'Medium','Active',@active_record_status_id,COALESCE(NULLIF(@p_usr_id,''),'system')
   FROM repository_controls rc
   WHERE NOT EXISTS(
     SELECT 1 FROM grac_practice.organization_control oc
     WHERE oc.organization_id=rc.organization_id AND oc.repository_control_id=rc.control_id AND oc.release_id=rc.release_id
   );
 END

 IF @p_entity_type='lookups'
 BEGIN
   SELECT 'organizations' LookupKey,CAST(o.organization_id AS NVARCHAR(40)) [Value],o.organization_code+' - '+o.organization_name Label,CAST(NULL AS BIGINT) OrganizationId
   FROM grac_practice.organization o
   WHERE o.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=o.organization_id))
   UNION ALL SELECT 'divisions',CAST(d.division_id AS NVARCHAR(40)),d.division_code+' - '+d.division_name,d.organization_id FROM grac_practice.organization_division d WHERE d.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=d.organization_id))
   UNION ALL SELECT 'location-types',CAST(location_type_id AS NVARCHAR(40)),location_type_name,CAST(NULL AS BIGINT) FROM grac_practice.location_type_master WHERE is_active=1
   UNION ALL SELECT 'locations',CAST(l.location_id AS NVARCHAR(40)),l.location_name,l.organization_id FROM grac_practice.organization_location l WHERE l.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=l.organization_id))
   UNION ALL SELECT 'business-functions',CAST(bf.business_function_id AS NVARCHAR(40)),bf.function_code+' - '+bf.function_name,bf.organization_id FROM grac_practice.organization_business_function bf WHERE bf.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=bf.organization_id))
   UNION ALL SELECT 'departments',CAST(d.department_id AS NVARCHAR(40)),d.department_code+' - '+d.department_name,d.organization_id FROM grac_practice.organization_department d WHERE d.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=d.organization_id))
   UNION ALL SELECT 'teams',CAST(t.team_id AS NVARCHAR(40)),t.team_name,t.organization_id FROM grac_practice.organization_team t WHERE t.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=t.organization_id))
   UNION ALL SELECT 'committees',CAST(c.committee_id AS NVARCHAR(40)),c.committee_name,c.organization_id FROM grac_practice.organization_committee c WHERE c.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=c.organization_id))
    UNION ALL SELECT 'employees',e.employee_name,e.employee_code+' - '+e.employee_name,e.organization_id FROM grac_practice.organization_employee e WHERE e.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=e.organization_id))
    UNION ALL SELECT 'employees-id',CAST(e.employee_id AS NVARCHAR(40)),e.employee_code+' - '+e.employee_name,e.organization_id FROM grac_practice.organization_employee e WHERE e.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=e.organization_id))
    UNION ALL SELECT 'users',e.employee_name,e.employee_code+' - '+e.employee_name,e.organization_id FROM grac_practice.organization_employee e WHERE e.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=e.organization_id))
    UNION ALL SELECT 'users-id',CAST(e.employee_id AS NVARCHAR(40)),e.employee_code+' - '+e.employee_name,e.organization_id FROM grac_practice.organization_employee e WHERE e.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=e.organization_id))
    UNION ALL SELECT 'users-detail',CAST(e.employee_id AS NVARCHAR(40)),e.employee_code+' - '+e.employee_name,e.organization_id FROM grac_practice.organization_employee e WHERE e.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=e.organization_id))
    UNION ALL SELECT 'roles',CAST(r.role_id AS NVARCHAR(40)),r.role_name,r.organization_id FROM grac_practice.organization_role r WHERE r.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=r.organization_id))
    UNION ALL SELECT 'menus',CAST(m.menu_id AS NVARCHAR(40)),m.menu_name,NULL FROM grac_practice.menu_master m WHERE m.status='Active'
   UNION ALL SELECT 'practices',CAST(p.practice_id AS NVARCHAR(40)),p.practice_code+' - '+p.practice_name,p.organization_id FROM grac_practice.practice p WHERE p.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=p.organization_id))
   UNION ALL SELECT 'practice-instances',CAST(pi.practice_instance_id AS NVARCHAR(40)),pi.instance_code+' - '+pi.instance_name,pi.organization_id FROM grac_practice.practice_instance pi WHERE pi.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=pi.organization_id))
   UNION ALL SELECT 'status-active',status_code,status_name,CAST(NULL AS BIGINT) FROM grac_practice.record_status_master WHERE is_active=1 AND status_code IN ('Active','Inactive')
   UNION ALL SELECT 'record-status',CAST(record_status_id AS NVARCHAR(40)),status_name,CAST(NULL AS BIGINT) FROM grac_practice.record_status_master WHERE is_active=1
   UNION ALL SELECT 'applicability-status',status_code,status_name,CAST(NULL AS BIGINT) FROM grac_practice.applicability_status_master WHERE is_active=1
   UNION ALL SELECT 'subscription-status',status_code,status_name,CAST(NULL AS BIGINT) FROM grac_practice.subscription_status_master WHERE is_active=1
   UNION ALL SELECT 'implementation-status',status_code,status_name,CAST(NULL AS BIGINT) FROM grac_practice.implementation_status_master WHERE is_active=1
   UNION ALL
   SELECT 'frequency-master',CAST(frequency_id AS NVARCHAR(40)),frequency_name,CAST(NULL AS BIGINT)
   FROM (
     SELECT frequency_id,frequency_name,ROW_NUMBER() OVER(
       PARTITION BY LOWER(LTRIM(RTRIM(COALESCE(NULLIF(frequency_code,N''),frequency_name))))
       ORDER BY display_order,frequency_id
     ) row_no
     FROM grac_practice.frequency_master
     WHERE is_active=1
   ) frequency_lookup
   WHERE row_no=1
   UNION ALL SELECT 'dependency-types',CAST(dependency_type_id AS NVARCHAR(40)),dependency_type_name,CAST(NULL AS BIGINT) FROM grac_practice.dependency_type_master WHERE is_active=1
   UNION ALL SELECT 'evidence-types',CAST(evidence_type_id AS NVARCHAR(40)),evidence_type_name,CAST(NULL AS BIGINT) FROM GRAC_New.evidence_type_master WHERE is_active=1
   UNION ALL SELECT 'collection-methods',CAST(collection_method_id AS NVARCHAR(40)),collection_method_name,CAST(NULL AS BIGINT) FROM grac_practice.collection_method_master WHERE is_active=1
   UNION ALL SELECT 'assurance-types',CAST(assurance_type_id AS NVARCHAR(40)),assurance_type_name,CAST(NULL AS BIGINT) FROM grac_practice.assurance_type_master WHERE is_active=1
   UNION ALL SELECT 'assurance-activity-status',status_code,status_name,CAST(NULL AS BIGINT) FROM grac_practice.assurance_activity_status_master WHERE is_active=1
   UNION ALL SELECT 'assurance-result-status',status_code,status_name,CAST(NULL AS BIGINT) FROM grac_practice.assurance_result_status_master WHERE is_active=1
   UNION ALL SELECT 'assurance-check-status',value,label,CAST(NULL AS BIGINT) FROM (VALUES(N'Pending',N'Pending'),(N'Pass',N'Pass'),(N'Fail',N'Fail'),(N'Unable To Verify',N'Unable To Verify')) v(value,label)
   UNION ALL SELECT 'assurance-effectiveness',value,label,CAST(NULL AS BIGINT) FROM (VALUES(N'Not Assessed',N'Not Assessed'),(N'Effective',N'Effective'),(N'Partially Effective',N'Partially Effective'),(N'Ineffective',N'Ineffective')) v(value,label)
   UNION ALL SELECT 'finding-status',value,label,CAST(NULL AS BIGINT) FROM (VALUES(N'Open',N'Open'),(N'In Progress',N'In Progress'),(N'Resolved',N'Resolved'),(N'Closed',N'Closed')) v(value,label)
   UNION ALL SELECT 'signal-status',value,label,CAST(NULL AS BIGINT) FROM (VALUES(N'Open',N'Open'),(N'Acknowledged',N'Acknowledged'),(N'Closed',N'Closed')) v(value,label)
   UNION ALL SELECT 'assurance-eligible-instances',CAST(pi.practice_instance_id AS NVARCHAR(40)),pi.instance_code+N' - '+pi.instance_name,pi.organization_id
   FROM grac_practice.practice_instance pi
   JOIN grac_practice.practice_operationalization po ON po.practice_instance_id=pi.practice_instance_id AND po.organization_id=pi.organization_id AND po.status=N'Resolved'
   WHERE pi.status=N'Active'
     AND NULLIF(pi.primary_owner,N'') IS NOT NULL
     AND (pi.department_id IS NOT NULL OR NULLIF(pi.department,N'') IS NOT NULL)
     AND EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status=N'Active' AND NULLIF(e.evidence_location,N'') IS NOT NULL AND NULLIF(e.evidence_locator,N'') IS NOT NULL)
     AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_dependency d WHERE d.practice_instance_id=pi.practice_instance_id AND d.status=N'Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_dependency_resolution r WHERE r.practice_instance_id=pi.practice_instance_id AND r.dependency_type_id=d.dependency_type_id AND r.is_active=1 AND r.resolution_status=N'Resolved'))
     AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=pi.organization_id))
   UNION ALL SELECT 'assurance-activities',CAST(aa.assurance_activity_id AS NVARCHAR(40)),aa.activity_number+N' - '+pi.instance_name,aa.organization_id
   FROM grac_practice.assurance_activity aa
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=aa.practice_instance_id
   WHERE (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=aa.organization_id))
   UNION ALL SELECT 'evidence-alignment-status',CAST(alignment_status_id AS NVARCHAR(40)),alignment_status_name,CAST(NULL AS BIGINT) FROM grac_practice.evidence_alignment_status_master WHERE is_active=1
   UNION ALL SELECT 'criticality-master',CAST(criticality_id AS NVARCHAR(40)),criticality_name,CAST(NULL AS BIGINT) FROM grac_practice.criticality_master WHERE is_active=1
   UNION ALL SELECT 'hosting-types',CAST(hosting_type_id AS NVARCHAR(40)),hosting_type_name,CAST(NULL AS BIGINT) FROM grac_practice.dependency_hosting_type_master WHERE is_active=1
   UNION ALL SELECT 'license-types',CAST(license_type_id AS NVARCHAR(40)),license_type_name,CAST(NULL AS BIGINT) FROM grac_practice.dependency_license_type_master WHERE is_active=1
   UNION ALL SELECT 'service-categories',CAST(service_category_id AS NVARCHAR(40)),service_category_name,CAST(NULL AS BIGINT) FROM grac_practice.dependency_service_category_master WHERE is_active=1
   UNION ALL SELECT 'asset-categories',CAST(asset_category_id AS NVARCHAR(40)),asset_category_name,CAST(NULL AS BIGINT) FROM grac_practice.dependency_asset_category_master WHERE is_active=1
   UNION ALL SELECT 'dependency-vendors',CAST(v.vendor_id AS NVARCHAR(40)),v.vendor_name,v.organization_id FROM grac_practice.organization_dependency_vendor v WHERE v.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=v.organization_id))
   UNION ALL SELECT option_group,option_value,option_label,CAST(NULL AS BIGINT) FROM grac_practice.reference_option WHERE status='Active'
   UNION ALL SELECT 'industries',option_value,option_label,CAST(NULL AS BIGINT) FROM grac_new.reference_option WHERE option_group='industries' AND status='Active'
   UNION ALL SELECT 'countries',option_value,option_label,CAST(NULL AS BIGINT) FROM grac_new.reference_option WHERE option_group='jurisdictions' AND status='Active';
 END
 ELSE IF @p_entity_type='organization-setup'
 BEGIN
   SELECT organization_id Id,organization_code Code,organization_name Name,industry Industry,entity_type EntityType,country Country,status Status
   FROM grac_practice.organization
   WHERE organization_id=@organization_id;

   SELECT d.metadata_key MetadataKey,d.metadata_name MetadataName,d.data_type DataType,d.lookup_group LookupGroup,
     v.value_text ValueText,v.value_number ValueNumber,v.value_date ValueDate,v.value_bool ValueBool,v.value_json ValueJson
   FROM grac_practice.organization_metadata_definition d
   LEFT JOIN grac_practice.organization_metadata_value v ON v.metadata_definition_id=d.metadata_definition_id AND v.organization_id=@organization_id AND v.status='Active'
   WHERE d.status='Active'
   ORDER BY d.metadata_definition_id;

   SELECT au.authority_id AuthorityId,au.authority_code AuthorityCode,au.authority_name AuthorityName,
     a.artifact_id ArtifactId,a.artifact_code ArtifactCode,a.artifact_name ArtifactName,
     r.release_id ReleaseId,r.version_no ReleaseVersion,r.status ReleaseStatus,
     CASE WHEN s.subscription_id IS NOT NULL AND s.status='Active' AND s.subscription_status='Active' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END IsSubscribed
   FROM grac_new.authority au
   JOIN grac_new.artifact a ON a.authority_id=au.authority_id AND a.status='Active'
   JOIN grac_new.release r ON r.artifact_id=a.artifact_id AND r.status IN ('Draft','Active')
   LEFT JOIN grac_practice.repository_subscription s ON s.organization_id=@organization_id AND s.release_id=r.release_id AND s.status='Active'
   WHERE au.status='Active'
   ORDER BY au.authority_code,a.artifact_code,r.version_no;
 END
 ELSE IF @p_entity_type='dashboard-summary'
 BEGIN
   IF @organization_id IS NULL AND @is_system_admin=1
     SELECT TOP (1) @organization_id=organization_id FROM grac_practice.organization WHERE status='Active' ORDER BY organization_id;

   SELECT
    (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id AND status='Active') TotalOrganizationControls,
    (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id AND status='Active' AND applicability_status IN ('Not Updated','Pending','')) NotUpdatedControls,
    (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id AND status='Active' AND applicability_status='Applicable') ApplicableControls,
    (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id AND status='Active' AND applicability_status='Not Applicable') NotApplicableControls,
    (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id AND status='Active' AND applicability_status='Deferred') DeferredControls,
    (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id AND status='Active' AND applicability_status='Accepted Risk') AcceptedRiskControls,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice WHERE organization_id=@organization_id AND status='Active') TotalPractices,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice WHERE organization_id=@organization_id AND status='Active' AND applicability_status='Applicable') ApplicablePractices,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice WHERE organization_id=@organization_id AND status='Active' AND applicability_status IN ('Not Updated','Pending','')) NotUpdatedPractices,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice WHERE organization_id=@organization_id AND status='Active' AND applicability_status='Not Applicable') NotApplicablePractices,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance WHERE organization_id=@organization_id AND status='Active') TotalPracticeInstances,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance WHERE organization_id=@organization_id AND status='Active') ActivePracticeInstances,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance WHERE organization_id=@organization_id AND status='Active' AND criticality='Critical') CriticalPracticeInstances,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance WHERE organization_id=@organization_id AND status='Active' AND (primary_owner_id IS NULL AND NULLIF(LTRIM(RTRIM(primary_owner)),'') IS NULL)) InstancesWithoutOwner,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance pi WHERE pi.organization_id=@organization_id AND pi.status='Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_dependency d WHERE d.practice_instance_id=pi.practice_instance_id AND d.status='Active')) InstancesWithoutDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance pi WHERE pi.organization_id=@organization_id AND pi.status='Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status='Active')) InstancesWithoutEvidenceConfiguration,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id WHERE d.organization_id=@organization_id AND d.status='Active' AND (UPPER(dt.dependency_type_code)='TOOL' OR UPPER(dt.dependency_type_name)='TOOL' OR UPPER(d.dependency_type)='TOOL')) ToolDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id WHERE d.organization_id=@organization_id AND d.status='Active' AND (UPPER(dt.dependency_type_code)='VENDOR' OR UPPER(dt.dependency_type_name)='VENDOR' OR UPPER(d.dependency_type)='VENDOR')) VendorDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id WHERE d.organization_id=@organization_id AND d.status='Active' AND (UPPER(dt.dependency_type_code)='APPLICATION' OR UPPER(dt.dependency_type_name)='APPLICATION' OR UPPER(d.dependency_type)='APPLICATION')) ApplicationDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id WHERE d.organization_id=@organization_id AND d.status='Active' AND (UPPER(dt.dependency_type_code)='ASSET' OR UPPER(dt.dependency_type_name)='ASSET' OR UPPER(d.dependency_type)='ASSET')) AssetDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id WHERE d.organization_id=@organization_id AND d.status='Active' AND (UPPER(dt.dependency_type_code) IN ('PERSON','PEOPLE','USER') OR UPPER(dt.dependency_type_name) IN ('PERSON','PEOPLE','USER') OR UPPER(d.dependency_type) IN ('PERSON','PEOPLE','USER'))) PersonDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance pi WHERE pi.organization_id=@organization_id AND pi.status='Active' AND (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d WHERE d.practice_instance_id=pi.practice_instance_id AND d.status='Active')=1) SinglePointDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_evidence e WHERE e.organization_id=@organization_id AND e.status='Active') EvidenceConfiguredCount,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance pi WHERE pi.organization_id=@organization_id AND pi.status='Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status='Active')) EvidenceNotConfiguredCount,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_evidence e JOIN grac_practice.evidence_alignment_status_master s ON s.alignment_status_id=e.alignment_status_id WHERE e.organization_id=@organization_id AND e.status='Active' AND s.alignment_status_code='Aligned') AlignedEvidence,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_evidence e JOIN grac_practice.evidence_alignment_status_master s ON s.alignment_status_id=e.alignment_status_id WHERE e.organization_id=@organization_id AND e.status='Active' AND s.alignment_status_code='Enhanced') EnhancedEvidence,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_evidence e JOIN grac_practice.evidence_alignment_status_master s ON s.alignment_status_id=e.alignment_status_id WHERE e.organization_id=@organization_id AND e.status='Active' AND s.alignment_status_code='Not Aligned') NotAlignedEvidence,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_dependency_resolution r WHERE r.organization_id=@organization_id AND r.is_active=1 AND r.resolution_status='Pending') PendingResolveItems,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_dependency_resolution r WHERE r.organization_id=@organization_id AND r.is_active=1 AND r.resolution_status='Resolved') ResolvedItems,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_dependency_resolution r WHERE r.organization_id=@organization_id AND r.is_active=1 AND r.resolution_status IN ('Partially Resolved','Partial')) PartiallyResolvedItems,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d WHERE d.organization_id=@organization_id AND d.status='Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_dependency_resolution r WHERE r.organization_id=d.organization_id AND r.practice_instance_id=d.practice_instance_id AND r.dependency_type_id=d.dependency_type_id AND r.is_active=1 AND r.resolution_status='Resolved')) OpenDependencyMappingItems;

   SELECT N'Controls still Not Updated' Title,
          COUNT_BIG(1) ItemCount,
          N'High' Severity,
          N'Organization controls need applicability decisions.' Detail,
          N'Practice/Index/organization-controls' Route
   FROM grac_practice.organization_control
   WHERE organization_id=@organization_id AND status='Active' AND applicability_status IN ('Not Updated','Pending','')
   UNION ALL
   SELECT N'Practices still Not Updated',COUNT_BIG(1),N'High',N'Practices need applicability decisions.',N'Practice/Index/organization-requirements'
   FROM grac_practice.practice
   WHERE organization_id=@organization_id AND status='Active' AND applicability_status IN ('Not Updated','Pending','')
   UNION ALL
   SELECT N'Applicable practices without instances',COUNT_BIG(1),N'High',N'Applicable practices require at least one practice instance.',N'Practice/Index/practice-instances'
   FROM grac_practice.practice p
   WHERE p.organization_id=@organization_id AND p.status='Active' AND p.applicability_status='Applicable'
     AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance pi WHERE pi.practice_id=p.practice_id AND pi.status='Active')
   UNION ALL
   SELECT N'Critical instances without evidence',COUNT_BIG(1),N'High',N'Critical practice instances need evidence configuration.',N'Practice/Index/evidence-configurations'
   FROM grac_practice.practice_instance pi
   WHERE pi.organization_id=@organization_id AND pi.status='Active' AND pi.criticality='Critical'
     AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status='Active')
   UNION ALL
   SELECT N'Instances with expired dependency',COUNT_BIG(DISTINCT pi.practice_instance_id),N'Medium',N'License, support, or vendor dates have expired.',N'Practice/Index/resolve'
   FROM grac_practice.practice_instance pi
   WHERE pi.organization_id=@organization_id AND pi.status='Active'
     AND EXISTS(
       SELECT 1
       FROM grac_practice.practice_dependency_resolution r
       LEFT JOIN grac_practice.organization_dependency_tool t ON t.tool_id=r.resolved_dependency_id AND r.dependency_category IN ('Tool','Tools')
       LEFT JOIN grac_practice.organization_dependency_application a ON a.application_id=r.resolved_dependency_id AND r.dependency_category IN ('Application','Applications')
       LEFT JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id=r.resolved_dependency_id AND r.dependency_category IN ('Vendor','Vendors')
       WHERE r.practice_instance_id=pi.practice_instance_id
         AND r.organization_id=@organization_id
         AND r.is_active=1
         AND (
           t.license_expiry_dt<CONVERT(DATE,SYSUTCDATETIME())
           OR t.support_expiry_dt<CONVERT(DATE,SYSUTCDATETIME())
           OR a.support_expiry_dt<CONVERT(DATE,SYSUTCDATETIME())
           OR a.end_of_life_dt<CONVERT(DATE,SYSUTCDATETIME())
           OR v.contract_end_dt<CONVERT(DATE,SYSUTCDATETIME())
         )
     )
   UNION ALL
   SELECT N'Evidence not aligned with obligations',COUNT_BIG(1),N'Medium',N'Evidence alignment is missing or marked Not Aligned.',N'Practice/Index/evidence-configurations'
   FROM grac_practice.practice_instance pi
   WHERE pi.organization_id=@organization_id AND pi.status='Active'
     AND (
       EXISTS(
         SELECT 1
         FROM grac_practice.practice_instance_evidence e
         JOIN grac_practice.evidence_alignment_status_master s ON s.alignment_status_id=e.alignment_status_id
         WHERE e.practice_instance_id=pi.practice_instance_id AND e.status='Active' AND s.alignment_status_code='Not Aligned'
       )
       OR NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status='Active')
     )
   ORDER BY ItemCount DESC, Severity;
 END
 ELSE IF @p_entity_type='applicability-recommendations'
 BEGIN
   DECLARE @industry NVARCHAR(160)=NULLIF(JSON_VALUE(@p_payload,'$.organization.industry'),'');
   DECLARE @entity_type NVARCHAR(160)=NULLIF(JSON_VALUE(@p_payload,'$.organization.entityType'),'');
   DECLARE @country NVARCHAR(160)=NULLIF(JSON_VALUE(@p_payload,'$.organization.country'),'');
   DECLARE @deposit_status NVARCHAR(80)=NULLIF(JSON_VALUE(@p_payload,'$.attributes.deposit_taking_status'),'');
   DECLARE @scale_class NVARCHAR(120)=NULLIF(JSON_VALUE(@p_payload,'$.attributes.asset_size_scale'),'');
   DECLARE @registration_type NVARCHAR(160)=NULLIF(JSON_VALUE(@p_payload,'$.attributes.regulatory_registration_type'),'');
   DECLARE @payment_aggregator NVARCHAR(80)=NULLIF(JSON_VALUE(@p_payload,'$.attributes.payment_aggregator_status'),'');
   DECLARE @investment_advisor NVARCHAR(80)=NULLIF(JSON_VALUE(@p_payload,'$.attributes.investment_advisor_status'),'');
   DECLARE @cloud_adoption NVARCHAR(80)=NULLIF(JSON_VALUE(@p_payload,'$.attributes.cloud_adoption'),'');
   DECLARE @stores_cardholder_data NVARCHAR(20)=LOWER(COALESCE(JSON_VALUE(@p_payload,'$.attributes.stores_cardholder_data'),'false'));

   DECLARE @values TABLE(attribute_key NVARCHAR(120), attribute_value NVARCHAR(200));
   INSERT @values(attribute_key,attribute_value)
   SELECT 'industry',@industry WHERE @industry IS NOT NULL
   UNION ALL SELECT 'entity_type',@entity_type WHERE @entity_type IS NOT NULL
   UNION ALL SELECT 'country',@country WHERE @country IS NOT NULL
   UNION ALL SELECT 'deposit_taking_status',@deposit_status WHERE @deposit_status IS NOT NULL
   UNION ALL SELECT 'asset_size_scale',@scale_class WHERE @scale_class IS NOT NULL
   UNION ALL SELECT 'regulatory_registration_type',@registration_type WHERE @registration_type IS NOT NULL
   UNION ALL SELECT 'payment_aggregator_status',@payment_aggregator WHERE @payment_aggregator IS NOT NULL
   UNION ALL SELECT 'investment_advisor_status',@investment_advisor WHERE @investment_advisor IS NOT NULL
   UNION ALL SELECT 'cloud_adoption',@cloud_adoption WHERE @cloud_adoption IS NOT NULL
   UNION ALL SELECT 'stores_cardholder_data',@stores_cardholder_data WHERE @stores_cardholder_data IN ('true','1','yes');

   INSERT @values(attribute_key,attribute_value)
   SELECT 'geographic_presence',TRY_CONVERT(NVARCHAR(200),[value]) FROM OPENJSON(@p_payload,'$.attributes.geographic_presence')
   WHERE NULLIF(TRY_CONVERT(NVARCHAR(200),[value]),'') IS NOT NULL;
   INSERT @values(attribute_key,attribute_value)
   SELECT 'business_operations',TRY_CONVERT(NVARCHAR(200),[value]) FROM OPENJSON(@p_payload,'$.attributes.business_functions')
   WHERE NULLIF(TRY_CONVERT(NVARCHAR(200),[value]),'') IS NOT NULL;
   INSERT @values(attribute_key,attribute_value)
   SELECT 'technology_landscape',TRY_CONVERT(NVARCHAR(200),[value]) FROM OPENJSON(@p_payload,'$.attributes.technology_landscape')
   WHERE NULLIF(TRY_CONVERT(NVARCHAR(200),[value]),'') IS NOT NULL;

   ;WITH candidates AS (
     SELECT au.authority_id,au.authority_code,au.authority_name,a.artifact_id,a.artifact_code,a.artifact_name,r.release_id,r.version_no,
       CAST(0 AS INT) BaseScore,CAST(N'' AS NVARCHAR(MAX)) BaseReason
     FROM grac_new.authority au
     JOIN grac_new.artifact a ON a.authority_id=au.authority_id AND a.status='Active'
     JOIN grac_new.release r ON r.artifact_id=a.artifact_id AND r.status IN ('Draft','Active')
     WHERE au.status='Active'
   ),
   metadata_score AS (
     SELECT c.release_id,
       SUM(score) Score,
       STRING_AGG(reason,'; ') Reason
     FROM candidates c
     CROSS APPLY (
       SELECT 35 score,CONCAT(N'Industry match: ',@industry) reason
       WHERE @industry IS NOT NULL AND EXISTS(
         SELECT 1 FROM grac_new.artifact_industry_map m JOIN grac_new.reference_option o ON o.reference_option_id=m.reference_option_id
         WHERE m.artifact_id=c.artifact_id AND m.status='Active' AND o.option_group='industries' AND o.status='Active'
           AND (o.option_value=@industry OR o.option_value IN ('All Industries','Banking and Financial Services'))
       )
       UNION ALL
       SELECT 35,CONCAT(N'Jurisdiction match: ',COALESCE(@country,(SELECT TOP 1 attribute_value FROM @values WHERE attribute_key='geographic_presence')))
       WHERE EXISTS(
         SELECT 1 FROM grac_new.artifact_jurisdiction_map m JOIN grac_new.reference_option o ON o.reference_option_id=m.reference_option_id
         WHERE m.artifact_id=c.artifact_id AND m.status='Active' AND o.option_group='jurisdictions' AND o.status='Active'
           AND (o.option_value=@country OR o.option_value IN (SELECT attribute_value FROM @values WHERE attribute_key='geographic_presence') OR o.option_value IN ('Global','International'))
       )
       UNION ALL
       SELECT 20,CONCAT(N'Applicability rule matched: ',ar.rule_name)
       FROM grac_new.applicability_rule ar
       WHERE ar.status='Active' AND ar.outcome='Applicable' AND (ar.release_id=c.release_id OR ar.artifact_id=c.artifact_id)
         AND EXISTS(
           SELECT 1 FROM @values v
           WHERE ar.rule_expression_json LIKE '%'+v.attribute_key+'%' AND ar.rule_expression_json LIKE '%'+v.attribute_value+'%'
         )
       UNION ALL
       SELECT 20,N'Payment/card data driver matched'
       WHERE @stores_cardholder_data IN ('true','1','yes') AND (c.artifact_code LIKE '%PCI%' OR c.artifact_name LIKE '%PCI%' OR c.artifact_name LIKE '%Card%')
       UNION ALL
       SELECT 15,N'Cloud adoption driver matched'
       WHERE @cloud_adoption IS NOT NULL AND (c.artifact_name LIKE '%Cloud%' OR c.artifact_name LIKE '%Cyber%' OR c.artifact_name LIKE '%IT%')
     ) s
     GROUP BY c.release_id
   )
   SELECT c.authority_id AuthorityId,c.authority_code AuthorityCode,c.authority_name AuthorityName,
     c.artifact_id ArtifactId,c.artifact_code ArtifactCode,c.artifact_name ArtifactName,
     c.release_id ReleaseId,c.version_no ReleaseVersion,
     COALESCE(ms.Reason,N'Review recommended based on organization profile and repository metadata.') RecommendationReason,
     CASE WHEN COALESCE(ms.Score,0)>=70 THEN N'High' WHEN COALESCE(ms.Score,0)>=35 THEN N'Medium' ELSE N'Low' END ConfidenceLevel,
     CAST(CASE WHEN COALESCE(ms.Score,0)>=35 THEN 1 ELSE 0 END AS BIT) IsRecommended
   FROM candidates c
   JOIN metadata_score ms ON ms.release_id=c.release_id
   WHERE COALESCE(ms.Score,0)>=35
   ORDER BY ms.Score DESC,c.authority_code,c.artifact_code,c.version_no;
 END
 ELSE IF @p_entity_type='organizations'
   SELECT organization_id Id,organization_code Code,organization_name Name,industry Industry,entity_type EntityType,country Country,rs.status_name Status
   FROM grac_practice.organization o
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=o.record_status_id
   WHERE (@p_id=0 OR o.organization_id=@p_id) AND (@p_status='' OR o.record_status_id=@filter_record_status_id)
     AND (@date_from IS NULL OR o.entered_dt>=@date_from) AND (@date_to IS NULL OR o.entered_dt<DATEADD(DAY,1,@date_to))
     AND (@p_search='' OR organization_code LIKE '%'+@p_search+'%' OR organization_name LIKE '%'+@p_search+'%')
   ORDER BY organization_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='divisions'
   SELECT d.division_id Id,d.organization_id OrganizationId,d.division_code Code,d.division_name Name,
     d.head_employee_id HeadUserId,COALESCE(e.employee_name,'') HeadUser,d.description Description,rs.status_name Status
   FROM grac_practice.organization_division d
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=d.record_status_id
   LEFT JOIN grac_practice.organization_employee e ON e.employee_id=d.head_employee_id
   WHERE (@p_id=0 OR d.division_id=@p_id) AND (@organization_id IS NULL OR d.organization_id=@organization_id)
     AND (@p_status='' OR d.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR d.division_code LIKE '%'+@p_search+'%' OR d.division_name LIKE '%'+@p_search+'%' OR ISNULL(e.employee_name,'') LIKE '%'+@p_search+'%')
   ORDER BY d.division_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='locations'
   SELECT l.location_id Id,l.organization_id OrganizationId,l.location_name Name,
     l.location_type_id LocationTypeId,lt.location_type_name LocationType,
     l.location_head_id LocationHeadId,COALESCE(e.employee_name,'') LocationHead,
     l.region Region,l.remarks Remarks,l.record_status_id StatusId,rs.status_name Status
   FROM grac_practice.organization_location l
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=l.record_status_id
   JOIN grac_practice.location_type_master lt ON lt.location_type_id=l.location_type_id
   LEFT JOIN grac_practice.organization_employee e ON e.employee_id=l.location_head_id
   WHERE (@p_id=0 OR l.location_id=@p_id) AND (@organization_id IS NULL OR l.organization_id=@organization_id)
     AND (@p_status='' OR l.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR l.location_name LIKE '%'+@p_search+'%' OR lt.location_type_name LIKE '%'+@p_search+'%' OR ISNULL(e.employee_name,'') LIKE '%'+@p_search+'%' OR ISNULL(l.region,'') LIKE '%'+@p_search+'%')
   ORDER BY l.location_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='departments'
   SELECT d.department_id Id,d.organization_id OrganizationId,d.department_code Code,d.department_name Name,
     d.head_employee_id HeadUserId,COALESCE(e.employee_name,'') HeadUser,d.description Description,rs.status_name Status
   FROM grac_practice.organization_department d
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=d.record_status_id
   LEFT JOIN grac_practice.organization_employee e ON e.employee_id=d.head_employee_id
   WHERE (@p_id=0 OR d.department_id=@p_id) AND (@organization_id IS NULL OR d.organization_id=@organization_id)
     AND (@p_status='' OR d.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR d.department_code LIKE '%'+@p_search+'%' OR d.department_name LIKE '%'+@p_search+'%' OR ISNULL(e.employee_name,'') LIKE '%'+@p_search+'%')
   ORDER BY d.department_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='teams'
   SELECT t.team_id Id,t.organization_id OrganizationId,t.team_name Name,
     t.team_manager_id TeamManagerId,COALESCE(m.employee_name,'') TeamManager,
     t.parent_department_id ParentDepartmentId,COALESCE(d.department_name,'') ParentDepartment,
     t.remarks Remarks,t.record_status_id StatusId,rs.status_name Status
   FROM grac_practice.organization_team t
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=t.record_status_id
   LEFT JOIN grac_practice.organization_employee m ON m.employee_id=t.team_manager_id
   LEFT JOIN grac_practice.organization_department d ON d.department_id=t.parent_department_id
   WHERE (@p_id=0 OR t.team_id=@p_id) AND (@organization_id IS NULL OR t.organization_id=@organization_id)
     AND (@p_status='' OR t.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR t.team_name LIKE '%'+@p_search+'%' OR ISNULL(m.employee_name,'') LIKE '%'+@p_search+'%' OR ISNULL(d.department_name,'') LIKE '%'+@p_search+'%')
   ORDER BY t.team_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='committees'
   SELECT c.committee_id Id,c.organization_id OrganizationId,c.committee_name Name,
     c.chairperson_id ChairpersonId,COALESCE(ch.employee_name,'') Chairperson,
     c.secretary_id SecretaryId,COALESCE(sec.employee_name,'') Secretary,
     c.review_frequency_id ReviewFrequencyId,COALESCE(f.frequency_name,'') ReviewFrequency,
     c.remarks Remarks,c.record_status_id StatusId,rs.status_name Status
   FROM grac_practice.organization_committee c
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=c.record_status_id
   LEFT JOIN grac_practice.organization_employee ch ON ch.employee_id=c.chairperson_id
   LEFT JOIN grac_practice.organization_employee sec ON sec.employee_id=c.secretary_id
   LEFT JOIN grac_practice.frequency_master f ON f.frequency_id=c.review_frequency_id
   WHERE (@p_id=0 OR c.committee_id=@p_id) AND (@organization_id IS NULL OR c.organization_id=@organization_id)
     AND (@p_status='' OR c.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR c.committee_name LIKE '%'+@p_search+'%' OR ISNULL(ch.employee_name,'') LIKE '%'+@p_search+'%' OR ISNULL(sec.employee_name,'') LIKE '%'+@p_search+'%' OR ISNULL(f.frequency_name,'') LIKE '%'+@p_search+'%')
   ORDER BY c.committee_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='business-functions'
   SELECT business_function_id Id,organization_id OrganizationId,function_code Code,function_name Name,owner_name OwnerName,criticality Criticality,status Status
   FROM grac_practice.organization_business_function
   WHERE (@p_id=0 OR business_function_id=@p_id) AND (@organization_id IS NULL OR organization_id=@organization_id)
     AND (@p_status='' OR status=@p_status)
     AND (@p_search='' OR function_code LIKE '%'+@p_search+'%' OR function_name LIKE '%'+@p_search+'%' OR ISNULL(owner_name,'') LIKE '%'+@p_search+'%')
   ORDER BY function_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='users'
   SELECT e.employee_id Id,e.organization_id OrganizationId,e.employee_code EmployeeCode,e.employee_name EmployeeName,
     e.email Email,e.designation Designation,e.location_id LocationId,loc.location_name Location,
     e.department Department,e.department_id DepartmentId,d.department_name DepartmentName,
     e.business_function_id BusinessFunctionId,bf.function_name BusinessFunction,
     e.reporting_officer_id ReportingOfficerId,COALESCE(ro.employee_name,'') ReportingOfficer,
     e.role_id RoleId,COALESCE(role.role_name,'') RoleName,rs.status_name Status
   FROM grac_practice.organization_employee e
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=e.record_status_id
   LEFT JOIN grac_practice.organization_location loc ON loc.location_id=e.location_id
   LEFT JOIN grac_practice.organization_department d ON d.department_id=e.department_id
   LEFT JOIN grac_practice.organization_business_function bf ON bf.business_function_id=e.business_function_id
   LEFT JOIN grac_practice.organization_employee ro ON ro.employee_id=e.reporting_officer_id
   LEFT JOIN grac_practice.organization_role role ON role.role_id=e.role_id
   WHERE (@p_id=0 OR e.employee_id=@p_id) AND (@organization_id IS NULL OR e.organization_id=@organization_id)
     AND (@p_status='' OR e.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR e.employee_code LIKE '%'+@p_search+'%' OR e.employee_name LIKE '%'+@p_search+'%' OR ISNULL(e.email,'') LIKE '%'+@p_search+'%')
   ORDER BY e.employee_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='roles'
   SELECT r.role_id Id,r.organization_id OrganizationId,o.organization_name Organization,
     r.role_name RoleName,r.description Description,r.record_status_id StatusId,rs.status_name Status
   FROM grac_practice.organization_role r
   JOIN grac_practice.organization o ON o.organization_id=r.organization_id
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=r.record_status_id
   WHERE (@p_id=0 OR r.role_id=@p_id) AND (@organization_id IS NULL OR r.organization_id=@organization_id)
     AND (@p_status='' OR r.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR r.role_name LIKE '%'+@p_search+'%' OR ISNULL(r.description,'') LIKE '%'+@p_search+'%')
   ORDER BY r.role_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='role-menu-permissions'
   SELECT p.role_menu_permission_id Id,r.organization_id OrganizationId,o.organization_name Organization,
     p.role_id RoleId,r.role_name RoleName,p.menu_id MenuId,m.menu_name MenuName,m.menu_key MenuKey,
     p.can_view CanView,p.can_add CanAdd,p.can_edit CanEdit,p.can_delete CanDelete,p.can_approve CanApprove,
     p.record_status_id StatusId,rs.status_name Status
   FROM grac_practice.organization_role_menu_permission p
   JOIN grac_practice.organization_role r ON r.role_id=p.role_id
   JOIN grac_practice.organization o ON o.organization_id=r.organization_id
   JOIN grac_practice.menu_master m ON m.menu_id=p.menu_id
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=p.record_status_id
   WHERE (@p_id=0 OR p.role_menu_permission_id=@p_id) AND (@organization_id IS NULL OR r.organization_id=@organization_id)
     AND (@p_status='' OR p.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR r.role_name LIKE '%'+@p_search+'%' OR m.menu_name LIKE '%'+@p_search+'%')
   ORDER BY r.role_name,m.display_order,m.menu_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='dependency-vendors'
   SELECT v.vendor_id Id,v.organization_id OrganizationId,v.vendor_name Name,
     v.service_category_id ServiceCategoryId,sc.service_category_name ServiceCategory,
     v.relationship_owner_id RelationshipOwnerId,COALESCE(ro.employee_name,'') RelationshipOwner,
     v.contract_start_dt ContractStartDate,v.contract_end_dt ContractEndDate,v.renewal_dt RenewalDate,
     v.sla_applicable SlaApplicable,v.criticality_id CriticalityId,COALESCE(cm.criticality_name,'') Criticality,
     v.remarks Remarks,v.record_status_id StatusId,rs.status_name Status
   FROM grac_practice.organization_dependency_vendor v
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=v.record_status_id
   JOIN grac_practice.dependency_service_category_master sc ON sc.service_category_id=v.service_category_id
   LEFT JOIN grac_practice.organization_employee ro ON ro.employee_id=v.relationship_owner_id
   LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id=v.criticality_id
   WHERE (@p_id=0 OR v.vendor_id=@p_id) AND (@organization_id IS NULL OR v.organization_id=@organization_id)
     AND (@p_status='' OR v.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR v.vendor_name LIKE '%'+@p_search+'%' OR sc.service_category_name LIKE '%'+@p_search+'%' OR ISNULL(ro.employee_name,'') LIKE '%'+@p_search+'%')
   ORDER BY v.vendor_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='dependency-applications'
   SELECT a.application_id Id,a.organization_id OrganizationId,a.application_name Name,a.description Description,
     a.business_owner_id BusinessOwnerId,COALESCE(bo.employee_name,'') BusinessOwner,
     a.technical_owner_id TechnicalOwnerId,COALESCE(te.employee_name,'') TechnicalOwner,
     a.vendor_id VendorId,COALESCE(v.vendor_name,'') Vendor,a.version_no Version,
     a.hosting_type_id HostingTypeId,COALESCE(ht.hosting_type_name,'') HostingType,
     a.support_expiry_dt SupportExpiryDate,a.end_of_life_dt EndOfLifeDate,
     a.criticality_id CriticalityId,COALESCE(cm.criticality_name,'') Criticality,
     a.remarks Remarks,a.record_status_id StatusId,rs.status_name Status
   FROM grac_practice.organization_dependency_application a
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=a.record_status_id
   LEFT JOIN grac_practice.organization_employee bo ON bo.employee_id=a.business_owner_id
   LEFT JOIN grac_practice.organization_employee te ON te.employee_id=a.technical_owner_id
   LEFT JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id=a.vendor_id
   LEFT JOIN grac_practice.dependency_hosting_type_master ht ON ht.hosting_type_id=a.hosting_type_id
   LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id=a.criticality_id
   WHERE (@p_id=0 OR a.application_id=@p_id) AND (@organization_id IS NULL OR a.organization_id=@organization_id)
     AND (@p_status='' OR a.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR a.application_name LIKE '%'+@p_search+'%' OR ISNULL(v.vendor_name,'') LIKE '%'+@p_search+'%' OR ISNULL(bo.employee_name,'') LIKE '%'+@p_search+'%' OR ISNULL(te.employee_name,'') LIKE '%'+@p_search+'%')
   ORDER BY a.application_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='dependency-tools'
   SELECT t.tool_id Id,t.organization_id OrganizationId,t.tool_name Name,t.description Description,
     t.business_owner_id BusinessOwnerId,COALESCE(bo.employee_name,'') BusinessOwner,
     t.vendor_id VendorId,COALESCE(v.vendor_name,'') Vendor,
     t.license_type_id LicenseTypeId,COALESCE(lt.license_type_name,'') LicenseType,
     t.license_expiry_dt LicenseExpiryDate,t.support_expiry_dt SupportExpiryDate,
     t.criticality_id CriticalityId,COALESCE(cm.criticality_name,'') Criticality,
     t.remarks Remarks,t.record_status_id StatusId,rs.status_name Status
   FROM grac_practice.organization_dependency_tool t
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=t.record_status_id
   LEFT JOIN grac_practice.organization_employee bo ON bo.employee_id=t.business_owner_id
   LEFT JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id=t.vendor_id
   LEFT JOIN grac_practice.dependency_license_type_master lt ON lt.license_type_id=t.license_type_id
   LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id=t.criticality_id
   WHERE (@p_id=0 OR t.tool_id=@p_id) AND (@organization_id IS NULL OR t.organization_id=@organization_id)
     AND (@p_status='' OR t.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR t.tool_name LIKE '%'+@p_search+'%' OR ISNULL(v.vendor_name,'') LIKE '%'+@p_search+'%' OR ISNULL(bo.employee_name,'') LIKE '%'+@p_search+'%')
   ORDER BY t.tool_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='dependency-assets'
   SELECT a.asset_id Id,a.organization_id OrganizationId,a.asset_name Name,
     a.asset_category_id AssetCategoryId,ac.asset_category_name AssetCategory,
     a.owner_id OwnerId,COALESCE(o.employee_name,'') Owner,
     a.location_id LocationId,COALESCE(l.location_name,'') Location,
     a.purchase_dt PurchaseDate,a.warranty_expiry_dt WarrantyExpiryDate,a.amc_expiry_dt AmcExpiryDate,
     a.criticality_id CriticalityId,COALESCE(cm.criticality_name,'') Criticality,
     a.remarks Remarks,a.record_status_id StatusId,rs.status_name Status
   FROM grac_practice.organization_dependency_asset a
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=a.record_status_id
   JOIN grac_practice.dependency_asset_category_master ac ON ac.asset_category_id=a.asset_category_id
   LEFT JOIN grac_practice.organization_employee o ON o.employee_id=a.owner_id
   LEFT JOIN grac_practice.organization_location l ON l.location_id=a.location_id
   LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id=a.criticality_id
   WHERE (@p_id=0 OR a.asset_id=@p_id) AND (@organization_id IS NULL OR a.organization_id=@organization_id)
     AND (@p_status='' OR a.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR a.asset_name LIKE '%'+@p_search+'%' OR ac.asset_category_name LIKE '%'+@p_search+'%' OR ISNULL(o.employee_name,'') LIKE '%'+@p_search+'%' OR ISNULL(l.location_name,'') LIKE '%'+@p_search+'%')
   ORDER BY a.asset_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='dependency-processes'
   SELECT p.process_id Id,p.organization_id OrganizationId,p.process_name Name,
     p.process_owner_id ProcessOwnerId,COALESCE(o.employee_name,'') ProcessOwner,
     p.version_no Version,p.effective_dt EffectiveDate,p.last_review_dt LastReviewDate,p.next_review_dt NextReviewDate,
     p.remarks Remarks,p.record_status_id StatusId,rs.status_name Status
   FROM grac_practice.organization_dependency_process p
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=p.record_status_id
   LEFT JOIN grac_practice.organization_employee o ON o.employee_id=p.process_owner_id
   WHERE (@p_id=0 OR p.process_id=@p_id) AND (@organization_id IS NULL OR p.organization_id=@organization_id)
     AND (@p_status='' OR p.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR p.process_name LIKE '%'+@p_search+'%' OR ISNULL(o.employee_name,'') LIKE '%'+@p_search+'%')
   ORDER BY p.process_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='organization-metadata'
   SELECT v.metadata_value_id Id,v.organization_id OrganizationId,d.metadata_key MetadataKey,d.metadata_name MetadataName,d.data_type DataType,
     v.value_text ValueText,v.value_number ValueNumber,v.value_date ValueDate,v.value_bool ValueBool,v.value_json ValueJson,v.status Status
   FROM grac_practice.organization_metadata_value v
   JOIN grac_practice.organization_metadata_definition d ON d.metadata_definition_id=v.metadata_definition_id
   WHERE (@p_id=0 OR v.metadata_value_id=@p_id) AND (@organization_id IS NULL OR v.organization_id=@organization_id)
     AND (@p_status='' OR v.status=@p_status)
     AND (@date_from IS NULL OR v.entered_dt>=@date_from) AND (@date_to IS NULL OR v.entered_dt<DATEADD(DAY,1,@date_to))
   ORDER BY d.metadata_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='repository-subscriptions'
   SELECT subscription_id Id,organization_id OrganizationId,authority_id AuthorityId,artifact_id ArtifactId,release_id ReleaseId,
     subscription_type SubscriptionType,ss.status_name SubscriptionStatus,effective_dt EffectiveDate,end_dt EndDate,rs.status_name Status
   FROM grac_practice.repository_subscription s
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=s.record_status_id
   JOIN grac_practice.subscription_status_master ss ON ss.subscription_status_id=s.subscription_status_id
   WHERE (@p_id=0 OR s.subscription_id=@p_id) AND (@organization_id IS NULL OR s.organization_id=@organization_id)
     AND (@p_status='' OR s.record_status_id=@filter_record_status_id OR s.subscription_status_id=@filter_subscription_status_id)
     AND (@date_from IS NULL OR s.entered_dt>=@date_from) AND (@date_to IS NULL OR s.entered_dt<DATEADD(DAY,1,@date_to))
   ORDER BY s.entered_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='organization-controls'
 BEGIN
   ;WITH practice_counts AS (
     SELECT req.organization_id OrganizationId,req.organization_control_id OrganizationControlId,COUNT_BIG(1) ApplicablePracticeCount
     FROM grac_practice.organization_requirement req
     LEFT JOIN grac_practice.applicability_status_master req_aps ON req_aps.applicability_status_id=req.applicability_status_id
     WHERE ISNULL(req.status,'Active')='Active'
       AND (req_aps.status_code='Applicable' OR req_aps.status_name='Applicable' OR req.applicability_status='Applicable')
     GROUP BY req.organization_id,req.organization_control_id
   ),
   base AS (
     SELECT oc.organization_control_id Id,oc.organization_id OrganizationId,oc.origin_type OriginType,oc.repository_control_id RepositoryControlId,
       oc.control_code Code,oc.control_name Name,oc.description Description,oc.business_justification BusinessJustification,
       oc.objective Objective,oc.control_domain_id DomainId,oc.control_sub_domain_id SubDomainId,oc.is_manually_added IsManuallyAdded,
        oc.subscription_id SubscriptionId,oc.release_id ReleaseId,oc.artifact_id ArtifactId,
        COALESCE(a.artifact_code + N' / ' + r.version_no, CASE WHEN oc.origin_type='Organization' THEN N'Organization Defined' END) SourceFrameworkRelease,
        aps.status_name ApplicabilityStatus,oc.primary_owner PrimaryOwner,oc.secondary_owner SecondaryOwner,oc.backup_owner BackupOwner,
        oc.business_function_id BusinessFunctionId,oc.criticality Criticality,rs.status_name Status,oc.entered_dt EnteredDate,
        COALESCE(pc.ApplicablePracticeCount,0) ApplicablePracticeCount,
        CASE WHEN oc.repository_control_id IS NOT NULL THEN N'R:' + CONVERT(NVARCHAR(40),oc.repository_control_id) ELSE N'M:' + CONVERT(NVARCHAR(40),oc.organization_control_id) END ControlGroupKey
     FROM grac_practice.organization_control oc
     JOIN grac_practice.record_status_master rs ON rs.record_status_id=oc.record_status_id
     JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=oc.applicability_status_id
     LEFT JOIN practice_counts pc ON pc.OrganizationId=oc.organization_id AND pc.OrganizationControlId=oc.organization_control_id
     LEFT JOIN grac_new.release r ON r.release_id=oc.release_id
     LEFT JOIN grac_new.artifact a ON a.artifact_id=COALESCE(oc.artifact_id,r.artifact_id)
     WHERE (@organization_id IS NULL OR oc.organization_id=@organization_id)
       AND (@p_status='' OR oc.record_status_id=@filter_record_status_id OR oc.applicability_status_id=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=@p_status OR status_name=@p_status))
       AND (@origin_type IS NULL OR ISNULL(oc.origin_type,'')=@origin_type)
       AND (@owner IS NULL OR ISNULL(oc.primary_owner,'') LIKE '%'+@owner+'%' OR ISNULL(oc.secondary_owner,'') LIKE '%'+@owner+'%' OR ISNULL(oc.backup_owner,'') LIKE '%'+@owner+'%')
       AND (@criticality IS NULL OR ISNULL(oc.criticality,'')=@criticality)
       AND (@date_from IS NULL OR oc.entered_dt>=@date_from) AND (@date_to IS NULL OR oc.entered_dt<DATEADD(DAY,1,@date_to))
   ),
   source_values AS (
     SELECT DISTINCT OrganizationId,ControlGroupKey,SourceFrameworkRelease
     FROM base
     WHERE SourceFrameworkRelease IS NOT NULL AND SourceFrameworkRelease<>N''
   ),
   source_agg AS (
     SELECT OrganizationId,ControlGroupKey,STRING_AGG(SourceFrameworkRelease,N', ') WITHIN GROUP (ORDER BY SourceFrameworkRelease) SourceFrameworkRelease
     FROM source_values
     GROUP BY OrganizationId,ControlGroupKey
   ),
   group_flags AS (
     SELECT OrganizationId,ControlGroupKey,MAX(CASE WHEN Id=@p_id THEN 1 ELSE 0 END) HasRequestedId
     FROM base
     GROUP BY OrganizationId,ControlGroupKey
   ),
   ranked AS (
     SELECT base.*,ROW_NUMBER() OVER(PARTITION BY base.OrganizationId,base.ControlGroupKey ORDER BY CASE WHEN base.Id=@p_id THEN 0 ELSE 1 END,base.Id) RowNumber
     FROM base
   )
   SELECT ranked.Id,ranked.OrganizationId,ranked.OriginType,ranked.RepositoryControlId,
      ranked.Code,ranked.Name,ranked.Description,ranked.BusinessJustification,ranked.Objective,
      ranked.DomainId,ranked.SubDomainId,ranked.IsManuallyAdded,ranked.SubscriptionId,ranked.ReleaseId,ranked.ArtifactId,
      COALESCE(source_agg.SourceFrameworkRelease,ranked.SourceFrameworkRelease) SourceFrameworkRelease,
      ranked.ApplicabilityStatus,ranked.PrimaryOwner,ranked.SecondaryOwner,ranked.BackupOwner,
      ranked.ApplicablePracticeCount,ranked.BusinessFunctionId,ranked.Criticality,ranked.Status
   FROM ranked
   JOIN group_flags ON group_flags.OrganizationId=ranked.OrganizationId AND group_flags.ControlGroupKey=ranked.ControlGroupKey
   LEFT JOIN source_agg ON source_agg.OrganizationId=ranked.OrganizationId AND source_agg.ControlGroupKey=ranked.ControlGroupKey
   WHERE ranked.RowNumber=1
     AND (@p_id=0 OR group_flags.HasRequestedId=1)
     AND (@p_search='' OR ranked.Code LIKE '%'+@p_search+'%' OR ranked.Name LIKE '%'+@p_search+'%' OR ranked.OriginType LIKE '%'+@p_search+'%' OR COALESCE(source_agg.SourceFrameworkRelease,ranked.SourceFrameworkRelease,N'') LIKE '%'+@p_search+'%')
   ORDER BY ranked.Code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='control-applicability'
   SELECT oc.organization_control_id Id,oc.organization_id OrganizationId,oc.origin_type OriginType,oc.repository_control_id RepositoryControlId,
     oc.control_code Code,oc.control_name Name,oc.description Description,oc.objective Objective,
     oc.is_manually_added IsManuallyAdded,aps.status_name ApplicabilityStatus,oc.exclusion_justification ExclusionJustification,
     oc.primary_owner PrimaryOwner,oc.secondary_owner SecondaryOwner,oc.business_function_id BusinessFunctionId,bf.function_name BusinessFunction,
     oc.criticality Criticality,rs.status_name Status
   FROM grac_practice.organization_control oc
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=oc.record_status_id
   JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=oc.applicability_status_id
   LEFT JOIN grac_practice.organization_business_function bf ON bf.business_function_id=oc.business_function_id
   WHERE (@p_id=0 OR oc.organization_control_id=@p_id) AND (@organization_id IS NULL OR oc.organization_id=@organization_id)
     AND (@p_status='' OR oc.record_status_id=@filter_record_status_id OR oc.applicability_status_id=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=@p_status OR status_name=@p_status))
     AND (@origin_type IS NULL OR ISNULL(oc.origin_type,'')=@origin_type)
     AND (@owner IS NULL OR ISNULL(oc.primary_owner,'') LIKE '%'+@owner+'%' OR ISNULL(oc.secondary_owner,'') LIKE '%'+@owner+'%' OR ISNULL(oc.backup_owner,'') LIKE '%'+@owner+'%')
     AND (@criticality IS NULL OR ISNULL(oc.criticality,'')=@criticality)
     AND (@date_from IS NULL OR oc.entered_dt>=@date_from) AND (@date_to IS NULL OR oc.entered_dt<DATEADD(DAY,1,@date_to))
     AND (@p_search='' OR ISNULL(oc.control_code,'') LIKE '%'+@p_search+'%' OR ISNULL(oc.control_name,'') LIKE '%'+@p_search+'%' OR ISNULL(oc.origin_type,'') LIKE '%'+@p_search+'%' OR ISNULL(bf.function_name,'') LIKE '%'+@p_search+'%')
   ORDER BY oc.control_code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='organization-requirements'
 BEGIN
   IF @organization_control_id IS NULL
      THROW 51024,'Control context is required to load requirements.',1;

   ;WITH requirement_candidates AS (
     SELECT
       oc.organization_id,
       q.requirement_id repository_requirement_id,
       oc.organization_control_id,
       q.requirement_code,
       q.requirement_name,
       q.requirement_statement,
       q.objective,
       ROW_NUMBER() OVER(
         PARTITION BY oc.organization_id,oc.organization_control_id,q.requirement_code
         ORDER BY q.requirement_id
       ) row_no
     FROM grac_practice.organization_control oc
     JOIN grac_new.control repo_control ON (repo_control.control_id=oc.repository_control_id OR repo_control.control_code=oc.control_code) AND repo_control.status='Active'
     JOIN grac_new.control_requirement_map crm ON crm.control_id=repo_control.control_id AND crm.status='Active'
     JOIN grac_new.requirement q ON q.requirement_id=crm.requirement_id AND q.status='Active'
     WHERE ISNULL(oc.origin_type,'Repository') IN ('Repository','Hybrid')
       AND oc.record_status_id=@active_record_status_id
       AND (
         oc.applicability_status_id=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable')
       OR oc.applicability_status='Applicable'
       )
       AND (@organization_id IS NULL OR oc.organization_id=@organization_id)
       AND oc.organization_control_id=@organization_control_id
   )
   INSERT grac_practice.organization_requirement(
     organization_id,origin_type,repository_requirement_id,organization_control_id,requirement_code,requirement_name,
     requirement_statement,objective,applicability_status,applicability_status_id,implementation_status,implementation_status_id,status,record_status_id,entered_by)
   SELECT c.organization_id,'Repository',c.repository_requirement_id,c.organization_control_id,c.requirement_code,c.requirement_name,
     c.requirement_statement,c.objective,'Not Updated',@not_updated_applicability_status_id,'Not Started',@not_started_implementation_status_id,'Active',@active_record_status_id,COALESCE(NULLIF(@p_usr_id,''),'system')
   FROM requirement_candidates c
   WHERE c.row_no=1
     AND NOT EXISTS(
       SELECT 1
       FROM grac_practice.organization_requirement existing
       WHERE existing.organization_id=c.organization_id
         AND existing.organization_control_id=c.organization_control_id
         AND (
           existing.requirement_code=c.requirement_code
           OR existing.repository_requirement_id=c.repository_requirement_id
         )
     );

   SELECT q.organization_requirement_id Id,q.organization_id OrganizationId,q.origin_type OriginType,q.repository_requirement_id RepositoryRequirementId,
     q.organization_control_id OrganizationControlId,q.requirement_code Code,q.requirement_name Name,q.requirement_statement Statement,
     q.objective Objective,practice.practice_id PracticeId,practice.practice_owner_id PracticeOwnerId,COALESCE(emp.employee_name,practice.practice_owner) PracticeOwner,
     COALESCE(aps.status_name,q.applicability_status) ApplicabilityStatus,COALESCE(ims.status_name,q.implementation_status) ImplementationStatus,COALESCE(rs.status_name,q.status) Status,
     (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance pi_count JOIN grac_practice.practice p_count ON p_count.practice_id=pi_count.practice_id WHERE p_count.organization_requirement_id=q.organization_requirement_id AND pi_count.status='Active') PracticeInstanceCount
   FROM grac_practice.organization_requirement q
   LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=q.record_status_id
   LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=q.applicability_status_id
   LEFT JOIN grac_practice.implementation_status_master ims ON ims.implementation_status_id=q.implementation_status_id
   OUTER APPLY (
     SELECT TOP (1) p.practice_id,p.practice_owner_id,p.practice_owner
     FROM grac_practice.practice p
     WHERE p.organization_id=q.organization_id
       AND p.organization_requirement_id=q.organization_requirement_id
       AND p.status='Active'
     ORDER BY p.practice_id
   ) practice
   LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id=practice.practice_owner_id
   WHERE (@p_id=0 OR q.organization_requirement_id=@p_id) AND (@organization_id IS NULL OR q.organization_id=@organization_id)
     -- Accept the Practice if it is linked to @organization_control_id either
     -- through the legacy "primary" column on organization_requirement OR
     -- through the many-to-many organization_control_requirement mapping added
     -- by migration 057 (dedup of shared repository requirements).
     AND (q.organization_control_id=@organization_control_id
          OR EXISTS(
              SELECT 1
              FROM grac_practice.organization_control_requirement m
              WHERE m.organization_requirement_id=q.organization_requirement_id
                AND m.organization_control_id=@organization_control_id
                AND m.status='Active'))
     AND (@p_status='' OR q.record_status_id=@filter_record_status_id OR q.status=@p_status OR q.applicability_status=@p_status OR q.implementation_status=@p_status OR q.applicability_status_id=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=@p_status OR status_name=@p_status)) AND (@origin_type IS NULL OR q.origin_type=@origin_type)
     AND (@date_from IS NULL OR q.entered_dt>=@date_from) AND (@date_to IS NULL OR q.entered_dt<DATEADD(DAY,1,@date_to))
     AND (@p_search='' OR requirement_code LIKE '%'+@p_search+'%' OR requirement_name LIKE '%'+@p_search+'%')
   ORDER BY requirement_code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='practices'
 BEGIN
   IF @organization_requirement_id IS NOT NULL
   BEGIN
     UPDATE p
       SET organization_requirement_id=q.organization_requirement_id,
           updated_by=COALESCE(NULLIF(@p_usr_id,''),'system'),
           updated_dt=SYSUTCDATETIME()
     FROM grac_practice.practice p
     JOIN grac_practice.organization_requirement q
       ON q.organization_requirement_id=@organization_requirement_id
      AND q.organization_id=p.organization_id
      AND (q.requirement_code=p.practice_code OR q.requirement_name=p.practice_name)
     WHERE p.organization_requirement_id IS NULL;

     INSERT grac_practice.practice(
       organization_id,organization_requirement_id,origin_type,practice_code,practice_name,description,practice_owner,
       applicability_status,applicability_status_id,status,record_status_id,entered_by)
     SELECT q.organization_id,q.organization_requirement_id,q.origin_type,q.requirement_code,q.requirement_name,q.requirement_statement,NULL,
       'Not Updated',@not_updated_applicability_status_id,'Active',@active_record_status_id,COALESCE(NULLIF(@p_usr_id,''),'system')
     FROM grac_practice.organization_requirement q
     WHERE q.organization_requirement_id=@organization_requirement_id
       AND (@organization_id IS NULL OR q.organization_id=@organization_id)
       AND NOT EXISTS(
         SELECT 1
         FROM grac_practice.practice p
         WHERE p.organization_id=q.organization_id
           AND p.organization_requirement_id=q.organization_requirement_id
       );
   END;

   SELECT p.practice_id Id,p.organization_id OrganizationId,p.organization_requirement_id OrganizationRequirementId,p.origin_type OriginType,
     p.practice_code Code,p.practice_name Name,p.description Description,p.practice_owner_id PracticeOwnerId,COALESCE(emp.employee_name,p.practice_owner) PracticeOwner,
     p.applicability_status_id ApplicabilityStatusId,COALESCE(aps.status_code,p.applicability_status) ApplicabilityStatusCode,
     COALESCE(aps.status_name,p.applicability_status) ApplicabilityStatus,p.exclusion_justification ExclusionJustification,COALESCE(rs.status_name,p.status) Status
   FROM grac_practice.practice p
   LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=p.record_status_id
   LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=p.applicability_status_id
   LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id=p.practice_owner_id
   WHERE (@p_id=0 OR p.practice_id=@p_id) AND (@organization_id IS NULL OR p.organization_id=@organization_id)
     AND (@organization_requirement_id IS NULL OR p.organization_requirement_id=@organization_requirement_id)
     AND (@p_status='' OR p.record_status_id=@filter_record_status_id OR p.status=@p_status OR p.applicability_status=@p_status OR p.applicability_status_id=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=@p_status OR status_name=@p_status))
     AND (@origin_type IS NULL OR p.origin_type=@origin_type)
     AND (@owner IS NULL OR COALESCE(emp.employee_name,p.practice_owner) LIKE '%'+@owner+'%')
     AND (@date_from IS NULL OR p.entered_dt>=@date_from) AND (@date_to IS NULL OR p.entered_dt<DATEADD(DAY,1,@date_to))
     AND (@p_search='' OR p.practice_code LIKE '%'+@p_search+'%' OR p.practice_name LIKE '%'+@p_search+'%')
   ORDER BY p.practice_code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='practice-instances'
 BEGIN
   IF @organization_requirement_id IS NOT NULL
   BEGIN
     INSERT grac_practice.practice(
       organization_id,organization_requirement_id,origin_type,practice_code,practice_name,description,practice_owner,
       applicability_status,applicability_status_id,status,record_status_id,entered_by)
     SELECT q.organization_id,q.organization_requirement_id,q.origin_type,q.requirement_code,q.requirement_name,q.requirement_statement,NULL,
       'Applicable',(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable'),'Active',@active_record_status_id,COALESCE(NULLIF(@p_usr_id,''),'system')
     FROM grac_practice.organization_requirement q
     WHERE q.organization_requirement_id=@organization_requirement_id
       AND (@organization_id IS NULL OR q.organization_id=@organization_id)
       AND (
         q.applicability_status_id=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable')
         OR q.applicability_status='Applicable'
       )
       AND NOT EXISTS(
         SELECT 1
         FROM grac_practice.practice p
         WHERE p.organization_id=q.organization_id
           AND p.organization_requirement_id=q.organization_requirement_id
       );
   END;

    SELECT pi.practice_instance_id Id,pi.practice_id PracticeId,COALESCE(p.organization_requirement_id,@organization_requirement_id) OrganizationRequirementId,
      pi.organization_id OrganizationId,pi.instance_code Code,pi.instance_name Name,
      pi.primary_owner_id PrimaryOwnerId,COALESCE(emp.employee_name,pi.primary_owner) PrimaryOwner,pi.secondary_owner SecondaryOwner,
      pi.business_function_id BusinessFunctionId,pi.department_id DepartmentId,COALESCE(dept.department_name,pi.department) Department,
      pi.execution_frequency_id ExecutionFrequencyId,execf.frequency_name ExecutionFrequency,
      pi.assurance_frequency_id AssuranceFrequencyId,assurf.frequency_name AssuranceFrequency,
      COALESCE(pi.execution_frequency_id,pi.frequency_id) FrequencyId,COALESCE(execf.frequency_code,f.frequency_code,pi.frequency_type) FrequencyType,
      COALESCE(CASE WHEN f.is_custom=0 THEN f.frequency_value END,pi.frequency_value) FrequencyValue,
      COALESCE(CASE WHEN f.is_custom=0 THEN f.frequency_unit END,pi.frequency_unit) FrequencyUnit,pi.assurance_mode AssuranceMode,
      pi.criticality Criticality,pi.implementation_status ImplementationStatus,pi.status Status,
      COALESCE(po.status,N'Pending') ResolveStatus,COALESCE(last_result.result_status,N'Not Assured') AssuranceStatus
    FROM grac_practice.practice_instance pi
    JOIN grac_practice.practice p ON p.practice_id=pi.practice_id
    LEFT JOIN grac_practice.frequency_master f ON f.frequency_id=pi.frequency_id
    LEFT JOIN grac_practice.frequency_master execf ON execf.frequency_id=pi.execution_frequency_id
    LEFT JOIN grac_practice.frequency_master assurf ON assurf.frequency_id=pi.assurance_frequency_id
    LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id=pi.primary_owner_id
    LEFT JOIN grac_practice.organization_department dept ON dept.department_id=pi.department_id
    LEFT JOIN grac_practice.practice_operationalization po ON po.practice_instance_id=pi.practice_instance_id AND po.organization_id=pi.organization_id
    OUTER APPLY (SELECT TOP (1) ar.result_status FROM grac_practice.assurance_activity aa LEFT JOIN grac_practice.assurance_result ar ON ar.assurance_activity_id=aa.assurance_activity_id WHERE aa.practice_instance_id=pi.practice_instance_id ORDER BY COALESCE(ar.updated_dt,ar.entered_dt,aa.updated_dt,aa.entered_dt) DESC) last_result
   WHERE (@p_id=0 OR pi.practice_instance_id=@p_id) AND (@organization_id IS NULL OR pi.organization_id=@organization_id)
     AND (@practice_id IS NULL OR pi.practice_id=@practice_id)
     AND (
       @organization_requirement_id IS NULL
       OR p.organization_requirement_id=@organization_requirement_id
       OR EXISTS (
         SELECT 1
         FROM grac_practice.organization_requirement q
         WHERE q.organization_requirement_id=@organization_requirement_id
           AND q.organization_id=pi.organization_id
           AND (q.requirement_code=p.practice_code OR q.requirement_name=p.practice_name)
       )
     )
     AND (@p_status='' OR pi.status=@p_status)
     AND (@owner IS NULL OR pi.primary_owner LIKE '%'+@owner+'%' OR pi.secondary_owner LIKE '%'+@owner+'%')
     AND (@criticality IS NULL OR pi.criticality=@criticality)
     AND (@date_from IS NULL OR pi.entered_dt>=@date_from) AND (@date_to IS NULL OR pi.entered_dt<DATEADD(DAY,1,@date_to))
     AND (@p_search='' OR pi.instance_code LIKE '%'+@p_search+'%' OR pi.instance_name LIKE '%'+@p_search+'%')
   ORDER BY pi.instance_code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='dependency-options'
 BEGIN
   DECLARE @dep_opt_dependency_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.dependencyTypeId'),''));
   DECLARE @dep_opt_source_type NVARCHAR(80);
   DECLARE @dep_opt_source_table NVARCHAR(256);
   DECLARE @dep_opt_id_column SYSNAME;
   DECLARE @dep_opt_display_column SYSNAME;
   DECLARE @dep_opt_org_column SYSNAME;
   DECLARE @dep_opt_status_column SYSNAME;
   DECLARE @dep_opt_status_value NVARCHAR(80);
   DECLARE @dep_opt_sort_column SYSNAME;
   DECLARE @dep_opt_multi BIT;
   DECLARE @dep_opt_schema SYSNAME;
   DECLARE @dep_opt_table SYSNAME;
   DECLARE @dep_opt_object_id INT;
   DECLARE @dep_opt_sql NVARCHAR(MAX);

   IF @dep_opt_dependency_type_id IS NULL
     THROW 51062,'Dependency Type is required to load dependency options.',1;
   IF @organization_id IS NULL
     THROW 51063,'Organization context is required to load dependency options.',1;

   SELECT TOP 1
     @dep_opt_source_type=source_type,
     @dep_opt_source_table=source_table_name,
     @dep_opt_id_column=id_column_name,
     @dep_opt_display_column=display_column_name,
     @dep_opt_org_column=organization_filter_column,
     @dep_opt_status_column=status_filter_column,
     @dep_opt_status_value=status_active_value,
     @dep_opt_sort_column=COALESCE(NULLIF(sort_column,''),display_column_name),
     @dep_opt_multi=is_multi_select_allowed
   FROM grac_practice.dependency_type_source_config
   WHERE dependency_type_id=@dep_opt_dependency_type_id
     AND status='Active'
     AND source_table_name IN (
       N'grac_practice.organization_dependency_tool',
       N'grac_practice.organization_dependency_vendor',
       N'grac_practice.organization_dependency_application',
       N'grac_practice.organization_dependency_asset',
       N'grac_practice.organization_dependency_process',
       N'grac_practice.organization_location',
       N'grac_practice.organization_employee',
       N'grac_practice.organization_team',
       N'grac_practice.organization_committee'
     );

   IF @dep_opt_source_table IS NULL
     THROW 51064,'Dependency Type source configuration is missing or inactive.',1;

   SET @dep_opt_schema=PARSENAME(@dep_opt_source_table,2);
   SET @dep_opt_table=PARSENAME(@dep_opt_source_table,1);
   SET @dep_opt_object_id=OBJECT_ID(@dep_opt_source_table);
   IF @dep_opt_schema<>N'grac_practice' OR @dep_opt_object_id IS NULL
     THROW 51065,'Dependency Type source configuration is invalid.',1;
   IF COL_LENGTH(@dep_opt_source_table,@dep_opt_id_column) IS NULL
      OR COL_LENGTH(@dep_opt_source_table,@dep_opt_display_column) IS NULL
      OR COL_LENGTH(@dep_opt_source_table,@dep_opt_org_column) IS NULL
      OR COL_LENGTH(@dep_opt_source_table,@dep_opt_status_column) IS NULL
      OR COL_LENGTH(@dep_opt_source_table,@dep_opt_sort_column) IS NULL
     THROW 51066,'Dependency Type source columns are invalid.',1;

   SET @dep_opt_sql=N'
SELECT
 CAST(' + QUOTENAME(@dep_opt_id_column) + N' AS NVARCHAR(40)) [Value],
 CAST(' + QUOTENAME(@dep_opt_display_column) + N' AS NVARCHAR(300)) [Label],
 @dependencyTypeId DependencyTypeId,
 @sourceType SourceType,
 @isMultiSelectAllowed IsMultiSelectAllowed
FROM ' + QUOTENAME(@dep_opt_schema) + N'.' + QUOTENAME(@dep_opt_table) + N'
WHERE ' + QUOTENAME(@dep_opt_org_column) + N'=@organizationId
  AND ' + QUOTENAME(@dep_opt_status_column) + N'=@activeStatus
  AND (@searchText=N'''' OR CAST(' + QUOTENAME(@dep_opt_display_column) + N' AS NVARCHAR(300)) LIKE N''%''+@searchText+N''%'')
ORDER BY ' + QUOTENAME(@dep_opt_sort_column) + N'
OFFSET 0 ROWS FETCH NEXT @take ROWS ONLY;';

   EXEC sp_executesql @dep_opt_sql,
     N'@organizationId BIGINT,@activeStatus NVARCHAR(80),@searchText NVARCHAR(200),@take INT,@dependencyTypeId INT,@sourceType NVARCHAR(80),@isMultiSelectAllowed BIT',
     @organizationId=@organization_id,
     @activeStatus=@dep_opt_status_value,
     @searchText=@p_search,
     @take=@page_size,
     @dependencyTypeId=@dep_opt_dependency_type_id,
     @sourceType=@dep_opt_source_type,
     @isMultiSelectAllowed=@dep_opt_multi;
 END
 ELSE IF @p_entity_type='practice-operationalization'
 BEGIN
   DECLARE @resolve_dependency_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.dependencyTypeId'),''));
   DECLARE @resolve_register_type NVARCHAR(80)=NULLIF(JSON_VALUE(@p_payload,'$.registerType'),'');
   ;WITH configured_categories AS (
     SELECT d.organization_id,d.practice_instance_id,d.dependency_type_id,
       COALESCE(dt.dependency_type_name,d.dependency_type) DependencyCategory
     FROM grac_practice.practice_instance_dependency d
     LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id
     WHERE d.status='Active'
       AND d.dependency_type_id IS NOT NULL
     GROUP BY d.organization_id,d.practice_instance_id,d.dependency_type_id,COALESCE(dt.dependency_type_name,d.dependency_type)
   ),
    category_agg AS (
      SELECT c.organization_id,c.practice_instance_id,
        COUNT(1) TotalDependencyCategories,
        STUFF((
          SELECT N', ' + c2.DependencyCategory
          FROM configured_categories c2
          WHERE c2.organization_id=c.organization_id
            AND c2.practice_instance_id=c.practice_instance_id
          ORDER BY c2.DependencyCategory
          FOR XML PATH(''),TYPE
        ).value('.','NVARCHAR(MAX)'),1,2,N'') DependencyCategories
      FROM configured_categories c
      GROUP BY c.organization_id,c.practice_instance_id
   ),
    resolved_categories AS (
      SELECT r.organization_id,r.practice_instance_id,r.dependency_type_id
      FROM grac_practice.practice_dependency_resolution r
      WHERE r.is_active=1
        AND r.resolution_status=N'Resolved'
      GROUP BY r.organization_id,r.practice_instance_id,r.dependency_type_id
    ),
    resolution_agg AS (
      SELECT organization_id,practice_instance_id,
        COUNT(1) ResolvedDependenciesCount
      FROM resolved_categories
      GROUP BY organization_id,practice_instance_id
    ),
   evidence_values AS (
     SELECT e.organization_id,e.practice_instance_id,
       COALESCE(et.evidence_type_name,N'Evidence Type #' + CONVERT(NVARCHAR(20),e.evidence_type_id)) EvidenceTypeName
     FROM grac_practice.practice_instance_evidence e
     LEFT JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=e.evidence_type_id
     WHERE e.status='Active'
     GROUP BY e.organization_id,e.practice_instance_id,COALESCE(et.evidence_type_name,N'Evidence Type #' + CONVERT(NVARCHAR(20),e.evidence_type_id))
   ),
   evidence_agg AS (
     SELECT ev1.organization_id,ev1.practice_instance_id,
       STUFF((
         SELECT N', ' + ev2.EvidenceTypeName
         FROM evidence_values ev2
         WHERE ev2.organization_id=ev1.organization_id
           AND ev2.practice_instance_id=ev1.practice_instance_id
         ORDER BY ev2.EvidenceTypeName
         FOR XML PATH(''),TYPE
       ).value('.','NVARCHAR(MAX)'),1,2,N'') EvidenceTypes
     FROM evidence_values ev1
     GROUP BY ev1.organization_id,ev1.practice_instance_id
   ),
   base AS (
     SELECT pi.practice_instance_id Id,pi.practice_instance_id PracticeInstanceId,pi.organization_id OrganizationId,
       pi.instance_code Code,pi.instance_name Name,
       COALESCE(bf.function_name,pi.department,N'') OwningDepartment,
        pi.primary_owner PrimaryOwner,
        COALESCE(execf.frequency_name,f.frequency_name,pi.frequency_type,N'') Frequency,
       COALESCE(ev.EvidenceTypes,N'') EvidenceTypes,
       COALESCE(cat.DependencyCategories,N'') DependencyCategories,
       CASE WHEN @resolve_register_type='Evidence' THEN N'Evidence Register'
            WHEN @resolve_dependency_type_id IS NOT NULL THEN COALESCE((SELECT TOP 1 dependency_type_name FROM grac_practice.dependency_type_master WHERE dependency_type_id=@resolve_dependency_type_id),N'Dependency Register') + N' Register'
            ELSE COALESCE(cat.DependencyCategories,N'') END Register,
       CASE WHEN @resolve_register_type='Evidence' THEN COALESCE(ev.EvidenceTypes,N'')
            ELSE COALESCE((SELECT STUFF((SELECT N', ' + r2.resolved_dependency_name
              FROM grac_practice.practice_dependency_resolution r2
              WHERE r2.organization_id=pi.organization_id AND r2.practice_instance_id=pi.practice_instance_id
                AND r2.is_active=1 AND (@resolve_dependency_type_id IS NULL OR r2.dependency_type_id=@resolve_dependency_type_id)
              ORDER BY r2.resolved_dependency_name FOR XML PATH(''),TYPE).value('.','NVARCHAR(MAX)'),1,2,N'')),N'') END ResolvedDependencyName,
       CASE WHEN @resolve_register_type='Evidence' THEN CASE WHEN EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e2 WHERE e2.practice_instance_id=pi.practice_instance_id AND e2.status='Active') THEN N'Resolved' ELSE N'Pending' END
            WHEN @resolve_dependency_type_id IS NOT NULL AND EXISTS(SELECT 1 FROM grac_practice.practice_dependency_resolution r3 WHERE r3.organization_id=pi.organization_id AND r3.practice_instance_id=pi.practice_instance_id AND r3.dependency_type_id=@resolve_dependency_type_id AND r3.is_active=1 AND r3.resolution_status='Resolved') THEN N'Resolved'
            WHEN @resolve_dependency_type_id IS NULL AND COALESCE(res.ResolvedDependenciesCount,0)>0 THEN N'Resolved'
            ELSE N'Pending' END ResolutionStatus,
       COALESCE((SELECT TOP 1 e3.employee_name FROM grac_practice.practice_dependency_resolution r4 LEFT JOIN grac_practice.organization_employee e3 ON e3.employee_id=r4.resolution_owner_id WHERE r4.organization_id=pi.organization_id AND r4.practice_instance_id=pi.practice_instance_id AND (@resolve_dependency_type_id IS NULL OR r4.dependency_type_id=@resolve_dependency_type_id) AND r4.is_active=1 ORDER BY r4.updated_dt DESC,r4.entered_dt DESC),N'') ResolutionOwner,
       COALESCE((SELECT MAX(COALESCE(r5.updated_dt,r5.entered_dt)) FROM grac_practice.practice_dependency_resolution r5 WHERE r5.organization_id=pi.organization_id AND r5.practice_instance_id=pi.practice_instance_id AND (@resolve_dependency_type_id IS NULL OR r5.dependency_type_id=@resolve_dependency_type_id) AND r5.is_active=1),pi.updated_dt,pi.entered_dt) LastUpdated,
       (SELECT TOP 1 e6.evidence_id FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceId,
       (SELECT TOP 1 e6.evidence_type_id FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceTypeId,
       (SELECT TOP 1 e6.assurance_type_id FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) AssuranceTypeId,
       (SELECT TOP 1 at6.assurance_type_name FROM grac_practice.practice_instance_evidence e6 LEFT JOIN grac_practice.assurance_type_master at6 ON at6.assurance_type_id=e6.assurance_type_id WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) AssuranceTypeName,
       (SELECT TOP 1 e6.collection_method_id FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) CollectionMethodId,
       (SELECT TOP 1 e6.retention_period FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) RetentionPeriod,
       (SELECT TOP 1 e6.evidence_description FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceDescription,
       (SELECT TOP 1 e6.evidence_location FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceLocation,
       (SELECT TOP 1 e6.evidence_locator FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceLocator,
       COALESCE(res.ResolvedDependenciesCount,0) ResolvedDependenciesCount,
       CASE
         WHEN COALESCE(cat.TotalDependencyCategories,0)-COALESCE(res.ResolvedDependenciesCount,0) < 0 THEN 0
         ELSE COALESCE(cat.TotalDependencyCategories,0)-COALESCE(res.ResolvedDependenciesCount,0)
       END PendingDependenciesCount,
        CASE
          WHEN pi.status IN ('Inactive','Retired') OR prs.status_code IN ('Inactive','Retired') THEN N'Retired'
          WHEN COALESCE(cat.TotalDependencyCategories,0)=0 THEN N'Dependency Categories Pending'
          WHEN COALESCE(res.ResolvedDependenciesCount,0)>=COALESCE(cat.TotalDependencyCategories,0) THEN N'Operationalized'
          WHEN COALESCE(res.ResolvedDependenciesCount,0)>0 THEN N'Partially Operationalized'
          ELSE N'Configured'
        END OperationalizationStatus,
        COALESCE(prs.status_name,pi.status) Status,
        pi.entered_dt EnteredDate
      FROM grac_practice.practice_instance pi
      LEFT JOIN grac_practice.practice p ON p.practice_id=pi.practice_id
      LEFT JOIN grac_practice.organization_requirement req ON req.organization_requirement_id=p.organization_requirement_id
      LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=req.applicability_status_id
      LEFT JOIN grac_practice.record_status_master prs ON prs.record_status_id=pi.record_status_id
      LEFT JOIN grac_practice.organization_business_function bf ON bf.business_function_id=pi.business_function_id
      LEFT JOIN grac_practice.frequency_master f ON f.frequency_id=pi.frequency_id
      LEFT JOIN grac_practice.frequency_master execf ON execf.frequency_id=pi.execution_frequency_id
      LEFT JOIN category_agg cat ON cat.organization_id=pi.organization_id AND cat.practice_instance_id=pi.practice_instance_id
     LEFT JOIN resolution_agg res ON res.organization_id=pi.organization_id AND res.practice_instance_id=pi.practice_instance_id
     LEFT JOIN evidence_agg ev ON ev.organization_id=pi.organization_id AND ev.practice_instance_id=pi.practice_instance_id
      WHERE (@p_id=0 OR pi.practice_instance_id=@p_id)
        AND (@organization_id IS NULL OR pi.organization_id=@organization_id)
        AND (@practice_id IS NULL OR pi.practice_id=@practice_id)
        AND (@p_status='' OR pi.status=@p_status OR prs.status_code=@p_status OR prs.status_name=@p_status OR aps.status_code=@p_status OR aps.status_name=@p_status)
        AND (@owner IS NULL OR pi.primary_owner LIKE '%'+@owner+'%' OR pi.secondary_owner LIKE '%'+@owner+'%')
       AND (@criticality IS NULL OR pi.criticality=@criticality)
       AND (@date_from IS NULL OR pi.entered_dt>=@date_from) AND (@date_to IS NULL OR pi.entered_dt<DATEADD(DAY,1,@date_to))
       AND EXISTS(
         SELECT 1
         FROM grac_practice.organization_employee owner_emp
         WHERE owner_emp.status='Active'
           AND owner_emp.organization_id=pi.organization_id
           AND (owner_emp.employee_id=pi.primary_owner_id OR owner_emp.employee_name=pi.primary_owner)
           AND (owner_emp.email=@p_usr_id OR owner_emp.employee_code=@p_usr_id)
       )
       AND (
         (@resolve_register_type='Evidence' AND EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status='Active'))
         OR
         (COALESCE(@resolve_register_type,N'')<>N'Evidence' AND (@resolve_dependency_type_id IS NULL OR EXISTS(
            SELECT 1 FROM grac_practice.practice_instance_dependency dfilter
            WHERE dfilter.practice_instance_id=pi.practice_instance_id
              AND dfilter.organization_id=pi.organization_id
              AND dfilter.dependency_type_id=@resolve_dependency_type_id
              AND dfilter.status='Active'
         )))
       )
       AND (@p_search='' OR pi.instance_code LIKE '%'+@p_search+'%' OR pi.instance_name LIKE '%'+@p_search+'%' OR COALESCE(bf.function_name,pi.department,N'') LIKE '%'+@p_search+'%')
   )
    SELECT Id,PracticeInstanceId,OrganizationId,Code,Name,OwningDepartment,PrimaryOwner,Frequency,EvidenceTypes,DependencyCategories,
      Register,ResolvedDependencyName,ResolutionStatus,ResolutionOwner,LastUpdated,EvidenceId,EvidenceTypeId,AssuranceTypeId,AssuranceTypeName,CollectionMethodId,RetentionPeriod,EvidenceDescription,EvidenceLocation,EvidenceLocator,
      ResolvedDependenciesCount,PendingDependenciesCount,OperationalizationStatus,Status
    FROM base
    ORDER BY Name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;

    SELECT
      @organization_id SelectedOrganizationId,
      CONVERT(BIGINT,NULL) LoggedInOrganizationId,
      (SELECT COUNT(1)
       FROM grac_practice.practice_instance pi
       LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=pi.record_status_id
       WHERE (@organization_id IS NULL OR pi.organization_id=@organization_id)
         AND (pi.status='Active' OR rs.status_code='Active' OR pi.record_status_id IS NULL)) ApplicablePracticeInstanceCount,
      (SELECT COUNT(1)
       FROM (
         SELECT d.organization_id,d.practice_instance_id,d.dependency_type_id
         FROM grac_practice.practice_instance_dependency d
         LEFT JOIN grac_practice.record_status_master drs ON drs.record_status_id=d.record_status_id
         WHERE d.dependency_type_id IS NOT NULL
           AND (d.status='Active' OR drs.status_code='Active' OR d.record_status_id IS NULL)
           AND (@organization_id IS NULL OR d.organization_id=@organization_id)
         GROUP BY d.organization_id,d.practice_instance_id,d.dependency_type_id
       ) dependency_categories) ConfiguredDependencyCategoryCount,
      (SELECT COUNT(1)
       FROM grac_practice.practice_operationalization po
       WHERE (@organization_id IS NULL OR po.organization_id=@organization_id)) OperationalizationRecordCount,
      (SELECT COUNT(1)
       FROM grac_practice.practice_instance pi
       LEFT JOIN grac_practice.practice p ON p.practice_id=pi.practice_id
       LEFT JOIN grac_practice.organization_requirement req ON req.organization_requirement_id=p.organization_requirement_id
       LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=req.applicability_status_id
       LEFT JOIN grac_practice.record_status_master prs ON prs.record_status_id=pi.record_status_id
       LEFT JOIN grac_practice.organization_business_function bf ON bf.business_function_id=pi.business_function_id
       WHERE (@p_id=0 OR pi.practice_instance_id=@p_id)
         AND (@organization_id IS NULL OR pi.organization_id=@organization_id)
         AND (@practice_id IS NULL OR pi.practice_id=@practice_id)
         AND (@p_status='' OR pi.status=@p_status OR prs.status_code=@p_status OR prs.status_name=@p_status OR aps.status_code=@p_status OR aps.status_name=@p_status)
         AND (@owner IS NULL OR pi.primary_owner LIKE '%'+@owner+'%' OR pi.secondary_owner LIKE '%'+@owner+'%')
         AND (@criticality IS NULL OR pi.criticality=@criticality)
         AND (@date_from IS NULL OR pi.entered_dt>=@date_from) AND (@date_to IS NULL OR pi.entered_dt<DATEADD(DAY,1,@date_to))
         AND (@p_search='' OR pi.instance_code LIKE '%'+@p_search+'%' OR pi.instance_name LIKE '%'+@p_search+'%' OR COALESCE(bf.function_name,pi.department,N'') LIKE '%'+@p_search+'%')) FinalReturnedCount;

    IF @p_id<>0
   BEGIN
     ;WITH configured_categories AS (
       SELECT d.organization_id,d.practice_instance_id,d.dependency_type_id,
         COALESCE(dt.dependency_type_name,d.dependency_type) DependencyCategory
       FROM grac_practice.practice_instance_dependency d
       LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id
       WHERE d.status='Active'
         AND d.practice_instance_id=@p_id
         AND d.dependency_type_id IS NOT NULL
       GROUP BY d.organization_id,d.practice_instance_id,d.dependency_type_id,COALESCE(dt.dependency_type_name,d.dependency_type)
     )
     SELECT c.practice_instance_id PracticeInstanceId,c.dependency_type_id DependencyTypeId,c.DependencyCategory,
       r.resolution_id ResolutionId,r.resolved_dependency_id ResolvedDependencyId,r.resolved_dependency_name ResolvedDependencyName,
       COALESCE(drs.status_name,N'Pending') ResolutionStatus,r.resolution_owner_id ResolutionOwnerId,COALESCE(e.employee_name,N'') ResolutionOwner,
       r.resolution_dt ResolutionDate,r.remarks Remarks,
       CASE WHEN r.resolution_id IS NULL THEN N'Pending' ELSE N'Resolved' END CategoryStatus
     FROM configured_categories c
     LEFT JOIN grac_practice.practice_dependency_resolution r
       ON r.organization_id=c.organization_id
      AND r.practice_instance_id=c.practice_instance_id
      AND r.dependency_type_id=c.dependency_type_id
      AND r.is_active=1
     LEFT JOIN grac_practice.dependency_resolution_status_master drs ON drs.resolution_status_id=r.resolution_status_id
     LEFT JOIN grac_practice.organization_employee e ON e.employee_id=r.resolution_owner_id
     ORDER BY c.DependencyCategory,r.resolved_dependency_name;
   END
 END
 ELSE IF @p_entity_type='dependencies'
   SELECT d.dependency_id Id,d.practice_instance_id PracticeInstanceId,d.dependency_type_id DependencyTypeId,
     COALESCE(dt.dependency_type_name,d.dependency_type) DependencyType,d.dependency_name Name,
     d.dependency_reference_id DependencyReferenceId,d.dependency_source_type DependencySourceType,
     dependency_reference Reference,owner_name OwnerName,d.criticality_id CriticalityId,
     COALESCE(cm.criticality_name,d.criticality) Criticality,d.record_status_id StatusId,COALESCE(rs.status_name,d.status) Status
   FROM grac_practice.practice_instance_dependency d
   LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id
   LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id=d.criticality_id
   LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=d.record_status_id
   WHERE (@p_id=0 OR d.dependency_id=@p_id) AND (@practice_instance_id IS NULL OR d.practice_instance_id=@practice_instance_id)
     AND (@organization_id IS NULL OR d.organization_id=@organization_id)
     AND (@p_status='' OR d.status=@p_status OR rs.status_code=@p_status OR rs.status_name=@p_status)
     AND (@owner IS NULL OR d.owner_name LIKE '%'+@owner+'%')
     AND (@criticality IS NULL OR d.criticality=@criticality OR cm.criticality_code=@criticality OR cm.criticality_name=@criticality)
     AND (@date_from IS NULL OR d.entered_dt>=@date_from) AND (@date_to IS NULL OR d.entered_dt<DATEADD(DAY,1,@date_to))
   ORDER BY COALESCE(dt.display_order,999),d.dependency_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='evidence-configurations'
 BEGIN
  SELECT e.evidence_id Id,e.practice_instance_id PracticeInstanceId,e.evidence_type_id EvidenceTypeId,
    COALESCE(et.evidence_type_name,N'Evidence Type #' + CONVERT(NVARCHAR(20),e.evidence_type_id)) EvidenceType,e.is_mandatory Mandatory,
    e.collection_method_id CollectionMethodId,cm.collection_method_name CollectionMethod,
    e.collection_frequency_id CollectionFrequencyId,f.frequency_name CollectionFrequency,
    e.evidence_owner EvidenceOwner,e.assurance_type_id AssuranceTypeId,at.assurance_type_name AssuranceTypeName,
    e.retention_period RetentionPeriod,e.record_status_id StatusId,COALESCE(rs.status_name,e.status) Status,et.display_order DisplayOrder
  FROM grac_practice.practice_instance_evidence e
  LEFT JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=e.evidence_type_id
  LEFT JOIN grac_practice.collection_method_master cm ON cm.collection_method_id=e.collection_method_id
  LEFT JOIN grac_practice.assurance_type_master at ON at.assurance_type_id=e.assurance_type_id
  LEFT JOIN grac_practice.frequency_master f ON f.frequency_id=e.collection_frequency_id
  LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=e.record_status_id
   WHERE (@p_id=0 OR e.evidence_id=@p_id) AND (@practice_instance_id IS NULL OR e.practice_instance_id=@practice_instance_id)
     AND (@organization_id IS NULL OR e.organization_id=@organization_id)
     AND (@p_status='' OR e.status=@p_status OR rs.status_code=@p_status OR rs.status_name=@p_status)
     AND (@owner IS NULL OR e.evidence_owner LIKE '%'+@owner+'%')
    AND (@p_search='' OR et.evidence_type_name LIKE '%'+@p_search+'%' OR e.evidence_owner LIKE '%'+@p_search+'%' OR cm.collection_method_name LIKE '%'+@p_search+'%' OR f.frequency_name LIKE '%'+@p_search+'%')
  ORDER BY COALESCE(et.display_order,999),COALESCE(et.evidence_type_name,N'Evidence Type #' + CONVERT(NVARCHAR(20),e.evidence_type_id)) OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='evidence-obligations'
 BEGIN
   /* ── View Obligations  (updated 2026-07-06) ──────────────────────────
      Uses the current obligation model:
        GRAC_New.obligation_requirement_release_map  (mapping)
        GRAC_New.requirement_obligation              (obligation master)
        GRAC_New.requirement_obligation_evidence      (evidence per obligation)
      Legacy tables obligation / obligation_evidence_type are no longer used.
   ──────────────────────────────────────────────────────────────────────── */
   ;WITH context_requirement AS (
     SELECT DISTINCT
       req.organization_requirement_id,
       req.organization_id,
       COALESCE(req.repository_requirement_id,repo_req.requirement_id) repository_requirement_id,
       req.org_statement_id,
       req.organization_control_id,
       oc.repository_control_id,
       COALESCE(ofs.release_id,oc.release_id) context_release_id
     FROM grac_practice.organization_requirement req
     LEFT JOIN grac_practice.organization_framework_statements ofs
       ON ofs.org_statement_id=req.org_statement_id AND ofs.organization_id=req.organization_id
     LEFT JOIN grac_practice.organization_control oc
       ON oc.organization_control_id=req.organization_control_id AND oc.organization_id=req.organization_id
     LEFT JOIN GRAC_New.requirement repo_req
       ON repo_req.requirement_code=req.requirement_code AND repo_req.status='Active'
     WHERE (@organization_requirement_id IS NOT NULL AND req.organization_requirement_id=@organization_requirement_id)
        OR (@practice_id IS NOT NULL AND EXISTS(
          SELECT 1 FROM grac_practice.practice p
          WHERE p.practice_id=@practice_id AND p.organization_requirement_id=req.organization_requirement_id))
        OR (@practice_instance_id IS NOT NULL AND EXISTS(
          SELECT 1 FROM grac_practice.practice_instance pi
          JOIN grac_practice.practice p ON p.practice_id=pi.practice_id
          WHERE pi.practice_instance_id=@practice_instance_id AND p.organization_requirement_id=req.organization_requirement_id))
   ),
   /* Deduplicate: context_requirement may produce multiple rows with the same
      repository_requirement_id (via different org_statement / org_control paths).
      The CROSS JOIN below would multiply evidence rows without this step. */
   distinct_requirements AS (
     SELECT DISTINCT repository_requirement_id, organization_id
     FROM context_requirement
     WHERE repository_requirement_id IS NOT NULL
   ),
   /* Step 1: Get DISTINCT obligation_ids mapped to any requirement+release.
      No CROSS JOIN with releases — avoids multiplying evidence rows. */
   distinct_obligations AS (
     SELECT DISTINCT orm.obligation_id
     FROM distinct_requirements dr
     JOIN GRAC_New.obligation_requirement_release_map orm
       ON orm.requirement_id=dr.repository_requirement_id AND orm.status='Active'
   )
   /* Step 2: For each obligation, get evidence ONLY by obligation_id.
      Release info via OUTER APPLY (one representative release, no multiplication). */
   SELECT
     rel.release_id FrameworkReleaseId,
     rel.FrameworkRelease,
     o.obligation_id ObligationId,
     COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)),N''),LEFT(o.obligation_text,300)) ObligationName,
     COALESCE(exec_freq.option_label,o.frequency_type) ExecutionFrequency,
     o.retention_requirement ObligationRetention,
     o.approval_authority ApprovalAuthority,
     o.responsibility Responsibility,
     roe.obligation_evidence_id EvidenceId,
     roe.evidence_type_id EvidenceTypeId,
     et.evidence_type_name EvidenceType,
     f.frequency_id FrequencyId,
     COALESCE(f.frequency_name,cm_freq.option_label) Frequency,
     roe.retention_requirement RetentionRequirement,
     roe.remarks Remarks
   FROM distinct_obligations dob
   JOIN GRAC_New.requirement_obligation o
     ON o.obligation_id=dob.obligation_id AND o.status='Active'
   JOIN GRAC_New.requirement_obligation_evidence roe
     ON roe.obligation_id=o.obligation_id AND roe.status='Active'
   JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=roe.evidence_type_id
   LEFT JOIN GRAC_New.reference_option exec_freq ON exec_freq.reference_option_id=o.execution_frequency_id
   LEFT JOIN GRAC_New.reference_option cm_freq ON cm_freq.reference_option_id=roe.frequency_id
   OUTER APPLY (
     SELECT TOP 1 f2.frequency_id,f2.frequency_name
     FROM grac_practice.frequency_master f2
     WHERE f2.frequency_code=cm_freq.option_value OR f2.frequency_name=cm_freq.option_label
   ) f
   /* One representative release per obligation (no row multiplication) */
   OUTER APPLY (
     SELECT TOP 1 r.release_id,
       COALESCE(a.artifact_code + N' ' + r.version_no,a.artifact_name + N' ' + r.version_no,r.version_no) FrameworkRelease
     FROM distinct_requirements dr2
     JOIN GRAC_New.obligation_requirement_release_map orm2
       ON orm2.requirement_id=dr2.repository_requirement_id AND orm2.obligation_id=dob.obligation_id AND orm2.status='Active'
     JOIN GRAC_New.release r ON r.release_id=orm2.release_id
     LEFT JOIN GRAC_New.artifact a ON a.artifact_id=r.artifact_id
   ) rel
   WHERE (@p_search='' OR et.evidence_type_name LIKE '%'+@p_search+'%'
          OR ISNULL(rel.FrameworkRelease,'') LIKE '%'+@p_search+'%'
          OR ISNULL(o.obligation_name,'') LIKE '%'+@p_search+'%')
   ORDER BY rel.FrameworkRelease,et.display_order,et.evidence_type_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='evidence-alignments'
   SELECT ea.evidence_alignment_id Id,ea.practice_instance_id PracticeInstanceId,ea.framework_release_id FrameworkReleaseId,
     COALESCE(a.artifact_code + N' ' + r.version_no,a.artifact_name + N' ' + r.version_no,r.version_no) FrameworkRelease,
     eas.alignment_status_name AlignmentStatus,ea.alignment_reason AlignmentReason,ea.calculated_dt CalculatedDate
   FROM grac_practice.practice_instance_evidence_alignment ea
   JOIN grac_practice.evidence_alignment_status_master eas ON eas.alignment_status_id=ea.alignment_status_id
   LEFT JOIN GRAC_New.release r ON r.release_id=ea.framework_release_id
   LEFT JOIN GRAC_New.artifact a ON a.artifact_id=r.artifact_id
   WHERE (@practice_instance_id IS NULL OR ea.practice_instance_id=@practice_instance_id)
     AND ea.status='Active'
   ORDER BY FrameworkRelease;
 ELSE IF @p_entity_type='repository-subscription-tree'
   SELECT au.authority_id AuthorityId,au.authority_code AuthorityCode,au.authority_name AuthorityName,
     a.artifact_id ArtifactId,a.artifact_code ArtifactCode,a.artifact_name ArtifactName,
     r.release_id ReleaseId,r.version_no ReleaseVersion,r.status ReleaseStatus,
     CASE WHEN s.subscription_id IS NOT NULL AND s.status='Active' AND s.subscription_status='Active' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END IsSubscribed
   FROM grac_new.authority au
   JOIN grac_new.artifact a ON a.authority_id=au.authority_id AND a.status='Active'
   JOIN grac_new.release r ON r.artifact_id=a.artifact_id AND r.status IN ('Draft','Active')
   LEFT JOIN grac_practice.repository_subscription s ON s.organization_id=@organization_id AND s.release_id=r.release_id AND s.status='Active'
    WHERE au.status='Active'
    ORDER BY au.authority_code,a.artifact_code,r.version_no;
 ELSE IF @p_entity_type='menu-master'
   SELECT menu_id Id,menu_key MenuKey,menu_name MenuName,menu_url MenuUrl,parent_menu_id ParentMenuId,
     display_order DisplayOrder,icon_class IconClass,module_type ModuleType,status Status
   FROM grac_practice.menu_master
   WHERE status='Active'
   ORDER BY display_order,menu_name;
 ELSE IF @p_entity_type='assurance-dashboard'
 BEGIN
   ;WITH eligible AS (
     SELECT pi.organization_id,pi.practice_instance_id
     FROM grac_practice.practice_instance pi
     JOIN grac_practice.practice_operationalization po ON po.practice_instance_id=pi.practice_instance_id AND po.organization_id=pi.organization_id AND po.status=N'Resolved'
     WHERE (@organization_id IS NULL OR pi.organization_id=@organization_id)
       AND pi.status=N'Active'
       AND NULLIF(pi.primary_owner,N'') IS NOT NULL
       AND (pi.department_id IS NOT NULL OR NULLIF(pi.department,N'') IS NOT NULL)
       AND EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status=N'Active' AND NULLIF(e.evidence_location,N'') IS NOT NULL AND NULLIF(e.evidence_locator,N'') IS NOT NULL)
       AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_dependency d WHERE d.practice_instance_id=pi.practice_instance_id AND d.status=N'Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_dependency_resolution r WHERE r.practice_instance_id=pi.practice_instance_id AND r.dependency_type_id=d.dependency_type_id AND r.is_active=1 AND r.resolution_status=N'Resolved'))
   )
   SELECT N'Eligible Practice Instances' Metric,COUNT_BIG(1) Value,N'Info' Severity,N'Resolved practice instances ready for assurance.' Message FROM eligible
   UNION ALL SELECT N'Pending Activities',COUNT_BIG(1),N'High',N'Assurance activities awaiting execution.' FROM grac_practice.assurance_activity WHERE (@organization_id IS NULL OR organization_id=@organization_id) AND status=N'Pending'
   UNION ALL SELECT N'Overdue Activities',COUNT_BIG(1),N'High',N'Assurance activities past due date.' FROM grac_practice.assurance_activity WHERE (@organization_id IS NULL OR organization_id=@organization_id) AND status NOT IN (N'Completed') AND due_dt<CONVERT(DATE,SYSUTCDATETIME())
   UNION ALL SELECT N'Open Findings',COUNT_BIG(1),N'High',N'Findings requiring closure.' FROM grac_practice.assurance_finding WHERE (@organization_id IS NULL OR organization_id=@organization_id) AND finding_status NOT IN (N'Closed',N'Resolved')
   UNION ALL SELECT N'Open Signals',COUNT_BIG(1),N'Medium',N'Active assurance intelligence signals.' FROM grac_practice.assurance_signal WHERE (@organization_id IS NULL OR organization_id=@organization_id) AND signal_status<>N'Closed';
 END
 ELSE IF @p_entity_type='assurance-generation'
 BEGIN
   SELECT pi.practice_instance_id Id,pi.organization_id OrganizationId,pi.instance_code+N' - '+pi.instance_name PracticeInstance,
     pi.assurance_frequency_id AssuranceFrequencyId,COALESCE(freq.frequency_name,pi.frequency_type,N'Not Set') AssuranceFrequency,
     at.assurance_type_name AssuranceType,pi.criticality Criticality,
     CASE WHEN aa.assurance_activity_id IS NULL THEN N'Eligible' ELSE N'Already Generated' END EligibilityStatus,
     COALESCE(MAX(aa.period_to),CONVERT(DATE,pi.entered_dt)) LastAssurancePeriodTo,
     DATEADD(DAY,30,COALESCE(MAX(aa.period_to),CONVERT(DATE,pi.entered_dt))) NextDueDate,
     CASE WHEN aa.assurance_activity_id IS NULL THEN N'Ready' ELSE N'Skip' END ActionStatus
   FROM grac_practice.practice_instance pi
   JOIN grac_practice.practice_operationalization po ON po.practice_instance_id=pi.practice_instance_id AND po.organization_id=pi.organization_id AND po.status=N'Resolved'
   LEFT JOIN grac_practice.frequency_master freq ON freq.frequency_id=pi.assurance_frequency_id
   LEFT JOIN grac_practice.assurance_type_master at ON at.assurance_type_name=pi.assurance_mode OR at.assurance_type_code=pi.assurance_mode
   LEFT JOIN grac_practice.assurance_activity aa ON aa.practice_instance_id=pi.practice_instance_id AND aa.organization_id=pi.organization_id AND aa.status<>N'Completed'
   WHERE (@organization_id IS NULL OR pi.organization_id=@organization_id)
     AND pi.status=N'Active'
     AND (@p_id=0 OR pi.practice_instance_id=@p_id)
     AND (@p_search='' OR pi.instance_code LIKE '%'+@p_search+'%' OR pi.instance_name LIKE '%'+@p_search+'%')
     AND NULLIF(pi.primary_owner,N'') IS NOT NULL
     AND (pi.department_id IS NOT NULL OR NULLIF(pi.department,N'') IS NOT NULL)
     AND EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status=N'Active' AND NULLIF(e.evidence_location,N'') IS NOT NULL AND NULLIF(e.evidence_locator,N'') IS NOT NULL)
     AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_dependency d WHERE d.practice_instance_id=pi.practice_instance_id AND d.status=N'Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_dependency_resolution r WHERE r.practice_instance_id=pi.practice_instance_id AND r.dependency_type_id=d.dependency_type_id AND r.is_active=1 AND r.resolution_status=N'Resolved'))
   GROUP BY pi.practice_instance_id,pi.organization_id,pi.instance_code,pi.instance_name,pi.assurance_frequency_id,freq.frequency_name,pi.frequency_type,at.assurance_type_name,pi.criticality,aa.assurance_activity_id,pi.entered_dt
   ORDER BY NextDueDate OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='assurance-activities'
   SELECT aa.assurance_activity_id Id,aa.organization_id OrganizationId,aa.practice_instance_id PracticeInstanceId,aa.activity_number ActivityNumber,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,aa.period_from PeriodFrom,aa.period_to PeriodTo,
     aa.assurance_type AssuranceType,aa.activity_owner ActivityOwner,aa.created_dt CreatedDate,aa.due_dt DueDate,aa.status Status
   FROM grac_practice.assurance_activity aa
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=aa.practice_instance_id
   WHERE (@organization_id IS NULL OR aa.organization_id=@organization_id)
     AND (@p_id=0 OR aa.assurance_activity_id=@p_id)
     AND (@p_status='' OR aa.status=@p_status)
     AND (@p_search='' OR aa.activity_number LIKE '%'+@p_search+'%' OR pi.instance_name LIKE '%'+@p_search+'%')
   ORDER BY aa.due_dt DESC,aa.assurance_activity_id DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='assurance-execution'
   SELECT ex.assurance_execution_id Id,aa.assurance_activity_id ActivityId,aa.organization_id OrganizationId,aa.activity_number ActivityNumber,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,ex.execution_dt ExecutionDate,ex.executor_name Executor,
     ex.evidence_status EvidenceStatus,ex.dependency_status DependencyStatus,ex.result_status ResultStatus,aa.status Status
   FROM grac_practice.assurance_execution ex
   JOIN grac_practice.assurance_activity aa ON aa.assurance_activity_id=ex.assurance_activity_id
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=aa.practice_instance_id
   WHERE (@organization_id IS NULL OR aa.organization_id=@organization_id) AND (@assurance_activity_id IS NULL OR aa.assurance_activity_id=@assurance_activity_id) AND (@p_id=0 OR ex.assurance_execution_id=@p_id)
   ORDER BY ex.execution_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='evidence-assurance'
   SELECT ec.evidence_check_id Id,aa.assurance_activity_id ActivityId,aa.activity_number ActivityNumber,aa.organization_id OrganizationId,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,ec.evidence_type_name EvidenceType,
     CASE WHEN ec.evidence_exists=1 THEN N'Yes' ELSE N'No' END EvidenceExists,
     CASE WHEN ec.evidence_accessible=1 THEN N'Yes' ELSE N'No' END EvidenceAccessible,
     CASE WHEN ec.matches_expected_type=1 THEN N'Yes' ELSE N'No' END MatchesExpectedType,
     CASE WHEN ec.relates_to_assurance=1 THEN N'Yes' ELSE N'No' END RelatesToAssurance,
     ec.result_status ResultStatus
   FROM grac_practice.assurance_evidence_check ec
   JOIN grac_practice.assurance_activity aa ON aa.assurance_activity_id=ec.assurance_activity_id
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=aa.practice_instance_id
   WHERE (@organization_id IS NULL OR aa.organization_id=@organization_id) AND (@assurance_activity_id IS NULL OR aa.assurance_activity_id=@assurance_activity_id) AND (@p_id=0 OR ec.evidence_check_id=@p_id)
   ORDER BY ec.entered_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='dependency-assurance'
   SELECT dc.dependency_check_id Id,aa.assurance_activity_id ActivityId,aa.activity_number ActivityNumber,aa.organization_id OrganizationId,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,dc.dependency_type_name DependencyType,dc.resolved_dependency_name ResolvedDependency,
     CASE WHEN dc.dependency_available=1 THEN N'Yes' ELSE N'No' END DependencyAvailable,
     CASE WHEN dc.dependency_current=1 THEN N'Yes' ELSE N'No' END DependencyCurrent,
     dc.result_status ResultStatus
   FROM grac_practice.assurance_dependency_check dc
   JOIN grac_practice.assurance_activity aa ON aa.assurance_activity_id=dc.assurance_activity_id
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=aa.practice_instance_id
   WHERE (@organization_id IS NULL OR aa.organization_id=@organization_id) AND (@assurance_activity_id IS NULL OR aa.assurance_activity_id=@assurance_activity_id) AND (@p_id=0 OR dc.dependency_check_id=@p_id)
   ORDER BY dc.entered_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='assurance-results'
   SELECT ar.assurance_result_id Id,aa.assurance_activity_id ActivityId,aa.activity_number ActivityNumber,aa.organization_id OrganizationId,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,ar.result_status ResultStatus,ar.operating_effectiveness OperatingEffectiveness,
     ar.completed_dt CompletedDate,ar.completed_by CompletedBy
   FROM grac_practice.assurance_result ar
   JOIN grac_practice.assurance_activity aa ON aa.assurance_activity_id=ar.assurance_activity_id
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=aa.practice_instance_id
   WHERE (@organization_id IS NULL OR aa.organization_id=@organization_id) AND (@assurance_activity_id IS NULL OR aa.assurance_activity_id=@assurance_activity_id) AND (@p_id=0 OR ar.assurance_result_id=@p_id)
   ORDER BY ar.entered_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='assurance-findings'
   SELECT f.finding_id Id,f.organization_id OrganizationId,f.assurance_activity_id ActivityId,f.finding_number FindingNumber,aa.activity_number ActivityNumber,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,f.severity Severity,f.finding_status FindingStatus,f.owner_name Owner,f.due_dt DueDate
   FROM grac_practice.assurance_finding f
   JOIN grac_practice.assurance_activity aa ON aa.assurance_activity_id=f.assurance_activity_id
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=f.practice_instance_id
   WHERE (@organization_id IS NULL OR f.organization_id=@organization_id) AND (@assurance_activity_id IS NULL OR f.assurance_activity_id=@assurance_activity_id) AND (@p_id=0 OR f.finding_id=@p_id)
   ORDER BY f.entered_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='assurance-signals'
   SELECT s.signal_id Id,s.organization_id OrganizationId,s.assurance_activity_id ActivityId,s.signal_type SignalType,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,s.severity Severity,s.signal_status SignalStatus,s.detected_dt DetectedDate,s.message Message
   FROM grac_practice.assurance_signal s
   LEFT JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=s.practice_instance_id
   WHERE (@organization_id IS NULL OR s.organization_id=@organization_id) AND (@assurance_activity_id IS NULL OR s.assurance_activity_id=@assurance_activity_id) AND (@p_id=0 OR s.signal_id=@p_id)
   ORDER BY s.detected_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='assurance-trends'
   SELECT pi.practice_instance_id Id,pi.organization_id OrganizationId,pi.instance_code+N' - '+pi.instance_name PracticeInstance,
     N'Activity Completion' TrendType,
     SUM(CASE WHEN aa.status=N'Completed' THEN 1 ELSE 0 END) CurrentValue,
     COUNT_BIG(aa.assurance_activity_id) PreviousValue,
     CASE WHEN COUNT_BIG(aa.assurance_activity_id)=0 THEN N'No Data' WHEN SUM(CASE WHEN aa.status=N'Completed' THEN 1 ELSE 0 END)=COUNT_BIG(aa.assurance_activity_id) THEN N'Improving' ELSE N'Watch' END TrendDirection,
     CASE WHEN SUM(CASE WHEN aa.status=N'Completed' THEN 1 ELSE 0 END)=COUNT_BIG(aa.assurance_activity_id) THEN N'Low' ELSE N'Medium' END Severity
   FROM grac_practice.practice_instance pi
   LEFT JOIN grac_practice.assurance_activity aa ON aa.practice_instance_id=pi.practice_instance_id
   WHERE (@organization_id IS NULL OR pi.organization_id=@organization_id) AND pi.status=N'Active'
   GROUP BY pi.practice_instance_id,pi.organization_id,pi.instance_code,pi.instance_name
   ORDER BY PracticeInstance OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type IN ('practice-health','audit-intelligence','risk-intelligence')
   SELECT pi.practice_instance_id Id,pi.organization_id OrganizationId,pi.instance_code+N' - '+pi.instance_name PracticeInstance,
     CASE WHEN @p_entity_type='practice-health' THEN CAST(100-COUNT(DISTINCT f.finding_id)*15 AS NVARCHAR(40)) ELSE COALESCE(MAX(ar.result_status),N'Not Assured') END HealthScore,
     CASE WHEN COUNT(DISTINCT f.finding_id)=0 THEN N'Healthy' WHEN COUNT(DISTINCT f.finding_id)<3 THEN N'Watch' ELSE N'At Risk' END HealthStatus,
     pi.criticality Criticality,MAX(aa.period_to) LastAssuredDate,COUNT(DISTINCT f.finding_id) OpenFindings,
     COALESCE(MAX(ar.result_status),N'Not Assured') LastAssuranceResult,
     CASE WHEN EXISTS(SELECT 1 FROM grac_practice.assurance_evidence_check ec WHERE ec.practice_instance_id=pi.practice_instance_id AND ec.result_status=N'Fail') THEN N'Failed' WHEN EXISTS(SELECT 1 FROM grac_practice.assurance_evidence_check ec WHERE ec.practice_instance_id=pi.practice_instance_id AND ec.result_status=N'Pass') THEN N'Passed' ELSE N'Not Checked' END EvidenceStatus,
     CASE WHEN @p_entity_type='audit-intelligence' THEN N'Practice Instance Operation' ELSE N'Assurance / Operational Risk' END AuditableArea,
     CASE WHEN @p_entity_type='risk-intelligence' AND COUNT(DISTINCT f.finding_id)>0 THEN N'Open finding risk' ELSE N'No active risk signal' END RiskSignal,
     CASE WHEN pi.criticality IN (N'Critical',N'High') OR COUNT(DISTINCT f.finding_id)>0 THEN N'High' ELSE N'Medium' END AuditPriority,
     CASE WHEN pi.criticality IN (N'Critical',N'High') OR COUNT(DISTINCT f.finding_id)>0 THEN N'High' ELSE N'Medium' END RiskPriority
   FROM grac_practice.practice_instance pi
   LEFT JOIN grac_practice.assurance_activity aa ON aa.practice_instance_id=pi.practice_instance_id
   LEFT JOIN grac_practice.assurance_result ar ON ar.assurance_activity_id=aa.assurance_activity_id
   LEFT JOIN grac_practice.assurance_finding f ON f.practice_instance_id=pi.practice_instance_id AND f.finding_status NOT IN (N'Closed',N'Resolved')
   WHERE (@organization_id IS NULL OR pi.organization_id=@organization_id) AND pi.status=N'Active'
   GROUP BY pi.practice_instance_id,pi.organization_id,pi.instance_code,pi.instance_name,pi.criticality
   ORDER BY OpenFindings DESC,PracticeInstance OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type IN ('applicability-discovery','applicability-results','repository-import','requirement-applicability',
   'assurance-attributes','vendor-attributes','risk-attributes','audit-attributes','task-attributes','resilience-attributes','future-triggers')
   SELECT CAST(NULL AS BIGINT) Id,CAST('Configured in upcoming phase' AS NVARCHAR(200)) Message WHERE 1=0;
 ELSE IF @p_entity_type='audit-trace'
   SELECT audit_trace_id Id,entity_type EntityType,entity_id EntityId,action_type ActionType,status Status,entered_by EnteredBy,entered_dt EnteredDt
   FROM grac_practice.practice_audit_trace
   WHERE (@p_status='' OR status=@p_status)
     AND (@date_from IS NULL OR entered_dt>=@date_from) AND (@date_to IS NULL OR entered_dt<DATEADD(DAY,1,@date_to))
   ORDER BY entered_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='assurance-schedule-rules'
   SELECT r.schedule_rule_id Id,r.organization_id OrganizationId,r.practice_instance_id PracticeInstanceId,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,
     r.frequency_id FrequencyId,fm.frequency_name FrequencyName,fm.frequency_value FrequencyValue,fm.frequency_unit FrequencyUnit,
     r.anchor_date AnchorDate,r.end_date EndDate,r.schedule_owner ScheduleOwner,r.notes Notes,r.is_active IsActive,r.status Status
   FROM grac_practice.assurance_schedule_rule r
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=r.practice_instance_id
   JOIN grac_practice.frequency_master fm ON fm.frequency_id=r.frequency_id
   WHERE (@organization_id IS NULL OR r.organization_id=@organization_id) AND r.status=N'Active'
     AND (@p_id=0 OR r.schedule_rule_id=@p_id)
   ORDER BY pi.instance_name;
 ELSE IF @p_entity_type='assurance-schedule-overrides'
   SELECT o.override_id Id,o.schedule_rule_id ScheduleRuleId,o.organization_id OrganizationId,
     o.original_date OriginalDate,o.override_type OverrideType,o.new_date NewDate,
     o.reason Reason,o.apply_to_future ApplyToFuture,o.override_by OverrideBy,o.status Status,o.entered_dt EnteredDt
   FROM grac_practice.assurance_schedule_override o
   WHERE (@organization_id IS NULL OR o.organization_id=@organization_id) AND o.status=N'Active'
     AND (@p_id=0 OR o.override_id=@p_id)
   ORDER BY o.original_date;
 ELSE IF @p_entity_type='assurance-calendar-config'
   SELECT c.config_id Id,c.organization_id OrganizationId,c.look_back_months LookBackMonths,
     c.look_ahead_months LookAheadMonths,c.default_view DefaultView,c.status Status
   FROM grac_practice.assurance_calendar_config c
   WHERE (@organization_id IS NULL OR c.organization_id=@organization_id);
 ELSE THROW 51002,'Unsupported practice area',1;
END
GO

-- 2026-09-16: Reason / Justification stopped being erased on Applicable.
-- Every organization-requirements/practices save branch below used to run
-- `exclusion_justification = CASE WHEN <status>='Applicable' THEN NULL ELSE
-- ... END` -- so a previously entered reason vanished from the database the
-- moment a record was (re)marked Applicable, even if the save itself never
-- touched that field. Reported by sir: "owner is now ok [separate, already-
-- fixed issue], but Reason / Justification not displayed" on Practices ->
-- Update Applicability for a record whose status was Applicable. Confirmed
-- with sir this is a genuine behaviour change (not "keep as-is"): the save
-- no longer nulls the column for Applicable, only merges in whatever new
-- value the client sends (COALESCE(@new, existing) -- an empty/blank
-- payload value already normalizes to NULL above via NULLIF, so it falls
-- through to the existing value instead of erasing it). The client side
-- (practice.js) now disables -- not hides -- the Reason/Justification input
-- whenever Applicable is selected, so no NEW reason can be typed while
-- Applicable, but whatever was saved before still displays on reopen. Scope
-- is organization-requirements + practices only, per sir's answer --
-- organization-controls/control-applicability (lines below, unchanged)
-- keep their original clear-on-Applicable behaviour; ask before extending
-- this there too.
CREATE OR ALTER PROCEDURE dbo.pm_manage_practice_repository
 @p_entity_type NVARCHAR(100), @p_action NVARCHAR(30), @p_id BIGINT=0, @p_search NVARCHAR(250)='', @p_status NVARCHAR(30)='',
 @p_payload NVARCHAR(MAX)='{}', @p_usr_id NVARCHAR(100)=''
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
 SET @p_entity_type=ISNULL(@p_entity_type,'');
 SET @p_action=ISNULL(@p_action,'');
 SET @p_search=ISNULL(@p_search,'');
 SET @p_status=ISNULL(@p_status,'');
 SET @p_payload=ISNULL(NULLIF(@p_payload,''),'{}');
 SET @p_usr_id=ISNULL(@p_usr_id,'');
 DECLARE @new_id BIGINT=@p_id;
 DECLARE @result_message NVARCHAR(500)=N'Saved successfully.';
 IF NULLIF(@p_usr_id,'') IS NULL SET @p_usr_id='system';
 DECLARE @active_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code='Active');
 DECLARE @inactive_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code='Inactive');
 DECLARE @active_subscription_status_id INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code='Active');
 DECLARE @disabled_subscription_status_id INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code='Disabled');
 DECLARE @not_updated_applicability_status_id INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Not Updated');
 DECLARE @not_started_implementation_status_id INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code='Not Started');
 DECLARE @active_implementation_status_id INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code='Active');
 DECLARE @payload_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.status') OR status_name=JSON_VALUE(@p_payload,'$.status'));
 DECLARE @payload_record_status_id_from_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.statusId'),''));
 SET @payload_record_status_id=COALESCE(@payload_record_status_id_from_id,@payload_record_status_id);
 DECLARE @payload_subscription_status_id INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.subscriptionStatus') OR status_name=JSON_VALUE(@p_payload,'$.subscriptionStatus'));
 DECLARE @payload_applicability_status_id INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.applicabilityStatus') OR status_name=JSON_VALUE(@p_payload,'$.applicabilityStatus'));
 DECLARE @payload_implementation_status_id INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.implementationStatus') OR status_name=JSON_VALUE(@p_payload,'$.implementationStatus'));
 DECLARE @is_system_admin BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$._security.isSystemAdmin'),'false')) IN ('true','1','yes') THEN 1 ELSE 0 END;
 DECLARE @allowed_organizations TABLE(organization_id BIGINT PRIMARY KEY);
 INSERT @allowed_organizations(organization_id)
 SELECT DISTINCT organization_id
 FROM grac_practice.user_organization_map
 WHERE user_email=@p_usr_id
   AND status='Active'
   AND record_status_id=@active_record_status_id;
 INSERT @allowed_organizations(organization_id)
 SELECT DISTINCT e.organization_id
 FROM grac_practice.organization_employee e
 WHERE e.status='Active'
   AND (e.email=@p_usr_id OR e.employee_code=@p_usr_id)
   AND NOT EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=e.organization_id);
 DECLARE @requested_organization_id BIGINT=COALESCE(
   TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),'')),
   TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organization.id'),''))
 );
 IF @requested_organization_id IS NOT NULL
    AND @is_system_admin=0
    AND NOT EXISTS(SELECT 1 FROM @allowed_organizations WHERE organization_id=@requested_organization_id)
   THROW 51052,'You do not have access to the selected organization.',1;

 IF @p_action='RETIRE'
 BEGIN
   DECLARE @retire_organization_id BIGINT=NULL;
   IF @p_entity_type='organizations' SET @retire_organization_id=@p_id;
   ELSE IF @p_entity_type='divisions' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_division WHERE division_id=@p_id;
   ELSE IF @p_entity_type='locations' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_location WHERE location_id=@p_id;
   ELSE IF @p_entity_type='departments' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_department WHERE department_id=@p_id;
   ELSE IF @p_entity_type='teams' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_team WHERE team_id=@p_id;
   ELSE IF @p_entity_type='committees' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_committee WHERE committee_id=@p_id;
   ELSE IF @p_entity_type='business-functions' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_business_function WHERE business_function_id=@p_id;
   ELSE IF @p_entity_type='roles' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_role WHERE role_id=@p_id;
   ELSE IF @p_entity_type='role-menu-permissions' SELECT @retire_organization_id=r.organization_id FROM grac_practice.organization_role_menu_permission p JOIN grac_practice.organization_role r ON r.role_id=p.role_id WHERE p.role_menu_permission_id=@p_id;
   ELSE IF @p_entity_type='users' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_employee WHERE employee_id=@p_id;
   ELSE IF @p_entity_type='dependency-applications' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_dependency_application WHERE application_id=@p_id;
   ELSE IF @p_entity_type='dependency-tools' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_dependency_tool WHERE tool_id=@p_id;
   ELSE IF @p_entity_type='dependency-vendors' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_dependency_vendor WHERE vendor_id=@p_id;
   ELSE IF @p_entity_type='dependency-assets' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_dependency_asset WHERE asset_id=@p_id;
   ELSE IF @p_entity_type='dependency-processes' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_dependency_process WHERE process_id=@p_id;
   ELSE IF @p_entity_type='organization-controls' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_control WHERE organization_control_id=@p_id;
   ELSE IF @p_entity_type='organization-requirements' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_requirement WHERE organization_requirement_id=@p_id;
   ELSE IF @p_entity_type='repository-subscriptions' SELECT @retire_organization_id=organization_id FROM grac_practice.repository_subscription WHERE subscription_id=@p_id;
   ELSE IF @p_entity_type='practices' SELECT @retire_organization_id=organization_id FROM grac_practice.practice WHERE practice_id=@p_id;
   ELSE IF @p_entity_type='practice-instances' SELECT @retire_organization_id=organization_id FROM grac_practice.practice_instance WHERE practice_instance_id=@p_id;
   ELSE IF @p_entity_type='dependencies' SELECT @retire_organization_id=organization_id FROM grac_practice.practice_instance_dependency WHERE dependency_id=@p_id;
   ELSE IF @p_entity_type='practice-dependency-resolutions' SELECT @retire_organization_id=organization_id FROM grac_practice.practice_dependency_resolution WHERE resolution_id=@p_id;
   ELSE IF @p_entity_type='evidence-configurations' SELECT @retire_organization_id=organization_id FROM grac_practice.practice_instance_evidence WHERE evidence_id=@p_id;
   IF @retire_organization_id IS NULL
     THROW 51054,'Selected record was not found or is no longer available.',1;
   IF @is_system_admin=0
      AND NOT EXISTS(SELECT 1 FROM @allowed_organizations WHERE organization_id=@retire_organization_id)
     THROW 51052,'You do not have access to the selected organization.',1;

   IF @p_entity_type='organizations' UPDATE grac_practice.organization SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE organization_id=@p_id;
   ELSE IF @p_entity_type='divisions' UPDATE grac_practice.organization_division SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE division_id=@p_id;
   ELSE IF @p_entity_type='locations' UPDATE grac_practice.organization_location SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE location_id=@p_id;
   ELSE IF @p_entity_type='departments' UPDATE grac_practice.organization_department SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE department_id=@p_id;
   ELSE IF @p_entity_type='teams' UPDATE grac_practice.organization_team SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE team_id=@p_id;
   ELSE IF @p_entity_type='committees' UPDATE grac_practice.organization_committee SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE committee_id=@p_id;
   ELSE IF @p_entity_type='business-functions' UPDATE grac_practice.organization_business_function SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE business_function_id=@p_id;
   ELSE IF @p_entity_type='roles' UPDATE grac_practice.organization_role SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE role_id=@p_id;
   ELSE IF @p_entity_type='role-menu-permissions' UPDATE grac_practice.organization_role_menu_permission SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE role_menu_permission_id=@p_id;
   ELSE IF @p_entity_type='users' UPDATE grac_practice.organization_employee SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE employee_id=@p_id;
   ELSE IF @p_entity_type='dependency-applications' UPDATE grac_practice.organization_dependency_application SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE application_id=@p_id;
   ELSE IF @p_entity_type='dependency-tools' UPDATE grac_practice.organization_dependency_tool SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE tool_id=@p_id;
   ELSE IF @p_entity_type='dependency-vendors' UPDATE grac_practice.organization_dependency_vendor SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE vendor_id=@p_id;
   ELSE IF @p_entity_type='dependency-assets' UPDATE grac_practice.organization_dependency_asset SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE asset_id=@p_id;
   ELSE IF @p_entity_type='dependency-processes' UPDATE grac_practice.organization_dependency_process SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE process_id=@p_id;
   ELSE IF @p_entity_type='organization-controls' UPDATE grac_practice.organization_control SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE organization_control_id=@p_id;
   ELSE IF @p_entity_type='organization-requirements' UPDATE grac_practice.organization_requirement SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE organization_requirement_id=@p_id;
   ELSE IF @p_entity_type='repository-subscriptions'
   BEGIN
     UPDATE grac_practice.repository_subscription SET status='Inactive',record_status_id=@inactive_record_status_id,subscription_status='Disabled',subscription_status_id=@disabled_subscription_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE subscription_id=@p_id;
     UPDATE oc SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     FROM grac_practice.organization_control oc
     JOIN grac_practice.repository_subscription s ON s.subscription_id=@p_id AND s.organization_id=oc.organization_id AND s.release_id=oc.release_id
     WHERE oc.is_manually_added=0;
   END
   ELSE IF @p_entity_type='practices' UPDATE grac_practice.practice SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE practice_id=@p_id;
   ELSE IF @p_entity_type='practice-instances' UPDATE grac_practice.practice_instance SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE practice_instance_id=@p_id;
   ELSE IF @p_entity_type='dependencies' UPDATE grac_practice.practice_instance_dependency SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE dependency_id=@p_id;
   ELSE IF @p_entity_type='practice-dependency-resolutions' UPDATE grac_practice.practice_dependency_resolution SET is_active=0,record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE resolution_id=@p_id;
   ELSE IF @p_entity_type='evidence-configurations' UPDATE grac_practice.practice_instance_evidence SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE evidence_id=@p_id;
   ELSE THROW 51003,'Retirement is not configured for this practice area',1;
 END
 ELSE IF @p_entity_type='organization-setup'
 BEGIN
   DECLARE @setup_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organization.id'),''));
   DECLARE @setup_org_code NVARCHAR(50)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.organization.code'))),'');
   DECLARE @setup_org_name NVARCHAR(250)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.organization.name'))),'');
   IF @setup_org_id IS NULL SET @setup_org_id=0;
   IF @is_system_admin=0
     THROW 51053,'You do not have permission to create a new organization.',1;
   IF @setup_org_code IS NULL THROW 51010,'Organization Code is required.',1;
   IF @setup_org_name IS NULL THROW 51011,'Organization Name is required.',1;
   IF @setup_org_id=0
   BEGIN
     INSERT grac_practice.organization(organization_code,organization_name,industry,entity_type,country,status,record_status_id,entered_by)
     VALUES(@setup_org_code,@setup_org_name,JSON_VALUE(@p_payload,'$.organization.industry'),JSON_VALUE(@p_payload,'$.organization.entityType'),JSON_VALUE(@p_payload,'$.organization.country'),COALESCE(JSON_VALUE(@p_payload,'$.organization.status'),'Active'),COALESCE((SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.organization.status') OR status_name=JSON_VALUE(@p_payload,'$.organization.status')),@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
     SET @new_id=@setup_org_id;
     UPDATE grac_practice.organization SET organization_code=@setup_org_code,organization_name=@setup_org_name,
       industry=JSON_VALUE(@p_payload,'$.organization.industry'),entity_type=JSON_VALUE(@p_payload,'$.organization.entityType'),country=JSON_VALUE(@p_payload,'$.organization.country'),
       status=COALESCE(JSON_VALUE(@p_payload,'$.organization.status'),status),
       record_status_id=COALESCE((SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.organization.status') OR status_name=JSON_VALUE(@p_payload,'$.organization.status')),record_status_id),
       updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE organization_id=@new_id;
     IF @@ROWCOUNT=0 THROW 51012,'Selected organization was not found or is no longer available.',1;
   END

   DECLARE @attrs TABLE(metadata_key NVARCHAR(120), raw_value NVARCHAR(MAX));
   INSERT @attrs(metadata_key,raw_value)
   SELECT j.[key],
     CASE WHEN j.[type] IN (4,5) THEN j.[value] ELSE CONVERT(NVARCHAR(MAX),j.[value]) END
   FROM OPENJSON(@p_payload,'$.attributes') j
   WHERE NULLIF(j.[key],'') IS NOT NULL;

   UPDATE v SET
     value_text=CASE WHEN d.data_type NOT IN ('Json','Boolean','Number','Date') THEN a.raw_value ELSE NULL END,
     value_number=CASE WHEN d.data_type='Number' THEN TRY_CONVERT(DECIMAL(18,4),a.raw_value) ELSE NULL END,
     value_date=CASE WHEN d.data_type='Date' THEN TRY_CONVERT(DATE,a.raw_value) ELSE NULL END,
     value_bool=CASE WHEN d.data_type='Boolean' THEN CASE WHEN LOWER(a.raw_value) IN ('true','1','yes','y') THEN CAST(1 AS BIT) WHEN LOWER(a.raw_value) IN ('false','0','no','n') THEN CAST(0 AS BIT) ELSE NULL END ELSE NULL END,
     value_json=CASE WHEN d.data_type='Json' THEN a.raw_value ELSE NULL END,
     status='Active',record_status_id=@active_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM grac_practice.organization_metadata_value v
   JOIN grac_practice.organization_metadata_definition d ON d.metadata_definition_id=v.metadata_definition_id
   JOIN @attrs a ON a.metadata_key=d.metadata_key
   WHERE v.organization_id=@new_id;

   INSERT grac_practice.organization_metadata_value(organization_id,metadata_definition_id,value_text,value_number,value_date,value_bool,value_json,status,record_status_id,entered_by)
   SELECT @new_id,d.metadata_definition_id,
     CASE WHEN d.data_type NOT IN ('Json','Boolean','Number','Date') THEN a.raw_value ELSE NULL END,
     CASE WHEN d.data_type='Number' THEN TRY_CONVERT(DECIMAL(18,4),a.raw_value) ELSE NULL END,
     CASE WHEN d.data_type='Date' THEN TRY_CONVERT(DATE,a.raw_value) ELSE NULL END,
     CASE WHEN d.data_type='Boolean' THEN CASE WHEN LOWER(a.raw_value) IN ('true','1','yes','y') THEN CAST(1 AS BIT) WHEN LOWER(a.raw_value) IN ('false','0','no','n') THEN CAST(0 AS BIT) ELSE NULL END ELSE NULL END,
     CASE WHEN d.data_type='Json' THEN a.raw_value ELSE NULL END,
     'Active',@active_record_status_id,@p_usr_id
   FROM @attrs a
   JOIN grac_practice.organization_metadata_definition d ON d.metadata_key=a.metadata_key
   WHERE NOT EXISTS(SELECT 1 FROM grac_practice.organization_metadata_value v WHERE v.organization_id=@new_id AND v.metadata_definition_id=d.metadata_definition_id);

   DECLARE @selected_releases TABLE(release_id BIGINT PRIMARY KEY);
   INSERT @selected_releases(release_id)
   SELECT DISTINCT TRY_CONVERT(BIGINT,[value]) FROM OPENJSON(@p_payload,'$.releaseIds') WHERE TRY_CONVERT(BIGINT,[value]) IS NOT NULL;

   IF EXISTS(
     SELECT 1
     FROM @selected_releases x
     WHERE NOT EXISTS(SELECT 1 FROM grac_new.release r WHERE r.release_id=x.release_id)
   )
     THROW 51013,'One or more selected repository releases are not available.',1;

   UPDATE s SET status='Inactive',record_status_id=@inactive_record_status_id,subscription_status='Disabled',subscription_status_id=@disabled_subscription_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM grac_practice.repository_subscription s
   WHERE s.organization_id=@new_id AND s.status='Active'
     AND NOT EXISTS(SELECT 1 FROM @selected_releases r WHERE r.release_id=s.release_id);

   UPDATE s SET status='Active',record_status_id=@active_record_status_id,subscription_status='Active',subscription_status_id=@active_subscription_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM grac_practice.repository_subscription s
   JOIN @selected_releases r ON r.release_id=s.release_id
   WHERE s.organization_id=@new_id AND s.status<>'Active';

   INSERT grac_practice.repository_subscription(organization_id,authority_id,artifact_id,release_id,subscription_type,subscription_status,subscription_status_id,effective_dt,status,record_status_id,entered_by)
   SELECT @new_id,a.authority_id,a.artifact_id,r.release_id,'Manual','Active',@active_subscription_status_id,CONVERT(DATE,SYSUTCDATETIME()),'Active',@active_record_status_id,@p_usr_id
   FROM @selected_releases x
   JOIN grac_new.release r ON r.release_id=x.release_id
   JOIN grac_new.artifact a ON a.artifact_id=r.artifact_id
   WHERE NOT EXISTS(SELECT 1 FROM grac_practice.repository_subscription s WHERE s.organization_id=@new_id AND s.release_id=r.release_id);

   ;WITH release_controls AS (
     SELECT DISTINCT
       scm.control_id,
       COALESCE(scm.release_id,n.release_id) release_id,
       COALESCE(scm.artifact_id,r.artifact_id) artifact_id
     FROM grac_new.source_control_map scm
     JOIN grac_new.source_structure_node n ON n.structure_node_id=scm.structure_node_id
     JOIN grac_new.release r ON r.release_id=n.release_id
     JOIN @selected_releases sr ON sr.release_id=COALESCE(scm.release_id,n.release_id)
     WHERE scm.status='Active' AND n.status='Active'
   ),
   repository_controls AS (
     SELECT
       rc.control_id,
       c.control_code,
       c.control_name,
       c.description,
       c.objective,
       c.control_domain_id,
       c.control_sub_domain_id,
       rc.release_id,
       rc.artifact_id,
       s.subscription_id
     FROM release_controls rc
     JOIN grac_new.control c ON c.control_id=rc.control_id AND c.status='Active'
     JOIN grac_practice.repository_subscription s ON s.organization_id=@new_id AND s.release_id=rc.release_id AND s.record_status_id=@active_record_status_id AND s.subscription_status_id=@active_subscription_status_id
   )
   UPDATE oc SET
     control_code=rc.control_code,
     control_name=rc.control_name,
     description=rc.description,
     objective=rc.objective,
     control_domain_id=rc.control_domain_id,
     control_sub_domain_id=rc.control_sub_domain_id,
     subscription_id=rc.subscription_id,
     artifact_id=rc.artifact_id,
     status='Active',
     record_status_id=@active_record_status_id,
     origin_type=CASE WHEN oc.origin_type='Hybrid' THEN 'Hybrid' ELSE 'Repository' END,
     is_manually_added=0,
     updated_by=@p_usr_id,
     updated_dt=SYSUTCDATETIME()
   FROM grac_practice.organization_control oc
   JOIN repository_controls rc ON rc.control_id=oc.repository_control_id AND rc.release_id=oc.release_id
   WHERE oc.organization_id=@new_id;

   ;WITH release_controls AS (
     SELECT DISTINCT
       scm.control_id,
       COALESCE(scm.release_id,n.release_id) release_id,
       COALESCE(scm.artifact_id,r.artifact_id) artifact_id
     FROM grac_new.source_control_map scm
     JOIN grac_new.source_structure_node n ON n.structure_node_id=scm.structure_node_id
     JOIN grac_new.release r ON r.release_id=n.release_id
     JOIN @selected_releases sr ON sr.release_id=COALESCE(scm.release_id,n.release_id)
     WHERE scm.status='Active' AND n.status='Active'
   ),
   repository_controls AS (
     SELECT
       rc.control_id,
       c.control_code,
       c.control_name,
       c.description,
       c.objective,
       c.control_domain_id,
       c.control_sub_domain_id,
       rc.release_id,
       rc.artifact_id,
       s.subscription_id
     FROM release_controls rc
     JOIN grac_new.control c ON c.control_id=rc.control_id AND c.status='Active'
     JOIN grac_practice.repository_subscription s ON s.organization_id=@new_id AND s.release_id=rc.release_id AND s.record_status_id=@active_record_status_id AND s.subscription_status_id=@active_subscription_status_id
   )
   INSERT grac_practice.organization_control(
     organization_id,origin_type,repository_control_id,control_code,control_name,description,objective,control_domain_id,control_sub_domain_id,
     is_manually_added,subscription_id,release_id,artifact_id,applicability_status,applicability_status_id,criticality,status,record_status_id,entered_by)
   SELECT @new_id,'Repository',rc.control_id,rc.control_code,rc.control_name,rc.description,rc.objective,rc.control_domain_id,rc.control_sub_domain_id,
     0,rc.subscription_id,rc.release_id,rc.artifact_id,'Not Updated',@not_updated_applicability_status_id,'Medium','Active',@active_record_status_id,@p_usr_id
   FROM repository_controls rc
   WHERE NOT EXISTS(
     SELECT 1 FROM grac_practice.organization_control oc
     WHERE oc.organization_id=@new_id AND oc.repository_control_id=rc.control_id AND oc.release_id=rc.release_id
   );

   UPDATE oc SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM grac_practice.organization_control oc
   WHERE oc.organization_id=@new_id
     AND oc.is_manually_added=0
     AND oc.release_id IS NOT NULL
     AND NOT EXISTS(SELECT 1 FROM @selected_releases sr WHERE sr.release_id=oc.release_id);

   DECLARE @recommended_releases TABLE(release_id BIGINT PRIMARY KEY, recommendation_reason NVARCHAR(1000), confidence_level NVARCHAR(30));
   INSERT @recommended_releases(release_id,recommendation_reason,confidence_level)
   SELECT DISTINCT TRY_CONVERT(BIGINT,JSON_VALUE([value],'$.releaseId')),
     LEFT(COALESCE(JSON_VALUE([value],'$.reason'),N'Recommended by applicability engine'),1000),
     COALESCE(JSON_VALUE([value],'$.confidence'),N'Medium')
   FROM OPENJSON(@p_payload,'$.recommendations')
   WHERE TRY_CONVERT(BIGINT,JSON_VALUE([value],'$.releaseId')) IS NOT NULL;

   INSERT grac_practice.subscription_recommendation_history(organization_id,authority_id,artifact_id,release_id,recommendation_reason,confidence_level,decision_status,status,entered_by)
   SELECT @new_id,a.authority_id,a.artifact_id,r.release_id,rr.recommendation_reason,rr.confidence_level,
     CASE WHEN sr.release_id IS NULL THEN N'Rejected' ELSE N'Accepted' END,N'Active',@p_usr_id
   FROM @recommended_releases rr
   JOIN grac_new.release r ON r.release_id=rr.release_id
   JOIN grac_new.artifact a ON a.artifact_id=r.artifact_id
   LEFT JOIN @selected_releases sr ON sr.release_id=rr.release_id;
 END
 ELSE IF @p_entity_type='organizations'
 BEGIN
   IF @is_system_admin=0
     THROW 51053,'You do not have permission to manage organizations.',1;
   IF @p_id=0 BEGIN
     INSERT grac_practice.organization(organization_code,organization_name,industry,entity_type,country,status,record_status_id,entered_by)
     VALUES(JSON_VALUE(@p_payload,'$.code'),JSON_VALUE(@p_payload,'$.name'),JSON_VALUE(@p_payload,'$.industry'),JSON_VALUE(@p_payload,'$.entityType'),JSON_VALUE(@p_payload,'$.country'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.organization SET organization_code=JSON_VALUE(@p_payload,'$.code'),organization_name=JSON_VALUE(@p_payload,'$.name'),
     industry=JSON_VALUE(@p_payload,'$.industry'),entity_type=JSON_VALUE(@p_payload,'$.entityType'),country=JSON_VALUE(@p_payload,'$.country'),
     status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),record_status_id=COALESCE(@payload_record_status_id,record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE organization_id=@p_id;
 END
 ELSE IF @p_entity_type='divisions'
 BEGIN
   DECLARE @division_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @division_code NVARCHAR(80)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.code'))),'');
   DECLARE @division_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @division_head_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.headUserId'),''));
   IF @division_org_id IS NULL THROW 51060,'Organization is required for Division.',1;
   IF @division_code IS NULL THROW 51061,'Division Code is required.',1;
   IF @division_name IS NULL THROW 51062,'Division Name is required.',1;
   IF @division_head_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@division_head_id AND organization_id=@division_org_id AND status='Active')
     THROW 51063,'Selected Division Head is not valid for this organization.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_division(organization_id,division_code,division_name,head_employee_id,description,status,record_status_id,entered_by)
     VALUES(@division_org_id,@division_code,@division_name,@division_head_id,JSON_VALUE(@p_payload,'$.description'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_division SET organization_id=@division_org_id,division_code=@division_code,division_name=@division_name,
       head_employee_id=@division_head_id,description=JSON_VALUE(@p_payload,'$.description'),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),
       record_status_id=COALESCE(@payload_record_status_id,record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE division_id=@p_id;
 END
 ELSE IF @p_entity_type='locations'
 BEGIN
   DECLARE @location_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @location_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @location_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.locationTypeId'),''));
   DECLARE @location_head_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.locationHeadId'),''));
   DECLARE @location_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @location_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@location_status_id),'Active');
   -- Status restriction (2026-09-20 change request): a NEW status may only
   -- be Active or Inactive; a legacy status already on the row (Retired/
   -- Draft/Disposed/...) is left alone unless this save actually changes
   -- it. Mirrors the same guard in the dedicated sp_org_location_save shim
   -- (361) -- this monolith branch only runs when that shim is missing.
   DECLARE @location_current_status_id INT=CASE WHEN @p_id<>0 THEN (SELECT record_status_id FROM grac_practice.organization_location WHERE location_id=@p_id) END;
   IF @location_status_id<>ISNULL(@location_current_status_id,-1)
      AND NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE record_status_id=@location_status_id AND status_code IN ('Active','Inactive'))
     THROW 51077,'Location status can only be set to Active or Inactive.',1;
   IF @location_org_id IS NULL THROW 51064,'Organization is required for Location.',1;
   IF @location_name IS NULL THROW 51065,'Location Name is required.',1;
   IF @location_type_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.location_type_master WHERE location_type_id=@location_type_id AND is_active=1)
     THROW 51066,'Location Type is required.',1;
   IF @location_head_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@location_head_id AND organization_id=@location_org_id AND status='Active')
     THROW 51067,'Selected Location Head is not valid for this organization.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_location(organization_id,location_name,location_type_id,location_head_id,region,remarks,status,record_status_id,entered_by)
     VALUES(@location_org_id,@location_name,@location_type_id,@location_head_id,JSON_VALUE(@p_payload,'$.region'),JSON_VALUE(@p_payload,'$.remarks'),@location_status_name,@location_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_location SET organization_id=@location_org_id,location_name=@location_name,location_type_id=@location_type_id,
       location_head_id=@location_head_id,region=JSON_VALUE(@p_payload,'$.region'),remarks=JSON_VALUE(@p_payload,'$.remarks'),
       status=@location_status_name,record_status_id=@location_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE location_id=@p_id;
 END
 ELSE IF @p_entity_type='departments'
 BEGIN
   DECLARE @department_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @department_code NVARCHAR(80)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.code'))),'');
   DECLARE @department_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @department_head_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.headUserId'),''));
   IF @department_org_id IS NULL THROW 51040,'Organization is required for Department.',1;
   IF @department_code IS NULL THROW 51041,'Department Code is required.',1;
   IF @department_name IS NULL THROW 51042,'Department Name is required.',1;
   IF @department_head_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@department_head_id AND organization_id=@department_org_id AND status='Active')
     THROW 51043,'Selected Department Head is not valid for this organization.',1;
   -- Status restriction (2026-09-20 change request): a NEW status may only
   -- be Active or Inactive; a legacy status already on the row (Retired/
   -- Draft/Disposed/...) is left alone unless this save actually changes
   -- it. Department has no dedicated shim, so this is the only save path.
   DECLARE @department_current_status_id INT=CASE WHEN @p_id<>0 THEN (SELECT record_status_id FROM grac_practice.organization_department WHERE department_id=@p_id) END;
   DECLARE @department_resolved_status_id INT=COALESCE(@payload_record_status_id,@department_current_status_id,@active_record_status_id);
   IF @department_resolved_status_id<>ISNULL(@department_current_status_id,-1)
      AND NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE record_status_id=@department_resolved_status_id AND status_code IN ('Active','Inactive'))
     THROW 51078,'Department status can only be set to Active or Inactive.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_department(organization_id,department_code,department_name,head_employee_id,description,status,record_status_id,entered_by)
     VALUES(@department_org_id,@department_code,@department_name,@department_head_id,JSON_VALUE(@p_payload,'$.description'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_department SET organization_id=@department_org_id,department_code=@department_code,department_name=@department_name,
       head_employee_id=@department_head_id,description=JSON_VALUE(@p_payload,'$.description'),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),
       record_status_id=COALESCE(@payload_record_status_id,record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE department_id=@p_id;
 END
 ELSE IF @p_entity_type='teams'
 BEGIN
   DECLARE @team_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @team_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @team_manager_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.teamManagerId'),''));
   DECLARE @team_department_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.parentDepartmentId'),''));
   DECLARE @team_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @team_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@team_status_id),'Active');
   -- Status restriction (2026-09-20 change request): a NEW status may only
   -- be Active or Inactive; a legacy status already on the row (Retired/
   -- Draft/Disposed/...) is left alone unless this save actually changes
   -- it. Mirrors the same guard in the dedicated sp_org_team_save shim
   -- (133) -- this monolith branch only runs when that shim is missing.
   DECLARE @team_current_status_id INT=CASE WHEN @p_id<>0 THEN (SELECT record_status_id FROM grac_practice.organization_team WHERE team_id=@p_id) END;
   IF @team_status_id<>ISNULL(@team_current_status_id,-1)
      AND NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE record_status_id=@team_status_id AND status_code IN ('Active','Inactive'))
     THROW 51081,'Team status can only be set to Active or Inactive.',1;
   IF @team_org_id IS NULL THROW 51068,'Organization is required for Team.',1;
   IF @team_name IS NULL THROW 51069,'Team Name is required.',1;
   IF @team_manager_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@team_manager_id AND organization_id=@team_org_id AND status='Active')
     THROW 51070,'Selected Team Manager is not valid for this organization.',1;
   IF @team_department_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_department WHERE department_id=@team_department_id AND organization_id=@team_org_id AND status='Active')
     THROW 51071,'Selected Parent Department is not valid for this organization.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_team(organization_id,team_name,team_manager_id,parent_department_id,remarks,status,record_status_id,entered_by)
     VALUES(@team_org_id,@team_name,@team_manager_id,@team_department_id,JSON_VALUE(@p_payload,'$.remarks'),@team_status_name,@team_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_team SET organization_id=@team_org_id,team_name=@team_name,team_manager_id=@team_manager_id,
       parent_department_id=@team_department_id,remarks=JSON_VALUE(@p_payload,'$.remarks'),status=@team_status_name,record_status_id=@team_status_id,
       updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE team_id=@p_id;
 END
 ELSE IF @p_entity_type='committees'
 BEGIN
   DECLARE @committee_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @committee_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @committee_chairperson_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.chairpersonId'),''));
   DECLARE @committee_secretary_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.secretaryId'),''));
   DECLARE @committee_frequency_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.reviewFrequencyId'),''));
   DECLARE @committee_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @committee_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@committee_status_id),'Active');
   IF @committee_org_id IS NULL THROW 51072,'Organization is required for Committee.',1;
   IF @committee_name IS NULL THROW 51073,'Committee Name is required.',1;
   IF @committee_chairperson_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@committee_chairperson_id AND organization_id=@committee_org_id AND status='Active')
     THROW 51074,'Selected Chairperson is not valid for this organization.',1;
   IF @committee_secretary_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@committee_secretary_id AND organization_id=@committee_org_id AND status='Active')
     THROW 51075,'Selected Secretary is not valid for this organization.',1;
   IF @committee_frequency_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.frequency_master WHERE frequency_id=@committee_frequency_id AND is_active=1)
     THROW 51076,'Selected Review Frequency is not valid.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_committee(organization_id,committee_name,chairperson_id,secretary_id,review_frequency_id,remarks,status,record_status_id,entered_by)
     VALUES(@committee_org_id,@committee_name,@committee_chairperson_id,@committee_secretary_id,@committee_frequency_id,JSON_VALUE(@p_payload,'$.remarks'),@committee_status_name,@committee_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_committee SET organization_id=@committee_org_id,committee_name=@committee_name,chairperson_id=@committee_chairperson_id,
       secretary_id=@committee_secretary_id,review_frequency_id=@committee_frequency_id,remarks=JSON_VALUE(@p_payload,'$.remarks'),
       status=@committee_status_name,record_status_id=@committee_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE committee_id=@p_id;
 END
 ELSE IF @p_entity_type='business-functions'
 BEGIN
   DECLARE @function_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @function_code NVARCHAR(80)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.code'))),'');
   DECLARE @function_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   IF @function_org_id IS NULL THROW 51044,'Organization is required for Business Function.',1;
   IF @function_code IS NULL THROW 51045,'Function Code is required.',1;
   IF @function_name IS NULL THROW 51046,'Function Name is required.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_business_function(organization_id,function_code,function_name,owner_name,criticality,status,entered_by)
     VALUES(@function_org_id,@function_code,@function_name,JSON_VALUE(@p_payload,'$.ownerName'),COALESCE(JSON_VALUE(@p_payload,'$.criticality'),'Medium'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_business_function SET organization_id=@function_org_id,function_code=@function_code,function_name=@function_name,
       owner_name=JSON_VALUE(@p_payload,'$.ownerName'),criticality=COALESCE(JSON_VALUE(@p_payload,'$.criticality'),criticality),
       status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE business_function_id=@p_id;
 END
 ELSE IF @p_entity_type='roles'
 BEGIN
   DECLARE @role_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @role_name NVARCHAR(120)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.roleName'))),'');
   IF @role_org_id IS NULL THROW 51140,'Organization is required for Role.',1;
   IF @role_name IS NULL THROW 51141,'Role Name is required.',1;
   IF EXISTS(SELECT 1 FROM grac_practice.organization_role WHERE organization_id=@role_org_id AND LOWER(role_name)=LOWER(@role_name) AND (@p_id=0 OR role_id<>@p_id))
     THROW 51142,'Role Name already exists for this organization.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_role(organization_id,role_name,description,status,record_status_id,entered_by)
     VALUES(@role_org_id,@role_name,JSON_VALUE(@p_payload,'$.description'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_role
     SET organization_id=@role_org_id,role_name=@role_name,description=JSON_VALUE(@p_payload,'$.description'),
         status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),record_status_id=COALESCE(@payload_record_status_id,record_status_id),
         updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE role_id=@p_id;
 END
 ELSE IF @p_entity_type='role-menu-permissions'
 BEGIN
   DECLARE @permission_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @permission_role_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.roleId'),''));
   DECLARE @permission_menu_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.menuId'),''));
   DECLARE @permission_view BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.canView'),'true')) IN ('true','1','yes') THEN 1 ELSE 0 END;
   DECLARE @permission_add BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.canAdd'),'false')) IN ('true','1','yes') THEN 1 ELSE 0 END;
   DECLARE @permission_edit BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.canEdit'),'false')) IN ('true','1','yes') THEN 1 ELSE 0 END;
   DECLARE @permission_delete BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.canDelete'),'false')) IN ('true','1','yes') THEN 1 ELSE 0 END;
   DECLARE @permission_approve BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.canApprove'),'false')) IN ('true','1','yes') THEN 1 ELSE 0 END;
   IF @permission_role_id IS NULL THROW 51143,'Role is required for Menu Permission.',1;
   IF @permission_menu_id IS NULL THROW 51144,'Menu is required for Menu Permission.',1;
   IF NOT EXISTS(SELECT 1 FROM grac_practice.organization_role WHERE role_id=@permission_role_id AND (@permission_org_id IS NULL OR organization_id=@permission_org_id) AND status='Active')
     THROW 51145,'Selected role is not valid for this organization.',1;
   IF NOT EXISTS(SELECT 1 FROM grac_practice.menu_master WHERE menu_id=@permission_menu_id AND status='Active')
     THROW 51146,'Selected menu is not active.',1;
   IF EXISTS(SELECT 1 FROM grac_practice.organization_role_menu_permission WHERE role_id=@permission_role_id AND menu_id=@permission_menu_id AND (@p_id=0 OR role_menu_permission_id<>@p_id))
     THROW 51147,'This menu is already mapped to the selected role.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_role_menu_permission(role_id,menu_id,can_view,can_add,can_edit,can_delete,can_approve,status,record_status_id,entered_by)
     VALUES(@permission_role_id,@permission_menu_id,@permission_view,@permission_add,@permission_edit,@permission_delete,@permission_approve,COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_role_menu_permission
     SET role_id=@permission_role_id,menu_id=@permission_menu_id,can_view=@permission_view,can_add=@permission_add,can_edit=@permission_edit,can_delete=@permission_delete,can_approve=@permission_approve,
         status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),record_status_id=COALESCE(@payload_record_status_id,record_status_id),
         updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE role_menu_permission_id=@p_id;
 END
 ELSE IF @p_entity_type='users'
 BEGIN
   DECLARE @employee_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @employee_code NVARCHAR(80)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.employeeCode'))),'');
   DECLARE @employee_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.employeeName'))),'');
   DECLARE @employee_email NVARCHAR(250)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.email'))),'');
   DECLARE @employee_password_hash NVARCHAR(500)=NULLIF(JSON_VALUE(@p_payload,'$.passwordHash'),'');
   DECLARE @employee_role_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.roleId'),''));
   DECLARE @employee_location_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.locationId'),''));
   DECLARE @employee_department_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.departmentId'),''));
   DECLARE @employee_function_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.businessFunctionId'),''));
   DECLARE @employee_reporting_officer_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.reportingOfficerId'),''));
   IF @employee_org_id IS NULL THROW 51047,'Organization is required for User / Employee.',1;
   IF @employee_code IS NULL THROW 51048,'Employee Code is required.',1;
   IF @employee_name IS NULL THROW 51049,'Employee Name is required.',1;
   IF @employee_email IS NULL THROW 51148,'Email ID is required for User / Employee login.',1;
   IF EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE LOWER(LTRIM(RTRIM(email)))=LOWER(@employee_email) AND (@p_id=0 OR employee_id<>@p_id))
     THROW 51149,'Employee Email ID already exists.',1;
   IF @p_id=0 AND @employee_password_hash IS NULL THROW 51152,'Password is required when creating a User / Employee.',1;
   IF @employee_role_id IS NULL THROW 51150,'Role is required for User / Employee.',1;
   IF NOT EXISTS(SELECT 1 FROM grac_practice.organization_role WHERE role_id=@employee_role_id AND organization_id=@employee_org_id AND status='Active')
     THROW 51151,'Selected Role is not valid for this organization.',1;
   IF @employee_location_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_location WHERE location_id=@employee_location_id AND organization_id=@employee_org_id AND status='Active')
     THROW 51056,'Selected Location is not valid for this organization.',1;
   IF @employee_department_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_department WHERE department_id=@employee_department_id AND organization_id=@employee_org_id AND status='Active')
     THROW 51050,'Selected Department is not valid for this organization.',1;
   IF @employee_function_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id=@employee_function_id AND organization_id=@employee_org_id AND status='Active')
     THROW 51051,'Selected Business Function is not valid for this organization.',1;
   IF @employee_reporting_officer_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@employee_reporting_officer_id AND organization_id=@employee_org_id AND status='Active')
     THROW 51054,'Selected Reporting Officer is not valid for this organization.',1;
   IF @p_id<>0 AND @employee_reporting_officer_id=@p_id
     THROW 51055,'Reporting Officer cannot be the same employee.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_employee(organization_id,employee_code,employee_name,email,password_hash,role_id,designation,location_id,department,department_id,business_function_id,reporting_officer_id,status,record_status_id,entered_by)
     SELECT @employee_org_id,@employee_code,@employee_name,@employee_email,@employee_password_hash,@employee_role_id,JSON_VALUE(@p_payload,'$.designation'),@employee_location_id,d.department_name,@employee_department_id,@employee_function_id,
       @employee_reporting_officer_id,
       COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id
     FROM (SELECT CAST(NULL AS NVARCHAR(200)) department_name) empty
     OUTER APPLY (SELECT department_name FROM grac_practice.organization_department WHERE department_id=@employee_department_id) d;
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE e SET organization_id=@employee_org_id,employee_code=@employee_code,employee_name=@employee_name,email=@employee_email,
       password_hash=COALESCE(@employee_password_hash,e.password_hash),role_id=@employee_role_id,
       designation=JSON_VALUE(@p_payload,'$.designation'),location_id=@employee_location_id,department=d.department_name,department_id=@employee_department_id,business_function_id=@employee_function_id,
       reporting_officer_id=@employee_reporting_officer_id,
       status=COALESCE(JSON_VALUE(@p_payload,'$.status'),e.status),record_status_id=COALESCE(@payload_record_status_id,e.record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     FROM grac_practice.organization_employee e
     OUTER APPLY (SELECT department_name FROM grac_practice.organization_department WHERE department_id=@employee_department_id) d
     WHERE e.employee_id=@p_id;

   IF @employee_email IS NOT NULL
   BEGIN
     INSERT grac_practice.user_organization_map(user_email,organization_id,access_role,is_default,status,record_status_id,entered_by)
     SELECT @employee_email,@employee_org_id,'Organization User',0,'Active',@active_record_status_id,@p_usr_id
     WHERE NOT EXISTS(SELECT 1 FROM grac_practice.user_organization_map WHERE user_email=@employee_email AND organization_id=@employee_org_id);
   END
 END
 ELSE IF @p_entity_type='dependency-vendors'
 BEGIN
   DECLARE @vendor_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @vendor_name NVARCHAR(220)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @vendor_category_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.serviceCategoryId'),''));
   DECLARE @vendor_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.relationshipOwnerId'),''));
   DECLARE @vendor_criticality_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.criticalityId'),''));
   DECLARE @vendor_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @vendor_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@vendor_status_id),'Active');
   IF @vendor_org_id IS NULL THROW 51100,'Organization is required for Vendor.',1;
   IF @vendor_name IS NULL THROW 51101,'Vendor Name is required.',1;
   IF @vendor_category_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.dependency_service_category_master WHERE service_category_id=@vendor_category_id AND is_active=1)
     THROW 51102,'Service Category is required.',1;
   IF @vendor_owner_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@vendor_owner_id AND organization_id=@vendor_org_id AND status='Active')
     THROW 51103,'Selected Relationship Owner is not valid for this organization.',1;
   IF @vendor_criticality_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id=@vendor_criticality_id AND is_active=1)
     THROW 51104,'Selected Criticality is not valid.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_dependency_vendor(organization_id,vendor_name,service_category_id,relationship_owner_id,contract_start_dt,contract_end_dt,renewal_dt,sla_applicable,criticality_id,remarks,status,record_status_id,entered_by)
     VALUES(@vendor_org_id,@vendor_name,@vendor_category_id,@vendor_owner_id,TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.contractStartDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.contractEndDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.renewalDate'),'')),
       CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.slaApplicable'),'false')) IN ('true','1','yes','y') THEN 1 ELSE 0 END,@vendor_criticality_id,JSON_VALUE(@p_payload,'$.remarks'),@vendor_status_name,@vendor_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_dependency_vendor SET organization_id=@vendor_org_id,vendor_name=@vendor_name,service_category_id=@vendor_category_id,
       relationship_owner_id=@vendor_owner_id,contract_start_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.contractStartDate'),'')),contract_end_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.contractEndDate'),'')),
       renewal_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.renewalDate'),'')),sla_applicable=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.slaApplicable'),'false')) IN ('true','1','yes','y') THEN 1 ELSE 0 END,
       criticality_id=@vendor_criticality_id,remarks=JSON_VALUE(@p_payload,'$.remarks'),status=@vendor_status_name,record_status_id=@vendor_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE vendor_id=@p_id;
 END
 ELSE IF @p_entity_type='dependency-applications'
 BEGIN
   DECLARE @app_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @app_name NVARCHAR(220)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @app_business_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.businessOwnerId'),''));
   DECLARE @app_technical_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.technicalOwnerId'),''));
   DECLARE @app_vendor_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.vendorId'),''));
   DECLARE @app_hosting_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.hostingTypeId'),''));
   DECLARE @app_criticality_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.criticalityId'),''));
   DECLARE @app_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @app_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@app_status_id),'Active');
   IF @app_org_id IS NULL THROW 51110,'Organization is required for Application.',1;
   IF @app_name IS NULL THROW 51111,'Application Name is required.',1;
   IF @app_business_owner_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@app_business_owner_id AND organization_id=@app_org_id AND status='Active')
     THROW 51112,'Selected Business Owner is not valid for this organization.',1;
   IF @app_technical_owner_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@app_technical_owner_id AND organization_id=@app_org_id AND status='Active')
     THROW 51113,'Selected Technical Owner is not valid for this organization.',1;
   IF @app_vendor_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_dependency_vendor WHERE vendor_id=@app_vendor_id AND organization_id=@app_org_id AND status='Active')
     THROW 51114,'Selected Vendor is not valid for this organization.',1;
   IF @app_hosting_type_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.dependency_hosting_type_master WHERE hosting_type_id=@app_hosting_type_id AND is_active=1)
     THROW 51115,'Selected Hosting Type is not valid.',1;
   IF @app_criticality_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id=@app_criticality_id AND is_active=1)
     THROW 51116,'Selected Criticality is not valid.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_dependency_application(organization_id,application_name,description,business_owner_id,technical_owner_id,vendor_id,version_no,hosting_type_id,support_expiry_dt,end_of_life_dt,criticality_id,remarks,status,record_status_id,entered_by)
     VALUES(@app_org_id,@app_name,JSON_VALUE(@p_payload,'$.description'),@app_business_owner_id,@app_technical_owner_id,@app_vendor_id,JSON_VALUE(@p_payload,'$.version'),@app_hosting_type_id,TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.supportExpiryDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.endOfLifeDate'),'')),@app_criticality_id,JSON_VALUE(@p_payload,'$.remarks'),@app_status_name,@app_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_dependency_application SET organization_id=@app_org_id,application_name=@app_name,description=JSON_VALUE(@p_payload,'$.description'),
       business_owner_id=@app_business_owner_id,technical_owner_id=@app_technical_owner_id,vendor_id=@app_vendor_id,version_no=JSON_VALUE(@p_payload,'$.version'),
       hosting_type_id=@app_hosting_type_id,support_expiry_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.supportExpiryDate'),'')),end_of_life_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.endOfLifeDate'),'')),
       criticality_id=@app_criticality_id,remarks=JSON_VALUE(@p_payload,'$.remarks'),status=@app_status_name,record_status_id=@app_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE application_id=@p_id;
 END
 ELSE IF @p_entity_type='dependency-tools'
 BEGIN
   DECLARE @tool_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @tool_name NVARCHAR(220)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @tool_business_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.businessOwnerId'),''));
   DECLARE @tool_vendor_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.vendorId'),''));
   DECLARE @tool_license_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.licenseTypeId'),''));
   DECLARE @tool_criticality_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.criticalityId'),''));
   DECLARE @tool_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @tool_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@tool_status_id),'Active');
   IF @tool_org_id IS NULL THROW 51120,'Organization is required for Tool.',1;
   IF @tool_name IS NULL THROW 51121,'Tool Name is required.',1;
   IF @tool_business_owner_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@tool_business_owner_id AND organization_id=@tool_org_id AND status='Active')
     THROW 51122,'Selected Business Owner is not valid for this organization.',1;
   IF @tool_vendor_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_dependency_vendor WHERE vendor_id=@tool_vendor_id AND organization_id=@tool_org_id AND status='Active')
     THROW 51123,'Selected Vendor is not valid for this organization.',1;
   IF @tool_license_type_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.dependency_license_type_master WHERE license_type_id=@tool_license_type_id AND is_active=1)
     THROW 51124,'Selected License Type is not valid.',1;
   IF @tool_criticality_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id=@tool_criticality_id AND is_active=1)
     THROW 51125,'Selected Criticality is not valid.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_dependency_tool(organization_id,tool_name,description,business_owner_id,vendor_id,license_type_id,license_expiry_dt,support_expiry_dt,criticality_id,remarks,status,record_status_id,entered_by)
     VALUES(@tool_org_id,@tool_name,JSON_VALUE(@p_payload,'$.description'),@tool_business_owner_id,@tool_vendor_id,@tool_license_type_id,TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.licenseExpiryDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.supportExpiryDate'),'')),@tool_criticality_id,JSON_VALUE(@p_payload,'$.remarks'),@tool_status_name,@tool_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_dependency_tool SET organization_id=@tool_org_id,tool_name=@tool_name,description=JSON_VALUE(@p_payload,'$.description'),
       business_owner_id=@tool_business_owner_id,vendor_id=@tool_vendor_id,license_type_id=@tool_license_type_id,
       license_expiry_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.licenseExpiryDate'),'')),support_expiry_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.supportExpiryDate'),'')),
       criticality_id=@tool_criticality_id,remarks=JSON_VALUE(@p_payload,'$.remarks'),status=@tool_status_name,record_status_id=@tool_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE tool_id=@p_id;
 END
 ELSE IF @p_entity_type='dependency-assets'
 BEGIN
   DECLARE @asset_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @asset_name NVARCHAR(220)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @asset_category_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.assetCategoryId'),''));
   DECLARE @asset_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.ownerId'),''));
   DECLARE @asset_location_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.locationId'),''));
   DECLARE @asset_criticality_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.criticalityId'),''));
   DECLARE @asset_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @asset_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@asset_status_id),'Active');
   IF @asset_org_id IS NULL THROW 51130,'Organization is required for Asset.',1;
   IF @asset_name IS NULL THROW 51131,'Asset Name is required.',1;
   IF @asset_category_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.dependency_asset_category_master WHERE asset_category_id=@asset_category_id AND is_active=1)
     THROW 51132,'Asset Category is required.',1;
   IF @asset_owner_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@asset_owner_id AND organization_id=@asset_org_id AND status='Active')
     THROW 51133,'Selected Owner is not valid for this organization.',1;
   IF @asset_location_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_location WHERE location_id=@asset_location_id AND organization_id=@asset_org_id AND status='Active')
     THROW 51134,'Selected Location is not valid for this organization.',1;
   IF @asset_criticality_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id=@asset_criticality_id AND is_active=1)
     THROW 51135,'Selected Criticality is not valid.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_dependency_asset(organization_id,asset_name,asset_category_id,owner_id,location_id,purchase_dt,warranty_expiry_dt,amc_expiry_dt,criticality_id,remarks,status,record_status_id,entered_by)
     VALUES(@asset_org_id,@asset_name,@asset_category_id,@asset_owner_id,@asset_location_id,TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.purchaseDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.warrantyExpiryDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.amcExpiryDate'),'')),@asset_criticality_id,JSON_VALUE(@p_payload,'$.remarks'),@asset_status_name,@asset_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_dependency_asset SET organization_id=@asset_org_id,asset_name=@asset_name,asset_category_id=@asset_category_id,
       owner_id=@asset_owner_id,location_id=@asset_location_id,purchase_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.purchaseDate'),'')),
       warranty_expiry_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.warrantyExpiryDate'),'')),amc_expiry_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.amcExpiryDate'),'')),
       criticality_id=@asset_criticality_id,remarks=JSON_VALUE(@p_payload,'$.remarks'),status=@asset_status_name,record_status_id=@asset_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE asset_id=@p_id;
 END
 ELSE IF @p_entity_type='dependency-processes'
 BEGIN
   DECLARE @process_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @process_name NVARCHAR(220)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @process_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.processOwnerId'),''));
   DECLARE @process_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @process_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@process_status_id),'Active');
   IF @process_org_id IS NULL THROW 51140,'Organization is required for Process.',1;
   IF @process_name IS NULL THROW 51141,'Process Name is required.',1;
   IF @process_owner_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@process_owner_id AND organization_id=@process_org_id AND status='Active')
     THROW 51142,'Selected Process Owner is not valid for this organization.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_dependency_process(organization_id,process_name,process_owner_id,version_no,effective_dt,last_review_dt,next_review_dt,remarks,status,record_status_id,entered_by)
     VALUES(@process_org_id,@process_name,@process_owner_id,JSON_VALUE(@p_payload,'$.version'),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.effectiveDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.lastReviewDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.nextReviewDate'),'')),JSON_VALUE(@p_payload,'$.remarks'),@process_status_name,@process_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_dependency_process SET organization_id=@process_org_id,process_name=@process_name,process_owner_id=@process_owner_id,
       version_no=JSON_VALUE(@p_payload,'$.version'),effective_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.effectiveDate'),'')),
       last_review_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.lastReviewDate'),'')),next_review_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.nextReviewDate'),'')),
       remarks=JSON_VALUE(@p_payload,'$.remarks'),status=@process_status_name,record_status_id=@process_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE process_id=@p_id;
 END
 ELSE IF @p_entity_type='practice-dependency-resolutions'
 BEGIN
   DECLARE @resolution_practice_instance_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceInstanceId'),''));
   DECLARE @resolution_organization_id BIGINT;
   DECLARE @resolution_dependency_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.dependencyTypeId'),''));
   DECLARE @resolution_dependency_category NVARCHAR(120);
   DECLARE @resolution_dependency_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.resolvedDependencyId'),''));
   DECLARE @resolution_dependency_name NVARCHAR(300);
   DECLARE @resolution_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.resolutionOwnerId'),''));
   DECLARE @resolution_status_id INT=(SELECT resolution_status_id FROM grac_practice.dependency_resolution_status_master WHERE status_code='Resolved');
   DECLARE @resolution_cfg_source_table NVARCHAR(256);
   DECLARE @resolution_cfg_id_column SYSNAME;
   DECLARE @resolution_cfg_display_column SYSNAME;
   DECLARE @resolution_cfg_org_column SYSNAME;
   DECLARE @resolution_cfg_status_column SYSNAME;
   DECLARE @resolution_cfg_status_value NVARCHAR(80);
   DECLARE @resolution_cfg_schema SYSNAME;
   DECLARE @resolution_cfg_table SYSNAME;
   DECLARE @resolution_cfg_sql NVARCHAR(MAX);

   SELECT @resolution_organization_id=organization_id
   FROM grac_practice.practice_instance
   WHERE practice_instance_id=@resolution_practice_instance_id;
   IF @resolution_practice_instance_id IS NULL OR @resolution_organization_id IS NULL
     THROW 51200,'Practice Instance is required for Operationalization.',1;
   IF @is_system_admin=0 AND NOT EXISTS(SELECT 1 FROM @allowed_organizations WHERE organization_id=@resolution_organization_id)
     THROW 51052,'You do not have access to the selected organization.',1;
   IF @is_system_admin=0 AND NOT EXISTS(
     SELECT 1
     FROM grac_practice.practice_instance pi
     JOIN grac_practice.organization_employee owner_emp
       ON owner_emp.organization_id=pi.organization_id
      AND owner_emp.status='Active'
      AND (owner_emp.employee_id=pi.primary_owner_id OR owner_emp.employee_name=pi.primary_owner)
     WHERE pi.practice_instance_id=@resolution_practice_instance_id
       AND (owner_emp.email=@p_usr_id OR owner_emp.employee_code=@p_usr_id)
   )
   AND NOT EXISTS(
     SELECT 1
     FROM grac_practice.organization_employee emp
     WHERE emp.organization_id=@resolution_organization_id
       AND emp.status='Active'
       AND (emp.email=@p_usr_id OR emp.employee_code=@p_usr_id)
   )
     THROW 51211,'You are not authorized to resolve this Practice Instance.',1;
   IF @resolution_dependency_type_id IS NULL
     THROW 51201,'Dependency Category is required.',1;
   IF @resolution_dependency_id IS NULL
     THROW 51202,'Resolved Dependency is required.',1;

   SELECT @resolution_dependency_category=dependency_type_name
   FROM grac_practice.dependency_type_master
   WHERE dependency_type_id=@resolution_dependency_type_id AND is_active=1;
   IF @resolution_dependency_category IS NULL
     THROW 51203,'Selected Dependency Category is not valid.',1;
   IF NOT EXISTS(
     SELECT 1
     FROM grac_practice.practice_instance_dependency d
     WHERE d.practice_instance_id=@resolution_practice_instance_id
       AND d.organization_id=@resolution_organization_id
       AND d.dependency_type_id=@resolution_dependency_type_id
       AND d.status='Active'
   )
     THROW 51204,'The selected dependency category is not configured for this Practice Instance.',1;

   SELECT TOP 1
     @resolution_cfg_source_table=source_table_name,
     @resolution_cfg_id_column=id_column_name,
     @resolution_cfg_display_column=display_column_name,
     @resolution_cfg_org_column=organization_filter_column,
     @resolution_cfg_status_column=status_filter_column,
     @resolution_cfg_status_value=status_active_value
   FROM grac_practice.dependency_type_source_config
   WHERE dependency_type_id=@resolution_dependency_type_id
     AND status='Active'
     AND source_table_name IN (
       N'grac_practice.organization_dependency_tool',
       N'grac_practice.organization_dependency_vendor',
       N'grac_practice.organization_dependency_application',
       N'grac_practice.organization_dependency_asset',
       N'grac_practice.organization_dependency_process',
       N'grac_practice.organization_location',
       N'grac_practice.organization_employee',
       N'grac_practice.organization_team',
       N'grac_practice.organization_committee'
     );
   IF @resolution_cfg_source_table IS NULL
     THROW 51205,'Dependency Category source configuration is missing or inactive.',1;

   SET @resolution_cfg_schema=PARSENAME(@resolution_cfg_source_table,2);
   SET @resolution_cfg_table=PARSENAME(@resolution_cfg_source_table,1);
   IF @resolution_cfg_schema<>N'grac_practice' OR OBJECT_ID(@resolution_cfg_source_table) IS NULL
     THROW 51206,'Dependency Category source configuration is invalid.',1;

   SET @resolution_cfg_sql=N'
SELECT @resolvedName=CAST(' + QUOTENAME(@resolution_cfg_display_column) + N' AS NVARCHAR(300))
FROM ' + QUOTENAME(@resolution_cfg_schema) + N'.' + QUOTENAME(@resolution_cfg_table) + N'
WHERE ' + QUOTENAME(@resolution_cfg_id_column) + N'=@referenceId
  AND ' + QUOTENAME(@resolution_cfg_org_column) + N'=@organizationId
  AND ' + QUOTENAME(@resolution_cfg_status_column) + N'=@activeStatus;';
   EXEC sp_executesql @resolution_cfg_sql,
     N'@referenceId BIGINT,@organizationId BIGINT,@activeStatus NVARCHAR(80),@resolvedName NVARCHAR(300) OUTPUT',
     @referenceId=@resolution_dependency_id,
     @organizationId=@resolution_organization_id,
     @activeStatus=@resolution_cfg_status_value,
     @resolvedName=@resolution_dependency_name OUTPUT;
   IF @resolution_dependency_name IS NULL
     THROW 51207,'Selected dependency object is not active or does not belong to this organization.',1;
   IF @resolution_owner_id IS NOT NULL AND NOT EXISTS(
     SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@resolution_owner_id AND organization_id=@resolution_organization_id AND status='Active'
   )
     THROW 51208,'Selected Resolution Owner is not valid for this organization.',1;
   IF @p_id=0
   BEGIN
     SET @new_id=NULL;
     SELECT @new_id=resolution_id
     FROM grac_practice.practice_dependency_resolution
     WHERE organization_id=@resolution_organization_id
       AND practice_instance_id=@resolution_practice_instance_id
       AND dependency_type_id=@resolution_dependency_type_id
       AND resolved_dependency_id=@resolution_dependency_id;

     IF @new_id IS NULL
     BEGIN
       INSERT grac_practice.practice_dependency_resolution(
         organization_id,practice_instance_id,dependency_type_id,dependency_category,resolved_dependency_id,resolved_dependency_name,
         resolution_status_id,resolution_status,resolution_owner_id,resolution_dt,remarks,is_active,record_status_id,entered_by)
       VALUES(@resolution_organization_id,@resolution_practice_instance_id,@resolution_dependency_type_id,@resolution_dependency_category,@resolution_dependency_id,@resolution_dependency_name,
         @resolution_status_id,N'Resolved',@resolution_owner_id,SYSUTCDATETIME(),JSON_VALUE(@p_payload,'$.remarks'),1,@active_record_status_id,@p_usr_id);
       SET @new_id=SCOPE_IDENTITY();
     END
     ELSE
       UPDATE grac_practice.practice_dependency_resolution
       SET resolved_dependency_name=@resolution_dependency_name,
           resolution_status_id=@resolution_status_id,
           resolution_status=N'Resolved',
           resolution_owner_id=@resolution_owner_id,
           resolution_dt=SYSUTCDATETIME(),
           remarks=JSON_VALUE(@p_payload,'$.remarks'),
           is_active=1,
           record_status_id=@active_record_status_id,
           updated_by=@p_usr_id,
           updated_dt=SYSUTCDATETIME()
       WHERE resolution_id=@new_id;
   END
   ELSE
   BEGIN
     SET @new_id=@p_id;
     UPDATE grac_practice.practice_dependency_resolution
     SET dependency_type_id=@resolution_dependency_type_id,
         dependency_category=@resolution_dependency_category,
         resolved_dependency_id=@resolution_dependency_id,
         resolved_dependency_name=@resolution_dependency_name,
         resolution_status_id=@resolution_status_id,
         resolution_status=N'Resolved',
         resolution_owner_id=@resolution_owner_id,
         resolution_dt=SYSUTCDATETIME(),
         remarks=JSON_VALUE(@p_payload,'$.remarks'),
         is_active=1,
         record_status_id=@active_record_status_id,
         updated_by=@p_usr_id,
         updated_dt=SYSUTCDATETIME()
     WHERE resolution_id=@p_id
       AND organization_id=@resolution_organization_id
       AND practice_instance_id=@resolution_practice_instance_id;
     IF @@ROWCOUNT=0 THROW 51209,'Selected dependency resolution was not found.',1;
   END
 END
 ELSE IF @p_entity_type='repository-subscriptions'
 BEGIN
   IF @p_id=0 BEGIN
     INSERT grac_practice.repository_subscription(organization_id,authority_id,artifact_id,release_id,subscription_type,subscription_status,subscription_status_id,effective_dt,end_dt,status,record_status_id,entered_by)
     VALUES(JSON_VALUE(@p_payload,'$.organizationId'),NULLIF(JSON_VALUE(@p_payload,'$.authorityId'),''),NULLIF(JSON_VALUE(@p_payload,'$.artifactId'),''),NULLIF(JSON_VALUE(@p_payload,'$.releaseId'),''),COALESCE(JSON_VALUE(@p_payload,'$.subscriptionType'),'Manual'),COALESCE(JSON_VALUE(@p_payload,'$.subscriptionStatus'),'Active'),COALESCE(@payload_subscription_status_id,@active_subscription_status_id),NULLIF(JSON_VALUE(@p_payload,'$.effectiveDate'),''),NULLIF(JSON_VALUE(@p_payload,'$.endDate'),''),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.repository_subscription SET organization_id=JSON_VALUE(@p_payload,'$.organizationId'),authority_id=NULLIF(JSON_VALUE(@p_payload,'$.authorityId'),''),artifact_id=NULLIF(JSON_VALUE(@p_payload,'$.artifactId'),''),release_id=NULLIF(JSON_VALUE(@p_payload,'$.releaseId'),''),subscription_type=COALESCE(JSON_VALUE(@p_payload,'$.subscriptionType'),subscription_type),subscription_status=COALESCE(JSON_VALUE(@p_payload,'$.subscriptionStatus'),subscription_status),subscription_status_id=COALESCE(@payload_subscription_status_id,subscription_status_id),effective_dt=NULLIF(JSON_VALUE(@p_payload,'$.effectiveDate'),''),end_dt=NULLIF(JSON_VALUE(@p_payload,'$.endDate'),''),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),record_status_id=COALESCE(@payload_record_status_id,record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE subscription_id=@p_id;

   DECLARE @single_org_id BIGINT,@single_release_id BIGINT,@single_artifact_id BIGINT,@single_subscription_status NVARCHAR(40),@single_status NVARCHAR(30);
   SELECT @single_org_id=organization_id,@single_release_id=release_id,@single_artifact_id=artifact_id,@single_subscription_status=subscription_status,@single_status=status
   FROM grac_practice.repository_subscription WHERE subscription_id=@new_id;

   IF @single_status='Active' AND @single_subscription_status='Active' AND @single_release_id IS NOT NULL
   BEGIN
     ;WITH repository_controls AS (
       SELECT DISTINCT
         scm.control_id,
         c.control_code,
         c.control_name,
         c.description,
         c.objective,
         c.control_domain_id,
         c.control_sub_domain_id,
         COALESCE(scm.release_id,n.release_id) release_id,
         COALESCE(scm.artifact_id,r.artifact_id,@single_artifact_id) artifact_id,
         @new_id subscription_id
       FROM grac_new.source_control_map scm
       JOIN grac_new.source_structure_node n ON n.structure_node_id=scm.structure_node_id
       JOIN grac_new.release r ON r.release_id=n.release_id
       JOIN grac_new.control c ON c.control_id=scm.control_id AND c.status='Active'
       WHERE scm.status='Active' AND n.status='Active' AND COALESCE(scm.release_id,n.release_id)=@single_release_id
     )
     UPDATE oc SET
       control_code=rc.control_code,control_name=rc.control_name,description=rc.description,objective=rc.objective,
       control_domain_id=rc.control_domain_id,control_sub_domain_id=rc.control_sub_domain_id,
       subscription_id=rc.subscription_id,artifact_id=rc.artifact_id,status='Active',record_status_id=@active_record_status_id,
       origin_type=CASE WHEN oc.origin_type='Hybrid' THEN 'Hybrid' ELSE 'Repository' END,
       is_manually_added=0,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     FROM grac_practice.organization_control oc
     JOIN repository_controls rc ON rc.control_id=oc.repository_control_id AND rc.release_id=oc.release_id
     WHERE oc.organization_id=@single_org_id;

     ;WITH repository_controls AS (
       SELECT DISTINCT
         scm.control_id,c.control_code,c.control_name,c.description,c.objective,c.control_domain_id,c.control_sub_domain_id,
         COALESCE(scm.release_id,n.release_id) release_id,COALESCE(scm.artifact_id,r.artifact_id,@single_artifact_id) artifact_id,@new_id subscription_id
       FROM grac_new.source_control_map scm
       JOIN grac_new.source_structure_node n ON n.structure_node_id=scm.structure_node_id
       JOIN grac_new.release r ON r.release_id=n.release_id
       JOIN grac_new.control c ON c.control_id=scm.control_id AND c.status='Active'
       WHERE scm.status='Active' AND n.status='Active' AND COALESCE(scm.release_id,n.release_id)=@single_release_id
     )
     INSERT grac_practice.organization_control(
       organization_id,origin_type,repository_control_id,control_code,control_name,description,objective,control_domain_id,control_sub_domain_id,
       is_manually_added,subscription_id,release_id,artifact_id,applicability_status,applicability_status_id,criticality,status,record_status_id,entered_by)
     SELECT @single_org_id,'Repository',rc.control_id,rc.control_code,rc.control_name,rc.description,rc.objective,rc.control_domain_id,rc.control_sub_domain_id,
       0,rc.subscription_id,rc.release_id,rc.artifact_id,'Not Updated',@not_updated_applicability_status_id,'Medium','Active',@active_record_status_id,@p_usr_id
     FROM repository_controls rc
     WHERE NOT EXISTS(
       SELECT 1 FROM grac_practice.organization_control oc
       WHERE oc.organization_id=@single_org_id AND oc.repository_control_id=rc.control_id AND oc.release_id=rc.release_id
     );
   END
   ELSE
   BEGIN
     UPDATE oc SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     FROM grac_practice.organization_control oc
     WHERE oc.organization_id=@single_org_id AND oc.release_id=@single_release_id AND oc.is_manually_added=0;
   END
 END
 ELSE IF @p_entity_type='organization-controls'
  BEGIN
    DECLARE @org_control_applicability_status NVARCHAR(40)=CASE WHEN @p_id=0 THEN COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.applicabilityStatus'),''),N'Not Updated') ELSE COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.applicabilityStatus'),''),N'Applicable') END;
    DECLARE @org_control_applicability_status_id INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=@org_control_applicability_status OR status_name=@org_control_applicability_status);
    DECLARE @org_control_justification NVARCHAR(MAX)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.exclusionJustification'))),'');
    DECLARE @org_control_primary_owner NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.primaryOwner'))),'');
    DECLARE @org_control_secondary_owner NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.secondaryOwner'))),'');
    DECLARE @org_control_business_function_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.businessFunctionId'),''));
    DECLARE @org_control_criticality NVARCHAR(30)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.criticality'))),'');

    IF @org_control_applicability_status IN (N'Not Applicable',N'Deferred',N'Not Implemented',N'Retired') AND @org_control_justification IS NULL
       THROW 51024,'Justification is required when control applicability is Not Applicable, Deferred, Not Implemented, or Retired.',1;
    IF @org_control_applicability_status=N'Applicable' AND (@org_control_primary_owner IS NULL OR @org_control_business_function_id IS NULL OR @org_control_criticality IS NULL)
       THROW 51025,'Primary Owner, Business Function, and Criticality are required when control applicability is Applicable.',1;

    IF @p_id=0 BEGIN
      INSERT grac_practice.organization_control(organization_id,origin_type,repository_control_id,control_code,control_name,description,objective,business_justification,is_manually_added,applicability_status,applicability_status_id,exclusion_justification,primary_owner,secondary_owner,backup_owner,business_function_id,criticality,status,record_status_id,entered_by)
      VALUES(JSON_VALUE(@p_payload,'$.organizationId'),'Organization',NULL,JSON_VALUE(@p_payload,'$.code'),JSON_VALUE(@p_payload,'$.name'),JSON_VALUE(@p_payload,'$.description'),JSON_VALUE(@p_payload,'$.objective'),JSON_VALUE(@p_payload,'$.businessJustification'),1,@org_control_applicability_status,COALESCE(@org_control_applicability_status_id,@not_updated_applicability_status_id),NULL,@org_control_primary_owner,@org_control_secondary_owner,JSON_VALUE(@p_payload,'$.backupOwner'),@org_control_business_function_id,@org_control_criticality,'Active',@active_record_status_id,@p_usr_id);
      SET @new_id=SCOPE_IDENTITY();
    END
    ELSE UPDATE grac_practice.organization_control SET
      organization_id=COALESCE(JSON_VALUE(@p_payload,'$.organizationId'),organization_id),
      origin_type=CASE WHEN is_manually_added=1 THEN 'Organization' ELSE origin_type END,
      repository_control_id=CASE WHEN is_manually_added=1 THEN NULL ELSE repository_control_id END,
      control_code=CASE WHEN is_manually_added=1 THEN COALESCE(JSON_VALUE(@p_payload,'$.code'),control_code) ELSE control_code END,
      control_name=CASE WHEN is_manually_added=1 THEN COALESCE(JSON_VALUE(@p_payload,'$.name'),control_name) ELSE control_name END,
      description=CASE WHEN is_manually_added=1 THEN JSON_VALUE(@p_payload,'$.description') ELSE description END,
      objective=CASE WHEN is_manually_added=1 THEN JSON_VALUE(@p_payload,'$.objective') ELSE objective END,
      business_justification=CASE WHEN is_manually_added=1 THEN JSON_VALUE(@p_payload,'$.businessJustification') ELSE business_justification END,
      applicability_status=@org_control_applicability_status,
      applicability_status_id=COALESCE(@org_control_applicability_status_id,applicability_status_id),
      exclusion_justification=CASE WHEN @org_control_applicability_status=N'Applicable' THEN NULL ELSE @org_control_justification END,
      primary_owner=@org_control_primary_owner,
      secondary_owner=@org_control_secondary_owner,
      backup_owner=JSON_VALUE(@p_payload,'$.backupOwner'),
      business_function_id=@org_control_business_function_id,
      criticality=COALESCE(@org_control_criticality,criticality),
      status='Active',
      record_status_id=@active_record_status_id,
      updated_by=@p_usr_id,
      updated_dt=SYSUTCDATETIME()
    WHERE organization_control_id=@p_id;
  END
 ELSE IF @p_entity_type='control-applicability'
 BEGIN
  DECLARE @control_applicability_status NVARCHAR(40)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.applicabilityStatus'),''),'Applicable');
  DECLARE @control_justification NVARCHAR(MAX)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.exclusionJustification'))),'');
  DECLARE @control_primary_owner NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.primaryOwner'))),'');
  DECLARE @control_criticality NVARCHAR(30)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.criticality'))),'');
  IF @p_id=0 THROW 51020,'Select an organization control before saving applicability.',1;
  IF @control_applicability_status IN ('Not Applicable','Deferred','Accepted Risk') AND @control_justification IS NULL
     THROW 51021,'Justification is required when control applicability is Not Applicable, Deferred, or Accepted Risk.',1;
  IF @control_applicability_status='Applicable' AND (@control_primary_owner IS NULL OR @control_criticality IS NULL)
     THROW 51023,'Primary Owner and Criticality are required when control applicability is Applicable.',1;

  UPDATE grac_practice.organization_control SET
     applicability_status=@control_applicability_status,
     applicability_status_id=COALESCE(@payload_applicability_status_id,applicability_status_id),
     exclusion_justification=CASE WHEN @control_applicability_status='Applicable' THEN NULL ELSE @control_justification END,
     primary_owner=@control_primary_owner,
     secondary_owner=NULLIF(JSON_VALUE(@p_payload,'$.secondaryOwner'),''),
     business_function_id=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.businessFunctionId'),'')),
     criticality=COALESCE(@control_criticality,criticality),
     status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),''),status),
     record_status_id=COALESCE(@payload_record_status_id,record_status_id),
     updated_by=@p_usr_id,
     updated_dt=SYSUTCDATETIME()
  WHERE organization_control_id=@p_id;
  IF @@ROWCOUNT=0 THROW 51022,'Selected organization control was not found.',1;

  -- ------------------------------------------------------------------
  -- Practice import + cleanup delegated to the helpers created by
  -- migration 057 (grac_practice.sp_apply_practices_for_control /
  -- sp_unapply_practices_for_control). Those SPs:
  --   * Dedup practices by (organization_id, repository_requirement_id)
  --     across Controls -- no duplicate Practice rows when the same
  --     ISO practice is mapped to multiple applicable Controls.
  --   * Maintain the many-to-many mapping in
  --     grac_practice.organization_control_requirement so the app can
  --     see every Control that a Practice belongs to.
  --   * On Not Applicable / Deferred / Retired: soft-inactivate only
  --     THIS control's mapping rows; the Practice itself only gets
  --     soft-inactivated when no active mapping remains.
  -- The 'primary' organization_control_id column on organization_requirement
  -- stays populated for back-compat with the ~89 existing SP/view callers.
  -- ------------------------------------------------------------------
  IF @control_applicability_status='Applicable'
  BEGIN
    DECLARE @mapped_requirements INT=0;
    DECLARE @imported_requirements INT=0;
    EXEC grac_practice.sp_apply_practices_for_control
      @organization_control_id = @p_id,
      @actor                   = @p_usr_id,
      @mapped_count            = @mapped_requirements OUTPUT,
      @imported_count          = @imported_requirements OUTPUT;

    IF @mapped_requirements=0
      SET @result_message=N'Control applicability saved. No requirements are mapped to this control in the repository.';
    ELSE IF @imported_requirements=0
      SET @result_message=N'Control applicability saved. Requirements mapped to this control were already imported.';
    ELSE
      SET @result_message=CONCAT(N'Control applicability saved. ',@imported_requirements,N' practice(s) imported into Organization Practices.');
  END
  ELSE IF @control_applicability_status IN ('Not Applicable','Deferred','Retired','Accepted Risk')
  BEGIN
    DECLARE @unmapped_requirements INT=0;
    EXEC grac_practice.sp_unapply_practices_for_control
      @organization_control_id = @p_id,
      @actor                   = @p_usr_id,
      @deactivated_count       = @unmapped_requirements OUTPUT;

    IF @unmapped_requirements=0
      SET @result_message=N'Control applicability saved.';
    ELSE
      SET @result_message=CONCAT(N'Control applicability saved. ',@unmapped_requirements,N' practice mapping(s) deactivated for this control.');
  END
 END
 ELSE IF @p_entity_type='organization-requirements'
 BEGIN
   DECLARE @org_requirement_applicability_status NVARCHAR(40)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.applicabilityStatus'),''),'Not Updated');
   DECLARE @org_requirement_justification NVARCHAR(MAX)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.exclusionJustification'))),'');
   DECLARE @org_requirement_practice_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceOwnerId'),''));
   DECLARE @org_requirement_practice_owner NVARCHAR(200)=NULL;
   DECLARE @org_requirement_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @org_requirement_control_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationControlId'),''));
   -- Custom Practice Code Auto Generation (change request): true "custom
   -- practice" creation on this branch is exactly the condition already used
   -- below to auto-parent the row under the ORG-PRACTICES container -- a
   -- brand-new row (@p_id=0), no organization control chosen, origin
   -- 'Organization'. Pulled into its own flag so the code-generation block
   -- can reuse it without duplicating the condition.
   DECLARE @org_requirement_is_custom_create BIT=CASE WHEN @p_id=0 AND @org_requirement_control_id IS NULL AND COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.originType'),''),'Organization')='Organization' THEN 1 ELSE 0 END;
   DECLARE @org_requirement_generated_code NVARCHAR(50)=NULL;
   IF @org_requirement_org_id IS NULL THROW 51035,'Organization is required.',1;
   IF @org_requirement_is_custom_create=1
   BEGIN
     SELECT TOP (1) @org_requirement_control_id=organization_control_id
     FROM grac_practice.organization_control
     WHERE organization_id=@org_requirement_org_id
       AND origin_type='Organization'
       AND control_code='ORG-PRACTICES'
       AND status='Active'
     ORDER BY organization_control_id;

     IF @org_requirement_control_id IS NULL
     BEGIN
       INSERT grac_practice.organization_control(
         organization_id,origin_type,repository_control_id,control_code,control_name,description,objective,is_manually_added,
         applicability_status,applicability_status_id,criticality,status,record_status_id,entered_by)
       VALUES(
         @org_requirement_org_id,'Organization',NULL,'ORG-PRACTICES','Organization Defined Practices',
         'System container for manually added organization practices.','Manual practices created by the organization.',1,
         'Applicable',COALESCE((SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable'),@not_updated_applicability_status_id),
         'Medium','Active',@active_record_status_id,@p_usr_id);
       SET @org_requirement_control_id=SCOPE_IDENTITY();
     END

     -- Auto-generate the Practice Code (PR_001, PR_002, ...). Never taken
     -- from the payload for this path (requirement 6, "no manual
     -- override") -- see the requirement_code column of the INSERT below.
     -- sp_getapplock serializes this against every other custom-practice
     -- create (this branch and the practices branch both use the same
     -- resource name) so two concurrent creates cannot compute the same
     -- next number (requirement 10). @LockOwner='Transaction' auto-releases
     -- at this procedure's COMMIT/ROLLBACK (BEGIN TRAN / SET XACT_ABORT ON
     -- at the top of this procedure cover the whole body, confirmed down to
     -- the COMMIT right before the final SELECT).
     DECLARE @org_requirement_lock_result INT;
     EXEC @org_requirement_lock_result=sp_getapplock @Resource='pm_custom_practice_code_seq',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=15000;
     IF @org_requirement_lock_result<0 THROW 51210,'Unable to generate Practice Code right now. Please try again.',1;

     DECLARE @org_requirement_next_seq INT;
     SELECT @org_requirement_next_seq=ISNULL(MAX(seq),0)+1
     FROM (
       SELECT TRY_CONVERT(INT,SUBSTRING(requirement_code,4,50)) seq FROM grac_practice.organization_requirement WHERE requirement_code LIKE 'PR[_]%'
       UNION ALL
       SELECT TRY_CONVERT(INT,SUBSTRING(practice_code,4,50)) seq FROM grac_practice.practice WHERE practice_code LIKE 'PR[_]%'
     ) existing_codes
     WHERE seq IS NOT NULL;

     -- Zero-pad to 3 digits (PR_001 .. PR_999); beyond that, grow the number
     -- naturally instead of truncating it (RIGHT('000'+CAST(1000...),3)
     -- would otherwise cut a 4-digit number back down to 3 digits).
     SET @org_requirement_generated_code='PR_'+CASE WHEN @org_requirement_next_seq<1000 THEN RIGHT('000'+CAST(@org_requirement_next_seq AS VARCHAR(10)),3) ELSE CAST(@org_requirement_next_seq AS VARCHAR(10)) END;
   END
   IF @org_requirement_practice_owner_id IS NOT NULL
   BEGIN
     IF NOT EXISTS(
       SELECT 1
       FROM grac_practice.organization_employee
       WHERE employee_id=@org_requirement_practice_owner_id
         AND status='Active'
         AND (@org_requirement_org_id IS NULL OR organization_id=@org_requirement_org_id)
     )
       THROW 51033,'Selected Owner is not valid for this organization.',1;

     SELECT @org_requirement_practice_owner=employee_name
     FROM grac_practice.organization_employee
     WHERE employee_id=@org_requirement_practice_owner_id;
   END
   IF @org_requirement_applicability_status IN ('Not Applicable','Deferred','Accepted Risk') AND @org_requirement_justification IS NULL
     THROW 51032,'Reason / Justification is required when applicability is Not Applicable, Deferred, or Accepted Risk.',1;
   IF @org_requirement_applicability_status='Applicable' AND @org_requirement_practice_owner_id IS NULL
     THROW 51034,'Owner is required when practice is Applicable.',1;

   IF @p_id=0 BEGIN
     INSERT grac_practice.organization_requirement(organization_id,origin_type,repository_requirement_id,organization_control_id,requirement_code,requirement_name,requirement_statement,objective,applicability_status,applicability_status_id,exclusion_justification,implementation_status,implementation_status_id,status,record_status_id,entered_by)
     VALUES(@org_requirement_org_id,COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.originType'),''),'Organization'),NULLIF(JSON_VALUE(@p_payload,'$.repositoryRequirementId'),''),@org_requirement_control_id,COALESCE(@org_requirement_generated_code,JSON_VALUE(@p_payload,'$.code')),JSON_VALUE(@p_payload,'$.name'),JSON_VALUE(@p_payload,'$.statement'),JSON_VALUE(@p_payload,'$.objective'),@org_requirement_applicability_status,COALESCE(@payload_applicability_status_id,@not_updated_applicability_status_id),@org_requirement_justification,COALESCE(JSON_VALUE(@p_payload,'$.implementationStatus'),'Not Started'),COALESCE(@payload_implementation_status_id,@not_started_implementation_status_id),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.organization_requirement
     SET organization_id=COALESCE(JSON_VALUE(@p_payload,'$.organizationId'),organization_id),
         origin_type=COALESCE(JSON_VALUE(@p_payload,'$.originType'),origin_type),
         repository_requirement_id=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.repositoryRequirementId'),''),repository_requirement_id),
         organization_control_id=COALESCE(JSON_VALUE(@p_payload,'$.organizationControlId'),organization_control_id),
         requirement_code=COALESCE(JSON_VALUE(@p_payload,'$.code'),requirement_code),
         requirement_name=COALESCE(JSON_VALUE(@p_payload,'$.name'),requirement_name),
         requirement_statement=COALESCE(JSON_VALUE(@p_payload,'$.statement'),requirement_statement),
         objective=COALESCE(JSON_VALUE(@p_payload,'$.objective'),objective),
         applicability_status=COALESCE(JSON_VALUE(@p_payload,'$.applicabilityStatus'),applicability_status),
         applicability_status_id=COALESCE(@payload_applicability_status_id,applicability_status_id),
         exclusion_justification=COALESCE(@org_requirement_justification,exclusion_justification),
         implementation_status=COALESCE(JSON_VALUE(@p_payload,'$.implementationStatus'),implementation_status),
         implementation_status_id=COALESCE(@payload_implementation_status_id,implementation_status_id),
         status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),
         record_status_id=COALESCE(@payload_record_status_id,record_status_id),
         updated_by=@p_usr_id,
         updated_dt=SYSUTCDATETIME()
     WHERE organization_requirement_id=@p_id;

   DECLARE @saved_org_requirement_id BIGINT=CASE WHEN @p_id=0 THEN @new_id ELSE @p_id END;
   IF @saved_org_requirement_id IS NOT NULL AND @saved_org_requirement_id>0
   BEGIN
     UPDATE p
       SET practice_owner_id=@org_requirement_practice_owner_id,
           practice_owner=@org_requirement_practice_owner,
           applicability_status=@org_requirement_applicability_status,
           applicability_status_id=COALESCE(@payload_applicability_status_id,p.applicability_status_id),
           exclusion_justification=COALESCE(@org_requirement_justification,p.exclusion_justification),
           updated_by=@p_usr_id,
           updated_dt=SYSUTCDATETIME()
     FROM grac_practice.practice p
     WHERE p.organization_requirement_id=@saved_org_requirement_id;

     INSERT grac_practice.practice(
       organization_id,organization_requirement_id,origin_type,practice_code,practice_name,description,practice_owner_id,practice_owner,
       applicability_status,applicability_status_id,exclusion_justification,status,record_status_id,entered_by)
     SELECT q.organization_id,q.organization_requirement_id,q.origin_type,q.requirement_code,q.requirement_name,q.requirement_statement,
       @org_requirement_practice_owner_id,@org_requirement_practice_owner,
       @org_requirement_applicability_status,COALESCE(@payload_applicability_status_id,@not_updated_applicability_status_id),
       COALESCE(@org_requirement_justification,q.exclusion_justification),
       'Active',COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id
     FROM grac_practice.organization_requirement q
     WHERE q.organization_requirement_id=@saved_org_requirement_id
       AND NOT EXISTS(
         SELECT 1
         FROM grac_practice.practice p
         WHERE p.organization_id=q.organization_id
           AND p.organization_requirement_id=q.organization_requirement_id
       );

     -- Source Statement mapping (change request, 2026-09): the Add/Edit
     -- Practice form on Organization Requirements lets the user pick which
     -- subscribed-release Source Statements this practice maps to. The
     -- picker submits the FULL desired set as mappedOrgStatementIds (an
     -- array of organization_framework_statements.org_statement_id values)
     -- and this block reconciles organization_statement_practice_mapping
     -- to match it exactly -- insert/reactivate what's newly selected,
     -- deactivate what was dropped. Gated on the key actually being present
     -- in the payload (JSON_QUERY returns NULL both when the key is absent
     -- and when its value is JSON null, but returns '[]' for an empty
     -- array) so callers that don't send this field -- Update Applicability,
     -- quick edits, any other save that reuses this same branch -- leave
     -- existing mappings untouched instead of wiping them out.
     IF JSON_QUERY(@p_payload,'$.mappedOrgStatementIds') IS NOT NULL
     BEGIN
       DECLARE @mapped_statement_ids TABLE(org_statement_id BIGINT PRIMARY KEY);
       INSERT @mapped_statement_ids(org_statement_id)
       SELECT DISTINCT v.org_statement_id
       FROM (
         SELECT TRY_CONVERT(BIGINT,[value]) org_statement_id
         FROM OPENJSON(@p_payload,'$.mappedOrgStatementIds')
       ) v
       -- Only statements that actually belong to this organization can be
       -- mapped -- silently drops anything forged/stale rather than
       -- throwing, since the picker itself only ever offers this org's own
       -- subscribed-release statements.
       WHERE v.org_statement_id IS NOT NULL
         AND EXISTS(
           SELECT 1 FROM grac_practice.organization_framework_statements ofs
           WHERE ofs.org_statement_id=v.org_statement_id
             AND ofs.organization_id=@org_requirement_org_id
         );

       DECLARE @mapping_repository_requirement_id BIGINT=(SELECT repository_requirement_id FROM grac_practice.organization_requirement WHERE organization_requirement_id=@saved_org_requirement_id);

       -- Reactivate/insert every currently-selected statement.
       MERGE grac_practice.organization_statement_practice_mapping AS target
       USING (
         SELECT m.org_statement_id,ofs.organization_id,ofs.release_id,ofs.framework_statement_id
         FROM @mapped_statement_ids m
         JOIN grac_practice.organization_framework_statements ofs ON ofs.org_statement_id=m.org_statement_id
       ) AS src
         ON target.organization_id=src.organization_id
        AND target.org_statement_id=src.org_statement_id
        AND target.org_practice_id=@saved_org_requirement_id
       WHEN MATCHED AND target.status<>'Active' THEN UPDATE SET
         status='Active',
         record_status_id=@active_record_status_id,
         framework_statement_id=src.framework_statement_id,
         release_id=src.release_id,
         updated_by=@p_usr_id,
         updated_dt=SYSUTCDATETIME()
       WHEN NOT MATCHED BY TARGET THEN INSERT(
         organization_id,org_statement_id,framework_statement_id,repository_requirement_id,org_practice_id,release_id,status,record_status_id,entered_by)
       VALUES(
         src.organization_id,src.org_statement_id,src.framework_statement_id,@mapping_repository_requirement_id,@saved_org_requirement_id,src.release_id,'Active',@active_record_status_id,@p_usr_id);

       -- Deactivate mappings for this practice that are no longer selected.
       UPDATE grac_practice.organization_statement_practice_mapping
         SET status='Inactive',
             record_status_id=@inactive_record_status_id,
             updated_by=@p_usr_id,
             updated_dt=SYSUTCDATETIME()
       WHERE org_practice_id=@saved_org_requirement_id
         AND status='Active'
         AND org_statement_id NOT IN (SELECT org_statement_id FROM @mapped_statement_ids);
     END
   END
 END
 ELSE IF @p_entity_type='practices'
 BEGIN
   DECLARE @practice_applicability_status NVARCHAR(40)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.applicabilityStatus'),''),'Not Updated');
   DECLARE @practice_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceOwnerId'),''));
   DECLARE @practice_owner NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.practiceOwner'))),'');
   DECLARE @practice_justification NVARCHAR(MAX)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.exclusionJustification'))),'');
   DECLARE @practice_organization_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @practice_organization_requirement_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationRequirementId'),''));
   DECLARE @practice_origin_type NVARCHAR(30)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.originType'),''),'Organization');
   -- Custom Practice Code Auto Generation (change request): same condition
   -- already used below to auto-create the linked organization_requirement
   -- container row -- a brand-new practice (@p_id=0), not linked to an
   -- existing organization requirement, origin 'Organization'.
   DECLARE @practice_is_custom_create BIT=CASE WHEN @p_id=0 AND @practice_organization_requirement_id IS NULL AND @practice_origin_type='Organization' THEN 1 ELSE 0 END;
   DECLARE @practice_generated_code NVARCHAR(50)=NULL;
   IF @practice_organization_id IS NULL THROW 51028,'Organization is required.',1;
   IF @practice_is_custom_create=1
   BEGIN
     -- Same generation as the organization-requirements branch, sharing the
     -- same sp_getapplock resource name so a custom create on either screen
     -- serializes against the other and neither can land on the same
     -- PR_NNN code (requirement 10). See that branch for the full
     -- explanation of the lock and the padding formula.
     DECLARE @practice_lock_result INT;
     EXEC @practice_lock_result=sp_getapplock @Resource='pm_custom_practice_code_seq',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=15000;
     IF @practice_lock_result<0 THROW 51212,'Unable to generate Practice Code right now. Please try again.',1;

     DECLARE @practice_next_seq INT;
     SELECT @practice_next_seq=ISNULL(MAX(seq),0)+1
     FROM (
       SELECT TRY_CONVERT(INT,SUBSTRING(requirement_code,4,50)) seq FROM grac_practice.organization_requirement WHERE requirement_code LIKE 'PR[_]%'
       UNION ALL
       SELECT TRY_CONVERT(INT,SUBSTRING(practice_code,4,50)) seq FROM grac_practice.practice WHERE practice_code LIKE 'PR[_]%'
     ) existing_codes
     WHERE seq IS NOT NULL;

     SET @practice_generated_code='PR_'+CASE WHEN @practice_next_seq<1000 THEN RIGHT('000'+CAST(@practice_next_seq AS VARCHAR(10)),3) ELSE CAST(@practice_next_seq AS VARCHAR(10)) END;

     DECLARE @practice_container_control_id BIGINT=NULL;
     SELECT TOP (1) @practice_container_control_id=organization_control_id
     FROM grac_practice.organization_control
     WHERE organization_id=@practice_organization_id
       AND origin_type='Organization'
       AND control_code='ORG-PRACTICES'
       AND status='Active'
     ORDER BY organization_control_id;

     IF @practice_container_control_id IS NULL
     BEGIN
       INSERT grac_practice.organization_control(
         organization_id,origin_type,repository_control_id,control_code,control_name,description,objective,is_manually_added,
         applicability_status,applicability_status_id,criticality,status,record_status_id,entered_by)
       VALUES(
         @practice_organization_id,'Organization',NULL,'ORG-PRACTICES','Organization Defined Practices',
         'System container for manually added organization practices.','Manual practices created by the organization.',1,
         'Applicable',COALESCE((SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable'),@not_updated_applicability_status_id),
         'Medium','Active',@active_record_status_id,@p_usr_id);
       SET @practice_container_control_id=SCOPE_IDENTITY();
     END

     SELECT TOP (1) @practice_organization_requirement_id=organization_requirement_id
     FROM grac_practice.organization_requirement
     WHERE organization_id=@practice_organization_id
       AND organization_control_id=@practice_container_control_id
       AND requirement_code=COALESCE(@practice_generated_code,JSON_VALUE(@p_payload,'$.code'))
       AND status='Active'
     ORDER BY organization_requirement_id;

     IF @practice_organization_requirement_id IS NULL
     BEGIN
       INSERT grac_practice.organization_requirement(
         organization_id,origin_type,repository_requirement_id,organization_control_id,requirement_code,requirement_name,
         requirement_statement,objective,applicability_status,applicability_status_id,exclusion_justification,
         implementation_status,implementation_status_id,status,record_status_id,entered_by)
       VALUES(
         @practice_organization_id,'Organization',NULL,@practice_container_control_id,COALESCE(@practice_generated_code,JSON_VALUE(@p_payload,'$.code')),JSON_VALUE(@p_payload,'$.name'),
         JSON_VALUE(@p_payload,'$.description'),NULL,'Applicable',
         COALESCE((SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable'),@not_updated_applicability_status_id),
         NULL,'Not Started',@not_started_implementation_status_id,'Active',@active_record_status_id,@p_usr_id);
       SET @practice_organization_requirement_id=SCOPE_IDENTITY();
     END
   END
   IF @practice_owner_id IS NOT NULL
   BEGIN
     IF NOT EXISTS(
       SELECT 1
       FROM grac_practice.organization_employee
       WHERE employee_id=@practice_owner_id
         AND status='Active'
         AND (@practice_organization_id IS NULL OR organization_id=@practice_organization_id)
     )
       THROW 51027,'Selected Owner is not valid for this organization.',1;

     SELECT @practice_owner=employee_name
     FROM grac_practice.organization_employee
     WHERE employee_id=@practice_owner_id;
   END
   IF @practice_applicability_status IN ('Not Applicable','Deferred','Accepted Risk') AND @practice_justification IS NULL
     THROW 51025,'Reason / Justification is required when practice applicability is Not Applicable, Deferred, or Accepted Risk.',1;
   IF @practice_applicability_status='Applicable' AND @practice_owner_id IS NULL
     THROW 51026,'Owner is required when practice is Applicable.',1;
   IF @p_id=0 AND @practice_organization_requirement_id IS NULL
     THROW 51029,'Organization Requirement is required for repository-linked practices.',1;

   IF @p_id=0 BEGIN
     INSERT grac_practice.practice(organization_id,organization_requirement_id,origin_type,practice_code,practice_name,description,practice_owner_id,practice_owner,applicability_status,applicability_status_id,exclusion_justification,status,record_status_id,entered_by)
     VALUES(@practice_organization_id,@practice_organization_requirement_id,@practice_origin_type,COALESCE(@practice_generated_code,JSON_VALUE(@p_payload,'$.code')),JSON_VALUE(@p_payload,'$.name'),JSON_VALUE(@p_payload,'$.description'),@practice_owner_id,@practice_owner,@practice_applicability_status,COALESCE(@payload_applicability_status_id,@not_updated_applicability_status_id),@practice_justification,COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.practice SET organization_id=COALESCE(JSON_VALUE(@p_payload,'$.organizationId'),organization_id),organization_requirement_id=COALESCE(JSON_VALUE(@p_payload,'$.organizationRequirementId'),organization_requirement_id),origin_type=COALESCE(JSON_VALUE(@p_payload,'$.originType'),origin_type),practice_code=COALESCE(JSON_VALUE(@p_payload,'$.code'),practice_code),practice_name=COALESCE(JSON_VALUE(@p_payload,'$.name'),practice_name),description=COALESCE(JSON_VALUE(@p_payload,'$.description'),description),practice_owner_id=@practice_owner_id,practice_owner=@practice_owner,applicability_status=@practice_applicability_status,applicability_status_id=COALESCE(@payload_applicability_status_id,applicability_status_id),exclusion_justification=COALESCE(@practice_justification,exclusion_justification),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),record_status_id=COALESCE(@payload_record_status_id,record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE practice_id=@p_id;
 END
 ELSE IF @p_entity_type='practice-instances'
 BEGIN
   DECLARE @instance_practice_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceId'),''));
   DECLARE @instance_organization_requirement_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationRequirementId'),''));

   IF @instance_practice_id IS NULL AND @instance_organization_requirement_id IS NOT NULL
   BEGIN
     UPDATE p
       SET organization_requirement_id=q.organization_requirement_id,
           updated_by=@p_usr_id,
           updated_dt=SYSUTCDATETIME()
     FROM grac_practice.practice p
     JOIN grac_practice.organization_requirement q
       ON q.organization_requirement_id=@instance_organization_requirement_id
      AND q.organization_id=p.organization_id
      AND (q.requirement_code=p.practice_code OR q.requirement_name=p.practice_name)
     WHERE p.organization_requirement_id IS NULL;

     INSERT grac_practice.practice(
       organization_id,organization_requirement_id,origin_type,practice_code,practice_name,description,practice_owner,
       applicability_status,applicability_status_id,status,record_status_id,entered_by)
     SELECT q.organization_id,q.organization_requirement_id,q.origin_type,q.requirement_code,q.requirement_name,q.requirement_statement,NULL,
       'Applicable',(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable'),'Active',@active_record_status_id,@p_usr_id
     FROM grac_practice.organization_requirement q
     WHERE q.organization_requirement_id=@instance_organization_requirement_id
       AND (
         q.applicability_status_id=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable')
         OR q.applicability_status='Applicable'
       )
       AND NOT EXISTS(
         SELECT 1
         FROM grac_practice.practice p
         WHERE p.organization_id=q.organization_id
           AND p.organization_requirement_id=q.organization_requirement_id
       );

     SELECT @instance_practice_id=p.practice_id
     FROM grac_practice.practice p
     WHERE p.organization_requirement_id=@instance_organization_requirement_id
       AND p.organization_id=JSON_VALUE(@p_payload,'$.organizationId');
   END;

   IF @instance_practice_id IS NULL
     THROW 51031,'Practice context is required to save a Practice Instance.',1;

   DECLARE @instance_primary_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.primaryOwnerId'),''));
   DECLARE @instance_primary_owner_name NVARCHAR(200)=NULLIF(JSON_VALUE(@p_payload,'$.primaryOwner'),'');
   DECLARE @instance_department_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.departmentId'),''));
   DECLARE @instance_department_name NVARCHAR(200)=NULLIF(JSON_VALUE(@p_payload,'$.department'),'');
   DECLARE @instance_execution_frequency_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.executionFrequencyId'),''));
   DECLARE @instance_assurance_frequency_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.assuranceFrequencyId'),''));
   DECLARE @instance_frequency_id INT=COALESCE(@instance_execution_frequency_id,TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.frequencyId'),'')));
   DECLARE @instance_frequency_type NVARCHAR(40)=NULLIF(JSON_VALUE(@p_payload,'$.frequencyType'),'');
   DECLARE @instance_frequency_value INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.frequencyValue'),''));
   DECLARE @instance_frequency_unit NVARCHAR(40)=NULLIF(JSON_VALUE(@p_payload,'$.frequencyUnit'),'');
   DECLARE @instance_frequency_is_custom BIT=0;
   IF @instance_primary_owner_id IS NOT NULL
   BEGIN
     SELECT
       @instance_primary_owner_name=e.employee_name,
       @instance_department_id=COALESCE(@instance_department_id,e.department_id),
       @instance_department_name=COALESCE(d.department_name,e.department,@instance_department_name)
     FROM grac_practice.organization_employee e
     LEFT JOIN grac_practice.organization_department d ON d.department_id=e.department_id
     WHERE e.employee_id=@instance_primary_owner_id
       AND e.organization_id=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.organizationId'))
       AND e.status='Active';
     IF @instance_primary_owner_name IS NULL
       THROW 51036,'Selected Instance Owner is not valid for this organization.',1;
   END
   IF @instance_department_id IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_department WHERE department_id=@instance_department_id AND organization_id=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.organizationId')) AND status='Active')
     THROW 51037,'Selected owner Department is not valid for this organization.',1;

   IF @instance_execution_frequency_id IS NULL
     THROW 51038,'Execution Frequency is required.',1;
   IF @instance_assurance_frequency_id IS NULL
     THROW 51039,'Assurance Frequency is required.',1;
   IF NOT EXISTS(SELECT 1 FROM grac_practice.frequency_master WHERE frequency_id=@instance_execution_frequency_id AND is_active=1)
     THROW 51040,'Selected Execution Frequency is not valid.',1;
   IF NOT EXISTS(SELECT 1 FROM grac_practice.frequency_master WHERE frequency_id=@instance_assurance_frequency_id AND is_active=1)
     THROW 51041,'Selected Assurance Frequency is not valid.',1;

   IF @instance_frequency_id IS NULL AND @instance_frequency_type IS NOT NULL
     SELECT @instance_frequency_id=frequency_id
     FROM grac_practice.frequency_master
     WHERE frequency_code=@instance_frequency_type OR frequency_name=@instance_frequency_type;
   IF @instance_frequency_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.frequency_master WHERE frequency_id=@instance_frequency_id AND is_active=1)
     THROW 51034,'Selected Frequency is not valid.',1;
   SELECT @instance_frequency_type=frequency_code,
          @instance_frequency_is_custom=is_custom,
          @instance_frequency_value=CASE WHEN is_custom=1 THEN @instance_frequency_value ELSE frequency_value END,
          @instance_frequency_unit=CASE WHEN is_custom=1 THEN @instance_frequency_unit ELSE frequency_unit END
   FROM grac_practice.frequency_master
   WHERE frequency_id=@instance_frequency_id;
   IF @instance_frequency_id IS NULL AND @instance_frequency_type IS NOT NULL AND @instance_frequency_type='Custom'
     SET @instance_frequency_is_custom=1;
   IF @instance_frequency_id IS NULL AND @instance_frequency_type IS NOT NULL AND @instance_frequency_type<>'Custom'
   BEGIN
     SELECT
       @instance_frequency_value=CASE @instance_frequency_type
         WHEN 'Daily' THEN 1
         WHEN 'Weekly' THEN 1
         WHEN 'Monthly' THEN 1
         WHEN 'Quarterly' THEN 3
         WHEN 'Half-Yearly' THEN 6
         WHEN 'Annual' THEN 12
         ELSE NULL
       END,
       @instance_frequency_unit=CASE @instance_frequency_type
         WHEN 'Daily' THEN 'Day'
         WHEN 'Weekly' THEN 'Week'
         WHEN 'Monthly' THEN 'Month'
         WHEN 'Quarterly' THEN 'Month'
         WHEN 'Half-Yearly' THEN 'Month'
         WHEN 'Annual' THEN 'Month'
         ELSE NULL
       END;
   END
   IF @instance_frequency_is_custom=1 AND (@instance_frequency_value IS NULL OR @instance_frequency_unit IS NULL)
     THROW 51033,'Frequency Value and Frequency Unit are required when Frequency is Custom.',1;

   -- Validate NOT NULL columns before INSERT to give clear error messages
   DECLARE @instance_organization_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @instance_code NVARCHAR(100)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.code'))),'');
   DECLARE @instance_name NVARCHAR(300)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @instance_record_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @instance_implementation_status_id INT=COALESCE(@payload_implementation_status_id,@active_implementation_status_id,@not_started_implementation_status_id);
   IF @instance_organization_id IS NULL
     THROW 51042,'Organization is required to save a Practice Instance.',1;
   IF @instance_code IS NULL
     THROW 51043,'Instance Code is required.',1;
   IF @instance_name IS NULL
     THROW 51044,'Instance Name is required.',1;
   IF @instance_record_status_id IS NULL
     THROW 51045,'Record Status master data is missing. Please run the database setup scripts.',1;
   IF @instance_implementation_status_id IS NULL
     THROW 51046,'Implementation Status master data is missing. Please run the database setup scripts.',1;

   IF @p_id=0 BEGIN
     INSERT grac_practice.practice_instance(practice_id,organization_id,instance_code,instance_name,primary_owner_id,primary_owner,secondary_owner,business_function_id,department_id,department,execution_frequency_id,assurance_frequency_id,frequency_id,frequency_type,frequency_value,frequency_unit,assurance_mode,criticality,implementation_status,implementation_status_id,status,record_status_id,entered_by)
     VALUES(@instance_practice_id,@instance_organization_id,@instance_code,@instance_name,@instance_primary_owner_id,@instance_primary_owner_name,JSON_VALUE(@p_payload,'$.secondaryOwner'),NULLIF(JSON_VALUE(@p_payload,'$.businessFunctionId'),''),@instance_department_id,@instance_department_name,@instance_execution_frequency_id,@instance_assurance_frequency_id,@instance_frequency_id,@instance_frequency_type,@instance_frequency_value,@instance_frequency_unit,COALESCE(JSON_VALUE(@p_payload,'$.assuranceMode'),'Manual'),COALESCE(JSON_VALUE(@p_payload,'$.criticality'),'Medium'),COALESCE(JSON_VALUE(@p_payload,'$.implementationStatus'),'Active'),@instance_implementation_status_id,COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@instance_record_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.practice_instance SET practice_id=@instance_practice_id,organization_id=@instance_organization_id,instance_code=@instance_code,instance_name=@instance_name,primary_owner_id=@instance_primary_owner_id,primary_owner=@instance_primary_owner_name,secondary_owner=JSON_VALUE(@p_payload,'$.secondaryOwner'),business_function_id=NULLIF(JSON_VALUE(@p_payload,'$.businessFunctionId'),''),department_id=@instance_department_id,department=@instance_department_name,execution_frequency_id=@instance_execution_frequency_id,assurance_frequency_id=@instance_assurance_frequency_id,frequency_id=@instance_frequency_id,frequency_type=@instance_frequency_type,frequency_value=@instance_frequency_value,frequency_unit=@instance_frequency_unit,assurance_mode=COALESCE(JSON_VALUE(@p_payload,'$.assuranceMode'),assurance_mode),criticality=COALESCE(JSON_VALUE(@p_payload,'$.criticality'),criticality),implementation_status=COALESCE(JSON_VALUE(@p_payload,'$.implementationStatus'),implementation_status),implementation_status_id=COALESCE(@payload_implementation_status_id,implementation_status_id),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),record_status_id=COALESCE(@payload_record_status_id,record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE practice_instance_id=@p_id;
 END
 ELSE IF @p_entity_type='dependencies'
 BEGIN
   DECLARE @dependency_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.dependencyTypeId'),''));
   DECLARE @dependency_type_text NVARCHAR(120)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.dependencyType'))),'');
   DECLARE @dependency_practice_instance_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceInstanceId'),''));
   DECLARE @dependency_organization_id BIGINT;
   DECLARE @dependency_reference_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.dependencyReferenceId'),''));
   DECLARE @dependency_source_type NVARCHAR(80)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.sourceType'))),'');
   DECLARE @dependency_resolved_name NVARCHAR(300);
   DECLARE @dependency_criticality_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.criticalityId'),''));
   DECLARE @dependency_criticality_text NVARCHAR(120)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.criticality'))),'');
   DECLARE @dependency_status_id INT=COALESCE(TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.statusId'),'')),@payload_record_status_id,@active_record_status_id);
   DECLARE @dependency_status_text NVARCHAR(120);
   DECLARE @dependency_cfg_source_table NVARCHAR(256);
   DECLARE @dependency_cfg_id_column SYSNAME;
   DECLARE @dependency_cfg_display_column SYSNAME;
   DECLARE @dependency_cfg_org_column SYSNAME;
   DECLARE @dependency_cfg_status_column SYSNAME;
   DECLARE @dependency_cfg_status_value NVARCHAR(80);
   DECLARE @dependency_cfg_schema SYSNAME;
   DECLARE @dependency_cfg_table SYSNAME;
   DECLARE @dependency_cfg_sql NVARCHAR(MAX);

   SELECT @dependency_organization_id=organization_id
   FROM grac_practice.practice_instance
   WHERE practice_instance_id=@dependency_practice_instance_id;
   IF @dependency_practice_instance_id IS NULL OR @dependency_organization_id IS NULL
     THROW 51031,'Practice Instance is required for Dependency.',1;

   IF @dependency_type_id IS NULL AND @dependency_type_text IS NOT NULL
     SELECT @dependency_type_id=dependency_type_id
     FROM grac_practice.dependency_type_master
     WHERE dependency_type_code=@dependency_type_text OR dependency_type_name=@dependency_type_text;
   IF @dependency_type_id IS NULL
     THROW 51027,'Dependency Type is required.',1;
   IF NOT EXISTS(SELECT 1 FROM grac_practice.dependency_type_master WHERE dependency_type_id=@dependency_type_id AND is_active=1)
     THROW 51028,'Selected Dependency Type is not valid.',1;
   SELECT @dependency_type_text=dependency_type_code
   FROM grac_practice.dependency_type_master
   WHERE dependency_type_id=@dependency_type_id;

   IF @dependency_reference_id IS NULL
   BEGIN
     SELECT @dependency_resolved_name=dependency_type_name
     FROM grac_practice.dependency_type_master
     WHERE dependency_type_id=@dependency_type_id;
   END
   ELSE
   BEGIN
     SELECT TOP 1
       @dependency_source_type=COALESCE(@dependency_source_type,source_type),
       @dependency_cfg_source_table=source_table_name,
       @dependency_cfg_id_column=id_column_name,
       @dependency_cfg_display_column=display_column_name,
       @dependency_cfg_org_column=organization_filter_column,
       @dependency_cfg_status_column=status_filter_column,
       @dependency_cfg_status_value=status_active_value
     FROM grac_practice.dependency_type_source_config
     WHERE dependency_type_id=@dependency_type_id
       AND status='Active'
       AND source_table_name IN (
         N'grac_practice.organization_dependency_tool',
         N'grac_practice.organization_dependency_vendor',
         N'grac_practice.organization_dependency_application',
         N'grac_practice.organization_dependency_asset',
         N'grac_practice.organization_dependency_process',
         N'grac_practice.organization_location',
         N'grac_practice.organization_employee',
         N'grac_practice.organization_team',
         N'grac_practice.organization_committee'
       );
     IF @dependency_cfg_source_table IS NULL
       THROW 51032,'Dependency Type source configuration is missing or inactive.',1;

     SET @dependency_cfg_schema=PARSENAME(@dependency_cfg_source_table,2);
     SET @dependency_cfg_table=PARSENAME(@dependency_cfg_source_table,1);
     IF @dependency_cfg_schema<>N'grac_practice' OR OBJECT_ID(@dependency_cfg_source_table) IS NULL
       THROW 51034,'Dependency Type source configuration is invalid.',1;
     IF COL_LENGTH(@dependency_cfg_source_table,@dependency_cfg_id_column) IS NULL
        OR COL_LENGTH(@dependency_cfg_source_table,@dependency_cfg_display_column) IS NULL
        OR COL_LENGTH(@dependency_cfg_source_table,@dependency_cfg_org_column) IS NULL
        OR COL_LENGTH(@dependency_cfg_source_table,@dependency_cfg_status_column) IS NULL
       THROW 51035,'Dependency Type source columns are invalid.',1;

     SET @dependency_cfg_sql=N'
 SELECT @resolvedName=CAST(' + QUOTENAME(@dependency_cfg_display_column) + N' AS NVARCHAR(300))
 FROM ' + QUOTENAME(@dependency_cfg_schema) + N'.' + QUOTENAME(@dependency_cfg_table) + N'
 WHERE ' + QUOTENAME(@dependency_cfg_id_column) + N'=@referenceId
   AND ' + QUOTENAME(@dependency_cfg_org_column) + N'=@organizationId
   AND ' + QUOTENAME(@dependency_cfg_status_column) + N'=@activeStatus;';
     EXEC sp_executesql @dependency_cfg_sql,
       N'@referenceId BIGINT,@organizationId BIGINT,@activeStatus NVARCHAR(80),@resolvedName NVARCHAR(300) OUTPUT',
       @referenceId=@dependency_reference_id,
       @organizationId=@dependency_organization_id,
       @activeStatus=@dependency_cfg_status_value,
       @resolvedName=@dependency_resolved_name OUTPUT;
     IF @dependency_resolved_name IS NULL
       THROW 51036,'Selected Dependency Name is not valid for this organization.',1;
   END

   IF @dependency_criticality_id IS NULL AND @dependency_criticality_text IS NOT NULL
     SELECT @dependency_criticality_id=criticality_id
     FROM grac_practice.criticality_master
     WHERE criticality_code=@dependency_criticality_text OR criticality_name=@dependency_criticality_text;
   IF @dependency_criticality_id IS NULL
     SELECT @dependency_criticality_id=criticality_id FROM grac_practice.criticality_master WHERE criticality_code='Medium';
   IF @dependency_criticality_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id=@dependency_criticality_id AND is_active=1)
     THROW 51029,'Selected Criticality is not valid.',1;
   SELECT @dependency_criticality_text=criticality_code
   FROM grac_practice.criticality_master
   WHERE criticality_id=@dependency_criticality_id;

   IF @dependency_status_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE record_status_id=@dependency_status_id AND is_active=1)
     THROW 51030,'Selected dependency Status is not valid.',1;
   SELECT @dependency_status_text=status_code
   FROM grac_practice.record_status_master
   WHERE record_status_id=@dependency_status_id;

   IF @p_id=0 BEGIN
     SET @new_id=NULL;
     SELECT @new_id=dependency_id
     FROM grac_practice.practice_instance_dependency
     WHERE organization_id=@dependency_organization_id
       AND practice_instance_id=@dependency_practice_instance_id
       AND dependency_type_id=@dependency_type_id
       AND ISNULL(dependency_reference_id,0)=ISNULL(@dependency_reference_id,0);

     IF @new_id IS NULL
     BEGIN
       INSERT grac_practice.practice_instance_dependency(organization_id,practice_instance_id,dependency_type_id,dependency_type,dependency_name,dependency_reference,dependency_reference_id,dependency_source_type,owner_name,criticality_id,criticality,status,record_status_id,entered_by)
       VALUES(@dependency_organization_id,@dependency_practice_instance_id,@dependency_type_id,@dependency_type_text,@dependency_resolved_name,CONVERT(NVARCHAR(80),@dependency_reference_id),@dependency_reference_id,@dependency_source_type,JSON_VALUE(@p_payload,'$.ownerName'),@dependency_criticality_id,@dependency_criticality_text,@dependency_status_text,@dependency_status_id,@p_usr_id);
       SET @new_id=SCOPE_IDENTITY();
     END
     ELSE
     BEGIN
       UPDATE grac_practice.practice_instance_dependency
       SET dependency_type=@dependency_type_text,
           dependency_name=@dependency_resolved_name,
           dependency_reference=CONVERT(NVARCHAR(80),@dependency_reference_id),
           dependency_source_type=@dependency_source_type,
           owner_name=JSON_VALUE(@p_payload,'$.ownerName'),
           criticality_id=@dependency_criticality_id,
           criticality=@dependency_criticality_text,
           status=@dependency_status_text,
           record_status_id=@dependency_status_id,
           updated_by=@p_usr_id,
           updated_dt=SYSUTCDATETIME()
       WHERE dependency_id=@new_id;
     END
   END
   ELSE UPDATE d SET organization_id=pi.organization_id,practice_instance_id=pi.practice_instance_id,dependency_type_id=@dependency_type_id,dependency_type=@dependency_type_text,dependency_name=@dependency_resolved_name,dependency_reference=CONVERT(NVARCHAR(80),@dependency_reference_id),dependency_reference_id=@dependency_reference_id,dependency_source_type=@dependency_source_type,owner_name=JSON_VALUE(@p_payload,'$.ownerName'),criticality_id=@dependency_criticality_id,criticality=@dependency_criticality_text,status=@dependency_status_text,record_status_id=@dependency_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM grac_practice.practice_instance_dependency d
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=@dependency_practice_instance_id
   WHERE d.dependency_id=@p_id;
 END
 ELSE IF @p_entity_type='evidence-configurations'
 BEGIN
   DECLARE @evidence_practice_instance_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceInstanceId'),''));
   DECLARE @evidence_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.evidenceTypeId'),''));
   DECLARE @assurance_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.assuranceTypeId'),''));
   DECLARE @collection_method_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.collectionMethodId'),''));
   DECLARE @collection_frequency_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.collectionFrequencyId'),''));
   DECLARE @alignment_status_id INT=(SELECT alignment_status_id FROM grac_practice.evidence_alignment_status_master WHERE alignment_status_code=N'Organization Defined');
   DECLARE @evidence_status_id INT=COALESCE(TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.statusId'),'')),@payload_record_status_id,@active_record_status_id);
   DECLARE @evidence_status_text NVARCHAR(120);

   IF @evidence_practice_instance_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance WHERE practice_instance_id=@evidence_practice_instance_id)
     THROW 51035,'Practice Instance is required for Evidence Configuration.',1;
   /* ── Authorization: allow system admins, practice-instance owners, and
        users who belong to the same organization (evidence-configurations
        permission is already enforced by the API layer).
        This check must NOT block Add/Edit Practice Instance flows that
        chain evidence-configuration saves.  The old owner-only check
        incorrectly required the logged-in user to be the primary_owner,
        which fails when a different authorized user creates the instance.
        Updated 2026-07-06. ─────────────────────────────────────────────── */
   IF @is_system_admin=0
     AND NOT EXISTS(SELECT 1 FROM @allowed_organizations ao
       JOIN grac_practice.practice_instance pi ON pi.organization_id=ao.organization_id
       WHERE pi.practice_instance_id=@evidence_practice_instance_id)
     THROW 51041,'You are not authorized to manage evidence for this Practice Instance.',1;
   IF @evidence_type_id IS NULL OR NOT EXISTS(SELECT 1 FROM GRAC_New.evidence_type_master WHERE evidence_type_id=@evidence_type_id AND is_active=1)
     THROW 51036,'Selected Evidence Type is not valid.',1;
   IF @assurance_type_id IS NULL
     SELECT @assurance_type_id=assurance_type_id FROM grac_practice.assurance_type_master WHERE assurance_type_code=N'Manual' AND is_active=1;
   IF @assurance_type_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.assurance_type_master WHERE assurance_type_id=@assurance_type_id AND is_active=1)
     THROW 51042,'Selected Assurance Type is not valid.',1;
   IF @collection_method_id IS NULL
     SELECT @collection_method_id=collection_method_id FROM grac_practice.collection_method_master WHERE collection_method_code=N'Manual' AND is_active=1;
   IF @collection_method_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.collection_method_master WHERE collection_method_id=@collection_method_id AND is_active=1)
     THROW 51037,'Selected Collection Method is not valid.',1;
   IF @collection_frequency_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.frequency_master WHERE frequency_id=@collection_frequency_id AND is_active=1)
     THROW 51038,'Selected Collection Frequency is not valid.',1;
   IF @evidence_status_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE record_status_id=@evidence_status_id AND is_active=1)
     THROW 51040,'Selected Evidence Status is not valid.',1;
   SELECT @evidence_status_text=status_code
   FROM grac_practice.record_status_master
   WHERE record_status_id=@evidence_status_id;

   IF @p_id=0
   BEGIN
     SET @new_id=NULL;
     SELECT @new_id=evidence_id
     FROM grac_practice.practice_instance_evidence
     WHERE practice_instance_id=@evidence_practice_instance_id
       AND evidence_type_id=@evidence_type_id;
   END

   IF @p_id=0 AND @new_id IS NULL BEGIN
     INSERT grac_practice.practice_instance_evidence(
       organization_id,practice_instance_id,evidence_type_id,inherited_from_repository,organization_modified,is_mandatory,
       collection_method_id,collection_frequency_id,evidence_owner,assurance_type_id,retention_period,evidence_description,evidence_location,evidence_locator,alignment_status_id,status,record_status_id,entered_by)
     SELECT pi.organization_id,pi.practice_instance_id,@evidence_type_id,
       0,
       1,
       COALESCE(TRY_CONVERT(BIT,JSON_VALUE(@p_payload,'$.mandatory')),1),
       @collection_method_id,@collection_frequency_id,JSON_VALUE(@p_payload,'$.evidenceOwner'),@assurance_type_id,JSON_VALUE(@p_payload,'$.retentionPeriod'),JSON_VALUE(@p_payload,'$.evidenceDescription'),JSON_VALUE(@p_payload,'$.evidenceLocation'),JSON_VALUE(@p_payload,'$.evidenceLocator'),@alignment_status_id,
       @evidence_status_text,@evidence_status_id,@p_usr_id
     FROM grac_practice.practice_instance pi
      WHERE pi.practice_instance_id=@evidence_practice_instance_id;
      SET @new_id=SCOPE_IDENTITY();
    END
    ELSE UPDATE e SET organization_id=pi.organization_id,practice_instance_id=pi.practice_instance_id,
      evidence_type_id=@evidence_type_id,
     inherited_from_repository=0,
     organization_modified=1,
     is_mandatory=COALESCE(TRY_CONVERT(BIT,JSON_VALUE(@p_payload,'$.mandatory')),1),
     collection_method_id=@collection_method_id,collection_frequency_id=@collection_frequency_id,
     evidence_owner=JSON_VALUE(@p_payload,'$.evidenceOwner'),
     assurance_type_id=@assurance_type_id,
     retention_period=JSON_VALUE(@p_payload,'$.retentionPeriod'),
     evidence_description=JSON_VALUE(@p_payload,'$.evidenceDescription'),
     evidence_location=JSON_VALUE(@p_payload,'$.evidenceLocation'),
     evidence_locator=JSON_VALUE(@p_payload,'$.evidenceLocator'),
     alignment_status_id=@alignment_status_id,
     status=@evidence_status_text,record_status_id=@evidence_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
    FROM grac_practice.practice_instance_evidence e
    JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=@evidence_practice_instance_id
    WHERE e.evidence_id=COALESCE(NULLIF(@p_id,0),@new_id);

   DECLARE @aligned_status_id INT=(SELECT alignment_status_id FROM grac_practice.evidence_alignment_status_master WHERE alignment_status_code=N'Aligned');
   DECLARE @enhanced_status_id INT=(SELECT alignment_status_id FROM grac_practice.evidence_alignment_status_master WHERE alignment_status_code=N'Enhanced');
   DECLARE @not_aligned_status_id INT=(SELECT alignment_status_id FROM grac_practice.evidence_alignment_status_master WHERE alignment_status_code=N'Not Aligned');
   DECLARE @alignment_result TABLE(release_id BIGINT NOT NULL PRIMARY KEY,alignment_status_id INT NOT NULL,alignment_reason NVARCHAR(MAX) NULL);

   ;WITH frequency_rank AS (
     SELECT frequency_id,
       CASE
         WHEN LOWER(frequency_name)=N'annual' THEN 1
         WHEN LOWER(frequency_name)=N'half-yearly' THEN 2
         WHEN LOWER(frequency_name)=N'quarterly' THEN 3
         WHEN LOWER(frequency_name)=N'monthly' THEN 4
         WHEN LOWER(frequency_name)=N'weekly' THEN 5
         WHEN LOWER(frequency_name)=N'daily' THEN 6
         WHEN LOWER(frequency_name)=N'continuous' THEN 7
         ELSE 0
       END frequency_strength
     FROM grac_practice.frequency_master
   ),
   instance_context AS (
     SELECT pi.practice_instance_id,pi.organization_id,p.organization_requirement_id,req.repository_requirement_id,
       req.organization_control_id,oc.repository_control_id,oc.release_id context_release_id
     FROM grac_practice.practice_instance pi
     JOIN grac_practice.practice p ON p.practice_id=pi.practice_id
     JOIN grac_practice.organization_requirement req ON req.organization_requirement_id=p.organization_requirement_id
     LEFT JOIN grac_practice.organization_control oc ON oc.organization_control_id=req.organization_control_id
     WHERE pi.practice_instance_id=@evidence_practice_instance_id
   ),
   /* ── recommended: use current obligation model (requirement_obligation + requirement_obligation_evidence) ── */
   recommended AS (
     SELECT orm.release_id,roe.evidence_type_id,MAX(ISNULL(fr.frequency_strength,0)) required_strength
     FROM instance_context ctx
     JOIN GRAC_New.obligation_requirement_release_map orm
       ON orm.requirement_id=ctx.repository_requirement_id AND orm.status='Active'
     JOIN GRAC_New.requirement_obligation o
       ON o.obligation_id=orm.obligation_id AND o.status='Active'
     JOIN GRAC_New.requirement_obligation_evidence roe
       ON roe.obligation_id=o.obligation_id AND roe.status='Active'
     LEFT JOIN GRAC_New.reference_option cm_freq ON cm_freq.reference_option_id=roe.frequency_id
     LEFT JOIN grac_practice.frequency_master f
       ON f.frequency_code=cm_freq.option_value OR f.frequency_name=cm_freq.option_label
     LEFT JOIN frequency_rank fr ON fr.frequency_id=f.frequency_id
     WHERE ctx.repository_requirement_id IS NOT NULL
       AND (
         ctx.context_release_id IS NULL
         OR orm.release_id=ctx.context_release_id
         OR EXISTS(SELECT 1 FROM grac_practice.repository_subscription s WHERE s.organization_id=ctx.organization_id AND s.release_id=orm.release_id AND s.status='Active' AND ISNULL(s.subscription_status,'Active')='Active')
       )
     GROUP BY orm.release_id,roe.evidence_type_id
   ),
   organization_evidence AS (
     SELECT e.evidence_type_id,MAX(ISNULL(fr.frequency_strength,0)) configured_strength
     FROM grac_practice.practice_instance_evidence e
     LEFT JOIN frequency_rank fr ON fr.frequency_id=e.collection_frequency_id
     WHERE e.practice_instance_id=@evidence_practice_instance_id AND e.status='Active'
     GROUP BY e.evidence_type_id
   ),
   release_eval AS (
     SELECT r.release_id,
       COUNT(1) required_count,
       SUM(CASE WHEN oe.evidence_type_id IS NOT NULL AND oe.configured_strength>=r.required_strength THEN 1 ELSE 0 END) satisfied_count,
       SUM(CASE WHEN oe.evidence_type_id IS NOT NULL AND oe.configured_strength>r.required_strength THEN 1 ELSE 0 END) stronger_count,
       (SELECT COUNT(1) FROM organization_evidence oe2 WHERE NOT EXISTS(SELECT 1 FROM recommended r2 WHERE r2.release_id=r.release_id AND r2.evidence_type_id=oe2.evidence_type_id)) extra_count
     FROM recommended r
     LEFT JOIN organization_evidence oe ON oe.evidence_type_id=r.evidence_type_id
     GROUP BY r.release_id
   ),
   alignment_source AS (
     SELECT release_id,
       CASE
         WHEN satisfied_count<required_count THEN @not_aligned_status_id
         WHEN stronger_count>0 OR extra_count>0 THEN @enhanced_status_id
         ELSE @aligned_status_id
       END alignment_status_id,
       CASE
         WHEN satisfied_count<required_count THEN N'One or more required evidence types are missing or configured with weaker frequency.'
         WHEN stronger_count>0 OR extra_count>0 THEN N'Organization evidence satisfies the obligation and exceeds the recommendation.'
         ELSE N'Organization evidence exactly matches the obligation recommendation.'
       END alignment_reason
     FROM release_eval
   )
   INSERT @alignment_result(release_id,alignment_status_id,alignment_reason)
   SELECT release_id,alignment_status_id,alignment_reason
   FROM alignment_source;

   MERGE grac_practice.practice_instance_evidence_alignment AS target
   USING @alignment_result AS source
   ON target.practice_instance_id=@evidence_practice_instance_id AND target.framework_release_id=source.release_id
   WHEN MATCHED THEN UPDATE SET alignment_status_id=source.alignment_status_id,alignment_reason=source.alignment_reason,calculated_dt=SYSUTCDATETIME(),status=N'Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   WHEN NOT MATCHED THEN INSERT(practice_instance_id,framework_release_id,alignment_status_id,alignment_reason,calculated_dt,status,entered_by)
   VALUES(@evidence_practice_instance_id,source.release_id,source.alignment_status_id,source.alignment_reason,SYSUTCDATETIME(),N'Active',@p_usr_id);

   UPDATE existing
   SET status=N'Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM grac_practice.practice_instance_evidence_alignment existing
   WHERE existing.practice_instance_id=@evidence_practice_instance_id
     AND existing.status=N'Active'
     AND NOT EXISTS(SELECT 1 FROM @alignment_result ar WHERE ar.release_id=existing.framework_release_id);
 END
 ELSE IF @p_entity_type='assurance-generation'
 BEGIN
   DECLARE @assurance_gen_instance_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceInstanceId'),''));
   DECLARE @assurance_gen_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @assurance_period_from DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.periodFrom'));
   DECLARE @assurance_period_to DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.periodTo'));
   DECLARE @assurance_due_dt DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.dueDate'));
   DECLARE @assurance_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityOwnerId'),''));
   DECLARE @assurance_owner_name NVARCHAR(200)=(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@assurance_owner_id);
   DECLARE @assurance_gen_type_id INT=NULL;
   DECLARE @assurance_gen_type_name NVARCHAR(80)=N'Manual';
   DECLARE @pending_activity_status_id INT=(SELECT assurance_activity_status_id FROM grac_practice.assurance_activity_status_master WHERE status_code=N'Pending');

   IF @assurance_gen_instance_id IS NULL THROW 52001,'Eligible Practice Instance is required.',1;
   IF @assurance_period_from IS NULL OR @assurance_period_to IS NULL OR @assurance_period_to<@assurance_period_from
     THROW 52002,'Valid assurance period is required.',1;

   SELECT @assurance_gen_org_id=pi.organization_id,
          @assurance_gen_type_id=at.assurance_type_id,
          @assurance_gen_type_name=COALESCE(at.assurance_type_name,pi.assurance_mode,N'Manual')
   FROM grac_practice.practice_instance pi
   LEFT JOIN grac_practice.assurance_type_master at ON at.assurance_type_name=pi.assurance_mode OR at.assurance_type_code=pi.assurance_mode
   WHERE pi.practice_instance_id=@assurance_gen_instance_id;

   IF NOT EXISTS(
     SELECT 1
     FROM grac_practice.practice_instance pi
     JOIN grac_practice.practice_operationalization po ON po.practice_instance_id=pi.practice_instance_id AND po.organization_id=pi.organization_id AND po.status=N'Resolved'
     WHERE pi.practice_instance_id=@assurance_gen_instance_id
       AND pi.status=N'Active'
       AND NULLIF(pi.primary_owner,N'') IS NOT NULL
       AND (pi.department_id IS NOT NULL OR NULLIF(pi.department,N'') IS NOT NULL)
       AND EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status=N'Active' AND NULLIF(e.evidence_location,N'') IS NOT NULL AND NULLIF(e.evidence_locator,N'') IS NOT NULL)
       AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_dependency d WHERE d.practice_instance_id=pi.practice_instance_id AND d.status=N'Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_dependency_resolution r WHERE r.practice_instance_id=pi.practice_instance_id AND r.dependency_type_id=d.dependency_type_id AND r.is_active=1 AND r.resolution_status=N'Resolved'))
   )
     THROW 52003,'Practice Instance is not eligible for Assurance.',1;

   INSERT grac_practice.assurance_activity(organization_id,practice_instance_id,activity_number,period_from,period_to,assurance_type_id,assurance_type,activity_owner_id,activity_owner,status_id,status,due_dt,remarks,record_status_id,entered_by)
   VALUES(@assurance_gen_org_id,@assurance_gen_instance_id,
     N'ASM-' + RIGHT(N'000000' + CONVERT(NVARCHAR(20),NEXT VALUE FOR dbo.pm_assurance_activity_seq),6),
     @assurance_period_from,@assurance_period_to,@assurance_gen_type_id,@assurance_gen_type_name,@assurance_owner_id,@assurance_owner_name,@pending_activity_status_id,N'Pending',COALESCE(@assurance_due_dt,@assurance_period_to),JSON_VALUE(@p_payload,'$.remarks'),@active_record_status_id,@p_usr_id);
   SET @new_id=SCOPE_IDENTITY();
   SET @result_message=N'Assurance activity generated successfully.';
 END
 ELSE IF @p_entity_type='assurance-activities'
 BEGIN
   DECLARE @activity_instance_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceInstanceId'),''));
   DECLARE @activity_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @activity_period_from DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.periodFrom'));
   DECLARE @activity_period_to DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.periodTo'));
   DECLARE @activity_status NVARCHAR(80)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),''),N'Pending');
   DECLARE @activity_status_id INT=(SELECT assurance_activity_status_id FROM grac_practice.assurance_activity_status_master WHERE status_code=@activity_status OR status_name=@activity_status);
   DECLARE @activity_assurance_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.assuranceTypeId'),''));
   DECLARE @activity_assurance_type NVARCHAR(80)=COALESCE((SELECT assurance_type_name FROM grac_practice.assurance_type_master WHERE assurance_type_id=@activity_assurance_type_id),N'Manual');
   DECLARE @activity_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityOwnerId'),''));
   DECLARE @activity_owner NVARCHAR(200)=(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@activity_owner_id);
   IF @activity_instance_id IS NULL THROW 52004,'Practice Instance is required.',1;
   SELECT @activity_org_id=COALESCE(@activity_org_id,organization_id) FROM grac_practice.practice_instance WHERE practice_instance_id=@activity_instance_id;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_activity(organization_id,practice_instance_id,activity_number,period_from,period_to,assurance_type_id,assurance_type,activity_owner_id,activity_owner,status_id,status,due_dt,remarks,record_status_id,entered_by)
     VALUES(@activity_org_id,@activity_instance_id,N'ASM-' + RIGHT(N'000000' + CONVERT(NVARCHAR(20),NEXT VALUE FOR dbo.pm_assurance_activity_seq),6),@activity_period_from,@activity_period_to,@activity_assurance_type_id,@activity_assurance_type,@activity_owner_id,@activity_owner,@activity_status_id,@activity_status,TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.dueDate')),JSON_VALUE(@p_payload,'$.remarks'),@active_record_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_activity SET period_from=@activity_period_from,period_to=@activity_period_to,assurance_type_id=@activity_assurance_type_id,assurance_type=@activity_assurance_type,activity_owner_id=@activity_owner_id,activity_owner=@activity_owner,status_id=@activity_status_id,status=@activity_status,due_dt=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.dueDate')),remarks=JSON_VALUE(@p_payload,'$.remarks'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE assurance_activity_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-execution'
 BEGIN
   DECLARE @exec_activity_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityId'),''));
   DECLARE @exec_executor_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.executorId'),''));
   DECLARE @exec_result_status NVARCHAR(80)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.resultStatus'),''),N'Pending');
   DECLARE @exec_result_status_id INT=(SELECT assurance_result_status_id FROM grac_practice.assurance_result_status_master WHERE status_code=@exec_result_status OR status_name=@exec_result_status);
   IF @exec_activity_id IS NULL THROW 52005,'Assurance Activity is required.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_execution(assurance_activity_id,organization_id,practice_instance_id,execution_dt,executor_id,executor_name,evidence_status,dependency_status,result_status_id,result_status,execution_notes,entered_by)
     SELECT aa.assurance_activity_id,aa.organization_id,aa.practice_instance_id,TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.executionDate')),@exec_executor_id,(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@exec_executor_id),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.evidenceStatus'),''),N'Pending'),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.dependencyStatus'),''),N'Pending'),@exec_result_status_id,@exec_result_status,JSON_VALUE(@p_payload,'$.executionNotes'),@p_usr_id
     FROM grac_practice.assurance_activity aa WHERE aa.assurance_activity_id=@exec_activity_id;
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE ex SET execution_dt=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.executionDate')),executor_id=@exec_executor_id,executor_name=(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@exec_executor_id),evidence_status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.evidenceStatus'),''),N'Pending'),dependency_status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.dependencyStatus'),''),N'Pending'),result_status_id=@exec_result_status_id,result_status=@exec_result_status,execution_notes=JSON_VALUE(@p_payload,'$.executionNotes'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() FROM grac_practice.assurance_execution ex WHERE ex.assurance_execution_id=@p_id;
   UPDATE grac_practice.assurance_activity SET status=N'In Progress',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE assurance_activity_id=@exec_activity_id AND status=N'Pending';
 END
 ELSE IF @p_entity_type='evidence-assurance'
 BEGIN
   DECLARE @ev_activity_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityId'),''));
   DECLARE @ev_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.evidenceTypeId'),''));
   DECLARE @ev_exists BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.evidenceExists'),'')) IN ('yes','true','1') THEN 1 ELSE 0 END;
   DECLARE @ev_accessible BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.evidenceAccessible'),'')) IN ('yes','true','1') THEN 1 ELSE 0 END;
   DECLARE @ev_matches BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.matchesExpectedType'),'')) IN ('yes','true','1') THEN 1 ELSE 0 END;
   DECLARE @ev_relates BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.relatesToAssurance'),'')) IN ('yes','true','1') THEN 1 ELSE 0 END;
   DECLARE @ev_result NVARCHAR(80)=CASE WHEN @ev_exists=1 AND @ev_accessible=1 AND @ev_matches=1 AND @ev_relates=1 THEN N'Pass' ELSE N'Fail' END;
   IF @ev_activity_id IS NULL THROW 52006,'Assurance Activity is required.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_evidence_check(assurance_activity_id,organization_id,practice_instance_id,evidence_type_id,evidence_type_name,evidence_exists,evidence_accessible,matches_expected_type,relates_to_assurance,evidence_location,evidence_locator,result_status,remarks,entered_by)
     SELECT aa.assurance_activity_id,aa.organization_id,aa.practice_instance_id,@ev_type_id,(SELECT evidence_type_name FROM GRAC_New.evidence_type_master WHERE evidence_type_id=@ev_type_id),@ev_exists,@ev_accessible,@ev_matches,@ev_relates,JSON_VALUE(@p_payload,'$.evidenceLocation'),JSON_VALUE(@p_payload,'$.evidenceLocator'),@ev_result,JSON_VALUE(@p_payload,'$.remarks'),@p_usr_id
     FROM grac_practice.assurance_activity aa WHERE aa.assurance_activity_id=@ev_activity_id;
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_evidence_check SET evidence_type_id=@ev_type_id,evidence_type_name=(SELECT evidence_type_name FROM GRAC_New.evidence_type_master WHERE evidence_type_id=@ev_type_id),evidence_exists=@ev_exists,evidence_accessible=@ev_accessible,matches_expected_type=@ev_matches,relates_to_assurance=@ev_relates,evidence_location=JSON_VALUE(@p_payload,'$.evidenceLocation'),evidence_locator=JSON_VALUE(@p_payload,'$.evidenceLocator'),result_status=@ev_result,remarks=JSON_VALUE(@p_payload,'$.remarks'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE evidence_check_id=@p_id;
 END
 ELSE IF @p_entity_type='dependency-assurance'
 BEGIN
   DECLARE @dep_activity_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityId'),''));
   DECLARE @dep_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.dependencyTypeId'),''));
   DECLARE @dep_available BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.dependencyAvailable'),'')) IN ('yes','true','1') THEN 1 ELSE 0 END;
   DECLARE @dep_current BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.dependencyCurrent'),'')) IN ('yes','true','1') THEN 1 ELSE 0 END;
   DECLARE @dep_result NVARCHAR(80)=CASE WHEN @dep_available=1 AND @dep_current=1 THEN N'Pass' ELSE N'Fail' END;
   IF @dep_activity_id IS NULL THROW 52007,'Assurance Activity is required.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_dependency_check(assurance_activity_id,organization_id,practice_instance_id,dependency_type_id,dependency_type_name,resolved_dependency_name,dependency_available,dependency_current,result_status,remarks,entered_by)
     SELECT aa.assurance_activity_id,aa.organization_id,aa.practice_instance_id,@dep_type_id,(SELECT dependency_type_name FROM grac_practice.dependency_type_master WHERE dependency_type_id=@dep_type_id),JSON_VALUE(@p_payload,'$.resolvedDependencyName'),@dep_available,@dep_current,@dep_result,JSON_VALUE(@p_payload,'$.remarks'),@p_usr_id
     FROM grac_practice.assurance_activity aa WHERE aa.assurance_activity_id=@dep_activity_id;
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_dependency_check SET dependency_type_id=@dep_type_id,dependency_type_name=(SELECT dependency_type_name FROM grac_practice.dependency_type_master WHERE dependency_type_id=@dep_type_id),resolved_dependency_name=JSON_VALUE(@p_payload,'$.resolvedDependencyName'),dependency_available=@dep_available,dependency_current=@dep_current,result_status=@dep_result,remarks=JSON_VALUE(@p_payload,'$.remarks'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE dependency_check_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-results'
 BEGIN
   DECLARE @res_activity_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityId'),''));
   DECLARE @res_status NVARCHAR(80)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.resultStatus'),''),N'Pending');
   DECLARE @res_status_id INT=(SELECT assurance_result_status_id FROM grac_practice.assurance_result_status_master WHERE status_code=@res_status OR status_name=@res_status);
   DECLARE @res_completed_by_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.completedById'),''));
   IF @res_activity_id IS NULL THROW 52008,'Assurance Activity is required.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_result(assurance_activity_id,organization_id,practice_instance_id,result_status_id,result_status,operating_effectiveness,completed_dt,completed_by_id,completed_by,result_summary,entered_by)
     SELECT aa.assurance_activity_id,aa.organization_id,aa.practice_instance_id,@res_status_id,@res_status,COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.operatingEffectiveness'),''),N'Not Assessed'),TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.completedDate')),@res_completed_by_id,(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@res_completed_by_id),JSON_VALUE(@p_payload,'$.resultSummary'),@p_usr_id
     FROM grac_practice.assurance_activity aa WHERE aa.assurance_activity_id=@res_activity_id;
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_result SET result_status_id=@res_status_id,result_status=@res_status,operating_effectiveness=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.operatingEffectiveness'),''),N'Not Assessed'),completed_dt=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.completedDate')),completed_by_id=@res_completed_by_id,completed_by=(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@res_completed_by_id),result_summary=JSON_VALUE(@p_payload,'$.resultSummary'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE assurance_result_id=@p_id;
   IF @res_status IN (N'Pass',N'Pass With Observation',N'Fail',N'Unable To Verify')
     UPDATE grac_practice.assurance_activity SET status=CASE WHEN @res_status=N'Unable To Verify' THEN N'Unable To Verify' ELSE N'Completed' END,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE assurance_activity_id=@res_activity_id;
 END
 ELSE IF @p_entity_type='assurance-findings'
 BEGIN
   DECLARE @find_activity_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityId'),''));
   DECLARE @find_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.ownerId'),''));
   IF @find_activity_id IS NULL THROW 52009,'Assurance Activity is required.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_finding(assurance_activity_id,organization_id,practice_instance_id,finding_number,title,description,severity,owner_id,owner_name,due_dt,finding_status,entered_by)
     SELECT aa.assurance_activity_id,aa.organization_id,aa.practice_instance_id,N'ASF-' + RIGHT(N'000000' + CONVERT(NVARCHAR(20),NEXT VALUE FOR dbo.pm_assurance_finding_seq),6),JSON_VALUE(@p_payload,'$.title'),JSON_VALUE(@p_payload,'$.description'),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.severity'),''),N'Medium'),@find_owner_id,(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@find_owner_id),TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.dueDate')),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.findingStatus'),''),N'Open'),@p_usr_id
     FROM grac_practice.assurance_activity aa WHERE aa.assurance_activity_id=@find_activity_id;
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_finding SET title=JSON_VALUE(@p_payload,'$.title'),description=JSON_VALUE(@p_payload,'$.description'),severity=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.severity'),''),severity),owner_id=@find_owner_id,owner_name=(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@find_owner_id),due_dt=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.dueDate')),finding_status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.findingStatus'),''),finding_status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE finding_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-signals'
 BEGIN
   DECLARE @sig_activity_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityId'),''));
   DECLARE @sig_org_id BIGINT=NULL,@sig_instance_id BIGINT=NULL;
   SELECT @sig_org_id=organization_id,@sig_instance_id=practice_instance_id FROM grac_practice.assurance_activity WHERE assurance_activity_id=@sig_activity_id;
   SET @sig_org_id=COALESCE(@sig_org_id,TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),'')));
   IF @sig_org_id IS NULL THROW 52010,'Organization or Assurance Activity is required for signal.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_signal(assurance_activity_id,organization_id,practice_instance_id,signal_type,severity,signal_status,message,entered_by)
     VALUES(@sig_activity_id,@sig_org_id,@sig_instance_id,JSON_VALUE(@p_payload,'$.signalType'),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.severity'),''),N'Medium'),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.signalStatus'),''),N'Open'),JSON_VALUE(@p_payload,'$.message'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_signal SET signal_type=JSON_VALUE(@p_payload,'$.signalType'),severity=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.severity'),''),severity),signal_status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.signalStatus'),''),signal_status),message=JSON_VALUE(@p_payload,'$.message'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE signal_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-schedule-rules'
 BEGIN
   DECLARE @rule_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @rule_instance_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceInstanceId'),''));
   DECLARE @rule_frequency_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.frequencyId'),''));
   DECLARE @rule_anchor DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.anchorDate'));
   DECLARE @rule_end DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.endDate'));
   IF @rule_org_id IS NULL OR @rule_instance_id IS NULL THROW 52020,'Organization and Practice Instance are required.',1;
   IF @rule_frequency_id IS NULL THROW 52021,'Frequency is required for schedule rule.',1;
   IF @rule_anchor IS NULL THROW 52022,'Anchor date is required for schedule rule.',1;
   IF @p_id=0
   BEGIN
     SET @new_id=NULL;
     SELECT @new_id=schedule_rule_id FROM grac_practice.assurance_schedule_rule WHERE practice_instance_id=@rule_instance_id AND status='Active';
     IF @new_id IS NOT NULL THROW 52023,'A schedule rule already exists for this practice instance.',1;
     INSERT grac_practice.assurance_schedule_rule(organization_id,practice_instance_id,frequency_id,anchor_date,end_date,schedule_owner,notes,entered_by)
     VALUES(@rule_org_id,@rule_instance_id,@rule_frequency_id,@rule_anchor,@rule_end,JSON_VALUE(@p_payload,'$.scheduleOwner'),JSON_VALUE(@p_payload,'$.notes'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_schedule_rule SET frequency_id=@rule_frequency_id,anchor_date=@rule_anchor,end_date=@rule_end,schedule_owner=JSON_VALUE(@p_payload,'$.scheduleOwner'),notes=JSON_VALUE(@p_payload,'$.notes'),status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),''),'Active'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE schedule_rule_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-schedule-overrides'
 BEGIN
   DECLARE @ovr_rule_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.scheduleRuleId'),''));
   DECLARE @ovr_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @ovr_original DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.originalDate'));
   DECLARE @ovr_type NVARCHAR(30)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.overrideType'),''),N'Moved');
   DECLARE @ovr_new_date DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.newDate'));
   IF @ovr_rule_id IS NULL THROW 52030,'Schedule rule is required.',1;
   IF @ovr_original IS NULL THROW 52031,'Original date is required.',1;
   IF @ovr_org_id IS NULL SELECT @ovr_org_id=organization_id FROM grac_practice.assurance_schedule_rule WHERE schedule_rule_id=@ovr_rule_id;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_schedule_override(schedule_rule_id,organization_id,original_date,override_type,new_date,reason,apply_to_future,override_by,entered_by)
     VALUES(@ovr_rule_id,@ovr_org_id,@ovr_original,@ovr_type,@ovr_new_date,JSON_VALUE(@p_payload,'$.reason'),COALESCE(TRY_CONVERT(BIT,JSON_VALUE(@p_payload,'$.applyToFuture')),0),JSON_VALUE(@p_payload,'$.overrideBy'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_schedule_override SET override_type=@ovr_type,new_date=@ovr_new_date,reason=JSON_VALUE(@p_payload,'$.reason'),apply_to_future=COALESCE(TRY_CONVERT(BIT,JSON_VALUE(@p_payload,'$.applyToFuture')),0),override_by=JSON_VALUE(@p_payload,'$.overrideBy'),status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),''),'Active'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE override_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-calendar-config'
 BEGIN
   DECLARE @cfg_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   IF @cfg_org_id IS NULL THROW 52040,'Organization is required for calendar config.',1;
   SET @new_id=NULL;
   SELECT @new_id=config_id FROM grac_practice.assurance_calendar_config WHERE organization_id=@cfg_org_id;
   IF @new_id IS NULL
   BEGIN
     INSERT grac_practice.assurance_calendar_config(organization_id,look_back_months,look_ahead_months,default_view,entered_by)
     VALUES(@cfg_org_id,COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.lookBackMonths')),3),COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.lookAheadMonths')),12),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.defaultView'),''),N'month'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_calendar_config SET look_back_months=COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.lookBackMonths')),look_back_months),look_ahead_months=COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.lookAheadMonths')),look_ahead_months),default_view=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.defaultView'),''),default_view),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE config_id=@new_id;
 END
 ELSE THROW 51004,'Save is not configured for this practice area yet',1;

 INSERT grac_practice.practice_audit_trace(entity_type,entity_id,action_type,after_json,status,entered_by)
 VALUES(@p_entity_type,@new_id,@p_action,@p_payload,'Active',@p_usr_id);
 COMMIT;
 SELECT CAST(1 AS BIT) Success,@result_message Message,@new_id Id;
END
GO




