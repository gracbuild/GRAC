-- Why do the "Govern project security" instances not show in Operationalize?
-- sp_resolve_instance_list INNER JOINs grac_practice.practice p on practice_id,
-- so an instance whose practice row is missing/inactive is dropped even though
-- the practice_instance row exists. This finds the instances and tests that join.
SET NOCOUNT ON;

-- 1. The instances themselves: org, practice_id, status, owner.
SELECT pi.practice_instance_id, pi.instance_code, pi.instance_name,
       pi.organization_id, pi.practice_id, pi.status, pi.primary_owner_id,
       COALESCE(ims.status_name, pi.implementation_status) AS ImplementationStatus
FROM   grac_practice.practice_instance pi
LEFT   JOIN grac_practice.implementation_status_master ims
       ON ims.implementation_status_id = pi.implementation_status_id
WHERE  pi.instance_name LIKE N'Govern project security%'
ORDER  BY pi.practice_instance_id;

-- 2. THE TEST: does each instance's practice row exist and is it Active?
--    A blank/absent PracticeStatus here = the INNER JOIN in
--    sp_resolve_instance_list drops the instance -> not shown on the page.
SELECT pi.practice_instance_id, pi.instance_code, pi.practice_id,
       p.practice_id                         AS JoinedPracticeId,
       p.status                              AS PracticeStatus,
       p.organization_requirement_id         AS OrgRequirementId,
       CASE WHEN p.practice_id IS NULL THEN 'DROPPED -- no practice row'
            WHEN p.status <> N'Active'  THEN CONCAT('DROPPED -- practice status = ', p.status)
            ELSE 'joins OK' END               AS Verdict
FROM   grac_practice.practice_instance pi
LEFT   JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
WHERE  pi.instance_name LIKE N'Govern project security%'
ORDER  BY pi.practice_instance_id;

-- 3. What the Operationalize list returns for THAT org (admin). Compare to (1):
--    any instance in (1) missing here is being filtered out by the list proc.
DECLARE @org BIGINT = (SELECT TOP 1 organization_id FROM grac_practice.practice_instance
                       WHERE instance_name LIKE N'Govern project security%');
PRINT CONCAT('--- sp_resolve_instance_list for org ', @org, ' (admin) ---');
EXEC grac_practice.sp_resolve_instance_list
     @organization_id = @org, @caller_employee_id = NULL, @is_admin = 1,
     @include_retired = 1, @page_number = 1, @page_size = 200;
GO
