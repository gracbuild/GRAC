-- =====================================================================
-- 553  Role Responsibilities -- what a role DOES (Auditor, Audit Reviewer,
--      Audit Approver ...); the engagement's Assigned Auditor lists only
--      people whose role carries the Auditor responsibility
--
-- REQUEST (2026-11-14, sir)
--   The engagement dialog asked for a Role and then a person; the role is
--   always the auditor's -- ask only for the auditor and list only
--   auditors. Nothing marked a role as an auditor role. A first cut (an
--   "Auditor role" tick on Role Master) was replaced the same day, at
--   sir's request, by a general mechanism so that the next such need
--   (Audit Reviewer, Approver ...) is a master row, not a new column.
--
-- MODEL
--   role_responsibility_master          global list: code (fixed, used by
--                                       the screens), name, order. Seeded:
--                                       AUDITOR, AUDIT_REVIEWER,
--                                       AUDIT_APPROVER. More are rows.
--   organization_role_responsibility    role -> responsibilities (many).
--   Distinct from menu permissions (which SCREENS a role may use): this is
--   what JOB the role does. Screens ask for "the people whose role has
--   responsibility <code>".
--
-- WHAT THIS DOES
--   1. The two tables + the three seed rows.
--   2. If the first cut ran (organization_role.is_auditor_role exists):
--      every ticked role gets the AUDITOR responsibility; its procedure
--      sp_org_auditor_list is dropped. The column is left in place, unread.
--   3. sp_org_role_save (465 body) saves '$.responsibilityIds' (Role
--      Master's Responsibilities multi-select); sp_org_role_list (465
--      body) returns ResponsibilityIds (comma list, for the form) and
--      Responsibilities (names, for the grid). The gateway shims
--      (sp_org_role_repository_manage / _get) are unchanged.
--   4. NEW sp_get_role_responsibility_lookup -- the "role-responsibilities"
--      lookup (gateway shim shape, as sp_get_time_zone_lookup, 361).
--   5. NEW sp_org_responsibility_holder_list(@organization_id,
--      @responsibility_code) -- active people whose role
--      (organization_employee.role_id, the sp_org_role_holders_list rule,
--      117) is active and carries the responsibility.
--
-- DEPENDS ON: 465.
-- Rollback: 553_role_responsibilities_rollback.sql (465 bodies; drops the
--   new procedures; the tables are kept).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_role_save','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_role_list','P') IS NULL
BEGIN
    PRINT 'ABORT (553): run 465 first. Nothing was changed.';
    RAISERROR('553_role_responsibilities: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Tables and seed
-- =====================================================================
IF OBJECT_ID('grac_practice.role_responsibility_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.role_responsibility_master(
        role_responsibility_id INT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_role_resp PRIMARY KEY,
        responsibility_code    NVARCHAR(60)  NOT NULL
            CONSTRAINT uq_pm_role_resp_code UNIQUE,
        responsibility_name    NVARCHAR(120) NOT NULL,
        description            NVARCHAR(500) NULL,
        display_order          INT NOT NULL CONSTRAINT df_pm_role_resp_order DEFAULT 0,
        is_active              BIT NOT NULL CONSTRAINT df_pm_role_resp_active DEFAULT 1,
        entered_by             NVARCHAR(100) NOT NULL CONSTRAINT df_pm_role_resp_ent_by DEFAULT 'system',
        entered_dt             DATETIME2 NOT NULL CONSTRAINT df_pm_role_resp_ent_dt DEFAULT SYSUTCDATETIME(),
        updated_by             NVARCHAR(100) NULL,
        updated_dt             DATETIME2 NULL
    );
    PRINT '553.1: role_responsibility_master created.';
END
GO

IF OBJECT_ID('grac_practice.organization_role_responsibility','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.organization_role_responsibility(
        organization_role_responsibility_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_org_role_resp PRIMARY KEY,
        organization_id        BIGINT NOT NULL,
        role_id                BIGINT NOT NULL,
        role_responsibility_id INT    NOT NULL,
        is_active              BIT NOT NULL CONSTRAINT df_pm_org_role_resp_active DEFAULT 1,
        entered_by             NVARCHAR(100) NOT NULL CONSTRAINT df_pm_org_role_resp_ent_by DEFAULT 'system',
        entered_dt             DATETIME2 NOT NULL CONSTRAINT df_pm_org_role_resp_ent_dt DEFAULT SYSUTCDATETIME(),
        updated_by             NVARCHAR(100) NULL,
        updated_dt             DATETIME2 NULL,
        CONSTRAINT fk_pm_org_role_resp_org
            FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT fk_pm_org_role_resp_role
            FOREIGN KEY(role_id) REFERENCES grac_practice.organization_role(role_id),
        CONSTRAINT fk_pm_org_role_resp_resp
            FOREIGN KEY(role_responsibility_id) REFERENCES grac_practice.role_responsibility_master(role_responsibility_id)
    );
    CREATE UNIQUE INDEX uq_pm_org_role_resp_active
        ON grac_practice.organization_role_responsibility(role_id, role_responsibility_id)
        WHERE is_active = 1;
    PRINT '553.1: organization_role_responsibility created.';
END
GO

MERGE grac_practice.role_responsibility_master AS t
USING (VALUES
    (N'AUDITOR',        N'Auditor',        N'Performs audits: assigned to audit engagements and executions.', 10),
    (N'AUDIT_REVIEWER', N'Audit Reviewer', N'Reviews audit work and findings.',                              20),
    (N'AUDIT_APPROVER', N'Audit Approver', N'Approves audit results.',                                       30)
) AS s(code, name, descr, ord)
ON t.responsibility_code = s.code
WHEN NOT MATCHED THEN
    INSERT (responsibility_code, responsibility_name, description, display_order, is_active, entered_by)
    VALUES (s.code, s.name, s.descr, s.ord, 1, N'seed-553');
GO

-- =====================================================================
-- 2. From the first cut: roles ticked "Auditor role" -> AUDITOR
-- =====================================================================
IF COL_LENGTH('grac_practice.organization_role','is_auditor_role') IS NOT NULL
BEGIN
    DECLARE @moved INT;
    EXEC sp_executesql N'
        INSERT INTO grac_practice.organization_role_responsibility
            (organization_id, role_id, role_responsibility_id, is_active, entered_by)
        SELECT r.organization_id, r.role_id, m.role_responsibility_id, 1, N''migration-553''
          FROM grac_practice.organization_role r
          JOIN grac_practice.role_responsibility_master m ON m.responsibility_code = N''AUDITOR''
         WHERE r.is_auditor_role = 1
           AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_responsibility x
                            WHERE x.role_id = r.role_id
                              AND x.role_responsibility_id = m.role_responsibility_id
                              AND x.is_active = 1);
        SET @n = @@ROWCOUNT;', N'@n INT OUTPUT', @n = @moved OUTPUT;
    PRINT '553.2: roles ticked "Auditor role" moved to the AUDITOR responsibility = ' + CAST(@moved AS NVARCHAR(20));
