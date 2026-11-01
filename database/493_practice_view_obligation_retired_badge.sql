-- =====================================================================
-- 493 Practice View: "Retired in repository" on published obligations
--
-- Change request 2026-10-26: when Control Management retires an obligation
-- and the organization approves that Repository Update (395, flag only --
-- sir's decision 4), Practice View must mark the obligation the way the
-- Operationalize workspace card already does (396).
--
-- WHAT THIS SCRIPT DOES
--   dbo.sp_pm_view_obligations_typed (394 body, verbatim) returns one more
--   column, RepositoryLifecycleStatus = organization_obligation.lifecycle_status.
--   Nothing else changes: the row set, order and paging are the same, and a
--   retired obligation is still listed (it stays adopted -- decision 4).
--   The API passes the column through untouched (generic dictionary read);
--   practice-view.cshtml draws the badge.
--
-- Requires 391-396. SAFE TO RE-RUN. ASCII-only.
-- Rollback: 493_practice_view_obligation_retired_badge_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('grac_practice.organization_obligation','lifecycle_status') IS NULL
   OR COL_LENGTH('grac_practice.organization_obligation','obligation_name') IS NULL
   OR OBJECT_ID('grac_practice.organization_obligation_requirement_map','U') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_org_obligation_typed_detail','V') IS NULL
BEGIN
    PRINT 'ABORT (493): run 391-396 first.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- dbo.sp_pm_view_obligations_typed (from 394; 493 edit marked)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_pm_view_obligations_typed
    @p_organization_requirement_id BIGINT       = NULL,
    @p_practice_id                 BIGINT       = NULL,
    @p_practice_instance_id        BIGINT       = NULL,
    @p_search                      NVARCHAR(200) = N'',
    @p_offset                      INT           = 0,
    @p_page_size                   INT           = 200
AS
BEGIN
    SET NOCOUNT ON;

    IF @p_page_size IS NULL OR @p_page_size <= 0 SET @p_page_size = 200;
    IF @p_page_size > 500 SET @p_page_size = 500;
    IF @p_offset IS NULL OR @p_offset < 0 SET @p_offset = 0;
    IF @p_search IS NULL SET @p_search = N'';

    IF @p_organization_requirement_id IS NULL
       AND @p_practice_id IS NULL
       AND @p_practice_instance_id IS NULL
    BEGIN
        RAISERROR('sp_pm_view_obligations_typed: pass at least one of @p_organization_requirement_id / @p_practice_id / @p_practice_instance_id.', 16, 1);
        RETURN;
    END

    -- ------------------------------------------------------------------
    -- Context CTEs -- mirror the existing 'evidence-obligations' branch
    -- of pm_get_practice_repository so the projection matches the same
    -- set of reachable obligations.
    -- ------------------------------------------------------------------
    ;WITH context_requirement AS (
        SELECT DISTINCT
            req.organization_requirement_id,
            req.organization_id,
            COALESCE(req.repository_requirement_id, repo_req.requirement_id) repository_requirement_id,
            req.org_statement_id,
            req.organization_control_id,
            oc.repository_control_id,
            COALESCE(ofs.release_id, oc.release_id) context_release_id
        FROM grac_practice.organization_requirement req
        LEFT JOIN grac_practice.organization_framework_statements ofs
            ON ofs.org_statement_id = req.org_statement_id AND ofs.organization_id = req.organization_id
        LEFT JOIN grac_practice.organization_control oc
            ON oc.organization_control_id = req.organization_control_id AND oc.organization_id = req.organization_id
        LEFT JOIN grac_practice.organization_repository_requirement repo_req
            ON repo_req.organization_id = req.organization_id
           AND repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
        WHERE (@p_organization_requirement_id IS NOT NULL AND req.organization_requirement_id = @p_organization_requirement_id)
           OR (@p_practice_id IS NOT NULL AND EXISTS(
                 SELECT 1 FROM grac_practice.practice p
                 WHERE p.practice_id = @p_practice_id
                   AND p.organization_requirement_id = req.organization_requirement_id))
           OR (@p_practice_instance_id IS NOT NULL AND EXISTS(
                 SELECT 1 FROM grac_practice.practice_instance pi
                 JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
                 WHERE pi.practice_instance_id = @p_practice_instance_id
                   AND p.organization_requirement_id = req.organization_requirement_id))
    ),
    distinct_requirements AS (
        SELECT DISTINCT repository_requirement_id, organization_id
        FROM context_requirement
        WHERE repository_requirement_id IS NOT NULL
    ),
    distinct_obligations AS (
        -- 394: the organization's approved obligation copy.
        SELECT DISTINCT dr.organization_id, orm.obligation_id
        FROM distinct_requirements dr
        JOIN grac_practice.organization_obligation_requirement_map orm
            ON orm.organization_id = dr.organization_id
           AND orm.requirement_id = dr.repository_requirement_id
           AND orm.status = N'Active'
    )
    SELECT
        rel.release_id AS FrameworkReleaseId,
        rel.FrameworkRelease,
        o.obligation_id AS ObligationId,
        COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''), LEFT(o.obligation_text, 300)) AS ObligationName,
        -- (301) The authored text, in full and untruncated. ObligationName
        -- above already falls back to LEFT(obligation_text, 300) when an
        -- obligation was published without a name, so the two can carry the
        -- same words -- the Practice View suppresses the second line in that
        -- case rather than printing it twice.
        o.obligation_text                                                                     AS ObligationText,
        o.obligation_type_id AS ObligationTypeId,
        t.type_code AS TypeCode,
        t.type_name AS TypeName,
        COALESCE(exec_freq.option_label, o.frequency_type) AS ExecutionFrequency,
        o.retention_requirement AS ObligationRetention,
        o.approval_authority AS ApprovalAuthority,
        o.responsibility AS Responsibility,
        -- Per-type detail JSON, now from vw_pm_obligation_typed_detail.
        COALESCE(td.StateRulesJson,      N'[]') AS StateRulesJson,
        COALESCE(td.ExecutionSpecsJson,  N'[]') AS ExecutionSpecsJson,
        COALESCE(td.AssuranceSpecsJson,  N'[]') AS AssuranceSpecsJson,
        COALESCE(td.EventResponsesJson,  N'[]') AS EventResponsesJson,
        COALESCE(td.ConstraintRulesJson, N'[]') AS ConstraintRulesJson,
        COALESCE(td.RetentionSpecsJson,  N'[]') AS RetentionSpecsJson,
        COALESCE(td.EvidenceJson,        N'[]') AS EvidenceJson,
        -- 493: approved repository retirement (395 flag) -- Practice View
        -- shows "Retired in repository", same as the Operationalize card (396).
        o.lifecycle_status                       AS RepositoryLifecycleStatus
    FROM distinct_obligations dob
    JOIN grac_practice.organization_obligation o
        ON o.organization_id = dob.organization_id
       AND o.obligation_id = dob.obligation_id AND o.status = N'Active'
    LEFT JOIN GRAC_New.obligation_type_master t
        ON t.obligation_type_id = o.obligation_type_id
    LEFT JOIN GRAC_New.reference_option exec_freq
        ON exec_freq.reference_option_id = o.execution_frequency_id
    LEFT JOIN grac_practice.vw_pm_org_obligation_typed_detail td
        ON td.OrganizationId = dob.organization_id
       AND td.ObligationId = dob.obligation_id
    OUTER APPLY (
        -- One representative release per obligation (no row multiplication)
        SELECT TOP 1
            r.release_id,
            COALESCE(a.artifact_code + N' ' + r.version_no,
                     a.artifact_name + N' ' + r.version_no,
                     r.version_no) AS FrameworkRelease
        FROM distinct_requirements dr2
        JOIN grac_practice.organization_obligation_requirement_map orm2
            ON orm2.organization_id = dr2.organization_id
           AND orm2.requirement_id = dr2.repository_requirement_id
           AND orm2.obligation_id = dob.obligation_id
           AND orm2.status = N'Active'
        JOIN GRAC_New.release r ON r.release_id = orm2.release_id
        LEFT JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
    ) rel
    WHERE (@p_search = N''
           OR COALESCE(o.obligation_name, o.obligation_text) LIKE N'%' + @p_search + N'%'
           OR ISNULL(rel.FrameworkRelease, N'') LIKE N'%' + @p_search + N'%'
           OR ISNULL(t.type_name, N'') LIKE N'%' + @p_search + N'%')
    ORDER BY ISNULL(t.display_order, 999),
             rel.FrameworkRelease,
             COALESCE(o.obligation_name, o.obligation_text)
    OFFSET @p_offset ROWS FETCH NEXT @p_page_size ROWS ONLY;
END
GO

SELECT '493 proc returns RepositoryLifecycleStatus' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.sp_pm_view_obligations_typed')) LIKE '%lifecycle_status%RepositoryLifecycleStatus%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '493 complete. Deploy Web next (practice-view.cshtml). The API needs no change.';
GO

SET NOEXEC OFF;
GO
