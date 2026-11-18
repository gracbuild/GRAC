-- =====================================================================
-- 570_org_registry_masters_menu.sql
--
-- Organization Registry -- controlled values, menu, Legal Entities list.
--
-- 1. org_registry_master_value <- workbook sheet "15 Masters & Codes"
--    (every list, every value, workbook order). Values that the workbook's
--    own SAMPLE rows use but sheet 15 does not list are added with
--    is_workbook_value = 0 and a source_note: the rows load exactly as
--    given and the screen shows the value flagged "not approved" until a
--    data owner approves it (START HERE: additions require data-owner
--    approval). Nothing is renamed or corrected.
-- 2. location_type_master / committee_designation_master gain the sheet-15
--    LocationType / CommitteeMemberDesignation values they lack: those
--    columns store the master's id (existing FKs), so the values have to
--    exist there. Existing values are untouched.
-- 3. Menu: 'org-registry' (Organization Registry), first in Organization
--    Management; 'organizations' renamed "Legal Entities" -- the existing
--    organization rows ARE the Legal Entity level now. Both rows sit under
--    the 'Organization' group, hidden from the Practice Management sidebar,
--    exactly as 512 placed 'organizations'. 274 is amended to match.
-- 4. sp_org_organization_list (latest body: 518) re-issued with the
--    Legal Entity's Organization and parent Legal Entity added -- the
--    Legal Entities list shows where each sits in the hierarchy.
--
-- Idempotent (MERGE / NOT EXISTS). ASCII only.
-- Rollback: 570_org_registry_masters_menu_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO
IF OBJECT_ID('grac_practice.org_registry_master_value','U') IS NULL
   OR COL_LENGTH('grac_practice.organization','registry_organization_id') IS NULL
BEGIN
    PRINT 'ABORT (570): run 569_org_registry_schema.sql first. Nothing was changed.';
    SET NOEXEC ON;
END
GO
IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR COL_LENGTH('grac_practice.menu_master','show_in_sidebar') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'Organization')
BEGIN
    PRINT 'ABORT (570): menu_master / the Organization group row is missing (274, 390, 512). Nothing was changed.';
    SET NOEXEC ON;
END
GO

