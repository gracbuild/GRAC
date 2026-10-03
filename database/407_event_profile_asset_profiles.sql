-- =====================================================================
-- 407 Profile Type: People Profile and Asset Profile
--
-- WHAT AND WHY
-- ------------
-- The Profile page (Event Profiles, 329/330) delivered People profiles
-- only. 329 was built so a second kind is "a seed plus a UI toggle":
-- event_profile.subject_entity already discriminates EMPLOYEE / ASSET and
-- the dimension master is tagged per subject. This migration turns the
-- Asset kind on:
--
--   * ASSET dimensions seeded into the EXISTING dimension master, reading
--     the EXISTING masters (no new master tables, nothing hard-coded):
--         ASSET_LOCATION     organization_location              (org)
--         ASSET_CATEGORY     dependency_asset_category_master   (239)
--         ASSET_SUBCATEGORY  dependency_asset_subcategory_master (parent: category)
--         ASSET_TYPE         dependency_asset_type_master        (parent: sub category)
--     matched against organization_dependency_asset.location_id /
--     asset_category_id / asset_subcategory_id / asset_type_id.
--
--   * event_profile_dimension_master + source_parent_column /
--     parent_dimension_code, so the picker can cascade
--     Category -> Sub Category -> Type from data, not from code.
--
--   * event_profile.profile_type -- computed from subject_entity
--     (EMPLOYEE -> People, ASSET -> Asset). One source of truth: the type
--     is stored once (subject_entity) and every existing row is already
--     People, so existing profiles need no data change.
--
--   * vw_pm_event_profile_subject_attribute + four ASSET arms. The
--     generic matcher fn_pm_event_profile_matches is unchanged.
--
--   * Procedures (CREATE OR ALTER of the latest bodies, 330 / 343, with
--     only the 407 changes marked "407:" inside):
--         sp_event_profile_dimension_list    + ParentDimensionCode
--         sp_event_profile_dimension_values  + ParentId, is_active filter
--         sp_event_profile_list              + ALL filter, ProfileType
--         sp_event_profile_get               + ProfileType
--         sp_event_profile_save              type fixed once saved (67438)
--         sp_event_profile_preview_members   counts assets for an Asset profile
--         sp_event_obligation_coverage_list  PROFILE counts both kinds
--         sp_event_obligation_raise          an asset resolves its Asset
--                                            profiles beside its category
--
-- BACKEND ENFORCEMENT OF THE TYPE
-- -------------------------------
--   * save already joins criteria to dimensions of the profile's own
--     subject_entity (330) -- an Asset criterion on a People profile, or
--     the reverse, is refused there.
--   * save now refuses to change the type of a saved profile (67438).
--   * the matcher only evaluates a profile against its own subject kind,
--     so a People profile can never fire for an asset and vice versa.
--
-- Re-runnable. Depends on 329, 330, 239 (asset taxonomy), 343.
-- Rollback: 407_event_profile_asset_profiles_rollback.sql.
-- API: restart the API after running (shim/procedure metadata cache).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- =====================================================================
-- Prerequisites
-- =====================================================================
IF OBJECT_ID('grac_practice.event_profile','U') IS NULL
   OR OBJECT_ID('grac_practice.event_profile_dimension_master','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_pm_event_profile_matches','IF') IS NULL
   OR OBJECT_ID('grac_practice.sp_event_profile_save','P') IS NULL
BEGIN
    RAISERROR('407: run 329_event_profile_schema.sql and 330_event_profile_procs.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_event_obligation_raise','P') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V') IS NULL
BEGIN
    RAISERROR('407: run 343_event_obligation_procs_local_identity.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.dependency_asset_category_master','U') IS NULL
   OR OBJECT_ID('grac_practice.dependency_asset_subcategory_master','U') IS NULL
   OR OBJECT_ID('grac_practice.dependency_asset_type_master','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','asset_subcategory_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','asset_type_id')        IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','location_id')          IS NULL
