-- =====================================================================
-- 381 Location list degrades gracefully when GRAC_New.time_zone_master
--     is absent -- fixes SQL error 208 opening the Location tab
--
-- CONTEXT
-- -------
--   Reported: opening the Location tab shows "PracticeManagement
--   database scripts are not aligned with the current database.
--   Reference: <correlation id>". That exact text comes from
--   PracticeRepositoryService.cs's generic SQL exception handler,
--   which returns it whenever a query throws SQL error 207 (invalid
--   column name) or 208 (invalid object name) -- i.e. a script/table
--   mismatch, not application data. It is a generic message for a
--   class of error, not specific to Location; this migration addresses
--   the one confirmed, reproducible cause found in the current scripts
--   for the Location screen specifically.
--
-- ROOT CAUSE, TRACED BEFORE WRITING ANYTHING
-- --------------------------------------------
--   Migration 360 added address + time_zone_id columns to
--   organization_location. time_zone_id is a nullable FK into
--   GRAC_New.time_zone_master -- a table that belongs to a DIFFERENT
--   module (ControlManagement, its own migrations 058/059) and is only
--   referenced, never owned, by PracticeManagement. 360's own header
--   explicitly anticipated this: "an unapplied migration should degrade
--   a feature ... not break the Location screen."
--
--   Migration 361 built that promise into two of its three new procs
--   correctly:
--     * sp_org_location_save        -- guards with
--       OBJECT_ID('GRAC_New.time_zone_master','U') IS NOT NULL before
--       validating a supplied time_zone_id.
--     * sp_get_time_zone_lookup     -- guards with
--       IF OBJECT_ID('GRAC_New.time_zone_master','U') IS NULL and
--       returns an empty dropdown instead of erroring.
--   but NOT into the third:
--     * sp_org_location_list        -- the proc that actually runs the
--       moment the Location tab opens (routed there by
--       PracticeRepositoryService.cs's 'locations' entity-type shim,
--       confirmed by reading the routing table) -- has an unconditional
--       LEFT JOIN GRAC_New.time_zone_master tz ON tz.time_zone_id =
--       l.time_zone_id, with no existence guard at all.
--
--   On any database where organization_location has its 360 columns
--   (time_zone_id etc. exist -- see the "IMPORTANT" note below for the
--   other, unrelated way this same message can appear) but
--   ControlManagement's own migration has not yet reached
--   GRAC_New.time_zone_master, this LEFT JOIN throws SQL error 208
--   ("Invalid object name 'GRAC_New.time_zone_master'") the instant the
--   Location grid tries to load -- exactly the reported symptom. This
--   is a genuine inconsistency in 361 itself, not merely a deployment
--   gap: two of its three procs already handle this correctly, this is
--   the one that didn't.
--
--   IMPORTANT -- a second, DIFFERENT possible cause of the exact same
--   message exists and this migration does not (and cannot) fix it:
--   if migration 360 itself was never run on this database,
--   organization_location has no time_zone_id / address_line1 / etc.
--   columns at all, and sp_org_location_list's reference to
--   l.time_zone_id would throw SQL error 207 ("Invalid column name")
--   regardless of this fix -- that is a genuine "the scripts have not
--   been fully deployed here yet" situation, and the correct fix is to
--   run 360 (then 361, then this migration) in order, not a code
--   change. See this migration's own guard below, which checks for
--   exactly that and aborts with a clear message rather than silently
--   doing nothing.
--
-- WHAT THIS DOES
-- --------------
--   Re-issues sp_org_location_list (CREATE OR ALTER requires the whole
--   body) with the query split on
--   OBJECT_ID('GRAC_New.time_zone_master','U'): the existing query,
--   byte-for-byte, when the table exists; the same query minus the tz
--   JOIN, with TimeZoneName/IanaTimeZone/UtcOffset/TimeZone coming back
--   blank instead of erroring, when it does not -- exactly the pattern
--   sp_get_time_zone_lookup already uses successfully in 361, and
--   exactly what 360's own header promised for this screen.
--
-- WHAT THIS DELIBERATELY DOES NOT CHANGE
-- -----------------------------------------
--   * sp_org_location_save and sp_get_time_zone_lookup -- already
--     correct, not touched.
--   * organization_location's schema, or any other table -- this is a
--     query-shape fix only.
--   * No frontend or API file -- the 'locations' routing, the grid
--     columns, and the Time Zone dropdown's own graceful-empty
--     behaviour (already handled by sp_get_time_zone_lookup) are all
--     unaffected; a Location record simply shows a blank Time Zone
--     until GRAC_New.time_zone_master is reachable, the same way it
--     already shows blank Address fields on a record nobody has edited
--     yet.
--
-- DEPENDS ON: 360 (organization_location's time_zone_id/address
-- columns -- this migration's own guard checks for them), 361 (this
-- proc's base definition being re-issued).
-- Rollback: 381_location_list_timezone_graceful_degrade_rollback.sql
-- Re-runnable: yes -- CREATE OR ALTER.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.organization_location','U') IS NULL
BEGIN
    RAISERROR('ABORT (381): grac_practice.organization_location missing. Run 002 first.', 16, 1);
    SET NOEXEC ON;
END
GO
IF COL_LENGTH('grac_practice.organization_location','time_zone_id') IS NULL
BEGIN
    RAISERROR('ABORT (381): organization_location has no time_zone_id column yet -- run 360 (then 361) first. This migration only fixes the missing-GRAC_New.time_zone_master case, not a missing 360.', 16, 1);
    SET NOEXEC ON;
END
GO
IF OBJECT_ID('grac_practice.sp_org_location_list','P') IS NULL
BEGIN
    RAISERROR('ABORT (381): grac_practice.sp_org_location_list missing. Run 361 first.', 16, 1);
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

    -- 381: GRAC_New.time_zone_master belongs to a different module
    -- (ControlManagement). Guard exactly like sp_org_location_save and
    -- sp_get_time_zone_lookup (both 361) already do, so a database
    -- where that module's own migration hasn't landed yet degrades
    -- this grid's Time Zone columns to blank instead of failing the
    -- whole Location tab with SQL error 208.
    IF OBJECT_ID('GRAC_New.time_zone_master','U') IS NOT NULL
    BEGIN
        SELECT l.location_id Id, l.organization_id OrganizationId, l.location_name Name,
               l.location_type_id LocationTypeId, lt.location_type_name LocationType,
               l.location_head_id LocationHeadId, COALESCE(e.employee_name,'') LocationHead,
               l.region Region, l.remarks Remarks,
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
    END
    ELSE
    BEGIN
        SELECT l.location_id Id, l.organization_id OrganizationId, l.location_name Name,
               l.location_type_id LocationTypeId, lt.location_type_name LocationType,
               l.location_head_id LocationHeadId, COALESCE(e.employee_name,'') LocationHead,
               l.region Region, l.remarks Remarks,
               l.time_zone_id TimeZoneId,
               CAST(NULL AS NVARCHAR(200)) TimeZoneName, CAST(NULL AS NVARCHAR(200)) IanaTimeZone, CAST(NULL AS NVARCHAR(200)) UtcOffset,
               N'' AS TimeZone,
               l.address_line1 AddressLine1, l.address_line2 AddressLine2, l.city City,
               l.state_province StateProvince, l.country Country, l.postal_code PostalCode,
               l.record_status_id StatusId, rs.status_name Status, COUNT(*) OVER () AS TotalRows
        FROM       grac_practice.organization_location l
        JOIN       grac_practice.record_status_master rs ON rs.record_status_id = l.record_status_id
        JOIN       grac_practice.location_type_master lt ON lt.location_type_id = l.location_type_id
        LEFT JOIN  grac_practice.organization_employee e ON e.employee_id = l.location_head_id
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
    END
END;
GO

PRINT '381: sp_org_location_list re-issued -- the Location grid now degrades to blank Time Zone fields instead of erroring when GRAC_New.time_zone_master is unreachable.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '381-a proc compiled' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_location_list','P')) IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '381-b proc body now guards on GRAC_New.time_zone_master',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_location_list','P')) LIKE '%OBJECT_ID(''GRAC_New.time_zone_master'',''U'') IS NOT NULL%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '381-c GRAC_New.time_zone_master reachable on this database (informational -- FAIL just means the dropdown/Time Zone columns are currently blank, which is expected and no longer breaks the tab)',
       CASE WHEN OBJECT_ID('GRAC_New.time_zone_master','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '381-d organization_location has its 360 columns (informational -- FAIL here means 360 itself still needs to be run; this migration cannot fix that)',
       CASE WHEN COL_LENGTH('grac_practice.organization_location','time_zone_id') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '381 complete. Opening the Location tab no longer fails with SQL error';
PRINT '    208 when GRAC_New.time_zone_master is unreachable; Time Zone shows';
PRINT '    blank instead. Check 381-c/381-d above for this database''s actual';
PRINT '    state. See docs/location-time-zone-and-address.md.';
GO
SET NOEXEC OFF;
GO
