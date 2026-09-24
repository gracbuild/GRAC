-- =====================================================================
-- 272 Consolidated master data seed -- every GLOBAL grac_practice master
--
-- WHY THIS EXISTS
--   grac_practice has 53 tables whose name ends in _master. Their rows
--   are seeded in 21 different places: deployment/03_Insert_Master_Data.sql
--   covers 17 of them, and the rest arrive with their owning migration
--   (026, 028, 035, 037, 040, 041, 048, 069, 073, 089, 098, 101, 104,
--   148, 158, 166, 174, 178, 204, 216, 240, 244). Standing up a fresh
--   database, or refilling one after 192_practice_data_reset.sql ran with
--   masters dropped, meant replaying that whole chain.
--
--   This script is one place that fills every global master. It does not
--   replace the owning migrations -- they still own the DDL and remain the
--   source of truth for their rows. This is the consolidation of what
--   those rows finally are.
--
-- INSERT-ONLY ON PURPOSE (same rule as 217)
--   Every block only inserts rows that are absent, matched on the natural
--   key. A row an operator renamed, reordered or deactivated is left
--   exactly as it is. The one deliberate UPDATE is the gap-transition
--   deactivation in section H, which is what 174 does and is required for
--   a fresh database to reach the current lifecycle shape.
--
-- WHAT IS *NOT* SEEDED HERE, AND WHY
--   1. menu_master and organization_role_menu_permission.
--      The navigation tree is the product of ~35 migrations that insert,
--      rename, re-parent and DELETE menu rows (022, 042, 050, 051, 052,
--      056, 058, 059, 060, 061, 062, 063, 068, 071..106, 113, 125, 135,
--      138, 149, 152, 154, 155, 163, 171, 180, 203, 251). Its final state
--      cannot be re-derived from the files without replaying that order,
--      and a hand-written snapshot would silently regress the menu.
--      SUPERSEDED: 274_menu_master_seed.sql now carries that tree as a
--      98-row snapshot taken from the running database, so run 274 (or
--      the menu chain) for menus. 273 grants MSP whatever menu_master
--      holds at the time, so 274 belongs BEFORE 273 on a fresh database.
--   2. Org-scoped tables that happen to end in _master:
--         entity_type_master        (066, organization_id NOT NULL)
--         risk_category_master      (204)
--         risk_likelihood_master    (204)
--         risk_impact_master        (204)
--      plus risk_matrix_cell. These are per-tenant. 273 seeds them for
--      MSP by calling grac_practice.sp_risk_scoring_seed_default.
--   3. grac_practice.evidence_type_master (created by 001) is dead --
--      practice_instance_evidence.evidence_type_id was repointed to
--      GRAC_New.evidence_type_master by deployment/03. Section L seeds
--      the GRAC_New one, guarded, and leaves the grac_practice shell
--      empty on purpose.
--   4. security_role / security_permission / security_role_permission /
--      rbac_rule / entity_state_transition_rule. Global config, not
--      masters; owned by 004, 035 and 040 and left to them.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters corrupt string literals. Where an
-- owning migration used a section sign in a description, the ASCII form
-- is used here for NEW rows only -- existing rows are never rewritten.
--
-- Re-runnable: yes. A second run inserts nothing.
-- Rollback: database/272_master_data_seed_rollback.sql
-- DEPENDS ON: 001/002 (or deployment/01), and each owning migration for
--             the DDL. Every block is guarded on OBJECT_ID, so a table a
--             database has not created yet is skipped with a PRINT rather
--             than failing the script.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (272): schema grac_practice is missing. Run base scripts first.';
    RAISERROR('272_master_data_seed: schema grac_practice missing.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (272): record_status_master is missing. Run 001/002 first.';
    RAISERROR('272_master_data_seed: record_status_master missing.', 16, 1);
    SET NOEXEC ON;
END
GO

PRINT '272: starting consolidated master seed.';
GO

-- =====================================================================
-- SECTION A -- foundation status masters
--   Source: deployment/03_Insert_Master_Data.sql, 008_normalize_practice_status_master.sql
--   record_status_master must be first: eight other masters carry a
--   record_status_id FK to it.
-- =====================================================================
MERGE grac_practice.record_status_master AS t
USING (VALUES
    (N'Active',   N'Active',   1),
    (N'Inactive', N'Inactive', 2),
    (N'Retired',  N'Retired',  3),
    (N'Draft',    N'Draft',    4),
    (N'Disposed', N'Disposed', 5)
) AS s(status_code, status_name, display_order)
ON t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (status_code, status_name, display_order, is_active, entered_by)
    VALUES (s.status_code, s.status_name, s.display_order, 1, N'seed-272');
GO

MERGE grac_practice.applicability_status_master AS t
USING (VALUES
    (N'Not Updated',     N'Not Updated',     1),
    (N'Applicable',      N'Applicable',      2),
    (N'Not Applicable',  N'Not Applicable',  3),
    (N'Deferred',        N'Deferred',        4),
    (N'Accepted Risk',   N'Accepted Risk',   5),
    (N'Not Implemented', N'Not Implemented', 6),
    (N'Retired',         N'Retired',         7)
) AS s(status_code, status_name, display_order)
ON t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (status_code, status_name, display_order, is_active, entered_by)
    VALUES (s.status_code, s.status_name, s.display_order, 1, N'seed-272');
GO

MERGE grac_practice.subscription_status_master AS t
USING (VALUES
    (N'Active',         N'Active',         1),
    (N'Disabled',       N'Disabled',       2),
    (N'Superseded',     N'Superseded',     3),
    (N'Pending Review', N'Pending Review', 4)
) AS s(status_code, status_name, display_order)
ON t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (status_code, status_name, display_order, is_active, entered_by)
    VALUES (s.status_code, s.status_name, s.display_order, 1, N'seed-272');
GO

MERGE grac_practice.implementation_status_master AS t
USING (VALUES
    (N'Not Started',  N'Not Started',  1),
    (N'In Progress',  N'In Progress',  2),
    (N'Implemented',  N'Implemented',  3),
    (N'Active',       N'Active',       4),
    (N'Inactive',     N'Inactive',     5)
) AS s(status_code, status_name, display_order)
ON t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (status_code, status_name, display_order, is_active, entered_by)
    VALUES (s.status_code, s.status_name, s.display_order, 1, N'seed-272');
GO

MERGE grac_practice.operationalization_status_master AS t
USING (VALUES
    (N'Configured',               N'Configured',               1),
    (N'Partially Operationalized',N'Partially Operationalized',2),
    (N'Operationalized',          N'Operationalized',          3),
    (N'Retired',                  N'Retired',                  4)
) AS s(status_code, status_name, display_order)
ON t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (status_code, status_name, display_order, is_active, entered_by)
    VALUES (s.status_code, s.status_name, s.display_order, 1, N'seed-272');
GO

PRINT '272: section A (foundation status masters) done.';
GO

-- =====================================================================
-- SECTION B -- organization structure lookups
--   Source: deployment/03_Insert_Master_Data.sql
-- =====================================================================
MERGE grac_practice.location_type_master AS t
USING (VALUES
    (N'HO',     N'HO',     10),
    (N'BRANCH', N'Branch', 20),
    (N'DC',     N'DC',     30),
    (N'DR',     N'DR',     40),
    (N'OFFICE', N'Office', 50),
    (N'OTHER',  N'Other',  60)
) AS s(location_type_code, location_type_name, display_order)
ON t.location_type_code = s.location_type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (location_type_code, location_type_name, display_order, is_active, entered_by)
    VALUES (s.location_type_code, s.location_type_name, s.display_order, 1, N'seed-272');
GO

MERGE grac_practice.criticality_master AS t
USING (VALUES
    (N'Critical', N'Critical', 1),
    (N'High',     N'High',     2),
    (N'Medium',   N'Medium',   3),
    (N'Low',      N'Low',      4)
) AS s(criticality_code, criticality_name, display_order)
ON t.criticality_code = s.criticality_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (criticality_code, criticality_name, display_order, is_active, entered_by)
    VALUES (s.criticality_code, s.criticality_name, s.display_order, 1, N'seed-272');
GO

-- frequency_master: 019_cleanup_duplicate_frequency_master.sql exists
-- because an older seed matched on code OR name and produced duplicates.
-- Matching on frequency_code alone here cannot reintroduce that.
MERGE grac_practice.frequency_master AS t
USING (VALUES
    (N'Daily',        N'Daily',        1,    N'Day',   CAST(0 AS BIT), 1),
    (N'Weekly',       N'Weekly',       1,    N'Week',  CAST(0 AS BIT), 2),
    (N'Monthly',      N'Monthly',      1,    N'Month', CAST(0 AS BIT), 3),
    (N'Quarterly',    N'Quarterly',    3,    N'Month', CAST(0 AS BIT), 4),
    (N'Half-Yearly',  N'Half-Yearly',  6,    N'Month', CAST(0 AS BIT), 5),
    (N'Annual',       N'Annual',       12,   N'Month', CAST(0 AS BIT), 6),
    (N'Event Driven', N'Event Driven', NULL, NULL,     CAST(0 AS BIT), 7),
    (N'Continuous',   N'Continuous',   NULL, NULL,     CAST(0 AS BIT), 8),
    (N'Custom',       N'Custom',       NULL, NULL,     CAST(1 AS BIT), 9)
) AS s(frequency_code, frequency_name, frequency_value, frequency_unit, is_custom, display_order)
ON t.frequency_code = s.frequency_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (frequency_code, frequency_name, frequency_value, frequency_unit,
            is_custom, display_order, is_active, entered_by)
    VALUES (s.frequency_code, s.frequency_name, s.frequency_value, s.frequency_unit,
            s.is_custom, s.display_order, 1, N'seed-272');
GO

PRINT '272: section B (organization structure lookups) done.';
GO

-- =====================================================================
-- SECTION C -- dependency lookups
--   Source: deployment/03_Insert_Master_Data.sql, 015, 239, 240
--   dependency_type_master carries 9 rows: the 7 from 015 plus Team and
--   Committee, which deployment/03 added when the workbench registers
--   arrived.
-- =====================================================================
MERGE grac_practice.dependency_type_master AS t
USING (VALUES
    (N'Application', N'Application', 1),
    (N'Tool',        N'Tool',        2),
    (N'Vendor',      N'Vendor',      3),
    (N'Asset',       N'Asset',       4),
    (N'Process',     N'Process',     5),
    (N'Location',    N'Location',    6),
    (N'Person',      N'Person',      7),
    (N'Team',        N'Team',        8),
    (N'Committee',   N'Committee',   9)
) AS s(dependency_type_code, dependency_type_name, display_order)
ON t.dependency_type_code = s.dependency_type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (dependency_type_code, dependency_type_name, display_order, is_active, entered_by)
    VALUES (s.dependency_type_code, s.dependency_type_name, s.display_order, 1, N'seed-272');
GO

MERGE grac_practice.dependency_hosting_type_master AS t
USING (VALUES
    (N'ON_PREM', N'On-Prem', 10),
    (N'CLOUD',   N'Cloud',   20),
    (N'SAAS',    N'SaaS',    30)
) AS s(hosting_type_code, hosting_type_name, display_order)
ON t.hosting_type_code = s.hosting_type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (hosting_type_code, hosting_type_name, display_order, is_active, entered_by)
    VALUES (s.hosting_type_code, s.hosting_type_name, s.display_order, 1, N'seed-272');
GO

MERGE grac_practice.dependency_license_type_master AS t
USING (VALUES
    (N'SUBSCRIPTION', N'Subscription', 10),
    (N'PERPETUAL',    N'Perpetual',    20)
) AS s(license_type_code, license_type_name, display_order)
ON t.license_type_code = s.license_type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (license_type_code, license_type_name, display_order, is_active, entered_by)
    VALUES (s.license_type_code, s.license_type_name, s.display_order, 1, N'seed-272');
GO

MERGE grac_practice.dependency_service_category_master AS t
USING (VALUES
    (N'IT_SERVICES',       N'IT Services',       10),
    (N'CLOUD_SERVICES',    N'Cloud Services',    20),
    (N'CYBER_SECURITY',    N'Cyber Security',    30),
    (N'PAYMENT_SERVICES',  N'Payment Services',  40),
    (N'FACILITY_SERVICES', N'Facility Services', 50),
    (N'CONSULTING',        N'Consulting',        60),
    (N'OTHER',             N'Other',            100)
) AS s(service_category_code, service_category_name, display_order)
ON t.service_category_code = s.service_category_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (service_category_code, service_category_name, display_order, is_active, entered_by)
    VALUES (s.service_category_code, s.service_category_name, s.display_order, 1, N'seed-272');
GO

MERGE grac_practice.dependency_resolution_status_master AS t
USING (VALUES
    (N'Pending',  N'Pending',  1),
    (N'Resolved', N'Resolved', 2)
) AS s(status_code, status_name, display_order)
ON t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (status_code, status_name, display_order, is_active, entered_by)
    VALUES (s.status_code, s.status_name, s.display_order, 1, N'seed-272');
GO

-- dependency_asset_category_master carries two generations of rows: the
-- original 8 from deployment/03 (display_order 10..100) and the 5 taxonomy
-- roots from 240 (display_order 1000..1400). Both are live -- 240's
-- subcategories hang off the taxonomy roots, the originals are still
-- referenced by organization_dependency_asset rows created before 239.
MERGE grac_practice.dependency_asset_category_master AS t
USING (VALUES
    (N'SERVER',               N'Server',                  10),
    (N'NETWORK_DEVICE',       N'Network Device',          20),
    (N'DATABASE',             N'Database',                30),
    (N'ENDPOINT',             N'Endpoint',                40),
    (N'STORAGE',              N'Storage',                 50),
    (N'FACILITY',             N'Facility',                60),
    (N'DOCUMENT',             N'Document',                70),
    (N'OTHER',                N'Other',                  100),
    (N'TECHNOLOGY',           N'Technology',            1000),
    (N'INFORMATION_DATA',     N'Information & Data',    1100),
    (N'PHYSICAL_OPERATIONAL', N'Physical & Operational',1200),
    (N'FACILITIES_UTILITY',   N'Facilities & Utility',  1300),
    (N'VEHICLES',             N'Vehicles',              1400)
) AS s(asset_category_code, asset_category_name, display_order)
ON t.asset_category_code = s.asset_category_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (asset_category_code, asset_category_name, display_order, is_active, entered_by)
    VALUES (s.asset_category_code, s.asset_category_name, s.display_order, 1, N'seed-272');
GO

-- Asset taxonomy: subcategories (17) then types (~70). Source: 240.
IF OBJECT_ID('grac_practice.dependency_asset_subcategory_master','U') IS NULL
    PRINT '272: dependency_asset_subcategory_master absent (run 239) -- taxonomy skipped.';
ELSE
BEGIN
    ;WITH sub(cat_code, sub_code, sub_name, ord) AS (
        SELECT N'TECHNOLOGY', N'TECH_END_USER',      N'End User Computing',          10 UNION ALL
        SELECT N'TECHNOLOGY', N'TECH_COMPUTE',       N'Compute & Infrastructure',    20 UNION ALL
        SELECT N'TECHNOLOGY', N'TECH_NETWORK',       N'Network & Communications',    30 UNION ALL
        SELECT N'TECHNOLOGY', N'TECH_APPS',          N'Applications & Software',     40 UNION ALL
        SELECT N'TECHNOLOGY', N'TECH_CLOUD',         N'Cloud & Technology Services', 50 UNION ALL
        SELECT N'TECHNOLOGY', N'TECH_SECURITY',      N'Security Technology',         60 UNION ALL
        SELECT N'INFORMATION_DATA', N'INFO_DATA',         N'Data',                    10 UNION ALL
        SELECT N'INFORMATION_DATA', N'INFO_REPOSITORIES', N'Information Repositories',20 UNION ALL
        SELECT N'INFORMATION_DATA', N'INFO_RECORDS',      N'Information Records',     30 UNION ALL
        SELECT N'PHYSICAL_OPERATIONAL', N'PHY_OPERATIONAL', N'Operational Equipment',       10 UNION ALL
        SELECT N'PHYSICAL_OPERATIONAL', N'PHY_SAFETY',      N'Safety & Security Equipment', 20 UNION ALL
        SELECT N'PHYSICAL_OPERATIONAL', N'PHY_SPECIALIZED', N'Specialized Equipment',       30 UNION ALL
        SELECT N'FACILITIES_UTILITY', N'FAC_ELECTRICAL', N'Electrical Systems',           10 UNION ALL
        SELECT N'FACILITIES_UTILITY', N'FAC_HVAC',       N'HVAC & Environmental Systems', 20 UNION ALL
        SELECT N'FACILITIES_UTILITY', N'FAC_INFRA',      N'Facility Infrastructure',      30 UNION ALL
        SELECT N'VEHICLES', N'VEH_GENERAL',     N'General Vehicles',     10 UNION ALL
        SELECT N'VEHICLES', N'VEH_OPERATIONAL', N'Operational Vehicles', 20
    )
    MERGE grac_practice.dependency_asset_subcategory_master AS t
    USING (
        SELECT c.asset_category_id, sub.sub_code, sub.sub_name, sub.ord
        FROM   sub
        JOIN   grac_practice.dependency_asset_category_master c
               ON c.asset_category_code = sub.cat_code
    ) AS s(asset_category_id, subcategory_code, subcategory_name, display_order)
    ON t.subcategory_code = s.subcategory_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (asset_category_id, subcategory_code, subcategory_name, display_order, is_active, entered_by)
        VALUES (s.asset_category_id, s.subcategory_code, s.subcategory_name, s.display_order, 1, N'seed-272');
END
GO

IF OBJECT_ID('grac_practice.dependency_asset_type_master','U') IS NULL
    PRINT '272: dependency_asset_type_master absent (run 239) -- asset types skipped.';
ELSE
BEGIN
    ;WITH atype(sub_code, type_code, type_name, ord) AS (
        SELECT N'TECH_END_USER', N'TYPE_DESKTOP',      N'Desktop',           10 UNION ALL
        SELECT N'TECH_END_USER', N'TYPE_LAPTOP',       N'Laptop',            20 UNION ALL
        SELECT N'TECH_END_USER', N'TYPE_TABLET',       N'Tablet',            30 UNION ALL
        SELECT N'TECH_END_USER', N'TYPE_MOBILE',       N'Mobile Device',     40 UNION ALL
        SELECT N'TECH_END_USER', N'TYPE_THIN_CLIENT',  N'Thin Client',       50 UNION ALL
        SELECT N'TECH_END_USER', N'TYPE_PERIPHERAL',   N'Peripheral Device', 60 UNION ALL
        SELECT N'TECH_COMPUTE', N'TYPE_PHYSICAL_SERVER', N'Physical Server',       10 UNION ALL
        SELECT N'TECH_COMPUTE', N'TYPE_VIRTUAL_SERVER',  N'Virtual Server',        20 UNION ALL
        SELECT N'TECH_COMPUTE', N'TYPE_STORAGE_SYSTEM',  N'Storage System',        30 UNION ALL
        SELECT N'TECH_COMPUTE', N'TYPE_BACKUP_SYSTEM',   N'Backup System',         40 UNION ALL
        SELECT N'TECH_COMPUTE', N'TYPE_DC_EQUIPMENT',    N'Data Centre Equipment', 50 UNION ALL
        SELECT N'TECH_NETWORK', N'TYPE_ROUTER',            N'Router',                  10 UNION ALL
        SELECT N'TECH_NETWORK', N'TYPE_SWITCH',            N'Switch',                  20 UNION ALL
        SELECT N'TECH_NETWORK', N'TYPE_FIREWALL',          N'Firewall',                30 UNION ALL
        SELECT N'TECH_NETWORK', N'TYPE_WIRELESS_AP',       N'Wireless Access Point',   40 UNION ALL
        SELECT N'TECH_NETWORK', N'TYPE_NETWORK_APPLIANCE', N'Network Appliance',       50 UNION ALL
        SELECT N'TECH_NETWORK', N'TYPE_COMMS_EQUIPMENT',   N'Communication Equipment', 60 UNION ALL
        SELECT N'TECH_APPS', N'TYPE_BUSINESS_APP',     N'Business Application',   10 UNION ALL
        SELECT N'TECH_APPS', N'TYPE_ENTERPRISE_APP',   N'Enterprise Application', 20 UNION ALL
        SELECT N'TECH_APPS', N'TYPE_SYSTEM_SOFTWARE',  N'System Software',        30 UNION ALL
        SELECT N'TECH_APPS', N'TYPE_DATABASE',         N'Database',               40 UNION ALL
        SELECT N'TECH_APPS', N'TYPE_MIDDLEWARE',       N'Middleware',             50 UNION ALL
        SELECT N'TECH_APPS', N'TYPE_MOBILE_APP',       N'Mobile Application',     60 UNION ALL
        SELECT N'TECH_APPS', N'TYPE_WEB_APP',          N'Web Application',        70 UNION ALL
        SELECT N'TECH_APPS', N'TYPE_SOFTWARE_LICENCE', N'Software Licence',       80 UNION ALL
        SELECT N'TECH_CLOUD', N'TYPE_CLOUD_SERVICE',        N'Cloud Service',                10 UNION ALL
        SELECT N'TECH_CLOUD', N'TYPE_SAAS_SERVICE',         N'SaaS Service',                 20 UNION ALL
        SELECT N'TECH_CLOUD', N'TYPE_HOSTING_SERVICE',      N'Hosting Service',              30 UNION ALL
        SELECT N'TECH_CLOUD', N'TYPE_MANAGED_TECH_SERVICE', N'Managed Technology Service',   40 UNION ALL
        SELECT N'TECH_SECURITY', N'TYPE_SIEM',              N'Security Information & Event Management', 10 UNION ALL
        SELECT N'TECH_SECURITY', N'TYPE_ENDPOINT_SECURITY', N'Endpoint Security',                       20 UNION ALL
        SELECT N'TECH_SECURITY', N'TYPE_IAM',               N'Identity & Access Management System',     30 UNION ALL
        SELECT N'TECH_SECURITY', N'TYPE_VULN_MGMT',         N'Vulnerability Management Tool',           40 UNION ALL
        SELECT N'TECH_SECURITY', N'TYPE_SECURITY_APPLIANCE',N'Security Appliance',                      50 UNION ALL
        SELECT N'TECH_SECURITY', N'TYPE_ENCRYPTION',        N'Encryption / Key Management System',      60 UNION ALL
        SELECT N'INFO_DATA', N'TYPE_CUSTOMER_DATA',    N'Customer Data',    10 UNION ALL
        SELECT N'INFO_DATA', N'TYPE_EMPLOYEE_DATA',    N'Employee Data',    20 UNION ALL
        SELECT N'INFO_DATA', N'TYPE_FINANCIAL_DATA',   N'Financial Data',   30 UNION ALL
        SELECT N'INFO_DATA', N'TYPE_TRANSACTION_DATA', N'Transaction Data', 40 UNION ALL
        SELECT N'INFO_DATA', N'TYPE_OPERATIONAL_DATA', N'Operational Data', 50 UNION ALL
        SELECT N'INFO_DATA', N'TYPE_REGULATORY_DATA',  N'Regulatory Data',  60 UNION ALL
        SELECT N'INFO_REPOSITORIES', N'TYPE_DB_REPOSITORY',   N'Database',            10 UNION ALL
        SELECT N'INFO_REPOSITORIES', N'TYPE_DOC_REPOSITORY',  N'Document Repository', 20 UNION ALL
        SELECT N'INFO_REPOSITORIES', N'TYPE_FILE_REPOSITORY', N'File Repository',     30 UNION ALL
        SELECT N'INFO_REPOSITORIES', N'TYPE_RECORDS_REPO',    N'Records Repository',  40 UNION ALL
        SELECT N'INFO_REPOSITORIES', N'TYPE_DATA_WAREHOUSE',  N'Data Warehouse',      50 UNION ALL
        SELECT N'INFO_REPOSITORIES', N'TYPE_DATA_LAKE',       N'Data Lake',           60 UNION ALL
        SELECT N'INFO_RECORDS', N'TYPE_POLICY',      N'Policy',             10 UNION ALL
        SELECT N'INFO_RECORDS', N'TYPE_PROCEDURE',   N'Procedure',          20 UNION ALL
        SELECT N'INFO_RECORDS', N'TYPE_CONTRACT',    N'Contract',           30 UNION ALL
        SELECT N'INFO_RECORDS', N'TYPE_REPORT',      N'Report',             40 UNION ALL
        SELECT N'INFO_RECORDS', N'TYPE_REG_RETURN',  N'Regulatory Return',  50 UNION ALL
        SELECT N'INFO_RECORDS', N'TYPE_RECORD',      N'Record',             60 UNION ALL
        SELECT N'PHY_OPERATIONAL', N'TYPE_PRODUCTION_EQ', N'Production Equipment', 10 UNION ALL
        SELECT N'PHY_OPERATIONAL', N'TYPE_PROCESSING_EQ', N'Processing Equipment', 20 UNION ALL
        SELECT N'PHY_OPERATIONAL', N'TYPE_MEASURING_EQ',  N'Measuring Equipment',  30 UNION ALL
        SELECT N'PHY_OPERATIONAL', N'TYPE_TESTING_EQ',    N'Testing Equipment',    40 UNION ALL
        SELECT N'PHY_OPERATIONAL', N'TYPE_LAB_EQ',        N'Laboratory Equipment', 50 UNION ALL
        SELECT N'PHY_SAFETY', N'TYPE_CCTV',           N'CCTV',                     10 UNION ALL
        SELECT N'PHY_SAFETY', N'TYPE_ACCESS_CONTROL', N'Access Control Equipment', 20 UNION ALL
        SELECT N'PHY_SAFETY', N'TYPE_FIRE_SAFETY',    N'Fire Safety Equipment',    30 UNION ALL
        SELECT N'PHY_SAFETY', N'TYPE_ALARM_SYSTEM',   N'Alarm System',             40 UNION ALL
        SELECT N'PHY_SAFETY', N'TYPE_SURVEILLANCE',   N'Surveillance Equipment',   50 UNION ALL
        SELECT N'PHY_SPECIALIZED', N'TYPE_MEDICAL_EQ',    N'Medical Equipment',           10 UNION ALL
        SELECT N'PHY_SPECIALIZED', N'TYPE_SCIENTIFIC_EQ', N'Scientific Equipment',        20 UNION ALL
        SELECT N'PHY_SPECIALIZED', N'TYPE_INDUSTRY_EQ',   N'Industry-Specific Equipment', 30 UNION ALL
        SELECT N'FAC_ELECTRICAL', N'TYPE_GENERATOR',   N'Generator',                          10 UNION ALL
        SELECT N'FAC_ELECTRICAL', N'TYPE_UPS',         N'UPS',                                20 UNION ALL
        SELECT N'FAC_ELECTRICAL', N'TYPE_TRANSFORMER', N'Transformer',                        30 UNION ALL
        SELECT N'FAC_ELECTRICAL', N'TYPE_ELEC_DIST',   N'Electrical Distribution Equipment',  40 UNION ALL
        SELECT N'FAC_HVAC', N'TYPE_HVAC',            N'HVAC System',                      10 UNION ALL
        SELECT N'FAC_HVAC', N'TYPE_COOLING',         N'Cooling System',                   20 UNION ALL
        SELECT N'FAC_HVAC', N'TYPE_ENV_MONITORING',  N'Environmental Monitoring System',  30 UNION ALL
        SELECT N'FAC_INFRA', N'TYPE_BUILDING_INFRA',          N'Building Infrastructure',          10 UNION ALL
        SELECT N'FAC_INFRA', N'TYPE_WATER_TREATMENT',         N'Water Treatment System',           20 UNION ALL
        SELECT N'FAC_INFRA', N'TYPE_FIRE_PROTECTION',         N'Fire Protection System',           30 UNION ALL
        SELECT N'FAC_INFRA', N'TYPE_PHYSICAL_SECURITY_INFRA', N'Physical Security Infrastructure', 40 UNION ALL
        SELECT N'VEH_GENERAL', N'TYPE_COMPANY_CAR', N'Company Car', 10 UNION ALL
        SELECT N'VEH_GENERAL', N'TYPE_TRUCK',       N'Truck',       20 UNION ALL
        SELECT N'VEH_GENERAL', N'TYPE_VAN',         N'Van',         30 UNION ALL
        SELECT N'VEH_GENERAL', N'TYPE_TWO_WHEELER', N'Two-Wheeler', 40 UNION ALL
        SELECT N'VEH_OPERATIONAL', N'TYPE_AMBULANCE',    N'Ambulance',                 10 UNION ALL
        SELECT N'VEH_OPERATIONAL', N'TYPE_FORKLIFT',     N'Forklift',                  20 UNION ALL
        SELECT N'VEH_OPERATIONAL', N'TYPE_SPECIAL_VEH',  N'Special-Purpose Vehicle',   30 UNION ALL
        SELECT N'VEH_OPERATIONAL', N'TYPE_MATERIAL_VEH', N'Material Handling Vehicle', 40
    )
    MERGE grac_practice.dependency_asset_type_master AS t
    USING (
        SELECT sub.subcategory_id, atype.type_code, atype.type_name, atype.ord
        FROM   atype
        JOIN   grac_practice.dependency_asset_subcategory_master sub
               ON sub.subcategory_code = atype.sub_code
    ) AS s(subcategory_id, asset_type_code, asset_type_name, display_order)
    ON t.asset_type_code = s.asset_type_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (subcategory_id, asset_type_code, asset_type_name, display_order, is_active, entered_by)
        VALUES (s.subcategory_id, s.asset_type_code, s.asset_type_name, s.display_order, 1, N'seed-272');
END
GO

-- dependency_type_source_config is not a _master but is the resolver
-- lookup that turns a dependency type into a picker query. Source:
-- deployment/03. Keyed on dependency_type_id (unique index).
IF OBJECT_ID('grac_practice.dependency_type_source_config','U') IS NULL
    PRINT '272: dependency_type_source_config absent -- resolver config skipped.';
ELSE
BEGIN
    DECLARE @src_active_rs INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);

    ;WITH cfg(type_code, source_table_name, id_column_name, display_column_name, sort_column) AS (
        SELECT N'Tool',        N'grac_practice.organization_dependency_tool',        N'tool_id',        N'tool_name',        N'tool_name'        UNION ALL
        SELECT N'Vendor',      N'grac_practice.organization_dependency_vendor',      N'vendor_id',      N'vendor_name',      N'vendor_name'      UNION ALL
        SELECT N'Application', N'grac_practice.organization_dependency_application', N'application_id', N'application_name', N'application_name' UNION ALL
        SELECT N'Asset',       N'grac_practice.organization_dependency_asset',       N'asset_id',       N'asset_name',       N'asset_name'       UNION ALL
        SELECT N'Process',     N'grac_practice.organization_dependency_process',     N'process_id',     N'process_name',     N'process_name'     UNION ALL
        SELECT N'Location',    N'grac_practice.organization_location',               N'location_id',    N'location_name',    N'location_name'    UNION ALL
        SELECT N'Person',      N'grac_practice.organization_employee',               N'employee_id',    N'employee_name',    N'employee_name'    UNION ALL
        SELECT N'Team',        N'grac_practice.organization_team',                   N'team_id',        N'team_name',        N'team_name'        UNION ALL
        SELECT N'Committee',   N'grac_practice.organization_committee',              N'committee_id',   N'committee_name',   N'committee_name'
    )
    MERGE grac_practice.dependency_type_source_config AS t
    USING (
        SELECT dt.dependency_type_id, dt.dependency_type_name, dt.dependency_type_name AS source_type,
               cfg.source_table_name, cfg.id_column_name, cfg.display_column_name, cfg.sort_column
        FROM   cfg
        JOIN   grac_practice.dependency_type_master dt
               ON dt.dependency_type_code = cfg.type_code
    ) AS s(dependency_type_id, dependency_type_name, source_type,
           source_table_name, id_column_name, display_column_name, sort_column)
    ON t.dependency_type_id = s.dependency_type_id
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (dependency_type_id, dependency_type_name, source_type, source_table_name,
                id_column_name, display_column_name, organization_filter_column,
                status_filter_column, status_active_value, sort_column,
                is_multi_select_allowed, status, record_status_id, entered_by)
        VALUES (s.dependency_type_id, s.dependency_type_name, s.source_type, s.source_table_name,
                s.id_column_name, s.display_column_name, N'organization_id',
                N'status', N'Active', s.sort_column,
                1, N'Active', @src_active_rs, N'seed-272');
