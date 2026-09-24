-- =====================================================================
-- 303_practice_detail_implementation_status.sql
--
-- PURPOSE
--   grac_practice.sp_practice_detail_get -> PracticeImplementationStatus.
--   The Practice View header shows the practice's implementation roll-up
--   where it used to repeat the Requirement.
--
-- ---------------------------------------------------------------------
-- THE SAME RULE, NOT A SECOND ONE
-- ---------------------------------------------------------------------
-- The Organization Practices list already derives this, in
-- QueryOrganizationRequirementFallbackAsync. The CASE below is that one:
--
--   Implemented             Applicable, has instances, and EVERY instance
--                           Implemented -- one unfinished instance holds
--                           the whole practice back
--   Partially Implemented   Applicable and at least one Implemented
--   Not Applicable          applicability is Not Applicable, Deferred,
--                           Accepted Risk, Not Implemented or Retired
--   Not Implemented         everything else, including no instances
--
-- "Every instance Implemented" is practice_instance.implementation_status_id
-- resolving to implementation_status_master.status_code = N'Implemented'.
-- There is no Closed state on a practice instance; the master holds only
-- Not Implemented / Partially Implemented / Implemented / Not Applicable
-- (migration 045) and Implemented is the terminal one.
--
-- ---------------------------------------------------------------------
-- TWO CHOICES THAT KEEP THE VIEW AND THE LIST AGREEING
-- ---------------------------------------------------------------------
-- 1. KEYED ON organization_requirement_id, NOT practice_id. That is the
--    key the list rolls up on -- its PracticeInstanceCount joins practice
--    on organization_requirement_id too. Rolling up by practice_id here
--    would make the View disagree with the row the user clicked to reach
--    it, whenever a requirement has more than one practice.
--
-- 2. APPLICABILITY READ FROM organization_requirement. The practice row
--    carries an applicability_status of its own and this deliberately
--    ignores it: it can lag the requirement, and the list never reads it.
--    The practice branch joins applicability_status_master through req
--    for exactly this.
--
-- Both branches gain the column -- the practice branch and the 218
-- requirement fallback, which serves a requirement with no practice row
-- yet. A caller reading it by name must find it whichever answered.
--
-- ---------------------------------------------------------------------
-- WHY THE PROCEDURE IS RE-EMITTED WHOLE
-- ---------------------------------------------------------------------
-- CREATE OR ALTER replaces a procedure whole. The body below is its
-- current definition -- 301 -- character for character, with only the
-- roll-up added: one CASE per branch and one OUTER APPLY per branch to
-- feed it. ObligationText and MappedFrameworksJson from 301 are carried
-- forward untouched.
--
-- Keep this in step with 301 and 218: the next change to this
-- procedure's body belongs HERE, not in either of those.
--
-- ADDITIVE ONLY. No schema change, no data change. Existing columns keep
-- their names, types and positions.
-- Rollback: 303_practice_detail_implementation_status_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_practice_detail_get','P') IS NULL
BEGIN
    PRINT 'ABORT (303): sp_practice_detail_get missing -- run 139/218/301 first.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.implementation_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (303): implementation_status_master missing -- run 002/045 first.';
    SET NOEXEC ON;
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
        -- (303) Practice-level implementation roll-up, the SAME rule the
        -- Organization Practices list applies in
        -- QueryOrganizationRequirementFallbackAsync: Implemented only when the
        -- practice is Applicable, has instances, and EVERY instance is
        -- Implemented, so one unfinished instance holds the whole practice
        -- back. No instances falls through to Not Implemented.
        --
        -- Keyed on organization_requirement_id, not practice_id, because that
        -- is the key the list rolls up on -- its PracticeInstanceCount joins
        -- practice on organization_requirement_id too. Using practice_id here
        -- would make the View disagree with the row the user clicked to reach
        -- it whenever a requirement has more than one practice.
        --
        -- Applicability comes from organization_requirement for the same
        -- reason: it is what the list reads. This branch already reads it as ApplicabilityStatus above.
        CASE
            WHEN COALESCE(aps.status_name, q.applicability_status, N'Not Updated') = N'Applicable'
                 AND COALESCE(impl.InstanceCount, 0) > 0
                 AND impl.InstanceCount = impl.ImplementedInstanceCount THEN N'Implemented'
            WHEN COALESCE(aps.status_name, q.applicability_status, N'Not Updated') = N'Applicable'
                 AND COALESCE(impl.ImplementedInstanceCount, 0) > 0 THEN N'Partially Implemented'
            WHEN COALESCE(aps.status_name, q.applicability_status, N'Not Updated') IN (N'Not Applicable', N'Deferred', N'Accepted Risk', N'Not Implemented', N'Retired')
                 THEN N'Not Applicable'
            ELSE N'Not Implemented'
        END                               AS PracticeImplementationStatus,

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
        OUTER APPLY (
            -- Same two joins the list's pic apply uses, and the same
            -- status_code = N'Implemented' test.
            SELECT COUNT_BIG(1) AS InstanceCount,
               COUNT_BIG(CASE WHEN ism_pi.status_code = N'Implemented' THEN 1 END) AS ImplementedInstanceCount
            FROM   grac_practice.practice_instance pi_impl
            JOIN   grac_practice.practice pp_impl ON pp_impl.practice_id = pi_impl.practice_id
            LEFT   JOIN grac_practice.implementation_status_master ism_pi
                   ON ism_pi.implementation_status_id = pi_impl.implementation_status_id
            WHERE  pp_impl.organization_requirement_id = q.organization_requirement_id
              AND  pi_impl.organization_id = q.organization_id
              AND  pi_impl.status = N'Active'
        ) impl
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
        -- (303) Practice-level implementation roll-up, the SAME rule the
        -- Organization Practices list applies in
        -- QueryOrganizationRequirementFallbackAsync: Implemented only when the
        -- practice is Applicable, has instances, and EVERY instance is
        -- Implemented, so one unfinished instance holds the whole practice
        -- back. No instances falls through to Not Implemented.
        --
        -- Keyed on organization_requirement_id, not practice_id, because that
        -- is the key the list rolls up on -- its PracticeInstanceCount joins
        -- practice on organization_requirement_id too. Using practice_id here
        -- would make the View disagree with the row the user clicked to reach
        -- it whenever a requirement has more than one practice.
        --
        -- Applicability comes from organization_requirement for the same
        -- reason: it is what the list reads. p.applicability_status on the practice row is NOT used --
        -- it can lag the requirement, and the list never reads it.
        CASE
            WHEN COALESCE(req_aps.status_name, req.applicability_status, N'Not Updated') = N'Applicable'
                 AND COALESCE(impl.InstanceCount, 0) > 0
                 AND impl.InstanceCount = impl.ImplementedInstanceCount THEN N'Implemented'
            WHEN COALESCE(req_aps.status_name, req.applicability_status, N'Not Updated') = N'Applicable'
                 AND COALESCE(impl.ImplementedInstanceCount, 0) > 0 THEN N'Partially Implemented'
            WHEN COALESCE(req_aps.status_name, req.applicability_status, N'Not Updated') IN (N'Not Applicable', N'Deferred', N'Accepted Risk', N'Not Implemented', N'Retired')
                 THEN N'Not Applicable'
            ELSE N'Not Implemented'
        END                               AS PracticeImplementationStatus,

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
    LEFT   JOIN grac_practice.applicability_status_master req_aps
           ON req_aps.applicability_status_id = req.applicability_status_id
    OUTER APPLY (
        -- Same two joins the list's pic apply uses, and the same
        -- status_code = N'Implemented' test.
        SELECT COUNT_BIG(1) AS InstanceCount,
               COUNT_BIG(CASE WHEN ism_pi.status_code = N'Implemented' THEN 1 END) AS ImplementedInstanceCount
        FROM   grac_practice.practice_instance pi_impl
        JOIN   grac_practice.practice pp_impl ON pp_impl.practice_id = pi_impl.practice_id
        LEFT   JOIN grac_practice.implementation_status_master ism_pi
               ON ism_pi.implementation_status_id = pi_impl.implementation_status_id
        WHERE  pp_impl.organization_requirement_id = p.organization_requirement_id
          AND  pi_impl.organization_id = p.organization_id
          AND  pi_impl.status = N'Active'
    ) impl
    WHERE  p.practice_id = @practice_id;
END
GO
SELECT 'sp_practice_detail_get present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_detail_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'PracticeImplementationStatus projected',
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                         WHERE object_id = OBJECT_ID('grac_practice.sp_practice_detail_get')
                           AND definition LIKE '%PracticeImplementationStatus%')
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '303 PracticeImplementationStatus installed.';
GO
