-- =====================================================================
-- 456_implementation_status_not_updated_default.sql
--
-- WHY
-- ---
-- Applicability defaults to "Not Updated", but Implementation Status
-- defaulted to "Not Implemented" (Control Statement, Practice, Practice
-- Instance) and to "Not set" on an Operationalize obligation. Change
-- request 2026-10-08: Implementation Status also defaults to
-- "Not Updated" everywhere, and only becomes Not Implemented once
-- something has actually been updated.
--
-- RULE (all three levels)
--   Obligation : NULL (or the legacy Not Started) is shown as Not Updated
--                (Web tier label; no data change).
--   Instance   : no applicable obligation updated      -> Not Updated
--                every applicable obligation Implemented -> Implemented
--                otherwise                               -> Not Implemented
--                (N/A obligations excluded, as in 346.)
--   Practice / Control Statement (derived, never stored):
--                Applicable + all instances Implemented  -> Implemented
--                Applicable + some instance Implemented  -> Partially Implemented
--                Not Applicable / Deferred / ...         -> Not Applicable
--                Applicable + an instance updated        -> Not Implemented
--                otherwise                               -> Not Updated
--
-- WHAT
--   1. implementation_status_master row 'Not Updated' (kept is_active = 0
--      so it is NOT offered in the obligation dropdown -- the dropdown's
--      empty "Not Updated" option already means unset).
--   2. sp_pm_recalc_instance_impl_status (346) re-issued with the rule
--      above; zero-obligation instances holding a default value move to
--      Not Updated (346 left them untouched).
--   3. New AFTER INSERT trigger tr_pm_practice_instance_impl_status_default:
--      a new instance starts at Not Updated whatever the creating path
--      wrote (sp_practice_instance_configure: Not Implemented,
--      pm_manage_practice_repository: Not Started / Active).
--   4. Backfill: every instance recalculated.
--   5. sp_practice_detail_get (from 396): Practice View roll-up.
--   6. sp_dashboard_governance (from 414): + "Not updated" instance KPI.
--   7. sp_practice_instance_open_implementation_task (from 043): also
--      opens from Not Updated.
-- The Practices grid and the Control Statement tree are derived in
-- PracticeRepositoryService.cs (same change).
--
-- Gap detection is NOT affected: gaps come from obligation statuses
-- (Not Implemented / Partially Implemented, 243/245), not from the
-- instance column.
--
-- Re-issued from the files named; nothing else in them changes.
-- SAFE TO RE-RUN. Requires 043, 346, 396, 414. ASCII-only.
-- Rollback: database/456_implementation_status_not_updated_default_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_pm_recalc_instance_impl_status','P') IS NULL
   OR OBJECT_ID('grac_practice.tr_pm_pio_impl_status_rollup','TR') IS NULL
   OR OBJECT_ID('grac_practice.sp_practice_instance_open_implementation_task','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_dashboard_governance','P') IS NULL
   OR ISNULL(OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_detail_get')), N'') NOT LIKE N'%RepositoryLifecycleStatus%'
   OR COL_LENGTH('grac_practice.practice_instance_obligation','implementation_status_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance','updated_by') IS NULL
BEGIN
    PRINT 'ABORT (456): run 043, 346, 396 and 414 first.';
    SET NOEXEC ON;
END
GO

-- 1. Master row ---------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM grac_practice.implementation_status_master WHERE status_code = N'Not Updated')
    INSERT grac_practice.implementation_status_master (status_code, status_name, display_order, is_active, entered_by)
    VALUES (N'Not Updated', N'Not Updated', 0, 0, N'migration-456');
ELSE
    UPDATE grac_practice.implementation_status_master
       SET status_name = N'Not Updated', is_active = 0,
           updated_by = N'migration-456', updated_dt = SYSUTCDATETIME()
     WHERE status_code = N'Not Updated'
       AND (status_name <> N'Not Updated' OR is_active <> 0);
