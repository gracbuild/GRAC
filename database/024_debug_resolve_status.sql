/*  ============================================================
    024_debug_resolve_status.sql
    Comprehensive diagnostic for Resolve status showing "Pending"
    after save.

    THREE query paths exist — this tests all of them:
    1. C# QueryResolveFallbackAsync (screen.Key="resolve")
    2. C# QueryDependencyWorkbenchAsync (screen.Key="practice-operationalization")
    3. Stored procedure practice-operationalization handler

    Run this after saving a resolution to see exactly what each
    path would return.
    ============================================================ */

-- ============================================================
-- OUTPUT 1: All saved resolution records (raw data)
-- ============================================================
PRINT '=== OUTPUT 1: Saved resolution records ===';
SELECT
    r.resolution_id,
    r.organization_id,
    r.practice_instance_id,
    r.dependency_type_id,
    dt.dependency_type_name,
    r.resolved_dependency_id,
    r.resolved_dependency_name,
    r.resolution_status_id,
    r.resolution_status,
    r.is_active,
    drs.status_code StatusMasterCode,
    drs.status_name StatusMasterName,
    r.entered_by,
    r.entered_dt,
    r.updated_by,
    r.updated_dt
FROM grac_practice.practice_dependency_resolution r
LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=r.dependency_type_id
LEFT JOIN grac_practice.dependency_resolution_status_master drs ON drs.resolution_status_id=r.resolution_status_id
ORDER BY r.entered_dt DESC;

-- ============================================================
-- OUTPUT 2: dependency_resolution_status_master contents
-- ============================================================
PRINT '=== OUTPUT 2: Resolution status master entries ===';
SELECT * FROM grac_practice.dependency_resolution_status_master;

-- ============================================================
-- OUTPUT 3: C# QueryResolveFallbackAsync status derivation
-- (This is the path used when screen.Key="resolve")
-- Tests the resolution_agg CTE that counts by is_active=1
-- ============================================================
PRINT '=== OUTPUT 3: C# Resolve Fallback status (screen=resolve) ===';
;WITH resolution_agg_csharp AS (
    SELECT r.organization_id, r.practice_instance_id,
        COUNT(1) ResolvedDependenciesCount
    FROM grac_practice.practice_dependency_resolution r
    WHERE r.is_active = 1
    GROUP BY r.organization_id, r.practice_instance_id
)
SELECT
    pi.practice_instance_id,
    pi.instance_name,
    pi.organization_id,
    COALESCE(ra.ResolvedDependenciesCount, 0) ResolvedDependenciesCount,
    CASE
        WHEN COALESCE(ra.ResolvedDependenciesCount, 0) > 0 THEN N'Resolved'
        ELSE N'Pending'
    END CSharpResolveFallbackStatus,
    N'QueryResolveFallbackAsync line 1609' QueryPath
FROM grac_practice.practice_instance pi
LEFT JOIN resolution_agg_csharp ra
    ON ra.organization_id = pi.organization_id
   AND ra.practice_instance_id = pi.practice_instance_id
WHERE pi.status = 'Active'
  AND EXISTS (
    SELECT 1 FROM grac_practice.practice_instance_dependency d
    WHERE d.practice_instance_id = pi.practice_instance_id
      AND d.status = 'Active' AND d.dependency_type_id IS NOT NULL
  )
ORDER BY pi.instance_name;

-- ============================================================
-- OUTPUT 4: C# QueryDependencyWorkbenchAsync status derivation
-- (This is the path used when screen.Key="practice-operationalization")
-- Tests the res_all OUTER APPLY that checks resolved_dependency_names
-- ============================================================
PRINT '=== OUTPUT 4: C# Workbench status (screen=practice-operationalization) ===';
SELECT
    d.dependency_id,
    pi.practice_instance_id,
    pi.instance_name,
    pi.organization_id,
    d.dependency_type_id,
    dt.dependency_type_name DependencyCategory,
    res.resolution_id,
    res.resolved_dependency_name SingleResolvedName,
    res_all.resolved_dependency_names AllResolvedNames,
    CASE WHEN res_all.resolved_dependency_names IS NULL
         THEN N'Pending'
         ELSE N'Resolved'
    END CSharpWorkbenchStatus,
    N'QueryDependencyWorkbenchAsync line 1772' QueryPath
FROM grac_practice.practice_instance_dependency d
JOIN grac_practice.practice_instance pi
    ON pi.practice_instance_id = d.practice_instance_id
   AND pi.organization_id = d.organization_id
JOIN grac_practice.dependency_type_master dt
    ON dt.dependency_type_id = d.dependency_type_id
