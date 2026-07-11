-- =====================================================================
-- 028 Diagnose "database scripts are not aligned" (SQL error 207/208)
-- Run this in the SAME database the PracticeManagement API uses
-- (ConnectionStrings:PracticeManagement in PracticeManagement.Api).
-- It reports the exact missing column/table and whether the deployed
-- procedures are the current version.
-- =====================================================================
SET NOCOUNT ON;

-- 1. Confirm which database/server you are actually in.
SELECT DB_NAME() DatabaseName, @@SERVERNAME ServerName;

-- 2. Are the deployed procedures the current (027-aware) version?
SELECT o.name ProcedureName,
       o.modify_date LastDeployedUtc,
       CASE WHEN m.definition LIKE '%user-role-assignments%' THEN 'CURRENT (has 027 branches)' ELSE 'OLD VERSION - re-run 02_Create_Procedures.sql' END VersionState
FROM sys.objects o
JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.name IN ('pm_get_practice_repository','pm_manage_practice_repository');

-- 3. Schema objects the current procedures depend on.
SELECT CheckName, CASE WHEN Present = 1 THEN 'OK' ELSE '*** MISSING - run the script listed ***' END State, RequiredBy
FROM (VALUES
 ('organization_role.role_code column',        CASE WHEN COL_LENGTH('grac_practice.organization_role','role_code') IS NOT NULL THEN 1 ELSE 0 END, 'script 027'),
 ('organization_employee_role table',          CASE WHEN OBJECT_ID('grac_practice.organization_employee_role','U') IS NOT NULL THEN 1 ELSE 0 END, 'script 027'),
 ('organization_role table',                   CASE WHEN OBJECT_ID('grac_practice.organization_role','U') IS NOT NULL THEN 1 ELSE 0 END, 'script 022'),
 ('organization_role_menu_permission table',   CASE WHEN OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL THEN 1 ELSE 0 END, 'script 022'),
 ('menu_master table',                         CASE WHEN OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL THEN 1 ELSE 0 END, 'script 022'),
 ('organization_employee.role_id column',      CASE WHEN COL_LENGTH('grac_practice.organization_employee','role_id') IS NOT NULL THEN 1 ELSE 0 END, 'script 022'),
 ('organization_framework_statements table',   CASE WHEN OBJECT_ID('grac_practice.organization_framework_statements','U') IS NOT NULL THEN 1 ELSE 0 END, 'script 011/05 statement flow'),
 ('organization_requirement.org_statement_id', CASE WHEN COL_LENGTH('grac_practice.organization_requirement','org_statement_id') IS NOT NULL THEN 1 ELSE 0 END, 'script 011/05 statement flow'),
 ('applicability_status_master table',         CASE WHEN OBJECT_ID('grac_practice.applicability_status_master','U') IS NOT NULL THEN 1 ELSE 0 END, 'script 013')
) checks(CheckName, Present, RequiredBy);

-- 4. Execute the failing query directly and surface the REAL SQL error.
DECLARE @organization_id BIGINT = (SELECT TOP 1 organization_id FROM grac_practice.organization WHERE status='Active' ORDER BY organization_id);
-- Include the server security context so the proc's organization access
-- gate (THROW 51052) lets the diagnostic through to the entity branch.
DECLARE @payload NVARCHAR(MAX) = N'{"organizationId":' + CAST(ISNULL(@organization_id,0) AS NVARCHAR(20))
    + N',"allowedOrganizationIds":[' + CAST(ISNULL(@organization_id,0) AS NVARCHAR(20)) + N']'
    + N',"_security":{"isSystemAdmin":true,"subject":"diagnostic"}'
    + N',"pageNumber":1,"pageSize":5}';
BEGIN TRY
    EXEC dbo.pm_get_practice_repository
        @p_entity_type = N'organization-requirements',
        @p_action = N'QUERY',
        @p_id = 0,
        @p_search = N'',
        @p_status = N'',
        @p_payload = @payload,
        @p_usr_id = N'diagnostic';
    SELECT 'organization-requirements query executed successfully.' Result;
END TRY
BEGIN CATCH
    SELECT 'organization-requirements query FAILED' Result,
           ERROR_NUMBER() ErrorNumber,
           ERROR_MESSAGE() ErrorMessage,   -- names the exact missing column/object
           ERROR_PROCEDURE() ErrorProcedure,
           ERROR_LINE() ErrorLine;
END CATCH;
