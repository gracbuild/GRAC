-- =====================================================================
-- 105 rollback -- Organization Assurance Gap procedures
-- Also restores original sp_org_assurance_observation_accept (see 102).
-- =====================================================================
SET NOCOUNT ON;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_history_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_action_delete;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_action_complete;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_action_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_action_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_reopen;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_close;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_verify;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_submit_remediation;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_start;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_transition;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_generate_from_observation;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_delete;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_status_list;
GO

-- Restore the pre-105 accept (no gap hook).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_accept
    @organization_id BIGINT, @observation_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_observation_transition
        @organization_id = @organization_id, @observation_id = @observation_id,
        @expected_from_codes = N'InReview', @to_code = N'Accepted',
        @stamp_field = N'accepted', @notes = @notes, @actor = @actor;
END
GO

PRINT '105 Organization Assurance Gap procedures rolled back.';
GO
