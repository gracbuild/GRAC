-- =====================================================================
-- DIAGNOSTIC: Audit Traceability page shows no rows.
-- Read-only. Run the whole script and send the three result sets.
--
-- The page reads grac_practice.practice_audit_trace through the generic
-- query procedure (dbo.pm_get_practice_repository, branch 'audit-trace',
-- latest body in 404). Rows are written mainly by the generic save
-- procedure (dbo.pm_manage_practice_repository) and the asset procedures
-- (419-461); most newer flows (risk, task, applicability, statements)
-- save through their own procedures and do not write here.
-- =====================================================================
SET NOCOUNT ON;

PRINT '=== 1. Total rows and date range ===';
SELECT COUNT_BIG(*) AS total_rows, MIN(entered_dt) AS first_entry, MAX(entered_dt) AS last_entry
  FROM grac_practice.practice_audit_trace;

PRINT '=== 2. Rows per entity type / action / status ===';
SELECT entity_type, action_type, status, COUNT_BIG(*) AS rows_, MAX(entered_dt) AS last_entry
  FROM grac_practice.practice_audit_trace
 GROUP BY entity_type, action_type, status
 ORDER BY MAX(entered_dt) DESC;

PRINT '=== 3. What the page query returns (first page, no filters) ===';
EXEC dbo.pm_get_practice_repository
     @p_entity_type = N'audit-trace', @p_action = N'QUERY', @p_id = 0,
     @p_search = N'', @p_status = N'',
     @p_payload = N'{"pageNumber":1,"pageSize":25,"_security":{"isSystemAdmin":true}}',
     @p_usr_id = N'diag';
