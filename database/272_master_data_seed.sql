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
    (N'Committee',   N'Committee',   9),
    (N'Department',  N'Department',  10),  -- added by 385 (Impact Details category)
    (N'BusinessFunction', N'Business Function', 11)   -- added by 386
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
        SELECT N'Committee',   N'grac_practice.organization_committee',              N'committee_id',   N'committee_name',   N'committee_name'   UNION ALL
        SELECT N'Department',  N'grac_practice.organization_department',             N'department_id',  N'department_name',  N'department_name'  UNION ALL  -- added by 385
        SELECT N'BusinessFunction', N'grac_practice.organization_business_function', N'business_function_id', N'function_name', N'function_name'  -- added by 386
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
-- M. Asset field dictionary (owning migration: 420_asset_form_templates)
--    Global masters: dictionary groups, supported data types and the BRD
--    5.1 field definitions. Insert-only, same rows as 420.
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_field_group_master','U') IS NULL
    PRINT '272: asset_field_group_master absent (run 420) -- dictionary groups skipped.';
ELSE
BEGIN
    MERGE grac_practice.asset_field_group_master AS t
    USING (VALUES
        (N'IDENTIFICATION',          N'Identification',                                 N'5.1.1',   10),
        (N'ORGANIZATION_LOCATION',   N'Organization and Location',                      N'5.1.2',   20),
        (N'OWNERSHIP',               N'Ownership and Responsibility',                   N'5.1.3',   30),
        (N'PROCUREMENT_FINANCE',     N'Procurement and Financial Details',              N'5.1.4',   40),
        (N'COMPLIANCE_RISK',         N'Compliance, Risk and Classification',            N'5.1.5',   50),
        (N'TECHNICAL_CYBER',         N'Technical and Cybersecurity Details',            N'5.1.6',   60),
        (N'MAINTENANCE_CALIBRATION', N'Maintenance, Calibration and Equipment Details', N'5.1.7',   70),
        (N'BIOMEDICAL',              N'Biomedical and Clinical Equipment Details',      N'5.1.8',   80),
        (N'VEHICLE',                 N'Vehicle Details',                                N'5.1.9',   90),
        (N'PRIVACY',                 N'Privacy and Personal Data Details',              N'5.1.10', 100),
        (N'CONTRACT_COVERAGE',       N'Contract, Coverage and Service Details',         N'5.1.11', 110),
        (N'DISPOSAL',                N'Disposal and Retirement Details',                N'5.1.12', 120),
        (N'AUDIT_INTEGRATION',       N'Audit and Integration Metadata',                 N'5.1.13', 130),
        (N'CIA_VALUATION',           N'Asset Value and CIA Valuation',                  N'5.1.18', 140)
    ) AS s(group_code, group_name, brd_section, display_order)
    ON t.group_code = s.group_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (group_code, group_name, brd_section, display_order, entered_by)
        VALUES (s.group_code, s.group_name, s.brd_section, s.display_order, N'seed-272');
    PRINT CONCAT('272: dictionary groups inserted: ', @@ROWCOUNT);
END
GO

IF OBJECT_ID('grac_practice.asset_field_data_type_master','U') IS NULL
    PRINT '272: asset_field_data_type_master absent (run 420) -- data types skipped.';
ELSE
BEGIN
    MERGE grac_practice.asset_field_data_type_master AS t
    USING (VALUES
        (N'TEXT',          N'Text',                       1,  10),
        (N'MULTILINE',     N'Multiline text',             1,  20),
        (N'DECIMAL',       N'Number',                     1,  30),
        (N'CURRENCY',      N'Amount and currency',        1,  40),
        (N'PERCENT',       N'Percentage',                 1,  50),
        (N'QUANTITY_UNIT', N'Quantity with unit',         1,  60),
        (N'DATE',          N'Date',                       1,  70),
        (N'DATETIME',      N'Date and time',              0,  80),
        (N'YES_NO',        N'Yes / No',                   1,  90),
        (N'TRI_STATE',     N'Yes / No / third value',     1, 100),
        (N'LOOKUP',        N'Single-select lookup',       1, 110),
        (N'MULTI_SELECT',  N'Multi-select lookup',        1, 120),
        (N'USER',          N'User',                       1, 130),
        (N'MULTI_USER',    N'Multiple users',             1, 140),
        (N'TEAM',          N'Team',                       1, 150),
        (N'USER_OR_TEAM',  N'User or team',               1, 160),
        (N'VENDOR',        N'Vendor',                     1, 170),
        (N'CONTRACT',      N'Contract',                   1, 180),
        (N'MAKE',          N'Asset make',                 1, 190),
        (N'MODEL',         N'Asset model',                1, 200),
        (N'FIRMWARE',      N'Firmware release',           1, 210),
        (N'OS_RELEASE',    N'Operating-system release',   1, 220),
        (N'IP_ADDRESS',    N'IP address',                 1, 230),
        (N'IP_LIST',       N'IP address list',            1, 240),
        (N'ATTACHMENT',    N'Attachment / evidence link', 1, 250),
        (N'APPROVAL_REF',  N'Approval reference',         0, 260),
        (N'AUTO',          N'Auto-generated',             0, 270),
        (N'CALCULATED',    N'Calculated',                 0, 280),
        (N'SYSTEM',        N'System-maintained',          0, 290)
    ) AS s(data_type_code, data_type_name, is_user_entered, display_order)
    ON t.data_type_code = s.data_type_code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (data_type_code, data_type_name, is_user_entered, display_order, entered_by)
        VALUES (s.data_type_code, s.data_type_name, s.is_user_entered, s.display_order, N'seed-272');
    PRINT CONCAT('272: data types inserted: ', @@ROWCOUNT);
END
GO

IF OBJECT_ID('grac_practice.asset_field_definition','U') IS NULL
    PRINT '272: asset_field_definition absent (run 420) -- field definitions skipped.';
