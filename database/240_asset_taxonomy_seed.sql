-- =====================================================================
-- 240 Baseline Asset Taxonomy seed
--
-- WHAT IT DOES
-- ------------
-- Populates the three master tables with the Enterprise Asset Taxonomy
-- Template baseline (docx sections A..E). Idempotent via MERGE on the
-- natural keys, so re-running lifts is_active back to 1 and refreshes
-- display_order / names but never duplicates.
--
-- Old asset categories (Server, Network Device, Database, Endpoint,
-- Storage, Facility, Document, Other) are left ACTIVE alongside the new
-- Main Categories -- existing organization_dependency_asset rows still
-- reference them, and deactivating would silently break their display.
-- The new taxonomy becomes the recommended set going forward.
--
-- Custom entries an organization adds later are marked is_active=1 and
-- do not conflict; the natural-key columns keep this seed
-- non-destructive.
--
-- SAFE TO RE-RUN. Requires 239. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.dependency_asset_subcategory_master','U') IS NULL
    OR OBJECT_ID('grac_practice.dependency_asset_type_master','U') IS NULL
BEGIN
    PRINT 'ABORT (240): taxonomy tables missing -- run 239 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Main Categories (docx section 3: A/B/C/D/E)
-- =====================================================================
MERGE grac_practice.dependency_asset_category_master AS target
USING (VALUES
    (N'TECHNOLOGY',            N'Technology',            1000),
    (N'INFORMATION_DATA',      N'Information & Data',    1100),
    (N'PHYSICAL_OPERATIONAL',  N'Physical & Operational',1200),
    (N'FACILITIES_UTILITY',    N'Facilities & Utility',  1300),
    (N'VEHICLES',              N'Vehicles',              1400)
) AS s(asset_category_code, asset_category_name, display_order)
ON target.asset_category_code = s.asset_category_code
WHEN MATCHED THEN UPDATE SET
    asset_category_name = s.asset_category_name,
    display_order       = s.display_order,
    is_active           = 1,
    updated_by          = N'seed-240',
    updated_dt          = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (asset_category_code, asset_category_name, display_order, is_active, entered_by)
    VALUES(s.asset_category_code, s.asset_category_name, s.display_order, 1, N'seed-240');
GO
PRINT '240: main categories seeded.';
GO

-- =====================================================================
-- 2. Subcategories (docx: A1..A6, B1..B3, C1..C3, D1..D3, E1..E2)
-- =====================================================================
;WITH sub(cat_code, sub_code, sub_name, ord) AS (
    -- A. Technology
    SELECT N'TECHNOLOGY', N'TECH_END_USER',       N'End User Computing',           10 UNION ALL
    SELECT N'TECHNOLOGY', N'TECH_COMPUTE',        N'Compute & Infrastructure',     20 UNION ALL
    SELECT N'TECHNOLOGY', N'TECH_NETWORK',        N'Network & Communications',     30 UNION ALL
    SELECT N'TECHNOLOGY', N'TECH_APPS',           N'Applications & Software',      40 UNION ALL
    SELECT N'TECHNOLOGY', N'TECH_CLOUD',          N'Cloud & Technology Services',  50 UNION ALL
    SELECT N'TECHNOLOGY', N'TECH_SECURITY',       N'Security Technology',          60 UNION ALL
    -- B. Information & Data
    SELECT N'INFORMATION_DATA', N'INFO_DATA',           N'Data',                    10 UNION ALL
    SELECT N'INFORMATION_DATA', N'INFO_REPOSITORIES',   N'Information Repositories',20 UNION ALL
    SELECT N'INFORMATION_DATA', N'INFO_RECORDS',        N'Information Records',     30 UNION ALL
    -- C. Physical & Operational
    SELECT N'PHYSICAL_OPERATIONAL', N'PHY_OPERATIONAL',  N'Operational Equipment',       10 UNION ALL
    SELECT N'PHYSICAL_OPERATIONAL', N'PHY_SAFETY',       N'Safety & Security Equipment', 20 UNION ALL
    SELECT N'PHYSICAL_OPERATIONAL', N'PHY_SPECIALIZED',  N'Specialized Equipment',       30 UNION ALL
    -- D. Facilities & Utility
    SELECT N'FACILITIES_UTILITY', N'FAC_ELECTRICAL',    N'Electrical Systems',                   10 UNION ALL
    SELECT N'FACILITIES_UTILITY', N'FAC_HVAC',          N'HVAC & Environmental Systems',         20 UNION ALL
    SELECT N'FACILITIES_UTILITY', N'FAC_INFRA',         N'Facility Infrastructure',              30 UNION ALL
    -- E. Vehicles
    SELECT N'VEHICLES', N'VEH_GENERAL',        N'General Vehicles',      10 UNION ALL
    SELECT N'VEHICLES', N'VEH_OPERATIONAL',    N'Operational Vehicles',  20
)
MERGE grac_practice.dependency_asset_subcategory_master AS target
USING (
    SELECT c.asset_category_id, sub.sub_code, sub.sub_name, sub.ord
    FROM   sub
    JOIN   grac_practice.dependency_asset_category_master c
           ON c.asset_category_code = sub.cat_code
) AS s(asset_category_id, subcategory_code, subcategory_name, display_order)
ON target.subcategory_code = s.subcategory_code
WHEN MATCHED THEN UPDATE SET
    asset_category_id = s.asset_category_id,
    subcategory_name  = s.subcategory_name,
    display_order     = s.display_order,
    is_active         = 1,
    updated_by        = N'seed-240',
    updated_dt        = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (asset_category_id, subcategory_code, subcategory_name, display_order, is_active, entered_by)
    VALUES(s.asset_category_id, s.subcategory_code, s.subcategory_name, s.display_order, 1, N'seed-240');
