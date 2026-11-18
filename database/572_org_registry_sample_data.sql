-- =====================================================================
-- 572_org_registry_sample_data.sql
--
-- Organization Registry -- loads the workbook's populated pilot rows
-- (sheets 01-13; Muthoot Finance / Lakeshore Hospital, SYNTHETIC pilot
-- examples per the workbook's START HERE disclaimer). Remarks and their
-- caveats ("illustrative", "to be confirmed", "sample data for pilot
-- only") are loaded verbatim; nothing is presented as verified.
--
-- HOW
--   * One #s_<area> table per sheet holds the workbook values as text, with
--     codes in the reference columns.
--   * Pass 1 matches or inserts every record and builds #m_<area> (workbook
--     code -> GRAC id). A record is matched by its code in its Legal Entity;
--     a Legal Entity also by its exact legal name (an existing GRAC
--     organization is ADOPTED, keeping its own code, never duplicated); a
--     location / team / committee / process also by its name in that Legal
--     Entity when the existing row has no code yet (the code is filled in).
--   * Pass 2 fills every column, references resolved through #m_<area>, and
--     ONLY WHERE THE COLUMN IS STILL EMPTY. So the first run loads the row,
--     a re-run changes nothing, and nothing anyone has edited since is ever
--     overwritten. Bridges are inserted only when missing.
--   * Inserted rows carry entered_by = 'seed-572' (the rollback deletes
--     exactly those).
--
-- WORKBOOK ISSUES handled here (also printed at the end, and listed in
-- docs/organization-registry.md):

--   * 02 Legal Entities / LE-MF-0001 / Entity Type* = 'Holding / Operating Company': Not in 15 Masters & Codes (LegalEntityType); added to the list flagged 'not approved' so the row loads as given.
--   * 02 Legal Entities / LE-LH-0001 / Entity Type* = 'Operating Company': Not in 15 Masters & Codes (LegalEntityType); added to the list flagged 'not approved' so the row loads as given.
--   * 03 Organization Units / UNIT-MF-HO / Business Unit Type = 'Corporate': Not in 15 Masters & Codes (BusinessUnitType); added to the list flagged 'not approved' so the row loads as given.
--   * 03 Organization Units / UNIT-MF-OPS / Business Unit Type = 'Operations': Not in 15 Masters & Codes (BusinessUnitType); added to the list flagged 'not approved' so the row loads as given.
--   * 03 Organization Units / UNIT-MF-CTRL / Business Unit Type = 'Control / Assurance': Not in 15 Masters & Codes (BusinessUnitType); added to the list flagged 'not approved' so the row loads as given.
--   * 05 Departments / DEPT-MF-FIN / Department Type* = 'Finance': Not in 15 Masters & Codes (DepartmentType); added to the list flagged 'not approved' so the row loads as given.
--   * 05 Departments / DEPT-MF-HR / Department Type* = 'Corporate': Not in 15 Masters & Codes (DepartmentType); added to the list flagged 'not approved' so the row loads as given.
--   * 05 Departments / DEPT-MF-IA / Department Type* = 'Control': Not in 15 Masters & Codes (DepartmentType); added to the list flagged 'not approved' so the row loads as given.
--   * 08 People / PERS-MF-CEO / Person Category* = 'KMP': Not in 15 Masters & Codes (PersonCategory); added to the list flagged 'not approved' so the row loads as given.
--   * 11 Business Processes / PROC-MF-LENDING-L1 / Regulatory Impact = 'High': Not in 15 Masters & Codes (RegulatoryImpact); added to the list flagged 'not approved' so the row loads as given.
--   * 12 Products & Services / PROD-MF-GOLD / Product Category* = 'Loan': Not in 15 Masters & Codes (ProductCategory); added to the list flagged 'not approved' so the row loads as given.
--   * 12 Products & Services / PROD-MF-NCD / Product Category* = 'Investment': Not in 15 Masters & Codes (ProductCategory); added to the list flagged 'not approved' so the row loads as given.
--   * 12 Products & Services / PROD-LH-IPD / Product Category* = 'Healthcare Service': Not in 15 Masters & Codes (ProductCategory); added to the list flagged 'not approved' so the row loads as given.
--   * 12 Products & Services / PROD-MF-GOLD / Secured / Unsecured (if applicable) = 'Secured': Not in 15 Masters & Codes (SecuredUnsecured); added to the list flagged 'not approved' so the row loads as given.
--   * 12 Products & Services / PROD-MF-BUS / Secured / Unsecured (if applicable) = 'Unsecured': Not in 15 Masters & Codes (SecuredUnsecured); added to the list flagged 'not approved' so the row loads as given.
--   * 12 Products & Services / PROD-MF-NCD / Secured / Unsecured (if applicable) = 'Not applicable': Not in 15 Masters & Codes (SecuredUnsecured); added to the list flagged 'not approved' so the row loads as given.
--   * 13 Delivery Channels / CHAN-MF-BR / Channel Type* = 'Physical': Not in 15 Masters & Codes (ChannelType); added to the list flagged 'not approved' so the row loads as given.
--   * 13 Delivery Channels / CHAN-MF-WEB / Channel Type* = 'Digital': Not in 15 Masters & Codes (ChannelType); added to the list flagged 'not approved' so the row loads as given.
--   * 13 Delivery Channels / CHAN-MF-CC / Channel Type* = 'Assisted': Not in 15 Masters & Codes (ChannelType); added to the list flagged 'not approved' so the row loads as given.
--   * 13 Delivery Channels / CHAN-LH-REF / Channel Type* = 'Partner': Not in 15 Masters & Codes (ChannelType); added to the list flagged 'not approved' so the row loads as given.
--   * 01 Organization Profile / M/s Lakeshore Hospital and Research Centre Limited / Organization Code* = 'ORG-MF-0001': Duplicate code; loaded as ORG-LH-0001 (note kept on the record).
--   * 13 Delivery Channels / CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF / Processes Supported (codes) = 'PROC-LH-BILL': No process has this code; the one code that extends it, PROC-LH-BILL-L1, was linked.
--   * 13 Delivery Channels / CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF / Processes Supported (codes) = 'PROC-LH-CLIN': No process has this code; the one code that extends it, PROC-LH-CLIN-L1, was linked.
--   * 13 Delivery Channels / CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF / Processes Supported (codes) = 'PROC-LH-IT': No process has this code; the one code that extends it, PROC-LH-IT-L1, was linked.
--   * 13 Delivery Channels / CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF / Processes Supported (codes) = 'PROC-LH-LAB': No process has this code; the one code that extends it, PROC-LH-LAB-L1, was linked.
--   * 13 Delivery Channels / CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF / Processes Supported (codes) = 'PROC-LH-PAT': No process has this code; the one code that extends it, PROC-LH-PAT-L1, was linked.
--   * 13 Delivery Channels / CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF / Processes Supported (codes) = 'PROC-LH-PHARM': No process has this code; the one code that extends it, PROC-LH-PHARM-L1, was linked.
--   * 13 Delivery Channels / CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC / Processes Supported (codes) = 'PROC-MF-COLL': No process has this code; the one code that extends it, PROC-MF-COLL-L1, was linked.
--   * 13 Delivery Channels / CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC / Processes Supported (codes) = 'PROC-MF-GOLD': No process has this code; the one code that extends it, PROC-MF-GOLD-L1, was linked.
--   * 13 Delivery Channels / CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC / Processes Supported (codes) = 'PROC-MF-IT': No process has this code; the one code that extends it, PROC-MF-IT-L1, was linked.
--   * 13 Delivery Channels / CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC / Processes Supported (codes) = 'PROC-MF-KYC': No process has this code; the one code that extends it, PROC-MF-KYC-L1, was linked.
--   * 13 Delivery Channels / CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC / Processes Supported (codes) = 'PROC-MF-LENDING': No process has this code; the one code that extends it, PROC-MF-LENDING-L1, was linked.
--   * 13 Delivery Channels / CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC / Processes Supported (codes) = 'PROC-MF-TREAS': No process has this code; the one code that extends it, PROC-MF-TREAS-L1, was linked.
--
-- Requires 569, 570 (controlled values / location types / designations).
-- Rollback: 572_org_registry_sample_data_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO
IF COL_LENGTH('grac_practice.organization','registry_organization_id') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value)
   OR NOT EXISTS (SELECT 1 FROM grac_practice.committee_designation_master WHERE designation_name = N'Chairperson' AND organization_id IS NULL)
   OR NOT EXISTS (SELECT 1 FROM grac_practice.location_type_master WHERE location_type_name = N'Head Office')
BEGIN
    PRINT 'ABORT (572): run 569 and 570 first. Nothing was changed.';
    SET NOEXEC ON;
END
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
-- Re-runnable in the same session: earlier runs' work tables go first.
DROP TABLE IF EXISTS #s_organizations;
DROP TABLE IF EXISTS #m_organizations;
DROP TABLE IF EXISTS #s_legal_entities;
DROP TABLE IF EXISTS #m_legal_entities;
DROP TABLE IF EXISTS #s_units;
DROP TABLE IF EXISTS #m_units;
DROP TABLE IF EXISTS #s_locations;
DROP TABLE IF EXISTS #m_locations;
DROP TABLE IF EXISTS #s_departments;
DROP TABLE IF EXISTS #m_departments;
DROP TABLE IF EXISTS #s_functions;
DROP TABLE IF EXISTS #m_functions;
DROP TABLE IF EXISTS #s_teams;
DROP TABLE IF EXISTS #m_teams;
DROP TABLE IF EXISTS #s_people;
DROP TABLE IF EXISTS #m_people;
DROP TABLE IF EXISTS #s_committees;
DROP TABLE IF EXISTS #m_committees;
DROP TABLE IF EXISTS #s_products;
DROP TABLE IF EXISTS #m_products;
DROP TABLE IF EXISTS #s_processes;
DROP TABLE IF EXISTS #m_processes;
DROP TABLE IF EXISTS #s_channels;
DROP TABLE IF EXISTS #m_channels;
DROP TABLE IF EXISTS #s_committee_members;
DROP TABLE IF EXISTS #m_committee_members;
BEGIN TRAN;

-- 01 Organization Profile
CREATE TABLE #s_organizations (rn INT NOT NULL, [organizationCode] NVARCHAR(MAX) NULL, [registeredName] NVARCHAR(MAX) NULL, [brandName] NVARCHAR(MAX) NULL, [organizationType] NVARCHAR(MAX) NULL, [industry] NVARCHAR(MAX) NULL, [regulatorClassification] NVARCHAR(MAX) NULL, [registrationCin] NVARCHAR(MAX) NULL, [lei] NVARCHAR(MAX) NULL, [incorporationDate] NVARCHAR(MAX) NULL, [registeredOfficeAddress] NVARCHAR(MAX) NULL, [city] NVARCHAR(MAX) NULL, [state] NVARCHAR(MAX) NULL, [country] NVARCHAR(MAX) NULL, [pinCode] NVARCHAR(MAX) NULL, [corporateWebsite] NVARCHAR(MAX) NULL, [financialYearStart] NVARCHAR(MAX) NULL, [financialYearEnd] NVARCHAR(MAX) NULL, [primaryContactRole] NVARCHAR(MAX) NULL, [primaryContactEmail] NVARCHAR(MAX) NULL, [dataCutoffDate] NVARCHAR(MAX) NULL, [recordStatus] NVARCHAR(MAX) NULL, [remarks] NVARCHAR(MAX) NULL, [dataQualityNote] NVARCHAR(MAX) NULL);
INSERT #s_organizations (rn, [organizationCode], [registeredName], [brandName], [organizationType], [industry], [regulatorClassification], [registrationCin], [lei], [incorporationDate], [registeredOfficeAddress], [city], [state], [country], [pinCode], [corporateWebsite], [financialYearStart], [financialYearEnd], [primaryContactRole], [primaryContactEmail], [dataCutoffDate], [recordStatus], [remarks], [dataQualityNote]) VALUES
    (1, N'ORG-MF-0001', N'Muthoot Finance Limited', N'Muthoot Finance', N'Company', N'Financial Services - NBFC', N'NBFC - Investment and Credit Company (illustrative classification; confirm current RBI classification)', N'L65910KL1997PLC011300', NULL, N'1997-03-14', N'Muthoot Chambers, Banerji Road', N'Kochi', N'Kerala', N'India', N'682035', N'https://www.muthootfinance.com', N'01-04', N'31-03', N'Company Secretary / Pilot Coordinator', NULL, N'2026-10-31', N'Active', N'SAMPLE DATA FOR GRAC PILOT ONLY. Validate all legal particulars, addresses, classifications and contacts with the organization.', NULL),
    (2, N'ORG-LH-0001', N'M/s Lakeshore Hospital and Research Centre Limited', N'Lakeshore Hospital', N'Company', N'Healthcare - Multi-specialty Hospital', N'Healthcare provider; regulatory registrations to be confirmed', NULL, NULL, NULL, N'Maradu, Nettoor', N'Kochi', N'Kerala', N'India', N'682040', N'https://www.vpslakeshorehospital.com', N'01-04', N'31-03', N'Company Secretary / Pilot Coordinator', NULL, N'2026-10-31', N'Active', N'SAMPLE DATA FOR GRAC PILOT ONLY. Validate all legal particulars, addresses, classifications and contacts with the organization.', N'The workbook (''01 Organization Profile'', second data row) repeats Organization Code ORG-MF-0001, already used by the first row. Loaded as ORG-LH-0001 so both rows can be stored; confirm the intended code with the data owner.');
CREATE TABLE #m_organizations (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);

-- 02 Legal Entities
CREATE TABLE #s_legal_entities (rn INT NOT NULL, [registryOrganizationId] NVARCHAR(MAX) NULL, [legalEntityCode] NVARCHAR(MAX) NULL, [legalName] NVARCHAR(MAX) NULL, [shortName] NVARCHAR(MAX) NULL, [entityType] NVARCHAR(MAX) NULL, [parentLegalEntityId] NVARCHAR(MAX) NULL, [registrationNumber] NVARCHAR(MAX) NULL, [incorporationDate] NVARCHAR(MAX) NULL, [registeredOfficeAddress] NVARCHAR(MAX) NULL, [city] NVARCHAR(MAX) NULL, [state] NVARCHAR(MAX) NULL, [country] NVARCHAR(MAX) NULL, [regulator] NVARCHAR(MAX) NULL, [regulatoryClassification] NVARCHAR(MAX) NULL, [businessActivity] NVARCHAR(MAX) NULL, [inScopeForGrac] NVARCHAR(MAX) NULL, [entityOwnerPersonId] NVARCHAR(MAX) NULL, [recordStatus] NVARCHAR(MAX) NULL, [effectiveFrom] NVARCHAR(MAX) NULL, [effectiveTo] NVARCHAR(MAX) NULL, [remarks] NVARCHAR(MAX) NULL);
INSERT #s_legal_entities (rn, [registryOrganizationId], [legalEntityCode], [legalName], [shortName], [entityType], [parentLegalEntityId], [registrationNumber], [incorporationDate], [registeredOfficeAddress], [city], [state], [country], [regulator], [regulatoryClassification], [businessActivity], [inScopeForGrac], [entityOwnerPersonId], [recordStatus], [effectiveFrom], [effectiveTo], [remarks]) VALUES
    (1, N'ORG-MF-0001', N'LE-MF-0001', N'Muthoot Finance Limited', N'MFL', N'Holding / Operating Company', NULL, N'L65910KL1997PLC011300', NULL, N'Muthoot Chambers, Banerji Road', N'Kochi', N'Kerala', N'India', N'Reserve Bank of India', N'NBFC - to be validated', N'Gold loans and other lending / financial services', N'Yes', NULL, N'Active', NULL, NULL, N'Illustrative single-entity pilot scope; group subsidiaries and associate entities excluded pending confirmation.'),
    (2, N'ORG-LH-0001', N'LE-LH-0001', N'M/s Lakeshore Hospital and Research Centre Limited', N'LHRC', N'Operating Company', NULL, NULL, NULL, N'Maradu, Nettoor', N'Kochi', N'Kerala', N'India', N'Corporate / healthcare regulators (as applicable)', N'Hospital / healthcare provider - registrations to be confirmed', N'Multi-specialty hospital and healthcare services', N'Yes', NULL, N'Active', NULL, NULL, N'Illustrative pilot entity; confirm exact registered legal name and entity structure before production loading.');
CREATE TABLE #m_legal_entities (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);

