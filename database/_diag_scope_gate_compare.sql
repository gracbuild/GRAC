-- _diag_scope_gate_compare.sql  (READ-ONLY; SSMS against UAT)
-- Proves the new SET-BASED scope gate == the old correlated gate (same
-- requirement IDs) AND is cheaper, for org 3, WITHOUT rebuilding the API.
-- Old gate = PracticeStatementScopeSql (extracted verbatim from the C#).
-- New gate = membership in #applicable (org's Applicable statements computed ONCE).
SET NOCOUNT ON;
DECLARE @organization_id int = 3;

-- #applicable: the org's Applicable statements, same subscription test as the
-- old gate's inner EXISTS -- built ONCE instead of per requirement.
IF OBJECT_ID('tempdb..#applicable') IS NOT NULL DROP TABLE #applicable;
SELECT sofs.org_statement_id
INTO #applicable
FROM grac_practice.organization_framework_statements sofs
JOIN grac_practice.applicability_status_master saps
    ON saps.applicability_status_id=sofs.applicability_status_id
   AND saps.status_name=N'Applicable'
WHERE sofs.organization_id=@organization_id
  AND sofs.status='Active'
  AND (NOT EXISTS(
           SELECT 1 FROM grac_practice.repository_subscription ss0
           WHERE ss0.organization_id=sofs.organization_id
             AND ss0.release_id=sofs.release_id)
       OR EXISTS(
           SELECT 1 FROM grac_practice.repository_subscription ss
           WHERE ss.organization_id=sofs.organization_id
             AND ss.release_id=sofs.release_id
             AND ss.status='Active'
             AND ISNULL(ss.subscription_status,'Active')='Active'
             AND ss.owner_id IS NOT NULL));
CREATE UNIQUE CLUSTERED INDEX ix_app ON #applicable(org_statement_id)
    WITH (IGNORE_DUP_KEY=ON);

-- ===== CORRECTNESS: the two gates must select the SAME requirement set =====
;WITH old_set AS (
    SELECT q.organization_requirement_id
    FROM grac_practice.organization_requirement q
    WHERE q.organization_id=@organization_id AND (
            ISNULL(q.origin_type,N'')<>N'Repository'
            OR (q.org_statement_id IS NULL
                AND NOT EXISTS(
                    SELECT 1 FROM grac_practice.organization_statement_practice_mapping lm
                    WHERE lm.org_practice_id=q.organization_requirement_id
                      AND lm.organization_id=q.organization_id
                      AND lm.status='Active'))
            OR EXISTS(
                SELECT 1
                FROM grac_practice.organization_framework_statements sofs
                JOIN grac_practice.applicability_status_master saps
                    ON saps.applicability_status_id=sofs.applicability_status_id
                   AND saps.status_name=N'Applicable'
                WHERE sofs.organization_id=q.organization_id
                  AND sofs.status='Active'
                  AND (sofs.org_statement_id=q.org_statement_id
                       OR EXISTS(
                           SELECT 1 FROM grac_practice.organization_statement_practice_mapping sm
                           WHERE sm.org_practice_id=q.organization_requirement_id
                             AND sm.organization_id=q.organization_id
                             AND sm.org_statement_id=sofs.org_statement_id
                             AND sm.status='Active'))
                  AND (NOT EXISTS(
                           SELECT 1 FROM grac_practice.repository_subscription ss0
                           WHERE ss0.organization_id=sofs.organization_id
                             AND ss0.release_id=sofs.release_id)
                       OR EXISTS(
                           SELECT 1 FROM grac_practice.repository_subscription ss
                           WHERE ss.organization_id=sofs.organization_id
                             AND ss.release_id=sofs.release_id
                             AND ss.status='Active'
                             AND ISNULL(ss.subscription_status,'Active')='Active'
                             AND ss.owner_id IS NOT NULL)))
        )
),
new_set AS (
    SELECT q.organization_requirement_id
    FROM grac_practice.organization_requirement q
    WHERE q.organization_id=@organization_id AND (
    ISNULL(q.origin_type,N'')<>N'Repository'
    OR (q.org_statement_id IS NULL
        AND NOT EXISTS(
            SELECT 1 FROM grac_practice.organization_statement_practice_mapping lm
            WHERE lm.org_practice_id=q.organization_requirement_id
              AND lm.organization_id=q.organization_id
              AND lm.status='Active'))
    OR EXISTS(SELECT 1 FROM #applicable a WHERE a.org_statement_id=q.org_statement_id)
    OR EXISTS(
        SELECT 1 FROM grac_practice.organization_statement_practice_mapping sm
        JOIN #applicable a ON a.org_statement_id=sm.org_statement_id
        WHERE sm.org_practice_id=q.organization_requirement_id
          AND sm.organization_id=q.organization_id
          AND sm.status='Active')
)
)
SELECT
    (SELECT COUNT(*) FROM old_set) AS old_count,
    (SELECT COUNT(*) FROM new_set) AS new_count,
    (SELECT COUNT(*) FROM (SELECT organization_requirement_id FROM old_set
                           EXCEPT SELECT organization_requirement_id FROM new_set) d) AS in_old_not_new,
    (SELECT COUNT(*) FROM (SELECT organization_requirement_id FROM new_set
                           EXCEPT SELECT organization_requirement_id FROM old_set) d) AS in_new_not_old;
-- EXPECT: old_count = new_count, and both diffs = 0.

-- ===== PERFORMANCE: reads/time for each gate (read the Messages tab) =====
PRINT '--- OLD correlated gate ---';
SET STATISTICS IO ON; SET STATISTICS TIME ON;
SELECT COUNT(*) AS old_rows
FROM grac_practice.organization_requirement q
WHERE q.organization_id=@organization_id AND (
            ISNULL(q.origin_type,N'')<>N'Repository'
            OR (q.org_statement_id IS NULL
                AND NOT EXISTS(
                    SELECT 1 FROM grac_practice.organization_statement_practice_mapping lm
                    WHERE lm.org_practice_id=q.organization_requirement_id
                      AND lm.organization_id=q.organization_id
                      AND lm.status='Active'))
            OR EXISTS(
                SELECT 1
                FROM grac_practice.organization_framework_statements sofs
                JOIN grac_practice.applicability_status_master saps
                    ON saps.applicability_status_id=sofs.applicability_status_id
                   AND saps.status_name=N'Applicable'
                WHERE sofs.organization_id=q.organization_id
                  AND sofs.status='Active'
                  AND (sofs.org_statement_id=q.org_statement_id
                       OR EXISTS(
                           SELECT 1 FROM grac_practice.organization_statement_practice_mapping sm
                           WHERE sm.org_practice_id=q.organization_requirement_id
                             AND sm.organization_id=q.organization_id
                             AND sm.org_statement_id=sofs.org_statement_id
                             AND sm.status='Active'))
                  AND (NOT EXISTS(
                           SELECT 1 FROM grac_practice.repository_subscription ss0
                           WHERE ss0.organization_id=sofs.organization_id
                             AND ss0.release_id=sofs.release_id)
                       OR EXISTS(
                           SELECT 1 FROM grac_practice.repository_subscription ss
                           WHERE ss.organization_id=sofs.organization_id
                             AND ss.release_id=sofs.release_id
                             AND ss.status='Active'
                             AND ISNULL(ss.subscription_status,'Active')='Active'
                             AND ss.owner_id IS NOT NULL)))
        );
SET STATISTICS IO OFF; SET STATISTICS TIME OFF;

PRINT '--- NEW set-based gate (#applicable built once) ---';
SET STATISTICS IO ON; SET STATISTICS TIME ON;
SELECT COUNT(*) AS new_rows
FROM grac_practice.organization_requirement q
WHERE q.organization_id=@organization_id AND (
    ISNULL(q.origin_type,N'')<>N'Repository'
    OR (q.org_statement_id IS NULL
        AND NOT EXISTS(
            SELECT 1 FROM grac_practice.organization_statement_practice_mapping lm
            WHERE lm.org_practice_id=q.organization_requirement_id
              AND lm.organization_id=q.organization_id
              AND lm.status='Active'))
    OR EXISTS(SELECT 1 FROM #applicable a WHERE a.org_statement_id=q.org_statement_id)
    OR EXISTS(
        SELECT 1 FROM grac_practice.organization_statement_practice_mapping sm
        JOIN #applicable a ON a.org_statement_id=sm.org_statement_id
        WHERE sm.org_practice_id=q.organization_requirement_id
          AND sm.organization_id=q.organization_id
          AND sm.status='Active')
);
SET STATISTICS IO OFF; SET STATISTICS TIME OFF;

DROP TABLE #applicable;
