/* ================================================================
   Migration 361 -- Location gateway shims (monolith-compatible)
   ----------------------------------------------------------------
   360 added Time Zone + address columns to organization_location.
   The 'locations' GET/MANAGE branches inside dbo.pm_get_practice_
   repository / dbo.pm_manage_practice_repository (002, re-emitted
   whole by 300) enumerate their own explicit column lists and do
   not know about the new columns, and that giant procedure cannot
   have one projection patched in place -- CREATE OR ALTER replaces
   it whole (see 300's own header note).

   This migration follows the EXACT precedent already established
   for this situation: migration 134 pulled 'users' and 'teams' out
   of the monolith into dedicated save/list procedures plus thin
   "gateway shim" procedures that keep the monolith's fixed 7-
   parameter contract, so PracticeRepositoryService can route to them
   by name while everything that is NOT a save (RETIRE today, and
   whatever is added tomorrow) is passed straight back to the
   monolith unchanged. 'locations' gets the same treatment here for
   the same reason 'teams' did: it needs new columns.

   Objects:
     * sp_org_location_save               NEW (locations SAVE logic, +8 columns)
     * sp_org_location_list                NEW (locations read branch, +8 columns)
     * sp_org_location_repository_manage   NEW (monolith contract; SAVE -> above, else -> monolith)
     * sp_org_location_repository_get      NEW (monolith contract; unpacks + calls the list proc)
     * sp_get_time_zone_lookup             NEW (dropdown lookup: active GRAC_New.time_zone_master rows)

   Depends on 360 (the columns) and 002 (organization_location,
   location_type_master, record_status_master).
   Rollback: database/361_location_gateway_shim_rollback.sql
   ================================================================ */
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.organization_location','U') IS NULL
BEGIN
    RAISERROR('361: organization_location missing. Run 002 first.', 16, 1);
    RETURN;
END
GO
IF COL_LENGTH('grac_practice.organization_location','time_zone_id') IS NULL
BEGIN
    RAISERROR('361: run 360 first -- organization_location has no time_zone_id / address columns yet.', 16, 1);
    RETURN;
END
GO

/* =====================================================================
   sp_org_location_save
   ---------------------------------------------------------------------
   Same validation as the monolith's 'locations' branch (002), plus:
     - time_zone_id: optional FK into GRAC_New.time_zone_master, must
       be Active if supplied.
     - six plain address columns: no master exists for
       City/State-Province/Postal Code anywhere in this codebase (see
       360's header), so these are unvalidated user-entered text, same
       treatment as the pre-existing Region field.
   ===================================================================== */