-- 03 Organization Units
CREATE TABLE #s_units (rn INT NOT NULL, [unitCode] NVARCHAR(MAX) NULL, [unitName] NVARCHAR(MAX) NULL, [unitType] NVARCHAR(MAX) NULL, [parentUnitId] NVARCHAR(MAX) NULL, [legalEntityId] NVARCHAR(MAX) NULL, [primaryLocationId] NVARCHAR(MAX) NULL, [unitHeadPersonId] NVARCHAR(MAX) NULL, [unitHeadDesignation] NVARCHAR(MAX) NULL, [businessUnitType] NVARCHAR(MAX) NULL, [stateRegion] NVARCHAR(MAX) NULL, [unitCostCentre] NVARCHAR(MAX) NULL, [isOperational] NVARCHAR(MAX) NULL, [recordStatus] NVARCHAR(MAX) NULL, [effectiveFrom] NVARCHAR(MAX) NULL, [effectiveTo] NVARCHAR(MAX) NULL, [remarks] NVARCHAR(MAX) NULL);
INSERT #s_units (rn, [unitCode], [unitName], [unitType], [parentUnitId], [legalEntityId], [primaryLocationId], [unitHeadPersonId], [unitHeadDesignation], [businessUnitType], [stateRegion], [unitCostCentre], [isOperational], [recordStatus], [effectiveFrom], [effectiveTo], [remarks]) VALUES
    (1, N'UNIT-MF-HO', N'Muthoot Finance - Head Office', N'Head Office', NULL, N'LE-MF-0001', N'LOC-MF-HO', NULL, N'Chief Executive Officer', N'Corporate', N'Kerala', NULL, N'Yes', N'Active', NULL, NULL, N'Illustrative pilot hierarchy.'),
    (2, N'UNIT-MF-OPS', N'Muthoot Finance - Operations', N'Region', N'UNIT-MF-HO', N'LE-MF-0001', N'LOC-MF-MAIN', NULL, N'Chief Operating Officer / Operations Head', N'Operations', N'Kerala', NULL, N'Yes', N'Active', NULL, NULL, NULL),
    (3, N'UNIT-MF-CTRL', N'Muthoot Finance - Corporate Control Functions', N'Corporate Office', N'UNIT-MF-HO', N'LE-MF-0001', N'LOC-MF-HO', NULL, N'Functional Heads', N'Control / Assurance', N'Kerala', NULL, N'Yes', N'Active', NULL, NULL, NULL),
    (4, N'UNIT-LH-HO', N'Lakeshore Hospital - Head Office', N'Head Office', NULL, N'LE-LH-0001', N'LOC-LH-HO', NULL, N'Chief Executive Officer', N'Corporate', N'Kerala', NULL, N'Yes', N'Active', NULL, NULL, N'Illustrative pilot hierarchy.'),
    (5, N'UNIT-LH-OPS', N'Lakeshore Hospital - Operations', N'Region', N'UNIT-LH-HO', N'LE-LH-0001', N'LOC-LH-MAIN', NULL, N'Chief Operating Officer / Operations Head', N'Operations', N'Kerala', NULL, N'Yes', N'Active', NULL, NULL, NULL),
    (6, N'UNIT-LH-CTRL', N'Lakeshore Hospital - Corporate Control Functions', N'Corporate Office', N'UNIT-LH-HO', N'LE-LH-0001', N'LOC-LH-HO', NULL, N'Functional Heads', N'Control / Assurance', N'Kerala', NULL, N'Yes', N'Active', NULL, NULL, NULL);
CREATE TABLE #m_units (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);

-- 04 Locations
CREATE TABLE #s_locations (rn INT NOT NULL, [locationCode] NVARCHAR(MAX) NULL, [locationName] NVARCHAR(MAX) NULL, [locationType] NVARCHAR(MAX) NULL, [legalEntityId] NVARCHAR(MAX) NULL, [organizationUnitId] NVARCHAR(MAX) NULL, [parentLocationId] NVARCHAR(MAX) NULL, [addressLine1] NVARCHAR(MAX) NULL, [addressLine2] NVARCHAR(MAX) NULL, [cityTown] NVARCHAR(MAX) NULL, [district] NVARCHAR(MAX) NULL, [state] NVARCHAR(MAX) NULL, [pinCode] NVARCHAR(MAX) NULL, [country] NVARCHAR(MAX) NULL, [latitude] NVARCHAR(MAX) NULL, [longitude] NVARCHAR(MAX) NULL, [regionZoneLabel] NVARCHAR(MAX) NULL, [locationHeadPersonId] NVARCHAR(MAX) NULL, [openingDate] NVARCHAR(MAX) NULL, [closureDate] NVARCHAR(MAX) NULL, [customerFacing] NVARCHAR(MAX) NULL, [operationalStatus] NVARCHAR(MAX) NULL, [remarks] NVARCHAR(MAX) NULL);
INSERT #s_locations (rn, [locationCode], [locationName], [locationType], [legalEntityId], [organizationUnitId], [parentLocationId], [addressLine1], [addressLine2], [cityTown], [district], [state], [pinCode], [country], [latitude], [longitude], [regionZoneLabel], [locationHeadPersonId], [openingDate], [closureDate], [customerFacing], [operationalStatus], [remarks]) VALUES
    (1, N'LOC-MF-HO', N'Muthoot Finance Head Office', N'Head Office', N'LE-MF-0001', N'UNIT-MF-HO', NULL, N'Muthoot Chambers, Banerji Road', NULL, N'Kochi', N'Ernakulam', N'Kerala', N'682035', N'India', NULL, NULL, N'Kerala', NULL, NULL, NULL, N'No', N'Active', N'Address is indicative; validate exact registered / operating address.'),
    (2, N'LOC-MF-MAIN', N'Muthoot Finance Main Operating Facility', N'Branch', N'LE-MF-0001', N'UNIT-MF-OPS', N'LOC-MF-HO', N'Muthoot Chambers, Banerji Road', NULL, N'Kochi', N'Ernakulam', N'Kerala', N'682035', N'India', NULL, NULL, N'Kerala', NULL, NULL, NULL, N'Yes', N'Active', N'Pilot anchor location; not a complete location inventory.'),
    (3, N'LOC-MF-SAT', N'Muthoot Finance Sample Satellite Location', N'Branch', N'LE-MF-0001', N'UNIT-MF-OPS', N'LOC-MF-MAIN', N'Sample location - address to be confirmed', NULL, N'Thrissur', N'Thrissur', N'Kerala', N'680001', N'India', NULL, NULL, N'Central Kerala', NULL, NULL, NULL, N'Yes', N'Active', N'Synthetic location for pilot relationship and hierarchy testing; not an assertion of an actual operating site.'),
    (4, N'LOC-LH-HO', N'Lakeshore Hospital Head Office', N'Head Office', N'LE-LH-0001', N'UNIT-LH-HO', NULL, N'Nettoor, Maradu', NULL, N'Kochi', N'Ernakulam', N'Kerala', N'682040', N'India', NULL, NULL, N'Kerala', NULL, NULL, NULL, N'No', N'Active', N'Address is indicative; validate exact registered / operating address.'),
    (5, N'LOC-LH-MAIN', N'Lakeshore Hospital Main Operating Facility', N'Other', N'LE-LH-0001', N'UNIT-LH-OPS', N'LOC-LH-HO', N'Nettoor, Maradu', NULL, N'Kochi', N'Ernakulam', N'Kerala', N'682040', N'India', NULL, NULL, N'Kerala', NULL, NULL, NULL, N'Yes', N'Active', N'Pilot anchor location; not a complete location inventory.'),
    (6, N'LOC-LH-SAT', N'Lakeshore Hospital Sample Satellite Location', N'Other', N'LE-LH-0001', N'UNIT-LH-OPS', N'LOC-LH-MAIN', N'Sample location - address to be confirmed', NULL, N'Thrissur', N'Thrissur', N'Kerala', N'680001', N'India', NULL, NULL, N'Central Kerala', NULL, NULL, NULL, N'Yes', N'Active', N'Synthetic location for pilot relationship and hierarchy testing; not an assertion of an actual operating site.');
CREATE TABLE #m_locations (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);

-- 05 Departments
CREATE TABLE #s_departments (rn INT NOT NULL, [departmentCode] NVARCHAR(MAX) NULL, [departmentName] NVARCHAR(MAX) NULL, [shortName] NVARCHAR(MAX) NULL, [departmentType] NVARCHAR(MAX) NULL, [parentDepartmentId] NVARCHAR(MAX) NULL, [legalEntityId] NVARCHAR(MAX) NULL, [primaryOrganizationUnitId] NVARCHAR(MAX) NULL, [departmentHeadPersonId] NVARCHAR(MAX) NULL, [departmentHeadDesignation] NVARCHAR(MAX) NULL, [primaryBusinessFunctionId] NVARCHAR(MAX) NULL, [costCentre] NVARCHAR(MAX) NULL, [centralisation] NVARCHAR(MAX) NULL, [recordStatus] NVARCHAR(MAX) NULL, [effectiveFrom] NVARCHAR(MAX) NULL, [effectiveTo] NVARCHAR(MAX) NULL, [remarks] NVARCHAR(MAX) NULL);
INSERT #s_departments (rn, [departmentCode], [departmentName], [shortName], [departmentType], [parentDepartmentId], [legalEntityId], [primaryOrganizationUnitId], [departmentHeadPersonId], [departmentHeadDesignation], [primaryBusinessFunctionId], [costCentre], [centralisation], [recordStatus], [effectiveFrom], [effectiveTo], [remarks]) VALUES
    (1, N'DEPT-MF-OPS', N'Operations', N'Operations', N'Operations', NULL, N'LE-MF-0001', N'UNIT-MF-OPS', NULL, N'Operations Head', N'FUNC-MF-OPS', N'MF-OPS-001', N'Centralised', N'Active', NULL, NULL, N'Illustrative department; confirm approved organization chart.'),
    (2, N'DEPT-MF-FIN', N'Finance & Accounts', N'Finance', N'Finance', NULL, N'LE-MF-0001', N'UNIT-MF-CTRL', NULL, N'Finance & Accounts Head', N'FUNC-MF-FIN', N'MF-FIN-001', N'Centralised', N'Active', NULL, NULL, N'Illustrative department; confirm approved organization chart.'),
    (3, N'DEPT-MF-HR', N'Human Resources', N'HR', N'Corporate', NULL, N'LE-MF-0001', N'UNIT-MF-CTRL', NULL, N'Human Resources Head', N'FUNC-MF-HR', N'MF-HR-001', N'Centralised', N'Active', NULL, NULL, N'Illustrative department; confirm approved organization chart.'),
    (4, N'DEPT-MF-IT', N'Information Technology', N'IT', N'Technology', NULL, N'LE-MF-0001', N'UNIT-MF-CTRL', NULL, N'Information Technology Head', N'FUNC-MF-IT', N'MF-IT-001', N'Centralised', N'Active', NULL, NULL, N'Illustrative department; confirm approved organization chart.'),
    (5, N'DEPT-MF-IA', N'Internal Audit', N'Internal Audit', N'Control', NULL, N'LE-MF-0001', N'UNIT-MF-CTRL', NULL, N'Internal Audit Head', N'FUNC-MF-IA', N'MF-IA-001', N'Centralised', N'Active', NULL, NULL, N'Illustrative department; confirm approved organization chart.'),
    (6, N'DEPT-LH-OPS', N'Operations', N'Operations', N'Operations', NULL, N'LE-LH-0001', N'UNIT-LH-OPS', NULL, N'Operations Head', N'FUNC-LH-OPS', N'LH-OPS-001', N'Centralised', N'Active', NULL, NULL, N'Illustrative department; confirm approved organization chart.'),
    (7, N'DEPT-LH-FIN', N'Finance & Accounts', N'Finance', N'Finance', NULL, N'LE-LH-0001', N'UNIT-LH-CTRL', NULL, N'Finance & Accounts Head', N'FUNC-LH-FIN', N'LH-FIN-001', N'Centralised', N'Active', NULL, NULL, N'Illustrative department; confirm approved organization chart.'),
    (8, N'DEPT-LH-HR', N'Human Resources', N'HR', N'Corporate', NULL, N'LE-LH-0001', N'UNIT-LH-CTRL', NULL, N'Human Resources Head', N'FUNC-LH-HR', N'LH-HR-001', N'Centralised', N'Active', NULL, NULL, N'Illustrative department; confirm approved organization chart.'),
    (9, N'DEPT-LH-IT', N'Information Technology', N'IT', N'Technology', NULL, N'LE-LH-0001', N'UNIT-LH-CTRL', NULL, N'Information Technology Head', N'FUNC-LH-IT', N'LH-IT-001', N'Centralised', N'Active', NULL, NULL, N'Illustrative department; confirm approved organization chart.'),
    (10, N'DEPT-LH-IA', N'Internal Audit', N'Internal Audit', N'Control', NULL, N'LE-LH-0001', N'UNIT-LH-CTRL', NULL, N'Internal Audit Head', N'FUNC-LH-IA', N'LH-IA-001', N'Centralised', N'Active', NULL, NULL, N'Illustrative department; confirm approved organization chart.');
CREATE TABLE #m_departments (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);

-- 06 Business Functions
CREATE TABLE #s_functions (rn INT NOT NULL, [functionCode] NVARCHAR(MAX) NULL, [functionName] NVARCHAR(MAX) NULL, [functionCategory] NVARCHAR(MAX) NULL, [parentFunctionId] NVARCHAR(MAX) NULL, [businessUnitType] NVARCHAR(MAX) NULL, [functionOwnerPersonId] NVARCHAR(MAX) NULL, [accountableDepartmentId] NVARCHAR(MAX) NULL, [executiveSponsorPersonId] NVARCHAR(MAX) NULL, [descriptionScope] NVARCHAR(MAX) NULL, [keyResponsibilities] NVARCHAR(MAX) NULL, [legalEntityId] NVARCHAR(MAX) NULL, [recordStatus] NVARCHAR(MAX) NULL, [effectiveFrom] NVARCHAR(MAX) NULL, [effectiveTo] NVARCHAR(MAX) NULL, [remarks] NVARCHAR(MAX) NULL);
INSERT #s_functions (rn, [functionCode], [functionName], [functionCategory], [parentFunctionId], [businessUnitType], [functionOwnerPersonId], [accountableDepartmentId], [executiveSponsorPersonId], [descriptionScope], [keyResponsibilities], [legalEntityId], [recordStatus], [effectiveFrom], [effectiveTo], [remarks]) VALUES
    (1, N'FUNC-MF-OPS', N'Operations', N'Operations', NULL, N'Operations', NULL, N'DEPT-MF-OPS', NULL, N'Operations function for MF pilot organization.', N'Governance, execution, monitoring and reporting within approved delegation.', N'LE-MF-0001', N'Active', NULL, NULL, N'Function-to-department mapping is illustrative.'),
    (2, N'FUNC-MF-FIN', N'Finance & Accounts', N'Support', NULL, N'Corporate', NULL, N'DEPT-MF-FIN', NULL, N'Finance & Accounts function for MF pilot organization.', N'Governance, execution, monitoring and reporting within approved delegation.', N'LE-MF-0001', N'Active', NULL, NULL, N'Function-to-department mapping is illustrative.'),
    (3, N'FUNC-MF-HR', N'Human Resources', N'Support', NULL, N'Corporate', NULL, N'DEPT-MF-HR', NULL, N'Human Resources function for MF pilot organization.', N'Governance, execution, monitoring and reporting within approved delegation.', N'LE-MF-0001', N'Active', NULL, NULL, N'Function-to-department mapping is illustrative.'),
    (4, N'FUNC-MF-IT', N'Information Technology', N'Technology', NULL, N'Corporate', NULL, N'DEPT-MF-IT', NULL, N'Information Technology function for MF pilot organization.', N'Governance, execution, monitoring and reporting within approved delegation.', N'LE-MF-0001', N'Active', NULL, NULL, N'Function-to-department mapping is illustrative.'),
    (5, N'FUNC-MF-IA', N'Internal Audit', N'Control', NULL, N'Corporate', NULL, N'DEPT-MF-IA', NULL, N'Internal Audit function for MF pilot organization.', N'Governance, execution, monitoring and reporting within approved delegation.', N'LE-MF-0001', N'Active', NULL, NULL, N'Function-to-department mapping is illustrative.'),
    (6, N'FUNC-LH-OPS', N'Operations', N'Operations', NULL, N'Operations', NULL, N'DEPT-LH-OPS', NULL, N'Operations function for LH pilot organization.', N'Governance, execution, monitoring and reporting within approved delegation.', N'LE-LH-0001', N'Active', NULL, NULL, N'Function-to-department mapping is illustrative.'),
    (7, N'FUNC-LH-FIN', N'Finance & Accounts', N'Support', NULL, N'Corporate', NULL, N'DEPT-LH-FIN', NULL, N'Finance & Accounts function for LH pilot organization.', N'Governance, execution, monitoring and reporting within approved delegation.', N'LE-LH-0001', N'Active', NULL, NULL, N'Function-to-department mapping is illustrative.'),
    (8, N'FUNC-LH-HR', N'Human Resources', N'Support', NULL, N'Corporate', NULL, N'DEPT-LH-HR', NULL, N'Human Resources function for LH pilot organization.', N'Governance, execution, monitoring and reporting within approved delegation.', N'LE-LH-0001', N'Active', NULL, NULL, N'Function-to-department mapping is illustrative.'),
    (9, N'FUNC-LH-IT', N'Information Technology', N'Technology', NULL, N'Corporate', NULL, N'DEPT-LH-IT', NULL, N'Information Technology function for LH pilot organization.', N'Governance, execution, monitoring and reporting within approved delegation.', N'LE-LH-0001', N'Active', NULL, NULL, N'Function-to-department mapping is illustrative.'),
    (10, N'FUNC-LH-IA', N'Internal Audit', N'Control', NULL, N'Corporate', NULL, N'DEPT-LH-IA', NULL, N'Internal Audit function for LH pilot organization.', N'Governance, execution, monitoring and reporting within approved delegation.', N'LE-LH-0001', N'Active', NULL, NULL, N'Function-to-department mapping is illustrative.');
CREATE TABLE #m_functions (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);

