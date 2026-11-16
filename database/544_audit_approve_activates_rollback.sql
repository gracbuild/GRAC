-- =====================================================================
-- 544 ROLLBACK  Restores sp_org_assurance_definition_approve (070 body):
--   Approve ends at Approved again; Activate is a separate step.
--   Revert the Web files with it. ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_approve
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @reason_text     NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_definition_transition
        @organization_id    = @organization_id,
        @definition_id      = @definition_id,
        @expected_from_code = N'UnderReview',
        @to_code            = N'Approved',
        @action_code        = N'APPROVE',
        @reason_text        = @reason_text,
        @actor              = @actor;
END
GO
PRINT '544 rolled back.';
GO