CREATE OR ALTER PROCEDURE grac_practice.sp_org_location_save
    @p_payload NVARCHAR(MAX),
    @p_id      BIGINT = 0,
    @p_usr_id  NVARCHAR(100) = 'system',
    @out_id    BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @active_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = 'Active');
    DECLARE @payload_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master
          WHERE status_code = JSON_VALUE(@p_payload,'$.status') OR status_name = JSON_VALUE(@p_payload,'$.status'));
    DECLARE @payload_record_status_id_from_id INT = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload,'$.statusId'),''));
    SET @payload_record_status_id = COALESCE(@payload_record_status_id_from_id, @payload_record_status_id);

    DECLARE @location_org_id      BIGINT        = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
    DECLARE @location_name        NVARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
    DECLARE @location_type_id     INT           = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload,'$.locationTypeId'),''));
    DECLARE @location_head_id     BIGINT        = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.locationHeadId'),''));
    DECLARE @location_status_id   INT           = COALESCE(@payload_record_status_id, @active_record_status_id);
    DECLARE @location_status_name NVARCHAR(30)  =
        COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id = @location_status_id),'Active');

    -- ---- status restriction (2026-09-20 change request) ----
    -- A NEW status may only be Active or Inactive going forward; a location
    -- already sitting on a legacy status (Retired/Draft/Disposed/...) is
    -- left alone as long as this save does not actually change its status
    -- -- @current_record_status_id is NULL on INSERT, so a brand-new row
    -- (status hidden on the Add form, defaults Active) is always checked
    -- too. Only a genuine status CHANGE to something other than
    -- Active/Inactive is rejected; editing any other field on a legacy
    -- row and resubmitting the same legacy status still succeeds.
    DECLARE @current_record_status_id INT =
        CASE WHEN @p_id <> 0 THEN (SELECT record_status_id FROM grac_practice.organization_location WHERE location_id = @p_id) END;
    IF @location_status_id <> ISNULL(@current_record_status_id, -1)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.record_status_master
                         WHERE record_status_id = @location_status_id AND status_code IN ('Active','Inactive'))
        THROW 51077, 'Location status can only be set to Active or Inactive.', 1;

    -- ---- 361 additions: Time Zone + address ----
    DECLARE @location_time_zone_id BIGINT        = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.timeZoneId'),''));
    DECLARE @address_line1         NVARCHAR(200) = JSON_VALUE(@p_payload,'$.addressLine1');
    DECLARE @address_line2         NVARCHAR(200) = JSON_VALUE(@p_payload,'$.addressLine2');
    DECLARE @location_city         NVARCHAR(120) = JSON_VALUE(@p_payload,'$.city');
    DECLARE @state_province        NVARCHAR(120) = JSON_VALUE(@p_payload,'$.stateProvince');
    DECLARE @location_country      NVARCHAR(120) = JSON_VALUE(@p_payload,'$.country');
    DECLARE @postal_code           NVARCHAR(30)  = JSON_VALUE(@p_payload,'$.postalCode');

    -- ---- original validation, unchanged ----
    IF @location_org_id IS NULL THROW 51064,'Organization is required for Location.',1;
    IF @location_name IS NULL   THROW 51065,'Location Name is required.',1;
    IF @location_type_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.location_type_master
                   WHERE location_type_id = @location_type_id AND is_active = 1)
        THROW 51066,'Location Type is required.',1;
    IF @location_head_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee
                   WHERE employee_id = @location_head_id AND organization_id = @location_org_id AND status = 'Active')
        THROW 51067,'Selected Location Head is not valid for this organization.',1;

    -- ---- 361 validation ----
    -- Guarded by OBJECT_ID so a Location save never breaks merely because
    -- ControlManagement's Time Zone Master migration (058) has not been
    -- deployed to this database yet -- same "degrade the feature, not the
    -- screen" rule 134 established for a missing cross-module dependency.
    IF @location_time_zone_id IS NOT NULL
       AND OBJECT_ID('GRAC_New.time_zone_master','U') IS NOT NULL
       AND NOT EXISTS(SELECT 1 FROM GRAC_New.time_zone_master WHERE time_zone_id = @location_time_zone_id AND status = 'Active')
        THROW 51072,'Selected Time Zone is not valid.',1;

    IF @p_id = 0
    BEGIN
        INSERT grac_practice.organization_location
            (organization_id, location_name, location_type_id, location_head_id, region, remarks,
             time_zone_id, address_line1, address_line2, city, state_province, country, postal_code,
             status, record_status_id, entered_by)
        VALUES
            (@location_org_id, @location_name, @location_type_id, @location_head_id,
             JSON_VALUE(@p_payload,'$.region'), JSON_VALUE(@p_payload,'$.remarks'),
             @location_time_zone_id, @address_line1, @address_line2, @location_city, @state_province, @location_country, @postal_code,
             @location_status_name, @location_status_id, @p_usr_id);
        SET @out_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_location
           SET organization_id = @location_org_id, location_name = @location_name, location_type_id = @location_type_id,
               location_head_id = @location_head_id, region = JSON_VALUE(@p_payload,'$.region'), remarks = JSON_VALUE(@p_payload,'$.remarks'),
               time_zone_id = @location_time_zone_id, address_line1 = @address_line1, address_line2 = @address_line2,
               city = @location_city, state_province = @state_province, country = @location_country, postal_code = @postal_code,
               status = @location_status_name, record_status_id = @location_status_id,
               updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
         WHERE location_id = @p_id;
        SET @out_id = @p_id;
    END
END;
GO

/* =====================================================================
   sp_org_location_list -- the 'locations' read branch + the new columns
   ===================================================================== */
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

/* =====================================================================
   sp_org_location_repository_manage / sp_org_location_repository_get
   ---------------------------------------------------------------------
   134's gateway shim, unchanged in shape -- only the entity-specific
   names differ.
   ===================================================================== */
