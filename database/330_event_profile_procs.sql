-- =====================================================================
-- 330 Event Profile -- attribute view, matcher and CRUD procedures
--
-- Objects:
--   grac_practice.vw_pm_event_profile_subject_attribute   (NEW view)
--   grac_practice.fn_pm_event_profile_matches             (NEW inline TVF)
--   grac_practice.sp_event_profile_dimension_list
--   grac_practice.sp_event_profile_dimension_values
--   grac_practice.sp_event_profile_list
--   grac_practice.sp_event_profile_get
--   grac_practice.sp_event_profile_save
--   grac_practice.sp_event_profile_set_status
--   grac_practice.sp_event_profile_delete
--   grac_practice.sp_event_profile_preview_members
--
-- WHERE THE EXTENSIBILITY ACTUALLY LIVES
-- --------------------------------------
-- 329's dimension master makes the STORAGE and the SCREEN open-ended.
-- Matching cannot be equally open-ended for free: T-SQL cannot read a
-- column name out of a data row inside a set-based predicate, and a
-- function may not use dynamic SQL. Rather than scatter that limit
-- through the matcher, it is isolated in ONE view:
--
--     vw_pm_event_profile_subject_attribute
--         (organization_id, subject_entity, subject_record_id,
--          dimension_code, value_id, value_text)
--
-- one UNION ALL arm per dimension, turning an employee row into the set
-- of attribute values it holds. fn_pm_event_profile_matches is then
-- entirely generic over that view and never names a dimension.
--
-- So adding a criterion later is:
--     1. a seed row in event_profile_dimension_master   (329)
--     2. one UNION ALL arm in this view                 (CREATE OR ALTER)
-- and nothing else. No table change, no save-proc change, no resolver
-- change, no screen change. That is the promise the design makes, stated
-- plainly rather than implied.
--
-- MATCH SEMANTICS
-- ---------------
--     OR  within a dimension   ("Role is System Administrator OR IT Manager")
--     AND across dimensions    ("...AND Department is IT Operations")
--     absent dimension = unconstrained
--     match_all = 1            = unconstrained, recorded as a decision
--
-- Absent and match_all are treated identically on purpose. They mean the
-- same thing, and if they did not, the meaning of a profile would depend
-- on which screen created it. match_all exists so the UI can show "All"
-- as something the admin chose rather than something nobody filled in.
--
-- A profile whose every criterion is match_all matches every employee in
-- the organisation. That is legitimate ("All Employees") and the preview
-- count makes it obvious, so it is allowed -- but a profile with NO
-- criteria rows at all is rejected, because it is indistinguishable from
-- a half-finished save.
--
-- Depends on 329 (tables), 131 (fn_pm_employee_role_ids), 133
-- (organization_employee attribute columns).
-- Rollback: 330_event_profile_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- =====================================================================
-- Prerequisites
-- =====================================================================
IF OBJECT_ID('grac_practice.event_profile','U') IS NULL
   OR OBJECT_ID('grac_practice.event_profile_criteria','U') IS NULL
   OR OBJECT_ID('grac_practice.event_profile_criteria_value','U') IS NULL
   OR OBJECT_ID('grac_practice.event_profile_dimension_master','U') IS NULL
BEGIN
    RAISERROR('330: run 329_event_profile_schema.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.fn_pm_employee_role_ids','IF') IS NULL
BEGIN
    RAISERROR('330: fn_pm_employee_role_ids missing. Run 131 first -- ORG_ROLE matching depends on it.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Every attribute column the view reads. All three arrive in 133; a
-- missing one would make the view fail to compile with a message that
-- does not say why, so it is named here instead.
IF COL_LENGTH('grac_practice.organization_employee','location_id')          IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','department_id')     IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','business_function_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','designation')       IS NULL
BEGIN
    RAISERROR('330: organization_employee is missing one of location_id / department_id / business_function_id / designation. Run 133 first.', 16, 1);
    SET NOEXEC ON;
