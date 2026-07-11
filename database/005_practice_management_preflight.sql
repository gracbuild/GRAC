/*
  GRAC Part 2 - PracticeManagement database preflight.
  Run this before/after deploying PracticeManagement scripts to identify schema drift.
*/
SET NOCOUNT ON;

DECLARE @issues TABLE(
 issue_type NVARCHAR(40) NOT NULL,
 object_name NVARCHAR(256) NOT NULL,
 column_name NVARCHAR(128) NULL,
 detail NVARCHAR(500) NOT NULL
);

DECLARE @repository_schema SYSNAME =
 CASE
   WHEN SCHEMA_ID(N'grac_new') IS NOT NULL THEN N'grac_new'
   ELSE NULL
 END;
DECLARE @repository_table_schema SYSNAME =
 CASE
   WHEN OBJECT_ID(N'grac_new.authority',N'U') IS NOT NULL THEN N'grac_new'
   ELSE @repository_schema
 END;

IF SCHEMA_ID(N'grac_practice') IS NULL
 INSERT @issues VALUES(N'Schema',N'grac_practice',NULL,N'PracticeManagement schema is missing. Run 001_practice_management_schema.sql.');

IF @repository_schema IS NULL
 INSERT @issues VALUES(N'Schema',N'grac_new',NULL,N'ControlManagement repository schema is missing. Part 1 database scripts must be applied first.');

DECLARE @required_objects TABLE(object_name NVARCHAR(256) NOT NULL);
INSERT @required_objects(object_name)
VALUES
 (N'grac_practice.organization'),
 (N'grac_practice.organization_metadata_definition'),
 (N'grac_practice.organization_metadata_value'),
 (N'grac_practice.organization_employee'),
 (N'grac_practice.frequency_master'),
 (N'grac_practice.dependency_type_master'),
 (N'GRAC_New.evidence_type_master'),
 (N'grac_practice.collection_method_master'),
 (N'grac_practice.evidence_alignment_status_master'),
 (N'grac_practice.criticality_master'),
 (N'grac_practice.practice_instance_evidence'),
 (N'grac_practice.reference_option'),
 (N'grac_practice.repository_subscription'),
 (N'grac_practice.subscription_recommendation_history'),
 (N'grac_practice.practice_audit_trace');

IF @repository_schema IS NOT NULL
BEGIN
 INSERT @required_objects(object_name)
 VALUES
  (QUOTENAME(@repository_schema)+N'.authority'),
  (QUOTENAME(@repository_schema)+N'.artifact'),
  (QUOTENAME(@repository_schema)+N'.release'),
  (QUOTENAME(@repository_schema)+N'.reference_option');
END;

INSERT @issues(issue_type,object_name,column_name,detail)
SELECT N'Object',o.object_name,NULL,N'Required table is missing.'
FROM @required_objects o
WHERE OBJECT_ID(o.object_name,N'U') IS NULL
  AND OBJECT_ID(o.object_name,N'SN') IS NULL;

