-- Diagnostic (read-only) for 528: Governance dashboard practice implemented KPI.
-- Set @org, run, send back all three result sets. Nothing is changed.
DECLARE @org BIGINT = 1;   -- organization id selected on the dashboard

-- 1. Is 528 live in this database?
SELECT CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_dashboard_governance')) LIKE '%practices_implemented_n%'
            THEN '528 LIVE' ELSE '528 NOT RUN' END AS proc_version;

-- 2. KPI rows the dashboard receives (look for practices / implemented).
EXEC grac_practice.sp_dashboard_governance @organization_id = @org, @caller_employee_id = NULL, @is_admin = 1;

-- 3. Per-practice roll-up (applicable practices): instances / implemented.
SELECT p.practice_id, p.practice_code, p.applicability_status,
       COUNT(pi.practice_instance_id)                                AS active_instances,
       COUNT(CASE WHEN ism.status_code = N'Implemented' THEN 1 END)  AS implemented_instances
  FROM grac_practice.practice p
  LEFT JOIN grac_practice.practice pp ON pp.organization_requirement_id = p.organization_requirement_id
  LEFT JOIN grac_practice.practice_instance pi ON pi.practice_id = pp.practice_id
                                              AND pi.organization_id = p.organization_id
                                              AND pi.status = N'Active'
  LEFT JOIN grac_practice.implementation_status_master ism ON ism.implementation_status_id = pi.implementation_status_id
 WHERE p.organization_id = @org AND p.status = N'Active' AND p.applicability_status = N'Applicable'
 GROUP BY p.practice_id, p.practice_code, p.applicability_status
 ORDER BY implemented_instances DESC, p.practice_code;
