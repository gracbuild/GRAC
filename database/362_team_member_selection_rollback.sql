-- =====================================================================
-- 362_team_member_selection_rollback.sql
--
-- Drops the Team Member Selection lookup procedure and the
-- organization_team_member mapping table added by 362. Roll this back
-- BEFORE reverting the 133 edits that reference organization_team_member
-- (sp_org_team_save's member-sync block, sp_org_team_list's MemberIds /
-- MemberNames columns), or those procedures will fail at runtime
-- referencing a table that no longer exists.
--
-- WHAT YOU LOSE: every Team's list of selected members. The report
-- below lists the mappings about to be discarded so they can be
-- captured before the table goes. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT '--- Data about to be discarded: team member mappings ---';
IF OBJECT_ID('grac_practice.organization_team_member','U') IS NOT NULL
    EXEC('SELECT tm.organization_id, t.team_name, tm.employee_id, e.employee_code, e.employee_name, tm.status
            FROM grac_practice.organization_team_member tm
            JOIN grac_practice.organization_team t ON t.team_id = tm.team_id
            JOIN grac_practice.organization_employee e ON e.employee_id = tm.employee_id
           ORDER BY tm.organization_id, t.team_name, e.employee_name;');
GO

BEGIN TRAN;

IF OBJECT_ID('grac_practice.sp_get_team_department_employee_tree','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_get_team_department_employee_tree;

IF OBJECT_ID('grac_practice.organization_team_member','U') IS NOT NULL
    DROP TABLE grac_practice.organization_team_member;

COMMIT;
GO

PRINT '362 rollback: sp_get_team_department_employee_tree and organization_team_member dropped.';
GO