CREATE OR ALTER PROCEDURE grac_practice.sp_org_location_repository_manage
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30),
    @p_id          BIGINT = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30) = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @p_action  = ISNULL(@p_action, '');
    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');
    SET @p_usr_id  = ISNULL(NULLIF(@p_usr_id, ''), 'system');

    -- Not a save: the monolith owns it (RETIRE and anything future),
    -- keeping its generic organization-access check intact.
    IF @p_action <> N'SAVE' AND @p_action <> N''
    BEGIN
        EXEC dbo.pm_manage_practice_repository
             @p_entity_type = @p_entity_type, @p_action = @p_action, @p_id = @p_id,
             @p_search = @p_search, @p_status = @p_status,
             @p_payload = @p_payload, @p_usr_id = @p_usr_id;
        RETURN;
    END

    BEGIN TRAN;

    DECLARE @new_id BIGINT = @p_id;
    EXEC grac_practice.sp_org_location_save
         @p_payload = @p_payload, @p_id = @p_id, @p_usr_id = @p_usr_id,
         @out_id = @new_id OUTPUT;

    -- Same audit row the monolith writes, so the trace stays continuous
    -- across the boundary.
    INSERT grac_practice.practice_audit_trace
        (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (@p_entity_type, @new_id, N'SAVE', @p_payload, 'Active', @p_usr_id);

    COMMIT;

    SELECT CAST(1 AS BIT) Success, N'Saved successfully.' Message, @new_id Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_location_repository_get
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30) = 'QUERY',
    @p_id          BIGINT = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30) = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');

    DECLARE @organization_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
    DECLARE @page_number INT = ISNULL(NULLIF(TRY_CONVERT(INT, JSON_VALUE(@p_payload,'$.pageNumber')),0),1);
    DECLARE @page_size   INT = ISNULL(NULLIF(TRY_CONVERT(INT, JSON_VALUE(@p_payload,'$.pageSize')),0),25);

    EXEC grac_practice.sp_org_location_list
         @p_id            = @p_id,
         @organization_id = @organization_id,
         @p_status        = @p_status,
         @p_search        = @p_search,
         @p_page_number   = @page_number,
         @p_page_size     = @page_size;
END;
GO

/* =====================================================================
   sp_get_time_zone_lookup -- feeds Location's Time Zone dropdown.
   Same shim pattern as sp_get_asset_taxonomy_lookup / sp_get_connection_
   type_lookup (241/244): a dedicated small lookup proc instead of
   extending the master-lookup UNION on the monolith. Returns the shape
   the /lookups endpoint's rows already use (LookupKey/Value/Label/
   ParentId), so the frontend can merge it into state.lookups["time-zones"]
   exactly like every other lookup key.
   ===================================================================== */
CREATE OR ALTER PROCEDURE grac_practice.sp_get_time_zone_lookup
    @p_entity_type NVARCHAR(100) = 'time-zones',
    @p_action      NVARCHAR(30)  = 'QUERY',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30)  = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('GRAC_New.time_zone_master','U') IS NULL
    BEGIN
        -- Degrade gracefully: an empty dropdown, not a broken Location
        -- screen, if ControlManagement's 058 has not reached this
        -- database yet.
        SELECT CAST(NULL AS NVARCHAR(40)) LookupKey, CAST(NULL AS NVARCHAR(40)) Value,
               CAST(NULL AS NVARCHAR(200)) Label, CAST(NULL AS BIGINT) ParentId
        WHERE 1 = 0;
        RETURN;
    END

    SELECT N'time-zones' AS LookupKey,
           CAST(time_zone_id AS NVARCHAR(40)) AS Value,
           time_zone_name + N' (' + iana_time_zone + N')' AS Label,
           CAST(NULL AS BIGINT) AS ParentId
    FROM GRAC_New.time_zone_master
    WHERE status = N'Active'
    ORDER BY time_zone_name;
END;
GO

PRINT '361 Location gateway shims deployed.';
PRINT 'NEXT: map ''locations'' and ''time-zones'' to these procedure names in PracticeRepositoryService,';
PRINT '      then add the fields to wwwroot/js/practice.js.';
GO
