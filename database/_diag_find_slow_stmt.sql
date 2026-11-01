-- =====================================================================
-- _diag_find_slow_stmt.sql  (READ-ONLY; not a migration)
--
-- Pinpoints the ACTUAL slow statement behind the Practices grid
-- (organization-requirements/query), using SQL Server's own cached
-- query stats -- no parameters or control id needed.
--
-- HOW TO USE:
--   1. In the browser, open the slow Practices page once (fire the query).
--   2. Immediately run this script against the local DB.
--   3. Read the top rows: last_ms is how long that statement's most
--      recent run took; stmt shows which statement it is.
--      - If a row whose stmt contains 'requirement_candidates' is the big
--        one -> the materialization candidate CTE (the OR-join) is the cost.
--      - If a row whose stmt contains 'PracticeInstanceCount' /
--        'OUTER APPLY' is big -> the final grid SELECT.
--      - If NOTHING here is ~1000+ ms -> the time is not in SQL at all
--        (it is the Web->API pipeline / encryption / serialization).
--
-- Needs VIEW SERVER STATE (admin on localhost has it). Reads nothing but
-- DMVs. ASCII only.
-- =====================================================================
SET NOCOUNT ON;

SELECT TOP 25
       CAST(qs.last_elapsed_time/1000.0 AS DECIMAL(10,1)) AS last_ms,
       qs.last_logical_reads,
       qs.execution_count,
       qs.last_execution_time,
       SUBSTRING(st.text,
                 (qs.statement_start_offset/2)+1,
                 ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
                        ELSE qs.statement_end_offset END - qs.statement_start_offset)/2)+1) AS stmt
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE (st.text LIKE '%requirement_candidates%'
    OR st.text LIKE '%PracticeInstanceCount%'
    OR st.text LIKE '%organization_requirement%'
    OR st.text LIKE '%organization_repository_control%')
ORDER BY qs.last_elapsed_time DESC;