DECLARE @required_columns TABLE(object_name NVARCHAR(256) NOT NULL,column_name NVARCHAR(128) NOT NULL);
INSERT @required_columns(object_name,column_name)
VALUES
 (N'grac_practice.organization',N'organization_id'),
 (N'grac_practice.organization',N'organization_code'),
 (N'grac_practice.organization',N'organization_name'),
 (N'grac_practice.organization',N'industry'),
 (N'grac_practice.organization',N'entity_type'),
 (N'grac_practice.organization',N'country'),
 (N'grac_practice.organization',N'status'),
 (N'grac_practice.organization_metadata_definition',N'metadata_definition_id'),
 (N'grac_practice.organization_metadata_definition',N'metadata_key'),
 (N'grac_practice.organization_metadata_definition',N'data_type'),
 (N'grac_practice.organization_metadata_value',N'organization_id'),
 (N'grac_practice.organization_metadata_value',N'metadata_definition_id'),
 (N'grac_practice.organization_metadata_value',N'value_text'),
 (N'grac_practice.organization_metadata_value',N'value_number'),
 (N'grac_practice.organization_metadata_value',N'value_date'),
 (N'grac_practice.organization_metadata_value',N'value_bool'),
 (N'grac_practice.organization_metadata_value',N'value_json'),
 (N'grac_practice.organization_employee',N'employee_id'),
 (N'grac_practice.organization_employee',N'organization_id'),
 (N'grac_practice.organization_employee',N'employee_code'),
 (N'grac_practice.organization_employee',N'employee_name'),
 (N'grac_practice.organization_employee',N'status'),
 (N'grac_practice.organization_employee',N'record_status_id'),
 (N'grac_practice.frequency_master',N'frequency_id'),
 (N'grac_practice.frequency_master',N'frequency_code'),
 (N'grac_practice.frequency_master',N'frequency_name'),
 (N'grac_practice.practice_instance',N'frequency_id'),
 (N'grac_practice.dependency_type_master',N'dependency_type_id'),
 (N'grac_practice.dependency_type_master',N'dependency_type_code'),
 (N'grac_practice.dependency_type_master',N'dependency_type_name'),
 (N'grac_practice.criticality_master',N'criticality_id'),
 (N'grac_practice.criticality_master',N'criticality_code'),
 (N'grac_practice.criticality_master',N'criticality_name'),
 (N'grac_practice.practice_instance_dependency',N'dependency_type_id'),
 (N'grac_practice.practice_instance_dependency',N'criticality_id'),
 (N'grac_practice.practice_instance_dependency',N'record_status_id'),
 (N'GRAC_New.evidence_type_master',N'evidence_type_id'),
 (N'GRAC_New.evidence_type_master',N'evidence_type_code'),
 (N'GRAC_New.evidence_type_master',N'evidence_type_name'),
 (N'grac_practice.collection_method_master',N'collection_method_id'),
 (N'grac_practice.collection_method_master',N'collection_method_code'),
 (N'grac_practice.collection_method_master',N'collection_method_name'),
 (N'grac_practice.evidence_alignment_status_master',N'alignment_status_id'),
 (N'grac_practice.evidence_alignment_status_master',N'alignment_status_code'),
 (N'grac_practice.evidence_alignment_status_master',N'alignment_status_name'),
 (N'grac_practice.practice_instance_evidence',N'evidence_id'),
 (N'grac_practice.practice_instance_evidence',N'organization_id'),
 (N'grac_practice.practice_instance_evidence',N'practice_instance_id'),
 (N'grac_practice.practice_instance_evidence',N'evidence_type_id'),
 (N'grac_practice.practice_instance_evidence',N'inherited_from_repository'),
 (N'grac_practice.practice_instance_evidence',N'organization_modified'),
 (N'grac_practice.practice_instance_evidence',N'is_mandatory'),
 (N'grac_practice.practice_instance_evidence',N'collection_method_id'),
 (N'grac_practice.practice_instance_evidence',N'collection_frequency_id'),
 (N'grac_practice.practice_instance_evidence',N'evidence_owner'),
 (N'grac_practice.practice_instance_evidence',N'alignment_status_id'),
 (N'grac_practice.practice_instance_evidence',N'record_status_id'),
 (N'grac_practice.reference_option',N'option_group'),
 (N'grac_practice.reference_option',N'option_value'),
 (N'grac_practice.reference_option',N'option_label'),
 (N'grac_practice.repository_subscription',N'organization_id'),
 (N'grac_practice.repository_subscription',N'authority_id'),
 (N'grac_practice.repository_subscription',N'artifact_id'),
 (N'grac_practice.repository_subscription',N'release_id'),
 (N'grac_practice.repository_subscription',N'subscription_status'),
 (N'grac_practice.subscription_recommendation_history',N'organization_id'),
 (N'grac_practice.subscription_recommendation_history',N'release_id'),
 (N'grac_practice.subscription_recommendation_history',N'decision_status'),
 (N'grac_practice.subscription_recommendation_history',N'confidence_level'),
 (N'grac_practice.organization_control',N'organization_control_id'),
 (N'grac_practice.organization_control',N'organization_id'),
 (N'grac_practice.organization_control',N'origin_type'),
 (N'grac_practice.organization_control',N'repository_control_id'),
 (N'grac_practice.organization_control',N'control_code'),
 (N'grac_practice.organization_control',N'control_name'),
 (N'grac_practice.organization_control',N'description'),
 (N'grac_practice.organization_control',N'objective'),
 (N'grac_practice.organization_control',N'control_domain_id'),
 (N'grac_practice.organization_control',N'control_sub_domain_id'),
 (N'grac_practice.organization_control',N'is_manually_added'),
 (N'grac_practice.organization_control',N'subscription_id'),
 (N'grac_practice.organization_control',N'release_id'),
 (N'grac_practice.organization_control',N'artifact_id'),
 (N'grac_practice.organization_control',N'applicability_status'),
 (N'grac_practice.organization_control',N'criticality'),
 (N'grac_practice.organization_control',N'status'),
 (N'grac_practice.practice_audit_trace',N'entity_type'),
 (N'grac_practice.practice_audit_trace',N'entity_id'),
 (N'grac_practice.practice_audit_trace',N'action_type'),
 (N'grac_practice.practice_audit_trace',N'after_json');