-- 07 Teams
CREATE TABLE #s_teams (rn INT NOT NULL, [teamCode] NVARCHAR(MAX) NULL, [teamName] NVARCHAR(MAX) NULL, [teamType] NVARCHAR(MAX) NULL, [legalEntityId] NVARCHAR(MAX) NULL, [parentDepartmentId] NVARCHAR(MAX) NULL, [primaryFunctionId] NVARCHAR(MAX) NULL, [organizationUnitId] NVARCHAR(MAX) NULL, [teamManagerPersonId] NVARCHAR(MAX) NULL, [teamPurpose] NVARCHAR(MAX) NULL, [recordStatus] NVARCHAR(MAX) NULL, [effectiveFrom] NVARCHAR(MAX) NULL, [effectiveTo] NVARCHAR(MAX) NULL, [remarks] NVARCHAR(MAX) NULL);
INSERT #s_teams (rn, [teamCode], [teamName], [teamType], [legalEntityId], [parentDepartmentId], [primaryFunctionId], [organizationUnitId], [teamManagerPersonId], [teamPurpose], [recordStatus], [effectiveFrom], [effectiveTo], [remarks]) VALUES
    (1, N'TEAM-MF-OPS-01', N'Operations Core Team', N'Permanent Functional Team', N'LE-MF-0001', N'DEPT-MF-OPS', N'FUNC-MF-OPS', N'UNIT-MF-OPS', NULL, N'Execute and monitor operations activities.', N'Active', NULL, NULL, N'Sample team record.'),
    (2, N'TEAM-MF-FIN-01', N'Finance & Accounts Core Team', N'Permanent Functional Team', N'LE-MF-0001', N'DEPT-MF-FIN', N'FUNC-MF-FIN', N'UNIT-MF-CTRL', NULL, N'Execute and monitor finance & accounts activities.', N'Active', NULL, NULL, N'Sample team record.'),
    (3, N'TEAM-MF-HR-01', N'Human Resources Core Team', N'Permanent Functional Team', N'LE-MF-0001', N'DEPT-MF-HR', N'FUNC-MF-HR', N'UNIT-MF-CTRL', NULL, N'Execute and monitor human resources activities.', N'Active', NULL, NULL, N'Sample team record.'),
    (4, N'TEAM-MF-IT-01', N'Information Technology Core Team', N'Permanent Functional Team', N'LE-MF-0001', N'DEPT-MF-IT', N'FUNC-MF-IT', N'UNIT-MF-CTRL', NULL, N'Execute and monitor information technology activities.', N'Active', NULL, NULL, N'Sample team record.'),
    (5, N'TEAM-MF-IA-01', N'Internal Audit Core Team', N'Permanent Functional Team', N'LE-MF-0001', N'DEPT-MF-IA', N'FUNC-MF-IA', N'UNIT-MF-CTRL', NULL, N'Execute and monitor internal audit activities.', N'Active', NULL, NULL, N'Sample team record.'),
    (6, N'TEAM-LH-OPS-01', N'Operations Core Team', N'Permanent Functional Team', N'LE-LH-0001', N'DEPT-LH-OPS', N'FUNC-LH-OPS', N'UNIT-LH-OPS', NULL, N'Execute and monitor operations activities.', N'Active', NULL, NULL, N'Sample team record.'),
    (7, N'TEAM-LH-FIN-01', N'Finance & Accounts Core Team', N'Permanent Functional Team', N'LE-LH-0001', N'DEPT-LH-FIN', N'FUNC-LH-FIN', N'UNIT-LH-CTRL', NULL, N'Execute and monitor finance & accounts activities.', N'Active', NULL, NULL, N'Sample team record.'),
    (8, N'TEAM-LH-HR-01', N'Human Resources Core Team', N'Permanent Functional Team', N'LE-LH-0001', N'DEPT-LH-HR', N'FUNC-LH-HR', N'UNIT-LH-CTRL', NULL, N'Execute and monitor human resources activities.', N'Active', NULL, NULL, N'Sample team record.'),
    (9, N'TEAM-LH-IT-01', N'Information Technology Core Team', N'Permanent Functional Team', N'LE-LH-0001', N'DEPT-LH-IT', N'FUNC-LH-IT', N'UNIT-LH-CTRL', NULL, N'Execute and monitor information technology activities.', N'Active', NULL, NULL, N'Sample team record.'),
    (10, N'TEAM-LH-IA-01', N'Internal Audit Core Team', N'Permanent Functional Team', N'LE-LH-0001', N'DEPT-LH-IA', N'FUNC-LH-IA', N'UNIT-LH-CTRL', NULL, N'Execute and monitor internal audit activities.', N'Active', NULL, NULL, N'Sample team record.');
CREATE TABLE #m_teams (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);

-- 08 People
CREATE TABLE #s_people (rn INT NOT NULL, [personCode] NVARCHAR(MAX) NULL, [fullName] NVARCHAR(MAX) NULL, [personCategory] NVARCHAR(MAX) NULL, [employmentType] NVARCHAR(MAX) NULL, [referenceNo] NVARCHAR(MAX) NULL, [officialEmail] NVARCHAR(MAX) NULL, [officialPhone] NVARCHAR(MAX) NULL, [designation] NVARCHAR(MAX) NULL, [roleName] NVARCHAR(MAX) NULL, [legalEntityId] NVARCHAR(MAX) NULL, [departmentId] NVARCHAR(MAX) NULL, [primaryFunctionId] NVARCHAR(MAX) NULL, [primaryTeamId] NVARCHAR(MAX) NULL, [organizationUnitId] NVARCHAR(MAX) NULL, [primaryLocationId] NVARCHAR(MAX) NULL, [reportsToPersonId] NVARCHAR(MAX) NULL, [functionalReportsToPersonId] NVARCHAR(MAX) NULL, [joiningDate] NVARCHAR(MAX) NULL, [exitDate] NVARCHAR(MAX) NULL, [personStatus] NVARCHAR(MAX) NULL, [isKmp] NVARCHAR(MAX) NULL, [recordStatus] NVARCHAR(MAX) NULL, [remarks] NVARCHAR(MAX) NULL);
INSERT #s_people (rn, [personCode], [fullName], [personCategory], [employmentType], [referenceNo], [officialEmail], [officialPhone], [designation], [roleName], [legalEntityId], [departmentId], [primaryFunctionId], [primaryTeamId], [organizationUnitId], [primaryLocationId], [reportsToPersonId], [functionalReportsToPersonId], [joiningDate], [exitDate], [personStatus], [isKmp], [recordStatus], [remarks]) VALUES
    (1, N'PERS-MF-CEO', N'Sample MF Chief Executive Officer', N'KMP', N'Permanent', N'SYN-MF-001', N'ceo.mf@example.com', NULL, N'Chief Executive Officer', N'Executive leadership', N'LE-MF-0001', N'DEPT-MF-FIN', N'FUNC-MF-FIN', N'TEAM-MF-FIN-01', N'UNIT-MF-HO', N'LOC-MF-HO', NULL, NULL, N'2024-04-01', NULL, N'Active', N'Yes', N'Active', N'Fictional role-holder and contact for pilot testing only; replace with approved official work details.'),
    (2, N'PERS-MF-OPS', N'Sample MF Chief Operating Officer', N'Officer', N'Permanent', N'SYN-MF-002', N'ops.mf@example.com', NULL, N'Chief Operating Officer', N'Operations leadership', N'LE-MF-0001', N'DEPT-MF-OPS', N'FUNC-MF-OPS', N'TEAM-MF-OPS-01', N'UNIT-MF-OPS', N'LOC-MF-HO', N'PERS-MF-CEO', NULL, N'2024-04-01', NULL, N'Active', N'No', N'Active', N'Fictional role-holder and contact for pilot testing only; replace with approved official work details.'),
    (3, N'PERS-MF-CFO', N'Sample MF Chief Financial Officer', N'KMP', N'Permanent', N'SYN-MF-003', N'cfo.mf@example.com', NULL, N'Chief Financial Officer', N'Finance leadership', N'LE-MF-0001', N'DEPT-MF-FIN', N'FUNC-MF-FIN', N'TEAM-MF-FIN-01', N'UNIT-MF-CTRL', N'LOC-MF-HO', N'PERS-MF-CEO', NULL, N'2024-04-01', NULL, N'Active', N'Yes', N'Active', N'Fictional role-holder and contact for pilot testing only; replace with approved official work details.'),
    (4, N'PERS-MF-CIO', N'Sample MF Chief Information Officer', N'Officer', N'Permanent', N'SYN-MF-004', N'cio.mf@example.com', NULL, N'Chief Information Officer', N'Technology leadership', N'LE-MF-0001', N'DEPT-MF-IT', N'FUNC-MF-IT', N'TEAM-MF-IT-01', N'UNIT-MF-CTRL', N'LOC-MF-HO', N'PERS-MF-CEO', NULL, N'2024-04-01', NULL, N'Active', N'No', N'Active', N'Fictional role-holder and contact for pilot testing only; replace with approved official work details.'),
    (5, N'PERS-MF-IAH', N'Sample MF Head - Internal Audit', N'Officer', N'Permanent', N'SYN-MF-005', N'iah.mf@example.com', NULL, N'Head - Internal Audit', N'Internal audit leadership', N'LE-MF-0001', N'DEPT-MF-IA', N'FUNC-MF-IA', N'TEAM-MF-IA-01', N'UNIT-MF-CTRL', N'LOC-MF-HO', N'PERS-MF-CEO', NULL, N'2024-04-01', NULL, N'Active', N'No', N'Active', N'Fictional role-holder and contact for pilot testing only; replace with approved official work details.'),
    (6, N'PERS-MF-HRH', N'Sample MF Head - Human Resources', N'Officer', N'Permanent', N'SYN-MF-006', N'hrh.mf@example.com', NULL, N'Head - Human Resources', N'HR leadership', N'LE-MF-0001', N'DEPT-MF-HR', N'FUNC-MF-HR', N'TEAM-MF-HR-01', N'UNIT-MF-CTRL', N'LOC-MF-HO', N'PERS-MF-CEO', NULL, N'2024-04-01', NULL, N'Active', N'No', N'Active', N'Fictional role-holder and contact for pilot testing only; replace with approved official work details.'),
    (7, N'PERS-LH-CEO', N'Sample LH Chief Executive Officer', N'KMP', N'Permanent', N'SYN-LH-001', N'ceo.lh@example.com', NULL, N'Chief Executive Officer', N'Executive leadership', N'LE-LH-0001', N'DEPT-LH-FIN', N'FUNC-LH-FIN', N'TEAM-LH-FIN-01', N'UNIT-LH-HO', N'LOC-LH-HO', NULL, NULL, N'2024-04-01', NULL, N'Active', N'Yes', N'Active', N'Fictional role-holder and contact for pilot testing only; replace with approved official work details.'),
    (8, N'PERS-LH-OPS', N'Sample LH Chief Operating Officer', N'Officer', N'Permanent', N'SYN-LH-002', N'ops.lh@example.com', NULL, N'Chief Operating Officer', N'Operations leadership', N'LE-LH-0001', N'DEPT-LH-OPS', N'FUNC-LH-OPS', N'TEAM-LH-OPS-01', N'UNIT-LH-OPS', N'LOC-LH-HO', N'PERS-LH-CEO', NULL, N'2024-04-01', NULL, N'Active', N'No', N'Active', N'Fictional role-holder and contact for pilot testing only; replace with approved official work details.'),
    (9, N'PERS-LH-CFO', N'Sample LH Chief Financial Officer', N'KMP', N'Permanent', N'SYN-LH-003', N'cfo.lh@example.com', NULL, N'Chief Financial Officer', N'Finance leadership', N'LE-LH-0001', N'DEPT-LH-FIN', N'FUNC-LH-FIN', N'TEAM-LH-FIN-01', N'UNIT-LH-CTRL', N'LOC-LH-HO', N'PERS-LH-CEO', NULL, N'2024-04-01', NULL, N'Active', N'Yes', N'Active', N'Fictional role-holder and contact for pilot testing only; replace with approved official work details.'),
    (10, N'PERS-LH-CIO', N'Sample LH Chief Information Officer', N'Officer', N'Permanent', N'SYN-LH-004', N'cio.lh@example.com', NULL, N'Chief Information Officer', N'Technology leadership', N'LE-LH-0001', N'DEPT-LH-IT', N'FUNC-LH-IT', N'TEAM-LH-IT-01', N'UNIT-LH-CTRL', N'LOC-LH-HO', N'PERS-LH-CEO', NULL, N'2024-04-01', NULL, N'Active', N'No', N'Active', N'Fictional role-holder and contact for pilot testing only; replace with approved official work details.'),
    (11, N'PERS-LH-IAH', N'Sample LH Head - Internal Audit', N'Officer', N'Permanent', N'SYN-LH-005', N'iah.lh@example.com', NULL, N'Head - Internal Audit', N'Internal audit leadership', N'LE-LH-0001', N'DEPT-LH-IA', N'FUNC-LH-IA', N'TEAM-LH-IA-01', N'UNIT-LH-CTRL', N'LOC-LH-HO', N'PERS-LH-CEO', NULL, N'2024-04-01', NULL, N'Active', N'No', N'Active', N'Fictional role-holder and contact for pilot testing only; replace with approved official work details.'),
    (12, N'PERS-LH-HRH', N'Sample LH Head - Human Resources', N'Officer', N'Permanent', N'SYN-LH-006', N'hrh.lh@example.com', NULL, N'Head - Human Resources', N'HR leadership', N'LE-LH-0001', N'DEPT-LH-HR', N'FUNC-LH-HR', N'TEAM-LH-HR-01', N'UNIT-LH-CTRL', N'LOC-LH-HO', N'PERS-LH-CEO', NULL, N'2024-04-01', NULL, N'Active', N'No', N'Active', N'Fictional role-holder and contact for pilot testing only; replace with approved official work details.');
CREATE TABLE #m_people (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);

-- 09 Committees
CREATE TABLE #s_committees (rn INT NOT NULL, [committeeCode] NVARCHAR(MAX) NULL, [committeeName] NVARCHAR(MAX) NULL, [committeeType] NVARCHAR(MAX) NULL, [legalEntityId] NVARCHAR(MAX) NULL, [committeeMandate] NVARCHAR(MAX) NULL, [scopeResponsibilities] NVARCHAR(MAX) NULL, [chairpersonPersonId] NVARCHAR(MAX) NULL, [secretaryPersonId] NVARCHAR(MAX) NULL, [reviewFrequency] NVARCHAR(MAX) NULL, [torReference] NVARCHAR(MAX) NULL, [constitutedDate] NVARCHAR(MAX) NULL, [lastReviewedDate] NVARCHAR(MAX) NULL, [nextReviewDueDate] NVARCHAR(MAX) NULL, [recordStatus] NVARCHAR(MAX) NULL, [effectiveFrom] NVARCHAR(MAX) NULL, [effectiveTo] NVARCHAR(MAX) NULL, [remarks] NVARCHAR(MAX) NULL);
INSERT #s_committees (rn, [committeeCode], [committeeName], [committeeType], [legalEntityId], [committeeMandate], [scopeResponsibilities], [chairpersonPersonId], [secretaryPersonId], [reviewFrequency], [torReference], [constitutedDate], [lastReviewedDate], [nextReviewDueDate], [recordStatus], [effectiveFrom], [effectiveTo], [remarks]) VALUES
    (1, N'COMM-MF-AC', N'Audit Committee', N'Board Committee', N'LE-MF-0001', N'Oversight of financial reporting, internal controls and audit assurance.', N'Oversight of financial reporting, internal controls and audit assurance.', N'PERS-MF-CEO', N'PERS-MF-IAH', N'Quarterly', N'SAMPLE-TOR-MF-AC', N'2024-04-01', N'2026-09-30', N'2026-12-31', N'Active', NULL, NULL, N'Committee names and mandates are sample structures; confirm actual constitution and statutory status.'),
    (2, N'COMM-MF-RMC', N'Risk Management Committee', N'Management Committee', N'LE-MF-0001', N'Oversight of enterprise risks and risk mitigation.', N'Oversight of enterprise risks and risk mitigation.', N'PERS-MF-CEO', N'PERS-MF-IAH', N'Quarterly', N'SAMPLE-TOR-MF-RMC', N'2024-04-01', N'2026-09-30', N'2026-12-31', N'Active', NULL, NULL, N'Committee names and mandates are sample structures; confirm actual constitution and statutory status.'),
    (3, N'COMM-MF-ITC', N'IT Steering Committee', N'Operational Committee', N'LE-MF-0001', N'Technology strategy, cyber risk, IT projects and service performance.', N'Technology strategy, cyber risk, IT projects and service performance.', N'PERS-MF-CEO', N'PERS-MF-IAH', N'Quarterly', N'SAMPLE-TOR-MF-ITC', N'2024-04-01', N'2026-09-30', N'2026-12-31', N'Active', NULL, NULL, N'Committee names and mandates are sample structures; confirm actual constitution and statutory status.'),
    (4, N'COMM-LH-AC', N'Audit Committee', N'Board Committee', N'LE-LH-0001', N'Oversight of financial reporting, internal controls and audit assurance.', N'Oversight of financial reporting, internal controls and audit assurance.', N'PERS-LH-CEO', N'PERS-LH-IAH', N'Quarterly', N'SAMPLE-TOR-LH-AC', N'2024-04-01', N'2026-09-30', N'2026-12-31', N'Active', NULL, NULL, N'Committee names and mandates are sample structures; confirm actual constitution and statutory status.'),
    (5, N'COMM-LH-RMC', N'Risk Management Committee', N'Management Committee', N'LE-LH-0001', N'Oversight of enterprise risks and risk mitigation.', N'Oversight of enterprise risks and risk mitigation.', N'PERS-LH-CEO', N'PERS-LH-IAH', N'Quarterly', N'SAMPLE-TOR-LH-RMC', N'2024-04-01', N'2026-09-30', N'2026-12-31', N'Active', NULL, NULL, N'Committee names and mandates are sample structures; confirm actual constitution and statutory status.'),
    (6, N'COMM-LH-ITC', N'IT Steering Committee', N'Operational Committee', N'LE-LH-0001', N'Technology strategy, cyber risk, IT projects and service performance.', N'Technology strategy, cyber risk, IT projects and service performance.', N'PERS-LH-CEO', N'PERS-LH-IAH', N'Quarterly', N'SAMPLE-TOR-LH-ITC', N'2024-04-01', N'2026-09-30', N'2026-12-31', N'Active', NULL, NULL, N'Committee names and mandates are sample structures; confirm actual constitution and statutory status.');
