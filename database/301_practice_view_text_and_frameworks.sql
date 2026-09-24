-- =====================================================================
-- 301_practice_view_text_and_frameworks.sql
--
-- PURPOSE
--   Two additive columns behind the Practice View page:
--     1. dbo.sp_pm_view_obligations_typed  -> ObligationText
--     2. grac_practice.sp_practice_detail_get -> MappedFrameworksJson
--
-- ---------------------------------------------------------------------
-- 1. ObligationText
-- ---------------------------------------------------------------------
-- The Obligations panel shows a name and nothing of what the obligation
-- actually says. The text was always there -- obligation_text on
-- GRAC_New.requirement_obligation -- but the procedure never projected
-- it. It only ever borrowed it, as the fallback when an obligation was
-- published without a name:
--
--     COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
--              LEFT(o.obligation_text, 300)) AS ObligationName
--
-- That fallback stays exactly as it is. The new column is the raw,
-- untruncated text alongside it. Where the two coincide -- a nameless
-- obligation, whose "name" IS the first 300 characters of its text --
-- the page suppresses the second line rather than printing the same
-- words twice. That is a rendering decision, so it lives in the
-- renderer; this procedure returns the truth and lets the caller
-- decide.
--
-- ---------------------------------------------------------------------
-- 2. MappedFrameworksJson
-- ---------------------------------------------------------------------
-- Practice Details names the requirement a practice came from but never
-- the framework release it belongs to, even though the mapping has been
-- stored since migration 031.
--
-- organization_statement_practice_mapping is the source: one row per
-- (statement, practice), carrying release_id. The Source Statements
-- grid already reads this table in the opposite direction -- its
-- statement_practice_counts CTE counts practices per statement -- so
-- reading it back the other way is the same relationship, not a second
-- definition of it. release_id on that table is nullable, so the org
-- statement's own release is the fallback.
--
-- A practice reached through a Control rather than a Statement has no
-- mapping row at all. The UNION's second arm covers it from
-- organization_control.release_id, guarded by a NOT EXISTS so it stays
-- silent for any practice that does have statement mappings.
--
-- The release label is built with the same COALESCE(artifact_code + ' '
-- + version_no, ...) expression sp_pm_view_obligations_typed uses, so a
-- release named in the details header and the same release named on an
-- obligation card read identically.
--
-- WHY JSON AND NOT A DELIMITED STRING
--   The page draws one pm-badge per release. Splitting a STRING_AGG on
--   ', ' would break the first time an artifact name contained a comma,
--   and would do it silently, as two half-named badges. FOR JSON PATH
--   is also the shape this schema already uses for the repeating detail
--   on the obligations procedure (StateRulesJson, EvidenceJson, ...),
--   and the page already carries a jsonArray() parser for exactly that.
--   Empty is N'[]', never NULL, so the caller never branches on null.
--
-- ---------------------------------------------------------------------
-- WHY BOTH PROCEDURES ARE RE-EMITTED WHOLE
-- ---------------------------------------------------------------------
-- CREATE OR ALTER replaces a procedure whole. Each body below is its
-- current definition -- 224 for the obligations procedure, 218 for the
-- detail procedure -- character for character, with only the additions
-- described above. Keep this file and those two in step: the next
-- change to either body belongs here, not in 224 or 218.
--
-- Both branches of sp_practice_detail_get gain the column: the practice
-- branch and the 218 requirement-fallback branch, which serves a
-- requirement that has no practice row yet. A caller reading the column
-- by name must find it whichever branch answered.
--
-- ADDITIVE ONLY. No schema change, no data change. Existing columns
-- keep their names, types and ordinal positions, so a caller that does
-- not know about the new ones is unaffected.
-- Rollback: 301_practice_view_text_and_frameworks_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (301): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.organization_statement_practice_mapping','U') IS NULL
BEGIN
    PRINT 'ABORT (301): organization_statement_practice_mapping missing -- run 031 first.';
    SET NOEXEC ON;
