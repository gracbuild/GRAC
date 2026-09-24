-- =====================================================================
-- 381 ROLLBACK -- sp_org_location_list back to 361's exact body
--
-- Restores the unconditional LEFT JOIN GRAC_New.time_zone_master (no
-- existence guard) -- the pre-381 behaviour, where the Location tab
-- throws SQL error 208 if that table is unreachable.
--
-- Re-runnable: yes -- CREATE OR ALTER.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.organization_location','U') IS NULL
BEGIN
    RAISERROR('381 rollback: grac_practice.organization_location missing.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_location_list
    @p_id            BIGINT        = 0,
    @organization_id BIGINT        = NULL,
    @p_status        NVARCHAR(30)  = '',
    @p_search        NVARCHAR(200) = '',
    @p_page_number   INT           = 1,
    @p_page_size     INT           = 25
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @page_size INT = ISNULL(NULLIF(@p_page_size,0),25);
    DECLARE @offset    INT = (ISNULL(NULLIF(@p_page_number,0),1) - 1) * @page_size;
    DECLARE @filter_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master
          WHERE status_code = @p_status OR status_name = @p_status);

    SELECT l.location_id Id, l.organization_id OrganizationId, l.location_name Name,
           l.location_type_id LocationTypeId, lt.location_type_name LocationType,
           l.location_head_id LocationHeadId, COALESCE(e.employee_name,'') LocationHead,
           l.region Region, l.remarks Remarks,
           -- 361
           l.time_zone_id TimeZoneId,
           tz.time_zone_name TimeZoneName, tz.iana_time_zone IanaTimeZone, tz.utc_offset UtcOffset,
           CASE WHEN tz.time_zone_id IS NULL THEN '' ELSE tz.time_zone_name + N' (' + tz.iana_time_zone + N')' END AS TimeZone,
           l.address_line1 AddressLine1, l.address_line2 AddressLine2, l.city City,
           l.state_province StateProvince, l.country Country, l.postal_code PostalCode,
           l.record_status_id StatusId, rs.status_name Status, COUNT(*) OVER () AS TotalRows
    FROM       grac_practice.organization_location l
    JOIN       grac_practice.record_status_master rs ON rs.record_status_id = l.record_status_id
    JOIN       grac_practice.location_type_master lt ON lt.location_type_id = l.location_type_id
    LEFT JOIN  grac_practice.organization_employee e ON e.employee_id = l.location_head_id
    LEFT JOIN  GRAC_New.time_zone_master tz ON tz.time_zone_id = l.time_zone_id
    WHERE      (@p_id = 0 OR l.location_id = @p_id)
      AND      (@organization_id IS NULL OR l.organization_id = @organization_id)
      AND      (@p_status = '' OR l.record_status_id = @filter_record_status_id)
      AND      (@p_search = '' OR l.location_name LIKE '%'+@p_search+'%'
                               OR lt.location_type_name LIKE '%'+@p_search+'%'
                               OR ISNULL(e.employee_name,'') LIKE '%'+@p_search+'%'
                               OR ISNULL(l.region,'') LIKE '%'+@p_search+'%'
                               OR ISNULL(l.city,'') LIKE '%'+@p_search+'%')
    ORDER BY   l.location_name
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

PRINT '381 rollback: sp_org_location_list restored to its pre-381 body.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '381 rollback-a proc compiled' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_location_list','P')) IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '381 rollback-b existence guard removed',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_location_list','P')) NOT LIKE '%OBJECT_ID(''GRAC_New.time_zone_master'',''U'') IS NOT NULL%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '381 rollback complete.';
GO
SET NOEXEC OFF;
GO