-- 1. Controlled values.
MERGE grac_practice.org_registry_master_value AS t
USING (VALUES
    (N'YesNo', N'Yes', 10, CAST(1 AS BIT), NULL),
    (N'YesNo', N'No', 20, CAST(1 AS BIT), NULL),
    (N'RecordStatus', N'Active', 10, CAST(1 AS BIT), NULL),
    (N'RecordStatus', N'Inactive', 20, CAST(1 AS BIT), NULL),
    (N'RecordStatus', N'Draft', 30, CAST(1 AS BIT), NULL),
    (N'RecordStatus', N'Pending Approval', 40, CAST(1 AS BIT), NULL),
    (N'RecordStatus', N'Closed', 50, CAST(1 AS BIT), NULL),
    (N'OrgUnitType', N'Corporate Office', 10, CAST(1 AS BIT), NULL),
    (N'OrgUnitType', N'Head Office', 20, CAST(1 AS BIT), NULL),
    (N'OrgUnitType', N'Zone', 30, CAST(1 AS BIT), NULL),
    (N'OrgUnitType', N'Region', 40, CAST(1 AS BIT), NULL),
    (N'OrgUnitType', N'Area', 50, CAST(1 AS BIT), NULL),
    (N'OrgUnitType', N'Cluster', 60, CAST(1 AS BIT), NULL),
    (N'OrgUnitType', N'Branch', 70, CAST(1 AS BIT), NULL),
    (N'OrgUnitType', N'Service Centre', 80, CAST(1 AS BIT), NULL),
    (N'OrgUnitType', N'Processing Centre', 90, CAST(1 AS BIT), NULL),
    (N'OrgUnitType', N'Training Centre', 100, CAST(1 AS BIT), NULL),
    (N'OrgUnitType', N'Other', 110, CAST(1 AS BIT), NULL),
    (N'LocationType', N'Corporate Office', 10, CAST(1 AS BIT), NULL),
    (N'LocationType', N'Head Office', 20, CAST(1 AS BIT), NULL),
    (N'LocationType', N'Zonal Office', 30, CAST(1 AS BIT), NULL),
    (N'LocationType', N'Regional Office', 40, CAST(1 AS BIT), NULL),
    (N'LocationType', N'Area Office', 50, CAST(1 AS BIT), NULL),
    (N'LocationType', N'Branch', 60, CAST(1 AS BIT), NULL),
    (N'LocationType', N'Service Centre', 70, CAST(1 AS BIT), NULL),
    (N'LocationType', N'Processing Centre', 80, CAST(1 AS BIT), NULL),
    (N'LocationType', N'Training Centre', 90, CAST(1 AS BIT), NULL),
    (N'LocationType', N'Other', 100, CAST(1 AS BIT), NULL),
    (N'DepartmentType', N'Business', 10, CAST(1 AS BIT), NULL),
    (N'DepartmentType', N'Operations', 20, CAST(1 AS BIT), NULL),
    (N'DepartmentType', N'Control / Assurance', 30, CAST(1 AS BIT), NULL),
    (N'DepartmentType', N'Support', 40, CAST(1 AS BIT), NULL),
    (N'DepartmentType', N'Technology', 50, CAST(1 AS BIT), NULL),
    (N'DepartmentType', N'Other', 60, CAST(1 AS BIT), NULL),
    (N'FunctionCategory', N'Business', 10, CAST(1 AS BIT), NULL),
    (N'FunctionCategory', N'Operations', 20, CAST(1 AS BIT), NULL),
    (N'FunctionCategory', N'Control', 30, CAST(1 AS BIT), NULL),
    (N'FunctionCategory', N'Support', 40, CAST(1 AS BIT), NULL),
    (N'FunctionCategory', N'Corporate', 50, CAST(1 AS BIT), NULL),
    (N'FunctionCategory', N'Technology', 60, CAST(1 AS BIT), NULL),
    (N'FunctionCategory', N'Other', 70, CAST(1 AS BIT), NULL),
    (N'TeamType', N'Permanent Functional Team', 10, CAST(1 AS BIT), NULL),
    (N'TeamType', N'Cross-functional Team', 20, CAST(1 AS BIT), NULL),
    (N'TeamType', N'Project Team', 30, CAST(1 AS BIT), NULL),
    (N'TeamType', N'Committee Secretariat', 40, CAST(1 AS BIT), NULL),
    (N'TeamType', N'Operational Team', 50, CAST(1 AS BIT), NULL),
    (N'TeamType', N'Other', 60, CAST(1 AS BIT), NULL),
    (N'PersonCategory', N'Employee', 10, CAST(1 AS BIT), NULL),
    (N'PersonCategory', N'Director', 20, CAST(1 AS BIT), NULL),
    (N'PersonCategory', N'Key Managerial Personnel', 30, CAST(1 AS BIT), NULL),
    (N'PersonCategory', N'Officer', 40, CAST(1 AS BIT), NULL),
    (N'PersonCategory', N'Other', 50, CAST(1 AS BIT), NULL),
    (N'EmploymentType', N'Permanent', 10, CAST(1 AS BIT), NULL),
    (N'EmploymentType', N'Fixed Term', 20, CAST(1 AS BIT), NULL),
    (N'EmploymentType', N'Probation', 30, CAST(1 AS BIT), NULL),
    (N'EmploymentType', N'Trainee', 40, CAST(1 AS BIT), NULL),
    (N'EmploymentType', N'Contractual', 50, CAST(1 AS BIT), NULL),
    (N'EmploymentType', N'Other', 60, CAST(1 AS BIT), NULL),
    (N'PersonStatus', N'Active', 10, CAST(1 AS BIT), NULL),
    (N'PersonStatus', N'On Leave', 20, CAST(1 AS BIT), NULL),
    (N'PersonStatus', N'Seconded', 30, CAST(1 AS BIT), NULL),
    (N'PersonStatus', N'Resigned', 40, CAST(1 AS BIT), NULL),
    (N'PersonStatus', N'Retired', 50, CAST(1 AS BIT), NULL),
    (N'PersonStatus', N'Terminated', 60, CAST(1 AS BIT), NULL),
    (N'PersonStatus', N'Other', 70, CAST(1 AS BIT), NULL),
    (N'CommitteeType', N'Board Committee', 10, CAST(1 AS BIT), NULL),
    (N'CommitteeType', N'Board-level Committee', 20, CAST(1 AS BIT), NULL),
    (N'CommitteeType', N'Management Committee', 30, CAST(1 AS BIT), NULL),
    (N'CommitteeType', N'Statutory Committee', 40, CAST(1 AS BIT), NULL),
    (N'CommitteeType', N'Operational Committee', 50, CAST(1 AS BIT), NULL),
    (N'CommitteeType', N'Other', 60, CAST(1 AS BIT), NULL),
    (N'ReviewFrequency', N'Monthly', 10, CAST(1 AS BIT), NULL),
    (N'ReviewFrequency', N'Quarterly', 20, CAST(1 AS BIT), NULL),
    (N'ReviewFrequency', N'Half-yearly', 30, CAST(1 AS BIT), NULL),
    (N'ReviewFrequency', N'Annually', 40, CAST(1 AS BIT), NULL),
    (N'ReviewFrequency', N'As Required', 50, CAST(1 AS BIT), NULL),
    (N'CommitteeMemberDesignation', N'Chairperson', 10, CAST(1 AS BIT), NULL),
    (N'CommitteeMemberDesignation', N'Member', 20, CAST(1 AS BIT), NULL),
    (N'CommitteeMemberDesignation', N'Permanent Invitee', 30, CAST(1 AS BIT), NULL),
    (N'CommitteeMemberDesignation', N'Special Invitee', 40, CAST(1 AS BIT), NULL),
    (N'CommitteeMemberDesignation', N'Secretary', 50, CAST(1 AS BIT), NULL),
    (N'CommitteeMemberDesignation', N'Convenor', 60, CAST(1 AS BIT), NULL),
    (N'CommitteeMemberDesignation', N'Other', 70, CAST(1 AS BIT), NULL),
    (N'ProcessLevel', N'L1', 10, CAST(1 AS BIT), NULL),
    (N'ProcessLevel', N'L2', 20, CAST(1 AS BIT), NULL),
    (N'ProcessLevel', N'L3', 30, CAST(1 AS BIT), NULL),
    (N'ProcessNature', N'Core', 10, CAST(1 AS BIT), NULL),
    (N'ProcessNature', N'Management', 20, CAST(1 AS BIT), NULL),
    (N'ProcessNature', N'Support', 30, CAST(1 AS BIT), NULL),
    (N'ProcessFrequency', N'Real-time', 10, CAST(1 AS BIT), NULL),
    (N'ProcessFrequency', N'Daily', 20, CAST(1 AS BIT), NULL),
    (N'ProcessFrequency', N'Weekly', 30, CAST(1 AS BIT), NULL),
    (N'ProcessFrequency', N'Monthly', 40, CAST(1 AS BIT), NULL),
    (N'ProcessFrequency', N'Quarterly', 50, CAST(1 AS BIT), NULL),
    (N'ProcessFrequency', N'Half-yearly', 60, CAST(1 AS BIT), NULL),
    (N'ProcessFrequency', N'Annually', 70, CAST(1 AS BIT), NULL),
    (N'ProcessFrequency', N'Event-driven', 80, CAST(1 AS BIT), NULL),
    (N'ProcessFrequency', N'As Required', 90, CAST(1 AS BIT), NULL),
    (N'RegulatoryImpact', N'Direct', 10, CAST(1 AS BIT), NULL),
    (N'RegulatoryImpact', N'Indirect', 20, CAST(1 AS BIT), NULL),
    (N'RegulatoryImpact', N'None', 30, CAST(1 AS BIT), NULL),
    (N'RegulatoryImpact', N'To Be Assessed', 40, CAST(1 AS BIT), NULL),
    (N'ProductCategory', N'Gold Loan', 10, CAST(1 AS BIT), NULL),
    (N'ProductCategory', N'Vehicle Loan', 20, CAST(1 AS BIT), NULL),
    (N'ProductCategory', N'Personal Loan', 30, CAST(1 AS BIT), NULL),
    (N'ProductCategory', N'Business Loan', 40, CAST(1 AS BIT), NULL),
    (N'ProductCategory', N'Mortgage / Loan Against Property', 50, CAST(1 AS BIT), NULL),
    (N'ProductCategory', N'Deposit', 60, CAST(1 AS BIT), NULL),
    (N'ProductCategory', N'Investment / Bond', 70, CAST(1 AS BIT), NULL),
    (N'ProductCategory', N'Insurance / Distribution', 80, CAST(1 AS BIT), NULL),
    (N'ProductCategory', N'Other', 90, CAST(1 AS BIT), NULL),
    (N'ProductStatus', N'Active', 10, CAST(1 AS BIT), NULL),
    (N'ProductStatus', N'Under Development', 20, CAST(1 AS BIT), NULL),
    (N'ProductStatus', N'Withdrawn', 30, CAST(1 AS BIT), NULL),
    (N'ProductStatus', N'Discontinued', 40, CAST(1 AS BIT), NULL),
    (N'ChannelType', N'Physical Branch', 10, CAST(1 AS BIT), NULL),
    (N'ChannelType', N'Digital / Mobile', 20, CAST(1 AS BIT), NULL),
    (N'ChannelType', N'Internet', 30, CAST(1 AS BIT), NULL),
    (N'ChannelType', N'Call Centre', 40, CAST(1 AS BIT), NULL),
    (N'ChannelType', N'Business Correspondent', 50, CAST(1 AS BIT), NULL),
    (N'ChannelType', N'Partner Channel', 60, CAST(1 AS BIT), NULL),
    (N'ChannelType', N'Centralised Processing', 70, CAST(1 AS BIT), NULL),
    (N'ChannelType', N'Other', 80, CAST(1 AS BIT), NULL),
    (N'ChannelStatus', N'Active', 10, CAST(1 AS BIT), NULL),
    (N'ChannelStatus', N'Planned', 20, CAST(1 AS BIT), NULL),
    (N'ChannelStatus', N'Inactive', 30, CAST(1 AS BIT), NULL),
    (N'ChannelStatus', N'Retired', 40, CAST(1 AS BIT), NULL),
    (N'ProcessRisk', N'Credit', 10, CAST(1 AS BIT), NULL),
    (N'ProcessRisk', N'Operational', 20, CAST(1 AS BIT), NULL),
    (N'ProcessRisk', N'Compliance', 30, CAST(1 AS BIT), NULL),
    (N'ProcessRisk', N'Conduct', 40, CAST(1 AS BIT), NULL),
    (N'ProcessRisk', N'Fraud', 50, CAST(1 AS BIT), NULL),
    (N'ProcessRisk', N'Technology', 60, CAST(1 AS BIT), NULL),
    (N'ProcessRisk', N'Cybersecurity', 70, CAST(1 AS BIT), NULL),
    (N'ProcessRisk', N'Financial', 80, CAST(1 AS BIT), NULL),
    (N'ProcessRisk', N'Reputational', 90, CAST(1 AS BIT), NULL),
    (N'ProcessRisk', N'Strategic', 100, CAST(1 AS BIT), NULL),
    (N'ProcessRisk', N'Other', 110, CAST(1 AS BIT), NULL),
    (N'State', N'Andhra Pradesh', 10, CAST(1 AS BIT), NULL),
    (N'State', N'Arunachal Pradesh', 20, CAST(1 AS BIT), NULL),
    (N'State', N'Assam', 30, CAST(1 AS BIT), NULL),
    (N'State', N'Bihar', 40, CAST(1 AS BIT), NULL),
    (N'State', N'Chhattisgarh', 50, CAST(1 AS BIT), NULL),
    (N'State', N'Goa', 60, CAST(1 AS BIT), NULL),
    (N'State', N'Gujarat', 70, CAST(1 AS BIT), NULL),
    (N'State', N'Haryana', 80, CAST(1 AS BIT), NULL),
    (N'State', N'Himachal Pradesh', 90, CAST(1 AS BIT), NULL),
    (N'State', N'Jharkhand', 100, CAST(1 AS BIT), NULL),
    (N'State', N'Karnataka', 110, CAST(1 AS BIT), NULL),
    (N'State', N'Kerala', 120, CAST(1 AS BIT), NULL),
    (N'State', N'Madhya Pradesh', 130, CAST(1 AS BIT), NULL),
    (N'State', N'Maharashtra', 140, CAST(1 AS BIT), NULL),
    (N'State', N'Manipur', 150, CAST(1 AS BIT), NULL),
    (N'State', N'Meghalaya', 160, CAST(1 AS BIT), NULL),
    (N'State', N'Mizoram', 170, CAST(1 AS BIT), NULL),
    (N'State', N'Nagaland', 180, CAST(1 AS BIT), NULL),
    (N'State', N'Odisha', 190, CAST(1 AS BIT), NULL),
    (N'State', N'Punjab', 200, CAST(1 AS BIT), NULL),
    (N'State', N'Rajasthan', 210, CAST(1 AS BIT), NULL),
    (N'State', N'Sikkim', 220, CAST(1 AS BIT), NULL),
    (N'State', N'Tamil Nadu', 230, CAST(1 AS BIT), NULL),
    (N'State', N'Telangana', 240, CAST(1 AS BIT), NULL),
    (N'State', N'Tripura', 250, CAST(1 AS BIT), NULL),
    (N'State', N'Uttar Pradesh', 260, CAST(1 AS BIT), NULL),
    (N'State', N'Uttarakhand', 270, CAST(1 AS BIT), NULL),
    (N'State', N'West Bengal', 280, CAST(1 AS BIT), NULL),
    (N'State', N'Andaman and Nicobar Islands', 290, CAST(1 AS BIT), NULL),
    (N'State', N'Chandigarh', 300, CAST(1 AS BIT), NULL),
    (N'State', N'Dadra and Nagar Haveli and Daman and Diu', 310, CAST(1 AS BIT), NULL),
    (N'State', N'Delhi', 320, CAST(1 AS BIT), NULL),
    (N'State', N'Jammu and Kashmir', 330, CAST(1 AS BIT), NULL),
    (N'State', N'Ladakh', 340, CAST(1 AS BIT), NULL),
    (N'State', N'Lakshadweep', 350, CAST(1 AS BIT), NULL),
    (N'State', N'Puducherry', 360, CAST(1 AS BIT), NULL),
    (N'State', N'Other', 370, CAST(1 AS BIT), NULL),
    (N'Country', N'India', 10, CAST(1 AS BIT), NULL),
    (N'Country', N'Other', 20, CAST(1 AS BIT), NULL),
    (N'BusinessUnitType', N'Retail Lending', 10, CAST(1 AS BIT), NULL),
    (N'BusinessUnitType', N'Gold Loan', 20, CAST(1 AS BIT), NULL),
    (N'BusinessUnitType', N'Vehicle Finance', 30, CAST(1 AS BIT), NULL),
    (N'BusinessUnitType', N'Deposits', 40, CAST(1 AS BIT), NULL),
    (N'BusinessUnitType', N'Treasury', 50, CAST(1 AS BIT), NULL),
    (N'BusinessUnitType', N'Collections', 60, CAST(1 AS BIT), NULL),
    (N'BusinessUnitType', N'Customer Service', 70, CAST(1 AS BIT), NULL),
    (N'BusinessUnitType', N'Corporate Services', 80, CAST(1 AS BIT), NULL),
    (N'BusinessUnitType', N'Other', 90, CAST(1 AS BIT), NULL),
    (N'OrganizationType', N'Company', 10, CAST(1 AS BIT), NULL),
    (N'OrganizationType', N'Bank', 20, CAST(1 AS BIT), NULL),
    (N'OrganizationType', N'NBFC', 30, CAST(1 AS BIT), NULL),
    (N'OrganizationType', N'HFC', 40, CAST(1 AS BIT), NULL),
    (N'OrganizationType', N'Insurance Company', 50, CAST(1 AS BIT), NULL),
    (N'OrganizationType', N'Asset Management Company', 60, CAST(1 AS BIT), NULL),
    (N'OrganizationType', N'Other', 70, CAST(1 AS BIT), NULL),
    (N'LegalEntityType', N'Public Limited Company', 10, CAST(1 AS BIT), NULL),
    (N'LegalEntityType', N'Private Limited Company', 20, CAST(1 AS BIT), NULL),
    (N'LegalEntityType', N'Listed Company', 30, CAST(1 AS BIT), NULL),
    (N'LegalEntityType', N'Unlisted Company', 40, CAST(1 AS BIT), NULL),
    (N'LegalEntityType', N'LLP', 50, CAST(1 AS BIT), NULL),
    (N'LegalEntityType', N'Partnership', 60, CAST(1 AS BIT), NULL),
    (N'LegalEntityType', N'Trust', 70, CAST(1 AS BIT), NULL),
    (N'LegalEntityType', N'Society', 80, CAST(1 AS BIT), NULL),
    (N'LegalEntityType', N'Other', 90, CAST(1 AS BIT), NULL),
    (N'Centralisation', N'Centralised', 10, CAST(1 AS BIT), NULL),
    (N'Centralisation', N'Decentralised', 20, CAST(1 AS BIT), NULL),
    (N'Centralisation', N'Hybrid', 30, CAST(1 AS BIT), NULL),
    (N'LegalEntityType', N'Holding / Operating Company', 909, CAST(0 AS BIT), N'Value used in the workbook sample rows (02 Legal Entities) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'LegalEntityType', N'Operating Company', 910, CAST(0 AS BIT), N'Value used in the workbook sample rows (02 Legal Entities) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'BusinessUnitType', N'Corporate', 909, CAST(0 AS BIT), N'Value used in the workbook sample rows (03 Organization Units) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'BusinessUnitType', N'Operations', 910, CAST(0 AS BIT), N'Value used in the workbook sample rows (03 Organization Units) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'BusinessUnitType', N'Control / Assurance', 911, CAST(0 AS BIT), N'Value used in the workbook sample rows (03 Organization Units) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'DepartmentType', N'Finance', 906, CAST(0 AS BIT), N'Value used in the workbook sample rows (05 Departments) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'DepartmentType', N'Corporate', 907, CAST(0 AS BIT), N'Value used in the workbook sample rows (05 Departments) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'DepartmentType', N'Control', 908, CAST(0 AS BIT), N'Value used in the workbook sample rows (05 Departments) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'PersonCategory', N'KMP', 905, CAST(0 AS BIT), N'Value used in the workbook sample rows (08 People) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'RegulatoryImpact', N'High', 904, CAST(0 AS BIT), N'Value used in the workbook sample rows (11 Business Processes) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'ProductCategory', N'Loan', 909, CAST(0 AS BIT), N'Value used in the workbook sample rows (12 Products & Services) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'ProductCategory', N'Investment', 910, CAST(0 AS BIT), N'Value used in the workbook sample rows (12 Products & Services) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'ProductCategory', N'Healthcare Service', 911, CAST(0 AS BIT), N'Value used in the workbook sample rows (12 Products & Services) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'SecuredUnsecured', N'Secured', 900, CAST(0 AS BIT), N'Value used in the workbook sample rows (12 Products & Services). 14 Field Dictionary links ''Secured / Unsecured'' to YesNo; kept as its own list. Requires data-owner approval.'),
    (N'SecuredUnsecured', N'Unsecured', 901, CAST(0 AS BIT), N'Value used in the workbook sample rows (12 Products & Services). 14 Field Dictionary links ''Secured / Unsecured'' to YesNo; kept as its own list. Requires data-owner approval.'),
    (N'SecuredUnsecured', N'Not applicable', 902, CAST(0 AS BIT), N'Value used in the workbook sample rows (12 Products & Services). 14 Field Dictionary links ''Secured / Unsecured'' to YesNo; kept as its own list. Requires data-owner approval.'),
    (N'ChannelType', N'Physical', 908, CAST(0 AS BIT), N'Value used in the workbook sample rows (13 Delivery Channels) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'ChannelType', N'Digital', 909, CAST(0 AS BIT), N'Value used in the workbook sample rows (13 Delivery Channels) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'ChannelType', N'Assisted', 910, CAST(0 AS BIT), N'Value used in the workbook sample rows (13 Delivery Channels) but not listed in 15 Masters & Codes. Requires data-owner approval.'),
    (N'ChannelType', N'Partner', 911, CAST(0 AS BIT), N'Value used in the workbook sample rows (13 Delivery Channels) but not listed in 15 Masters & Codes. Requires data-owner approval.')
) AS s(master_group, value_label, display_order, is_workbook_value, source_note)
ON t.master_group = s.master_group AND t.value_label = s.value_label
WHEN MATCHED AND (t.display_order <> s.display_order OR t.is_workbook_value <> s.is_workbook_value
                  OR ISNULL(t.source_note, N'') <> ISNULL(s.source_note, N'')) THEN
    UPDATE SET display_order = s.display_order, is_workbook_value = s.is_workbook_value,
               source_note = s.source_note, updated_by = N'seed-570', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (master_group, value_label, display_order, is_workbook_value, source_note, status, entered_by)
    VALUES (s.master_group, s.value_label, s.display_order, s.is_workbook_value, s.source_note, N'Active', N'seed-570');
PRINT CONCAT('570: controlled values merged: ', @@ROWCOUNT);
GO

-- 2a. Location types the registry needs (stored as location_type_id).
INSERT grac_practice.location_type_master (location_type_code, location_type_name, display_order, is_active, entered_by)
SELECT s.code, s.name, s.display_order, 1, N'seed-570'
  FROM (VALUES
    (N'WB_CORPORATE_OFFICE', N'Corporate Office', 200),
    (N'WB_HEAD_OFFICE', N'Head Office', 210),
    (N'WB_ZONAL_OFFICE', N'Zonal Office', 220),
    (N'WB_REGIONAL_OFFICE', N'Regional Office', 230),
    (N'WB_AREA_OFFICE', N'Area Office', 240),
    (N'WB_BRANCH', N'Branch', 250),
    (N'WB_SERVICE_CENTRE', N'Service Centre', 260),
    (N'WB_PROCESSING_CENTRE', N'Processing Centre', 270),
    (N'WB_TRAINING_CENTRE', N'Training Centre', 280),
    (N'WB_OTHER', N'Other', 290)
       ) s(code, name, display_order)
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.location_type_master x WHERE x.location_type_name = s.name)
   AND NOT EXISTS (SELECT 1 FROM grac_practice.location_type_master x WHERE x.location_type_code = s.code);
