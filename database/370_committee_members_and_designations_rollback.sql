-- =====================================================================
-- 370_committee_members_and_designations_rollback.sql
--
-- Drops the objects added by 370: the two Committee Members lookup
-- shims, the Add Designation shim, the gateway shim, the save
-- procedure, the organization_committee_member mapping table, and the
-- committee_designation_master table. dbo.pm_manage_practice_repository
-- and dbo.pm_get_practice_repository's own 'committees' branches were
-- never touched by 370, so nothing needs restoring there -- Committee
-- save/list simply falls back to whatever PracticeRepositoryService
-- routes 'committees' to once this rollback runs (the monolith, if the
-- service-side ResolveProcedureAsync mapping for 'committees' isManage
-- is also reverted).
--
-- WHAT YOU LOSE: every Committee's member list, and every organization's
-- custom Committee Designations. The report below lists both before
-- they are discarded. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT '--- Data about to be discarded: committee member mappings ---';
IF OBJECT_ID('grac_practice.organization_committee_member','U') IS NOT NULL
    EXEC('SELECT cm.organization_id, c.committee_name, cm.employee_id, e.employee_code, e.employee_name, d.designation_name, cm.status
            FROM grac_practice.organization_committee_member cm
            JOIN grac_practice.organization_committee c ON c.committee_id = cm.committee_id
            JOIN grac_practice.organization_employee e ON e.employee_id = cm.employee_id
            JOIN grac_practice.committee_designation_master d ON d.designation_id = cm.designation_id
           ORDER BY cm.organization_id, c.committee_name, e.employee_name;');
GO

PRINT '--- Data about to be discarded: organization-specific committee designations ---';
IF OBJECT_ID('grac_practice.committee_designation_master','U') IS NOT NULL
    EXEC('SELECT designation_id, organization_id, designation_name, is_active
            FROM grac_practice.committee_designation_master
           WHERE organization_id IS NOT NULL
           ORDER BY organization_id, designation_name;');
GO

BEGIN TRAN;

IF OBJECT_ID('grac_practice.sp_org_committee_designation_manage','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_committee_designation_manage;

IF OBJECT_ID('grac_practice.sp_get_committee_designation_lookup','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_get_committee_designation_lookup;

IF OBJECT_ID('grac_practice.sp_get_committee_member_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_get_committee_member_list;

IF OBJECT_ID('grac_practice.sp_org_committee_repository_manage','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_committee_repository_manage;

IF OBJECT_ID('grac_practice.sp_org_committee_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_committee_save;

IF OBJECT_ID('grac_practice.organization_committee_member','U') IS NOT NULL
    DROP TABLE grac_practice.organization_committee_member;

IF OBJECT_ID('grac_practice.committee_designation_master','U') IS NOT NULL
    DROP TABLE grac_practice.committee_designation_master;

COMMIT;
GO

PRINT '370 rollback: Committee Members + Committee Designation Master objects dropped.';
GO