END
IF OBJECT_ID('grac_practice.sp_org_auditor_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_auditor_list;
GO

-- =====================================================================
-- 3. Role save / list (465 bodies + 553)
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

    -- 553: the role's responsibilities -- '$.responsibilityIds', the
    -- Responsibilities multi-select (an array of ids, as strings or
    -- numbers). Absent from the payload = left as they are; an empty
    -- array clears them.
    IF JSON_QUERY(@p_payload, '$.responsibilityIds') IS NOT NULL
    BEGIN
        DECLARE @resp TABLE (role_responsibility_id INT NOT NULL PRIMARY KEY);
        INSERT INTO @resp (role_responsibility_id)
        SELECT DISTINCT m.role_responsibility_id
          FROM OPENJSON(@p_payload, '$.responsibilityIds') j
          JOIN grac_practice.role_responsibility_master m
               ON m.role_responsibility_id = TRY_CAST(j.[value] AS INT)
         WHERE m.is_active = 1;

        UPDATE rr
           SET is_active = 0, updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.organization_role_responsibility rr
         WHERE rr.role_id = @out_id AND rr.is_active = 1
           AND rr.role_responsibility_id NOT IN (SELECT role_responsibility_id FROM @resp);

        INSERT INTO grac_practice.organization_role_responsibility
            (organization_id, role_id, role_responsibility_id, is_active, entered_by)
        SELECT @role_org_id, @out_id, x.role_responsibility_id, 1, @p_usr_id
          FROM @resp x
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_responsibility rr
                            WHERE rr.role_id = @out_id AND rr.role_responsibility_id = x.role_responsibility_id
                              AND rr.is_active = 1);
    END