END
GO


-- =====================================================================
-- 1. vw_pm_event_profile_subject_attribute
--
--    One row per attribute value a subject holds. The ONE place that
--    knows dimension codes map to employee columns.
--
--    NULL attributes produce no row, so a profile constrained on a
--    dimension the employee has no value for simply does not match --
--    which is correct: "Department is Finance" cannot be true of an
--    employee with no department.
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
    CROSS APPLY grac_practice.fn_pm_employee_role_ids(e.employee_id) r;
GO


-- =====================================================================
-- 2. fn_pm_event_profile_matches
--
--    Every Active profile of the organisation that the subject satisfies.
--    Inline (RETURNS TABLE) so the optimiser folds it into the caller --
--    the resolver calls it once per raise and the screen calls it per
--    preview.
--
--    Reads as: no criterion of this profile is unsatisfied.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_pm_event_profile_matches
(
    @organization_id   BIGINT,
    @subject_entity    NVARCHAR(60),
    @subject_record_id BIGINT
)
RETURNS TABLE
AS
RETURN
    SELECT p.profile_id, p.profile_code, p.profile_name
    FROM   grac_practice.event_profile p
    WHERE  p.organization_id = @organization_id
      AND  p.subject_entity  = @subject_entity
      AND  p.status          = N'Active'
      -- A profile with no criteria at all is not "matches everyone", it
      -- is an incomplete record. sp_event_profile_save rejects it; this
      -- guard means one that predates a fix still cannot fire.
      AND  EXISTS (SELECT 1 FROM grac_practice.event_profile_criteria c
                    WHERE c.profile_id = p.profile_id)
      AND  NOT EXISTS (
                SELECT 1
                FROM   grac_practice.event_profile_criteria c
                JOIN   grac_practice.event_profile_dimension_master d
                       ON d.dimension_id = c.dimension_id
                WHERE  c.profile_id = p.profile_id
                  AND  c.match_all  = 0
                  AND  d.is_active  = 1
                  -- unsatisfied: not one of this criterion's values is an
                  -- attribute the subject holds
                  AND  NOT EXISTS (
                        SELECT 1
                        FROM   grac_practice.event_profile_criteria_value v
                        JOIN   grac_practice.vw_pm_event_profile_subject_attribute a
                               ON  a.organization_id   = @organization_id
                              AND  a.subject_entity    = @subject_entity
                              AND  a.subject_record_id = @subject_record_id
                              AND  a.dimension_code    = c.dimension_code
                              AND  (   (v.value_id IS NOT NULL AND a.value_id = v.value_id)
                                    OR (v.value_text IS NOT NULL AND a.value_text = v.value_text))
                        WHERE  v.criteria_id = c.criteria_id));
GO


-- =====================================================================
-- 3. sp_event_profile_dimension_list
-- =====================================================================
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
           display_order         AS DisplayOrder
    FROM   grac_practice.event_profile_dimension_master
    WHERE  is_active      = 1
      AND  subject_entity = @subject_entity
    ORDER BY display_order, dimension_id;
END;
GO


