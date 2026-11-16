-- =====================================================================
-- 538 ROLLBACK  drops sp_org_assurance_admin_workflow_template_stage_list.
--   Revert the Api / Web files with it. ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_admin_workflow_template_stage_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_admin_workflow_template_stage_list;
GO
PRINT 'ROLLBACK 538 complete.';
GO