END
GO

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
        LEFT JOIN GRAC_New.requirement repo_req
            ON repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
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
        SELECT DISTINCT orm.obligation_id
        FROM distinct_requirements dr
        JOIN GRAC_New.obligation_requirement_release_map orm
            ON orm.requirement_id = dr.repository_requirement_id
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
        COALESCE(td.EvidenceJson,        N'[]') AS EvidenceJson
    FROM distinct_obligations dob
    JOIN GRAC_New.requirement_obligation o
        ON o.obligation_id = dob.obligation_id AND o.status = N'Active'
    LEFT JOIN GRAC_New.obligation_type_master t
        ON t.obligation_type_id = o.obligation_type_id
    LEFT JOIN GRAC_New.reference_option exec_freq
        ON exec_freq.reference_option_id = o.execution_frequency_id
    LEFT JOIN grac_practice.vw_pm_obligation_typed_detail td
        ON td.ObligationId = dob.obligation_id
    OUTER APPLY (
        -- One representative release per obligation (no row multiplication)
        SELECT TOP 1
            r.release_id,
            COALESCE(a.artifact_code + N' ' + r.version_no,
                     a.artifact_name + N' ' + r.version_no,
                     r.version_no) AS FrameworkRelease
        FROM distinct_requirements dr2
        JOIN GRAC_New.obligation_requirement_release_map orm2
            ON orm2.requirement_id = dr2.repository_requirement_id
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
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_detail_get
    @practice_id                BIGINT = NULL,
    @organization_id            BIGINT = NULL,
    @organization_requirement_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- The caller may know either identifier. The Organization Practices grid
    -- is one row per organization_requirement and does not always carry the
    -- practice id, so accepting the requirement id and resolving from it here
    -- keeps the page working regardless of which column that grid returns.
    -- When a requirement has several practices, the earliest active one is
    -- the practice the grid itself displays.
    IF @practice_id IS NULL AND @organization_requirement_id IS NOT NULL
        SELECT TOP 1 @practice_id = practice_id
        FROM   grac_practice.practice
        WHERE  organization_requirement_id = @organization_requirement_id
          AND (@organization_id IS NULL OR organization_id = @organization_id)
        ORDER  BY CASE WHEN status = N'Active' THEN 0 ELSE 1 END, practice_id;

    -- (218) No practice row yet -- serve the header straight from the
    -- requirement rather than 404-ing the page. See the file header for why
    -- this state is normal rather than a data fault.
    IF @practice_id IS NULL AND @organization_requirement_id IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1
                       FROM   grac_practice.organization_requirement
                       WHERE  organization_requirement_id = @organization_requirement_id
                         AND (@organization_id IS NULL OR organization_id = @organization_id))
            THROW 52512, 'sp_practice_detail_get: requirement not found for this organization.', 1;

        SELECT
            CAST(0 AS BIGINT)                 AS PracticeId,
            q.organization_id                 AS OrganizationId,
            o.organization_name               AS OrganizationName,
            q.requirement_code                AS PracticeCode,
            q.requirement_name                AS PracticeName,
            q.requirement_statement           AS Description,
            q.origin_type                     AS OriginType,
            CAST(NULL AS NVARCHAR(200))       AS PracticeOwner,
            CAST(NULL AS BIGINT)              AS PracticeOwnerId,
            COALESCE(aps.status_name, q.applicability_status) AS ApplicabilityStatus,
            q.exclusion_justification         AS ExclusionJustification,
            COALESCE(rs.status_name, q.status) AS Status,
            q.organization_requirement_id     AS OrganizationRequirementId,
            q.requirement_code                AS RequirementCode,
            q.requirement_name                AS RequirementName,
            CAST(0 AS INT)                    AS ActiveInstanceCount,

        -- (301) Framework releases this practice is mapped to.
        --
        -- Source of truth is organization_statement_practice_mapping -- the
        -- same table the Source Statements grid counts practices from, read
        -- in the opposite direction. Its release_id is nullable, so the
        -- org statement's own release is the fallback.
        --
        -- A practice that arrived through a Control rather than a Statement
        -- has no mapping row; the UNION's second arm supplies that Control's
        -- release, and its NOT EXISTS keeps it from firing for a practice
        -- that does have statement mappings.
        --
        -- FrameworkRelease is built exactly as sp_pm_view_obligations_typed
        -- builds it, so the chips here and the "Framework" line on each
        -- obligation card below read identically.
        --
        -- JSON, not a delimited string: the page renders one badge per
        -- release and must not split on a comma that could sit inside a
        -- name. '[]' when nothing is mapped -- the row is then omitted.
        COALESCE((
            SELECT   f.ReleaseId, f.FrameworkRelease
            FROM (
                SELECT DISTINCT
                       r.release_id AS ReleaseId,
                       COALESCE(a.artifact_code + N' ' + r.version_no,
                                a.artifact_name + N' ' + r.version_no,
                                r.version_no) AS FrameworkRelease
                FROM   grac_practice.organization_statement_practice_mapping m
                LEFT   JOIN grac_practice.organization_framework_statements ofs2
                       ON ofs2.org_statement_id = m.org_statement_id
                JOIN   GRAC_New.release r
                       ON r.release_id = COALESCE(m.release_id, ofs2.release_id)
                LEFT   JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
                WHERE  m.org_practice_id = q.organization_requirement_id
                  AND  m.status = N'Active'
                UNION
                SELECT DISTINCT
                       r2.release_id,
                       COALESCE(a2.artifact_code + N' ' + r2.version_no,
                                a2.artifact_name + N' ' + r2.version_no,
                                r2.version_no)
                FROM   grac_practice.organization_requirement q2
                JOIN   grac_practice.organization_control oc2
                       ON oc2.organization_control_id = q2.organization_control_id
                JOIN   GRAC_New.release r2 ON r2.release_id = oc2.release_id
                LEFT   JOIN GRAC_New.artifact a2 ON a2.artifact_id = r2.artifact_id
                WHERE  q2.organization_requirement_id = q.organization_requirement_id
                  AND  NOT EXISTS (SELECT 1
                                   FROM   grac_practice.organization_statement_practice_mapping m2
                                   WHERE  m2.org_practice_id = q.organization_requirement_id
                                     AND  m2.status = N'Active')
            ) f
            ORDER BY f.FrameworkRelease
            FOR JSON PATH
        ), N'[]')                         AS MappedFrameworksJson
        FROM   grac_practice.organization_requirement q
        JOIN   grac_practice.organization o
               ON o.organization_id = q.organization_id
        LEFT   JOIN grac_practice.applicability_status_master aps
               ON aps.applicability_status_id = q.applicability_status_id
        LEFT   JOIN grac_practice.record_status_master rs
               ON rs.record_status_id = q.record_status_id
        WHERE  q.organization_requirement_id = @organization_requirement_id
          AND (@organization_id IS NULL OR q.organization_id = @organization_id);

        RETURN;
    END

    IF @practice_id IS NULL
        THROW 52500, 'sp_practice_detail_get: no practice found. Supply practice_id, or an organization_requirement_id that has a practice.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice
                    WHERE practice_id = @practice_id
                      AND (@organization_id IS NULL OR organization_id = @organization_id))
        THROW 52501, 'sp_practice_detail_get: practice not found for this organization.', 1;

    SELECT
        p.practice_id                    AS PracticeId,
        p.organization_id                AS OrganizationId,
        o.organization_name              AS OrganizationName,
        p.practice_code                  AS PracticeCode,
        p.practice_name                  AS PracticeName,
        p.description                    AS Description,
        p.origin_type                    AS OriginType,
        p.practice_owner                 AS PracticeOwner,
        p.practice_owner_id              AS PracticeOwnerId,
        p.applicability_status           AS ApplicabilityStatus,
        p.exclusion_justification        AS ExclusionJustification,
        p.status                         AS Status,
        p.organization_requirement_id    AS OrganizationRequirementId,
        req.requirement_code             AS RequirementCode,
        req.requirement_name             AS RequirementName,
        (SELECT COUNT(*)
         FROM   grac_practice.practice_instance pi
         WHERE  pi.practice_id = p.practice_id
           AND  pi.status = N'Active')   AS ActiveInstanceCount,

        -- (301) Framework releases this practice is mapped to.
        --
        -- Source of truth is organization_statement_practice_mapping -- the
        -- same table the Source Statements grid counts practices from, read
        -- in the opposite direction. Its release_id is nullable, so the
        -- org statement's own release is the fallback.
        --
        -- A practice that arrived through a Control rather than a Statement
        -- has no mapping row; the UNION's second arm supplies that Control's
        -- release, and its NOT EXISTS keeps it from firing for a practice
        -- that does have statement mappings.
        --
        -- FrameworkRelease is built exactly as sp_pm_view_obligations_typed
        -- builds it, so the chips here and the "Framework" line on each
        -- obligation card below read identically.
        --
        -- JSON, not a delimited string: the page renders one badge per
        -- release and must not split on a comma that could sit inside a
        -- name. '[]' when nothing is mapped -- the row is then omitted.
        COALESCE((
            SELECT   f.ReleaseId, f.FrameworkRelease
            FROM (
                SELECT DISTINCT
                       r.release_id AS ReleaseId,
                       COALESCE(a.artifact_code + N' ' + r.version_no,
                                a.artifact_name + N' ' + r.version_no,
                                r.version_no) AS FrameworkRelease
                FROM   grac_practice.organization_statement_practice_mapping m
                LEFT   JOIN grac_practice.organization_framework_statements ofs2
                       ON ofs2.org_statement_id = m.org_statement_id
                JOIN   GRAC_New.release r
                       ON r.release_id = COALESCE(m.release_id, ofs2.release_id)
                LEFT   JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
                WHERE  m.org_practice_id = p.organization_requirement_id
                  AND  m.status = N'Active'
                UNION
                SELECT DISTINCT
                       r2.release_id,
                       COALESCE(a2.artifact_code + N' ' + r2.version_no,
                                a2.artifact_name + N' ' + r2.version_no,
                                r2.version_no)
                FROM   grac_practice.organization_requirement q2
                JOIN   grac_practice.organization_control oc2
                       ON oc2.organization_control_id = q2.organization_control_id
                JOIN   GRAC_New.release r2 ON r2.release_id = oc2.release_id
                LEFT   JOIN GRAC_New.artifact a2 ON a2.artifact_id = r2.artifact_id
                WHERE  q2.organization_requirement_id = p.organization_requirement_id
                  AND  NOT EXISTS (SELECT 1
                                   FROM   grac_practice.organization_statement_practice_mapping m2
                                   WHERE  m2.org_practice_id = p.organization_requirement_id
                                     AND  m2.status = N'Active')
            ) f
            ORDER BY f.FrameworkRelease
            FOR JSON PATH
        ), N'[]')                         AS MappedFrameworksJson
    FROM   grac_practice.practice p
    JOIN   grac_practice.organization o
           ON o.organization_id = p.organization_id
    LEFT   JOIN grac_practice.organization_requirement req
           ON req.organization_requirement_id = p.organization_requirement_id
    WHERE  p.practice_id = @practice_id;
END
GO
-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'sp_pm_view_obligations_typed present' AS Check_,
       CASE WHEN OBJECT_ID('dbo.sp_pm_view_obligations_typed','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'sp_practice_detail_get present',
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_detail_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '301 ObligationText + MappedFrameworksJson installed.';
GO