GO
PRINT '456: implementation_status_master Not Updated ready.';
GO

-- 2. Recompute procedure (from 346) -------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_pm_recalc_instance_impl_status
    @p_practice_instance_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @implemented_id INT =
        (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Implemented');
    DECLARE @not_impl_id INT =
        (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Not Implemented');
    DECLARE @not_updated_id INT =
        (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Not Updated');
    IF @implemented_id IS NULL OR @not_impl_id IS NULL OR @not_updated_id IS NULL RETURN;

    -- Applicable (non-N/A, Active) obligations per instance:
    --   implemented_n -- status Implemented
    --   updated_n     -- status set to anything other than the unset
    --                    default (NULL / Not Started / Not Updated)
    ;WITH agg AS (
        SELECT pio.practice_instance_id,
               COUNT(*) AS effective_n,
               SUM(CASE WHEN COALESCE(ims.status_code, N'Not Started') = N'Implemented' THEN 1 ELSE 0 END) AS implemented_n,
               SUM(CASE WHEN COALESCE(ims.status_code, N'Not Started') IN (N'Not Started', N'Not Updated') THEN 0 ELSE 1 END) AS updated_n
        FROM   grac_practice.practice_instance_obligation pio
        LEFT   JOIN grac_practice.implementation_status_master ims
               ON ims.implementation_status_id = pio.implementation_status_id
        WHERE  pio.status = N'Active'
          AND  COALESCE(ims.status_code, N'Not Started') <> N'N/A'
          AND  (@p_practice_instance_id IS NULL OR pio.practice_instance_id = @p_practice_instance_id)
        GROUP  BY pio.practice_instance_id
    ),
    target AS (
        SELECT pi.practice_instance_id,
               CASE
                   -- No applicable obligations: only a default value moves
                   -- to Not Updated; a legacy explicit value is kept.
                   WHEN COALESCE(agg.effective_n, 0) = 0 THEN
                        CASE WHEN COALESCE(pi.implementation_status, N'') IN
                                  (N'', N'Not Updated', N'Not Started', N'Not Set', N'Active', N'Not Implemented')
                             THEN N'Not Updated' END
                   WHEN agg.updated_n = 0                    THEN N'Not Updated'
                   WHEN agg.implemented_n = agg.effective_n  THEN N'Implemented'
                   ELSE N'Not Implemented'
               END AS derived_code
        FROM   grac_practice.practice_instance pi
        LEFT   JOIN agg ON agg.practice_instance_id = pi.practice_instance_id
        WHERE  (@p_practice_instance_id IS NULL OR pi.practice_instance_id = @p_practice_instance_id)
    )
    UPDATE pi
       SET implementation_status    = t.derived_code,
           implementation_status_id = d.derived_id,
           updated_by               = N'derive-456',
           updated_dt               = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance pi
    JOIN   target t ON t.practice_instance_id = pi.practice_instance_id
    CROSS  APPLY (SELECT CASE t.derived_code
                             WHEN N'Implemented'     THEN @implemented_id
                             WHEN N'Not Implemented' THEN @not_impl_id
                             ELSE @not_updated_id
                         END AS derived_id) d
    WHERE  t.derived_code IS NOT NULL
      AND (ISNULL(pi.implementation_status, N'') <> t.derived_code
           OR ISNULL(pi.implementation_status_id, -1) <> d.derived_id);
END
GO
PRINT '456: sp_pm_recalc_instance_impl_status ready.';
GO

-- 3. New-instance default -----------------------------------------------
CREATE OR ALTER TRIGGER grac_practice.tr_pm_practice_instance_impl_status_default
ON grac_practice.practice_instance
AFTER INSERT
NOT FOR REPLICATION
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @not_updated_id INT =
        (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Not Updated');
    IF @not_updated_id IS NULL RETURN;

    -- A new instance has no obligations yet, so whatever default the
    -- creating path wrote (Not Started, Not Implemented, Active ...) is
    -- replaced by Not Updated. Obligations adopted afterwards fire
    -- tr_pm_pio_impl_status_rollup, which derives the real status.
    UPDATE pi
       SET implementation_status    = N'Not Updated',
           implementation_status_id = @not_updated_id
    FROM   grac_practice.practice_instance pi
    JOIN   inserted i ON i.practice_instance_id = pi.practice_instance_id
    WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_obligation pio
                       WHERE pio.practice_instance_id = pi.practice_instance_id)
      AND (ISNULL(pi.implementation_status, N'') <> N'Not Updated'
           OR ISNULL(pi.implementation_status_id, -1) <> @not_updated_id);
END
GO
PRINT '456: tr_pm_practice_instance_impl_status_default ready.';
GO

-- 4. Backfill -----------------------------------------------------------
EXEC grac_practice.sp_pm_recalc_instance_impl_status NULL;
GO
PRINT '456: existing practice instances recalculated.';
GO

-- 5. sp_practice_detail_get (from 396) ----------------------------------
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
        -- back. 456: the default is Not Updated; Not Implemented only once
        -- at least one instance has been updated.
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
            WHEN COALESCE(aps.status_name, q.applicability_status, N'Not Updated') = N'Applicable'
                 AND COALESCE(impl.UpdatedInstanceCount, 0) > 0 THEN N'Not Implemented'
            ELSE N'Not Updated'
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
        ), N'[]')                         AS MappedFrameworksJson,

        -- (316) Source Statement(s) this practice is mapped to -- the SAME
        -- organization_statement_practice_mapping rows as
        -- MappedFrameworksJson above, joined this time to
        -- GRAC_New.framework_statement instead of GRAC_New.release, exactly
        -- as QueryReleaseStatementsAsync (the Source Statements grid) already
        -- joins that table for StatementReference / StatementTitle. No
        -- Control-origin fallback: a Control has no individual statement to
        -- name, so a practice reached that way correctly gets '[]' here even
        -- though it has a Framework.
        COALESCE((
            SELECT   s.FrameworkStatementId, s.StatementReference, s.StatementTitle, s.SourceStatement,
                     s.RepositoryLifecycleStatus
            FROM (
                SELECT DISTINCT
                       fs.framework_statement_id AS FrameworkStatementId,
                       COALESCE(fs.statement_reference, crs.statement_reference) AS StatementReference,
                       COALESCE(fs.statement_title, crs.statement_title)         AS StatementTitle,
                       COALESCE(COALESCE(fs.statement_reference, crs.statement_reference) + N' - ' + COALESCE(fs.statement_title, crs.statement_title),
                                COALESCE(fs.statement_reference, crs.statement_reference),
                                COALESCE(fs.statement_title, crs.statement_title)) AS SourceStatement,
                       -- 396: 'Retired' once a repository retirement of the
                       -- statement has been approved (Practice View badge).
                       fs.lifecycle_status AS RepositoryLifecycleStatus
                FROM   grac_practice.organization_statement_practice_mapping m
                LEFT   JOIN grac_practice.organization_framework_statements ofs
                       ON ofs.org_statement_id = m.org_statement_id
                -- 393: repository label from the organization's copy
                LEFT   JOIN grac_practice.organization_framework_statements fs
                       ON fs.org_statement_id = m.org_statement_id
                      AND fs.source_type = N'Repository'
                LEFT   JOIN grac_practice.custom_release_statement crs
                       ON crs.custom_statement_id = ofs.custom_statement_id
                WHERE  m.org_practice_id = q.organization_requirement_id
                  AND  m.status = N'Active'
            ) s
            WHERE s.StatementReference IS NOT NULL OR s.StatementTitle IS NOT NULL
            ORDER BY s.StatementReference
            FOR JSON PATH
        ), N'[]')                         AS MappedSourceStatementsJson
        FROM   grac_practice.organization_requirement q
        JOIN   grac_practice.organization o
               ON o.organization_id = q.organization_id
        OUTER APPLY (
            -- Same two joins the list's pic apply uses, and the same
            -- status_code = N'Implemented' test.
            SELECT COUNT_BIG(1) AS InstanceCount,
               COUNT_BIG(CASE WHEN ism_pi.status_code = N'Implemented' THEN 1 END) AS ImplementedInstanceCount,
               -- 456: instances past the Not Updated default.
               COUNT_BIG(CASE WHEN COALESCE(ism_pi.status_code, pi_impl.implementation_status, N'Not Updated') NOT IN (N'Not Updated', N'Not Started') THEN 1 END) AS UpdatedInstanceCount
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
        -- back. 456: the default is Not Updated; Not Implemented only once
        -- at least one instance has been updated.
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
            WHEN COALESCE(req_aps.status_name, req.applicability_status, N'Not Updated') = N'Applicable'
                 AND COALESCE(impl.UpdatedInstanceCount, 0) > 0 THEN N'Not Implemented'
            ELSE N'Not Updated'
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
        ), N'[]')                         AS MappedFrameworksJson,

        -- (316) Source Statement(s) this practice is mapped to -- see the
        -- matching block in the 218 fallback branch above for the full
        -- explanation. Same mapping rows as MappedFrameworksJson, joined to
        -- GRAC_New.framework_statement instead of GRAC_New.release.
        COALESCE((
            SELECT   s.FrameworkStatementId, s.StatementReference, s.StatementTitle, s.SourceStatement,
                     s.RepositoryLifecycleStatus
            FROM (
                SELECT DISTINCT
                       fs.framework_statement_id AS FrameworkStatementId,
                       COALESCE(fs.statement_reference, crs.statement_reference) AS StatementReference,
                       COALESCE(fs.statement_title, crs.statement_title)         AS StatementTitle,
                       COALESCE(COALESCE(fs.statement_reference, crs.statement_reference) + N' - ' + COALESCE(fs.statement_title, crs.statement_title),
                                COALESCE(fs.statement_reference, crs.statement_reference),
                                COALESCE(fs.statement_title, crs.statement_title)) AS SourceStatement,
                       -- 396: 'Retired' once a repository retirement of the
                       -- statement has been approved (Practice View badge).
                       fs.lifecycle_status AS RepositoryLifecycleStatus
                FROM   grac_practice.organization_statement_practice_mapping m
                LEFT   JOIN grac_practice.organization_framework_statements ofs
                       ON ofs.org_statement_id = m.org_statement_id
                -- 393: repository label from the organization's copy
                LEFT   JOIN grac_practice.organization_framework_statements fs
                       ON fs.org_statement_id = m.org_statement_id
                      AND fs.source_type = N'Repository'
                LEFT   JOIN grac_practice.custom_release_statement crs
                       ON crs.custom_statement_id = ofs.custom_statement_id
                WHERE  m.org_practice_id = p.organization_requirement_id
                  AND  m.status = N'Active'
            ) s
            WHERE s.StatementReference IS NOT NULL OR s.StatementTitle IS NOT NULL
            ORDER BY s.StatementReference
            FOR JSON PATH
        ), N'[]')                         AS MappedSourceStatementsJson
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
               COUNT_BIG(CASE WHEN ism_pi.status_code = N'Implemented' THEN 1 END) AS ImplementedInstanceCount,
               -- 456: instances past the Not Updated default.
               COUNT_BIG(CASE WHEN COALESCE(ism_pi.status_code, pi_impl.implementation_status, N'Not Updated') NOT IN (N'Not Updated', N'Not Started') THEN 1 END) AS UpdatedInstanceCount
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