CREATE TABLE #m_committees (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);

-- 12 Products & Services
CREATE TABLE #s_products (rn INT NOT NULL, [productCode] NVARCHAR(MAX) NULL, [productName] NVARCHAR(MAX) NULL, [productCategory] NVARCHAR(MAX) NULL, [schemeVariant] NVARCHAR(MAX) NULL, [description] NVARCHAR(MAX) NULL, [owningFunctionId] NVARCHAR(MAX) NULL, [owningDepartmentId] NVARCHAR(MAX) NULL, [productOwnerPersonId] NVARCHAR(MAX) NULL, [legalEntityId] NVARCHAR(MAX) NULL, [customerSegment] NVARCHAR(MAX) NULL, [securedUnsecured] NVARCHAR(MAX) NULL, [regulatoryClassification] NVARCHAR(MAX) NULL, [launchDate] NVARCHAR(MAX) NULL, [withdrawalDate] NVARCHAR(MAX) NULL, [productStatus] NVARCHAR(MAX) NULL, [remarks] NVARCHAR(MAX) NULL);
INSERT #s_products (rn, [productCode], [productName], [productCategory], [schemeVariant], [description], [owningFunctionId], [owningDepartmentId], [productOwnerPersonId], [legalEntityId], [customerSegment], [securedUnsecured], [regulatoryClassification], [launchDate], [withdrawalDate], [productStatus], [remarks]) VALUES
    (1, N'PROD-MF-GOLD', N'Gold Loan', N'Loan', NULL, N'Gold-backed lending product', N'FUNC-MF-OPS', N'DEPT-MF-OPS', NULL, N'LE-MF-0001', N'Retail / individual customers', N'Secured', N'To be validated against applicable regulatory requirements', NULL, NULL, N'Active', N'Sample product/service record; verify official product catalogue and service nomenclature.'),
    (2, N'PROD-MF-VEH', N'Vehicle Loan', N'Loan', NULL, N'Vehicle finance product', N'FUNC-MF-OPS', N'DEPT-MF-OPS', NULL, N'LE-MF-0001', N'Retail / individual customers', N'Secured', N'To be validated against applicable regulatory requirements', NULL, NULL, N'Active', N'Sample product/service record; verify official product catalogue and service nomenclature.'),
    (3, N'PROD-MF-BUS', N'Business Loan', N'Loan', NULL, N'Small business lending product', N'FUNC-MF-OPS', N'DEPT-MF-OPS', NULL, N'LE-MF-0001', N'Retail / individual customers', N'Unsecured', N'To be validated against applicable regulatory requirements', NULL, NULL, N'Active', N'Sample product/service record; verify official product catalogue and service nomenclature.'),
    (4, N'PROD-MF-NCD', N'Non-Convertible Debentures', N'Investment', NULL, N'Debt securities / investment product', N'FUNC-MF-FIN', N'DEPT-MF-FIN', NULL, N'LE-MF-0001', N'Retail / individual customers', N'Not applicable', N'To be validated against applicable regulatory requirements', NULL, NULL, N'Active', N'Sample product/service record; verify official product catalogue and service nomenclature.'),
    (5, N'PROD-LH-IPD', N'Inpatient Services', N'Healthcare Service', NULL, N'Inpatient diagnosis, treatment and care', N'FUNC-LH-OPS', N'DEPT-LH-OPS', NULL, N'LE-LH-0001', N'Patients / corporate clients', N'Not applicable', N'To be validated against applicable regulatory requirements', NULL, NULL, N'Active', N'Sample product/service record; verify official product catalogue and service nomenclature.'),
    (6, N'PROD-LH-OPD', N'Outpatient Services', N'Healthcare Service', NULL, N'Consultation and outpatient treatment', N'FUNC-LH-OPS', N'DEPT-LH-OPS', NULL, N'LE-LH-0001', N'Patients / corporate clients', N'Not applicable', N'To be validated against applicable regulatory requirements', NULL, NULL, N'Active', N'Sample product/service record; verify official product catalogue and service nomenclature.'),
    (7, N'PROD-LH-EMG', N'Emergency Services', N'Healthcare Service', NULL, N'Emergency assessment and treatment', N'FUNC-LH-OPS', N'DEPT-LH-OPS', NULL, N'LE-LH-0001', N'Patients / corporate clients', N'Not applicable', N'To be validated against applicable regulatory requirements', NULL, NULL, N'Active', N'Sample product/service record; verify official product catalogue and service nomenclature.'),
    (8, N'PROD-LH-DIAG', N'Diagnostics & Imaging', N'Healthcare Service', NULL, N'Laboratory and imaging services', N'FUNC-LH-OPS', N'DEPT-LH-OPS', NULL, N'LE-LH-0001', N'Patients / corporate clients', N'Not applicable', N'To be validated against applicable regulatory requirements', NULL, NULL, N'Active', N'Sample product/service record; verify official product catalogue and service nomenclature.');
CREATE TABLE #m_products (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);

-- 11 Business Processes
CREATE TABLE #s_processes (rn INT NOT NULL, [processCode] NVARCHAR(MAX) NULL, [processName] NVARCHAR(MAX) NULL, [processLevel] NVARCHAR(MAX) NULL, [parentProcessId] NVARCHAR(MAX) NULL, [processNature] NVARCHAR(MAX) NULL, [businessFunctionId] NVARCHAR(MAX) NULL, [owningDepartmentId] NVARCHAR(MAX) NULL, [processOwnerPersonId] NVARCHAR(MAX) NULL, [accountableExecutivePersonId] NVARCHAR(MAX) NULL, [descriptionObjective] NVARCHAR(MAX) NULL, [keyActivities] NVARCHAR(MAX) NULL, [primaryProductId] NVARCHAR(MAX) NULL, [primaryChannelId] NVARCHAR(MAX) NULL, [legalEntityId] NVARCHAR(MAX) NULL, [primaryOrganizationUnitId] NVARCHAR(MAX) NULL, [locationScope] NVARCHAR(MAX) NULL, [processFrequency] NVARCHAR(MAX) NULL, [annualVolume] NVARCHAR(MAX) NULL, [customerImpact] NVARCHAR(MAX) NULL, [regulatoryImpact] NVARCHAR(MAX) NULL, [regulatoryReferences] NVARCHAR(MAX) NULL, [recordStatus] NVARCHAR(MAX) NULL, [effectiveFrom] NVARCHAR(MAX) NULL, [effectiveTo] NVARCHAR(MAX) NULL, [remarks] NVARCHAR(MAX) NULL);
INSERT #s_processes (rn, [processCode], [processName], [processLevel], [parentProcessId], [processNature], [businessFunctionId], [owningDepartmentId], [processOwnerPersonId], [accountableExecutivePersonId], [descriptionObjective], [keyActivities], [primaryProductId], [primaryChannelId], [legalEntityId], [primaryOrganizationUnitId], [locationScope], [processFrequency], [annualVolume], [customerImpact], [regulatoryImpact], [regulatoryReferences], [recordStatus], [effectiveFrom], [effectiveTo], [remarks]) VALUES
    (1, N'PROC-MF-LENDING-L1', N'Lending Operations', N'L1', NULL, N'Core', N'FUNC-MF-OPS', N'DEPT-MF-OPS', N'PERS-MF-OPS', N'PERS-MF-CEO', N'Origination, appraisal, sanction and disbursement', N'Origination, appraisal, sanction and disbursement', NULL, NULL, N'LE-MF-0001', N'UNIT-MF-OPS', N'All in-scope locations', N'Daily', NULL, N'Yes', N'High', NULL, N'Active', NULL, NULL, N'Illustrative L1 process; child L2 records can be added during process owner workshops.'),
    (2, N'PROC-MF-GOLD-L1', N'Gold Loan Operations', N'L1', NULL, N'Core', N'FUNC-MF-OPS', N'DEPT-MF-OPS', N'PERS-MF-OPS', N'PERS-MF-CEO', N'Gold receipt, valuation, custody and release', N'Gold receipt, valuation, custody and release', NULL, NULL, N'LE-MF-0001', N'UNIT-MF-OPS', N'All in-scope locations', N'Daily', NULL, N'Yes', N'High', NULL, N'Active', NULL, NULL, N'Illustrative L1 process; child L2 records can be added during process owner workshops.'),
    (3, N'PROC-MF-COLL-L1', N'Collections', N'L1', NULL, N'Core', N'FUNC-MF-OPS', N'DEPT-MF-OPS', N'PERS-MF-OPS', N'PERS-MF-CEO', N'Repayment follow-up, overdue management and recovery', N'Repayment follow-up, overdue management and recovery', NULL, NULL, N'LE-MF-0001', N'UNIT-MF-OPS', N'All in-scope locations', N'Daily', NULL, N'Yes', N'High', NULL, N'Active', NULL, NULL, N'Illustrative L1 process; child L2 records can be added during process owner workshops.'),
    (4, N'PROC-MF-KYC-L1', N'Customer Onboarding & KYC', N'L1', NULL, N'Core', N'FUNC-MF-OPS', N'DEPT-MF-OPS', N'PERS-MF-OPS', N'PERS-MF-CEO', N'Customer identification, due diligence and record maintenance', N'Customer identification, due diligence and record maintenance', NULL, NULL, N'LE-MF-0001', N'UNIT-MF-OPS', N'All in-scope locations', N'Daily', NULL, N'Yes', N'High', NULL, N'Active', NULL, NULL, N'Illustrative L1 process; child L2 records can be added during process owner workshops.'),
    (5, N'PROC-MF-TREAS-L1', N'Treasury & Investments', N'L1', NULL, N'Core', N'FUNC-MF-FIN', N'DEPT-MF-FIN', N'PERS-MF-OPS', N'PERS-MF-CEO', N'Liquidity, investments and funding', N'Liquidity, investments and funding', NULL, NULL, N'LE-MF-0001', N'UNIT-MF-OPS', N'All in-scope locations', N'Daily', NULL, N'Yes', N'High', NULL, N'Active', NULL, NULL, N'Illustrative L1 process; child L2 records can be added during process owner workshops.'),
    (6, N'PROC-MF-IT-L1', N'IT Service Management', N'L1', NULL, N'Support', N'FUNC-MF-OPS', N'DEPT-MF-OPS', N'PERS-MF-OPS', N'PERS-MF-CEO', N'IT operations, access, change and incident management', N'IT operations, access, change and incident management', NULL, NULL, N'LE-MF-0001', N'UNIT-MF-OPS', N'All in-scope locations', N'Daily', NULL, N'Yes', N'High', NULL, N'Active', NULL, NULL, N'Illustrative L1 process; child L2 records can be added during process owner workshops.'),
    (7, N'PROC-LH-PAT-L1', N'Patient Registration & Admission', N'L1', NULL, N'Core', N'FUNC-LH-OPS', N'DEPT-LH-OPS', N'PERS-LH-OPS', N'PERS-LH-CEO', N'Registration, identity checks, admission and discharge', N'Registration, identity checks, admission and discharge', NULL, NULL, N'LE-LH-0001', N'UNIT-LH-OPS', N'All in-scope locations', N'Daily', NULL, N'Yes', N'High', NULL, N'Active', NULL, NULL, N'Illustrative L1 process; child L2 records can be added during process owner workshops.'),
    (8, N'PROC-LH-CLIN-L1', N'Clinical Care', N'L1', NULL, N'Core', N'FUNC-LH-OPS', N'DEPT-LH-OPS', N'PERS-LH-OPS', N'PERS-LH-CEO', N'Assessment, diagnosis, treatment, nursing and clinical documentation', N'Assessment, diagnosis, treatment, nursing and clinical documentation', NULL, NULL, N'LE-LH-0001', N'UNIT-LH-OPS', N'All in-scope locations', N'Daily', NULL, N'Yes', N'High', NULL, N'Active', NULL, NULL, N'Illustrative L1 process; child L2 records can be added during process owner workshops.'),
    (9, N'PROC-LH-PHARM-L1', N'Pharmacy Services', N'L1', NULL, N'Core', N'FUNC-LH-OPS', N'DEPT-LH-OPS', N'PERS-LH-OPS', N'PERS-LH-CEO', N'Prescription validation, dispensing and stock control', N'Prescription validation, dispensing and stock control', NULL, NULL, N'LE-LH-0001', N'UNIT-LH-OPS', N'All in-scope locations', N'Daily', NULL, N'Yes', N'High', NULL, N'Active', NULL, NULL, N'Illustrative L1 process; child L2 records can be added during process owner workshops.'),
    (10, N'PROC-LH-LAB-L1', N'Laboratory & Diagnostics', N'L1', NULL, N'Core', N'FUNC-LH-OPS', N'DEPT-LH-OPS', N'PERS-LH-OPS', N'PERS-LH-CEO', N'Sample collection, testing, validation and result reporting', N'Sample collection, testing, validation and result reporting', NULL, NULL, N'LE-LH-0001', N'UNIT-LH-OPS', N'All in-scope locations', N'Daily', NULL, N'Yes', N'High', NULL, N'Active', NULL, NULL, N'Illustrative L1 process; child L2 records can be added during process owner workshops.'),
    (11, N'PROC-LH-BILL-L1', N'Billing & Revenue Cycle', N'L1', NULL, N'Core', N'FUNC-LH-OPS', N'DEPT-LH-OPS', N'PERS-LH-OPS', N'PERS-LH-CEO', N'Charge capture, billing, insurance and collections', N'Charge capture, billing, insurance and collections', NULL, NULL, N'LE-LH-0001', N'UNIT-LH-OPS', N'All in-scope locations', N'Daily', NULL, N'Yes', N'High', NULL, N'Active', NULL, NULL, N'Illustrative L1 process; child L2 records can be added during process owner workshops.'),
    (12, N'PROC-LH-IT-L1', N'IT Service Management', N'L1', NULL, N'Support', N'FUNC-LH-OPS', N'DEPT-LH-OPS', N'PERS-LH-OPS', N'PERS-LH-CEO', N'IT operations, access, change and incident management', N'IT operations, access, change and incident management', NULL, NULL, N'LE-LH-0001', N'UNIT-LH-OPS', N'All in-scope locations', N'Daily', NULL, N'Yes', N'High', NULL, N'Active', NULL, NULL, N'Illustrative L1 process; child L2 records can be added during process owner workshops.');
CREATE TABLE #m_processes (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);

-- 13 Delivery Channels
CREATE TABLE #s_channels (rn INT NOT NULL, [channelCode] NVARCHAR(MAX) NULL, [channelName] NVARCHAR(MAX) NULL, [channelType] NVARCHAR(MAX) NULL, [description] NVARCHAR(MAX) NULL, [owningFunctionId] NVARCHAR(MAX) NULL, [channelOwnerPersonId] NVARCHAR(MAX) NULL, [legalEntityId] NVARCHAR(MAX) NULL, [primaryOrganizationUnitId] NVARCHAR(MAX) NULL, [customerFacing] NVARCHAR(MAX) NULL, [operationalHours] NVARCHAR(MAX) NULL, [geographicScope] NVARCHAR(MAX) NULL, [channelStatus] NVARCHAR(MAX) NULL, [remarks] NVARCHAR(MAX) NULL);
INSERT #s_channels (rn, [channelCode], [channelName], [channelType], [description], [owningFunctionId], [channelOwnerPersonId], [legalEntityId], [primaryOrganizationUnitId], [customerFacing], [operationalHours], [geographicScope], [channelStatus], [remarks]) VALUES
    (1, N'CHAN-MF-BR', N'Branch Network', N'Physical', N'Customer servicing and loan origination at branches.', N'FUNC-MF-OPS', NULL, N'LE-MF-0001', N'UNIT-MF-OPS', N'Yes', N'As per approved operating schedule - confirm', N'India', N'Active', N'Illustrative channel; validate availability and actual channel ownership.'),
    (2, N'CHAN-MF-WEB', N'Website', N'Digital', N'Corporate information and digital customer access.', N'FUNC-MF-OPS', NULL, N'LE-MF-0001', N'UNIT-MF-OPS', N'Yes', N'As per approved operating schedule - confirm', N'India', N'Active', N'Illustrative channel; validate availability and actual channel ownership.'),
    (3, N'CHAN-MF-MOB', N'Mobile Application', N'Digital', N'Mobile customer servicing channel.', N'FUNC-MF-OPS', NULL, N'LE-MF-0001', N'UNIT-MF-OPS', N'Yes', N'As per approved operating schedule - confirm', N'India', N'Active', N'Illustrative channel; validate availability and actual channel ownership.'),
    (4, N'CHAN-MF-CC', N'Customer Contact Centre', N'Assisted', N'Customer enquiries and service requests.', N'FUNC-MF-OPS', NULL, N'LE-MF-0001', N'UNIT-MF-OPS', N'Yes', N'As per approved operating schedule - confirm', N'India', N'Active', N'Illustrative channel; validate availability and actual channel ownership.'),
    (5, N'CHAN-LH-HOSP', N'Hospital Facility', N'Physical', N'In-person care at hospital facility.', N'FUNC-LH-OPS', NULL, N'LE-LH-0001', N'UNIT-LH-OPS', N'Yes', N'As per approved operating schedule - confirm', N'Kerala / as applicable', N'Active', N'Illustrative channel; validate availability and actual channel ownership.'),
    (6, N'CHAN-LH-WEB', N'Website / Appointment Portal', N'Digital', N'Online information and appointment requests.', N'FUNC-LH-OPS', NULL, N'LE-LH-0001', N'UNIT-LH-OPS', N'Yes', N'As per approved operating schedule - confirm', N'Kerala / as applicable', N'Active', N'Illustrative channel; validate availability and actual channel ownership.'),
    (7, N'CHAN-LH-CALL', N'Telephone / Contact Centre', N'Assisted', N'Appointment, enquiry and patient support.', N'FUNC-LH-OPS', NULL, N'LE-LH-0001', N'UNIT-LH-OPS', N'Yes', N'As per approved operating schedule - confirm', N'Kerala / as applicable', N'Active', N'Illustrative channel; validate availability and actual channel ownership.'),
    (8, N'CHAN-LH-REF', N'Referral Network', N'Partner', N'Patient referrals from clinicians and institutions.', N'FUNC-LH-OPS', NULL, N'LE-LH-0001', N'UNIT-LH-OPS', N'Yes', N'As per approved operating schedule - confirm', N'Kerala / as applicable', N'Active', N'Illustrative channel; validate availability and actual channel ownership.');