OUTER APPLY (
    SELECT TOP 1 r.*
    FROM grac_practice.practice_dependency_resolution r
    WHERE r.organization_id = d.organization_id
      AND r.practice_instance_id = d.practice_instance_id
      AND r.dependency_type_id = d.dependency_type_id
      AND r.is_active = 1
    ORDER BY ISNULL(r.updated_dt, r.entered_dt) DESC, r.resolution_id DESC
) res
OUTER APPLY (
    SELECT
        STUFF((
            SELECT N', ' + r2.resolved_dependency_name
            FROM grac_practice.practice_dependency_resolution r2
            WHERE r2.organization_id = d.organization_id
              AND r2.practice_instance_id = d.practice_instance_id
              AND r2.dependency_type_id = d.dependency_type_id
              AND r2.is_active = 1
            ORDER BY r2.resolved_dependency_name
            FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') resolved_dependency_names
) res_all
WHERE d.status = 'Active'
ORDER BY pi.instance_name, dt.dependency_type_name;

-- ============================================================
-- OUTPUT 5: Stored procedure resolved_categories CTE
-- (Only used if C# fallback is bypassed)
-- Tests the FIXED CTE that uses resolution_status column
-- ============================================================
PRINT '=== OUTPUT 5: Stored proc status (fixed CTE) ===';
;WITH resolved_categories_fixed AS (
    SELECT r.organization_id, r.practice_instance_id, r.dependency_type_id
    FROM grac_practice.practice_dependency_resolution r
    WHERE r.is_active = 1
      AND r.resolution_status = N'Resolved'
    GROUP BY r.organization_id, r.practice_instance_id, r.dependency_type_id
),
resolution_agg_fixed AS (
    SELECT organization_id, practice_instance_id,
        COUNT(1) ResolvedDependenciesCount
    FROM resolved_categories_fixed
    GROUP BY organization_id, practice_instance_id
)
SELECT
    pi.practice_instance_id,
    pi.instance_name,
    pi.organization_id,
    COALESCE(res.ResolvedDependenciesCount, 0) ResolvedDependenciesCount,
    CASE
        WHEN COALESCE(res.ResolvedDependenciesCount, 0) > 0 THEN N'Resolved'
        ELSE N'Pending'
    END StoredProcFixedStatus,
    N'Stored proc resolved_categories (fixed)' QueryPath
FROM grac_practice.practice_instance pi
LEFT JOIN resolution_agg_fixed res
    ON res.organization_id = pi.organization_id
   AND res.practice_instance_id = pi.practice_instance_id
WHERE pi.status = 'Active'
  AND EXISTS (
    SELECT 1 FROM grac_practice.practice_instance_dependency d
    WHERE d.practice_instance_id = pi.practice_instance_id
      AND d.status = 'Active' AND d.dependency_type_id IS NOT NULL
  )
ORDER BY pi.instance_name;

-- ============================================================
-- OUTPUT 6: Data integrity checks
-- ============================================================
PRINT '=== OUTPUT 6: Data integrity checks ===';
SELECT
    'Resolution rows with is_active=1' CheckName,
    COUNT(*) [Count]
FROM grac_practice.practice_dependency_resolution
WHERE is_active = 1
UNION ALL
SELECT
    'Resolution rows with NULL resolution_status_id',
    COUNT(*) [Count]
FROM grac_practice.practice_dependency_resolution
WHERE resolution_status_id IS NULL AND is_active = 1
UNION ALL
SELECT
    'Resolution rows with resolution_status=Resolved',
    COUNT(*) [Count]
FROM grac_practice.practice_dependency_resolution
WHERE resolution_status = N'Resolved' AND is_active = 1
UNION ALL
SELECT
    'Resolution rows with NULL resolved_dependency_name',
    COUNT(*) [Count]
FROM grac_practice.practice_dependency_resolution
WHERE resolved_dependency_name IS NULL AND is_active = 1
UNION ALL
SELECT
    'Status master entries',
    COUNT(*) [Count]
FROM grac_practice.dependency_resolution_status_master
UNION ALL
SELECT
    'practice_instance_dependency rows (Active)',
    COUNT(*) [Count]
FROM grac_practice.practice_instance_dependency
WHERE status = 'Active' AND dependency_type_id IS NOT NULL;

PRINT '';
PRINT '=== DIAGNOSIS ===';
PRINT 'If OUTPUT 3 shows Resolved but grid shows Pending → C# fallback is not being reached (check CanUseOrganizationFallback).';
PRINT 'If OUTPUT 4 shows Pending → resolved_dependency_name is NULL in saved rows.';
PRINT 'If OUTPUT 5 shows Pending → stored procedure CTE fix was not deployed.';
PRINT 'If OUTPUT 6 shows NULL resolution_status_id → run 025_seed_resolution_status_master.sql.';
PRINT 'If OUTPUT 6 shows NULL resolved_dependency_name → dependency object lookup failed during save.';