END;
GO

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
           -- 553: the role's responsibilities -- ids for the form's
           -- multi-select (comma list, read by comboChecks) and names for
           -- the grid.
           rsp.ids ResponsibilityIds, rsp.names Responsibilities,
           r.record_status_id StatusId, rs.status_name Status,
           COUNT(*) OVER () AS TotalRows
    FROM   grac_practice.organization_role r
    JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
    JOIN   grac_practice.record_status_master rs ON rs.record_status_id = r.record_status_id
    OUTER APPLY (SELECT STRING_AGG(CAST(m.role_responsibility_id AS NVARCHAR(20)), N',')
                            WITHIN GROUP (ORDER BY m.display_order) AS ids,
                        STRING_AGG(CONVERT(NVARCHAR(MAX), m.responsibility_name), N', ')
                            WITHIN GROUP (ORDER BY m.display_order) AS names
                   FROM grac_practice.organization_role_responsibility x
                   JOIN grac_practice.role_responsibility_master m
                        ON m.role_responsibility_id = x.role_responsibility_id
                  WHERE x.role_id = r.role_id AND x.is_active = 1 AND m.is_active = 1) rsp
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
-- 4. The "role-responsibilities" lookup (gateway shim shape, as 361's
--    sp_get_time_zone_lookup)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_get_role_responsibility_lookup
    @p_entity_type NVARCHAR(100) = 'role-responsibilities',
    @p_action      NVARCHAR(30)  = 'QUERY',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30)  = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SELECT N'role-responsibilities'                     AS LookupKey,
           CAST(role_responsibility_id AS NVARCHAR(40)) AS Value,
           responsibility_name                          AS Label,
           responsibility_code                          AS Code,
           CAST(NULL AS BIGINT)                         AS ParentId
      FROM grac_practice.role_responsibility_master
     WHERE is_active = 1
     ORDER BY display_order, responsibility_name;
END;
GO

-- =====================================================================
-- 5. sp_org_responsibility_holder_list -- people whose role carries a
--    responsibility (AUDITOR for the engagement's Assigned Auditor)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_responsibility_holder_list
    @organization_id     BIGINT,
    @responsibility_code NVARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR NULLIF(LTRIM(RTRIM(@responsibility_code)), N'') IS NULL
        THROW 55100, 'organization_id and responsibility_code are required.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    SELECT e.employee_id   AS EmployeeId,
           e.employee_code AS EmployeeCode,
           e.employee_name AS EmployeeName,
           e.designation   AS Designation,
           r.role_id       AS RoleId,
           r.role_name     AS RoleName
    FROM grac_practice.organization_employee e
    JOIN grac_practice.organization_role r
         ON r.role_id = e.role_id
    WHERE e.organization_id  = @organization_id
      AND e.status           = N'Active'
      AND e.record_status_id = @active_record_status_id
      AND r.record_status_id = @active_record_status_id
      AND EXISTS (SELECT 1
                    FROM grac_practice.organization_role_responsibility x
                    JOIN grac_practice.role_responsibility_master m
                         ON m.role_responsibility_id = x.role_responsibility_id
                   WHERE x.role_id = r.role_id
                     AND x.is_active = 1
                     AND m.is_active = 1
                     AND m.responsibility_code = @responsibility_code)
    ORDER BY e.employee_name, e.employee_id;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '553 tables and seed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.organization_role_responsibility','U') IS NOT NULL
             AND EXISTS (SELECT 1 FROM grac_practice.role_responsibility_master WHERE responsibility_code = N'AUDITOR')
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '553 role save / list carry responsibilities',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_role_save')) LIKE '%responsibilityIds%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_role_list')) LIKE '%ResponsibilityIds%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '553 lookup and holder list',
       CASE WHEN OBJECT_ID('grac_practice.sp_get_role_responsibility_lookup','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_responsibility_holder_list','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
PRINT '553 complete. Restart the Api and publish Web; give the auditor roles the Auditor responsibility in Role Master.';
GO
SET NOEXEC OFF;
GO
