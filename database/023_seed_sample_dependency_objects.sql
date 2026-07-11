/*  ============================================================
    023_seed_sample_dependency_objects.sql
    Seeds sample dependency objects for testing the Resolve dialog.

    Problem:  The "Dependency Object" dropdown in Resolve shows
              "No dependency objects found" because the source tables
              (organization_dependency_application, etc.) are empty.

    This script inserts sample records for ALL organizations that
    have active practice instances with configured dependencies.

    Run AFTER 002_practice_management_procedures.sql.
    Safe to re-run (checks for existing records before inserting).
    ============================================================ */

-- ============================================================
-- STEP 0: Show current state (before seeding)
-- ============================================================
PRINT '=== BEFORE: Source table record counts by organization ===';
SELECT 'Application' DependencyType, a.organization_id, o.organization_name, COUNT(*) RecordCount
FROM grac_practice.organization_dependency_application a
LEFT JOIN grac_practice.organization o ON o.organization_id=a.organization_id
WHERE a.status='Active'
GROUP BY a.organization_id, o.organization_name
UNION ALL
SELECT 'Tool', t.organization_id, o.organization_name, COUNT(*)
FROM grac_practice.organization_dependency_tool t
LEFT JOIN grac_practice.organization o ON o.organization_id=t.organization_id
WHERE t.status='Active'
GROUP BY t.organization_id, o.organization_name
UNION ALL
SELECT 'Vendor', v.organization_id, o.organization_name, COUNT(*)
FROM grac_practice.organization_dependency_vendor v
LEFT JOIN grac_practice.organization o ON o.organization_id=v.organization_id
WHERE v.status='Active'
GROUP BY v.organization_id, o.organization_name
UNION ALL
SELECT 'Asset', a.organization_id, o.organization_name, COUNT(*)
FROM grac_practice.organization_dependency_asset a
LEFT JOIN grac_practice.organization o ON o.organization_id=a.organization_id
WHERE a.status='Active'
GROUP BY a.organization_id, o.organization_name
UNION ALL
SELECT 'Process', p.organization_id, o.organization_name, COUNT(*)
FROM grac_practice.organization_dependency_process p
LEFT JOIN grac_practice.organization o ON o.organization_id=p.organization_id
WHERE p.status='Active'
GROUP BY p.organization_id, o.organization_name
ORDER BY DependencyType, organization_id;

-- ============================================================
-- STEP 1: Get active record status ID
-- ============================================================
DECLARE @active_status_id BIGINT=(SELECT TOP 1 record_status_id FROM grac_practice.record_status_master WHERE status_name='Active');
IF @active_status_id IS NULL SET @active_status_id=1;

-- ============================================================
-- STEP 2: Seed sample Applications for each organization that
--         has practice instances with Application dependencies
-- ============================================================
PRINT '=== Seeding sample Applications ===';
;WITH orgs_needing_apps AS (
    SELECT DISTINCT d.organization_id
    FROM grac_practice.practice_instance_dependency d
    JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id
    WHERE dt.dependency_type_code='Application' AND d.status='Active'
      AND NOT EXISTS(
        SELECT 1 FROM grac_practice.organization_dependency_application a
        WHERE a.organization_id=d.organization_id AND a.status='Active'
      )
    UNION
    -- Also seed for organizations with active practice instances (even without explicit Application dependencies)
    SELECT DISTINCT pi.organization_id
    FROM grac_practice.practice_instance pi
    WHERE pi.status='Active'
      AND NOT EXISTS(
        SELECT 1 FROM grac_practice.organization_dependency_application a
        WHERE a.organization_id=pi.organization_id AND a.status='Active'
      )
)
INSERT grac_practice.organization_dependency_application(organization_id,application_name,description,status,record_status_id,entered_by)
SELECT o.organization_id, app.application_name, app.description, 'Active', @active_status_id, 'system'
FROM orgs_needing_apps o
CROSS APPLY (VALUES
    (N'Microsoft Office 365',N'Office productivity suite'),
    (N'SAP ERP',N'Enterprise resource planning system'),
    (N'Salesforce CRM',N'Customer relationship management'),
    (N'ServiceNow',N'IT service management platform'),
    (N'Jira',N'Project and issue tracking'),
    (N'Slack',N'Team communication platform'),
    (N'AWS Console',N'Cloud infrastructure management'),
    (N'Active Directory',N'Identity and access management'),
    (N'DocuSign',N'Electronic signature platform'),
    (N'Workday',N'Human capital management')
) app(application_name,description);

