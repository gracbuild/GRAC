-- =====================================================================
-- 032 Ownership-Based Role Model
-- Adds DataScope to organization_role, owner columns to subscription
-- and custom_release_statement (if it exists), admin-credential
-- columns to employee, and creates central ownership filter functions.
-- Re-run database/deployment/02_Create_Procedures.sql AFTER this script.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 53200, 'PracticeManagement schema grac_practice is missing. Run base scripts first.', 1;
GO

DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id
    FROM grac_practice.record_status_master
    WHERE status_code = 'ACTIVE' OR status_name = 'Active'
    ORDER BY record_status_id
);
IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

-- =====================================================================
-- 1. DataScope on organization_role
-- =====================================================================
-- Valid values: GLOBAL, ORGANIZATION, RELEASE, STATEMENT, PRACTICE, INSTANCE
IF COL_LENGTH('grac_practice.organization_role', 'data_scope') IS NULL
    ALTER TABLE grac_practice.organization_role
        ADD data_scope NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_org_role_data_scope DEFAULT 'ORGANIZATION';
GO

-- Backfill existing Admin roles to GLOBAL scope
UPDATE grac_practice.organization_role
SET data_scope = 'GLOBAL'
WHERE role_name = 'Admin'
  AND data_scope = 'ORGANIZATION';
GO

-- =====================================================================
-- 2. Owner columns on repository_subscription (release ownership)
-- =====================================================================
IF COL_LENGTH('grac_practice.repository_subscription', 'owner_id') IS NULL
    ALTER TABLE grac_practice.repository_subscription
        ADD owner_id BIGINT NULL;
GO

-- FK to organization_employee
IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = 'fk_pm_subscription_owner'
      AND parent_object_id = OBJECT_ID('grac_practice.repository_subscription')
)
    ALTER TABLE grac_practice.repository_subscription
        ADD CONSTRAINT fk_pm_subscription_owner
            FOREIGN KEY (owner_id) REFERENCES grac_practice.organization_employee(employee_id);
GO

-- Index for ownership lookups
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_subscription_owner' AND object_id = OBJECT_ID('grac_practice.repository_subscription'))
    CREATE INDEX ix_pm_subscription_owner
        ON grac_practice.repository_subscription(owner_id)
        WHERE owner_id IS NOT NULL;
GO

-- =====================================================================
-- 3. Owner columns on custom_release_statement (statement ownership)
--    Only if the table exists (created by 001_practice_management_schema)
-- =====================================================================
IF OBJECT_ID('grac_practice.custom_release_statement','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.custom_release_statement', 'owner_id') IS NULL
    ALTER TABLE grac_practice.custom_release_statement
        ADD owner_id BIGINT NULL;
GO

IF OBJECT_ID('grac_practice.custom_release_statement','U') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM sys.foreign_keys
       WHERE name = 'fk_pm_custom_stmt_owner'
         AND parent_object_id = OBJECT_ID('grac_practice.custom_release_statement')
   )
    ALTER TABLE grac_practice.custom_release_statement
        ADD CONSTRAINT fk_pm_custom_stmt_owner
            FOREIGN KEY (owner_id) REFERENCES grac_practice.organization_employee(employee_id);
GO

IF OBJECT_ID('grac_practice.custom_release_statement','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_custom_stmt_owner' AND object_id = OBJECT_ID('grac_practice.custom_release_statement'))
    CREATE INDEX ix_pm_custom_stmt_owner
        ON grac_practice.custom_release_statement(owner_id)
        WHERE owner_id IS NOT NULL;
GO

-- =====================================================================
-- 4. Admin credential columns on organization_employee
-- =====================================================================
IF COL_LENGTH('grac_practice.organization_employee', 'force_password_change') IS NULL
    ALTER TABLE grac_practice.organization_employee
        ADD force_password_change BIT NOT NULL
            CONSTRAINT df_pm_employee_force_pw DEFAULT 0;
GO

IF COL_LENGTH('grac_practice.organization_employee', 'email_credentials_sent') IS NULL
    ALTER TABLE grac_practice.organization_employee
        ADD email_credentials_sent BIT NOT NULL
            CONSTRAINT df_pm_employee_cred_sent DEFAULT 0;
