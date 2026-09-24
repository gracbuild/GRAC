-- =====================================================================
-- _diag_operationalize_missing_instance.sql
--
-- "I marked a practice applicable and configured 2 teams, but the
--  instance did not appear on the Operationalize page."
--
-- sp_practice_instance_configure creates the practice_instance row
-- DIRECTLY (default implementation_status = 'Not Implemented'); it does
-- NOT open a task, so this is unrelated to the task-transition bug.
-- Either the row was not created (configure threw) or it is being
-- filtered out of the Operationalize list. This tells you which.
--
-- READ-ONLY. Set @org_id to the organization you configured under.
-- =====================================================================
SET NOCOUNT ON;
DECLARE @org_id BIGINT = 2;   -- <<< the organization you were working in

-- 1. Every non-retired practice instance for this org, newest first.
--    If your just-configured instance is NOT here, configure did not
--    create it (look for an error on the Configure save). If it IS here,
--    the row exists and the Operationalize page is filtering/looking at a
--    different organization.
SELECT TOP 50
       pi.practice_instance_id, pi.instance_code, pi.instance_name,
       pi.organization_id, pi.status,
       COALESCE(ims.status_name, pi.implementation_status) AS ImplementationStatus
FROM   grac_practice.practice_instance pi
LEFT   JOIN grac_practice.implementation_status_master ims
       ON ims.implementation_status_id = pi.implementation_status_id
WHERE  pi.organization_id = @org_id
ORDER  BY pi.practice_instance_id DESC;

-- 2. What the Operationalize list actually returns for this org as ADMIN
--    (mirrors the page for a GLOBAL/ORGANIZATION-scope user). If section 1
--    shows the instance but this returns 0 rows, the filter/scope is the
--    problem, not the data.
PRINT '--- sp_resolve_instance_list (admin, no filters) ---';
EXEC grac_practice.sp_resolve_instance_list
     @organization_id     = @org_id,
     @caller_employee_id  = NULL,
     @is_admin            = 1,
     @include_retired     = 0,
     @page_number         = 1,
     @page_size           = 50;
GO
