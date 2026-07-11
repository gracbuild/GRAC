/*  ============================================================
    021_debug_resolve_dependency_types.sql
    Diagnostic script: Resolve page - dependency type loading

    Root cause: dependency_type_master seed only had Team and
    Committee. Application, Tool, Vendor, Asset, Process, Location,
    and Person were missing. Without master rows, the dependency-types
    lookup returns no entries for these types, so the Resolve page
    category tabs can't filter by them.

    After running the updated 002_practice_management_procedures.sql
    (or deployment scripts), run this to verify the fix.
    ============================================================ */

-- ============================================================
-- OUTPUT 1: dependency_type_master - all rows
-- Expect: Application, Tool, Vendor, Asset, Process, Location,
--         Person, Team, Committee (9 rows, all is_active=1)
-- ============================================================
PRINT '=== OUTPUT 1: dependency_type_master ===';
SELECT dependency_type_id, dependency_type_code, dependency_type_name,
       display_order, is_active
FROM grac_practice.dependency_type_master
ORDER BY display_order;

-- ============================================================
-- OUTPUT 2: dependency_type_source_config - all rows
-- Expect: one config row per dependency type (9 rows)
-- If any type shows NULL dependency_type_id, the master seed
-- was not applied before the source_config seed.
-- ============================================================
PRINT '=== OUTPUT 2: dependency_type_source_config ===';
SELECT sc.dependency_type_id, sc.dependency_type_name, sc.source_type,
       sc.source_table_name, sc.id_column_name, sc.display_column_name,
       sc.organization_filter_column, sc.status,
       CASE WHEN OBJECT_ID(sc.source_table_name) IS NOT NULL THEN 'EXISTS' ELSE 'MISSING' END SourceTableExists
FROM grac_practice.dependency_type_source_config sc
ORDER BY sc.dependency_type_id;

-- ============================================================
-- OUTPUT 3: dependency-types lookup (what the UI receives)
-- Expect: same types as OUTPUT 1, with string values of IDs
-- ============================================================
PRINT '=== OUTPUT 3: dependency-types lookup values ===';
SELECT 'dependency-types' LookupType,
       CAST(dependency_type_id AS NVARCHAR(40)) Value,
       dependency_type_name Label
FROM grac_practice.dependency_type_master
WHERE is_active=1
ORDER BY display_order;

-- ============================================================
-- OUTPUT 4: practice_instance_dependency summary
-- Shows which dependency types are actually configured
-- ============================================================
PRINT '=== OUTPUT 4: configured dependencies by type ===';
SELECT d.dependency_type_id,
       COALESCE(dt.dependency_type_name, d.dependency_type, 'NULL TYPE ID') TypeName,
       COUNT(*) DependencyCount,
       COUNT(DISTINCT d.practice_instance_id) PracticeInstanceCount
FROM grac_practice.practice_instance_dependency d
LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id
WHERE d.status='Active'
GROUP BY d.dependency_type_id, COALESCE(dt.dependency_type_name, d.dependency_type, 'NULL TYPE ID')
ORDER BY DependencyCount DESC;

-- ============================================================
-- OUTPUT 5: dependencies with NULL dependency_type_id
-- These records won't show on any resolve page tab
-- ============================================================
PRINT '=== OUTPUT 5: dependencies with NULL dependency_type_id ===';
SELECT d.dependency_id, d.practice_instance_id, d.organization_id,
       d.dependency_type, d.dependency_name, d.dependency_type_id,
       d.status
FROM grac_practice.practice_instance_dependency d
WHERE d.dependency_type_id IS NULL AND d.status='Active';

-- ============================================================
-- OUTPUT 6: Cross-check - types referenced in source_config
-- that DON'T exist in dependency_type_master
-- Should return 0 rows after fix
-- ============================================================
PRINT '=== OUTPUT 6: orphaned source_config entries ===';
SELECT sc.dependency_type_source_config_id, sc.dependency_type_id, sc.dependency_type_name
FROM grac_practice.dependency_type_source_config sc
WHERE NOT EXISTS(
  SELECT 1 FROM grac_practice.dependency_type_master dt
  WHERE dt.dependency_type_id=sc.dependency_type_id
);
