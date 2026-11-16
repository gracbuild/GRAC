-- =====================================================================
-- 544  Approving an audit makes it Active
--
-- REQUEST (2026-11-13, sir)
--   Approve should make the audit Active at once -- no separate Activate.
--
-- WHAT THIS DOES
--   sp_org_assurance_definition_approve (070 body) now runs the two
--   lifecycle transitions it is made of, one after the other, through the
--   same helper (sp_org_assurance_definition_transition, 070):
--     UnderReview -> Approved  (APPROVE: approved_by / approved_dt)
--     Approved    -> Active    (ACTIVATE: activated_by / activated_dt,
--                               active_version_id = the approved version)
--   History therefore gets both rows, APPROVE then ACTIVATE, with the same
--   reason. Same parameters, so the Api (POST definitions/{id}/approve)
--   is unchanged and simply ends at Active.
--
--   No outer transaction: the helper opens and rolls back its own, so
--   nesting it would turn a failure into a transaction-count error on top
--   of the real one. If the second step ever failed, the audit is left
--   Approved -- exactly the old state -- and Audit Definition still offers
--   Activate for an Approved audit (also for audits approved before 544).
--
-- NOT CHANGED: sp_org_assurance_definition_activate, the transition
--   helper, the review gate (537), tables, statuses.
-- Rollback: 544_audit_approve_activates_rollback.sql (070 body).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_definition_transition','P') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_status_master WHERE status_code = N'Active')
   OR NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_status_master WHERE status_code = N'Approved')
BEGIN
    PRINT 'ABORT (544): run 070 first (transition helper, Approved / Active statuses). Nothing was changed.';
    RAISERROR('544_audit_approve_activates: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_approve
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @reason_text     NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Under Review -> Approved (070, unchanged).
    EXEC grac_practice.sp_org_assurance_definition_transition
        @organization_id    = @organization_id,
        @definition_id      = @definition_id,
        @expected_from_code = N'UnderReview',
        @to_code            = N'Approved',
        @action_code        = N'APPROVE',
        @reason_text        = @reason_text,
        @actor              = @actor;

    -- 2. 544: Approved -> Active straight away (what Activate did).
    EXEC grac_practice.sp_org_assurance_definition_transition
        @organization_id    = @organization_id,
        @definition_id      = @definition_id,
        @expected_from_code = N'Approved',
        @to_code            = N'Active',
        @action_code        = N'ACTIVATE',
        @reason_text        = @reason_text,
        @actor              = @actor;
END
GO

SELECT '544 approve also activates' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_definition_approve')) LIKE '%ACTIVATE%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '544 complete. No Api restart needed; publish Web.';
GO
SET NOEXEC OFF;
GO