CREATE TABLE #m_channels (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);

-- 10 Committee Members
CREATE TABLE #s_committee_members (rn INT NOT NULL, [membershipCode] NVARCHAR(MAX) NULL, [committeeId] NVARCHAR(MAX) NULL, [personId] NVARCHAR(MAX) NULL, [designationInCommittee] NVARCHAR(MAX) NULL, [memberSince] NVARCHAR(MAX) NULL, [memberUntil] NVARCHAR(MAX) NULL, [votingMember] NVARCHAR(MAX) NULL, [permanentInvitee] NVARCHAR(MAX) NULL, [participationRequirement] NVARCHAR(MAX) NULL, [recordStatus] NVARCHAR(MAX) NULL, [remarks] NVARCHAR(MAX) NULL, [legalEntityId] NVARCHAR(MAX) NULL);
INSERT #s_committee_members (rn, [membershipCode], [committeeId], [personId], [designationInCommittee], [memberSince], [memberUntil], [votingMember], [permanentInvitee], [participationRequirement], [recordStatus], [remarks], [legalEntityId]) VALUES
    (1, N'MEM-MF-AC-CEO', N'COMM-MF-AC', N'PERS-MF-CEO', N'Chairperson', N'2024-04-01', NULL, N'Yes', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-MF-0001'),
    (2, N'MEM-MF-AC-CFO', N'COMM-MF-AC', N'PERS-MF-CFO', N'Member', N'2024-04-01', NULL, N'Yes', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-MF-0001'),
    (3, N'MEM-MF-AC-IAH', N'COMM-MF-AC', N'PERS-MF-IAH', N'Secretary', N'2024-04-01', NULL, N'No', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-MF-0001'),
    (4, N'MEM-MF-RMC-CEO', N'COMM-MF-RMC', N'PERS-MF-CEO', N'Chairperson', N'2024-04-01', NULL, N'Yes', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-MF-0001'),
    (5, N'MEM-MF-RMC-CFO', N'COMM-MF-RMC', N'PERS-MF-CFO', N'Member', N'2024-04-01', NULL, N'Yes', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-MF-0001'),
    (6, N'MEM-MF-RMC-IAH', N'COMM-MF-RMC', N'PERS-MF-IAH', N'Secretary', N'2024-04-01', NULL, N'No', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-MF-0001'),
    (7, N'MEM-MF-ITC-CEO', N'COMM-MF-ITC', N'PERS-MF-CEO', N'Chairperson', N'2024-04-01', NULL, N'Yes', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-MF-0001'),
    (8, N'MEM-MF-ITC-CFO', N'COMM-MF-ITC', N'PERS-MF-CFO', N'Member', N'2024-04-01', NULL, N'Yes', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-MF-0001'),
    (9, N'MEM-MF-ITC-IAH', N'COMM-MF-ITC', N'PERS-MF-IAH', N'Secretary', N'2024-04-01', NULL, N'No', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-MF-0001'),
    (10, N'MEM-LH-AC-CEO', N'COMM-LH-AC', N'PERS-LH-CEO', N'Chairperson', N'2024-04-01', NULL, N'Yes', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-LH-0001'),
    (11, N'MEM-LH-AC-CFO', N'COMM-LH-AC', N'PERS-LH-CFO', N'Member', N'2024-04-01', NULL, N'Yes', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-LH-0001'),
    (12, N'MEM-LH-AC-IAH', N'COMM-LH-AC', N'PERS-LH-IAH', N'Secretary', N'2024-04-01', NULL, N'No', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-LH-0001'),
    (13, N'MEM-LH-RMC-CEO', N'COMM-LH-RMC', N'PERS-LH-CEO', N'Chairperson', N'2024-04-01', NULL, N'Yes', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-LH-0001'),
    (14, N'MEM-LH-RMC-CFO', N'COMM-LH-RMC', N'PERS-LH-CFO', N'Member', N'2024-04-01', NULL, N'Yes', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-LH-0001'),
    (15, N'MEM-LH-RMC-IAH', N'COMM-LH-RMC', N'PERS-LH-IAH', N'Secretary', N'2024-04-01', NULL, N'No', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-LH-0001'),
    (16, N'MEM-LH-ITC-CEO', N'COMM-LH-ITC', N'PERS-LH-CEO', N'Chairperson', N'2024-04-01', NULL, N'Yes', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-LH-0001'),
    (17, N'MEM-LH-ITC-CFO', N'COMM-LH-ITC', N'PERS-LH-CFO', N'Member', N'2024-04-01', NULL, N'Yes', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-LH-0001'),
    (18, N'MEM-LH-ITC-IAH', N'COMM-LH-ITC', N'PERS-LH-IAH', N'Secretary', N'2024-04-01', NULL, N'No', N'No', N'Attend scheduled meetings and review papers', N'Active', N'Synthetic committee membership for relationship testing.', N'LE-LH-0001');
CREATE TABLE #m_committee_members (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);

-- ============================ PASS 1: match or insert ============================
-- Organizations (registry_organization): by code.
INSERT #m_organizations (code, id) SELECT s.organizationCode, t.registry_organization_id
  FROM #s_organizations s JOIN grac_practice.registry_organization t ON t.organization_code = s.organizationCode;
INSERT grac_practice.registry_organization (organization_code, registered_name, organization_type, industry, record_status, entered_by)
SELECT s.organizationCode, s.registeredName, s.organizationType, s.industry, s.recordStatus, N'seed-572'
  FROM #s_organizations s WHERE NOT EXISTS (SELECT 1 FROM #m_organizations x WHERE x.code = s.organizationCode);
INSERT #m_organizations (code, id, inserted) SELECT s.organizationCode, t.registry_organization_id, 1
  FROM #s_organizations s JOIN grac_practice.registry_organization t ON t.organization_code = s.organizationCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_organizations x WHERE x.code = s.organizationCode);

-- Legal Entities (organization): by code, else ADOPT an existing organization with the same legal name.
INSERT #m_legal_entities (code, id) SELECT s.legalEntityCode, t.organization_id
  FROM #s_legal_entities s JOIN grac_practice.organization t ON t.organization_code = s.legalEntityCode;
INSERT #m_legal_entities (code, id)
SELECT s.legalEntityCode, MIN(t.organization_id)
  FROM #s_legal_entities s JOIN grac_practice.organization t ON t.organization_name = s.legalName
 WHERE NOT EXISTS (SELECT 1 FROM #m_legal_entities x WHERE x.code = s.legalEntityCode)
 GROUP BY s.legalEntityCode;
INSERT grac_practice.organization (organization_code, organization_name, status, record_status_id, entered_by)
SELECT s.legalEntityCode, s.legalName, s.recordStatus, (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = CASE WHEN s.recordStatus = N'Active' THEN N'Active' WHEN s.recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft' ELSE N'Inactive' END), N'seed-572'
  FROM #s_legal_entities s WHERE NOT EXISTS (SELECT 1 FROM #m_legal_entities x WHERE x.code = s.legalEntityCode);
INSERT #m_legal_entities (code, id, inserted) SELECT s.legalEntityCode, t.organization_id, 1
  FROM #s_legal_entities s JOIN grac_practice.organization t ON t.organization_code = s.legalEntityCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_legal_entities x WHERE x.code = s.legalEntityCode);

-- Organization Units (organization_division): by code in its Legal Entity.
INSERT #m_units (code, id) SELECT s.unitCode, t.division_id
  FROM #s_units s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_division t ON t.organization_id = l.id AND t.division_code = s.unitCode;
INSERT grac_practice.organization_division (organization_id, division_code, division_name, unit_type, is_operational, status, record_status_id, entered_by)
SELECT l.id, s.unitCode, s.unitName, s.unitType, s.isOperational, s.recordStatus, (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = CASE WHEN s.recordStatus = N'Active' THEN N'Active' WHEN s.recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft' ELSE N'Inactive' END), N'seed-572'
  FROM #s_units s JOIN #m_legal_entities l ON l.code = s.legalEntityId
 WHERE NOT EXISTS (SELECT 1 FROM #m_units x WHERE x.code = s.unitCode);
INSERT #m_units (code, id, inserted) SELECT s.unitCode, t.division_id, 1
  FROM #s_units s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_division t ON t.organization_id = l.id AND t.division_code = s.unitCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_units x WHERE x.code = s.unitCode);

-- Locations (organization_location): by code in its Legal Entity.
INSERT #m_locations (code, id) SELECT s.locationCode, t.location_id
  FROM #s_locations s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_location t ON t.organization_id = l.id AND t.location_code = s.locationCode;
-- ... else adopt the existing record of the same name (it has no code yet: the code is filled in).
UPDATE t SET t.location_code = s.locationCode, t.updated_by = N'seed-572', t.updated_dt = SYSUTCDATETIME()
  FROM #s_locations s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_location t ON t.organization_id = l.id AND t.location_name = s.locationName AND t.location_code IS NULL
 WHERE NOT EXISTS (SELECT 1 FROM #m_locations x WHERE x.code = s.locationCode);
INSERT #m_locations (code, id) SELECT s.locationCode, t.location_id
  FROM #s_locations s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_location t ON t.organization_id = l.id AND t.location_code = s.locationCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_locations x WHERE x.code = s.locationCode);
INSERT grac_practice.organization_location (organization_id, location_code, location_name, location_type_id, state_province, country, customer_facing, status, record_status_id, entered_by)
SELECT l.id, s.locationCode, s.locationName, lt.location_type_id, s.state, s.country, s.customerFacing, s.operationalStatus, (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = CASE WHEN s.operationalStatus = N'Active' THEN N'Active' WHEN s.operationalStatus IN (N'Draft', N'Pending Approval') THEN N'Draft' ELSE N'Inactive' END), N'seed-572'
  FROM #s_locations s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.location_type_master lt ON lt.location_type_name = s.locationType
 WHERE NOT EXISTS (SELECT 1 FROM #m_locations x WHERE x.code = s.locationCode);
INSERT #m_locations (code, id, inserted) SELECT s.locationCode, t.location_id, 1
  FROM #s_locations s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_location t ON t.organization_id = l.id AND t.location_code = s.locationCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_locations x WHERE x.code = s.locationCode);

-- Departments (organization_department): by code in its Legal Entity.
INSERT #m_departments (code, id) SELECT s.departmentCode, t.department_id
  FROM #s_departments s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_department t ON t.organization_id = l.id AND t.department_code = s.departmentCode;
INSERT grac_practice.organization_department (organization_id, department_code, department_name, department_type, status, record_status_id, entered_by)
SELECT l.id, s.departmentCode, s.departmentName, s.departmentType, s.recordStatus, (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = CASE WHEN s.recordStatus = N'Active' THEN N'Active' WHEN s.recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft' ELSE N'Inactive' END), N'seed-572'
  FROM #s_departments s JOIN #m_legal_entities l ON l.code = s.legalEntityId
 WHERE NOT EXISTS (SELECT 1 FROM #m_departments x WHERE x.code = s.departmentCode);
INSERT #m_departments (code, id, inserted) SELECT s.departmentCode, t.department_id, 1
  FROM #s_departments s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_department t ON t.organization_id = l.id AND t.department_code = s.departmentCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_departments x WHERE x.code = s.departmentCode);

-- Business Functions (organization_business_function): by code in its Legal Entity.
INSERT #m_functions (code, id) SELECT s.functionCode, t.business_function_id
  FROM #s_functions s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_business_function t ON t.organization_id = l.id AND t.function_code = s.functionCode;
INSERT grac_practice.organization_business_function (organization_id, function_code, function_name, function_category, status, entered_by)
SELECT l.id, s.functionCode, s.functionName, s.functionCategory, s.recordStatus, N'seed-572'
  FROM #s_functions s JOIN #m_legal_entities l ON l.code = s.legalEntityId
 WHERE NOT EXISTS (SELECT 1 FROM #m_functions x WHERE x.code = s.functionCode);
INSERT #m_functions (code, id, inserted) SELECT s.functionCode, t.business_function_id, 1
  FROM #s_functions s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_business_function t ON t.organization_id = l.id AND t.function_code = s.functionCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_functions x WHERE x.code = s.functionCode);

-- Teams (organization_team): by code in its Legal Entity.
INSERT #m_teams (code, id) SELECT s.teamCode, t.team_id
  FROM #s_teams s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_team t ON t.organization_id = l.id AND t.team_code = s.teamCode;
-- ... else adopt the existing record of the same name (it has no code yet: the code is filled in).
UPDATE t SET t.team_code = s.teamCode, t.updated_by = N'seed-572', t.updated_dt = SYSUTCDATETIME()
  FROM #s_teams s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_team t ON t.organization_id = l.id AND t.team_name = s.teamName AND t.team_code IS NULL
 WHERE NOT EXISTS (SELECT 1 FROM #m_teams x WHERE x.code = s.teamCode);
INSERT #m_teams (code, id) SELECT s.teamCode, t.team_id
  FROM #s_teams s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_team t ON t.organization_id = l.id AND t.team_code = s.teamCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_teams x WHERE x.code = s.teamCode);
INSERT grac_practice.organization_team (organization_id, team_code, team_name, team_classification, status, record_status_id, team_type, entered_by)
SELECT l.id, s.teamCode, s.teamName, s.teamType, s.recordStatus, (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = CASE WHEN s.recordStatus = N'Active' THEN N'Active' WHEN s.recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft' ELSE N'Inactive' END), N'InHouse', N'seed-572'
  FROM #s_teams s JOIN #m_legal_entities l ON l.code = s.legalEntityId
 WHERE NOT EXISTS (SELECT 1 FROM #m_teams x WHERE x.code = s.teamCode);
INSERT #m_teams (code, id, inserted) SELECT s.teamCode, t.team_id, 1
  FROM #s_teams s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_team t ON t.organization_id = l.id AND t.team_code = s.teamCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_teams x WHERE x.code = s.teamCode);

-- People (organization_employee): by code in its Legal Entity.
INSERT #m_people (code, id) SELECT s.personCode, t.employee_id
  FROM #s_people s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_employee t ON t.organization_id = l.id AND t.employee_code = s.personCode;
INSERT grac_practice.organization_employee (organization_id, employee_code, employee_name, person_category, designation, person_status, status, record_status_id, party_type, entered_by)
SELECT l.id, s.personCode, s.fullName, s.personCategory, s.designation, s.personStatus, s.recordStatus, (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = CASE WHEN s.recordStatus = N'Active' THEN N'Active' WHEN s.recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft' ELSE N'Inactive' END), N'Employee', N'seed-572'
  FROM #s_people s JOIN #m_legal_entities l ON l.code = s.legalEntityId
 WHERE NOT EXISTS (SELECT 1 FROM #m_people x WHERE x.code = s.personCode);
INSERT #m_people (code, id, inserted) SELECT s.personCode, t.employee_id, 1
  FROM #s_people s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_employee t ON t.organization_id = l.id AND t.employee_code = s.personCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_people x WHERE x.code = s.personCode);

-- Committees (organization_committee): by code in its Legal Entity.
INSERT #m_committees (code, id) SELECT s.committeeCode, t.committee_id
  FROM #s_committees s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_committee t ON t.organization_id = l.id AND t.committee_code = s.committeeCode;
-- ... else adopt the existing record of the same name (it has no code yet: the code is filled in).
UPDATE t SET t.committee_code = s.committeeCode, t.updated_by = N'seed-572', t.updated_dt = SYSUTCDATETIME()
  FROM #s_committees s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_committee t ON t.organization_id = l.id AND t.committee_name = s.committeeName AND t.committee_code IS NULL
 WHERE NOT EXISTS (SELECT 1 FROM #m_committees x WHERE x.code = s.committeeCode);
INSERT #m_committees (code, id) SELECT s.committeeCode, t.committee_id
  FROM #s_committees s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_committee t ON t.organization_id = l.id AND t.committee_code = s.committeeCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_committees x WHERE x.code = s.committeeCode);
INSERT grac_practice.organization_committee (organization_id, committee_code, committee_name, committee_type, mandate, status, record_status_id, entered_by)
SELECT l.id, s.committeeCode, s.committeeName, s.committeeType, s.committeeMandate, s.recordStatus, (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = CASE WHEN s.recordStatus = N'Active' THEN N'Active' WHEN s.recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft' ELSE N'Inactive' END), N'seed-572'
  FROM #s_committees s JOIN #m_legal_entities l ON l.code = s.legalEntityId
 WHERE NOT EXISTS (SELECT 1 FROM #m_committees x WHERE x.code = s.committeeCode);
INSERT #m_committees (code, id, inserted) SELECT s.committeeCode, t.committee_id, 1
  FROM #s_committees s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_committee t ON t.organization_id = l.id AND t.committee_code = s.committeeCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_committees x WHERE x.code = s.committeeCode);

-- Products & Services (organization_product_service): by code in its Legal Entity.
INSERT #m_products (code, id) SELECT s.productCode, t.product_service_id
  FROM #s_products s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_product_service t ON t.organization_id = l.id AND t.product_code = s.productCode;
INSERT grac_practice.organization_product_service (organization_id, product_code, product_name, product_category, status, entered_by)
SELECT l.id, s.productCode, s.productName, s.productCategory, s.productStatus, N'seed-572'
  FROM #s_products s JOIN #m_legal_entities l ON l.code = s.legalEntityId
 WHERE NOT EXISTS (SELECT 1 FROM #m_products x WHERE x.code = s.productCode);
INSERT #m_products (code, id, inserted) SELECT s.productCode, t.product_service_id, 1
  FROM #s_products s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_product_service t ON t.organization_id = l.id AND t.product_code = s.productCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_products x WHERE x.code = s.productCode);

-- Business Processes (organization_dependency_process): by code in its Legal Entity.
INSERT #m_processes (code, id) SELECT s.processCode, t.process_id
  FROM #s_processes s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_dependency_process t ON t.organization_id = l.id AND t.process_code = s.processCode;
-- ... else adopt the existing record of the same name (it has no code yet: the code is filled in).
UPDATE t SET t.process_code = s.processCode, t.updated_by = N'seed-572', t.updated_dt = SYSUTCDATETIME()
  FROM #s_processes s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_dependency_process t ON t.organization_id = l.id AND t.process_name = s.processName AND t.process_code IS NULL
 WHERE NOT EXISTS (SELECT 1 FROM #m_processes x WHERE x.code = s.processCode);
INSERT #m_processes (code, id) SELECT s.processCode, t.process_id
  FROM #s_processes s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_dependency_process t ON t.organization_id = l.id AND t.process_code = s.processCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_processes x WHERE x.code = s.processCode);
INSERT grac_practice.organization_dependency_process (organization_id, process_code, process_name, process_level, process_nature, status, record_status_id, entered_by)
SELECT l.id, s.processCode, s.processName, s.processLevel, s.processNature, s.recordStatus, (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = CASE WHEN s.recordStatus = N'Active' THEN N'Active' WHEN s.recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft' ELSE N'Inactive' END), N'seed-572'
  FROM #s_processes s JOIN #m_legal_entities l ON l.code = s.legalEntityId
 WHERE NOT EXISTS (SELECT 1 FROM #m_processes x WHERE x.code = s.processCode);
INSERT #m_processes (code, id, inserted) SELECT s.processCode, t.process_id, 1
  FROM #s_processes s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_dependency_process t ON t.organization_id = l.id AND t.process_code = s.processCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_processes x WHERE x.code = s.processCode);

-- Delivery Channels (organization_delivery_channel): by code in its Legal Entity.
INSERT #m_channels (code, id) SELECT s.channelCode, t.channel_id
  FROM #s_channels s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_delivery_channel t ON t.organization_id = l.id AND t.channel_code = s.channelCode;
INSERT grac_practice.organization_delivery_channel (organization_id, channel_code, channel_name, channel_type, customer_facing, status, entered_by)
SELECT l.id, s.channelCode, s.channelName, s.channelType, s.customerFacing, s.channelStatus, N'seed-572'
  FROM #s_channels s JOIN #m_legal_entities l ON l.code = s.legalEntityId
 WHERE NOT EXISTS (SELECT 1 FROM #m_channels x WHERE x.code = s.channelCode);
INSERT #m_channels (code, id, inserted) SELECT s.channelCode, t.channel_id, 1
  FROM #s_channels s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_delivery_channel t ON t.organization_id = l.id AND t.channel_code = s.channelCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_channels x WHERE x.code = s.channelCode);

-- Committee Members (organization_committee_member): by code in its Legal Entity.
INSERT #m_committee_members (code, id) SELECT s.membershipCode, t.committee_member_id
  FROM #s_committee_members s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_committee_member t ON t.organization_id = l.id AND t.membership_code = s.membershipCode;
INSERT grac_practice.organization_committee_member (organization_id, membership_code, committee_id, employee_id, designation_id, status, record_status_id, entered_by)
SELECT l.id, s.membershipCode, c.id, p.id, dz.designation_id, s.recordStatus, (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = CASE WHEN s.recordStatus = N'Active' THEN N'Active' WHEN s.recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft' ELSE N'Inactive' END), N'seed-572'
  FROM #s_committee_members s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN #m_committees c ON c.code = s.committeeId
  JOIN #m_people p ON p.code = s.personId
  JOIN grac_practice.committee_designation_master dz ON dz.designation_name = s.designationInCommittee AND dz.organization_id IS NULL
 WHERE NOT EXISTS (SELECT 1 FROM #m_committee_members x WHERE x.code = s.membershipCode);
INSERT #m_committee_members (code, id, inserted) SELECT s.membershipCode, t.committee_member_id, 1
  FROM #s_committee_members s JOIN #m_legal_entities l ON l.code = s.legalEntityId
  JOIN grac_practice.organization_committee_member t ON t.organization_id = l.id AND t.membership_code = s.membershipCode
 WHERE NOT EXISTS (SELECT 1 FROM #m_committee_members x WHERE x.code = s.membershipCode);

-- ============================ PASS 2: fill empty columns ============================
-- Organizations
UPDATE t SET t.registered_name = COALESCE(t.registered_name, s.[registeredName]),
             t.brand_name = COALESCE(t.brand_name, s.[brandName]),
             t.organization_type = COALESCE(t.organization_type, s.[organizationType]),
             t.industry = COALESCE(t.industry, s.[industry]),
             t.regulator_classification = COALESCE(t.regulator_classification, s.[regulatorClassification]),
             t.registration_cin = COALESCE(t.registration_cin, s.[registrationCin]),
             t.lei = COALESCE(t.lei, s.[lei]),
             t.incorporation_dt = COALESCE(t.incorporation_dt, TRY_CONVERT(DATE, s.[incorporationDate], 23)),
             t.registered_office_address = COALESCE(t.registered_office_address, s.[registeredOfficeAddress]),
             t.city = COALESCE(t.city, s.[city]),
             t.state = COALESCE(t.state, s.[state]),
             t.country = COALESCE(t.country, s.[country]),
             t.pin_code = COALESCE(t.pin_code, s.[pinCode]),
             t.corporate_website = COALESCE(t.corporate_website, s.[corporateWebsite]),
             t.financial_year_start = COALESCE(t.financial_year_start, s.[financialYearStart]),
             t.financial_year_end = COALESCE(t.financial_year_end, s.[financialYearEnd]),
             t.primary_contact_role = COALESCE(t.primary_contact_role, s.[primaryContactRole]),
             t.primary_contact_email = COALESCE(t.primary_contact_email, s.[primaryContactEmail]),
             t.data_cutoff_dt = COALESCE(t.data_cutoff_dt, TRY_CONVERT(DATE, s.[dataCutoffDate], 23)),
             t.record_status = COALESCE(t.record_status, s.[recordStatus]),
             t.remarks = COALESCE(t.remarks, s.[remarks]),
             t.data_quality_note = COALESCE(t.data_quality_note, s.[dataQualityNote])
  FROM grac_practice.registry_organization t JOIN #m_organizations me ON me.id = t.registry_organization_id
  JOIN #s_organizations s ON s.[organizationCode] = me.code
  ;

-- Legal Entities
UPDATE t SET t.registry_organization_id = COALESCE(t.registry_organization_id, r1.id),
             t.short_name = COALESCE(t.short_name, s.[shortName]),
             t.entity_type = COALESCE(t.entity_type, s.[entityType]),
             t.parent_organization_id = COALESCE(t.parent_organization_id, r2.id),
             t.registration_number = COALESCE(t.registration_number, s.[registrationNumber]),
             t.incorporation_dt = COALESCE(t.incorporation_dt, TRY_CONVERT(DATE, s.[incorporationDate], 23)),
             t.address_line1 = COALESCE(t.address_line1, s.[registeredOfficeAddress]),
             t.city = COALESCE(t.city, s.[city]),
             t.state_province = COALESCE(t.state_province, s.[state]),
             t.country = COALESCE(t.country, s.[country]),
             t.regulator = COALESCE(t.regulator, s.[regulator]),
             t.regulatory_classification = COALESCE(t.regulatory_classification, s.[regulatoryClassification]),
             t.business_activity = COALESCE(t.business_activity, s.[businessActivity]),
             t.in_scope_for_grac = COALESCE(t.in_scope_for_grac, s.[inScopeForGrac]),
             t.entity_owner_employee_id = COALESCE(t.entity_owner_employee_id, r3.id),
             t.status = COALESCE(t.status, s.[recordStatus]),
             t.effective_from = COALESCE(t.effective_from, TRY_CONVERT(DATE, s.[effectiveFrom], 23)),
             t.effective_to = COALESCE(t.effective_to, TRY_CONVERT(DATE, s.[effectiveTo], 23)),
             t.legal_entity_remarks = COALESCE(t.legal_entity_remarks, s.[remarks])
  FROM grac_practice.organization t JOIN #m_legal_entities me ON me.id = t.organization_id
  JOIN #s_legal_entities s ON s.[legalEntityCode] = me.code
  LEFT JOIN #m_organizations r1 ON r1.code = s.[registryOrganizationId]
  LEFT JOIN #m_legal_entities r2 ON r2.code = s.[parentLegalEntityId]
  LEFT JOIN #m_people r3 ON r3.code = s.[entityOwnerPersonId];

-- Organization Units
UPDATE t SET t.division_name = COALESCE(t.division_name, s.[unitName]),
             t.unit_type = COALESCE(t.unit_type, s.[unitType]),
             t.parent_division_id = COALESCE(t.parent_division_id, r1.id),
             t.primary_location_id = COALESCE(t.primary_location_id, r2.id),
             t.head_employee_id = COALESCE(t.head_employee_id, r3.id),
             t.head_designation = COALESCE(t.head_designation, s.[unitHeadDesignation]),
             t.business_unit_type = COALESCE(t.business_unit_type, s.[businessUnitType]),
             t.state_region = COALESCE(t.state_region, s.[stateRegion]),
             t.cost_centre = COALESCE(t.cost_centre, s.[unitCostCentre]),
             t.is_operational = COALESCE(t.is_operational, s.[isOperational]),
             t.status = COALESCE(t.status, s.[recordStatus]),
             t.effective_from = COALESCE(t.effective_from, TRY_CONVERT(DATE, s.[effectiveFrom], 23)),
             t.effective_to = COALESCE(t.effective_to, TRY_CONVERT(DATE, s.[effectiveTo], 23)),
             t.remarks = COALESCE(t.remarks, s.[remarks])
  FROM grac_practice.organization_division t JOIN #m_units me ON me.id = t.division_id
  JOIN #s_units s ON s.[unitCode] = me.code
  LEFT JOIN #m_units r1 ON r1.code = s.[parentUnitId]
  LEFT JOIN #m_locations r2 ON r2.code = s.[primaryLocationId]
  LEFT JOIN #m_people r3 ON r3.code = s.[unitHeadPersonId];

-- Locations
UPDATE t SET t.location_name = COALESCE(t.location_name, s.[locationName]),
             t.location_type_id = COALESCE(t.location_type_id, r1.location_type_id),
             t.division_id = COALESCE(t.division_id, r2.id),
             t.parent_location_id = COALESCE(t.parent_location_id, r3.id),
             t.address_line1 = COALESCE(t.address_line1, s.[addressLine1]),
             t.address_line2 = COALESCE(t.address_line2, s.[addressLine2]),
             t.city = COALESCE(t.city, s.[cityTown]),
             t.district = COALESCE(t.district, s.[district]),
             t.state_province = COALESCE(t.state_province, s.[state]),
             t.postal_code = COALESCE(t.postal_code, s.[pinCode]),
             t.country = COALESCE(t.country, s.[country]),
             t.latitude = COALESCE(t.latitude, TRY_CONVERT(DECIMAL(9,6), s.[latitude])),
             t.longitude = COALESCE(t.longitude, TRY_CONVERT(DECIMAL(9,6), s.[longitude])),
             t.region = COALESCE(t.region, s.[regionZoneLabel]),
             t.location_head_id = COALESCE(t.location_head_id, r4.id),
             t.opening_dt = COALESCE(t.opening_dt, TRY_CONVERT(DATE, s.[openingDate], 23)),
             t.closure_dt = COALESCE(t.closure_dt, TRY_CONVERT(DATE, s.[closureDate], 23)),
             t.customer_facing = COALESCE(t.customer_facing, s.[customerFacing]),
             t.status = COALESCE(t.status, s.[operationalStatus]),
             t.remarks = COALESCE(t.remarks, s.[remarks])
  FROM grac_practice.organization_location t JOIN #m_locations me ON me.id = t.location_id
  JOIN #s_locations s ON s.[locationCode] = me.code
  LEFT JOIN grac_practice.location_type_master r1 ON r1.location_type_name = s.[locationType]
  LEFT JOIN #m_units r2 ON r2.code = s.[organizationUnitId]
  LEFT JOIN #m_locations r3 ON r3.code = s.[parentLocationId]
  LEFT JOIN #m_people r4 ON r4.code = s.[locationHeadPersonId];

-- Departments
UPDATE t SET t.department_name = COALESCE(t.department_name, s.[departmentName]),
             t.short_name = COALESCE(t.short_name, s.[shortName]),
             t.department_type = COALESCE(t.department_type, s.[departmentType]),
             t.parent_department_id = COALESCE(t.parent_department_id, r1.id),
             t.primary_division_id = COALESCE(t.primary_division_id, r2.id),
             t.head_employee_id = COALESCE(t.head_employee_id, r3.id),
             t.head_designation = COALESCE(t.head_designation, s.[departmentHeadDesignation]),
             t.primary_business_function_id = COALESCE(t.primary_business_function_id, r4.id),
             t.cost_centre = COALESCE(t.cost_centre, s.[costCentre]),
             t.centralisation = COALESCE(t.centralisation, s.[centralisation]),
             t.status = COALESCE(t.status, s.[recordStatus]),
             t.effective_from = COALESCE(t.effective_from, TRY_CONVERT(DATE, s.[effectiveFrom], 23)),
             t.effective_to = COALESCE(t.effective_to, TRY_CONVERT(DATE, s.[effectiveTo], 23)),
             t.remarks = COALESCE(t.remarks, s.[remarks])
  FROM grac_practice.organization_department t JOIN #m_departments me ON me.id = t.department_id
  JOIN #s_departments s ON s.[departmentCode] = me.code
  LEFT JOIN #m_departments r1 ON r1.code = s.[parentDepartmentId]
  LEFT JOIN #m_units r2 ON r2.code = s.[primaryOrganizationUnitId]
  LEFT JOIN #m_people r3 ON r3.code = s.[departmentHeadPersonId]
  LEFT JOIN #m_functions r4 ON r4.code = s.[primaryBusinessFunctionId];

-- Business Functions
UPDATE t SET t.function_name = COALESCE(t.function_name, s.[functionName]),
             t.function_category = COALESCE(t.function_category, s.[functionCategory]),
             t.parent_function_id = COALESCE(t.parent_function_id, r1.id),
             t.business_unit_type = COALESCE(t.business_unit_type, s.[businessUnitType]),
             t.owner_employee_id = COALESCE(t.owner_employee_id, r2.id),
             t.accountable_department_id = COALESCE(t.accountable_department_id, r3.id),
             t.executive_sponsor_employee_id = COALESCE(t.executive_sponsor_employee_id, r4.id),
             t.description = COALESCE(t.description, s.[descriptionScope]),
             t.key_responsibilities = COALESCE(t.key_responsibilities, s.[keyResponsibilities]),
             t.status = COALESCE(t.status, s.[recordStatus]),
             t.effective_from = COALESCE(t.effective_from, TRY_CONVERT(DATE, s.[effectiveFrom], 23)),
             t.effective_to = COALESCE(t.effective_to, TRY_CONVERT(DATE, s.[effectiveTo], 23)),
             t.remarks = COALESCE(t.remarks, s.[remarks])
  FROM grac_practice.organization_business_function t JOIN #m_functions me ON me.id = t.business_function_id
  JOIN #s_functions s ON s.[functionCode] = me.code
  LEFT JOIN #m_functions r1 ON r1.code = s.[parentFunctionId]
  LEFT JOIN #m_people r2 ON r2.code = s.[functionOwnerPersonId]
  LEFT JOIN #m_departments r3 ON r3.code = s.[accountableDepartmentId]
  LEFT JOIN #m_people r4 ON r4.code = s.[executiveSponsorPersonId];

-- Teams
UPDATE t SET t.team_name = COALESCE(t.team_name, s.[teamName]),
             t.team_classification = COALESCE(t.team_classification, s.[teamType]),
             t.parent_department_id = COALESCE(t.parent_department_id, r1.id),
             t.primary_function_id = COALESCE(t.primary_function_id, r2.id),
             t.division_id = COALESCE(t.division_id, r3.id),
             t.team_manager_id = COALESCE(t.team_manager_id, r4.id),
             t.team_purpose = COALESCE(t.team_purpose, s.[teamPurpose]),
             t.status = COALESCE(t.status, s.[recordStatus]),
             t.effective_from = COALESCE(t.effective_from, TRY_CONVERT(DATE, s.[effectiveFrom], 23)),
             t.effective_to = COALESCE(t.effective_to, TRY_CONVERT(DATE, s.[effectiveTo], 23)),
             t.remarks = COALESCE(t.remarks, s.[remarks])
  FROM grac_practice.organization_team t JOIN #m_teams me ON me.id = t.team_id
  JOIN #s_teams s ON s.[teamCode] = me.code
  LEFT JOIN #m_departments r1 ON r1.code = s.[parentDepartmentId]
  LEFT JOIN #m_functions r2 ON r2.code = s.[primaryFunctionId]
  LEFT JOIN #m_units r3 ON r3.code = s.[organizationUnitId]
  LEFT JOIN #m_people r4 ON r4.code = s.[teamManagerPersonId];

-- People
UPDATE t SET t.employee_name = COALESCE(t.employee_name, s.[fullName]),
             t.person_category = COALESCE(t.person_category, s.[personCategory]),
             t.employment_type = COALESCE(t.employment_type, s.[employmentType]),
             t.reference_no = COALESCE(t.reference_no, s.[referenceNo]),
             t.email = COALESCE(t.email, CASE WHEN EXISTS (SELECT 1 FROM grac_practice.organization_employee e2 WHERE e2.email = s.[officialEmail] AND e2.employee_id <> t.employee_id) THEN NULL ELSE s.[officialEmail] END),
             t.official_phone = COALESCE(t.official_phone, s.[officialPhone]),
             t.designation = COALESCE(t.designation, s.[designation]),
             t.functional_role = COALESCE(t.functional_role, s.[roleName]),
             t.department_id = COALESCE(t.department_id, r1.id),
             t.business_function_id = COALESCE(t.business_function_id, r2.id),
             t.primary_team_id = COALESCE(t.primary_team_id, r3.id),
             t.division_id = COALESCE(t.division_id, r4.id),
             t.location_id = COALESCE(t.location_id, r5.id),
             t.reporting_officer_id = COALESCE(t.reporting_officer_id, r6.id),
             t.functional_reporting_to_id = COALESCE(t.functional_reporting_to_id, r7.id),
             t.appointment_dt = COALESCE(t.appointment_dt, TRY_CONVERT(DATE, s.[joiningDate], 23)),
             t.exit_dt = COALESCE(t.exit_dt, TRY_CONVERT(DATE, s.[exitDate], 23)),
             t.person_status = COALESCE(t.person_status, s.[personStatus]),
             t.is_kmp = COALESCE(t.is_kmp, s.[isKmp]),
             t.status = COALESCE(t.status, s.[recordStatus]),
             t.remarks = COALESCE(t.remarks, s.[remarks])
  FROM grac_practice.organization_employee t JOIN #m_people me ON me.id = t.employee_id
  JOIN #s_people s ON s.[personCode] = me.code
  LEFT JOIN #m_departments r1 ON r1.code = s.[departmentId]
  LEFT JOIN #m_functions r2 ON r2.code = s.[primaryFunctionId]
  LEFT JOIN #m_teams r3 ON r3.code = s.[primaryTeamId]
  LEFT JOIN #m_units r4 ON r4.code = s.[organizationUnitId]
  LEFT JOIN #m_locations r5 ON r5.code = s.[primaryLocationId]
  LEFT JOIN #m_people r6 ON r6.code = s.[reportsToPersonId]
  LEFT JOIN #m_people r7 ON r7.code = s.[functionalReportsToPersonId];

-- Committees
UPDATE t SET t.committee_name = COALESCE(t.committee_name, s.[committeeName]),
             t.committee_type = COALESCE(t.committee_type, s.[committeeType]),
             t.mandate = COALESCE(t.mandate, s.[committeeMandate]),
             t.scope_responsibilities = COALESCE(t.scope_responsibilities, s.[scopeResponsibilities]),
             t.chairperson_id = COALESCE(t.chairperson_id, r1.id),
             t.secretary_id = COALESCE(t.secretary_id, r2.id),
             t.review_frequency = COALESCE(t.review_frequency, s.[reviewFrequency]),
             t.tor_reference = COALESCE(t.tor_reference, s.[torReference]),
             t.constituted_dt = COALESCE(t.constituted_dt, TRY_CONVERT(DATE, s.[constitutedDate], 23)),
             t.last_reviewed_dt = COALESCE(t.last_reviewed_dt, TRY_CONVERT(DATE, s.[lastReviewedDate], 23)),
             t.next_review_due_dt = COALESCE(t.next_review_due_dt, TRY_CONVERT(DATE, s.[nextReviewDueDate], 23)),
             t.status = COALESCE(t.status, s.[recordStatus]),
             t.effective_from = COALESCE(t.effective_from, TRY_CONVERT(DATE, s.[effectiveFrom], 23)),
             t.effective_to = COALESCE(t.effective_to, TRY_CONVERT(DATE, s.[effectiveTo], 23)),
             t.remarks = COALESCE(t.remarks, s.[remarks]),
             t.review_frequency_id = COALESCE(t.review_frequency_id, (SELECT TOP (1) fm.frequency_id FROM grac_practice.frequency_master fm WHERE fm.frequency_name = CASE s.[reviewFrequency] WHEN N'Annually' THEN N'Annual' ELSE s.[reviewFrequency] END ORDER BY fm.is_active DESC, fm.frequency_id))
  FROM grac_practice.organization_committee t JOIN #m_committees me ON me.id = t.committee_id
  JOIN #s_committees s ON s.[committeeCode] = me.code
  LEFT JOIN #m_people r1 ON r1.code = s.[chairpersonPersonId]
  LEFT JOIN #m_people r2 ON r2.code = s.[secretaryPersonId];

-- Products & Services
UPDATE t SET t.product_name = COALESCE(t.product_name, s.[productName]),
             t.product_category = COALESCE(t.product_category, s.[productCategory]),
             t.scheme_variant = COALESCE(t.scheme_variant, s.[schemeVariant]),
             t.description = COALESCE(t.description, s.[description]),
             t.owning_function_id = COALESCE(t.owning_function_id, r1.id),
             t.owning_department_id = COALESCE(t.owning_department_id, r2.id),
             t.product_owner_id = COALESCE(t.product_owner_id, r3.id),
             t.customer_segment = COALESCE(t.customer_segment, s.[customerSegment]),
             t.secured_unsecured = COALESCE(t.secured_unsecured, s.[securedUnsecured]),
             t.regulatory_classification = COALESCE(t.regulatory_classification, s.[regulatoryClassification]),
             t.launch_dt = COALESCE(t.launch_dt, TRY_CONVERT(DATE, s.[launchDate], 23)),
             t.withdrawal_dt = COALESCE(t.withdrawal_dt, TRY_CONVERT(DATE, s.[withdrawalDate], 23)),
             t.status = COALESCE(t.status, s.[productStatus]),
             t.remarks = COALESCE(t.remarks, s.[remarks])
  FROM grac_practice.organization_product_service t JOIN #m_products me ON me.id = t.product_service_id
  JOIN #s_products s ON s.[productCode] = me.code
  LEFT JOIN #m_functions r1 ON r1.code = s.[owningFunctionId]
  LEFT JOIN #m_departments r2 ON r2.code = s.[owningDepartmentId]
  LEFT JOIN #m_people r3 ON r3.code = s.[productOwnerPersonId];

-- Business Processes
UPDATE t SET t.process_name = COALESCE(t.process_name, s.[processName]),
             t.process_level = COALESCE(t.process_level, s.[processLevel]),
             t.parent_process_id = COALESCE(t.parent_process_id, r1.id),
             t.process_nature = COALESCE(t.process_nature, s.[processNature]),
             t.business_function_id = COALESCE(t.business_function_id, r2.id),
             t.owning_department_id = COALESCE(t.owning_department_id, r3.id),
             t.process_owner_id = COALESCE(t.process_owner_id, r4.id),
             t.accountable_executive_id = COALESCE(t.accountable_executive_id, r5.id),
             t.description = COALESCE(t.description, s.[descriptionObjective]),
             t.key_activities = COALESCE(t.key_activities, s.[keyActivities]),
             t.primary_product_id = COALESCE(t.primary_product_id, r6.id),
             t.primary_channel_id = COALESCE(t.primary_channel_id, r7.id),
             t.primary_division_id = COALESCE(t.primary_division_id, r8.id),
             t.location_scope = COALESCE(t.location_scope, s.[locationScope]),
             t.process_frequency = COALESCE(t.process_frequency, s.[processFrequency]),
             t.annual_volume = COALESCE(t.annual_volume, TRY_CONVERT(BIGINT, s.[annualVolume])),
             t.customer_impact = COALESCE(t.customer_impact, s.[customerImpact]),
             t.regulatory_impact = COALESCE(t.regulatory_impact, s.[regulatoryImpact]),
             t.regulatory_references = COALESCE(t.regulatory_references, s.[regulatoryReferences]),
             t.status = COALESCE(t.status, s.[recordStatus]),
             t.effective_dt = COALESCE(t.effective_dt, TRY_CONVERT(DATE, s.[effectiveFrom], 23)),
             t.effective_to = COALESCE(t.effective_to, TRY_CONVERT(DATE, s.[effectiveTo], 23)),
             t.remarks = COALESCE(t.remarks, s.[remarks])
  FROM grac_practice.organization_dependency_process t JOIN #m_processes me ON me.id = t.process_id
  JOIN #s_processes s ON s.[processCode] = me.code
  LEFT JOIN #m_processes r1 ON r1.code = s.[parentProcessId]
  LEFT JOIN #m_functions r2 ON r2.code = s.[businessFunctionId]
  LEFT JOIN #m_departments r3 ON r3.code = s.[owningDepartmentId]
  LEFT JOIN #m_people r4 ON r4.code = s.[processOwnerPersonId]
  LEFT JOIN #m_people r5 ON r5.code = s.[accountableExecutivePersonId]
  LEFT JOIN #m_products r6 ON r6.code = s.[primaryProductId]
  LEFT JOIN #m_channels r7 ON r7.code = s.[primaryChannelId]
  LEFT JOIN #m_units r8 ON r8.code = s.[primaryOrganizationUnitId];

-- Delivery Channels
UPDATE t SET t.channel_name = COALESCE(t.channel_name, s.[channelName]),
             t.channel_type = COALESCE(t.channel_type, s.[channelType]),
             t.description = COALESCE(t.description, s.[description]),
             t.owning_function_id = COALESCE(t.owning_function_id, r1.id),
             t.channel_owner_id = COALESCE(t.channel_owner_id, r2.id),
             t.primary_division_id = COALESCE(t.primary_division_id, r3.id),
             t.customer_facing = COALESCE(t.customer_facing, s.[customerFacing]),
             t.operational_hours = COALESCE(t.operational_hours, s.[operationalHours]),
             t.geographic_scope = COALESCE(t.geographic_scope, s.[geographicScope]),
             t.status = COALESCE(t.status, s.[channelStatus]),
             t.remarks = COALESCE(t.remarks, s.[remarks])
  FROM grac_practice.organization_delivery_channel t JOIN #m_channels me ON me.id = t.channel_id
  JOIN #s_channels s ON s.[channelCode] = me.code
  LEFT JOIN #m_functions r1 ON r1.code = s.[owningFunctionId]
  LEFT JOIN #m_people r2 ON r2.code = s.[channelOwnerPersonId]
  LEFT JOIN #m_units r3 ON r3.code = s.[primaryOrganizationUnitId];

-- Committee Members
UPDATE t SET t.committee_id = COALESCE(t.committee_id, r1.id),
             t.employee_id = COALESCE(t.employee_id, r2.id),
             t.designation_id = COALESCE(t.designation_id, r3.designation_id),
             t.member_since = COALESCE(t.member_since, TRY_CONVERT(DATE, s.[memberSince], 23)),
             t.member_until = COALESCE(t.member_until, TRY_CONVERT(DATE, s.[memberUntil], 23)),
             t.is_voting_member = COALESCE(t.is_voting_member, s.[votingMember]),
             t.is_permanent_invitee = COALESCE(t.is_permanent_invitee, s.[permanentInvitee]),
             t.participation_requirement = COALESCE(t.participation_requirement, s.[participationRequirement]),
             t.status = COALESCE(t.status, s.[recordStatus]),
             t.remarks = COALESCE(t.remarks, s.[remarks])
  FROM grac_practice.organization_committee_member t JOIN #m_committee_members me ON me.id = t.committee_member_id
  JOIN #s_committee_members s ON s.[membershipCode] = me.code
  LEFT JOIN #m_committees r1 ON r1.code = s.[committeeId]
  LEFT JOIN #m_people r2 ON r2.code = s.[personId]
  LEFT JOIN grac_practice.committee_designation_master r3 ON r3.designation_name = s.[designationInCommittee] AND r3.organization_id IS NULL;

-- Bridges (semicolon lists of sheets 11 and 13), only when missing.
INSERT grac_practice.organization_channel_product (channel_id, product_service_id, entered_by)
SELECT c.id, p.id, N'seed-572' FROM (VALUES
    (N'CHAN-MF-BR', N'PROD-MF-GOLD'),
    (N'CHAN-MF-BR', N'PROD-MF-VEH'),
    (N'CHAN-MF-BR', N'PROD-MF-BUS'),
    (N'CHAN-MF-BR', N'PROD-MF-NCD'),
    (N'CHAN-MF-WEB', N'PROD-MF-GOLD'),
    (N'CHAN-MF-WEB', N'PROD-MF-VEH'),
    (N'CHAN-MF-WEB', N'PROD-MF-BUS'),
    (N'CHAN-MF-WEB', N'PROD-MF-NCD'),
    (N'CHAN-MF-MOB', N'PROD-MF-GOLD'),
    (N'CHAN-MF-MOB', N'PROD-MF-VEH'),
    (N'CHAN-MF-MOB', N'PROD-MF-BUS'),
    (N'CHAN-MF-MOB', N'PROD-MF-NCD'),
    (N'CHAN-MF-CC', N'PROD-MF-GOLD'),
    (N'CHAN-MF-CC', N'PROD-MF-VEH'),
    (N'CHAN-MF-CC', N'PROD-MF-BUS'),
    (N'CHAN-MF-CC', N'PROD-MF-NCD'),
    (N'CHAN-LH-HOSP', N'PROD-LH-IPD'),
    (N'CHAN-LH-HOSP', N'PROD-LH-OPD'),
    (N'CHAN-LH-HOSP', N'PROD-LH-EMG'),
    (N'CHAN-LH-HOSP', N'PROD-LH-DIAG'),
    (N'CHAN-LH-WEB', N'PROD-LH-IPD'),
    (N'CHAN-LH-WEB', N'PROD-LH-OPD'),
    (N'CHAN-LH-WEB', N'PROD-LH-EMG'),
    (N'CHAN-LH-WEB', N'PROD-LH-DIAG'),
    (N'CHAN-LH-CALL', N'PROD-LH-IPD'),
    (N'CHAN-LH-CALL', N'PROD-LH-OPD'),
    (N'CHAN-LH-CALL', N'PROD-LH-EMG'),
    (N'CHAN-LH-CALL', N'PROD-LH-DIAG'),
    (N'CHAN-LH-REF', N'PROD-LH-IPD'),
    (N'CHAN-LH-REF', N'PROD-LH-OPD'),
    (N'CHAN-LH-REF', N'PROD-LH-EMG'),
    (N'CHAN-LH-REF', N'PROD-LH-DIAG')) v(ch, pr)
  JOIN #m_channels c ON c.code = v.ch JOIN #m_products p ON p.code = v.pr
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_channel_product b WHERE b.channel_id = c.id AND b.product_service_id = p.id);
INSERT grac_practice.organization_channel_process (channel_id, process_id, entered_by)
SELECT c.id, p.id, N'seed-572' FROM (VALUES
    (N'CHAN-MF-BR', N'PROC-MF-LENDING-L1'),
    (N'CHAN-MF-BR', N'PROC-MF-GOLD-L1'),
    (N'CHAN-MF-BR', N'PROC-MF-COLL-L1'),
    (N'CHAN-MF-BR', N'PROC-MF-KYC-L1'),
    (N'CHAN-MF-BR', N'PROC-MF-TREAS-L1'),
    (N'CHAN-MF-BR', N'PROC-MF-IT-L1'),
    (N'CHAN-MF-WEB', N'PROC-MF-LENDING-L1'),
    (N'CHAN-MF-WEB', N'PROC-MF-GOLD-L1'),
    (N'CHAN-MF-WEB', N'PROC-MF-COLL-L1'),
    (N'CHAN-MF-WEB', N'PROC-MF-KYC-L1'),
    (N'CHAN-MF-WEB', N'PROC-MF-TREAS-L1'),
    (N'CHAN-MF-WEB', N'PROC-MF-IT-L1'),
    (N'CHAN-MF-MOB', N'PROC-MF-LENDING-L1'),
    (N'CHAN-MF-MOB', N'PROC-MF-GOLD-L1'),
    (N'CHAN-MF-MOB', N'PROC-MF-COLL-L1'),
    (N'CHAN-MF-MOB', N'PROC-MF-KYC-L1'),
    (N'CHAN-MF-MOB', N'PROC-MF-TREAS-L1'),
    (N'CHAN-MF-MOB', N'PROC-MF-IT-L1'),
    (N'CHAN-MF-CC', N'PROC-MF-LENDING-L1'),
    (N'CHAN-MF-CC', N'PROC-MF-GOLD-L1'),
    (N'CHAN-MF-CC', N'PROC-MF-COLL-L1'),
    (N'CHAN-MF-CC', N'PROC-MF-KYC-L1'),
    (N'CHAN-MF-CC', N'PROC-MF-TREAS-L1'),
    (N'CHAN-MF-CC', N'PROC-MF-IT-L1'),
    (N'CHAN-LH-HOSP', N'PROC-LH-PAT-L1'),
    (N'CHAN-LH-HOSP', N'PROC-LH-CLIN-L1'),
    (N'CHAN-LH-HOSP', N'PROC-LH-PHARM-L1'),
    (N'CHAN-LH-HOSP', N'PROC-LH-LAB-L1'),
    (N'CHAN-LH-HOSP', N'PROC-LH-BILL-L1'),
    (N'CHAN-LH-HOSP', N'PROC-LH-IT-L1'),
    (N'CHAN-LH-WEB', N'PROC-LH-PAT-L1'),
    (N'CHAN-LH-WEB', N'PROC-LH-CLIN-L1'),
    (N'CHAN-LH-WEB', N'PROC-LH-PHARM-L1'),
    (N'CHAN-LH-WEB', N'PROC-LH-LAB-L1'),
    (N'CHAN-LH-WEB', N'PROC-LH-BILL-L1'),
    (N'CHAN-LH-WEB', N'PROC-LH-IT-L1'),
    (N'CHAN-LH-CALL', N'PROC-LH-PAT-L1'),
    (N'CHAN-LH-CALL', N'PROC-LH-CLIN-L1'),
    (N'CHAN-LH-CALL', N'PROC-LH-PHARM-L1'),
    (N'CHAN-LH-CALL', N'PROC-LH-LAB-L1'),
    (N'CHAN-LH-CALL', N'PROC-LH-BILL-L1'),
    (N'CHAN-LH-CALL', N'PROC-LH-IT-L1'),
    (N'CHAN-LH-REF', N'PROC-LH-PAT-L1'),
    (N'CHAN-LH-REF', N'PROC-LH-CLIN-L1'),
    (N'CHAN-LH-REF', N'PROC-LH-PHARM-L1'),
    (N'CHAN-LH-REF', N'PROC-LH-LAB-L1'),
    (N'CHAN-LH-REF', N'PROC-LH-BILL-L1'),
    (N'CHAN-LH-REF', N'PROC-LH-IT-L1')) v(ch, pr)
  JOIN #m_channels c ON c.code = v.ch JOIN #m_processes p ON p.code = v.pr
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_channel_process b WHERE b.channel_id = c.id AND b.process_id = p.id);
INSERT grac_practice.organization_process_risk_category (process_id, risk_category, entered_by)
SELECT p.id, v.rc, N'seed-572' FROM (VALUES
    (N'PROC-MF-LENDING-L1', N'Operational'),
    (N'PROC-MF-LENDING-L1', N'Compliance'),
    (N'PROC-MF-LENDING-L1', N'Conduct'),
    (N'PROC-MF-LENDING-L1', N'Technology'),
    (N'PROC-MF-GOLD-L1', N'Operational'),
    (N'PROC-MF-GOLD-L1', N'Compliance'),
    (N'PROC-MF-GOLD-L1', N'Conduct'),
    (N'PROC-MF-GOLD-L1', N'Technology'),
    (N'PROC-MF-COLL-L1', N'Operational'),
    (N'PROC-MF-COLL-L1', N'Compliance'),
    (N'PROC-MF-COLL-L1', N'Conduct'),
    (N'PROC-MF-COLL-L1', N'Technology'),
    (N'PROC-MF-KYC-L1', N'Operational'),
    (N'PROC-MF-KYC-L1', N'Compliance'),
    (N'PROC-MF-KYC-L1', N'Conduct'),
    (N'PROC-MF-KYC-L1', N'Technology'),
    (N'PROC-MF-TREAS-L1', N'Operational'),
    (N'PROC-MF-TREAS-L1', N'Compliance'),
    (N'PROC-MF-TREAS-L1', N'Conduct'),
    (N'PROC-MF-TREAS-L1', N'Technology'),
    (N'PROC-MF-IT-L1', N'Operational'),
    (N'PROC-MF-IT-L1', N'Compliance'),
    (N'PROC-MF-IT-L1', N'Conduct'),
    (N'PROC-MF-IT-L1', N'Technology'),
    (N'PROC-LH-PAT-L1', N'Operational'),
    (N'PROC-LH-PAT-L1', N'Compliance'),
    (N'PROC-LH-PAT-L1', N'Conduct'),
    (N'PROC-LH-PAT-L1', N'Technology'),
    (N'PROC-LH-CLIN-L1', N'Operational'),
    (N'PROC-LH-CLIN-L1', N'Compliance'),
    (N'PROC-LH-CLIN-L1', N'Conduct'),
    (N'PROC-LH-CLIN-L1', N'Technology'),
    (N'PROC-LH-PHARM-L1', N'Operational'),
    (N'PROC-LH-PHARM-L1', N'Compliance'),
    (N'PROC-LH-PHARM-L1', N'Conduct'),
    (N'PROC-LH-PHARM-L1', N'Technology'),
    (N'PROC-LH-LAB-L1', N'Operational'),
    (N'PROC-LH-LAB-L1', N'Compliance'),
    (N'PROC-LH-LAB-L1', N'Conduct'),
    (N'PROC-LH-LAB-L1', N'Technology'),
    (N'PROC-LH-BILL-L1', N'Operational'),
    (N'PROC-LH-BILL-L1', N'Compliance'),
    (N'PROC-LH-BILL-L1', N'Conduct'),
    (N'PROC-LH-BILL-L1', N'Technology'),
    (N'PROC-LH-IT-L1', N'Operational'),
    (N'PROC-LH-IT-L1', N'Compliance'),
    (N'PROC-LH-IT-L1', N'Conduct'),
    (N'PROC-LH-IT-L1', N'Technology')) v(pc, rc)
  JOIN #m_processes p ON p.code = v.pc
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_process_risk_category b WHERE b.process_id = p.id AND b.risk_category = v.rc);

COMMIT;

PRINT '--- 572 result: workbook rows -> GRAC records (inserted = new this run) ---';
SELECT N'01 Organization Profile' AS sheet, (SELECT COUNT(*) FROM #s_organizations) AS workbook_rows, (SELECT COUNT(*) FROM #m_organizations) AS matched_or_loaded, (SELECT COUNT(*) FROM #m_organizations WHERE inserted = 1) AS inserted_this_run
UNION ALL SELECT N'02 Legal Entities' AS sheet, (SELECT COUNT(*) FROM #s_legal_entities) AS workbook_rows, (SELECT COUNT(*) FROM #m_legal_entities) AS matched_or_loaded, (SELECT COUNT(*) FROM #m_legal_entities WHERE inserted = 1) AS inserted_this_run
UNION ALL SELECT N'03 Organization Units' AS sheet, (SELECT COUNT(*) FROM #s_units) AS workbook_rows, (SELECT COUNT(*) FROM #m_units) AS matched_or_loaded, (SELECT COUNT(*) FROM #m_units WHERE inserted = 1) AS inserted_this_run
UNION ALL SELECT N'04 Locations' AS sheet, (SELECT COUNT(*) FROM #s_locations) AS workbook_rows, (SELECT COUNT(*) FROM #m_locations) AS matched_or_loaded, (SELECT COUNT(*) FROM #m_locations WHERE inserted = 1) AS inserted_this_run
UNION ALL SELECT N'05 Departments' AS sheet, (SELECT COUNT(*) FROM #s_departments) AS workbook_rows, (SELECT COUNT(*) FROM #m_departments) AS matched_or_loaded, (SELECT COUNT(*) FROM #m_departments WHERE inserted = 1) AS inserted_this_run
UNION ALL SELECT N'06 Business Functions' AS sheet, (SELECT COUNT(*) FROM #s_functions) AS workbook_rows, (SELECT COUNT(*) FROM #m_functions) AS matched_or_loaded, (SELECT COUNT(*) FROM #m_functions WHERE inserted = 1) AS inserted_this_run
UNION ALL SELECT N'07 Teams' AS sheet, (SELECT COUNT(*) FROM #s_teams) AS workbook_rows, (SELECT COUNT(*) FROM #m_teams) AS matched_or_loaded, (SELECT COUNT(*) FROM #m_teams WHERE inserted = 1) AS inserted_this_run
UNION ALL SELECT N'08 People' AS sheet, (SELECT COUNT(*) FROM #s_people) AS workbook_rows, (SELECT COUNT(*) FROM #m_people) AS matched_or_loaded, (SELECT COUNT(*) FROM #m_people WHERE inserted = 1) AS inserted_this_run
UNION ALL SELECT N'09 Committees' AS sheet, (SELECT COUNT(*) FROM #s_committees) AS workbook_rows, (SELECT COUNT(*) FROM #m_committees) AS matched_or_loaded, (SELECT COUNT(*) FROM #m_committees WHERE inserted = 1) AS inserted_this_run
UNION ALL SELECT N'12 Products & Services' AS sheet, (SELECT COUNT(*) FROM #s_products) AS workbook_rows, (SELECT COUNT(*) FROM #m_products) AS matched_or_loaded, (SELECT COUNT(*) FROM #m_products WHERE inserted = 1) AS inserted_this_run
UNION ALL SELECT N'11 Business Processes' AS sheet, (SELECT COUNT(*) FROM #s_processes) AS workbook_rows, (SELECT COUNT(*) FROM #m_processes) AS matched_or_loaded, (SELECT COUNT(*) FROM #m_processes WHERE inserted = 1) AS inserted_this_run
UNION ALL SELECT N'13 Delivery Channels' AS sheet, (SELECT COUNT(*) FROM #s_channels) AS workbook_rows, (SELECT COUNT(*) FROM #m_channels) AS matched_or_loaded, (SELECT COUNT(*) FROM #m_channels WHERE inserted = 1) AS inserted_this_run
UNION ALL SELECT N'10 Committee Members' AS sheet, (SELECT COUNT(*) FROM #s_committee_members) AS workbook_rows, (SELECT COUNT(*) FROM #m_committee_members) AS matched_or_loaded, (SELECT COUNT(*) FROM #m_committee_members WHERE inserted = 1) AS inserted_this_run;
SELECT s.personCode AS person_without_email, s.officialEmail AS workbook_email
  FROM #s_people s JOIN #m_people me ON me.code = s.personCode
  JOIN grac_practice.organization_employee e ON e.employee_id = me.id
 WHERE s.officialEmail IS NOT NULL AND e.email IS NULL;   -- e-mail already used by another person in GRAC

PRINT N'572 workbook note -- 02 Legal Entities / LE-MF-0001 / Entity Type*: Holding / Operating Company -> Not in 15 Masters & Codes (LegalEntityType); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 02 Legal Entities / LE-LH-0001 / Entity Type*: Operating Company -> Not in 15 Masters & Codes (LegalEntityType); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 03 Organization Units / UNIT-MF-HO / Business Unit Type: Corporate -> Not in 15 Masters & Codes (BusinessUnitType); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 03 Organization Units / UNIT-MF-OPS / Business Unit Type: Operations -> Not in 15 Masters & Codes (BusinessUnitType); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 03 Organization Units / UNIT-MF-CTRL / Business Unit Type: Control / Assurance -> Not in 15 Masters & Codes (BusinessUnitType); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 05 Departments / DEPT-MF-FIN / Department Type*: Finance -> Not in 15 Masters & Codes (DepartmentType); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 05 Departments / DEPT-MF-HR / Department Type*: Corporate -> Not in 15 Masters & Codes (DepartmentType); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 05 Departments / DEPT-MF-IA / Department Type*: Control -> Not in 15 Masters & Codes (DepartmentType); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 08 People / PERS-MF-CEO / Person Category*: KMP -> Not in 15 Masters & Codes (PersonCategory); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 11 Business Processes / PROC-MF-LENDING-L1 / Regulatory Impact: High -> Not in 15 Masters & Codes (RegulatoryImpact); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 12 Products & Services / PROD-MF-GOLD / Product Category*: Loan -> Not in 15 Masters & Codes (ProductCategory); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 12 Products & Services / PROD-MF-NCD / Product Category*: Investment -> Not in 15 Masters & Codes (ProductCategory); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 12 Products & Services / PROD-LH-IPD / Product Category*: Healthcare Service -> Not in 15 Masters & Codes (ProductCategory); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 12 Products & Services / PROD-MF-GOLD / Secured / Unsecured (if applicable): Secured -> Not in 15 Masters & Codes (SecuredUnsecured); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 12 Products & Services / PROD-MF-BUS / Secured / Unsecured (if applicable): Unsecured -> Not in 15 Masters & Codes (SecuredUnsecured); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 12 Products & Services / PROD-MF-NCD / Secured / Unsecured (if applicable): Not applicable -> Not in 15 Masters & Codes (SecuredUnsecured); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-MF-BR / Channel Type*: Physical -> Not in 15 Masters & Codes (ChannelType); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-MF-WEB / Channel Type*: Digital -> Not in 15 Masters & Codes (ChannelType); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-MF-CC / Channel Type*: Assisted -> Not in 15 Masters & Codes (ChannelType); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-LH-REF / Channel Type*: Partner -> Not in 15 Masters & Codes (ChannelType); added to the list flagged ''not approved'' so the row loads as given.';
PRINT N'572 workbook note -- 01 Organization Profile / M/s Lakeshore Hospital and Research Centre Limited / Organization Code*: ORG-MF-0001 -> Duplicate code; loaded as ORG-LH-0001 (note kept on the record).';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF / Processes Supported (codes): PROC-LH-BILL -> No process has this code; the one code that extends it, PROC-LH-BILL-L1, was linked.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF / Processes Supported (codes): PROC-LH-CLIN -> No process has this code; the one code that extends it, PROC-LH-CLIN-L1, was linked.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF / Processes Supported (codes): PROC-LH-IT -> No process has this code; the one code that extends it, PROC-LH-IT-L1, was linked.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF / Processes Supported (codes): PROC-LH-LAB -> No process has this code; the one code that extends it, PROC-LH-LAB-L1, was linked.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF / Processes Supported (codes): PROC-LH-PAT -> No process has this code; the one code that extends it, PROC-LH-PAT-L1, was linked.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF / Processes Supported (codes): PROC-LH-PHARM -> No process has this code; the one code that extends it, PROC-LH-PHARM-L1, was linked.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC / Processes Supported (codes): PROC-MF-COLL -> No process has this code; the one code that extends it, PROC-MF-COLL-L1, was linked.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC / Processes Supported (codes): PROC-MF-GOLD -> No process has this code; the one code that extends it, PROC-MF-GOLD-L1, was linked.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC / Processes Supported (codes): PROC-MF-IT -> No process has this code; the one code that extends it, PROC-MF-IT-L1, was linked.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC / Processes Supported (codes): PROC-MF-KYC -> No process has this code; the one code that extends it, PROC-MF-KYC-L1, was linked.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC / Processes Supported (codes): PROC-MF-LENDING -> No process has this code; the one code that extends it, PROC-MF-LENDING-L1, was linked.';
PRINT N'572 workbook note -- 13 Delivery Channels / CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC / Processes Supported (codes): PROC-MF-TREAS -> No process has this code; the one code that extends it, PROC-MF-TREAS-L1, was linked.';
DROP TABLE IF EXISTS #s_organizations;
DROP TABLE IF EXISTS #m_organizations;
DROP TABLE IF EXISTS #s_legal_entities;
DROP TABLE IF EXISTS #m_legal_entities;
DROP TABLE IF EXISTS #s_units;
DROP TABLE IF EXISTS #m_units;
DROP TABLE IF EXISTS #s_locations;
DROP TABLE IF EXISTS #m_locations;
DROP TABLE IF EXISTS #s_departments;
DROP TABLE IF EXISTS #m_departments;
DROP TABLE IF EXISTS #s_functions;
DROP TABLE IF EXISTS #m_functions;
DROP TABLE IF EXISTS #s_teams;
DROP TABLE IF EXISTS #m_teams;
DROP TABLE IF EXISTS #s_people;
DROP TABLE IF EXISTS #m_people;
DROP TABLE IF EXISTS #s_committees;
DROP TABLE IF EXISTS #m_committees;
DROP TABLE IF EXISTS #s_products;
DROP TABLE IF EXISTS #m_products;
DROP TABLE IF EXISTS #s_processes;
DROP TABLE IF EXISTS #m_processes;
DROP TABLE IF EXISTS #s_channels;
DROP TABLE IF EXISTS #m_channels;
DROP TABLE IF EXISTS #s_committee_members;
DROP TABLE IF EXISTS #m_committee_members;
GO
SET NOEXEC OFF;
GO
PRINT '572 complete.';
GO
