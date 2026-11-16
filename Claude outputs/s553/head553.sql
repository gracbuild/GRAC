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