BEGIN
    RAISERROR('407: asset taxonomy missing. Run 239_asset_taxonomy_schema.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 0a. Cascade columns on the dimension master
--
--     source_parent_column  -- column on source_table holding the parent
--                              value id (subcategory -> asset_category_id)
--     parent_dimension_code -- the dimension that parent id belongs to
--
--     Both NULL for every existing dimension: nothing cascades today.
-- =====================================================================
IF COL_LENGTH('grac_practice.event_profile_dimension_master','source_parent_column') IS NULL
    ALTER TABLE grac_practice.event_profile_dimension_master
        ADD source_parent_column NVARCHAR(128) NULL;
GO
IF COL_LENGTH('grac_practice.event_profile_dimension_master','parent_dimension_code') IS NULL
    ALTER TABLE grac_practice.event_profile_dimension_master
        ADD parent_dimension_code NVARCHAR(40) NULL;
GO

-- =====================================================================
-- 0b. event_profile.profile_type (computed, not persisted)
--
--     The list's "Profile Type" column and filter. Computed so it can
--     never disagree with subject_entity, which the matcher, the raise
--     and every existing row already use.
-- =====================================================================
IF COL_LENGTH('grac_practice.event_profile','profile_type') IS NULL
    ALTER TABLE grac_practice.event_profile
        ADD profile_type AS (CAST(CASE subject_entity
                                      WHEN N'EMPLOYEE' THEN N'People'
                                      WHEN N'ASSET'    THEN N'Asset'
                                      ELSE subject_entity END AS NVARCHAR(60)));
GO

-- =====================================================================
-- 0c. ASSET dimensions -- seeded the way 329 seeds the EMPLOYEE ones
--     (MERGE with UPDATE so a re-run corrects a drifted row).
--
--     employee_match_column is 329's name for "the subject column a
--     picked value is compared against"; for ASSET rows it names the
--     organization_dependency_asset column. The matching itself is done
--     by the view arms below, exactly as for EMPLOYEE.
--
--     Location reuses the organisation's own Location master
--     (organization_location, org-scoped). Category / Sub Category /
--     Type are the shared asset taxonomy (239) -- global, retired with
--     is_active, which the values procedure now honours.
-- =====================================================================
MERGE grac_practice.event_profile_dimension_master AS t
USING (VALUES
    (N'ASSET_LOCATION',    N'Location',           N'ASSET', N'ID',
     N'grac_practice.organization_location',               N'location_id',       N'location_name',       N'organization_id',
     NULL,                NULL,
     N'location_id',          0, 10, 1),
    (N'ASSET_CATEGORY',    N'Asset Category',     N'ASSET', N'ID',
     N'grac_practice.dependency_asset_category_master',    N'asset_category_id', N'asset_category_name', NULL,
     NULL,                NULL,
     N'asset_category_id',    0, 20, 1),
    (N'ASSET_SUBCATEGORY', N'Asset Sub Category', N'ASSET', N'ID',
     N'grac_practice.dependency_asset_subcategory_master', N'subcategory_id',    N'subcategory_name',    NULL,
     N'asset_category_id', N'ASSET_CATEGORY',
     N'asset_subcategory_id', 0, 30, 1),
    (N'ASSET_TYPE',        N'Asset Type',         N'ASSET', N'ID',
     N'grac_practice.dependency_asset_type_master',        N'asset_type_id',     N'asset_type_name',     NULL,
     N'subcategory_id',    N'ASSET_SUBCATEGORY',
     N'asset_type_id',        0, 40, 1)
) AS src(dimension_code, dimension_name, subject_entity, value_kind,
         source_table, source_id_column, source_name_column, source_org_column,
         source_parent_column, parent_dimension_code,
         employee_match_column, is_multi_valued, display_order, is_active)
ON t.dimension_code = src.dimension_code
WHEN MATCHED THEN UPDATE SET
    dimension_name        = src.dimension_name,
    subject_entity        = src.subject_entity,
    value_kind            = src.value_kind,
    source_table          = src.source_table,
    source_id_column      = src.source_id_column,
    source_name_column    = src.source_name_column,
    source_org_column     = src.source_org_column,
    source_parent_column  = src.source_parent_column,
    parent_dimension_code = src.parent_dimension_code,
    employee_match_column = src.employee_match_column,
    is_multi_valued       = src.is_multi_valued,
    display_order         = src.display_order,
    is_active             = src.is_active,
    updated_by            = 'migration-407',
    updated_dt            = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (dimension_code, dimension_name, subject_entity, value_kind,
     source_table, source_id_column, source_name_column, source_org_column,
     source_parent_column, parent_dimension_code,
     employee_match_column, is_multi_valued, display_order, is_active, entered_by)
VALUES
    (src.dimension_code, src.dimension_name, src.subject_entity, src.value_kind,
     src.source_table, src.source_id_column, src.source_name_column, src.source_org_column,
     src.source_parent_column, src.parent_dimension_code,
     src.employee_match_column, src.is_multi_valued, src.display_order, src.is_active, 'migration-407');
GO
PRINT '407: ASSET profile dimensions seeded.';
GO

-- =====================================================================
-- 1. vw_pm_event_profile_subject_attribute (330 body + ASSET arms)
--
--    The EMPLOYEE arms are 330's, unchanged. fn_pm_event_profile_matches
--    (2. in 330) is generic over this view and needs no change.
-- =====================================================================
CREATE OR ALTER VIEW grac_practice.vw_pm_event_profile_subject_attribute
AS
    -- LOCATION
    SELECT e.organization_id,
           CAST(N'EMPLOYEE' AS NVARCHAR(60))  AS subject_entity,
           e.employee_id                      AS subject_record_id,
           CAST(N'LOCATION' AS NVARCHAR(40))  AS dimension_code,
           CAST(e.location_id AS BIGINT)      AS value_id,
           CAST(NULL AS NVARCHAR(200))        AS value_text
    FROM   grac_practice.organization_employee e
    WHERE  e.location_id IS NOT NULL

    UNION ALL
    -- DEPARTMENT
    SELECT e.organization_id, CAST(N'EMPLOYEE' AS NVARCHAR(60)), e.employee_id,
           CAST(N'DEPARTMENT' AS NVARCHAR(40)),
           CAST(e.department_id AS BIGINT), CAST(NULL AS NVARCHAR(200))
    FROM   grac_practice.organization_employee e
    WHERE  e.department_id IS NOT NULL

    UNION ALL
    -- BUSINESS_FUNCTION (dimension seeded inactive; the arm is here so
    -- turning it on is an UPDATE to one master row)
    SELECT e.organization_id, CAST(N'EMPLOYEE' AS NVARCHAR(60)), e.employee_id,
           CAST(N'BUSINESS_FUNCTION' AS NVARCHAR(40)),
           CAST(e.business_function_id AS BIGINT), CAST(NULL AS NVARCHAR(200))
    FROM   grac_practice.organization_employee e
    WHERE  e.business_function_id IS NOT NULL

    UNION ALL
    -- DESIGNATION -- free text, no master. Trimmed here so a stray space
    -- in the employee record cannot silently break a match.
    SELECT e.organization_id, CAST(N'EMPLOYEE' AS NVARCHAR(60)), e.employee_id,
           CAST(N'DESIGNATION' AS NVARCHAR(40)),
           CAST(NULL AS BIGINT),
           CAST(LTRIM(RTRIM(e.designation)) AS NVARCHAR(200))
    FROM   grac_practice.organization_employee e
    WHERE  NULLIF(LTRIM(RTRIM(e.designation)), N'') IS NOT NULL

    UNION ALL
    -- ORG_ROLE -- multi-valued, and the two role sources must stay
    -- unioned, so this reuses 131's function rather than joining either
    -- table directly.
    SELECT e.organization_id, CAST(N'EMPLOYEE' AS NVARCHAR(60)), e.employee_id,
           CAST(N'ORG_ROLE' AS NVARCHAR(40)),
           r.role_id, CAST(NULL AS NVARCHAR(200))
    FROM        grac_practice.organization_employee e
    CROSS APPLY grac_practice.fn_pm_employee_role_ids(e.employee_id) r

    -- -----------------------------------------------------------------
    -- 407: ASSET arms. One per ASSET dimension, reading the asset record
    -- the Asset screen maintains. NULL attributes produce no row, the
    -- same rule the EMPLOYEE arms follow.
    -- -----------------------------------------------------------------
    UNION ALL
    -- ASSET_LOCATION
    SELECT a.organization_id, CAST(N'ASSET' AS NVARCHAR(60)), a.asset_id,
           CAST(N'ASSET_LOCATION' AS NVARCHAR(40)),
           CAST(a.location_id AS BIGINT), CAST(NULL AS NVARCHAR(200))
    FROM   grac_practice.organization_dependency_asset a
    WHERE  a.location_id IS NOT NULL

    UNION ALL
    -- ASSET_CATEGORY
    SELECT a.organization_id, CAST(N'ASSET' AS NVARCHAR(60)), a.asset_id,
           CAST(N'ASSET_CATEGORY' AS NVARCHAR(40)),
           CAST(a.asset_category_id AS BIGINT), CAST(NULL AS NVARCHAR(200))
    FROM   grac_practice.organization_dependency_asset a
    WHERE  a.asset_category_id IS NOT NULL

    UNION ALL
    -- ASSET_SUBCATEGORY
    SELECT a.organization_id, CAST(N'ASSET' AS NVARCHAR(60)), a.asset_id,
           CAST(N'ASSET_SUBCATEGORY' AS NVARCHAR(40)),
           CAST(a.asset_subcategory_id AS BIGINT), CAST(NULL AS NVARCHAR(200))
    FROM   grac_practice.organization_dependency_asset a
    WHERE  a.asset_subcategory_id IS NOT NULL

    UNION ALL
    -- ASSET_TYPE
    SELECT a.organization_id, CAST(N'ASSET' AS NVARCHAR(60)), a.asset_id,
           CAST(N'ASSET_TYPE' AS NVARCHAR(40)),
           CAST(a.asset_type_id AS BIGINT), CAST(NULL AS NVARCHAR(200))
    FROM   grac_practice.organization_dependency_asset a
    WHERE  a.asset_type_id IS NOT NULL;
GO

-- 3. sp_event_profile_dimension_list (330 body + ParentDimensionCode)
CREATE OR ALTER PROCEDURE grac_practice.sp_event_profile_dimension_list
    @subject_entity NVARCHAR(60) = N'EMPLOYEE'
AS
BEGIN
    SET NOCOUNT ON;

    IF @subject_entity NOT IN (N'EMPLOYEE', N'ASSET')
        SET @subject_entity = N'EMPLOYEE';

    SELECT dimension_id          AS DimensionId,
           dimension_code        AS DimensionCode,
           dimension_name        AS DimensionName,
           subject_entity        AS SubjectEntity,
           value_kind            AS ValueKind,
           is_multi_valued       AS IsMultiValued,
           -- The screen renders a picker when there is a source to pick
           -- from, and a free-text entry otherwise.
           CAST(CASE WHEN source_table IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS HasValueSource,
           display_order         AS DisplayOrder,
           -- 407: the criterion this one cascades under (Asset Category ->
           -- Sub Category -> Type). NULL for an independent criterion.
           parent_dimension_code AS ParentDimensionCode
    FROM   grac_practice.event_profile_dimension_master
    WHERE  is_active      = 1
      AND  subject_entity = @subject_entity
    ORDER BY display_order, dimension_id;
END;
GO

-- 4. sp_event_profile_dimension_values (330 body + ParentId, is_active)
CREATE OR ALTER PROCEDURE grac_practice.sp_event_profile_dimension_values
    @organization_id BIGINT,
    @dimension_code  NVARCHAR(40),
    @search          NVARCHAR(200) = NULL,
    @page_size       INT           = 200
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 67400, 'sp_event_profile_dimension_values: organization_id is required.', 1;
    IF @dimension_code IS NULL
        THROW 67401, 'sp_event_profile_dimension_values: dimension_code is required.', 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 200;
    IF @page_size > 1000                    SET @page_size = 1000;

    DECLARE @value_kind   NVARCHAR(10),
            @src_table    NVARCHAR(200),
            @src_id       NVARCHAR(128),
            @src_name     NVARCHAR(128),
            @src_org      NVARCHAR(128),
            @emp_col      NVARCHAR(128),
            @src_parent   NVARCHAR(128),
            @is_active    BIT;

    SELECT @value_kind = value_kind,
           @src_table  = source_table,
           @src_id     = source_id_column,
           @src_name   = source_name_column,
           @src_org    = source_org_column,
           @emp_col    = employee_match_column,
           @src_parent = source_parent_column,
           @is_active  = is_active
    FROM   grac_practice.event_profile_dimension_master
    WHERE  dimension_code = @dimension_code;

    IF @value_kind IS NULL
        THROW 67402, 'sp_event_profile_dimension_values: unknown dimension_code.', 1;
    IF @is_active = 0
        THROW 67403, 'sp_event_profile_dimension_values: this dimension is not active.', 1;

    DECLARE @like NVARCHAR(220) = CASE
        WHEN @search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0 THEN NULL
        ELSE N'%' + @search + N'%' END;

    -- -----------------------------------------------------------------
    -- TEXT dimension with no master: the values in use are the values on
    -- offer. Returning nothing here would make the dimension unusable,
    -- and inventing a master the product has not agreed to would be
    -- worse.
    -- -----------------------------------------------------------------
    IF @src_table IS NULL
    BEGIN
        IF @emp_col IS NULL
        BEGIN
            SELECT CAST(NULL AS BIGINT) AS Id, CAST(NULL AS NVARCHAR(200)) AS TextValue,
                   CAST(NULL AS NVARCHAR(300)) AS Name, CAST(NULL AS BIGINT) AS ParentId
            WHERE  1 = 0;
            RETURN;
        END;

        -- Only the designation column is reachable this way today; the
        -- identifier still goes through the same verification, because a
        -- future TEXT dimension will use this branch too.
        IF NOT EXISTS (SELECT 1 FROM sys.columns
                        WHERE object_id = OBJECT_ID('grac_practice.organization_employee')
                          AND name = @emp_col)
            THROW 67404, 'sp_event_profile_dimension_values: employee_match_column does not exist.', 1;

        DECLARE @text_sql NVARCHAR(MAX) =
            N'SELECT DISTINCT TOP (@ps)
                     CAST(NULL AS BIGINT)                    AS Id,
                     CAST(LTRIM(RTRIM(e.' + QUOTENAME(@emp_col) + N')) AS NVARCHAR(200)) AS TextValue,
                     CAST(LTRIM(RTRIM(e.' + QUOTENAME(@emp_col) + N')) AS NVARCHAR(300)) AS Name,
                     CAST(NULL AS BIGINT)                    AS ParentId
              FROM   grac_practice.organization_employee e
              WHERE  e.organization_id = @org
                AND  NULLIF(LTRIM(RTRIM(e.' + QUOTENAME(@emp_col) + N')), N'''') IS NOT NULL
                AND  (@lk IS NULL OR e.' + QUOTENAME(@emp_col) + N' LIKE @lk)
              ORDER BY Name;';

        EXEC sp_executesql @text_sql,
             N'@org BIGINT, @lk NVARCHAR(220), @ps INT',
             @org = @organization_id, @lk = @like, @ps = @page_size;
        RETURN;
    END

    -- -----------------------------------------------------------------
    -- ID dimension backed by a master table.
    -- -----------------------------------------------------------------
    IF OBJECT_ID(@src_table, 'U') IS NULL
        THROW 67405, 'sp_event_profile_dimension_values: source_table does not exist.', 1;
    IF @src_id IS NULL OR NOT EXISTS (SELECT 1 FROM sys.columns
                                       WHERE object_id = OBJECT_ID(@src_table) AND name = @src_id)
        THROW 67406, 'sp_event_profile_dimension_values: source_id_column does not exist.', 1;
    IF @src_name IS NULL OR NOT EXISTS (SELECT 1 FROM sys.columns
                                         WHERE object_id = OBJECT_ID(@src_table) AND name = @src_name)
        THROW 67407, 'sp_event_profile_dimension_values: source_name_column does not exist.', 1;
    IF @src_org IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.columns
                                             WHERE object_id = OBJECT_ID(@src_table) AND name = @src_org)
        THROW 67408, 'sp_event_profile_dimension_values: source_org_column does not exist.', 1;

    -- status is filtered only where the source actually has one. Every
    -- org master here does; a future source might not, and a hard-coded
    -- predicate would then fail to compile for it.
    DECLARE @has_status BIT = CASE WHEN EXISTS (
        SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(@src_table) AND name = 'status')
        THEN 1 ELSE 0 END;

    -- 407: the asset taxonomy masters (239) mark retirement with is_active,
    -- not status. Filtered the same way, only where the column exists.
    DECLARE @has_is_active BIT = CASE WHEN EXISTS (
        SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(@src_table) AND name = 'is_active')
        THEN 1 ELSE 0 END;

    -- 407: parent id for a cascading criterion, verified like every other
    -- identifier read from the master row.
    IF @src_parent IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.columns
                                                WHERE object_id = OBJECT_ID(@src_table) AND name = @src_parent)
        THROW 67409, 'sp_event_profile_dimension_values: source_parent_column does not exist.', 1;

    DECLARE @sql NVARCHAR(MAX) =
        N'SELECT TOP (@ps)
                 CAST(s.' + QUOTENAME(@src_id)   + N' AS BIGINT)        AS Id,
                 CAST(NULL AS NVARCHAR(200))                            AS TextValue,
                 CAST(s.' + QUOTENAME(@src_name) + N' AS NVARCHAR(300)) AS Name,
                 ' + CASE WHEN @src_parent IS NOT NULL
                          THEN N'CAST(s.' + QUOTENAME(@src_parent) + N' AS BIGINT)'
                          ELSE N'CAST(NULL AS BIGINT)' END + N'  AS ParentId
          FROM   ' + @src_table + N' s
          WHERE  1 = 1'
      + CASE WHEN @src_org   IS NOT NULL THEN N' AND s.' + QUOTENAME(@src_org) + N' = @org' ELSE N'' END
      + CASE WHEN @has_status = 1        THEN N' AND s.[status] = N''Active''' ELSE N'' END
      + CASE WHEN @has_is_active = 1     THEN N' AND s.[is_active] = 1' ELSE N'' END
      + N' AND (@lk IS NULL OR s.' + QUOTENAME(@src_name) + N' LIKE @lk)
          ORDER BY Name;';

    EXEC sp_executesql @sql,
         N'@org BIGINT, @lk NVARCHAR(220), @ps INT',
         @org = @organization_id, @lk = @like, @ps = @page_size;
END;
GO

-- 5. sp_event_profile_list (330 body + ALL, ProfileType)
CREATE OR ALTER PROCEDURE grac_practice.sp_event_profile_list
    @organization_id BIGINT,
    @subject_entity  NVARCHAR(60)  = N'EMPLOYEE',
    @status          NVARCHAR(30)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 67410, 'sp_event_profile_list: organization_id is required.', 1;
    -- 407: 'ALL' (the Profile Type filter's All) lists both kinds. Any
    -- other unknown value keeps the old EMPLOYEE default, so an existing
    -- caller that sends nothing still sees exactly what it did before.
    IF @subject_entity IS NULL OR @subject_entity NOT IN (N'EMPLOYEE', N'ASSET', N'ALL')
        SET @subject_entity = N'EMPLOYEE';

    DECLARE @size   INT = ISNULL(NULLIF(@page_size, 0), 25);
    DECLARE @offset INT = (ISNULL(NULLIF(@page_number, 0), 1) - 1) * @size;
    DECLARE @like   NVARCHAR(220) = CASE
        WHEN @search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0 THEN NULL
        ELSE N'%' + @search + N'%' END;

    SELECT p.profile_id      AS ProfileId,
           p.organization_id AS OrganizationId,
           p.profile_code    AS ProfileCode,
           p.profile_name    AS ProfileName,
           p.description     AS Description,
           p.subject_entity  AS SubjectEntity,
           p.profile_type    AS ProfileType,
           p.status          AS Status,

           -- "Location: India, Kerala | Department: IT Operations | Role: All"
           STUFF((
               SELECT N' | ' + d.dimension_name + N': '
                      + CASE WHEN c.match_all = 1 THEN N'All'
                             ELSE ISNULL(STUFF((
                                     SELECT N', ' + ISNULL(v.value_label,
                                                ISNULL(v.value_text, CAST(v.value_id AS NVARCHAR(20))))
                                     FROM   grac_practice.event_profile_criteria_value v
                                     WHERE  v.criteria_id = c.criteria_id
                                     ORDER BY v.criteria_value_id
                                     FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''),
                                  N'(none)')
                        END
               FROM   grac_practice.event_profile_criteria c
               JOIN   grac_practice.event_profile_dimension_master d
                      ON d.dimension_id = c.dimension_id
               WHERE  c.profile_id = p.profile_id
               ORDER BY d.display_order, d.dimension_id
               FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 3, N'')
                             AS CriteriaSummary,

           -- Two numbers, for the same reason 130 split them: how many
           -- decisions exist, and how many of them actually apply.
           (SELECT COUNT(1) FROM grac_practice.event_obligation_applicability a
             WHERE a.organization_id = p.organization_id
               AND a.profile_id      = p.profile_id
               AND a.status          = N'Active')                    AS MappedObligationCount,
           (SELECT COUNT(1) FROM grac_practice.event_obligation_applicability a
             WHERE a.organization_id = p.organization_id
               AND a.profile_id      = p.profile_id
               AND a.status          = N'Active'
               AND a.is_applicable   = 1)                            AS ApplicableObligationCount,

           (SELECT COUNT(1) FROM grac_practice.event_profile_criteria c
             WHERE c.profile_id = p.profile_id)                      AS CriteriaCount,

           p.entered_by      AS EnteredBy,
           p.entered_dt      AS EnteredDate,
           p.updated_by      AS UpdatedBy,
           p.updated_dt      AS UpdatedDate,
           COUNT(*) OVER ()  AS TotalRows
    FROM   grac_practice.event_profile p
    WHERE  p.organization_id = @organization_id
      AND  (@subject_entity = N'ALL' OR p.subject_entity = @subject_entity)
      AND  (@status IS NULL OR @status = N'' OR p.status = @status)
      AND  (@like IS NULL OR p.profile_name LIKE @like
                          OR p.profile_code LIKE @like
                          OR ISNULL(p.description, N'') LIKE @like)
    ORDER BY p.profile_name
    OFFSET @offset ROWS FETCH NEXT @size ROWS ONLY;
END;
GO

-- 6. sp_event_profile_get (330 body + ProfileType)
CREATE OR ALTER PROCEDURE grac_practice.sp_event_profile_get
    @organization_id BIGINT,
    @profile_id      BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @profile_id IS NULL
        THROW 67420, 'sp_event_profile_get: organization_id and profile_id are required.', 1;

    SELECT p.profile_id      AS ProfileId,
           p.organization_id AS OrganizationId,
           p.profile_code    AS ProfileCode,
           p.profile_name    AS ProfileName,
           p.description     AS Description,
           p.subject_entity  AS SubjectEntity,
           p.profile_type    AS ProfileType,
           p.status          AS Status,
           p.entered_by      AS EnteredBy,
           p.entered_dt      AS EnteredDate,
           p.updated_by      AS UpdatedBy,
           p.updated_dt      AS UpdatedDate
    FROM   grac_practice.event_profile p
    WHERE  p.profile_id      = @profile_id
      AND  p.organization_id = @organization_id;

    -- One row per criterion VALUE, with the criterion repeated. A
    -- match_all criterion returns exactly one row with a NULL value, so
    -- the caller sees the dimension even though it has no values --
    -- otherwise "All" would be indistinguishable from "not configured".
    SELECT c.criteria_id       AS CriteriaId,
           c.dimension_id      AS DimensionId,
           c.dimension_code    AS DimensionCode,
           d.dimension_name    AS DimensionName,
           d.value_kind        AS ValueKind,
           d.display_order     AS DisplayOrder,
           c.match_all         AS MatchAll,
           v.criteria_value_id AS CriteriaValueId,
           v.value_id          AS ValueId,
           v.value_text        AS ValueText,
           v.value_label       AS ValueLabel
    FROM       grac_practice.event_profile_criteria c
    JOIN       grac_practice.event_profile_dimension_master d
           ON  d.dimension_id = c.dimension_id
    LEFT JOIN  grac_practice.event_profile_criteria_value v
           ON  v.criteria_id = c.criteria_id
    WHERE      c.profile_id      = @profile_id
      AND      c.organization_id = @organization_id
    ORDER BY   d.display_order, d.dimension_id, v.criteria_value_id;
END;
GO

-- 7. sp_event_profile_save (330 body + type is fixed once saved)
CREATE OR ALTER PROCEDURE grac_practice.sp_event_profile_save
    @organization_id BIGINT,
    @profile_json    NVARCHAR(MAX),
    @actor           NVARCHAR(100) = 'api',
    @out_profile_id  BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 67430, 'sp_event_profile_save: organization_id is required.', 1;
    IF @profile_json IS NULL OR ISJSON(@profile_json) = 0
        THROW 67431, 'sp_event_profile_save: profile_json is not a valid JSON document.', 1;

    DECLARE @profile_id     BIGINT,
            @profile_code   NVARCHAR(60),
            @profile_name   NVARCHAR(200),
            @description    NVARCHAR(1000),
            @subject_entity NVARCHAR(60),
            @status         NVARCHAR(30);

    SELECT @profile_id     = j.profileId,
           @profile_code   = LTRIM(RTRIM(j.profileCode)),
           @profile_name   = LTRIM(RTRIM(j.profileName)),
           @description    = j.description,
           @subject_entity = j.subjectEntity,
           @status         = j.status
    FROM OPENJSON(@profile_json)
    WITH (
        profileId     BIGINT         '$.profileId',
        profileCode   NVARCHAR(60)   '$.profileCode',
        profileName   NVARCHAR(200)  '$.profileName',
        description   NVARCHAR(1000) '$.description',
        subjectEntity NVARCHAR(60)   '$.subjectEntity',
        status        NVARCHAR(30)   '$.status'
    ) j;

    IF @profile_name IS NULL OR LEN(@profile_name) = 0
        THROW 67432, 'sp_event_profile_save: profileName is required.', 1;
    -- 407: an update that does not name a type keeps the saved one (so an
    -- older caller can never flip an Asset profile to People by omission);
    -- a new profile with no type is People, exactly as before.
    IF @subject_entity IS NULL OR @subject_entity NOT IN (N'EMPLOYEE', N'ASSET')
        SET @subject_entity = COALESCE(
            (SELECT subject_entity FROM grac_practice.event_profile
              WHERE profile_id = @profile_id AND organization_id = @organization_id),
            N'EMPLOYEE');
    IF @status IS NULL OR @status NOT IN (N'Active', N'Inactive')
        SET @status = N'Active';

    -- A code is required but need not be typed. Derived from the name,
    -- uppercased, non-alphanumerics collapsed to '-', then de-duplicated.
    IF @profile_code IS NULL OR LEN(@profile_code) = 0
    BEGIN
        DECLARE @base NVARCHAR(60) = UPPER(LEFT(@profile_name, 50));
        DECLARE @i INT = 1;
        WHILE @i <= LEN(@base)
        BEGIN
            IF SUBSTRING(@base, @i, 1) NOT LIKE N'[A-Z0-9]'
                SET @base = STUFF(@base, @i, 1, N'-');
            SET @i = @i + 1;
        END
        WHILE CHARINDEX(N'--', @base) > 0 SET @base = REPLACE(@base, N'--', N'-');
        SET @base = NULLIF(LTRIM(RTRIM(@base)), N'');
        IF @base IS NULL SET @base = N'PROFILE';

        SET @profile_code = @base;
        DECLARE @n INT = 1;
        WHILE EXISTS (SELECT 1 FROM grac_practice.event_profile
                       WHERE organization_id = @organization_id
                         AND profile_code    = @profile_code
                         AND (@profile_id IS NULL OR @profile_id = 0 OR profile_id <> @profile_id))
        BEGIN
            SET @n = @n + 1;
            SET @profile_code = LEFT(@base, 55) + N'-' + CAST(@n AS NVARCHAR(5));
        END
    END

    IF EXISTS (SELECT 1 FROM grac_practice.event_profile
                WHERE organization_id = @organization_id
                  AND profile_code    = @profile_code
                  AND (@profile_id IS NULL OR @profile_id = 0 OR profile_id <> @profile_id))
        THROW 67433, 'sp_event_profile_save: a profile with this code already exists in this organization.', 1;

    -- ---- criteria, validated before anything is written ----
    DECLARE @crit TABLE(
        rowid          INT IDENTITY(1,1) PRIMARY KEY,
        dimension_code NVARCHAR(40),
        dimension_id   INT,
        match_all      BIT,
        values_json    NVARCHAR(MAX),
        value_count    INT);

    -- value_count is computed here, through CROSS APPLY, rather than in the
    -- validation below. OPENJSON is a table-valued function: referencing an
    -- outer column from inside a plain subquery is not allowed, so the count
    -- has to be taken where APPLY can see the row. ISNULL guards a criterion
    -- sent with no "values" key at all.
    INSERT INTO @crit(dimension_code, match_all, values_json, value_count)
    SELECT LTRIM(RTRIM(c.dimensionCode)),
           CASE WHEN c.matchAll = 1 THEN 1 ELSE 0 END,
           c.[values],
           vc.n
    FROM OPENJSON(@profile_json, N'$.criteria')
    WITH (
        dimensionCode NVARCHAR(40)  '$.dimensionCode',
        matchAll      BIT           '$.matchAll',
        [values]      NVARCHAR(MAX) '$.values' AS JSON
    ) c
    CROSS APPLY (SELECT COUNT(1) AS n FROM OPENJSON(ISNULL(c.[values], N'[]'))) vc
    WHERE NULLIF(LTRIM(RTRIM(c.dimensionCode)), N'') IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM @crit)
        THROW 67434, 'sp_event_profile_save: at least one criterion is required. A profile with no criteria cannot be told apart from an unfinished one.', 1;

    IF EXISTS (SELECT 1 FROM @crit GROUP BY dimension_code HAVING COUNT(1) > 1)
        THROW 67435, 'sp_event_profile_save: a dimension may appear only once. Put multiple values in that criterion instead.', 1;

    UPDATE c
       SET dimension_id = d.dimension_id
      FROM @crit c
      JOIN grac_practice.event_profile_dimension_master d
           ON  d.dimension_code  = c.dimension_code
          AND  d.subject_entity  = @subject_entity
          AND  d.is_active       = 1;

    IF EXISTS (SELECT 1 FROM @crit WHERE dimension_id IS NULL)
    BEGIN
        DECLARE @bad NVARCHAR(400) = (
            SELECT TOP 1 dimension_code FROM @crit WHERE dimension_id IS NULL);
        RAISERROR('sp_event_profile_save: unknown or inactive criterion dimension "%s" for this subject entity.', 16, 1, @bad);
        RETURN;
    END

    -- A constrained criterion with no values matches nobody, which turns
    -- the whole profile off without saying so.
    IF EXISTS (SELECT 1 FROM @crit WHERE match_all = 0 AND value_count = 0)
        THROW 67436, 'sp_event_profile_save: a criterion that is not "All" must have at least one value.', 1;

    DECLARE @is_new BIT = CASE WHEN @profile_id IS NULL OR @profile_id = 0 THEN 1 ELSE 0 END;

    IF @is_new = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.event_profile
                        WHERE profile_id = @profile_id AND organization_id = @organization_id)
        THROW 67437, 'sp_event_profile_save: profile not found in this organization.', 1;

    -- 407: a profile's type is fixed once saved. Its criteria, its
    -- checklist decisions and every instance raised from it describe
    -- one kind of subject; turning a People profile into an Asset one
    -- (or back) would silently re-point all of them.
    IF @is_new = 0
       AND EXISTS (SELECT 1 FROM grac_practice.event_profile
                    WHERE profile_id = @profile_id AND organization_id = @organization_id
                      AND subject_entity <> @subject_entity)
        THROW 67438, 'sp_event_profile_save: the Profile Type of a saved profile cannot be changed.', 1;

    BEGIN TRAN;

    IF @is_new = 1
    BEGIN
        INSERT INTO grac_practice.event_profile
            (organization_id, profile_code, profile_name, description,
             subject_entity, status, entered_by, entered_dt)
        VALUES
            (@organization_id, @profile_code, @profile_name, @description,
             @subject_entity, @status, @actor, SYSUTCDATETIME());
        SET @out_profile_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.event_profile
           SET profile_code   = @profile_code,
               profile_name   = @profile_name,
               description    = @description,
               subject_entity = @subject_entity,
               status         = @status,
               updated_by     = @actor,
               updated_dt     = SYSUTCDATETIME()
         WHERE profile_id      = @profile_id
           AND organization_id = @organization_id;
        SET @out_profile_id = @profile_id;
    END

    -- Replace the criteria tree. Values before criteria (FK order).
    DELETE v
      FROM grac_practice.event_profile_criteria_value v
     WHERE v.profile_id = @out_profile_id;

    DELETE FROM grac_practice.event_profile_criteria
     WHERE profile_id = @out_profile_id;

    DECLARE @rowid INT = 0, @max_rowid INT = (SELECT ISNULL(MAX(rowid), 0) FROM @crit);
    DECLARE @criteria_id BIGINT;

    WHILE @rowid < @max_rowid
    BEGIN
        SET @rowid = @rowid + 1;

        DECLARE @dim_code NVARCHAR(40), @dim_id INT, @all BIT, @vals NVARCHAR(MAX);
        SELECT @dim_code = dimension_code, @dim_id = dimension_id,
               @all = match_all, @vals = values_json
        FROM @crit WHERE rowid = @rowid;

        INSERT INTO grac_practice.event_profile_criteria
            (profile_id, organization_id, dimension_id, dimension_code,
             match_all, entered_by, entered_dt)
        VALUES
            (@out_profile_id, @organization_id, @dim_id, @dim_code,
             @all, @actor, SYSUTCDATETIME());

        SET @criteria_id = SCOPE_IDENTITY();

        -- match_all carries no values by definition; any sent with it are
        -- dropped rather than stored, so the row cannot later be read two
        -- ways.
        IF @all = 0 AND @vals IS NOT NULL
            INSERT INTO grac_practice.event_profile_criteria_value
                (criteria_id, profile_id, value_id, value_text, value_label, entered_by, entered_dt)
            SELECT @criteria_id, @out_profile_id,
                   v.valueId,
                   CASE WHEN v.valueId IS NULL THEN NULLIF(LTRIM(RTRIM(v.valueText)), N'') END,
                   LEFT(COALESCE(NULLIF(LTRIM(RTRIM(v.valueLabel)), N''),
                                 NULLIF(LTRIM(RTRIM(v.valueText)), N''),
                                 CAST(v.valueId AS NVARCHAR(20))), 300),
                   @actor, SYSUTCDATETIME()
            FROM OPENJSON(@vals)
            WITH (
                valueId    BIGINT        '$.valueId',
                valueText  NVARCHAR(200) '$.valueText',
                valueLabel NVARCHAR(300) '$.valueLabel'
            ) v
            -- A value carrying neither an id nor text would violate
            -- ck_pm_event_profile_cv_one_value; skipping it here gives a
            -- clean save instead of a constraint error nobody can read.
            WHERE v.valueId IS NOT NULL
               OR NULLIF(LTRIM(RTRIM(v.valueText)), N'') IS NOT NULL;
    END

    IF OBJECT_ID('grac_practice.event_audit','U') IS NOT NULL
        INSERT INTO grac_practice.event_audit
            (organization_id, entity_type, entity_id, action, actor, new_value, entered_dt)
        VALUES
            (@organization_id, N'EventProfile', @out_profile_id,
             CASE WHEN @is_new = 1 THEN N'Create' ELSE N'Update' END, @actor,
             CONCAT(N'code=', @profile_code, N';name=', @profile_name,
                    N';subject=', @subject_entity, N';status=', @status,
                    N';criteria=', @max_rowid),
             SYSUTCDATETIME());

    COMMIT TRAN;

    SELECT @out_profile_id AS ProfileId, @profile_code AS ProfileCode;
END;
GO

-- 8. sp_event_profile_preview_members (ASSET population)
CREATE OR ALTER PROCEDURE grac_practice.sp_event_profile_preview_members
    @organization_id BIGINT,
    @profile_id      BIGINT       = NULL,
    @sample_size     INT          = 10,
    -- 407: which population to count. Taken from the profile when one is
    -- given; used as-is only for the unsaved form (no profile yet).
    @subject_entity  NVARCHAR(60) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 67460, 'sp_event_profile_preview_members: organization_id is required.', 1;
    IF @sample_size IS NULL OR @sample_size < 1 SET @sample_size = 10;
    IF @sample_size > 100 SET @sample_size = 100;

    IF @profile_id IS NOT NULL
    BEGIN
        SELECT @subject_entity = subject_entity
        FROM   grac_practice.event_profile
        WHERE  profile_id = @profile_id AND organization_id = @organization_id;
        IF @subject_entity IS NULL
            THROW 67461, 'sp_event_profile_preview_members: profile not found in this organization.', 1;
    END
    IF @subject_entity IS NULL OR @subject_entity NOT IN (N'EMPLOYEE', N'ASSET')
        SET @subject_entity = N'EMPLOYEE';

    -- One member shape for both populations, so the caller never branches:
    -- MemberId / MemberCode / MemberName / MemberDetail.
    DECLARE @members TABLE (
        member_id     BIGINT PRIMARY KEY,
        member_code   NVARCHAR(100),
        member_name   NVARCHAR(300),
        member_detail NVARCHAR(300));

    IF @subject_entity = N'EMPLOYEE'
        INSERT INTO @members(member_id, member_code, member_name, member_detail)
        SELECT e.employee_id, e.employee_code, e.employee_name, e.designation
        FROM   grac_practice.organization_employee e
        WHERE  e.organization_id = @organization_id AND e.status = N'Active';
    ELSE
        INSERT INTO @members(member_id, member_code, member_name, member_detail)
        SELECT a.asset_id, NULL, a.asset_name, ac.asset_category_name
        FROM   grac_practice.organization_dependency_asset a
        LEFT JOIN grac_practice.dependency_asset_category_master ac
               ON ac.asset_category_id = a.asset_category_id
        WHERE  a.organization_id = @organization_id AND a.status = N'Active';

    DECLARE @total INT = (SELECT COUNT(1) FROM @members);

    -- No profile: the unconstrained population, so the form can show the
    -- whole before a profile narrows it.
    IF @profile_id IS NOT NULL
        DELETE m
        FROM   @members m
        WHERE  NOT EXISTS (SELECT 1
                           FROM grac_practice.fn_pm_event_profile_matches(
                                    @organization_id, @subject_entity, m.member_id) f
                           WHERE f.profile_id = @profile_id);

    DECLARE @matched INT = (SELECT COUNT(1) FROM @members);

    SELECT @matched         AS MatchedCount,
           @total           AS TotalActive,
           -- kept under its 330 name for any caller that still reads it
           @total           AS TotalActiveEmployees,
           @subject_entity  AS SubjectEntity;

    SELECT TOP (@sample_size)
           m.member_id     AS MemberId,
           m.member_code   AS MemberCode,
           m.member_name   AS MemberName,
           m.member_detail AS MemberDetail
    FROM   @members m
    ORDER BY m.member_name;
END;
GO

-- 9. sp_event_obligation_coverage_list (343 body, PROFILE counts both kinds)
CREATE OR ALTER PROCEDURE grac_practice.sp_event_obligation_coverage_list
    @organization_id BIGINT,
    @scope_dimension NVARCHAR(40),
    @event_type_id   BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @scope_dimension IS NULL
        THROW 67320, 'sp_event_obligation_coverage_list: organization_id and scope_dimension are required.', 1;
    IF @scope_dimension NOT IN (N'ORG_ROLE', N'ASSET_CATEGORY', N'PROFILE')
        THROW 67321, 'sp_event_obligation_coverage_list: scope_dimension must be ORG_ROLE, ASSET_CATEGORY or PROFILE.', 1;

    -- Denominator: distinct event-driven obligations actually reaching this
    -- organization. DISTINCT matters -- the view fans out per requirement /
    -- practice / release path (see 129).
    --
    -- Migration 343: COUNT(DISTINCT obligation_id) silently ignored every
    -- custom obligation (COUNT DISTINCT drops NULLs, and obligation_id is
    -- NULL on both new branches). A single composite key, letter-prefixed
    -- so a catalog id, a practice-level id and an instance-level id of the
    -- same number cannot collide, replaces it.
    DECLARE @total INT = (
        SELECT COUNT(DISTINCT
                 COALESCE('C' + CAST(obligation_id AS NVARCHAR(20)),
                          'P' + CAST(local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(local_instance_obligation_id AS NVARCHAR(20))))
        FROM   grac_practice.vw_pm_event_driven_obligation
        WHERE  organization_id = @organization_id
          AND  is_subscribed   = 1
          AND  (@event_type_id IS NULL OR event_type_id = @event_type_id));

    IF @scope_dimension = N'ORG_ROLE'
        SELECT N'ORG_ROLE'                     AS ScopeDimension,
               r.role_id                       AS ScopeValueId,
               r.role_name                      AS ScopeValueName,
               @total                           AS TotalObligations,
               COUNT(DISTINCT
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))))  AS DecidedObligations,
               @total - COUNT(DISTINCT
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20)))) AS UndecidedObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 1 THEN
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))) END)
                                                AS ApplicableObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 0 THEN
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))) END)
                                                AS ExcludedObligations
        FROM      grac_practice.organization_role r
        LEFT JOIN grac_practice.event_obligation_applicability a
               ON a.organization_id = r.organization_id
              AND a.scope_role_id   = r.role_id
              AND a.status          = N'Active'
              AND (@event_type_id IS NULL OR a.event_type_id = @event_type_id)
        WHERE     r.organization_id = @organization_id
          AND     r.status          = N'Active'
        GROUP BY  r.role_id, r.role_name
        ORDER BY  UndecidedObligations DESC, r.role_name;
    ELSE IF @scope_dimension = N'ASSET_CATEGORY'
        SELECT N'ASSET_CATEGORY'                AS ScopeDimension,
               ac.asset_category_id             AS ScopeValueId,
               ac.asset_category_name           AS ScopeValueName,
               @total                           AS TotalObligations,
               COUNT(DISTINCT
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))))  AS DecidedObligations,
               @total - COUNT(DISTINCT
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20)))) AS UndecidedObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 1 THEN
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))) END)
                                                AS ApplicableObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 0 THEN
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))) END)
                                                AS ExcludedObligations
        FROM      grac_practice.dependency_asset_category_master ac
        LEFT JOIN grac_practice.event_obligation_applicability a
               ON a.organization_id         = @organization_id
              AND a.scope_asset_category_id = ac.asset_category_id
              AND a.status                  = N'Active'
              AND (@event_type_id IS NULL OR a.event_type_id = @event_type_id)
        WHERE     ac.is_active = 1
        GROUP BY  ac.asset_category_id, ac.asset_category_name
        ORDER BY  UndecidedObligations DESC, ac.asset_category_name;
    ELSE
        SELECT N'PROFILE'                       AS ScopeDimension,
               p.profile_id                     AS ScopeValueId,
               p.profile_name                   AS ScopeValueName,
               @total                           AS TotalObligations,
               COUNT(DISTINCT
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))))  AS DecidedObligations,
               @total - COUNT(DISTINCT
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20)))) AS UndecidedObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 1 THEN
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))) END)
                                                AS ApplicableObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 0 THEN
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))) END)
                                                AS ExcludedObligations
        FROM      grac_practice.event_profile p
        LEFT JOIN grac_practice.event_obligation_applicability a
               ON a.organization_id = p.organization_id
              AND a.profile_id      = p.profile_id
              AND a.status          = N'Active'
              AND (@event_type_id IS NULL OR a.event_type_id = @event_type_id)
        WHERE     p.organization_id = @organization_id
          -- 407: Asset profiles are mapped to checklists too, so the
          -- coverage strip counts both kinds (was EMPLOYEE only).
          AND     p.status          = N'Active'
        GROUP BY  p.profile_id, p.profile_name
        ORDER BY  UndecidedObligations DESC, p.profile_name;
