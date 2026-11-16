-- =====================================================================
-- 510  Organization list: SPOC name + subscribed frameworks
--
-- REQUEST (2026-11-02)
--   Organization Management's landing page becomes a list of
--   organizations with these columns:
--     Organisation Short Name, Organisation Long Name, Start Date,
--     End Date, Selected Standards and Frameworks, SPOC Name,
--     Organisation Status.
--
-- WHAT WAS ALREADY THERE, AND WHAT WAS NOT
--   dbo.pm_get_practice_repository's @p_entity_type='organizations'
--   branch (latest body: 404) already returns Code, Name,
--   SubscriptionStartDate, SubscriptionEndDate and Status -- five of the
--   seven. The two it does not have:
--
--     SPOC Name   There is no SPOC column anywhere in grac_practice, and
--                 no SPOC field on any form. What DOES exist is the
--                 "Admin Full Name" captured on the onboarding form:
--                 pm_create_organization_admin (217) stores it as an
--                 organization_employee holding the organization's Admin
--                 role (role_name 'Admin', role_code 'ORG_ADMIN'). Sir
--                 confirmed that is the name to show, so SPOC is derived
--                 from that employee -- no new column, no new form field,
--                 and nothing to backfill.
--
--     Frameworks  Aggregated from repository_subscription joined to
--                 grac_new.artifact: up to three artifact codes, then
--                 "+N more" when there are more. Three keeps the cell to
--                 one line in the generic grid; the count is over
--                 DISTINCT artifacts, so two releases of one framework
--                 count once. "Subscribed" is status='Active' AND
--                 subscription_status='Active', which is how 404 reads a
--                 live subscription everywhere else (a Disabled one keeps
--                 status='Active' but is not subscribed).
--
-- HOW (the house gateway-shim pattern -- 134, 361, 419, 465)
--   The monolith is NOT re-issued: CREATE OR ALTER would replace all
--   2,000+ lines of it. Instead a per-entity read shim,
--   sp_org_organizations_repository_get, takes the monolith's seven
--   parameters and calls sp_org_organization_list. PracticeRepositoryService
--   .ResolveProcedureAsync routes 'organizations' reads to it and falls
--   back to the monolith when the shim is absent, so SQL and Api can be
--   deployed in either order. The probe is cached per process -- restart
--   the Api after running this.
--
--   The list body is the 404 branch copied verbatim with only the two
--   columns added, because the SAME branch seeds the Edit form on the
--   organization page (WHERE @p_id=0 OR organization_id=@p_id): dropping
--   a column here would blank a field there. TotalRows = COUNT(*) OVER()
--   is kept for the generic pagination (300).
--
--   There is no manage shim: nothing about saving an organization
--   changes, so writes keep going to the monolith untouched.
--
-- SAFE TO RE-RUN. Requires 404 (subscription dates) and 217 (the admin
-- provisioning that creates the employee SPOC is read from).
-- Rollback: 510_organization_list_spoc_frameworks_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Guard on the COLUMNS the body below reads, not merely on the tables:
-- a missing column fails CREATE with Msg 207, which would leave the old
-- state behind while the script still printed success.
IF OBJECT_ID('grac_practice.organization','U') IS NULL
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
BEGIN
    PRINT 'ABORT (510): run 404 (organization address/subscription columns), 027 (organization_role.role_code) and 217 first. Nothing was changed.';
    SET NOEXEC ON;
END
GO
IF OBJECT_ID('grac_new.artifact','U') IS NULL
   OR COL_LENGTH('grac_new.artifact','artifact_code') IS NULL
BEGIN
    PRINT 'ABORT (510): grac_new.artifact is not present; the frameworks column cannot be built.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_org_organization_list -- the 404 'organizations' branch + 2 columns
-- =====================================================================
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
PRINT '510: sp_org_organization_list created.';
GO

-- =====================================================================
-- sp_org_organizations_repository_get -- the gateway read shim
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_organizations_repository_get
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30)  = 'QUERY',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30)  = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');

    DECLARE @page_number INT  = ISNULL(NULLIF(TRY_CONVERT(INT, JSON_VALUE(@p_payload,'$.pageNumber')),0),1);
    DECLARE @page_size   INT  = ISNULL(NULLIF(TRY_CONVERT(INT, JSON_VALUE(@p_payload,'$.pageSize')),0),25);
    DECLARE @date_from   DATE = TRY_CONVERT(DATE, NULLIF(JSON_VALUE(@p_payload,'$.dateFrom'),''));
    DECLARE @date_to     DATE = TRY_CONVERT(DATE, NULLIF(JSON_VALUE(@p_payload,'$.dateTo'),''));

    EXEC grac_practice.sp_org_organization_list
         @p_id          = @p_id,
         @p_status      = @p_status,
         @p_search      = @p_search,
         @p_page_number = @page_number,
         @p_page_size   = @page_size,
         @date_from     = @date_from,
         @date_to       = @date_to;
END;
GO
PRINT '510: sp_org_organizations_repository_get created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 510 verification ---';
SELECT CASE WHEN OBJECT_ID('grac_practice.sp_org_organization_list','P') IS NULL
            THEN 'MISSING' ELSE 'ok' END AS list_procedure,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_organizations_repository_get','P') IS NULL
            THEN 'MISSING' ELSE 'ok' END AS get_shim;

-- The shim must return every column the monolith's branch returned, or
-- the organization form behind the list loses fields.
EXEC grac_practice.sp_org_organizations_repository_get
     @p_entity_type = N'organizations', @p_action = N'QUERY',
     @p_payload = N'{"pageNumber":1,"pageSize":5}';
PRINT '510: done. Restart the Api -- ShimExistsAsync caches its probe per process.';
GO
