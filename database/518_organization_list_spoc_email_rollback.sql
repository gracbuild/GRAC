-- =====================================================================
-- 518 ROLLBACK  Restore 510's sp_org_organization_list (no SpocEmail)
--
-- Re-issues the procedure body exactly as 510 created it. The Organization
-- Setup form then shows the admin's name only (email blank, read-only);
-- the save-side fix in practice.js does not depend on this column.
-- ASCII-only. Safe to re-run.
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
    PRINT 'ABORT (518 rollback): run 510 (and its prerequisites 404, 027, 217) first. Nothing was changed.';
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
           -- Name" supplied at onboarding. Active preferred, then the
           -- earliest, so a re-provisioned org still shows one name.
           (SELECT TOP (1) e.employee_name
              FROM grac_practice.organization_employee e
              JOIN grac_practice.organization_role r ON r.role_id = e.role_id
             WHERE e.organization_id = o.organization_id
               AND (r.role_code = N'ORG_ADMIN' OR r.role_name = N'Admin')
             ORDER BY CASE WHEN e.status = N'Active' THEN 0 ELSE 1 END,
                      CASE WHEN r.role_code = N'ORG_ADMIN' THEN 0 ELSE 1 END,
                      e.employee_id) AS SpocName,
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

PRINT '518 rollback: sp_org_organization_list restored to the 510 body.';
GO
SET NOEXEC OFF;
GO
