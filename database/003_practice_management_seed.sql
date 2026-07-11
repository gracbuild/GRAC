/*
  GRAC Part 2 - Practice Intelligence Layer
  Foundation seed data.
*/
MERGE grac_practice.organization_metadata_definition AS target
USING (VALUES
 (N'entity_type',N'Entity Type',N'Lookup',N'entity-types',1),
 (N'deposit_taking_status',N'Deposit Taking Status',N'Lookup',N'yes-no',0),
 (N'asset_size_scale',N'Asset Size / Scale Classification',N'Lookup',N'asset-size-scale',0),
 (N'regulatory_registration_type',N'Regulatory Registration Type',N'Lookup',N'regulatory-registration-types',0),
 (N'payment_aggregator_status',N'Payment Aggregator Status',N'Lookup',N'yes-no',0),
 (N'investment_advisor_status',N'Investment Advisor Status',N'Lookup',N'yes-no',0),
 (N'cloud_adoption',N'Cloud Adoption',N'Lookup',N'adoption-levels',0),
 (N'stores_cardholder_data',N'Stores Cardholder Data',N'Boolean',NULL,0),
 (N'geographic_presence',N'Geographic Presence',N'Json',N'countries',0),
 (N'business_functions',N'Business Functions',N'Json',N'business-function-types',0),
 (N'technology_landscape',N'Technology Landscape',N'Json',N'technology-landscape',0)
) AS source(metadata_key,metadata_name,data_type,lookup_group,is_required)
ON target.metadata_key=source.metadata_key
WHEN MATCHED THEN UPDATE SET metadata_name=source.metadata_name,data_type=source.data_type,lookup_group=source.lookup_group,is_required=source.is_required,status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(metadata_key,metadata_name,data_type,lookup_group,is_required,status,entered_by)
VALUES(source.metadata_key,source.metadata_name,source.data_type,source.lookup_group,source.is_required,N'Active',N'system');
GO

MERGE grac_practice.reference_option AS target
USING (VALUES
 (N'entity-types',N'Bank',N'Bank',1),(N'entity-types',N'NBFC',N'NBFC',2),(N'entity-types',N'Insurance',N'Insurance',3),(N'entity-types',N'Fintech',N'Fintech',4),(N'entity-types',N'Payment Aggregator',N'Payment Aggregator',5),(N'entity-types',N'Investment Advisor',N'Investment Advisor',6),(N'entity-types',N'Healthcare',N'Healthcare',7),(N'entity-types',N'Other',N'Other',99),
 (N'yes-no',N'Yes',N'Yes',1),(N'yes-no',N'No',N'No',2),(N'yes-no',N'Not Applicable',N'Not Applicable',3),
 (N'asset-size-scale',N'Micro',N'Micro',1),(N'asset-size-scale',N'Small',N'Small',2),(N'asset-size-scale',N'Medium',N'Medium',3),(N'asset-size-scale',N'Large',N'Large',4),(N'asset-size-scale',N'Systemically Important',N'Systemically Important',5),
 (N'regulatory-registration-types',N'RBI Regulated',N'RBI Regulated',1),(N'regulatory-registration-types',N'SEBI Registered',N'SEBI Registered',2),(N'regulatory-registration-types',N'IRDAI Regulated',N'IRDAI Regulated',3),(N'regulatory-registration-types',N'NPCI Participant',N'NPCI Participant',4),(N'regulatory-registration-types',N'Other',N'Other',99),
 (N'adoption-levels',N'None',N'None',1),(N'adoption-levels',N'Low',N'Low',2),(N'adoption-levels',N'Moderate',N'Moderate',3),(N'adoption-levels',N'High',N'High',4),
 (N'business-function-types',N'Information Technology',N'Information Technology',1),(N'business-function-types',N'Operations',N'Operations',2),(N'business-function-types',N'Finance',N'Finance',3),(N'business-function-types',N'Compliance',N'Compliance',4),(N'business-function-types',N'Risk Management',N'Risk Management',5),(N'business-function-types',N'Customer Service',N'Customer Service',6),
 (N'technology-landscape',N'Core Banking',N'Core Banking',1),(N'technology-landscape',N'Cloud Services',N'Cloud Services',2),(N'technology-landscape',N'Payment Systems',N'Payment Systems',3),(N'technology-landscape',N'Data Warehouse',N'Data Warehouse',4),(N'technology-landscape',N'Identity Platform',N'Identity Platform',5),(N'technology-landscape',N'Endpoint Management',N'Endpoint Management',6)
) AS source(option_group,option_value,option_label,display_order)
ON target.option_group=source.option_group AND target.option_value=source.option_value
WHEN MATCHED THEN UPDATE SET option_label=source.option_label,display_order=source.display_order,status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(option_group,option_value,option_label,display_order,status,entered_by)
VALUES(source.option_group,source.option_value,source.option_label,source.display_order,N'Active',N'system');
GO

IF NOT EXISTS(SELECT 1 FROM grac_practice.organization WHERE organization_code=N'DEMO-BANK')
 INSERT grac_practice.organization(organization_code,organization_name,industry,entity_type,country,status,entered_by)
 VALUES(N'DEMO-BANK',N'Demo Bank Limited',N'Banking',N'Bank',N'India',N'Active',N'system');
GO

DECLARE @org BIGINT=(SELECT organization_id FROM grac_practice.organization WHERE organization_code=N'DEMO-BANK');
IF @org IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_business_function WHERE organization_id=@org AND function_code=N'IT')
 INSERT grac_practice.organization_business_function(organization_id,function_code,function_name,owner_name,criticality,status,entered_by)
 VALUES(@org,N'IT',N'Information Technology',N'IT Head',N'Critical',N'Active',N'system');
GO