PRINT CONCAT('570: location types added: ', @@ROWCOUNT);
GO

-- 2b. Committee designations (stored as designation_id), as common
--     (organization_id NULL, is_system 1) designations.
INSERT grac_practice.committee_designation_master (designation_name, organization_id, is_system, is_active, entered_by)
SELECT s.name, NULL, 1, 1, N'seed-570'
  FROM (VALUES (N'Chairperson'), (N'Member'), (N'Permanent Invitee'), (N'Special Invitee'), (N'Secretary'), (N'Convenor'), (N'Other')) s(name)
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.committee_designation_master x WHERE x.designation_name = s.name AND x.organization_id IS NULL);
PRINT CONCAT('570: committee designations added: ', @@ROWCOUNT);
GO

-- 3. Menu. 'org-registry' first (display_order 3, before 'organizations' 5);
--    'organizations' is the Legal Entities list now.
MERGE grac_practice.menu_master AS t
USING (VALUES
    -- 'Organizations & Legal Entities' / 1 since 575 (Organization
    -- Management keeps only these two areas); kept here too so a re-run of
    -- 570 does not undo 574 / 575.
    (N'org-registry', N'Organizations & Legal Entities', N'Practice/Index/org-registry', 1, N'sitemap', N'Organization')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-570', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-570');