END
GO

PRINT '272: section C (dependency lookups) done.';
GO

-- =====================================================================
-- SECTION D -- evidence and assurance lookups
--   Source: deployment/03, 025, 026, 028
--   assurance_type_master intentionally holds only Manual and Automated:
--   deployment/03 deactivates Semi-Automated / Hybrid if a legacy
--   database carries them.
-- =====================================================================
MERGE grac_practice.collection_method_master AS t
USING (VALUES
    (N'Manual',    N'Manual',    1),
    (N'Automated', N'Automated', 2)
) AS s(collection_method_code, collection_method_name, display_order)
ON t.collection_method_code = s.collection_method_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (collection_method_code, collection_method_name, display_order, is_active, entered_by)
    VALUES (s.collection_method_code, s.collection_method_name, s.display_order, 1, N'seed-272');
GO

MERGE grac_practice.assurance_type_master AS t
USING (VALUES
    (N'Manual',    N'Manual',    1),
    (N'Automated', N'Automated', 2)
) AS s(assurance_type_code, assurance_type_name, display_order)
ON t.assurance_type_code = s.assurance_type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (assurance_type_code, assurance_type_name, display_order, is_active, entered_by)
    VALUES (s.assurance_type_code, s.assurance_type_name, s.display_order, 1, N'seed-272');
