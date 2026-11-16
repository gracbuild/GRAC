-- =====================================================================
-- 518  Organization list: SpocEmail (the admin's email) for the
--      Organization Setup edit form
--
-- REQUEST (2026-11-05)
--   Organization Management > Add Organization: Admin Email and Admin
--   Full Name did not save, and did not load when the organization was
--   opened again.
--
-- WHY
--   Those two fields are not organization columns. After the
--   organization-setup save, practice.js calls provision-and-notify,
--   which creates the organization's Admin employee
--   (pm_create_organization_admin, 217). That call never ran: the save
--   returns the new id as `Id` and practice.js's
--   extractNewOrganizationId() read only OrganizationId, so it got 0 and
--   skipped provisioning without a message. That half is fixed in
--   practice.js alone.
--
--   The load half needs the admin's email on the read. 510's
--   sp_org_organization_list already derives SpocName from that Admin
--   employee; 518 re-issues it with SpocEmail beside it, picked by the
--   SAME rule (Active first, ORG_ADMIN over a role merely named Admin,
--   then the earliest), now in one OUTER APPLY instead of an inline
--   subquery so name and email always come from one employee.
--
--   Everything else in the body is 510's, unchanged. The gateway shim
--   sp_org_organizations_repository_get is not touched -- it EXECs this
--   procedure, so it returns the new column with no change.
--   No table change, no monolith change, no write-path change.
--
-- SAFE TO RE-RUN. Requires 510.
-- Rollback: 518_organization_list_spoc_email_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Guard on the COLUMNS the body reads (reissued_proc_needs_column_guard):
-- a missing column fails CREATE with Msg 207 while the script still
-- PRINTs success.
IF OBJECT_ID('grac_practice.sp_org_organization_list','P') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
   OR COL_LENGTH('grac_practice.organization','subscription_start_dt') IS NULL
   OR COL_LENGTH('grac_practice.organization','subscription_end_dt')   IS NULL
   OR COL_LENGTH('grac_practice.organization','time_zone_id')          IS NULL
   OR COL_LENGTH('grac_practice.organization','address_line1')         IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','role_id')       IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','status')        IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','employee_name') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','email')         IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U')     IS NULL
   OR COL_LENGTH('grac_practice.organization_role','role_code') IS NULL
   OR COL_LENGTH('grac_practice.organization_role','role_name') IS NULL
   OR OBJECT_ID('grac_practice.repository_subscription','U') IS NULL
   OR COL_LENGTH('grac_practice.repository_subscription','artifact_id')         IS NULL
   OR COL_LENGTH('grac_practice.repository_subscription','subscription_status') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U')  IS NULL
   OR OBJECT_ID('grac_new.artifact','U') IS NULL
   OR COL_LENGTH('grac_new.artifact','artifact_code') IS NULL