IF @repository_table_schema IS NOT NULL
BEGIN
 INSERT @required_columns(object_name,column_name)
 VALUES
  (QUOTENAME(@repository_table_schema)+N'.authority',N'authority_id'),
  (QUOTENAME(@repository_table_schema)+N'.authority',N'authority_code'),
  (QUOTENAME(@repository_table_schema)+N'.authority',N'authority_name'),
  (QUOTENAME(@repository_table_schema)+N'.authority',N'status'),
  (QUOTENAME(@repository_table_schema)+N'.artifact',N'artifact_id'),
  (QUOTENAME(@repository_table_schema)+N'.artifact',N'authority_id'),
  (QUOTENAME(@repository_table_schema)+N'.artifact',N'artifact_code'),
  (QUOTENAME(@repository_table_schema)+N'.artifact',N'artifact_name'),
  (QUOTENAME(@repository_table_schema)+N'.artifact',N'status'),
  (QUOTENAME(@repository_table_schema)+N'.release',N'release_id'),
  (QUOTENAME(@repository_table_schema)+N'.release',N'artifact_id'),
  (QUOTENAME(@repository_table_schema)+N'.release',N'version_no'),
  (QUOTENAME(@repository_table_schema)+N'.release',N'status'),
  (QUOTENAME(@repository_table_schema)+N'.control',N'control_id'),
  (QUOTENAME(@repository_table_schema)+N'.control',N'control_code'),
  (QUOTENAME(@repository_table_schema)+N'.control',N'control_name'),
  (QUOTENAME(@repository_table_schema)+N'.control',N'description'),
  (QUOTENAME(@repository_table_schema)+N'.control',N'objective'),
  (QUOTENAME(@repository_table_schema)+N'.control',N'control_domain_id'),
  (QUOTENAME(@repository_table_schema)+N'.control',N'control_sub_domain_id'),
  (QUOTENAME(@repository_table_schema)+N'.control',N'status'),
  (QUOTENAME(@repository_table_schema)+N'.source_structure_node',N'structure_node_id'),
  (QUOTENAME(@repository_table_schema)+N'.source_structure_node',N'release_id'),
  (QUOTENAME(@repository_table_schema)+N'.source_structure_node',N'status'),
  (QUOTENAME(@repository_table_schema)+N'.source_control_map',N'structure_node_id'),
  (QUOTENAME(@repository_table_schema)+N'.source_control_map',N'control_id'),
  (QUOTENAME(@repository_table_schema)+N'.source_control_map',N'release_id'),
  (QUOTENAME(@repository_table_schema)+N'.source_control_map',N'artifact_id'),
  (QUOTENAME(@repository_table_schema)+N'.source_control_map',N'status'),
  (QUOTENAME(@repository_table_schema)+N'.reference_option',N'option_group'),
  (QUOTENAME(@repository_table_schema)+N'.reference_option',N'option_value'),
  (QUOTENAME(@repository_table_schema)+N'.reference_option',N'option_label'),
  (QUOTENAME(@repository_table_schema)+N'.reference_option',N'status');
END;

INSERT @issues(issue_type,object_name,column_name,detail)
SELECT N'Column',c.object_name,c.column_name,N'Required column is missing.'
FROM @required_columns c
WHERE OBJECT_ID(c.object_name,N'U') IS NOT NULL
  AND COL_LENGTH(c.object_name,c.column_name) IS NULL;

IF EXISTS(SELECT 1 FROM @issues)
BEGIN
 SELECT issue_type IssueType,object_name ObjectName,column_name ColumnName,detail Detail
 FROM @issues
 ORDER BY issue_type,object_name,column_name;
END
ELSE
BEGIN
 SELECT CAST(1 AS BIT) Success,
   COALESCE(@repository_schema,N'') RepositorySchema,
   N'PracticeManagement database preflight passed.' Message;
END;
