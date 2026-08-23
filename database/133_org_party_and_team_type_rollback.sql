-- =====================================================================
-- 133 Personnel type + team sourcing type -- ROLLBACK
--
-- Drops the six new procedures and the added columns. The monolith
-- dbo.pm_manage_practice_repository / pm_get_practice_repository were never
-- modified, so 'users' and 'teams' fall straight back to them once the
-- gateway routing is reverted -- revert that FIRST, or the gateway will
-- call procedures that no longer exist.
--
-- WHAT YOU LOSE: the record of which users are third-party personnel and
-- which teams are vendor-managed, including the provider and vendor links.
-- That is real compliance data, not configuration. The report below lists
-- it so it can be captured before the columns go.
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT '--- Data about to be discarded: third-party personnel ---';
IF COL_LENGTH('grac_practice.organization_employee','party_type') IS NOT NULL
    EXEC('SELECT e.organization_id, e.employee_code, e.employee_name, e.email,
                 e.party_type, e.provider_vendor_id, v.vendor_name AS Provider,
                 e.engagement_start_dt, e.engagement_end_dt
            FROM grac_practice.organization_employee e
            LEFT JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id = e.provider_vendor_id
           WHERE e.party_type = N''ThirdParty''
           ORDER BY e.organization_id, e.employee_name;');
GO

PRINT '--- Data about to be discarded: vendor-managed teams ---';
IF COL_LENGTH('grac_practice.organization_team','team_type') IS NOT NULL
    EXEC('SELECT t.organization_id, t.team_name, t.team_type, t.vendor_id, v.vendor_name AS Vendor
            FROM grac_practice.organization_team t
            LEFT JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id = t.vendor_id
           WHERE t.team_type = N''Vendor''
           ORDER BY t.organization_id, t.team_name;');
GO

BEGIN TRAN;

-- ---------------------------------------------------------------------
-- Procedures
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_org_team_list','P')            IS NOT NULL DROP PROCEDURE grac_practice.sp_org_team_list;
GO
IF OBJECT_ID('grac_practice.sp_org_team_save','P')            IS NOT NULL DROP PROCEDURE grac_practice.sp_org_team_save;
GO
IF OBJECT_ID('grac_practice.sp_org_user_list','P')            IS NOT NULL DROP PROCEDURE grac_practice.sp_org_user_list;
GO
IF OBJECT_ID('grac_practice.sp_org_user_save','P')            IS NOT NULL DROP PROCEDURE grac_practice.sp_org_user_save;
GO
IF OBJECT_ID('grac_practice.sp_org_team_type_list','P')       IS NOT NULL DROP PROCEDURE grac_practice.sp_org_team_type_list;
GO
IF OBJECT_ID('grac_practice.sp_org_personnel_type_list','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_org_personnel_type_list;
GO

-- ---------------------------------------------------------------------
-- organization_team
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_team_vendor_required')
    ALTER TABLE grac_practice.organization_team DROP CONSTRAINT ck_pm_team_vendor_required;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_team_team_type')
    ALTER TABLE grac_practice.organization_team DROP CONSTRAINT ck_pm_team_team_type;
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_team_vendor')
    ALTER TABLE grac_practice.organization_team DROP CONSTRAINT fk_pm_team_vendor;
GO
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_team_team_type')
    ALTER TABLE grac_practice.organization_team DROP CONSTRAINT df_pm_team_team_type;
GO
IF COL_LENGTH('grac_practice.organization_team','vendor_id') IS NOT NULL
    ALTER TABLE grac_practice.organization_team DROP COLUMN vendor_id;
GO
IF COL_LENGTH('grac_practice.organization_team','team_type') IS NOT NULL
    ALTER TABLE grac_practice.organization_team DROP COLUMN team_type;
GO

-- ---------------------------------------------------------------------
-- organization_employee
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ix_pm_employee_party_type'
             AND object_id = OBJECT_ID('grac_practice.organization_employee'))
    DROP INDEX ix_pm_employee_party_type ON grac_practice.organization_employee;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_employee_engagement_dates')
    ALTER TABLE grac_practice.organization_employee DROP CONSTRAINT ck_pm_employee_engagement_dates;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_employee_provider_required')
    ALTER TABLE grac_practice.organization_employee DROP CONSTRAINT ck_pm_employee_provider_required;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_employee_party_type')
    ALTER TABLE grac_practice.organization_employee DROP CONSTRAINT ck_pm_employee_party_type;
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_employee_provider_vendor')
    ALTER TABLE grac_practice.organization_employee DROP CONSTRAINT fk_pm_employee_provider_vendor;
GO
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_employee_party_type')
    ALTER TABLE grac_practice.organization_employee DROP CONSTRAINT df_pm_employee_party_type;
GO
IF COL_LENGTH('grac_practice.organization_employee','engagement_end_dt') IS NOT NULL
    ALTER TABLE grac_practice.organization_employee DROP COLUMN engagement_end_dt;
GO
IF COL_LENGTH('grac_practice.organization_employee','engagement_start_dt') IS NOT NULL
    ALTER TABLE grac_practice.organization_employee DROP COLUMN engagement_start_dt;
GO
IF COL_LENGTH('grac_practice.organization_employee','provider_vendor_id') IS NOT NULL
    ALTER TABLE grac_practice.organization_employee DROP COLUMN provider_vendor_id;
GO
IF COL_LENGTH('grac_practice.organization_employee','party_type') IS NOT NULL
    ALTER TABLE grac_practice.organization_employee DROP COLUMN party_type;
GO

COMMIT TRAN;
GO

SELECT 'employee columns removed' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.organization_employee','party_type') IS NULL
             AND COL_LENGTH('grac_practice.organization_employee','provider_vendor_id') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'team columns removed',
       CASE WHEN COL_LENGTH('grac_practice.organization_team','team_type') IS NULL
             AND COL_LENGTH('grac_practice.organization_team','vendor_id') IS NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'procedures removed',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_user_save','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_org_team_save','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '133 rolled back. Revert the gateway routing for users / teams if you have not already.';
GO