PRINT CONCAT('570: org-registry menu row upserted: ', @@ROWCOUNT);
GO
UPDATE c SET parent_menu_id = p.menu_id, updated_by = N'seed-570', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c JOIN grac_practice.menu_master p ON p.menu_key = N'Organization'
 WHERE c.menu_key = N'org-registry' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
UPDATE grac_practice.menu_master SET show_in_sidebar = 0, updated_by = N'seed-570', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-registry' AND show_in_sidebar = 1;
UPDATE grac_practice.menu_master SET menu_name = N'Legal Entities', updated_by = N'seed-570', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'organizations' AND menu_name <> N'Legal Entities';
PRINT CONCAT('570: organizations menu renamed Legal Entities: ', @@ROWCOUNT);
GO

-- 3b. Grants, as 511 did for Subscription Requests: every active
--     GLOBAL-scope role may VIEW, ADD and EDIT the registry (there is no
--     delete). Other roles are granted in Role Menu Permission as usual;
--     the Web tier additionally requires a GLOBAL-scope sign-in.
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.organization_role','data_scope') IS NOT NULL
    EXEC sp_executesql N'
        INSERT grac_practice.organization_role_menu_permission
            (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
             status, record_status_id, entered_by, entered_dt)
        SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 0, N''Active'',
               (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = N''Active''),
               N''seed-570'', SYSUTCDATETIME()
          FROM grac_practice.organization_role r
          JOIN grac_practice.menu_master m ON m.menu_key = N''org-registry''
         WHERE r.data_scope = N''GLOBAL'' AND r.status = N''Active''
           AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                            WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
        PRINT CONCAT(''570: GLOBAL-scope role grants inserted: '', @@ROWCOUNT);';
