-- =====================================================================
-- 547 ROLLBACK  Restores sp_org_assurance_plan_approve (090 body): Approve
--   ends at Approved; Activate is a separate step. Revert the Web file
--   with it. ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_approve
    @organization_id BIGINT, @plan_id BIGINT, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_plan_transition
        @organization_id = @organization_id, @plan_id = @plan_id,
        @expected_from_code = N'Submitted', @to_code = N'Approved', @actor = @actor;
END
GO
PRINT '547 rolled back.';
GO
