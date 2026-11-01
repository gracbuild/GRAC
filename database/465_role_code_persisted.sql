-- =====================================================================
-- 465_role_code_persisted.sql
--
-- THE FAULT
-- ---------
-- Role Master -> Add Role: the Role Code typed into the form is never
-- stored, and the field is blank on the grid and on the Edit form.
--
-- WHY -- two independent gaps, both in the gateway monolith
-- --------------------------------------------------------
-- 1. SAVE. dbo.pm_manage_practice_repository's @p_entity_type='roles'
--    branch (current body in 404) reads organizationId, roleName,
--    description and status out of @p_payload. It never reads
--    '$.roleCode', and role_code is not in its INSERT column list nor in
--    its UPDATE SET list. The posted code is silently dropped.
--
-- 2. READ. dbo.pm_get_practice_repository's 'roles' branch (same file)
--    projects Id, OrganizationId, Organization, RoleName, Description,
--    StatusId, Status, TotalRows. There is no RoleCode column, so even a
--    stored code could not reach the grid -- and the Edit form seeds from
--    this same branch (WHERE @p_id=0 OR r.role_id=@p_id), which is why
--    Edit shows it blank too.
--
-- The column has existed since 027, together with a UNIQUE filtered index
-- ux_pm_org_role_code on (organization_id, role_code) WHERE role_code IS
-- NOT NULL AND role_code <> ''. 034 and 217 populate role_code for the
-- roles they seed, so seeded roles DO carry a code -- only roles created
-- through the screen lose it, which is what makes the column look broken
-- rather than unused. The Api already maps SQL error 51150 to the
-- roleCode field (PracticeRepositoryService.FieldForSqlError), for a
-- duplicate-code THROW that was never written.
--
-- WHAT THIS DOES
-- --------------
-- Follows the gateway SHIM pattern 134 established and 361 (locations)
-- and 419 (assets) reused -- the monolith is 2,000-plus lines and
-- CREATE OR ALTER can only replace it whole, so an entity whose save or
-- projection needs new columns gets a dedicated pair instead:
--
--   grac_practice.sp_org_role_save              -- the 404 roles save
--                                                  branch + role_code
--   grac_practice.sp_org_role_list              -- the 404 roles read
--                                                  branch + RoleCode
--   grac_practice.sp_org_role_repository_manage -- SAVE here, every other
--                                                  action handed back to
--                                                  the monolith
--   grac_practice.sp_org_role_repository_get    -- QUERY here
--
-- 419 hit exactly this bug on assets and recorded it the same way: "The
-- monolith's projection never returned asset_subcategory_id /
-- asset_type_id, so the Edit form opened with both blank and Save wrote
-- NULL over them."
--
-- Behaviour deliberately preserved from the monolith's own roles branch:
-- the same 51140 / 51141 / 51142 validations in the same order, status
-- written from '$.status' as a string with record_status_id resolved from
-- '$.statusId' or '$.status', and RETIRE left entirely to the monolith so
-- its generic organization-access check still runs.
--
-- NEW: role_code is stored, and a duplicate code in the same
-- organization THROWs 51150 -- the number the Api already maps to the
-- roleCode field. Without that check the filtered unique index would
-- surface as a raw 2601 index violation with no field to attach it to.
-- A blank code is stored as NULL, not '', matching the index's own
-- filter so any number of roles may have no code.
--
-- The Api change is one entry in ResolveProcedureAsync. It probes with
-- ShimExistsAsync and falls back to the monolith when the procedures are
-- absent, so this script and the Api can be deployed in either order.
--
-- No schema change. No data migration -- existing roles keep whatever
-- role_code they have (NULL for any created through the screen so far;
-- those have to be re-entered, there is nothing to recover them from).
--
-- SAFE TO RE-RUN (CREATE OR ALTER). Requires 027 (role_code +
-- ux_pm_org_role_code) and 404 (the monolith these two branches came
-- from). Rollback: database/465_role_code_persisted_rollback.sql
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Guard on the COLUMNS and objects these bodies read, not merely on the
-- tables existing: both procedures are lifted from an earlier
-- migration's body.
IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_audit_trace','U') IS NULL
   OR OBJECT_ID('dbo.pm_manage_practice_repository','P') IS NULL