BEGIN
    PRINT 'ABORT (518): run 510 (and its prerequisites 404, 027, 217) first. Nothing was changed.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_organization_list
    @p_id          BIGINT        = 0,
    @p_status      NVARCHAR(30)  = '',
    @p_search      NVARCHAR(250) = '',
    @p_page_number INT           = 1,
    @p_page_size   INT           = 25,
    @date_from     DATE          = NULL,
    @date_to       DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @p_page_number IS NULL OR @p_page_number < 1 SET @p_page_number = 1;
    IF @p_page_size   IS NULL OR @p_page_size   < 1 SET @p_page_size   = 25;
    DECLARE @offset INT = (@p_page_number - 1) * @p_page_size;

    -- Same status handling as the monolith: the caller sends the status
    -- NAME and it is resolved to record_status_id.
    DECLARE @filter_record_status_id INT = NULL;
    IF ISNULL(@p_status, '') <> ''
        SELECT @filter_record_status_id = record_status_id
        FROM grac_practice.record_status_master
        WHERE status_name = @p_status;

    SET @p_search = ISNULL(@p_search, '');

    SELECT o.organization_id        Id,
           o.organization_code      Code,
           o.organization_name      Name,
           o.industry               Industry,
           o.entity_type            EntityType,
           o.country                Country,
           o.address_line1          AddressLine1,
           o.address_line2          AddressLine2,
           o.city                   City,
           o.state_province         StateProvince,
           o.postal_code            PostalCode,
           o.time_zone_id           TimeZoneId,
           o.subscription_start_dt  SubscriptionStartDate,
           o.subscription_end_dt    SubscriptionEndDate,
           rs.status_name           Status,
           -- 510: the organization's Admin employee -- the "Admin Full
           -- Name" supplied at onboarding. 518: read once through the
           -- OUTER APPLY below, which also yields that employee's email.
           adm.employee_name        AS SpocName,
           adm.email                AS SpocEmail,
           -- 510: up to three subscribed framework codes, then "+N more".
           -- DISTINCT on the artifact, so two releases of one framework
           -- are one entry and are counted once.
           CASE WHEN fw.total = 0 THEN N''
                ELSE ISNULL((SELECT STRING_AGG(t.artifact_code, N', ') WITHIN GROUP (ORDER BY t.artifact_code)
                               FROM (SELECT DISTINCT TOP (3) a.artifact_code
                                       FROM grac_practice.repository_subscription s
                                       JOIN grac_new.artifact a ON a.artifact_id = s.artifact_id
                                      WHERE s.organization_id = o.organization_id
                                        AND s.status = N'Active'
                                        AND ISNULL(s.subscription_status, N'Active') = N'Active'
                                      ORDER BY a.artifact_code) t), N'')
                     + CASE WHEN fw.total > 3
                            THEN N' +' + CAST(fw.total - 3 AS NVARCHAR(10)) + N' more'
                            ELSE N'' END
           END AS FrameworkSummary,
           fw.total                 AS FrameworkCount,
           COUNT(*) OVER ()         AS TotalRows
    FROM grac_practice.organization o
    JOIN grac_practice.record_status_master rs ON rs.record_status_id = o.record_status_id
    CROSS APPLY (
        SELECT COUNT(DISTINCT a.artifact_id) AS total
          FROM grac_practice.repository_subscription s
          JOIN grac_new.artifact a ON a.artifact_id = s.artifact_id
         WHERE s.organization_id = o.organization_id
           AND ISNULL(s.subscription_status, N'Active') = N'Active'
           AND s.status = N'Active'
    ) fw
    -- 518: the same pick 510 made inline (Active first, then ORG_ADMIN over
    -- a role merely named Admin, then the earliest) -- now one row giving
    -- both the name and the email.
    OUTER APPLY (
        SELECT TOP (1) e.employee_name, e.email
          FROM grac_practice.organization_employee e
          JOIN grac_practice.organization_role r ON r.role_id = e.role_id
         WHERE e.organization_id = o.organization_id
           AND (r.role_code = N'ORG_ADMIN' OR r.role_name = N'Admin')
         ORDER BY CASE WHEN e.status = N'Active' THEN 0 ELSE 1 END,
                  CASE WHEN r.role_code = N'ORG_ADMIN' THEN 0 ELSE 1 END,
                  e.employee_id
    ) adm
    WHERE (@p_id = 0 OR o.organization_id = @p_id)
      AND (@filter_record_status_id IS NULL OR o.record_status_id = @filter_record_status_id)
      AND (@date_from IS NULL OR o.entered_dt >= @date_from)
      AND (@date_to   IS NULL OR o.entered_dt <  DATEADD(DAY, 1, @date_to))
      AND (@p_search = ''
           OR o.organization_code LIKE '%' + @p_search + '%'
           OR o.organization_name LIKE '%' + @p_search + '%')
    ORDER BY o.organization_name
    OFFSET @offset ROWS FETCH NEXT @p_page_size ROWS ONLY;
END;
GO

PRINT '518: sp_org_organization_list re-issued with SpocEmail.';
GO

-- Verification: SpocName and SpocEmail must come from the same employee.
PRINT '--- 518 verification ---';
EXEC grac_practice.sp_org_organizations_repository_get
     @p_entity_type = N'organizations', @p_action = N'QUERY',
     @p_payload = N'{"pageNumber":1,"pageSize":5}';
PRINT '518: done. No Api restart needed (the shim already exists); hard-refresh the browser for practice.js.';
GO
SET NOEXEC OFF;
GO