ELSE
BEGIN
    MERGE grac_practice.asset_field_definition AS t
    USING (
        SELECT v.field_key, v.display_label, g.field_group_id, v.data_type_code, v.lookup_source,
               v.validation_rule_text, v.description, v.is_system_mandatory, v.is_system_field,
               v.storage_kind, v.column_name, v.sensitivity_code, v.display_order
          FROM (VALUES
        (N'asset_id', N'Asset ID', N'IDENTIFICATION', N'AUTO', NULL, N'Required; unique; read-only', N'System-generated primary identifier for the asset record.', 1, 0, N'COLUMN', N'asset_id', N'INTERNAL', 10),
        (N'asset_name', N'Asset name', N'IDENTIFICATION', N'TEXT', NULL, N'Required; 3-150 characters', N'Clear business-facing name used to identify the asset.', 1, 0, N'COLUMN', N'asset_name', N'INTERNAL', 20),
        (N'main_category', N'Main category', N'IDENTIFICATION', N'LOOKUP', N'MASTER:ASSET_CATEGORY', N'Required; active values only', N'Selects the top-level asset category and drives applicable rules.', 1, 0, N'COLUMN', N'asset_category_id', N'INTERNAL', 30),
        (N'subcategory', N'Subcategory', N'IDENTIFICATION', N'LOOKUP', N'MASTER:ASSET_SUBCATEGORY', N'Required; must belong to main category', N'Provides the next classification level and filters asset types.', 1, 0, N'COLUMN', N'asset_subcategory_id', N'INTERNAL', 40),
        (N'asset_type', N'Asset type', N'IDENTIFICATION', N'LOOKUP', N'MASTER:ASSET_TYPE', N'Required; active values only; must belong to subcategory', N'Defines the specific asset type and applicable field template.', 1, 0, N'COLUMN', N'asset_type_id', N'INTERNAL', 50),
        (N'asset_template', N'Asset template', N'IDENTIFICATION', N'LOOKUP', N'MASTER:ASSET_FORM_TEMPLATE', N'Optional; active templates for selected asset type', N'Applies reusable defaults, checklist mappings and recurrence settings.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
        (N'asset_tag', N'Asset tag', N'IDENTIFICATION', N'TEXT', NULL, N'Required where tagging applies; unique', N'Organization-assigned physical or logical tag.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
        (N'serial_number', N'Serial number', N'IDENTIFICATION', N'TEXT', NULL, N'Format configurable; duplicate warning; uniqueness may be make/model scoped', N'Manufacturer-issued serial number used for traceability.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
        (N'barcode', N'Barcode', N'IDENTIFICATION', N'TEXT', NULL, N'Unique when provided', N'Barcode value used for scanning and inventory operations.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
        (N'qr_code', N'QR code', N'IDENTIFICATION', N'TEXT', NULL, N'Unique; linked to Asset ID', N'QR value generated or recorded for rapid asset lookup.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
        (N'rfid_number', N'RFID number', N'IDENTIFICATION', N'TEXT', NULL, N'Unique when provided', N'RFID tag identifier used for automated tracking.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
        (N'manufacturer_make', N'Manufacturer / Make', N'IDENTIFICATION', N'MAKE', N'MASTER:MAKE', N'Required for manufactured assets; active approved make', N'Identifies the original equipment or product manufacturer.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
        (N'model', N'Model', N'IDENTIFICATION', N'MODEL', N'MASTER:MODEL', N'Required where applicable; must belong to selected make and asset type', N'References the approved model record and lifecycle dates.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
        (N'model_family_series', N'Model family / series', N'IDENTIFICATION', N'CALCULATED', NULL, N'Derived from model; editable only by catalog administrator', N'Groups related models for reporting and lifecycle planning.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 140),
        (N'hardware_revision', N'Hardware revision', N'IDENTIFICATION', N'TEXT', NULL, N'Optional; required where compatibility depends on revision', N'Records chassis, board or hardware revision.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
        (N'version', N'Version', N'IDENTIFICATION', N'TEXT', NULL, N'Optional; configurable format', N'General hardware, software or product version where a catalog object is not applicable.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
        (N'manufacture_date', N'Manufacture date', N'IDENTIFICATION', N'DATE', NULL, N'Cannot be a future date', N'Date on which the asset was manufactured.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
        (N'country_of_origin', N'Country of origin', N'IDENTIFICATION', N'LOOKUP', N'MASTER:COUNTRY', N'Optional; active country values only', N'Country in which the asset or product was manufactured.', 0, 0, N'VALUE', NULL, N'INTERNAL', 180),
        (N'asset_status', N'Asset status', N'IDENTIFICATION', N'LOOKUP', N'STATE:ASSET', N'Required; valid transition only', N'Current lifecycle state controlled by the configured workflow.', 1, 0, N'SYSTEM', NULL, N'INTERNAL', 190),
        (N'record_source', N'Record source', N'IDENTIFICATION', N'LOOKUP', N'OPTION:record_source', N'Required; Manual, Import, Discovery, ERP, API or other configured source', N'Identifies the originating system or process.', 1, 0, N'VALUE', NULL, N'INTERNAL', 200),
        (N'source_record_identifier', N'Source record identifier', N'IDENTIFICATION', N'TEXT', NULL, N'Required for integrated/imported records; unique per source', N'External key used to reconcile and synchronize the asset.', 0, 0, N'VALUE', NULL, N'INTERNAL', 210),
        (N'legal_entity', N'Legal entity', N'ORGANIZATION_LOCATION', N'LOOKUP', N'MASTER:ORGANIZATION', N'Required; authorized active entities only', N'Identifies the legal entity that owns or controls the asset.', 1, 0, N'COLUMN', N'organization_id', N'INTERNAL', 10),
        (N'business_unit', N'Business unit', N'ORGANIZATION_LOCATION', N'LOOKUP', N'MASTER:DIVISION', N'Required; must belong to legal entity', N'Maps the asset to the responsible business unit.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
        (N'department', N'Department', N'ORGANIZATION_LOCATION', N'LOOKUP', N'MASTER:DEPARTMENT', N'Required; active department belonging to business unit', N'Identifies the department using or managing the asset.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
        (N'cost_centre', N'Cost centre', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:cost_centre', N'Valid active finance code', N'Links acquisition and operating costs to the responsible cost centre.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
        (N'process_supported', N'Process supported', N'ORGANIZATION_LOCATION', N'MULTI_SELECT', N'MASTER:PROCESS', N'At least one value for critical assets', N'Links the asset to supported business or operational processes.', 0, 0, N'VALUE', NULL, N'INTERNAL', 50),
        (N'service_supported', N'Service supported', N'ORGANIZATION_LOCATION', N'MULTI_SELECT', N'OPTION:service_supported', N'Recommended for service-related assets', N'Links the asset to business or technology services.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
        (N'site', N'Site', N'ORGANIZATION_LOCATION', N'LOOKUP', N'MASTER:LOCATION', N'Required for physical assets; active sites only', N'Specifies the site where the asset is located.', 0, 0, N'COLUMN', N'location_id', N'INTERNAL', 70),
        (N'building', N'Building', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:building', N'Must belong to selected site', N'Identifies the building containing the asset.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
        (N'floor', N'Floor', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:floor', N'Must belong to selected building', N'Identifies the applicable floor.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
        (N'room', N'Room', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:room', N'Must belong to selected floor', N'Identifies the room or controlled area.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
        (N'rack', N'Rack', N'ORGANIZATION_LOCATION', N'TEXT', NULL, N'Required for rack-mounted equipment', N'Records rack identifier.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
        (N'cabinet_bay', N'Cabinet / Bay', N'ORGANIZATION_LOCATION', N'TEXT', NULL, N'Required where applicable', N'Records cabinet, bay or enclosure.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
        (N'production_line', N'Production line', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:production_line', N'Required for line-specific manufacturing assets', N'Identifies the production line supported by the asset.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
        (N'clinical_area', N'Clinical area', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:clinical_area', N'Required for clinical/biomedical assets where applicable', N'Identifies ICU, ward, theatre, radiology, laboratory or other clinical area.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
        (N'zone', N'Zone', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:zone', N'Optional; must belong to selected site/location', N'Records safety, security, environmental or operational zone.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
        (N'exact_installation_location', N'Exact installation location', N'ORGANIZATION_LOCATION', N'MULTILINE', NULL, N'Required for fixed equipment', N'Records rack unit, bay, bed, line position, coordinates or precise location.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
        (N'location_type', N'Location type', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:location_type', N'Required; Physical, Virtual, Mobile, Cloud or other configured value', N'Determines applicable location and mobility controls.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
        (N'mobility_status', N'Mobility status', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:mobility_status', N'Required for portable/mobile assets', N'Indicates fixed, portable, mobile, pool or temporarily assigned status.', 0, 0, N'VALUE', NULL, N'INTERNAL', 180),
        (N'storage_location', N'Storage location', N'ORGANIZATION_LOCATION', N'LOOKUP', N'MASTER:LOCATION', N'Required when lifecycle status is In Storage', N'Identifies the controlled storage location.', 0, 0, N'VALUE', NULL, N'INTERNAL', 190),
        (N'business_owner', N'Business owner', N'OWNERSHIP', N'USER', N'MASTER:EMPLOYEE', N'Required for business- critical assets; active user', N'Accountable business representative for value and use.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
        (N'asset_owner', N'Asset owner', N'OWNERSHIP', N'USER', N'MASTER:EMPLOYEE', N'Required; active user', N'Person accountable for lifecycle, risk and compliance.', 1, 0, N'COLUMN', N'owner_id', N'INTERNAL', 20),
        (N'technical_owner', N'Technical owner', N'OWNERSHIP', N'USER_OR_TEAM', N'MASTER:EMPLOYEE_OR_TEAM', N'Required for technical assets', N'Responsible for technical configuration and support.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
        (N'custodian', N'Custodian', N'OWNERSHIP', N'USER_OR_TEAM', N'MASTER:EMPLOYEE_OR_TEAM', N'Required when custody is assigned', N'Responsible for day-to-day possession and safeguarding.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
        (N'operator', N'Operator', N'OWNERSHIP', N'MULTI_USER', N'MASTER:EMPLOYEE', N'Active and authorized users only', N'Lists personnel authorized to operate the asset.', 0, 0, N'VALUE', NULL, N'INTERNAL', 50),
        (N'maintenance_owner', N'Maintenance owner', N'OWNERSHIP', N'USER_OR_TEAM', N'MASTER:EMPLOYEE_OR_TEAM', N'Required when maintenance is applicable', N'Accountable for maintenance planning and completion.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
        (N'calibration_owner', N'Calibration owner', N'OWNERSHIP', N'USER_OR_TEAM', N'MASTER:EMPLOYEE_OR_TEAM', N'Required when calibration is applicable', N'Accountable for calibration scheduling, evidence and closure.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
        (N'compliance_owner', N'Compliance owner', N'OWNERSHIP', N'USER', N'MASTER:EMPLOYEE', N'Required for regulated or controlled assets', N'Monitors applicable obligations, evidence and exceptions.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
        (N'privacy_owner', N'Privacy owner', N'OWNERSHIP', N'USER', N'MASTER:EMPLOYEE', N'Required when personal data is processed', N'Accountable for privacy assessment and safeguards.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
        (N'information_security_owner', N'Information security owner', N'OWNERSHIP', N'USER_OR_TEAM', N'MASTER:EMPLOYEE_OR_TEAM', N'Required for security-critical assets', N'Accountable for security baseline, monitoring and remediation.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
        (N'vendor', N'Vendor', N'OWNERSHIP', N'VENDOR', N'MASTER:VENDOR', N'Approved and active vendor only', N'Identifies the supplying or contracted vendor.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
        (N'service_provider', N'Service provider', N'OWNERSHIP', N'VENDOR', N'MASTER:VENDOR', N'Required for externally supported assets', N'Identifies the organization providing support or managed service.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
        (N'support_group', N'Support group', N'OWNERSHIP', N'TEAM', N'MASTER:TEAM', N'Required for supported operational assets', N'Team responsible for incident, request and maintenance handling.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
        (N'assignment_start_date', N'Assignment start date', N'OWNERSHIP', N'DATE', NULL, N'Cannot be after assignment end date', N'Effective date for the current ownership or custody assignment.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
        (N'assignment_end_date', N'Assignment end date', N'OWNERSHIP', N'DATE', NULL, N'Optional; must follow assignment start date', N'End date retained in ownership history.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
        (N'acquisition_method', N'Acquisition method', N'PROCUREMENT_FINANCE', N'LOOKUP', N'OPTION:acquisition_method', N'Required; Purchase, Lease, Rental, Donation, Transfer, Subscription or configured value', N'Defines how the asset was acquired.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 10),
        (N'purchase_date', N'Purchase date', N'PROCUREMENT_FINANCE', N'DATE', NULL, N'Cannot be a future date', N'Date the asset was purchased or contractually acquired.', 0, 0, N'COLUMN', N'purchase_dt', N'CONFIDENTIAL', 20),
        (N'purchase_order_number', N'Purchase order number', N'PROCUREMENT_FINANCE', N'TEXT', NULL, N'Required for purchased assets; valid reference', N'Links the asset to the approved purchase order.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 30),
        (N'invoice_number', N'Invoice number', N'PROCUREMENT_FINANCE', N'TEXT', NULL, N'Required where invoiced; duplicate warning', N'Supplier invoice reference for financial traceability.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 40),
        (N'purchase_cost', N'Purchase cost', N'PROCUREMENT_FINANCE', N'CURRENCY', NULL, N'Non-negative; currency required', N'Original acquisition cost, with tax treatment defined by configuration.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 50),
        (N'currency', N'Currency', N'PROCUREMENT_FINANCE', N'LOOKUP', N'MASTER:CURRENCY', N'Required when cost is entered; ISO currency code', N'Currency used for purchase and financial reporting.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 60),
        (N'capex_opex', N'CapEx / OpEx', N'PROCUREMENT_FINANCE', N'LOOKUP', N'OPTION:capex_opex', N'Required; approved values only', N'Classifies the financial treatment of expenditure.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 70),
        (N'capitalization_date', N'Capitalization date', N'PROCUREMENT_FINANCE', N'DATE', NULL, N'Required for capitalized assets; not before purchase date unless approved', N'Date the asset enters the fixed-asset register.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 80),
        (N'finance_asset_number', N'Finance asset number', N'PROCUREMENT_FINANCE', N'TEXT', NULL, N'Unique when provided', N'Fixed-asset identifier in the finance/ERP system.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 90),
        (N'warranty_start_date', N'Warranty start date', N'PROCUREMENT_FINANCE', N'DATE', NULL, N'Must be on or before warranty expiry', N'Date from which warranty coverage begins.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 100),
        (N'warranty_expiry_date', N'Warranty expiry date', N'PROCUREMENT_FINANCE', N'DATE', NULL, N'Must be after warranty start date', N'Triggers expiry notifications and renewal or support review.', 0, 0, N'COLUMN', N'warranty_expiry_dt', N'CONFIDENTIAL', 110),
        (N'expected_useful_life', N'Expected useful life', N'PROCUREMENT_FINANCE', N'QUANTITY_UNIT', NULL, N'Positive value; category default allowed', N'Expected operational life used for planning and depreciation.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 120),
        (N'depreciation_method', N'Depreciation method', N'PROCUREMENT_FINANCE', N'LOOKUP', N'OPTION:depreciation_method', N'Required for capitalized assets', N'Defines the approved accounting depreciation method.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 130),
        (N'depreciation_rate', N'Depreciation rate', N'PROCUREMENT_FINANCE', N'PERCENT', NULL, N'Non-negative; required when method uses a rate', N'Rate applied by the selected depreciation method.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 140),
        (N'residual_value', N'Residual value', N'PROCUREMENT_FINANCE', N'CURRENCY', NULL, N'Non-negative; cannot exceed purchase cost', N'Estimated value remaining at the end of useful life.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 150),
        (N'lease_rental_start_date', N'Lease / rental start date', N'PROCUREMENT_FINANCE', N'DATE', NULL, N'Required for leased/rented assets', N'Start date of lease or rental possession.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 160),
        (N'lease_rental_end_date', N'Lease / rental end date', N'PROCUREMENT_FINANCE', N'DATE', NULL, N'Must follow start date', N'Triggers return, renewal or purchase-option workflow.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 170),
        (N'budget_owner', N'Budget owner', N'PROCUREMENT_FINANCE', N'USER', N'MASTER:EMPLOYEE', N'Required where configured', N'Person accountable for budget and renewal decisions.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 180),
        (N'applicable_standards', N'Applicable standards', N'COMPLIANCE_RISK', N'MULTI_SELECT', N'MASTER:PRACTICE', N'Active frameworks, obligations and practices only', N'Links the asset to applicable standards, regulations and practices.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
        (N'risk_classification', N'Risk classification', N'COMPLIANCE_RISK', N'LOOKUP', N'OPTION:risk_classification', N'Required; approved risk scale', N'Sets the asset risk level and drives control frequency.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
        (N'criticality', N'Criticality', N'COMPLIANCE_RISK', N'LOOKUP', N'MASTER:CRITICALITY', N'Required; approved criticality scale', N'Rates business, operational, safety or service impact.', 1, 0, N'COLUMN', N'criticality_id', N'INTERNAL', 30),
        (N'confidentiality_classification', N'Confidentiality classification', N'COMPLIANCE_RISK', N'LOOKUP', N'OPTION:confidentiality_classification', N'Required for information-processing assets', N'Defines protection required against unauthorized disclosure.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
        (N'integrity_requirement', N'Integrity requirement', N'COMPLIANCE_RISK', N'LOOKUP', N'OPTION:integrity_requirement', N'Required for information-processing assets', N'Defines tolerance for unauthorized or accidental modification.', 0, 0, N'VALUE', NULL, N'INTERNAL', 50),
        (N'availability_requirement', N'Availability requirement', N'COMPLIANCE_RISK', N'LOOKUP', N'OPTION:availability_requirement', N'Required for service-supporting assets', N'Defines uptime, recovery and continuity expectations.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
        (N'personal_data_processed', N'Personal data processed', N'COMPLIANCE_RISK', N'TRI_STATE', N'OPTION:yes_no_unknown', N'Required', N'Yes or Unknown triggers privacy fields, assessment and controls.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
        (N'special_category_or_health_data_processed', N'Special-category or health data processed', N'COMPLIANCE_RISK', N'TRI_STATE', N'OPTION:yes_no_unknown', N'Required when personal data processed is Yes/Unknown', N'Triggers enhanced privacy and security requirements.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
        (N'children_data_processed', N'Children data processed', N'COMPLIANCE_RISK', N'TRI_STATE', N'OPTION:yes_no_unknown', N'Required when personal data processed is Yes/Unknown', N'Triggers child-data and consent/authorization review.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
        (N'environmental_impact', N'Environmental impact', N'COMPLIANCE_RISK', N'MULTI_SELECT', N'OPTION:environmental_impact', N'Required for assets with environmental aspects', N'Records energy, emissions, waste, spill or resource impacts.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
        (N'safety_hazard', N'Safety hazard', N'COMPLIANCE_RISK', N'MULTI_SELECT', N'OPTION:safety_hazard', N'Required for machinery and safety-relevant assets', N'Identifies hazards and drives inspections and controls.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
        (N'patient_safety_impact', N'Patient safety impact', N'COMPLIANCE_RISK', N'LOOKUP', N'OPTION:patient_safety_impact', N'Required for clinical or biomedical assets', N'Classifies potential impact on patient safety and care.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
        (N'calibration_required', N'Calibration required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'When Yes, calibration schedule and evidence fields become mandatory.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
        (N'preventive_maintenance_required', N'Preventive maintenance required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'When Yes, maintenance schedule fields become mandatory.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
        (N'statutory_inspection_required', N'Statutory inspection required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'Triggers statutory inspection schedules and evidence.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
        (N'certification_required', N'Certification required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'Triggers certificate tracking, expiry and renewal workflow.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
        (N'licence_required', N'Licence required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'Triggers licence details, expiry alerts and use restrictions.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
        (N'insurance_required', N'Insurance required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'Triggers insurance policy and expiry management.', 0, 0, N'VALUE', NULL, N'INTERNAL', 180),
        (N'amc_required', N'AMC required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'Triggers annual maintenance contract coverage tracking.', 0, 0, N'VALUE', NULL, N'INTERNAL', 190),
        (N'cmc_required', N'CMC required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'Triggers comprehensive maintenance contract coverage tracking.', 0, 0, N'VALUE', NULL, N'INTERNAL', 200),
        (N'exception_status', N'Exception status', N'COMPLIANCE_RISK', N'LOOKUP', N'OPTION:exception_status', N'Controlled values; approval required for Approved', N'Records whether the asset operates under an approved exception.', 0, 0, N'VALUE', NULL, N'INTERNAL', 210),
        (N'exception_expiry_date', N'Exception expiry date', N'COMPLIANCE_RISK', N'DATE', NULL, N'Required for approved time-bound exceptions', N'Triggers reminders, escalation and reassessment.', 0, 0, N'VALUE', NULL, N'INTERNAL', 220),
        (N'compliance_status', N'Compliance status', N'COMPLIANCE_RISK', N'CALCULATED', NULL, N'System-calculated; manual override requires approval', N'Overall compliance result derived from applicable tasks, evidence and exceptions.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 230),
        (N'operating_system', N'Operating system', N'TECHNICAL_CYBER', N'OS_RELEASE', N'MASTER:OS_RELEASE', N'Required for computing assets; approved compatible values', N'References operating-system family, edition, version and lifecycle record.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
        (N'os_build_patch_level', N'OS build / patch level', N'TECHNICAL_CYBER', N'TEXT', NULL, N'Format configurable; required where OS applies', N'Records installed build and patch level.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
        (N'firmware_version', N'Firmware version', N'TECHNICAL_CYBER', N'FIRMWARE', N'MASTER:FIRMWARE', N'Required where firmware applies; approved compatible values', N'References installed firmware and lifecycle record.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
        (N'bios_uefi_version', N'BIOS / UEFI version', N'TECHNICAL_CYBER', N'TEXT', NULL, N'Required for managed computing assets where applicable', N'Records platform firmware version.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
        (N'ip_address', N'IP address', N'TECHNICAL_CYBER', N'IP_ADDRESS', NULL, N'Valid IPv4 or IPv6; duplicate warning', N'Records assigned network address.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 50),
        (N'secondary_ip_addresses', N'Secondary IP addresses', N'TECHNICAL_CYBER', N'IP_LIST', NULL, N'Valid IPv4/IPv6; duplicate warning', N'Records additional interfaces or addresses.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 60),
        (N'mac_address', N'MAC address', N'TECHNICAL_CYBER', N'TEXT', NULL, N'Valid MAC format; duplicate warning', N'Records physical network-interface address.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 70),
        (N'hostname', N'Hostname', N'TECHNICAL_CYBER', N'TEXT', NULL, N'Valid naming convention; unique within domain', N'Network hostname used for discovery and management.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 80),
        (N'domain', N'Domain', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:domain', N'Approved directory or DNS domain values only', N'Identifies domain association.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
        (N'installed_software', N'Installed software', N'TECHNICAL_CYBER', N'MULTI_SELECT', N'OPTION:installed_software', N'Approved catalogue values; discovery sync allowed', N'Lists installed applications for licence and security review.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
        (N'encryption_status', N'Encryption status', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:encryption_status', N'Required for data-storing assets', N'Records whether required encryption is enabled, partial, disabled or unknown.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
        (N'encryption_method', N'Encryption method', N'TECHNICAL_CYBER', N'MULTI_SELECT', N'OPTION:encryption_method', N'Required when encryption status is enabled/partial', N'Records disk, file, database, application or transport encryption.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
        (N'antivirus_status', N'Antivirus status', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:antivirus_status', N'Required for supported endpoints and servers', N'Records deployment, health and reporting state.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
        (N'edr_xdr_status', N'EDR/XDR status', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:edr_xdr_status', N'Required for supported endpoints and servers', N'Records endpoint detection and response onboarding and health.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
        (N'backup_requirement', N'Backup requirement', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:backup_requirement', N'Required for data-bearing or service assets', N'Defines backup requirement and policy tier.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
        (N'backup_status', N'Backup status', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:backup_status', N'Required when backup is required', N'Records success, failure, not configured or unknown state.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
        (N'recovery_tier_rto', N'Recovery tier / RTO', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:recovery_tier_rto', N'Required for critical service assets', N'Defines recovery time expectation.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
        (N'rpo', N'RPO', N'TECHNICAL_CYBER', N'QUANTITY_UNIT', NULL, N'Required where backup/recovery applies', N'Defines maximum acceptable data-loss period.', 0, 0, N'VALUE', NULL, N'INTERNAL', 180),
        (N'network_zone', N'Network zone', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:network_zone', N'Approved zones only', N'Maps asset to network security segment.', 0, 0, N'VALUE', NULL, N'INTERNAL', 190),
        (N'internet_exposure', N'Internet exposure', N'TECHNICAL_CYBER', N'TRI_STATE', N'OPTION:yes_no_unknown', N'Required for network-connected assets', N'Indicates direct or indirect public exposure.', 0, 0, N'VALUE', NULL, N'INTERNAL', 200),
        (N'remote_access_enabled', N'Remote access enabled', N'TECHNICAL_CYBER', N'YES_NO', NULL, N'Required; approval reference when Yes', N'Indicates whether remote administrative or user access is permitted.', 0, 0, N'VALUE', NULL, N'INTERNAL', 210),
        (N'remote_access_method', N'Remote access method', N'TECHNICAL_CYBER', N'MULTI_SELECT', N'OPTION:remote_access_method', N'Required when remote access enabled', N'Records VPN, ZTNA, RDP gateway, vendor tunnel or other method.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 220),
        (N'privileged_access_present', N'Privileged access present', N'TECHNICAL_CYBER', N'YES_NO', NULL, N'Required for managed technical assets', N'Indicates whether privileged credentials or administration exist.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 230),
        (N'mfa_required', N'MFA required', N'TECHNICAL_CYBER', N'YES_NO', NULL, N'Required when remote or privileged access exists', N'Defines authentication requirement.', 0, 0, N'VALUE', NULL, N'INTERNAL', 240),
        (N'logging_monitoring_required', N'Logging / monitoring required', N'TECHNICAL_CYBER', N'YES_NO', NULL, N'Required for security-relevant assets', N'Determines monitoring onboarding and evidence requirements.', 0, 0, N'VALUE', NULL, N'INTERNAL', 250),
        (N'log_source_monitoring_identifier', N'Log source / monitoring identifier', N'TECHNICAL_CYBER', N'TEXT', NULL, N'Required when logging is enabled', N'Links the asset to SIEM, monitoring or telemetry source.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 260),
        (N'vulnerability_scanning_applicable', N'Vulnerability scanning applicable', N'TECHNICAL_CYBER', N'YES_NO', NULL, N'Required for technical assets', N'Determines vulnerability assessment scope.', 0, 0, N'VALUE', NULL, N'INTERNAL', 270),
        (N'last_vulnerability_scan_date', N'Last vulnerability scan date', N'TECHNICAL_CYBER', N'DATE', NULL, N'Cannot be future date', N'Latest completed scan date.', 0, 0, N'VALUE', NULL, N'INTERNAL', 280),
        (N'data_storage_capability', N'Data storage capability', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:data_storage_capability', N'Required', N'Identifies whether and how the asset stores business or personal data.', 0, 0, N'VALUE', NULL, N'INTERNAL', 290),
        (N'cloud_resource_identifier', N'Cloud resource identifier', N'TECHNICAL_CYBER', N'TEXT', NULL, N'Unique per cloud tenant/subscription when provided', N'Stores resource ID or ARN for cloud assets.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 300),
        (N'integration_identifier', N'Integration identifier', N'TECHNICAL_CYBER', N'TEXT', NULL, N'Unique per source system and asset', N'Stores external-system key used for synchronization.', 0, 0, N'VALUE', NULL, N'INTERNAL', 310),
        (N'calibration_frequency', N'Calibration frequency', N'MAINTENANCE_CALIBRATION', N'QUANTITY_UNIT', NULL, N'Required when calibration required; positive value', N'Defines interval used to calculate calibration due dates.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
        (N'calibration_basis', N'Calibration basis', N'MAINTENANCE_CALIBRATION', N'LOOKUP', N'OPTION:calibration_basis', N'Required when calibration required', N'Scheduled date, approved completion date, usage or manufacturer basis.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
        (N'last_calibration_date', N'Last calibration date', N'MAINTENANCE_CALIBRATION', N'DATE', NULL, N'Cannot be a future date', N'Date of latest approved calibration activity.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
        (N'next_calibration_date', N'Next calibration date', N'MAINTENANCE_CALIBRATION', N'CALCULATED', NULL, N'Must follow last calibration date; override requires approval', N'Calculated from approved date and configured frequency.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 40),
        (N'calibration_status', N'Calibration status', N'MAINTENANCE_CALIBRATION', N'CALCULATED', NULL, N'System calculated; override controlled', N'N/A, Valid, Due Soon, Overdue or Failed.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 50),
        (N'calibration_certificate_number', N'Calibration certificate number', N'MAINTENANCE_CALIBRATION', N'TEXT', NULL, N'Required after successful calibration; unique where applicable', N'Certificate reference for traceability.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
        (N'calibration_certificate_expiry', N'Calibration certificate expiry', N'MAINTENANCE_CALIBRATION', N'DATE', NULL, N'Must follow certificate issue date', N'Drives evidence-expiry notifications.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
        (N'calibration_service_provider', N'Calibration service provider', N'MAINTENANCE_CALIBRATION', N'VENDOR', N'MASTER:VENDOR', N'Approved provider only', N'Organization performing calibration.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
        (N'maintenance_frequency', N'Maintenance frequency', N'MAINTENANCE_CALIBRATION', N'QUANTITY_UNIT', NULL, N'Required when maintenance required; positive value', N'Defines preventive maintenance interval.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
        (N'maintenance_basis', N'Maintenance basis', N'MAINTENANCE_CALIBRATION', N'LOOKUP', N'OPTION:maintenance_basis', N'Required when maintenance required', N'Calendar, completion date, usage, run-hours or manufacturer basis.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
        (N'last_maintenance_date', N'Last maintenance date', N'MAINTENANCE_CALIBRATION', N'DATE', NULL, N'Cannot be a future date', N'Date of latest approved maintenance activity.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
        (N'next_maintenance_date', N'Next maintenance date', N'MAINTENANCE_CALIBRATION', N'CALCULATED', NULL, N'Must follow last maintenance date; override requires approval', N'Calculated from approved date and frequency.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 120),
        (N'maintenance_status', N'Maintenance status', N'MAINTENANCE_CALIBRATION', N'CALCULATED', NULL, N'System calculated', N'Not Due, Due Soon, Overdue, In Progress or Completed.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 130),
        (N'usage_meter_type', N'Usage meter type', N'MAINTENANCE_CALIBRATION', N'LOOKUP', N'OPTION:usage_meter_type', N'Required for usage-based equipment', N'Odometer, run-hours, cycles, production quantity or configured unit.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
        (N'current_meter_reading', N'Current meter reading', N'MAINTENANCE_CALIBRATION', N'DECIMAL', NULL, N'Non-negative; cannot be lower than previous reading without approved reset', N'Current usage value for scheduling.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
        (N'measurement_range', N'Measurement range', N'MAINTENANCE_CALIBRATION', N'TEXT', NULL, N'Minimum cannot exceed maximum; unit required', N'Certified operating or measurement range.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
        (N'accuracy', N'Accuracy', N'MAINTENANCE_CALIBRATION', N'TEXT', NULL, N'Unit or percentage required', N'Specified measurement accuracy.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
        (N'tolerance', N'Tolerance', N'MAINTENANCE_CALIBRATION', N'TEXT', NULL, N'Unit or percentage required', N'Permitted process or measurement tolerance.', 0, 0, N'VALUE', NULL, N'INTERNAL', 180),
        (N'operating_instructions', N'Operating instructions', N'MAINTENANCE_CALIBRATION', N'ATTACHMENT', NULL, N'Required for controlled equipment', N'Links approved operating instructions or manufacturer manual.', 0, 0, N'VALUE', NULL, N'INTERNAL', 190),
        (N'safety_instructions', N'Safety instructions', N'MAINTENANCE_CALIBRATION', N'ATTACHMENT', NULL, N'Required where safety hazards exist', N'Links approved safe-use, shutdown and emergency instructions.', 0, 0, N'VALUE', NULL, N'INTERNAL', 200),
        (N'equipment_licence_number', N'Equipment licence number', N'MAINTENANCE_CALIBRATION', N'TEXT', NULL, N'Required when licence is required; unique as applicable', N'Regulatory or operational equipment licence reference.', 0, 0, N'VALUE', NULL, N'INTERNAL', 210),
        (N'equipment_licence_expiry', N'Equipment licence expiry', N'MAINTENANCE_CALIBRATION', N'DATE', NULL, N'Required when licence has validity period', N'Triggers licence renewal and restriction workflow.', 0, 0, N'VALUE', NULL, N'INTERNAL', 220),
        (N'inspection_frequency', N'Inspection frequency', N'MAINTENANCE_CALIBRATION', N'QUANTITY_UNIT', NULL, N'Required when statutory inspection required', N'Defines recurring inspection interval.', 0, 0, N'VALUE', NULL, N'INTERNAL', 230),
        (N'last_inspection_date', N'Last inspection date', N'MAINTENANCE_CALIBRATION', N'DATE', NULL, N'Cannot be future date', N'Date of latest approved inspection.', 0, 0, N'VALUE', NULL, N'INTERNAL', 240),
        (N'next_inspection_date', N'Next inspection date', N'MAINTENANCE_CALIBRATION', N'CALCULATED', NULL, N'Must follow last inspection date; override controlled', N'Drives inspection tasks and reminders.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 250),
        (N'biomedical_device_class', N'Biomedical device class', N'BIOMEDICAL', N'LOOKUP', N'OPTION:biomedical_device_class', N'Required for regulated biomedical equipment; configured jurisdiction values', N'Regulatory device classification.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
        (N'clinical_department', N'Clinical department', N'BIOMEDICAL', N'LOOKUP', N'MASTER:DEPARTMENT', N'Required for deployed clinical equipment', N'Department accountable for clinical use.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
        (N'patient_use_classification', N'Patient-use classification', N'BIOMEDICAL', N'LOOKUP', N'OPTION:patient_use_classification', N'Required for biomedical equipment', N'Classifies direct patient use, diagnostic, monitoring, therapeutic or support use.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
        (N'patient_safety_classification', N'Patient safety classification', N'BIOMEDICAL', N'LOOKUP', N'OPTION:patient_safety_classification', N'Required; approved scale', N'Critical, High, Medium or Low patient-safety impact.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
        (N'life_support_equipment', N'Life-support equipment', N'BIOMEDICAL', N'YES_NO', NULL, N'Required', N'Identifies equipment essential to sustaining life.', 0, 0, N'VALUE', NULL, N'INTERNAL', 50),
        (N'electrical_safety_category', N'Electrical safety category', N'BIOMEDICAL', N'LOOKUP', N'OPTION:electrical_safety_category', N'Required where electrical safety applies', N'Records approved electrical safety class/category.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
        (N'electrical_safety_test_required', N'Electrical safety test required', N'BIOMEDICAL', N'YES_NO', NULL, N'Required', N'Triggers test frequency and evidence.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
        (N'last_electrical_safety_test', N'Last electrical safety test', N'BIOMEDICAL', N'DATE', NULL, N'Cannot be future date', N'Date of most recent approved electrical safety test.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
        (N'next_electrical_safety_test', N'Next electrical safety test', N'BIOMEDICAL', N'CALCULATED', NULL, N'Must follow last test', N'Drives recurring safety test task.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 90),
        (N'sterilization_disinfection_required', N'Sterilization / disinfection required', N'BIOMEDICAL', N'YES_NO', NULL, N'Required for reusable patient-contact equipment', N'Triggers decontamination controls and evidence.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
        (N'sterilization_method', N'Sterilization method', N'BIOMEDICAL', N'MULTI_SELECT', N'OPTION:sterilization_method', N'Required when sterilization is required', N'Approved sterilization or disinfection method.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
        (N'biomedical_engineer', N'Biomedical engineer', N'BIOMEDICAL', N'USER_OR_TEAM', N'MASTER:EMPLOYEE_OR_TEAM', N'Required for maintained biomedical assets', N'Responsible biomedical engineering contact.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
        (N'oem_service_authorization_required', N'OEM service authorization required', N'BIOMEDICAL', N'YES_NO', NULL, N'Required', N'Controls assignment to approved service providers.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
        (N'medical_gas_connection', N'Medical gas connection', N'BIOMEDICAL', N'LOOKUP', N'OPTION:medical_gas_connection', N'Required where medical gas is used', N'Records oxygen, air, vacuum or other connection.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
        (N'software_as_medical_device_component', N'Software as medical device component', N'BIOMEDICAL', N'YES_NO', NULL, N'Required where embedded/standalone clinical software applies', N'Triggers software lifecycle and validation controls. clinical software applies', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
        (N'validation_status', N'Validation status', N'BIOMEDICAL', N'LOOKUP', N'OPTION:validation_status', N'Required for validated clinical equipment', N'Not Validated, Valid, Due, Failed or Conditional.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
        (N'recall_status', N'Recall status', N'BIOMEDICAL', N'LOOKUP', N'OPTION:recall_status', N'Controlled values', N'None, Under Review, Recalled, Corrective Action or Closed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
        (N'condemnation_category', N'Condemnation category', N'BIOMEDICAL', N'LOOKUP', N'OPTION:condemnation_category', N'Required when condemnation is initiated', N'Reason and classification for retirement/condemnation.', 0, 0, N'VALUE', NULL, N'INTERNAL', 180),
        (N'registration_number', N'Registration number', N'VEHICLE', N'TEXT', NULL, N'Required; valid regional format; unique', N'Official vehicle registration identifier.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
        (N'registration_date', N'Registration date', N'VEHICLE', N'DATE', NULL, N'Cannot be future date', N'Date vehicle was registered.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
        (N'registration_expiry', N'Registration expiry', N'VEHICLE', N'DATE', NULL, N'Must follow registration date where applicable', N'Triggers renewal notifications and restricted-use rules.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
        (N'chassis_vin', N'Chassis / VIN', N'VEHICLE', N'TEXT', NULL, N'Required; unique; format configurable', N'Manufacturer vehicle identification number.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
        (N'engine_motor_number', N'Engine / motor number', N'VEHICLE', N'TEXT', NULL, N'Required where applicable; unique', N'Engine or traction-motor identifier.', 0, 0, N'VALUE', NULL, N'INTERNAL', 50),
        (N'insurance_policy_number', N'Insurance policy number', N'VEHICLE', N'TEXT', NULL, N'Required when insurance required', N'Links vehicle to insurance policy or contract.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
        (N'insurance_expiry', N'Insurance expiry', N'VEHICLE', N'DATE', NULL, N'Required when insurance required', N'Triggers renewal and compliance status updates.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
        (N'fitness_certificate_number', N'Fitness certificate number', N'VEHICLE', N'TEXT', NULL, N'Required where legally applicable', N'Statutory fitness certificate reference.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
        (N'fitness_certificate_expiry', N'Fitness certificate expiry', N'VEHICLE', N'DATE', NULL, N'Required where legally applicable', N'Tracks statutory fitness validity and renewal.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
        (N'pollution_certificate_number', N'Pollution certificate number', N'VEHICLE', N'TEXT', NULL, N'Required where legally applicable', N'Emissions certificate reference.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
        (N'pollution_certificate_expiry', N'Pollution certificate expiry', N'VEHICLE', N'DATE', NULL, N'Required where legally applicable', N'Tracks emissions certificate validity.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
        (N'permit_number', N'Permit number', N'VEHICLE', N'TEXT', NULL, N'Required for permit-controlled vehicles', N'Operational or jurisdictional permit reference.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
        (N'permit_expiry', N'Permit expiry', N'VEHICLE', N'DATE', NULL, N'Required for permit-controlled vehicles', N'Tracks permit validity.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
        (N'road_tax_expiry', N'Road tax expiry', N'VEHICLE', N'DATE', NULL, N'Required where applicable', N'Tracks road-tax validity.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
        (N'fuel_type', N'Fuel type', N'VEHICLE', N'LOOKUP', N'OPTION:fuel_type', N'Required; approved values only', N'Petrol, diesel, electric, hybrid, gas or other fuel type.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
        (N'battery_capacity', N'Battery capacity', N'VEHICLE', N'QUANTITY_UNIT', NULL, N'Required for electric/hybrid assets where applicable', N'Rated traction-battery capacity.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
        (N'assigned_driver', N'Assigned driver', N'VEHICLE', N'USER', N'MASTER:EMPLOYEE', N'Active user with valid authorization', N'Current authorized driver.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
        (N'driver_licence_expiry', N'Driver licence expiry', N'VEHICLE', N'CALCULATED', NULL, N'Required when driver is assigned', N'Used to validate driver authorization.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 180),
        (N'odometer_reading', N'Odometer reading', N'VEHICLE', N'DECIMAL', NULL, N'Non-negative; cannot be lower than previous reading', N'Current distance used for usage-based servicing.', 0, 0, N'VALUE', NULL, N'INTERNAL', 190),
        (N'odometer_unit', N'Odometer unit', N'VEHICLE', N'LOOKUP', N'OPTION:odometer_unit', N'Required; km or miles', N'Unit for distance readings.', 0, 0, N'VALUE', NULL, N'INTERNAL', 200),
        (N'service_interval', N'Service interval', N'VEHICLE', N'QUANTITY_UNIT', NULL, N'Positive value; distance or time unit required', N'Defines next vehicle service trigger.', 0, 0, N'VALUE', NULL, N'INTERNAL', 210),
        (N'last_service_date', N'Last service date', N'VEHICLE', N'DATE', NULL, N'Cannot be future date', N'Date of latest approved service.', 0, 0, N'VALUE', NULL, N'INTERNAL', 220),
        (N'next_service_due', N'Next service due', N'VEHICLE', N'CALCULATED', NULL, N'Must follow last date/reading', N'Next service date or odometer threshold.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 230),
        (N'telematics_identifier', N'Telematics identifier', N'VEHICLE', N'TEXT', NULL, N'Unique when provided', N'Links vehicle to tracking or telematics platform.', 0, 0, N'VALUE', NULL, N'INTERNAL', 240),
        (N'fuel_card_number', N'Fuel card number', N'VEHICLE', N'TEXT', NULL, N'Unique; restricted visibility', N'Links vehicle to fuel-card control.', 0, 0, N'VALUE', NULL, N'RESTRICTED', 250),
        (N'dpdp_applicable', N'DPDP applicable', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_assessment', N'Required for digital personal-data assets', N'Records India DPDP applicability assessment.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 10),
        (N'gdpr_applicable', N'GDPR applicable', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_assessment', N'Required where EU personal data may be processed', N'Records GDPR applicability assessment.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 20),
        (N'privacy_assessment_status', N'Privacy assessment status', N'PRIVACY', N'LOOKUP', N'OPTION:privacy_assessment_status', N'Required when personal data is Yes/Unknown', N'Not Assessed, Pending, Approved, Conditional or Non-Compliant.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 30),
        (N'personal_data_categories', N'Personal data categories', N'PRIVACY', N'MULTI_SELECT', N'OPTION:personal_data_categories', N'Required when personal data processed', N'Name, contact, identifier, financial, health, biometric, location and configured categories.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 40),
        (N'data_subject_categories', N'Data subject categories', N'PRIVACY', N'MULTI_SELECT', N'OPTION:data_subject_categories', N'Required when personal data processed', N'Employees, customers, patients, vendors, visitors, children and other subjects.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 50),
        (N'processing_operations', N'Processing operations', N'PRIVACY', N'MULTI_SELECT', N'OPTION:processing_operations', N'Required when personal data processed', N'Store, process, receive, generate, display, transmit, back up or delete.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 60),
        (N'processing_activity', N'Processing activity', N'PRIVACY', N'LOOKUP', N'OPTION:processing_activity', N'Required when personal data processed', N'Links asset to the relevant processing activity/register.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 70),
        (N'processing_purpose', N'Processing purpose', N'PRIVACY', N'MULTILINE', NULL, N'Required when personal data processed', N'Approved purpose for the supported processing.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 80),
        (N'high_risk_processing', N'High-risk processing', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_assessment', N'Required', N'Flags processing requiring enhanced assessment.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 90),
        (N'dpia_pia_required', N'DPIA / PIA required', N'PRIVACY', N'YES_NO', NULL, N'Required for applicable privacy assets', N'Determines formal assessment workflow.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 100),
        (N'dpia_pia_status', N'DPIA / PIA status', N'PRIVACY', N'LOOKUP', N'OPTION:dpia_pia_status', N'Required when assessment is required', N'Not Started, In Progress, Approved, Rejected or Expired.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 110),
        (N'masking_applicable', N'Masking applicable', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_assessment', N'Required when personal data processed', N'Determines whether masking control is required.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 120),
        (N'masking_implemented', N'Masking implemented', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_partial', N'Required when masking applicable', N'Records implementation status.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 130),
        (N'masking_method', N'Masking method', N'PRIVACY', N'MULTI_SELECT', N'OPTION:masking_method', N'Required when implemented/partial', N'Static, Dynamic, Tokenization, Pseudonymization, Anonymization, Partial Mask, Redaction, Obfuscation, Encryption-based or Custom.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 140),
        (N'masking_coverage', N'Masking coverage', N'PRIVACY', N'MULTI_SELECT', N'OPTION:masking_coverage', N'Required when masking applies', N'Production, non-production, reports, exports, logs and backups.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 150),
        (N'encryption_required', N'Encryption required', N'PRIVACY', N'YES_NO', NULL, N'Required when personal data processed', N'Defines encryption control requirement.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 160),
        (N'encryption_implemented', N'Encryption implemented', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_partial', N'Required when encryption required', N'Records implementation status and drives privacy compliance.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 170),
        (N'retention_policy', N'Retention policy', N'PRIVACY', N'LOOKUP', N'OPTION:retention_policy', N'Required when personal data processed', N'Links approved retention schedule.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 180),
        (N'retention_period', N'Retention period', N'PRIVACY', N'QUANTITY_UNIT', NULL, N'Required when retention applies; positive value', N'Duration for retaining personal data.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 190),
        (N'retention_trigger', N'Retention trigger', N'PRIVACY', N'LOOKUP', N'OPTION:retention_trigger', N'Required when retention applies', N'Creation, closure, employment end, contract end, last activity or configured trigger.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 200),
        (N'auto_purge_enabled', N'Auto-purge enabled', N'PRIVACY', N'YES_NO', NULL, N'Required where supported', N'Indicates automated deletion or archival.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 210),
        (N'legal_hold_status', N'Legal hold status', N'PRIVACY', N'YES_NO', NULL, N'Required', N'Prevents deletion while approved legal hold is active.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 220),
        (N'third_party_access', N'Third-party access', N'PRIVACY', N'YES_NO', NULL, N'Required', N'Indicates processor/vendor access to personal data.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 230),
        (N'processor_third_party', N'Processor / third party', N'PRIVACY', N'VENDOR', N'MASTER:VENDOR', N'Required when third-party access is Yes', N'Identifies external processor or recipient.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 240),
        (N'cross_border_transfer', N'Cross-border transfer', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_assessment', N'Required when third party or external hosting applies', N'Triggers country and transfer-control assessment.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 250),
        (N'transfer_countries', N'Transfer countries', N'PRIVACY', N'MULTI_SELECT', N'MASTER:COUNTRY', N'Required when cross-border transfer is Yes', N'Countries where data is transferred or accessed.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 260),
        (N'deletion_sanitization_required', N'Deletion / sanitization required', N'PRIVACY', N'YES_NO', NULL, N'Required for personal-data-bearing assets', N'Triggers disposal privacy controls.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 270),
        (N'privacy_review_date', N'Privacy review date', N'PRIVACY', N'DATE', NULL, N'Required when privacy applies', N'Next scheduled privacy review.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 280),
        (N'residual_privacy_risk', N'Residual privacy risk', N'PRIVACY', N'LOOKUP', N'OPTION:residual_privacy_risk', N'Required after privacy assessment', N'Approved residual-risk level.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 290),
        (N'primary_support_contract', N'Primary support contract', N'CONTRACT_COVERAGE', N'CONTRACT', N'MASTER:CONTRACT', N'Required when contract coverage exists', N'Links the asset to its primary warranty, support, AMC or CMC agreement.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
        (N'coverage_type', N'Coverage type', N'CONTRACT_COVERAGE', N'LOOKUP', N'OPTION:coverage_type', N'Required with contract mapping', N'Warranty, AMC, CMC, licence, insurance, calibration, managed service or custom.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
        (N'coverage_start_date', N'Coverage start date', N'CONTRACT_COVERAGE', N'DATE', NULL, N'Must not follow coverage end date', N'Asset-specific coverage start.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
        (N'coverage_end_date', N'Coverage end date', N'CONTRACT_COVERAGE', N'DATE', NULL, N'Must follow coverage start date', N'Drives expiry and uncovered status.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
        (N'coverage_status', N'Coverage status', N'CONTRACT_COVERAGE', N'CALCULATED', NULL, N'System calculated', N'Covered, Expiring, Expired, Uncovered, Suspended or Excluded.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 50),
        (N'entitlement_sku', N'Entitlement / SKU', N'CONTRACT_COVERAGE', N'TEXT', NULL, N'Required where entitlement applies', N'Purchased service or licence entitlement.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
        (N'service_level', N'Service level', N'CONTRACT_COVERAGE', N'LOOKUP', N'OPTION:service_level', N'Must be valid for selected contract', N'Applicable service tier or SLA.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
        (N'support_hours', N'Support hours', N'CONTRACT_COVERAGE', N'TEXT', NULL, N'Optional', N'Applicable support window.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
        (N'contract_exclusion_reason', N'Contract exclusion reason', N'CONTRACT_COVERAGE', N'MULTILINE', NULL, N'Required when coverage status is Excluded', N'Explains why asset is not covered.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
        (N'vendor_support_reference', N'Vendor support reference', N'CONTRACT_COVERAGE', N'TEXT', NULL, N'Optional', N'Vendor portal, entitlement or service reference.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
        (N'decommission_request_date', N'Decommission request date', N'DISPOSAL', N'DATE', NULL, N'Required when retirement initiated', N'Date retirement workflow began.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
        (N'decommission_reason', N'Decommission reason', N'DISPOSAL', N'LOOKUP', N'OPTION:decommission_reason', N'Required', N'Obsolete, unsupported, damaged, replaced, lost, sold or configured reason.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
        (N'dependency_review_completed', N'Dependency review completed', N'DISPOSAL', N'YES_NO', NULL, N'Required before disposal approval', N'Confirms service, contract, data and integration dependencies reviewed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
        (N'data_backup_retention_decision', N'Data backup / retention decision', N'DISPOSAL', N'LOOKUP', N'OPTION:data_backup_retention_decision', N'Required for data-bearing assets', N'Retain, migrate, archive, delete or not applicable.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
        (N'sanitization_required', N'Sanitization required', N'DISPOSAL', N'YES_NO', NULL, N'Required', N'Determines secure erasure or media destruction workflow.', 0, 0, N'VALUE', NULL, N'INTERNAL', 50),
        (N'sanitization_method', N'Sanitization method', N'DISPOSAL', N'LOOKUP', N'OPTION:sanitization_method', N'Required when sanitization required', N'Clear, purge, cryptographic erase, degauss, physical destruction or approved method.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
        (N'sanitization_date', N'Sanitization date', N'DISPOSAL', N'DATE', NULL, N'Cannot be future date', N'Date sanitization completed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
        (N'sanitization_evidence', N'Sanitization evidence', N'DISPOSAL', N'ATTACHMENT', NULL, N'Required when sanitization required', N'Certificate, tool log or verification evidence.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
        (N'licence_access_revoked', N'Licence/access revoked', N'DISPOSAL', N'YES_NO', NULL, N'Required for technical/software assets', N'Confirms access, certificates and entitlements removed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
        (N'disposal_method', N'Disposal method', N'DISPOSAL', N'LOOKUP', N'OPTION:disposal_method', N'Required', N'Return, resale, donation, recycle, scrap, destroy or transfer.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
        (N'disposal_vendor', N'Disposal vendor', N'DISPOSAL', N'VENDOR', N'MASTER:VENDOR', N'Required for third-party disposal', N'Approved disposal/recycling vendor.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
        (N'disposal_certificate_number', N'Disposal certificate number', N'DISPOSAL', N'TEXT', NULL, N'Required where certificate issued', N'Certificate reference.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
        (N'disposal_date', N'Disposal date', N'DISPOSAL', N'DATE', NULL, N'Cannot precede approval date', N'Date physical or logical disposal completed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
        (N'final_approval', N'Final approval', N'DISPOSAL', N'APPROVAL_REF', NULL, N'Required before Disposed status', N'Authorized disposal approval.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
        (N'archive_date', N'Archive date', N'DISPOSAL', N'DATE', NULL, N'Must be on or after disposal date', N'Date record moved to archived lifecycle status.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
        (N'created_by', N'Created by', N'AUDIT_INTEGRATION', N'SYSTEM', NULL, N'Required; read-only', N'User or integration that created the record.', 0, 1, N'COLUMN', N'entered_by', N'INTERNAL', 10),
        (N'created_date_time', N'Created date/time', N'AUDIT_INTEGRATION', N'DATETIME', NULL, N'Required; read-only', N'Record creation timestamp in tenant time zone/UTC storage.', 0, 1, N'COLUMN', N'entered_dt', N'INTERNAL', 20),
        (N'last_modified_by', N'Last modified by', N'AUDIT_INTEGRATION', N'SYSTEM', NULL, N'Required; read-only', N'Actor responsible for latest change.', 0, 1, N'COLUMN', N'updated_by', N'INTERNAL', 30),
        (N'last_modified_date_time', N'Last modified date/time', N'AUDIT_INTEGRATION', N'DATETIME', NULL, N'Required; read-only', N'Latest modification timestamp.', 0, 1, N'COLUMN', N'updated_dt', N'INTERNAL', 40),
        (N'record_version', N'Record version', N'AUDIT_INTEGRATION', N'SYSTEM', NULL, N'Required; incremented on change', N'Supports optimistic concurrency and audit reconstruction.', 0, 1, N'SYSTEM', NULL, N'INTERNAL', 50),
        (N'approval_status', N'Approval status', N'AUDIT_INTEGRATION', N'LOOKUP', N'OPTION:approval_status', N'Controlled by workflow', N'Draft, Submitted, Pending Approval, Approved, Rejected or Returned.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
        (N'data_confidence', N'Data confidence', N'AUDIT_INTEGRATION', N'LOOKUP', N'OPTION:data_confidence', N'Required for discovered/imported data', N'Verified, Probable, Unverified, Stale or Conflicting.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
        (N'last_verified_date', N'Last verified date', N'AUDIT_INTEGRATION', N'DATE', NULL, N'Required for governed catalog/critical data', N'Date record was last validated.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
        (N'verified_by', N'Verified by', N'AUDIT_INTEGRATION', N'USER', N'MASTER:EMPLOYEE', N'Required when verified', N'Accountable verifier.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
        (N'sync_status', N'Sync status', N'AUDIT_INTEGRATION', N'LOOKUP', N'OPTION:sync_status', N'Required for integrated records', N'Not Applicable, Pending, Synchronized, Warning or Failed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
        (N'last_synchronization_time', N'Last synchronization time', N'AUDIT_INTEGRATION', N'DATETIME', NULL, N'Read-only for integrations', N'Latest successful or attempted synchronization.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
        (N'import_batch_job_id', N'Import batch / job ID', N'AUDIT_INTEGRATION', N'TEXT', NULL, N'Required for imported records', N'Links record to import and per-record result.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
        (N'audit_event_count_link', N'Audit event count / link', N'AUDIT_INTEGRATION', N'CALCULATED', NULL, N'Read-only', N'Opens immutable event history.', 0, 1, N'SYSTEM', NULL, N'INTERNAL', 130),
        (N'confidentiality_rating', N'Confidentiality Rating', N'CIA_VALUATION', N'LOOKUP', N'CONFIG:CIA_SCALE', N'Required for information-processing assets', N'Impact if information is disclosed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
        (N'integrity_rating', N'Integrity Rating', N'CIA_VALUATION', N'LOOKUP', N'CONFIG:CIA_SCALE', N'Required for information-processing assets', N'Impact if information or process is altered.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
        (N'availability_rating', N'Availability Rating', N'CIA_VALUATION', N'LOOKUP', N'CONFIG:CIA_SCALE', N'Required for information-processing assets', N'Impact if unavailable when required.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
        (N'asset_valuation_method', N'Asset Valuation Method', N'CIA_VALUATION', N'LOOKUP', N'OPTION:asset_valuation_method', N'Required for information-processing assets', N'Maximum, Weighted Average or Summation.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
        (N'asset_value_score', N'Asset Value Score', N'CIA_VALUATION', N'CALCULATED', NULL, N'System-calculated; read-only', N'Calculated CIA-based score.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 50),
        (N'asset_value_category', N'Asset Value Category', N'CIA_VALUATION', N'CALCULATED', NULL, N'System-calculated; read-only', N'Low, Medium, High or Critical.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 60),
        (N'amc_expiry_date', N'AMC expiry date (legacy)', N'CONTRACT_COVERAGE', N'DATE', NULL, N'Optional', N'Carried from the original Assets tab (organization_dependency_asset.amc_expiry_dt). Superseded by contract coverage records in Phase 5; kept so existing values stay visible.', 0, 0, N'COLUMN', N'amc_expiry_dt', N'INTERNAL', 900),
        (N'remarks', N'Remarks', N'IDENTIFICATION', N'MULTILINE', NULL, N'Optional', N'Carried from the original Assets tab (organization_dependency_asset.remarks).', 0, 0, N'COLUMN', N'remarks', N'INTERNAL', 900)
          ) AS v(field_key, display_label, group_code, data_type_code, lookup_source,
                 validation_rule_text, description, is_system_mandatory, is_system_field,
                 storage_kind, column_name, sensitivity_code, display_order)
          JOIN grac_practice.asset_field_group_master g ON g.group_code = v.group_code
    ) AS s
    ON t.field_key = s.field_key
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (field_key, display_label, field_group_id, data_type_code, lookup_source,
                validation_rule_text, description, is_system_mandatory, is_system_field,
                storage_kind, column_name, sensitivity_code, display_order, entered_by)
        VALUES (s.field_key, s.display_label, s.field_group_id, s.data_type_code, s.lookup_source,
                s.validation_rule_text, s.description, s.is_system_mandatory, s.is_system_field,
                s.storage_kind, s.column_name, s.sensitivity_code, s.display_order, N'seed-272');
    PRINT CONCAT('272: field definitions inserted: ', @@ROWCOUNT);
END
GO

PRINT '272: section M (asset field dictionary) done.';
GO

-- =====================================================================
-- N. Asset field option lists (owning migration: 421_asset_form_rules)
--    reference_option rows in groups 'asset_field.<list>' -- the values
--    the BRD enumerates. Insert-only, same rows as 421.
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_field_definition','U') IS NULL
    PRINT '272: asset field dictionary absent (run 420/421) -- asset option lists skipped.';
ELSE
BEGIN
    MERGE grac_practice.reference_option AS t
    USING (VALUES
        (N'asset_field.record_source', N'MANUAL', N'Manual', 10),
        (N'asset_field.record_source', N'IMPORT', N'Import', 20),
        (N'asset_field.record_source', N'DISCOVERY', N'Discovery', 30),
        (N'asset_field.record_source', N'ERP', N'ERP', 40),
        (N'asset_field.record_source', N'API', N'API', 50),
        (N'asset_field.location_type', N'PHYSICAL', N'Physical', 10),
        (N'asset_field.location_type', N'VIRTUAL', N'Virtual', 20),
        (N'asset_field.location_type', N'MOBILE', N'Mobile', 30),
        (N'asset_field.location_type', N'CLOUD', N'Cloud', 40),
        (N'asset_field.mobility_status', N'FIXED', N'Fixed', 10),
        (N'asset_field.mobility_status', N'PORTABLE', N'Portable', 20),
        (N'asset_field.mobility_status', N'MOBILE', N'Mobile', 30),
        (N'asset_field.mobility_status', N'POOL', N'Pool', 40),
        (N'asset_field.mobility_status', N'TEMPORARILY_ASSIGNED', N'Temporarily Assigned', 50),
        (N'asset_field.acquisition_method', N'PURCHASE', N'Purchase', 10),
        (N'asset_field.acquisition_method', N'LEASE', N'Lease', 20),
        (N'asset_field.acquisition_method', N'RENTAL', N'Rental', 30),
        (N'asset_field.acquisition_method', N'DONATION', N'Donation', 40),
        (N'asset_field.acquisition_method', N'TRANSFER', N'Transfer', 50),
        (N'asset_field.acquisition_method', N'SUBSCRIPTION', N'Subscription', 60),
        (N'asset_field.capex_opex', N'CAPEX', N'CapEx', 10),
        (N'asset_field.capex_opex', N'OPEX', N'OpEx', 20),
        (N'asset_field.yes_no_unknown', N'YES', N'Yes', 10),
        (N'asset_field.yes_no_unknown', N'NO', N'No', 20),
        (N'asset_field.yes_no_unknown', N'UNKNOWN', N'Unknown', 30),
        (N'asset_field.yes_no_assessment', N'YES', N'Yes', 10),
        (N'asset_field.yes_no_assessment', N'NO', N'No', 20),
        (N'asset_field.yes_no_assessment', N'UNDER_ASSESSMENT', N'Under Assessment', 30),
        (N'asset_field.yes_no_partial', N'YES', N'Yes', 10),
        (N'asset_field.yes_no_partial', N'NO', N'No', 20),
        (N'asset_field.yes_no_partial', N'PARTIALLY', N'Partially', 30),
        (N'asset_field.environmental_impact', N'ENERGY', N'Energy', 10),
        (N'asset_field.environmental_impact', N'EMISSIONS', N'Emissions', 20),
        (N'asset_field.environmental_impact', N'WASTE', N'Waste', 30),
        (N'asset_field.environmental_impact', N'SPILL', N'Spill', 40),
        (N'asset_field.environmental_impact', N'RESOURCE', N'Resource', 50),
        (N'asset_field.encryption_status', N'ENABLED', N'Enabled', 10),
        (N'asset_field.encryption_status', N'PARTIAL', N'Partial', 20),
        (N'asset_field.encryption_status', N'DISABLED', N'Disabled', 30),
        (N'asset_field.encryption_status', N'UNKNOWN', N'Unknown', 40),
        (N'asset_field.encryption_method', N'DISK', N'Disk', 10),
        (N'asset_field.encryption_method', N'FILE', N'File', 20),
        (N'asset_field.encryption_method', N'DATABASE', N'Database', 30),
        (N'asset_field.encryption_method', N'APPLICATION', N'Application', 40),
        (N'asset_field.encryption_method', N'TRANSPORT', N'Transport', 50),
        (N'asset_field.backup_status', N'SUCCESS', N'Success', 10),
        (N'asset_field.backup_status', N'FAILURE', N'Failure', 20),
        (N'asset_field.backup_status', N'NOT_CONFIGURED', N'Not Configured', 30),
        (N'asset_field.backup_status', N'UNKNOWN', N'Unknown', 40),
        (N'asset_field.remote_access_method', N'VPN', N'VPN', 10),
        (N'asset_field.remote_access_method', N'ZTNA', N'ZTNA', 20),
        (N'asset_field.remote_access_method', N'RDP_GATEWAY', N'RDP Gateway', 30),
        (N'asset_field.remote_access_method', N'VENDOR_TUNNEL', N'Vendor Tunnel', 40),
        (N'asset_field.remote_access_method', N'OTHER', N'Other', 50),
        (N'asset_field.calibration_basis', N'SCHEDULED_DATE', N'Scheduled Date', 10),
        (N'asset_field.calibration_basis', N'APPROVED_COMPLETION_DATE', N'Approved Completion Date', 20),
        (N'asset_field.calibration_basis', N'USAGE', N'Usage', 30),
        (N'asset_field.calibration_basis', N'MANUFACTURER', N'Manufacturer', 40),
        (N'asset_field.maintenance_basis', N'CALENDAR', N'Calendar', 10),
        (N'asset_field.maintenance_basis', N'COMPLETION_DATE', N'Completion Date', 20),
        (N'asset_field.maintenance_basis', N'USAGE', N'Usage', 30),
        (N'asset_field.maintenance_basis', N'RUN_HOURS', N'Run-hours', 40),
        (N'asset_field.maintenance_basis', N'MANUFACTURER', N'Manufacturer', 50),
        (N'asset_field.usage_meter_type', N'ODOMETER', N'Odometer', 10),
        (N'asset_field.usage_meter_type', N'RUN_HOURS', N'Run-hours', 20),
        (N'asset_field.usage_meter_type', N'CYCLES', N'Cycles', 30),
        (N'asset_field.usage_meter_type', N'PRODUCTION_QUANTITY', N'Production Quantity', 40),
        (N'asset_field.patient_use_classification', N'DIRECT_PATIENT_USE', N'Direct Patient Use', 10),
        (N'asset_field.patient_use_classification', N'DIAGNOSTIC', N'Diagnostic', 20),
        (N'asset_field.patient_use_classification', N'MONITORING', N'Monitoring', 30),
        (N'asset_field.patient_use_classification', N'THERAPEUTIC', N'Therapeutic', 40),
        (N'asset_field.patient_use_classification', N'SUPPORT', N'Support', 50),
        (N'asset_field.patient_safety_classification', N'CRITICAL', N'Critical', 10),
        (N'asset_field.patient_safety_classification', N'HIGH', N'High', 20),
        (N'asset_field.patient_safety_classification', N'MEDIUM', N'Medium', 30),
        (N'asset_field.patient_safety_classification', N'LOW', N'Low', 40),
        (N'asset_field.medical_gas_connection', N'OXYGEN', N'Oxygen', 10),
        (N'asset_field.medical_gas_connection', N'AIR', N'Air', 20),
        (N'asset_field.medical_gas_connection', N'VACUUM', N'Vacuum', 30),
        (N'asset_field.medical_gas_connection', N'OTHER', N'Other', 40),
        (N'asset_field.validation_status', N'NOT_VALIDATED', N'Not Validated', 10),
        (N'asset_field.validation_status', N'VALID', N'Valid', 20),
        (N'asset_field.validation_status', N'DUE', N'Due', 30),
        (N'asset_field.validation_status', N'FAILED', N'Failed', 40),
        (N'asset_field.validation_status', N'CONDITIONAL', N'Conditional', 50),
        (N'asset_field.recall_status', N'NONE', N'None', 10),
        (N'asset_field.recall_status', N'UNDER_REVIEW', N'Under Review', 20),
        (N'asset_field.recall_status', N'RECALLED', N'Recalled', 30),
        (N'asset_field.recall_status', N'CORRECTIVE_ACTION', N'Corrective Action', 40),
        (N'asset_field.recall_status', N'CLOSED', N'Closed', 50),
        (N'asset_field.fuel_type', N'PETROL', N'Petrol', 10),
        (N'asset_field.fuel_type', N'DIESEL', N'Diesel', 20),
        (N'asset_field.fuel_type', N'ELECTRIC', N'Electric', 30),
        (N'asset_field.fuel_type', N'HYBRID', N'Hybrid', 40),
        (N'asset_field.fuel_type', N'GAS', N'Gas', 50),
        (N'asset_field.fuel_type', N'OTHER', N'Other', 60),
        (N'asset_field.odometer_unit', N'KM', N'km', 10),
        (N'asset_field.odometer_unit', N'MILES', N'miles', 20),
        (N'asset_field.privacy_assessment_status', N'NOT_ASSESSED', N'Not Assessed', 10),
        (N'asset_field.privacy_assessment_status', N'PENDING', N'Pending', 20),
        (N'asset_field.privacy_assessment_status', N'APPROVED', N'Approved', 30),
        (N'asset_field.privacy_assessment_status', N'CONDITIONAL', N'Conditional', 40),
        (N'asset_field.privacy_assessment_status', N'NON_COMPLIANT', N'Non-Compliant', 50),
        (N'asset_field.personal_data_categories', N'NAME', N'Name', 10),
        (N'asset_field.personal_data_categories', N'CONTACT', N'Contact', 20),
        (N'asset_field.personal_data_categories', N'IDENTIFIER', N'Identifier', 30),
        (N'asset_field.personal_data_categories', N'FINANCIAL', N'Financial', 40),
        (N'asset_field.personal_data_categories', N'HEALTH', N'Health', 50),
        (N'asset_field.personal_data_categories', N'BIOMETRIC', N'Biometric', 60),
        (N'asset_field.personal_data_categories', N'LOCATION', N'Location', 70),
        (N'asset_field.data_subject_categories', N'EMPLOYEES', N'Employees', 10),
        (N'asset_field.data_subject_categories', N'CUSTOMERS', N'Customers', 20),
        (N'asset_field.data_subject_categories', N'PATIENTS', N'Patients', 30),
        (N'asset_field.data_subject_categories', N'VENDORS', N'Vendors', 40),
        (N'asset_field.data_subject_categories', N'VISITORS', N'Visitors', 50),
        (N'asset_field.data_subject_categories', N'CHILDREN', N'Children', 60),
        (N'asset_field.data_subject_categories', N'OTHER', N'Other', 70),
        (N'asset_field.processing_operations', N'STORE', N'Store', 10),
        (N'asset_field.processing_operations', N'PROCESS', N'Process', 20),
        (N'asset_field.processing_operations', N'RECEIVE', N'Receive', 30),
        (N'asset_field.processing_operations', N'GENERATE', N'Generate', 40),
        (N'asset_field.processing_operations', N'DISPLAY', N'Display', 50),
        (N'asset_field.processing_operations', N'TRANSMIT', N'Transmit', 60),
        (N'asset_field.processing_operations', N'BACK_UP', N'Back Up', 70),
        (N'asset_field.processing_operations', N'DELETE', N'Delete', 80),
        (N'asset_field.dpia_pia_status', N'NOT_STARTED', N'Not Started', 10),
        (N'asset_field.dpia_pia_status', N'IN_PROGRESS', N'In Progress', 20),
        (N'asset_field.dpia_pia_status', N'APPROVED', N'Approved', 30),
        (N'asset_field.dpia_pia_status', N'REJECTED', N'Rejected', 40),
        (N'asset_field.dpia_pia_status', N'EXPIRED', N'Expired', 50),
        (N'asset_field.masking_method', N'STATIC', N'Static', 10),
        (N'asset_field.masking_method', N'DYNAMIC', N'Dynamic', 20),
        (N'asset_field.masking_method', N'TOKENIZATION', N'Tokenization', 30),
        (N'asset_field.masking_method', N'PSEUDONYMIZATION', N'Pseudonymization', 40),
        (N'asset_field.masking_method', N'ANONYMIZATION', N'Anonymization', 50),
        (N'asset_field.masking_method', N'PARTIAL_MASK', N'Partial Mask', 60),
        (N'asset_field.masking_method', N'REDACTION', N'Redaction', 70),
        (N'asset_field.masking_method', N'OBFUSCATION', N'Obfuscation', 80),
        (N'asset_field.masking_method', N'ENCRYPTION_BASED', N'Encryption-based', 90),
        (N'asset_field.masking_method', N'CUSTOM', N'Custom', 100),
        (N'asset_field.masking_coverage', N'PRODUCTION', N'Production', 10),
        (N'asset_field.masking_coverage', N'NON_PRODUCTION', N'Non-production', 20),
        (N'asset_field.masking_coverage', N'REPORTS', N'Reports', 30),
        (N'asset_field.masking_coverage', N'EXPORTS', N'Exports', 40),
        (N'asset_field.masking_coverage', N'LOGS', N'Logs', 50),
        (N'asset_field.masking_coverage', N'BACKUPS', N'Backups', 60),
        (N'asset_field.retention_trigger', N'CREATION', N'Creation', 10),
        (N'asset_field.retention_trigger', N'CLOSURE', N'Closure', 20),
        (N'asset_field.retention_trigger', N'EMPLOYMENT_END', N'Employment End', 30),
        (N'asset_field.retention_trigger', N'CONTRACT_END', N'Contract End', 40),
        (N'asset_field.retention_trigger', N'LAST_ACTIVITY', N'Last Activity', 50),
        (N'asset_field.coverage_type', N'WARRANTY', N'Warranty', 10),
        (N'asset_field.coverage_type', N'AMC', N'AMC', 20),
        (N'asset_field.coverage_type', N'CMC', N'CMC', 30),
        (N'asset_field.coverage_type', N'LICENCE', N'Licence', 40),
        (N'asset_field.coverage_type', N'INSURANCE', N'Insurance', 50),
        (N'asset_field.coverage_type', N'CALIBRATION', N'Calibration', 60),
        (N'asset_field.coverage_type', N'MANAGED_SERVICE', N'Managed Service', 70),
        (N'asset_field.coverage_type', N'CUSTOM', N'Custom', 80),
        (N'asset_field.decommission_reason', N'OBSOLETE', N'Obsolete', 10),
        (N'asset_field.decommission_reason', N'UNSUPPORTED', N'Unsupported', 20),
        (N'asset_field.decommission_reason', N'DAMAGED', N'Damaged', 30),
        (N'asset_field.decommission_reason', N'REPLACED', N'Replaced', 40),
        (N'asset_field.decommission_reason', N'LOST', N'Lost', 50),
        (N'asset_field.decommission_reason', N'SOLD', N'Sold', 60),
        (N'asset_field.data_backup_retention_decision', N'RETAIN', N'Retain', 10),
        (N'asset_field.data_backup_retention_decision', N'MIGRATE', N'Migrate', 20),
        (N'asset_field.data_backup_retention_decision', N'ARCHIVE', N'Archive', 30),
        (N'asset_field.data_backup_retention_decision', N'DELETE', N'Delete', 40),
        (N'asset_field.data_backup_retention_decision', N'NOT_APPLICABLE', N'Not Applicable', 50),
        (N'asset_field.sanitization_method', N'CLEAR', N'Clear', 10),
        (N'asset_field.sanitization_method', N'PURGE', N'Purge', 20),
        (N'asset_field.sanitization_method', N'CRYPTOGRAPHIC_ERASE', N'Cryptographic Erase', 30),
        (N'asset_field.sanitization_method', N'DEGAUSS', N'Degauss', 40),
        (N'asset_field.sanitization_method', N'PHYSICAL_DESTRUCTION', N'Physical Destruction', 50),
        (N'asset_field.disposal_method', N'RETURN', N'Return', 10),
        (N'asset_field.disposal_method', N'RESALE', N'Resale', 20),
        (N'asset_field.disposal_method', N'DONATION', N'Donation', 30),
        (N'asset_field.disposal_method', N'RECYCLE', N'Recycle', 40),
        (N'asset_field.disposal_method', N'SCRAP', N'Scrap', 50),
        (N'asset_field.disposal_method', N'DESTROY', N'Destroy', 60),
        (N'asset_field.disposal_method', N'TRANSFER', N'Transfer', 70),
        (N'asset_field.approval_status', N'DRAFT', N'Draft', 10),
        (N'asset_field.approval_status', N'SUBMITTED', N'Submitted', 20),
        (N'asset_field.approval_status', N'PENDING_APPROVAL', N'Pending Approval', 30),
        (N'asset_field.approval_status', N'APPROVED', N'Approved', 40),
        (N'asset_field.approval_status', N'REJECTED', N'Rejected', 50),
        (N'asset_field.approval_status', N'RETURNED', N'Returned', 60),
        (N'asset_field.data_confidence', N'VERIFIED', N'Verified', 10),
        (N'asset_field.data_confidence', N'PROBABLE', N'Probable', 20),
        (N'asset_field.data_confidence', N'UNVERIFIED', N'Unverified', 30),
        (N'asset_field.data_confidence', N'STALE', N'Stale', 40),
        (N'asset_field.data_confidence', N'CONFLICTING', N'Conflicting', 50),
        (N'asset_field.sync_status', N'NOT_APPLICABLE', N'Not Applicable', 10),
        (N'asset_field.sync_status', N'PENDING', N'Pending', 20),
        (N'asset_field.sync_status', N'SYNCHRONIZED', N'Synchronized', 30),
        (N'asset_field.sync_status', N'WARNING', N'Warning', 40),
        (N'asset_field.sync_status', N'FAILED', N'Failed', 50),
        (N'asset_field.asset_valuation_method', N'MAXIMUM', N'Maximum', 10),
        (N'asset_field.asset_valuation_method', N'WEIGHTED_AVERAGE', N'Weighted Average', 20),
        (N'asset_field.asset_valuation_method', N'SUMMATION', N'Summation', 30)
    ) AS s(option_group, option_value, option_label, display_order)
    ON t.option_group = s.option_group AND t.option_value = s.option_value
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (option_group, option_value, option_label, display_order, status, entered_by)
        VALUES (s.option_group, s.option_value, s.option_label, s.display_order, N'Active', N'seed-272');
    PRINT CONCAT('272: asset option values inserted: ', @@ROWCOUNT);
END
GO

PRINT '272: section N (asset field option lists) done.';
GO

-- =====================================================================
-- O. Asset option-list catalogue (owning migration: 423_asset_option_lists)
--    One row per OPTION: list in the field dictionary. Insert-only, same
--    rows as 423. Organization values (asset_field_option_org) are
--    tenant data and are not seeded.
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_option_list_master','U') IS NULL
    PRINT '272: asset_option_list_master absent (run 423) -- option-list catalogue skipped.';
ELSE
BEGIN
    ;WITH src AS (
        SELECT N'asset_field.' + SUBSTRING(d.lookup_source, 8, 100) AS option_group,
               SUBSTRING(d.lookup_source, 8, 100) AS list_key,
               MIN(d.display_label) AS first_label
          FROM grac_practice.asset_field_definition d
         WHERE d.lookup_source LIKE N'OPTION:%'
         GROUP BY d.lookup_source
    )
    MERGE grac_practice.asset_option_list_master AS t
    USING (
        SELECT s.option_group,
               CASE s.list_key WHEN N'yes_no_unknown'    THEN N'Yes / No / Unknown'
                               WHEN N'yes_no_assessment' THEN N'Yes / No / Under Assessment'
                               WHEN N'yes_no_partial'    THEN N'Yes / No / Partially'
                               ELSE s.first_label END AS list_name,
               CASE WHEN s.list_key IN (N'yes_no_unknown', N'yes_no_assessment', N'yes_no_partial') THEN N'GLOBAL_ONLY'
                    WHEN EXISTS (SELECT 1 FROM grac_practice.reference_option o WHERE o.option_group = s.option_group) THEN N'ORG_EXTENSIBLE'
                    ELSE N'ORG_ONLY' END AS scope_code,
               CASE s.list_key WHEN N'building' THEN N'site'
                               WHEN N'floor'    THEN N'building'
                               WHEN N'room'     THEN N'floor'
                               WHEN N'zone'     THEN N'site' END AS parent_field_key
          FROM src s
    ) AS s
    ON t.option_group = s.option_group
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (option_group, list_name, scope_code, parent_field_key, entered_by)
        VALUES (s.option_group, s.list_name, s.scope_code, s.parent_field_key, N'seed-272');
    PRINT CONCAT('272: option lists catalogued: ', @@ROWCOUNT);
END
GO

PRINT '272: section O (asset option-list catalogue) done.';
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
    (N'dependency_type_master',                    11),   -- 385: + Department, 386: + Business Function
    (N'dependency_hosting_type_master',             3),
    (N'dependency_license_type_master',             2),
    (N'dependency_service_category_master',         7),
    (N'dependency_resolution_status_master',        2),
    (N'dependency_asset_category_master',          13),
    (N'dependency_asset_subcategory_master',       17),
    (N'dependency_asset_type_master',              80),
    (N'dependency_type_source_config',             11),   -- 385: + Department, 386: + Business Function
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
    (N'reference_option',                          36),
    (N'asset_field_group_master',                  14),   -- 420
    (N'asset_field_data_type_master',              29),   -- 420
    (N'asset_field_definition',                   270);   -- 420

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