GO
PRINT '240: subcategories seeded.';
GO

-- =====================================================================
-- 3. Asset Types (docx bullet lists per subcategory)
-- =====================================================================
;WITH atype(sub_code, type_code, type_name, ord) AS (
    -- A1 End User Computing
    SELECT N'TECH_END_USER', N'TYPE_DESKTOP',          N'Desktop',            10 UNION ALL
    SELECT N'TECH_END_USER', N'TYPE_LAPTOP',           N'Laptop',             20 UNION ALL
    SELECT N'TECH_END_USER', N'TYPE_TABLET',           N'Tablet',             30 UNION ALL
    SELECT N'TECH_END_USER', N'TYPE_MOBILE',           N'Mobile Device',      40 UNION ALL
    SELECT N'TECH_END_USER', N'TYPE_THIN_CLIENT',      N'Thin Client',        50 UNION ALL
    SELECT N'TECH_END_USER', N'TYPE_PERIPHERAL',       N'Peripheral Device',  60 UNION ALL
    -- A2 Compute & Infrastructure
    SELECT N'TECH_COMPUTE', N'TYPE_PHYSICAL_SERVER',   N'Physical Server',    10 UNION ALL
    SELECT N'TECH_COMPUTE', N'TYPE_VIRTUAL_SERVER',    N'Virtual Server',     20 UNION ALL
    SELECT N'TECH_COMPUTE', N'TYPE_STORAGE_SYSTEM',    N'Storage System',     30 UNION ALL
    SELECT N'TECH_COMPUTE', N'TYPE_BACKUP_SYSTEM',     N'Backup System',      40 UNION ALL
    SELECT N'TECH_COMPUTE', N'TYPE_DC_EQUIPMENT',      N'Data Centre Equipment', 50 UNION ALL
    -- A3 Network & Communications
    SELECT N'TECH_NETWORK', N'TYPE_ROUTER',            N'Router',             10 UNION ALL
    SELECT N'TECH_NETWORK', N'TYPE_SWITCH',            N'Switch',             20 UNION ALL
    SELECT N'TECH_NETWORK', N'TYPE_FIREWALL',          N'Firewall',           30 UNION ALL
    SELECT N'TECH_NETWORK', N'TYPE_WIRELESS_AP',       N'Wireless Access Point', 40 UNION ALL
    SELECT N'TECH_NETWORK', N'TYPE_NETWORK_APPLIANCE', N'Network Appliance',  50 UNION ALL
    SELECT N'TECH_NETWORK', N'TYPE_COMMS_EQUIPMENT',   N'Communication Equipment', 60 UNION ALL
    -- A4 Applications & Software
    SELECT N'TECH_APPS', N'TYPE_BUSINESS_APP',         N'Business Application',   10 UNION ALL
    SELECT N'TECH_APPS', N'TYPE_ENTERPRISE_APP',       N'Enterprise Application', 20 UNION ALL
    SELECT N'TECH_APPS', N'TYPE_SYSTEM_SOFTWARE',      N'System Software',        30 UNION ALL
    SELECT N'TECH_APPS', N'TYPE_DATABASE',             N'Database',               40 UNION ALL
    SELECT N'TECH_APPS', N'TYPE_MIDDLEWARE',           N'Middleware',             50 UNION ALL
    SELECT N'TECH_APPS', N'TYPE_MOBILE_APP',           N'Mobile Application',     60 UNION ALL
    SELECT N'TECH_APPS', N'TYPE_WEB_APP',              N'Web Application',        70 UNION ALL
    SELECT N'TECH_APPS', N'TYPE_SOFTWARE_LICENCE',     N'Software Licence',       80 UNION ALL
    -- A5 Cloud & Technology Services
    SELECT N'TECH_CLOUD', N'TYPE_CLOUD_SERVICE',       N'Cloud Service',           10 UNION ALL
    SELECT N'TECH_CLOUD', N'TYPE_SAAS_SERVICE',        N'SaaS Service',            20 UNION ALL
    SELECT N'TECH_CLOUD', N'TYPE_HOSTING_SERVICE',     N'Hosting Service',         30 UNION ALL
    SELECT N'TECH_CLOUD', N'TYPE_MANAGED_TECH_SERVICE',N'Managed Technology Service', 40 UNION ALL
    -- A6 Security Technology
    SELECT N'TECH_SECURITY', N'TYPE_SIEM',             N'Security Information & Event Management', 10 UNION ALL
    SELECT N'TECH_SECURITY', N'TYPE_ENDPOINT_SECURITY',N'Endpoint Security',       20 UNION ALL
    SELECT N'TECH_SECURITY', N'TYPE_IAM',              N'Identity & Access Management System', 30 UNION ALL
    SELECT N'TECH_SECURITY', N'TYPE_VULN_MGMT',        N'Vulnerability Management Tool', 40 UNION ALL
    SELECT N'TECH_SECURITY', N'TYPE_SECURITY_APPLIANCE',N'Security Appliance',     50 UNION ALL
    SELECT N'TECH_SECURITY', N'TYPE_ENCRYPTION',       N'Encryption / Key Management System', 60 UNION ALL
    -- B1 Data
    SELECT N'INFO_DATA', N'TYPE_CUSTOMER_DATA',        N'Customer Data',           10 UNION ALL
    SELECT N'INFO_DATA', N'TYPE_EMPLOYEE_DATA',        N'Employee Data',           20 UNION ALL
    SELECT N'INFO_DATA', N'TYPE_FINANCIAL_DATA',       N'Financial Data',          30 UNION ALL
    SELECT N'INFO_DATA', N'TYPE_TRANSACTION_DATA',     N'Transaction Data',        40 UNION ALL
    SELECT N'INFO_DATA', N'TYPE_OPERATIONAL_DATA',     N'Operational Data',        50 UNION ALL
    SELECT N'INFO_DATA', N'TYPE_REGULATORY_DATA',      N'Regulatory Data',         60 UNION ALL
    -- B2 Information Repositories
    SELECT N'INFO_REPOSITORIES', N'TYPE_DB_REPOSITORY',   N'Database',              10 UNION ALL
    SELECT N'INFO_REPOSITORIES', N'TYPE_DOC_REPOSITORY',  N'Document Repository',   20 UNION ALL
    SELECT N'INFO_REPOSITORIES', N'TYPE_FILE_REPOSITORY', N'File Repository',       30 UNION ALL
    SELECT N'INFO_REPOSITORIES', N'TYPE_RECORDS_REPO',    N'Records Repository',    40 UNION ALL
    SELECT N'INFO_REPOSITORIES', N'TYPE_DATA_WAREHOUSE',  N'Data Warehouse',        50 UNION ALL
    SELECT N'INFO_REPOSITORIES', N'TYPE_DATA_LAKE',       N'Data Lake',             60 UNION ALL
    -- B3 Information Records
    SELECT N'INFO_RECORDS', N'TYPE_POLICY',            N'Policy',                  10 UNION ALL
    SELECT N'INFO_RECORDS', N'TYPE_PROCEDURE',         N'Procedure',               20 UNION ALL
    SELECT N'INFO_RECORDS', N'TYPE_CONTRACT',          N'Contract',                30 UNION ALL
    SELECT N'INFO_RECORDS', N'TYPE_REPORT',            N'Report',                  40 UNION ALL
    SELECT N'INFO_RECORDS', N'TYPE_REG_RETURN',        N'Regulatory Return',       50 UNION ALL
    SELECT N'INFO_RECORDS', N'TYPE_RECORD',            N'Record',                  60 UNION ALL
    -- C1 Operational Equipment
    SELECT N'PHY_OPERATIONAL', N'TYPE_PRODUCTION_EQ',     N'Production Equipment', 10 UNION ALL
    SELECT N'PHY_OPERATIONAL', N'TYPE_PROCESSING_EQ',     N'Processing Equipment', 20 UNION ALL
    SELECT N'PHY_OPERATIONAL', N'TYPE_MEASURING_EQ',      N'Measuring Equipment',  30 UNION ALL
    SELECT N'PHY_OPERATIONAL', N'TYPE_TESTING_EQ',        N'Testing Equipment',    40 UNION ALL
    SELECT N'PHY_OPERATIONAL', N'TYPE_LAB_EQ',            N'Laboratory Equipment', 50 UNION ALL
    -- C2 Safety & Security Equipment
    SELECT N'PHY_SAFETY', N'TYPE_CCTV',                N'CCTV',                    10 UNION ALL
    SELECT N'PHY_SAFETY', N'TYPE_ACCESS_CONTROL',      N'Access Control Equipment',20 UNION ALL
    SELECT N'PHY_SAFETY', N'TYPE_FIRE_SAFETY',         N'Fire Safety Equipment',   30 UNION ALL
    SELECT N'PHY_SAFETY', N'TYPE_ALARM_SYSTEM',        N'Alarm System',            40 UNION ALL
    SELECT N'PHY_SAFETY', N'TYPE_SURVEILLANCE',        N'Surveillance Equipment',  50 UNION ALL
    -- C3 Specialized Equipment
    SELECT N'PHY_SPECIALIZED', N'TYPE_MEDICAL_EQ',        N'Medical Equipment',        10 UNION ALL
    SELECT N'PHY_SPECIALIZED', N'TYPE_SCIENTIFIC_EQ',     N'Scientific Equipment',     20 UNION ALL
    SELECT N'PHY_SPECIALIZED', N'TYPE_INDUSTRY_EQ',       N'Industry-Specific Equipment', 30 UNION ALL
    -- D1 Electrical Systems
    SELECT N'FAC_ELECTRICAL', N'TYPE_GENERATOR',       N'Generator',                    10 UNION ALL
    SELECT N'FAC_ELECTRICAL', N'TYPE_UPS',             N'UPS',                          20 UNION ALL
    SELECT N'FAC_ELECTRICAL', N'TYPE_TRANSFORMER',     N'Transformer',                  30 UNION ALL
    SELECT N'FAC_ELECTRICAL', N'TYPE_ELEC_DIST',       N'Electrical Distribution Equipment', 40 UNION ALL
    -- D2 HVAC & Environmental Systems
    SELECT N'FAC_HVAC', N'TYPE_HVAC',                  N'HVAC System',                  10 UNION ALL
    SELECT N'FAC_HVAC', N'TYPE_COOLING',               N'Cooling System',               20 UNION ALL
    SELECT N'FAC_HVAC', N'TYPE_ENV_MONITORING',        N'Environmental Monitoring System', 30 UNION ALL
    -- D3 Facility Infrastructure
    SELECT N'FAC_INFRA', N'TYPE_BUILDING_INFRA',       N'Building Infrastructure',      10 UNION ALL
    SELECT N'FAC_INFRA', N'TYPE_WATER_TREATMENT',      N'Water Treatment System',       20 UNION ALL
    SELECT N'FAC_INFRA', N'TYPE_FIRE_PROTECTION',      N'Fire Protection System',       30 UNION ALL
    SELECT N'FAC_INFRA', N'TYPE_PHYSICAL_SECURITY_INFRA', N'Physical Security Infrastructure', 40 UNION ALL
    -- E1 General Vehicles
    SELECT N'VEH_GENERAL', N'TYPE_COMPANY_CAR',        N'Company Car',                  10 UNION ALL
    SELECT N'VEH_GENERAL', N'TYPE_TRUCK',              N'Truck',                        20 UNION ALL
    SELECT N'VEH_GENERAL', N'TYPE_VAN',                N'Van',                          30 UNION ALL
    SELECT N'VEH_GENERAL', N'TYPE_TWO_WHEELER',        N'Two-Wheeler',                  40 UNION ALL
    -- E2 Operational Vehicles
    SELECT N'VEH_OPERATIONAL', N'TYPE_AMBULANCE',      N'Ambulance',                    10 UNION ALL
    SELECT N'VEH_OPERATIONAL', N'TYPE_FORKLIFT',       N'Forklift',                     20 UNION ALL
    SELECT N'VEH_OPERATIONAL', N'TYPE_SPECIAL_VEH',    N'Special-Purpose Vehicle',      30 UNION ALL
    SELECT N'VEH_OPERATIONAL', N'TYPE_MATERIAL_VEH',   N'Material Handling Vehicle',    40
)
MERGE grac_practice.dependency_asset_type_master AS target
USING (
    SELECT sub.subcategory_id, atype.type_code, atype.type_name, atype.ord
    FROM   atype
    JOIN   grac_practice.dependency_asset_subcategory_master sub
           ON sub.subcategory_code = atype.sub_code
) AS s(subcategory_id, asset_type_code, asset_type_name, display_order)
ON target.asset_type_code = s.asset_type_code
WHEN MATCHED THEN UPDATE SET
    subcategory_id  = s.subcategory_id,
    asset_type_name = s.asset_type_name,
    display_order   = s.display_order,
    is_active       = 1,
    updated_by      = N'seed-240',
    updated_dt      = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (subcategory_id, asset_type_code, asset_type_name, display_order, is_active, entered_by)
    VALUES(s.subcategory_id, s.asset_type_code, s.asset_type_name, s.display_order, 1, N'seed-240');
