-- =====================================================================
-- 273 MSP organization -- ROLLBACK
--
-- Removes the MSP tenant that 273 provisioned: the organisation row and
-- the structure, roles, admin account, access grants and risk framework
-- that hang off it.
--
-- SAFETY GATE (this is the important part)
--   273 creates an EMPTY tenant. Once someone subscribes MSP to a
--   release, generates practices, opens tasks, raises gaps or uploads
--   documents, deleting the organisation is data loss, not a rollback.
--   Section 1 therefore counts the "real work" tables and ABORTS if any
--   of them holds a row for MSP. Set @ForceWhenInUse = 1 only if you have
--   consciously decided to lose that work and have a backup.
--
--   Even with the gate passed, a DELETE can still fail on a foreign key
--   this script does not know about (a newer migration pointing at
--   organization_employee, say). That failure is the correct outcome:
--   fix or remove the dependent rows, then re-run.
--
-- WHAT IS NOT TOUCHED
--   Every global master. Those belong to 272; roll them back with
--   272_master_data_seed_rollback.sql.
--
-- Re-runnable: yes. A second run finds nothing to delete.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @OrgCode NVARCHAR(80) = N'MSP';
DECLARE @org_id  BIGINT =
    (SELECT organization_id FROM grac_practice.organization WHERE organization_code = @OrgCode);

IF @org_id IS NULL
BEGIN
    PRINT '273 rollback: organisation MSP not found -- nothing to do.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Safety gate -- does MSP hold real work?
-- =====================================================================
-- ---------------------------------------------------------------------
-- OPERATOR SWITCH -- edit this one line only
-- ---------------------------------------------------------------------
DECLARE @ForceWhenInUse BIT = 0;   -- 1 = delete MSP even if it holds work
-- ---------------------------------------------------------------------

DECLARE @org_id BIGINT =
    (SELECT organization_id FROM grac_practice.organization WHERE organization_code = N'MSP');

DECLARE @work TABLE(table_name SYSNAME PRIMARY KEY, row_count_ INT);
DECLARE @probe TABLE(seq INT IDENTITY(1,1) PRIMARY KEY, table_name SYSNAME);
INSERT @probe(table_name) VALUES
    (N'repository_subscription'), (N'organization_control'), (N'organization_requirement'),
    (N'organization_framework_statements'), (N'organization_statement_applicability'),
    (N'practice'), (N'practice_instance'), (N'practice_task'), (N'task_candidate'),
    (N'custom_gap'), (N'practice_gap'), (N'exception_request'), (N'document_upload'),
    (N'risk_candidate'), (N'risk_register'), (N'org_assurance_definition'),
    (N'organization_dependency_application'), (N'organization_dependency_tool'),
    (N'organization_dependency_vendor'), (N'organization_dependency_asset'),
    (N'organization_dependency_process');

DECLARE @seq INT = 1, @max_seq INT = (SELECT MAX(seq) FROM @probe);
DECLARE @tbl SYSNAME, @sql NVARCHAR(MAX), @cnt INT;

WHILE @seq <= @max_seq
BEGIN
    SELECT @tbl = table_name FROM @probe WHERE seq = @seq;
    SET @cnt = 0;

    IF OBJECT_ID(N'grac_practice.' + QUOTENAME(@tbl), 'U') IS NOT NULL
       AND COL_LENGTH(N'grac_practice.' + QUOTENAME(@tbl), 'organization_id') IS NOT NULL
    BEGIN
        SET @sql = N'SELECT @c = COUNT_BIG(1) FROM grac_practice.' + QUOTENAME(@tbl)
                 + N' WHERE organization_id = @o;';
        EXEC sys.sp_executesql @sql, N'@c INT OUTPUT, @o BIGINT', @c = @cnt OUTPUT, @o = @org_id;
    END

    IF @cnt > 0 INSERT @work(table_name, row_count_) VALUES(@tbl, @cnt);
    SET @seq = @seq + 1;
END

IF EXISTS(SELECT 1 FROM @work)
BEGIN
    SELECT 'MSP holds rows in this table' AS Check_, table_name AS Table_, row_count_ AS Count_
    FROM @work ORDER BY table_name;

    IF @ForceWhenInUse = 0
    BEGIN
        PRINT 'ABORT (273 rollback): MSP is in use -- see the tables listed above.';
        PRINT 'Set @ForceWhenInUse = 1 at the top of section 1 if you really mean to lose that work.';
        RAISERROR('273_msp_organization_setup_rollback: organisation MSP is in use.', 16, 1);
        SET NOEXEC ON;
    END
    ELSE
        PRINT '273 rollback: @ForceWhenInUse = 1 -- proceeding despite the rows listed above.';