GO

MERGE grac_practice.evidence_alignment_status_master AS t
USING (VALUES
    (N'Inherited',            N'Inherited',            1),
    (N'Enhanced',             N'Enhanced',             2),
    (N'Partially Aligned',    N'Partially Aligned',    3),
    (N'Organization Defined', N'Organization Defined', 4),
    (N'Aligned',              N'Aligned',              5),
    (N'Not Aligned',          N'Not Aligned',          6)
) AS s(alignment_status_code, alignment_status_name, display_order)
ON t.alignment_status_code = s.alignment_status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (alignment_status_code, alignment_status_name, display_order, is_active, entered_by)
    VALUES (s.alignment_status_code, s.alignment_status_name, s.display_order, 1, N'seed-272');
GO

IF OBJECT_ID('grac_practice.assurance_activity_status_master','U') IS NULL
    PRINT '272: assurance_activity_status_master absent (run 026) -- skipped.';
ELSE
    MERGE grac_practice.assurance_activity_status_master AS t
    USING (VALUES
        (N'Pending',          N'Pending',          1),
        (N'In Progress',      N'In Progress',      2),
        (N'Completed',        N'Completed',        3),
        (N'Unable To Verify', N'Unable To Verify', 4)
    ) AS s(status_code, status_name, display_order)
    ON t.status_code = s.status_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (status_code, status_name, display_order, is_active, entered_by)
        VALUES (s.status_code, s.status_name, s.display_order, 1, N'seed-272');