BEGIN
    PRINT 'ABORT (465): run 002 / 027 / 404 first.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.organization_role','role_code') IS NULL
   OR COL_LENGTH('grac_practice.organization_role','role_name') IS NULL
   OR COL_LENGTH('grac_practice.organization_role','description') IS NULL
   OR COL_LENGTH('grac_practice.organization_role','record_status_id') IS NULL
BEGIN
    PRINT 'ABORT (465): organization_role.role_code missing. Run 027_organization_access_administration.sql first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_org_role_save -- the 404 'roles' save branch + role_code
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_role_save
    @p_payload NVARCHAR(MAX),
    @p_id      BIGINT = 0,
    @p_usr_id  NVARCHAR(100) = 'system',
    @out_id    BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Same derivation the monolith does at the top of its save, so the
    -- status a role ends up on is identical either side of this boundary.
    DECLARE @active_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = 'Active');
    DECLARE @payload_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master
          WHERE status_code = JSON_VALUE(@p_payload,'$.status') OR status_name = JSON_VALUE(@p_payload,'$.status'));
    DECLARE @payload_record_status_id_from_id INT = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload,'$.statusId'),''));
    SET @payload_record_status_id = COALESCE(@payload_record_status_id_from_id, @payload_record_status_id);

    DECLARE @role_org_id BIGINT       = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
    DECLARE @role_name   NVARCHAR(120)= NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.roleName'))),'');
    -- 465. NULL, not '': ux_pm_org_role_code is filtered on
    -- role_code IS NOT NULL AND role_code <> '', so storing '' for "no
    -- code" would be outside the index on some rows and inside it on
    -- others. NULL keeps every blank out of it, so any number of roles
    -- may carry no code. NVARCHAR(60) matches the column from 027.
    DECLARE @role_code   NVARCHAR(60) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.roleCode'))),'');

    -- ---- the monolith's validation, unchanged and in the same order ----
    IF @role_org_id IS NULL THROW 51140,'Organization is required for Role.',1;
    IF @role_name IS NULL THROW 51141,'Role Name is required.',1;
    IF EXISTS(SELECT 1 FROM grac_practice.organization_role
               WHERE organization_id = @role_org_id AND LOWER(role_name) = LOWER(@role_name)
                 AND (@p_id = 0 OR role_id <> @p_id))
        THROW 51142,'Role Name already exists for this organization.',1;

    -- ---- 465 validation ----
    -- The friendly form of the ux_pm_org_role_code violation. 51150 is
    -- the number PracticeRepositoryService already maps to the roleCode
    -- field, so this error lands on the Role Code input instead of
    -- reaching the operator as a bare index error. Only checked when a
    -- code was actually supplied -- blanks are NULL and the index
    -- ignores them.
    IF @role_code IS NOT NULL
       AND EXISTS(SELECT 1 FROM grac_practice.organization_role
                   WHERE organization_id = @role_org_id AND LOWER(role_code) = LOWER(@role_code)
                     AND (@p_id = 0 OR role_id <> @p_id))
        THROW 51150,'Role Code already exists for this organization.',1;

    IF @p_id = 0
    BEGIN
        INSERT grac_practice.organization_role
            (organization_id, role_name, role_code, description,
             status, record_status_id, entered_by)
        VALUES
            (@role_org_id, @role_name, @role_code, JSON_VALUE(@p_payload,'$.description'),
             COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),
             COALESCE(@payload_record_status_id, @active_record_status_id), @p_usr_id);
        SET @out_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_role
           SET organization_id  = @role_org_id,
               role_name        = @role_name,
               role_code        = @role_code,
               description      = JSON_VALUE(@p_payload,'$.description'),
               status           = COALESCE(JSON_VALUE(@p_payload,'$.status'), status),
               record_status_id = COALESCE(@payload_record_status_id, record_status_id),
               updated_by       = @p_usr_id,
               updated_dt       = SYSUTCDATETIME()
         WHERE role_id = @p_id;
        SET @out_id = @p_id;
    END
END;
GO

