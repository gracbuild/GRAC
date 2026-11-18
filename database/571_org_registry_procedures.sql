-- =====================================================================
-- 571_org_registry_procedures.sql
--
-- Organization Registry -- every read and write the Registry screen makes.
-- Generated from one field specification (docs/organization-registry.md
-- lists it), so the thirteen areas follow exactly the same rules:
--
--   sp_orgreg_lookups      controlled values + pickable records
--   sp_orgreg_summary      Legal Entities with per-area record counts
--   sp_orgreg_<area>_list  rows (filter: Organization / Legal Entity /
--                          status / search / one id), reference fields
--                          returned as id + code + name
--   sp_orgreg_<area>_save  insert (@id = 0) or update; @payload is the
--                          form as JSON, keys = the field keys
--
-- @allowed_legal_entity_ids (every procedure): NULL for GRAC administration
-- (Organization Management, GLOBAL scope); otherwise the JSON array of the
-- caller's organization ids, set by the Web tier from the session -- reads
-- are limited to those Legal Entities (and their Organizations), saves to
-- records of those Legal Entities, and Organizations / Legal Entities are
-- read-only (Practice Management -> Organization, 575).
--
-- Save rules (in order): JSON + actor; record exists; types (date, number,
-- id); mandatory fields; lengths and formats; controlled values (a value
-- off the list is kept only if the record already holds it); references
-- exist and belong to the same Legal Entity / Organization; no parent
-- loops; unique codes. Writes one practice_audit_trace row (before/after)
-- per save. There is NO delete: a record is retired by its status, and
-- inactive / closed records stay for traceability (workbook START HERE).
--
-- Errors: THROW 52700-52707 (52707: outside the caller's Legal Entities). The message starts with "[fieldKey] " so the
-- Api can return the field and the screen can mark it.
--
-- Requires 569. ASCII only. Rollback: 571_org_registry_procedures_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO
IF OBJECT_ID('grac_practice.registry_organization','U') IS NULL
   OR OBJECT_ID('grac_practice.org_registry_master_value','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_delivery_channel','U') IS NULL
   OR COL_LENGTH('grac_practice.organization','registry_organization_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','person_status') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_process','process_code') IS NULL
BEGIN
    PRINT 'ABORT (571): run 569_org_registry_schema.sql first. Nothing was changed.';
    SET NOEXEC ON;
END
GO
-- The Organization Administration columns the registry took over (2026-11-16).
IF COL_LENGTH('grac_practice.organization_location','time_zone_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_business_function','criticality') IS NULL
   OR COL_LENGTH('grac_practice.organization_team','vendor_id') IS NULL
   OR OBJECT_ID('grac_practice.organization_dependency_vendor','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_team_member','U') IS NULL
BEGIN
    PRINT 'ABORT (571): run 133, 360 and 362 first (team vendor, location time zone, team members). Nothing was changed.';
    SET NOEXEC ON;
END
GO
-- Every column the procedures read that 569 did not add (Msg 207 inside a
-- CREATE PROCEDURE does not stop the script, so it is checked up front).
IF COL_LENGTH('grac_practice.organization','record_status_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_division','record_status_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_location','record_status_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_department','record_status_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_team','record_status_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','record_status_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_committee','record_status_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_committee_member','record_status_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_process','record_status_id') IS NULL
BEGIN
    PRINT 'ABORT (571): a record_status_id column the procedures write is missing (see 002 / 008 / 370). Nothing was changed.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_lookups
    @registry_organization_id BIGINT = 0,
    @legal_entity_id          BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = every Legal Entity
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tz TABLE (id BIGINT NOT NULL PRIMARY KEY, label NVARCHAR(400) NOT NULL, active BIT NOT NULL);
    IF OBJECT_ID(N'GRAC_New.time_zone_master', N'U') IS NOT NULL
        INSERT @tz (id, label, active)
        SELECT z.time_zone_id, z.time_zone_name + ISNULL(N' (' + z.iana_time_zone + N')', N''),
               CASE WHEN z.status = N'Active' THEN 1 ELSE 0 END
          FROM GRAC_New.time_zone_master z;

    -- 1. Controlled values. LocationType and CommitteeMemberDesignation come
    --    from the existing FK masters (location_type_master,
    --    committee_designation_master) because those columns store their ids;
    --    the 570 rows of the same groups only say which values the workbook lists.
    SELECT m.master_group AS [Group], m.value_label AS Value, m.is_workbook_value AS IsWorkbookValue,
           m.source_note AS Note, m.display_order AS DisplayOrder, CAST(NULL AS BIGINT) AS LegalEntityId
      FROM grac_practice.org_registry_master_value m
     WHERE m.status = N'Active' AND m.master_group NOT IN (N'LocationType', N'CommitteeMemberDesignation')
    UNION ALL
    SELECT N'LocationType', lt.location_type_name, ISNULL(m.is_workbook_value, CAST(0 AS BIT)),
           ISNULL(m.source_note, N'Existing GRAC location type (not in 15 Masters & Codes).'),
           ISNULL(m.display_order, 500 + lt.display_order), CAST(NULL AS BIGINT)
      FROM grac_practice.location_type_master lt
      LEFT JOIN grac_practice.org_registry_master_value m ON m.master_group = N'LocationType' AND m.value_label = lt.location_type_name
     WHERE lt.is_active = 1
    UNION ALL
    SELECT N'CommitteeMemberDesignation', d.designation_name, ISNULL(m.is_workbook_value, CAST(0 AS BIT)),
           ISNULL(m.source_note, CASE WHEN d.organization_id IS NULL THEN N'Existing GRAC designation (not in 15 Masters & Codes).'
                                      ELSE N'Designation added by this Legal Entity.' END),
           ISNULL(m.display_order, 500), d.organization_id
      FROM grac_practice.committee_designation_master d
      LEFT JOIN grac_practice.org_registry_master_value m ON m.master_group = N'CommitteeMemberDesignation' AND m.value_label = d.designation_name
     WHERE d.is_active = 1
       AND (d.organization_id IS NULL OR @legal_entity_id = 0 OR d.organization_id = @legal_entity_id)
       AND (d.organization_id IS NULL OR @allowed_legal_entity_ids IS NULL OR d.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
    UNION ALL
    -- Time zones (Locations), from another module's table: empty until it is deployed.
    SELECT N'TimeZone', z.label, CAST(1 AS BIT), CAST(NULL AS NVARCHAR(400)), 0, CAST(NULL AS BIGINT)
      FROM @tz z
     WHERE z.active = 1
     ORDER BY [Group], DisplayOrder, Value;

    -- 2. Records that reference fields pick from (code + name, with the
    --    Legal Entity / Organization the screen filters dependent choices by).
    SELECT N'organizations' AS Kind, t.registry_organization_id AS Id, t.organization_code AS Code, t.registered_name AS Name,
           CAST(NULL AS BIGINT) AS LegalEntityId, t.registry_organization_id AS RegistryOrganizationId,
           CAST(NULL AS BIGINT) AS ParentId, t.record_status AS Status
      FROM grac_practice.registry_organization t
     WHERE @allowed_legal_entity_ids IS NULL
        OR t.registry_organization_id IN (SELECT ax.registry_organization_id FROM grac_practice.organization ax WHERE ax.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
    UNION ALL
    SELECT N'legal-entities', t.organization_id, t.organization_code, t.organization_name,
           t.organization_id, t.registry_organization_id, t.parent_organization_id, t.status
      FROM grac_practice.organization t
     WHERE (@registry_organization_id = 0 OR t.registry_organization_id = @registry_organization_id
        OR (@registry_organization_id = -1 AND t.registry_organization_id IS NULL))
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
    UNION ALL
    SELECT N'units', t.division_id, t.division_code, t.division_name,
           t.organization_id, le.registry_organization_id, t.parent_division_id, t.status
      FROM grac_practice.organization_division t JOIN grac_practice.organization le ON le.organization_id = t.organization_id
     WHERE (@registry_organization_id = 0 OR le.registry_organization_id = @registry_organization_id
            OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL))
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
    UNION ALL
    SELECT N'locations', t.location_id, t.location_code, t.location_name,
           t.organization_id, le.registry_organization_id, t.parent_location_id, t.status
      FROM grac_practice.organization_location t JOIN grac_practice.organization le ON le.organization_id = t.organization_id
     WHERE (@registry_organization_id = 0 OR le.registry_organization_id = @registry_organization_id
            OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL))
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
    UNION ALL
    SELECT N'departments', t.department_id, t.department_code, t.department_name,
           t.organization_id, le.registry_organization_id, t.parent_department_id, t.status
      FROM grac_practice.organization_department t JOIN grac_practice.organization le ON le.organization_id = t.organization_id
     WHERE (@registry_organization_id = 0 OR le.registry_organization_id = @registry_organization_id
            OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL))
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
    UNION ALL
    SELECT N'functions', t.business_function_id, t.function_code, t.function_name,
           t.organization_id, le.registry_organization_id, t.parent_function_id, t.status
      FROM grac_practice.organization_business_function t JOIN grac_practice.organization le ON le.organization_id = t.organization_id
     WHERE (@registry_organization_id = 0 OR le.registry_organization_id = @registry_organization_id
            OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL))
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
    UNION ALL
    SELECT N'teams', t.team_id, t.team_code, t.team_name,
           t.organization_id, le.registry_organization_id, CAST(NULL AS BIGINT), t.status
      FROM grac_practice.organization_team t JOIN grac_practice.organization le ON le.organization_id = t.organization_id
     WHERE (@registry_organization_id = 0 OR le.registry_organization_id = @registry_organization_id
            OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL))
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
    UNION ALL
    SELECT N'people', t.employee_id, t.employee_code, t.employee_name,
           t.organization_id, le.registry_organization_id, t.reporting_officer_id, t.status
      FROM grac_practice.organization_employee t JOIN grac_practice.organization le ON le.organization_id = t.organization_id
     WHERE (@registry_organization_id = 0 OR le.registry_organization_id = @registry_organization_id
            OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL))
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
    UNION ALL
    SELECT N'committees', t.committee_id, t.committee_code, t.committee_name,
           t.organization_id, le.registry_organization_id, CAST(NULL AS BIGINT), t.status
      FROM grac_practice.organization_committee t JOIN grac_practice.organization le ON le.organization_id = t.organization_id
     WHERE (@registry_organization_id = 0 OR le.registry_organization_id = @registry_organization_id
            OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL))
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
    UNION ALL
    SELECT N'processes', t.process_id, t.process_code, t.process_name,
           t.organization_id, le.registry_organization_id, t.parent_process_id, t.status
      FROM grac_practice.organization_dependency_process t JOIN grac_practice.organization le ON le.organization_id = t.organization_id
     WHERE (@registry_organization_id = 0 OR le.registry_organization_id = @registry_organization_id
            OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL))
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
    UNION ALL
    SELECT N'products', t.product_service_id, t.product_code, t.product_name,
           t.organization_id, le.registry_organization_id, CAST(NULL AS BIGINT), t.status
      FROM grac_practice.organization_product_service t JOIN grac_practice.organization le ON le.organization_id = t.organization_id
     WHERE (@registry_organization_id = 0 OR le.registry_organization_id = @registry_organization_id
            OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL))
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
    UNION ALL
    SELECT N'channels', t.channel_id, t.channel_code, t.channel_name,
           t.organization_id, le.registry_organization_id, CAST(NULL AS BIGINT), t.status
      FROM grac_practice.organization_delivery_channel t JOIN grac_practice.organization le ON le.organization_id = t.organization_id
     WHERE (@registry_organization_id = 0 OR le.registry_organization_id = @registry_organization_id
            OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL))
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
    UNION ALL
    SELECT N'vendors', t.vendor_id, CAST(NULL AS NVARCHAR(80)), t.vendor_name,
           t.organization_id, le.registry_organization_id, CAST(NULL AS BIGINT), t.status
      FROM grac_practice.organization_dependency_vendor t JOIN grac_practice.organization le ON le.organization_id = t.organization_id
     WHERE (@registry_organization_id = 0 OR le.registry_organization_id = @registry_organization_id
            OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL))
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
     ORDER BY Kind, Code;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_summary
    @registry_organization_id BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = every Legal Entity