GO

IF OBJECT_ID('grac_practice.assurance_result_status_master','U') IS NULL
    PRINT '272: assurance_result_status_master absent (run 026) -- skipped.';
ELSE
    MERGE grac_practice.assurance_result_status_master AS t
    USING (VALUES
        (N'Pending',               N'Pending',               1),
        (N'Pass',                  N'Pass',                  2),
        (N'Pass With Observation', N'Pass With Observation',  3),
        (N'Fail',                  N'Fail',                  4),
        (N'Unable To Verify',      N'Unable To Verify',      5)
    ) AS s(status_code, status_name, display_order)
    ON t.status_code = s.status_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (status_code, status_name, display_order, is_active, entered_by)
        VALUES (s.status_code, s.status_name, s.display_order, 1, N'seed-272');
GO

-- schedule_override_type_master (028) has no updated_by/updated_dt.
IF OBJECT_ID('grac_practice.schedule_override_type_master','U') IS NULL
    PRINT '272: schedule_override_type_master absent (run 028) -- skipped.';
ELSE
    MERGE grac_practice.schedule_override_type_master AS t
    USING (VALUES
        (N'Moved',   N'Moved to Different Date',    1),
        (N'Skipped', N'Skipped / Cancelled',        2),
        (N'Added',   N'Manually Added Occurrence',  3)
    ) AS s(override_type_code, override_type_name, display_order)
    ON t.override_type_code = s.override_type_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (override_type_code, override_type_name, display_order, is_active, entered_by)
        VALUES (s.override_type_code, s.override_type_name, s.display_order, 1, N'seed-272');
GO

PRINT '272: section D (evidence and assurance lookups) done.';
GO

-- =====================================================================
-- SECTION E -- state machine, task engine, origin, feature flags
--   Source: 035, 037, 040, 041, 048
--   entity_status_master is keyed on (entity_type, status_code).
-- =====================================================================
IF OBJECT_ID('grac_practice.entity_status_master','U') IS NULL
    PRINT '272: entity_status_master absent (run 035) -- skipped.';
ELSE
    MERGE grac_practice.entity_status_master AS t
    USING (VALUES
        (N'Task',       N'Open',                   N'Open',                   10, 1, 0),
        (N'Task',       N'Assigned',               N'Assigned',               20, 0, 0),
        (N'Task',       N'InProgress',             N'In Progress',            30, 0, 0),
        (N'Task',       N'ConfigGatePassed',       N'Config Gate Passed',     35, 0, 0),
        (N'Task',       N'AwaitingFirstExecution', N'Awaiting Execution',     36, 0, 0),
        (N'Task',       N'OperationalGatePassed',  N'Operational Gate Passed',37, 0, 0),
        (N'Task',       N'PendingReview',          N'Pending Review',         40, 0, 0),
        (N'Task',       N'Closed',                 N'Closed',                 50, 0, 1),
        (N'Task',       N'Cancelled',              N'Cancelled',              60, 0, 1),
        (N'Task',       N'Escalated',              N'Escalated',              70, 0, 0),
        (N'Assignment', N'Nominated',              N'Nominated',              10, 1, 0),
        (N'Assignment', N'Notified',               N'Notified',               20, 0, 0),
        (N'Assignment', N'Accepted',               N'Accepted',               30, 0, 0),
        (N'Assignment', N'Active',                 N'Active',                 40, 0, 0),
        (N'Assignment', N'Declined',               N'Declined',               50, 0, 1),
        (N'Assignment', N'Delegated',              N'Delegated',              60, 0, 1),
        (N'Assignment', N'Reassigned',             N'Reassigned',             70, 0, 1),
        (N'Assignment', N'Vacated',                N'Vacated',                80, 0, 1),
        (N'Waiver',     N'Draft',                  N'Draft',                  10, 1, 0),
        (N'Waiver',     N'Requested',              N'Requested',              20, 0, 0),
        (N'Waiver',     N'Approved',               N'Approved',               30, 0, 0),
        (N'Waiver',     N'Active',                 N'Active',                 40, 0, 0),
        (N'Waiver',     N'Expired',                N'Expired',                50, 0, 1),
        (N'Waiver',     N'Withdrawn',              N'Withdrawn',              60, 0, 1)
    ) AS s(entity_type, status_code, status_name, display_order, is_initial, is_terminal)
    ON t.entity_type = s.entity_type AND t.status_code = s.status_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (entity_type, status_code, status_name, display_order, is_initial, is_terminal, is_active, entered_by)
        VALUES (s.entity_type, s.status_code, s.status_name, s.display_order, s.is_initial, s.is_terminal, 1, N'seed-272');
GO

-- task_type_master: 8 rows from 037 plus Assurance and Custom from 048.
IF OBJECT_ID('grac_practice.task_type_master','U') IS NULL
    PRINT '272: task_type_master absent (run 037) -- skipped.';
ELSE
    MERGE grac_practice.task_type_master AS t
    USING (VALUES
        (N'Implementation',    N'Implementation',     N'Configure and operationalise an Instance',                    168, N'High',    0,  10),
        (N'Rectification',     N'Rectification',      N'Address a Fail from assurance execution',                      72, N'High',    0,  20),
        (N'Change',            N'Change',             N'Approved change request for content',                         168, N'Medium',  0,  30),
        (N'Waiver',            N'Waiver',             N'Waiver request or extension',                                 120, N'Medium',  0,  40),
        (N'Reverification',    N'Reverification',     N'Reverify an NA or Waiver before expiry',                      240, N'Medium',  0,  50),
        (N'AssignmentPending', N'Assignment Pending', N'Ownership acceptance pending',                                168, N'Medium',  1,  60),
        (N'AuditDriven',       N'Audit Driven',       N'Task raised from an auditor finding',                         168, N'High',    0,  70),
        (N'RiskDriven',        N'Risk Driven',        N'Task raised from a KRI or risk change',                       120, N'High',    0,  80),
        (N'Assurance',         N'Assurance',          N'Auto-generated task tied to an Assurance Ticket / Activity',   72, N'Medium',  1,  90),
        (N'Custom',            N'Custom',             N'User-created ad-hoc task from Task Center',                   120, N'Medium',  0, 100)
    ) AS s(type_code, type_name, description, default_sla_hours, default_priority, is_system_only, display_order)
    ON t.type_code = s.type_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (type_code, type_name, description, default_sla_hours, default_priority,
                is_system_only, display_order, is_active, entered_by)
        VALUES (s.type_code, s.type_name, s.description, s.default_sla_hours, s.default_priority,
                s.is_system_only, s.display_order, 1, N'seed-272');
GO

IF OBJECT_ID('grac_practice.origin_type_master','U') IS NULL
    PRINT '272: origin_type_master absent (run 040) -- skipped.';
ELSE
    MERGE grac_practice.origin_type_master AS t
    USING (VALUES
        (N'GRAC',   N'GRAC (published)', N'Published by gracbuild/GRAC-ADMIN; immutable text',        0, 10),
        (N'Custom', N'Custom (org)',     N'Org-authored content; full CRUD via retirement lifecycle', 1, 20)
    ) AS s(origin_code, origin_name, description, is_mutable, display_order)
    ON t.origin_code = s.origin_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (origin_code, origin_name, description, is_mutable, display_order, is_active, entered_by)
        VALUES (s.origin_code, s.origin_name, s.description, s.is_mutable, s.display_order, 1, N'seed-272');
GO

IF OBJECT_ID('grac_practice.related_entity_type_master','U') IS NULL
    PRINT '272: related_entity_type_master absent (run 048) -- skipped.';
ELSE
    MERGE grac_practice.related_entity_type_master AS t
    USING (VALUES
        (N'PracticeInstance',  N'Practice Instance', 10),
        (N'Practice',          N'Practice',          20),
        (N'Control',           N'Control',           30),
        (N'Release',           N'Release',           40),
        (N'Risk',              N'Risk',              50),
        (N'Waiver',            N'Waiver',            60),
        (N'AssuranceTicket',   N'Assurance Ticket',  70),
        (N'AssuranceActivity', N'Assurance Activity',75),
        (N'Custom',            N'Custom / Ad-hoc',   99)
    ) AS s(entity_code, entity_name, display_order)
    ON t.entity_code = s.entity_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (entity_code, entity_name, display_order, is_active, entered_by)
        VALUES (s.entity_code, s.entity_name, s.display_order, 1, N'seed-272');
GO

