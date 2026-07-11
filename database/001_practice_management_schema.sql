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
-- Custom release columns for organization-specific releases (not tied to repository)
IF OBJECT_ID('grac_practice.repository_subscription','U') IS NOT NULL AND COL_LENGTH('grac_practice.repository_subscription','custom_release_name') IS NULL
 ALTER TABLE grac_practice.repository_subscription ADD custom_release_name NVARCHAR(200) NULL;
GO
IF OBJECT_ID('grac_practice.repository_subscription','U') IS NOT NULL AND COL_LENGTH('grac_practice.repository_subscription','custom_release_notes') IS NULL
 ALTER TABLE grac_practice.repository_subscription ADD custom_release_notes NVARCHAR(MAX) NULL;
GO

-- Organization-specific custom release statements (not tied to repository framework_statement)
IF OBJECT_ID('grac_practice.custom_release_source_structure','U') IS NULL
CREATE TABLE grac_practice.custom_release_source_structure(
 structure_node_id BIGINT IDENTITY PRIMARY KEY,
 subscription_id BIGINT NOT NULL REFERENCES grac_practice.repository_subscription(subscription_id),
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 parent_node_id BIGINT NULL,
 node_level INT NOT NULL DEFAULT 1,
 display_order INT NOT NULL DEFAULT 0,
 node_reference NVARCHAR(160) NULL,
 node_title NVARCHAR(500) NOT NULL,
 description NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT fk_pm_custom_source_structure_parent
   FOREIGN KEY(parent_node_id) REFERENCES grac_practice.custom_release_source_structure(structure_node_id)
);
GO

IF OBJECT_ID('grac_practice.custom_release_statement','U') IS NULL
CREATE TABLE grac_practice.custom_release_statement(
 custom_statement_id BIGINT IDENTITY PRIMARY KEY,
 subscription_id BIGINT NOT NULL REFERENCES grac_practice.repository_subscription(subscription_id),
 organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 parent_statement_id BIGINT NULL,
 structure_node_id BIGINT NULL REFERENCES grac_practice.custom_release_source_structure(structure_node_id),
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

IF OBJECT_ID('grac_practice.uq_pm_organization_control','UQ') IS NOT NULL
 ALTER TABLE grac_practice.organization_control DROP CONSTRAINT uq_pm_organization_control;
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

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_custom_source_structure_sub_org_status' AND object_id=OBJECT_ID('grac_practice.custom_release_source_structure'))
 CREATE INDEX ix_pm_custom_source_structure_sub_org_status
   ON grac_practice.custom_release_source_structure(subscription_id,organization_id,status,display_order)
   INCLUDE(parent_node_id,node_level,node_reference,node_title);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_custom_statement_structure_node' AND object_id=OBJECT_ID('grac_practice.custom_release_statement'))
 CREATE INDEX ix_pm_custom_statement_structure_node
   ON grac_practice.custom_release_statement(structure_node_id,subscription_id,organization_id,status)
   WHERE structure_node_id IS NOT NULL;
GO