GO

-- =====================================================================
-- 5. Performance indexes for ownership queries
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_subscription_org_status' AND object_id = OBJECT_ID('grac_practice.repository_subscription'))
    CREATE INDEX ix_pm_subscription_org_status
        ON grac_practice.repository_subscription(organization_id, status)
        INCLUDE (owner_id, release_id, subscription_type);
GO

IF OBJECT_ID('grac_practice.custom_release_statement','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_custom_stmt_subscription' AND object_id = OBJECT_ID('grac_practice.custom_release_statement'))
    CREATE INDEX ix_pm_custom_stmt_subscription
        ON grac_practice.custom_release_statement(subscription_id, organization_id)
        INCLUDE (owner_id, status);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_org_role_data_scope' AND object_id = OBJECT_ID('grac_practice.organization_role'))
    CREATE INDEX ix_pm_org_role_data_scope
        ON grac_practice.organization_role(organization_id, data_scope)
        WHERE status = 'Active';
GO

-- =====================================================================
-- 6. Central ownership filter: fn_visible_releases
--    When custom_release_statement does not exist, the function only
--    checks repository_subscription ownership. We use dynamic SQL to
--    conditionally include the custom_release_statement UNION branch.
-- =====================================================================

-- Build the function body dynamically based on whether custom_release_statement exists
DECLARE @fn_releases NVARCHAR(MAX) = N'
CREATE OR ALTER FUNCTION grac_practice.fn_visible_releases
(
    @employee_id BIGINT,
    @data_scope  NVARCHAR(30),
    @organization_id BIGINT
)
RETURNS TABLE
AS RETURN
(
    -- GLOBAL / ORGANIZATION: see all releases in the org
    SELECT s.subscription_id
    FROM grac_practice.repository_subscription s
    WHERE s.organization_id = @organization_id
      AND s.status = ''Active''
      AND @data_scope IN (''GLOBAL'', ''ORGANIZATION'')

    UNION

    -- RELEASE: see only owned releases
    SELECT s.subscription_id
    FROM grac_practice.repository_subscription s
    WHERE s.organization_id = @organization_id
      AND s.status = ''Active''
      AND s.owner_id = @employee_id
      AND @data_scope = ''RELEASE''

    UNION

    -- STATEMENT / PRACTICE / INSTANCE: also see releases they directly own
    SELECT s.subscription_id
    FROM grac_practice.repository_subscription s
    WHERE s.organization_id = @organization_id
      AND s.status = ''Active''
      AND s.owner_id = @employee_id
      AND @data_scope IN (''STATEMENT'', ''PRACTICE'', ''INSTANCE'')
';

IF OBJECT_ID('grac_practice.custom_release_statement','U') IS NOT NULL
    SET @fn_releases = @fn_releases + N'
    UNION

    -- STATEMENT / PRACTICE / INSTANCE: releases that contain owned statements
    SELECT DISTINCT cs.subscription_id
    FROM grac_practice.custom_release_statement cs
    WHERE cs.organization_id = @organization_id
      AND cs.status = ''Active''
      AND cs.owner_id = @employee_id
      AND @data_scope IN (''STATEMENT'', ''PRACTICE'', ''INSTANCE'')
';

SET @fn_releases = @fn_releases + N'
);';

EXEC sp_executesql @fn_releases;
GO