-- feature_flag_master: the 42 screen flags registered across 041, 050,
-- 068, 071..106, 125, 138, 149, 152, 154, 163, 171, 180, 203. All ship
-- default_enabled = 0; pm_grant_organization_default_access (217) turns
-- the 'screen.%' ones ON per organisation.
IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
    PRINT '272: feature_flag_master absent (run 041) -- skipped.';
ELSE
    MERGE grac_practice.feature_flag_master AS t
    USING (VALUES
        (N'screen.tasks',                        N'Task Center',                          N'Task Center (BRD Sec 12.1.3).'),
        (N'screen.waivers',                      N'Waivers & Exceptions',                 N'Waivers and exceptions (BRD Sec 12.1.5).'),
        (N'screen.applicability-decision',       N'Applicability & NA Decisions',          N'Applicability and NA decisions (BRD Sec 12.2.5).'),
        (N'screen.ownership-tree',               N'Ownership Tree',                       N'Ownership tree (BRD Sec 12.4.1).'),
        (N'screen.my-assignments',               N'My Assignments (Inbox)',               N'My assignments inbox (BRD Sec 12.4.2).'),
        (N'screen.gap-view',                     N'Gap View',                             N'Gap view (BRD Sec 12.4.3).'),
        (N'screen.handover',                     N'Handover / Bulk Reassign',             N'Handover and bulk reassign (BRD Sec 12.4.4).'),
        (N'screen.auditor-workbench',            N'Auditor Workbench',                    N'Auditor workbench (BRD Sec 12.5.3).'),
        (N'screen.risk-register',                N'Risk Register',                        N'Risk register (BRD Sec 12.5.5).'),
        (N'screen.kri-dashboard',                N'KRI Dashboard',                        N'KRI dashboard (BRD Sec 12.5.6).'),
        (N'screen.adapter-bindings',             N'Assurance Adapter Bindings',           N'Assurance adapter bindings (BRD Sec 12.3.3).'),
        (N'screen.gaps',                         N'Gap Center',                           N'Gap-source module split from Task Center (see Sec 12.1.3 follow-up).'),
        (N'screen.workflows',                    N'Workflow Definitions',                 N'Workflow & Event-Driven Assurance Engine (BRD Sec 6).'),
        (N'screen.workflow-stages',              N'Workflow Stages',                      N'BRD Sec 7.'),
        (N'screen.workflow-entity-types',        N'Entity Types',                         N'BRD Sec 9.'),
        (N'screen.workflow-events',              N'Events',                               N'BRD Sec 8.'),
        (N'screen.workflow-checklists',          N'Checklists',                           N'BRD Sec 11.'),
        (N'screen.workflow-event-mappings',      N'Event-Checklist Mappings',             N'BRD Sec 10.'),
        (N'screen.event-assurance',              N'Event Assurance',                      N'BRD Sec 13/14.'),
        (N'screen.workflow-dashboard',           N'Workflow Dashboard',                   N'BRD Sec 16.'),
        (N'screen.org-assurance-definitions',    N'Organization Assurance Definitions',   N'Phase 2 Assurance Management -- Organization-level Assurance Definitions (BRD Part 2 Sec 1).'),
        (N'screen.org-assurance-scope-builder',  N'Assurance Scope Builder',              N'Phase 2 Assurance Management -- Scope Builder (BRD Part 2 Sec 2).'),
        (N'screen.org-assurance-scope-resolution',N'Assurance Scope Resolution',          N'Phase 2 Assurance Management -- Scope Resolution Engine + snapshot viewer (BRD Part 2 Sec 3).'),
        (N'screen.org-assurance-question-sets',  N'Assurance Question Sets',              N'Phase 2 Assurance Management -- reusable Question Sets & Questions (BRD Part 2 Sec 4).'),
        (N'screen.org-assurance-evidence-config',N'Assurance Evidence Config',            N'Phase 2 Assurance Management -- Evidence configuration per definition version (BRD Part 2 Sec 5).'),
        (N'screen.org-assurance-workflow-config',N'Assurance Workflow Config',            N'Phase 2 Assurance Management -- workflow config per definition version (BRD Part 2 Sec 6).'),
        (N'screen.org-assurance-scoring-config', N'Assurance Scoring Config',             N'Phase 2 Assurance Management -- scoring model + bands per definition version (BRD Part 2 Sec 7).'),
        (N'screen.org-assurance-plans',          N'Assurance Plans',                      N'Phase 2 Assurance Management -- Annual / Quarterly / Monthly / One-Time plans (BRD Part 2 Sec 8).'),
        (N'screen.org-assurance-triggers',       N'Assurance Triggers',                   N'Phase 2 Assurance Management -- Scheduled / Event / Continuous / Manual triggers (BRD Part 2 Sec 9).'),
        (N'screen.org-assurance-executions',     N'Assurance Executions',                 N'Phase 2 Assurance Management -- Execution materialization + snapshot viewer (BRD Part 2 Sec 9-10).'),
        (N'screen.org-assurance-observations',   N'Assurance Observations',               N'Phase 2 Assurance Management -- Observation Management + evidence + lifecycle (BRD Part 2 Sec 11).'),
        (N'screen.org-assurance-gaps',           N'Assurance Gaps',                       N'Phase 2 Assurance Management -- Gap Management, auto-gen from observation, remediation lifecycle (BRD Part 2 Sec 12).'),
        (N'screen.workflow-scope-mapping',       N'Scoped Checklist Mapping',             N'Map checklists to an organisation role or asset category, restricted to subscribed releases (migrations 123/124).'),
        (N'screen.workflow-event-inbox',         N'Event Checklist Inbox',                N'Raise people and asset lifecycle events and complete the resulting scoped checklists (migrations 123/124).'),
        (N'screen.asset-category-assurance',     N'Asset Category Assurance',             N'Configure the checklists and obligations that apply when an asset of a given category is commissioned or decommissioned (migration 138).'),
        (N'screen.document-uploads',             N'Document Uploads',                     N'Controlled document register, upload, and review/approve workflow (migrations 146-148).'),
        (N'screen.document-acknowledgements',    N'Document Acknowledgements',            N'Admin batches for tracking user acknowledgement of published documents (migrations 150-151).'),
        (N'screen.my-acknowledgements',          N'My Acknowledgements',                  N'Employee inbox for pending document acknowledgements (migration 153).'),
        (N'screen.exception-centre',             N'Exception Centre',                     N'Governance workflow for time-boxed acceptance of gaps (migrations 161-162).'),
        (N'screen.risk-centre',                  N'Risk Centre',                          N'Module for triaging risk candidates raised from gap analysis (migrations 169-172).'),
        (N'screen.org-sla-config',               N'SLA Configuration',                    N'Organization-level adoption of Control Management SLA masters, with warning/escalation thresholds, notify roles, and per-process bindings.'),
        (N'screen.my-notifications',             N'My Notifications',                     N'Recipient inbox for SLA task notifications (migrations 201-203).')
    ) AS s(feature_code, feature_name, description)
    ON t.feature_code = s.feature_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (feature_code, feature_name, description, category, default_enabled, is_active, entered_by)
        VALUES (s.feature_code, s.feature_name, s.description, N'Screen', 0, 1, N'seed-272');
GO

PRINT '272: section E (state machine, tasks, origin, feature flags) done.';
GO

-- =====================================================================
-- SECTION F -- organization assurance lifecycle vocabularies
--   Source: 069, 073, 089, 098, 101, 104
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_status_master','U') IS NULL
    PRINT '272: org_assurance_status_master absent (run 069) -- skipped.';
ELSE
    MERGE grac_practice.org_assurance_status_master AS t
    USING (VALUES
        (N'Draft',       N'Draft',        1, 0),
        (N'UnderReview', N'Under Review', 2, 0),
        (N'Approved',    N'Approved',     3, 0),
        (N'Active',      N'Active',       4, 0),
        (N'Retired',     N'Retired',      5, 1)
    ) AS s(status_code, status_name, display_order, is_terminal)
    ON t.status_code = s.status_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (status_code, status_name, display_order, is_terminal, is_active, entered_by)
        VALUES (s.status_code, s.status_name, s.display_order, s.is_terminal, 1, N'seed-272');
GO

IF OBJECT_ID('grac_practice.org_assurance_scope_dimension_master','U') IS NULL
    PRINT '272: org_assurance_scope_dimension_master absent (run 073) -- skipped.';
ELSE
    MERGE grac_practice.org_assurance_scope_dimension_master AS t
    USING (VALUES
        (N'PRACTICE_CATEGORY', N'Practice Categories', N'Practice',     0,  1),
        (N'PRACTICE_INSTANCE', N'Practice Instances',  N'Practice',     1,  2),
        (N'FRAMEWORK',         N'Frameworks',          N'Compliance',   0,  3),
        (N'REQUIREMENT',       N'Requirements',        N'Compliance',   0,  4),
        (N'OBLIGATION',        N'Obligations',         N'Compliance',   0,  5),
        (N'ASSET_CATEGORY',    N'Asset Categories',    N'Dependency',   0,  6),
        (N'ASSET',             N'Assets',              N'Dependency',   1,  7),
        (N'DEPARTMENT',        N'Departments',         N'Organization', 1,  8),
        (N'BRANCH',            N'Branches',            N'Organization', 0,  9),
        (N'BUSINESS_UNIT',     N'Business Units',      N'Organization', 0, 10),
        (N'VENDOR',            N'Vendors',             N'Dependency',   1, 11),
        (N'VENDOR_SERVICE',    N'Vendor Services',     N'Dependency',   0, 12),
        (N'APPLICATION',       N'Applications',        N'Dependency',   0, 13),
        (N'PRODUCT',           N'Products',            N'Dependency',   0, 14),
        (N'PROCESS',           N'Processes',           N'Dependency',   0, 15),
        (N'RISK',              N'Risks',               N'Risk',         0, 16),
        (N'PEOPLE_ROLE',       N'People Roles',        N'People',       0, 17)
    ) AS s(dimension_code, dimension_name, category, is_pickable, display_order)
    ON t.dimension_code = s.dimension_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (dimension_code, dimension_name, category, is_pickable, display_order, is_active, entered_by)
        VALUES (s.dimension_code, s.dimension_name, s.category, s.is_pickable, s.display_order, 1, N'seed-272');
GO

IF OBJECT_ID('grac_practice.org_assurance_plan_status_master','U') IS NULL
    PRINT '272: org_assurance_plan_status_master absent (run 089) -- skipped.';
ELSE
    MERGE grac_practice.org_assurance_plan_status_master AS t
    USING (VALUES
        (N'Draft',     N'Draft',     1, 0),
        (N'Submitted', N'Submitted', 2, 0),
        (N'Approved',  N'Approved',  3, 0),
        (N'Active',    N'Active',    4, 0),
        (N'Closed',    N'Closed',    5, 1)
    ) AS s(status_code, status_name, display_order, is_terminal)
    ON t.status_code = s.status_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (status_code, status_name, display_order, is_terminal, is_active, entered_by)
        VALUES (s.status_code, s.status_name, s.display_order, s.is_terminal, 1, N'seed-272');
GO