-- =====================================================================
-- 4. sp_event_profile_dimension_values
--
--    The value picker for one dimension.
--
--    WHY THIS IS METADATA-DRIVEN AND 074'S EQUIVALENT IS HAND-BRANCHED
--    ----------------------------------------------------------------
--    sp_org_assurance_scope_dimension_values branches per dimension
--    because its 17 dimensions come from unrelated tables with different
--    shapes and different filters. Here the master row declares the
--    shape -- table, id column, name column, org column -- precisely so
--    that a new dimension needs no new branch. Branching by hand would
--    reintroduce the redesign this feature exists to avoid.
--
--    The dynamic SQL is built from the MASTER TABLE, never from caller
--    input, and every identifier is verified against sys.columns and
--    wrapped in QUOTENAME before it is used. A caller can choose which
--    dimension to read; it cannot contribute a character of the query.
-- =====================================================================
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
            @is_active    BIT;

    SELECT @value_kind = value_kind,
           @src_table  = source_table,
           @src_id     = source_id_column,
           @src_name   = source_name_column,
           @src_org    = source_org_column,
           @emp_col    = employee_match_column,
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
                   CAST(NULL AS NVARCHAR(300)) AS Name
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
                     CAST(LTRIM(RTRIM(e.' + QUOTENAME(@emp_col) + N')) AS NVARCHAR(300)) AS Name
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

    DECLARE @sql NVARCHAR(MAX) =
        N'SELECT TOP (@ps)
                 CAST(s.' + QUOTENAME(@src_id)   + N' AS BIGINT)        AS Id,
                 CAST(NULL AS NVARCHAR(200))                            AS TextValue,
                 CAST(s.' + QUOTENAME(@src_name) + N' AS NVARCHAR(300)) AS Name
          FROM   ' + @src_table + N' s
          WHERE  1 = 1'
      + CASE WHEN @src_org   IS NOT NULL THEN N' AND s.' + QUOTENAME(@src_org) + N' = @org' ELSE N'' END
      + CASE WHEN @has_status = 1        THEN N' AND s.[status] = N''Active''' ELSE N'' END
      + N' AND (@lk IS NULL OR s.' + QUOTENAME(@src_name) + N' LIKE @lk)
          ORDER BY Name;';

    EXEC sp_executesql @sql,
         N'@org BIGINT, @lk NVARCHAR(220), @ps INT',
         @org = @organization_id, @lk = @like, @ps = @page_size;
END;
GO


-- =====================================================================
-- 5. sp_event_profile_list
--
--    The grid. Paged with COUNT(*) OVER () AS TotalRows, per
--    docs/grid-and-pagination-standard.md.
--
--    CriteriaSummary is built server-side because the grid needs one
--    readable line ("Location: India, Kerala | Department: IT Operations
--    | Role: All") and assembling it in JavaScript would mean shipping
--    the whole criteria tree of every row just to render a caption.
-- =====================================================================
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
    IF @subject_entity NOT IN (N'EMPLOYEE', N'ASSET') SET @subject_entity = N'EMPLOYEE';

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
      AND  p.subject_entity  = @subject_entity
      AND  (@status IS NULL OR @status = N'' OR p.status = @status)
      AND  (@like IS NULL OR p.profile_name LIKE @like
                          OR p.profile_code LIKE @like
                          OR ISNULL(p.description, N'') LIKE @like)
    ORDER BY p.profile_name
    OFFSET @offset ROWS FETCH NEXT @size ROWS ONLY;
END;
GO


-- =====================================================================
-- 6. sp_event_profile_get -- two result sets: header, then criteria+values
-- =====================================================================
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


-- =====================================================================
-- 7. sp_event_profile_save
--
--    Create or replace one profile from a JSON tree. Delete-and-rehydrate
--    the criteria, following sp_org_assurance_scope_save (074): a
--    criteria row carries no history of its own, and diffing it would be
--    more code for the same result.
--
--    The applicability rows the profile owns are NOT touched -- they are
--    decisions about obligations, not part of the population definition,
--    and rewriting the population must not silently discard them.
--
--    Payload:
--      { "profileId": 0, "profileCode": "...", "profileName": "...",
--        "description": "...", "subjectEntity": "EMPLOYEE",
--        "status": "Active",
--        "criteria": [
--          { "dimensionCode": "LOCATION", "matchAll": false,
--            "values": [ { "valueId": 3, "valueLabel": "India" } ] },
--          { "dimensionCode": "ORG_ROLE", "matchAll": true, "values": [] }
--        ] }
-- =====================================================================
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
    IF @subject_entity IS NULL OR @subject_entity NOT IN (N'EMPLOYEE', N'ASSET')
        SET @subject_entity = N'EMPLOYEE';
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


-- =====================================================================
-- 8. sp_event_profile_set_status -- Activate / Deactivate
--
--    Deactivating stops the profile matching anyone from the next raise
--    onwards. Instances already raised keep their snapshot and are not
--    touched -- they are a record of what was served, not a live view.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_profile_set_status
    @organization_id BIGINT,
    @profile_id      BIGINT,
    @status          NVARCHAR(30),
    @actor           NVARCHAR(100) = 'api'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @profile_id IS NULL
        THROW 67440, 'sp_event_profile_set_status: organization_id and profile_id are required.', 1;
    IF @status NOT IN (N'Active', N'Inactive')
        THROW 67441, 'sp_event_profile_set_status: status must be Active or Inactive.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.event_profile
                    WHERE profile_id = @profile_id AND organization_id = @organization_id)
        THROW 67442, 'sp_event_profile_set_status: profile not found in this organization.', 1;

    UPDATE grac_practice.event_profile
       SET status     = @status,
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
     WHERE profile_id      = @profile_id
       AND organization_id = @organization_id;

    IF OBJECT_ID('grac_practice.event_audit','U') IS NOT NULL
        INSERT INTO grac_practice.event_audit
            (organization_id, entity_type, entity_id, action, actor, new_value, entered_dt)
        VALUES
            (@organization_id, N'EventProfile', @profile_id,
             CASE WHEN @status = N'Active' THEN N'Activate' ELSE N'Deactivate' END,
             @actor, CONCAT(N'status=', @status), SYSUTCDATETIME());

    SELECT @profile_id AS ProfileId, @status AS Status;