GO

-- 4. Legal Entities list (sp_org_organization_list, 518 body + the
--    hierarchy columns). Guarded on every column the 518 body reads.
IF COL_LENGTH('grac_practice.organization_employee','role_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_role','role_code') IS NULL
   OR COL_LENGTH('grac_practice.repository_subscription','subscription_status') IS NULL
   OR COL_LENGTH('grac_practice.organization','subscription_start_dt') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','email') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_organization_list','P') IS NULL
BEGIN
    PRINT 'ABORT (570 part 4): run 510 and 518 first. Parts 1-3 were applied.';
    SET NOEXEC ON;
END
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_org_organization_list
    @p_id          BIGINT        = 0,
    @p_status      NVARCHAR(30)  = '',
    @p_search      NVARCHAR(250) = '',
    @p_page_number INT           = 1,
    @p_page_size   INT           = 25,
    @date_from     DATE          = NULL,
    @date_to       DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @p_page_number IS NULL OR @p_page_number < 1 SET @p_page_number = 1;
    IF @p_page_size   IS NULL OR @p_page_size   < 1 SET @p_page_size   = 25;
    DECLARE @offset INT = (@p_page_number - 1) * @p_page_size;

    -- Same status handling as the monolith: the caller sends the status
    -- NAME and it is resolved to record_status_id.
    DECLARE @filter_record_status_id INT = NULL;
    IF ISNULL(@p_status, '') <> ''
        SELECT @filter_record_status_id = record_status_id
        FROM grac_practice.record_status_master
        WHERE status_name = @p_status;

    SET @p_search = ISNULL(@p_search, '');

    SELECT o.organization_id        Id,
           o.organization_code      Code,
           o.organization_name      Name,
           o.industry               Industry,
           o.entity_type            EntityType,
           o.country                Country,
           o.address_line1          AddressLine1,
           o.address_line2          AddressLine2,
           o.city                   City,
           o.state_province         StateProvince,
           o.postal_code            PostalCode,
           o.time_zone_id           TimeZoneId,
           o.subscription_start_dt  SubscriptionStartDate,
           o.subscription_end_dt    SubscriptionEndDate,
           rs.status_name           Status,
           -- 510: the organization's Admin employee -- the "Admin Full
           -- Name" supplied at onboarding. 518: read once through the
           -- OUTER APPLY below, which also yields that employee's email.
           adm.employee_name        AS SpocName,
           adm.email                AS SpocEmail,
           -- 510: up to three subscribed framework codes, then "+N more".
           -- DISTINCT on the artifact, so two releases of one framework
           -- are one entry and are counted once.
           CASE WHEN fw.total = 0 THEN N''
                ELSE ISNULL((SELECT STRING_AGG(t.artifact_code, N', ') WITHIN GROUP (ORDER BY t.artifact_code)
                               FROM (SELECT DISTINCT TOP (3) a.artifact_code
                                       FROM grac_practice.repository_subscription s
                                       JOIN grac_new.artifact a ON a.artifact_id = s.artifact_id
                                      WHERE s.organization_id = o.organization_id
                                        AND s.status = N'Active'
                                        AND ISNULL(s.subscription_status, N'Active') = N'Active'
                                      ORDER BY a.artifact_code) t), N'')
                     + CASE WHEN fw.total > 3
                            THEN N' +' + CAST(fw.total - 3 AS NVARCHAR(10)) + N' more'
                            ELSE N'' END
           END AS FrameworkSummary,
           fw.total                 AS FrameworkCount,
           -- 570: where the Legal Entity sits in the Organization Registry.
           o.registry_organization_id AS RegistryOrganizationId,
           ro.organization_code     AS RegistryOrganizationCode,
           ISNULL(ro.registered_name, N'')  AS RegistryOrganization,
           o.parent_organization_id AS ParentLegalEntityId,
           ISNULL(po.organization_name, N'') AS ParentLegalEntity,
           COUNT(*) OVER ()         AS TotalRows
    FROM grac_practice.organization o
    LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = o.registry_organization_id
    LEFT JOIN grac_practice.organization po ON po.organization_id = o.parent_organization_id
    JOIN grac_practice.record_status_master rs ON rs.record_status_id = o.record_status_id
    CROSS APPLY (
        SELECT COUNT(DISTINCT a.artifact_id) AS total
          FROM grac_practice.repository_subscription s
          JOIN grac_new.artifact a ON a.artifact_id = s.artifact_id
         WHERE s.organization_id = o.organization_id
           AND ISNULL(s.subscription_status, N'Active') = N'Active'
           AND s.status = N'Active'
    ) fw
    -- 518: the same pick 510 made inline (Active first, then ORG_ADMIN over
    -- a role merely named Admin, then the earliest) -- now one row giving
    -- both the name and the email.
    OUTER APPLY (
        SELECT TOP (1) e.employee_name, e.email
          FROM grac_practice.organization_employee e
          JOIN grac_practice.organization_role r ON r.role_id = e.role_id
         WHERE e.organization_id = o.organization_id
           AND (r.role_code = N'ORG_ADMIN' OR r.role_name = N'Admin')
         ORDER BY CASE WHEN e.status = N'Active' THEN 0 ELSE 1 END,
                  CASE WHEN r.role_code = N'ORG_ADMIN' THEN 0 ELSE 1 END,
                  e.employee_id
    ) adm
    WHERE (@p_id = 0 OR o.organization_id = @p_id)
      AND (@filter_record_status_id IS NULL OR o.record_status_id = @filter_record_status_id)
      AND (@date_from IS NULL OR o.entered_dt >= @date_from)
      AND (@date_to   IS NULL OR o.entered_dt <  DATEADD(DAY, 1, @date_to))
      AND (@p_search = ''
           OR o.organization_code LIKE '%' + @p_search + '%'
           OR o.organization_name LIKE '%' + @p_search + '%'
           OR ro.registered_name LIKE '%' + @p_search + '%')
    ORDER BY o.organization_name
    OFFSET @offset ROWS FETCH NEXT @p_page_size ROWS ONLY;
END;
GO

SET NOEXEC OFF;
GO
PRINT '--- 570 verification ---';
SELECT master_group, COUNT(*) AS [values], SUM(CASE WHEN is_workbook_value = 0 THEN 1 ELSE 0 END) AS not_in_sheet_15
  FROM grac_practice.org_registry_master_value GROUP BY master_group ORDER BY master_group;
SELECT menu_key, menu_name, status, show_in_sidebar, display_order,
       (SELECT p.menu_key FROM grac_practice.menu_master p WHERE p.menu_id = m.parent_menu_id) AS parent_key
  FROM grac_practice.menu_master m WHERE menu_key IN (N'org-registry', N'organizations', N'subscription-requests') ORDER BY display_order;
GO
PRINT '570 complete. Sign out and in again -- the menu is read at sign-in.';
GO
