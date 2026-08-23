-- =====================================================================
-- 099 rollback -- Organization Assurance Execution procedures
-- =====================================================================
SET NOCOUNT ON;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_execution_delete;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_execution_cancel;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_execution_close;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_execution_approve;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_execution_review;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_execution_submit;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_execution_start;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_execution_transition;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_execution_materialize;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_execution_entity_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_execution_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_execution_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_execution_status_list;
GO

PRINT '099 Organization Assurance Execution procedures rolled back.';
GO