END;
GO


-- =====================================================================
-- 9. sp_event_profile_delete
--
--    Refuses once the profile has been used. An applicability decision
--    or an event instance is the recorded reason a checklist was or was
--    not served; deleting the profile behind it destroys the only
--    explanation. Deactivate instead -- which is what the error says.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_profile_delete
    @organization_id BIGINT,
    @profile_id      BIGINT,
    @actor           NVARCHAR(100) = 'api'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @profile_id IS NULL
        THROW 67450, 'sp_event_profile_delete: organization_id and profile_id are required.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.event_profile
                    WHERE profile_id = @profile_id AND organization_id = @organization_id)
        THROW 67451, 'sp_event_profile_delete: profile not found in this organization.', 1;

    IF EXISTS (SELECT 1 FROM grac_practice.event_obligation_applicability
                WHERE profile_id = @profile_id)
        THROW 67452, 'sp_event_profile_delete: this profile has obligation decisions recorded against it. Deactivate it instead.', 1;

    IF EXISTS (SELECT 1 FROM grac_practice.event_instance
                WHERE scope_profile_id = @profile_id)
        THROW 67453, 'sp_event_profile_delete: this profile has raised event instances. Deactivate it instead.', 1;

    BEGIN TRAN;

    DELETE FROM grac_practice.event_profile_criteria_value WHERE profile_id = @profile_id;
    DELETE FROM grac_practice.event_profile_criteria       WHERE profile_id = @profile_id;
    DELETE FROM grac_practice.event_profile
     WHERE profile_id = @profile_id AND organization_id = @organization_id;

    IF OBJECT_ID('grac_practice.event_audit','U') IS NOT NULL
        INSERT INTO grac_practice.event_audit
            (organization_id, entity_type, entity_id, action, actor, new_value, entered_dt)
        VALUES
            (@organization_id, N'EventProfile', @profile_id, N'Delete', @actor,
             N'profile deleted (no decisions or instances existed)', SYSUTCDATETIME());

    COMMIT TRAN;

    SELECT @profile_id AS ProfileId;
END;
GO


