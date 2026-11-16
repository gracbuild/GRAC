-- =====================================================================
-- 519 Practice View: obligations of the selected framework only
--
-- Change request 2026-11-05: "practice nte view edukumbo framework select
-- cheythu anu edukunnenkil aa framework nte applicable ayitulla obligations
-- mathram list cheythal mathi. ipo vere framework nte obligations koodi
-- kanikunnundu."
--
-- WHY
--   The Practices grid (organization-requirements) lists one framework
--   release at a time. Its practice is mapped to a repository requirement,
--   and that requirement's obligations can be mapped under several
--   releases (organization_obligation_requirement_map.release_id). The
--   Practice View showed all of them. It could not filter in the browser
--   either: the proc returns ONE representative FrameworkReleaseId per
--   obligation (TOP 1), so an obligation shared by two frameworks could
--   carry the other framework's id and be dropped wrongly.
--
-- WHAT THIS SCRIPT DOES
--   dbo.sp_pm_view_obligations_typed (494 body, verbatim otherwise) gains an
--   optional @p_release_id:
--     * distinct_obligations keeps only map rows of that release;
--     * the representative-release OUTER APPLY picks that release, so the
--       FrameworkRelease label matches the selected framework.
--   NULL (the default) changes nothing, so every existing caller
--   (Operationalize, Evidence Center, Practice View without a framework)
--   gets exactly the 494 result. Columns, order and paging are unchanged.
--   Practice-level (organization-defined, 307) obligations are a different
--   feed and are not filtered: they belong to the practice, not to a
--   framework.
--
-- Requires 494. SAFE TO RE-RUN. ASCII-only.
-- Rollback: 519_practice_view_obligations_by_framework_rollback.sql (494 body)
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Guard on the COLUMNS the body reads, not just the proc
-- (reissued_proc_needs_column_guard).
IF COL_LENGTH('grac_practice.organization_obligation_evidence','evidence_cadence') IS NULL
   OR COL_LENGTH('grac_practice.organization_obligation','lifecycle_status') IS NULL
   OR COL_LENGTH('grac_practice.organization_obligation_requirement_map','release_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_obligation_requirement_map','requirement_id') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_org_obligation_typed_detail','V') IS NULL
   OR OBJECT_ID('dbo.sp_pm_view_obligations_typed','P') IS NULL
   OR OBJECT_DEFINITION(OBJECT_ID('dbo.sp_pm_view_obligations_typed')) NOT LIKE '%EvidenceCadenceLabel%'
BEGIN
    PRINT 'ABORT (519): run 473, 493 and 494 first. Nothing was changed.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- dbo.sp_pm_view_obligations_typed (494 body; 519 edits marked)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_pm_view_obligations_typed
    @p_organization_requirement_id BIGINT       = NULL,
    @p_practice_id                 BIGINT       = NULL,
    @p_practice_instance_id        BIGINT       = NULL,
    @p_search                      NVARCHAR(200) = N'',
    @p_offset                      INT           = 0,
    @p_page_size                   INT           = 200,
    -- 519: the framework release the Practice View was opened under (the
    -- Practices grid's selected framework). NULL = every framework, which is
    -- what every other caller (Operationalize, Evidence Center) still gets.
    @p_release_id                  BIGINT        = NULL
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
           -- 519: only obligations mapped under the selected framework.
           AND (@p_release_id IS NULL OR orm.release_id = @p_release_id)
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
        -- 494: each evidence element also carries its cadence (Recurring /
        -- OneTime) and label, the same enrichment 473 gives the
        -- Operationalize card (sp_resolve_obligation_list, evj).
        COALESCE(evj.EvidenceJson, td.EvidenceJson, N'[]') AS EvidenceJson,
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
    -- 494: cadence onto every element of the copied EvidenceJson (the 473
    -- OUTER APPLY of sp_resolve_obligation_list, keyed on this row's
    -- organization). The element is kept whole -- JSON_MODIFY adds two keys
    -- -- so nothing the page already reads changes. No elements gives NULL
    -- and the COALESCE above falls back to the stored JSON. A spec not yet
    -- copied with a cadence reads Recurring (077's default).
    OUTER APPLY (
        SELECT N'[' + STRING_AGG(CAST(
                   JSON_MODIFY(JSON_MODIFY(j.[value],
                       '$.EvidenceCadence', COALESCE(ooe.evidence_cadence, N'Recurring')),
                       '$.EvidenceCadenceLabel', COALESCE(cad.option_label, ooe.evidence_cadence, N'Recurring'))
                   AS NVARCHAR(MAX)), N',') WITHIN GROUP (ORDER BY CAST(j.[key] AS INT)) + N']' AS EvidenceJson
        FROM   OPENJSON(td.EvidenceJson) j
        LEFT   JOIN grac_practice.organization_obligation_evidence ooe
               ON ooe.organization_id = dob.organization_id
              AND ooe.obligation_evidence_id = TRY_CAST(JSON_VALUE(j.[value], '$.ObligationEvidenceId') AS BIGINT)
        LEFT   JOIN GRAC_New.reference_option cad
               ON cad.option_group = N'evidence-cadence'
              AND cad.option_value = COALESCE(ooe.evidence_cadence, N'Recurring')
        WHERE  ISJSON(td.EvidenceJson) = 1
          AND  j.[type] = 5
    ) evj
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
           -- 519: with a framework selected, label the row with THAT
           -- framework, not whichever mapped release TOP 1 met first.
           AND (@p_release_id IS NULL OR orm2.release_id = @p_release_id)
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

SELECT '519 proc accepts @p_release_id' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('dbo.sp_pm_view_obligations_typed')
                            AND name = '@p_release_id')
             AND OBJECT_DEFINITION(OBJECT_ID('dbo.sp_pm_view_obligations_typed')) LIKE '%EvidenceCadenceLabel%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '519 complete. Deploy Api (passes releaseId) and Web (practice.js, practice-view.cshtml). Api and SQL may go in either order.';
GO
SET NOEXEC OFF;
GO