-- =====================================================================
-- 7. Central ownership filter: fn_visible_statements
--    Only created when custom_release_statement exists.
-- =====================================================================
IF OBJECT_ID('grac_practice.custom_release_statement','U') IS NOT NULL
BEGIN
    DECLARE @fn_stmts NVARCHAR(MAX) = N'
    CREATE OR ALTER FUNCTION grac_practice.fn_visible_statements
    (
        @employee_id BIGINT,
        @data_scope  NVARCHAR(30),
        @organization_id BIGINT
    )
    RETURNS TABLE
    AS RETURN
    (
        -- GLOBAL / ORGANIZATION: see all statements
        SELECT cs.custom_statement_id
        FROM grac_practice.custom_release_statement cs
        WHERE cs.organization_id = @organization_id
          AND cs.status = ''Active''
          AND @data_scope IN (''GLOBAL'', ''ORGANIZATION'')

        UNION

        -- RELEASE: see all statements under owned releases (cascading visibility)
        SELECT cs.custom_statement_id
        FROM grac_practice.custom_release_statement cs
        JOIN grac_practice.repository_subscription s ON s.subscription_id = cs.subscription_id
        WHERE cs.organization_id = @organization_id
          AND cs.status = ''Active''
          AND s.owner_id = @employee_id
          AND @data_scope = ''RELEASE''

        UNION

        -- STATEMENT / PRACTICE / INSTANCE: directly owned statements
        SELECT cs.custom_statement_id
        FROM grac_practice.custom_release_statement cs
        WHERE cs.organization_id = @organization_id
          AND cs.status = ''Active''
          AND cs.owner_id = @employee_id
          AND @data_scope IN (''STATEMENT'', ''PRACTICE'', ''INSTANCE'')

        UNION

        -- STATEMENT / PRACTICE / INSTANCE: cascading — all statements under owned releases
        SELECT cs.custom_statement_id
        FROM grac_practice.custom_release_statement cs
        JOIN grac_practice.repository_subscription s ON s.subscription_id = cs.subscription_id
        WHERE cs.organization_id = @organization_id
          AND cs.status = ''Active''
          AND s.owner_id = @employee_id
          AND @data_scope IN (''STATEMENT'', ''PRACTICE'', ''INSTANCE'')
    );';

    EXEC sp_executesql @fn_stmts;
END
ELSE
    PRINT 'Skipped fn_visible_statements — custom_release_statement table does not exist yet.';
GO

-- =====================================================================
-- 8. Seed: Ensure existing Admin roles have GLOBAL data_scope
-- =====================================================================
UPDATE grac_practice.organization_role
SET data_scope = 'GLOBAL',
    updated_by = 'seed-032',
    updated_dt = SYSUTCDATETIME()
WHERE role_name = 'Admin'
  AND data_scope <> 'GLOBAL';
GO

-- =====================================================================
-- 9. Seed: Set owner_id on custom releases to the first Admin employee
--    of each organization (for existing data)
-- =====================================================================
IF OBJECT_ID('grac_practice.custom_release_statement','U') IS NULL
BEGIN
    -- Only seed subscription owners for Custom releases
    ;WITH first_admin AS (
        SELECT e.organization_id, MIN(e.employee_id) AS admin_employee_id
        FROM grac_practice.organization_employee e
        JOIN grac_practice.organization_role r ON r.role_id = e.role_id
            AND r.organization_id = e.organization_id
        WHERE r.role_name = 'Admin'
          AND e.status = 'Active'
        GROUP BY e.organization_id
    )
    UPDATE s
    SET s.owner_id = fa.admin_employee_id,
        s.updated_by = 'seed-032',
        s.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.repository_subscription s
    JOIN first_admin fa ON fa.organization_id = s.organization_id
    WHERE s.owner_id IS NULL
      AND s.subscription_type = 'Custom';
END
ELSE
BEGIN
    ;WITH first_admin AS (
        SELECT e.organization_id, MIN(e.employee_id) AS admin_employee_id
        FROM grac_practice.organization_employee e
        JOIN grac_practice.organization_role r ON r.role_id = e.role_id
            AND r.organization_id = e.organization_id
        WHERE r.role_name = 'Admin'
          AND e.status = 'Active'
        GROUP BY e.organization_id
    )
    UPDATE s
    SET s.owner_id = fa.admin_employee_id,
        s.updated_by = 'seed-032',
        s.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.repository_subscription s
    JOIN first_admin fa ON fa.organization_id = s.organization_id
    WHERE s.owner_id IS NULL
      AND s.subscription_type = 'Custom';
END
GO

SELECT 'Ownership Role Model migration 032 complete. Now re-run database/deployment/02_Create_Procedures.sql.' Message;