IF OBJECT_ID('grac_practice.org_assurance_execution_status_master','U') IS NULL
    PRINT '272: org_assurance_execution_status_master absent (run 098) -- skipped.';
ELSE
    MERGE grac_practice.org_assurance_execution_status_master AS t
    USING (VALUES
        (N'Planned',    N'Planned',     1, 0),
        (N'InProgress', N'In Progress', 2, 0),
        (N'Submitted',  N'Submitted',   3, 0),
        (N'Reviewed',   N'Reviewed',    4, 0),
        (N'Approved',   N'Approved',    5, 0),
        (N'Closed',     N'Closed',      6, 1),
        (N'Cancelled',  N'Cancelled',   7, 1)
    ) AS s(status_code, status_name, display_order, is_terminal)
    ON t.status_code = s.status_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (status_code, status_name, display_order, is_terminal, is_active, entered_by)
        VALUES (s.status_code, s.status_name, s.display_order, s.is_terminal, 1, N'seed-272');
GO

IF OBJECT_ID('grac_practice.org_assurance_observation_severity_master','U') IS NULL
    PRINT '272: org_assurance_observation_severity_master absent (run 101) -- skipped.';
ELSE
    MERGE grac_practice.org_assurance_observation_severity_master AS t
    USING (VALUES
        (N'Critical',      N'Critical',      1, N'#b91c1c'),
        (N'High',          N'High',          2, N'#ea580c'),
        (N'Medium',        N'Medium',        3, N'#ca8a04'),
        (N'Low',           N'Low',           4, N'#65a30d'),
        (N'Informational', N'Informational', 5, N'#0284c7')
    ) AS s(severity_code, severity_name, display_order, color_hex)
    ON t.severity_code = s.severity_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (severity_code, severity_name, display_order, color_hex, is_active, entered_by)
        VALUES (s.severity_code, s.severity_name, s.display_order, s.color_hex, 1, N'seed-272');
GO

IF OBJECT_ID('grac_practice.org_assurance_observation_status_master','U') IS NULL
    PRINT '272: org_assurance_observation_status_master absent (run 101) -- skipped.';
ELSE
    MERGE grac_practice.org_assurance_observation_status_master AS t
    USING (VALUES
        (N'Open',     N'Open',      1, 0),
        (N'InReview', N'In Review', 2, 0),
        (N'Accepted', N'Accepted',  3, 0),
        (N'Rejected', N'Rejected',  4, 1),
        (N'Resolved', N'Resolved',  5, 0),
        (N'Closed',   N'Closed',    6, 1)
    ) AS s(status_code, status_name, display_order, is_terminal)
    ON t.status_code = s.status_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (status_code, status_name, display_order, is_terminal, is_active, entered_by)
        VALUES (s.status_code, s.status_name, s.display_order, s.is_terminal, 1, N'seed-272');
GO

IF OBJECT_ID('grac_practice.org_assurance_gap_status_master','U') IS NULL
    PRINT '272: org_assurance_gap_status_master absent (run 104) -- skipped.';
ELSE
    MERGE grac_practice.org_assurance_gap_status_master AS t
    USING (VALUES
        (N'Open',                 N'Open',                  1, 0),
        (N'InProgress',           N'In Progress',           2, 0),
        (N'RemediationSubmitted', N'Remediation Submitted', 3, 0),
        (N'Verified',             N'Verified',              4, 0),
        (N'Closed',               N'Closed',                5, 1),
        (N'Reopened',             N'Reopened',              6, 0)
    ) AS s(status_code, status_name, display_order, is_terminal)
    ON t.status_code = s.status_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (status_code, status_name, display_order, is_terminal, is_active, entered_by)
        VALUES (s.status_code, s.status_name, s.display_order, s.is_terminal, 1, N'seed-272');
GO

PRINT '272: section F (organization assurance vocabularies) done.';
GO

-- =====================================================================
-- SECTION G -- document management masters
--   Source: 146 (DDL), 148 (rows). All five carry a NOT NULL
--   record_status_id, so the Active/Inactive ids are resolved first.
--   POLICY_DRIVEN is seeded Inactive on purpose -- the legacy catalog
--   carried it hidden.
-- =====================================================================
IF OBJECT_ID('grac_practice.document_type_master','U') IS NULL
    PRINT '272: document masters absent (run 146) -- section G skipped.';
ELSE
BEGIN
    DECLARE @doc_active_rs   INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
    DECLARE @doc_inactive_rs INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Inactive');

    IF @doc_active_rs IS NULL OR @doc_inactive_rs IS NULL
        RAISERROR('272: record_status_master needs Active and Inactive rows before the document masters can be seeded.', 16, 1);
    ELSE
    BEGIN
        MERGE grac_practice.document_type_master AS t
        USING (VALUES
            (N'POLICY', N'Policy', N'Governing statement of intent adopted by the organization.', 10),
            (N'SOP',    N'SOP',    N'Standard Operating Procedure -- step-by-step operational instructions.', 20)
        ) AS s(type_code, document_type, description, sort_order)
        ON t.type_code = s.type_code
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (type_code, document_type, description, sort_order, status, record_status_id, entered_by)
            VALUES (s.type_code, s.document_type, s.description, s.sort_order, N'Active', @doc_active_rs, N'seed-272');

        MERGE grac_practice.document_stage_master AS t
        USING (VALUES
            (N'Draft',     N'Draft',     N'Document has been created/edited and is awaiting review.', 10),
            (N'Reviewed',  N'Reviewed',  N'Reviewer has signed off; awaiting approver action.',       20),
            (N'Published', N'Published', N'Approver has signed off; document is in force.',           30)
        ) AS s(stage_code, document_stage, description, sort_order)
        ON t.stage_code = s.stage_code
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (stage_code, document_stage, description, sort_order, status, record_status_id, entered_by)
            VALUES (s.stage_code, s.document_stage, s.description, s.sort_order, N'Active', @doc_active_rs, N'seed-272');

        MERGE grac_practice.document_status_master AS t
        USING (VALUES
            (N'Active',  N'Active',  N'Document is in force and visible to distribution.',        10),
            (N'Retired', N'Retired', N'Document is archived; no longer visible to distribution.', 20)
        ) AS s(status_code, document_status, description, sort_order)
        ON t.status_code = s.status_code
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (status_code, document_status, description, sort_order, status, record_status_id, entered_by)
            VALUES (s.status_code, s.document_status, s.description, s.sort_order, N'Active', @doc_active_rs, N'seed-272');

        MERGE grac_practice.document_source_type_master AS t
        USING (VALUES
            (N'UPLOADED',      N'Uploaded',      N'Document was uploaded directly by the organization.', 10, N'Active',   @doc_active_rs),
            (N'POLICY_DRIVEN', N'Policy Driven', N'Document generated from a policy template. Legacy carried status_id=2 (hidden).', 20, N'Inactive', @doc_inactive_rs)
        ) AS s(source_code, source_type, description, sort_order, row_status, row_record_status_id)
        ON t.source_code = s.source_code
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (source_code, source_type, description, sort_order, status, record_status_id, entered_by)
            VALUES (s.source_code, s.source_type, s.description, s.sort_order, s.row_status, s.row_record_status_id, N'seed-272');

        MERGE grac_practice.document_distribution_type_master AS t
        USING (VALUES
            (N'Organization', N'Organization', N'Whole organization -- no distribution rows needed.', 10),
            (N'Departments',  N'Departments',  N'One or more departments in the organization.',       20),
            (N'Users',        N'Users',        N'A hand-picked list of individual employees.',        30)
        ) AS s(distribution_code, distribution_type, description, sort_order)
        ON t.distribution_code = s.distribution_code
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (distribution_code, distribution_type, description, sort_order, status, record_status_id, entered_by)
            VALUES (s.distribution_code, s.distribution_type, s.description, s.sort_order, N'Active', @doc_active_rs, N'seed-272');
    END
END
GO

PRINT '272: section G (document masters) done.';
GO

-- =====================================================================
-- SECTION H -- gap centre lifecycle
--   Source: 156 (DDL), 158 (9 states + 17 transitions), 174 (Delegated
--   state, 3 Delegate transitions, and the deactivation of the 9
--   transitions the collapse retired).
--   gap_lifecycle_transition_master has no updated_by / updated_dt.
-- =====================================================================
IF OBJECT_ID('grac_practice.gap_lifecycle_state_master','U') IS NULL
    PRINT '272: gap_lifecycle_state_master absent (run 156) -- section H skipped.';
ELSE
BEGIN
    DECLARE @gap_active_rs INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    IF @gap_active_rs IS NULL
        RAISERROR('272: record_status_master.Active is missing; gap lifecycle cannot be seeded.', 16, 1);
    ELSE
        MERGE grac_practice.gap_lifecycle_state_master AS t
        USING (VALUES
            (N'New',                N'New',                 N'Gap has just been raised; needs validation.',                                10, 0, 0),
            (N'Validation',         N'Validation',          N'Reviewer confirms the gap is real and in-scope.',                            20, 0, 0),
            (N'Analysis',           N'Analysis',            N'Gap Analysis Engine captures severity, impact, RCA and recommended actions.',30, 0, 0),
            (N'Delegated',          N'Delegated',           N'Analysis saved; downstream tasks / exceptions / risk candidates own remediation from here. Terminal from Gap Centre.', 35, 1, 1),
            (N'ResolutionPlanning', N'Resolution Planning', N'Decision Gateway: plan tasks / exceptions / risk candidates.',               40, 0, 0),
            (N'Execution',          N'Execution',           N'Remediation is being carried out; linked tasks are in flight.',              50, 0, 0),
            (N'Verification',       N'Verification',        N'Remediation complete; verifier confirms closure criteria are met.',          60, 0, 0),
            (N'Closed',             N'Closed',              N'Gap resolved and verified.',                                                 70, 1, 1),
            (N'Invalid',            N'Invalid',             N'Gap was not real / not in scope; withdrawn.',                                80, 1, 0),
            (N'Duplicate',          N'Duplicate',           N'Gap merged into another existing gap.',                                      90, 1, 0)
        ) AS s(state_code, state_name, description, sort_order, is_terminal, is_valid_terminal)
        ON t.state_code = s.state_code
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (state_code, state_name, description, sort_order, is_terminal, is_valid_terminal,
                    status, record_status_id, entered_by)
            VALUES (s.state_code, s.state_name, s.description, s.sort_order, s.is_terminal, s.is_valid_terminal,
                    N'Active', @gap_active_rs, N'seed-272');
END
GO

IF OBJECT_ID('grac_practice.gap_lifecycle_transition_master','U') IS NULL
    PRINT '272: gap_lifecycle_transition_master absent (run 156) -- transitions skipped.';