PRINT '   Applications seeded.';

-- ============================================================
-- STEP 3: Seed sample Tools
-- ============================================================
PRINT '=== Seeding sample Tools ===';
;WITH orgs_needing_tools AS (
    SELECT DISTINCT pi.organization_id
    FROM grac_practice.practice_instance pi
    WHERE pi.status='Active'
      AND NOT EXISTS(
        SELECT 1 FROM grac_practice.organization_dependency_tool t
        WHERE t.organization_id=pi.organization_id AND t.status='Active'
      )
)
INSERT grac_practice.organization_dependency_tool(organization_id,tool_name,description,status,record_status_id,entered_by)
SELECT o.organization_id, t.tool_name, t.tool_desc, 'Active', @active_status_id, 'system'
FROM orgs_needing_tools o
CROSS APPLY (VALUES
    (N'Git',N'Version control system'),
    (N'Jenkins',N'CI/CD automation server'),
    (N'Terraform',N'Infrastructure as code'),
    (N'Docker',N'Container platform'),
    (N'SonarQube',N'Code quality scanner'),
    (N'Splunk',N'Log analysis and monitoring'),
    (N'Nessus',N'Vulnerability scanner'),
    (N'Postman',N'API testing tool')
) t(tool_name,tool_desc);

PRINT '   Tools seeded.';

-- ============================================================
-- STEP 4: Seed sample Vendors (requires service_category_id NOT NULL)
-- ============================================================
DECLARE @default_service_category_id INT=(SELECT TOP 1 service_category_id FROM grac_practice.dependency_service_category_master WHERE is_active=1 ORDER BY display_order);
IF @default_service_category_id IS NULL SET @default_service_category_id=1;

PRINT '=== Seeding sample Vendors ===';
;WITH orgs_needing_vendors AS (
    SELECT DISTINCT pi.organization_id
    FROM grac_practice.practice_instance pi
    WHERE pi.status='Active'
      AND NOT EXISTS(
        SELECT 1 FROM grac_practice.organization_dependency_vendor v
        WHERE v.organization_id=pi.organization_id AND v.status='Active'
      )
)
INSERT grac_practice.organization_dependency_vendor(organization_id,vendor_name,service_category_id,remarks,status,record_status_id,entered_by)
SELECT o.organization_id, v.vendor_name, @default_service_category_id, v.vendor_remarks, 'Active', @active_status_id, 'system'
FROM orgs_needing_vendors o
CROSS APPLY (VALUES
    (N'Microsoft Corporation',N'Enterprise software and cloud services'),
    (N'Amazon Web Services',N'Cloud infrastructure provider'),
    (N'Deloitte',N'Audit and consulting services'),
    (N'Salesforce Inc.',N'CRM and cloud platform'),
    (N'Oracle Corporation',N'Database and enterprise software')
) v(vendor_name,vendor_remarks);

PRINT '   Vendors seeded.';

-- ============================================================
-- STEP 5: Seed sample Assets (requires asset_category_id NOT NULL)
-- ============================================================
DECLARE @default_asset_category_id INT=(SELECT TOP 1 asset_category_id FROM grac_practice.dependency_asset_category_master WHERE is_active=1 ORDER BY display_order);
IF @default_asset_category_id IS NULL SET @default_asset_category_id=1;

