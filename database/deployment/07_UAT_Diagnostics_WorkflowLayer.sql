/*
  Practice Management — Workflow-Layer UAT diagnostics
  Runs after 05_UAT_Setup_Diagnostics.sql. Verifies Wave 1 additions.

  Charter §5 forbids modifying existing files under database/deployment/;
  we honour that by adding smoke checks in a new numbered file rather than
  appending to 05_UAT_Setup_Diagnostics.sql.

  Charter §9: "smoke test appended to 05_UAT_Setup_Diagnostics.sql" is
  interpreted here as "extend the UAT diagnostics surface" — this file
  is the extension.
*/
SET NOCOUNT ON;

--------------------------------------------------------------------
-- §12.1.1 State-machine framework smoke checks
--------------------------------------------------------------------
SELECT 'grac_practice.entity_status_master' AS ObjectName,
       COUNT_BIG(1) AS RecordCount
FROM grac_practice.entity_status_master;

SELECT 'grac_practice.entity_state_transition_rule' AS ObjectName,
       COUNT_BIG(1) AS RecordCount
FROM grac_practice.entity_state_transition_rule;

SELECT 'Task lifecycle seed present' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM grac_practice.entity_status_master
           WHERE entity_type = N'Task' AND status_code = N'Open')
           AND EXISTS (
           SELECT 1 FROM grac_practice.entity_status_master
           WHERE entity_type = N'Task' AND status_code = N'Closed')
       THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Assignment lifecycle seed present' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM grac_practice.entity_status_master
           WHERE entity_type = N'Assignment' AND status_code = N'Nominated')
           AND EXISTS (
           SELECT 1 FROM grac_practice.entity_status_master
           WHERE entity_type = N'Assignment' AND status_code = N'Active')
       THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Waiver lifecycle seed present' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM grac_practice.entity_status_master
           WHERE entity_type = N'Waiver' AND status_code = N'Draft')
           AND EXISTS (
           SELECT 1 FROM grac_practice.entity_status_master
           WHERE entity_type = N'Waiver' AND status_code = N'Expired')
       THEN 'PASS' ELSE 'FAIL' END AS Result;

-- fn_is_transition_allowed happy path: Open -> Assigned should be legal
SELECT 'fn_is_transition_allowed(Task, Open, Assigned)' AS Check_,
       CASE grac_practice.fn_is_transition_allowed(N'Task', N'Open', N'Assigned', NULL)
            WHEN 1 THEN 'PASS' ELSE 'FAIL' END AS Result;

-- fn_is_transition_allowed rejects illegal path: Open -> Closed skipping states
SELECT 'fn_is_transition_allowed rejects Task Open->Closed' AS Check_,
       CASE grac_practice.fn_is_transition_allowed(N'Task', N'Open', N'Closed', NULL)
            WHEN 0 THEN 'PASS' ELSE 'FAIL' END AS Result;

-- Reopening Closed requires Admin role
SELECT 'Reopen (Closed->Open) allowed as Admin' AS Check_,
       CASE grac_practice.fn_is_transition_allowed(N'Task', N'Closed', N'Open', N'Admin')
            WHEN 1 THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Reopen (Closed->Open) rejected without role' AS Check_,
       CASE grac_practice.fn_is_transition_allowed(N'Task', N'Closed', N'Open', NULL)
            WHEN 0 THEN 'PASS' ELSE 'FAIL' END AS Result;

--------------------------------------------------------------------
-- §12.1.6 Origin-aware permission smoke checks
--------------------------------------------------------------------
SELECT 'grac_practice.origin_type_master' AS ObjectName,
       COUNT_BIG(1) AS RecordCount
FROM grac_practice.origin_type_master;

SELECT 'grac_practice.rbac_rule' AS ObjectName,
       COUNT_BIG(1) AS RecordCount
FROM grac_practice.rbac_rule;

SELECT 'fn_pm_can_mutate default GRAC-admin GLOBAL' AS Check_,
       grac_practice.fn_pm_can_mutate(N'Release', 0, N'Admin', N'GLOBAL', N'GRAC', N'RETIRE_CONTROL') AS Verdict;
