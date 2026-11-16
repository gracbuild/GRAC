-- =====================================================================
-- 547  Approving a plan makes it Active
--
-- REQUEST (2026-11-14, sir)
--   As for audits (544): approving a plan should make it Active at once,
--   with no separate Activate.
--
-- WHAT THIS DOES
--   sp_org_assurance_plan_approve (090 body) runs both plan transitions
--   through the 090 helper, one after the other:
--     Submitted -> Approved, then Approved -> Active.
--   Same parameters, so the Api (POST plans/{id}/approve) is unchanged and
--   simply ends at Active. The helper runs one UPDATE per call and opens
--   no transaction of its own; this procedure wraps both in one, so the
--   plan never stops half-way.
--
-- NOT CHANGED: sp_org_assurance_plan_activate (still there for a plan left
--   Approved before 547), the helper, close, tables.
-- Rollback: 547_audit_plan_approve_activates_rollback.sql (090 body).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_plan_transition','P') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_status_master WHERE status_code = N'Active')
BEGIN
    PRINT 'ABORT (547): run 089 / 090 first. Nothing was changed.';
    RAISERROR('547_audit_plan_approve_activates: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_approve
    @organization_id BIGINT, @plan_id BIGINT, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRAN;

    -- 1. Submitted -> Approved (090, unchanged).
    EXEC grac_practice.sp_org_assurance_plan_transition
        @organization_id = @organization_id, @plan_id = @plan_id,
        @expected_from_code = N'Submitted', @to_code = N'Approved', @actor = @actor;

    -- 2. 547: Approved -> Active straight away (what Activate did).
    EXEC grac_practice.sp_org_assurance_plan_transition
        @organization_id = @organization_id, @plan_id = @plan_id,
        @expected_from_code = N'Approved', @to_code = N'Active', @actor = @actor;

    COMMIT;
END
GO

SELECT '547 plan approve also activates' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_plan_approve')) LIKE '%N''Active''%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '547 complete. No Api restart needed; publish Web.';
GO
SET NOEXEC OFF;
GO
