/*  ============================================================
    022_debug_resolve_dependency_objects.sql
    Diagnostic script: Resolve Details — Dependency Object dropdown

    Issue: When clicking Resolve from 3-dot menu, the Dependency
    Object dropdown is empty. This script traces the full chain:

    1. dependency_type_master → must have all 9 types
    2. dependency_type_source_config → must map each type to a source table
    3. Source tables → must exist with correct columns
    4. Organization data → must have active records in the source tables
    5. practice_instance_dependency → must have dependency_type_id populated
    6. Resolve query result set → must return resolution rows

    Run after deploying 002_practice_management_procedures.sql.
    ============================================================ */

-- ============================================================
-- OUTPUT 1: dependency_type_master — expect 9 active rows
-- ============================================================
PRINT '=== OUTPUT 1: dependency_type_master ===';
SELECT dependency_type_id, dependency_type_code, dependency_type_name,
       display_order, is_active
FROM grac_practice.dependency_type_master
ORDER BY display_order;

-- ============================================================
-- OUTPUT 2: dependency_type_source_config — expect 9 active rows
-- Each must have: source_table_name, id_column_name, display_column_name,
-- organization_filter_column, status_filter_column
-- ============================================================
PRINT '=== OUTPUT 2: dependency_type_source_config with validation ===';
SELECT sc.dependency_type_source_config_id,
       sc.dependency_type_id,
       sc.dependency_type_name,
       sc.source_type,
       sc.source_table_name,
       sc.id_column_name,
       sc.display_column_name,
       sc.organization_filter_column,
       sc.status_filter_column,
       sc.status_active_value,
       sc.sort_column,
       sc.status ConfigStatus,
       CASE WHEN OBJECT_ID(sc.source_table_name) IS NOT NULL THEN 'EXISTS' ELSE 'MISSING' END SourceTableExists,
       CASE WHEN COL_LENGTH(sc.source_table_name, sc.id_column_name) IS NOT NULL THEN 'OK' ELSE 'MISSING' END IdColumnOK,
       CASE WHEN COL_LENGTH(sc.source_table_name, sc.display_column_name) IS NOT NULL THEN 'OK' ELSE 'MISSING' END DisplayColumnOK,
       CASE WHEN COL_LENGTH(sc.source_table_name, sc.organization_filter_column) IS NOT NULL THEN 'OK' ELSE 'MISSING' END OrgColumnOK,
       CASE WHEN COL_LENGTH(sc.source_table_name, sc.status_filter_column) IS NOT NULL THEN 'OK' ELSE 'MISSING' END StatusColumnOK
FROM grac_practice.dependency_type_source_config sc
ORDER BY sc.dependency_type_id;

-- ============================================================
-- OUTPUT 3: Source table record counts per organization
-- Shows whether each source table has active records
-- ============================================================
PRINT '=== OUTPUT 3: Source table record counts by organization ===';
SELECT 'Application' DependencyType, a.organization_id, o.organization_name, COUNT(*) ActiveRecords
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
-- OUTPUT 4: practice_instance_dependency — configured dependencies
-- Shows what dependency types are configured per practice instance
-- If dependency_type_id is NULL, the resolve dialog can't work
-- ============================================================
PRINT '=== OUTPUT 4: Configured dependencies by practice instance ===';
SELECT d.practice_instance_id,
       pi.instance_name PracticeInstanceName,
       d.organization_id,
       d.dependency_type_id,
       COALESCE(dt.dependency_type_name, d.dependency_type, 'NULL TYPE') DependencyTypeName,
       d.dependency_name,
       d.status,
       CASE WHEN d.dependency_type_id IS NULL THEN 'MISSING - will not appear in resolve' ELSE 'OK' END TypeIdStatus
FROM grac_practice.practice_instance_dependency d
LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id
LEFT JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=d.practice_instance_id
WHERE d.status='Active'
ORDER BY d.practice_instance_id, d.dependency_type_id;

-- ============================================================
-- OUTPUT 5: Resolution rows — what the dialog should display
-- This mirrors the new second result set added to the resolve query
-- ============================================================
PRINT '=== OUTPUT 5: Resolution detail rows (dialog data) ===';
SELECT d.practice_instance_id PracticeInstanceId,
       pi.instance_name PracticeInstanceName,
       d.dependency_type_id DependencyTypeId,
       dt.dependency_type_name DependencyCategory,
       COALESCE(r.resolved_dependency_name, '') ResolvedDependencyName,
       r.resolution_id ResolutionId,
       r.resolved_dependency_id ResolvedDependencyId,
       CASE WHEN r.resolution_id IS NOT NULL THEN 'Resolved' ELSE 'Pending' END ResolutionStatus,
       COALESCE(r.remarks, '') Remarks
FROM grac_practice.practice_instance_dependency d
INNER JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id
LEFT JOIN grac_practice.practice_dependency_resolution r
    ON r.practice_instance_id=d.practice_instance_id
    AND r.dependency_type_id=d.dependency_type_id
    AND r.is_active=1
LEFT JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=d.practice_instance_id
WHERE d.status='Active'
  AND d.dependency_type_id IS NOT NULL
GROUP BY d.practice_instance_id, pi.instance_name, d.dependency_type_id, dt.dependency_type_name,
         r.resolution_id, r.resolved_dependency_id, r.resolved_dependency_name, r.remarks
ORDER BY d.practice_instance_id, dt.dependency_type_name;

-- ============================================================
-- OUTPUT 6: Simulated dependency-options API call
-- For each dependency type with source_config, shows what the
-- Dependency Object dropdown would load for each organization.
-- If this returns 0 rows, the dropdown will show "No dependency
-- objects found" — the user needs to add records first.
-- ============================================================
PRINT '=== OUTPUT 6: Dependency object availability per org/type ===';
SELECT dt.dependency_type_id DependencyTypeId,
       dt.dependency_type_name DependencyTypeName,
       sc.source_table_name SourceTable,
       o.organization_id OrganizationId,
       o.organization_name OrganizationName,
       CASE
         WHEN sc.source_table_name IS NULL THEN 'NO SOURCE CONFIG'
         WHEN OBJECT_ID(sc.source_table_name) IS NULL THEN 'SOURCE TABLE MISSING'
         ELSE 'CONFIGURED'
       END ConfigStatus
FROM grac_practice.dependency_type_master dt
LEFT JOIN grac_practice.dependency_type_source_config sc
    ON sc.dependency_type_id=dt.dependency_type_id AND sc.status='Active'
CROSS JOIN grac_practice.organization o
WHERE dt.is_active=1 AND o.status='Active'
ORDER BY o.organization_id, dt.display_order;