END;
GO

-- 10. sp_event_obligation_raise (343 body + ASSET profiles)
CREATE OR ALTER PROCEDURE grac_practice.sp_event_obligation_raise
    @organization_id     BIGINT,
    @event_type_id       BIGINT        = NULL,
    @event_type_code     NVARCHAR(60)  = NULL,
    @event_definition_id BIGINT        = NULL,
    @subject_entity      NVARCHAR(60),
    @subject_record_id   BIGINT,
    @effective_date      DATE          = NULL,
    @trigger_source      NVARCHAR(60)  = N'Manual',
    @actor_employee_id   BIGINT        = NULL,
    @out_raised_count    INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @out_raised_count = 0;

    IF @organization_id IS NULL
        THROW 67330, 'sp_event_obligation_raise: organization_id is required.', 1;
    IF @subject_entity NOT IN (N'EMPLOYEE', N'ASSET')
        THROW 67331, 'sp_event_obligation_raise: subject_entity must be EMPLOYEE or ASSET.', 1;
    IF @subject_record_id IS NULL
        THROW 67332, 'sp_event_obligation_raise: subject_record_id is required.', 1;

    IF @event_type_id IS NULL AND @event_type_code IS NOT NULL
        SELECT @event_type_id = event_type_id
        FROM   GRAC_New.event_type_master
        WHERE  event_code = @event_type_code AND status = N'Active';

    IF @event_type_id IS NULL
        THROW 67333, 'sp_event_obligation_raise: event type not resolved.', 1;

    SELECT @event_type_code = event_code
    FROM   GRAC_New.event_type_master WHERE event_type_id = @event_type_id;

    SET @effective_date = ISNULL(@effective_date, CAST(SYSUTCDATETIME() AS DATE));
    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    DECLARE @subject_label NVARCHAR(300),
            @asset_cat     INT = NULL,
            @asset_cat_nm  NVARCHAR(160) = NULL;
    DECLARE @roles TABLE (role_id BIGINT PRIMARY KEY, role_name NVARCHAR(120));
    -- 331 (a)
    DECLARE @profiles TABLE (profile_id BIGINT PRIMARY KEY, profile_name NVARCHAR(200));

    IF @subject_entity = N'EMPLOYEE'
    BEGIN
        SELECT @subject_label = LEFT(CONCAT(employee_name, N' (', employee_code, N')'), 300)
        FROM   grac_practice.organization_employee
        WHERE  employee_id = @subject_record_id AND organization_id = @organization_id;
        IF @subject_label IS NULL
            THROW 67334, 'sp_event_obligation_raise: employee not found in this organization.', 1;

        -- BOTH role sources (131). The Employee form writes
        -- organization_employee.role_id; User Role Assignment writes
        -- organization_employee_role.
        INSERT INTO @roles(role_id, role_name)
        SELECT role_id, MIN(role_name)
        FROM   grac_practice.fn_pm_employee_role_ids(@subject_record_id)
        GROUP BY role_id;

        -- 331 (a): every Active profile whose criteria this employee
        -- satisfies. Evaluated live rather than stored, for the same
        -- reason 127 reads the obligation view live: a profile edited in
        -- GRAC must take effect on the next raise and cannot be allowed
        -- to drift behind a projection.
        INSERT INTO @profiles(profile_id, profile_name)
        SELECT m.profile_id, MIN(m.profile_name)
        FROM   grac_practice.fn_pm_event_profile_matches(
                   @organization_id, N'EMPLOYEE', @subject_record_id) m
        GROUP BY m.profile_id;
    END
    ELSE
    BEGIN
        SELECT @subject_label = LEFT(a.asset_name, 300),
               @asset_cat     = a.asset_category_id,
               @asset_cat_nm  = ac.asset_category_name
        FROM   grac_practice.organization_dependency_asset a
        LEFT JOIN grac_practice.dependency_asset_category_master ac
               ON ac.asset_category_id = a.asset_category_id
        WHERE  a.asset_id = @subject_record_id AND a.organization_id = @organization_id;
        IF @subject_label IS NULL
            THROW 67335, 'sp_event_obligation_raise: asset not found in this organization.', 1;

        -- 407: every Active ASSET profile this asset satisfies (Location,
        -- Asset Category, Sub Category, Type) -- the same live evaluation
        -- the EMPLOYEE branch does above. Asset Category decisions keep
        -- resolving exactly as before; profile decisions sit beside them.
        INSERT INTO @profiles(profile_id, profile_name)
        SELECT m.profile_id, MIN(m.profile_name)
        FROM   grac_practice.fn_pm_event_profile_matches(
                   @organization_id, N'ASSET', @subject_record_id) m
        GROUP BY m.profile_id;
    END

    DECLARE @event_def BIGINT = @event_definition_id;
    IF @event_def IS NULL
        SELECT TOP 1 @event_def = event_definition_id
        FROM   grac_practice.event_definition
        WHERE  organization_id = @organization_id AND status = N'Active'
        ORDER BY CASE WHEN event_code = @event_type_code THEN 0 ELSE 1 END, event_definition_id;

    -- 331 (b): an employee with no role used to be a dead end, because a
    -- role was the only thing a mapping could be scoped to. A profile can
    -- be scoped on Location and Department alone, so the exit now needs
    -- BOTH to be empty.
    IF (@subject_entity = N'EMPLOYEE'
            AND NOT EXISTS (SELECT 1 FROM @roles)
            AND NOT EXISTS (SELECT 1 FROM @profiles))
       OR (@subject_entity = N'ASSET'
            AND @asset_cat IS NULL
            AND NOT EXISTS (SELECT 1 FROM @profiles))
    BEGIN
        INSERT INTO grac_practice.event_mapping_resolution
            (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
             subject_label, effective_date, decision, reason_code, reason_detail, entered_by, entered_dt)
        VALUES
            (@organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
             @subject_label, @effective_date, N'Excluded', N'SubjectScopeMissing',
             CASE WHEN @subject_entity = N'EMPLOYEE'
                  THEN N'Employee has no active role (in either organization_employee.role_id or organization_employee_role) and matches no active Profile.'
                  ELSE N'Asset has no category assigned and matches no active Profile.' END,
             @actor, SYSUTCDATETIME());
        RETURN;
    END

    -- Migration 343: obligation_id is no longer the row's only possible
    -- identity, so it can no longer be the PRIMARY KEY -- a table
    -- variable's key column cannot hold NULL, and a custom obligation's
    -- obligation_id is always NULL. cand_id is a plain surrogate; the
    -- uniqueness that mattered (one candidate row per obligation) is
    -- still enforced below by the ranked CTE's PARTITION BY + rn = 1
    -- filter, exactly as it was when obligation_id carried both jobs.
    DECLARE @cand TABLE (
        cand_id                     INT IDENTITY(1,1) PRIMARY KEY,
        obligation_id               BIGINT NULL,
        local_practice_obligation_id BIGINT NULL,
        local_instance_obligation_id BIGINT NULL,
        obligation_label            NVARCHAR(400),
        obligation_text             NVARCHAR(MAX),
        applicability_id            BIGINT,
        owner_role_id                BIGINT,
        due_days                     INT,
        decision                     NVARCHAR(20),
        reason_code                  NVARCHAR(60),
        profile_id                   BIGINT          -- 331 (c)
    );

    ;WITH raw AS (
        SELECT v.obligation_id, v.local_practice_obligation_id, v.local_instance_obligation_id,
               v.obligation_label, v.obligation_text,
               a.applicability_id, a.owner_role_id, a.due_days,
               a.profile_id,                                   -- 331 (c)
               CASE WHEN a.applicability_id IS NULL THEN N'Excluded'
                    WHEN a.status <> N'Active'      THEN N'Excluded'
                    WHEN a.is_applicable = 0        THEN N'Excluded'
                    ELSE N'Included' END AS decision,
               CASE WHEN a.applicability_id IS NULL THEN N'ObligationUnmapped'
                    WHEN a.status <> N'Active'      THEN N'MappingInactive'
                    WHEN a.is_applicable = 0        THEN N'ObligationNotApplicable'
                    ELSE N'ObligationApplicable' END AS reason_code
        FROM       grac_practice.vw_pm_event_driven_obligation v
        LEFT JOIN  grac_practice.event_obligation_applicability a
               ON  a.organization_id = v.organization_id
              -- Migration 343: match on whichever identity this row carries.
              AND  ISNULL(a.obligation_id,-1)                = ISNULL(v.obligation_id,-1)
              AND  ISNULL(a.local_practice_obligation_id,-1) = ISNULL(v.local_practice_obligation_id,-1)
              AND  ISNULL(a.local_instance_obligation_id,-1) = ISNULL(v.local_instance_obligation_id,-1)
              AND  a.event_type_id   = v.event_type_id
              AND  (   (@subject_entity = N'EMPLOYEE'
                            AND a.scope_role_id IN (SELECT role_id FROM @roles))
                    -- 331 (c): profile decisions sit beside role decisions,
                    -- never instead of them. The ranked window below settles
                    -- any disagreement the same way it has always settled a
                    -- disagreement between two of an employee's roles.
                    OR (@subject_entity = N'EMPLOYEE'
                            AND a.profile_id IN (SELECT profile_id FROM @profiles))
                    OR (@subject_entity = N'ASSET'
                            AND a.scope_asset_category_id = @asset_cat)
                    -- 407: asset profile decisions, beside category ones.
                    OR (@subject_entity = N'ASSET'
                            AND a.profile_id IN (SELECT profile_id FROM @profiles)))
        WHERE      v.organization_id = @organization_id
          AND      v.event_type_id   = @event_type_id
          AND      v.is_subscribed   = 1
    ),
    ranked AS (
        SELECT *, ROW_NUMBER() OVER (
                     PARTITION BY obligation_id, local_practice_obligation_id, local_instance_obligation_id
                     ORDER BY CASE WHEN decision = N'Included' THEN 0 ELSE 1 END,
                              CASE WHEN due_days IS NULL THEN 1 ELSE 0 END,
                              due_days, applicability_id) AS rn
        FROM raw
    )
    INSERT INTO @cand
        (obligation_id, local_practice_obligation_id, local_instance_obligation_id,
         obligation_label, obligation_text, applicability_id,
         owner_role_id, due_days, decision, reason_code, profile_id)
    SELECT obligation_id, local_practice_obligation_id, local_instance_obligation_id,
           obligation_label, obligation_text, applicability_id,
           owner_role_id, due_days, decision, reason_code, profile_id
    FROM   ranked WHERE rn = 1;

    -- 331 (c): which profile, if any, produced the decisions being acted
    -- on. Picked from the Included rows so the snapshot names a profile
    -- that actually contributed, not merely one that matched.
    DECLARE @scope_profile    BIGINT = NULL,
            @scope_profile_nm NVARCHAR(200) = NULL;

    SELECT TOP 1 @scope_profile = c.profile_id
    FROM   @cand c
    WHERE  c.decision = N'Included' AND c.profile_id IS NOT NULL
    ORDER BY CASE WHEN c.due_days IS NULL THEN 1 ELSE 0 END, c.due_days, c.applicability_id;

    IF @scope_profile IS NULL
        SELECT TOP 1 @scope_profile = profile_id FROM @profiles ORDER BY profile_id;

    IF @scope_profile IS NOT NULL
        SELECT @scope_profile_nm = profile_name FROM @profiles WHERE profile_id = @scope_profile;

    IF NOT EXISTS (SELECT 1 FROM @cand WHERE decision = N'Included')
    BEGIN
        IF EXISTS (SELECT 1 FROM @cand)
            INSERT INTO grac_practice.event_mapping_resolution
                (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
                 subject_label, effective_date, obligation_id, local_practice_obligation_id, local_instance_obligation_id,
                 obligation_label, applicability_id,
                 scope_role_id, scope_asset_category_id, profile_id, profile_name,
                 decision, reason_code, entered_by, entered_dt)
            SELECT @organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
                   @subject_label, @effective_date, c.obligation_id, c.local_practice_obligation_id, c.local_instance_obligation_id,
                   c.obligation_label, c.applicability_id,
                   (SELECT TOP 1 role_id FROM @roles ORDER BY role_id), @asset_cat,
                   c.profile_id,
                   (SELECT TOP 1 p.profile_name FROM @profiles p WHERE p.profile_id = c.profile_id),
                   N'Excluded', c.reason_code, @actor, SYSUTCDATETIME()
            FROM   @cand c;
        ELSE
            INSERT INTO grac_practice.event_mapping_resolution
                (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
                 subject_label, effective_date, profile_id, profile_name,
                 decision, reason_code, reason_detail, entered_by, entered_dt)
            VALUES
                (@organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
                 @subject_label, @effective_date, @scope_profile, @scope_profile_nm,
                 N'Excluded', N'NoMappingForEvent',
                 N'No event-driven obligation of this event type reaches this organization.',
                 @actor, SYSUTCDATETIME());
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM grac_practice.event_instance
                WHERE organization_id   = @organization_id
                  AND origin_kind       = N'OBLIGATION'
                  AND event_type_id     = @event_type_id
                  AND subject_entity    = @subject_entity
                  AND subject_record_id = @subject_record_id
                  AND status NOT IN (N'Completed', N'Cancelled'))
    BEGIN
        INSERT INTO grac_practice.event_mapping_resolution
            (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
             subject_label, effective_date, profile_id, profile_name,
             decision, reason_code, reason_detail, entered_by, entered_dt)
        VALUES
            (@organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
             @subject_label, @effective_date, @scope_profile, @scope_profile_nm,
             N'Excluded', N'AlreadyOpen',
             N'An open obligation instance already exists for this subject and event.',
             @actor, SYSUTCDATETIME());
        RETURN;
    END

    IF @event_def IS NULL
        THROW 67336, 'sp_event_obligation_raise: organization has no active event_definition. Run migration 126.', 1;

    DECLARE @due_days INT = (SELECT MIN(due_days) FROM @cand WHERE decision = N'Included');
    DECLARE @owner_role BIGINT = (
        SELECT TOP 1 owner_role_id FROM @cand
         WHERE decision = N'Included' AND owner_role_id IS NOT NULL
         ORDER BY CASE WHEN due_days IS NULL THEN 1 ELSE 0 END, due_days);

    DECLARE @owner_emp BIGINT = NULL, @owner_nm NVARCHAR(240) = NULL;
    IF @owner_role IS NOT NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id = @organization_id, @role_id = @owner_role,
             @employee_id_out = @owner_emp OUTPUT, @employee_name_out = @owner_nm OUTPUT;

    DECLARE @scope_role BIGINT = (SELECT TOP 1 role_id FROM @roles ORDER BY role_id);
    DECLARE @scope_role_nm NVARCHAR(120) = (SELECT TOP 1 role_name FROM @roles ORDER BY role_id);

    BEGIN TRAN;

    INSERT INTO grac_practice.event_instance
        (organization_id, event_definition_id, entity_type_id, entity_reference,
         entity_display_name, checklist_id, trigger_source,
         owner_employee_id, due_date, status,
         origin_kind, event_type_id, event_type_code,
         subject_entity, subject_record_id,
         scope_role_id, scope_role_name,
         scope_asset_category_id, scope_asset_category_name,
         scope_profile_id, scope_profile_name,
         effective_date, entered_by, entered_dt)
    VALUES
        (@organization_id, @event_def, NULL, CAST(@subject_record_id AS NVARCHAR(200)),
         @subject_label, NULL, ISNULL(@trigger_source, N'Manual'),
         @owner_emp,
         CASE WHEN @due_days IS NULL THEN NULL ELSE DATEADD(DAY, @due_days, @effective_date) END,
         N'Pending',
         N'OBLIGATION', @event_type_id, @event_type_code,
         @subject_entity, @subject_record_id,
         CASE WHEN @subject_entity = N'EMPLOYEE' THEN @scope_role ELSE NULL END,
         CASE WHEN @subject_entity = N'EMPLOYEE' THEN @scope_role_nm ELSE NULL END,
         CASE WHEN @subject_entity = N'ASSET' THEN @asset_cat ELSE NULL END,
         CASE WHEN @subject_entity = N'ASSET' THEN @asset_cat_nm ELSE NULL END,
         -- 407: the profile snapshot is kept for an asset too.
         @scope_profile,
         @scope_profile_nm,
         @effective_date, @actor, SYSUTCDATETIME());

    DECLARE @instance BIGINT = SCOPE_IDENTITY();

    INSERT INTO grac_practice.event_instance_obligation
        (event_instance_id, organization_id, obligation_id, local_practice_obligation_id, local_instance_obligation_id,
         obligation_label, obligation_text,
         applicability_id, item_sequence, is_mandatory, item_status, entered_dt)
    SELECT @instance, @organization_id, c.obligation_id, c.local_practice_obligation_id, c.local_instance_obligation_id,
           c.obligation_label, c.obligation_text,
           c.applicability_id,
           ROW_NUMBER() OVER (ORDER BY COALESCE(c.obligation_id, c.local_practice_obligation_id, c.local_instance_obligation_id)),
           1, N'Pending', SYSUTCDATETIME()
    FROM   @cand c WHERE c.decision = N'Included';

    SET @out_raised_count = @@ROWCOUNT;

    -- Per-obligation trace. profile_id is the one that decided THAT
    -- obligation, not the instance-level snapshot -- with two profiles
    -- matching, "which profile put this check here?" has a different
    -- answer per row, and collapsing it to one would lose exactly the
    -- fact an auditor asks for.
    INSERT INTO grac_practice.event_mapping_resolution
        (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
         subject_label, effective_date, obligation_id, local_practice_obligation_id, local_instance_obligation_id,
         obligation_label, applicability_id,
         scope_role_id, scope_asset_category_id, profile_id, profile_name,
         decision, reason_code, event_instance_id, entered_by, entered_dt)
    SELECT @organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
           @subject_label, @effective_date, c.obligation_id, c.local_practice_obligation_id, c.local_instance_obligation_id,
           c.obligation_label, c.applicability_id,
           @scope_role, @asset_cat, c.profile_id,
           (SELECT TOP 1 p.profile_name FROM @profiles p WHERE p.profile_id = c.profile_id),
           c.decision, c.reason_code,
           CASE WHEN c.decision = N'Included' THEN @instance ELSE NULL END,
           @actor, SYSUTCDATETIME()
    FROM   @cand c;

    INSERT INTO grac_practice.event_audit
        (organization_id, event_instance_id, entity_type, entity_id, action, actor, new_value, entered_dt)
    VALUES
        (@organization_id, @instance, N'EventInstance', @instance, N'Trigger', @actor,
         CONCAT(N'origin=OBLIGATION;event_type=', @event_type_code,
                N';subject=', @subject_entity, N':', @subject_record_id,
                N';obligations=', @out_raised_count,
                N';profiles=', (SELECT COUNT(1) FROM @profiles),
                N';effective_date=', CONVERT(NVARCHAR(10), @effective_date, 23)),
         SYSUTCDATETIME());

    COMMIT TRAN;

    SELECT @out_raised_count AS RaisedCount, @instance AS EventInstanceId;