PRINT '=== Seeding sample Assets ===';
;WITH orgs_needing_assets AS (
    SELECT DISTINCT pi.organization_id
    FROM grac_practice.practice_instance pi
    WHERE pi.status='Active'
      AND NOT EXISTS(
        SELECT 1 FROM grac_practice.organization_dependency_asset a
        WHERE a.organization_id=pi.organization_id AND a.status='Active'
      )
)
INSERT grac_practice.organization_dependency_asset(organization_id,asset_name,asset_category_id,remarks,status,record_status_id,entered_by)
SELECT o.organization_id, a.asset_name, @default_asset_category_id, a.asset_remarks, 'Active', @active_status_id, 'system'
FROM orgs_needing_assets o
CROSS APPLY (VALUES
    (N'Production Database Server',N'Primary SQL Server instance'),
    (N'Web Application Server',N'IIS web server cluster'),
    (N'Firewall Appliance',N'Network perimeter firewall'),
    (N'Backup Storage Array',N'SAN backup storage'),
    (N'VPN Gateway',N'Remote access VPN concentrator')
) a(asset_name,asset_remarks);

PRINT '   Assets seeded.';

-- ============================================================
-- STEP 6: Seed sample Processes (no description column — use remarks)
-- ============================================================
PRINT '=== Seeding sample Processes ===';
;WITH orgs_needing_processes AS (
    SELECT DISTINCT pi.organization_id
    FROM grac_practice.practice_instance pi
    WHERE pi.status='Active'
      AND NOT EXISTS(
        SELECT 1 FROM grac_practice.organization_dependency_process p
        WHERE p.organization_id=pi.organization_id AND p.status='Active'
      )
)
INSERT grac_practice.organization_dependency_process(organization_id,process_name,remarks,status,record_status_id,entered_by)
SELECT o.organization_id, bp.process_name, bp.process_remarks, 'Active', @active_status_id, 'system'
FROM orgs_needing_processes o
CROSS APPLY (VALUES
    (N'Change Management',N'IT change request and approval process'),
    (N'Incident Response',N'Security incident handling procedure'),
    (N'Access Review',N'Periodic user access recertification'),
    (N'Backup and Recovery',N'Data backup and disaster recovery process'),
    (N'Patch Management',N'Software patch deployment process')
) bp(process_name,process_remarks);

PRINT '   Processes seeded.';

-- ============================================================
-- STEP 7: Show results (after seeding)
-- ============================================================
PRINT '';
PRINT '=== AFTER: Source table record counts by organization ===';
SELECT 'Application' DependencyType, a.organization_id, o.organization_name, COUNT(*) RecordCount
FROM grac_practice.organization_dependency_application a
LEFT JOIN grac_practice.organization o ON o.organization_id=a.organization_id
WHERE a.status='Active'
GROUP BY a.organization_id, o.organization_name
UNION ALL
SELECT 'Tool', t.organization_id, o.organization_name, COUNT(*)
FROM grac_practice.organization_dependency_tool t
LEFT JOIN grac_practice.organization o ON o.organization_id=t.organization_id
WHERE t.status='Active'
GROUP BY t.organization_id, o.organization_name
UNION ALL
SELECT 'Vendor', v.organization_id, o.organization_name, COUNT(*)
FROM grac_practice.organization_dependency_vendor v
LEFT JOIN grac_practice.organization o ON o.organization_id=v.organization_id
WHERE v.status='Active'
GROUP BY v.organization_id, o.organization_name
UNION ALL
SELECT 'Asset', a.organization_id, o.organization_name, COUNT(*)
FROM grac_practice.organization_dependency_asset a
LEFT JOIN grac_practice.organization o ON o.organization_id=a.organization_id
WHERE a.status='Active'
GROUP BY a.organization_id, o.organization_name
UNION ALL
SELECT 'Process', p.organization_id, o.organization_name, COUNT(*)
FROM grac_practice.organization_dependency_process p
LEFT JOIN grac_practice.organization o ON o.organization_id=p.organization_id
WHERE p.status='Active'
GROUP BY p.organization_id, o.organization_name
ORDER BY DependencyType, organization_id;

PRINT '';
PRINT '=== Dependency Object dropdown should now populate for all dependency categories. ===';
PRINT '=== Restart the app and test the Resolve dialog. ===';