-- 6. sp_dashboard_governance (from 414) ---------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_dashboard_governance
    @organization_id    BIGINT,
    @caller_employee_id BIGINT = NULL,
    @is_admin           BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 57312, 'sp_dashboard_governance: organization_id is required.', 1;
    SET @is_admin = ISNULL(@is_admin, 0);

    -- A non-admin with no employee record owns nothing (398's rule for
    -- an unmatched caller): every count is zero rather than an error.
    SELECT pi.practice_instance_id,
           pi.primary_owner_id,
           COALESCE(ims.status_name, pi.implementation_status) AS implementation_status
      INTO #ins
      FROM grac_practice.practice_instance pi
      JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
      LEFT JOIN grac_practice.implementation_status_master ims
             ON ims.implementation_status_id = pi.implementation_status_id
     WHERE pi.organization_id = @organization_id
       AND pi.status = N'Active'
       AND (@is_admin = 1 OR (@caller_employee_id IS NOT NULL AND pi.primary_owner_id = @caller_employee_id));

    -- ---- 0. KPIs --------------------------------------------------------
    SELECT k.SectionKey, k.SectionTitle, k.KpiKey, k.Label, k.Value, k.IsAlert, k.SortOrder
      FROM (
        SELECT N'instances' AS SectionKey,
               CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END AS SectionTitle,
               N'total' AS KpiKey, N'Total' AS Label, COUNT(*) AS Value, CAST(0 AS BIT) AS IsAlert, 1 AS SortOrder
          FROM #ins
        UNION ALL SELECT N'instances', CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END,
                         N'implemented', N'Implemented',
                         SUM(CASE WHEN implementation_status = N'Implemented' THEN 1 ELSE 0 END), 0, 2 FROM #ins
        UNION ALL SELECT N'instances', CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END,
                         N'partial', N'Partially implemented',
                         SUM(CASE WHEN implementation_status = N'Partially Implemented' THEN 1 ELSE 0 END), 0, 3 FROM #ins
        UNION ALL SELECT N'instances', CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END,
                         N'notimplemented', N'Not implemented',
                         SUM(CASE WHEN implementation_status = N'Not Implemented' THEN 1 ELSE 0 END), 1, 4 FROM #ins
        -- 456: the default status. Without this tile those instances
        -- would drop out of every KPI except Total.
        UNION ALL SELECT N'instances', CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END,
                         N'notupdated', N'Not updated',
                         SUM(CASE WHEN implementation_status = N'Not Updated' THEN 1 ELSE 0 END), 0, 5 FROM #ins
        -- Only an admin sees unowned instances in Operationalize, so only
        -- an admin gets this tile.
        UNION ALL SELECT N'instances', N'Practice instances', N'noowner', N'No owner',
                         SUM(CASE WHEN primary_owner_id IS NULL THEN 1 ELSE 0 END), 1, 6
                    FROM #ins WHERE @is_admin = 1
                  HAVING @is_admin = 1
      ) k
     ORDER BY k.SortOrder;

    -- ---- 1. Ageing: none. Practice instances carry no due, review or
    --      target date, so no ageing is invented. Empty set, same shape.
    SELECT CAST(NULL AS NVARCHAR(40)) AS GroupKey, CAST(NULL AS NVARCHAR(200)) AS GroupTitle,
           CAST(NULL AS NVARCHAR(20)) AS BandCode, CAST(NULL AS NVARCHAR(60)) AS BandName,
           CAST(NULL AS INT) AS SortOrder, CAST(NULL AS INT) AS MinDays, CAST(NULL AS INT) AS MaxDays,
           CAST(NULL AS INT) AS ItemCount
     WHERE 1 = 0;

    -- ---- 2. Distributions: instances by implementation status ----------
    -- ItemKey is the value Operationalize's Status filter takes.
    SELECT N'instances_status' AS GroupKey, N'Practice instances by implementation status' AS GroupTitle,
           implementation_status AS ItemKey, ISNULL(implementation_status, N'(not set)') AS ItemLabel,
           COUNT(*) AS ItemCount, CAST(NULL AS NVARCHAR(20)) AS ColourHex,
           ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, implementation_status) AS SortOrder
      FROM #ins
     GROUP BY implementation_status
     ORDER BY SortOrder;

    -- ---- 3. Lists: none (the page lists releases from subscribed-
    --      frameworks and attention items from dashboard-summary).
    SELECT CAST(NULL AS NVARCHAR(40)) AS ListKey, CAST(NULL AS NVARCHAR(200)) AS ListTitle,
           CAST(NULL AS BIGINT) AS RecordId, CAST(NULL AS NVARCHAR(100)) AS RefText,
           CAST(NULL AS NVARCHAR(400)) AS Title, CAST(NULL AS NVARCHAR(300)) AS OwnerName,
           CAST(NULL AS NVARCHAR(100)) AS StatusText, CAST(NULL AS DATE) AS DateValue,
           CAST(NULL AS INT) AS SortOrder
     WHERE 1 = 0;