-- =====================================================================
-- 2. sp_org_role_list -- the 404 'roles' read branch + RoleCode
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_role_list
    @p_id            BIGINT = 0,
    @organization_id BIGINT = NULL,
    @p_status        NVARCHAR(30) = '',
    @p_search        NVARCHAR(250) = '',
    @p_page_number   INT = 1,
    @p_page_size     INT = 25
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @filter_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master
          WHERE status_code = @p_status OR status_name = @p_status);
    DECLARE @offset INT = (CASE WHEN @p_page_number < 1 THEN 1 ELSE @p_page_number END - 1)
                          * CASE WHEN @p_page_size < 1 THEN 25 ELSE @p_page_size END;
    DECLARE @page_size INT = CASE WHEN @p_page_size < 1 THEN 25 ELSE @p_page_size END;

    SELECT r.role_id Id, r.organization_id OrganizationId, o.organization_name Organization,
           r.role_code RoleCode,                       -- 465: was absent entirely
           r.role_name RoleName, r.description Description,
           r.record_status_id StatusId, rs.status_name Status,
           COUNT(*) OVER () AS TotalRows
    FROM   grac_practice.organization_role r
    JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
    JOIN   grac_practice.record_status_master rs ON rs.record_status_id = r.record_status_id
    WHERE  (@p_id = 0 OR r.role_id = @p_id)
      AND  (@organization_id IS NULL OR r.organization_id = @organization_id)
      AND  (@p_status = '' OR r.record_status_id = @filter_record_status_id)
      -- 465: role_code joins the searchable fields. The column is on the
      -- grid, and a column you can see but not search reads as broken.
      AND  (@p_search = '' OR r.role_name LIKE '%'+@p_search+'%'
                           OR ISNULL(r.role_code,'') LIKE '%'+@p_search+'%'
                           OR ISNULL(r.description,'') LIKE '%'+@p_search+'%')
    ORDER  BY r.role_name
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- =====================================================================
-- 3. The gateway shims -- 134's shape, 361's wording, only the names
--    and the inner save differ.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_role_repository_manage
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
    EXEC grac_practice.sp_org_role_save
         @p_payload = @p_payload, @p_id = @p_id, @p_usr_id = @p_usr_id,
         @out_id = @new_id OUTPUT;

    -- Same audit row the monolith writes, so the trace stays continuous
    -- across the boundary.
    INSERT grac_practice.practice_audit_trace
        (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (@p_entity_type, @new_id, N'SAVE', @p_payload, 'Active', @p_usr_id);

    COMMIT;

    -- Shape the Web layer already reads: Role Master's Add flow takes the
    -- new role id off this row and switches the open dialog to Edit so the
    -- menu-permission matrix beside the fields can be written.
    SELECT CAST(1 AS BIT) Success, N'Saved successfully.' Message, @new_id Id;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_role_repository_get
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

    EXEC grac_practice.sp_org_role_list
         @p_id            = @p_id,
         @organization_id = @organization_id,
         @p_status        = @p_status,
         @p_search        = @p_search,
         @p_page_number   = @page_number,
         @p_page_size     = @page_size;
END;
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 465 verification ===';

SELECT '465 all four procedures exist' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_role_save','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_role_list','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_role_repository_manage','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_role_repository_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '465 save writes role_code',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_role_save','P')) LIKE '%$.roleCode%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '465 save throws 51150 on a duplicate code',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_role_save','P')) LIKE '%51150%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '465 list projects RoleCode',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_role_list','P')) LIKE '%RoleCode%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '465 manage shim hands non-SAVE back to the monolith',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_role_repository_manage','P'))
                 LIKE '%pm_manage_practice_repository%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '465 ux_pm_org_role_code still present (the index 51150 fronts)',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                         WHERE name = 'ux_pm_org_role_code'
                           AND object_id = OBJECT_ID('grac_practice.organization_role'))
            THEN 'PASS' ELSE 'INFO (index absent -- 027 not applied here)' END;
GO

-- Information: roles created through the screen before this migration
-- have no code and have to be re-entered. Nothing can recover them --
-- the value was never written anywhere.
SELECT r.organization_id AS OrganizationId,
       COUNT(1)          AS RolesWithNoCode
FROM   grac_practice.organization_role r
WHERE  NULLIF(LTRIM(RTRIM(ISNULL(r.role_code, N''))), N'') IS NULL
GROUP  BY r.organization_id
ORDER  BY r.organization_id;
GO

SET NOEXEC OFF;
GO