END
ELSE
    PRINT '273 rollback: MSP holds no practice, task, gap, document or dependency rows. Safe to remove.';
GO

-- =====================================================================
-- 2. Delete MSP, children first.
--    One transaction: a foreign key this script does not know about
--    rolls the whole thing back rather than leaving a half-deleted org.
-- =====================================================================
BEGIN TRANSACTION;

DECLARE @org_id BIGINT =
    (SELECT organization_id FROM grac_practice.organization WHERE organization_code = N'MSP');
DECLARE @AdminEmail NVARCHAR(250) = N'msp.admin@grac.in';

-- 2a. Risk framework (org-scoped; seeded by sp_risk_scoring_seed_default)
IF OBJECT_ID('grac_practice.risk_matrix_cell','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.risk_matrix_cell WHERE organization_id = @org_id;
    PRINT '273 rollback: risk_matrix_cell rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

IF OBJECT_ID('grac_practice.risk_likelihood_master','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.risk_likelihood_master WHERE organization_id = @org_id;
    PRINT '273 rollback: risk_likelihood_master rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

IF OBJECT_ID('grac_practice.risk_impact_master','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.risk_impact_master WHERE organization_id = @org_id;
    PRINT '273 rollback: risk_impact_master rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

IF OBJECT_ID('grac_practice.risk_category_master','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.risk_category_master WHERE organization_id = @org_id;
    PRINT '273 rollback: risk_category_master rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

-- 2b. Access grants
IF OBJECT_ID('grac_practice.feature_flag','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.feature_flag WHERE organization_id = @org_id;
    PRINT '273 rollback: feature_flag rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
BEGIN
    DELETE p
    FROM grac_practice.organization_role_menu_permission p
    JOIN grac_practice.organization_role r ON r.role_id = p.role_id
    WHERE r.organization_id = @org_id;
    PRINT '273 rollback: organization_role_menu_permission rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

IF OBJECT_ID('grac_practice.organization_employee_role','U') IS NOT NULL
BEGIN
    DELETE er
    FROM grac_practice.organization_employee_role er
    JOIN grac_practice.organization_employee e ON e.employee_id = er.employee_id
    WHERE e.organization_id = @org_id;
    PRINT '273 rollback: organization_employee_role rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

IF OBJECT_ID('grac_practice.user_organization_map','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.user_organization_map WHERE organization_id = @org_id;
    PRINT '273 rollback: user_organization_map rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

-- 2c. People. organization_employee.role_id points at organization_role,
--     so employees go before roles.
IF OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.organization_employee WHERE organization_id = @org_id;
    PRINT '273 rollback: organization_employee rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

IF OBJECT_ID('grac_practice.organization_role','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.organization_role WHERE organization_id = @org_id;
    PRINT '273 rollback: organization_role rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

-- 2d. Structure
IF OBJECT_ID('grac_practice.organization_team','U') IS NOT NULL
    DELETE FROM grac_practice.organization_team WHERE organization_id = @org_id;

IF OBJECT_ID('grac_practice.organization_committee','U') IS NOT NULL
    DELETE FROM grac_practice.organization_committee WHERE organization_id = @org_id;

IF OBJECT_ID('grac_practice.organization_location','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.organization_location WHERE organization_id = @org_id;
    PRINT '273 rollback: organization_location rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

IF OBJECT_ID('grac_practice.organization_department','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.organization_department WHERE organization_id = @org_id;
    PRINT '273 rollback: organization_department rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

IF OBJECT_ID('grac_practice.organization_division','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.organization_division WHERE organization_id = @org_id;
    PRINT '273 rollback: organization_division rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

IF OBJECT_ID('grac_practice.organization_business_function','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.organization_business_function WHERE organization_id = @org_id;
    PRINT '273 rollback: organization_business_function rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

IF OBJECT_ID('grac_practice.organization_metadata_value','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.organization_metadata_value WHERE organization_id = @org_id;
    PRINT '273 rollback: organization_metadata_value rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

-- 2e. The organisation itself
DELETE FROM grac_practice.organization WHERE organization_id = @org_id;
PRINT '273 rollback: organization rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

COMMIT TRANSACTION;
GO

-- =====================================================================
-- VERIFICATION
-- =====================================================================
SELECT 'MSP organisation removed' AS Check_,
       CASE WHEN EXISTS(SELECT 1 FROM grac_practice.organization WHERE organization_code = N'MSP')
            THEN 'FAIL' ELSE 'PASS' END AS Result_;

SELECT 'MSP admin account removed' AS Check_,
       CASE WHEN EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE LOWER(email) = N'msp.admin@grac.in')
            THEN 'FAIL' ELSE 'PASS' END AS Result_;

PRINT '273 rollback complete.';
GO

SET NOEXEC OFF;
GO
