-- _diag_scope_gate_perf.sql  (READ-ONLY; SSMS against UAT)
-- Reads comparison OLD vs NEW scope gate for org 3, returned as a GRID.
-- GO between batches so each gate's stats are captured before we read them.
-- Correctness already proven separately (404=404, 0 diffs).
SET NOCOUNT ON;
IF OBJECT_ID('tempdb..#applicable') IS NOT NULL DROP TABLE #applicable;
SELECT sofs.org_statement_id
INTO #applicable
FROM grac_practice.organization_framework_statements sofs
JOIN grac_practice.applicability_status_master saps
    ON saps.applicability_status_id=sofs.applicability_status_id
   AND saps.status_name=N'Applicable'
WHERE sofs.organization_id=3 AND sofs.status='Active'
  AND (NOT EXISTS(SELECT 1 FROM grac_practice.repository_subscription ss0
                  WHERE ss0.organization_id=sofs.organization_id AND ss0.release_id=sofs.release_id)
       OR EXISTS(SELECT 1 FROM grac_practice.repository_subscription ss
                 WHERE ss.organization_id=sofs.organization_id AND ss.release_id=sofs.release_id
                   AND ss.status='Active' AND ISNULL(ss.subscription_status,'Active')='Active'
                   AND ss.owner_id IS NOT NULL));
CREATE UNIQUE CLUSTERED INDEX ix_app ON #applicable(org_statement_id) WITH (IGNORE_DUP_KEY=ON);
GO
SELECT COUNT(*) AS old_rows FROM grac_practice.organization_requirement q
WHERE q.organization_id=3 AND (
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
        ) /*SCOPEGATE-OLD-MARKER*/;
GO
SELECT COUNT(*) AS new_rows FROM grac_practice.organization_requirement q
WHERE q.organization_id=3 AND (
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
) /*SCOPEGATE-NEW-MARKER*/;
GO
SELECT
    CASE WHEN st.text LIKE '%SCOPEGATE-OLD'+'-MARKER%' THEN 'OLD correlated gate'
         ELSE 'NEW set-based gate' END AS gate,
    qs.last_logical_reads,
    CAST(qs.last_elapsed_time/1000.0 AS DECIMAL(10,1)) AS last_ms
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE (st.text LIKE '%SCOPEGATE-OLD'+'-MARKER%' OR st.text LIKE '%SCOPEGATE-NEW'+'-MARKER%')
  AND st.text NOT LIKE '%dm_exec_query_stats%'
ORDER BY gate;
GO
DROP TABLE #applicable;
GO
