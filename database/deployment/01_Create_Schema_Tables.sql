/*
  Practice Management deployment script
  File: 01_Create_Schema_Tables.sql
  Generated: 2026-06-20
  Purpose: Create schema and latest grac_practice tables
  Execution: run scripts in numeric order against the target database.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
IF SCHEMA_ID('grac_practice') IS NULL
    EXEC('CREATE SCHEMA grac_practice AUTHORIZATION dbo');
GO

BEGIN TRY
    BEGIN TRANSACTION;
    IF SCHEMA_ID('grac_practice') IS NULL
        EXEC('CREATE SCHEMA grac_practice AUTHORIZATION dbo');
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO

/* Core schema and table definitions */
/*
  GRAC Part 2 - Practice Intelligence Layer
  Foundation schema.
*/
IF SCHEMA_ID('grac_practice') IS NULL EXEC('CREATE SCHEMA grac_practice');
GO

IF OBJECT_ID('grac_practice.organization','U') IS NULL
CREATE TABLE grac_practice.organization(
 organization_id BIGINT IDENTITY PRIMARY KEY,
 organization_code NVARCHAR(80) NOT NULL UNIQUE,
 organization_name NVARCHAR(250) NOT NULL,
 industry NVARCHAR(120) NULL,
 entity_type NVARCHAR(120) NULL,
 country NVARCHAR(120) NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.organization_metadata_definition','U') IS NULL
CREATE TABLE grac_practice.organization_metadata_definition(
 metadata_definition_id BIGINT IDENTITY PRIMARY KEY,
 metadata_key NVARCHAR(120) NOT NULL UNIQUE,
 metadata_name NVARCHAR(200) NOT NULL,
 data_type NVARCHAR(40) NOT NULL,
 lookup_group NVARCHAR(120) NULL,
 is_required BIT NOT NULL DEFAULT 0,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.reference_option','U') IS NULL
CREATE TABLE grac_practice.reference_option(
 reference_option_id BIGINT IDENTITY PRIMARY KEY,
 option_group NVARCHAR(120) NOT NULL,
 option_value NVARCHAR(160) NOT NULL,
 option_label NVARCHAR(200) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_pm_reference_option UNIQUE(option_group,option_value)
);
GO

IF OBJECT_ID('grac_practice.organization_metadata_value','U') IS NULL
CREATE TABLE grac_practice.organization_metadata_value(
 metadata_value_id BIGINT IDENTITY PRIMARY KEY,
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 metadata_definition_id BIGINT NOT NULL REFERENCES grac_practice.organization_metadata_definition(metadata_definition_id),
 value_text NVARCHAR(MAX) NULL,
 value_number DECIMAL(18,4) NULL,
 value_date DATE NULL,
 value_bool BIT NULL,
 value_json NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 record_status_id INT NULL,
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_pm_organization_metadata UNIQUE(organization_id,metadata_definition_id)
);
GO

IF OBJECT_ID('grac_practice.organization_business_function','U') IS NULL
CREATE TABLE grac_practice.organization_business_function(
 business_function_id BIGINT IDENTITY PRIMARY KEY,
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 function_code NVARCHAR(80) NOT NULL,
 function_name NVARCHAR(200) NOT NULL,
 owner_name NVARCHAR(200) NULL,
 criticality NVARCHAR(30) NOT NULL DEFAULT 'Medium',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_pm_business_function UNIQUE(organization_id,function_code)
);
GO

IF OBJECT_ID('grac_practice.repository_subscription','U') IS NULL
CREATE TABLE grac_practice.repository_subscription(
 subscription_id BIGINT IDENTITY PRIMARY KEY,
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 authority_id BIGINT NULL,
 artifact_id BIGINT NULL,
 release_id BIGINT NULL,
 subscription_type NVARCHAR(40) NOT NULL DEFAULT 'Manual',
 subscription_status NVARCHAR(40) NOT NULL DEFAULT 'Active',
 source_evaluation_id BIGINT NULL,
 effective_dt DATE NULL,
 end_dt DATE NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.subscription_recommendation_history','U') IS NULL
CREATE TABLE grac_practice.subscription_recommendation_history(
 recommendation_history_id BIGINT IDENTITY PRIMARY KEY,
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 authority_id BIGINT NULL,
 artifact_id BIGINT NULL,
 release_id BIGINT NULL,
 recommendation_reason NVARCHAR(1000) NULL,
 confidence_level NVARCHAR(30) NOT NULL DEFAULT 'Medium',
 decision_status NVARCHAR(30) NOT NULL DEFAULT 'Recommended',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.organization_control','U') IS NULL
CREATE TABLE grac_practice.organization_control(
 organization_control_id BIGINT IDENTITY PRIMARY KEY,
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 origin_type NVARCHAR(30) NOT NULL,
 repository_control_id BIGINT NULL,
 control_code NVARCHAR(100) NOT NULL,
 control_name NVARCHAR(300) NOT NULL,
 description NVARCHAR(MAX) NULL,
 objective NVARCHAR(MAX) NULL,
 control_domain_id BIGINT NULL,
 control_sub_domain_id BIGINT NULL,
 business_justification NVARCHAR(MAX) NULL,
 is_manually_added BIT NOT NULL DEFAULT 0,
 subscription_id BIGINT NULL REFERENCES grac_practice.repository_subscription(subscription_id),
 release_id BIGINT NULL,
 artifact_id BIGINT NULL,
 effective_dt DATE NULL,
 review_frequency NVARCHAR(80) NULL,
 applicability_status NVARCHAR(40) NOT NULL DEFAULT 'Not Updated',
 exclusion_justification NVARCHAR(MAX) NULL,
 primary_owner NVARCHAR(200) NULL,
 secondary_owner NVARCHAR(200) NULL,
 backup_owner NVARCHAR(200) NULL,
 business_function_id BIGINT NULL REFERENCES grac_practice.organization_business_function(business_function_id),
 criticality NVARCHAR(30) NOT NULL DEFAULT 'Medium',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF COL_LENGTH('grac_practice.organization_control','objective') IS NULL
 ALTER TABLE grac_practice.organization_control ADD objective NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('grac_practice.organization_control','control_domain_id') IS NULL
 ALTER TABLE grac_practice.organization_control ADD control_domain_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.organization_control','control_sub_domain_id') IS NULL
 ALTER TABLE grac_practice.organization_control ADD control_sub_domain_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.organization_control','is_manually_added') IS NULL
 ALTER TABLE grac_practice.organization_control ADD is_manually_added BIT NOT NULL CONSTRAINT df_pm_org_control_manual DEFAULT 0;
GO
IF COL_LENGTH('grac_practice.organization_control','subscription_id') IS NULL
 ALTER TABLE grac_practice.organization_control ADD subscription_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.organization_control','release_id') IS NULL
 ALTER TABLE grac_practice.organization_control ADD release_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.organization_control','artifact_id') IS NULL
 ALTER TABLE grac_practice.organization_control ADD artifact_id BIGINT NULL;
GO

IF OBJECT_ID('grac_practice.uq_pm_organization_control','UQ') IS NOT NULL
 ALTER TABLE grac_practice.organization_control DROP CONSTRAINT uq_pm_organization_control;
GO

IF OBJECT_ID('grac_practice.organization_statement_applicability','U') IS NULL
CREATE TABLE grac_practice.organization_statement_applicability(
 organization_statement_applicability_id BIGINT IDENTITY PRIMARY KEY,
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 release_id BIGINT NOT NULL,
 framework_statement_id BIGINT NOT NULL,
 applicability_status NVARCHAR(40) NOT NULL DEFAULT 'Not Updated',
 applicability_status_id INT NULL REFERENCES grac_practice.applicability_status_master(applicability_status_id),
 owner_id BIGINT NULL REFERENCES grac_practice.organization_employee(employee_id),
 exclusion_justification NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_pm_org_statement_applicability UNIQUE(organization_id,release_id,framework_statement_id)
);
GO
IF COL_LENGTH('grac_practice.organization_statement_applicability','owner_id') IS NULL
 ALTER TABLE grac_practice.organization_statement_applicability ADD owner_id BIGINT NULL;
GO

IF OBJECT_ID('grac_practice.organization_framework_statements','U') IS NULL
CREATE TABLE grac_practice.organization_framework_statements(
 org_statement_id BIGINT IDENTITY PRIMARY KEY,
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 release_id BIGINT NOT NULL,
 framework_statement_id BIGINT NOT NULL,
 applicability_status_id INT NULL REFERENCES grac_practice.applicability_status_master(applicability_status_id),
 owner_id BIGINT NULL REFERENCES grac_practice.organization_employee(employee_id),
 applicability_reason NVARCHAR(MAX) NULL,
 status_id INT NULL REFERENCES grac_practice.record_status_master(record_status_id),
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_pm_org_framework_statement UNIQUE(organization_id,release_id,framework_statement_id)
);
GO
IF COL_LENGTH('grac_practice.organization_framework_statements','status_id') IS NULL
 ALTER TABLE grac_practice.organization_framework_statements ADD status_id INT NULL;
GO
IF COL_LENGTH('grac_practice.organization_framework_statements','status') IS NULL
 ALTER TABLE grac_practice.organization_framework_statements ADD status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_org_framework_statement_status DEFAULT 'Active';
GO

IF OBJECT_ID('grac_practice.organization_requirement','U') IS NULL
CREATE TABLE grac_practice.organization_requirement(
 organization_requirement_id BIGINT IDENTITY PRIMARY KEY,
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 org_statement_id BIGINT NULL REFERENCES grac_practice.organization_framework_statements(org_statement_id),
 origin_type NVARCHAR(30) NOT NULL,
 repository_requirement_id BIGINT NULL,
 organization_control_id BIGINT NULL REFERENCES grac_practice.organization_control(organization_control_id),
 requirement_code NVARCHAR(100) NOT NULL,
 requirement_name NVARCHAR(300) NOT NULL,
 requirement_statement NVARCHAR(MAX) NULL,
 objective NVARCHAR(MAX) NULL,
 applicability_status NVARCHAR(40) NOT NULL DEFAULT 'Not Updated',
 exclusion_justification NVARCHAR(MAX) NULL,
 implementation_status NVARCHAR(40) NOT NULL DEFAULT 'Not Started',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO
IF OBJECT_ID('grac_practice.uq_pm_organization_requirement','UQ') IS NOT NULL
 ALTER TABLE grac_practice.organization_requirement DROP CONSTRAINT uq_pm_organization_requirement;
GO
IF COL_LENGTH('grac_practice.organization_requirement','org_statement_id') IS NULL
 ALTER TABLE grac_practice.organization_requirement ADD org_statement_id BIGINT NULL;
GO
IF EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_pm_org_requirement_control_code' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
 DROP INDEX ux_pm_org_requirement_control_code ON grac_practice.organization_requirement;
GO
IF EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_requirement_control_status' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
 DROP INDEX ix_pm_org_requirement_control_status ON grac_practice.organization_requirement;
GO
IF EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_requirement_org_status_origin' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
 DROP INDEX ix_pm_org_requirement_org_status_origin ON grac_practice.organization_requirement;
GO
IF COL_LENGTH('grac_practice.organization_requirement','organization_control_id') IS NOT NULL
 ALTER TABLE grac_practice.organization_requirement ALTER COLUMN organization_control_id BIGINT NULL;
GO

IF OBJECT_ID('grac_practice.practice','U') IS NULL
CREATE TABLE grac_practice.practice(
 practice_id BIGINT IDENTITY PRIMARY KEY,
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 organization_requirement_id BIGINT NOT NULL REFERENCES grac_practice.organization_requirement(organization_requirement_id),
 origin_type NVARCHAR(30) NOT NULL,
 practice_code NVARCHAR(100) NOT NULL,
 practice_name NVARCHAR(300) NOT NULL,
 description NVARCHAR(MAX) NULL,
 practice_owner_id BIGINT NULL,
 practice_owner NVARCHAR(200) NULL,
 applicability_status NVARCHAR(40) NOT NULL DEFAULT 'Not Updated',
 applicability_status_id INT NULL,
 exclusion_justification NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_pm_practice UNIQUE(organization_id,organization_requirement_id,practice_code)
);
GO

IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
CREATE TABLE grac_practice.practice_instance(
 practice_instance_id BIGINT IDENTITY PRIMARY KEY,
 practice_id BIGINT NOT NULL REFERENCES grac_practice.practice(practice_id),
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 instance_code NVARCHAR(100) NOT NULL,
 instance_name NVARCHAR(300) NOT NULL,
 primary_owner NVARCHAR(200) NULL,
 secondary_owner NVARCHAR(200) NULL,
 business_function_id BIGINT NULL REFERENCES grac_practice.organization_business_function(business_function_id),
 department NVARCHAR(200) NULL,
 frequency_type NVARCHAR(40) NULL,
 frequency_value INT NULL,
 frequency_unit NVARCHAR(40) NULL,
 assurance_mode NVARCHAR(40) NOT NULL DEFAULT 'Manual',
 criticality NVARCHAR(30) NOT NULL DEFAULT 'Medium',
 implementation_status NVARCHAR(40) NOT NULL DEFAULT 'Active',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_pm_practice_instance UNIQUE(organization_id,instance_code)
);
GO

IF OBJECT_ID('grac_practice.frequency_master','U') IS NULL
CREATE TABLE grac_practice.frequency_master(
 frequency_id INT IDENTITY PRIMARY KEY,
 frequency_code NVARCHAR(40) NOT NULL UNIQUE,
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
GO

IF COL_LENGTH('grac_practice.practice_instance','frequency_id') IS NULL
 ALTER TABLE grac_practice.practice_instance ADD frequency_id INT NULL REFERENCES grac_practice.frequency_master(frequency_id);
GO

IF COL_LENGTH('grac_practice.practice_instance','primary_owner_id') IS NULL
 ALTER TABLE grac_practice.practice_instance ADD primary_owner_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.practice_instance','department_id') IS NULL
 ALTER TABLE grac_practice.practice_instance ADD department_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.practice_instance','execution_frequency_id') IS NULL
 ALTER TABLE grac_practice.practice_instance ADD execution_frequency_id INT NULL REFERENCES grac_practice.frequency_master(frequency_id);
GO

IF COL_LENGTH('grac_practice.practice_instance','assurance_frequency_id') IS NULL
 ALTER TABLE grac_practice.practice_instance ADD assurance_frequency_id INT NULL REFERENCES grac_practice.frequency_master(frequency_id);
GO

IF OBJECT_ID('grac_practice.dependency_type_master','U') IS NULL
CREATE TABLE grac_practice.dependency_type_master(
 dependency_type_id INT IDENTITY PRIMARY KEY,
 dependency_type_code NVARCHAR(60) NOT NULL UNIQUE,
 dependency_type_name NVARCHAR(120) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.criticality_master','U') IS NULL
CREATE TABLE grac_practice.criticality_master(
 criticality_id INT IDENTITY PRIMARY KEY,
 criticality_code NVARCHAR(40) NOT NULL UNIQUE,
 criticality_name NVARCHAR(80) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NULL
CREATE TABLE grac_practice.practice_instance_dependency(
 dependency_id BIGINT IDENTITY PRIMARY KEY,
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 practice_instance_id BIGINT NOT NULL REFERENCES grac_practice.practice_instance(practice_instance_id),
 dependency_type_id INT NULL REFERENCES grac_practice.dependency_type_master(dependency_type_id),
 dependency_type NVARCHAR(40) NOT NULL,
 dependency_name NVARCHAR(300) NOT NULL,
 dependency_reference NVARCHAR(200) NULL,
 owner_name NVARCHAR(200) NULL,
 criticality_id INT NULL REFERENCES grac_practice.criticality_master(criticality_id),
 criticality NVARCHAR(30) NOT NULL DEFAULT 'Medium',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.evidence_type_master','U') IS NULL
CREATE TABLE grac_practice.evidence_type_master(
 evidence_type_id INT IDENTITY PRIMARY KEY,
 evidence_type_code NVARCHAR(60) NOT NULL UNIQUE,
 evidence_type_name NVARCHAR(160) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.collection_method_master','U') IS NULL
CREATE TABLE grac_practice.collection_method_master(
 collection_method_id INT IDENTITY PRIMARY KEY,
 collection_method_code NVARCHAR(60) NOT NULL UNIQUE,
 collection_method_name NVARCHAR(120) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.assurance_type_master','U') IS NULL
CREATE TABLE grac_practice.assurance_type_master(
 assurance_type_id INT IDENTITY PRIMARY KEY,
 assurance_type_code NVARCHAR(60) NOT NULL UNIQUE,
 assurance_type_name NVARCHAR(120) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.evidence_alignment_status_master','U') IS NULL
CREATE TABLE grac_practice.evidence_alignment_status_master(
 alignment_status_id INT IDENTITY PRIMARY KEY,
 alignment_status_code NVARCHAR(80) NOT NULL UNIQUE,
 alignment_status_name NVARCHAR(160) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF OBJECT_ID('grac_practice.practice_instance_evidence_alignment','U') IS NULL
CREATE TABLE grac_practice.practice_instance_evidence_alignment(
 evidence_alignment_id BIGINT IDENTITY PRIMARY KEY,
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
GO

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NULL
CREATE TABLE grac_practice.practice_instance_evidence(
 evidence_id BIGINT IDENTITY PRIMARY KEY,
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
 evidence_description NVARCHAR(MAX) NULL,
 evidence_location NVARCHAR(500) NULL,
 evidence_locator NVARCHAR(500) NULL,
 alignment_status_id INT NOT NULL REFERENCES grac_practice.evidence_alignment_status_master(alignment_status_id),
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 record_status_id INT NULL,
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
GO

IF COL_LENGTH('grac_practice.practice_instance_dependency','organization_id') IS NULL
BEGIN
 ALTER TABLE grac_practice.practice_instance_dependency ADD organization_id BIGINT NULL;
 EXEC('UPDATE d SET organization_id=pi.organization_id FROM grac_practice.practice_instance_dependency d JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=d.practice_instance_id WHERE d.organization_id IS NULL');
 ALTER TABLE grac_practice.practice_instance_dependency ALTER COLUMN organization_id BIGINT NOT NULL;
 ALTER TABLE grac_practice.practice_instance_dependency ADD CONSTRAINT fk_pm_dependency_organization FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id);
END
GO

IF OBJECT_ID('grac_practice.practice_audit_trace','U') IS NULL
CREATE TABLE grac_practice.practice_audit_trace(
 audit_trace_id BIGINT IDENTITY PRIMARY KEY,
 entity_type NVARCHAR(100) NOT NULL,
 entity_id BIGINT NOT NULL,
 action_type NVARCHAR(80) NOT NULL,
 before_json NVARCHAR(MAX) NULL,
 after_json NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

CREATE OR ALTER TRIGGER grac_practice.tr_practice_audit_trace_immutable
ON grac_practice.practice_audit_trace
INSTEAD OF UPDATE, DELETE
AS
BEGIN
 THROW 51001, 'Practice audit trace is immutable.', 1;
END;
GO

/*
  Enterprise scale indexes.
  Keep organization-scoped screens fast and avoid full-table scans as organizations,
  controls, requirements, practices, and instances grow.
*/
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_organization_status_entered' AND object_id=OBJECT_ID('grac_practice.organization'))
 CREATE INDEX ix_pm_organization_status_entered ON grac_practice.organization(status,entered_dt DESC) INCLUDE(organization_code,organization_name);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_metadata_value_org_status_entered' AND object_id=OBJECT_ID('grac_practice.organization_metadata_value'))
 CREATE INDEX ix_pm_metadata_value_org_status_entered ON grac_practice.organization_metadata_value(organization_id,status,entered_dt DESC,metadata_definition_id);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_reference_option_group_status' AND object_id=OBJECT_ID('grac_practice.reference_option'))
 CREATE INDEX ix_pm_reference_option_group_status ON grac_practice.reference_option(option_group,status,display_order) INCLUDE(option_value,option_label);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_business_function_org_status_criticality' AND object_id=OBJECT_ID('grac_practice.organization_business_function'))
 CREATE INDEX ix_pm_business_function_org_status_criticality ON grac_practice.organization_business_function(organization_id,status,criticality,entered_dt DESC);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_subscription_org_status_release' AND object_id=OBJECT_ID('grac_practice.repository_subscription'))
 CREATE INDEX ix_pm_subscription_org_status_release ON grac_practice.repository_subscription(organization_id,status,release_id,artifact_id,entered_dt DESC);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_subscription_artifact_release_status' AND object_id=OBJECT_ID('grac_practice.repository_subscription'))
 CREATE INDEX ix_pm_subscription_artifact_release_status ON grac_practice.repository_subscription(artifact_id,release_id,status,entered_dt DESC);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_recommendation_org_release_status' AND object_id=OBJECT_ID('grac_practice.subscription_recommendation_history'))
 CREATE INDEX ix_pm_recommendation_org_release_status ON grac_practice.subscription_recommendation_history(organization_id,release_id,status,entered_dt DESC) INCLUDE(decision_status,confidence_level);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_control_org_status_origin' AND object_id=OBJECT_ID('grac_practice.organization_control'))
 CREATE INDEX ix_pm_org_control_org_status_origin ON grac_practice.organization_control(organization_id,status,origin_type,entered_dt DESC) INCLUDE(repository_control_id,control_code,control_name,primary_owner,criticality);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_control_repo_control' AND object_id=OBJECT_ID('grac_practice.organization_control'))
 CREATE INDEX ix_pm_org_control_repo_control ON grac_practice.organization_control(repository_control_id,organization_id,status) WHERE repository_control_id IS NOT NULL;
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_control_subscription' AND object_id=OBJECT_ID('grac_practice.organization_control'))
 CREATE INDEX ix_pm_org_control_subscription ON grac_practice.organization_control(organization_id,subscription_id,release_id,artifact_id,status) INCLUDE(repository_control_id,control_code,control_name);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_pm_org_control_repo_release' AND object_id=OBJECT_ID('grac_practice.organization_control'))
 CREATE UNIQUE INDEX ux_pm_org_control_repo_release ON grac_practice.organization_control(organization_id,repository_control_id,release_id)
 WHERE repository_control_id IS NOT NULL AND release_id IS NOT NULL;
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_pm_org_control_manual_code' AND object_id=OBJECT_ID('grac_practice.organization_control'))
 CREATE UNIQUE INDEX ux_pm_org_control_manual_code ON grac_practice.organization_control(organization_id,control_code)
 WHERE repository_control_id IS NULL AND status='Active';
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_requirement_org_status_origin' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
 CREATE INDEX ix_pm_org_requirement_org_status_origin ON grac_practice.organization_requirement(organization_id,status,origin_type,entered_dt DESC) INCLUDE(repository_requirement_id,organization_control_id,requirement_code,requirement_name);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_requirement_control_status' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
 CREATE INDEX ix_pm_org_requirement_control_status ON grac_practice.organization_requirement(organization_control_id,status,entered_dt DESC);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_requirement_repo_requirement' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
 CREATE INDEX ix_pm_org_requirement_repo_requirement ON grac_practice.organization_requirement(repository_requirement_id,organization_id,status) WHERE repository_requirement_id IS NOT NULL;
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_framework_statement_org_release' AND object_id=OBJECT_ID('grac_practice.organization_framework_statements'))
 CREATE INDEX ix_pm_org_framework_statement_org_release ON grac_practice.organization_framework_statements(organization_id,release_id,status) INCLUDE(framework_statement_id,applicability_status_id,owner_id);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_pm_org_requirement_statement_requirement' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
 CREATE UNIQUE INDEX ux_pm_org_requirement_statement_requirement ON grac_practice.organization_requirement(organization_id,org_statement_id,repository_requirement_id)
 WHERE org_statement_id IS NOT NULL AND repository_requirement_id IS NOT NULL;
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_pm_org_requirement_control_code' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
 CREATE UNIQUE INDEX ux_pm_org_requirement_control_code ON grac_practice.organization_requirement(organization_id,organization_control_id,requirement_code)
 WHERE organization_control_id IS NOT NULL;
GO

INSERT grac_practice.organization_framework_statements(
 organization_id,release_id,framework_statement_id,applicability_status_id,owner_id,applicability_reason,status_id,status,entered_by,entered_dt,updated_by,updated_dt)
SELECT osa.organization_id,osa.release_id,osa.framework_statement_id,osa.applicability_status_id,osa.owner_id,osa.exclusion_justification,rs.record_status_id,osa.status,osa.entered_by,osa.entered_dt,osa.updated_by,osa.updated_dt
FROM grac_practice.organization_statement_applicability osa
LEFT JOIN grac_practice.record_status_master rs ON rs.status_code=osa.status OR rs.status_name=osa.status
WHERE NOT EXISTS(
 SELECT 1 FROM grac_practice.organization_framework_statements ofs
 WHERE ofs.organization_id=osa.organization_id
   AND ofs.release_id=osa.release_id
   AND ofs.framework_statement_id=osa.framework_statement_id
);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_practice_org_requirement_status' AND object_id=OBJECT_ID('grac_practice.practice'))
 CREATE INDEX ix_pm_practice_org_requirement_status ON grac_practice.practice(organization_id,organization_requirement_id,status,entered_dt DESC) INCLUDE(practice_code,practice_name,practice_owner,origin_type);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_practice_instance_org_practice_status' AND object_id=OBJECT_ID('grac_practice.practice_instance'))
 CREATE INDEX ix_pm_practice_instance_org_practice_status ON grac_practice.practice_instance(organization_id,practice_id,status,entered_dt DESC) INCLUDE(instance_code,instance_name,primary_owner,criticality,assurance_mode);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_practice_instance_owner_criticality' AND object_id=OBJECT_ID('grac_practice.practice_instance'))
 CREATE INDEX ix_pm_practice_instance_owner_criticality ON grac_practice.practice_instance(organization_id,primary_owner,criticality,status,entered_dt DESC);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_dependency_org_instance_status' AND object_id=OBJECT_ID('grac_practice.practice_instance_dependency'))
 CREATE INDEX ix_pm_dependency_org_instance_status ON grac_practice.practice_instance_dependency(organization_id,practice_instance_id,status,criticality,entered_dt DESC) INCLUDE(dependency_type,dependency_name,owner_name);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_evidence_org_instance_status' AND object_id=OBJECT_ID('grac_practice.practice_instance_evidence'))
 CREATE INDEX ix_pm_evidence_org_instance_status ON grac_practice.practice_instance_evidence(organization_id,practice_instance_id,status,entered_dt DESC) INCLUDE(evidence_type_id,collection_method_id,alignment_status_id,evidence_owner);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_audit_entity_status_entered' AND object_id=OBJECT_ID('grac_practice.practice_audit_trace'))
 CREATE INDEX ix_pm_audit_entity_status_entered ON grac_practice.practice_audit_trace(entity_type,entity_id,status,entered_dt DESC);
GO


/* Latest table additions, constraints, indexes, and compatibility upgrades used by Practice Management */
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
-- Custom release columns for organization-specific releases (not tied to repository)
IF OBJECT_ID('grac_practice.repository_subscription','U') IS NOT NULL AND COL_LENGTH('grac_practice.repository_subscription','custom_release_name') IS NULL
 ALTER TABLE grac_practice.repository_subscription ADD custom_release_name NVARCHAR(200) NULL;
GO
IF OBJECT_ID('grac_practice.repository_subscription','U') IS NOT NULL AND COL_LENGTH('grac_practice.repository_subscription','custom_release_notes') IS NULL
 ALTER TABLE grac_practice.repository_subscription ADD custom_release_notes NVARCHAR(MAX) NULL;
GO
-- Organization-specific custom release statements (not tied to repository framework_statement)
IF OBJECT_ID('grac_practice.custom_release_statement','U') IS NULL
CREATE TABLE grac_practice.custom_release_statement(
 custom_statement_id BIGINT IDENTITY PRIMARY KEY,
 subscription_id BIGINT NOT NULL REFERENCES grac_practice.repository_subscription(subscription_id),
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 parent_statement_id BIGINT NULL,
 node_level INT NOT NULL DEFAULT 1,
 display_order INT NOT NULL DEFAULT 0,
 statement_reference NVARCHAR(160) NULL,
 statement_title NVARCHAR(500) NOT NULL,
 statement_text NVARCHAR(MAX) NULL,
 keywords NVARCHAR(500) NULL,
 classification NVARCHAR(100) NULL,
 practice_mapping NVARCHAR(500) NULL,
 applicability_status_id INT NULL REFERENCES grac_practice.applicability_status_master(applicability_status_id),
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL
);
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

IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
 MERGE grac_practice.menu_master AS target
 USING (VALUES
  (N'dashboard',N'Dashboard',N'Practice/Index',5,N'chart-line',N'Dashboard'),
  (N'menu-master',N'Menu Master',N'Practice/Index/menu-master',6,N'bars',N'System'),
  (N'organization-setup',N'Organization Setup',N'Practice/Index/organization-setup',10,N'building',N'Organization Setup'),
  (N'organization-administration',N'Organization Administration',N'Practice/Index/organization-administration',20,N'building-user',N'Organization Administration'),
  (N'organizations',N'Organization Onboarding',N'Practice/Index/organizations',30,N'building',N'Organization Setup'),
  (N'organization-metadata',N'Organization Metadata',N'Practice/Index/organization-metadata',40,N'sliders',N'Organization Setup'),
  (N'repository-subscriptions',N'Repository Subscriptions',N'Practice/Index/repository-subscriptions',50,N'bookmark',N'Organization Setup'),
  (N'locations',N'Location Management',N'Practice/Index/locations',60,N'location-dot',N'Organization Administration'),
  (N'departments',N'Department Management',N'Practice/Index/departments',70,N'building-user',N'Organization Administration'),
  (N'business-functions',N'Business Function Management',N'Practice/Index/business-functions',80,N'briefcase',N'Organization Administration'),
  (N'teams',N'Team Management',N'Practice/Index/teams',90,N'people-group',N'Organization Administration'),
  (N'committees',N'Committee Management',N'Practice/Index/committees',100,N'users-gear',N'Organization Administration'),
  (N'roles',N'Role Master',N'Practice/Index/roles',110,N'user-lock',N'Organization Administration'),
  (N'role-menu-permissions',N'Role Menu Permission',N'Practice/Index/role-menu-permissions',120,N'list-check',N'Organization Administration'),
  (N'users',N'User Management',N'Practice/Index/users',130,N'users',N'Organization Administration'),
  (N'organization-dependencies',N'Organization Dependencies',N'Practice/Index/organization-dependencies',140,N'diagram-project',N'Organization Dependencies'),
  (N'dependency-applications',N'Applications',N'Practice/Index/dependency-applications',150,N'window-restore',N'Organization Dependencies'),
  (N'dependency-tools',N'Tools',N'Practice/Index/dependency-tools',160,N'screwdriver-wrench',N'Organization Dependencies'),
  (N'dependency-vendors',N'Vendors',N'Practice/Index/dependency-vendors',170,N'handshake',N'Organization Dependencies'),
  (N'dependency-assets',N'Assets',N'Practice/Index/dependency-assets',180,N'server',N'Organization Dependencies'),
  (N'dependency-processes',N'Processes',N'Practice/Index/dependency-processes',190,N'arrows-spin',N'Organization Dependencies'),
  (N'organization-controls',N'Organization Controls',N'Practice/Index/organization-controls',200,N'shield',N'Practice Management'),
  (N'organization-requirements',N'Organization Practices',N'Practice/Index/organization-requirements',210,N'list-check',N'Practice Management'),
  (N'practice-instances',N'Practice Instances',N'Practice/Index/practice-instances',220,N'network-wired',N'Practice Management'),
  (N'resolve',N'Resolve',N'Practice/Index/resolve',230,N'gears',N'Practice Management'),
  (N'workbench-applications',N'Applications',N'Practice/Index/workbench-applications',240,N'window-restore',N'Registers'),
  (N'workbench-tools',N'Tools',N'Practice/Index/workbench-tools',250,N'screwdriver-wrench',N'Registers'),
  (N'workbench-vendors',N'Vendors',N'Practice/Index/workbench-vendors',260,N'handshake',N'Registers'),
  (N'workbench-assets',N'Assets',N'Practice/Index/workbench-assets',270,N'server',N'Registers'),
  (N'workbench-teams',N'Teams',N'Practice/Index/workbench-teams',280,N'people-group',N'Registers'),
  (N'workbench-committees',N'Committees',N'Practice/Index/workbench-committees',290,N'users-gear',N'Registers'),
  (N'workbench-processes',N'Processes',N'Practice/Index/workbench-processes',300,N'arrows-spin',N'Registers'),
  (N'workbench-locations',N'Locations',N'Practice/Index/workbench-locations',310,N'location-dot',N'Registers'),
  (N'audit-trace',N'Audit Traceability',N'Practice/Index/audit-trace',900,N'timeline',N'Practice Management')
 ) AS source(menu_key,menu_name,menu_url,display_order,icon_class,module_type)
 ON target.menu_key=source.menu_key
 WHEN MATCHED THEN UPDATE SET menu_name=source.menu_name,menu_url=source.menu_url,display_order=source.display_order,icon_class=source.icon_class,module_type=source.module_type,status='Active',updated_by='seed',updated_dt=SYSUTCDATETIME()
 WHEN NOT MATCHED THEN INSERT(menu_key,menu_name,menu_url,display_order,icon_class,module_type,status,entered_by)
 VALUES(source.menu_key,source.menu_name,source.menu_url,source.display_order,source.icon_class,source.module_type,'Active','seed');
END
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
 UPDATE grac_practice.menu_master
 SET status='Inactive',updated_by='seed',updated_dt=SYSUTCDATETIME()
 WHERE menu_key='practice-operationalization';
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

/* Security tables required by Practice Management permissions */
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