-- =====================================================================
-- 10. sp_event_profile_preview_members
--
--     Who does this profile actually match?
--
--     Without this an admin builds a population blind and finds out it
--     was empty weeks later, when nobody's onboarding produced a
--     checklist. The count is the whole point; the sample is there so
--     "42 people" can be sanity-checked against two names.
--
--     @profile_id is optional: passing a saved profile previews it,
--     while the create form passes none and gets the unconstrained
--     count, so the two numbers can be compared before saving.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_profile_preview_members
    @organization_id BIGINT,
    @profile_id      BIGINT = NULL,
    @sample_size     INT    = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 67460, 'sp_event_profile_preview_members: organization_id is required.', 1;
    IF @sample_size IS NULL OR @sample_size < 1 SET @sample_size = 10;
    IF @sample_size > 100 SET @sample_size = 100;

    DECLARE @total INT = (
        SELECT COUNT(1) FROM grac_practice.organization_employee e
         WHERE e.organization_id = @organization_id AND e.status = N'Active');

    IF @profile_id IS NULL
    BEGIN
        SELECT @total AS MatchedCount, @total AS TotalActiveEmployees;

        SELECT TOP (@sample_size)
               e.employee_id   AS EmployeeId,
               e.employee_code AS EmployeeCode,
               e.employee_name AS EmployeeName,
               e.designation   AS Designation
        FROM   grac_practice.organization_employee e
        WHERE  e.organization_id = @organization_id AND e.status = N'Active'
        ORDER BY e.employee_name;
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM grac_practice.event_profile
                    WHERE profile_id = @profile_id AND organization_id = @organization_id)
        THROW 67461, 'sp_event_profile_preview_members: profile not found in this organization.', 1;

    DECLARE @matched INT = (
        SELECT COUNT(1)
        FROM   grac_practice.organization_employee e
        WHERE  e.organization_id = @organization_id
          AND  e.status          = N'Active'
          AND  EXISTS (SELECT 1
                       FROM grac_practice.fn_pm_event_profile_matches(
                                @organization_id, N'EMPLOYEE', e.employee_id) m
                       WHERE m.profile_id = @profile_id));

    SELECT @matched AS MatchedCount, @total AS TotalActiveEmployees;

    SELECT TOP (@sample_size)
           e.employee_id   AS EmployeeId,
           e.employee_code AS EmployeeCode,
           e.employee_name AS EmployeeName,
           e.designation   AS Designation
    FROM   grac_practice.organization_employee e
    WHERE  e.organization_id = @organization_id
      AND  e.status          = N'Active'
      AND  EXISTS (SELECT 1
                   FROM grac_practice.fn_pm_event_profile_matches(
                            @organization_id, N'EMPLOYEE', e.employee_id) m
                   WHERE m.profile_id = @profile_id)
    ORDER BY e.employee_name;
END;
GO


-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'vw_pm_event_profile_subject_attribute' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_event_profile_subject_attribute','V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'fn_pm_event_profile_matches',
       CASE WHEN OBJECT_ID('grac_practice.fn_pm_event_profile_matches','IF') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_profile_dimension_list',
       CASE WHEN OBJECT_ID('grac_practice.sp_event_profile_dimension_list','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_profile_dimension_values',
       CASE WHEN OBJECT_ID('grac_practice.sp_event_profile_dimension_values','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_profile_list',
       CASE WHEN OBJECT_ID('grac_practice.sp_event_profile_list','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_profile_get',
       CASE WHEN OBJECT_ID('grac_practice.sp_event_profile_get','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_profile_save',
       CASE WHEN OBJECT_ID('grac_practice.sp_event_profile_save','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_profile_set_status',
       CASE WHEN OBJECT_ID('grac_practice.sp_event_profile_set_status','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_profile_delete',
       CASE WHEN OBJECT_ID('grac_practice.sp_event_profile_delete','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_profile_preview_members',
       CASE WHEN OBJECT_ID('grac_practice.sp_event_profile_preview_members','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

PRINT '330 Event Profile procedures installed.';
PRINT 'NEXT: run 331_event_profile_resolution_procs.sql -- until it runs, profiles can be created but nothing resolves against them.';
GO

SET NOEXEC OFF;
GO