END
GO

-- 7. sp_practice_instance_open_implementation_task (from 043) -----------
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_instance_open_implementation_task
    @practice_instance_id  BIGINT,
    @subject_title         NVARCHAR(250),
    @subject_description   NVARCHAR(MAX)   = NULL,
    @assigned_to_employee_id BIGINT        = NULL,
    @target_date           DATETIME2       = NULL,          -- maps to sla_due_at
    @priority              NVARCHAR(30)    = NULL,
    @remarks               NVARCHAR(1000)  = NULL,          -- Q14: reuse reason_text
    @actor_employee_id     BIGINT          = NULL,
    @actor_role_code       NVARCHAR(60)    = NULL,
    @correlation_id        UNIQUEIDENTIFIER = NULL,
    @task_id               BIGINT          OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 54301, 'sp_practice_instance_open_implementation_task: @practice_instance_id is required.', 1;
    IF @subject_title IS NULL OR LTRIM(RTRIM(@subject_title)) = N''
        THROW 54303, 'sp_practice_instance_open_implementation_task: @subject_title is required.', 1;

    -- Resolve instance + its declared status (from either column).
    DECLARE @organization_id BIGINT,
            @practice_id     BIGINT,
            @status_id_col   INT,
            @status_txt_col  NVARCHAR(40),
            @status_code_now NVARCHAR(60),
            @instance_code   NVARCHAR(100);

    SELECT @organization_id = pi.organization_id,
           @practice_id     = pi.practice_id,
           @status_id_col   = pi.implementation_status_id,
           @status_txt_col  = pi.implementation_status,
           @instance_code   = pi.instance_code
    FROM grac_practice.practice_instance pi
    WHERE pi.practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
    BEGIN
        DECLARE @msg1 NVARCHAR(200) = CONCAT(N'Practice Instance ', CAST(@practice_instance_id AS NVARCHAR(30)), N' not found.');
        THROW 54301, @msg1, 1;
    END

    -- Prefer the surrogate FK; fall back to the legacy NVARCHAR label.
    IF @status_id_col IS NOT NULL
        SELECT @status_code_now = ims.status_code
        FROM grac_practice.implementation_status_master ims
        WHERE ims.implementation_status_id = @status_id_col;

    IF @status_code_now IS NULL
        SET @status_code_now = @status_txt_col;

    -- 456: Not Updated is the default status now; it is as open to an
    -- Implementation Task as the legacy Not Started was.
    IF ISNULL(@status_code_now, N'') NOT IN (N'Not Implemented', N'Not Started', N'Not Updated')
    BEGIN
        DECLARE @msg2 NVARCHAR(400) = CONCAT(
            N'Practice Instance ', @instance_code,
            N' is in state ''', ISNULL(@status_code_now, N'<null>'),
            N'''. Implementation Task can only be opened when state is ''Not Updated'' or ''Not Implemented''.');
        THROW 54302, @msg2, 1;
    END

    -- Delegate to the task engine -- idempotent by the filtered unique index.
    EXEC grac_practice.sp_task_open
        @organization_id         = @organization_id,
        @task_type_code          = N'Implementation',
        @subject_entity_type     = N'PracticeInstance',
        @subject_entity_id       = @practice_instance_id,
        @subject_title           = @subject_title,
        @subject_description     = @subject_description,
        @linked_practice_id      = @practice_id,
        @linked_instance_id      = @practice_instance_id,
        @priority                = @priority,
        @criticality             = NULL,
        @origin_code             = NULL,
        @assigned_to_employee_id = @assigned_to_employee_id,
        @actor_employee_id       = @actor_employee_id,
        @actor_role_code         = @actor_role_code,
        @correlation_id          = @correlation_id,
        @task_id                 = @task_id OUTPUT;

    -- If caller supplied a Target Date override, apply it now (sp_task_open
    -- uses the type's default_sla_hours otherwise).
    IF @target_date IS NOT NULL AND @task_id IS NOT NULL
    BEGIN
        UPDATE grac_practice.practice_task
           SET sla_due_at  = @target_date,
               reason_text = ISNULL(@remarks, reason_text),
               updated_by  = CASE WHEN @actor_employee_id IS NOT NULL
                                  THEN CONCAT('emp:', CAST(@actor_employee_id AS NVARCHAR(30)))
                                  ELSE N'system' END,
               updated_dt  = SYSUTCDATETIME()
         WHERE task_id = @task_id;
    END
    ELSE IF @remarks IS NOT NULL AND @task_id IS NOT NULL
    BEGIN
        UPDATE grac_practice.practice_task
           SET reason_text = @remarks,
               updated_by  = CASE WHEN @actor_employee_id IS NOT NULL
                                  THEN CONCAT('emp:', CAST(@actor_employee_id AS NVARCHAR(30)))
                                  ELSE N'system' END,
               updated_dt  = SYSUTCDATETIME()
         WHERE task_id = @task_id;
    END
END;
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 456 verification ===';
SELECT '456 master row' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.implementation_status_master WHERE status_code = N'Not Updated')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '456 objects',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_pm_recalc_instance_impl_status')) LIKE '%updated_n%'
             AND OBJECT_ID('grac_practice.tr_pm_practice_instance_impl_status_default','TR') IS NOT NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_detail_get')) LIKE '%UpdatedInstanceCount%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_dashboard_governance')) LIKE '%notupdated%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_instance_open_implementation_task')) LIKE '%Not Updated%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- An instance whose applicable obligations are all unset must be Not Updated.
SELECT '456 unset instances are Not Updated',
       CASE WHEN NOT EXISTS (
           SELECT 1
           FROM   grac_practice.practice_instance pi
           JOIN  (SELECT pio.practice_instance_id
                  FROM   grac_practice.practice_instance_obligation pio
                  LEFT   JOIN grac_practice.implementation_status_master ims
                         ON ims.implementation_status_id = pio.implementation_status_id
                  WHERE  pio.status = N'Active'
                    AND  COALESCE(ims.status_code, N'Not Started') <> N'N/A'
                  GROUP  BY pio.practice_instance_id
                  HAVING SUM(CASE WHEN COALESCE(ims.status_code, N'Not Started') IN (N'Not Started', N'Not Updated') THEN 0 ELSE 1 END) = 0) u
                  ON u.practice_instance_id = pi.practice_instance_id
           WHERE  ISNULL(pi.implementation_status, N'') <> N'Not Updated')
            THEN 'PASS' ELSE 'FAIL' END;

SELECT implementation_status AS ImplementationStatus, COUNT(*) AS Instances
FROM   grac_practice.practice_instance
GROUP  BY implementation_status
ORDER  BY implementation_status;
GO
PRINT '456 complete.';
GO