END;
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 407 verification ===';

SELECT '407-a dimension master cascade columns' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.event_profile_dimension_master','source_parent_column') IS NOT NULL
             AND COL_LENGTH('grac_practice.event_profile_dimension_master','parent_dimension_code') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '407-b event_profile.profile_type',
       CASE WHEN COL_LENGTH('grac_practice.event_profile','profile_type') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '407-c four active ASSET dimensions',
       CASE WHEN (SELECT COUNT(1) FROM grac_practice.event_profile_dimension_master
                   WHERE subject_entity = N'ASSET' AND is_active = 1
                     AND dimension_code IN (N'ASSET_LOCATION', N'ASSET_CATEGORY',
                                            N'ASSET_SUBCATEGORY', N'ASSET_TYPE')) = 4
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '407-d view carries ASSET arms',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.vw_pm_event_profile_subject_attribute','V'))
                 LIKE '%ASSET_SUBCATEGORY%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '407-e list supports ALL + ProfileType',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_profile_list','P')) LIKE '%AS ProfileType%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '407-f save fixes the type (67438)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_profile_save','P')) LIKE '%67438%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '407-g preview takes @subject_entity',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_event_profile_preview_members','P')
                            AND name = '@subject_entity')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '407-h raise resolves ASSET profiles',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_obligation_raise','P'))
                 LIKE '%fn_pm_event_profile_matches(%N''ASSET''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '407-i existing profiles all read as People',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.event_profile
                              WHERE subject_entity = N'EMPLOYEE' AND profile_type <> N'People')
            THEN 'PASS' ELSE 'FAIL' END;

-- Profiles per type (information only)
SELECT profile_type AS ProfileType, COUNT(1) AS Profiles
FROM   grac_practice.event_profile
GROUP BY profile_type;
GO

SET NOEXEC OFF;
GO
PRINT 'Migration 407_event_profile_asset_profiles applied.';
GO