GO
PRINT '240: asset types seeded.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 240 verification ===';

DECLARE @cat_count INT = (SELECT COUNT(*) FROM grac_practice.dependency_asset_category_master
                          WHERE asset_category_code IN (N'TECHNOLOGY',N'INFORMATION_DATA',N'PHYSICAL_OPERATIONAL',N'FACILITIES_UTILITY',N'VEHICLES'));
DECLARE @sub_count INT = (SELECT COUNT(*) FROM grac_practice.dependency_asset_subcategory_master WHERE entered_by = N'seed-240' OR updated_by = N'seed-240');
DECLARE @type_count INT = (SELECT COUNT(*) FROM grac_practice.dependency_asset_type_master WHERE entered_by = N'seed-240' OR updated_by = N'seed-240');

SELECT 'Main Categories seeded (5 expected)' AS Check_, CAST(@cat_count AS NVARCHAR(10)) AS Count_
UNION ALL SELECT 'Subcategories seeded (17 expected)', CAST(@sub_count AS NVARCHAR(10))
UNION ALL SELECT 'Asset Types seeded (~70 expected)', CAST(@type_count AS NVARCHAR(10));

PRINT '';
PRINT '=== Sample chain: pick any subcategory and its types ===';
SELECT TOP 5 c.asset_category_name  AS Category,
             sc.subcategory_name    AS Subcategory,
             t.asset_type_name      AS AssetType
FROM   grac_practice.dependency_asset_type_master t
JOIN   grac_practice.dependency_asset_subcategory_master sc ON sc.subcategory_id = t.subcategory_id
JOIN   grac_practice.dependency_asset_category_master   c  ON c.asset_category_id = sc.asset_category_id
ORDER  BY c.display_order, sc.display_order, t.display_order;

PRINT '';
PRINT '240 complete. Now apply 241 (save proc + lookups) and the Web build.';
GO

SET NOEXEC OFF;
GO
