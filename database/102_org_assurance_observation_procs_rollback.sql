-- =====================================================================
-- 102 rollback -- Organization Assurance Observation procedures
-- =====================================================================
SET NOCOUNT ON;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_history_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_evidence_delete;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_evidence_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_evidence_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_close;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_resolve;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_reject;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_accept;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_submit_review;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_transition;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_delete;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_type_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_status_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_severity_list;
GO

PRINT '102 Organization Assurance Observation procedures rolled back.';
GO