AS
BEGIN
    SET NOCOUNT ON;
    -- One row per Legal Entity: where it sits in the hierarchy and how many
    -- records each registry area holds for it (the Registry's hierarchy panel).
    SELECT o.organization_id AS LegalEntityId, o.organization_code AS LegalEntityCode, o.organization_name AS LegalEntityName,
           o.parent_organization_id AS ParentLegalEntityId, o.registry_organization_id AS RegistryOrganizationId,
           o.status AS Status, o.in_scope_for_grac AS InScopeForGrac,
           (SELECT COUNT(*) FROM grac_practice.organization_division x WHERE x.organization_id = o.organization_id) AS Units,
           (SELECT COUNT(*) FROM grac_practice.organization_location x WHERE x.organization_id = o.organization_id) AS Locations,
           (SELECT COUNT(*) FROM grac_practice.organization_department x WHERE x.organization_id = o.organization_id) AS Departments,
           (SELECT COUNT(*) FROM grac_practice.organization_business_function x WHERE x.organization_id = o.organization_id) AS Functions,
           (SELECT COUNT(*) FROM grac_practice.organization_team x WHERE x.organization_id = o.organization_id) AS Teams,
           (SELECT COUNT(*) FROM grac_practice.organization_employee x WHERE x.organization_id = o.organization_id) AS People,
           (SELECT COUNT(*) FROM grac_practice.organization_committee x WHERE x.organization_id = o.organization_id) AS Committees,
           (SELECT COUNT(*) FROM grac_practice.organization_committee_member x WHERE x.organization_id = o.organization_id) AS CommitteeMembers,
           (SELECT COUNT(*) FROM grac_practice.organization_dependency_process x WHERE x.organization_id = o.organization_id) AS Processes,
           (SELECT COUNT(*) FROM grac_practice.organization_product_service x WHERE x.organization_id = o.organization_id) AS Products,
           (SELECT COUNT(*) FROM grac_practice.organization_delivery_channel x WHERE x.organization_id = o.organization_id) AS Channels
      FROM grac_practice.organization o
     WHERE (@registry_organization_id = 0 OR o.registry_organization_id = @registry_organization_id
        OR (@registry_organization_id = -1 AND o.registry_organization_id IS NULL))
       AND (@allowed_legal_entity_ids IS NULL OR o.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
     ORDER BY o.organization_name;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_organizations_list
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
    SELECT t.registry_organization_id AS Id,
           t.organization_code AS Code,
           t.registered_name AS Name,
           t.record_status AS Status,
           CAST(NULL AS BIGINT) AS LegalEntityId,
           CAST(NULL AS NVARCHAR(80)) AS LegalEntityCode,
           CAST(NULL AS NVARCHAR(250)) AS LegalEntityName,
           t.registry_organization_id AS RegistryOrganizationId,
           t.organization_code AS RegistryOrganizationCode,
           t.registered_name AS RegistryOrganizationName,
           (SELECT COUNT(*) FROM grac_practice.organization o2 WHERE o2.registry_organization_id = t.registry_organization_id) AS LegalEntityCount,
           t.entered_by AS EnteredBy,
           t.entered_dt AS EnteredDate,
           COALESCE(t.updated_by, t.entered_by) AS UpdatedBy,
           COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate,
           t.organization_code AS OrganizationCode,
           t.registered_name AS RegisteredName,
           t.brand_name AS BrandName,
           t.organization_type AS OrganizationType,
           t.industry AS Industry,
           t.regulator_classification AS RegulatorClassification,
           t.registration_cin AS RegistrationCin,
           t.lei AS Lei,
           t.incorporation_dt AS IncorporationDate,
           t.registered_office_address AS RegisteredOfficeAddress,
           t.city AS City,
           t.state AS State,
           t.country AS Country,
           t.pin_code AS PinCode,
           t.corporate_website AS CorporateWebsite,
           t.financial_year_start AS FinancialYearStart,
           t.financial_year_end AS FinancialYearEnd,
           t.primary_contact_role AS PrimaryContactRole,
           t.primary_contact_email AS PrimaryContactEmail,
           t.data_cutoff_dt AS DataCutoffDate,
           t.record_status AS RecordStatus,
           t.remarks AS Remarks,
           t.data_quality_note AS DataQualityNote
      FROM grac_practice.registry_organization t
      
     WHERE (@id = 0 OR t.registry_organization_id = @id)
       AND (@registry_organization_id <= 0 OR t.registry_organization_id = @registry_organization_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.registry_organization_id IN (SELECT ax.registry_organization_id FROM grac_practice.organization ax WHERE ax.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a)))
       AND (@status = N'' OR t.record_status = @status)
       AND (@search = N'' OR t.organization_code LIKE N'%' + @search + N'%' OR t.registered_name LIKE N'%' + @search + N'%')
     ORDER BY t.registered_name;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_organizations_save
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.registry_organization WHERE registry_organization_id = @id)
        THROW 52705, N'[] The Organization no longer exists. Reload the list.', 1;

    -- Organizations and Legal Entities are maintained by GRAC administration
    -- (Organization Management); an organization's own users see them read-only.
    IF @allowed_legal_entity_ids IS NOT NULL
        THROW 52707, N'[] Organizations are maintained in Organization Management.', 1;

    -- Raw values (text; OPENJSON so long text is never truncated).
    DECLARE @f_organizationCode NVARCHAR(MAX);
    DECLARE @f_registeredName NVARCHAR(MAX);
    DECLARE @f_brandName NVARCHAR(MAX);
    DECLARE @f_organizationType NVARCHAR(MAX);
    DECLARE @f_industry NVARCHAR(MAX);
    DECLARE @f_regulatorClassification NVARCHAR(MAX);
    DECLARE @f_registrationCin NVARCHAR(MAX);
    DECLARE @f_lei NVARCHAR(MAX);
    DECLARE @f_incorporationDate NVARCHAR(MAX);
    DECLARE @f_registeredOfficeAddress NVARCHAR(MAX);
    DECLARE @f_city NVARCHAR(MAX);
    DECLARE @f_state NVARCHAR(MAX);
    DECLARE @f_country NVARCHAR(MAX);
    DECLARE @f_pinCode NVARCHAR(MAX);
    DECLARE @f_corporateWebsite NVARCHAR(MAX);
    DECLARE @f_financialYearStart NVARCHAR(MAX);
    DECLARE @f_financialYearEnd NVARCHAR(MAX);
    DECLARE @f_primaryContactRole NVARCHAR(MAX);
    DECLARE @f_primaryContactEmail NVARCHAR(MAX);
    DECLARE @f_dataCutoffDate NVARCHAR(MAX);
    DECLARE @f_recordStatus NVARCHAR(MAX);
    DECLARE @f_remarks NVARCHAR(MAX);
    DECLARE @f_dataQualityNote NVARCHAR(MAX);
    SELECT @f_organizationCode = NULLIF(LTRIM(RTRIM(j.[organizationCode])), N''),
           @f_registeredName = NULLIF(LTRIM(RTRIM(j.[registeredName])), N''),
           @f_brandName = NULLIF(LTRIM(RTRIM(j.[brandName])), N''),
           @f_organizationType = NULLIF(LTRIM(RTRIM(j.[organizationType])), N''),
           @f_industry = NULLIF(LTRIM(RTRIM(j.[industry])), N''),
           @f_regulatorClassification = NULLIF(LTRIM(RTRIM(j.[regulatorClassification])), N''),
           @f_registrationCin = NULLIF(LTRIM(RTRIM(j.[registrationCin])), N''),
           @f_lei = NULLIF(LTRIM(RTRIM(j.[lei])), N''),
           @f_incorporationDate = NULLIF(LTRIM(RTRIM(j.[incorporationDate])), N''),
           @f_registeredOfficeAddress = NULLIF(LTRIM(RTRIM(j.[registeredOfficeAddress])), N''),
           @f_city = NULLIF(LTRIM(RTRIM(j.[city])), N''),
           @f_state = NULLIF(LTRIM(RTRIM(j.[state])), N''),
           @f_country = NULLIF(LTRIM(RTRIM(j.[country])), N''),
           @f_pinCode = NULLIF(LTRIM(RTRIM(j.[pinCode])), N''),
           @f_corporateWebsite = NULLIF(LTRIM(RTRIM(j.[corporateWebsite])), N''),
           @f_financialYearStart = NULLIF(LTRIM(RTRIM(j.[financialYearStart])), N''),
           @f_financialYearEnd = NULLIF(LTRIM(RTRIM(j.[financialYearEnd])), N''),
           @f_primaryContactRole = NULLIF(LTRIM(RTRIM(j.[primaryContactRole])), N''),
           @f_primaryContactEmail = NULLIF(LTRIM(RTRIM(j.[primaryContactEmail])), N''),
           @f_dataCutoffDate = NULLIF(LTRIM(RTRIM(j.[dataCutoffDate])), N''),
           @f_recordStatus = NULLIF(LTRIM(RTRIM(j.[recordStatus])), N''),
           @f_remarks = NULLIF(LTRIM(RTRIM(j.[remarks])), N''),
           @f_dataQualityNote = NULLIF(LTRIM(RTRIM(j.[dataQualityNote])), N'')
      FROM OPENJSON(@payload) WITH ([organizationCode] NVARCHAR(MAX) N'$.organizationCode',
           [registeredName] NVARCHAR(MAX) N'$.registeredName',
           [brandName] NVARCHAR(MAX) N'$.brandName',
           [organizationType] NVARCHAR(MAX) N'$.organizationType',
           [industry] NVARCHAR(MAX) N'$.industry',
           [regulatorClassification] NVARCHAR(MAX) N'$.regulatorClassification',
           [registrationCin] NVARCHAR(MAX) N'$.registrationCin',
           [lei] NVARCHAR(MAX) N'$.lei',
           [incorporationDate] NVARCHAR(MAX) N'$.incorporationDate',
           [registeredOfficeAddress] NVARCHAR(MAX) N'$.registeredOfficeAddress',
           [city] NVARCHAR(MAX) N'$.city',
           [state] NVARCHAR(MAX) N'$.state',
           [country] NVARCHAR(MAX) N'$.country',
           [pinCode] NVARCHAR(MAX) N'$.pinCode',
           [corporateWebsite] NVARCHAR(MAX) N'$.corporateWebsite',
           [financialYearStart] NVARCHAR(MAX) N'$.financialYearStart',
           [financialYearEnd] NVARCHAR(MAX) N'$.financialYearEnd',
           [primaryContactRole] NVARCHAR(MAX) N'$.primaryContactRole',
           [primaryContactEmail] NVARCHAR(MAX) N'$.primaryContactEmail',
           [dataCutoffDate] NVARCHAR(MAX) N'$.dataCutoffDate',
           [recordStatus] NVARCHAR(MAX) N'$.recordStatus',
           [remarks] NVARCHAR(MAX) N'$.remarks',
           [dataQualityNote] NVARCHAR(MAX) N'$.dataQualityNote') j;

    DECLARE @d_incorporationDate DATE = TRY_CONVERT(DATE, LEFT(@f_incorporationDate, 10), 23);
    IF @f_incorporationDate IS NOT NULL AND @d_incorporationDate IS NULL THROW 52701, N'[incorporationDate] Date of Incorporation must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_dataCutoffDate DATE = TRY_CONVERT(DATE, LEFT(@f_dataCutoffDate, 10), 23);
    IF @f_dataCutoffDate IS NOT NULL AND @d_dataCutoffDate IS NULL THROW 52701, N'[dataCutoffDate] Data Cut-off Date must be a date (yyyy-mm-dd).', 1;

    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).
    IF @f_organizationCode IS NULL THROW 52701, N'[organizationCode] Organization Code is required.', 1;
    IF @f_registeredName IS NULL THROW 52701, N'[registeredName] Registered Name is required.', 1;
    IF @f_organizationType IS NULL THROW 52701, N'[organizationType] Organization Type is required.', 1;
    IF @f_industry IS NULL THROW 52701, N'[industry] Industry is required.', 1;
    IF @f_recordStatus IS NULL THROW 52701, N'[recordStatus] Record Status is required.', 1;
    IF LEN(@f_organizationCode) > 80 THROW 52701, N'[organizationCode] Organization Code cannot be longer than 80 characters.', 1;
    IF LEN(@f_registeredName) > 250 THROW 52701, N'[registeredName] Registered Name cannot be longer than 250 characters.', 1;
    IF LEN(@f_brandName) > 250 THROW 52701, N'[brandName] Common / Brand Name cannot be longer than 250 characters.', 1;
    IF LEN(@f_industry) > 160 THROW 52701, N'[industry] Industry cannot be longer than 160 characters.', 1;
    IF LEN(@f_regulatorClassification) > 400 THROW 52701, N'[regulatorClassification] RBI / Regulator Classification cannot be longer than 400 characters.', 1;
    IF LEN(@f_registrationCin) > 80 THROW 52701, N'[registrationCin] Registration / CIN cannot be longer than 80 characters.', 1;
    IF LEN(@f_lei) > 40 THROW 52701, N'[lei] LEI (if applicable) cannot be longer than 40 characters.', 1;
    IF LEN(@f_registeredOfficeAddress) > 500 THROW 52701, N'[registeredOfficeAddress] Registered Office Address cannot be longer than 500 characters.', 1;
    IF LEN(@f_city) > 120 THROW 52701, N'[city] City cannot be longer than 120 characters.', 1;
    IF LEN(@f_pinCode) > 20 THROW 52701, N'[pinCode] PIN Code cannot be longer than 20 characters.', 1;
    IF LEN(@f_corporateWebsite) > 300 THROW 52701, N'[corporateWebsite] Corporate Website cannot be longer than 300 characters.', 1;
    IF @f_corporateWebsite IS NOT NULL AND @f_corporateWebsite NOT LIKE N'http%://%' THROW 52701, N'[corporateWebsite] Corporate Website must start with http:// or https://.', 1;
    IF @f_financialYearStart IS NOT NULL AND (@f_financialYearStart NOT LIKE N'[0-3][0-9]-[01][0-9]' OR TRY_CONVERT(DATE, N'2000-' + RIGHT(@f_financialYearStart, 2) + N'-' + LEFT(@f_financialYearStart, 2), 23) IS NULL) THROW 52701, N'[financialYearStart] Financial Year Start (DD-MM) must be a day and month as DD-MM, e.g. 01-04.', 1;
    IF @f_financialYearEnd IS NOT NULL AND (@f_financialYearEnd NOT LIKE N'[0-3][0-9]-[01][0-9]' OR TRY_CONVERT(DATE, N'2000-' + RIGHT(@f_financialYearEnd, 2) + N'-' + LEFT(@f_financialYearEnd, 2), 23) IS NULL) THROW 52701, N'[financialYearEnd] Financial Year End (DD-MM) must be a day and month as DD-MM, e.g. 01-04.', 1;
    IF LEN(@f_primaryContactRole) > 200 THROW 52701, N'[primaryContactRole] Primary Contact Role cannot be longer than 200 characters.', 1;
    IF LEN(@f_primaryContactEmail) > 250 THROW 52701, N'[primaryContactEmail] Primary Contact Official Email cannot be longer than 250 characters.', 1;
    IF @f_primaryContactEmail IS NOT NULL AND (@f_primaryContactEmail NOT LIKE N'%_@_%._%' OR CHARINDEX(N' ', @f_primaryContactEmail) > 0) THROW 52701, N'[primaryContactEmail] Primary Contact Official Email is not a valid e-mail address.', 1;
    IF LEN(@f_dataQualityNote) > 1000 THROW 52701, N'[dataQualityNote] (GRAC import note) cannot be longer than 1000 characters.', 1;

    -- Controlled values (15 Masters & Codes). A value that is not on the list
    -- is accepted only when it is the value the record already holds, so an
    -- older record can still be saved without being forced to change it.
    IF @f_organizationType IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'OrganizationType' AND m.value_label = @f_organizationType AND m.status = N'Active')
            SELECT @f_organizationType = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'OrganizationType' AND m.value_label = @f_organizationType;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.registry_organization WHERE registry_organization_id = @id AND organization_type = @f_organizationType)
            THROW 52702, N'[organizationType] Organization Type: the value is not in the approved list (OrganizationType).', 1;
    END
    IF @f_state IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'State' AND m.value_label = @f_state AND m.status = N'Active')
            SELECT @f_state = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'State' AND m.value_label = @f_state;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.registry_organization WHERE registry_organization_id = @id AND state = @f_state)
            THROW 52702, N'[state] State: the value is not in the approved list (State).', 1;
    END
    IF @f_country IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'Country' AND m.value_label = @f_country AND m.status = N'Active')
            SELECT @f_country = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'Country' AND m.value_label = @f_country;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.registry_organization WHERE registry_organization_id = @id AND country = @f_country)
            THROW 52702, N'[country] Country: the value is not in the approved list (Country).', 1;
    END
    IF @f_recordStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus AND m.status = N'Active')
            SELECT @f_recordStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.registry_organization WHERE registry_organization_id = @id AND record_status = @f_recordStatus)
            THROW 52702, N'[recordStatus] Record Status: the value is not in the approved list (RecordStatus).', 1;
    END


    -- References: the record must exist (and belong where the field says).

    -- Unique codes.
    IF EXISTS (SELECT 1 FROM grac_practice.registry_organization WHERE organization_code = @f_organizationCode AND registry_organization_id <> @id) THROW 52704, N'[organizationCode] Organization Code is already used by another Organization.', 1;


    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).
    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT organization_code, registered_name, brand_name, organization_type, industry, regulator_classification, registration_cin, lei, incorporation_dt, registered_office_address, city, state, country, pin_code, corporate_website, financial_year_start, financial_year_end, primary_contact_role, primary_contact_email, data_cutoff_dt, record_status, remarks, data_quality_note FROM grac_practice.registry_organization WHERE registry_organization_id = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;
    BEGIN TRAN;
    IF @id = 0
    BEGIN
        INSERT grac_practice.registry_organization (organization_code, registered_name, brand_name, organization_type, industry, regulator_classification, registration_cin, lei, incorporation_dt, registered_office_address, city, state, country, pin_code, corporate_website, financial_year_start, financial_year_end, primary_contact_role, primary_contact_email, data_cutoff_dt, record_status, remarks, data_quality_note, entered_by)
        VALUES (@f_organizationCode, @f_registeredName, @f_brandName, @f_organizationType, @f_industry, @f_regulatorClassification, @f_registrationCin, @f_lei, @d_incorporationDate, @f_registeredOfficeAddress, @f_city, @f_state, @f_country, @f_pinCode, @f_corporateWebsite, @f_financialYearStart, @f_financialYearEnd, @f_primaryContactRole, @f_primaryContactEmail, @d_dataCutoffDate, @f_recordStatus, @f_remarks, @f_dataQualityNote, @actor);
        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.registry_organization SET organization_code = @f_organizationCode,
               registered_name = @f_registeredName,
               brand_name = @f_brandName,
               organization_type = @f_organizationType,
               industry = @f_industry,
               regulator_classification = @f_regulatorClassification,
               registration_cin = @f_registrationCin,
               lei = @f_lei,
               incorporation_dt = @d_incorporationDate,
               registered_office_address = @f_registeredOfficeAddress,
               city = @f_city,
               state = @f_state,
               country = @f_country,
               pin_code = @f_pinCode,
               corporate_website = @f_corporateWebsite,
               financial_year_start = @f_financialYearStart,
               financial_year_end = @f_financialYearEnd,
               primary_contact_role = @f_primaryContactRole,
               primary_contact_email = @f_primaryContactEmail,
               data_cutoff_dt = @d_dataCutoffDate,
               record_status = @f_recordStatus,
               remarks = @f_remarks,
               data_quality_note = @f_dataQualityNote,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE registry_organization_id = @id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/organizations', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Organization saved.' AS Message, @id AS Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_legal_entities_list
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
    SELECT t.organization_id AS Id,
           t.organization_code AS Code,
           t.organization_name AS Name,
           t.status AS Status,
           t.organization_id AS LegalEntityId,
           t.organization_code AS LegalEntityCode,
           t.organization_name AS LegalEntityName,
           t.registry_organization_id AS RegistryOrganizationId,
           ro.organization_code AS RegistryOrganizationCode,
           ro.registered_name AS RegistryOrganizationName,
           (SELECT COUNT(*) FROM grac_practice.organization c WHERE c.parent_organization_id = t.organization_id) AS ChildLegalEntityCount,
           t.entered_by AS EnteredBy,
           t.entered_dt AS EnteredDate,
           COALESCE(t.updated_by, t.entered_by) AS UpdatedBy,
           COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate,
           t.registry_organization_id AS RegistryOrganizationId,
           j1.organization_code AS RegistryOrganizationCode,
           j1.registered_name AS RegistryOrganizationName,
           t.organization_code AS LegalEntityCode,
           t.organization_name AS LegalName,
           t.short_name AS ShortName,
           t.entity_type AS EntityType,
           t.parent_organization_id AS ParentLegalEntityId,
           j2.organization_code AS ParentLegalEntityCode,
           j2.organization_name AS ParentLegalEntityName,
           t.registration_number AS RegistrationNumber,
           t.incorporation_dt AS IncorporationDate,
           t.address_line1 AS RegisteredOfficeAddress,
           t.city AS City,
           t.state_province AS State,
           t.country AS Country,
           t.regulator AS Regulator,
           t.regulatory_classification AS RegulatoryClassification,
           t.business_activity AS BusinessActivity,
           t.in_scope_for_grac AS InScopeForGrac,
           t.entity_owner_employee_id AS EntityOwnerPersonId,
           j3.employee_code AS EntityOwnerPersonCode,
           j3.employee_name AS EntityOwnerPersonName,
           t.status AS RecordStatus,
           t.effective_from AS EffectiveFrom,
           t.effective_to AS EffectiveTo,
           t.legal_entity_remarks AS Remarks
      FROM grac_practice.organization t
      
      LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = t.registry_organization_id
      LEFT JOIN grac_practice.registry_organization j1 ON j1.registry_organization_id = t.registry_organization_id
      LEFT JOIN grac_practice.organization j2 ON j2.organization_id = t.parent_organization_id
      LEFT JOIN grac_practice.organization_employee j3 ON j3.employee_id = t.entity_owner_employee_id
     WHERE (@id = 0 OR t.organization_id = @id)
       AND (@registry_organization_id = 0 OR (@registry_organization_id = -1 AND t.registry_organization_id IS NULL) OR t.registry_organization_id = @registry_organization_id)
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
       AND (@status = N'' OR t.status = @status)
       AND (@search = N'' OR t.organization_code LIKE N'%' + @search + N'%' OR t.organization_name LIKE N'%' + @search + N'%')
     ORDER BY t.organization_name, t.organization_code;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_legal_entities_save
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @id)
        THROW 52705, N'[] The Legal Entity no longer exists. Reload the list.', 1;

    -- Organizations and Legal Entities are maintained by GRAC administration
    -- (Organization Management); an organization's own users see them read-only.
    IF @allowed_legal_entity_ids IS NOT NULL
        THROW 52707, N'[] Legal Entities are maintained in Organization Management.', 1;

    -- Raw values (text; OPENJSON so long text is never truncated).
    DECLARE @f_registryOrganizationId NVARCHAR(MAX);
    DECLARE @f_legalEntityCode NVARCHAR(MAX);
    DECLARE @f_legalName NVARCHAR(MAX);
    DECLARE @f_shortName NVARCHAR(MAX);
    DECLARE @f_entityType NVARCHAR(MAX);
    DECLARE @f_parentLegalEntityId NVARCHAR(MAX);
    DECLARE @f_registrationNumber NVARCHAR(MAX);
    DECLARE @f_incorporationDate NVARCHAR(MAX);
    DECLARE @f_registeredOfficeAddress NVARCHAR(MAX);
    DECLARE @f_city NVARCHAR(MAX);
    DECLARE @f_state NVARCHAR(MAX);
    DECLARE @f_country NVARCHAR(MAX);
    DECLARE @f_regulator NVARCHAR(MAX);
    DECLARE @f_regulatoryClassification NVARCHAR(MAX);
    DECLARE @f_businessActivity NVARCHAR(MAX);
    DECLARE @f_inScopeForGrac NVARCHAR(MAX);
    DECLARE @f_entityOwnerPersonId NVARCHAR(MAX);
    DECLARE @f_recordStatus NVARCHAR(MAX);
    DECLARE @f_effectiveFrom NVARCHAR(MAX);
    DECLARE @f_effectiveTo NVARCHAR(MAX);
    DECLARE @f_remarks NVARCHAR(MAX);
    SELECT @f_registryOrganizationId = NULLIF(LTRIM(RTRIM(j.[registryOrganizationId])), N''),
           @f_legalEntityCode = NULLIF(LTRIM(RTRIM(j.[legalEntityCode])), N''),
           @f_legalName = NULLIF(LTRIM(RTRIM(j.[legalName])), N''),
           @f_shortName = NULLIF(LTRIM(RTRIM(j.[shortName])), N''),
           @f_entityType = NULLIF(LTRIM(RTRIM(j.[entityType])), N''),
           @f_parentLegalEntityId = NULLIF(LTRIM(RTRIM(j.[parentLegalEntityId])), N''),
           @f_registrationNumber = NULLIF(LTRIM(RTRIM(j.[registrationNumber])), N''),
           @f_incorporationDate = NULLIF(LTRIM(RTRIM(j.[incorporationDate])), N''),
           @f_registeredOfficeAddress = NULLIF(LTRIM(RTRIM(j.[registeredOfficeAddress])), N''),
           @f_city = NULLIF(LTRIM(RTRIM(j.[city])), N''),
           @f_state = NULLIF(LTRIM(RTRIM(j.[state])), N''),
           @f_country = NULLIF(LTRIM(RTRIM(j.[country])), N''),
           @f_regulator = NULLIF(LTRIM(RTRIM(j.[regulator])), N''),
           @f_regulatoryClassification = NULLIF(LTRIM(RTRIM(j.[regulatoryClassification])), N''),
           @f_businessActivity = NULLIF(LTRIM(RTRIM(j.[businessActivity])), N''),
           @f_inScopeForGrac = NULLIF(LTRIM(RTRIM(j.[inScopeForGrac])), N''),
           @f_entityOwnerPersonId = NULLIF(LTRIM(RTRIM(j.[entityOwnerPersonId])), N''),
           @f_recordStatus = NULLIF(LTRIM(RTRIM(j.[recordStatus])), N''),
           @f_effectiveFrom = NULLIF(LTRIM(RTRIM(j.[effectiveFrom])), N''),
           @f_effectiveTo = NULLIF(LTRIM(RTRIM(j.[effectiveTo])), N''),
           @f_remarks = NULLIF(LTRIM(RTRIM(j.[remarks])), N'')
      FROM OPENJSON(@payload) WITH ([registryOrganizationId] NVARCHAR(MAX) N'$.registryOrganizationId',
           [legalEntityCode] NVARCHAR(MAX) N'$.legalEntityCode',
           [legalName] NVARCHAR(MAX) N'$.legalName',
           [shortName] NVARCHAR(MAX) N'$.shortName',
           [entityType] NVARCHAR(MAX) N'$.entityType',
           [parentLegalEntityId] NVARCHAR(MAX) N'$.parentLegalEntityId',
           [registrationNumber] NVARCHAR(MAX) N'$.registrationNumber',
           [incorporationDate] NVARCHAR(MAX) N'$.incorporationDate',
           [registeredOfficeAddress] NVARCHAR(MAX) N'$.registeredOfficeAddress',
           [city] NVARCHAR(MAX) N'$.city',
           [state] NVARCHAR(MAX) N'$.state',
           [country] NVARCHAR(MAX) N'$.country',
           [regulator] NVARCHAR(MAX) N'$.regulator',
           [regulatoryClassification] NVARCHAR(MAX) N'$.regulatoryClassification',
           [businessActivity] NVARCHAR(MAX) N'$.businessActivity',
           [inScopeForGrac] NVARCHAR(MAX) N'$.inScopeForGrac',
           [entityOwnerPersonId] NVARCHAR(MAX) N'$.entityOwnerPersonId',
           [recordStatus] NVARCHAR(MAX) N'$.recordStatus',
           [effectiveFrom] NVARCHAR(MAX) N'$.effectiveFrom',
           [effectiveTo] NVARCHAR(MAX) N'$.effectiveTo',
           [remarks] NVARCHAR(MAX) N'$.remarks') j;

    DECLARE @r_registryOrganizationId BIGINT = TRY_CONVERT(BIGINT, @f_registryOrganizationId);
    IF @f_registryOrganizationId IS NOT NULL AND @r_registryOrganizationId IS NULL THROW 52701, N'[registryOrganizationId] Organization is not a valid selection.', 1;
    DECLARE @r_parentLegalEntityId BIGINT = TRY_CONVERT(BIGINT, @f_parentLegalEntityId);
    IF @f_parentLegalEntityId IS NOT NULL AND @r_parentLegalEntityId IS NULL THROW 52701, N'[parentLegalEntityId] Parent Legal Entity Code is not a valid selection.', 1;
    DECLARE @d_incorporationDate DATE = TRY_CONVERT(DATE, LEFT(@f_incorporationDate, 10), 23);
    IF @f_incorporationDate IS NOT NULL AND @d_incorporationDate IS NULL THROW 52701, N'[incorporationDate] Date of Incorporation must be a date (yyyy-mm-dd).', 1;
    DECLARE @r_entityOwnerPersonId BIGINT = TRY_CONVERT(BIGINT, @f_entityOwnerPersonId);
    IF @f_entityOwnerPersonId IS NOT NULL AND @r_entityOwnerPersonId IS NULL THROW 52701, N'[entityOwnerPersonId] Entity Owner Person Code is not a valid selection.', 1;
    DECLARE @d_effectiveFrom DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveFrom, 10), 23);
    IF @f_effectiveFrom IS NOT NULL AND @d_effectiveFrom IS NULL THROW 52701, N'[effectiveFrom] Effective From must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_effectiveTo DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveTo, 10), 23);
    IF @f_effectiveTo IS NOT NULL AND @d_effectiveTo IS NULL THROW 52701, N'[effectiveTo] Effective To must be a date (yyyy-mm-dd).', 1;

    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).
    IF @f_registryOrganizationId IS NULL THROW 52701, N'[registryOrganizationId] Organization is required.', 1;
    IF @f_legalEntityCode IS NULL THROW 52701, N'[legalEntityCode] Legal Entity Code is required.', 1;
    IF @f_legalName IS NULL THROW 52701, N'[legalName] Legal Name is required.', 1;
    IF @f_entityType IS NULL THROW 52701, N'[entityType] Entity Type is required.', 1;
    IF @f_inScopeForGrac IS NULL THROW 52701, N'[inScopeForGrac] In Scope for GRAC? is required.', 1;
    IF @f_recordStatus IS NULL THROW 52701, N'[recordStatus] Record Status is required.', 1;
    IF LEN(@f_legalEntityCode) > 80 THROW 52701, N'[legalEntityCode] Legal Entity Code cannot be longer than 80 characters.', 1;
    IF LEN(@f_legalName) > 250 THROW 52701, N'[legalName] Legal Name cannot be longer than 250 characters.', 1;
    IF LEN(@f_shortName) > 120 THROW 52701, N'[shortName] Short Name cannot be longer than 120 characters.', 1;
    IF LEN(@f_registrationNumber) > 80 THROW 52701, N'[registrationNumber] Registration Number cannot be longer than 80 characters.', 1;
    IF LEN(@f_registeredOfficeAddress) > 200 THROW 52701, N'[registeredOfficeAddress] Registered Office Address cannot be longer than 200 characters.', 1;
    IF LEN(@f_city) > 120 THROW 52701, N'[city] City cannot be longer than 120 characters.', 1;
    IF LEN(@f_regulator) > 250 THROW 52701, N'[regulator] Regulator cannot be longer than 250 characters.', 1;
    IF LEN(@f_regulatoryClassification) > 400 THROW 52701, N'[regulatoryClassification] Regulatory Classification cannot be longer than 400 characters.', 1;
    IF LEN(@f_businessActivity) > 500 THROW 52701, N'[businessActivity] Business Activity cannot be longer than 500 characters.', 1;
    IF @d_effectiveFrom IS NOT NULL AND @d_effectiveTo IS NOT NULL AND @d_effectiveTo < @d_effectiveFrom THROW 52701, N'[effectiveTo] Effective To cannot be before Effective From.', 1;

    -- Controlled values (15 Masters & Codes). A value that is not on the list
    -- is accepted only when it is the value the record already holds, so an
    -- older record can still be saved without being forced to change it.
    IF @f_entityType IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'LegalEntityType' AND m.value_label = @f_entityType AND m.status = N'Active')
            SELECT @f_entityType = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'LegalEntityType' AND m.value_label = @f_entityType;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @id AND entity_type = @f_entityType)
            THROW 52702, N'[entityType] Entity Type: the value is not in the approved list (LegalEntityType).', 1;
    END
    IF @f_state IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'State' AND m.value_label = @f_state AND m.status = N'Active')
            SELECT @f_state = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'State' AND m.value_label = @f_state;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @id AND state_province = @f_state)
            THROW 52702, N'[state] State: the value is not in the approved list (State).', 1;
    END
    IF @f_country IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'Country' AND m.value_label = @f_country AND m.status = N'Active')
            SELECT @f_country = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'Country' AND m.value_label = @f_country;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @id AND country = @f_country)
            THROW 52702, N'[country] Country: the value is not in the approved list (Country).', 1;
    END
    IF @f_inScopeForGrac IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_inScopeForGrac AND m.status = N'Active')
            SELECT @f_inScopeForGrac = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_inScopeForGrac;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @id AND in_scope_for_grac = @f_inScopeForGrac)
            THROW 52702, N'[inScopeForGrac] In Scope for GRAC?: the value is not in the approved list (YesNo).', 1;
    END
    IF @f_recordStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus AND m.status = N'Active')
            SELECT @f_recordStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @id AND status = @f_recordStatus)
            THROW 52702, N'[recordStatus] Record Status: the value is not in the approved list (RecordStatus).', 1;
    END


    -- References: the record must exist (and belong where the field says).
    IF @r_registryOrganizationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.registry_organization WHERE registry_organization_id = @r_registryOrganizationId) THROW 52703, N'[registryOrganizationId] Organization: the selected record does not exist.', 1;
    IF @r_parentLegalEntityId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @r_parentLegalEntityId) THROW 52703, N'[parentLegalEntityId] Parent Legal Entity Code: the selected record does not exist.', 1;
    IF @r_parentLegalEntityId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization x WHERE x.organization_id = @r_parentLegalEntityId AND ((x.registry_organization_id IS NOT NULL AND x.registry_organization_id = @r_registryOrganizationId) OR x.organization_id = @id))
        THROW 52703, N'[parentLegalEntityId] Parent Legal Entity Code must belong to the same Organization.', 1;
    IF @r_parentLegalEntityId IS NOT NULL AND @id > 0
    BEGIN
        IF @r_parentLegalEntityId = @id THROW 52706, N'[parentLegalEntityId] Parent Legal Entity Code cannot be the record itself.', 1;
        DECLARE @walk_parentLegalEntityId BIGINT = @r_parentLegalEntityId, @guard_parentLegalEntityId INT = 0;
        WHILE @walk_parentLegalEntityId IS NOT NULL AND @guard_parentLegalEntityId < 100
        BEGIN
            IF @walk_parentLegalEntityId = @id THROW 52706, N'[parentLegalEntityId] Parent Legal Entity Code would make a loop: this record is already above it.', 1;
            SET @walk_parentLegalEntityId = (SELECT parent_organization_id FROM grac_practice.organization WHERE organization_id = @walk_parentLegalEntityId);
            SET @guard_parentLegalEntityId += 1;
        END
    END
    IF @r_entityOwnerPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_entityOwnerPersonId) THROW 52703, N'[entityOwnerPersonId] Entity Owner Person Code: the selected record does not exist.', 1;
    IF @r_entityOwnerPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id WHERE x.employee_id = @r_entityOwnerPersonId AND (x.organization_id = @id OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = @r_registryOrganizationId)))
        THROW 52703, N'[entityOwnerPersonId] Entity Owner Person Code must belong to the same Organization.', 1;

    -- Unique codes.
    IF EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_code = @f_legalEntityCode AND organization_id <> @id) THROW 52704, N'[legalEntityCode] Legal Entity Code is already used by another Legal Entity.', 1;

    DECLARE @rsid INT = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master
                          WHERE status_code = CASE WHEN @f_recordStatus = N'Active' THEN N'Active'
                                                   WHEN @f_recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft'
                                                   ELSE N'Inactive' END);
    IF @rsid IS NULL SET @rsid = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).
    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT registry_organization_id, organization_code, organization_name, short_name, entity_type, parent_organization_id, registration_number, incorporation_dt, address_line1, city, state_province, country, regulator, regulatory_classification, business_activity, in_scope_for_grac, entity_owner_employee_id, status, effective_from, effective_to, legal_entity_remarks, record_status_id FROM grac_practice.organization WHERE organization_id = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;
    BEGIN TRAN;
    IF @id = 0
    BEGIN
        INSERT grac_practice.organization (registry_organization_id, organization_code, organization_name, short_name, entity_type, parent_organization_id, registration_number, incorporation_dt, address_line1, city, state_province, country, regulator, regulatory_classification, business_activity, in_scope_for_grac, entity_owner_employee_id, status, effective_from, effective_to, legal_entity_remarks, record_status_id, entered_by)
        VALUES (@r_registryOrganizationId, @f_legalEntityCode, @f_legalName, @f_shortName, @f_entityType, @r_parentLegalEntityId, @f_registrationNumber, @d_incorporationDate, @f_registeredOfficeAddress, @f_city, @f_state, @f_country, @f_regulator, @f_regulatoryClassification, @f_businessActivity, @f_inScopeForGrac, @r_entityOwnerPersonId, @f_recordStatus, @d_effectiveFrom, @d_effectiveTo, @f_remarks, @rsid, @actor);
        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization SET registry_organization_id = @r_registryOrganizationId,
               organization_code = @f_legalEntityCode,
               organization_name = @f_legalName,
               short_name = @f_shortName,
               entity_type = @f_entityType,
               parent_organization_id = @r_parentLegalEntityId,
               registration_number = @f_registrationNumber,
               incorporation_dt = @d_incorporationDate,
               address_line1 = @f_registeredOfficeAddress,
               city = @f_city,
               state_province = @f_state,
               country = @f_country,
               regulator = @f_regulator,
               regulatory_classification = @f_regulatoryClassification,
               business_activity = @f_businessActivity,
               in_scope_for_grac = @f_inScopeForGrac,
               entity_owner_employee_id = @r_entityOwnerPersonId,
               status = @f_recordStatus,
               effective_from = @d_effectiveFrom,
               effective_to = @d_effectiveTo,
               legal_entity_remarks = @f_remarks,
               record_status_id = @rsid,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE organization_id = @id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/legal-entities', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Legal Entity saved.' AS Message, @id AS Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_units_list
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
    SELECT t.division_id AS Id,
           t.division_code AS Code,
           t.division_name AS Name,
           t.status AS Status,
           le.organization_id AS LegalEntityId,
           le.organization_code AS LegalEntityCode,
           le.organization_name AS LegalEntityName,
           le.registry_organization_id AS RegistryOrganizationId,
           ro.organization_code AS RegistryOrganizationCode,
           ro.registered_name AS RegistryOrganizationName,
           t.entered_by AS EnteredBy,
           t.entered_dt AS EnteredDate,
           COALESCE(t.updated_by, t.entered_by) AS UpdatedBy,
           COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate,
           t.division_code AS UnitCode,
           t.division_name AS UnitName,
           t.unit_type AS UnitType,
           t.parent_division_id AS ParentUnitId,
           j1.division_code AS ParentUnitCode,
           j1.division_name AS ParentUnitName,
           t.organization_id AS LegalEntityId,
           j2.organization_code AS LegalEntityCode,
           j2.organization_name AS LegalEntityName,
           t.primary_location_id AS PrimaryLocationId,
           j3.location_code AS PrimaryLocationCode,
           j3.location_name AS PrimaryLocationName,
           t.head_employee_id AS UnitHeadPersonId,
           j4.employee_code AS UnitHeadPersonCode,
           j4.employee_name AS UnitHeadPersonName,
           t.head_designation AS UnitHeadDesignation,
           t.business_unit_type AS BusinessUnitType,
           t.state_region AS StateRegion,
           t.cost_centre AS UnitCostCentre,
           t.is_operational AS IsOperational,
           t.status AS RecordStatus,
           t.effective_from AS EffectiveFrom,
           t.effective_to AS EffectiveTo,
           t.remarks AS Remarks
      FROM grac_practice.organization_division t
      LEFT JOIN grac_practice.organization le ON le.organization_id = t.organization_id
      LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = le.registry_organization_id
      LEFT JOIN grac_practice.organization_division j1 ON j1.division_id = t.parent_division_id
      LEFT JOIN grac_practice.organization j2 ON j2.organization_id = t.organization_id
      LEFT JOIN grac_practice.organization_location j3 ON j3.location_id = t.primary_location_id
      LEFT JOIN grac_practice.organization_employee j4 ON j4.employee_id = t.head_employee_id
     WHERE (@id = 0 OR t.division_id = @id)
       AND (@registry_organization_id = 0 OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL) OR le.registry_organization_id = @registry_organization_id)
       AND (@legal_entity_id = 0 OR le.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR le.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
       AND (@status = N'' OR t.status = @status)
       AND (@search = N'' OR t.division_code LIKE N'%' + @search + N'%' OR t.division_name LIKE N'%' + @search + N'%')
     ORDER BY le.organization_name, t.division_code;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_units_save
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @id)
        THROW 52705, N'[] The Organization Unit no longer exists. Reload the list.', 1;

    -- Outside GRAC administration a record of another Legal Entity is out of reach.
    IF @allowed_legal_entity_ids IS NOT NULL AND @id > 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division x WHERE x.division_id = @id AND x.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[] This record belongs to a Legal Entity you do not have access to.', 1;

    -- Raw values (text; OPENJSON so long text is never truncated).
    DECLARE @f_unitCode NVARCHAR(MAX);
    DECLARE @f_unitName NVARCHAR(MAX);
    DECLARE @f_unitType NVARCHAR(MAX);
    DECLARE @f_parentUnitId NVARCHAR(MAX);
    DECLARE @f_legalEntityId NVARCHAR(MAX);
    DECLARE @f_primaryLocationId NVARCHAR(MAX);
    DECLARE @f_unitHeadPersonId NVARCHAR(MAX);
    DECLARE @f_unitHeadDesignation NVARCHAR(MAX);
    DECLARE @f_businessUnitType NVARCHAR(MAX);
    DECLARE @f_stateRegion NVARCHAR(MAX);
    DECLARE @f_unitCostCentre NVARCHAR(MAX);
    DECLARE @f_isOperational NVARCHAR(MAX);
    DECLARE @f_recordStatus NVARCHAR(MAX);
    DECLARE @f_effectiveFrom NVARCHAR(MAX);
    DECLARE @f_effectiveTo NVARCHAR(MAX);
    DECLARE @f_remarks NVARCHAR(MAX);
    SELECT @f_unitCode = NULLIF(LTRIM(RTRIM(j.[unitCode])), N''),
           @f_unitName = NULLIF(LTRIM(RTRIM(j.[unitName])), N''),
           @f_unitType = NULLIF(LTRIM(RTRIM(j.[unitType])), N''),
           @f_parentUnitId = NULLIF(LTRIM(RTRIM(j.[parentUnitId])), N''),
           @f_legalEntityId = NULLIF(LTRIM(RTRIM(j.[legalEntityId])), N''),
           @f_primaryLocationId = NULLIF(LTRIM(RTRIM(j.[primaryLocationId])), N''),
           @f_unitHeadPersonId = NULLIF(LTRIM(RTRIM(j.[unitHeadPersonId])), N''),
           @f_unitHeadDesignation = NULLIF(LTRIM(RTRIM(j.[unitHeadDesignation])), N''),
           @f_businessUnitType = NULLIF(LTRIM(RTRIM(j.[businessUnitType])), N''),
           @f_stateRegion = NULLIF(LTRIM(RTRIM(j.[stateRegion])), N''),
           @f_unitCostCentre = NULLIF(LTRIM(RTRIM(j.[unitCostCentre])), N''),
           @f_isOperational = NULLIF(LTRIM(RTRIM(j.[isOperational])), N''),
           @f_recordStatus = NULLIF(LTRIM(RTRIM(j.[recordStatus])), N''),
           @f_effectiveFrom = NULLIF(LTRIM(RTRIM(j.[effectiveFrom])), N''),
           @f_effectiveTo = NULLIF(LTRIM(RTRIM(j.[effectiveTo])), N''),
           @f_remarks = NULLIF(LTRIM(RTRIM(j.[remarks])), N'')
      FROM OPENJSON(@payload) WITH ([unitCode] NVARCHAR(MAX) N'$.unitCode',
           [unitName] NVARCHAR(MAX) N'$.unitName',
           [unitType] NVARCHAR(MAX) N'$.unitType',
           [parentUnitId] NVARCHAR(MAX) N'$.parentUnitId',
           [legalEntityId] NVARCHAR(MAX) N'$.legalEntityId',
           [primaryLocationId] NVARCHAR(MAX) N'$.primaryLocationId',
           [unitHeadPersonId] NVARCHAR(MAX) N'$.unitHeadPersonId',
           [unitHeadDesignation] NVARCHAR(MAX) N'$.unitHeadDesignation',
           [businessUnitType] NVARCHAR(MAX) N'$.businessUnitType',
           [stateRegion] NVARCHAR(MAX) N'$.stateRegion',
           [unitCostCentre] NVARCHAR(MAX) N'$.unitCostCentre',
           [isOperational] NVARCHAR(MAX) N'$.isOperational',
           [recordStatus] NVARCHAR(MAX) N'$.recordStatus',
           [effectiveFrom] NVARCHAR(MAX) N'$.effectiveFrom',
           [effectiveTo] NVARCHAR(MAX) N'$.effectiveTo',
           [remarks] NVARCHAR(MAX) N'$.remarks') j;

    DECLARE @r_parentUnitId BIGINT = TRY_CONVERT(BIGINT, @f_parentUnitId);
    IF @f_parentUnitId IS NOT NULL AND @r_parentUnitId IS NULL THROW 52701, N'[parentUnitId] Parent Unit Code is not a valid selection.', 1;
    DECLARE @r_legalEntityId BIGINT = TRY_CONVERT(BIGINT, @f_legalEntityId);
    IF @f_legalEntityId IS NOT NULL AND @r_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Legal Entity Code is not a valid selection.', 1;
    DECLARE @r_primaryLocationId BIGINT = TRY_CONVERT(BIGINT, @f_primaryLocationId);
    IF @f_primaryLocationId IS NOT NULL AND @r_primaryLocationId IS NULL THROW 52701, N'[primaryLocationId] Primary Location Code is not a valid selection.', 1;
    DECLARE @r_unitHeadPersonId BIGINT = TRY_CONVERT(BIGINT, @f_unitHeadPersonId);
    IF @f_unitHeadPersonId IS NOT NULL AND @r_unitHeadPersonId IS NULL THROW 52701, N'[unitHeadPersonId] Unit Head Person Code is not a valid selection.', 1;
    DECLARE @d_effectiveFrom DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveFrom, 10), 23);
    IF @f_effectiveFrom IS NOT NULL AND @d_effectiveFrom IS NULL THROW 52701, N'[effectiveFrom] Effective From must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_effectiveTo DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveTo, 10), 23);
    IF @f_effectiveTo IS NOT NULL AND @d_effectiveTo IS NULL THROW 52701, N'[effectiveTo] Effective To must be a date (yyyy-mm-dd).', 1;

    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).
    IF @f_unitCode IS NULL THROW 52701, N'[unitCode] Unit Code is required.', 1;
    IF @f_unitName IS NULL THROW 52701, N'[unitName] Unit Name is required.', 1;
    IF @f_unitType IS NULL THROW 52701, N'[unitType] Unit Type is required.', 1;
    IF @f_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Legal Entity Code is required.', 1;
    IF @f_isOperational IS NULL THROW 52701, N'[isOperational] Is Operational? is required.', 1;
    IF @f_recordStatus IS NULL THROW 52701, N'[recordStatus] Record Status is required.', 1;
    IF LEN(@f_unitCode) > 80 THROW 52701, N'[unitCode] Unit Code cannot be longer than 80 characters.', 1;
    IF LEN(@f_unitName) > 200 THROW 52701, N'[unitName] Unit Name cannot be longer than 200 characters.', 1;
    IF LEN(@f_unitHeadDesignation) > 200 THROW 52701, N'[unitHeadDesignation] Unit Head Designation cannot be longer than 200 characters.', 1;
    IF LEN(@f_stateRegion) > 120 THROW 52701, N'[stateRegion] State / Region cannot be longer than 120 characters.', 1;
    IF LEN(@f_unitCostCentre) > 80 THROW 52701, N'[unitCostCentre] Unit Cost Centre cannot be longer than 80 characters.', 1;
    IF @d_effectiveFrom IS NOT NULL AND @d_effectiveTo IS NOT NULL AND @d_effectiveTo < @d_effectiveFrom THROW 52701, N'[effectiveTo] Effective To cannot be before Effective From.', 1;

    -- Controlled values (15 Masters & Codes). A value that is not on the list
    -- is accepted only when it is the value the record already holds, so an
    -- older record can still be saved without being forced to change it.
    IF @f_unitType IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'OrgUnitType' AND m.value_label = @f_unitType AND m.status = N'Active')
            SELECT @f_unitType = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'OrgUnitType' AND m.value_label = @f_unitType;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @id AND unit_type = @f_unitType)
            THROW 52702, N'[unitType] Unit Type: the value is not in the approved list (OrgUnitType).', 1;
    END
    IF @f_businessUnitType IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'BusinessUnitType' AND m.value_label = @f_businessUnitType AND m.status = N'Active')
            SELECT @f_businessUnitType = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'BusinessUnitType' AND m.value_label = @f_businessUnitType;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @id AND business_unit_type = @f_businessUnitType)
            THROW 52702, N'[businessUnitType] Business Unit Type: the value is not in the approved list (BusinessUnitType).', 1;
    END
    IF @f_isOperational IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_isOperational AND m.status = N'Active')
            SELECT @f_isOperational = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_isOperational;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @id AND is_operational = @f_isOperational)
            THROW 52702, N'[isOperational] Is Operational?: the value is not in the approved list (YesNo).', 1;
    END
    IF @f_recordStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus AND m.status = N'Active')
            SELECT @f_recordStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @id AND status = @f_recordStatus)
            THROW 52702, N'[recordStatus] Record Status: the value is not in the approved list (RecordStatus).', 1;
    END

    DECLARE @le BIGINT = @r_legalEntityId;
    IF @le IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @le) THROW 52703, N'[legalEntityId] The selected Legal Entity does not exist.', 1;
    IF @id > 0 AND EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @id AND organization_id <> @le)
       AND EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @id AND organization_id IS NOT NULL)
        THROW 52703, N'[legalEntityId] A Organization Unit cannot be moved to another Legal Entity: other records refer to it there. Mark it Inactive and create it in the other Legal Entity.', 1;
    IF @allowed_legal_entity_ids IS NOT NULL AND (@le IS NULL OR @le NOT IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[legalEntityId] You can only maintain records of your own Legal Entities.', 1;

    -- References: the record must exist (and belong where the field says).
    IF @r_parentUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @r_parentUnitId) THROW 52703, N'[parentUnitId] Parent Unit Code: the selected record does not exist.', 1;
    IF @r_parentUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division x WHERE x.division_id = @r_parentUnitId AND x.organization_id = @le)
        THROW 52703, N'[parentUnitId] Parent Unit Code must belong to the same Legal Entity.', 1;
    IF @r_parentUnitId IS NOT NULL AND @id > 0
    BEGIN
        IF @r_parentUnitId = @id THROW 52706, N'[parentUnitId] Parent Unit Code cannot be the record itself.', 1;
        DECLARE @walk_parentUnitId BIGINT = @r_parentUnitId, @guard_parentUnitId INT = 0;
        WHILE @walk_parentUnitId IS NOT NULL AND @guard_parentUnitId < 100
        BEGIN
            IF @walk_parentUnitId = @id THROW 52706, N'[parentUnitId] Parent Unit Code would make a loop: this record is already above it.', 1;
            SET @walk_parentUnitId = (SELECT parent_division_id FROM grac_practice.organization_division WHERE division_id = @walk_parentUnitId);
            SET @guard_parentUnitId += 1;
        END
    END
    IF @r_primaryLocationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_location WHERE location_id = @r_primaryLocationId) THROW 52703, N'[primaryLocationId] Primary Location Code: the selected record does not exist.', 1;
    IF @r_primaryLocationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_location x WHERE x.location_id = @r_primaryLocationId AND x.organization_id = @le)
        THROW 52703, N'[primaryLocationId] Primary Location Code must belong to the same Legal Entity.', 1;
    IF @r_unitHeadPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_unitHeadPersonId) THROW 52703, N'[unitHeadPersonId] Unit Head Person Code: the selected record does not exist.', 1;
    IF @r_unitHeadPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_unitHeadPersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[unitHeadPersonId] Unit Head Person Code must belong to the same Organization.', 1;

    -- Unique codes.
    IF EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE organization_id = @le AND division_code = @f_unitCode AND division_id <> @id) THROW 52704, N'[unitCode] Unit Code is already used in this Legal Entity.', 1;

    DECLARE @rsid INT = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master
                          WHERE status_code = CASE WHEN @f_recordStatus = N'Active' THEN N'Active'
                                                   WHEN @f_recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft'
                                                   ELSE N'Inactive' END);
    IF @rsid IS NULL SET @rsid = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).
    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT division_code, division_name, unit_type, parent_division_id, organization_id, primary_location_id, head_employee_id, head_designation, business_unit_type, state_region, cost_centre, is_operational, status, effective_from, effective_to, remarks, record_status_id FROM grac_practice.organization_division WHERE division_id = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;
    BEGIN TRAN;
    IF @id = 0
    BEGIN
        INSERT grac_practice.organization_division (division_code, division_name, unit_type, parent_division_id, organization_id, primary_location_id, head_employee_id, head_designation, business_unit_type, state_region, cost_centre, is_operational, status, effective_from, effective_to, remarks, record_status_id, entered_by)
        VALUES (@f_unitCode, @f_unitName, @f_unitType, @r_parentUnitId, @r_legalEntityId, @r_primaryLocationId, @r_unitHeadPersonId, @f_unitHeadDesignation, @f_businessUnitType, @f_stateRegion, @f_unitCostCentre, @f_isOperational, @f_recordStatus, @d_effectiveFrom, @d_effectiveTo, @f_remarks, @rsid, @actor);
        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_division SET division_code = @f_unitCode,
               division_name = @f_unitName,
               unit_type = @f_unitType,
               parent_division_id = @r_parentUnitId,
               organization_id = @r_legalEntityId,
               primary_location_id = @r_primaryLocationId,
               head_employee_id = @r_unitHeadPersonId,
               head_designation = @f_unitHeadDesignation,
               business_unit_type = @f_businessUnitType,
               state_region = @f_stateRegion,
               cost_centre = @f_unitCostCentre,
               is_operational = @f_isOperational,
               status = @f_recordStatus,
               effective_from = @d_effectiveFrom,
               effective_to = @d_effectiveTo,
               remarks = @f_remarks,
               record_status_id = @rsid,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE division_id = @id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/units', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Organization Unit saved.' AS Message, @id AS Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_locations_list
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
    DECLARE @tz TABLE (id BIGINT NOT NULL PRIMARY KEY, label NVARCHAR(400) NOT NULL, active BIT NOT NULL);
    IF OBJECT_ID(N'GRAC_New.time_zone_master', N'U') IS NOT NULL
        INSERT @tz (id, label, active)
        SELECT z.time_zone_id, z.time_zone_name + ISNULL(N' (' + z.iana_time_zone + N')', N''),
               CASE WHEN z.status = N'Active' THEN 1 ELSE 0 END
          FROM GRAC_New.time_zone_master z;
    SELECT t.location_id AS Id,
           t.location_code AS Code,
           t.location_name AS Name,
           t.status AS Status,
           le.organization_id AS LegalEntityId,
           le.organization_code AS LegalEntityCode,
           le.organization_name AS LegalEntityName,
           le.registry_organization_id AS RegistryOrganizationId,
           ro.organization_code AS RegistryOrganizationCode,
           ro.registered_name AS RegistryOrganizationName,
           t.entered_by AS EnteredBy,
           t.entered_dt AS EnteredDate,
           COALESCE(t.updated_by, t.entered_by) AS UpdatedBy,
           COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate,
           t.location_code AS LocationCode,
           t.location_name AS LocationName,
           j1.location_type_name AS LocationType,
           t.organization_id AS LegalEntityId,
           j2.organization_code AS LegalEntityCode,
           j2.organization_name AS LegalEntityName,
           t.division_id AS OrganizationUnitId,
           j3.division_code AS OrganizationUnitCode,
           j3.division_name AS OrganizationUnitName,
           t.parent_location_id AS ParentLocationId,
           j4.location_code AS ParentLocationCode,
           j4.location_name AS ParentLocationName,
           t.address_line1 AS AddressLine1,
           t.address_line2 AS AddressLine2,
           t.city AS CityTown,
           t.district AS District,
           t.state_province AS State,
           t.postal_code AS PinCode,
           t.country AS Country,
           t.latitude AS Latitude,
           t.longitude AS Longitude,
           t.region AS RegionZoneLabel,
           j5.label AS TimeZone,
           t.location_head_id AS LocationHeadPersonId,
           j6.employee_code AS LocationHeadPersonCode,
           j6.employee_name AS LocationHeadPersonName,
           t.opening_dt AS OpeningDate,
           t.closure_dt AS ClosureDate,
           t.customer_facing AS CustomerFacing,
           t.status AS OperationalStatus,
           t.remarks AS Remarks
      FROM grac_practice.organization_location t
      LEFT JOIN grac_practice.organization le ON le.organization_id = t.organization_id
      LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = le.registry_organization_id
      LEFT JOIN grac_practice.location_type_master j1 ON j1.location_type_id = t.location_type_id
      LEFT JOIN grac_practice.organization j2 ON j2.organization_id = t.organization_id
      LEFT JOIN grac_practice.organization_division j3 ON j3.division_id = t.division_id
      LEFT JOIN grac_practice.organization_location j4 ON j4.location_id = t.parent_location_id
      LEFT JOIN @tz j5 ON j5.id = t.time_zone_id
      LEFT JOIN grac_practice.organization_employee j6 ON j6.employee_id = t.location_head_id
     WHERE (@id = 0 OR t.location_id = @id)
       AND (@registry_organization_id = 0 OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL) OR le.registry_organization_id = @registry_organization_id)
       AND (@legal_entity_id = 0 OR le.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR le.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
       AND (@status = N'' OR t.status = @status)
       AND (@search = N'' OR t.location_code LIKE N'%' + @search + N'%' OR t.location_name LIKE N'%' + @search + N'%')
     ORDER BY le.organization_name, t.location_code;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_locations_save
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_location WHERE location_id = @id)
        THROW 52705, N'[] The Location no longer exists. Reload the list.', 1;

    -- Outside GRAC administration a record of another Legal Entity is out of reach.
    IF @allowed_legal_entity_ids IS NOT NULL AND @id > 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_location x WHERE x.location_id = @id AND x.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[] This record belongs to a Legal Entity you do not have access to.', 1;

    -- Raw values (text; OPENJSON so long text is never truncated).
    DECLARE @f_locationCode NVARCHAR(MAX);
    DECLARE @f_locationName NVARCHAR(MAX);
    DECLARE @f_locationType NVARCHAR(MAX);
    DECLARE @f_legalEntityId NVARCHAR(MAX);
    DECLARE @f_organizationUnitId NVARCHAR(MAX);
    DECLARE @f_parentLocationId NVARCHAR(MAX);
    DECLARE @f_addressLine1 NVARCHAR(MAX);
    DECLARE @f_addressLine2 NVARCHAR(MAX);
    DECLARE @f_cityTown NVARCHAR(MAX);
    DECLARE @f_district NVARCHAR(MAX);
    DECLARE @f_state NVARCHAR(MAX);
    DECLARE @f_pinCode NVARCHAR(MAX);
    DECLARE @f_country NVARCHAR(MAX);
    DECLARE @f_latitude NVARCHAR(MAX);
    DECLARE @f_longitude NVARCHAR(MAX);
    DECLARE @f_regionZoneLabel NVARCHAR(MAX);
    DECLARE @f_timeZone NVARCHAR(MAX);
    DECLARE @f_locationHeadPersonId NVARCHAR(MAX);
    DECLARE @f_openingDate NVARCHAR(MAX);
    DECLARE @f_closureDate NVARCHAR(MAX);
    DECLARE @f_customerFacing NVARCHAR(MAX);
    DECLARE @f_operationalStatus NVARCHAR(MAX);
    DECLARE @f_remarks NVARCHAR(MAX);
    SELECT @f_locationCode = NULLIF(LTRIM(RTRIM(j.[locationCode])), N''),
           @f_locationName = NULLIF(LTRIM(RTRIM(j.[locationName])), N''),
           @f_locationType = NULLIF(LTRIM(RTRIM(j.[locationType])), N''),
           @f_legalEntityId = NULLIF(LTRIM(RTRIM(j.[legalEntityId])), N''),
           @f_organizationUnitId = NULLIF(LTRIM(RTRIM(j.[organizationUnitId])), N''),
           @f_parentLocationId = NULLIF(LTRIM(RTRIM(j.[parentLocationId])), N''),
           @f_addressLine1 = NULLIF(LTRIM(RTRIM(j.[addressLine1])), N''),
           @f_addressLine2 = NULLIF(LTRIM(RTRIM(j.[addressLine2])), N''),
           @f_cityTown = NULLIF(LTRIM(RTRIM(j.[cityTown])), N''),
           @f_district = NULLIF(LTRIM(RTRIM(j.[district])), N''),
           @f_state = NULLIF(LTRIM(RTRIM(j.[state])), N''),
           @f_pinCode = NULLIF(LTRIM(RTRIM(j.[pinCode])), N''),
           @f_country = NULLIF(LTRIM(RTRIM(j.[country])), N''),
           @f_latitude = NULLIF(LTRIM(RTRIM(j.[latitude])), N''),
           @f_longitude = NULLIF(LTRIM(RTRIM(j.[longitude])), N''),
           @f_regionZoneLabel = NULLIF(LTRIM(RTRIM(j.[regionZoneLabel])), N''),
           @f_timeZone = NULLIF(LTRIM(RTRIM(j.[timeZone])), N''),
           @f_locationHeadPersonId = NULLIF(LTRIM(RTRIM(j.[locationHeadPersonId])), N''),
           @f_openingDate = NULLIF(LTRIM(RTRIM(j.[openingDate])), N''),
           @f_closureDate = NULLIF(LTRIM(RTRIM(j.[closureDate])), N''),
           @f_customerFacing = NULLIF(LTRIM(RTRIM(j.[customerFacing])), N''),
           @f_operationalStatus = NULLIF(LTRIM(RTRIM(j.[operationalStatus])), N''),
           @f_remarks = NULLIF(LTRIM(RTRIM(j.[remarks])), N'')
      FROM OPENJSON(@payload) WITH ([locationCode] NVARCHAR(MAX) N'$.locationCode',
           [locationName] NVARCHAR(MAX) N'$.locationName',
           [locationType] NVARCHAR(MAX) N'$.locationType',
           [legalEntityId] NVARCHAR(MAX) N'$.legalEntityId',
           [organizationUnitId] NVARCHAR(MAX) N'$.organizationUnitId',
           [parentLocationId] NVARCHAR(MAX) N'$.parentLocationId',
           [addressLine1] NVARCHAR(MAX) N'$.addressLine1',
           [addressLine2] NVARCHAR(MAX) N'$.addressLine2',
           [cityTown] NVARCHAR(MAX) N'$.cityTown',
           [district] NVARCHAR(MAX) N'$.district',
           [state] NVARCHAR(MAX) N'$.state',
           [pinCode] NVARCHAR(MAX) N'$.pinCode',
           [country] NVARCHAR(MAX) N'$.country',
           [latitude] NVARCHAR(MAX) N'$.latitude',
           [longitude] NVARCHAR(MAX) N'$.longitude',
           [regionZoneLabel] NVARCHAR(MAX) N'$.regionZoneLabel',
           [timeZone] NVARCHAR(MAX) N'$.timeZone',
           [locationHeadPersonId] NVARCHAR(MAX) N'$.locationHeadPersonId',
           [openingDate] NVARCHAR(MAX) N'$.openingDate',
           [closureDate] NVARCHAR(MAX) N'$.closureDate',
           [customerFacing] NVARCHAR(MAX) N'$.customerFacing',
           [operationalStatus] NVARCHAR(MAX) N'$.operationalStatus',
           [remarks] NVARCHAR(MAX) N'$.remarks') j;

    DECLARE @i_locationType INT = NULL;
    DECLARE @r_legalEntityId BIGINT = TRY_CONVERT(BIGINT, @f_legalEntityId);
    IF @f_legalEntityId IS NOT NULL AND @r_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Legal Entity Code is not a valid selection.', 1;
    DECLARE @r_organizationUnitId BIGINT = TRY_CONVERT(BIGINT, @f_organizationUnitId);
    IF @f_organizationUnitId IS NOT NULL AND @r_organizationUnitId IS NULL THROW 52701, N'[organizationUnitId] Organization Unit Code is not a valid selection.', 1;
    DECLARE @r_parentLocationId BIGINT = TRY_CONVERT(BIGINT, @f_parentLocationId);
    IF @f_parentLocationId IS NOT NULL AND @r_parentLocationId IS NULL THROW 52701, N'[parentLocationId] Parent Location Code is not a valid selection.', 1;
    DECLARE @x_latitude DECIMAL(9,6) = TRY_CONVERT(DECIMAL(9,6), @f_latitude);
    IF @f_latitude IS NOT NULL AND (@x_latitude IS NULL OR @x_latitude < -90 OR @x_latitude > 90) THROW 52701, N'[latitude] Latitude (optional) must be a number between -90 and 90.', 1;
    DECLARE @x_longitude DECIMAL(9,6) = TRY_CONVERT(DECIMAL(9,6), @f_longitude);
    IF @f_longitude IS NOT NULL AND (@x_longitude IS NULL OR @x_longitude < -180 OR @x_longitude > 180) THROW 52701, N'[longitude] Longitude (optional) must be a number between -180 and 180.', 1;
    DECLARE @i_timeZone BIGINT = NULL;
    DECLARE @r_locationHeadPersonId BIGINT = TRY_CONVERT(BIGINT, @f_locationHeadPersonId);
    IF @f_locationHeadPersonId IS NOT NULL AND @r_locationHeadPersonId IS NULL THROW 52701, N'[locationHeadPersonId] Location Head Person Code is not a valid selection.', 1;
    DECLARE @d_openingDate DATE = TRY_CONVERT(DATE, LEFT(@f_openingDate, 10), 23);
    IF @f_openingDate IS NOT NULL AND @d_openingDate IS NULL THROW 52701, N'[openingDate] Opening Date must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_closureDate DATE = TRY_CONVERT(DATE, LEFT(@f_closureDate, 10), 23);
    IF @f_closureDate IS NOT NULL AND @d_closureDate IS NULL THROW 52701, N'[closureDate] Closure Date must be a date (yyyy-mm-dd).', 1;

    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).
    IF @f_locationCode IS NULL THROW 52701, N'[locationCode] Location Code is required.', 1;
    IF @f_locationName IS NULL THROW 52701, N'[locationName] Location Name is required.', 1;
    IF @f_locationType IS NULL THROW 52701, N'[locationType] Location Type is required.', 1;
    IF @f_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Legal Entity Code is required.', 1;
    IF @f_state IS NULL THROW 52701, N'[state] State is required.', 1;
    IF @f_country IS NULL THROW 52701, N'[country] Country is required.', 1;
    IF @f_customerFacing IS NULL THROW 52701, N'[customerFacing] Customer-facing? is required.', 1;
    IF @f_operationalStatus IS NULL THROW 52701, N'[operationalStatus] Operational Status is required.', 1;
    IF LEN(@f_locationCode) > 80 THROW 52701, N'[locationCode] Location Code cannot be longer than 80 characters.', 1;
    IF LEN(@f_locationName) > 200 THROW 52701, N'[locationName] Location Name cannot be longer than 200 characters.', 1;
    IF LEN(@f_addressLine1) > 200 THROW 52701, N'[addressLine1] Address Line 1 cannot be longer than 200 characters.', 1;
    IF LEN(@f_addressLine2) > 200 THROW 52701, N'[addressLine2] Address Line 2 cannot be longer than 200 characters.', 1;
    IF LEN(@f_cityTown) > 120 THROW 52701, N'[cityTown] City / Town cannot be longer than 120 characters.', 1;
    IF LEN(@f_district) > 120 THROW 52701, N'[district] District cannot be longer than 120 characters.', 1;
    IF LEN(@f_pinCode) > 30 THROW 52701, N'[pinCode] PIN Code cannot be longer than 30 characters.', 1;
    IF LEN(@f_regionZoneLabel) > 160 THROW 52701, N'[regionZoneLabel] Region / Zone Label cannot be longer than 160 characters.', 1;
    IF @d_openingDate IS NOT NULL AND @d_closureDate IS NOT NULL AND @d_closureDate < @d_openingDate THROW 52701, N'[closureDate] Closure Date cannot be before Opening Date.', 1;

    -- Controlled values (15 Masters & Codes). A value that is not on the list
    -- is accepted only when it is the value the record already holds, so an
    -- older record can still be saved without being forced to change it.
    SELECT TOP (1) @i_locationType = lt.location_type_id FROM grac_practice.location_type_master lt
     WHERE lt.location_type_name = @f_locationType ORDER BY lt.is_active DESC, lt.location_type_id;
    IF @f_locationType IS NOT NULL AND @i_locationType IS NULL THROW 52702, N'[locationType] Location Type: the value is not in the approved list (LocationType).', 1;
    IF @f_state IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'State' AND m.value_label = @f_state AND m.status = N'Active')
            SELECT @f_state = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'State' AND m.value_label = @f_state;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_location WHERE location_id = @id AND state_province = @f_state)
            THROW 52702, N'[state] State: the value is not in the approved list (State).', 1;
    END
    IF @f_country IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'Country' AND m.value_label = @f_country AND m.status = N'Active')
            SELECT @f_country = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'Country' AND m.value_label = @f_country;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_location WHERE location_id = @id AND country = @f_country)
            THROW 52702, N'[country] Country: the value is not in the approved list (Country).', 1;
    END
    DECLARE @tz TABLE (id BIGINT NOT NULL PRIMARY KEY, label NVARCHAR(400) NOT NULL, active BIT NOT NULL);
    IF OBJECT_ID(N'GRAC_New.time_zone_master', N'U') IS NOT NULL
        INSERT @tz (id, label, active)
        SELECT z.time_zone_id, z.time_zone_name + ISNULL(N' (' + z.iana_time_zone + N')', N''),
               CASE WHEN z.status = N'Active' THEN 1 ELSE 0 END
          FROM GRAC_New.time_zone_master z;
    IF OBJECT_ID(N'GRAC_New.time_zone_master', N'U') IS NULL
        -- Time zones not deployed: the screen cannot show or pick one, so
        -- the record keeps the one it has.
        SET @i_timeZone = (SELECT time_zone_id FROM grac_practice.organization_location WHERE location_id = @id);
    ELSE IF @f_timeZone IS NOT NULL
    BEGIN
        SELECT TOP (1) @i_timeZone = z.id FROM @tz z WHERE z.label = @f_timeZone ORDER BY z.active DESC, z.id;
        IF @i_timeZone IS NULL THROW 52702, N'[timeZone] Time Zone: the value is not in the time zone list.', 1;
        IF NOT EXISTS (SELECT 1 FROM @tz z WHERE z.id = @i_timeZone AND z.active = 1)
           AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_location WHERE location_id = @id AND time_zone_id = @i_timeZone)
            THROW 52702, N'[timeZone] Time Zone: the selected time zone is not Active.', 1;
    END
    IF @f_customerFacing IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_customerFacing AND m.status = N'Active')
            SELECT @f_customerFacing = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_customerFacing;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_location WHERE location_id = @id AND customer_facing = @f_customerFacing)
            THROW 52702, N'[customerFacing] Customer-facing?: the value is not in the approved list (YesNo).', 1;
    END
    IF @f_operationalStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_operationalStatus AND m.status = N'Active')
            SELECT @f_operationalStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_operationalStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_location WHERE location_id = @id AND status = @f_operationalStatus)
            THROW 52702, N'[operationalStatus] Operational Status: the value is not in the approved list (RecordStatus).', 1;
    END

    DECLARE @le BIGINT = @r_legalEntityId;
    IF @le IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @le) THROW 52703, N'[legalEntityId] The selected Legal Entity does not exist.', 1;
    IF @id > 0 AND EXISTS (SELECT 1 FROM grac_practice.organization_location WHERE location_id = @id AND organization_id <> @le)
       AND EXISTS (SELECT 1 FROM grac_practice.organization_location WHERE location_id = @id AND organization_id IS NOT NULL)
        THROW 52703, N'[legalEntityId] A Location cannot be moved to another Legal Entity: other records refer to it there. Mark it Inactive and create it in the other Legal Entity.', 1;
    IF @allowed_legal_entity_ids IS NOT NULL AND (@le IS NULL OR @le NOT IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[legalEntityId] You can only maintain records of your own Legal Entities.', 1;

    -- References: the record must exist (and belong where the field says).
    IF @r_organizationUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @r_organizationUnitId) THROW 52703, N'[organizationUnitId] Organization Unit Code: the selected record does not exist.', 1;
    IF @r_organizationUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division x WHERE x.division_id = @r_organizationUnitId AND x.organization_id = @le)
        THROW 52703, N'[organizationUnitId] Organization Unit Code must belong to the same Legal Entity.', 1;
    IF @r_parentLocationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_location WHERE location_id = @r_parentLocationId) THROW 52703, N'[parentLocationId] Parent Location Code: the selected record does not exist.', 1;
    IF @r_parentLocationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_location x WHERE x.location_id = @r_parentLocationId AND x.organization_id = @le)
        THROW 52703, N'[parentLocationId] Parent Location Code must belong to the same Legal Entity.', 1;
    IF @r_parentLocationId IS NOT NULL AND @id > 0
    BEGIN
        IF @r_parentLocationId = @id THROW 52706, N'[parentLocationId] Parent Location Code cannot be the record itself.', 1;
        DECLARE @walk_parentLocationId BIGINT = @r_parentLocationId, @guard_parentLocationId INT = 0;
        WHILE @walk_parentLocationId IS NOT NULL AND @guard_parentLocationId < 100
        BEGIN
            IF @walk_parentLocationId = @id THROW 52706, N'[parentLocationId] Parent Location Code would make a loop: this record is already above it.', 1;
            SET @walk_parentLocationId = (SELECT parent_location_id FROM grac_practice.organization_location WHERE location_id = @walk_parentLocationId);
            SET @guard_parentLocationId += 1;
        END
    END
    IF @r_locationHeadPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_locationHeadPersonId) THROW 52703, N'[locationHeadPersonId] Location Head Person Code: the selected record does not exist.', 1;
    IF @r_locationHeadPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_locationHeadPersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[locationHeadPersonId] Location Head Person Code must belong to the same Organization.', 1;

    -- Unique codes.
    IF EXISTS (SELECT 1 FROM grac_practice.organization_location WHERE organization_id = @le AND location_code = @f_locationCode AND location_id <> @id) THROW 52704, N'[locationCode] Location Code is already used in this Legal Entity.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.organization_location WHERE organization_id = @le AND location_name = @f_locationName AND location_id <> @id) THROW 52704, N'[locationName] Location Name is already used in this Legal Entity.', 1;

    DECLARE @rsid INT = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master
                          WHERE status_code = CASE WHEN @f_operationalStatus = N'Active' THEN N'Active'
                                                   WHEN @f_operationalStatus IN (N'Draft', N'Pending Approval') THEN N'Draft'
                                                   ELSE N'Inactive' END);
    IF @rsid IS NULL SET @rsid = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).
    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT location_code, location_name, location_type_id, organization_id, division_id, parent_location_id, address_line1, address_line2, city, district, state_province, postal_code, country, latitude, longitude, region, time_zone_id, location_head_id, opening_dt, closure_dt, customer_facing, status, remarks, record_status_id FROM grac_practice.organization_location WHERE location_id = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;
    BEGIN TRAN;
    IF @id = 0
    BEGIN
        INSERT grac_practice.organization_location (location_code, location_name, location_type_id, organization_id, division_id, parent_location_id, address_line1, address_line2, city, district, state_province, postal_code, country, latitude, longitude, region, time_zone_id, location_head_id, opening_dt, closure_dt, customer_facing, status, remarks, record_status_id, entered_by)
        VALUES (@f_locationCode, @f_locationName, @i_locationType, @r_legalEntityId, @r_organizationUnitId, @r_parentLocationId, @f_addressLine1, @f_addressLine2, @f_cityTown, @f_district, @f_state, @f_pinCode, @f_country, @x_latitude, @x_longitude, @f_regionZoneLabel, @i_timeZone, @r_locationHeadPersonId, @d_openingDate, @d_closureDate, @f_customerFacing, @f_operationalStatus, @f_remarks, @rsid, @actor);
        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_location SET location_code = @f_locationCode,
               location_name = @f_locationName,
               location_type_id = @i_locationType,
               organization_id = @r_legalEntityId,
               division_id = @r_organizationUnitId,
               parent_location_id = @r_parentLocationId,
               address_line1 = @f_addressLine1,
               address_line2 = @f_addressLine2,
               city = @f_cityTown,
               district = @f_district,
               state_province = @f_state,
               postal_code = @f_pinCode,
               country = @f_country,
               latitude = @x_latitude,
               longitude = @x_longitude,
               region = @f_regionZoneLabel,
               time_zone_id = @i_timeZone,
               location_head_id = @r_locationHeadPersonId,
               opening_dt = @d_openingDate,
               closure_dt = @d_closureDate,
               customer_facing = @f_customerFacing,
               status = @f_operationalStatus,
               remarks = @f_remarks,
               record_status_id = @rsid,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE location_id = @id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/locations', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Location saved.' AS Message, @id AS Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_departments_list
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
    SELECT t.department_id AS Id,
           t.department_code AS Code,
           t.department_name AS Name,
           t.status AS Status,
           le.organization_id AS LegalEntityId,
           le.organization_code AS LegalEntityCode,
           le.organization_name AS LegalEntityName,
           le.registry_organization_id AS RegistryOrganizationId,
           ro.organization_code AS RegistryOrganizationCode,
           ro.registered_name AS RegistryOrganizationName,
           t.entered_by AS EnteredBy,
           t.entered_dt AS EnteredDate,
           COALESCE(t.updated_by, t.entered_by) AS UpdatedBy,
           COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate,
           t.department_code AS DepartmentCode,
           t.department_name AS DepartmentName,
           t.short_name AS ShortName,
           t.department_type AS DepartmentType,
           t.parent_department_id AS ParentDepartmentId,
           j1.department_code AS ParentDepartmentCode,
           j1.department_name AS ParentDepartmentName,
           t.organization_id AS LegalEntityId,
           j2.organization_code AS LegalEntityCode,
           j2.organization_name AS LegalEntityName,
           t.primary_division_id AS PrimaryOrganizationUnitId,
           j3.division_code AS PrimaryOrganizationUnitCode,
           j3.division_name AS PrimaryOrganizationUnitName,
           t.head_employee_id AS DepartmentHeadPersonId,
           j4.employee_code AS DepartmentHeadPersonCode,
           j4.employee_name AS DepartmentHeadPersonName,
           t.head_designation AS DepartmentHeadDesignation,
           t.primary_business_function_id AS PrimaryBusinessFunctionId,
           j5.function_code AS PrimaryBusinessFunctionCode,
           j5.function_name AS PrimaryBusinessFunctionName,
           t.cost_centre AS CostCentre,
           t.centralisation AS Centralisation,
           t.status AS RecordStatus,
           t.effective_from AS EffectiveFrom,
           t.effective_to AS EffectiveTo,
           t.remarks AS Remarks
      FROM grac_practice.organization_department t
      LEFT JOIN grac_practice.organization le ON le.organization_id = t.organization_id
      LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = le.registry_organization_id
      LEFT JOIN grac_practice.organization_department j1 ON j1.department_id = t.parent_department_id
      LEFT JOIN grac_practice.organization j2 ON j2.organization_id = t.organization_id
      LEFT JOIN grac_practice.organization_division j3 ON j3.division_id = t.primary_division_id
      LEFT JOIN grac_practice.organization_employee j4 ON j4.employee_id = t.head_employee_id
      LEFT JOIN grac_practice.organization_business_function j5 ON j5.business_function_id = t.primary_business_function_id
     WHERE (@id = 0 OR t.department_id = @id)
       AND (@registry_organization_id = 0 OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL) OR le.registry_organization_id = @registry_organization_id)
       AND (@legal_entity_id = 0 OR le.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR le.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
       AND (@status = N'' OR t.status = @status)
       AND (@search = N'' OR t.department_code LIKE N'%' + @search + N'%' OR t.department_name LIKE N'%' + @search + N'%')
     ORDER BY le.organization_name, t.department_code;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_departments_save
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE department_id = @id)
        THROW 52705, N'[] The Department no longer exists. Reload the list.', 1;

    -- Outside GRAC administration a record of another Legal Entity is out of reach.
    IF @allowed_legal_entity_ids IS NOT NULL AND @id > 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department x WHERE x.department_id = @id AND x.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[] This record belongs to a Legal Entity you do not have access to.', 1;

    -- Raw values (text; OPENJSON so long text is never truncated).
    DECLARE @f_departmentCode NVARCHAR(MAX);
    DECLARE @f_departmentName NVARCHAR(MAX);
    DECLARE @f_shortName NVARCHAR(MAX);
    DECLARE @f_departmentType NVARCHAR(MAX);
    DECLARE @f_parentDepartmentId NVARCHAR(MAX);
    DECLARE @f_legalEntityId NVARCHAR(MAX);
    DECLARE @f_primaryOrganizationUnitId NVARCHAR(MAX);
    DECLARE @f_departmentHeadPersonId NVARCHAR(MAX);
    DECLARE @f_departmentHeadDesignation NVARCHAR(MAX);
    DECLARE @f_primaryBusinessFunctionId NVARCHAR(MAX);
    DECLARE @f_costCentre NVARCHAR(MAX);
    DECLARE @f_centralisation NVARCHAR(MAX);
    DECLARE @f_recordStatus NVARCHAR(MAX);
    DECLARE @f_effectiveFrom NVARCHAR(MAX);
    DECLARE @f_effectiveTo NVARCHAR(MAX);
    DECLARE @f_remarks NVARCHAR(MAX);
    SELECT @f_departmentCode = NULLIF(LTRIM(RTRIM(j.[departmentCode])), N''),
           @f_departmentName = NULLIF(LTRIM(RTRIM(j.[departmentName])), N''),
           @f_shortName = NULLIF(LTRIM(RTRIM(j.[shortName])), N''),
           @f_departmentType = NULLIF(LTRIM(RTRIM(j.[departmentType])), N''),
           @f_parentDepartmentId = NULLIF(LTRIM(RTRIM(j.[parentDepartmentId])), N''),
           @f_legalEntityId = NULLIF(LTRIM(RTRIM(j.[legalEntityId])), N''),
           @f_primaryOrganizationUnitId = NULLIF(LTRIM(RTRIM(j.[primaryOrganizationUnitId])), N''),
           @f_departmentHeadPersonId = NULLIF(LTRIM(RTRIM(j.[departmentHeadPersonId])), N''),
           @f_departmentHeadDesignation = NULLIF(LTRIM(RTRIM(j.[departmentHeadDesignation])), N''),
           @f_primaryBusinessFunctionId = NULLIF(LTRIM(RTRIM(j.[primaryBusinessFunctionId])), N''),
           @f_costCentre = NULLIF(LTRIM(RTRIM(j.[costCentre])), N''),
           @f_centralisation = NULLIF(LTRIM(RTRIM(j.[centralisation])), N''),
           @f_recordStatus = NULLIF(LTRIM(RTRIM(j.[recordStatus])), N''),
           @f_effectiveFrom = NULLIF(LTRIM(RTRIM(j.[effectiveFrom])), N''),
           @f_effectiveTo = NULLIF(LTRIM(RTRIM(j.[effectiveTo])), N''),
           @f_remarks = NULLIF(LTRIM(RTRIM(j.[remarks])), N'')
      FROM OPENJSON(@payload) WITH ([departmentCode] NVARCHAR(MAX) N'$.departmentCode',
           [departmentName] NVARCHAR(MAX) N'$.departmentName',
           [shortName] NVARCHAR(MAX) N'$.shortName',
           [departmentType] NVARCHAR(MAX) N'$.departmentType',
           [parentDepartmentId] NVARCHAR(MAX) N'$.parentDepartmentId',
           [legalEntityId] NVARCHAR(MAX) N'$.legalEntityId',
           [primaryOrganizationUnitId] NVARCHAR(MAX) N'$.primaryOrganizationUnitId',
           [departmentHeadPersonId] NVARCHAR(MAX) N'$.departmentHeadPersonId',
           [departmentHeadDesignation] NVARCHAR(MAX) N'$.departmentHeadDesignation',
           [primaryBusinessFunctionId] NVARCHAR(MAX) N'$.primaryBusinessFunctionId',
           [costCentre] NVARCHAR(MAX) N'$.costCentre',
           [centralisation] NVARCHAR(MAX) N'$.centralisation',
           [recordStatus] NVARCHAR(MAX) N'$.recordStatus',
           [effectiveFrom] NVARCHAR(MAX) N'$.effectiveFrom',
           [effectiveTo] NVARCHAR(MAX) N'$.effectiveTo',
           [remarks] NVARCHAR(MAX) N'$.remarks') j;

    DECLARE @r_parentDepartmentId BIGINT = TRY_CONVERT(BIGINT, @f_parentDepartmentId);
    IF @f_parentDepartmentId IS NOT NULL AND @r_parentDepartmentId IS NULL THROW 52701, N'[parentDepartmentId] Parent Department Code is not a valid selection.', 1;
    DECLARE @r_legalEntityId BIGINT = TRY_CONVERT(BIGINT, @f_legalEntityId);
    IF @f_legalEntityId IS NOT NULL AND @r_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Legal Entity Code is not a valid selection.', 1;
    DECLARE @r_primaryOrganizationUnitId BIGINT = TRY_CONVERT(BIGINT, @f_primaryOrganizationUnitId);
    IF @f_primaryOrganizationUnitId IS NOT NULL AND @r_primaryOrganizationUnitId IS NULL THROW 52701, N'[primaryOrganizationUnitId] Primary Organization Unit Code is not a valid selection.', 1;
    DECLARE @r_departmentHeadPersonId BIGINT = TRY_CONVERT(BIGINT, @f_departmentHeadPersonId);
    IF @f_departmentHeadPersonId IS NOT NULL AND @r_departmentHeadPersonId IS NULL THROW 52701, N'[departmentHeadPersonId] Department Head Person Code is not a valid selection.', 1;
    DECLARE @r_primaryBusinessFunctionId BIGINT = TRY_CONVERT(BIGINT, @f_primaryBusinessFunctionId);
    IF @f_primaryBusinessFunctionId IS NOT NULL AND @r_primaryBusinessFunctionId IS NULL THROW 52701, N'[primaryBusinessFunctionId] Primary Business Function Code is not a valid selection.', 1;
    DECLARE @d_effectiveFrom DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveFrom, 10), 23);
    IF @f_effectiveFrom IS NOT NULL AND @d_effectiveFrom IS NULL THROW 52701, N'[effectiveFrom] Effective From must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_effectiveTo DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveTo, 10), 23);
    IF @f_effectiveTo IS NOT NULL AND @d_effectiveTo IS NULL THROW 52701, N'[effectiveTo] Effective To must be a date (yyyy-mm-dd).', 1;

    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).
    IF @f_departmentCode IS NULL THROW 52701, N'[departmentCode] Department Code is required.', 1;
    IF @f_departmentName IS NULL THROW 52701, N'[departmentName] Department Name is required.', 1;
    IF @f_departmentType IS NULL THROW 52701, N'[departmentType] Department Type is required.', 1;
    IF @f_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Legal Entity Code is required.', 1;
    IF @f_recordStatus IS NULL THROW 52701, N'[recordStatus] Record Status is required.', 1;
    IF LEN(@f_departmentCode) > 80 THROW 52701, N'[departmentCode] Department Code cannot be longer than 80 characters.', 1;
    IF LEN(@f_departmentName) > 200 THROW 52701, N'[departmentName] Department Name cannot be longer than 200 characters.', 1;
    IF LEN(@f_shortName) > 120 THROW 52701, N'[shortName] Short Name cannot be longer than 120 characters.', 1;
    IF LEN(@f_departmentHeadDesignation) > 200 THROW 52701, N'[departmentHeadDesignation] Department Head Designation cannot be longer than 200 characters.', 1;
    IF LEN(@f_costCentre) > 80 THROW 52701, N'[costCentre] Cost Centre cannot be longer than 80 characters.', 1;
    IF @d_effectiveFrom IS NOT NULL AND @d_effectiveTo IS NOT NULL AND @d_effectiveTo < @d_effectiveFrom THROW 52701, N'[effectiveTo] Effective To cannot be before Effective From.', 1;

    -- Controlled values (15 Masters & Codes). A value that is not on the list
    -- is accepted only when it is the value the record already holds, so an
    -- older record can still be saved without being forced to change it.
    IF @f_departmentType IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'DepartmentType' AND m.value_label = @f_departmentType AND m.status = N'Active')
            SELECT @f_departmentType = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'DepartmentType' AND m.value_label = @f_departmentType;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE department_id = @id AND department_type = @f_departmentType)
            THROW 52702, N'[departmentType] Department Type: the value is not in the approved list (DepartmentType).', 1;
    END
    IF @f_centralisation IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'Centralisation' AND m.value_label = @f_centralisation AND m.status = N'Active')
            SELECT @f_centralisation = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'Centralisation' AND m.value_label = @f_centralisation;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE department_id = @id AND centralisation = @f_centralisation)
            THROW 52702, N'[centralisation] Centralised / Distributed: the value is not in the approved list (Centralisation).', 1;
    END
    IF @f_recordStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus AND m.status = N'Active')
            SELECT @f_recordStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE department_id = @id AND status = @f_recordStatus)
            THROW 52702, N'[recordStatus] Record Status: the value is not in the approved list (RecordStatus).', 1;
    END

    DECLARE @le BIGINT = @r_legalEntityId;
    IF @le IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @le) THROW 52703, N'[legalEntityId] The selected Legal Entity does not exist.', 1;
    IF @id > 0 AND EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE department_id = @id AND organization_id <> @le)
       AND EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE department_id = @id AND organization_id IS NOT NULL)
        THROW 52703, N'[legalEntityId] A Department cannot be moved to another Legal Entity: other records refer to it there. Mark it Inactive and create it in the other Legal Entity.', 1;
    IF @allowed_legal_entity_ids IS NOT NULL AND (@le IS NULL OR @le NOT IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[legalEntityId] You can only maintain records of your own Legal Entities.', 1;

    -- References: the record must exist (and belong where the field says).
    IF @r_parentDepartmentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE department_id = @r_parentDepartmentId) THROW 52703, N'[parentDepartmentId] Parent Department Code: the selected record does not exist.', 1;
    IF @r_parentDepartmentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department x WHERE x.department_id = @r_parentDepartmentId AND x.organization_id = @le)
        THROW 52703, N'[parentDepartmentId] Parent Department Code must belong to the same Legal Entity.', 1;
    IF @r_parentDepartmentId IS NOT NULL AND @id > 0
    BEGIN
        IF @r_parentDepartmentId = @id THROW 52706, N'[parentDepartmentId] Parent Department Code cannot be the record itself.', 1;
        DECLARE @walk_parentDepartmentId BIGINT = @r_parentDepartmentId, @guard_parentDepartmentId INT = 0;
        WHILE @walk_parentDepartmentId IS NOT NULL AND @guard_parentDepartmentId < 100
        BEGIN
            IF @walk_parentDepartmentId = @id THROW 52706, N'[parentDepartmentId] Parent Department Code would make a loop: this record is already above it.', 1;
            SET @walk_parentDepartmentId = (SELECT parent_department_id FROM grac_practice.organization_department WHERE department_id = @walk_parentDepartmentId);
            SET @guard_parentDepartmentId += 1;
        END
    END
    IF @r_primaryOrganizationUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @r_primaryOrganizationUnitId) THROW 52703, N'[primaryOrganizationUnitId] Primary Organization Unit Code: the selected record does not exist.', 1;
    IF @r_primaryOrganizationUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division x WHERE x.division_id = @r_primaryOrganizationUnitId AND x.organization_id = @le)
        THROW 52703, N'[primaryOrganizationUnitId] Primary Organization Unit Code must belong to the same Legal Entity.', 1;
    IF @r_departmentHeadPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_departmentHeadPersonId) THROW 52703, N'[departmentHeadPersonId] Department Head Person Code: the selected record does not exist.', 1;
    IF @r_departmentHeadPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_departmentHeadPersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[departmentHeadPersonId] Department Head Person Code must belong to the same Organization.', 1;
    IF @r_primaryBusinessFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @r_primaryBusinessFunctionId) THROW 52703, N'[primaryBusinessFunctionId] Primary Business Function Code: the selected record does not exist.', 1;
    IF @r_primaryBusinessFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function x WHERE x.business_function_id = @r_primaryBusinessFunctionId AND x.organization_id = @le)
        THROW 52703, N'[primaryBusinessFunctionId] Primary Business Function Code must belong to the same Legal Entity.', 1;

    -- Unique codes.
    IF EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE organization_id = @le AND department_code = @f_departmentCode AND department_id <> @id) THROW 52704, N'[departmentCode] Department Code is already used in this Legal Entity.', 1;

    DECLARE @rsid INT = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master
                          WHERE status_code = CASE WHEN @f_recordStatus = N'Active' THEN N'Active'
                                                   WHEN @f_recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft'
                                                   ELSE N'Inactive' END);
    IF @rsid IS NULL SET @rsid = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).
    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT department_code, department_name, short_name, department_type, parent_department_id, organization_id, primary_division_id, head_employee_id, head_designation, primary_business_function_id, cost_centre, centralisation, status, effective_from, effective_to, remarks, record_status_id FROM grac_practice.organization_department WHERE department_id = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;
    BEGIN TRAN;
    IF @id = 0
    BEGIN
        INSERT grac_practice.organization_department (department_code, department_name, short_name, department_type, parent_department_id, organization_id, primary_division_id, head_employee_id, head_designation, primary_business_function_id, cost_centre, centralisation, status, effective_from, effective_to, remarks, record_status_id, entered_by)
        VALUES (@f_departmentCode, @f_departmentName, @f_shortName, @f_departmentType, @r_parentDepartmentId, @r_legalEntityId, @r_primaryOrganizationUnitId, @r_departmentHeadPersonId, @f_departmentHeadDesignation, @r_primaryBusinessFunctionId, @f_costCentre, @f_centralisation, @f_recordStatus, @d_effectiveFrom, @d_effectiveTo, @f_remarks, @rsid, @actor);
        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_department SET department_code = @f_departmentCode,
               department_name = @f_departmentName,
               short_name = @f_shortName,
               department_type = @f_departmentType,
               parent_department_id = @r_parentDepartmentId,
               organization_id = @r_legalEntityId,
               primary_division_id = @r_primaryOrganizationUnitId,
               head_employee_id = @r_departmentHeadPersonId,
               head_designation = @f_departmentHeadDesignation,
               primary_business_function_id = @r_primaryBusinessFunctionId,
               cost_centre = @f_costCentre,
               centralisation = @f_centralisation,
               status = @f_recordStatus,
               effective_from = @d_effectiveFrom,
               effective_to = @d_effectiveTo,
               remarks = @f_remarks,
               record_status_id = @rsid,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE department_id = @id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/departments', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Department saved.' AS Message, @id AS Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_functions_list
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
    SELECT t.business_function_id AS Id,
           t.function_code AS Code,
           t.function_name AS Name,
           t.status AS Status,
           le.organization_id AS LegalEntityId,
           le.organization_code AS LegalEntityCode,
           le.organization_name AS LegalEntityName,
           le.registry_organization_id AS RegistryOrganizationId,
           ro.organization_code AS RegistryOrganizationCode,
           ro.registered_name AS RegistryOrganizationName,
           t.entered_by AS EnteredBy,
           t.entered_dt AS EnteredDate,
           COALESCE(t.updated_by, t.entered_by) AS UpdatedBy,
           COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate,
           t.function_code AS FunctionCode,
           t.function_name AS FunctionName,
           t.function_category AS FunctionCategory,
           t.parent_function_id AS ParentFunctionId,
           j1.function_code AS ParentFunctionCode,
           j1.function_name AS ParentFunctionName,
           t.business_unit_type AS BusinessUnitType,
           t.criticality AS Criticality,
           t.owner_employee_id AS FunctionOwnerPersonId,
           j2.employee_code AS FunctionOwnerPersonCode,
           j2.employee_name AS FunctionOwnerPersonName,
           t.accountable_department_id AS AccountableDepartmentId,
           j3.department_code AS AccountableDepartmentCode,
           j3.department_name AS AccountableDepartmentName,
           t.executive_sponsor_employee_id AS ExecutiveSponsorPersonId,
           j4.employee_code AS ExecutiveSponsorPersonCode,
           j4.employee_name AS ExecutiveSponsorPersonName,
           t.description AS DescriptionScope,
           t.key_responsibilities AS KeyResponsibilities,
           t.organization_id AS LegalEntityId,
           j5.organization_code AS LegalEntityCode,
           j5.organization_name AS LegalEntityName,
           t.status AS RecordStatus,
           t.effective_from AS EffectiveFrom,
           t.effective_to AS EffectiveTo,
           t.remarks AS Remarks
      FROM grac_practice.organization_business_function t
      LEFT JOIN grac_practice.organization le ON le.organization_id = t.organization_id
      LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = le.registry_organization_id
      LEFT JOIN grac_practice.organization_business_function j1 ON j1.business_function_id = t.parent_function_id
      LEFT JOIN grac_practice.organization_employee j2 ON j2.employee_id = t.owner_employee_id
      LEFT JOIN grac_practice.organization_department j3 ON j3.department_id = t.accountable_department_id
      LEFT JOIN grac_practice.organization_employee j4 ON j4.employee_id = t.executive_sponsor_employee_id
      LEFT JOIN grac_practice.organization j5 ON j5.organization_id = t.organization_id
     WHERE (@id = 0 OR t.business_function_id = @id)
       AND (@registry_organization_id = 0 OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL) OR le.registry_organization_id = @registry_organization_id)
       AND (@legal_entity_id = 0 OR le.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR le.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
       AND (@status = N'' OR t.status = @status)
       AND (@search = N'' OR t.function_code LIKE N'%' + @search + N'%' OR t.function_name LIKE N'%' + @search + N'%')
     ORDER BY le.organization_name, t.function_code;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_functions_save
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @id)
        THROW 52705, N'[] The Business Function no longer exists. Reload the list.', 1;

    -- Outside GRAC administration a record of another Legal Entity is out of reach.
    IF @allowed_legal_entity_ids IS NOT NULL AND @id > 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function x WHERE x.business_function_id = @id AND x.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[] This record belongs to a Legal Entity you do not have access to.', 1;

    -- Raw values (text; OPENJSON so long text is never truncated).
    DECLARE @f_functionCode NVARCHAR(MAX);
    DECLARE @f_functionName NVARCHAR(MAX);
    DECLARE @f_functionCategory NVARCHAR(MAX);
    DECLARE @f_parentFunctionId NVARCHAR(MAX);
    DECLARE @f_businessUnitType NVARCHAR(MAX);
    DECLARE @f_criticality NVARCHAR(MAX);
    DECLARE @f_functionOwnerPersonId NVARCHAR(MAX);
    DECLARE @f_accountableDepartmentId NVARCHAR(MAX);
    DECLARE @f_executiveSponsorPersonId NVARCHAR(MAX);
    DECLARE @f_descriptionScope NVARCHAR(MAX);
    DECLARE @f_keyResponsibilities NVARCHAR(MAX);
    DECLARE @f_legalEntityId NVARCHAR(MAX);
    DECLARE @f_recordStatus NVARCHAR(MAX);
    DECLARE @f_effectiveFrom NVARCHAR(MAX);
    DECLARE @f_effectiveTo NVARCHAR(MAX);
    DECLARE @f_remarks NVARCHAR(MAX);
    SELECT @f_functionCode = NULLIF(LTRIM(RTRIM(j.[functionCode])), N''),
           @f_functionName = NULLIF(LTRIM(RTRIM(j.[functionName])), N''),
           @f_functionCategory = NULLIF(LTRIM(RTRIM(j.[functionCategory])), N''),
           @f_parentFunctionId = NULLIF(LTRIM(RTRIM(j.[parentFunctionId])), N''),
           @f_businessUnitType = NULLIF(LTRIM(RTRIM(j.[businessUnitType])), N''),
           @f_criticality = NULLIF(LTRIM(RTRIM(j.[criticality])), N''),
           @f_functionOwnerPersonId = NULLIF(LTRIM(RTRIM(j.[functionOwnerPersonId])), N''),
           @f_accountableDepartmentId = NULLIF(LTRIM(RTRIM(j.[accountableDepartmentId])), N''),
           @f_executiveSponsorPersonId = NULLIF(LTRIM(RTRIM(j.[executiveSponsorPersonId])), N''),
           @f_descriptionScope = NULLIF(LTRIM(RTRIM(j.[descriptionScope])), N''),
           @f_keyResponsibilities = NULLIF(LTRIM(RTRIM(j.[keyResponsibilities])), N''),
           @f_legalEntityId = NULLIF(LTRIM(RTRIM(j.[legalEntityId])), N''),
           @f_recordStatus = NULLIF(LTRIM(RTRIM(j.[recordStatus])), N''),
           @f_effectiveFrom = NULLIF(LTRIM(RTRIM(j.[effectiveFrom])), N''),
           @f_effectiveTo = NULLIF(LTRIM(RTRIM(j.[effectiveTo])), N''),
           @f_remarks = NULLIF(LTRIM(RTRIM(j.[remarks])), N'')
      FROM OPENJSON(@payload) WITH ([functionCode] NVARCHAR(MAX) N'$.functionCode',
           [functionName] NVARCHAR(MAX) N'$.functionName',
           [functionCategory] NVARCHAR(MAX) N'$.functionCategory',
           [parentFunctionId] NVARCHAR(MAX) N'$.parentFunctionId',
           [businessUnitType] NVARCHAR(MAX) N'$.businessUnitType',
           [criticality] NVARCHAR(MAX) N'$.criticality',
           [functionOwnerPersonId] NVARCHAR(MAX) N'$.functionOwnerPersonId',
           [accountableDepartmentId] NVARCHAR(MAX) N'$.accountableDepartmentId',
           [executiveSponsorPersonId] NVARCHAR(MAX) N'$.executiveSponsorPersonId',
           [descriptionScope] NVARCHAR(MAX) N'$.descriptionScope',
           [keyResponsibilities] NVARCHAR(MAX) N'$.keyResponsibilities',
           [legalEntityId] NVARCHAR(MAX) N'$.legalEntityId',
           [recordStatus] NVARCHAR(MAX) N'$.recordStatus',
           [effectiveFrom] NVARCHAR(MAX) N'$.effectiveFrom',
           [effectiveTo] NVARCHAR(MAX) N'$.effectiveTo',
           [remarks] NVARCHAR(MAX) N'$.remarks') j;

    DECLARE @r_parentFunctionId BIGINT = TRY_CONVERT(BIGINT, @f_parentFunctionId);
    IF @f_parentFunctionId IS NOT NULL AND @r_parentFunctionId IS NULL THROW 52701, N'[parentFunctionId] Parent Function Code is not a valid selection.', 1;
    DECLARE @r_functionOwnerPersonId BIGINT = TRY_CONVERT(BIGINT, @f_functionOwnerPersonId);
    IF @f_functionOwnerPersonId IS NOT NULL AND @r_functionOwnerPersonId IS NULL THROW 52701, N'[functionOwnerPersonId] Function Owner Person Code is not a valid selection.', 1;
    DECLARE @r_accountableDepartmentId BIGINT = TRY_CONVERT(BIGINT, @f_accountableDepartmentId);
    IF @f_accountableDepartmentId IS NOT NULL AND @r_accountableDepartmentId IS NULL THROW 52701, N'[accountableDepartmentId] Accountable Department Code is not a valid selection.', 1;
    DECLARE @r_executiveSponsorPersonId BIGINT = TRY_CONVERT(BIGINT, @f_executiveSponsorPersonId);
    IF @f_executiveSponsorPersonId IS NOT NULL AND @r_executiveSponsorPersonId IS NULL THROW 52701, N'[executiveSponsorPersonId] Executive Sponsor Person Code is not a valid selection.', 1;
    DECLARE @r_legalEntityId BIGINT = TRY_CONVERT(BIGINT, @f_legalEntityId);
    IF @f_legalEntityId IS NOT NULL AND @r_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Primary Legal Entity Code is not a valid selection.', 1;
    DECLARE @d_effectiveFrom DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveFrom, 10), 23);
    IF @f_effectiveFrom IS NOT NULL AND @d_effectiveFrom IS NULL THROW 52701, N'[effectiveFrom] Effective From must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_effectiveTo DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveTo, 10), 23);
    IF @f_effectiveTo IS NOT NULL AND @d_effectiveTo IS NULL THROW 52701, N'[effectiveTo] Effective To must be a date (yyyy-mm-dd).', 1;

    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).
    IF @f_functionCode IS NULL THROW 52701, N'[functionCode] Function Code is required.', 1;
    IF @f_functionName IS NULL THROW 52701, N'[functionName] Function Name is required.', 1;
    IF @f_functionCategory IS NULL THROW 52701, N'[functionCategory] Function Category is required.', 1;
    IF @f_criticality IS NULL THROW 52701, N'[criticality] Criticality is required.', 1;
    IF @f_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Primary Legal Entity Code is required.', 1;
    IF @f_recordStatus IS NULL THROW 52701, N'[recordStatus] Record Status is required.', 1;
    IF LEN(@f_functionCode) > 80 THROW 52701, N'[functionCode] Function Code cannot be longer than 80 characters.', 1;
    IF LEN(@f_functionName) > 200 THROW 52701, N'[functionName] Function Name cannot be longer than 200 characters.', 1;
    IF @d_effectiveFrom IS NOT NULL AND @d_effectiveTo IS NOT NULL AND @d_effectiveTo < @d_effectiveFrom THROW 52701, N'[effectiveTo] Effective To cannot be before Effective From.', 1;

    -- Controlled values (15 Masters & Codes). A value that is not on the list
    -- is accepted only when it is the value the record already holds, so an
    -- older record can still be saved without being forced to change it.
    IF @f_functionCategory IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'FunctionCategory' AND m.value_label = @f_functionCategory AND m.status = N'Active')
            SELECT @f_functionCategory = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'FunctionCategory' AND m.value_label = @f_functionCategory;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @id AND function_category = @f_functionCategory)
            THROW 52702, N'[functionCategory] Function Category: the value is not in the approved list (FunctionCategory).', 1;
    END
    IF @f_businessUnitType IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'BusinessUnitType' AND m.value_label = @f_businessUnitType AND m.status = N'Active')
            SELECT @f_businessUnitType = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'BusinessUnitType' AND m.value_label = @f_businessUnitType;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @id AND business_unit_type = @f_businessUnitType)
            THROW 52702, N'[businessUnitType] Business Unit Type: the value is not in the approved list (BusinessUnitType).', 1;
    END
    IF @f_criticality IS NOT NULL AND @f_criticality NOT IN (N'Critical', N'High', N'Medium', N'Low')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @id AND criticality = @f_criticality)
        THROW 52702, N'[criticality] Criticality must be one of: Critical / High / Medium / Low.', 1;
    IF @f_recordStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus AND m.status = N'Active')
            SELECT @f_recordStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @id AND status = @f_recordStatus)
            THROW 52702, N'[recordStatus] Record Status: the value is not in the approved list (RecordStatus).', 1;
    END
    IF @f_recordStatus NOT IN (N'Active', N'Inactive') THROW 52702, N'[recordStatus] A business function can only be Active or Inactive (migration 365).', 1;

    DECLARE @le BIGINT = @r_legalEntityId;
    IF @le IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @le) THROW 52703, N'[legalEntityId] The selected Legal Entity does not exist.', 1;
    IF @id > 0 AND EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @id AND organization_id <> @le)
       AND EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @id AND organization_id IS NOT NULL)
        THROW 52703, N'[legalEntityId] A Business Function cannot be moved to another Legal Entity: other records refer to it there. Mark it Inactive and create it in the other Legal Entity.', 1;
    IF @allowed_legal_entity_ids IS NOT NULL AND (@le IS NULL OR @le NOT IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[legalEntityId] You can only maintain records of your own Legal Entities.', 1;

    -- References: the record must exist (and belong where the field says).
    IF @r_parentFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @r_parentFunctionId) THROW 52703, N'[parentFunctionId] Parent Function Code: the selected record does not exist.', 1;
    IF @r_parentFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function x WHERE x.business_function_id = @r_parentFunctionId AND x.organization_id = @le)
        THROW 52703, N'[parentFunctionId] Parent Function Code must belong to the same Legal Entity.', 1;
    IF @r_parentFunctionId IS NOT NULL AND @id > 0
    BEGIN
        IF @r_parentFunctionId = @id THROW 52706, N'[parentFunctionId] Parent Function Code cannot be the record itself.', 1;
        DECLARE @walk_parentFunctionId BIGINT = @r_parentFunctionId, @guard_parentFunctionId INT = 0;
        WHILE @walk_parentFunctionId IS NOT NULL AND @guard_parentFunctionId < 100
        BEGIN
            IF @walk_parentFunctionId = @id THROW 52706, N'[parentFunctionId] Parent Function Code would make a loop: this record is already above it.', 1;
            SET @walk_parentFunctionId = (SELECT parent_function_id FROM grac_practice.organization_business_function WHERE business_function_id = @walk_parentFunctionId);
            SET @guard_parentFunctionId += 1;
        END
    END
    IF @r_functionOwnerPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_functionOwnerPersonId) THROW 52703, N'[functionOwnerPersonId] Function Owner Person Code: the selected record does not exist.', 1;
    IF @r_functionOwnerPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_functionOwnerPersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[functionOwnerPersonId] Function Owner Person Code must belong to the same Organization.', 1;
    IF @r_accountableDepartmentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE department_id = @r_accountableDepartmentId) THROW 52703, N'[accountableDepartmentId] Accountable Department Code: the selected record does not exist.', 1;
    IF @r_accountableDepartmentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department x WHERE x.department_id = @r_accountableDepartmentId AND x.organization_id = @le)
        THROW 52703, N'[accountableDepartmentId] Accountable Department Code must belong to the same Legal Entity.', 1;
    IF @r_executiveSponsorPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_executiveSponsorPersonId) THROW 52703, N'[executiveSponsorPersonId] Executive Sponsor Person Code: the selected record does not exist.', 1;
    IF @r_executiveSponsorPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_executiveSponsorPersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[executiveSponsorPersonId] Executive Sponsor Person Code must belong to the same Organization.', 1;

    -- Unique codes.
    IF EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE organization_id = @le AND function_code = @f_functionCode AND business_function_id <> @id) THROW 52704, N'[functionCode] Function Code is already used in this Legal Entity.', 1;

    DECLARE @owner_name NVARCHAR(200) = (SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id = @r_functionOwnerPersonId);

    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).
    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT function_code, function_name, function_category, parent_function_id, business_unit_type, criticality, owner_employee_id, accountable_department_id, executive_sponsor_employee_id, description, key_responsibilities, organization_id, status, effective_from, effective_to, remarks FROM grac_practice.organization_business_function WHERE business_function_id = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;
    BEGIN TRAN;
    IF @id = 0
    BEGIN
        INSERT grac_practice.organization_business_function (function_code, function_name, function_category, parent_function_id, business_unit_type, criticality, owner_employee_id, accountable_department_id, executive_sponsor_employee_id, description, key_responsibilities, organization_id, status, effective_from, effective_to, remarks, owner_name, entered_by)
        VALUES (@f_functionCode, @f_functionName, @f_functionCategory, @r_parentFunctionId, @f_businessUnitType, @f_criticality, @r_functionOwnerPersonId, @r_accountableDepartmentId, @r_executiveSponsorPersonId, @f_descriptionScope, @f_keyResponsibilities, @r_legalEntityId, @f_recordStatus, @d_effectiveFrom, @d_effectiveTo, @f_remarks, @owner_name, @actor);
        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_business_function SET function_code = @f_functionCode,
               function_name = @f_functionName,
               function_category = @f_functionCategory,
               parent_function_id = @r_parentFunctionId,
               business_unit_type = @f_businessUnitType,
               criticality = @f_criticality,
               owner_employee_id = @r_functionOwnerPersonId,
               accountable_department_id = @r_accountableDepartmentId,
               executive_sponsor_employee_id = @r_executiveSponsorPersonId,
               description = @f_descriptionScope,
               key_responsibilities = @f_keyResponsibilities,
               organization_id = @r_legalEntityId,
               status = @f_recordStatus,
               effective_from = @d_effectiveFrom,
               effective_to = @d_effectiveTo,
               remarks = @f_remarks,
               owner_name = COALESCE(@owner_name, owner_name),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE business_function_id = @id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/functions', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Business Function saved.' AS Message, @id AS Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_teams_list
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
    SELECT t.team_id AS Id,
           t.team_code AS Code,
           t.team_name AS Name,
           t.status AS Status,
           le.organization_id AS LegalEntityId,
           le.organization_code AS LegalEntityCode,
           le.organization_name AS LegalEntityName,
           le.registry_organization_id AS RegistryOrganizationId,
           ro.organization_code AS RegistryOrganizationCode,
           ro.registered_name AS RegistryOrganizationName,
           t.entered_by AS EnteredBy,
           t.entered_dt AS EnteredDate,
           COALESCE(t.updated_by, t.entered_by) AS UpdatedBy,
           COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate,
           t.team_code AS TeamCode,
           t.team_name AS TeamName,
           t.team_classification AS TeamType,
           t.organization_id AS LegalEntityId,
           j1.organization_code AS LegalEntityCode,
           j1.organization_name AS LegalEntityName,
           t.parent_department_id AS ParentDepartmentId,
           j2.department_code AS ParentDepartmentCode,
           j2.department_name AS ParentDepartmentName,
           t.primary_function_id AS PrimaryFunctionId,
           j3.function_code AS PrimaryFunctionCode,
           j3.function_name AS PrimaryFunctionName,
           t.division_id AS OrganizationUnitId,
           j4.division_code AS OrganizationUnitCode,
           j4.division_name AS OrganizationUnitName,
           t.team_manager_id AS TeamManagerPersonId,
           j5.employee_code AS TeamManagerPersonCode,
           j5.employee_name AS TeamManagerPersonName,
           t.team_type AS TeamSourcing,
           t.vendor_id AS VendorId,
           CAST(NULL AS NVARCHAR(80)) AS VendorCode,
           j6.vendor_name AS VendorName,
           (SELECT b.employee_id AS id, x.employee_code AS code, x.employee_name AS name
         FROM grac_practice.organization_team_member b JOIN grac_practice.organization_employee x ON x.employee_id = b.employee_id
        WHERE b.team_id = t.team_id ORDER BY x.employee_code, x.employee_name FOR JSON PATH) AS TeamMembers,
           t.team_purpose AS TeamPurpose,
           t.status AS RecordStatus,
           t.effective_from AS EffectiveFrom,
           t.effective_to AS EffectiveTo,
           t.remarks AS Remarks
      FROM grac_practice.organization_team t
      LEFT JOIN grac_practice.organization le ON le.organization_id = t.organization_id
      LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = le.registry_organization_id
      LEFT JOIN grac_practice.organization j1 ON j1.organization_id = t.organization_id
      LEFT JOIN grac_practice.organization_department j2 ON j2.department_id = t.parent_department_id
      LEFT JOIN grac_practice.organization_business_function j3 ON j3.business_function_id = t.primary_function_id
      LEFT JOIN grac_practice.organization_division j4 ON j4.division_id = t.division_id
      LEFT JOIN grac_practice.organization_employee j5 ON j5.employee_id = t.team_manager_id
      LEFT JOIN grac_practice.organization_dependency_vendor j6 ON j6.vendor_id = t.vendor_id
     WHERE (@id = 0 OR t.team_id = @id)
       AND (@registry_organization_id = 0 OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL) OR le.registry_organization_id = @registry_organization_id)
       AND (@legal_entity_id = 0 OR le.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR le.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
       AND (@status = N'' OR t.status = @status)
       AND (@search = N'' OR t.team_code LIKE N'%' + @search + N'%' OR t.team_name LIKE N'%' + @search + N'%')
     ORDER BY le.organization_name, t.team_code;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_teams_save
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_team WHERE team_id = @id)
        THROW 52705, N'[] The Team no longer exists. Reload the list.', 1;

    -- Outside GRAC administration a record of another Legal Entity is out of reach.
    IF @allowed_legal_entity_ids IS NOT NULL AND @id > 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_team x WHERE x.team_id = @id AND x.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[] This record belongs to a Legal Entity you do not have access to.', 1;

    -- Raw values (text; OPENJSON so long text is never truncated).
    DECLARE @f_teamCode NVARCHAR(MAX);
    DECLARE @f_teamName NVARCHAR(MAX);
    DECLARE @f_teamType NVARCHAR(MAX);
    DECLARE @f_legalEntityId NVARCHAR(MAX);
    DECLARE @f_parentDepartmentId NVARCHAR(MAX);
    DECLARE @f_primaryFunctionId NVARCHAR(MAX);
    DECLARE @f_organizationUnitId NVARCHAR(MAX);
    DECLARE @f_teamManagerPersonId NVARCHAR(MAX);
    DECLARE @f_teamSourcing NVARCHAR(MAX);
    DECLARE @f_vendorId NVARCHAR(MAX);
    DECLARE @f_teamPurpose NVARCHAR(MAX);
    DECLARE @f_recordStatus NVARCHAR(MAX);
    DECLARE @f_effectiveFrom NVARCHAR(MAX);
    DECLARE @f_effectiveTo NVARCHAR(MAX);
    DECLARE @f_remarks NVARCHAR(MAX);
    SELECT @f_teamCode = NULLIF(LTRIM(RTRIM(j.[teamCode])), N''),
           @f_teamName = NULLIF(LTRIM(RTRIM(j.[teamName])), N''),
           @f_teamType = NULLIF(LTRIM(RTRIM(j.[teamType])), N''),
           @f_legalEntityId = NULLIF(LTRIM(RTRIM(j.[legalEntityId])), N''),
           @f_parentDepartmentId = NULLIF(LTRIM(RTRIM(j.[parentDepartmentId])), N''),
           @f_primaryFunctionId = NULLIF(LTRIM(RTRIM(j.[primaryFunctionId])), N''),
           @f_organizationUnitId = NULLIF(LTRIM(RTRIM(j.[organizationUnitId])), N''),
           @f_teamManagerPersonId = NULLIF(LTRIM(RTRIM(j.[teamManagerPersonId])), N''),
           @f_teamSourcing = NULLIF(LTRIM(RTRIM(j.[teamSourcing])), N''),
           @f_vendorId = NULLIF(LTRIM(RTRIM(j.[vendorId])), N''),
           @f_teamPurpose = NULLIF(LTRIM(RTRIM(j.[teamPurpose])), N''),
           @f_recordStatus = NULLIF(LTRIM(RTRIM(j.[recordStatus])), N''),
           @f_effectiveFrom = NULLIF(LTRIM(RTRIM(j.[effectiveFrom])), N''),
           @f_effectiveTo = NULLIF(LTRIM(RTRIM(j.[effectiveTo])), N''),
           @f_remarks = NULLIF(LTRIM(RTRIM(j.[remarks])), N'')
      FROM OPENJSON(@payload) WITH ([teamCode] NVARCHAR(MAX) N'$.teamCode',
           [teamName] NVARCHAR(MAX) N'$.teamName',
           [teamType] NVARCHAR(MAX) N'$.teamType',
           [legalEntityId] NVARCHAR(MAX) N'$.legalEntityId',
           [parentDepartmentId] NVARCHAR(MAX) N'$.parentDepartmentId',
           [primaryFunctionId] NVARCHAR(MAX) N'$.primaryFunctionId',
           [organizationUnitId] NVARCHAR(MAX) N'$.organizationUnitId',
           [teamManagerPersonId] NVARCHAR(MAX) N'$.teamManagerPersonId',
           [teamSourcing] NVARCHAR(MAX) N'$.teamSourcing',
           [vendorId] NVARCHAR(MAX) N'$.vendorId',
           [teamPurpose] NVARCHAR(MAX) N'$.teamPurpose',
           [recordStatus] NVARCHAR(MAX) N'$.recordStatus',
           [effectiveFrom] NVARCHAR(MAX) N'$.effectiveFrom',
           [effectiveTo] NVARCHAR(MAX) N'$.effectiveTo',
           [remarks] NVARCHAR(MAX) N'$.remarks') j;

    DECLARE @r_legalEntityId BIGINT = TRY_CONVERT(BIGINT, @f_legalEntityId);
    IF @f_legalEntityId IS NOT NULL AND @r_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Legal Entity is not a valid selection.', 1;
    DECLARE @r_parentDepartmentId BIGINT = TRY_CONVERT(BIGINT, @f_parentDepartmentId);
    IF @f_parentDepartmentId IS NOT NULL AND @r_parentDepartmentId IS NULL THROW 52701, N'[parentDepartmentId] Parent Department Code is not a valid selection.', 1;
    DECLARE @r_primaryFunctionId BIGINT = TRY_CONVERT(BIGINT, @f_primaryFunctionId);
    IF @f_primaryFunctionId IS NOT NULL AND @r_primaryFunctionId IS NULL THROW 52701, N'[primaryFunctionId] Primary Function Code is not a valid selection.', 1;
    DECLARE @r_organizationUnitId BIGINT = TRY_CONVERT(BIGINT, @f_organizationUnitId);
    IF @f_organizationUnitId IS NOT NULL AND @r_organizationUnitId IS NULL THROW 52701, N'[organizationUnitId] Organization Unit Code is not a valid selection.', 1;
    DECLARE @r_teamManagerPersonId BIGINT = TRY_CONVERT(BIGINT, @f_teamManagerPersonId);
    IF @f_teamManagerPersonId IS NOT NULL AND @r_teamManagerPersonId IS NULL THROW 52701, N'[teamManagerPersonId] Team Manager Person Code is not a valid selection.', 1;
    DECLARE @r_vendorId BIGINT = TRY_CONVERT(BIGINT, @f_vendorId);
    IF @f_vendorId IS NOT NULL AND @r_vendorId IS NULL THROW 52701, N'[vendorId] Vendor is not a valid selection.', 1;
    DECLARE @d_effectiveFrom DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveFrom, 10), 23);
    IF @f_effectiveFrom IS NOT NULL AND @d_effectiveFrom IS NULL THROW 52701, N'[effectiveFrom] Effective From must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_effectiveTo DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveTo, 10), 23);
    IF @f_effectiveTo IS NOT NULL AND @d_effectiveTo IS NULL THROW 52701, N'[effectiveTo] Effective To must be a date (yyyy-mm-dd).', 1;

    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).
    IF @f_teamCode IS NULL THROW 52701, N'[teamCode] Team Code is required.', 1;
    IF @f_teamName IS NULL THROW 52701, N'[teamName] Team Name is required.', 1;
    IF @f_teamType IS NULL THROW 52701, N'[teamType] Team Type is required.', 1;
    IF @f_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Legal Entity is required.', 1;
    IF @f_teamSourcing IS NULL THROW 52701, N'[teamSourcing] Team Sourcing is required.', 1;
    IF @f_recordStatus IS NULL THROW 52701, N'[recordStatus] Record Status is required.', 1;
    IF LEN(@f_teamCode) > 80 THROW 52701, N'[teamCode] Team Code cannot be longer than 80 characters.', 1;
    IF LEN(@f_teamName) > 200 THROW 52701, N'[teamName] Team Name cannot be longer than 200 characters.', 1;
    IF @d_effectiveFrom IS NOT NULL AND @d_effectiveTo IS NOT NULL AND @d_effectiveTo < @d_effectiveFrom THROW 52701, N'[effectiveTo] Effective To cannot be before Effective From.', 1;

    -- Controlled values (15 Masters & Codes). A value that is not on the list
    -- is accepted only when it is the value the record already holds, so an
    -- older record can still be saved without being forced to change it.
    IF @f_teamType IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'TeamType' AND m.value_label = @f_teamType AND m.status = N'Active')
            SELECT @f_teamType = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'TeamType' AND m.value_label = @f_teamType;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_team WHERE team_id = @id AND team_classification = @f_teamType)
            THROW 52702, N'[teamType] Team Type: the value is not in the approved list (TeamType).', 1;
    END
    IF @f_teamSourcing IS NOT NULL AND @f_teamSourcing NOT IN (N'InHouse', N'Vendor')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_team WHERE team_id = @id AND team_type = @f_teamSourcing)
        THROW 52702, N'[teamSourcing] Team Sourcing must be one of: In-house / Vendor-managed.', 1;
    IF @f_recordStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus AND m.status = N'Active')
            SELECT @f_recordStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_team WHERE team_id = @id AND status = @f_recordStatus)
            THROW 52702, N'[recordStatus] Record Status: the value is not in the approved list (RecordStatus).', 1;
    END

    DECLARE @le BIGINT = @r_legalEntityId;
    IF @le IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @le) THROW 52703, N'[legalEntityId] The selected Legal Entity does not exist.', 1;
    IF @id > 0 AND EXISTS (SELECT 1 FROM grac_practice.organization_team WHERE team_id = @id AND organization_id <> @le)
       AND EXISTS (SELECT 1 FROM grac_practice.organization_team WHERE team_id = @id AND organization_id IS NOT NULL)
        THROW 52703, N'[legalEntityId] A Team cannot be moved to another Legal Entity: other records refer to it there. Mark it Inactive and create it in the other Legal Entity.', 1;
    IF @allowed_legal_entity_ids IS NOT NULL AND (@le IS NULL OR @le NOT IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[legalEntityId] You can only maintain records of your own Legal Entities.', 1;

    IF @f_teamSourcing = N'InHouse' SET @r_vendorId = NULL;   -- an in-house team has no vendor (133)
    -- References: the record must exist (and belong where the field says).
    IF @r_parentDepartmentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE department_id = @r_parentDepartmentId) THROW 52703, N'[parentDepartmentId] Parent Department Code: the selected record does not exist.', 1;
    IF @r_parentDepartmentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department x WHERE x.department_id = @r_parentDepartmentId AND x.organization_id = @le)
        THROW 52703, N'[parentDepartmentId] Parent Department Code must belong to the same Legal Entity.', 1;
    IF @r_primaryFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @r_primaryFunctionId) THROW 52703, N'[primaryFunctionId] Primary Function Code: the selected record does not exist.', 1;
    IF @r_primaryFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function x WHERE x.business_function_id = @r_primaryFunctionId AND x.organization_id = @le)
        THROW 52703, N'[primaryFunctionId] Primary Function Code must belong to the same Legal Entity.', 1;
    IF @r_organizationUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @r_organizationUnitId) THROW 52703, N'[organizationUnitId] Organization Unit Code: the selected record does not exist.', 1;
    IF @r_organizationUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division x WHERE x.division_id = @r_organizationUnitId AND x.organization_id = @le)
        THROW 52703, N'[organizationUnitId] Organization Unit Code must belong to the same Legal Entity.', 1;
    IF @r_teamManagerPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_teamManagerPersonId) THROW 52703, N'[teamManagerPersonId] Team Manager Person Code: the selected record does not exist.', 1;
    IF @r_teamManagerPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_teamManagerPersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[teamManagerPersonId] Team Manager Person Code must belong to the same Organization.', 1;
    IF @r_vendorId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_vendor WHERE vendor_id = @r_vendorId) THROW 52703, N'[vendorId] Vendor: the selected record does not exist.', 1;
    IF @r_vendorId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_vendor x WHERE x.vendor_id = @r_vendorId AND x.organization_id = @le)
        THROW 52703, N'[vendorId] Vendor must belong to the same Legal Entity.', 1;
    IF @f_teamSourcing = N'Vendor' AND @r_vendorId IS NULL THROW 52701, N'[vendorId] Vendor is required for a vendor-managed team. Register the vendor first, then select it here.', 1;
    IF @f_teamSourcing = N'Vendor'
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_vendor v WHERE v.vendor_id = @r_vendorId AND v.status = N'Active')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_team WHERE team_id = @id AND vendor_id = @r_vendorId)
        THROW 52703, N'[vendorId] Vendor: the selected vendor is not Active.', 1;
    DECLARE @m_teamMembers TABLE (v BIGINT NOT NULL PRIMARY KEY);
    IF ISJSON(JSON_QUERY(@payload, N'$.teamMembers')) = 1
        INSERT @m_teamMembers(v) SELECT DISTINCT TRY_CONVERT(BIGINT, j.[value]) FROM OPENJSON(@payload, N'$.teamMembers') j
         WHERE TRY_CONVERT(BIGINT, j.[value]) IS NOT NULL;
    IF EXISTS (SELECT 1 FROM @m_teamMembers m WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x WHERE x.employee_id = m.v AND x.organization_id = @le))
        THROW 52703, N'[teamMembers] Team Members: every selection must exist in the same Legal Entity.', 1;

    -- Unique codes.
    IF EXISTS (SELECT 1 FROM grac_practice.organization_team WHERE organization_id = @le AND team_code = @f_teamCode AND team_id <> @id) THROW 52704, N'[teamCode] Team Code is already used in this Legal Entity.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.organization_team WHERE organization_id = @le AND team_name = @f_teamName AND team_id <> @id) THROW 52704, N'[teamName] Team Name is already used in this Legal Entity.', 1;

    DECLARE @rsid INT = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master
                          WHERE status_code = CASE WHEN @f_recordStatus = N'Active' THEN N'Active'
                                                   WHEN @f_recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft'
                                                   ELSE N'Inactive' END);
    IF @rsid IS NULL SET @rsid = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).
    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT team_code, team_name, team_classification, organization_id, parent_department_id, primary_function_id, division_id, team_manager_id, team_type, vendor_id, team_purpose, status, effective_from, effective_to, remarks, record_status_id FROM grac_practice.organization_team WHERE team_id = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;
    BEGIN TRAN;
    IF @id = 0
    BEGIN
        INSERT grac_practice.organization_team (team_code, team_name, team_classification, organization_id, parent_department_id, primary_function_id, division_id, team_manager_id, team_type, vendor_id, team_purpose, status, effective_from, effective_to, remarks, record_status_id, entered_by)
        VALUES (@f_teamCode, @f_teamName, @f_teamType, @r_legalEntityId, @r_parentDepartmentId, @r_primaryFunctionId, @r_organizationUnitId, @r_teamManagerPersonId, @f_teamSourcing, @r_vendorId, @f_teamPurpose, @f_recordStatus, @d_effectiveFrom, @d_effectiveTo, @f_remarks, @rsid, @actor);
        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_team SET team_code = @f_teamCode,
               team_name = @f_teamName,
               team_classification = @f_teamType,
               organization_id = @r_legalEntityId,
               parent_department_id = @r_parentDepartmentId,
               primary_function_id = @r_primaryFunctionId,
               division_id = @r_organizationUnitId,
               team_manager_id = @r_teamManagerPersonId,
               team_type = @f_teamSourcing,
               vendor_id = @r_vendorId,
               team_purpose = @f_teamPurpose,
               status = @f_recordStatus,
               effective_from = @d_effectiveFrom,
               effective_to = @d_effectiveTo,
               remarks = @f_remarks,
               record_status_id = @rsid,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE team_id = @id;
    END
    IF JSON_QUERY(@payload, N'$.teamMembers') IS NOT NULL
    BEGIN
        DELETE b FROM grac_practice.organization_team_member b WHERE b.team_id = @id AND NOT EXISTS (SELECT 1 FROM @m_teamMembers m WHERE m.v = b.employee_id);
        INSERT grac_practice.organization_team_member (team_id, employee_id, organization_id, status, record_status_id, entered_by)
        SELECT @id, m.v, @le, N'Active', (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active'), @actor FROM @m_teamMembers m
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_team_member b WHERE b.team_id = @id AND b.employee_id = m.v);
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/teams', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Team saved.' AS Message, @id AS Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_people_list
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
    SELECT t.employee_id AS Id,
           t.employee_code AS Code,
           t.employee_name AS Name,
           t.status AS Status,
           le.organization_id AS LegalEntityId,
           le.organization_code AS LegalEntityCode,
           le.organization_name AS LegalEntityName,
           le.registry_organization_id AS RegistryOrganizationId,
           ro.organization_code AS RegistryOrganizationCode,
           ro.registered_name AS RegistryOrganizationName,
           t.entered_by AS EnteredBy,
           t.entered_dt AS EnteredDate,
           COALESCE(t.updated_by, t.entered_by) AS UpdatedBy,
           COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate,
           t.employee_code AS PersonCode,
           t.employee_name AS FullName,
           t.person_category AS PersonCategory,
           t.employment_type AS EmploymentType,
           t.reference_no AS ReferenceNo,
           t.email AS OfficialEmail,
           t.official_phone AS OfficialPhone,
           t.designation AS Designation,
           t.functional_role AS RoleName,
           t.organization_id AS LegalEntityId,
           j1.organization_code AS LegalEntityCode,
           j1.organization_name AS LegalEntityName,
           t.department_id AS DepartmentId,
           j2.department_code AS DepartmentCode,
           j2.department_name AS DepartmentName,
           t.business_function_id AS PrimaryFunctionId,
           j3.function_code AS PrimaryFunctionCode,
           j3.function_name AS PrimaryFunctionName,
           t.primary_team_id AS PrimaryTeamId,
           j4.team_code AS PrimaryTeamCode,
           j4.team_name AS PrimaryTeamName,
           t.division_id AS OrganizationUnitId,
           j5.division_code AS OrganizationUnitCode,
           j5.division_name AS OrganizationUnitName,
           t.location_id AS PrimaryLocationId,
           j6.location_code AS PrimaryLocationCode,
           j6.location_name AS PrimaryLocationName,
           t.reporting_officer_id AS ReportsToPersonId,
           j7.employee_code AS ReportsToPersonCode,
           j7.employee_name AS ReportsToPersonName,
           t.functional_reporting_to_id AS FunctionalReportsToPersonId,
           j8.employee_code AS FunctionalReportsToPersonCode,
           j8.employee_name AS FunctionalReportsToPersonName,
           t.appointment_dt AS JoiningDate,
           t.exit_dt AS ExitDate,
           t.person_status AS PersonStatus,
           t.is_kmp AS IsKmp,
           t.status AS RecordStatus,
           t.remarks AS Remarks
      FROM grac_practice.organization_employee t
      LEFT JOIN grac_practice.organization le ON le.organization_id = t.organization_id
      LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = le.registry_organization_id
      LEFT JOIN grac_practice.organization j1 ON j1.organization_id = t.organization_id
      LEFT JOIN grac_practice.organization_department j2 ON j2.department_id = t.department_id
      LEFT JOIN grac_practice.organization_business_function j3 ON j3.business_function_id = t.business_function_id
      LEFT JOIN grac_practice.organization_team j4 ON j4.team_id = t.primary_team_id
      LEFT JOIN grac_practice.organization_division j5 ON j5.division_id = t.division_id
      LEFT JOIN grac_practice.organization_location j6 ON j6.location_id = t.location_id
      LEFT JOIN grac_practice.organization_employee j7 ON j7.employee_id = t.reporting_officer_id
      LEFT JOIN grac_practice.organization_employee j8 ON j8.employee_id = t.functional_reporting_to_id
     WHERE (@id = 0 OR t.employee_id = @id)
       AND (@registry_organization_id = 0 OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL) OR le.registry_organization_id = @registry_organization_id)
       AND (@legal_entity_id = 0 OR le.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR le.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
       AND (@status = N'' OR t.status = @status)
       AND (@search = N'' OR t.employee_code LIKE N'%' + @search + N'%' OR t.employee_name LIKE N'%' + @search + N'%' OR t.email LIKE N'%' + @search + N'%' OR t.designation LIKE N'%' + @search + N'%')
     ORDER BY le.organization_name, t.employee_code;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_people_save
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @id)
        THROW 52705, N'[] The Person no longer exists. Reload the list.', 1;

    -- Outside GRAC administration a record of another Legal Entity is out of reach.
    IF @allowed_legal_entity_ids IS NOT NULL AND @id > 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x WHERE x.employee_id = @id AND x.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[] This record belongs to a Legal Entity you do not have access to.', 1;

    -- Raw values (text; OPENJSON so long text is never truncated).
    DECLARE @f_personCode NVARCHAR(MAX);
    DECLARE @f_fullName NVARCHAR(MAX);
    DECLARE @f_personCategory NVARCHAR(MAX);
    DECLARE @f_employmentType NVARCHAR(MAX);
    DECLARE @f_referenceNo NVARCHAR(MAX);
    DECLARE @f_officialEmail NVARCHAR(MAX);
    DECLARE @f_officialPhone NVARCHAR(MAX);
    DECLARE @f_designation NVARCHAR(MAX);
    DECLARE @f_roleName NVARCHAR(MAX);
    DECLARE @f_legalEntityId NVARCHAR(MAX);
    DECLARE @f_departmentId NVARCHAR(MAX);
    DECLARE @f_primaryFunctionId NVARCHAR(MAX);
    DECLARE @f_primaryTeamId NVARCHAR(MAX);
    DECLARE @f_organizationUnitId NVARCHAR(MAX);
    DECLARE @f_primaryLocationId NVARCHAR(MAX);
    DECLARE @f_reportsToPersonId NVARCHAR(MAX);
    DECLARE @f_functionalReportsToPersonId NVARCHAR(MAX);
    DECLARE @f_joiningDate NVARCHAR(MAX);
    DECLARE @f_exitDate NVARCHAR(MAX);
    DECLARE @f_personStatus NVARCHAR(MAX);
    DECLARE @f_isKmp NVARCHAR(MAX);
    DECLARE @f_recordStatus NVARCHAR(MAX);
    DECLARE @f_remarks NVARCHAR(MAX);
    SELECT @f_personCode = NULLIF(LTRIM(RTRIM(j.[personCode])), N''),
           @f_fullName = NULLIF(LTRIM(RTRIM(j.[fullName])), N''),
           @f_personCategory = NULLIF(LTRIM(RTRIM(j.[personCategory])), N''),
           @f_employmentType = NULLIF(LTRIM(RTRIM(j.[employmentType])), N''),
           @f_referenceNo = NULLIF(LTRIM(RTRIM(j.[referenceNo])), N''),
           @f_officialEmail = NULLIF(LTRIM(RTRIM(j.[officialEmail])), N''),
           @f_officialPhone = NULLIF(LTRIM(RTRIM(j.[officialPhone])), N''),
           @f_designation = NULLIF(LTRIM(RTRIM(j.[designation])), N''),
           @f_roleName = NULLIF(LTRIM(RTRIM(j.[roleName])), N''),
           @f_legalEntityId = NULLIF(LTRIM(RTRIM(j.[legalEntityId])), N''),
           @f_departmentId = NULLIF(LTRIM(RTRIM(j.[departmentId])), N''),
           @f_primaryFunctionId = NULLIF(LTRIM(RTRIM(j.[primaryFunctionId])), N''),
           @f_primaryTeamId = NULLIF(LTRIM(RTRIM(j.[primaryTeamId])), N''),
           @f_organizationUnitId = NULLIF(LTRIM(RTRIM(j.[organizationUnitId])), N''),
           @f_primaryLocationId = NULLIF(LTRIM(RTRIM(j.[primaryLocationId])), N''),
           @f_reportsToPersonId = NULLIF(LTRIM(RTRIM(j.[reportsToPersonId])), N''),
           @f_functionalReportsToPersonId = NULLIF(LTRIM(RTRIM(j.[functionalReportsToPersonId])), N''),
           @f_joiningDate = NULLIF(LTRIM(RTRIM(j.[joiningDate])), N''),
           @f_exitDate = NULLIF(LTRIM(RTRIM(j.[exitDate])), N''),
           @f_personStatus = NULLIF(LTRIM(RTRIM(j.[personStatus])), N''),
           @f_isKmp = NULLIF(LTRIM(RTRIM(j.[isKmp])), N''),
           @f_recordStatus = NULLIF(LTRIM(RTRIM(j.[recordStatus])), N''),
           @f_remarks = NULLIF(LTRIM(RTRIM(j.[remarks])), N'')
      FROM OPENJSON(@payload) WITH ([personCode] NVARCHAR(MAX) N'$.personCode',
           [fullName] NVARCHAR(MAX) N'$.fullName',
           [personCategory] NVARCHAR(MAX) N'$.personCategory',
           [employmentType] NVARCHAR(MAX) N'$.employmentType',
           [referenceNo] NVARCHAR(MAX) N'$.referenceNo',
           [officialEmail] NVARCHAR(MAX) N'$.officialEmail',
           [officialPhone] NVARCHAR(MAX) N'$.officialPhone',
           [designation] NVARCHAR(MAX) N'$.designation',
           [roleName] NVARCHAR(MAX) N'$.roleName',
           [legalEntityId] NVARCHAR(MAX) N'$.legalEntityId',
           [departmentId] NVARCHAR(MAX) N'$.departmentId',
           [primaryFunctionId] NVARCHAR(MAX) N'$.primaryFunctionId',
           [primaryTeamId] NVARCHAR(MAX) N'$.primaryTeamId',
           [organizationUnitId] NVARCHAR(MAX) N'$.organizationUnitId',
           [primaryLocationId] NVARCHAR(MAX) N'$.primaryLocationId',
           [reportsToPersonId] NVARCHAR(MAX) N'$.reportsToPersonId',
           [functionalReportsToPersonId] NVARCHAR(MAX) N'$.functionalReportsToPersonId',
           [joiningDate] NVARCHAR(MAX) N'$.joiningDate',
           [exitDate] NVARCHAR(MAX) N'$.exitDate',
           [personStatus] NVARCHAR(MAX) N'$.personStatus',
           [isKmp] NVARCHAR(MAX) N'$.isKmp',
           [recordStatus] NVARCHAR(MAX) N'$.recordStatus',
           [remarks] NVARCHAR(MAX) N'$.remarks') j;

    DECLARE @r_legalEntityId BIGINT = TRY_CONVERT(BIGINT, @f_legalEntityId);
    IF @f_legalEntityId IS NOT NULL AND @r_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Legal Entity is not a valid selection.', 1;
    DECLARE @r_departmentId BIGINT = TRY_CONVERT(BIGINT, @f_departmentId);
    IF @f_departmentId IS NOT NULL AND @r_departmentId IS NULL THROW 52701, N'[departmentId] Department Code is not a valid selection.', 1;
    DECLARE @r_primaryFunctionId BIGINT = TRY_CONVERT(BIGINT, @f_primaryFunctionId);
    IF @f_primaryFunctionId IS NOT NULL AND @r_primaryFunctionId IS NULL THROW 52701, N'[primaryFunctionId] Primary Function Code is not a valid selection.', 1;
    DECLARE @r_primaryTeamId BIGINT = TRY_CONVERT(BIGINT, @f_primaryTeamId);
    IF @f_primaryTeamId IS NOT NULL AND @r_primaryTeamId IS NULL THROW 52701, N'[primaryTeamId] Team Code (primary) is not a valid selection.', 1;
    DECLARE @r_organizationUnitId BIGINT = TRY_CONVERT(BIGINT, @f_organizationUnitId);
    IF @f_organizationUnitId IS NOT NULL AND @r_organizationUnitId IS NULL THROW 52701, N'[organizationUnitId] Organization Unit Code is not a valid selection.', 1;
    DECLARE @r_primaryLocationId BIGINT = TRY_CONVERT(BIGINT, @f_primaryLocationId);
    IF @f_primaryLocationId IS NOT NULL AND @r_primaryLocationId IS NULL THROW 52701, N'[primaryLocationId] Primary Location Code is not a valid selection.', 1;
    DECLARE @r_reportsToPersonId BIGINT = TRY_CONVERT(BIGINT, @f_reportsToPersonId);
    IF @f_reportsToPersonId IS NOT NULL AND @r_reportsToPersonId IS NULL THROW 52701, N'[reportsToPersonId] Reports To Person Code is not a valid selection.', 1;
    DECLARE @r_functionalReportsToPersonId BIGINT = TRY_CONVERT(BIGINT, @f_functionalReportsToPersonId);
    IF @f_functionalReportsToPersonId IS NOT NULL AND @r_functionalReportsToPersonId IS NULL THROW 52701, N'[functionalReportsToPersonId] Functional Reporting To Person Code is not a valid selection.', 1;
    DECLARE @d_joiningDate DATE = TRY_CONVERT(DATE, LEFT(@f_joiningDate, 10), 23);
    IF @f_joiningDate IS NOT NULL AND @d_joiningDate IS NULL THROW 52701, N'[joiningDate] Joining / Appointment Date must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_exitDate DATE = TRY_CONVERT(DATE, LEFT(@f_exitDate, 10), 23);
    IF @f_exitDate IS NOT NULL AND @d_exitDate IS NULL THROW 52701, N'[exitDate] Exit / End Date must be a date (yyyy-mm-dd).', 1;

    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).
    IF @f_personCode IS NULL THROW 52701, N'[personCode] Person Code is required.', 1;
    IF @f_fullName IS NULL THROW 52701, N'[fullName] Full Name is required.', 1;
    IF @f_personCategory IS NULL THROW 52701, N'[personCategory] Person Category is required.', 1;
    IF @f_designation IS NULL THROW 52701, N'[designation] Designation is required.', 1;
    IF @f_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Legal Entity is required.', 1;
    IF @f_personStatus IS NULL THROW 52701, N'[personStatus] Person Status is required.', 1;
    IF @f_recordStatus IS NULL THROW 52701, N'[recordStatus] Record Status is required.', 1;
    IF LEN(@f_personCode) > 80 THROW 52701, N'[personCode] Person Code cannot be longer than 80 characters.', 1;
    IF LEN(@f_fullName) > 200 THROW 52701, N'[fullName] Full Name cannot be longer than 200 characters.', 1;
    IF LEN(@f_referenceNo) > 80 THROW 52701, N'[referenceNo] Employee / Director Reference No. cannot be longer than 80 characters.', 1;
    IF LEN(@f_officialEmail) > 250 THROW 52701, N'[officialEmail] Official Email cannot be longer than 250 characters.', 1;
    IF @f_officialEmail IS NOT NULL AND (@f_officialEmail NOT LIKE N'%_@_%._%' OR CHARINDEX(N' ', @f_officialEmail) > 0) THROW 52701, N'[officialEmail] Official Email is not a valid e-mail address.', 1;
    IF LEN(@f_officialPhone) > 40 THROW 52701, N'[officialPhone] Official Phone (optional) cannot be longer than 40 characters.', 1;
    IF LEN(@f_designation) > 150 THROW 52701, N'[designation] Designation cannot be longer than 150 characters.', 1;
    IF LEN(@f_roleName) > 200 THROW 52701, N'[roleName] Role Name / Functional Role cannot be longer than 200 characters.', 1;
    IF @d_joiningDate IS NOT NULL AND @d_exitDate IS NOT NULL AND @d_exitDate < @d_joiningDate THROW 52701, N'[exitDate] Exit / End Date cannot be before Joining / Appointment Date.', 1;

    -- Controlled values (15 Masters & Codes). A value that is not on the list
    -- is accepted only when it is the value the record already holds, so an
    -- older record can still be saved without being forced to change it.
    IF @f_personCategory IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'PersonCategory' AND m.value_label = @f_personCategory AND m.status = N'Active')
            SELECT @f_personCategory = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'PersonCategory' AND m.value_label = @f_personCategory;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @id AND person_category = @f_personCategory)
            THROW 52702, N'[personCategory] Person Category: the value is not in the approved list (PersonCategory).', 1;
    END
    IF @f_employmentType IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'EmploymentType' AND m.value_label = @f_employmentType AND m.status = N'Active')
            SELECT @f_employmentType = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'EmploymentType' AND m.value_label = @f_employmentType;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @id AND employment_type = @f_employmentType)
            THROW 52702, N'[employmentType] Employment Type: the value is not in the approved list (EmploymentType).', 1;
    END
    IF @f_personStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'PersonStatus' AND m.value_label = @f_personStatus AND m.status = N'Active')
            SELECT @f_personStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'PersonStatus' AND m.value_label = @f_personStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @id AND person_status = @f_personStatus)
            THROW 52702, N'[personStatus] Person Status: the value is not in the approved list (PersonStatus).', 1;
    END
    IF @f_isKmp IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_isKmp AND m.status = N'Active')
            SELECT @f_isKmp = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_isKmp;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @id AND is_kmp = @f_isKmp)
            THROW 52702, N'[isKmp] Key Managerial Personnel?: the value is not in the approved list (YesNo).', 1;
    END
    IF @f_recordStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus AND m.status = N'Active')
            SELECT @f_recordStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @id AND status = @f_recordStatus)
            THROW 52702, N'[recordStatus] Record Status: the value is not in the approved list (RecordStatus).', 1;
    END

    DECLARE @le BIGINT = @r_legalEntityId;
    IF @le IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @le) THROW 52703, N'[legalEntityId] The selected Legal Entity does not exist.', 1;
    IF @id > 0 AND EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @id AND organization_id <> @le)
       AND EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @id AND organization_id IS NOT NULL)
        THROW 52703, N'[legalEntityId] A Person cannot be moved to another Legal Entity: other records refer to it there. Mark it Inactive and create it in the other Legal Entity.', 1;
    IF @allowed_legal_entity_ids IS NOT NULL AND (@le IS NULL OR @le NOT IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[legalEntityId] You can only maintain records of your own Legal Entities.', 1;

    -- References: the record must exist (and belong where the field says).
    IF @r_departmentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE department_id = @r_departmentId) THROW 52703, N'[departmentId] Department Code: the selected record does not exist.', 1;
    IF @r_departmentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department x WHERE x.department_id = @r_departmentId AND x.organization_id = @le)
        THROW 52703, N'[departmentId] Department Code must belong to the same Legal Entity.', 1;
    IF @r_primaryFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @r_primaryFunctionId) THROW 52703, N'[primaryFunctionId] Primary Function Code: the selected record does not exist.', 1;
    IF @r_primaryFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function x WHERE x.business_function_id = @r_primaryFunctionId AND x.organization_id = @le)
        THROW 52703, N'[primaryFunctionId] Primary Function Code must belong to the same Legal Entity.', 1;
    IF @r_primaryTeamId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_team WHERE team_id = @r_primaryTeamId) THROW 52703, N'[primaryTeamId] Team Code (primary): the selected record does not exist.', 1;
    IF @r_primaryTeamId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_team x WHERE x.team_id = @r_primaryTeamId AND x.organization_id = @le)
        THROW 52703, N'[primaryTeamId] Team Code (primary) must belong to the same Legal Entity.', 1;
    IF @r_organizationUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @r_organizationUnitId) THROW 52703, N'[organizationUnitId] Organization Unit Code: the selected record does not exist.', 1;
    IF @r_organizationUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division x WHERE x.division_id = @r_organizationUnitId AND x.organization_id = @le)
        THROW 52703, N'[organizationUnitId] Organization Unit Code must belong to the same Legal Entity.', 1;
    IF @r_primaryLocationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_location WHERE location_id = @r_primaryLocationId) THROW 52703, N'[primaryLocationId] Primary Location Code: the selected record does not exist.', 1;
    IF @r_primaryLocationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_location x WHERE x.location_id = @r_primaryLocationId AND x.organization_id = @le)
        THROW 52703, N'[primaryLocationId] Primary Location Code must belong to the same Legal Entity.', 1;
    IF @r_reportsToPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_reportsToPersonId) THROW 52703, N'[reportsToPersonId] Reports To Person Code: the selected record does not exist.', 1;
    IF @r_reportsToPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_reportsToPersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[reportsToPersonId] Reports To Person Code must belong to the same Organization.', 1;
    IF @r_reportsToPersonId IS NOT NULL AND @id > 0
    BEGIN
        IF @r_reportsToPersonId = @id THROW 52706, N'[reportsToPersonId] Reports To Person Code cannot be the record itself.', 1;
        DECLARE @walk_reportsToPersonId BIGINT = @r_reportsToPersonId, @guard_reportsToPersonId INT = 0;
        WHILE @walk_reportsToPersonId IS NOT NULL AND @guard_reportsToPersonId < 100
        BEGIN
            IF @walk_reportsToPersonId = @id THROW 52706, N'[reportsToPersonId] Reports To Person Code would make a loop: this record is already above it.', 1;
            SET @walk_reportsToPersonId = (SELECT reporting_officer_id FROM grac_practice.organization_employee WHERE employee_id = @walk_reportsToPersonId);
            SET @guard_reportsToPersonId += 1;
        END
    END
    IF @r_functionalReportsToPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_functionalReportsToPersonId) THROW 52703, N'[functionalReportsToPersonId] Functional Reporting To Person Code: the selected record does not exist.', 1;
    IF @r_functionalReportsToPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_functionalReportsToPersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[functionalReportsToPersonId] Functional Reporting To Person Code must belong to the same Organization.', 1;
    IF @r_functionalReportsToPersonId IS NOT NULL AND @id > 0
    BEGIN
        IF @r_functionalReportsToPersonId = @id THROW 52706, N'[functionalReportsToPersonId] Functional Reporting To Person Code cannot be the record itself.', 1;
        DECLARE @walk_functionalReportsToPersonId BIGINT = @r_functionalReportsToPersonId, @guard_functionalReportsToPersonId INT = 0;
        WHILE @walk_functionalReportsToPersonId IS NOT NULL AND @guard_functionalReportsToPersonId < 100
        BEGIN
            IF @walk_functionalReportsToPersonId = @id THROW 52706, N'[functionalReportsToPersonId] Functional Reporting To Person Code would make a loop: this record is already above it.', 1;
            SET @walk_functionalReportsToPersonId = (SELECT functional_reporting_to_id FROM grac_practice.organization_employee WHERE employee_id = @walk_functionalReportsToPersonId);
            SET @guard_functionalReportsToPersonId += 1;
        END
    END

    -- Unique codes.
    IF EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE organization_id = @le AND employee_code = @f_personCode AND employee_id <> @id) THROW 52704, N'[personCode] Person Code is already used in this Legal Entity.', 1;
    IF @f_officialEmail IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE email = @f_officialEmail AND employee_id <> @id) THROW 52704, N'[officialEmail] Official Email is already used by another person in GRAC.', 1;

    DECLARE @rsid INT = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master
                          WHERE status_code = CASE WHEN @f_recordStatus = N'Active' THEN N'Active'
                                                   WHEN @f_recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft'
                                                   ELSE N'Inactive' END);
    IF @rsid IS NULL SET @rsid = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).
    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT employee_code, employee_name, person_category, employment_type, reference_no, email, official_phone, designation, functional_role, organization_id, department_id, business_function_id, primary_team_id, division_id, location_id, reporting_officer_id, functional_reporting_to_id, appointment_dt, exit_dt, person_status, is_kmp, status, remarks, record_status_id FROM grac_practice.organization_employee WHERE employee_id = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;
    BEGIN TRAN;
    IF @id = 0
    BEGIN
        INSERT grac_practice.organization_employee (employee_code, employee_name, person_category, employment_type, reference_no, email, official_phone, designation, functional_role, organization_id, department_id, business_function_id, primary_team_id, division_id, location_id, reporting_officer_id, functional_reporting_to_id, appointment_dt, exit_dt, person_status, is_kmp, status, remarks, record_status_id, party_type, entered_by)
        VALUES (@f_personCode, @f_fullName, @f_personCategory, @f_employmentType, @f_referenceNo, @f_officialEmail, @f_officialPhone, @f_designation, @f_roleName, @r_legalEntityId, @r_departmentId, @r_primaryFunctionId, @r_primaryTeamId, @r_organizationUnitId, @r_primaryLocationId, @r_reportsToPersonId, @r_functionalReportsToPersonId, @d_joiningDate, @d_exitDate, @f_personStatus, @f_isKmp, @f_recordStatus, @f_remarks, @rsid, N'Employee', @actor);
        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_employee SET employee_code = @f_personCode,
               employee_name = @f_fullName,
               person_category = @f_personCategory,
               employment_type = @f_employmentType,
               reference_no = @f_referenceNo,
               email = @f_officialEmail,
               official_phone = @f_officialPhone,
               designation = @f_designation,
               functional_role = @f_roleName,
               organization_id = @r_legalEntityId,
               department_id = @r_departmentId,
               business_function_id = @r_primaryFunctionId,
               primary_team_id = @r_primaryTeamId,
               division_id = @r_organizationUnitId,
               location_id = @r_primaryLocationId,
               reporting_officer_id = @r_reportsToPersonId,
               functional_reporting_to_id = @r_functionalReportsToPersonId,
               appointment_dt = @d_joiningDate,
               exit_dt = @d_exitDate,
               person_status = @f_personStatus,
               is_kmp = @f_isKmp,
               status = @f_recordStatus,
               remarks = @f_remarks,
               record_status_id = @rsid,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/people', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Person saved.' AS Message, @id AS Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_committees_list
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
    SELECT t.committee_id AS Id,
           t.committee_code AS Code,
           t.committee_name AS Name,
           t.status AS Status,
           le.organization_id AS LegalEntityId,
           le.organization_code AS LegalEntityCode,
           le.organization_name AS LegalEntityName,
           le.registry_organization_id AS RegistryOrganizationId,
           ro.organization_code AS RegistryOrganizationCode,
           ro.registered_name AS RegistryOrganizationName,
           t.entered_by AS EnteredBy,
           t.entered_dt AS EnteredDate,
           COALESCE(t.updated_by, t.entered_by) AS UpdatedBy,
           COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate,
           t.committee_code AS CommitteeCode,
           t.committee_name AS CommitteeName,
           t.committee_type AS CommitteeType,
           t.organization_id AS LegalEntityId,
           j1.organization_code AS LegalEntityCode,
           j1.organization_name AS LegalEntityName,
           t.mandate AS CommitteeMandate,
           t.scope_responsibilities AS ScopeResponsibilities,
           t.chairperson_id AS ChairpersonPersonId,
           j2.employee_code AS ChairpersonPersonCode,
           j2.employee_name AS ChairpersonPersonName,
           t.secretary_id AS SecretaryPersonId,
           j3.employee_code AS SecretaryPersonCode,
           j3.employee_name AS SecretaryPersonName,
           t.review_frequency AS ReviewFrequency,
           t.tor_reference AS TorReference,
           t.constituted_dt AS ConstitutedDate,
           t.last_reviewed_dt AS LastReviewedDate,
           t.next_review_due_dt AS NextReviewDueDate,
           t.status AS RecordStatus,
           t.effective_from AS EffectiveFrom,
           t.effective_to AS EffectiveTo,
           t.remarks AS Remarks
      FROM grac_practice.organization_committee t
      LEFT JOIN grac_practice.organization le ON le.organization_id = t.organization_id
      LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = le.registry_organization_id
      LEFT JOIN grac_practice.organization j1 ON j1.organization_id = t.organization_id
      LEFT JOIN grac_practice.organization_employee j2 ON j2.employee_id = t.chairperson_id
      LEFT JOIN grac_practice.organization_employee j3 ON j3.employee_id = t.secretary_id
     WHERE (@id = 0 OR t.committee_id = @id)
       AND (@registry_organization_id = 0 OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL) OR le.registry_organization_id = @registry_organization_id)
       AND (@legal_entity_id = 0 OR le.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR le.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
       AND (@status = N'' OR t.status = @status)
       AND (@search = N'' OR t.committee_code LIKE N'%' + @search + N'%' OR t.committee_name LIKE N'%' + @search + N'%')
     ORDER BY le.organization_name, t.committee_code;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_committees_save
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_committee WHERE committee_id = @id)
        THROW 52705, N'[] The Committee no longer exists. Reload the list.', 1;

    -- Outside GRAC administration a record of another Legal Entity is out of reach.
    IF @allowed_legal_entity_ids IS NOT NULL AND @id > 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_committee x WHERE x.committee_id = @id AND x.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[] This record belongs to a Legal Entity you do not have access to.', 1;

    -- Raw values (text; OPENJSON so long text is never truncated).
    DECLARE @f_committeeCode NVARCHAR(MAX);
    DECLARE @f_committeeName NVARCHAR(MAX);
    DECLARE @f_committeeType NVARCHAR(MAX);
    DECLARE @f_legalEntityId NVARCHAR(MAX);
    DECLARE @f_committeeMandate NVARCHAR(MAX);
    DECLARE @f_scopeResponsibilities NVARCHAR(MAX);
    DECLARE @f_chairpersonPersonId NVARCHAR(MAX);
    DECLARE @f_secretaryPersonId NVARCHAR(MAX);
    DECLARE @f_reviewFrequency NVARCHAR(MAX);
    DECLARE @f_torReference NVARCHAR(MAX);
    DECLARE @f_constitutedDate NVARCHAR(MAX);
    DECLARE @f_lastReviewedDate NVARCHAR(MAX);
    DECLARE @f_nextReviewDueDate NVARCHAR(MAX);
    DECLARE @f_recordStatus NVARCHAR(MAX);
    DECLARE @f_effectiveFrom NVARCHAR(MAX);
    DECLARE @f_effectiveTo NVARCHAR(MAX);
    DECLARE @f_remarks NVARCHAR(MAX);
    SELECT @f_committeeCode = NULLIF(LTRIM(RTRIM(j.[committeeCode])), N''),
           @f_committeeName = NULLIF(LTRIM(RTRIM(j.[committeeName])), N''),
           @f_committeeType = NULLIF(LTRIM(RTRIM(j.[committeeType])), N''),
           @f_legalEntityId = NULLIF(LTRIM(RTRIM(j.[legalEntityId])), N''),
           @f_committeeMandate = NULLIF(LTRIM(RTRIM(j.[committeeMandate])), N''),
           @f_scopeResponsibilities = NULLIF(LTRIM(RTRIM(j.[scopeResponsibilities])), N''),
           @f_chairpersonPersonId = NULLIF(LTRIM(RTRIM(j.[chairpersonPersonId])), N''),
           @f_secretaryPersonId = NULLIF(LTRIM(RTRIM(j.[secretaryPersonId])), N''),
           @f_reviewFrequency = NULLIF(LTRIM(RTRIM(j.[reviewFrequency])), N''),
           @f_torReference = NULLIF(LTRIM(RTRIM(j.[torReference])), N''),
           @f_constitutedDate = NULLIF(LTRIM(RTRIM(j.[constitutedDate])), N''),
           @f_lastReviewedDate = NULLIF(LTRIM(RTRIM(j.[lastReviewedDate])), N''),
           @f_nextReviewDueDate = NULLIF(LTRIM(RTRIM(j.[nextReviewDueDate])), N''),
           @f_recordStatus = NULLIF(LTRIM(RTRIM(j.[recordStatus])), N''),
           @f_effectiveFrom = NULLIF(LTRIM(RTRIM(j.[effectiveFrom])), N''),
           @f_effectiveTo = NULLIF(LTRIM(RTRIM(j.[effectiveTo])), N''),
           @f_remarks = NULLIF(LTRIM(RTRIM(j.[remarks])), N'')
      FROM OPENJSON(@payload) WITH ([committeeCode] NVARCHAR(MAX) N'$.committeeCode',
           [committeeName] NVARCHAR(MAX) N'$.committeeName',
           [committeeType] NVARCHAR(MAX) N'$.committeeType',
           [legalEntityId] NVARCHAR(MAX) N'$.legalEntityId',
           [committeeMandate] NVARCHAR(MAX) N'$.committeeMandate',
           [scopeResponsibilities] NVARCHAR(MAX) N'$.scopeResponsibilities',
           [chairpersonPersonId] NVARCHAR(MAX) N'$.chairpersonPersonId',
           [secretaryPersonId] NVARCHAR(MAX) N'$.secretaryPersonId',
           [reviewFrequency] NVARCHAR(MAX) N'$.reviewFrequency',
           [torReference] NVARCHAR(MAX) N'$.torReference',
           [constitutedDate] NVARCHAR(MAX) N'$.constitutedDate',
           [lastReviewedDate] NVARCHAR(MAX) N'$.lastReviewedDate',
           [nextReviewDueDate] NVARCHAR(MAX) N'$.nextReviewDueDate',
           [recordStatus] NVARCHAR(MAX) N'$.recordStatus',
           [effectiveFrom] NVARCHAR(MAX) N'$.effectiveFrom',
           [effectiveTo] NVARCHAR(MAX) N'$.effectiveTo',
           [remarks] NVARCHAR(MAX) N'$.remarks') j;

    DECLARE @r_legalEntityId BIGINT = TRY_CONVERT(BIGINT, @f_legalEntityId);
    IF @f_legalEntityId IS NOT NULL AND @r_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Legal Entity Code is not a valid selection.', 1;
    DECLARE @r_chairpersonPersonId BIGINT = TRY_CONVERT(BIGINT, @f_chairpersonPersonId);
    IF @f_chairpersonPersonId IS NOT NULL AND @r_chairpersonPersonId IS NULL THROW 52701, N'[chairpersonPersonId] Chairperson Person Code is not a valid selection.', 1;
    DECLARE @r_secretaryPersonId BIGINT = TRY_CONVERT(BIGINT, @f_secretaryPersonId);
    IF @f_secretaryPersonId IS NOT NULL AND @r_secretaryPersonId IS NULL THROW 52701, N'[secretaryPersonId] Committee Secretary Person Code is not a valid selection.', 1;
    DECLARE @d_constitutedDate DATE = TRY_CONVERT(DATE, LEFT(@f_constitutedDate, 10), 23);
    IF @f_constitutedDate IS NOT NULL AND @d_constitutedDate IS NULL THROW 52701, N'[constitutedDate] Constituted Date must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_lastReviewedDate DATE = TRY_CONVERT(DATE, LEFT(@f_lastReviewedDate, 10), 23);
    IF @f_lastReviewedDate IS NOT NULL AND @d_lastReviewedDate IS NULL THROW 52701, N'[lastReviewedDate] Last Reviewed Date must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_nextReviewDueDate DATE = TRY_CONVERT(DATE, LEFT(@f_nextReviewDueDate, 10), 23);
    IF @f_nextReviewDueDate IS NOT NULL AND @d_nextReviewDueDate IS NULL THROW 52701, N'[nextReviewDueDate] Next Review Due Date must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_effectiveFrom DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveFrom, 10), 23);
    IF @f_effectiveFrom IS NOT NULL AND @d_effectiveFrom IS NULL THROW 52701, N'[effectiveFrom] Effective From must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_effectiveTo DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveTo, 10), 23);
    IF @f_effectiveTo IS NOT NULL AND @d_effectiveTo IS NULL THROW 52701, N'[effectiveTo] Effective To must be a date (yyyy-mm-dd).', 1;

    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).
    IF @f_committeeCode IS NULL THROW 52701, N'[committeeCode] Committee Code is required.', 1;
    IF @f_committeeName IS NULL THROW 52701, N'[committeeName] Committee Name is required.', 1;
    IF @f_committeeType IS NULL THROW 52701, N'[committeeType] Committee Type is required.', 1;
    IF @f_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Legal Entity Code is required.', 1;
    IF @f_committeeMandate IS NULL THROW 52701, N'[committeeMandate] Committee Mandate is required.', 1;
    IF @f_recordStatus IS NULL THROW 52701, N'[recordStatus] Record Status is required.', 1;
    IF LEN(@f_committeeCode) > 80 THROW 52701, N'[committeeCode] Committee Code cannot be longer than 80 characters.', 1;
    IF LEN(@f_committeeName) > 200 THROW 52701, N'[committeeName] Committee Name cannot be longer than 200 characters.', 1;
    IF LEN(@f_torReference) > 200 THROW 52701, N'[torReference] Terms of Reference Reference cannot be longer than 200 characters.', 1;
    IF @d_effectiveFrom IS NOT NULL AND @d_effectiveTo IS NOT NULL AND @d_effectiveTo < @d_effectiveFrom THROW 52701, N'[effectiveTo] Effective To cannot be before Effective From.', 1;

    -- Controlled values (15 Masters & Codes). A value that is not on the list
    -- is accepted only when it is the value the record already holds, so an
    -- older record can still be saved without being forced to change it.
    IF @f_committeeType IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'CommitteeType' AND m.value_label = @f_committeeType AND m.status = N'Active')
            SELECT @f_committeeType = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'CommitteeType' AND m.value_label = @f_committeeType;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_committee WHERE committee_id = @id AND committee_type = @f_committeeType)
            THROW 52702, N'[committeeType] Committee Type: the value is not in the approved list (CommitteeType).', 1;
    END
    IF @f_reviewFrequency IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ReviewFrequency' AND m.value_label = @f_reviewFrequency AND m.status = N'Active')
            SELECT @f_reviewFrequency = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ReviewFrequency' AND m.value_label = @f_reviewFrequency;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_committee WHERE committee_id = @id AND review_frequency = @f_reviewFrequency)
            THROW 52702, N'[reviewFrequency] Review Frequency: the value is not in the approved list (ReviewFrequency).', 1;
    END
    IF @f_recordStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus AND m.status = N'Active')
            SELECT @f_recordStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_committee WHERE committee_id = @id AND status = @f_recordStatus)
            THROW 52702, N'[recordStatus] Record Status: the value is not in the approved list (RecordStatus).', 1;
    END

    DECLARE @le BIGINT = @r_legalEntityId;
    IF @le IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @le) THROW 52703, N'[legalEntityId] The selected Legal Entity does not exist.', 1;
    IF @id > 0 AND EXISTS (SELECT 1 FROM grac_practice.organization_committee WHERE committee_id = @id AND organization_id <> @le)
       AND EXISTS (SELECT 1 FROM grac_practice.organization_committee WHERE committee_id = @id AND organization_id IS NOT NULL)
        THROW 52703, N'[legalEntityId] A Committee cannot be moved to another Legal Entity: other records refer to it there. Mark it Inactive and create it in the other Legal Entity.', 1;
    IF @allowed_legal_entity_ids IS NOT NULL AND (@le IS NULL OR @le NOT IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[legalEntityId] You can only maintain records of your own Legal Entities.', 1;

    -- References: the record must exist (and belong where the field says).
    IF @r_chairpersonPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_chairpersonPersonId) THROW 52703, N'[chairpersonPersonId] Chairperson Person Code: the selected record does not exist.', 1;
    IF @r_chairpersonPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_chairpersonPersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[chairpersonPersonId] Chairperson Person Code must belong to the same Organization.', 1;
    IF @r_secretaryPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_secretaryPersonId) THROW 52703, N'[secretaryPersonId] Committee Secretary Person Code: the selected record does not exist.', 1;
    IF @r_secretaryPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_secretaryPersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[secretaryPersonId] Committee Secretary Person Code must belong to the same Organization.', 1;

    -- Unique codes.
    IF EXISTS (SELECT 1 FROM grac_practice.organization_committee WHERE organization_id = @le AND committee_code = @f_committeeCode AND committee_id <> @id) THROW 52704, N'[committeeCode] Committee Code is already used in this Legal Entity.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.organization_committee WHERE organization_id = @le AND committee_name = @f_committeeName AND committee_id <> @id) THROW 52704, N'[committeeName] Committee Name is already used in this Legal Entity.', 1;

    DECLARE @rsid INT = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master
                          WHERE status_code = CASE WHEN @f_recordStatus = N'Active' THEN N'Active'
                                                   WHEN @f_recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft'
                                                   ELSE N'Inactive' END);
    IF @rsid IS NULL SET @rsid = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
    DECLARE @freq_id INT = (SELECT TOP (1) fm.frequency_id FROM grac_practice.frequency_master fm
                             WHERE fm.frequency_name = CASE @f_reviewFrequency WHEN N'Annually' THEN N'Annual' ELSE @f_reviewFrequency END
                             ORDER BY fm.is_active DESC, fm.frequency_id);

    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).
    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT committee_code, committee_name, committee_type, organization_id, mandate, scope_responsibilities, chairperson_id, secretary_id, review_frequency, tor_reference, constituted_dt, last_reviewed_dt, next_review_due_dt, status, effective_from, effective_to, remarks, review_frequency_id, record_status_id FROM grac_practice.organization_committee WHERE committee_id = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;
    BEGIN TRAN;
    IF @id = 0
    BEGIN
        INSERT grac_practice.organization_committee (committee_code, committee_name, committee_type, organization_id, mandate, scope_responsibilities, chairperson_id, secretary_id, review_frequency, tor_reference, constituted_dt, last_reviewed_dt, next_review_due_dt, status, effective_from, effective_to, remarks, review_frequency_id, record_status_id, entered_by)
        VALUES (@f_committeeCode, @f_committeeName, @f_committeeType, @r_legalEntityId, @f_committeeMandate, @f_scopeResponsibilities, @r_chairpersonPersonId, @r_secretaryPersonId, @f_reviewFrequency, @f_torReference, @d_constitutedDate, @d_lastReviewedDate, @d_nextReviewDueDate, @f_recordStatus, @d_effectiveFrom, @d_effectiveTo, @f_remarks, @freq_id, @rsid, @actor);
        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_committee SET committee_code = @f_committeeCode,
               committee_name = @f_committeeName,
               committee_type = @f_committeeType,
               organization_id = @r_legalEntityId,
               mandate = @f_committeeMandate,
               scope_responsibilities = @f_scopeResponsibilities,
               chairperson_id = @r_chairpersonPersonId,
               secretary_id = @r_secretaryPersonId,
               review_frequency = @f_reviewFrequency,
               tor_reference = @f_torReference,
               constituted_dt = @d_constitutedDate,
               last_reviewed_dt = @d_lastReviewedDate,
               next_review_due_dt = @d_nextReviewDueDate,
               status = @f_recordStatus,
               effective_from = @d_effectiveFrom,
               effective_to = @d_effectiveTo,
               remarks = @f_remarks,
               review_frequency_id = @freq_id,
               record_status_id = @rsid,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE committee_id = @id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/committees', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Committee saved.' AS Message, @id AS Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_committee_members_list
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
    SELECT t.committee_member_id AS Id,
           t.membership_code AS Code,
           t.membership_code AS Name,
           t.status AS Status,
           le.organization_id AS LegalEntityId,
           le.organization_code AS LegalEntityCode,
           le.organization_name AS LegalEntityName,
           le.registry_organization_id AS RegistryOrganizationId,
           ro.organization_code AS RegistryOrganizationCode,
           ro.registered_name AS RegistryOrganizationName,
           t.entered_by AS EnteredBy,
           t.entered_dt AS EnteredDate,
           COALESCE(t.updated_by, t.entered_by) AS UpdatedBy,
           COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate,
           t.membership_code AS MembershipCode,
           t.committee_id AS CommitteeId,
           j1.committee_code AS CommitteeCode,
           j1.committee_name AS CommitteeName,
           t.employee_id AS PersonId,
           j2.employee_code AS PersonCode,
           j2.employee_name AS PersonName,
           j3.designation_name AS DesignationInCommittee,
           t.member_since AS MemberSince,
           t.member_until AS MemberUntil,
           t.is_voting_member AS VotingMember,
           t.is_permanent_invitee AS PermanentInvitee,
           t.participation_requirement AS ParticipationRequirement,
           t.status AS RecordStatus,
           t.remarks AS Remarks
      FROM grac_practice.organization_committee_member t
      LEFT JOIN grac_practice.organization le ON le.organization_id = t.organization_id
      LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = le.registry_organization_id
      LEFT JOIN grac_practice.organization_committee j1 ON j1.committee_id = t.committee_id
      LEFT JOIN grac_practice.organization_employee j2 ON j2.employee_id = t.employee_id
      LEFT JOIN grac_practice.committee_designation_master j3 ON j3.designation_id = t.designation_id
     WHERE (@id = 0 OR t.committee_member_id = @id)
       AND (@registry_organization_id = 0 OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL) OR le.registry_organization_id = @registry_organization_id)
       AND (@legal_entity_id = 0 OR le.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR le.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
       AND (@status = N'' OR t.status = @status)
       AND (@search = N'' OR t.membership_code LIKE N'%' + @search + N'%' OR t.membership_code LIKE N'%' + @search + N'%' OR j1.committee_name LIKE N'%' + @search + N'%' OR j2.employee_name LIKE N'%' + @search + N'%')
     ORDER BY le.organization_name, t.membership_code;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_committee_members_save
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_committee_member WHERE committee_member_id = @id)
        THROW 52705, N'[] The Committee Membership no longer exists. Reload the list.', 1;

    -- Outside GRAC administration a record of another Legal Entity is out of reach.
    IF @allowed_legal_entity_ids IS NOT NULL AND @id > 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_committee_member x WHERE x.committee_member_id = @id AND x.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[] This record belongs to a Legal Entity you do not have access to.', 1;

    -- Raw values (text; OPENJSON so long text is never truncated).
    DECLARE @f_membershipCode NVARCHAR(MAX);
    DECLARE @f_committeeId NVARCHAR(MAX);
    DECLARE @f_personId NVARCHAR(MAX);
    DECLARE @f_designationInCommittee NVARCHAR(MAX);
    DECLARE @f_memberSince NVARCHAR(MAX);
    DECLARE @f_memberUntil NVARCHAR(MAX);
    DECLARE @f_votingMember NVARCHAR(MAX);
    DECLARE @f_permanentInvitee NVARCHAR(MAX);
    DECLARE @f_participationRequirement NVARCHAR(MAX);
    DECLARE @f_recordStatus NVARCHAR(MAX);
    DECLARE @f_remarks NVARCHAR(MAX);
    SELECT @f_membershipCode = NULLIF(LTRIM(RTRIM(j.[membershipCode])), N''),
           @f_committeeId = NULLIF(LTRIM(RTRIM(j.[committeeId])), N''),
           @f_personId = NULLIF(LTRIM(RTRIM(j.[personId])), N''),
           @f_designationInCommittee = NULLIF(LTRIM(RTRIM(j.[designationInCommittee])), N''),
           @f_memberSince = NULLIF(LTRIM(RTRIM(j.[memberSince])), N''),
           @f_memberUntil = NULLIF(LTRIM(RTRIM(j.[memberUntil])), N''),
           @f_votingMember = NULLIF(LTRIM(RTRIM(j.[votingMember])), N''),
           @f_permanentInvitee = NULLIF(LTRIM(RTRIM(j.[permanentInvitee])), N''),
           @f_participationRequirement = NULLIF(LTRIM(RTRIM(j.[participationRequirement])), N''),
           @f_recordStatus = NULLIF(LTRIM(RTRIM(j.[recordStatus])), N''),
           @f_remarks = NULLIF(LTRIM(RTRIM(j.[remarks])), N'')
      FROM OPENJSON(@payload) WITH ([membershipCode] NVARCHAR(MAX) N'$.membershipCode',
           [committeeId] NVARCHAR(MAX) N'$.committeeId',
           [personId] NVARCHAR(MAX) N'$.personId',
           [designationInCommittee] NVARCHAR(MAX) N'$.designationInCommittee',
           [memberSince] NVARCHAR(MAX) N'$.memberSince',
           [memberUntil] NVARCHAR(MAX) N'$.memberUntil',
           [votingMember] NVARCHAR(MAX) N'$.votingMember',
           [permanentInvitee] NVARCHAR(MAX) N'$.permanentInvitee',
           [participationRequirement] NVARCHAR(MAX) N'$.participationRequirement',
           [recordStatus] NVARCHAR(MAX) N'$.recordStatus',
           [remarks] NVARCHAR(MAX) N'$.remarks') j;

    DECLARE @r_committeeId BIGINT = TRY_CONVERT(BIGINT, @f_committeeId);
    IF @f_committeeId IS NOT NULL AND @r_committeeId IS NULL THROW 52701, N'[committeeId] Committee Code is not a valid selection.', 1;
    DECLARE @r_personId BIGINT = TRY_CONVERT(BIGINT, @f_personId);
    IF @f_personId IS NOT NULL AND @r_personId IS NULL THROW 52701, N'[personId] Person Code is not a valid selection.', 1;
    DECLARE @i_designationInCommittee INT = NULL;
    DECLARE @d_memberSince DATE = TRY_CONVERT(DATE, LEFT(@f_memberSince, 10), 23);
    IF @f_memberSince IS NOT NULL AND @d_memberSince IS NULL THROW 52701, N'[memberSince] Member Since must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_memberUntil DATE = TRY_CONVERT(DATE, LEFT(@f_memberUntil, 10), 23);
    IF @f_memberUntil IS NOT NULL AND @d_memberUntil IS NULL THROW 52701, N'[memberUntil] Member Until must be a date (yyyy-mm-dd).', 1;

    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).
    IF @f_membershipCode IS NULL THROW 52701, N'[membershipCode] Membership Code is required.', 1;
    IF @f_committeeId IS NULL THROW 52701, N'[committeeId] Committee Code is required.', 1;
    IF @f_personId IS NULL THROW 52701, N'[personId] Person Code is required.', 1;
    IF @f_designationInCommittee IS NULL THROW 52701, N'[designationInCommittee] Designation in Committee is required.', 1;
    IF @f_recordStatus IS NULL THROW 52701, N'[recordStatus] Record Status is required.', 1;
    IF LEN(@f_membershipCode) > 80 THROW 52701, N'[membershipCode] Membership Code cannot be longer than 80 characters.', 1;
    IF LEN(@f_participationRequirement) > 300 THROW 52701, N'[participationRequirement] Attendance / Participation Requirement cannot be longer than 300 characters.', 1;
    IF @d_memberSince IS NOT NULL AND @d_memberUntil IS NOT NULL AND @d_memberUntil < @d_memberSince THROW 52701, N'[memberUntil] Member Until cannot be before Member Since.', 1;

    -- Controlled values (15 Masters & Codes). A value that is not on the list
    -- is accepted only when it is the value the record already holds, so an
    -- older record can still be saved without being forced to change it.
    IF @f_votingMember IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_votingMember AND m.status = N'Active')
            SELECT @f_votingMember = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_votingMember;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_committee_member WHERE committee_member_id = @id AND is_voting_member = @f_votingMember)
            THROW 52702, N'[votingMember] Voting Member?: the value is not in the approved list (YesNo).', 1;
    END
    IF @f_permanentInvitee IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_permanentInvitee AND m.status = N'Active')
            SELECT @f_permanentInvitee = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_permanentInvitee;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_committee_member WHERE committee_member_id = @id AND is_permanent_invitee = @f_permanentInvitee)
            THROW 52702, N'[permanentInvitee] Permanent Invitee?: the value is not in the approved list (YesNo).', 1;
    END
    IF @f_recordStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus AND m.status = N'Active')
            SELECT @f_recordStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_committee_member WHERE committee_member_id = @id AND status = @f_recordStatus)
            THROW 52702, N'[recordStatus] Record Status: the value is not in the approved list (RecordStatus).', 1;
    END

    DECLARE @le BIGINT = (SELECT organization_id FROM grac_practice.organization_committee WHERE committee_id = @r_committeeId);
    IF @r_committeeId IS NOT NULL AND @le IS NULL THROW 52703, N'[committeeId] The selected committee does not exist.', 1;
    IF @allowed_legal_entity_ids IS NOT NULL AND (@le IS NULL OR @le NOT IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[committeeId] You can only maintain records of your own Legal Entities.', 1;
    SELECT TOP (1) @i_designationInCommittee = d.designation_id FROM grac_practice.committee_designation_master d
     WHERE d.designation_name = @f_designationInCommittee AND (d.organization_id IS NULL OR d.organization_id = @le)
     ORDER BY CASE WHEN d.organization_id IS NULL THEN 1 ELSE 0 END, d.is_active DESC, d.designation_id;
    IF @f_designationInCommittee IS NOT NULL AND @i_designationInCommittee IS NULL THROW 52702, N'[designationInCommittee] Designation in Committee: the value is not in the approved list (CommitteeMemberDesignation).', 1;

    -- References: the record must exist (and belong where the field says).
    IF @r_committeeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_committee WHERE committee_id = @r_committeeId) THROW 52703, N'[committeeId] Committee Code: the selected record does not exist.', 1;
    IF @r_personId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_personId) THROW 52703, N'[personId] Person Code: the selected record does not exist.', 1;
    IF @r_personId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_personId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[personId] Person Code must belong to the same Organization.', 1;

    -- Unique codes.
    IF EXISTS (SELECT 1 FROM grac_practice.organization_committee_member WHERE organization_id = @le AND membership_code = @f_membershipCode AND committee_member_id <> @id) THROW 52704, N'[membershipCode] Membership Code is already used in this Legal Entity.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.organization_committee_member WHERE committee_id = @r_committeeId AND employee_id = @r_personId AND committee_member_id <> @id) THROW 52704, N'[personId] This person is already a member of this committee (one membership per person per committee).', 1;

    DECLARE @rsid INT = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master
                          WHERE status_code = CASE WHEN @f_recordStatus = N'Active' THEN N'Active'
                                                   WHEN @f_recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft'
                                                   ELSE N'Inactive' END);
    IF @rsid IS NULL SET @rsid = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).
    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT membership_code, committee_id, employee_id, designation_id, member_since, member_until, is_voting_member, is_permanent_invitee, participation_requirement, status, remarks, organization_id, record_status_id FROM grac_practice.organization_committee_member WHERE committee_member_id = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;
    BEGIN TRAN;
    IF @id = 0
    BEGIN
        INSERT grac_practice.organization_committee_member (membership_code, committee_id, employee_id, designation_id, member_since, member_until, is_voting_member, is_permanent_invitee, participation_requirement, status, remarks, organization_id, record_status_id, entered_by)
        VALUES (@f_membershipCode, @r_committeeId, @r_personId, @i_designationInCommittee, @d_memberSince, @d_memberUntil, @f_votingMember, @f_permanentInvitee, @f_participationRequirement, @f_recordStatus, @f_remarks, @le, @rsid, @actor);
        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_committee_member SET membership_code = @f_membershipCode,
               committee_id = @r_committeeId,
               employee_id = @r_personId,
               designation_id = @i_designationInCommittee,
               member_since = @d_memberSince,
               member_until = @d_memberUntil,
               is_voting_member = @f_votingMember,
               is_permanent_invitee = @f_permanentInvitee,
               participation_requirement = @f_participationRequirement,
               status = @f_recordStatus,
               remarks = @f_remarks,
               organization_id = @le,
               record_status_id = @rsid,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE committee_member_id = @id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/committee-members', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Committee Membership saved.' AS Message, @id AS Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_processes_list
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
    SELECT t.process_id AS Id,
           t.process_code AS Code,
           t.process_name AS Name,
           t.status AS Status,
           le.organization_id AS LegalEntityId,
           le.organization_code AS LegalEntityCode,
           le.organization_name AS LegalEntityName,
           le.registry_organization_id AS RegistryOrganizationId,
           ro.organization_code AS RegistryOrganizationCode,
           ro.registered_name AS RegistryOrganizationName,
           t.entered_by AS EnteredBy,
           t.entered_dt AS EnteredDate,
           COALESCE(t.updated_by, t.entered_by) AS UpdatedBy,
           COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate,
           t.process_code AS ProcessCode,
           t.process_name AS ProcessName,
           t.process_level AS ProcessLevel,
           t.parent_process_id AS ParentProcessId,
           j1.process_code AS ParentProcessCode,
           j1.process_name AS ParentProcessName,
           t.process_nature AS ProcessNature,
           t.business_function_id AS BusinessFunctionId,
           j2.function_code AS BusinessFunctionCode,
           j2.function_name AS BusinessFunctionName,
           t.owning_department_id AS OwningDepartmentId,
           j3.department_code AS OwningDepartmentCode,
           j3.department_name AS OwningDepartmentName,
           t.process_owner_id AS ProcessOwnerPersonId,
           j4.employee_code AS ProcessOwnerPersonCode,
           j4.employee_name AS ProcessOwnerPersonName,
           t.accountable_executive_id AS AccountableExecutivePersonId,
           j5.employee_code AS AccountableExecutivePersonCode,
           j5.employee_name AS AccountableExecutivePersonName,
           t.description AS DescriptionObjective,
           t.key_activities AS KeyActivities,
           t.primary_product_id AS PrimaryProductId,
           j6.product_code AS PrimaryProductCode,
           j6.product_name AS PrimaryProductName,
           t.primary_channel_id AS PrimaryChannelId,
           j7.channel_code AS PrimaryChannelCode,
           j7.channel_name AS PrimaryChannelName,
           t.organization_id AS LegalEntityId,
           j8.organization_code AS LegalEntityCode,
           j8.organization_name AS LegalEntityName,
           t.primary_division_id AS PrimaryOrganizationUnitId,
           j9.division_code AS PrimaryOrganizationUnitCode,
           j9.division_name AS PrimaryOrganizationUnitName,
           t.location_scope AS LocationScope,
           t.process_frequency AS ProcessFrequency,
           t.annual_volume AS AnnualVolume,
           t.customer_impact AS CustomerImpact,
           t.regulatory_impact AS RegulatoryImpact,
           t.regulatory_references AS RegulatoryReferences,
           (SELECT b.risk_category AS v FROM grac_practice.organization_process_risk_category b
        WHERE b.process_id = t.process_id ORDER BY b.risk_category FOR JSON PATH) AS KeyRiskCategories,
           t.status AS RecordStatus,
           t.effective_dt AS EffectiveFrom,
           t.effective_to AS EffectiveTo,
           t.remarks AS Remarks
      FROM grac_practice.organization_dependency_process t
      LEFT JOIN grac_practice.organization le ON le.organization_id = t.organization_id
      LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = le.registry_organization_id
      LEFT JOIN grac_practice.organization_dependency_process j1 ON j1.process_id = t.parent_process_id
      LEFT JOIN grac_practice.organization_business_function j2 ON j2.business_function_id = t.business_function_id
      LEFT JOIN grac_practice.organization_department j3 ON j3.department_id = t.owning_department_id
      LEFT JOIN grac_practice.organization_employee j4 ON j4.employee_id = t.process_owner_id
      LEFT JOIN grac_practice.organization_employee j5 ON j5.employee_id = t.accountable_executive_id
      LEFT JOIN grac_practice.organization_product_service j6 ON j6.product_service_id = t.primary_product_id
      LEFT JOIN grac_practice.organization_delivery_channel j7 ON j7.channel_id = t.primary_channel_id
      LEFT JOIN grac_practice.organization j8 ON j8.organization_id = t.organization_id
      LEFT JOIN grac_practice.organization_division j9 ON j9.division_id = t.primary_division_id
     WHERE (@id = 0 OR t.process_id = @id)
       AND (@registry_organization_id = 0 OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL) OR le.registry_organization_id = @registry_organization_id)
       AND (@legal_entity_id = 0 OR le.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR le.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
       AND (@status = N'' OR t.status = @status)
       AND (@search = N'' OR t.process_code LIKE N'%' + @search + N'%' OR t.process_name LIKE N'%' + @search + N'%')
     ORDER BY le.organization_name, t.process_code;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_processes_save
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process WHERE process_id = @id)
        THROW 52705, N'[] The Business Process no longer exists. Reload the list.', 1;

    -- Outside GRAC administration a record of another Legal Entity is out of reach.
    IF @allowed_legal_entity_ids IS NOT NULL AND @id > 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process x WHERE x.process_id = @id AND x.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[] This record belongs to a Legal Entity you do not have access to.', 1;

    -- Raw values (text; OPENJSON so long text is never truncated).
    DECLARE @f_processCode NVARCHAR(MAX);
    DECLARE @f_processName NVARCHAR(MAX);
    DECLARE @f_processLevel NVARCHAR(MAX);
    DECLARE @f_parentProcessId NVARCHAR(MAX);
    DECLARE @f_processNature NVARCHAR(MAX);
    DECLARE @f_businessFunctionId NVARCHAR(MAX);
    DECLARE @f_owningDepartmentId NVARCHAR(MAX);
    DECLARE @f_processOwnerPersonId NVARCHAR(MAX);
    DECLARE @f_accountableExecutivePersonId NVARCHAR(MAX);
    DECLARE @f_descriptionObjective NVARCHAR(MAX);
    DECLARE @f_keyActivities NVARCHAR(MAX);
    DECLARE @f_primaryProductId NVARCHAR(MAX);
    DECLARE @f_primaryChannelId NVARCHAR(MAX);
    DECLARE @f_legalEntityId NVARCHAR(MAX);
    DECLARE @f_primaryOrganizationUnitId NVARCHAR(MAX);
    DECLARE @f_locationScope NVARCHAR(MAX);
    DECLARE @f_processFrequency NVARCHAR(MAX);
    DECLARE @f_annualVolume NVARCHAR(MAX);
    DECLARE @f_customerImpact NVARCHAR(MAX);
    DECLARE @f_regulatoryImpact NVARCHAR(MAX);
    DECLARE @f_regulatoryReferences NVARCHAR(MAX);
    DECLARE @f_recordStatus NVARCHAR(MAX);
    DECLARE @f_effectiveFrom NVARCHAR(MAX);
    DECLARE @f_effectiveTo NVARCHAR(MAX);
    DECLARE @f_remarks NVARCHAR(MAX);
    SELECT @f_processCode = NULLIF(LTRIM(RTRIM(j.[processCode])), N''),
           @f_processName = NULLIF(LTRIM(RTRIM(j.[processName])), N''),
           @f_processLevel = NULLIF(LTRIM(RTRIM(j.[processLevel])), N''),
           @f_parentProcessId = NULLIF(LTRIM(RTRIM(j.[parentProcessId])), N''),
           @f_processNature = NULLIF(LTRIM(RTRIM(j.[processNature])), N''),
           @f_businessFunctionId = NULLIF(LTRIM(RTRIM(j.[businessFunctionId])), N''),
           @f_owningDepartmentId = NULLIF(LTRIM(RTRIM(j.[owningDepartmentId])), N''),
           @f_processOwnerPersonId = NULLIF(LTRIM(RTRIM(j.[processOwnerPersonId])), N''),
           @f_accountableExecutivePersonId = NULLIF(LTRIM(RTRIM(j.[accountableExecutivePersonId])), N''),
           @f_descriptionObjective = NULLIF(LTRIM(RTRIM(j.[descriptionObjective])), N''),
           @f_keyActivities = NULLIF(LTRIM(RTRIM(j.[keyActivities])), N''),
           @f_primaryProductId = NULLIF(LTRIM(RTRIM(j.[primaryProductId])), N''),
           @f_primaryChannelId = NULLIF(LTRIM(RTRIM(j.[primaryChannelId])), N''),
           @f_legalEntityId = NULLIF(LTRIM(RTRIM(j.[legalEntityId])), N''),
           @f_primaryOrganizationUnitId = NULLIF(LTRIM(RTRIM(j.[primaryOrganizationUnitId])), N''),
           @f_locationScope = NULLIF(LTRIM(RTRIM(j.[locationScope])), N''),
           @f_processFrequency = NULLIF(LTRIM(RTRIM(j.[processFrequency])), N''),
           @f_annualVolume = NULLIF(LTRIM(RTRIM(j.[annualVolume])), N''),
           @f_customerImpact = NULLIF(LTRIM(RTRIM(j.[customerImpact])), N''),
           @f_regulatoryImpact = NULLIF(LTRIM(RTRIM(j.[regulatoryImpact])), N''),
           @f_regulatoryReferences = NULLIF(LTRIM(RTRIM(j.[regulatoryReferences])), N''),
           @f_recordStatus = NULLIF(LTRIM(RTRIM(j.[recordStatus])), N''),
           @f_effectiveFrom = NULLIF(LTRIM(RTRIM(j.[effectiveFrom])), N''),
           @f_effectiveTo = NULLIF(LTRIM(RTRIM(j.[effectiveTo])), N''),
           @f_remarks = NULLIF(LTRIM(RTRIM(j.[remarks])), N'')
      FROM OPENJSON(@payload) WITH ([processCode] NVARCHAR(MAX) N'$.processCode',
           [processName] NVARCHAR(MAX) N'$.processName',
           [processLevel] NVARCHAR(MAX) N'$.processLevel',
           [parentProcessId] NVARCHAR(MAX) N'$.parentProcessId',
           [processNature] NVARCHAR(MAX) N'$.processNature',
           [businessFunctionId] NVARCHAR(MAX) N'$.businessFunctionId',
           [owningDepartmentId] NVARCHAR(MAX) N'$.owningDepartmentId',
           [processOwnerPersonId] NVARCHAR(MAX) N'$.processOwnerPersonId',
           [accountableExecutivePersonId] NVARCHAR(MAX) N'$.accountableExecutivePersonId',
           [descriptionObjective] NVARCHAR(MAX) N'$.descriptionObjective',
           [keyActivities] NVARCHAR(MAX) N'$.keyActivities',
           [primaryProductId] NVARCHAR(MAX) N'$.primaryProductId',
           [primaryChannelId] NVARCHAR(MAX) N'$.primaryChannelId',
           [legalEntityId] NVARCHAR(MAX) N'$.legalEntityId',
           [primaryOrganizationUnitId] NVARCHAR(MAX) N'$.primaryOrganizationUnitId',
           [locationScope] NVARCHAR(MAX) N'$.locationScope',
           [processFrequency] NVARCHAR(MAX) N'$.processFrequency',
           [annualVolume] NVARCHAR(MAX) N'$.annualVolume',
           [customerImpact] NVARCHAR(MAX) N'$.customerImpact',
           [regulatoryImpact] NVARCHAR(MAX) N'$.regulatoryImpact',
           [regulatoryReferences] NVARCHAR(MAX) N'$.regulatoryReferences',
           [recordStatus] NVARCHAR(MAX) N'$.recordStatus',
           [effectiveFrom] NVARCHAR(MAX) N'$.effectiveFrom',
           [effectiveTo] NVARCHAR(MAX) N'$.effectiveTo',
           [remarks] NVARCHAR(MAX) N'$.remarks') j;

    DECLARE @r_parentProcessId BIGINT = TRY_CONVERT(BIGINT, @f_parentProcessId);
    IF @f_parentProcessId IS NOT NULL AND @r_parentProcessId IS NULL THROW 52701, N'[parentProcessId] Parent Process Code is not a valid selection.', 1;
    DECLARE @r_businessFunctionId BIGINT = TRY_CONVERT(BIGINT, @f_businessFunctionId);
    IF @f_businessFunctionId IS NOT NULL AND @r_businessFunctionId IS NULL THROW 52701, N'[businessFunctionId] Business Function Code is not a valid selection.', 1;
    DECLARE @r_owningDepartmentId BIGINT = TRY_CONVERT(BIGINT, @f_owningDepartmentId);
    IF @f_owningDepartmentId IS NOT NULL AND @r_owningDepartmentId IS NULL THROW 52701, N'[owningDepartmentId] Owning Department Code is not a valid selection.', 1;
    DECLARE @r_processOwnerPersonId BIGINT = TRY_CONVERT(BIGINT, @f_processOwnerPersonId);
    IF @f_processOwnerPersonId IS NOT NULL AND @r_processOwnerPersonId IS NULL THROW 52701, N'[processOwnerPersonId] Process Owner Person Code is not a valid selection.', 1;
    DECLARE @r_accountableExecutivePersonId BIGINT = TRY_CONVERT(BIGINT, @f_accountableExecutivePersonId);
    IF @f_accountableExecutivePersonId IS NOT NULL AND @r_accountableExecutivePersonId IS NULL THROW 52701, N'[accountableExecutivePersonId] Accountable Executive Person Code is not a valid selection.', 1;
    DECLARE @r_primaryProductId BIGINT = TRY_CONVERT(BIGINT, @f_primaryProductId);
    IF @f_primaryProductId IS NOT NULL AND @r_primaryProductId IS NULL THROW 52701, N'[primaryProductId] Primary Product / Service Code is not a valid selection.', 1;
    DECLARE @r_primaryChannelId BIGINT = TRY_CONVERT(BIGINT, @f_primaryChannelId);
    IF @f_primaryChannelId IS NOT NULL AND @r_primaryChannelId IS NULL THROW 52701, N'[primaryChannelId] Primary Channel Code is not a valid selection.', 1;
    DECLARE @r_legalEntityId BIGINT = TRY_CONVERT(BIGINT, @f_legalEntityId);
    IF @f_legalEntityId IS NOT NULL AND @r_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Applicable Legal Entity Code is not a valid selection.', 1;
    DECLARE @r_primaryOrganizationUnitId BIGINT = TRY_CONVERT(BIGINT, @f_primaryOrganizationUnitId);
    IF @f_primaryOrganizationUnitId IS NOT NULL AND @r_primaryOrganizationUnitId IS NULL THROW 52701, N'[primaryOrganizationUnitId] Primary Organization Unit Code is not a valid selection.', 1;
    DECLARE @n_annualVolume BIGINT = TRY_CONVERT(BIGINT, @f_annualVolume);
    IF @f_annualVolume IS NOT NULL AND (@n_annualVolume IS NULL OR @n_annualVolume < 0) THROW 52701, N'[annualVolume] Approx. Annual Volume (optional) must be a whole number, 0 or more.', 1;
    DECLARE @d_effectiveFrom DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveFrom, 10), 23);
    IF @f_effectiveFrom IS NOT NULL AND @d_effectiveFrom IS NULL THROW 52701, N'[effectiveFrom] Effective From must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_effectiveTo DATE = TRY_CONVERT(DATE, LEFT(@f_effectiveTo, 10), 23);
    IF @f_effectiveTo IS NOT NULL AND @d_effectiveTo IS NULL THROW 52701, N'[effectiveTo] Effective To must be a date (yyyy-mm-dd).', 1;

    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).
    IF @f_processCode IS NULL THROW 52701, N'[processCode] Process Code is required.', 1;
    IF @f_processName IS NULL THROW 52701, N'[processName] Process Name is required.', 1;
    IF @f_processLevel IS NULL THROW 52701, N'[processLevel] Process Level is required.', 1;
    IF @f_processNature IS NULL THROW 52701, N'[processNature] Process Nature is required.', 1;
    IF @f_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Applicable Legal Entity Code is required.', 1;
    IF @f_recordStatus IS NULL THROW 52701, N'[recordStatus] Record Status is required.', 1;
    IF LEN(@f_processCode) > 80 THROW 52701, N'[processCode] Process Code cannot be longer than 80 characters.', 1;
    IF LEN(@f_processName) > 220 THROW 52701, N'[processName] Process Name cannot be longer than 220 characters.', 1;
    IF LEN(@f_locationScope) > 300 THROW 52701, N'[locationScope] Applicable Location Scope cannot be longer than 300 characters.', 1;
    IF @d_effectiveFrom IS NOT NULL AND @d_effectiveTo IS NOT NULL AND @d_effectiveTo < @d_effectiveFrom THROW 52701, N'[effectiveTo] Effective To cannot be before Effective From.', 1;

    -- Controlled values (15 Masters & Codes). A value that is not on the list
    -- is accepted only when it is the value the record already holds, so an
    -- older record can still be saved without being forced to change it.
    IF @f_processLevel IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ProcessLevel' AND m.value_label = @f_processLevel AND m.status = N'Active')
            SELECT @f_processLevel = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ProcessLevel' AND m.value_label = @f_processLevel;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process WHERE process_id = @id AND process_level = @f_processLevel)
            THROW 52702, N'[processLevel] Process Level: the value is not in the approved list (ProcessLevel).', 1;
    END
    IF @f_processNature IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ProcessNature' AND m.value_label = @f_processNature AND m.status = N'Active')
            SELECT @f_processNature = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ProcessNature' AND m.value_label = @f_processNature;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process WHERE process_id = @id AND process_nature = @f_processNature)
            THROW 52702, N'[processNature] Process Nature: the value is not in the approved list (ProcessNature).', 1;
    END
    IF @f_processFrequency IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ProcessFrequency' AND m.value_label = @f_processFrequency AND m.status = N'Active')
            SELECT @f_processFrequency = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ProcessFrequency' AND m.value_label = @f_processFrequency;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process WHERE process_id = @id AND process_frequency = @f_processFrequency)
            THROW 52702, N'[processFrequency] Process Frequency: the value is not in the approved list (ProcessFrequency).', 1;
    END
    IF @f_customerImpact IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_customerImpact AND m.status = N'Active')
            SELECT @f_customerImpact = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_customerImpact;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process WHERE process_id = @id AND customer_impact = @f_customerImpact)
            THROW 52702, N'[customerImpact] Customer Impact?: the value is not in the approved list (YesNo).', 1;
    END
    IF @f_regulatoryImpact IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RegulatoryImpact' AND m.value_label = @f_regulatoryImpact AND m.status = N'Active')
            SELECT @f_regulatoryImpact = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RegulatoryImpact' AND m.value_label = @f_regulatoryImpact;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process WHERE process_id = @id AND regulatory_impact = @f_regulatoryImpact)
            THROW 52702, N'[regulatoryImpact] Regulatory Impact: the value is not in the approved list (RegulatoryImpact).', 1;
    END
    IF @f_recordStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus AND m.status = N'Active')
            SELECT @f_recordStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'RecordStatus' AND m.value_label = @f_recordStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process WHERE process_id = @id AND status = @f_recordStatus)
            THROW 52702, N'[recordStatus] Record Status: the value is not in the approved list (RecordStatus).', 1;
    END

    DECLARE @le BIGINT = @r_legalEntityId;
    IF @le IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @le) THROW 52703, N'[legalEntityId] The selected Legal Entity does not exist.', 1;
    IF @id > 0 AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process WHERE process_id = @id AND organization_id <> @le)
       AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process WHERE process_id = @id AND organization_id IS NOT NULL)
        THROW 52703, N'[legalEntityId] A Business Process cannot be moved to another Legal Entity: other records refer to it there. Mark it Inactive and create it in the other Legal Entity.', 1;
    IF @allowed_legal_entity_ids IS NOT NULL AND (@le IS NULL OR @le NOT IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[legalEntityId] You can only maintain records of your own Legal Entities.', 1;

    -- References: the record must exist (and belong where the field says).
    IF @r_parentProcessId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process WHERE process_id = @r_parentProcessId) THROW 52703, N'[parentProcessId] Parent Process Code: the selected record does not exist.', 1;
    IF @r_parentProcessId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process x WHERE x.process_id = @r_parentProcessId AND x.organization_id = @le)
        THROW 52703, N'[parentProcessId] Parent Process Code must belong to the same Legal Entity.', 1;
    IF @r_parentProcessId IS NOT NULL AND @id > 0
    BEGIN
        IF @r_parentProcessId = @id THROW 52706, N'[parentProcessId] Parent Process Code cannot be the record itself.', 1;
        DECLARE @walk_parentProcessId BIGINT = @r_parentProcessId, @guard_parentProcessId INT = 0;
        WHILE @walk_parentProcessId IS NOT NULL AND @guard_parentProcessId < 100
        BEGIN
            IF @walk_parentProcessId = @id THROW 52706, N'[parentProcessId] Parent Process Code would make a loop: this record is already above it.', 1;
            SET @walk_parentProcessId = (SELECT parent_process_id FROM grac_practice.organization_dependency_process WHERE process_id = @walk_parentProcessId);
            SET @guard_parentProcessId += 1;
        END
    END
    IF @r_businessFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @r_businessFunctionId) THROW 52703, N'[businessFunctionId] Business Function Code: the selected record does not exist.', 1;
    IF @r_businessFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function x WHERE x.business_function_id = @r_businessFunctionId AND x.organization_id = @le)
        THROW 52703, N'[businessFunctionId] Business Function Code must belong to the same Legal Entity.', 1;
    IF @r_owningDepartmentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE department_id = @r_owningDepartmentId) THROW 52703, N'[owningDepartmentId] Owning Department Code: the selected record does not exist.', 1;
    IF @r_owningDepartmentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department x WHERE x.department_id = @r_owningDepartmentId AND x.organization_id = @le)
        THROW 52703, N'[owningDepartmentId] Owning Department Code must belong to the same Legal Entity.', 1;
    IF @r_processOwnerPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_processOwnerPersonId) THROW 52703, N'[processOwnerPersonId] Process Owner Person Code: the selected record does not exist.', 1;
    IF @r_processOwnerPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_processOwnerPersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[processOwnerPersonId] Process Owner Person Code must belong to the same Organization.', 1;
    IF @r_accountableExecutivePersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_accountableExecutivePersonId) THROW 52703, N'[accountableExecutivePersonId] Accountable Executive Person Code: the selected record does not exist.', 1;
    IF @r_accountableExecutivePersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_accountableExecutivePersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[accountableExecutivePersonId] Accountable Executive Person Code must belong to the same Organization.', 1;
    IF @r_primaryProductId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_product_service WHERE product_service_id = @r_primaryProductId) THROW 52703, N'[primaryProductId] Primary Product / Service Code: the selected record does not exist.', 1;
    IF @r_primaryProductId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_product_service x WHERE x.product_service_id = @r_primaryProductId AND x.organization_id = @le)
        THROW 52703, N'[primaryProductId] Primary Product / Service Code must belong to the same Legal Entity.', 1;
    IF @r_primaryChannelId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_delivery_channel WHERE channel_id = @r_primaryChannelId) THROW 52703, N'[primaryChannelId] Primary Channel Code: the selected record does not exist.', 1;
    IF @r_primaryChannelId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_delivery_channel x WHERE x.channel_id = @r_primaryChannelId AND x.organization_id = @le)
        THROW 52703, N'[primaryChannelId] Primary Channel Code must belong to the same Legal Entity.', 1;
    IF @r_primaryOrganizationUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @r_primaryOrganizationUnitId) THROW 52703, N'[primaryOrganizationUnitId] Primary Organization Unit Code: the selected record does not exist.', 1;
    IF @r_primaryOrganizationUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division x WHERE x.division_id = @r_primaryOrganizationUnitId AND x.organization_id = @le)
        THROW 52703, N'[primaryOrganizationUnitId] Primary Organization Unit Code must belong to the same Legal Entity.', 1;
    DECLARE @m_keyRiskCategories TABLE (v NVARCHAR(120) NOT NULL PRIMARY KEY);
    IF ISJSON(JSON_QUERY(@payload, N'$.keyRiskCategories')) = 1
        INSERT @m_keyRiskCategories(v) SELECT DISTINCT LTRIM(RTRIM(j.[value])) FROM OPENJSON(@payload, N'$.keyRiskCategories') j
         WHERE NULLIF(LTRIM(RTRIM(j.[value])), N'') IS NOT NULL;
    IF EXISTS (SELECT 1 FROM @m_keyRiskCategories m WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value x WHERE x.master_group = N'ProcessRisk' AND x.value_label = m.v AND x.status = N'Active')
                                       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_process_risk_category b WHERE b.process_id = @id AND b.risk_category = m.v))
        THROW 52702, N'[keyRiskCategories] Key Risk Categories: a value is not in the approved list (ProcessRisk).', 1;

    -- Unique codes.
    IF EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process WHERE organization_id = @le AND process_code = @f_processCode AND process_id <> @id) THROW 52704, N'[processCode] Process Code is already used in this Legal Entity.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process WHERE organization_id = @le AND process_name = @f_processName AND process_id <> @id) THROW 52704, N'[processName] Process Name is already used in this Legal Entity.', 1;

    DECLARE @rsid INT = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master
                          WHERE status_code = CASE WHEN @f_recordStatus = N'Active' THEN N'Active'
                                                   WHEN @f_recordStatus IN (N'Draft', N'Pending Approval') THEN N'Draft'
                                                   ELSE N'Inactive' END);
    IF @rsid IS NULL SET @rsid = (SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).
    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT process_code, process_name, process_level, parent_process_id, process_nature, business_function_id, owning_department_id, process_owner_id, accountable_executive_id, description, key_activities, primary_product_id, primary_channel_id, organization_id, primary_division_id, location_scope, process_frequency, annual_volume, customer_impact, regulatory_impact, regulatory_references, status, effective_dt, effective_to, remarks, record_status_id FROM grac_practice.organization_dependency_process WHERE process_id = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;
    BEGIN TRAN;
    IF @id = 0
    BEGIN
        INSERT grac_practice.organization_dependency_process (process_code, process_name, process_level, parent_process_id, process_nature, business_function_id, owning_department_id, process_owner_id, accountable_executive_id, description, key_activities, primary_product_id, primary_channel_id, organization_id, primary_division_id, location_scope, process_frequency, annual_volume, customer_impact, regulatory_impact, regulatory_references, status, effective_dt, effective_to, remarks, record_status_id, entered_by)
        VALUES (@f_processCode, @f_processName, @f_processLevel, @r_parentProcessId, @f_processNature, @r_businessFunctionId, @r_owningDepartmentId, @r_processOwnerPersonId, @r_accountableExecutivePersonId, @f_descriptionObjective, @f_keyActivities, @r_primaryProductId, @r_primaryChannelId, @r_legalEntityId, @r_primaryOrganizationUnitId, @f_locationScope, @f_processFrequency, @n_annualVolume, @f_customerImpact, @f_regulatoryImpact, @f_regulatoryReferences, @f_recordStatus, @d_effectiveFrom, @d_effectiveTo, @f_remarks, @rsid, @actor);
        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_dependency_process SET process_code = @f_processCode,
               process_name = @f_processName,
               process_level = @f_processLevel,
               parent_process_id = @r_parentProcessId,
               process_nature = @f_processNature,
               business_function_id = @r_businessFunctionId,
               owning_department_id = @r_owningDepartmentId,
               process_owner_id = @r_processOwnerPersonId,
               accountable_executive_id = @r_accountableExecutivePersonId,
               description = @f_descriptionObjective,
               key_activities = @f_keyActivities,
               primary_product_id = @r_primaryProductId,
               primary_channel_id = @r_primaryChannelId,
               organization_id = @r_legalEntityId,
               primary_division_id = @r_primaryOrganizationUnitId,
               location_scope = @f_locationScope,
               process_frequency = @f_processFrequency,
               annual_volume = @n_annualVolume,
               customer_impact = @f_customerImpact,
               regulatory_impact = @f_regulatoryImpact,
               regulatory_references = @f_regulatoryReferences,
               status = @f_recordStatus,
               effective_dt = @d_effectiveFrom,
               effective_to = @d_effectiveTo,
               remarks = @f_remarks,
               record_status_id = @rsid,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE process_id = @id;
    END
    IF JSON_QUERY(@payload, N'$.keyRiskCategories') IS NOT NULL
    BEGIN
        DELETE b FROM grac_practice.organization_process_risk_category b WHERE b.process_id = @id AND NOT EXISTS (SELECT 1 FROM @m_keyRiskCategories m WHERE m.v = b.risk_category);
        INSERT grac_practice.organization_process_risk_category (process_id, risk_category, entered_by)
        SELECT @id, m.v, @actor FROM @m_keyRiskCategories m
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_process_risk_category b WHERE b.process_id = @id AND b.risk_category = m.v);
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/processes', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Business Process saved.' AS Message, @id AS Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_products_list
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
    SELECT t.product_service_id AS Id,
           t.product_code AS Code,
           t.product_name AS Name,
           t.status AS Status,
           le.organization_id AS LegalEntityId,
           le.organization_code AS LegalEntityCode,
           le.organization_name AS LegalEntityName,
           le.registry_organization_id AS RegistryOrganizationId,
           ro.organization_code AS RegistryOrganizationCode,
           ro.registered_name AS RegistryOrganizationName,
           t.entered_by AS EnteredBy,
           t.entered_dt AS EnteredDate,
           COALESCE(t.updated_by, t.entered_by) AS UpdatedBy,
           COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate,
           t.product_code AS ProductCode,
           t.product_name AS ProductName,
           t.product_category AS ProductCategory,
           t.scheme_variant AS SchemeVariant,
           t.description AS Description,
           t.owning_function_id AS OwningFunctionId,
           j1.function_code AS OwningFunctionCode,
           j1.function_name AS OwningFunctionName,
           t.owning_department_id AS OwningDepartmentId,
           j2.department_code AS OwningDepartmentCode,
           j2.department_name AS OwningDepartmentName,
           t.product_owner_id AS ProductOwnerPersonId,
           j3.employee_code AS ProductOwnerPersonCode,
           j3.employee_name AS ProductOwnerPersonName,
           t.organization_id AS LegalEntityId,
           j4.organization_code AS LegalEntityCode,
           j4.organization_name AS LegalEntityName,
           t.customer_segment AS CustomerSegment,
           t.secured_unsecured AS SecuredUnsecured,
           t.regulatory_classification AS RegulatoryClassification,
           t.launch_dt AS LaunchDate,
           t.withdrawal_dt AS WithdrawalDate,
           t.status AS ProductStatus,
           t.remarks AS Remarks
      FROM grac_practice.organization_product_service t
      LEFT JOIN grac_practice.organization le ON le.organization_id = t.organization_id
      LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = le.registry_organization_id
      LEFT JOIN grac_practice.organization_business_function j1 ON j1.business_function_id = t.owning_function_id
      LEFT JOIN grac_practice.organization_department j2 ON j2.department_id = t.owning_department_id
      LEFT JOIN grac_practice.organization_employee j3 ON j3.employee_id = t.product_owner_id
      LEFT JOIN grac_practice.organization j4 ON j4.organization_id = t.organization_id
     WHERE (@id = 0 OR t.product_service_id = @id)
       AND (@registry_organization_id = 0 OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL) OR le.registry_organization_id = @registry_organization_id)
       AND (@legal_entity_id = 0 OR le.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR le.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
       AND (@status = N'' OR t.status = @status)
       AND (@search = N'' OR t.product_code LIKE N'%' + @search + N'%' OR t.product_name LIKE N'%' + @search + N'%')
     ORDER BY le.organization_name, t.product_code;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_products_save
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_product_service WHERE product_service_id = @id)
        THROW 52705, N'[] The Product / Service no longer exists. Reload the list.', 1;

    -- Outside GRAC administration a record of another Legal Entity is out of reach.
    IF @allowed_legal_entity_ids IS NOT NULL AND @id > 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_product_service x WHERE x.product_service_id = @id AND x.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[] This record belongs to a Legal Entity you do not have access to.', 1;

    -- Raw values (text; OPENJSON so long text is never truncated).
    DECLARE @f_productCode NVARCHAR(MAX);
    DECLARE @f_productName NVARCHAR(MAX);
    DECLARE @f_productCategory NVARCHAR(MAX);
    DECLARE @f_schemeVariant NVARCHAR(MAX);
    DECLARE @f_description NVARCHAR(MAX);
    DECLARE @f_owningFunctionId NVARCHAR(MAX);
    DECLARE @f_owningDepartmentId NVARCHAR(MAX);
    DECLARE @f_productOwnerPersonId NVARCHAR(MAX);
    DECLARE @f_legalEntityId NVARCHAR(MAX);
    DECLARE @f_customerSegment NVARCHAR(MAX);
    DECLARE @f_securedUnsecured NVARCHAR(MAX);
    DECLARE @f_regulatoryClassification NVARCHAR(MAX);
    DECLARE @f_launchDate NVARCHAR(MAX);
    DECLARE @f_withdrawalDate NVARCHAR(MAX);
    DECLARE @f_productStatus NVARCHAR(MAX);
    DECLARE @f_remarks NVARCHAR(MAX);
    SELECT @f_productCode = NULLIF(LTRIM(RTRIM(j.[productCode])), N''),
           @f_productName = NULLIF(LTRIM(RTRIM(j.[productName])), N''),
           @f_productCategory = NULLIF(LTRIM(RTRIM(j.[productCategory])), N''),
           @f_schemeVariant = NULLIF(LTRIM(RTRIM(j.[schemeVariant])), N''),
           @f_description = NULLIF(LTRIM(RTRIM(j.[description])), N''),
           @f_owningFunctionId = NULLIF(LTRIM(RTRIM(j.[owningFunctionId])), N''),
           @f_owningDepartmentId = NULLIF(LTRIM(RTRIM(j.[owningDepartmentId])), N''),
           @f_productOwnerPersonId = NULLIF(LTRIM(RTRIM(j.[productOwnerPersonId])), N''),
           @f_legalEntityId = NULLIF(LTRIM(RTRIM(j.[legalEntityId])), N''),
           @f_customerSegment = NULLIF(LTRIM(RTRIM(j.[customerSegment])), N''),
           @f_securedUnsecured = NULLIF(LTRIM(RTRIM(j.[securedUnsecured])), N''),
           @f_regulatoryClassification = NULLIF(LTRIM(RTRIM(j.[regulatoryClassification])), N''),
           @f_launchDate = NULLIF(LTRIM(RTRIM(j.[launchDate])), N''),
           @f_withdrawalDate = NULLIF(LTRIM(RTRIM(j.[withdrawalDate])), N''),
           @f_productStatus = NULLIF(LTRIM(RTRIM(j.[productStatus])), N''),
           @f_remarks = NULLIF(LTRIM(RTRIM(j.[remarks])), N'')
      FROM OPENJSON(@payload) WITH ([productCode] NVARCHAR(MAX) N'$.productCode',
           [productName] NVARCHAR(MAX) N'$.productName',
           [productCategory] NVARCHAR(MAX) N'$.productCategory',
           [schemeVariant] NVARCHAR(MAX) N'$.schemeVariant',
           [description] NVARCHAR(MAX) N'$.description',
           [owningFunctionId] NVARCHAR(MAX) N'$.owningFunctionId',
           [owningDepartmentId] NVARCHAR(MAX) N'$.owningDepartmentId',
           [productOwnerPersonId] NVARCHAR(MAX) N'$.productOwnerPersonId',
           [legalEntityId] NVARCHAR(MAX) N'$.legalEntityId',
           [customerSegment] NVARCHAR(MAX) N'$.customerSegment',
           [securedUnsecured] NVARCHAR(MAX) N'$.securedUnsecured',
           [regulatoryClassification] NVARCHAR(MAX) N'$.regulatoryClassification',
           [launchDate] NVARCHAR(MAX) N'$.launchDate',
           [withdrawalDate] NVARCHAR(MAX) N'$.withdrawalDate',
           [productStatus] NVARCHAR(MAX) N'$.productStatus',
           [remarks] NVARCHAR(MAX) N'$.remarks') j;

    DECLARE @r_owningFunctionId BIGINT = TRY_CONVERT(BIGINT, @f_owningFunctionId);
    IF @f_owningFunctionId IS NOT NULL AND @r_owningFunctionId IS NULL THROW 52701, N'[owningFunctionId] Owning Business Function Code is not a valid selection.', 1;
    DECLARE @r_owningDepartmentId BIGINT = TRY_CONVERT(BIGINT, @f_owningDepartmentId);
    IF @f_owningDepartmentId IS NOT NULL AND @r_owningDepartmentId IS NULL THROW 52701, N'[owningDepartmentId] Owning Department Code is not a valid selection.', 1;
    DECLARE @r_productOwnerPersonId BIGINT = TRY_CONVERT(BIGINT, @f_productOwnerPersonId);
    IF @f_productOwnerPersonId IS NOT NULL AND @r_productOwnerPersonId IS NULL THROW 52701, N'[productOwnerPersonId] Product Owner Person Code is not a valid selection.', 1;
    DECLARE @r_legalEntityId BIGINT = TRY_CONVERT(BIGINT, @f_legalEntityId);
    IF @f_legalEntityId IS NOT NULL AND @r_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Applicable Legal Entity Code is not a valid selection.', 1;
    DECLARE @d_launchDate DATE = TRY_CONVERT(DATE, LEFT(@f_launchDate, 10), 23);
    IF @f_launchDate IS NOT NULL AND @d_launchDate IS NULL THROW 52701, N'[launchDate] Launch Date must be a date (yyyy-mm-dd).', 1;
    DECLARE @d_withdrawalDate DATE = TRY_CONVERT(DATE, LEFT(@f_withdrawalDate, 10), 23);
    IF @f_withdrawalDate IS NOT NULL AND @d_withdrawalDate IS NULL THROW 52701, N'[withdrawalDate] Withdrawal Date must be a date (yyyy-mm-dd).', 1;

    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).
    IF @f_productCode IS NULL THROW 52701, N'[productCode] Product / Service Code is required.', 1;
    IF @f_productName IS NULL THROW 52701, N'[productName] Product / Service Name is required.', 1;
    IF @f_productCategory IS NULL THROW 52701, N'[productCategory] Product Category is required.', 1;
    IF @f_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Applicable Legal Entity Code is required.', 1;
    IF @f_productStatus IS NULL THROW 52701, N'[productStatus] Product Status is required.', 1;
    IF LEN(@f_productCode) > 80 THROW 52701, N'[productCode] Product / Service Code cannot be longer than 80 characters.', 1;
    IF LEN(@f_productName) > 200 THROW 52701, N'[productName] Product / Service Name cannot be longer than 200 characters.', 1;
    IF LEN(@f_schemeVariant) > 200 THROW 52701, N'[schemeVariant] Scheme / Variant Name cannot be longer than 200 characters.', 1;
    IF LEN(@f_customerSegment) > 200 THROW 52701, N'[customerSegment] Customer Segment cannot be longer than 200 characters.', 1;
    IF LEN(@f_regulatoryClassification) > 400 THROW 52701, N'[regulatoryClassification] Regulatory Classification cannot be longer than 400 characters.', 1;
    IF @d_launchDate IS NOT NULL AND @d_withdrawalDate IS NOT NULL AND @d_withdrawalDate < @d_launchDate THROW 52701, N'[withdrawalDate] Withdrawal Date cannot be before Launch Date.', 1;

    -- Controlled values (15 Masters & Codes). A value that is not on the list
    -- is accepted only when it is the value the record already holds, so an
    -- older record can still be saved without being forced to change it.
    IF @f_productCategory IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ProductCategory' AND m.value_label = @f_productCategory AND m.status = N'Active')
            SELECT @f_productCategory = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ProductCategory' AND m.value_label = @f_productCategory;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_product_service WHERE product_service_id = @id AND product_category = @f_productCategory)
            THROW 52702, N'[productCategory] Product Category: the value is not in the approved list (ProductCategory).', 1;
    END
    IF @f_securedUnsecured IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'SecuredUnsecured' AND m.value_label = @f_securedUnsecured AND m.status = N'Active')
            SELECT @f_securedUnsecured = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'SecuredUnsecured' AND m.value_label = @f_securedUnsecured;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_product_service WHERE product_service_id = @id AND secured_unsecured = @f_securedUnsecured)
            THROW 52702, N'[securedUnsecured] Secured / Unsecured (if applicable): the value is not in the approved list (SecuredUnsecured).', 1;
    END
    IF @f_productStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ProductStatus' AND m.value_label = @f_productStatus AND m.status = N'Active')
            SELECT @f_productStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ProductStatus' AND m.value_label = @f_productStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_product_service WHERE product_service_id = @id AND status = @f_productStatus)
            THROW 52702, N'[productStatus] Product Status: the value is not in the approved list (ProductStatus).', 1;
    END

    DECLARE @le BIGINT = @r_legalEntityId;
    IF @le IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @le) THROW 52703, N'[legalEntityId] The selected Legal Entity does not exist.', 1;
    IF @id > 0 AND EXISTS (SELECT 1 FROM grac_practice.organization_product_service WHERE product_service_id = @id AND organization_id <> @le)
       AND EXISTS (SELECT 1 FROM grac_practice.organization_product_service WHERE product_service_id = @id AND organization_id IS NOT NULL)
        THROW 52703, N'[legalEntityId] A Product / Service cannot be moved to another Legal Entity: other records refer to it there. Mark it Inactive and create it in the other Legal Entity.', 1;
    IF @allowed_legal_entity_ids IS NOT NULL AND (@le IS NULL OR @le NOT IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[legalEntityId] You can only maintain records of your own Legal Entities.', 1;

    -- References: the record must exist (and belong where the field says).
    IF @r_owningFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @r_owningFunctionId) THROW 52703, N'[owningFunctionId] Owning Business Function Code: the selected record does not exist.', 1;
    IF @r_owningFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function x WHERE x.business_function_id = @r_owningFunctionId AND x.organization_id = @le)
        THROW 52703, N'[owningFunctionId] Owning Business Function Code must belong to the same Legal Entity.', 1;
    IF @r_owningDepartmentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE department_id = @r_owningDepartmentId) THROW 52703, N'[owningDepartmentId] Owning Department Code: the selected record does not exist.', 1;
    IF @r_owningDepartmentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department x WHERE x.department_id = @r_owningDepartmentId AND x.organization_id = @le)
        THROW 52703, N'[owningDepartmentId] Owning Department Code must belong to the same Legal Entity.', 1;
    IF @r_productOwnerPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_productOwnerPersonId) THROW 52703, N'[productOwnerPersonId] Product Owner Person Code: the selected record does not exist.', 1;
    IF @r_productOwnerPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_productOwnerPersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[productOwnerPersonId] Product Owner Person Code must belong to the same Organization.', 1;

    -- Unique codes.
    IF EXISTS (SELECT 1 FROM grac_practice.organization_product_service WHERE organization_id = @le AND product_code = @f_productCode AND product_service_id <> @id) THROW 52704, N'[productCode] Product / Service Code is already used in this Legal Entity.', 1;


    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).
    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT product_code, product_name, product_category, scheme_variant, description, owning_function_id, owning_department_id, product_owner_id, organization_id, customer_segment, secured_unsecured, regulatory_classification, launch_dt, withdrawal_dt, status, remarks FROM grac_practice.organization_product_service WHERE product_service_id = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;
    BEGIN TRAN;
    IF @id = 0
    BEGIN
        INSERT grac_practice.organization_product_service (product_code, product_name, product_category, scheme_variant, description, owning_function_id, owning_department_id, product_owner_id, organization_id, customer_segment, secured_unsecured, regulatory_classification, launch_dt, withdrawal_dt, status, remarks, entered_by)
        VALUES (@f_productCode, @f_productName, @f_productCategory, @f_schemeVariant, @f_description, @r_owningFunctionId, @r_owningDepartmentId, @r_productOwnerPersonId, @r_legalEntityId, @f_customerSegment, @f_securedUnsecured, @f_regulatoryClassification, @d_launchDate, @d_withdrawalDate, @f_productStatus, @f_remarks, @actor);
        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_product_service SET product_code = @f_productCode,
               product_name = @f_productName,
               product_category = @f_productCategory,
               scheme_variant = @f_schemeVariant,
               description = @f_description,
               owning_function_id = @r_owningFunctionId,
               owning_department_id = @r_owningDepartmentId,
               product_owner_id = @r_productOwnerPersonId,
               organization_id = @r_legalEntityId,
               customer_segment = @f_customerSegment,
               secured_unsecured = @f_securedUnsecured,
               regulatory_classification = @f_regulatoryClassification,
               launch_dt = @d_launchDate,
               withdrawal_dt = @d_withdrawalDate,
               status = @f_productStatus,
               remarks = @f_remarks,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE product_service_id = @id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/products', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Product / Service saved.' AS Message, @id AS Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_channels_list
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
    SELECT t.channel_id AS Id,
           t.channel_code AS Code,
           t.channel_name AS Name,
           t.status AS Status,
           le.organization_id AS LegalEntityId,
           le.organization_code AS LegalEntityCode,
           le.organization_name AS LegalEntityName,
           le.registry_organization_id AS RegistryOrganizationId,
           ro.organization_code AS RegistryOrganizationCode,
           ro.registered_name AS RegistryOrganizationName,
           t.entered_by AS EnteredBy,
           t.entered_dt AS EnteredDate,
           COALESCE(t.updated_by, t.entered_by) AS UpdatedBy,
           COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate,
           t.channel_code AS ChannelCode,
           t.channel_name AS ChannelName,
           t.channel_type AS ChannelType,
           t.description AS Description,
           t.owning_function_id AS OwningFunctionId,
           j1.function_code AS OwningFunctionCode,
           j1.function_name AS OwningFunctionName,
           t.channel_owner_id AS ChannelOwnerPersonId,
           j2.employee_code AS ChannelOwnerPersonCode,
           j2.employee_name AS ChannelOwnerPersonName,
           t.organization_id AS LegalEntityId,
           j3.organization_code AS LegalEntityCode,
           j3.organization_name AS LegalEntityName,
           t.primary_division_id AS PrimaryOrganizationUnitId,
           j4.division_code AS PrimaryOrganizationUnitCode,
           j4.division_name AS PrimaryOrganizationUnitName,
           t.customer_facing AS CustomerFacing,
           t.operational_hours AS OperationalHours,
           t.geographic_scope AS GeographicScope,
           (SELECT b.product_service_id AS id, x.product_code AS code, x.product_name AS name
         FROM grac_practice.organization_channel_product b JOIN grac_practice.organization_product_service x ON x.product_service_id = b.product_service_id
        WHERE b.channel_id = t.channel_id ORDER BY x.product_code, x.product_name FOR JSON PATH) AS ProductsSupported,
           (SELECT b.process_id AS id, x.process_code AS code, x.process_name AS name
         FROM grac_practice.organization_channel_process b JOIN grac_practice.organization_dependency_process x ON x.process_id = b.process_id
        WHERE b.channel_id = t.channel_id ORDER BY x.process_code, x.process_name FOR JSON PATH) AS ProcessesSupported,
           t.status AS ChannelStatus,
           t.remarks AS Remarks
      FROM grac_practice.organization_delivery_channel t
      LEFT JOIN grac_practice.organization le ON le.organization_id = t.organization_id
      LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = le.registry_organization_id
      LEFT JOIN grac_practice.organization_business_function j1 ON j1.business_function_id = t.owning_function_id
      LEFT JOIN grac_practice.organization_employee j2 ON j2.employee_id = t.channel_owner_id
      LEFT JOIN grac_practice.organization j3 ON j3.organization_id = t.organization_id
      LEFT JOIN grac_practice.organization_division j4 ON j4.division_id = t.primary_division_id
     WHERE (@id = 0 OR t.channel_id = @id)
       AND (@registry_organization_id = 0 OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL) OR le.registry_organization_id = @registry_organization_id)
       AND (@legal_entity_id = 0 OR le.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR le.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
       AND (@status = N'' OR t.status = @status)
       AND (@search = N'' OR t.channel_code LIKE N'%' + @search + N'%' OR t.channel_name LIKE N'%' + @search + N'%')
     ORDER BY le.organization_name, t.channel_code;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_orgreg_channels_save
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_delivery_channel WHERE channel_id = @id)
        THROW 52705, N'[] The Delivery Channel no longer exists. Reload the list.', 1;

    -- Outside GRAC administration a record of another Legal Entity is out of reach.
    IF @allowed_legal_entity_ids IS NOT NULL AND @id > 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_delivery_channel x WHERE x.channel_id = @id AND x.organization_id IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[] This record belongs to a Legal Entity you do not have access to.', 1;

    -- Raw values (text; OPENJSON so long text is never truncated).
    DECLARE @f_channelCode NVARCHAR(MAX);
    DECLARE @f_channelName NVARCHAR(MAX);
    DECLARE @f_channelType NVARCHAR(MAX);
    DECLARE @f_description NVARCHAR(MAX);
    DECLARE @f_owningFunctionId NVARCHAR(MAX);
    DECLARE @f_channelOwnerPersonId NVARCHAR(MAX);
    DECLARE @f_legalEntityId NVARCHAR(MAX);
    DECLARE @f_primaryOrganizationUnitId NVARCHAR(MAX);
    DECLARE @f_customerFacing NVARCHAR(MAX);
    DECLARE @f_operationalHours NVARCHAR(MAX);
    DECLARE @f_geographicScope NVARCHAR(MAX);
    DECLARE @f_channelStatus NVARCHAR(MAX);
    DECLARE @f_remarks NVARCHAR(MAX);
    SELECT @f_channelCode = NULLIF(LTRIM(RTRIM(j.[channelCode])), N''),
           @f_channelName = NULLIF(LTRIM(RTRIM(j.[channelName])), N''),
           @f_channelType = NULLIF(LTRIM(RTRIM(j.[channelType])), N''),
           @f_description = NULLIF(LTRIM(RTRIM(j.[description])), N''),
           @f_owningFunctionId = NULLIF(LTRIM(RTRIM(j.[owningFunctionId])), N''),
           @f_channelOwnerPersonId = NULLIF(LTRIM(RTRIM(j.[channelOwnerPersonId])), N''),
           @f_legalEntityId = NULLIF(LTRIM(RTRIM(j.[legalEntityId])), N''),
           @f_primaryOrganizationUnitId = NULLIF(LTRIM(RTRIM(j.[primaryOrganizationUnitId])), N''),
           @f_customerFacing = NULLIF(LTRIM(RTRIM(j.[customerFacing])), N''),
           @f_operationalHours = NULLIF(LTRIM(RTRIM(j.[operationalHours])), N''),
           @f_geographicScope = NULLIF(LTRIM(RTRIM(j.[geographicScope])), N''),
           @f_channelStatus = NULLIF(LTRIM(RTRIM(j.[channelStatus])), N''),
           @f_remarks = NULLIF(LTRIM(RTRIM(j.[remarks])), N'')
      FROM OPENJSON(@payload) WITH ([channelCode] NVARCHAR(MAX) N'$.channelCode',
           [channelName] NVARCHAR(MAX) N'$.channelName',
           [channelType] NVARCHAR(MAX) N'$.channelType',
           [description] NVARCHAR(MAX) N'$.description',
           [owningFunctionId] NVARCHAR(MAX) N'$.owningFunctionId',
           [channelOwnerPersonId] NVARCHAR(MAX) N'$.channelOwnerPersonId',
           [legalEntityId] NVARCHAR(MAX) N'$.legalEntityId',
           [primaryOrganizationUnitId] NVARCHAR(MAX) N'$.primaryOrganizationUnitId',
           [customerFacing] NVARCHAR(MAX) N'$.customerFacing',
           [operationalHours] NVARCHAR(MAX) N'$.operationalHours',
           [geographicScope] NVARCHAR(MAX) N'$.geographicScope',
           [channelStatus] NVARCHAR(MAX) N'$.channelStatus',
           [remarks] NVARCHAR(MAX) N'$.remarks') j;

    DECLARE @r_owningFunctionId BIGINT = TRY_CONVERT(BIGINT, @f_owningFunctionId);
    IF @f_owningFunctionId IS NOT NULL AND @r_owningFunctionId IS NULL THROW 52701, N'[owningFunctionId] Owning Business Function Code is not a valid selection.', 1;
    DECLARE @r_channelOwnerPersonId BIGINT = TRY_CONVERT(BIGINT, @f_channelOwnerPersonId);
    IF @f_channelOwnerPersonId IS NOT NULL AND @r_channelOwnerPersonId IS NULL THROW 52701, N'[channelOwnerPersonId] Channel Owner Person Code is not a valid selection.', 1;
    DECLARE @r_legalEntityId BIGINT = TRY_CONVERT(BIGINT, @f_legalEntityId);
    IF @f_legalEntityId IS NOT NULL AND @r_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Applicable Legal Entity Code is not a valid selection.', 1;
    DECLARE @r_primaryOrganizationUnitId BIGINT = TRY_CONVERT(BIGINT, @f_primaryOrganizationUnitId);
    IF @f_primaryOrganizationUnitId IS NOT NULL AND @r_primaryOrganizationUnitId IS NULL THROW 52701, N'[primaryOrganizationUnitId] Primary Organization Unit Code is not a valid selection.', 1;

    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).
    IF @f_channelCode IS NULL THROW 52701, N'[channelCode] Channel Code is required.', 1;
    IF @f_channelName IS NULL THROW 52701, N'[channelName] Channel Name is required.', 1;
    IF @f_channelType IS NULL THROW 52701, N'[channelType] Channel Type is required.', 1;
    IF @f_legalEntityId IS NULL THROW 52701, N'[legalEntityId] Applicable Legal Entity Code is required.', 1;
    IF @f_customerFacing IS NULL THROW 52701, N'[customerFacing] Customer-facing? is required.', 1;
    IF @f_channelStatus IS NULL THROW 52701, N'[channelStatus] Channel Status is required.', 1;
    IF LEN(@f_channelCode) > 80 THROW 52701, N'[channelCode] Channel Code cannot be longer than 80 characters.', 1;
    IF LEN(@f_channelName) > 200 THROW 52701, N'[channelName] Channel Name cannot be longer than 200 characters.', 1;
    IF LEN(@f_operationalHours) > 300 THROW 52701, N'[operationalHours] Operational Hours / Availability cannot be longer than 300 characters.', 1;
    IF LEN(@f_geographicScope) > 300 THROW 52701, N'[geographicScope] Geographic Scope cannot be longer than 300 characters.', 1;

    -- Controlled values (15 Masters & Codes). A value that is not on the list
    -- is accepted only when it is the value the record already holds, so an
    -- older record can still be saved without being forced to change it.
    IF @f_channelType IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ChannelType' AND m.value_label = @f_channelType AND m.status = N'Active')
            SELECT @f_channelType = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ChannelType' AND m.value_label = @f_channelType;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_delivery_channel WHERE channel_id = @id AND channel_type = @f_channelType)
            THROW 52702, N'[channelType] Channel Type: the value is not in the approved list (ChannelType).', 1;
    END
    IF @f_customerFacing IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_customerFacing AND m.status = N'Active')
            SELECT @f_customerFacing = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'YesNo' AND m.value_label = @f_customerFacing;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_delivery_channel WHERE channel_id = @id AND customer_facing = @f_customerFacing)
            THROW 52702, N'[customerFacing] Customer-facing?: the value is not in the approved list (YesNo).', 1;
    END
    IF @f_channelStatus IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ChannelStatus' AND m.value_label = @f_channelStatus AND m.status = N'Active')
            SELECT @f_channelStatus = m.value_label FROM grac_practice.org_registry_master_value m WHERE m.master_group = N'ChannelStatus' AND m.value_label = @f_channelStatus;
        ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_delivery_channel WHERE channel_id = @id AND status = @f_channelStatus)
            THROW 52702, N'[channelStatus] Channel Status: the value is not in the approved list (ChannelStatus).', 1;
    END

    DECLARE @le BIGINT = @r_legalEntityId;
    IF @le IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @le) THROW 52703, N'[legalEntityId] The selected Legal Entity does not exist.', 1;
    IF @id > 0 AND EXISTS (SELECT 1 FROM grac_practice.organization_delivery_channel WHERE channel_id = @id AND organization_id <> @le)
       AND EXISTS (SELECT 1 FROM grac_practice.organization_delivery_channel WHERE channel_id = @id AND organization_id IS NOT NULL)
        THROW 52703, N'[legalEntityId] A Delivery Channel cannot be moved to another Legal Entity: other records refer to it there. Mark it Inactive and create it in the other Legal Entity.', 1;
    IF @allowed_legal_entity_ids IS NOT NULL AND (@le IS NULL OR @le NOT IN (SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a))
        THROW 52707, N'[legalEntityId] You can only maintain records of your own Legal Entities.', 1;

    -- References: the record must exist (and belong where the field says).
    IF @r_owningFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id = @r_owningFunctionId) THROW 52703, N'[owningFunctionId] Owning Business Function Code: the selected record does not exist.', 1;
    IF @r_owningFunctionId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function x WHERE x.business_function_id = @r_owningFunctionId AND x.organization_id = @le)
        THROW 52703, N'[owningFunctionId] Owning Business Function Code must belong to the same Legal Entity.', 1;
    IF @r_channelOwnerPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @r_channelOwnerPersonId) THROW 52703, N'[channelOwnerPersonId] Channel Owner Person Code: the selected record does not exist.', 1;
    IF @r_channelOwnerPersonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee x JOIN grac_practice.organization xl ON xl.organization_id = x.organization_id
                        JOIN grac_practice.organization me ON me.organization_id = @le
                       WHERE x.employee_id = @r_channelOwnerPersonId AND (xl.organization_id = me.organization_id
                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))
        THROW 52703, N'[channelOwnerPersonId] Channel Owner Person Code must belong to the same Organization.', 1;
    IF @r_primaryOrganizationUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @r_primaryOrganizationUnitId) THROW 52703, N'[primaryOrganizationUnitId] Primary Organization Unit Code: the selected record does not exist.', 1;
    IF @r_primaryOrganizationUnitId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division x WHERE x.division_id = @r_primaryOrganizationUnitId AND x.organization_id = @le)
        THROW 52703, N'[primaryOrganizationUnitId] Primary Organization Unit Code must belong to the same Legal Entity.', 1;
    DECLARE @m_productsSupported TABLE (v BIGINT NOT NULL PRIMARY KEY);
    IF ISJSON(JSON_QUERY(@payload, N'$.productsSupported')) = 1
        INSERT @m_productsSupported(v) SELECT DISTINCT TRY_CONVERT(BIGINT, j.[value]) FROM OPENJSON(@payload, N'$.productsSupported') j
         WHERE TRY_CONVERT(BIGINT, j.[value]) IS NOT NULL;
    IF EXISTS (SELECT 1 FROM @m_productsSupported m WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_product_service x WHERE x.product_service_id = m.v AND x.organization_id = @le))
        THROW 52703, N'[productsSupported] Products / Services Supported (codes): every selection must exist in the same Legal Entity.', 1;
    DECLARE @m_processesSupported TABLE (v BIGINT NOT NULL PRIMARY KEY);
    IF ISJSON(JSON_QUERY(@payload, N'$.processesSupported')) = 1
        INSERT @m_processesSupported(v) SELECT DISTINCT TRY_CONVERT(BIGINT, j.[value]) FROM OPENJSON(@payload, N'$.processesSupported') j
         WHERE TRY_CONVERT(BIGINT, j.[value]) IS NOT NULL;
    IF EXISTS (SELECT 1 FROM @m_processesSupported m WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process x WHERE x.process_id = m.v AND x.organization_id = @le))
        THROW 52703, N'[processesSupported] Processes Supported (codes): every selection must exist in the same Legal Entity.', 1;

    -- Unique codes.
    IF EXISTS (SELECT 1 FROM grac_practice.organization_delivery_channel WHERE organization_id = @le AND channel_code = @f_channelCode AND channel_id <> @id) THROW 52704, N'[channelCode] Channel Code is already used in this Legal Entity.', 1;


    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).
    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT channel_code, channel_name, channel_type, description, owning_function_id, channel_owner_id, organization_id, primary_division_id, customer_facing, operational_hours, geographic_scope, status, remarks FROM grac_practice.organization_delivery_channel WHERE channel_id = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;
    BEGIN TRAN;
    IF @id = 0
    BEGIN
        INSERT grac_practice.organization_delivery_channel (channel_code, channel_name, channel_type, description, owning_function_id, channel_owner_id, organization_id, primary_division_id, customer_facing, operational_hours, geographic_scope, status, remarks, entered_by)
        VALUES (@f_channelCode, @f_channelName, @f_channelType, @f_description, @r_owningFunctionId, @r_channelOwnerPersonId, @r_legalEntityId, @r_primaryOrganizationUnitId, @f_customerFacing, @f_operationalHours, @f_geographicScope, @f_channelStatus, @f_remarks, @actor);
        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_delivery_channel SET channel_code = @f_channelCode,
               channel_name = @f_channelName,
               channel_type = @f_channelType,
               description = @f_description,
               owning_function_id = @r_owningFunctionId,
               channel_owner_id = @r_channelOwnerPersonId,
               organization_id = @r_legalEntityId,
               primary_division_id = @r_primaryOrganizationUnitId,
               customer_facing = @f_customerFacing,
               operational_hours = @f_operationalHours,
               geographic_scope = @f_geographicScope,
               status = @f_channelStatus,
               remarks = @f_remarks,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE channel_id = @id;
    END
    IF JSON_QUERY(@payload, N'$.productsSupported') IS NOT NULL
    BEGIN
        DELETE b FROM grac_practice.organization_channel_product b WHERE b.channel_id = @id AND NOT EXISTS (SELECT 1 FROM @m_productsSupported m WHERE m.v = b.product_service_id);
        INSERT grac_practice.organization_channel_product (channel_id, product_service_id, entered_by)
        SELECT @id, m.v, @actor FROM @m_productsSupported m
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_channel_product b WHERE b.channel_id = @id AND b.product_service_id = m.v);
    END
    IF JSON_QUERY(@payload, N'$.processesSupported') IS NOT NULL
    BEGIN
        DELETE b FROM grac_practice.organization_channel_process b WHERE b.channel_id = @id AND NOT EXISTS (SELECT 1 FROM @m_processesSupported m WHERE m.v = b.process_id);
        INSERT grac_practice.organization_channel_process (channel_id, process_id, entered_by)
        SELECT @id, m.v, @actor FROM @m_processesSupported m
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_channel_process b WHERE b.channel_id = @id AND b.process_id = m.v);
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/channels', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Delivery Channel saved.' AS Message, @id AS Id;
END;
GO

SET NOEXEC OFF;
GO
PRINT '571 complete: Organization Registry procedures created. Restart the Api is NOT required (no shim probe).';
GO
