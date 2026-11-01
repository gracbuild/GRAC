-- =====================================================================
-- 460_view_scope_practices_statements.sql
--
-- WHY
-- ---
-- A role on View Data Scope = Assigned Owner (415) still saw every row on
-- Organization Practices and Control Statements (reported 2026-10-09,
-- user1 / role "User", org 10). 415's row-level security policy covers
-- nine tables (practice_instance, practice_task, custom_gap, ...); the
-- requirement / practice / statement tables those two lists read were
-- never in it, so nothing filtered them.
--
-- WHAT
-- ----
-- Two inline predicates, built on 415's own fn_pm_view_scope_owner (and
-- so on fn_pm_view_scope_core -- one definition of Owner / Team /
-- Location), applied by the API in the two LIST queries
-- (PracticeRepositoryService: QueryOrganizationRequirementFallbackAsync,
-- QueryReleaseStatementsAsync, QueryCustomReleaseStatementsAsync):
--
--   fn_pm_view_scope_requirement(@organization_requirement_id)
--     An Organization Practice is visible when the reader is unrestricted,
--     OR its practice owner is in the reader's scope
--     (practice.practice_owner_id), OR one of its practice instances is
--     visible to the reader. The instance test needs no logic of its own:
--     practice_instance is filtered by 415's policy, so EXISTS over it
--     already answers Owner / Team / Location for the instance.
--     (Chosen 2026-10-09: "Practice Owner OR Instance Owner".)
--
--   fn_pm_view_scope_statement(@owner_employee_id, @organization_id,
--                              @framework_statement_id, @org_statement_id)
--     A Control Statement is visible when the reader is unrestricted, OR
--     the statement owner is in the reader's scope, OR a practice mapped
--     to it (organization_statement_practice_mapping) is visible by the
--     rule above. A statement with no owner and no visible mapped
--     practice is hidden from a restricted reader.
--     (Chosen 2026-10-09: "Statement Owner OR mapped practice owner".)
--
-- Why not add these tables to the 415 security policy: practice /
-- organization_requirement / organization_framework_statements are joined
-- by almost every screen (instance, task, gap, risk lists show practice
-- and statement names). Filtering them for every read would drop a
-- reader's OWN instances and tasks from those lists whenever the practice
-- above them belongs to someone else. The scope is therefore applied to
-- the two lists whose rows ARE practices / statements, and nowhere else.
--
-- Unrestricted readers (SESSION_CONTEXT 'pm_view_scope' not set -- every
-- role on All records, writes, workers) see exactly what they saw before.
--
-- No table or column changes. SAFE TO RE-RUN. Requires 031, 415.
-- Deploy with the matching Api build (it calls these functions).
-- Rollback: database/460_view_scope_practices_statements_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.fn_pm_view_scope_owner') IS NULL
   OR OBJECT_ID('grac_practice.organization_statement_practice_mapping','U') IS NULL
   OR COL_LENGTH('grac_practice.practice','practice_owner_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance','practice_id') IS NULL
BEGIN
    PRINT 'ABORT (460): run 031 and 415 first.';
    SET NOEXEC ON;
END
GO

-- 1. Organization Practice ---------------------------------------------
CREATE OR ALTER FUNCTION grac_practice.fn_pm_view_scope_requirement
    (@organization_requirement_id BIGINT)
RETURNS TABLE
AS
RETURN
SELECT 1 AS fn_result
 WHERE SESSION_CONTEXT(N'pm_view_scope') IS NULL
    -- practice owner in the reader's scope
    OR EXISTS (SELECT 1
                 FROM grac_practice.practice p
                CROSS APPLY grac_practice.fn_pm_view_scope_owner(p.practice_owner_id) v
                WHERE p.organization_requirement_id = @organization_requirement_id)
    -- an instance the reader may see (practice_instance is RLS-filtered, 415)
    OR EXISTS (SELECT 1
                 FROM grac_practice.practice p
                 JOIN grac_practice.practice_instance pi ON pi.practice_id = p.practice_id
                WHERE p.organization_requirement_id = @organization_requirement_id);
GO

-- 2. Control Statement -------------------------------------------------
-- Repository statements are mapped by framework_statement_id (as the
-- statement grid's own counts are); custom statements by org_statement_id.
CREATE OR ALTER FUNCTION grac_practice.fn_pm_view_scope_statement
    (@owner_employee_id      BIGINT,
     @organization_id        BIGINT,
     @framework_statement_id BIGINT,
     @org_statement_id       BIGINT)
RETURNS TABLE
AS
RETURN
SELECT 1 AS fn_result
 WHERE SESSION_CONTEXT(N'pm_view_scope') IS NULL
    OR EXISTS (SELECT 1 FROM grac_practice.fn_pm_view_scope_owner(@owner_employee_id))
    OR EXISTS (SELECT 1
                 FROM grac_practice.organization_statement_practice_mapping m
                CROSS APPLY grac_practice.fn_pm_view_scope_requirement(m.org_practice_id) r
                WHERE m.organization_id = @organization_id
                  AND m.status = N'Active'
                  AND (   (@org_statement_id IS NOT NULL AND m.org_statement_id = @org_statement_id)
                       OR (@framework_statement_id IS NOT NULL AND m.framework_statement_id = @framework_statement_id)));
GO

-- =====================================================================
-- Verification (this session has no scope set -> both return one row)
-- =====================================================================
SELECT '460-a requirement predicate, unrestricted session' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.fn_pm_view_scope_requirement(NULL)) = 1
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '460-b statement predicate, unrestricted session',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.fn_pm_view_scope_statement(NULL, NULL, NULL, NULL)) = 1
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT 'Migration 460_view_scope_practices_statements applied. Deploy the matching Api build.';
GO

SET NOEXEC OFF;
GO