ELSE
BEGIN
    DECLARE @tr_active_rs INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    ;WITH desired(from_code, to_code, action_code, action_name, description, remark_required) AS (
        SELECT * FROM (VALUES
            (N'New',                N'Validation',         N'Validate',              N'Validate',                N'Confirm the gap is real and in-scope.',                 0),
            (N'New',                N'Invalid',            N'MarkInvalid',           N'Mark Invalid',            N'Reject the gap with a reason.',                         1),
            (N'New',                N'Duplicate',          N'MarkDuplicate',         N'Mark Duplicate',          N'Point at an existing gap this row duplicates.',         1),
            (N'New',                N'Delegated',          N'Delegate',              N'Delegate',                N'Analysis saved -- downstream artefacts own remediation.',0),
            (N'Validation',         N'Analysis',           N'Analyse',               N'Start Analysis',          N'Move into the Gap Analysis Engine.',                    0),
            (N'Validation',         N'Invalid',            N'MarkInvalid',           N'Mark Invalid',            N'Reject after validation.',                              1),
            (N'Validation',         N'Duplicate',          N'MarkDuplicate',         N'Mark Duplicate',          N'Point at an existing gap this row duplicates.',         1),
            (N'Validation',         N'Delegated',          N'Delegate',              N'Delegate',                N'Analysis saved -- downstream artefacts own remediation.',0),
            (N'Analysis',           N'ResolutionPlanning', N'PlanResolution',        N'Plan Resolution',         N'Analysis complete; move to Decision Gateway.',          0),
            (N'Analysis',           N'Validation',         N'SendBackToValidation',  N'Send Back to Validation', N'Analysis found the gap is not in scope; re-validate.',  1),
            (N'Analysis',           N'Invalid',            N'MarkInvalid',           N'Mark Invalid',            N'Reject during analysis.',                               1),
            (N'Analysis',           N'Delegated',          N'Delegate',              N'Delegate',                N'Analysis saved -- downstream artefacts own remediation.',0),
            (N'ResolutionPlanning', N'Execution',          N'StartExecution',        N'Start Execution',         N'Downstream artefacts created; remediation begins.',     0),
            (N'ResolutionPlanning', N'Analysis',           N'SendBackToAnalysis',    N'Send Back to Analysis',   N'Planning found analysis is incomplete.',                1),
            (N'Execution',          N'Verification',       N'SubmitForVerification', N'Submit for Verification', N'Remediation complete; ready for verifier sign-off.',    0),
            (N'Execution',          N'ResolutionPlanning', N'SendBackToPlanning',    N'Send Back to Planning',   N'Execution cannot proceed with the current plan.',       1),
            (N'Verification',       N'Closed',             N'Approve',               N'Close Gap',               N'Verifier approves closure.',                            0),
            (N'Verification',       N'Execution',          N'SendBackToExecution',   N'Send Back to Execution',  N'Verifier rejects; additional remediation needed.',      1),
            (N'Closed',             N'Execution',          N'Reopen',                N'Reopen',                  N'Reopen a closed gap for further remediation.',          1)
        ) v(from_code, to_code, action_code, action_name, description, remark_required)
    )
    INSERT grac_practice.gap_lifecycle_transition_master
        (from_state_id, to_state_id, action_code, action_name, description, remark_required,
         record_status_id, entered_by, entered_dt)
    SELECT f.lifecycle_state_id, x.lifecycle_state_id, d.action_code, d.action_name, d.description, d.remark_required,
           @tr_active_rs, N'seed-272', SYSUTCDATETIME()
      FROM desired d
      JOIN grac_practice.gap_lifecycle_state_master f ON f.state_code = d.from_code
      JOIN grac_practice.gap_lifecycle_state_master x ON x.state_code = d.to_code
     WHERE NOT EXISTS (
            SELECT 1 FROM grac_practice.gap_lifecycle_transition_master t
             WHERE t.from_state_id = f.lifecycle_state_id
               AND t.action_code   = d.action_code);
END
GO

-- The only UPDATE in this script. 174 collapsed the gap lifecycle onto
-- Delegate; these nine actions stay in the master so historical gaps
-- parked in those states remain resolvable, but are hidden from the
-- available-actions list. No-op on a database where 174 already ran.
IF OBJECT_ID('grac_practice.gap_lifecycle_transition_master','U') IS NOT NULL
BEGIN
    DECLARE @gap_inactive_rs INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Inactive');

    IF @gap_inactive_rs IS NOT NULL
        UPDATE grac_practice.gap_lifecycle_transition_master
           SET record_status_id = @gap_inactive_rs
         WHERE record_status_id <> @gap_inactive_rs
           AND action_code IN (
                N'PlanResolution', N'SendBackToValidation', N'SendBackToAnalysis',
                N'StartExecution', N'SendBackToPlanning',   N'SubmitForVerification',
                N'SendBackToExecution', N'Approve', N'Reopen');
END
GO

PRINT '272: section H (gap centre lifecycle) done.';
GO

-- =====================================================================
-- SECTION I -- exception centre and SLA
--   Source: 166, 178. exception_type_master has no updated_by/updated_dt.
-- =====================================================================
IF OBJECT_ID('grac_practice.exception_type_master','U') IS NULL
    PRINT '272: exception_type_master absent (run 166) -- skipped.';
ELSE
    MERGE grac_practice.exception_type_master AS t
    USING (VALUES
        (N'TemporaryInability',   N'Temporary inability to comply', N'Compliance blocked by a transient constraint (staffing gap, tool downtime, etc.). Return to compliance is planned.', 10),
        (N'BusinessAcceptance',   N'Business acceptance',           N'Business consciously accepts the deviation for the exception window.',                                             20),
        (N'CompensatingControl',  N'Compensating control',          N'A different control is in place that mitigates the underlying risk while the primary control is not met.',         30),
        (N'TechnicalLimitation',  N'Technical limitation',          N'Current technology cannot satisfy the control (legacy system, unsupported vendor feature, etc.).',                 40),
        (N'ThirdPartyDependency', N'Third-party dependency',        N'Non-compliance is caused or blocked by an external vendor or partner.',                                            50),
        (N'Other',                N'Other',                         N'Reason not covered by the above categories -- explain in justification.',                                          60)
    ) AS s(exception_type_code, exception_type_name, description, display_order)
    ON t.exception_type_code = s.exception_type_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (exception_type_code, exception_type_name, description, display_order, is_active, entered_by)
        VALUES (s.exception_type_code, s.exception_type_name, s.description, s.display_order, 1, N'seed-272');
GO

IF OBJECT_ID('grac_practice.sla_process_type_master','U') IS NULL
    PRINT '272: sla_process_type_master absent (run 178) -- skipped.';
ELSE
    MERGE grac_practice.sla_process_type_master AS t
    USING (VALUES
        (N'GAP',         N'Gap Analysis',           N'Custom gap lifecycle SLA (target close date driven).',                          N'process_scope_ref_id = custom_gap_id or control_id (optional).',        10),
        (N'TASK',        N'Task',                   N'Practice task engine SLA (task_type_master.default_sla_hours override).',       N'process_scope_ref_id = task_type_id (optional).',                      20),
        (N'OBSERVATION', N'Assurance Observation',  N'Assurance observation resolution SLA.',                                         N'process_scope_ref_id = org_assurance_definition_id (optional).',       30),
        (N'EXCEPTION',   N'Exception',              N'Exception centre response and closure SLA.',                                    N'process_scope_ref_id = exception_type_id (optional).',                 40)
    ) AS s(process_type_code, process_type_name, description, scope_ref_hint, display_order)
    ON t.process_type_code = s.process_type_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (process_type_code, process_type_name, description, scope_ref_hint, display_order, is_active, entered_by)
        VALUES (s.process_type_code, s.process_type_name, s.description, s.scope_ref_hint, s.display_order, 1, N'seed-272');
GO

PRINT '272: section I (exception centre and SLA) done.';
GO

-- =====================================================================
-- SECTION J -- risk masters (global ones only)
--   Source: 204 (risk_source_master), 216 (threat / vulnerability).
--   threat_master and vulnerability_master have a non-IDENTITY PK: id 0
--   is the "Others" escape hatch the assessment form needs. 216 copies
--   the rest from dbo.tbl_threat_mst / dbo.tbl_vulnerability_mst when
--   those legacy tables exist; that copy is NOT repeated here.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_source_master','U') IS NULL
    PRINT '272: risk_source_master absent (run 204) -- skipped.';
ELSE
    MERGE grac_practice.risk_source_master AS t
    USING (VALUES
        (N'Practice',   N'Practice',   N'Risk identified through practice/control evaluation',            N'Practice',         10),
        (N'Assurance',  N'Assurance',  N'Risk identified through assurance activity',                     N'Assurance',        20),
        (N'Gap',        N'Gap',        N'Risk originating from an identified gap',                        N'GapCentre',        30),
        (N'Exception',  N'Exception',  N'Risk arising from an accepted/unresolved exception',             N'ExceptionCentre',  40),
        (N'Obligation', N'Obligation', N'Risk associated with an obligation or regulatory requirement',   N'Obligation',       50),
        (N'Asset',      N'Asset',      N'Risk associated with an asset',                                  N'Asset',            60),
        (N'Vendor',     N'Vendor',     N'Risk associated with a vendor/service',                          N'Vendor',           70),
        (N'Event',      N'Event',      N'Risk triggered by a defined event',                              N'EventAssurance',   80),
        (N'Custom',     N'Custom',     N'Risk directly identified by an authorised user',                 NULL,                90),
        (N'Other',      N'Other',      N'Configurable future source',                                     NULL,               100)
    ) AS s(source_type_code, source_name, description, source_centre_code, display_order)
    ON t.source_type_code = s.source_type_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (source_type_code, source_name, description, source_centre_code,
                is_system, display_order, status, entered_by)
        VALUES (s.source_type_code, s.source_name, s.description, s.source_centre_code,
                1, s.display_order, N'Active', N'seed-272');
GO

