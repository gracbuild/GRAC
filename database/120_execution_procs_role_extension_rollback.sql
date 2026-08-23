-- =====================================================================
-- 120 rollback -- drop the new SP + reapply 099 to restore prior shape.
-- The role columns added by 115 are left in place.
-- =====================================================================
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_execution_entity_auditor_assign','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_execution_entity_auditor_assign;
GO
PRINT '120 rollback: re-run 099_org_assurance_execution_procs.sql to restore prior SP shape.';
GO