IF OBJECT_ID('grac_practice.threat_master','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM grac_practice.threat_master WHERE threat_id = 0)
    INSERT grac_practice.threat_master(threat_id, threat, status_id, entered_by)
    VALUES (0, N'Others', 1, N'seed-272');
GO

IF OBJECT_ID('grac_practice.vulnerability_master','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM grac_practice.vulnerability_master WHERE vulnerability_id = 0)
    INSERT grac_practice.vulnerability_master(vulnerability_id, vulnerability, status_id, entered_by)
    VALUES (0, N'Others', 1, N'seed-272');
GO

PRINT '272: section J (risk masters) done.';
GO

-- =====================================================================
-- SECTION K -- obligation connection types
--   Source: 244. One row today (API); more codes are pure data.
-- =====================================================================
IF OBJECT_ID('grac_practice.connection_type_master','U') IS NULL
    PRINT '272: connection_type_master absent (run 244) -- skipped.';
ELSE
    MERGE grac_practice.connection_type_master AS t
    USING (VALUES
        (N'API', N'API', N'REST or SOAP HTTP endpoint the runtime calls to check assurance.', 10)
    ) AS s(connection_type_code, connection_type_name, description, display_order)
    ON t.connection_type_code = s.connection_type_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (connection_type_code, connection_type_name, description, display_order, is_active, entered_by)
        VALUES (s.connection_type_code, s.connection_type_name, s.description, s.display_order, 1, N'seed-272');
GO

PRINT '272: section K (connection types) done.';
GO

-- =====================================================================
-- SECTION L -- global reference catalogs
--   organization_metadata_definition and reference_option drive the
--   Organization Setup attribute form. Source: 003 / deployment/03.
--   GRAC_New.evidence_type_master is the shared evidence catalog that
--   practice_instance_evidence.evidence_type_id points at.
-- =====================================================================
MERGE grac_practice.organization_metadata_definition AS t
USING (VALUES
    (N'entity_type',                  N'Entity Type',                         N'Lookup',  N'entity-types',                  1),
    (N'deposit_taking_status',        N'Deposit Taking Status',               N'Lookup',  N'yes-no',                        0),
    (N'asset_size_scale',             N'Asset Size / Scale Classification',   N'Lookup',  N'asset-size-scale',              0),
    (N'regulatory_registration_type', N'Regulatory Registration Type',        N'Lookup',  N'regulatory-registration-types', 0),
    (N'payment_aggregator_status',    N'Payment Aggregator Status',           N'Lookup',  N'yes-no',                        0),
    (N'investment_advisor_status',    N'Investment Advisor Status',           N'Lookup',  N'yes-no',                        0),
    (N'cloud_adoption',               N'Cloud Adoption',                      N'Lookup',  N'adoption-levels',               0),
    (N'stores_cardholder_data',       N'Stores Cardholder Data',              N'Boolean', NULL,                             0),
    (N'geographic_presence',          N'Geographic Presence',                 N'Json',    N'countries',                     0),
    (N'business_functions',           N'Business Functions',                  N'Json',    N'business-function-types',       0),
    (N'technology_landscape',         N'Technology Landscape',                N'Json',    N'technology-landscape',          0)
) AS s(metadata_key, metadata_name, data_type, lookup_group, is_required)
ON t.metadata_key = s.metadata_key
WHEN NOT MATCHED BY TARGET THEN
    INSERT (metadata_key, metadata_name, data_type, lookup_group, is_required, status, entered_by)
    VALUES (s.metadata_key, s.metadata_name, s.data_type, s.lookup_group, s.is_required, N'Active', N'seed-272');
GO

MERGE grac_practice.reference_option AS t
USING (VALUES
    (N'entity-types', N'Bank', N'Bank', 1),
    (N'entity-types', N'NBFC', N'NBFC', 2),
    (N'entity-types', N'Insurance', N'Insurance', 3),
    (N'entity-types', N'Fintech', N'Fintech', 4),
    (N'entity-types', N'Payment Aggregator', N'Payment Aggregator', 5),
    (N'entity-types', N'Investment Advisor', N'Investment Advisor', 6),
    (N'entity-types', N'Healthcare', N'Healthcare', 7),
    (N'entity-types', N'Other', N'Other', 99),
    (N'yes-no', N'Yes', N'Yes', 1),
    (N'yes-no', N'No', N'No', 2),
    (N'yes-no', N'Not Applicable', N'Not Applicable', 3),
    (N'asset-size-scale', N'Micro', N'Micro', 1),
    (N'asset-size-scale', N'Small', N'Small', 2),
    (N'asset-size-scale', N'Medium', N'Medium', 3),
    (N'asset-size-scale', N'Large', N'Large', 4),
    (N'asset-size-scale', N'Systemically Important', N'Systemically Important', 5),
    (N'regulatory-registration-types', N'RBI Regulated', N'RBI Regulated', 1),
    (N'regulatory-registration-types', N'SEBI Registered', N'SEBI Registered', 2),
    (N'regulatory-registration-types', N'IRDAI Regulated', N'IRDAI Regulated', 3),
    (N'regulatory-registration-types', N'NPCI Participant', N'NPCI Participant', 4),
    (N'regulatory-registration-types', N'Other', N'Other', 99),
    (N'adoption-levels', N'None', N'None', 1),
    (N'adoption-levels', N'Low', N'Low', 2),
    (N'adoption-levels', N'Moderate', N'Moderate', 3),
    (N'adoption-levels', N'High', N'High', 4),
    (N'business-function-types', N'Information Technology', N'Information Technology', 1),
    (N'business-function-types', N'Operations', N'Operations', 2),
    (N'business-function-types', N'Finance', N'Finance', 3),
    (N'business-function-types', N'Compliance', N'Compliance', 4),
    (N'business-function-types', N'Risk Management', N'Risk Management', 5),
    (N'business-function-types', N'Customer Service', N'Customer Service', 6),
    (N'technology-landscape', N'Core Banking', N'Core Banking', 1),
    (N'technology-landscape', N'Cloud Services', N'Cloud Services', 2),
    (N'technology-landscape', N'Payment Systems', N'Payment Systems', 3),
    (N'technology-landscape', N'Data Warehouse', N'Data Warehouse', 4),
    (N'technology-landscape', N'Identity Platform', N'Identity Platform', 5),
    (N'technology-landscape', N'Endpoint Management', N'Endpoint Management', 6)
) AS s(option_group, option_value, option_label, display_order)
ON t.option_group = s.option_group AND t.option_value = s.option_value
WHEN NOT MATCHED BY TARGET THEN
    INSERT (option_group, option_value, option_label, display_order, status, entered_by)
    VALUES (s.option_group, s.option_value, s.option_label, s.display_order, N'Active', N'seed-272');
GO

IF OBJECT_ID('GRAC_New.evidence_type_master','U') IS NULL
    PRINT '272: GRAC_New.evidence_type_master absent -- shared evidence catalog skipped.';
ELSE
    MERGE GRAC_New.evidence_type_master AS t
    USING (VALUES
        (N'Policy Document',      N'Policy Document',      1),
        (N'Procedure Document',   N'Procedure Document',   2),
        (N'System Screenshot',    N'System Screenshot',    3),
        (N'System Report',        N'System Report',        4),
        (N'Audit Log',            N'Audit Log',            5),
        (N'Approval Record',      N'Approval Record',      6),
        (N'Review Register',      N'Review Register',      7),
        (N'Meeting Minutes',      N'Meeting Minutes',      8),
        (N'Configuration Export', N'Configuration Export', 9),
        (N'Incident Report',      N'Incident Report',     10)
    ) AS s(evidence_type_code, evidence_type_name, display_order)
    ON t.evidence_type_code = s.evidence_type_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (evidence_type_code, evidence_type_name, display_order, is_active, entered_by)
        VALUES (s.evidence_type_code, s.evidence_type_name, s.display_order, 1, N'seed-272');
GO

PRINT '272: section L (global reference catalogs) done.';
GO

-- =====================================================================
-- VERIFICATION
--   Expected = the row count this script guarantees. Actual >= Expected
--   is normal on a database that has extra operator-added rows; Actual <
--   Expected means a table's DDL is missing and its block was skipped.
-- =====================================================================
PRINT '=== 272 verification ===';

DECLARE @expected TABLE(table_name SYSNAME PRIMARY KEY, expected_rows INT);
INSERT @expected(table_name, expected_rows) VALUES
    (N'record_status_master',                       5),
    (N'applicability_status_master',                7),
    (N'subscription_status_master',                 4),
    (N'implementation_status_master',               5),
    (N'operationalization_status_master',           4),
    (N'location_type_master',                       6),
    (N'criticality_master',                         4),
    (N'frequency_master',                           9),
    (N'dependency_type_master',                     9),
    (N'dependency_hosting_type_master',             3),
    (N'dependency_license_type_master',             2),
    (N'dependency_service_category_master',         7),
    (N'dependency_resolution_status_master',        2),
    (N'dependency_asset_category_master',          13),
    (N'dependency_asset_subcategory_master',       17),
    (N'dependency_asset_type_master',              80),
    (N'dependency_type_source_config',              9),
    (N'collection_method_master',                   2),
    (N'assurance_type_master',                      2),
    (N'evidence_alignment_status_master',           6),
    (N'assurance_activity_status_master',           4),
    (N'assurance_result_status_master',             5),
    (N'schedule_override_type_master',              3),
    (N'entity_status_master',                      24),
    (N'task_type_master',                          10),
    (N'origin_type_master',                         2),
    (N'related_entity_type_master',                 9),
    (N'feature_flag_master',                       42),
    (N'org_assurance_status_master',                5),
    (N'org_assurance_scope_dimension_master',      17),
    (N'org_assurance_plan_status_master',           5),
    (N'org_assurance_execution_status_master',      7),
    (N'org_assurance_observation_severity_master',  5),
    (N'org_assurance_observation_status_master',    6),
    (N'org_assurance_gap_status_master',            6),
    (N'document_type_master',                       2),
    (N'document_stage_master',                      3),
    (N'document_status_master',                     2),
    (N'document_source_type_master',                2),
    (N'document_distribution_type_master',          3),
    (N'gap_lifecycle_state_master',                10),
    (N'gap_lifecycle_transition_master',           19),
    (N'exception_type_master',                      6),
    (N'sla_process_type_master',                    4),
    (N'risk_source_master',                        10),
    (N'threat_master',                              1),
    (N'vulnerability_master',                       1),
    (N'connection_type_master',                     1),
    (N'organization_metadata_definition',          11),
    (N'reference_option',                          36);

DECLARE @actual TABLE(table_name SYSNAME PRIMARY KEY, actual_rows INT NULL);
DECLARE @tbl SYSNAME, @sql NVARCHAR(MAX), @cnt INT;

DECLARE table_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name FROM @expected ORDER BY table_name;
OPEN table_cur;
FETCH NEXT FROM table_cur INTO @tbl;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @cnt = NULL;
    IF OBJECT_ID(N'grac_practice.' + QUOTENAME(@tbl), 'U') IS NOT NULL
    BEGIN
        SET @sql = N'SELECT @c = COUNT_BIG(1) FROM grac_practice.' + QUOTENAME(@tbl) + N';';
        EXEC sys.sp_executesql @sql, N'@c INT OUTPUT', @c = @cnt OUTPUT;
    END
    INSERT @actual(table_name, actual_rows) VALUES(@tbl, @cnt);
    FETCH NEXT FROM table_cur INTO @tbl;
END
CLOSE table_cur;
DEALLOCATE table_cur;

SELECT e.table_name       AS Master_,
       e.expected_rows    AS Expected_,
       a.actual_rows      AS Actual_,
       CASE WHEN a.actual_rows IS NULL          THEN 'TABLE MISSING'
            WHEN a.actual_rows >= e.expected_rows THEN 'PASS'
            ELSE 'SHORT' END AS Result_
FROM @expected e
JOIN @actual   a ON a.table_name = e.table_name
ORDER BY CASE WHEN a.actual_rows IS NULL THEN 0
              WHEN a.actual_rows < e.expected_rows THEN 1
              ELSE 2 END,
         e.table_name;

SELECT 'Masters short or missing' AS Check_,
       COUNT(*) AS Count_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'REVIEW' END AS Result_
FROM @expected e
JOIN @actual   a ON a.table_name = e.table_name
WHERE a.actual_rows IS NULL OR a.actual_rows < e.expected_rows;

PRINT '272 consolidated master data seed complete.';
GO

SET NOEXEC OFF;
GO
